import type { InstancePluginContext } from "@clusterio/host";
import { on, type Bridge, type Handler } from "../runtime/index.js";
import { Counts, Report, SchedDownEvent, SchedUpEvent } from "./contracts.js";

/**
 * The tile's relay (sync spec §6): Lua's ue.sched.report and ue.sched.counts, checked on UE's bridge, go up to the
 * controller; the controller's ue.sched.set, drop and full go down to Lua as they are. No state.
 */
export function schedulesForwarding(context: InstancePluginContext) {
	const { instance } = context;
	const up = (kind: string) => (payload: object) => {
		instance.sendTo("controller", new SchedUpEvent(kind, payload));
	};
	const handlers: Record<string, Handler> = {
		"ue.sched.report": on(Report, up("ue.sched.report")),
		"ue.sched.counts": on(Counts, up("ue.sched.counts")),
	};
	function attach(bridge: Bridge) {
		instance.handle(SchedDownEvent, async (event: SchedDownEvent) => {
			bridge.send(event.kind, event.payload as object);
		});
	}
	return { handlers, attach };
}
