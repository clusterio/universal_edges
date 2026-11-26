import { test } from "node:test";
import assert from "node:assert/strict";
import * as lib from "@clusterio/lib";
import type { NetT } from "../../power/contracts.js";
import { PowerHub, STALE_MS } from "../../power/hub.js";
import { powerMetrics } from "../../power/controller.js";

const F0 = { so: 0, po: 0, se: 0, to: 0, pd: 0, sd: 0, td: 0 };
const net = (f: Partial<NetT["f"]>, a: number, c: number, ...l: [string, number, number][]): NetT => (
	{ a, c, f: { ...F0, ...f }, l }
);

/** The power series on the default registry, as "name{labels} value" lines, sorted. */
async function scrape(): Promise<string[]> {
	return (await lib.exposition()).split("\n").filter(l => l.startsWith("clusterio_universal_edges_power_")).sort();
}

test("issue #34: the gauges carry a tile's report summed over its networks and the hub's send amounts; a new report " +
	"replaces them; a stale or dropped tile's series go", async () => {
	const clock = { t: 0 };
	const hub = new PowerHub({ send: () => {}, now: () => clock.t });
	hub.report(1, { nets: [
		net({ se: 30_000 }, 9_000, 20_000, ["e1/1", 500, 7]),
		net({ se: 1_000, td: 50 }, -100, 5_000, ["e9/1", 0, 0]),
	] });
	hub.report(2, { nets: [net({ sd: 20_000 }, 10_000, 20_000, ["e1/1", 7, 400])] });
	hub.round();
	powerMetrics(hub, clock.t);
	const lines = await scrape();
	const has = (line: string) => assert.ok(lines.includes(line), `${line} in\n${lines.join("\n")}`);
	has('clusterio_universal_edges_power_stock_kj{instance_id="1"} 8900');
	has('clusterio_universal_edges_power_capacity_kj{instance_id="1"} 25000');
	has('clusterio_universal_edges_power_flow_kw{instance_id="1",class="secondary_output"} 31000');
	has('clusterio_universal_edges_power_flow_kw{instance_id="1",class="tertiary_demand"} 50');
	has('clusterio_universal_edges_power_flow_kw{instance_id="2",class="secondary_demand"} 20000');
	has('clusterio_universal_edges_power_link_energy_kj{instance_id="1",link="e1/1",direction="sent"} 500');
	has('clusterio_universal_edges_power_link_energy_kj{instance_id="2",link="e1/1",direction="got"} 400');
	const n = hub.sent.get(1)!["e1/1"].n;
	assert.ok(n > 0, "tile 1 exports over e1/1");
	has(`clusterio_universal_edges_power_link_send_kj{instance_id="1",link="e1/1"} ${n}`);
	has('clusterio_universal_edges_power_link_send_kj{instance_id="2",link="e1/1"} 0');
	has('clusterio_universal_edges_power_link_send_kj{instance_id="1",link="e9/1"} 0');
	assert.equal(lines.filter(l => l.includes('class="')).length, 14, "seven classes for each tile");

	clock.t = 1000;
	hub.report(1, { nets: [net({ se: 25_000 }, 9_500, 20_000, ["e1/1", 20_500, 7])] });
	hub.round();
	powerMetrics(hub, clock.t);
	const next = await scrape();
	assert.ok(next.includes('clusterio_universal_edges_power_stock_kj{instance_id="1"} 9500'), "the new report");
	assert.ok(next.includes(
		'clusterio_universal_edges_power_link_energy_kj{instance_id="1",link="e1/1",direction="sent"} 20500'));
	assert.ok(!next.some(l => l.includes('link="e9/1"')), "a link the tile no longer reports goes");

	clock.t = STALE_MS + 1; // tile 2 last reported at 0
	hub.round();
	powerMetrics(hub, clock.t);
	const stale = await scrape();
	assert.ok(!stale.some(l => l.includes('instance_id="2"')), "a stale tile's series go");
	assert.ok(stale.some(l => l.includes('instance_id="1"')));

	hub.drop(1);
	powerMetrics(hub, clock.t);
	assert.deepEqual(await scrape(), [], "a stopped tile's series go");
});
