import { Type, type Static } from "@sinclair/typebox";
import { LuaList } from "../routing/contracts.js";

// Train group sync's messages (sync spec §6). Lua → TS payloads are checked against these schemas on UE's bridge (the
// trust boundary); a group's or an interrupt's content is opaque to TypeScript, and checked where Lua writes it. Every
// kind travels in one of the two relay events below as { kind, payload }, as routing's do: the instance keeps no state.

export const Kind = Type.Union([Type.Literal("group"), Type.Literal("interrupt")]);
/** ue.sched.report (§5.1): a tile's edit of version base, or a name the tile's cache lacks (no base). */
export const Report = Type.Object({
	kind: Kind,
	name: Type.String(),
	base: Type.Optional(Type.Integer()),
	content: Type.Unknown(),
});
/** ue.sched.counts (§5.4): how many of the tile's trains hold each name, in parts; first replaces the tile's counts. */
export const Counts = Type.Object({
	first: Type.Optional(Type.Boolean()),
	rows: LuaList(Type.Tuple([Kind, Type.String(), Type.Integer()])), // eslint-disable-line new-cap
});

export type KindT = Static<typeof Kind>;
export type ReportT = Static<typeof Report>;
export type CountsT = Static<typeof Counts>;

/** Instance → controller: one of the tile's ue.sched.* Lua messages, already checked on the bridge. */
export class SchedUpEvent {
	declare ["constructor"]: typeof SchedUpEvent;
	static type = "event" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "universal_edges" as const;

	constructor(public kind: string, public payload: unknown) { }

	static jsonSchema = Type.Object({ kind: Type.String(), payload: Type.Unknown() });

	static fromJSON(json: Static<typeof SchedUpEvent.jsonSchema>) {
		return new this(json.kind, json.payload);
	}
}

/** Controller → instance: one ue.sched.* message for the tile's Lua, sent on as it is. */
export class SchedDownEvent {
	declare ["constructor"]: typeof SchedDownEvent;
	static type = "event" as const;
	static src = "controller" as const;
	static dst = "instance" as const;
	static plugin = "universal_edges" as const;

	constructor(public kind: string, public payload: unknown) { }

	static jsonSchema = Type.Object({ kind: Type.String(), payload: Type.Unknown() });

	static fromJSON(json: Static<typeof SchedDownEvent.jsonSchema>) {
		return new this(json.kind, json.payload);
	}
}
