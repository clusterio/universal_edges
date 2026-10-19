/**
 * The power hub's solve (power hub spec §8.2–§8.3), pure. A group of pools is solved the way the game solves
 * one electric network: one usage per producer class, one satisfaction per consumer class. On top of that,
 * each pool's stock against its target is a producer (above target) or a tertiary demand (below). Over one network
 * with no stock (a = c = 0) it is the game's own rule (plan ruling 1). Flows in kW, a and c in kJ.
 */

/** A pool's per-class numbers (§6.1): offers so, po, se, to; demands pd, sd, td. */
export type Flows = { so: number; po: number; se: number; to: number; pd: number; sd: number; td: number };
/** A pool as the solve sees it: its flows, its stock a and its capacity c. */
export type Pool = Flows & { a: number; c: number };
/** The group's usages: the stock E and each producer class; sp, sq and st, the consumer classes' satisfactions. */
export type Usage = { E: number; so: number; po: number; se: number; to: number; sp: number; sq: number; st: number };
/** Per pool: generation g, consumption w, network exchange y = g − w (positive: drawn into the pool), net send x. */
export type Share = { g: number; w: number; y: number; x: number };
export type Mode = "solar_output" | "primary_output" | "secondary_output" | "tertiary_output" | "secondary_input";

/**
 * §8.2's stock target (a fraction of c) and the seconds a stock gap closes over: calibration knobs (§8.6). τ 8 with
 * B_FACTOR 8 (Task 5's model): 4 s of a link's peak in stock covers a burst until its round's flow lands, and
 * B_FACTOR × H / τ stays at 0.5 (plan review S2).
 */
export const H = 0.5;
export const TAU = 8;
/** The interface prototype's 1 TW flow limit in kW: no cap goes above it (plan ruling 8). */
export const CAP_MAX = 1e9;

/**
 * §8.2's merit order before tertiary: solar, primary, the stock above target, then secondary. Stock is spent before
 * fuel, never instead of free generation (plan review M5).
 */
const ORDER = ["so", "po", "E", "se"] as const;

export function solve(pools: Pool[], h = H, tau = TAU): { u: Usage; shares: Share[] } {
	const E = pools.map(p => Math.max(0, p.a - h * p.c) / tau);
	const R = pools.map(p => Math.max(0, h * p.c - p.a) / tau);
	const sum = (f: (p: Pool, i: number) => number) => pools.reduce((s, p, i) => s + f(p, i), 0);
	const offer = { E: sum((_, i) => E[i]), so: sum(p => p.so), po: sum(p => p.po), se: sum(p => p.se) };
	const to = sum(p => p.to);
	const pd = sum(p => p.pd);
	const sd = sum(p => p.sd);
	const L = pd + sd;
	const G = offer.E + offer.so + offer.po + offer.se;
	const u: Usage = { E: 0, so: 0, po: 0, se: 0, to: 0, sp: 1, sq: 1, st: 0 };
	if (G >= L) {
		// enough: primary and secondary demand met; tertiary demand (accumulators, stocks below target) gets the spare
		const T = sum(p => p.td) + sum((_, i) => R[i]);
		u.st = T > 0 ? Math.min(1, (G - L) / T) : 1;
		let left = L + u.st * T;
		// what is left under a billionth of the demand is float residue (Task 5's model saw 1e-16 of it), not a class
		// in use: §8.3 would take that class as marginal and give importers a cap of CAP_MAX. Every later class gets 0.
		const residue = 1e-9 * left;
		for (const k of ORDER) {
			u[k] = offer[k] > 0 && left > residue ? Math.min(1, left / offer[k]) : 0;
			left -= u[k] * offer[k];
		}
	} else {
		// short: every producer at full, tertiary covers only the shortfall (spike 43 M), one satisfaction per class
		for (const k of ORDER) {
			u[k] = offer[k] > 0 ? 1 : 0;
		}
		u.st = 0;
		u.to = to > 0 ? Math.min(1, (L - G) / to) : 0;
		const V = G + u.to * to;
		u.sp = pd > 0 ? Math.min(1, V / pd) : 1;
		u.sq = sd > 0 ? Math.min(1, (V - u.sp * pd) / sd) : 1;
	}
	const shares = pools.map((p, i) => {
		const g = u.so * p.so + u.po * p.po + u.se * p.se + u.to * p.to;
		const w = u.sp * p.pd + u.sq * p.sd + u.st * p.td;
		return { g, w, y: g - w, x: g - w + u.E * E[i] - u.st * R[i] };
	});
	return { u, shares };
}

/** §8.3: the group's marginal class, the lowest-priority producer class in use, and its usage (none used: solar, 1). */
export function marginal(u: Usage): { m: "solar" | "primary" | "secondary" | "tertiary"; um: number } {
	if (u.to > 0) {
		return { m: "tertiary", um: u.to };
	}
	if (u.se > 0) {
		return { m: "secondary", um: u.se };
	}
	if (u.po > 0) {
		return { m: "primary", um: u.po };
	}
	return u.so > 0 ? { m: "solar", um: u.so } : { m: "solar", um: 1 };
}

/**
 * §8.3: a pool's mode and pool cap (kW) from its exchange y. Importing (y < 0): the marginal class's output mode at
 * −y / u_m, so it takes one fraction with that class's entities on its tile and gives exactly −y. Exporting:
 * secondary_input
 * at y / sq (y when sq is 0), one satisfaction with the tile's machines. y = 0: the marginal class at cap 0.
 */
export function cls(y: number, u: Usage): { mode: Mode; cap: number } {
	if (y > 0) {
		return { mode: "secondary_input", cap: Math.min(CAP_MAX, u.sq > 0 ? y / u.sq : y) };
	}
	const { m, um } = marginal(u);
	return { mode: `${m}_output`, cap: y < 0 ? Math.min(CAP_MAX, -y / um) : 0 };
}
