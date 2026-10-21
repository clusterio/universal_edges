import * as lib from "@clusterio/lib";
import { Type, type Static } from "@sinclair/typebox";

// The edge contracts of SP1 spec §5.1 and §6.1, declared once: record shapes, Clusterio messages, and the payloads
// Lua sends on the bridge. Clusterio checks each message against its jsonSchema when it arrives.

const Facing = Type.Union([Type.Literal(0), Type.Literal(4), Type.Literal(8), Type.Literal(12)]);

/** One side: its instance and surface, a tile corner, and its outward normal as a Factorio direction (§8). */
export const SideSchema = Type.Object({
	instanceId: Type.Integer(),
	surface: Type.String(),
	origin: Type.Tuple([Type.Integer(), Type.Integer()]),
	facing: Facing,
});
export type Side = Static<typeof SideSchema>;

/** What an owner asks for. a, b and length never change once the edge exists (D7). */
export const EdgeSpecSchema = Type.Object({
	// Printable ASCII only (0x21-0x7e), narrower than §5.1's letter ("no whitespace or control characters"):
	// this makes every character exactly one byte, so TypeScript's maxLength (UTF-16 units) and Lua's #
	// (bytes, edge_core.lua's `#rec.id > 128`) always agree. A wider charset could pass here and still be
	// rejected in Lua for a multi-byte id under 128 UTF-16 units but over 128 bytes (M5, plan review).
	id: Type.String({ minLength: 1, maxLength: 128, pattern: "^[\\x21-\\x7e]+$" }),
	owner: Type.String({ minLength: 1 }),
	length: Type.Integer({ minimum: 1, maximum: 100000 }),
	a: SideSchema,
	b: SideSchema,
});
export type EdgeSpec = Static<typeof EdgeSpecSchema>;

/**
 * A connector: canonical columns [pos, pos + width) in side a's frame (§8), and its type's params (at most 1 KB).
 * A transport's own facts live in params; an SP3 train's rail layer is params.layer (D18).
 */
export const ConnectorSchema = Type.Object({
	cid: Type.String(),
	type: Type.String(),
	pos: Type.Integer(),
	width: Type.Integer(),
	params: Type.Record(Type.String(), Type.Unknown()),
});
export type Connector = Static<typeof ConnectorSchema>;

/** The controller's record (§5.1): revision is the global counter's value of the edge's latest change. */
export const EdgeRecordSchema = Type.Object({
	...EdgeSpecSchema.properties,
	revision: Type.Integer(),
	deleted: Type.Boolean(),
	reason: Type.Optional(Type.String()),
	connectors: Type.Array(ConnectorSchema),
	trace: Type.String(),
	updatedAtMs: Type.Number(),
});
export type EdgeRecord = Static<typeof EdgeRecordSchema>;

/** What a side holds of one edge: its revision, and how many of its closing lanes are open (0 until SP1b). */
export const AppliedEdgeSchema = Type.Object({
	id: Type.String(),
	revision: Type.Integer(),
	open: Type.Integer({ minimum: 0 }),
});
export type AppliedEdge = Static<typeof AppliedEdgeSchema>;

/** A connector change (§6.1): add needs type and pos (width defaults to 1, params to {}); remove needs cid. */
export const ConnectorChangeSchema = Type.Object({
	edge: Type.String(),
	op: Type.Union([Type.Literal("add"), Type.Literal("remove")]),
	type: Type.Optional(Type.String()),
	pos: Type.Optional(Type.Integer()),
	width: Type.Optional(Type.Integer()),
	params: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
	cid: Type.Optional(Type.String()),
	trace: Type.String(),
});
export type ConnectorChange = Static<typeof ConnectorChangeSchema>;

export const ConnectorResultSchema = Type.Object({
	ok: Type.Boolean(),
	cid: Type.Optional(Type.String()),
	reason: Type.Optional(Type.String()),
});
export type ConnectorResult = Static<typeof ConnectorResultSchema>;

/** The in-process API's events (§7.1). An activation's epoch is the one that began or ended. */
export type EdgeEvent =
	| { kind: "changed"; edge: EdgeRecord }
	| { kind: "activation"; id: string; active: boolean; epoch: string; reason: string }
	| { kind: "purged"; id: string };

/** Lua → TS: one edge applied (§6.2), with the change's trace for the log line. */
export const AppliedPayload = Type.Object({
	id: Type.String(),
	revision: Type.Integer(),
	open: Type.Integer({ minimum: 0 }),
	sync: Type.Boolean(),
	trace: Type.String(),
});

/** Lua → TS: a sync's reports are complete; n is how many records the sync held. */
export const SyncedPayload = Type.Object({ n: Type.Integer({ minimum: 0 }) });

