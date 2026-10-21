import { test } from "node:test";
import assert from "node:assert/strict";
import * as lib from "@clusterio/lib";
import type { InstancePluginContext } from "@clusterio/host";
import {
	ChunkPayload, ConnectorChangeRequest, EdgeActivationEvent, EdgePurgedEvent, EdgeSyncEvent, EdgeUpdateEvent,
	LaneBatchEvent, type EdgeRecord, type LaneMsg,
} from "../../edges/contracts.js";
import {
	EdgeViews, HOLD_BATCHES, appliedAggregator, digest, edgeForwarding, laneHold, reassembly, sideRecord, verdict,
} from "../../edges/lanes.js";
import type { Bridge } from "../../runtime/index.js";

const turn = () => new Promise(resolve => {
	setImmediate(resolve);
});

function recorder() {
	const events: [boolean, string[]][] = [];
	const aggregator = appliedAggregator((sync, edges) => {
		events.push([sync, edges.map(e => e.id)]);
	});
	return { events, aggregator };
}

test("the reports of one turn leave as one event, not marked sync", async () => {
	const { events, aggregator } = recorder();
	aggregator.add({ id: "e1", revision: 1, open: 0 });
	aggregator.add({ id: "e2", revision: 2, open: 0 });
	assert.deepEqual(events, [], "nothing leaves within the turn");
	await turn();
	aggregator.add({ id: "e3", revision: 3, open: 0 });
	await turn();
	assert.deepEqual(events, [[false, ["e1", "e2"]], [false, ["e3"]]]);
});

test("synced() sends what is pending at once, marked sync, and the turn then sends nothing more", async () => {
	const { events, aggregator } = recorder();
	aggregator.add({ id: "e1", revision: 1, open: 0 });
	aggregator.synced();
	await turn();
	assert.deepEqual(events, [[true, ["e1"]]]);
});

test("an instance with no edges still ends its sync", () => {
	const { events, aggregator } = recorder();
	aggregator.synced();
	assert.deepEqual(events, [[true, []]]);
});

test("records reach Lua with this instance's side; a record naming neither side is not forwarded", () => {
	const edge = {
		id: "e1",
		a: { instanceId: 1, surface: "nauvis", origin: [0, 0], facing: 0 },
		b: { instanceId: 2, surface: "nauvis", origin: [64, 0], facing: 8 },
	} as EdgeRecord;
	assert.equal(sideRecord(edge, 1)?.me, "a");
	assert.equal(sideRecord(edge, 2)?.me, "b");
	assert.equal(sideRecord(edge, 3), undefined);
});

// SP1b: the edge view, direct lane batches, the receiver's checks and hold, reassembly and the digest (SP1 spec §11.2).

function rec(id: string, a: number, b: number, fields: Partial<EdgeRecord> = {}): EdgeRecord {
	return {
		id, owner: "test", length: 64, revision: 1, deleted: false, connectors: [], trace: "t", updatedAtMs: 0,
		a: { instanceId: a, surface: "nauvis", origin: [0, 0], facing: 0 },
		b: { instanceId: b, surface: "nauvis", origin: [64, 0], facing: 8 },
		...fields,
	};
}

type Sent = { to: unknown; message: unknown };
type Line = { level: string; message: string; meta: Record<string, any> };
// ponytail: a named alias, not an inline generic in `new Map<...>()` — ESLint's func-call-spacing misreads those.
type EventHandler = (event: any, src: lib.Address) => Promise<void>;

/** Instance 1's forwarding, with a fake instance and bridge: what it sends, logs and hands to Lua. */
function forwarding(reply: object = { ok: true }) {
	const handlers = new Map<unknown, EventHandler>();
	const sent: Sent[] = [];
	const lines: Line[] = [];
	const toLua: { type: string; payload: any }[] = [];
	const log = (level: string, message: string, meta: Record<string, any> = {}) => {
		lines.push({ level, message, meta });
	};
	const context = {
		instance: {
			id: 1,
			handle: (Class: unknown, fn: EventHandler) => handlers.set(Class, fn),
			sendTo: (to: unknown, message: unknown) => {
				sent.push({ to, message });
				return reply instanceof Error ? Promise.reject(reply) : Promise.resolve(reply);
			},
		},
		logger: { log, warn: (message: string, meta?: Record<string, any>) => log("warn", message, meta) },
	} as unknown as InstancePluginContext;
	const f = edgeForwarding(context, () => "b00t0001");
	const bridge: Bridge = {
		send: (type, payload) => {
			toLua.push({ type, payload });
		},
		rcon: async () => "",
		start: () => undefined,
	};
	f.attach(bridge);
	const from = (id: number) => new lib.Address(lib.Address.instance, id);
	const fire = (Class: unknown, event: unknown, src = from(0)) => handlers.get(Class)!(event, src);
	const lua = (type: string, payload: object) => f.handlers[type].handle(payload);
	return { f, sent, lines, toLua, fire, lua, from };
}

