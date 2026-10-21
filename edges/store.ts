import { isDeepStrictEqual } from "node:util";
import * as lib from "@clusterio/lib";
import { lifecycle, newId } from "../runtime/index.js";
import {
	EdgeSpecSchema,
	type Connector, type ConnectorChange, type ConnectorResult, type EdgeEvent, type EdgeRecord, type EdgeSpec,
	type Side,
} from "./contracts.js";

/** The store file's data (SP1 spec §5.1): the global counter, and every unpurged record. */
export type StoreData = { counter: number; edges: EdgeRecord[] };

export type StoreIo = {
	/** Write data atomically (0B saveDataFile); resolves once it is on disk. */
	save(data: StoreData): Promise<void>;
	/** After each write: the final records of the edges it changed, and the tombstones it purged. */
	published(changed: EdgeRecord[], purged: EdgeRecord[]): void;
};

type Log = [op: string, phase: string, fields: Record<string, unknown>];
type Unsaved = { touched: Set<string>; purged: Map<string, EdgeRecord>; logs: Log[] };

const MAX_PARAMS_BYTES = 1024;
const validSpec = lib.compile<EdgeSpec>(EdgeSpecSchema as any);
const nothingUnsaved = (): Unsaved => ({ touched: new Set(), purged: new Map(), logs: [] });

function sideOf(s: Side): Side {
	return { instanceId: s.instanceId, surface: s.surface, origin: [s.origin[0], s.origin[1]], facing: s.facing };
}

function specProblem(spec: EdgeSpec): string | undefined {
	if (!validSpec(spec)) {
		return JSON.stringify(validSpec.errors);
	}
	if (spec.a.instanceId === spec.b.instanceId) {
		return "a and b are the same instance";
	}
	return undefined;
}

/** The connector an add asks for, or why it can't be added (§5.1). */
function newConnector(r: EdgeRecord, change: ConnectorChange): Omit<Connector, "cid"> | string {
	const { type, pos, width = 1, params = {} } = change;
	if (type === undefined || type === "" || pos === undefined) {
		return "invalid";
	}
	if (pos < 0 || width < 1 || pos + width > r.length) {
		return "out_of_bounds";
	}
	if (Buffer.byteLength(JSON.stringify(params)) > MAX_PARAMS_BYTES) {
		return "params_too_large";
	}
	// Any column overlap is refused, whatever the params. Permanent, not a placeholder: owner-review D25 (Spike 5)
	// found that in a parallel stack, the rail built later wins, so this can never become layer-aware. FC1
	// (circuit-link spec C1 a): one pole carries a power and a circuit connector, at the same pos and width.
	const overlaps = r.connectors.filter(o => pos < o.pos + o.width && o.pos < pos + width);
	const pole = (o: Connector) => o.pos === pos && o.width === width
		&& [o.type, type].sort().join() === "circuit,power";
	if (overlaps.length > 1 || (overlaps.length === 1 && !pole(overlaps[0]))) {
		return "overlap";
	}
	return { type, pos, width, params };
}

/**
 * The controller's edge records (SP1 spec §5.1, §5.2): one global counter, tombstones and purge, and persist before
 * send (I2). Changes wait in memory until they are written; readers, listeners and messages see only written ones.
 */
export class EdgeStore {
	private counter: number;
	/** Every change, written or not: what new operations are checked against. */
	private records: Map<string, EdgeRecord>;
	/** The records of the last successful write: all that get, list, listeners and messages ever see. */
	private persisted: Map<string, EdgeRecord>;
	private unsaved = nothingUnsaved();
	private listeners = new Set<(event: EdgeEvent) => void>();
	private turn?: Promise<void>;
	private chain: Promise<void> = Promise.resolve();

	constructor(data: StoreData | undefined, private io: StoreIo, private logger: lib.Logger) {
		this.counter = data?.counter ?? 0;
		this.records = new Map((data?.edges ?? []).map(r => [r.id, r]));
		this.persisted = new Map(this.records);
	}

	/** A written record, tombstones included. A copy: mutating it never reaches the store (M11). */
	get(id: string): EdgeRecord | undefined {
		const r = this.persisted.get(id);
		return r && structuredClone(r);
	}

