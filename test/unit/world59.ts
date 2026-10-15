import type { EdgeRecord } from "../../edges/contracts.js";
import { UNLIMITED } from "../../routing/graph.js";

/** A seeded generator (mulberry32): the same seed gives the same world and the same requests. */
export function rng(seed: number): () => number {
	let a = seed >>> 0;
	return () => {
		a = (a + 0x6D2B79F5) >>> 0;
		let t = a;
		t = Math.imul(t ^ (t >>> 15), t | 1);
		t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
		return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
	};
}

export type World = {
	edges: EdgeRecord[];
	/** Each tile's full report, { full, costs, stations, conns }, as ue.route.report payloads. */
	reports: [number, object][];
	/** Every station name in the world. */
	names: string[];
	tiles: number[];
	/** A train's own costs on tile to its outbound boxes, keys c:… (a request's firsts). */
	firsts(tile: number, rand: () => number): [string, number][];
};

/**
 * Spike 8's stand-in for v1's 59 tiles (docs/spikes/2026-10-04-8-router.md:220-228; v1's real shape is in the live
 * install, off-limits): the -4..6 × -4..4 box, the 59 cells nearest the origin kept. Neighbours share an edge with
 * a train connector each way, so a tile has up to 4 inbound and 4 outbound boxes. 20 stations a tile, named from a
 * pool of 200 so names repeat across tiles; one in 4 limited to 2 trains, one in 10 at priority 60. Costs are seeded
 * and fractional, so no two paths tie. One planet: every edge and station is on "nauvis", as are the bench's requests.
 */
export function world59(seed: number): World {
	const rand = rng(seed);
	const cells: [number, number][] = [];
	for (let x = -4; x <= 6; x++) {
		for (let y = -4; y <= 4; y++) {
			cells.push([x, y]);
		}
	}
	cells.sort((a, b) => Math.hypot(a[0], a[1]) - Math.hypot(b[0], b[1]));
	const ids = new Map(cells.slice(0, 59).map(([x, y], i): [string, number] => [`${x},${y}`, i + 1]));
	const edges: EdgeRecord[] = [];
	const inbound = new Map<number, string[]>();
	const outbound = new Map<number, string[]>();
	const add = (m: Map<number, string[]>, tile: number, key: string) => {
		m.set(tile, [...(m.get(tile) ?? []), key]);
	};
	for (const [cell, a] of ids) {
		const [x, y] = cell.split(",").map(Number);
		for (const [dx, dy] of [[1, 0], [0, 1]]) {
			const b = ids.get(`${x + dx},${y + dy}`);
			if (b === undefined) {
				continue;
			}
			const id = `e${a}-${b}`;
			edges.push({
				id, owner: "bench", length: 64, revision: 1, deleted: false, trace: "t", updatedAtMs: 0,
				a: { instanceId: a, surface: "nauvis", origin: [0, 0], facing: 0 },
				b: { instanceId: b, surface: "nauvis", origin: [64, 0], facing: 8 },
				connectors: [
					{ cid: "ab", type: "train", pos: 8, width: 6, params: { dir: "ab" } },
					{ cid: "ba", type: "train", pos: 24, width: 6, params: { dir: "ba" } },
				],
			});
			add(outbound, a, `${id}/ab`);
			add(inbound, b, `${id}/ab`);
			add(outbound, b, `${id}/ba`);
			add(inbound, a, `${id}/ba`);
		}
	}
	const names = new Set<string>();
	const reports: [number, object][] = [];
	const tiles = [...ids.values()];
	for (const tile of tiles) {
		const stations = Array.from({ length: 20 }, (_, k) => {
			const name = `S${Math.floor(rand() * 200)}`;
			names.add(name);
			return {
				unit: tile * 100 + k, surface: "nauvis", name, limit: k % 4 === 0 ? 2 : UNLIMITED, count: 0, script: 0,
				priority: k % 10 === 0 ? 60 : 50,
			};
		});
		const costs: [string, string, number][] = [];
		for (const from of inbound.get(tile) ?? []) {
			for (const to of outbound.get(tile) ?? []) {
				costs.push([`c:${from}`, `c:${to}`, 50 + rand() * 2000]);
			}
			for (const s of stations) {
				costs.push([`c:${from}`, `s:${s.unit}`, 20 + rand() * 1500]);
			}
		}
		const conns = [
			...(inbound.get(tile) ?? []).map(key => ({ key, box: "inbound", live: true, ready: true, queued: 0 })),
			...(outbound.get(tile) ?? []).map(key => ({ key, box: "outbound", live: true, ready: true })),
		];
		reports.push([tile, { full: true, costs, stations, conns }]);
	}
	return {
		edges, reports, names: [...names], tiles,
		firsts: (tile, r) => (outbound.get(tile) ?? []).map((key): [string, number] => [`c:${key}`, 20 + r() * 500]),
	};
}