/** Controller → instance: every unpurged edge the instance is a side of, tombstones included. Authoritative. */
export class EdgeSyncEvent {
	declare ["constructor"]: typeof EdgeSyncEvent;
	static type = "event" as const;
	static src = "controller" as const;
	static dst = "instance" as const;
	static plugin = "universal_edges" as const;

	constructor(public edges: EdgeRecord[]) { }

	static jsonSchema = Type.Object({ edges: Type.Array(EdgeRecordSchema) });

	static fromJSON(json: Static<typeof EdgeSyncEvent.jsonSchema>) {
		return new this(json.edges);
	}
}

/** Controller → instance: one edge's whole record, live or tombstone, once its change is written. */
export class EdgeUpdateEvent {
	declare ["constructor"]: typeof EdgeUpdateEvent;
	static type = "event" as const;
	static src = "controller" as const;
	static dst = "instance" as const;
	static plugin = "universal_edges" as const;

	constructor(public edge: EdgeRecord) { }

	static jsonSchema = Type.Object({ edge: EdgeRecordSchema });

	static fromJSON(json: Static<typeof EdgeUpdateEvent.jsonSchema>) {
		return new this(json.edge);
	}
}

/** Controller → instance: active under epoch, or inactive for reason; trace ties the three log lines together. */
export class EdgeActivationEvent {
	declare ["constructor"]: typeof EdgeActivationEvent;
	static type = "event" as const;
	static src = "controller" as const;
	static dst = "instance" as const;
	static plugin = "universal_edges" as const;

	constructor(
		public id: string,
		public active: boolean,
		public epoch: string | undefined,
		public trace: string,
		public reason?: string,
	) { }

	static jsonSchema = Type.Object({
		id: Type.String(),
		active: Type.Boolean(),
		epoch: Type.Optional(Type.String()),
		trace: Type.String(),
		reason: Type.Optional(Type.String()),
	});

	static fromJSON(json: Static<typeof EdgeActivationEvent.jsonSchema>) {
		return new this(json.id, json.active, json.epoch, json.trace, json.reason);
	}
}

/** Controller → instance: the tombstone is purged, so the side's shell goes too. */
export class EdgePurgedEvent {
	declare ["constructor"]: typeof EdgePurgedEvent;
	static type = "event" as const;
	static src = "controller" as const;
	static dst = "instance" as const;
	static plugin = "universal_edges" as const;

	constructor(public id: string) { }

	static jsonSchema = Type.Object({ id: Type.String() });

	static fromJSON(json: Static<typeof EdgePurgedEvent.jsonSchema>) {
		return new this(json.id);
	}
}

/** Instance → controller: Lua's applied reports, stamped with the boot id of the run that made them. */
export class EdgeAppliedEvent {
	declare ["constructor"]: typeof EdgeAppliedEvent;
	static type = "event" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "universal_edges" as const;

	constructor(
		public boot: string,
		public sync: boolean,
		public edges: AppliedEdge[],
	) { }

	static jsonSchema = Type.Object({
		boot: Type.String(),
		sync: Type.Boolean(),
		edges: Type.Array(AppliedEdgeSchema),
	});

	static fromJSON(json: Static<typeof EdgeAppliedEvent.jsonSchema>) {
		return new this(json.boot, json.sync, json.edges);
	}
}

/** Instance or control → controller: add or remove a connector; an instance only on an edge it is a side of. */
export class ConnectorChangeRequest {
	declare ["constructor"]: typeof ConnectorChangeRequest;
	static type = "request" as const;
	static src = ["instance", "control"] as const;
	static dst = "controller" as const;
	static plugin = "universal_edges" as const;
	static permission = "universal_edges.edges.write" as const;

	constructor(public change: ConnectorChange) { }

	static jsonSchema = Type.Object({ change: ConnectorChangeSchema });

	static fromJSON(json: Static<typeof ConnectorChangeRequest.jsonSchema>) {
		return new this(json.change);
	}

	static Response = lib.plainJson(ConnectorResultSchema);
}

/** Control → controller: ensure an edge; the reply is its record, once written. */
export class EdgeEnsureRequest {
	declare ["constructor"]: typeof EdgeEnsureRequest;
	static type = "request" as const;
	static src = "control" as const;
	static dst = "controller" as const;
	static plugin = "universal_edges" as const;
	static permission = "universal_edges.edges.write" as const;

	constructor(public edge: EdgeSpec) { }

	static jsonSchema = Type.Object({ edge: EdgeSpecSchema });

	static fromJSON(json: Static<typeof EdgeEnsureRequest.jsonSchema>) {
		return new this(json.edge);
	}

	static Response = lib.plainJson(Type.Object({ edge: EdgeRecordSchema }));
}

