import type * as lib from "@clusterio/lib";
import type { ControllerPluginContext } from "@clusterio/controller";
import { lifecycle, rateLimited } from "../runtime/index.js";
import { RadarDownEvent, RadarUpEvent } from "./contracts.js";
import { Hub } from "./hub.js";

/** The radar sync's hook name: AsyncHook.attach throws on a second plain universal_edges one. */
const HOOK = "universal_edges:radar";

/** The radar sync on the controller (radar-sync spec §3, §5): the hub, its messages, and tiles stopping. */
export function startRadar(context: ControllerPluginContext): Hub {
	const { controller, logger } = context;
	const warn = rateLimited(logger);
	const hub = new Hub({
		send: (id, kind, payload) => {
			try {
				controller.sendTo({ instanceId: id }, new RadarDownEvent(kind, payload));
			} catch (err: any) {
				warn(`send:${id}`, "ue.radar message not delivered", { instance_id: id, kind, error: err.message });
			}
		},
		log: (phase, fields, level) => lifecycle(logger, "ue.radar", phase, fields, level),
		now: () => Date.now(),
	});
	controller.handle(RadarUpEvent, async (event: RadarUpEvent, src: lib.Address) => {
		hub.receive(src.id, event.kind, event.payload);
	});
	// §5: a down tile reads as silence. Its start is seen in its hello (Hub.runtime, from UE's controller.ts).
	controller.hooks.instanceStatusChanged.attach(HOOK, async instance => {
		if (instance.status !== "running") {
			hub.drop(instance.id);
		}
	});
	return hub;
}
