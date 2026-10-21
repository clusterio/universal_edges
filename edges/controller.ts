import * as path from "node:path";
import * as lib from "@clusterio/lib";
import type { ControllerPluginContext } from "@clusterio/controller";
import { lifecycle, loadDataFile, rateLimited, saveDataFile, type Migration } from "../runtime/index.js";
import { EdgeActivation } from "./activation.js";
import {
	ConnectorChangeRequest, EdgeAppliedEvent, EdgeChangedEvent, EdgeEnsureRequest, EdgeListRequest, EdgeRemoveRequest,
} from "./contracts.js";
import { crossingResolver, setEdgeApi } from "./index.js";
import { PlayerCrossRequest, PlayerJoinRequest, PlayerLeftEvent, resolveKeys } from "./players.js";
import { CrossingRecords } from "./crossings.js";
import { EdgeStore, type StoreData } from "./store.js";

/** Migrations of universal_edges_edges.json ({ counter, edges }). Append; never edit one. */
const EDGE_MIGRATIONS: Migration[] = [];
/** SP1 spec §6.3 and §11.11: how often lost syncs, updates and activation states are re-sent. */
const RECONCILE_MS = 60_000;

/**
 * The controller half of the edge lifecycle (§5, §6): load the store, wire activation to Clusterio's hooks and
 * messages, publish the in-process API and run the reconcile loop. The caller feeds it hellos and heartbeats.
 */
export async function startEdges(context: ControllerPluginContext) {
	const { controller, logger, plugin } = context;
	const file = path.resolve(controller.config.get("controller.database_directory"), "universal_edges_edges.json");
	const warn = rateLimited(logger);
	const data = await loadDataFile(file, EDGE_MIGRATIONS) as StoreData | undefined;
	const store: EdgeStore = new EdgeStore(data, {
		save: saved => saveDataFile(file, EDGE_MIGRATIONS, saved),
		published: (changed, purged) => {
			activation.published(changed, purged);
			if (changed.length > 0 || purged.length > 0) {
				// M2 (SP1a final review): purges are published too, so a subscribed page drops a purged edge.
				controller.subscriptions.broadcast(new EdgeChangedEvent(changed, purged.map(r => r.id)));
			}
		},
	}, logger);
	const activation = new EdgeActivation(store, {
		status: id => controller.instances.get(id)?.status,
		exists: id => controller.instances.has(id),
		send: (id, message) => {
			try {
				controller.sendTo({ instanceId: id }, message);
			} catch (err: any) {
				warn(`send:${id}`, "ue.edge message not delivered", { instance_id: id, error: err.message });
			}
		},
		readiness: readiness => {
			controller.subscriptions.broadcast(new EdgeChangedEvent([], [], [readiness]));
		},
	}, logger);

	setEdgeApi({
		ensure: spec => store.ensure(spec),
		remove: (id, owner) => store.remove(id, owner),
		get: id => store.get(id),
		list: filter => store.list(filter),
		isActive: id => activation.isActive(id),
		on: listener => store.on(listener),
	});

	controller.handle(EdgeAppliedEvent, async (event: EdgeAppliedEvent, src: lib.Address) => {
		activation.onApplied(src.id, event);
	});
	controller.hooks.instanceStatusChanged.attach(plugin.name, async instance => {
		activation.onStatus(instance.id, instance.status);
	});

	// Control requests (§6.1, §7.2). Clusterio has already checked each one's permission.
	controller.handle(EdgeEnsureRequest, async (request: EdgeEnsureRequest) => {
		const edge = await store.ensure(request.edge);
		return { edge };
	});
	controller.handle(EdgeRemoveRequest, async (request: EdgeRemoveRequest) => {
		await store.remove(request.id, request.owner);
	});
	controller.handle(EdgeListRequest, async () => ({ edges: store.list() }));
	controller.handle(ConnectorChangeRequest, async (request: ConnectorChangeRequest, src: lib.Address) => {
		const requester = src.type === lib.Address.instance ? src.id : undefined;
		return store.connector(request.change, requester);
	});
	// Player-crossing spec §4–§6: each key in order to an instance and its address; the first that works is recorded.
	const records = new CrossingRecords();
	const facts = (id: number) => {
		const i = controller.instances.get(id);
		return i && {
			name: i.config.get("instance.name"),
			host: i.config.get("instance.assigned_host") ?? undefined,
			status: i.status,
			gamePort: i.gamePort,
		};
	};
	controller.handle(PlayerCrossRequest, async (request: PlayerCrossRequest, src: lib.Address) => {
		const { result, to, key } = resolveKeys(request.keys, src.id, request.surface, id => store.get(id),
			crossingResolver, facts, id => controller.hosts.get(id));
		if (to !== undefined && key !== undefined) {
			records.cross(request.player, { to, key, from: src.id, x: request.x, y: request.y, surface: request.surface,
				trace: request.trace });
		}
		lifecycle(logger, "ue.player", "resolved", {
			keys: request.keys.join(","), key, player: request.player, from: src.id, to, ok: result.ok,
			reason: result.reason, x: request.x, y: request.y, surface: request.surface, trace: request.trace,
		});
		return result;
	});
	controller.handle(PlayerLeftEvent, async (event: PlayerLeftEvent, src: lib.Address) => {
		const known = records.left(event.player, { from: src.id, x: event.x, y: event.y, surface: event.surface });
		lifecycle(logger, "ue.player", "left_recorded", {
			player: event.player, from: src.id, known, x: event.x, y: event.y, surface: event.surface,
			trace: event.trace,
		});
	});
	controller.handle(PlayerJoinRequest, async (request: PlayerJoinRequest, src: lib.Address) => {
		const found = records.join(request.player, src.id);
		lifecycle(logger, "ue.player", "consumed", {
			player: request.player, to: src.id, found: found !== undefined, key: found?.arrival.key,
			trace: found?.arrival.trace, age_ms: found?.age,
		});
		return { arrival: found?.arrival ?? null };
	});
	// The subscription the web page and a future map use (§7.2, §7.4): records written since the subscriber's last
	// request, and every edge's readiness (D13), which isn't a record and has no update time. Always an event, even an
	// empty one, so a page that cleared its list on reconnect is repainted.
	controller.subscriptions.handle(EdgeChangedEvent, async (request: lib.SubscriptionRequest) => {
		if (request.action === "unsubscribe") {
			return null;
		}
		const all = store.list();
		const edges = all.filter(r => r.updatedAtMs > request.lastRequestTimeMs);
		return new EdgeChangedEvent(edges, [], all.map(r => activation.readiness(r)));
	});

	// §5.1: live edges naming an instance the controller no longer has are tombstoned (instance_missing).
	const named = new Set(store.list().filter(r => !r.deleted).flatMap(r => [r.a.instanceId, r.b.instanceId]));
	for (const id of named) {
		if (!controller.instances.has(id)) {
			store.tombstoneInstance(id, "instance_missing").catch((err: Error) => {
				logger.error(`ue.edge tombstoning missing instance ${id} failed: ${err.message}`);
			});
		}
	}
	activation.reconcile();
	const timer = setInterval(() => {
		// M2: an uncaught exception here would otherwise kill the interval (or the process) silently.
		try {
			activation.reconcile();
		} catch (err: any) {
			logger.error(`ue.edge reconcile failed: ${err.message}`);
		}
	}, RECONCILE_MS);
	controller.hooks.shutdown.attach(plugin.name, async () => {
		clearInterval(timer);
	});
	return { onRuntime: (instanceId: number, boot: string) => activation.onRuntime(instanceId, boot) };
}
