import type { NetT, ReportT, TargetT, TargetsT } from "./contracts.js";
import { CAP_MAX, cls, H, solve, TAU, type Mode, type Pool } from "./solve.js";

/**
 * The controller's power hub (power hub spec §8), pure. Once a second it solves every group of linked electric networks
 * (pools) the way the game solves one network, and gives each link this second's send amount, a buffer size, and the
 * class and cap its interface takes. It keeps each tile's latest report and each link's peaks; nothing is on disk.
 * After a controller restart the next reports rebuild it within a round (§8.7).
 */

export type PowerPort = {
	send(id: number, targets: TargetsT): void;
	now(): number;
};
/** §8.6's calibration knobs: the stock target H, its time constant τ (s), and the buffer's factor over the peak. */
export type Knobs = { h: number; tau: number; factor: number };

/** §8: reports older than this are left out (ms). */
export const STALE_MS = 5000;
/** §8.5: a link's peak is the largest of its last five one-minute maxima (plan review B5). */
export const MINUTE_MS = 60_000;
export const PEAK_MINUTES = 5;
/** §8.5: the buffer is factor × peak within [B_MIN, B_MAX] kJ (D37). */
export const B_FACTOR = 8; // Task 5's model (with TAU 8, solve.ts)
export const B_MIN = 10_000;
export const B_MAX = 10_000_000;

/** One side of a link as its tile reported it; n, what it sends this second, is 0 unless the tree makes it sender. */
type Side = { key: string; pool: P; sent: number; got: number; n: number };
/** A live link: its two sides, §8.4's amount (kJ) from side `from`, and its network part (branch Σy) for peaks. */
type Link = { key: string; s: [Side, Side]; amount: number; net: number; from: 0 | 1 };
/** A pool (§4): one reported network, its sides and live links, and its result. */
type P = Pool & { id: number; sides: Side[]; links: Link[]; x: number; y: number; mode?: Mode; cap: number };

const byKey = (a: { key: string }, b: { key: string }) => Number(a.key > b.key) - Number(a.key < b.key);
const other = (l: Link, p: P) => (l.s[0].pool === p ? l.s[1].pool : l.s[0].pool);

/** §8.1.1–2: the live links (a key reported from exactly two tiles), each direction settled into the pools' stock. */
function settle(sides: Map<string, Side[]>): Map<string, Link> {
	const live = new Map<string, Link>();
	for (const [key, list] of sides) {
		if (list.length !== 2 || list[0].pool.id === list[1].pool.id) {
			continue; // one-sided, or both on one tile: n stays 0 (plan ruling 10)
		}
		const l: Link = { key, s: [list[0], list[1]], amount: 0, net: 0, from: 0 };
		live.set(key, l);
		for (const [from, to] of [[list[0], list[1]], [list[1], list[0]]] as [Side, Side][]) {
			const done = Math.max(from.sent, to.got);
			from.pool.a -= done - from.sent; // sent after from's report, already credited in to's
			to.pool.a += done - to.got; // in transit: counted at its receiver
		}
		list[0].pool.links.push(l);
		list[1].pool.links.push(l);
	}
	return live;
}

/** §8.1.3: pools joined by live links (union-find); a pool with none is in no group. */
function groups(pools: P[]): P[][] {
	const up = new Map<P, P>();
	const find = (p: P): P => {
		const q = up.get(p);
		if (!q || q === p) {
			return p;
		}
		const r = find(q);
		up.set(p, r);
		return r;
	};
	for (const p of pools) {
		for (const l of p.links) {
			const a = find(l.s[0].pool);
			const b = find(l.s[1].pool);
			if (a !== b) {
				up.set(a, b);
			}
		}
	}
	const out = new Map<P, P[]>();
	for (const p of pools) {
		if (p.links.length > 0) {
			const r = find(p);
			out.set(r, [...(out.get(r) ?? []), p]);
		}
	}
	return [...out.values()];
}

/**
 * §8.4.1: breadth-first from the pool on the group's lowest instance id (ties: its lowest link key), links in key
 * order. Each tree edge carries its child's branch Σx for one second (kW × 1 s = kJ), split equally over its parallel
 * links and floored; its network part, the branch's Σy, sizes the peaks (§8.5, plan review S2).
 * Links off the tree carry nothing.
 */
function tree(group: P[]): void {
	const first = (p: P) => p.sides.map(s => s.key).sort()[0];
	const root = group.reduce((a, b) => (b.id < a.id || (b.id === a.id && first(b) < first(a)) ? b : a));
	const parent = new Map<P, P>();
	const order = [root];
	for (let i = 0; i < order.length; i++) {
		const p = order[i];
		for (const l of [...p.links].sort(byKey)) {
			const q = other(l, p);
			if (q !== root && !parent.has(q)) {
				parent.set(q, p);
				order.push(q);
			}
		}
	}
	const branch = new Map<P, { x: number; y: number }>();
	for (let i = order.length - 1; i > 0; i--) {
		const q = order[i];
		const p = parent.get(q)!;
		const below = branch.get(q) ?? { x: 0, y: 0 };
		const n = below.x + q.x;
		const ny = below.y + q.y;
		const above = branch.get(p) ?? { x: 0, y: 0 };
		branch.set(p, { x: above.x + n, y: above.y + ny });
		const parallel = q.links.filter(l => other(l, q) === p);
		// floored: a tree edge under-sends by at most parallel − 1 kJ a second; the stock terms absorb it (review M8)
		const each = Math.floor(Math.abs(n) / parallel.length);
		const net = Math.floor(Math.abs(ny) / parallel.length);
		const sender = n > 0 ? q : p;
		for (const l of parallel) {
			l.amount = each;
			l.net = net;
			l.from = l.s[0].pool === sender ? 0 : 1;
		}
	}
}