	/** Written records, tombstones included; filtered by owner, or by an instance on either side. Copies (M11). */
	list(filter: { owner?: string; instanceId?: number } = {}): EdgeRecord[] {
		const { owner, instanceId } = filter;
		return [...this.persisted.values()].filter(r => (owner === undefined || r.owner === owner)
			&& (instanceId === undefined || r.a.instanceId === instanceId || r.b.instanceId === instanceId))
			.map(r => structuredClone(r));
	}

	/** Listen to changes, activations and purges; returns the unsubscribe (§7.1). */
	on(listener: (event: EdgeEvent) => void): () => void {
		this.listeners.add(listener);
		return () => {
			this.listeners.delete(listener);
		};
	}

	/** Tell every listener; one that throws is logged, and the others still hear the event (§7.1). */
	emit(event: EdgeEvent): void {
		for (const listener of this.listeners) {
			try {
				listener(event);
			} catch (err: any) {
				this.logger.error(`an edge listener failed:\n${err.stack ?? err.message}`);
			}
		}
	}

	/** Create the edge, or return an identical live one; resolves once it is written (§5.1). */
	ensure(spec: EdgeSpec): Promise<EdgeRecord> {
		const problem = specProblem(spec);
		if (problem !== undefined) {
			return Promise.reject(new lib.RequestError(`invalid edge spec: ${problem}`, "EdgeInvalid"));
		}
		const wanted = { id: spec.id, owner: spec.owner, length: spec.length, a: sideOf(spec.a), b: sideOf(spec.b) };
		const existing = this.records.get(spec.id);
		if (existing?.deleted) {
			const message = `edge ${spec.id} is being deleted; ensure it again once it is purged`;
			return Promise.reject(new lib.RequestError(message, "EdgeDeleting"));
		}
		if (existing) {
			const { id, owner, length, a, b } = existing;
			if (!isDeepStrictEqual({ id, owner, length, a, b }, wanted)) {
				const message = `edge ${spec.id} exists with another spec`;
				return Promise.reject(new lib.RequestError(message, "EdgeConflict"));
			}
		} else {
			const record = this.commit({ ...wanted, deleted: false, connectors: [] }, newId());
			this.log("ue.edge", "ensured", {
				edge: record.id, revision: record.revision, owner: record.owner, trace: record.trace,
			});
		}
		// I1: a copy of what was written, not the object `records`/`persisted` hold — the caller may mutate it (this
		// also fixes the identical-edge branch above, which used to hand back a stale pre-write snapshot).
		return this.written().then(() => this.get(spec.id)!);
	}

	/** Tombstone the edge (§5.2 step 1). Absent or already deleted is a no-op; only its owner may. */
	remove(id: string, owner: string, reason = "removed"): Promise<void> {
		const r = this.records.get(id);
		if (r && !r.deleted) {
			if (r.owner !== owner) {
				const message = `edge ${id} is owned by ${r.owner}, not ${owner}`;
				return Promise.reject(new lib.RequestError(message, "EdgeOwner"));
			}
			this.tombstone(r, reason);
		}
		return this.written();
	}

	/** Tombstone every live edge the instance is a side of (§5.2 step 5): deleted, or missing at start. */
	tombstoneInstance(instanceId: number, reason: "instance_deleted" | "instance_missing"): Promise<void> {
		for (const r of this.records.values()) {
			if (!r.deleted && (r.a.instanceId === instanceId || r.b.instanceId === instanceId)) {
				this.tombstone(r, reason);
			}
		}
		return this.written();
	}

	/** Drop a tombstone that both sides are done with (§5.2 step 4); its id may then be re-created. */
	purge(id: string): Promise<void> {
		const r = this.records.get(id);
		if (r?.deleted) {
			this.records.delete(id);
			this.unsaved.purged.set(id, r);
			const { revision, owner, reason, trace } = r;
			this.log("ue.edge", "purged", { edge: id, revision, owner, reason, trace });
		}
		return this.written();
	}

