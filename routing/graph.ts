import type { EdgeRecord } from "../edges/contracts.js";
import type { ConnStateT, HopT, StationT } from "./contracts.js";

/** trains_limit when a stop has none: Factorio reads back the largest uint32 (spike 1, s1.bounds). */
export const UNLIMITED = 4294967295;

/**
 * Congestion layers 2 and 3 (D42 point 5), in the pathfinder's own penalty units: about 2 per straight rail, 12 per
 * signal, ~7000 for an occupied block (spike 8 Q1-Q3). ponytail: constants, not config (R29, O3): the owner's playtest
 * raised no cost complaint.
 */
export const COSTS = { border: 0, notReady: 3000, held: 3000, inflight: 1500, queuedCarriage: 300, traffic: 1000 };

/**
 * One tile as the controller keeps it: costs[from][to], its stations by unit, its connectors' rows by key, and its
 * adjacency (§8.1), built on first use after its costs change: "<tile>|<from>" → ["<tile>|<to>", cost][].
 */
export type TileData = {
	costs: Map<string, Map<string, number>>;
	stations: Map<number, StationT>;
	conns: Map<string, ConnStateT>;
	adj?: Map<string, [string, number][]>;
};
/** A train connector: trains leave tile `from` by its outbound box and arrive at tile `to`. key = "<edge>/<cid>". */
export type Link = { key: string; edge: string; cid: string; from: number; to: number };
/** How the search reached a node: the node before, and the link when that step crossed a border. */
export type Step = { prev: string; link?: Link };
/** A stop with the asked-for name, on its tile. */
export type Named = { tile: number; stop: StationT };

/** Every live edge's train connectors, oriented by params.dir: side a sends on "ab" (UE train.outbound). */
export function links(edges: EdgeRecord[]): Link[] {
	const out: Link[] = [];
	for (const e of edges) {
		if (e.deleted) {
			continue;
		}
		for (const c of e.connectors) {
			if (c.type === "train") {
				const ab = c.params.dir === "ab";
				const [from, to] = ab ? [e.a.instanceId, e.b.instanceId] : [e.b.instanceId, e.a.instanceId];
				out.push({ key: `${e.id}/${c.cid}`, edge: e.id, cid: c.cid, from, to });
			}
		}
	}
	return out;
}

/** The links by key, made per request from the edge API (R22): about 236 at v1 scale. */
export function linkMap(edges: EdgeRecord[]): Map<string, Link> {
	return new Map(links(edges).map((link): [string, Link] => [link.key, link]));
}

/** Layers 2 and 3 for one crossing; Infinity unless both sides report it live. */
export function crossingCost(link: Link, tiles: Map<number, TileData>, traffic: Map<string, number>): number {
	const out = tiles.get(link.from)?.conns.get(link.key);
	const inn = tiles.get(link.to)?.conns.get(link.key);
	if (!out?.live || !inn?.live) {
		return Infinity;
	}
	let cost = COSTS.border + (traffic.get(link.key) ?? 0) * COSTS.traffic + (inn.queued ?? 0) * COSTS.queuedCarriage;
	if (out.ready === false || inn.ready === false) {
		cost += COSTS.notReady;
	}
	if (out.held) {
		cost += COSTS.held;
	}
	if (out.inflight) {
		cost += COSTS.inflight;
	}
	return cost;
}

function adjacency(tile: number, t: TileData): Map<string, [string, number][]> {
	if (!t.adj) {
		const adj = new Map<string, [string, number][]>();
		for (const [from, row] of t.costs) {
			adj.set(`${tile}|${from}`, [...row].map(([to, cost]): [string, number] => [`${tile}|${to}`, cost]));
		}
		t.adj = adj;
	}
	return t.adj;
}

/** A binary min-heap of [cost, node]; a node pushed again with a lower cost leaves a stale entry, skipped on pop. */
class Heap {
	private items: [number, string][] = [];

	get size(): number {
		return this.items.length;
	}

	push(cost: number, node: string): void {
		const a = this.items;
		a.push([cost, node]);
		let i = a.length - 1;
		while (i > 0) {
			const p = (i - 1) >> 1;
			if (a[p][0] <= a[i][0]) {
				break;
			}
			[a[p], a[i]] = [a[i], a[p]];
			i = p;
		}
	}

