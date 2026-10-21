import type { InstancePluginContext } from "@clusterio/host";
import { on, type Bridge, type Handler } from "../runtime/index.js";
import { Alive, Arrived, Lost, Manual, Report, Request, RouteDownEvent, RouteUpEvent } from "./contracts.js";

/**
 * The tile's relay (R2): Lua's ue.route.* messages, checked on UE's bridge, go up to the controller; the controller's
 * go down to Lua as they are. No state. Lua's trace lines are logged by the bridge itself.
 */
export function routingForwarding(context: InstancePluginContext) {
	const { instance } = context;
	const up = (kind: string) => (payload: object) => {
		instance.sendTo("controller", new RouteUpEvent(kind, payload));
	};
	const handlers: Record<string, Handler> = {
		"ue.route.report": on(Report, up("ue.route.report")),
		"ue.route.request": on(Request, up("ue.route.request")),
		"ue.route.arrived": on(Arrived, up("ue.route.arrived")),
		"ue.route.lost": on(Lost, up("ue.route.lost")),
		"ue.route.manual": on(Manual, up("ue.route.manual")),
		"ue.route.alive": on(Alive, up("ue.route.alive")),
	};
	function attach(bridge: Bridge) {
		instance.handle(RouteDownEvent, async (event: RouteDownEvent) => {
			bridge.send(event.kind, event.payload as object);
		});
	}
	return { handlers, attach };
}
