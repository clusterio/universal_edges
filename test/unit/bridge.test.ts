import { test } from "node:test";
import assert from "node:assert/strict";
import { Type } from "@sinclair/typebox";
import type { InstancePluginContext } from "@clusterio/host";
import { INBOUND_CAP, on, openBridge } from "../../runtime/bridge.js";

type Line = { level: string; message: string; meta: Record<string, any> };
// ponytail: named, not written inline in the generic type arguments below — ESLint's func-call-spacing
// doesn't understand generics and mistakes a parenthesized function type there for the call's own parens.
type OutHandler = (data: unknown) => Promise<void>;

// Named rather than `ReturnType<typeof fake>` on fake's own `base` parameter below: that would make the
// parameter's type depend on the function's inferred return type, which depends on the parameter's type.
type Fake = {
	context: InstancePluginContext;
	ipc: Map<string, OutHandler>;
	stopHooks: (() => unknown)[];
	commands: string[];
	lines: Line[];
};

/** Just enough of an instance plugin context for the endpoint. Pass `base` to share one instance across plugins. */
function fake(pluginName = "universal_edges", base?: Fake): Fake {
	const ipc = base?.ipc ?? new Map<string, OutHandler>();
	const stopHooks: (() => unknown)[] = base?.stopHooks ?? [];
	const commands: string[] = base?.commands ?? [];
	const lines: Line[] = base?.lines ?? [];
	const log = (level: string, message: string, meta: Record<string, any> = {}) => {
		lines.push({ level, message, meta });
	};
	const context = {
		plugin: { name: pluginName },
		logger: { log, warn: (message: string, meta?: Record<string, any>) => log("warn", message, meta) },
		instance: base?.context.instance ?? {
			server: { handle: (channel: string, fn: (data: unknown) => Promise<void>) => ipc.set(channel, fn) },
			hooks: {
				stop: { attach: (_name: string, fn: () => unknown) => stopHooks.push(fn) },
				exit: { attach: () => undefined },
			},
			sendRcon: async (command: string) => {
				commands.push(command);
				return "";
			},
		},
	} as unknown as InstancePluginContext;
	return { context, ipc, stopHooks, commands, lines };
}

const turn = () => new Promise(resolve => setImmediate(resolve));

/** The JSON batch inside `/sc ue_rt.inbox("universal_edges", "<escaped json>")`. */
function inboxBatch(command: string): { id: string; type: string; payload: { trace: string } }[] {
	const escaped = /^\/sc ue_rt\.inbox\("universal_edges", "(.*)"\)$/.exec(command)![1];
	return JSON.parse(JSON.parse(`"${escaped}"`));
}

test("trace events are logged at their level; other types reach their handler only when valid", async () => {
	const f = fake();
	const got: unknown[] = [];
	openBridge(f.context, {
		echo: on(Type.Object({ n: Type.Integer() }), payload => {
			got.push(payload);
		}),
	});
	await f.ipc.get("universal_edges:out")!({ tick: 5, msgs: [
		{ id: "a.1", type: "trace", payload: { op: "ue.ping", phase: "start", trace: "a.1", tick: 5 } },
		{ id: "a.2", type: "trace", payload: { op: "gw.selfcheck", phase: "done", level: "verbose" } },
		{ id: "a.6", type: "trace", payload: { op: "ue.lane", phase: "backpressure", level: "warn" } },
		{ id: "a.7", type: "trace", payload: { op: "ue.transfer", phase: "lost", level: "error" } },
		{ id: "a.3", type: "echo", payload: { n: 1 } },
		{ id: "a.4", type: "echo", payload: { n: "one" } },
		{ id: "a.5", type: "toString", payload: {} },
	] });
	assert.deepEqual(got, [{ n: 1 }]);
	assert.deepEqual(f.lines.map(l => [l.level, l.message]), [
		["info", "ue.ping start"],
		["verbose", "gw.selfcheck done"],
		["warn", "ue.lane backpressure"],
		["error", "ue.transfer lost"],
		["warn", "ue.bridge invalid payload"],
		["warn", "ue.bridge message of unknown type"],
	]);
	assert.equal(f.lines[0].meta.trace, "a.1");
	assert.equal(f.lines[1].meta.level, undefined);
});

