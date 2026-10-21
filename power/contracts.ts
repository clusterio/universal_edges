import { Type, type Static } from "@sinclair/typebox";

// The power hub's messages (power hub spec §6.1, §6.2). ue.power.report is checked against Report on UE's bridge (the
// trust boundary) and again as PowerUpEvent's schema. The targets are the hub's own, plain for Lua.

const Key = Type.String({ minLength: 1, maxLength: 256 });
const Kw = Type.Integer({ minimum: 0 });
const Kj = Type.Integer({ minimum: 0 });

/**
 * One linked network (§6.1): a, its pool's energy less what its links owe (kJ; negative when a relay owes more than it
 * holds); c, its capacity (kJ); f, the six samples' means less UE's own interfaces (kW); l, each ready link's
 * [key, sent kJ, got kJ]. A network with no ready link isn't reported, so l is never empty (Lua's {}).
 */
export const Net = Type.Object({
	a: Type.Integer(),
	c: Kj,
	f: Type.Object({ so: Kw, po: Kw, se: Kw, to: Kw, pd: Kw, sd: Kw, td: Kw }),
	l: Type.Array(Type.Tuple([Key, Kj, Kj]), { minItems: 1 }),
});
/**
 * ue.power.report: a tile with no linked network sends nothing, so nets is never empty. No item cap (Review Focus 4).
 */
export const Report = Type.Object({ nets: Type.Array(Net, { minItems: 1 }) });

/** ue.power.report over 2000 bytes: its body came first, in ue.power.chunk parts keyed power/<seq> (as OwnParts). */
export const ReportParts = Type.Object({
	chunks: Type.Integer({ minimum: 1 }),
	seq: Type.Integer({ minimum: 0 }),
});
export const ReportIn = Type.Union([Report, ReportParts]);

export const MODES = [
	"solar_output", "primary_output", "secondary_output", "tertiary_output", "secondary_input",
] as const;
/**
 * One link's target (§6.2): n, what this side sends each poll while the target is fresh (kJ, a rate: plan review B1),
 * and the buffer b (kJ); the mode m and cap k (kW) its interface takes.
 */
export const Target = Type.Object({
	n: Kj,
	b: Kj,
	m: Type.Optional(Type.Union(MODES.map(m => Type.Literal(m)))),
	k: Type.Number({ minimum: 0 }),
});
/** ue.power.targets: every key the tile reported. */
export const Targets = Type.Object({ l: Type.Record(Type.String(), Target) });

export type NetT = Static<typeof Net>;
export type ReportT = Static<typeof Report>;
export type TargetT = Static<typeof Target>;
export type TargetsT = Static<typeof Targets>;

/** Instance → controller: a tile's ue.power.report, already checked on the bridge. */
export class PowerUpEvent {
	declare ["constructor"]: typeof PowerUpEvent;
	static type = "event" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "universal_edges" as const;

	constructor(public report: ReportT) { }

	static jsonSchema = Type.Object({ report: Report });

	static fromJSON(json: Static<typeof PowerUpEvent.jsonSchema>) {
		return new this(json.report);
	}
}

/** Controller → instance: the hub's targets for the tile's links, sent on to Lua as ue.power.targets. */
export class PowerDownEvent {
	declare ["constructor"]: typeof PowerDownEvent;
	static type = "event" as const;
	static src = "controller" as const;
	static dst = "instance" as const;
	static plugin = "universal_edges" as const;

	constructor(public targets: TargetsT) { }

	static jsonSchema = Type.Object({ targets: Targets });

	static fromJSON(json: Static<typeof PowerDownEvent.jsonSchema>) {
		return new this(json.targets);
	}
}
