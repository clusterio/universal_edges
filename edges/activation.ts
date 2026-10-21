import type * as lib from "@clusterio/lib";
import { lifecycle, newId } from "../runtime/index.js";
import {
	EdgeActivationEvent, EdgePurgedEvent, EdgeSyncEvent, EdgeUpdateEvent, type AppliedEdge, type EdgeRecord,
	type EdgeReadiness,
} from "./contracts.js";
import type { EdgeStore } from "./store.js";

/** What a side last reported of an edge: under which boot, at which revision, with how many lanes still open. */
export type Applied = { boot: string; revision: number; open: number };

/** The runtime facts activation reads (SP1 spec §5.1). Memory only: a controller restart starts them empty. */
export type Facts = {
	status(instanceId: number): string | undefined;
	boot(instanceId: number): string | undefined;
	syncedBoot(instanceId: number): string | undefined;
	applied(instanceId: number, edgeId: string): Applied | undefined;
};

export type Outbound = EdgeSyncEvent | EdgeUpdateEvent | EdgeActivationEvent | EdgePurgedEvent;

export type ActivationDeps = {
	/** Clusterio's status of the instance. */
	status(instanceId: number): string | undefined;
	/** False once the controller no longer has the instance. */
	exists(instanceId: number): boolean;
	/** Send to an instance; the sender logs a failure. */
	send(instanceId: number, message: Outbound): void;
	/** An edge's readiness changed (the web page's Ready column, D13). */
	readiness?(readiness: EdgeReadiness): void;
};

type EdgeState = { active: boolean; epoch?: string; trace: string; reason?: string; closing: boolean };

const sidesOf = (r: EdgeRecord) => [r.a.instanceId, r.b.instanceId];

/**
 * §6.1: the edge is live, or a tombstone a side is still closing lanes on, and both sides are running, synced and
 * applied under their current boot.
 */
export function isActive(r: EdgeRecord, f: Facts): boolean {
	const open = sidesOf(r).some(id => (f.applied(id, r.id)?.open ?? 0) > 0);
	return (!r.deleted || open) && sidesOf(r).every(id => {
		const boot = f.boot(id);
		return f.status(id) === "running" && boot !== undefined && f.syncedBoot(id) === boot
			&& f.applied(id, r.id)?.boot === boot;
	});
}

/**
 * The controller's activation bookkeeping (§5.2, §6): boots from hellos and heartbeats, syncs that deactivate first
 * (I1), applied reports, one epoch per activation, the open-gated purge, and the reconcile selections.
 */
export class EdgeActivation {
	private boots = new Map<number, string>();
	private synced = new Map<number, string>();
	private reports = new Map<string, Map<number, Applied>>();
	private states = new Map<string, EdgeState>();
	/** The readiness last published per edge, so only a change is broadcast. */
	private shown = new Map<string, string>();

	readonly facts: Facts = {
		status: id => this.deps.status(id),
		boot: id => this.boots.get(id),
		syncedBoot: id => this.synced.get(id),
		applied: (id, edgeId) => this.reports.get(edgeId)?.get(id),
	};

	constructor(private store: EdgeStore, private deps: ActivationDeps, private logger: lib.Logger) { }

	/** The controller's current state of the edge (EdgeApi.isActive). */
	isActive(id: string): boolean {
		return this.states.get(id)?.active ?? false;
	}

	/** A hello or a heartbeat: the only source of an instance's boot (§5.1). A new boot needs a new sync. */
	onRuntime(instanceId: number, boot: string): void {
		if (this.boots.get(instanceId) === boot) {
			return;
		}
		this.boots.set(instanceId, boot);
		for (const r of this.store.list({ instanceId })) {
			if (this.states.get(r.id)?.active) {
				this.deactivate(r, "new_boot");
			}
			this.publish(r);
		}
		this.syncIfStale(instanceId);
	}