test("lane messages leave as one batch per (edge, epoch) per turn, addressed to the edge's partner", async () => {
	const w = forwarding();
	await w.fire(EdgeSyncEvent, new EdgeSyncEvent([rec("e1", 1, 2), rec("e2", 3, 1)]));
	w.lua("ue.lane", { edge: "e1", epoch: "E1", k: "s.offer", cid: "c1", dir: "ab", totals: { iron: 1 } });
	w.lua("ue.lane", { edge: "e2", epoch: "E2", k: "ep", cid: "c4", state: "ready" });
	w.lua("ue.lane", { edge: "e1", epoch: "E1", k: "ep", cid: "c1", state: "ready" });
	w.lua("ue.lane", { edge: "e9", epoch: "E9", k: "ep", cid: "c9", state: "ready" });
	assert.equal(w.sent.length, 0, "nothing leaves within the turn");
	await turn();
	const batches = w.sent.map(s => {
		const batch = s.message as LaneBatchEvent;
		return [s.to, batch.edge, batch.msgs.map(m => m.k)];
	});
	assert.deepEqual(batches, [
		[{ instanceId: 2 }, "e1", ["s.offer", "ep"]],
		[{ instanceId: 3 }, "e2", ["ep"]],
	], "grouped in order; the edge the view lacks (e9) is dropped");
	assert.ok(w.sent.every(s => s.message instanceof LaneBatchEvent));
});

test("the edge view: a sync replaces it, an update sets the partner, activations move epochs, a purge deletes", () => {
	const views = new EdgeViews(1);
	views.sync([rec("e1", 1, 2), rec("e2", 5, 6)]);
	assert.deepEqual([...views.edges.keys()], ["e1"], "only edges this instance is a side of");
	views.activation("e1", true, "E1");
	views.activation("e1", true, "E1");
	assert.deepEqual(views.edges.get("e1"), { partner: 2, epoch: "E1" }, "a re-assertion changes nothing");
	views.activation("e1", true, "E2");
	const moved = { partner: 2, epoch: "E2", ended: "E1" };
	assert.deepEqual(views.edges.get("e1"), moved, "another epoch ends the current one");
	views.activation("e1", false, undefined);
	assert.deepEqual(views.edges.get("e1"), { partner: 2, epoch: undefined, ended: "E2" }, "so does a deactivation");
	views.activation("e1", true, "E3");
	views.sync([rec("e1", 1, 2)]);
	assert.deepEqual(views.edges.get("e1"), { partner: 2, ended: "E3" }, "a sync keeps the last epoch as ended");
	views.update(rec("e1", 1, 2, { deleted: true }));
	views.update(rec("e3", 7, 1));
	assert.equal(views.edges.get("e3")?.partner, 7, "an update adds an edge");
	assert.equal(views.edges.get("e1")?.ended, "E3", "a tombstone keeps its epochs");
	views.purged("e1");
	assert.equal(views.edges.has("e1"), false);
});

test("the receiver's checks, in order: sender, current, ended, unseen (§11.2)", () => {
	const view = { partner: 2, epoch: "E2", ended: "E1" };
	assert.equal(verdict(undefined, 2, "E2"), "unknown_edge");
	assert.equal(verdict(view, 3, "E2"), "not_partner");
	assert.equal(verdict(view, 2, "E2"), "deliver");
	assert.equal(verdict(view, 2, "E1"), "stale");
	assert.equal(verdict(view, 2, "E9"), "hold");
});

