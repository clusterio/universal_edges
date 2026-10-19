import { test } from "node:test";
import assert from "node:assert/strict";
import type { NetT, TargetsT } from "../../power/contracts.js";
import { CAP_MAX } from "../../power/solve.js";
import { B_MAX, B_MIN, PowerHub, STALE_MS } from "../../power/hub.js";

type Flows = { so: number; po: number; se: number; to: number; pd: number; sd: number; td: number };
const F0: Flows = { so: 0, po: 0, se: 0, to: 0, pd: 0, sd: 0, td: 0 };
type L = [string, number, number];
/** A reported network: flows over F0 (kW), stock a of capacity c (kJ), its links [key, sent, got]. */
const net = (f: Partial<Flows>, a: number, c: number, ...l: L[]): NetT => ({ a, c, f: { ...F0, ...f }, l });
/** A network at its stock target: a = H·c, c = 20,000 kJ. */
const at = (f: Partial<Flows>, ...l: L[]) => net(f, 10_000, 20_000, ...l);
const near = (got: number, want: number, what: string) => {
	assert.ok(Math.abs(got - want) < 1e-6, `${what}: ${got}, want ${want}`);
};

/** A hub on a clock; round(reports) reports each tile's nets now, runs a round and returns what each tile was sent. */
function hub() {
	const clock = { t: 0 };
	let sent = new Map<number, TargetsT["l"]>();
	const h = new PowerHub({ send: (id, targets) => { sent.set(id, targets.l); }, now: () => clock.t });
	const round = (reports: Record<number, NetT[]> = {}) => {
		for (const [id, nets] of Object.entries(reports)) {
			h.report(Number(id), { nets });
		}
		sent = new Map();
		h.round();
		return sent;
	};
	return { h, clock, round };
}

test("no reports: a round sends nothing", () => {
	assert.equal(hub().round().size, 0);
});

test("a pair: the exporter sends the importer's load each second, in secondary_input at y / sq; the importer takes " +
	"the marginal class at −y / u_m; buffers 8 × the amount (§8.2–§8.5)", () => {
	const out = hub().round({ 1: [at({ se: 30_000 }, ["e1/1", 0, 0])], 2: [at({ sd: 20_000 }, ["e1/1", 0, 0])] });
	const a = out.get(1)!["e1/1"];
	const b = out.get(2)!["e1/1"];
	assert.deepEqual({ ...a, k: 0 }, { n: 20_000, b: 160_000, m: "secondary_input", k: 0 });
	near(a.k, 20_000, "the export's cap");
	assert.deepEqual({ ...b, k: 0 }, { n: 0, b: 160_000, m: "secondary_output", k: 0 });
	assert.equal(b.k, CAP_MAX, "the import has nothing of its own: the cap is CAP_MAX (2026-10-20 burst headroom)");
});

test("an importing pool with no offers and no tertiary demand gets the cap CAP_MAX over its links; any own offer or " +
	"td keeps −y / u_m (§8.3, 2026-10-20 burst headroom)", () => {
	const imp = (f: Partial<Flows>) => {
		const out = hub().round({ 1: [at({ se: 30_000 }, ["e1/1", 0, 0])], 2: [at(f, ["e1/1", 0, 0])] });
		return out.get(2)!["e1/1"];
	};
	assert.equal(imp({ sd: 20_000 }).k, CAP_MAX, "nothing of its own");
	assert.equal(imp({ sd: 20_000 }).m, "secondary_output", "the class is unchanged");
	near(imp({ sd: 20_000, so: 1 }).k, 30_000, "a 1 kW solar offer");
	near(imp({ sd: 20_000, td: 100 }).k, 30_000, "an accumulator charging");
	const two = hub().round({ 1: [at({ se: 30_000 }, ["e1/1", 0, 0])],
		2: [at({ sd: 20_000 }, ["e1/1", 0, 0], ["e1/2", 0, 0])] }).get(2)!;
	assert.equal(two["e1/1"].k + two["e1/2"].k, CAP_MAX, "split over its links as today");
});

