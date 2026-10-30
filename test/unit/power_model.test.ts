import { test } from "node:test";
import assert from "node:assert/strict";
import { appendFileSync } from "node:fs";
import { B_FACTOR, B_MIN, type Knobs } from "../../power/hub.js";
import { World, type NetSpec } from "./power_world.js";

// The power hub's model gates (power hub spec §3, §11.2; plan Task 5): every scenario at every delay and two seeds of
// poll phases, each §3 point a numeric gate. POWER_MODEL_OUT=<file> appends each run's numbers as a JSON line, and
// POWER_MODEL_KNOBS='{"h":…,"tau":…,"factor":…}' tries other knobs (the stop rule: factor × h / tau ≤ 0.5).

const KNOBS: Partial<Knobs> = JSON.parse(process.env.POWER_MODEL_KNOBS ?? "{}");
const FACTOR = KNOBS.factor ?? B_FACTOR;
const DELAYS = [1, 2, 10, 30];
const SEEDS = [1, 2];

type Layout = { name: string; size: number; links: [number, number][]; far: number };
const chain = (k: number): Layout => ({ name: `chain${k}`, size: k, far: k - 1,
	links: Array.from({ length: k - 1 }, (_, i): [number, number] => [i, i + 1]) });
/** The grid's (r, c) as a network index. */
const at = (r: number, c: number) => r * 5 + c;
const grid5: Layout = { name: "grid5", size: 25, far: at(4, 4), links: [] };
for (let r = 0; r < 5; r++) {
	for (let c = 0; c < 5; c++) {
		if (c < 4) {
			grid5.links.push([at(r, c), at(r, c + 1)]);
		}
		if (r < 4) {
			grid5.links.push([at(r, c), at(r + 1, c)]);
		}
	}
}
const chain6 = chain(6);
const chain20 = chain(20);

type Scenario = {
	name: string;
	seconds: number;
	layouts: Layout[];
	/** The networks, by index; unset ones are empty relays. */
	nets(l: Layout): Record<number, NetSpec>;
	/**
	 * reach: the far load's changes (s); the first, a step bigger than any in the last 5 minutes, gets 360 ticks
	 * (Task 5 ruling 6: the far pool lives lump to lump until its stock refills), the rest 180.
	 */
	changes?: number[];
	/**
	 * The changes in load or generation (s), 0 when unset: priority, fuel, brownouts, smooth and steady count from
	 * 30 s after the last one (once settled).
	 */
	quiet?: number[];
	/** Called before each tick (S7's deactivation and removal). */
	events?(w: World): void;
};

const on = (from: number, to: number, kw: number, base = 0) => (s: number) => (s >= from && s < to ? kw : base);
/** S1's far load: 1 MW, 20 MW from 60 to 120 s, then 20 MW bursts of 10 s every 40 s from 160 s. */
const s1Load = (s: number) => ((s >= 60 && s < 120) || (s >= 160 && (s - 160) % 40 < 10) ? 20_000 : 1_000);
const s1Changes = [60, 120];
for (let s = 160; s < 600; s += 40) {
	s1Changes.push(s, s + 10);
}
/** S6's far load: 1 MW, 28 MW from 30 to 40 s, then 20 MW bursts of 10 s every 270 s from 300 s. */
function s6Load(s: number) {
	if (s >= 30 && s < 40) {
		return 28_000;
	}
	return [300, 570, 840].some(b => s >= b && s < b + 10) ? 20_000 : 1_000;
}

/**
 * One link is removed, once: of the links given (index i, sent from network i), the first whose sending end has an
 * offer in flight (and, with owing, owes).
 */
function removeOnce(w: World, links: number[], owing: boolean) {
	for (const i of w.removals.length === 0 ? links : []) {
		const e = w.end(i, i);
		if (e.sent > e.partner.got && (!owing || e.owe > 0)) {
			w.remove(i);
			return;
		}
	}
}

