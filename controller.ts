import * as path from "node:path";
import type * as lib from "@clusterio/lib";
import type { ControllerPluginContext } from "@clusterio/controller";
import { PingEvent, RuntimeEvent } from "./messages.js";
import { startEdges } from "./edges/controller.js";
import { startRouting } from "./routing/controller.js";
import { startRadar } from "./radar/controller.js";
import { startSchedules } from "./schedules/controller.js";
import { RuntimeTracker, lifecycle, loadDataFile, saveDataFile, type Migration } from "./runtime/index.js";

/** Migrations of universal_edges_runtime.json ({ [instance id]: last tick }). Append; never edit one. */
const TRACKER_MIGRATIONS: Migration[] = [];

export default async function loadControllerPlugin(context: ControllerPluginContext) {
	const { controller, logger, plugin } = context;
	const file = path.resolve(controller.config.get("controller.database_directory"), "universal_edges_runtime.json");
	const saved = await loadDataFile(file, TRACKER_MIGRATIONS) as Record<string, number> | undefined;
	const tracker = new RuntimeTracker(saved ?? {}, err => {
		logger.error(`a rollback listener failed:\n${err.stack ?? err.message}`);
	});

	// SP1a: the edge store, activation and reconcile loop; hellos and heartbeats below give it each boot.
	const edges = await startEdges(context);
	// SP4: train routing (spec §4), after the edge API it reads.
	await startRouting(context);
	// Train group sync (sync spec §3): the cluster's groups and interrupts.
	await startSchedules(context);
	// The radar sync (radar-sync spec §3): the hub of every tile's radar networks.
	const radar = startRadar(context);

	// A hello after each start's handshake, heartbeats every 600 ticks. A tick that went back is a rollback.
	controller.handle(RuntimeEvent, async (event: RuntimeEvent, src: lib.Address) => {
		if (event.kind === "hello") {
			lifecycle(logger, "ue.runtime", "hello", { instance_id: src.id, boot_id: event.bootId, tick: event.tick });
		}
		const rollback = tracker.observe(src.id, event.tick);
		if (rollback) {
			const fields = { instance_id: src.id, tick: rollback.tick, last_tick: rollback.lastTick };
			lifecycle(logger, "ue.runtime", "rollback", fields, "warn");
		}
		edges.onRuntime(src.id, event.bootId);
		radar.runtime(src.id, event.bootId); // a boot the hub hasn't seen resyncs (plan ruling 8)
	});

	// Instances address pings to the controller, so this hop happens, and is logged, even between two
	// instances on one host, where the host would otherwise deliver the message itself.
	controller.handle(PingEvent, async (event: PingEvent, src: lib.Address) => {
		const fields = { trace: event.trace, kind: event.kind, from: src.id, to: event.to };
		lifecycle(logger, "ue.ping", "relay", fields);
		try {
			controller.sendTo({ instanceId: event.to }, new PingEvent(event.trace, event.kind, src.id, event.to));
		} catch (err: any) {
			lifecycle(logger, "ue.ping", "undeliverable", { ...fields, error: err.message }, "warn");
		}
	});

	// The controller's save cycle; it also runs during shutdown.
	controller.hooks.save.attach(plugin.name, async () => {
		await saveDataFile(file, TRACKER_MIGRATIONS, tracker.toJSON());
	});
}