export class PowerHub {
	/** Each tile's latest report and when it arrived (ms). */
	readonly reports = new Map<number, { at: number; nets: NetT[] }>();
	/** §8.5, plan ruling 9: per link key, the largest network amount (kJ) in each of its last five minutes. */
	readonly peaks = new Map<string, { minute: number; max: number }[]>();
	/** The buffer (kJ) each link key was assigned last round: a floor on its pool's c (Task 5 ruling C). */
	private assigned = new Map<string, number>();
	private readonly knobs: Knobs;

	constructor(private port: PowerPort, knobs: Partial<Knobs> = {}) {
		this.knobs = { h: H, tau: TAU, factor: B_FACTOR, ...knobs };
	}

	report(id: number, r: ReportT): void {
		this.reports.set(id, { at: this.port.now(), nets: r.nets });
	}

	/** A tile stopped (§10): its links aren't live from the next round. */
	drop(id: number): void {
		this.reports.delete(id);
	}

	/** One round (§8.1–§8.6): one ue.power.targets to each tile with a fresh report, with every key it reported. */
	round(): void {
		const now = this.port.now();
		const pools: P[] = [];
		const sides = new Map<string, Side[]>();
		for (const [id, r] of this.reports) {
			if (now - r.at > STALE_MS) {
				continue;
			}
			for (const n of r.nets) {
				const p: P = { ...n.f, a: n.a, c: n.c, id, sides: [], links: [], x: 0, y: 0, cap: 0 };
				pools.push(p);
				for (const [key, sent, got] of n.l) {
					const s: Side = { key, pool: p, sent, got, n: 0 };
					p.sides.push(s);
					sides.set(key, [...(sides.get(key) ?? []), s]);
				}
			}
		}
		const live = settle(sides);
		// Task 5 ruling C: a pool's c for the stock terms is at least the buffers its links were assigned last round.
		// The report lags the buffer write (a link grows its buffer at its next poll), and settle counts the energy in
		// flight at the receiver: against the old c it reads as stock above target, and E would shorten the next send.
		for (const p of pools) {
			p.c = Math.max(p.c, p.sides.reduce((t, s) => t + (this.assigned.get(s.key) ?? 0), 0));
		}
		for (const group of groups(pools)) {
			const { u, shares } = solve(group, this.knobs.h, this.knobs.tau);
			group.forEach((p, i) => {
				p.x = shares[i].x;
				p.y = shares[i].y;
				const c = cls(shares[i].y, u);
				p.mode = c.mode;
				p.cap = c.cap;
				// power hub spec §8.3 (2026-10-20 burst headroom): the -y/u_m cap exists so a tile's OWN class-m
				// entities share at u_m. A pool with nothing of its own (no offers, no accumulators) has none to share
				// with, so the link's stock is the only limit and a burst is covered like one network's remote
				// accumulators. Not when the group is short (sp or sq < 1): the cap shares the brownout fairly (S5).
				if (u.sp >= 1 && u.sq >= 1 && shares[i].y <= 0 && p.so + p.po + p.se + p.to === 0 && p.td === 0) {
					p.cap = CAP_MAX;
				}
			});
			tree(group);
		}
		// ponytail: out copies a tile's targets per key, O(n²) in a tile's links; mutate in place if a tile ever has
		// hundreds of links (plan review M9)
		const out = new Map<number, Record<string, TargetT>>();
		// §8.5's buffers first: a pool's cap is split over its links in proportion to their buffers (Task 5 ruling F1).
		// Its interfaces then drain or fill at one rate against their size and stay at one fill ratio between writes;
		// an equal split empties (or fills) the smaller one first, and the pool gives (or takes) only part of its cap.
		const bs = new Map<string, number>();
		for (const key of sides.keys()) {
			bs.set(key, this.buffer(key, live.get(key)?.net ?? 0, now));
		}
		const total = new Map(pools.map(p => [p, p.sides.reduce((t, s) => t + bs.get(s.key)!, 0)]));
		this.assigned = bs;
		for (const [key, list] of sides) {
			const l = live.get(key);
			if (l) {
				l.s[l.from].n = l.amount; // §8.4.2: a rate, this second's amount (plan review B1)
			}
			const b = bs.get(key)!;
			for (const s of list) {
				const p = s.pool;
				const target: TargetT = { n: s.n, b, k: p.mode ? p.cap * b / total.get(p)! : 0 };
				if (p.mode) {
					target.m = p.mode;
				}
				out.set(p.id, { ...(out.get(p.id) ?? {}), [key]: target });
			}
		}
		const minute = Math.floor(now / MINUTE_MS);
		for (const [key, kept] of this.peaks) {
			if (!sides.has(key) && kept.every(m => m.minute <= minute - PEAK_MINUTES)) {
				this.peaks.delete(key);
			}
		}
		for (const [id, l] of out) {
			this.port.send(id, { l });
		}
	}

	/** §8.5: this minute's maximum takes net (kJ); the buffer is factor × the largest of the last five minutes'. */
	private buffer(key: string, net: number, now: number): number {
		const minute = Math.floor(now / MINUTE_MS);
		const kept = (this.peaks.get(key) ?? []).filter(m => m.minute > minute - PEAK_MINUTES);
		const current = kept.find(m => m.minute === minute);
		if (current) {
			current.max = Math.max(current.max, net);
		} else {
			kept.push({ minute, max: net });
		}
		this.peaks.set(key, kept);
		const peak = Math.max(...kept.map(m => m.max));
		return Math.min(B_MAX, Math.max(B_MIN, Math.ceil(this.knobs.factor * peak)));
	}
}