	/** Clusterio's instanceStatusChanged: a stop deactivates, running may sync, a deletion tombstones (§5.2). */
	onStatus(instanceId: number, status: string): void {
		if (status === "deleted") {
			this.boots.delete(instanceId);
			this.synced.delete(instanceId);
			const tombstones = this.store.list({ instanceId }).filter(r => r.deleted);
			this.store.tombstoneInstance(instanceId, "instance_deleted")
				.catch((err: Error) => this.fail("tombstone", err));
			for (const r of tombstones) {
				this.maybePurge(r);
			}
			return;
		}
		if (status !== "running") {
			// A boot is current only while the instance runs; the next one comes from a hello or heartbeat (I1).
			this.boots.delete(instanceId);
			this.synced.delete(instanceId);
		}
		for (const r of this.store.list({ instanceId })) {
			this.evaluate(r);
		}
		if (status === "running") {
			this.syncIfStale(instanceId);
		}
	}

	/** EdgeAppliedEvent: only reports of the current boot, about edges the instance is a side of, count (§5.1). */
	onApplied(instanceId: number, event: { boot: string; sync: boolean; edges: AppliedEdge[] }): void {
		if (event.boot !== this.boots.get(instanceId)) {
			const fields = { instance_id: instanceId, boot: event.boot };
			this.logger.verbose("ue.edge applied report of an old or unknown boot ignored", fields);
			return;
		}
		const touched = new Map<string, EdgeRecord>();
		for (const e of event.edges) {
			const r = this.store.get(e.id);
			if (r && sidesOf(r).includes(instanceId)) {
				const sides = this.reports.get(r.id) ?? new Map<number, Applied>();
				sides.set(instanceId, { boot: event.boot, revision: e.revision, open: e.open });
				this.reports.set(r.id, sides);
				touched.set(r.id, r);
			}
		}
		if (event.sync) {
			this.synced.set(instanceId, event.boot);
			for (const r of this.store.list({ instanceId })) {
				touched.set(r.id, r);
			}
		}
		for (const r of touched.values()) {
			this.evaluate(r);
			this.maybePurge(r);
		}
	}

	/** The store's hook after each write (§5.1): purges, then updates, go to running sides; activation follows. */
	published(changed: EdgeRecord[], purged: EdgeRecord[]): void {
		for (const r of purged) {
			this.reports.delete(r.id);
			this.states.delete(r.id);
			this.shown.delete(r.id);
			for (const id of sidesOf(r)) {
				this.sendRunning(id, new EdgePurgedEvent(r.id));
			}
		}
		for (const r of changed) {
			for (const id of sidesOf(r)) {
				this.sendRunning(id, new EdgeUpdateEvent(r));
			}
			this.evaluate(r);
			this.maybePurge(r);
		}
	}

	/** §6.3, every 60 s: re-send lost syncs and missing updates, and re-assert every edge's state. */
	reconcile(): void {
		for (const id of this.boots.keys()) {
			this.syncIfStale(id);
		}
		for (const r of this.store.list()) {
			// M2: refresh the state before re-asserting it, so reconcile can never re-broadcast a stale one.
			this.evaluate(r);
			const st = this.states.get(r.id);
			for (const id of sidesOf(r)) {
				if (this.deps.status(id) === "running") {
					if (this.lacks(id, r)) {
						this.deps.send(id, new EdgeUpdateEvent(r));
					}
					this.deps.send(id, st?.active
						? new EdgeActivationEvent(r.id, true, st.epoch, st.trace)
						: new EdgeActivationEvent(r.id, false, undefined, st?.trace ?? newId(), st?.reason));
				}
			}
			this.maybePurge(r);
		}
	}

	/** A synced instance whose report of the edge is missing, from an old boot, or below the record's revision. */
	private lacks(instanceId: number, r: EdgeRecord): boolean {
		const boot = this.boots.get(instanceId);
		const a = this.reports.get(r.id)?.get(instanceId);
		return boot !== undefined && this.synced.get(instanceId) === boot
			&& (a === undefined || a.boot !== boot || a.revision < r.revision);
	}

	private sendRunning(instanceId: number, message: Outbound): void {
		if (this.deps.status(instanceId) === "running") {
			this.deps.send(instanceId, message);
		}
	}