test("a chain: a relay forwards in the same round; a loop: breadth-first from the lowest instance id, links in key " +
	"order, the link off the tree carries nothing; report order doesn't matter (§8.4)", () => {
	const chain = hub().round({ 1: [at({ se: 50_000 }, ["e1/1", 0, 0])], 2: [at({}, ["e1/1", 0, 0], ["e2/1", 0, 0])],
		3: [at({ sd: 30_000 }, ["e2/1", 0, 0])] });
	assert.equal(chain.get(1)!["e1/1"].n, 30_000);
	assert.equal(chain.get(2)!["e2/1"].n, 30_000, "the relay forwards without waiting for its delivery");
	assert.equal(chain.get(2)!["e1/1"].n, 0);
	assert.equal(chain.get(2)!["e1/1"].m, "secondary_output", "the relay's y is 0: the marginal class");
	assert.equal(chain.get(2)!["e1/1"].k + chain.get(2)!["e2/1"].k, CAP_MAX,
		"a relay has nothing of its own: CAP_MAX (2026-10-20)");
	const loop = {
		1: [at({ se: 50_000 }, ["e1/1", 0, 0], ["e3/1", 0, 0])],
		2: [at({}, ["e1/1", 0, 0], ["e2/1", 0, 0])],
		3: [at({ sd: 30_000 }, ["e2/1", 0, 0], ["e3/1", 0, 0])],
	};
	const one = hub().round(loop);
	assert.equal(one.get(1)!["e3/1"].n, 30_000, "1 reaches 3 directly: e3/1 is on the tree");
	assert.equal(one.get(1)!["e1/1"].n, 0, "2 needs nothing");
	assert.equal(one.get(2)!["e2/1"].n, 0, "e2/1 is off the tree");
	assert.equal(one.get(3)!["e2/1"].n, 0);
	// Object.entries walks numeric keys in ascending order, so report one by one to reverse the hub's order
	const reversed = hub();
	for (const id of [3, 2, 1] as const) {
		reversed.h.report(id, { nets: loop[id] });
	}
	assert.deepEqual(reversed.round(), one, "the same targets in any report order");
});

test("parallel links split the tree edge's amount equally, floored, and the pool's cap by their equal buffers (§8.3, " +
	"§8.4)", () => {
	const out = hub().round({ 1: [at({ se: 40_000 }, ["e1/1", 0, 0], ["e1/2", 0, 0])],
		2: [at({ sd: 30_001 }, ["e1/1", 0, 0], ["e1/2", 0, 0])] });
	assert.equal(out.get(1)!["e1/1"].n, 15_000);
	assert.equal(out.get(1)!["e1/2"].n, 15_000);
	near(out.get(1)!["e1/1"].k, 15_000.5, "half the export's cap");
});

test("a pool's cap is split over its links in proportion to their buffers, summing to the pool's cap (Task 5 ruling " +
	"F1)", () => {
	// 1 exports 25 MW: 20 MW to 2 and 5 MW to 3, so its links' buffers are 8 × 20 and 8 × 5 MW (4 : 1)
	const out = hub().round({ 1: [at({ se: 30_000 }, ["e1/1", 0, 0], ["e2/1", 0, 0])],
		2: [at({ sd: 20_000 }, ["e1/1", 0, 0])], 3: [at({ sd: 5_000 }, ["e2/1", 0, 0])] });
	const [x, y] = [out.get(1)!["e1/1"], out.get(1)!["e2/1"]];
	assert.deepEqual([x.b, y.b], [160_000, 40_000]);
	near(x.k, 20_000, "4/5 of the export's 25 MW");
	near(y.k, 5_000, "1/5 of it");
	near(x.k + y.k, 25_000, "the pool's cap");
});

test("settle: a send in transit counts at its receiver; a send credited after the sender's report comes off the " +
	"sender; a stock refill is no peak (§8.1.2, §8.5)", () => {
	// in transit: 1 sent 500 and 2 got 300; 2 at 9,800 holds its target once the 200 land, 1's stock above target stays
	let out = hub().round({ 1: [net({}, 11_000, 20_000, ["e1/1", 500, 0])],
		2: [net({}, 9_800, 20_000, ["e1/1", 0, 300])] });
	assert.equal(out.get(1)!["e1/1"].n, 0, "nothing for 2: at its target with the transit");
	assert.equal(out.get(2)!["e1/1"].n, 0);
	// credited after 1's report: 1 said sent 300, 2 got 700, so 1 holds 400 less than it said; 2 refills an eighth
	out = hub().round({ 1: [net({}, 10_000, 20_000, ["e1/1", 300, 0])],
		2: [net({}, 11_000, 20_000, ["e1/1", 0, 700])] });
	assert.equal(out.get(1)!["e1/1"].n, 0);
	assert.equal(out.get(2)!["e1/1"].n, 50, "2's stock above target refills 1's 400 below, an eighth a second");
	assert.equal(out.get(2)!["e1/1"].b, B_MIN, "the refill has no network part: it sizes no buffer (plan review S2)");
});

test("a relay owing more than it holds (a < 0) is a pool below target: its partner refills it (Review Focus 5)", () => {
	const out = hub().round({ 1: [at({ se: 10_000 }, ["e1/1", 0, 0])], 2: [net({}, -5_000, 20_000, ["e1/1", 0, 0])] });
	assert.equal(out.get(1)!["e1/1"].n, 1_875, "15,000 below target, an eighth of it a second (τ 8)");
});

