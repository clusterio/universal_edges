import { createHash } from "node:crypto";
import * as lib from "@clusterio/lib";
import type { InstancePluginContext } from "@clusterio/host";
import { lifecycle, on, rateLimited, type Bridge, type Handler } from "../runtime/index.js";
import {
	AppliedPayload, ChunkPayload, ConnectorChangeRequest, EdgeActivationEvent, EdgeAppliedEvent, EdgePurgedEvent,
	EdgeSyncEvent, EdgeUpdateEvent, LaneBatchEvent, LaneOutPayload, ProposalPayload, RemovalPayload, SyncedPayload,
	type AppliedEdge, type EdgeRecord, type LaneMsg,
} from "./contracts.js";

/** SP1 spec §11.11: the receiver's hold for an unseen activation, and the source's chunk reassembly. */
export const HOLD_BATCHES = 64;
export const HOLD_MS = 10_000;
export const REASSEMBLY_KEYS = 16;
export const REASSEMBLY_MS = 60_000;

/** A record as Lua gets it: annotated with the side this instance is (SP1 spec §4, forwarding). */
export type SideRecord = EdgeRecord & { me: "a" | "b" };

/** Annotate a record with this instance's side of it; undefined when the instance is neither side. */
export function sideRecord(edge: EdgeRecord, instanceId: number): SideRecord | undefined {
	if (edge.a.instanceId === instanceId) {
		return { ...edge, me: "a" };
	}
	if (edge.b.instanceId === instanceId) {
		return { ...edge, me: "b" };
	}
	return undefined;
}

/**
 * Collect Lua's per-edge applied reports into one event per event-loop turn (§4). synced() ends a sync: what is
 * pending leaves at once, marked sync, even when nothing is, since an instance with no edges is synced too.
 */
export function appliedAggregator(emit: (sync: boolean, edges: AppliedEdge[]) => void) {
	let pending: AppliedEdge[] = [];
	let scheduled = false;
	function flush(sync: boolean) {
		scheduled = false;
		const edges = pending;
		pending = [];
		if (sync || edges.length > 0) {
			emit(sync, edges);
		}
	}
	return {
		add(edge: AppliedEdge) {
			pending.push(edge);
			if (!scheduled) {
				scheduled = true;
				setImmediate(() => {
					if (scheduled) {
						flush(false);
					}
				});
			}
		},
		synced() {
			flush(true);
		},
	};
}

/** The first 16 hex characters of the body's SHA-256 (§4). Synchronous: an await before the enqueue breaks order. */
export function digest(body: string): string {
	return createHash("sha256").update(body).digest("hex").slice(0, 16);
}

/** One edge as this instance knows it (§11.2): the partner instance, the current epoch, and the last one ended. */
export type EdgeView = { partner: number; epoch?: string; ended?: string };

/** What the receiver does with a batch (§11.2), in the order it checks. */
export type Verdict = "unknown_edge" | "not_partner" | "deliver" | "stale" | "hold";

export function verdict(view: EdgeView | undefined, from: number, epoch: string): Verdict {
	if (!view) {
		return "unknown_edge";
	}
	if (from !== view.partner) {
		return "not_partner";
	}
	if (epoch === view.epoch) {
		return "deliver";
	}
	return epoch === view.ended ? "stale" : "hold";
}

/**
 * The edge view (§11.2), kept from the controller's messages in the handlers that forward them. Memory only: the
 * instance plugin starts with each Factorio run, and the controller's first sync fills it.
 */
export class EdgeViews {
	readonly edges = new Map<string, EdgeView>();

	constructor(private instanceId: number) { }

	private partnerOf(edge: EdgeRecord): number | undefined {
		const side = sideRecord(edge, this.instanceId);
		if (!side) {
			return undefined;
		}
		return side.me === "a" ? edge.b.instanceId : edge.a.instanceId;
	}

	/** A sync replaces the view. An edge it keeps remembers its last epoch as ended, so a late batch is dropped. */
	sync(records: EdgeRecord[]): void {
		const old = new Map(this.edges);
		this.edges.clear();
		for (const r of records) {
			const partner = this.partnerOf(r);
			if (partner !== undefined) {
				const was = old.get(r.id);
				const ended = was?.epoch ?? was?.ended;
				this.edges.set(r.id, ended === undefined ? { partner } : { partner, ended });
			}
		}
	}

