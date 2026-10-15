import { Type, type Static } from "@sinclair/typebox";

// Every bridge message type, declared once (spec §7.3). Lua checks each field it reads, and TypeScript
// validates everything that arrives from Lua against these before use.

/** Lua → TS, on any plugin's channel: a lifecycle event, logged by the instance plugin as "<op> <phase>". */
export const Trace = Type.Object({
	op: Type.String(),
	phase: Type.String(),
	trace: Type.Optional(Type.String()),
	tick: Type.Optional(Type.Integer()),
	level: Type.Optional(
		Type.Union([Type.Literal("info"), Type.Literal("verbose"), Type.Literal("warn"), Type.Literal("error")]),
	),
});

/** Lua → TS: the runtime's answer to the startup handshake. */
export const Hello = Type.Object({
	boot_id: Type.String(),
	tick: Type.Integer(),
	schemas: Type.Record(Type.String(), Type.Integer()),
});

/** Lua → TS every 600 ticks, for rollback detection. */
export const Heartbeat = Type.Object({ tick: Type.Integer() });

/** Lua → TS every 3600 ticks: counters by task and kind since the previous report. */
export const Stats = Type.Object({
	tasks: Type.Record(Type.String(), Type.Record(Type.String(), Type.Number())),
});

const PingKind = Type.Union([Type.Literal("ping"), Type.Literal("pong")]);

/** Lua → TS: send this ping or pong to instance `target`. */
export const PingOut = Type.Object({ trace: Type.String(), kind: PingKind, target: Type.Integer() });

/** TS → Lua: a ping or pong from instance `from`. */
export const PingIn = Type.Object({ trace: Type.String(), kind: PingKind, from: Type.Integer() });
export type PingInPayload = Static<typeof PingIn>;

/** The envelope of one "<plugin>:out" IPC call: one tick's messages, or part of them. */
export const Flush = Type.Object({
	tick: Type.Integer(),
	msgs: Type.Array(Type.Object({ id: Type.String(), type: Type.String(), payload: Type.Unknown() })),
});