test("targets are a rate: a repeated stale report gives the same amount, and so does the next report once the send " +
	"shows (§8.4.2, plan review B1)", () => {
	const { round } = hub();
	// both pools at their target with the 160,000 kJ buffers the link is assigned (8 × 20 MW)
	const full = (f: Partial<Flows>, ...l: L[]) => net(f, 80_000, 160_000, ...l);
	const reports = { 1: [full({ se: 30_000 }, ["e1/1", 0, 0])], 2: [full({ sd: 20_000 }, ["e1/1", 0, 0])] };
	assert.equal(round(reports).get(1)!["e1/1"].n, 20_000);
	assert.equal(round(reports).get(1)!["e1/1"].n, 20_000, "the same reports: the same amount, not twice it");
	const next = round({ 1: [full({ se: 30_000 }, ["e1/1", 20_000, 0])],
		2: [full({ sd: 20_000 }, ["e1/1", 0, 20_000])] });
	assert.equal(next.get(1)!["e1/1"].n, 20_000, "the next second's amount, whatever sent and got say");
});

test("a pool's c is at least the buffers its links were assigned last round: the report lags the buffer write, and " +
	"energy in flight isn't read against the old c (Task 5 ruling C)", () => {
	const { round } = hub();
	// 2.5 MW from 1 to 2: the link is assigned 8 × 2,500 = 20,000 kJ on both sides
	const pair = (c2: number) => ({ 1: [at({ se: 10_000 }, ["e1/1", 0, 0])],
		2: [net({ sd: 2_500 }, 10_000, c2, ["e1/1", 0, 0])] });
	assert.equal(round(pair(20_000)).get(1)!["e1/1"].b, 20_000);
	// 2 still reports its old 10,000 kJ: read as 20,000, its 10,000 kJ is at target, not 5,000 above it (E 625 kW)
	assert.equal(round(pair(10_000)).get(1)!["e1/1"].n, 2_500, "the load, no E: 2 is treated as c = 20,000");
	// a pool reporting more than it was assigned keeps its own c: 2 at 10,000 of 40,000 is 10,000 below target
	assert.equal(round(pair(40_000)).get(1)!["e1/1"].n, 2_500 + 1_250, "the load and R = 10,000 / 8");
});

test("a key reported once, or whose partner's report is stale or dropped, sends nothing and its pool, in no group, " +
	"gets no m; a stale tile is sent nothing (§8.1, §8)", () => {
	const { h, clock, round } = hub();
	let out = round({ 1: [at({ se: 30_000 }, ["e1/1", 7, 0])] });
	assert.deepEqual(out.get(1), { "e1/1": { n: 0, b: B_MIN, k: 0 } }, "one-sided");
	h.report(2, { nets: [at({ sd: 20_000 }, ["e1/1", 0, 7])] });
	clock.t = STALE_MS + 1;
	out = round({ 1: [at({ se: 30_000 }, ["e1/1", 7, 0])] });
	assert.deepEqual(out.get(1), { "e1/1": { n: 0, b: B_MIN, k: 0 } }, "2's report is over 5 s old");
	assert.equal(out.has(2), false, "a stale tile gets no message");
	out = round({ 2: [at({ sd: 20_000 }, ["e1/1", 0, 7])] });
	assert.equal(out.get(1)!["e1/1"].n, 20_000, "fresh again: live");
	h.drop(2);
	out = round({ 1: [at({ se: 30_000 }, ["e1/1", 7, 0])] });
	assert.deepEqual(out.get(1), { "e1/1": { n: 0, b: 160_000, k: 0 } }, "dropped: no send, no m; the peak still held");
});

test("buffers: 8 × the largest network amount over five one-minute maxima, both sides, within [10 MJ, 10 GJ] " +
	"(§8.5, D37, plan review B5)", () => {
	const { clock, round } = hub();
	const pair = (load: number) => ({
		1: [at({ se: 10_000_000 }, ["e1/1", 0, 0])],
		2: [at({ sd: load }, ["e1/1", 0, 0])],
	});
	// a 28 MW step, then 20 MW bursts every 40 s and 1 MW between, a round every 10 s: 8 × 28 MW until five minutes
	// after the 28, then 8 × 20 MW, never B_MIN
	for (let s = 0; s <= 400; s += 10) {
		clock.t = s * 1000;
		const out = round(pair(s === 0 ? 28_000 : 1_000 + 19_000 * Number(s % 40 === 0)));
		const want = s < 300 ? 224_000 : 160_000;
		assert.equal(out.get(1)!["e1/1"].b, want, `at ${s} s`);
		assert.equal(out.get(2)!["e1/1"].b, want, `both sides, at ${s} s`);
	}
	clock.t = 1_000_000;
	assert.equal(round(pair(5_000_000)).get(1)!["e1/1"].b, B_MAX, "40 GJ, at most 10 GJ");
	clock.t = 1_400_000;
	assert.equal(round(pair(1_000)).get(1)!["e1/1"].b, B_MIN, "five minutes on: 8 MJ, at least 10 MJ");
});
