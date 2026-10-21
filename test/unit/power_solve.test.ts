import { test } from "node:test";
import assert from "node:assert/strict";
import { CAP_MAX, cls, H, marginal, solve, type Flows, type Pool, type Usage } from "../../power/solve.js";

const F0: Flows = { so: 0, po: 0, se: 0, to: 0, pd: 0, sd: 0, td: 0 };
/** One network as the game sees it (every entity in its class, UE's interfaces included), or a pool with a stock. */
const pool = (f: Partial<Flows>, a = 0, c = 0): Pool => ({ ...F0, ...f, a, c });
const near = (got: number, want: number, what: string, tol = 1e-6) => {
	assert.ok(Math.abs(got - want) <= tol, `${what}: ${got}, want ${want}`);
};
const sumX = (shares: { x: number }[]) => shares.reduce((s, p) => s + p.x, 0);

test("one network reproduces spike 43's probes D, G, H, I and M", () => {
	// D: steam 900, an interface in primary_output capped 200, load 500: interface 200, engine 300 (usage 0.333)
	let { u } = solve([pool({ po: 200, se: 900, sd: 500 })]);
	near(u.po, 1, "D primary");
	near(u.se * 900, 300, "D engine kW");
	// G: solar 600, a primary interface capped 600, steam 900, load 600: solar 1, primary 0, steam 0
	({ u } = solve([pool({ so: 600, po: 600, se: 900, sd: 600 })]));
	near(u.so, 1, "G solar");
	near(u.po, 0, "G primary");
	near(u.se, 0, "G steam");
	// H: steam 900 and a secondary_output interface capped 900, load 900: one fraction, 0.5
	({ u } = solve([pool({ se: 1800, sd: 900 })]));
	near(u.se, 0.5, "H");
	// I: steam 900 against secondary demand 4500 (run.log line 105) and tertiary demand 600300: satisfaction 0.2
	({ u } = solve([pool({ se: 900, sd: 4500, td: 600300 })]));
	near(u.sq, 0.2, "I satisfaction");
	near(u.st, 0, "I tertiary gets nothing");
	// M: steam 900, load 1200, tertiary offers 864600 (interfaces holding 4.802 and 9.603 MJ): they give the 300 short
	({ u } = solve([pool({ se: 900, sd: 1200, to: 864600, td: 935700 })]));
	near(u.se, 1, "M engine");
	near(u.to * 864600, 300, "M the shortfall only");
	near(u.to * 288120, 100, "M the 4.8 MJ interface, by its offer", 0.1);
	near(u.st, 0, "M nothing charges");
});

test("one network reproduces spike 45's P2, P3 and P5", () => {
	near(solve([pool({ se: 1200, sd: 600 })]).u.se, 0.5, "P2a: engine 450, interface 150");
	near(solve([pool({ se: 1020, sd: 600 })]).u.se * 900, 529.4, "P2b: the low interface offers 120", 0.1);
	near(solve([pool({ se: 1000, sd: 600 })]).u.se, 0.6, "P2c: capped 100");
	let { u } = solve([pool({ so: 900, se: 900, sd: 600 })]);
	near(u.so * 300, 200, "P3a: the solar interface gives 200");
	near(u.se, 0, "P3a: the engine idles");
	({ u } = solve([pool({ se: 900, to: 900, sd: 1500 })]));
	near(u.se, 1, "P3c engine");
	near(u.to * 300, 200, "P3c accumulator");
	near(u.to * 600, 400, "P3c interface");
	({ u } = solve([pool({ se: 900, to: 420, sd: 1500 })]));
	near(u.to, 1, "P3d tertiary at full");
	near(u.sq, 0.88, "P3d satisfaction");
	near(solve([pool({ se: 900, sd: 1800 })]).u.sq, 0.5, "P5a: machine 600, export 300");
	near(solve([pool({ se: 900, sd: 1500 })]).u.sq, 0.6, "P5b: machine 180, export 720");
	({ u } = solve([pool({ se: 900, to: 300, sd: 1800 })]));
	near(u.to, 1, "P5c: the accumulator feeds the export at its rate");
	near(u.sq * 1200, 800, "P5c machine");
});

test("a group: solar before steam, one usage per class, Σx = 0, each pool's exchange and send (§8.2)", () => {
	// A solar 10 MW, B steam 10 MW, C a load of 8 MW, all at their stock target (a = H·c)
	let { u, shares } = solve([pool({ so: 10_000 }, 10_000, 20_000), pool({ se: 10_000 }, 10_000, 20_000),
		pool({ sd: 8_000 }, 10_000, 20_000)]);
	near(u.so, 0.8, "solar carries the load");
	near(u.se, 0, "steam idles while solar has spare");
	near(shares[0].x, 8_000, "A sends");
	near(shares[2].y, -8_000, "C takes 8 MW from its link");
	near(sumX(shares), 0, "Σx");
	// two steam pools far apart, a 15 MW load: one usage, 0.75, so each exports 7.5 MW
	({ u, shares } = solve([pool({ se: 10_000 }, 10_000, 20_000), pool({ sd: 15_000 }, 10_000, 20_000),
		pool({ se: 10_000 }, 10_000, 20_000)]));
	near(u.se, 0.75, "one usage");
	near(shares[0].x, 7_500, "first");
	near(shares[2].x, 7_500, "second");
	near(sumX(shares), 0, "Σx");
});

