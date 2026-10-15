// The in-process edge API for other controller plugins (SP1 spec §7.1), imported from "universal_edges/edges".
import type { EdgeEvent, EdgeRecord, EdgeSpec } from "./contracts.js";

export type { Connector, EdgeEvent, EdgeRecord, EdgeSpec, Side } from "./contracts.js";

/**
 * M3: a rejected `ensure`/`remove` (a disk error, not a validation refusal) doesn't discard the change — it is
 * carried into whatever write happens next, from any caller, including one the reconcile loop's own purges
 * trigger, and only publishes then. Until it lands, `get`/`list` and the persisted `universal_edges_edges.json`
 * can still disagree with what the rejected call asked for.
 */
export interface EdgeApi {
	/** Resolves once the record is written; rejects with code EdgeConflict, EdgeDeleting or EdgeInvalid. */
	ensure(spec: EdgeSpec): Promise<EdgeRecord>;
	/** Tombstones the edge; a no-op when it is absent or already deleted; rejects with code EdgeOwner. */
	remove(id: string, owner: string): Promise<void>;
	/** A written record, tombstones included (deleted: true). A copy; mutating it has no effect (M11). */
	get(id: string): EdgeRecord | undefined;
	/** Copies (M11). */
	list(filter?: { owner?: string; instanceId?: number }): EdgeRecord[];
	isActive(id: string): boolean;
	/** Runs after each change is written and before any message about it; returns the unsubscribe. */
	on(listener: (event: EdgeEvent) => void): () => void;
}

let current: EdgeApi | undefined;

/**
 * The edge API. Clusterio keeps no plugin registry, so this is a module singleton that UE's controller plugin sets
 * as it loads: call edgeApi() from a hook, never at import time.
 */
export function edgeApi(): EdgeApi {
	if (!current) {
		throw new Error("universal_edges: the edge API is not ready; call edgeApi() from a hook, not at import time");
	}
	return current;
}

export function setEdgeApi(api: EdgeApi): void {
	current = api;
}

/** The player-crossing spec's controller hook (§7.2): the instance a zone key leads to, or why there is none. */
export type CrossingResolver = (from: number, key: string, surface: string) => number | string;

const resolvers = new Map<string, CrossingResolver>();

/** Another controller plugin resolves the zone keys its Lua hook gives (`<prefix>:…`). Call from its load. */
export function registerCrossingResolver(prefix: string, resolve: CrossingResolver): void {
	resolvers.set(prefix, resolve);
}

export function crossingResolver(prefix: string): CrossingResolver | undefined {
	return resolvers.get(prefix);
}
