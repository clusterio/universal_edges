import * as lib from "@clusterio/lib";
import type { InstancePluginContext } from "@clusterio/host";
import type { Static, TSchema } from "@sinclair/typebox";
import { Flush, Trace } from "./contracts.js";
import { newId } from "./ids.js";
import { lifecycle, rateLimited } from "./log.js";

/** A handler for one bridge message type: the compiled contract, and what to do with a valid payload. */
export type Handler = { validate: ReturnType<typeof lib.compile>; handle: (payload: any) => void | Promise<void> };

/** Pair a contract with its handler; the payload's type comes from the schema. */
export function on<S extends TSchema>(schema: S, handle: (payload: Static<S>) => void | Promise<void>): Handler {
	return { validate: lib.compile(schema as any), handle };
}

export type Bridge = {
	/** Queue a message for this plugin's Lua. Queued messages leave in order, once per event-loop turn. */
	send(type: string, payload: object): void;
	/** Send an RCON command, ordered with every plugin's RCON on this instance. */
	rcon(command: string): Promise<string>;
	/**
	 * Let queued messages flow, for every plugin's bridge on this instance, not only this one's. Only UE's
	 * plugin calls this, once its handshake completes; other plugins' endpoints (gridworld's included) share
	 * that signal instead of calling start() themselves.
	 */
	start(): void;
};

/** How many messages to Lua are held while the runtime is not started; more are dropped, with a warning. */
export const INBOUND_CAP = 1000;

/** State shared by every plugin's bridge on one instance: one RCON order, and one start() for all of them. */
type SharedState = { chain: Promise<unknown>; started: boolean; flushes: (() => void)[] };
// ponytail: a named alias, not `new WeakMap<object, { ... }>()` inline — ESLint's func-call-spacing doesn't
// understand generic type arguments and mistakes a parenthesized member type for the call's own parens.
const perInstance = new WeakMap<object, SharedState>();

function sharedState(instance: object) {
	let state = perInstance.get(instance);
	if (!state) {
		state = { chain: Promise.resolve(), started: false, flushes: [] };
		perInstance.set(instance, state);
	}
	return state;
}

/**
 * The instance end of a plugin's bridge (spec §7.3). IPC on "<plugin>:out" is dispatched in arrival order and
 * checked against the contracts: trace events are logged, other types go to their handler. Messages to Lua are
 * batched into one ordered `/sc ue_rt.inbox("<plugin>", "<json>")` per event-loop turn.
 */
export function openBridge(context: InstancePluginContext, handlers: Record<string, Handler>): Bridge {
	const { instance, logger, plugin } = context;
	const warn = rateLimited(logger);
	const validFlush = lib.compile<Static<typeof Flush>>(Flush as any);
	const validTrace = lib.compile<Static<typeof Trace>>(Trace as any);
	const shared = sharedState(instance);

	async function dispatch(type: string, payload: unknown) {
		if (type === "trace") {
			if (!validTrace(payload)) {
				warn("trace", "ue.bridge invalid trace event", { errors: validTrace.errors });
				return;
			}
			// Reserved log keys, and the fields the cluster logger stamps from real context: a trace event's
			// own fields must not overwrite them, and a spoofed instance_id/instance_name must not fake its origin.
			// Cast: none of the four are part of the Trace contract, but a hostile payload can still carry them,
			// so they must be named and stripped here rather than trusted to be absent.
			const { op, phase, level, message, timestamp, instance_id, instance_name, ...fields } =
				payload as Static<typeof Trace> & Record<string, unknown>;
			lifecycle(logger, op, phase, fields, level);
			return;
		}
		// Own properties only: a type such as "toString" from Lua must not find Object.prototype.
		const handler = Object.hasOwn(handlers, type) ? handlers[type] : undefined;
		if (!handler) {
			warn(`unknown:${type}`, "ue.bridge message of unknown type", { type });
			return;
		}
		if (!handler.validate(payload)) {
			warn(`invalid:${type}`, "ue.bridge invalid payload", { type, errors: handler.validate.errors });
			return;
		}
		try {
			await handler.handle(payload);
		} catch (err: any) {
			warn(`failed:${type}`, "ue.bridge handler failed", { type, error: err?.message ?? String(err) });
		}
	}

	async function receive(data: unknown) {
		if (!validFlush(data)) {
			warn("flush", "ue.bridge invalid flush", { errors: validFlush.errors });
			return;
		}
		for (const msg of data.msgs) {
			await dispatch(msg.type, msg.payload);
		}
	}

	// server.handle starts a handler per IPC line without waiting (server.ts:736-740); chain them so messages
	// from back-to-back flushes are still dispatched in arrival order.
	let receiving: Promise<void> = Promise.resolve();
	instance.server.handle(`${plugin.name}:out`, async (data: unknown) => {
		receiving = receiving.then(() => receive(data))
			.catch(err => warn("receive", "ue.bridge receive failed", { error: String(err) }));
		await receiving;
	});

	let queue: { id: string; type: string; payload: object }[] = [];
	let scheduled = false;
	// M7 (0B final review): one inbox command in flight at a time. Messages queued meanwhile (up to INBOUND_CAP) leave
	// together in the next command, so a slow Factorio makes batches bigger, not the RCON backlog longer.
	let inflight = false;

	// The default-export entrypoint has no sendOrderedRcon, so the bridge keeps its own order, shared across
	// every plugin on this instance (one Factorio server, one RCON connection).
	function rcon(command: string): Promise<string> {
		const result = shared.chain.then(() => instance.sendRcon(command, true, plugin.name));
		shared.chain = result.catch(() => undefined);
		return result;
	}

	function flush() {
		scheduled = false;
		if (!shared.started || queue.length === 0 || inflight) {
			return;
		}
		const json = JSON.stringify(queue);
		queue = [];
		inflight = true;
		// ponytail: one command per flush, however big (at most INBOUND_CAP messages); split it if a batch ever
		// outgrows RCON. v1 sent whole trains in one command (universal_edges/instance.ts:552-560).
		rcon(`/sc ue_rt.inbox("${plugin.name}", "${lib.escapeString(json)}")`).catch((err: Error) => {
			warn("inbox", "ue.bridge inbox command failed", { error: err.message });
		}).finally(() => {
			inflight = false;
			if (queue.length > 0 && !scheduled) {
				scheduled = true;
				setImmediate(flush);
			}
		});
	}
	shared.flushes.push(flush);

	function stop() {
		shared.started = false;
		queue = [];
	}

	instance.hooks.stop.attach(`${plugin.name}:bridge`, async () => stop());
	instance.hooks.exit.attach(`${plugin.name}:bridge`, () => stop());

	return {
		send(type, payload) {
			if (queue.length >= INBOUND_CAP) {
				warn("full", "ue.bridge inbound queue full, dropping", { type });
				return;
			}
			queue.push({ id: newId(), type, payload });
			if (!scheduled) {
				scheduled = true;
				setImmediate(flush);
			}
		},
		rcon,
		start() {
			shared.started = true;
			for (const f of shared.flushes) {
				f();
			}
		},
	};
}