const S: Record<string, Scenario> = {
	S1: { name: "S1 step and bursts", seconds: 600, layouts: [chain6, chain20, grid5], changes: s1Changes,
		nets: l => ({ 0: { steam: 30_000 }, [l.far]: { load: s1Load } }) },
	S2: { name: "S2 fuel shared", seconds: 180, layouts: [chain6, grid5],
		nets: l => (l === chain6 ? { 0: { steam: 15_000 }, 3: { steam: 15_000 }, 5: { load: () => 20_000 } }
			: { 0: { steam: 15_000 }, [at(2, 3)]: { steam: 15_000 }, [l.far]: { load: () => 20_000 } }) },
	S3: { name: "S3 priority", seconds: 180, layouts: [chain6],
		nets: () => ({ 0: { solar: () => 20_000 }, 3: { steam: 20_000 }, 5: { load: () => 15_000 } }) },
	S4: { name: "S4 a night", seconds: 400, layouts: [chain6], quiet: [0, 200],
		nets: () => ({ 0: { solar: on(0, 200, 30_000) }, 2: { steam: 10_000 }, 1: { acc: 100, accEmpty: true },
			3: { acc: 100, accEmpty: true }, 5: { acc: 100, accEmpty: true, load: () => 15_000 } }) },
	S5: { name: "S5 short", seconds: 120, layouts: [chain6, grid5],
		nets: l => (l === chain6 ? { 0: { steam: 10_000 }, 2: { load: () => 8_000 }, 5: { load: () => 8_000 } }
			: { 0: { steam: 10_000 }, [at(2, 2)]: { load: () => 8_000 }, [l.far]: { load: () => 8_000 } }) },
	S6: { name: "S6 bursts after a bigger step", seconds: 900, layouts: [chain6],
		changes: [30, 40, 300, 310, 570, 580, 840, 850],
		nets: () => ({ 0: { steam: 40_000 }, 5: { load: s6Load } }) },
	// The far tile has no entities of its own, so its import cap must not hold a burst to its share (spec §8.3).
	// Load: 340 kW, 1 MW for 2 of every 20 ticks (average 400 kW).
	S8: { name: "S8 far tile with nothing of its own", seconds: 90, layouts: [chain6], changes: [24],
		nets: () => ({ 0: { steam: 2_000, acc: 20 }, 5: { load: (_, t) => (t % 20 < 2 ? 1_000 : 340) } }) },
	S7: { name: "S7 deactivated and removed", seconds: 180, layouts: [chain6],
		nets: () => ({ 0: { steam: 15_000 }, 3: { steam: 15_000 }, 5: { load: () => 20_000 } }),
		events: w => {
			const t = w.tick + 1;
			if (t === 60 * 60 || t === 80 * 60) {
				w.deactivate(w.end(2, 3), t === 60 * 60); // tile 4's end of link 3–4, for 20 s
			}
			removeOnce(w, t >= 120 * 60 ? [4] : [], false); // link 5–6, its tile-5 end's offer in flight
		} },
	// A relay owes only in the cold start, and only where its poll comes before its credit: from about 15 s its stock
	// covers its sends (Task 5's report), so S7's removal at 120 s owes nothing. This one removes the first downstream
	// link whose relay end owes with an offer in flight.
	S7b: { name: "S7b removed while owing", seconds: 180, layouts: [chain6],
		nets: () => ({ 0: { steam: 15_000 }, 3: { steam: 15_000 }, 5: { load: () => 20_000 } }),
		events: w => removeOnce(w, [1, 2, 3, 4], true) },
};

type Stats = {
	tag: string;
	/** reach: the far load's lowest satisfaction in the gated windows, and its tick. */
	reach: number;
	reachAt: number;
	/** reach: ticks below 0.999 in the gated windows. */
	short: number;
	/**
	 * priority: the highest steam usage while solar has > 2 % spare; the most an accumulator bank discharges (kW)
	 * while any generator has > 2 % spare; S4's day: ticks with an accumulator neither full nor charging while solar
	 * has spare.
	 */
	secondary: number;
	discharge: number;
	day: number;
	/** fuel shared: the widest gap between a steam tile's usage and the group's, per second. */
	fuel: number;
	/** brownouts shared: the widest spread of the loaded tiles' satisfaction, per second. */
	brownout: number;
	/** conserved: the largest |ledger| (J) and |ledger| / energy moved. */
	ledgerJ: number;
	ledger: number;
	/** smooth: a steam generator's largest deviation from its window's mean, as a fraction of it. */
	smooth: number;
	/** bounded: the largest buffer (kJ), and in S1 after 30 s. */
	buffer: number;
	bufferLate: number;
	flips: number;
	/** S7: ticks the deactivated end's interface wasn't in the built state while deactivated; the removal. */
	notBuilt: number;
	removal?: World["removals"][number];
	moved: number;
};

const runs = new Map<string, Stats[]>();
function results(name: string): Stats[] {
	let r = runs.get(name);
	if (!r) {
		r = [];
		for (const l of S[name].layouts) {
			for (const delay of DELAYS) {
				for (const seed of SEEDS) {
					r.push(simulate(name, l, delay, seed));
				}
			}
		}
		runs.set(name, r);
	}
	return r;
}