/** Control → controller: tombstone an edge; only its owner may. */
export class EdgeRemoveRequest {
	declare ["constructor"]: typeof EdgeRemoveRequest;
	static type = "request" as const;
	static src = "control" as const;
	static dst = "controller" as const;
	static plugin = "universal_edges" as const;
	static permission = "universal_edges.edges.write" as const;

	constructor(
		public id: string,
		public owner: string,
	) { }

	static jsonSchema = Type.Object({ id: Type.String(), owner: Type.String() });

	static fromJSON(json: Static<typeof EdgeRemoveRequest.jsonSchema>) {
		return new this(json.id, json.owner);
	}
}

/** Control → controller: every written record, tombstones included. */
export class EdgeListRequest {
	declare ["constructor"]: typeof EdgeListRequest;
	static type = "request" as const;
	static src = "control" as const;
	static dst = "controller" as const;
	static plugin = "universal_edges" as const;
	static permission = "universal_edges.edges.read" as const;
	static Response = lib.plainJson(Type.Object({ edges: Type.Array(EdgeRecordSchema) }));
}

/** A lane message's kind and trace (SP1 spec §11.2); the rest is per kind, and Lua re-checks every field (G5). */
export const LaneMsgSchema = Type.Object({
	k: Type.String({ minLength: 1, maxLength: 16 }),
	trace: Type.Optional(Type.String({ maxLength: 64 })),
});
/** Every field a lane message may carry; its kind decides which it has. */
export type LaneMsg = Static<typeof LaneMsgSchema> & Record<string, unknown>;

/** Lua → TS: one lane message for the partner, stamped with its edge and the side's epoch. */
export const LaneOutPayload = Type.Object({
	edge: Type.String({ minLength: 1, maxLength: 128 }),
	epoch: Type.String({ minLength: 1, maxLength: 64 }),
	k: Type.String({ minLength: 1, maxLength: 16 }),
	trace: Type.Optional(Type.String({ maxLength: 64 })),
});

/**
 * Lua → TS: part i of n of a body over 3000 bytes: a unique offer's, or a big status's (FC3, circuit-link spec §5.2);
 * key is edge/cid/<dir or k>/seq (§11.2). Up to 64 parts (circuit-link fix 4): a status of up to 180,000 bytes is 60.
 */
export const ChunkPayload = Type.Object({
	key: Type.String({ minLength: 1, maxLength: 256 }),
	i: Type.Integer({ minimum: 1 }),
	n: Type.Integer({ minimum: 1, maximum: 64 }),
	data: Type.String({ maxLength: 3000 }),
});

/** Lua → TS: ep:request_removal (§10.2), sent on as a ConnectorChangeRequest. */
export const RemovalPayload = Type.Object({
	edge: Type.String({ minLength: 1, maxLength: 128 }),
	cid: Type.String({ minLength: 1 }),
	reason: Type.String(),
	trace: Type.String({ maxLength: 64 }),
});

/** Lua → TS: a player's build in a border row proposes a connector (SP3 §6.2), sent on as a ConnectorChangeRequest. */
export const ProposalPayload = Type.Object({
	edge: Type.String({ minLength: 1, maxLength: 128 }),
	type: Type.String({ minLength: 1 }),
	pos: Type.Integer({ minimum: 0 }),
	width: Type.Integer({ minimum: 1 }),
	params: Type.Record(Type.String(), Type.Unknown()),
	trace: Type.String({ maxLength: 64 }),
});

/**
 * Instance → partner instance, direct (D6): one event-loop turn's lane messages of one edge and epoch. Clusterio
 * checks the schema at the receiver, which caps every trace at 64 characters (0B carry M3).
 */
export class LaneBatchEvent {
	declare ["constructor"]: typeof LaneBatchEvent;
	static type = "event" as const;
	static src = "instance" as const;
	static dst = "instance" as const;
	static plugin = "universal_edges" as const;

	constructor(
		public edge: string,
		public epoch: string,
		public msgs: LaneMsg[],
	) { }

	static jsonSchema = Type.Object({
		edge: Type.String({ minLength: 1, maxLength: 128 }),
		epoch: Type.String({ minLength: 1, maxLength: 64 }),
		msgs: Type.Array(LaneMsgSchema, { minItems: 1, maxItems: 1000 }),
	});

	static fromJSON(json: Static<typeof LaneBatchEvent.jsonSchema>) {
		return new this(json.edge, json.epoch, json.msgs as LaneMsg[]);
	}
}

/** Each side's readiness and the edge's activation: the web page's Ready column (D13, owner 2026-09-29). */
export const EdgeReadinessSchema = Type.Object({
	id: Type.String(),
	active: Type.Boolean(),
	a: Type.Boolean(),
	b: Type.Boolean(),
});
export type EdgeReadiness = Static<typeof EdgeReadinessSchema>;