	/** Add or remove a connector (§5.1). requester is the asking instance, undefined for a control connection. */
	connector(change: ConnectorChange, requester?: number): Promise<ConnectorResult> {
		const r = this.target(change.edge, requester);
		if (typeof r === "string") {
			return this.rejected(change, r);
		}
		const { edge, trace } = change;
		if (change.op === "remove") {
			const removed = r.connectors.find(c => c.cid === change.cid);
			if (!removed) {
				return this.rejected(change, "unknown_connector");
			}
			this.commit({ ...r, connectors: r.connectors.filter(c => c.cid !== change.cid) }, trace);
			// M7: type and pos, matching "added" (below), so a removal's log line says what was removed.
			this.log("ue.connector", "removed", { edge, cid: change.cid, type: removed.type, pos: removed.pos, trace });
			return this.written().then(() => ({ ok: true }));
		}
		const added = newConnector(r, change);
		if (typeof added === "string") {
			return this.rejected(change, added);
		}
		const cid = `c${this.counter + 1}`;
		this.commit({ ...r, connectors: [...r.connectors, { cid, ...added }] }, trace);
		this.log("ue.connector", "added", { edge, cid, type: added.type, pos: added.pos, trace });
		return this.written().then(() => ({ ok: true, cid }));
	}

	/** The live edge a connector change may touch, or why not. */
	private target(edge: string, requester?: number): EdgeRecord | string {
		const r = this.records.get(edge);
		if (!r) {
			return "unknown_edge";
		}
		if (r.deleted) {
			return "deleted";
		}
		if (requester !== undefined && requester !== r.a.instanceId && requester !== r.b.instanceId) {
			return "not_a_side";
		}
		return r;
	}

	private rejected(change: ConnectorChange, reason: string): Promise<ConnectorResult> {
		const { edge, type, pos, cid, trace } = change;
		lifecycle(this.logger, "ue.connector", "rejected", { edge, type, pos, cid, reason, trace });
		return Promise.resolve({ ok: false, reason });
	}

	private tombstone(r: EdgeRecord, reason: string): void {
		const t = this.commit({ ...r, deleted: true, reason }, newId());
		this.log("ue.edge", "deleted", { edge: t.id, revision: t.revision, owner: t.owner, reason, trace: t.trace });
	}

	/** One change of one edge takes the next value of the global counter (§5.1). */
	private commit(fields: Omit<EdgeRecord, "revision" | "trace" | "updatedAtMs">, trace: string): EdgeRecord {
		this.counter += 1;
		const record: EdgeRecord = { ...fields, revision: this.counter, trace, updatedAtMs: Date.now() };
		this.records.set(record.id, record);
		this.unsaved.touched.add(record.id);
		return record;
	}

	private log(op: string, phase: string, fields: Record<string, unknown>): void {
		this.unsaved.logs.push([op, phase, fields]);
	}

	/**
	 * Resolves once everything changed so far is written and published. The calls of one event-loop turn share one
	 * write (§5.1), writes run one after another, and a turn with nothing unsaved writes nothing.
	 */
	private written(): Promise<void> {
		if (!this.turn) {
			this.turn = new Promise<void>(resolve => {
				setImmediate(resolve);
			}).then(() => {
				this.turn = undefined;
				const write = this.chain.then(() => this.write());
				this.chain = write.catch(() => undefined);
				return write;
			});
		}
		return this.turn;
	}

	private async write(): Promise<void> {
		const work = this.unsaved;
		if (work.touched.size === 0 && work.purged.size === 0) {
			return;
		}
		this.unsaved = nothingUnsaved();
		const data: StoreData = { counter: this.counter, edges: [...this.records.values()] };
		try {
			await this.io.save(data);
		} catch (err: any) {
			// Not written, so nothing of it may be read, heard or sent (I2): the next write carries it again.
			for (const id of this.unsaved.touched) {
				work.touched.add(id);
			}
			for (const [id, r] of this.unsaved.purged) {
				work.purged.set(id, r);
			}
			work.logs.push(...this.unsaved.logs);
			this.unsaved = work;
			this.logger.error(`ue.edge store write failed: ${err.message}`);
			throw err;
		}
		this.persisted = new Map(data.edges.map(r => [r.id, r]));
		for (const [op, phase, fields] of work.logs) {
			lifecycle(this.logger, op, phase, fields);
		}
		for (const id of work.purged.keys()) {
			this.emit({ kind: "purged", id });
		}
		// I1: a copy (the same helper `get` uses), so a listener mutating its edge never reaches the store.
		const changed = [...work.touched].flatMap(id => this.get(id) ?? []);
		for (const edge of changed) {
			this.emit({ kind: "changed", edge });
		}
		try {
			this.io.published(changed, [...work.purged.values()]);
		} catch (err: any) {
			this.logger.error(`ue.edge publishing failed:\n${err.stack ?? err.message}`);
		}
	}
}
