import * as path from "node:path";
import type * as lib from "@clusterio/lib";
import type { ControllerPluginContext } from "@clusterio/controller";
import { edgeApi } from "../edges/index.js";
import { lifecycle, loadDataFile, rateLimited, saveDataFile } from "../runtime/index.js";
import { RouteDownEvent, RouteUpEvent } from "./contracts.js";
import { Router, type SavedRoute } from "./router.js";

/** Every Clusterio hook routing attaches has this name: AsyncHook.attach throws on a second universal_edges one. */
const HOOK = "universal_edges:routing";
export const ROUTES_FILE = "universal_edges_routes.json";
/** The station list goes out at most this often, and only when it changed (D42 point 7). */
const STATIONS_MS = 5_000;
/** A running tile with no table gets a resync this often: after a controller restart, or a start it missed (§7.3). */
const RESYNC_MS = 60_000;
/** The 5-minute rule's pass (§7.4, R15). */
const GC_MS = 60_000;

/** The saved routes (§4.4): ours, or the prototype's router_state.json while ours is missing (R27). */
export async function loadRoutes(dir: string): Promise<{ routes?: SavedRoute[] } | undefined> {
	const ours = await loadDataFile(path.resolve(dir, ROUTES_FILE), []);
	const saved = ours ?? await loadDataFile(path.resolve(dir, "router_state.json"), []);
	return saved as { routes?: SavedRoute[] } | undefined;
}

/** SP4 routing on the controller (§4.1): messages, instance status, timers and the routes file. */
export async function startRouting(context: ControllerPluginContext): Promise<Router> {
	const { controller, logger } = context;
	const warn = rateLimited(logger);
	const dir = controller.config.get("controller.database_directory");
	const router = new Router({
		edges: () => edgeApi().list(),
		name: id => controller.instances.get(id)?.config.get("instance.name") ?? String(id),
		send: (id, kind, payload) => {
			try {
				controller.sendTo({ instanceId: id }, new RouteDownEvent(kind, payload));
			} catch (err: any) {
				warn(`send:${id}`, "ue.route message not delivered", { instance_id: id, kind, error: err.message });
			}
		},
		log: (op, phase, fields, level) => lifecycle(logger, op, phase, fields, level),
		now: () => Date.now(),
	}, await loadRoutes(dir));

	controller.handle(RouteUpEvent, async (event: RouteUpEvent, src: lib.Address) => {
		router.receive(src.id, event.kind, event.payload);
	});
	// D43: a tile's reservations are re-synced at its start; a stopped tile's table is stale until then.
	controller.hooks.instanceStatusChanged.attach(HOOK, async instance => {
		if (instance.status === "running") {
			router.resync(instance.id);
		} else {
			router.drop(instance.id);
		}
	});
	const timers = [
		setInterval(() => router.broadcastStations(), STATIONS_MS),
		setInterval(() => {
			for (const i of controller.instances.values()) {
				if (i.status === "running" && !router.tiles.has(i.id)) {
					router.resync(i.id);
				}
			}
		}, RESYNC_MS),
		setInterval(() => router.gc(), GC_MS),
	];
	controller.hooks.save.attach(HOOK, async () => {
		await saveDataFile(path.resolve(dir, ROUTES_FILE), [], router.toJSON());
	});
	controller.hooks.shutdown.attach(HOOK, async () => {
		for (const timer of timers) {
			clearInterval(timer);
		}
	});
	return router;
}