function simulate(name: string, l: Layout, delay: number, seed: number): Stats {
	const sc = S[name];
	const specs = sc.nets(l);
	const w = new World({ nets: Array.from({ length: l.size }, (_, i) => specs[i] ?? {}), links: l.links, delay, seed,
		knobs: KNOBS });
	const st: Stats = { tag: `${name} ${l.name} delay ${delay} seed ${seed}`, reach: 1, reachAt: -1, short: 0,
		secondary: 0, discharge: 0, day: 0, fuel: 0, brownout: 0, ledgerJ: 0, ledger: 0, smooth: 0, buffer: 0,
		bufferLate: 0, flips: 0, notBuilt: 0, moved: 0 };
	const quiet = (sc.quiet ?? [0]).map(c => c * 60);
	const settled = (t: number) => t >= Math.max(...quiet.filter(c => c <= t)) + 30 * 60;
	const steam = w.nets.filter(n => (n.spec.steam ?? 0) > 0);
	const loaded = w.nets.filter(n => n.spec.load);
	const accs = w.nets.filter(n => n.accC > 0);
	const far = w.nets[l.far];
	const off = name === "S7" ? w.end(2, 3) : undefined;
	// reach: [from, to) tick windows where the far load must be met
	const gated = (sc.changes ?? []).map((c, i, all) => [c * 60 + (i === 0 ? 360 : 180),
		(all[i + 1] ?? sc.seconds) * 60]);
	const reach = (t: number) => {
		if (gated.some(([a, b]) => t >= a && t < b)) {
			st.short += far.u.sq < 0.999 ? 1 : 0;
			if (far.u.sq < st.reach) {
				st.reach = far.u.sq;
				st.reachAt = t;
			}
		}
	};
	const priority = (t: number) => {
		const solarSpare = w.nets.some(n => n.solarOffer > 0 && n.solar < 0.98 * n.solarOffer);
		if (solarSpare) {
			st.secondary = Math.max(st.secondary, ...steam.map(n => n.steam / n.steamOffer));
		}
		if (solarSpare || steam.some(n => n.steam < 0.98 * n.steamOffer)) {
			st.discharge = Math.max(st.discharge, ...accs.map(n => n.acc));
		}
		if (name === "S4" && t < 200 * 60 && solarSpare) {
			st.day += accs.some(n => n.accC - n.accE >= 1 && n.acc >= 0) ? 1 : 0;
		}
	};
	// smooth: a window is the ticks between two arrivals of its tile's targets (plan review S7)
	const win = steam.map((): number[] | undefined => undefined);
	const smooth = (t: number) => steam.forEach((n, i) => {
		const x = win[i];
		if (n.arrived === t) {
			if (x && settled(t - x.length)) {
				const mean = x.reduce((a, b) => a + b, 0) / x.length;
				const dev = Math.max(...x.map(v => Math.abs(v - mean)));
				st.smooth = Math.max(st.smooth, mean > 0 ? dev / mean : dev);
			}
			win[i] = [];
		}
		win[i]?.push(n.steam);
	});
	// fuel shared and brownouts shared, per second
	const second = { out: steam.map(() => 0), sq: loaded.map(() => 0) };
	const perSecond = (t: number) => {
		steam.forEach((n, i) => { second.out[i] += n.steam; });
		loaded.forEach((n, i) => { second.sq[i] += n.u.sq; });
		if (t % 60 !== 59) {
			return;
		}
		if (settled(t - 59)) {
			const group = second.out.reduce((a, b) => a + b, 0) / steam.reduce((a, n) => a + 60 * n.steamOffer, 0);
			steam.forEach((n, i) => {
				st.fuel = Math.max(st.fuel, Math.abs(second.out[i] / (60 * n.steamOffer) - group));
			});
			st.brownout = Math.max(st.brownout, (Math.max(...second.sq) - Math.min(...second.sq)) / 60);
		}
		second.out.fill(0);
		second.sq.fill(0);
	};
	// conserved, bounded, and S7's deactivated end
	const every = (t: number) => {
		const L = Math.abs(w.ledger());
		st.ledgerJ = Math.max(st.ledgerJ, L);
		st.ledger = Math.max(st.ledger, L / Math.max(w.moved, 1));
		for (const n of w.nets) {
			for (const e of n.ends) {
				st.buffer = Math.max(st.buffer, e.buf / 1000);
				st.bufferLate = t >= 30 * 60 ? Math.max(st.bufferLate, e.buf / 1000) : 0;
			}
		}
		st.notBuilt += off && t >= 60 * 60 && t < 80 * 60 && off.mode !== "built" ? 1 : 0;
	};
	for (let t = 0; t < sc.seconds * 60; t++) {
		sc.events?.(w);
		w.step();
		reach(t);
		if (settled(t)) {
			priority(t);
		}
		smooth(t);
		perSecond(t);
		every(t);
	}
	st.flips = w.flips.filter(f => settled(f.tick)).length;
	st.removal = w.removals[0];
	st.moved = w.moved;
	if (process.env.POWER_MODEL_OUT) {
		// eslint-disable-next-line node/no-sync
		appendFileSync(process.env.POWER_MODEL_OUT, `${JSON.stringify(st)}\n`);
	}
	return st;
}