test("a partner's current-epoch batch reaches Lua in order, with digests, before the handler returns", async () => {
	const w = forwarding();
	await w.fire(EdgeSyncEvent, new EdgeSyncEvent([rec("e1", 1, 2)]));
	await w.fire(EdgeActivationEvent, new EdgeActivationEvent("e1", true, "E1", "E1"));
	w.toLua.length = 0;
	const msgs: LaneMsg[] = [
		{ k: "u.offer", cid: "c1", dir: "ba", seq: 1, tag: "T", body: "Ym9keQ==", trace: "t.1" },
		{ k: "ep", cid: "c1", state: "ready" },
	];
	void w.fire(LaneBatchEvent, new LaneBatchEvent("e1", "E1", msgs), w.from(2));
	assert.deepEqual(w.toLua.map(m => [m.type, m.payload.k, m.payload.edge, m.payload.epoch]), [
		["ue.lane", "u.offer", "e1", "E1"], ["ue.lane", "ep", "e1", "E1"],
	], "synchronously: no await before the enqueue");
	assert.equal(w.toLua[0].payload.digest, digest("Ym9keQ=="));
	assert.match(digest("Ym9keQ=="), /^[0-9a-f]{16}$/);
});

test("a batch from a non-partner, or for an unknown edge, is dropped with ue.lane rejected (M3)", async () => {
	const w = forwarding();
	await w.fire(EdgeSyncEvent, new EdgeSyncEvent([rec("e1", 1, 2)]));
	await w.fire(EdgeActivationEvent, new EdgeActivationEvent("e1", true, "E1", "E1"));
	w.toLua.length = 0;
	await w.fire(LaneBatchEvent, new LaneBatchEvent("e1", "E1", [{ k: "ep" }]), w.from(3));
	await w.fire(LaneBatchEvent, new LaneBatchEvent("e7", "E1", [{ k: "ep" }]), w.from(2));
	assert.equal(w.toLua.length, 0);
	const rejected = w.lines.filter(l => l.message === "ue.lane rejected");
	assert.deepEqual(rejected.map(l => l.meta.reason), ["not_partner", "unknown_edge"]);
	assert.equal(rejected[0].meta.from, 3);
});

test("an ended epoch's batch is dropped; a tombstone still delivers while it is active", async () => {
	const w = forwarding();
	await w.fire(EdgeSyncEvent, new EdgeSyncEvent([rec("e1", 1, 2)]));
	await w.fire(EdgeActivationEvent, new EdgeActivationEvent("e1", true, "E1", "E1"));
	await w.fire(EdgeActivationEvent, new EdgeActivationEvent("e1", true, "E2", "E2"));
	await w.fire(EdgeUpdateEvent, new EdgeUpdateEvent(rec("e1", 1, 2, { deleted: true, revision: 2 })));
	w.toLua.length = 0;
	await w.fire(LaneBatchEvent, new LaneBatchEvent("e1", "E1", [{ k: "done", cid: "c1", dir: "ab" }]), w.from(2));
	assert.equal(w.toLua.length, 0, "E1 ended");
	await w.fire(LaneBatchEvent, new LaneBatchEvent("e1", "E2", [{ k: "done", cid: "c1", dir: "ab" }]), w.from(2));
	assert.equal(w.toLua.length, 1, "the tombstone's current epoch still delivers");
});

test("a batch for an unseen epoch waits for its activation, then follows it in arrival order", async () => {
	const w = forwarding();
	await w.fire(EdgeSyncEvent, new EdgeSyncEvent([rec("e1", 1, 2)]));
	w.toLua.length = 0;
	await w.fire(LaneBatchEvent, new LaneBatchEvent("e1", "E5", [{ k: "ep", n: 1 }]), w.from(2));
	await w.fire(LaneBatchEvent, new LaneBatchEvent("e1", "E5", [{ k: "ep", n: 2 }]), w.from(2));
	assert.equal(w.toLua.length, 0, "held");
	await w.fire(EdgeActivationEvent, new EdgeActivationEvent("e1", true, "E5", "E5"));
	assert.deepEqual(w.toLua.map(m => (m.type === "ue.lane" ? m.payload.n : m.type)), ["ue.edge.activation", 1, 2]);
});

test("the hold keeps at most 64 batches per edge and none past 10 s, each drop logged", () => {
	let now = 0;
	const lines: string[] = [];
	const warn = (_key: string, message: string) => {
		lines.push(message);
	};
	const hold = laneHold(warn, () => now);
	for (let i = 0; i <= HOLD_BATCHES; i++) {
		hold.add("e1", "E9", [{ k: "ep", n: i }]);
	}
	assert.deepEqual(lines, ["ue.lane hold_overflow"], "the 65th is dropped");
	hold.add("e2", "E8", [{ k: "ep" }]);
	now = 10_000;
	assert.deepEqual(hold.take("e2", "E8"), [], "a batch of an epoch never seen expires after 10 s");
	assert.equal(lines.at(-1), "ue.lane hold_expired");
	now = 5_000;
	hold.add("e3", "E1", [{ k: "ep", n: 1 }]);
	hold.add("e3", "E2", [{ k: "ep", n: 2 }]);
	assert.deepEqual(hold.take("e3", "E2"), [[{ k: "ep", n: 2 }]], "only the activated epoch's batches");
	assert.deepEqual(hold.take("e3", "E1"), [[{ k: "ep", n: 1 }]], "the other one still waits");
});