	/** An update sets the edge's partner, tombstones included. */
	update(record: EdgeRecord): void {
		const partner = this.partnerOf(record);
		if (partner !== undefined) {
			const was = this.edges.get(record.id);
			this.edges.set(record.id, { ...was, partner });
		}
	}

	/** Another epoch, or a deactivation, ends the current one; the same epoch again changes nothing (§6.3). */
	activation(id: string, active: boolean, epoch: string | undefined): void {
		const view = this.edges.get(id);
		if (!view || (active && epoch === view.epoch)) {
			return;
		}
		if (view.epoch !== undefined) {
			view.ended = view.epoch;
		}
		view.epoch = active ? epoch : undefined;
	}

	purged(id: string): void {
		this.edges.delete(id);
	}
}

type Held = { epoch: string; msgs: LaneMsg[]; at: number };
type Warn = ReturnType<typeof rateLimited>;

/**
 * The hold (§11.2): batches of an activation this instance hasn't received wait until it arrives. At most 64 per
 * edge, and none past 10 s.
 * ponytail: expiry is checked whenever the edge's hold is touched, so no timer runs. An edge that is never touched
 * again keeps up to 64 expired batches until its purge or the instance's restart; sweep them if memory ever shows it.
 */
export function laneHold(warn: Warn, now: () => number = Date.now) {
	const held = new Map<string, Held[]>();
	function live(edge: string): Held[] {
		const list = held.get(edge) ?? [];
		const fresh = list.filter(h => now() - h.at < HOLD_MS);
		if (fresh.length < list.length) {
			warn(`expired:${edge}`, "ue.lane hold_expired", {
				op: "ue.lane", phase: "hold_expired", edge, dropped: list.length - fresh.length,
			});
		}
		held.set(edge, fresh);
		return fresh;
	}
	return {
		add(edge: string, epoch: string, msgs: LaneMsg[]): void {
			const list = live(edge);
			if (list.length >= HOLD_BATCHES) {
				const fields = { op: "ue.lane", phase: "hold_overflow", edge, epoch };
				warn(`overflow:${edge}`, "ue.lane hold_overflow", fields);
				return;
			}
			list.push({ epoch, msgs, at: now() });
		},
		/** The held batches of epoch, in arrival order, taken out of the hold. */
		take(edge: string, epoch: string): LaneMsg[][] {
			const list = live(edge);
			held.set(edge, list.filter(h => h.epoch !== epoch));
			return list.filter(h => h.epoch === epoch).map(h => h.msgs);
		},
		drop(edge: string): void {
			held.delete(edge);
		},
	};
}

/** The source's reassembly of ue.chunk parts (§11.2): at most 16 bodies in progress, none kept past 60 s. */
export function reassembly(now: () => number = Date.now) {
	const bodies = new Map<string, { n: number; parts: string[]; at: number }>();
	return {
		part(c: { key: string; i: number; n: number; data: string }): void {
			for (const [key, b] of bodies) {
				if (now() - b.at >= REASSEMBLY_MS) {
					bodies.delete(key);
				}
			}
			let body = bodies.get(c.key);
			if (!body || body.n !== c.n) {
				if (bodies.size >= REASSEMBLY_KEYS) {
					bodies.delete(bodies.keys().next().value!);
				}
				body = { n: c.n, parts: [], at: now() };
				bodies.set(c.key, body);
			}
			body.parts[c.i - 1] = c.data;
		},
		/** The body of key in n parts, or undefined when a part is missing. Either way the parts are forgotten. */
		take(key: string, n: number): string | undefined {
			const body = bodies.get(key);
			bodies.delete(key);
			if (!body || body.n !== n) {
				return undefined;
			}
			for (let i = 0; i < n; i++) {
				if (typeof body.parts[i] !== "string") {
					return undefined; // a sparse array's holes are invisible to some() and join()
				}
			}
			return body.parts.join("");
		},
	};
}

