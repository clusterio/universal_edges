import type * as lib from "@clusterio/lib";
import type { ControllerPluginContext } from "@clusterio/controller";
import { rateLimited } from "../runtime/index.js";
import { PowerDownEvent, PowerUpEvent } from "./contracts.js";
import { PowerHub } from "./hub.js";

/** The power hub's hook name: AsyncHook.attach throws on a second plain universal_edges one. */
const HOOK = "universal_edges:power";
/** §8: one round a second. */
export const ROUND_MS = 1000;

/** The power hub on the controller (power hub spec §7, §8): reports in, a round a second, tiles stopping (§10). */
export function startPower(context: ControllerPluginContext): PowerHub {
	const { controller, logger } = context;
	const warn = rateLimited(logger);
	const hub = new PowerHub({
		send: (id, targets) => {
			try {
				controller.sendTo({ instanceId: id }, new PowerDownEvent(targets));
			} catch (err: any) {
				warn(`send:${id}`, "ue.power targets not delivered", { instance_id: id, error: err.message });
			}
		},
		now: () => Date.now(),
	});
	controller.handle(PowerUpEvent, async (event: PowerUpEvent, src: lib.Address) => {
		hub.report(src.id, event.report);
	});
	controller.hooks.instanceStatusChanged.attach(HOOK, async instance => {
		if (instance.status !== "running") {
			hub.drop(instance.id);
		}
	});
	// plan ruling 11: a throw out of setInterval would end the controller
	const timer = setInterval(() => {
		try {
			hub.round();
		} catch (err: any) {
			warn("round", "ue.power round failed", { error: err.stack ?? err.message });
		}
	}, ROUND_MS);
	controller.hooks.shutdown.attach(HOOK, async () => {
		clearInterval(timer);
	});
	return hub;
}
