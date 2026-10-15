import * as lib from "@clusterio/lib";
import type { InstancePluginContext } from "@clusterio/host";
import { PingEvent, RuntimeEvent } from "./messages.js";
import { edgeForwarding } from "./edges/lanes.js";
import { playerForwarding } from "./edges/players.js";
import { routingForwarding } from "./routing/instance.js";
import { radarForwarding } from "./radar/instance.js";
import { schedulesForwarding } from "./schedules/instance.js";
import { Heartbeat, Hello, PingOut, Stats, newBootId, on, openBridge, type PingInPayload } from "./runtime/index.js";

/** The Lua runtime's counters (scheduler tasks, and "ue.bridge"), one series per instance, task and kind. */
const taskCounter = new lib.Counter(
	"clusterio_universal_edges_task_total",
	"Universal Edges runtime counters by task and kind (runs, units, deferrals, drops, expiries, rejects, ...)",
	{ labels: ["instance_id", "task", "kind"] },
);

/** Kinds that mean work was delayed, dropped or refused. Each such task gets one warning per report (60 s). */
const WARN_KINDS = new Set(["deferrals", "drops", "expiries", "rejects", "unknown", "errors"]);

export default async function loadInstancePlugin(context: InstancePluginContext) {
	const { instance, logger, plugin } = context;
	let bootId = "";

	// SP1a: the edge messages and Lua's applied reports (edges/lanes.ts).
	const edges = edgeForwarding(context, () => bootId);
	const players = playerForwarding(context);
	const routing = routingForwarding(context);
	const schedules = schedulesForwarding(context);
	const radar = radarForwarding(context);
	const bridge = openBridge(context, {
		...edges.handlers,
		...players.handlers,
		...routing.handlers,
		...schedules.handlers,
		...radar.handlers,
		"runtime.hello": on(Hello, hello => {
			instance.sendTo("controller", new RuntimeEvent("hello", hello.boot_id, hello.tick));
		}),
		"runtime.heartbeat": on(Heartbeat, heartbeat => {
			instance.sendTo("controller", new RuntimeEvent("heartbeat", bootId, heartbeat.tick));
		}),
		"runtime.stats": on(Stats, report => {
			for (const [task, kinds] of Object.entries(report.tasks)) {
				for (const [kind, n] of Object.entries(kinds)) {
					taskCounter.labels(String(instance.id), task, kind).inc(n);
				}
				if (Object.entries(kinds).some(([kind, n]) => WARN_KINDS.has(kind) && n > 0)) {
					logger.warn(`ue.runtime ${task} delayed, dropped or refused work`, { task, ...kinds });
				}
			}
		}),
		"ue.ping": on(PingOut, ping => {
			instance.sendTo("controller", new PingEvent(ping.trace, ping.kind, instance.id, ping.target));
		}),
	});

	// Pings and pongs that the controller relays here go to Lua's inbox.
	instance.handle(PingEvent, async event => {
		const payload: PingInPayload = { trace: event.trace, kind: event.kind, from: event.from };
		bridge.send("ue.ping", payload);
	});
	edges.attach(bridge);
	players.attach(bridge);
	routing.attach(bridge);
	schedules.attach(bridge);
	radar.attach(bridge);

	// The startup handshake (spec §7.5): a fresh boot id for this Factorio run; then messages to Lua may flow.
	instance.hooks.start.attach(plugin.name, async () => {
		bootId = newBootId();
		const handshake = { boot_id: bootId, instance_id: instance.id, instance_name: instance.name };
		await bridge.rcon(`/sc ue_rt.startup("${lib.escapeString(JSON.stringify(handshake))}")`);
		bridge.start();
	});
}