/** One Clusterio event per (edge, epoch) per event-loop turn (§4, §12 rule 6), in the order Lua sent them. */
export function laneBatcher(emit: (edge: string, epoch: string, msgs: LaneMsg[]) => void) {
	let pending = new Map<string, { edge: string; epoch: string; msgs: LaneMsg[] }>();
	let scheduled = false;
	return {
		add(edge: string, epoch: string, msg: LaneMsg): void {
			const key = `${edge}\n${epoch}`;
			const batch = pending.get(key) ?? { edge, epoch, msgs: [] };
			batch.msgs.push(msg);
			pending.set(key, batch);
			if (!scheduled) {
				scheduled = true;
				setImmediate(() => {
					scheduled = false;
					const batches = pending;
					pending = new Map();
					for (const b of batches.values()) {
						emit(b.edge, b.epoch, b.msgs);
					}
				});
			}
		},
	};
}

/** Lane batches by result, per instance: what the receiver checks drop is counted here as well as logged. */
const laneCounter = new lib.Counter(
	"clusterio_universal_edges_lane_batches_total",
	"Universal Edges lane batches by result (sent, unsent, delivered, held, stale, rejected, overflow, expired)",
	{ labels: ["instance_id", "result"] },
);

/**
 * The instance end of the edges (§4, §6, §11.2): the controller's edge messages go to Lua, and Lua's applied reports
 * go back as EdgeAppliedEvent, stamped with this run's boot id. Lane messages go straight to the edge's partner
 * instance (D6); a batch from the partner is checked, then delivered, held or dropped.
 */
