import type { InstancePluginContext } from "@clusterio/host";
import * as lib from "@clusterio/lib";
import { ChunkPayload } from "../edges/contracts.js";
import { reassembly } from "../edges/lanes.js";
import { on, rateLimited, type Bridge, type Handler } from "../runtime/index.js";
import { PowerDownEvent, PowerUpEvent, Report, ReportIn, type ReportT } from "./contracts.js";

/**
 * The tile's relay of the power hub (power hub spec §7). Lua's ue.power.report, checked on UE's bridge, goes up to the
 * controller, and the hub's targets come down to Lua as ue.power.targets. A report over 2000 bytes is put back together
 * from its ue.power.chunk parts first. No state but the parts in flight.
 */
export function powerForwarding(context: InstancePluginContext) {
	const { instance, logger } = context;
	const warn = rateLimited(logger);
	const bodies = reassembly();
	const validReport = lib.compile<ReportT>(Report as any);
	const handlers: Record<string, Handler> = {
		"ue.power.chunk": on(ChunkPayload, part => {
			bodies.part(part);
		}),
		"ue.power.report": on(ReportIn, p => {
			let report: unknown = p;
			if ("chunks" in p) {
				report = bodies.json(`power/${p.seq}`, p.chunks, validReport);
				if (report === undefined) {
					warn("chunks", "ue.power chunked report incomplete or invalid, dropped", { seq: p.seq });
					return; // the next second's report replaces it
				}
			}
			instance.sendTo("controller", new PowerUpEvent(report as ReportT));
		}),
	};
	function attach(bridge: Bridge) {
		instance.handle(PowerDownEvent, async (event: PowerDownEvent) => {
			bridge.send("ue.power.targets", event.targets);
		});
	}
	return { handlers, attach };
}