/**
 * Controller → control, by subscription (§7.2): records written after the subscriber's lastRequestTimeMs, the ids of
 * purged tombstones (SP1a final review M2), and changed readiness (D13).
 */
export class EdgeChangedEvent {
	declare ["constructor"]: typeof EdgeChangedEvent;
	static type = "event" as const;
	static src = "controller" as const;
	static dst = "control" as const;
	static plugin = "universal_edges" as const;
	static permission = "universal_edges.edges.read" as const;

	constructor(
		public edges: EdgeRecord[],
		public purged: string[] = [],
		public readiness: EdgeReadiness[] = [],
	) { }

	static jsonSchema = Type.Object({
		edges: Type.Array(EdgeRecordSchema),
		purged: Type.Optional(Type.Array(Type.String())),
		readiness: Type.Optional(Type.Array(EdgeReadinessSchema)),
	});

	static fromJSON(json: Static<typeof EdgeChangedEvent.jsonSchema>) {
		return new this(json.edges, json.purged ?? [], json.readiness ?? []);
	}
}

// Players crossing (player-crossing spec §4–§6): the zone keys a crossing tries in order, a leave point, and the join
// that fetches the arrival. The impure side (destination, target, playerForwarding) lives in edges/players.ts.

const Name = Type.String({ minLength: 1, maxLength: 64 });
const Surface = Type.String({ minLength: 1, maxLength: 200 });
const Trace = Type.String({ maxLength: 64 });

/** Lua → TS (§4 step 1), and the request's body: the zone's key, then the edge's as a fallback when a hook won. */
export const PlayerCrossPayload = Type.Object({
	player: Name,
	keys: Type.Array(Type.String({ minLength: 1, maxLength: 160 }), { minItems: 1, maxItems: 2 }),
	surface: Surface,
	x: Type.Number(),
	y: Type.Number(),
	trace: Trace,
});
/** Lua → TS (§4 step 5), and the event's body: where the player left, in the source's world. */
export const PlayerLeftPayload = Type.Object({
	player: Name, surface: Surface, x: Type.Number(), y: Type.Number(), trace: Trace,
});
/** Lua → TS (§6.1). */
export const PlayerJoinedPayload = Type.Object({ player: Name });

export const PlayerTargetSchema = Type.Object({
	ok: Type.Boolean(),
	address: Type.Optional(Type.String()),
	name: Type.Optional(Type.String()),
	reason: Type.Optional(Type.String()),
	/** The destination's instance id, for player_sync's set_destination (prefetch spec §9) */
	instanceId: Type.Optional(Type.Integer()),
});
export type PlayerTarget = Static<typeof PlayerTargetSchema>;

export const ArrivalSchema = Type.Object({
	key: Type.String(),
	x: Type.Number(),
	y: Type.Number(),
	surface: Type.String(),
	trace: Type.String(),
	left: Type.Optional(Type.Object({ x: Type.Number(), y: Type.Number(), surface: Type.String() })),
});

/** Instance → controller (§4 step 2): where a crossing player should go; the controller records it. */
export class PlayerCrossRequest {
	declare ["constructor"]: typeof PlayerCrossRequest;
	static type = "request" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "universal_edges" as const;

	constructor(
		public player: string,
		public keys: string[],
		public surface: string,
		public x: number,
		public y: number,
		public trace: string,
	) { }

	static jsonSchema = PlayerCrossPayload;

	static fromJSON(json: Static<typeof PlayerCrossRequest.jsonSchema>) {
		return new this(json.player, json.keys, json.surface, json.x, json.y, json.trace);
	}

	static Response = lib.plainJson(PlayerTargetSchema);
}

/** Instance → controller (§4 step 5): a player left while in a zone. */
export class PlayerLeftEvent {
	declare ["constructor"]: typeof PlayerLeftEvent;
	static type = "event" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "universal_edges" as const;

	constructor(
		public player: string,
		public surface: string,
		public x: number,
		public y: number,
		public trace: string,
	) { }

	static jsonSchema = PlayerLeftPayload;

	static fromJSON(json: Static<typeof PlayerLeftEvent.jsonSchema>) {
		return new this(json.player, json.surface, json.x, json.y, json.trace);
	}
}

/** Instance → controller (§5, §6.1): a player joined; their arrival here, if any. The record goes either way. */
export class PlayerJoinRequest {
	declare ["constructor"]: typeof PlayerJoinRequest;
	static type = "request" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "universal_edges" as const;

	constructor(public player: string) { }

	static jsonSchema = PlayerJoinedPayload;

	static fromJSON(json: Static<typeof PlayerJoinRequest.jsonSchema>) {
		return new this(json.player);
	}

	static Response = lib.plainJson(Type.Object({ arrival: Type.Union([ArrivalSchema, Type.Null()]) }));
}
