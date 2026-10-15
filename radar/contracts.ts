import { Type, type Static } from "@sinclair/typebox";

// The radar sync's messages (radar-sync spec §5; plan ruling 7). Lua → TS payloads are checked against these schemas
// on UE's bridge (the trust boundary); TS → Lua payloads are plain, and Lua checks each signal in circuit_core's fold.
// Every kind travels in one of the two relay events below as { kind, payload }.

/** The circuit link's encoding (circuit §8.2): { [type, or "type|quality"]: [name, count, …] }. */
const Signals = Type.Record(Type.String(), Type.Array(Type.Union([Type.String(), Type.Integer()])));
const Key = Type.String({ minLength: 1, maxLength: 256 });

/** ue.radar.own: a host's own signals, a change on base or (no base) the full form (§5). */
export const Own = Type.Object({
	key: Key,
	v: Type.Integer(),
	base: Type.Optional(Type.Integer()),
	r: Type.Optional(Signals),
	g: Type.Optional(Signals),
});
/** ue.radar.own over 3000 bytes: its body came first, in ue.radar.chunk parts keyed <key>/<seq> (plan ruling 12). */
export const OwnParts = Type.Object({
	key: Key,
	chunks: Type.Integer({ minimum: 1, maximum: 64 }),
	seq: Type.Integer(),
});
export const OwnIn = Type.Union([Own, OwnParts]);
/** ue.radar.ask and ue.radar.unhost. */
export const KeyOnly = Type.Object({ key: Key });

export type OwnT = Static<typeof Own>;

/** Instance → controller: one of the tile's radar messages, already checked on the bridge. */
export class RadarUpEvent {
	declare ["constructor"]: typeof RadarUpEvent;
	static type = "event" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "universal_edges" as const;

	constructor(public kind: string, public payload: unknown) { }

	static jsonSchema = Type.Object({ kind: Type.String(), payload: Type.Unknown() });

	static fromJSON(json: Static<typeof RadarUpEvent.jsonSchema>) {
		return new this(json.kind, json.payload);
	}
}

/** Controller → instance: one message for the tile's Lua, sent on as it is. */
export class RadarDownEvent {
	declare ["constructor"]: typeof RadarDownEvent;
	static type = "event" as const;
	static src = "controller" as const;
	static dst = "instance" as const;
	static plugin = "universal_edges" as const;

	constructor(public kind: string, public payload: unknown) { }

	static jsonSchema = Type.Object({ kind: Type.String(), payload: Type.Unknown() });

	static fromJSON(json: Static<typeof RadarDownEvent.jsonSchema>) {
		return new this(json.kind, json.payload);
	}
}