test("reassembly: parts in order make the body; a missing part, the 16-key cap and the 60 s TTL drop it", () => {
	let now = 0;
	const r = reassembly(() => now);
	r.part({ key: "e/c1/ab/1", i: 1, n: 2, data: "ab" });
	r.part({ key: "e/c1/ab/1", i: 2, n: 2, data: "cd" });
	assert.equal(r.take("e/c1/ab/1", 2), "abcd");
	r.part({ key: "e/c1/ab/2", i: 2, n: 2, data: "cd" });
	assert.equal(r.take("e/c1/ab/2", 2), undefined, "a missing part");
	for (let i = 0; i < 17; i++) {
		r.part({ key: `k${i}`, i: 1, n: 1, data: "x" });
	}
	assert.equal(r.take("k0", 1), undefined, "the oldest of 17 was evicted");
	assert.equal(r.take("k16", 1), "x");
	r.part({ key: "late", i: 1, n: 2, data: "a" });
	now = 60_000;
	r.part({ key: "other", i: 1, n: 1, data: "b" });
	r.part({ key: "late", i: 2, n: 2, data: "b" });
	assert.equal(r.take("late", 2), undefined, "the first part expired after 60 s");
});

test("reassembly: json parses the body, and a missing part, a body that isn't JSON or one valid refuses is undefined",
	() => {
		const r = reassembly();
		const parts = (key: string, ...data: string[]) => data.forEach((d, i) => {
			r.part({ key, i: i + 1, n: data.length, data: d });
		});
		parts("ok", '{"a":', "1}");
		assert.deepEqual(r.json("ok", 2), { a: 1 });
		parts("missing", '{"a":', "1}");
		assert.equal(r.json("missing", 3), undefined);
		parts("bad", '{"a":', "1");
		assert.equal(r.json("bad", 2), undefined, "a parse error is no throw");
		assert.equal(r.take("bad", 2), undefined, "and its parts are forgotten too");
		parts("refused", "[1]");
		assert.equal(r.json("refused", 1, (v): v is number => typeof v === "number"), undefined);
		parts("kept", "[1]");
		assert.deepEqual(r.json("kept", 1, Array.isArray), [1]);
	});

test("a chunked offer from Lua leaves as one message with the reassembled body", async () => {
	const w = forwarding();
	await w.fire(EdgeSyncEvent, new EdgeSyncEvent([rec("e1", 1, 2)]));
	w.lua("ue.chunk", { key: "e1/c1/ab/4", i: 1, n: 2, data: "AAAA" });
	w.lua("ue.chunk", { key: "e1/c1/ab/4", i: 2, n: 2, data: "BB==" });
	const offer = { edge: "e1", epoch: "E1", k: "u.offer", cid: "c1", dir: "ab", tag: "T", trace: "t", chunks: 2 };
	w.lua("ue.lane", { ...offer, seq: 4 });
	w.lua("ue.lane", { ...offer, seq: 5 });
	await turn();
	const msgs = (w.sent[0].message as LaneBatchEvent).msgs;
	const got = msgs.map(m => [m.seq, m.body, m.chunks]);
	assert.deepEqual(got, [[4, "AAAABB==", undefined]], "seq 5's parts never came");
	assert.ok(w.lines.some(l => l.message === "ue.lane chunked offer incomplete, dropped"));
});

test("a purge forgets the edge and its hold; ep:request_removal becomes a ConnectorChangeRequest", async () => {
	const w = forwarding();
	await w.fire(EdgeSyncEvent, new EdgeSyncEvent([rec("e1", 1, 2)]));
	await w.fire(LaneBatchEvent, new LaneBatchEvent("e1", "E5", [{ k: "ep" }]), w.from(2));
	await w.fire(EdgePurgedEvent, new EdgePurgedEvent("e1"));
	await w.fire(EdgeActivationEvent, new EdgeActivationEvent("e1", true, "E5", "E5"));
	assert.ok(w.toLua.every(m => m.type !== "ue.lane"), "the held batch went with the edge");
	w.lua("ue.connector.remove", { edge: "e1", cid: "c3", reason: "gone", trace: "t.9" });
	const request = w.sent.find(s => s.message instanceof ConnectorChangeRequest)!;
	assert.equal(request.to, "controller");
	const change = { edge: "e1", op: "remove", cid: "c3", trace: "t.9" };
	assert.deepEqual((request.message as ConnectorChangeRequest).change, change);
});