test("a short group: generation at full, accumulators cover the shortfall, one satisfaction everywhere (§8.2)", () => {
	// A steam 6 MW, B a 4 MW load and 3 MW of accumulators, C an 8 MW load: V = 9 MW over 12, sq 0.75
	const { u, shares } = solve([pool({ se: 6_000 }, 10_000, 20_000),
		pool({ sd: 4_000, to: 3_000, td: 3_000 }, 10_000, 20_000),
		pool({ sd: 8_000 }, 10_000, 20_000)]);
	near(u.se, 1, "steam at full");
	near(u.to, 1, "the accumulators at their rate");
	near(u.st, 0, "nothing charges");
	near(u.sq, 0.75, "one satisfaction");
	near(shares[1].y, 0, "B's accumulators cover B's share");
	near(shares[2].y, -6_000, "C gets 6 of its 8 MW");
	near(sumX(shares), 0, "Σx");
});

test("stock terms: free generation refills a pool below target before stock above target is spent; stock is " +
	"spent before fuel (§8.2, plan review M5)", () => {
	// A holds 8,000 kJ above target (E = 1,000 kW at τ 8), B has 5 MW of solar, C is 8,000 kJ below (R = 1,000 kW); no
	// loads
	let { u, shares } = solve([pool({}, 18_000, 20_000), pool({ so: 5_000 }, 10_000, 20_000), pool({}, 2_000, 20_000)]);
	near(u.so, 0.2, "solar refills C");
	near(u.E, 0, "A's stock stays");
	near(shares[1].x, 1_000, "B sends C's 1 MW");
	near(shares[2].x, -1_000, "C takes it");
	// steam in place of the solar: A's stock refills C and the steam idles
	({ u, shares } = solve([pool({}, 18_000, 20_000), pool({ se: 5_000 }, 10_000, 20_000), pool({}, 2_000, 20_000)]));
	near(u.E, 1, "the stock refills C");
	near(u.se, 0, "no fuel burnt for it");
	near(shares[0].x, 1_000, "A sends an eighth of its 8,000 above target");
	near(sumX(shares), 0, "Σx");
	// solar refills C, and B's accumulators charging from it take their share
	({ u, shares } = solve([pool({ so: 5_000, td: 2_000 }, 10_000, 20_000), pool({}, 2_000, 20_000)]));
	near(u.st, 1, "room for both");
	near(u.so, 0.6, "3 of 5 MW: 2 MW charging, 1 MW to C");
	near(shares[0].x, 1_000, "the solar pool sends C's 1 MW");
	near(sumX(shares), 0, "Σx");
	// a relay owing more than it holds (a negative a) asks for it like any pool below target
	({ shares } = solve([pool({ se: 10_000 }, 10_000, 20_000), pool({}, -6_000, 20_000)]));
	near(shares[1].x, -2_000, "a = −6,000: 16,000 below target, an eighth of it a second");
});

test("class and cap: the marginal class, y = 0, u_m near 0, an export under sq < 1 or sq = 0, tertiary (§8.3)", () => {
	const u = (o: Partial<Usage>): Usage => ({ E: 0, so: 0, po: 0, se: 0, to: 0, sp: 1, sq: 1, st: 0, ...o });
	assert.deepEqual(marginal(u({})), { m: "solar", um: 1 }, "nothing used: solar at 1");
	assert.deepEqual(marginal(u({ so: 1, se: 0.4 })), { m: "secondary", um: 0.4 });
	assert.deepEqual(cls(0, u({ so: 1, se: 0.5 })), { mode: "secondary_output", cap: 0 });
	assert.deepEqual(cls(-100, u({ se: 1e-12 })), { mode: "secondary_output", cap: CAP_MAX });
	assert.deepEqual(cls(100, u({ se: 1, sq: 0.5 })), { mode: "secondary_input", cap: 200 });
	assert.deepEqual(cls(100, u({ se: 1, sq: 0 })), { mode: "secondary_input", cap: 100 });
	assert.deepEqual(cls(-100, u({})), { mode: "solar_output", cap: 100 });
	assert.deepEqual(cls(-300, u({ se: 1, to: 0.5 })), { mode: "tertiary_output", cap: 600 });
});

test("float residue is no class in use: solar covers the group, steam stays at 0 and solar is marginal (§8.3, " +
	"Task 5's model)", () => {
	// solar 2393 kW covers the load and the stock refill; left over after it was 2.3e-13 kW, steam's usage 7.6e-18.
	// τ 5 explicitly: the residue depends on the numbers, and at the default τ 8 this case leaves none
	const { u, shares } = solve([pool({ so: 2_393 }, 10_000, 20_000), pool({ se: 30_000 }, 10_000, 20_000),
		pool({ sd: 721.9 }, 3_626, 20_000)], H, 5);
	assert.equal(u.se, 0, "steam unused");
	assert.equal(marginal(u).m, "solar");
	assert.equal(cls(shares[2].y, u).mode, "solar_output", "the importer in solar's class, not secondary at CAP_MAX");
	near(cls(shares[2].y, u).cap, -shares[2].y / u.so, "at −y / u_so");
});