	pop(): [number, string] {
		const a = this.items;
		const top = a[0];
		const last = a.pop()!;
		if (a.length > 0) {
			a[0] = last;
			let i = 0;
			for (;;) {
				const l = 2 * i + 1;
				const r = l + 1;
				let m = i;
				if (l < a.length && a[l][0] < a[m][0]) {
					m = l;
				}
				if (r < a.length && a[r][0] < a[m][0]) {
					m = r;
				}
				if (m === i) {
					break;
				}
				[a[m], a[i]] = [a[i], a[m]];
				i = m;
			}
		}
		return top;
	}
}

/**
 * Multi-source Dijkstra over "<tile>|<key>" nodes (§8.1): each tile's cached adjacency (layer 4), and crossings relaxed
 * on the fly from an outbound node "<from>|c:<key>" to "<to>|c:<key>" (layers 2 and 3). It stops once every target is
 * settled: the same-name rule needs every stop of the name, so it can't stop at the first.
 */
export function shortest(
	tiles: Map<number, TileData>, ls: Map<string, Link>, traffic: Map<string, number>, origins: [string, number][],
	targets: Set<string>,
): { dist: Map<string, number>; prev: Map<string, Step> } {
	const dist = new Map<string, number>();
	const prev = new Map<string, Step>();
	const done = new Set<string>();
	const heap = new Heap();
	const relax = (from: string, d: number, to: string, link?: Link) => {
		if (d < (dist.get(to) ?? Infinity)) {
			dist.set(to, d);
			prev.set(to, { prev: from, link });
			heap.push(d, to);
		}
	};
	for (const [node, cost] of origins) {
		if (cost < (dist.get(node) ?? Infinity)) {
			dist.set(node, cost);
			heap.push(cost, node);
		}
	}
	let left = targets.size;
	while (heap.size > 0 && left > 0) {
		const [d, u] = heap.pop();
		if (done.has(u)) {
			continue;
		}
		done.add(u);
		if (targets.has(u)) {
			left -= 1;
		}
		const bar = u.indexOf("|");
		const tile = Number(u.slice(0, bar));
		const t = tiles.get(tile);
		for (const [to, cost] of (t && adjacency(tile, t).get(u)) ?? []) {
			relax(u, d + cost, to);
		}
		if (u.startsWith("c:", bar + 1)) {
			const link = ls.get(u.slice(bar + 3));
			if (link && link.from === tile) {
				const cost = crossingCost(link, tiles, traffic);
				if (Number.isFinite(cost)) {
					relax(u, d + cost, `${link.to}|c:${link.key}`, link);
				}
			}
		}
	}
	return { dist, prev };
}

/** The crossings on the path to node, in order. */
export function hopsTo(prev: Map<string, Step>, node: string): HopT[] {
	const hops: HopT[] = [];
	for (let step = prev.get(node); step; step = prev.get(step.prev)) {
		if (step.link) {
			hops.unshift({ edge: step.link.edge, cid: step.link.cid });
		}
	}
	return hops;
}

export type Choice =
	| { tile: number; unit: number; cost: number; hops: HopT[] }
	| { reason: "unknown_station" | "no_path" | "destination_full" | "local" };

/**
 * Vanilla's same-name rule (D42 point 2, §6.2): among the stops named dest that the search reached and that have a free
 * slot, the highest priority, then the cheapest. named is one planet's: the router's index by (surface, name) (R31).
 * Ruling P1: it runs over every tile including the asking one (origin), and when that tile's own stop wins and is
 * reached with no crossing the answer is reason "local". A stop reached only out and back (through other tiles) is an
 * ordinary choice, its hops the way out and back.
 */
export function choose(
	named: Named[], dist: Map<string, number>, prev: Map<string, Step>, free: (tile: number, stop: StationT) => number,
	origin: number,
): Choice {
	if (named.length === 0) {
		return { reason: "unknown_station" };
	}
	const reached = named.map(n => ({ ...n, cost: dist.get(`${n.tile}|s:${n.stop.unit}`) ?? Infinity }))
		.filter(c => Number.isFinite(c.cost));
	if (reached.length === 0) {
		return { reason: "no_path" };
	}
	const open = reached.filter(c => free(c.tile, c.stop) > 0);
	if (open.length === 0) {
		return { reason: "destination_full" };
	}
	open.sort((a, b) => b.stop.priority - a.stop.priority || a.cost - b.cost);
	const { tile, stop, cost } = open[0];
	const hops = hopsTo(prev, `${tile}|s:${stop.unit}`);
	if (tile === origin && hops.length === 0) {
		return { reason: "local" };
	}
	return { tile, unit: stop.unit, cost, hops };
}