	private syncIfStale(instanceId: number): void {
		const boot = this.boots.get(instanceId);
		if (boot !== undefined && this.deps.status(instanceId) === "running" && this.synced.get(instanceId) !== boot) {
			this.resync(instanceId);
		}
	}

	/** I1 (§6.1): forget the instance's sync and deactivate its edges before the sync goes out. */
	private resync(instanceId: number): void {
		this.synced.delete(instanceId);
		const edges = this.store.list({ instanceId });
		for (const r of edges) {
			if (this.states.get(r.id)?.active) {
				this.deactivate(r, "unsynced");
			}
			this.publish(r);
		}
		this.deps.send(instanceId, new EdgeSyncEvent(edges));
	}

	/** Recompute isActive; only an inactive → active transition mints an epoch (§6.1). */
	private evaluate(r: EdgeRecord): void {
		const st = this.states.get(r.id);
		const want = isActive(r, this.facts);
		if (want && !st?.active) {
			const epoch = newId();
			this.states.set(r.id, { active: true, epoch, trace: epoch, closing: r.deleted });
			lifecycle(this.logger, "ue.edge", "activated", { edge: r.id, epoch, trace: epoch });
			this.store.emit({ kind: "activation", id: r.id, active: true, epoch, reason: "ready" });
			for (const id of sidesOf(r)) {
				this.sendRunning(id, new EdgeActivationEvent(r.id, true, epoch, epoch));
			}
		} else if (!want && st?.active) {
			this.deactivate(r, this.reasonFor(r, st));
		}
		this.publish(r);
	}

	/** An edge's readiness (D13's Ready column): each side's half of isActive, and whether the edge is active. */
	readiness(r: EdgeRecord): EdgeReadiness {
		const ready = (id: number) => {
			const boot = this.boots.get(id);
			return this.deps.status(id) === "running" && boot !== undefined && this.synced.get(id) === boot
				&& this.reports.get(r.id)?.get(id)?.boot === boot;
		};
		return { id: r.id, active: this.isActive(r.id), a: ready(r.a.instanceId), b: ready(r.b.instanceId) };
	}

	/** Tell the subscribers when an edge's readiness changed; the same readiness again sends nothing. */
	private publish(r: EdgeRecord): void {
		const now = this.readiness(r);
		const key = `${now.active}/${now.a}/${now.b}`;
		if (this.shown.get(r.id) !== key) {
			this.shown.set(r.id, key);
			this.deps.readiness?.(now);
		}
	}

	private reasonFor(r: EdgeRecord, st: EdgeState): string {
		if (r.deleted) {
			return st.closing ? "closed" : "deleted";
		}
		return sidesOf(r).every(id => this.deps.status(id) === "running") ? "unsynced" : "stopped";
	}

	private deactivate(r: EdgeRecord, reason: string): void {
		const epoch = this.states.get(r.id)?.epoch ?? "";
		const trace = newId();
		this.states.set(r.id, { active: false, trace, reason, closing: false });
		lifecycle(this.logger, "ue.edge", "deactivated", { edge: r.id, epoch, reason, trace });
		this.store.emit({ kind: "activation", id: r.id, active: false, epoch, reason });
		for (const id of sidesOf(r)) {
			this.sendRunning(id, new EdgeActivationEvent(r.id, false, undefined, trace, reason));
		}
	}

	/** §5.2 step 4: purge once each side applied the tombstone with nothing open, or no longer exists. */
	private maybePurge(r: EdgeRecord): void {
		if (!r.deleted) {
			return;
		}
		const done = (id: number) => {
			if (!this.deps.exists(id)) {
				return true;
			}
			const a = this.reports.get(r.id)?.get(id);
			return a !== undefined && a.boot === this.boots.get(id) && a.revision >= r.revision && a.open === 0;
		};
		if (done(r.a.instanceId) && done(r.b.instanceId)) {
			this.store.purge(r.id).catch((err: Error) => this.fail("purge", err));
		}
	}

	private fail(what: string, err: Error): void {
		this.logger.error(`ue.edge ${what} failed: ${err.message}`);
	}
}