test("a proposal becomes a ConnectorChangeRequest add", async () => {
	const w = forwarding();
	w.lua("ue.connector.propose", { edge: "e1", type: "belt", pos: 3, width: 1, params: { dir: "ab" }, trace: "t1" });
	const last = w.sent.at(-1)!;
	assert.equal(last.to, "controller");
	assert.ok(last.message instanceof ConnectorChangeRequest);
	assert.deepEqual((last.message as ConnectorChangeRequest).change,
		{ edge: "e1", op: "add", type: "belt", pos: 3, width: 1, params: { dir: "ab" }, trace: "t1" });
});

test("a refused proposal is logged at warn, once a minute per edge", async () => {
	const w = forwarding({ ok: false, reason: "overlap" });
	for (const trace of ["t1", "t2"]) {
		w.lua("ue.connector.propose", { edge: "e1", type: "pipe", pos: 2, width: 1, params: {}, trace });
	}
	await turn();
	const refused = w.lines.filter(l => l.message === "ue.connector proposal_refused");
	assert.equal(refused.length, 1);
	assert.equal(refused[0].level, "warn");
	assert.equal(refused[0].meta.reason, "overlap");
});

test("a refused or failed proposal is told to Lua as ue.connector.refused; an accepted one is not", async () => {
	const proposal = { edge: "e1", type: "train", pos: 3, width: 4, params: {}, trace: "t1" };
	const refused = forwarding({ ok: false, reason: "overlap" });
	refused.lua("ue.connector.propose", proposal);
	await turn();
	assert.deepEqual(refused.toLua.filter(m => m.type === "ue.connector.refused").map(m => m.payload),
		[{ trace: "t1", reason: "overlap" }]);
	const failed = forwarding(new Error("no controller"));
	failed.lua("ue.connector.propose", proposal);
	await turn();
	assert.deepEqual(failed.toLua.filter(m => m.type === "ue.connector.refused").map(m => m.payload),
		[{ trace: "t1", reason: "no controller" }]);
	const w = forwarding({ ok: true });
	w.lua("ue.connector.propose", proposal);
	await turn();
	assert.ok(w.toLua.every(m => m.type !== "ue.connector.refused"), "accepted: nothing");
});

test("the E2E delay seam holds every received batch for UE_TEST_LANE_DELAY_MS, in order", async () => {
	process.env.UE_TEST_LANE_DELAY_MS = "30";
	const w = forwarding();
	delete process.env.UE_TEST_LANE_DELAY_MS;
	await w.fire(EdgeSyncEvent, new EdgeSyncEvent([rec("e1", 1, 2)]));
	await w.fire(EdgeActivationEvent, new EdgeActivationEvent("e1", true, "E1", "t"));
	w.toLua.length = 0;
	for (const k of ["s.offer", "s.ack"]) {
		await w.fire(LaneBatchEvent, new LaneBatchEvent("e1", "E1", [{ k }]), w.from(2));
	}
	assert.equal(w.toLua.length, 0, "held");
	await new Promise(resolve => setTimeout(resolve, 60));
	assert.deepEqual(w.toLua.map(m => m.payload.k), ["s.offer", "s.ack"]);
	assert.ok(w.lines.some(l => l.message === "ue.lane test_delay"), "the seam says it is on");
});

test("FC3: a chunked status from Lua leaves as one ep message with its status parsed; one missing a part is dropped, " +
	"and a small status passes as it is", async () => {
	const w = forwarding();
	await w.fire(EdgeSyncEvent, new EdgeSyncEvent([rec("e1", 1, 2)]));
	const status = { v: 3, gr: "c1", r: { item: ["iron-plate", 120, "copper-plate", -5] } };
	const json = JSON.stringify(status);
	const half = Math.ceil(json.length / 2);
	w.lua("ue.chunk", { key: "e1/c1/ep/1", i: 1, n: 2, data: json.slice(0, half) });
	w.lua("ue.chunk", { key: "e1/c1/ep/1", i: 2, n: 2, data: json.slice(half) });
	const ep = { edge: "e1", epoch: "E1", k: "ep", cid: "c1", state: "ready", chunks: 2 };
	w.lua("ue.lane", { ...ep, seq: 1 });
	w.lua("ue.lane", { ...ep, seq: 2 });
	w.lua("ue.lane", { edge: "e1", epoch: "E1", k: "ep", cid: "c2", state: "ready", status: { v: 1 } });
	await turn();
	const msgs = (w.sent[0].message as LaneBatchEvent).msgs;
	assert.deepEqual(msgs.map(m => [m.cid, m.status, m.chunks, m.body]), [
		["c1", status, undefined, undefined],
		["c2", { v: 1 }, undefined, undefined],
	], "seq 2's parts never came");
	assert.ok(w.lines.some(l => l.message === "ue.lane chunked status incomplete or invalid, dropped"));
});

