import * as path from "node:path";
import type * as lib from "@clusterio/lib";
import type { ControllerPluginContext } from "@clusterio/controller";
import { lifecycle, loadDataFile, rateLimited, saveDataFile } from "../runtime/index.js";
import { SchedDownEvent, SchedUpEvent } from "./contracts.js";
import { ScheduleSync, type Saved } from "./sync.js";

/** Every Clusterio hook the sync attaches has this name: AsyncHook.attach throws on a second one of a name. */
const HOOK = "universal_edges:schedules";
export const SCHEDULES_FILE = "universal_edges_schedules.json";
/** §5.5's lifetime check. */
const CHECK_MS = 10_000;
/** A running tile not given a full since this controller started gets one this often (routing's resync, §5.2). */
const RESYNC_MS = 60_000;

/** The saved groups, interrupts and counts (§4), or undefined before the first save. */
export async function loadSchedules(dir: string): Promise<Saved | undefined> {
	const saved = await loadDataFile(path.resolve(dir, SCHEDULES_FILE), []);
	return saved as Saved | undefined;
}

/** Train group sync on the controller (spec §3): messages, instance status, the lifetime timer and the data file. */
export async function startSchedules(context: ControllerPluginContext): Promise<ScheduleSync> {
	const { controller, logger } = context;
	const warn = rateLimited(logger);
	const dir = controller.config.get("controller.database_directory");
	const running = () => [...controller.instances.values()].filter(i => i.status === "running").map(i => i.id);
	const sync = new ScheduleSync({
		tiles: running,
		name: id => controller.instances.get(id)?.config.get("instance.name") ?? String(id),
		send: (id, kind, payload) => {
			try {
				controller.sendTo({ instanceId: id }, new SchedDownEvent(kind, payload));
			} catch (err: any) {
				warn(`send:${id}`, "ue.sched message not delivered", { instance_id: id, kind, error: err.message });
			}
		},
		log: (op, phase, fields, level) => lifecycle(logger, op, phase, fields, level),
	}, await loadSchedules(dir));
	/** Tiles given a full since this controller started. */
	const synced = new Set<number>();
	const full = (id: number) => {
		sync.full(id);
		synced.add(id);
	};

	controller.handle(SchedUpEvent, async (event: SchedUpEvent, src: lib.Address) => {
		sync.receive(src.id, event.kind, event.payload);
	});
	controller.hooks.instanceStatusChanged.attach(HOOK, async instance => {
		if (instance.status === "running") {
			full(instance.id);
		} else {
			synced.delete(instance.id);
		}
	});
	const timers = [
		setInterval(() => sync.sweep(), CHECK_MS),
		setInterval(() => {
			for (const id of running()) {
				if (!synced.has(id)) {
					full(id);
				}
			}
		}, RESYNC_MS),
	];
	controller.hooks.save.attach(HOOK, async () => {
		await saveDataFile(path.resolve(dir, SCHEDULES_FILE), [], sync.toJSON());
	});
	controller.hooks.shutdown.attach(HOOK, async () => {
		for (const timer of timers) {
			clearInterval(timer);
		}
	});
	return sync;
}