/** Every run's failure of a gate, as one assertion listing them all. */
function gate(name: string, ok: (s: Stats) => boolean, show: (s: Stats) => string) {
	const bad = results(name).filter(s => !ok(s)).map(s => `${s.tag}: ${show(s)}`);
	assert.deepEqual(bad, [], `${S[name].name}`);
}

test("self-check: one network, steam 1 MW, load 500 kW, no links: the steam gives 500 kW every tick, ledger 0", () => {
	const w = new World({ nets: [{ steam: 1_000, load: () => 500 }], links: [], delay: 1, seed: 1 });
	for (let t = 0; t < 600; t++) {
		w.step();
		assert.ok(Math.abs(w.nets[0].steam - 500) < 1e-9, `tick ${t}: steam ${w.nets[0].steam}`);
		assert.equal(w.ledger(), 0, `tick ${t}`);
	}
});

const conserved = (s: Stats) => s.ledger <= 1e-6;
const conservedShow = (s: Stats) => `|ledger| ${s.ledgerJ} J, ${s.ledger} of ${s.moved} J moved`;
const bounded = (s: Stats) => s.buffer <= 10_000_000;

for (const name of Object.keys(S)) {
	test(`${S[name].name}: conserved (|ledger| ≤ 1e-6 × moved) and bounded (buffers ≤ 10 GJ), every tick`, () => {
		gate(name, conserved, conservedShow);
		gate(name, bounded, s => `buffer ${s.buffer} kJ`);
	});
}

for (const name of ["S1", "S6", "S8"]) {
	test(`${S[name].name}: reach, the far load met (≥ 0.999) from 180 ticks after each change (360 after the first)`,
		() => gate(name, s => s.reach >= 0.999,
			s => `satisfaction ${s.reach} at tick ${s.reachAt}, ${s.short} ticks short`));
}

test("S1 step and bursts: bounded, no buffer above max(B_MIN, 1.1 × factor × 20 MW) after the cold start", () => {
	const cap = Math.max(B_MIN, 1.1 * FACTOR * 20_000);
	gate("S1", s => s.bufferLate <= cap, s => `buffer ${s.bufferLate} kJ, cap ${cap}`);
});

for (const name of ["S3", "S4"]) {
	test(`${S[name].name}: priority, no steam above 2 % or accumulator discharging while solar (any generator) has ` +
		"spare", () => {
		gate(name, s => s.secondary <= 0.02, s => `steam usage ${s.secondary} while solar has spare`);
		gate(name, s => s.discharge <= 1,
			s => `an accumulator discharging ${s.discharge} kW while a generator has spare`);
		gate(name, s => s.day === 0, s => `${s.day} day ticks with an accumulator neither full nor charging`);
	});
}

test("S2 fuel shared: each steam tile's usage within 0.02 of the group's, per second", () => {
	gate("S2", s => s.fuel <= 0.02, s => `gap ${s.fuel}`);
});

test("S2 fuel shared: smooth, each steam generator within 1 % of its window's mean", () => {
	gate("S2", s => s.smooth <= 0.01, s => `deviation ${s.smooth}`);
});

for (const name of ["S2", "S3"]) {
	test(`${S[name].name}: steady, no link's direction flips once settled`, () => {
		gate(name, s => s.flips === 0, s => `${s.flips} flips`);
	});
}

test("S5 short: brownouts shared, the loaded tiles' satisfaction within 0.03, per second", () => {
	gate("S5", s => s.brownout <= 0.03, s => `spread ${s.brownout}`);
});

test("S7: the deactivated end is in the built state throughout; the removed link (an offer in flight) and the one " +
	"removed while owing: the owe is paid, cancelled by the refund or counted in lost", () => {
	gate("S7", s => s.notBuilt === 0, s => `${s.notBuilt} ticks out of the built state`);
	for (const name of ["S7", "S7b"]) {
		gate(name, s => s.removal !== undefined && s.removal.lane > 0 && (name === "S7" || s.removal.owe > 0),
			s => `removal ${JSON.stringify(s.removal)}`);
		gate(name, s => Math.abs(s.removal!.owe - s.removal!.paid - s.removal!.cancelled - s.removal!.unpaid) < 1e-6,
			s => `removal ${JSON.stringify(s.removal)}`);
	}
});