test("messages from back-to-back IPC flushes are dispatched in arrival order, not interleaved", async () => {
	const f = fake();
	const got: number[] = [];
	openBridge(f.context, {
		echo: on(Type.Object({ n: Type.Integer() }), payload => {
			got.push(payload.n);
		}),
	});
	const h = f.ipc.get("universal_edges:out")!;
	const m = (id: string, n: number) => ({ id, type: "echo", payload: { n } });
	await Promise.all([h({ tick: 1, msgs: [m("a.1", 1), m("a.2", 2)] }), h({ tick: 1, msgs: [m("a.3", 3)] })]);
	assert.deepEqual(got, [1, 2, 3]);
});

test("an invalid flush is refused, with one warning however often it repeats", async () => {
	const f = fake();
	openBridge(f.context, {});
	const handle = f.ipc.get("universal_edges:out")!;
	await handle({ msgs: "not an array" });
	await handle({ msgs: "not an array" });
	assert.deepEqual(f.lines.map(l => [l.level, l.message]), [["warn", "ue.bridge invalid flush"]]);
});

test("messages to Lua wait for start, then leave in order, one inbox command per event-loop turn", async () => {
	const f = fake();
	const bridge = openBridge(f.context, {});
	bridge.send("ue.ping", { trace: "t.1" });
	bridge.send("ue.ping", { trace: "t.2" });
	await turn();
	assert.deepEqual(f.commands, [], "nothing before start");
	await bridge.rcon('/sc ue_rt.startup("{}")');
	bridge.start();
	bridge.send("ue.ping", { trace: "t.3" });
	await turn();
	await turn();
	assert.equal(f.commands[0], '/sc ue_rt.startup("{}")');
	const batches = f.commands.slice(1).map(inboxBatch);
	assert.deepEqual(batches.map(batch => batch.map(m => m.payload.trace)), [["t.1", "t.2"], ["t.3"]]);
	assert.match(batches[0][0].id, /^[0-9a-f]{8}\.\d+$/);
});

test("the stop hook drops what was queued for the run that stopped", async () => {
	const f = fake();
	const bridge = openBridge(f.context, {});
	bridge.send("ue.ping", { trace: "t.1" });
	await f.stopHooks[0]();
	bridge.start();
	await turn();
	assert.deepEqual(f.commands, []);
});

test("messages to Lua beyond INBOUND_CAP are dropped with one rate-limited warning", async () => {
	const f = fake();
	const bridge = openBridge(f.context, {});
	for (let i = 0; i < INBOUND_CAP + 5; i++) {
		bridge.send("ue.ping", { trace: `t.${i}` });
	}
	bridge.start();
	await turn();
	assert.deepEqual(f.lines.map(l => [l.level, l.message]), [["warn", "ue.bridge inbound queue full, dropping"]]);
	assert.equal(inboxBatch(f.commands[0]).length, INBOUND_CAP);
});

test("gridworld shares UE's start() and RCON order, flushing right after UE starts", async () => {
	const ue = fake("universal_edges");
	const gw = fake("gridworld", ue);
	const ueBridge = openBridge(ue.context, {});
	const gwBridge = openBridge(gw.context, {});
	gwBridge.send("trace", { op: "gw.selfcheck", phase: "done" });
	await turn();
	assert.deepEqual(ue.commands, [], "nothing before UE's start, not even gridworld's");
	await ueBridge.rcon('/sc ue_rt.startup("{}")');
	ueBridge.start();
	await turn();
	await turn();
	assert.equal(ue.commands[0], '/sc ue_rt.startup("{}")');
	assert.match(ue.commands[1], /^\/sc ue_rt\.inbox\("gridworld", /);
});

test("M7: while an inbox command is in flight, later messages wait and leave together in one command", async () => {
	const f = fake();
	let release: () => void = () => undefined;
	const sent: string[] = [];
	const instance = f.context.instance as unknown as { sendRcon: (c: string) => Promise<string> };
	instance.sendRcon = async (command: string) => {
		sent.push(command);
		if (command.includes("t.1")) {
			await new Promise<void>(resolve => {
				release = resolve;
			});
		}
		return "";
	};
	const bridge = openBridge(f.context, {});
	bridge.start();
	bridge.send("ue.ping", { trace: "t.1" });
	await turn();
	for (const trace of ["t.2", "t.3"]) {
		bridge.send("ue.ping", { trace });
		await turn();
	}
	assert.equal(sent.length, 1, "nothing more while the first command is in flight");
	release();
	await turn();
	await turn();
	assert.deepEqual(sent.map(inboxBatch).map(batch => batch.map(m => m.payload.trace)), [["t.1"], ["t.2", "t.3"]]);
});
