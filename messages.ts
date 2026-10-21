import { Type, type Static } from "@sinclair/typebox";

/** Instance → controller: the Lua runtime's hello after each handshake, and its heartbeats (every 600 ticks). */
export class RuntimeEvent {
	declare ["constructor"]: typeof RuntimeEvent;
	static type = "event" as const;
	static src = "instance" as const;
	static dst = "controller" as const;
	static plugin = "universal_edges" as const;

	constructor(
		public kind: "hello" | "heartbeat",
		public bootId: string,
		public tick: number,
	) { }

	static jsonSchema = Type.Object({
		kind: Type.Union([Type.Literal("hello"), Type.Literal("heartbeat")]),
		bootId: Type.String(),
		tick: Type.Integer(),
	});

	static fromJSON(json: Static<typeof RuntimeEvent.jsonSchema>) {
		return new this(json.kind, json.bootId, json.tick);
	}
}

/** A ping (or its pong) on its way from instance `from` to instance `to`, always through the controller. */
export class PingEvent {
	declare ["constructor"]: typeof PingEvent;
	static type = "event" as const;
	static src = ["instance", "controller"] as const;
	static dst = ["controller", "instance"] as const;
	static plugin = "universal_edges" as const;

	constructor(
		public trace: string,
		public kind: "ping" | "pong",
		public from: number,
		public to: number,
	) { }

	static jsonSchema = Type.Object({
		trace: Type.String(),
		kind: Type.Union([Type.Literal("ping"), Type.Literal("pong")]),
		from: Type.Integer(),
		to: Type.Integer(),
	});

	static fromJSON(json: Static<typeof PingEvent.jsonSchema>) {
		return new this(json.trace, json.kind, json.from, json.to);
	}
}
