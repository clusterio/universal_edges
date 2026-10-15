import * as lib from "@clusterio/lib";
import type { InstancePluginContext } from "@clusterio/host";
import type { Static } from "@sinclair/typebox";
import { ChunkPayload } from "../edges/contracts.js";
import { reassembly } from "../edges/lanes.js";
import { on, rateLimited, type Bridge, type Handler } from "../runtime/index.js";
import { KeyOnly, Own, OwnIn, RadarDownEvent, RadarUpEvent } from "./contracts.js";

/**
 * The tile's relay of the radar sync (radar-sync spec §5; plan ruling 7): Lua's ue.radar.* messages, checked on UE's
 * bridge, go up to the controller. A report over 3000 bytes is put back together from its ue.radar.chunk parts first
 * (plan ruling 12). The controller's messages go down to Lua as they are. No state but the parts in flight.
 */
export function radarForwarding(context: InstancePluginContext) {
	const { instance, logger } = context;
	const warn = rateLimited(logger);
	const bodies = reassembly();
	const validOwn = lib.compile<Static<typeof Own>>(Own as any);
	const up = (kind: string) => (payload: object) => {
		instance.sendTo("controller", new RadarUpEvent(kind, payload));
	};
	const handlers: Record<string, Handler> = {
		"ue.radar.chunk": on(ChunkPayload, part => {
			bodies.part(part);
		}),
		"ue.radar.own": on(OwnIn, p => {
			if (!("chunks" in p)) {
				up("ue.radar.own")(p);
				return;
			}
			const body = bodies.take(`${p.key}/${p.seq}`, p.chunks);
			const report: unknown = body === undefined ? undefined : JSON.parse(body);
			if (!validOwn(report)) {
				warn("chunks", "ue.radar chunked report incomplete or invalid, dropped", { key: p.key, seq: p.seq });
				return; // the controller sees the next change as a gap and asks for the full own (plan ruling 7)
			}
			up("ue.radar.own")(report);
		}),
		"ue.radar.ask": on(KeyOnly, up("ue.radar.ask")),
		"ue.radar.unhost": on(KeyOnly, up("ue.radar.unhost")),
	};
	function attach(bridge: Bridge) {
		instance.handle(RadarDownEvent, async (event: RadarDownEvent) => {
			bridge.send(event.kind, event.payload as object);
		});
	}
	return { handlers, attach };
}