export function edgeForwarding(context: InstancePluginContext, bootId: () => string) {
	const { instance, logger } = context;
	const warn = rateLimited(logger);
	const count = (result: string) => laneCounter.labels(String(instance.id), result).inc();
	const views = new EdgeViews(instance.id);
	const hold = laneHold(warn);
	const bodies = reassembly();
	// The E2E delay seam (SP3 §4.1, §15): every received lane batch waits this long, so two instances on one machine
	// see a 300 ms round trip at 150 each way. Read once, at plugin start; unset in production.
	const delay = Number(process.env.UE_TEST_LANE_DELAY_MS ?? 0);
	if (delay > 0) {
		logger.warn("ue.lane test_delay", { op: "ue.lane", phase: "test_delay", ms: delay });
	}
	let bridge: Bridge | undefined;
	const applied = appliedAggregator((sync, edges) => {
		try {
			instance.sendTo("controller", new EdgeAppliedEvent(bootId(), sync, edges));
		} catch (err: any) {
			warn("applied", "ue.edge applied report not sent", { error: err.message });
		}
	});
	const batches = laneBatcher((edge, epoch, msgs) => {
		const view = views.edges.get(edge);
		if (!view) {
			count("unsent");
			return; // the edge was purged, or isn't synced yet: the ledger's resends recover
		}
		try {
			instance.sendTo({ instanceId: view.partner }, new LaneBatchEvent(edge, epoch, msgs));
			count("sent");
		} catch (err: any) {
			count("unsent");
			warn(`send:${view.partner}`, "ue.lane batch not sent", { edge, partner: view.partner, error: err.message });
		}
	});

	/** To this instance's Lua, in order, each u.offer with the digest of its body. */
	function deliver(edge: string, epoch: string, msgs: LaneMsg[]) {
		count("delivered");
		for (const m of msgs) {
			const out: LaneMsg = { ...m, edge, epoch };
			if (m.k === "u.offer" && typeof m.body === "string") {
				out.digest = digest(m.body);
			}
			bridge!.send("ue.lane", out);
		}
	}

	/** §11.2's receiver checks, in order: the sender, then the current, ended or unseen activation. */
	function receive(event: LaneBatchEvent, from: number) {
		const view = views.edges.get(event.edge);
		const result = verdict(view, from, event.epoch);
		if (result === "deliver") {
			deliver(event.edge, event.epoch, event.msgs);
		} else if (result === "hold") {
			count("held");
			hold.add(event.edge, event.epoch, event.msgs);
		} else if (result === "stale") {
			count("stale");
		} else {
			count("rejected");
			warn(`rejected:${result}`, "ue.lane rejected", {
				op: "ue.lane", phase: "rejected", edge: event.edge, epoch: event.epoch, from, reason: result,
			});
		}
	}

	const handlers: Record<string, Handler> = {
		"ue.edge.applied": on(AppliedPayload, p => {
			const { id, revision, sync, open, trace } = p;
			lifecycle(logger, "ue.edge", "applied", { edge: id, revision, sync, open, trace });
			applied.add({ id, revision, open });
		}),
		"ue.edge.synced": on(SyncedPayload, () => {
			applied.synced();
		}),
		"ue.chunk": on(ChunkPayload, part => {
			bodies.part(part);
		}),
		"ue.lane": on(LaneOutPayload, p => {
			const { edge, epoch, ...fields } = p as Record<string, unknown> & { edge: string; epoch: string };
			const msg = fields as LaneMsg;
			// A unique offer's body, or (FC3, circuit-link spec §5.2) a big status, came in ue.chunk parts.
			if ((msg.k === "u.offer" || msg.k === "ep") && typeof msg.chunks === "number") {
				const lane = msg.k === "ep" ? "ep" : String(msg.dir);
				const key = `${edge}/${String(msg.cid)}/${lane}/${String(msg.seq)}`;
				const body = bodies.take(key, msg.chunks);
				if (body === undefined) {
					const what = msg.k === "ep" ? "status" : "offer";
					warn("chunks", `ue.lane chunked ${what} incomplete, dropped`, { edge, cid: msg.cid, seq: msg.seq });
					return; // an offer is re-offered; a lost status is a gap its receiver repairs with an ask (§8.3)
				}
				delete msg.chunks;
				if (msg.k === "ep") {
					msg.status = JSON.parse(body);
				} else {
					msg.body = body;
				}
			}
			batches.add(edge, epoch, msg);
		}),
		"ue.connector.remove": on(RemovalPayload, p => {
			const change = { edge: p.edge, op: "remove" as const, cid: p.cid, trace: p.trace };
			const fields = { edge: p.edge, cid: p.cid };
			instance.sendTo("controller", new ConnectorChangeRequest(change)).then(result => {
				if (!result.ok) {
					warn(`removal:${p.edge}`, "ue.connector removal refused", { ...fields, reason: result.reason });
				}
			}).catch((err: Error) => {
				warn(`removal:${p.edge}`, "ue.connector removal not sent", { ...fields, error: err.message });
			});
		}),
		"ue.connector.propose": on(ProposalPayload, p => {
			const { edge, type, pos, width, params, trace } = p;
			const change = { edge, op: "add" as const, type, pos, width, params, trace };
			const fields = { op: "ue.connector", phase: "proposal_refused", edge, type, pos, trace };
			instance.sendTo("controller", new ConnectorChangeRequest(change)).then(result => {
				if (!result.ok) {
					warn(`proposal:${edge}`, "ue.connector proposal_refused", { ...fields, reason: result.reason });
					bridge!.send("ue.connector.refused", { trace, reason: result.reason ?? "unknown" });
				}
			}).catch((err: Error) => {
				warn(`proposal:${edge}`, "ue.connector proposal_refused", { ...fields, reason: err.message });
				bridge!.send("ue.connector.refused", { trace, reason: err.message });
			});
		}),
	};

	/** Every handler enqueues synchronously, so Lua sees the edge messages in the controller's order (§6.1). */
	function attach(b: Bridge) {
		bridge = b;
		instance.handle(EdgeSyncEvent, async (event: EdgeSyncEvent) => {
			views.sync(event.edges);
			b.send("ue.edge.sync", { edges: event.edges.flatMap(edge => sideRecord(edge, instance.id) ?? []) });
		});
		instance.handle(EdgeUpdateEvent, async (event: EdgeUpdateEvent) => {
			const edge = sideRecord(event.edge, instance.id);
			if (edge) {
				views.update(event.edge);
				b.send("ue.edge.update", { edge });
			}
		});
		instance.handle(EdgeActivationEvent, async (event: EdgeActivationEvent) => {
			const { id, active, epoch, trace, reason } = event;
			views.activation(id, active, epoch);
			b.send("ue.edge.activation", { id, active, epoch, trace, reason });
			if (active && epoch !== undefined) {
				for (const msgs of hold.take(id, epoch)) {
					deliver(id, epoch, msgs);
				}
			}
		});
		instance.handle(EdgePurgedEvent, async (event: EdgePurgedEvent) => {
			views.purged(event.id);
			hold.drop(event.id);
			b.send("ue.edge.purged", { id: event.id });
		});
		instance.handle(LaneBatchEvent, async (event: LaneBatchEvent, src: lib.Address) => {
			if (delay > 0) {
				setTimeout(() => receive(event, src.id), delay); // equal delays fire in order
			} else {
				receive(event, src.id);
			}
		});
	}
	return { handlers, attach, views };
}
