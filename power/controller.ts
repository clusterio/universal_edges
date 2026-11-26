import * as lib from "@clusterio/lib";
import type { ControllerPluginContext } from "@clusterio/controller";
import { rateLimited } from "../runtime/index.js";
import { PowerDownEvent, PowerUpEvent, type NetT } from "./contracts.js";
import { PowerHub, STALE_MS } from "./hub.js";

/** The power hub's hook name: AsyncHook.attach throws on a second plain universal_edges one. */
const HOOK = "universal_edges:power";
/** §8: one round a second. */
export const ROUND_MS = 1000;

// issue #34: the hub's latest reports as gauges, one series per tile (instance_id), not per electric network: network
// ids change as networks join and split. Link energies are running totals that restart at 0 when a link is rebuilt, so
// they are gauges, read with deriv().
const linkEnergy = new lib.Gauge(
	"clusterio_universal_edges_power_link_energy_kj",
	"Universal Edges power: energy each link has sent and got, running totals (kJ)",
	{ labels: ["instance_id", "link", "direction"] },
);
const linkSend = new lib.Gauge(
	"clusterio_universal_edges_power_link_send_kj",
	"Universal Edges power: what the hub gave each link to send this second (kJ)",
	{ labels: ["instance_id", "link"] },
);
const flow = new lib.Gauge(
	"clusterio_universal_edges_power_flow_kw",
	"Universal Edges power: the tile's linked networks' mean flows by class, less UE's own interfaces (kW)",
	{ labels: ["instance_id", "class"] },
);
const stock = new lib.Gauge(
	"clusterio_universal_edges_power_stock_kj",
	"Universal Edges power: the tile's linked networks' stored energy less what their links owe (kJ)",
	{ labels: ["instance_id"] },
);
const capacity = new lib.Gauge(
	"clusterio_universal_edges_power_capacity_kj",
	"Universal Edges power: the tile's linked networks' storage capacity (kJ)",
	{ labels: ["instance_id"] },
);
const CLASSES: [keyof NetT["f"], string][] = [
	["so", "solar_output"], ["po", "primary_output"], ["se", "secondary_output"], ["to", "tertiary_output"],
	["pd", "primary_demand"], ["sd", "secondary_demand"], ["td", "tertiary_demand"],
];

/** Rebuilds the gauges from the hub's fresh reports and last round, so a stale or stopped tile's series go. */
export function powerMetrics(hub: PowerHub, now: number): void {
	for (const g of [linkEnergy, linkSend, flow, stock, capacity]) {
		g.clear();
	}
	for (const [id, r] of hub.reports) {
		if (now - r.at > STALE_MS) {
			continue;
		}
		const i = String(id);
		// inc, not set: a tile's networks are summed, and so is a link with both ends on the tile
		for (const n of r.nets) {
			stock.labels(i).inc(n.a);
			capacity.labels(i).inc(n.c);
			for (const [k, name] of CLASSES) {
				flow.labels(i, name).inc(n.f[k]);
			}
			for (const [key, sent, got] of n.l) {
				linkEnergy.labels(i, key, "sent").inc(sent);
				linkEnergy.labels(i, key, "got").inc(got);
			}
		}
		for (const [key, t] of Object.entries(hub.sent.get(id) ?? {})) {
			linkSend.labels(i, key).set(t.n);
		}
	}
}

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
			powerMetrics(hub, Date.now());
		} catch (err: any) {
			warn("round", "ue.power round failed", { error: err.stack ?? err.message });
		}
	}, ROUND_MS);
	controller.hooks.shutdown.attach(HOOK, async () => {
		clearInterval(timer);
	});
	return hub;
}
