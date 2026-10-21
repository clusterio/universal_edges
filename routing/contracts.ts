import { Type, type Static, type TSchema } from "@sinclair/typebox";

// SP4 routing's messages (spec §4.2). Lua → TS payloads are checked against these schemas on UE's bridge (the trust
// boundary); TS → Lua payloads are plain types, checked field by field in Lua. Every kind travels in one of the two
// relay events below as { kind, payload }: the instance is stateless (R2).

/** Factorio writes an empty Lua table as {}, not [] (SP1b Planning ruling 38): a list from Lua is either. */
export const LuaList = <T extends TSchema>(item: T) => Type.Union([
	Type.Array(item),
	Type.Object({}, { additionalProperties: false }),
]);
/** A LuaList's items: [] for {}. */
export function list<T>(v: readonly T[] | object | undefined): T[] {
	return Array.isArray(v) ? (v as T[]) : [];
}

/**
 * One train stop (D42 point 1): surface is its surface's name (R31); limit is 4294967295 when none; count includes
 * script reservations.
 */
export const Station = Type.Object({
	unit: Type.Integer(), surface: Type.String(), name: Type.String(), limit: Type.Integer(), count: Type.Integer(),
	script: Type.Integer(), priority: Type.Integer(),
});
/**
 * One train connector's congestion as this tile sees it (D42 point 5). ready: an inbound box's own readiness, or an
 * outbound box's partner's. held: a train waits at the hold signal. inflight: a crossing awaits its reply. queued:
 * carriages still to spawn.
 */
export const ConnState = Type.Object({
	key: Type.String(),
	box: Type.Union([Type.Literal("inbound"), Type.Literal("outbound")]),
	live: Type.Boolean(),
	ready: Type.Boolean(),
	held: Type.Optional(Type.Boolean()),
	inflight: Type.Optional(Type.Boolean()),
	queued: Type.Optional(Type.Integer()),
});
/**
 * ue.route.report (§7.8, §7.9): changes only, each message applied on its own, in order. full (alone, first of a full
 * report) starts the tile's table again; costs, stations and conns upsert; gone, stops_gone and conns_gone remove.
 */
export const Report = Type.Object({
	full: Type.Optional(Type.Boolean()),
	costs: Type.Optional(
		LuaList(Type.Tuple([Type.String(), Type.String(), Type.Number()])), // eslint-disable-line new-cap
	),
	gone: Type.Optional(LuaList(Type.Tuple([Type.String(), Type.String()]))), // eslint-disable-line new-cap
	stations: Type.Optional(LuaList(Station)), // eslint-disable-line new-cap
	stops_gone: Type.Optional(LuaList(Type.Integer())), // eslint-disable-line new-cap
	conns: Type.Optional(LuaList(ConnState)), // eslint-disable-line new-cap
	conns_gone: Type.Optional(LuaList(Type.String())), // eslint-disable-line new-cap
});
export const Hop = Type.Object({ edge: Type.String(), cid: Type.String() });
/**
 * At a border via is the inbound box's key; anywhere else firsts are the train's own costs, keys c:… and s:… (R23).
 * surface is the train's (R32): only stops on it count (R31).
 */
export const Request = Type.Object({
	trace: Type.String(),
	dest: Type.String(),
	surface: Type.String(),
	via: Type.Optional(Type.String()),
	firsts: Type.Optional(LuaList(Type.Tuple([Type.String(), Type.Number()]))), // eslint-disable-line new-cap
});
export const Arrived = Type.Object({ trace: Type.String() });
export const Lost = Type.Object({ trace: Type.String(), reason: Type.String() });
export const Manual = Type.Object({ trace: Type.String() });
/** I2's report (§7.4): the routes this tile carries, and the reservations it holds. */
export const Alive = Type.Object({
	active: LuaList(Type.String()), // eslint-disable-line new-cap
	reserved: LuaList(Type.String()), // eslint-disable-line new-cap
});

export type StationT = Static<typeof Station>;
export type ConnStateT = Static<typeof ConnState>;
export type ReportT = Static<typeof Report>;
export type HopT = Static<typeof Hop>;
export type RequestT = Static<typeof Request>;
export type ArrivedT = Static<typeof Arrived>;
export type LostT = Static<typeof Lost>;
export type ManualT = Static<typeof Manual>;
export type AliveT = Static<typeof Alive>;
/** Why the controller cancels a reservation (§4.2). */
export type CancelReason = "rerouted" | "failed" | "lost" | "manual" | "gc" | "orphan";
/** A station-list key: one entry per (surface, name) pair (R35). */
export type StationKey = { surface: string; name: string };
/** One station-list entry: free is -1 when some stop of the name on that surface is unlimited. */
export type StationEntry = StationKey & { tiles: string[]; free: number };
/** ue.route.stations (§7.9): upserts and removals by (surface, name); full (first part) replaces the tile's list. */
export type StationsT = { full?: boolean; set: StationEntry[]; gone: StationKey[] };

/** Instance → controller: one of the tile's Lua messages, already checked on the bridge. */
export class RouteUpEvent {
	declare ["constructor"]: typeof RouteUpEvent;
	static type = "event" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "universal_edges" as const;

	constructor(public kind: string, public payload: unknown) { }

	static jsonSchema = Type.Object({ kind: Type.String(), payload: Type.Unknown() });

	static fromJSON(json: Static<typeof RouteUpEvent.jsonSchema>) {
		return new this(json.kind, json.payload);
	}
}

/** Controller → instance: one message for the tile's Lua, sent on as it is. */
export class RouteDownEvent {
	declare ["constructor"]: typeof RouteDownEvent;
	static type = "event" as const;
	static src = "controller" as const;
	static dst = "instance" as const;
	static plugin = "universal_edges" as const;

	constructor(public kind: string, public payload: unknown) { }

	static jsonSchema = Type.Object({ kind: Type.String(), payload: Type.Unknown() });

	static fromJSON(json: Static<typeof RouteDownEvent.jsonSchema>) {
		return new this(json.kind, json.payload);
	}
}