test("FC3: a chunked status that isn't JSON is dropped with a warning, not thrown", async () => {
	const w = forwarding();
	await w.fire(EdgeSyncEvent, new EdgeSyncEvent([rec("e1", 1, 2)]));
	w.lua("ue.chunk", { key: "e1/c1/ep/1", i: 1, n: 2, data: '{"v":' });
	w.lua("ue.chunk", { key: "e1/c1/ep/1", i: 2, n: 2, data: "3" });
	w.lua("ue.lane", { edge: "e1", epoch: "E1", k: "ep", cid: "c1", state: "ready", chunks: 2, seq: 1 });
	await turn();
	assert.equal(w.sent.length, 0);
	assert.ok(w.lines.some(l => l.message === "ue.lane chunked status incomplete or invalid, dropped"));
});

test("FC3: two chunked statuses of one endpoint in flight at once reassemble under their own keys", async () => {
	const w = forwarding();
	await w.fire(EdgeSyncEvent, new EdgeSyncEvent([rec("e1", 1, 2)]));
	const first = JSON.stringify({ v: 4, r: { virtual: ["signal-A", 1] } });
	const second = JSON.stringify({ v: 5, base: 4, r: { virtual: ["signal-A", 2] } });
	w.lua("ue.chunk", { key: "e1/c1/ep/1", i: 1, n: 2, data: first.slice(0, 10) });
	w.lua("ue.chunk", { key: "e1/c1/ep/2", i: 1, n: 2, data: second.slice(0, 10) });
	w.lua("ue.chunk", { key: "e1/c1/ep/2", i: 2, n: 2, data: second.slice(10) });
	w.lua("ue.chunk", { key: "e1/c1/ep/1", i: 2, n: 2, data: first.slice(10) });
	const ep = { edge: "e1", epoch: "E1", k: "ep", cid: "c1", state: "ready", chunks: 2 };
	w.lua("ue.lane", { ...ep, seq: 1 });
	w.lua("ue.lane", { ...ep, seq: 2 });
	await turn();
	const msgs = (w.sent[0].message as LaneBatchEvent).msgs;
	assert.deepEqual(msgs.map(m => m.status), [JSON.parse(first), JSON.parse(second)]);
});

test("FC3, fix 4: ChunkPayload allows 64 parts and refuses 65; a status the size of spike 9d's 2,000 × 2 reassembles",
	async () => {
		const valid = lib.compile(ChunkPayload as any);
		assert.ok(valid({ key: "k", i: 1, n: 64, data: "x" }), "64 parts");
		assert.ok(!valid({ key: "k", i: 1, n: 65, data: "x" }), "65 refused");
		const list = (base: number) => Array.from({ length: 2000 },
			(_, i) => [`signal-${String(i).padStart(9, "0")}`, base + i]).flat();
		const status = { v: 1, gr: "c1", gg: "c1", r: { item: list(10000) }, g: { item: list(20000) } };
		const json = JSON.stringify(status);
		const n = Math.ceil(json.length / 3000);
		assert.ok(n >= 33 && n <= 64, `${json.length} bytes in ${n} parts`);
		const w = forwarding();
		await w.fire(EdgeSyncEvent, new EdgeSyncEvent([rec("e1", 1, 2)]));
		for (let i = 1; i <= n; i++) {
			w.lua("ue.chunk", { key: "e1/c1/ep/7", i, n, data: json.slice((i - 1) * 3000, i * 3000) });
		}
		w.lua("ue.lane", { edge: "e1", epoch: "E1", k: "ep", cid: "c1", state: "ready", chunks: n, seq: 7 });
		await turn();
		assert.deepEqual((w.sent[0].message as LaneBatchEvent).msgs[0].status, status);
	});
