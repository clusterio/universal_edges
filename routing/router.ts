import type { EdgeRecord } from "../edges/contracts.js";
import {
	list, type AliveT, type ArrivedT, type CancelReason, type ConnStateT, type HopT, type LostT, type ManualT,
	type ReportT, type RequestT, type StationEntry, type StationKey, type StationT, type StationsT,
} from "./contracts.js";
import { UNLIMITED, choose, linkMap, shortest, type Named, type TileData } from "./graph.js";

type Level = "info" | "verbose" | "warn" | "error";
/** What the router needs from Clusterio (controller.ts) or a test. now(): wall-clock ms (the 5-minute rule, §7.4). */
export type Port = {
	edges(): EdgeRecord[];
	name(instanceId: number): string;
	send(instanceId: number, kind: string, payload: object): void;
	log(op: string, phase: string, fields: Record<string, unknown>, level?: Level): void;
	now(): number;
};
/**
 * A train's route (D42), by its trace (§4.4). tile: where its train last asked from. stop: its D43 reservation; the
 * controller is the truth. local: the asking tile's own stop won (R30). seen: when a message last named it (ms); not
 * saved, and loading sets it to the load time.
 */
export type Route = {
	trace: string; dest: string; tile: number; hops: HopT[]; stop?: { tile: number; unit: number }; failed?: boolean;
	local?: boolean; seen: number;
};
export type SavedRoute = Omit<Route, "seen">;

/** The 5-minute rule (§7.4, R15): a route no message named for longer is dropped and its reservation cancelled. */
export const GC_AGE_MS = 300_000;
/** Every routing message's JSON, both ways, stays within this many bytes (§7.9). */
export const BUDGET = 3000;

export const hopKey = (h: HopT) => `${h.edge}/${h.cid}`;
export const keys = (hops: HopT[]) => hops.map(hopKey).join(",");
/** The hops after the one crossed (via), or all of them if via isn't among them. */
const after = (hops: HopT[], via: string) => hops.slice(hops.findIndex(h => hopKey(h) === via) + 1);
const stopKey = (tile: number, unit: number) => `${tile}|${unit}`;
/** A station-list key as a string: one per (surface, name) pair (R35); the name index's key too (R31). */
const nameKey = (surface: string, name: string) => JSON.stringify([surface, name]);

/**
 * The station list as ue.route.stations messages of at most BUDGET bytes of JSON each (§7.9): set entries, then gone
 * (surface, name) pairs, in order; full on the first, so the tile replaces its list. A lone entry over BUDGET still
 * goes, alone.
 */
export function stationParts(set: StationEntry[], gone: StationKey[], full = false): StationsT[] {
	const empty = () => ({ set: [] as StationEntry[], gone: [] as StationKey[] });
	const parts: StationsT[] = [];
	let part = empty();
	let size = JSON.stringify({ full: true, ...part }).length;
	const room = (bytes: number) => {
		if (part.set.length + part.gone.length > 0 && size + bytes > BUDGET) {
			parts.push(part);
			part = empty();
			size = JSON.stringify({ full: true, ...part }).length;
		}
		size += bytes;
	};
	for (const entry of set) {
		room(JSON.stringify(entry).length + 1);
		part.set.push(entry);
	}
	for (const key of gone) {
		room(JSON.stringify(key).length + 1);
		part.gone.push(key);
	}
	if (part.set.length + part.gone.length > 0 || (full && parts.length === 0)) {
		parts.push(part);
	}
	if (full) {
		parts[0] = { full: true, ...parts[0] };
	}
	return parts;
}

export class Router {
	tiles = new Map<number, TileData>();
	/** Tiles resynced and not yet answered by a full report: their non-full reports ask for no second resync. */
	private pending = new Set<number>();
	routes = new Map<string, Route>();
	/** The station list last broadcast: each entry's JSON, by nameKey (R35). */
	private sent = new Map<string, string>();
	/**
	 * nameKey (surface, name) → its stops; rebuilt after any station row changes (§8.1's early exit needs every stop of
	 * a name on the request's planet, and only those: R31).
	 */
	private byName?: Map<string, Named[]>;

	constructor(private port: Port, saved?: { routes?: SavedRoute[] }) {
		const now = port.now();
		for (const r of saved?.routes ?? []) {
			this.routes.set(r.trace, { ...r, seen: now });
		}
	}

	receive(tile: number, kind: string, payload: unknown): void {
		if (kind === "ue.route.report") {
			this.report(tile, payload as ReportT);
		} else if (kind === "ue.route.request") {
			this.request(tile, payload as RequestT);
		} else if (kind === "ue.route.arrived") {
			this.end(tile, (payload as ArrivedT).trace);
		} else if (kind === "ue.route.lost") {
			this.end(tile, (payload as LostT).trace, (payload as LostT).reason);
		} else if (kind === "ue.route.manual") {
			this.manual(tile, (payload as ManualT).trace);
		} else if (kind === "ue.route.alive") {
			this.alive(tile, payload as AliveT);
		}
	}

	/** One report message (§7.9), applied on its own. One from a tile with no table, unless full, asks for one. */
	report(tile: number, msg: ReportT): void {
		let t = this.tiles.get(tile);
		if (!t && !msg.full) {
			if (!this.pending.has(tile)) {
				this.resync(tile);
			}
			return;
		}
		if (msg.full) {
			this.pending.delete(tile);
		}
		if (msg.full || !t) {
			t = { costs: new Map(), stations: new Map(), conns: new Map() };
			this.tiles.set(tile, t);
			this.byName = undefined;
		}
		const costs = list<[string, string, number]>(msg.costs);
		const gone = list<[string, string]>(msg.gone);
		for (const [from, to, cost] of costs) {
			const row = t.costs.get(from) ?? new Map<string, number>();
			row.set(to, cost);
			t.costs.set(from, row);
		}
		for (const [from, to] of gone) {
			t.costs.get(from)?.delete(to);
		}
		if (costs.length > 0 || gone.length > 0) {
			t.adj = undefined;
		}
		const stations = list<StationT>(msg.stations);
		const stopsGone = list<number>(msg.stops_gone);
		for (const s of stations) {
			t.stations.set(s.unit, s);
		}
		for (const unit of stopsGone) {
			t.stations.delete(unit);
		}
		if (stations.length > 0 || stopsGone.length > 0) {
			this.byName = undefined;
		}
		for (const c of list<ConnStateT>(msg.conns)) {
			t.conns.set(c.key, c);
		}
		for (const key of list<string>(msg.conns_gone)) {
			t.conns.delete(key);
		}
	}

	/** Planned traffic (other routes' remaining hops, per connector) and held reservations (per stop): R11. */
	private load(except?: string): { traffic: Map<string, number>; held: Map<string, number> } {
		const traffic = new Map<string, number>();
		const held = new Map<string, number>();
		for (const r of this.routes.values()) {
			if (r.trace === except) {
				continue;
			}
			for (const h of r.hops) {
				traffic.set(hopKey(h), (traffic.get(hopKey(h)) ?? 0) + 1);
			}
			if (r.stop) {
				const key = stopKey(r.stop.tile, r.stop.unit);
				held.set(key, (held.get(key) ?? 0) + 1);
			}
		}
		return { traffic, held };
	}

	/**
	 * A route from tile (§6.2): from its inbound box after a crossing (via), or from the train's own costs (firsts,
	 * full node keys, R23). The chosen stop is reserved through its tile; a different stop than before cancels the old
	 * one (rerouted). A failure cancels and clears the hops, logged once per trace until it succeeds (warn, or info for
	 * destination_full, R12). A local answer keeps the route, with no stop and no hops, logged once (R30). Only stops
	 * named dest on the request's surface count, and every reason is that planet's (R31).
	 */
	request(tile: number, q: RequestT): void {
		const now = this.port.now();
		const { traffic, held } = this.load(q.trace);
		const origins: [string, number][] = q.via !== undefined
			? [[`${tile}|c:${q.via}`, 0]]
			: list<[string, number]>(q.firsts).map(([key, cost]): [string, number] => [`${tile}|${key}`, cost]);
		const named = this.names().get(nameKey(q.surface, q.dest)) ?? [];
		const targets = new Set(named.map(n => `${n.tile}|s:${n.stop.unit}`));
		const { dist, prev } = shortest(this.tiles, linkMap(this.port.edges()), traffic, origins, targets);
		const known = this.routes.get(q.trace);
		const booked = known?.stop;
		// a booking holds for the whole trip, as a vanilla train's does when a stop's limit drops
		const choice = choose(named, dist, prev, (t, s) => {
			const free = this.free(t, s, held);
			return booked?.tile === t && booked.unit === s.unit ? Math.max(1, free) : free;
		}, tile);
		const route: Route = known ?? { trace: q.trace, dest: q.dest, tile, hops: [], seen: now };
		route.tile = tile;
		route.dest = q.dest;
		route.seen = now;
		this.routes.set(q.trace, route);
		const fields = { trace: q.trace, dest: q.dest, surface: q.surface, tile: this.port.name(tile) }; // §10: surface
		if ("reason" in choice) {
			route.hops = [];
			if (choice.reason === "local") {
				if (!route.local) {
					this.port.log("ue.route", "local", fields);
				}
				route.local = true;
				this.cancel(route, "rerouted"); // plan ruling 8: §4.2 has no local reason
			} else {
				if (!route.failed) {
					const level = choice.reason === "destination_full" ? "info" : "warn";
					this.port.log("ue.route", "failed", { ...fields, reason: choice.reason }, level);
				}
				route.failed = true;
				this.cancel(route, "failed");
			}
			this.port.send(tile, "ue.route.reply", { trace: q.trace, ok: false, reason: choice.reason });
			return;
		}
		const had = route.stop;
		const moved = had?.tile !== choice.tile || had?.unit !== choice.unit;
		const expected = q.via === undefined ? route.hops : after(route.hops, q.via);
		const rerouted = known !== undefined && had !== undefined && (moved || keys(expected) !== keys(choice.hops));
		this.port.log("ue.route", rerouted ? "rerouted" : "assigned", {
			...fields, stop_tile: this.port.name(choice.tile), stop: choice.unit, hops: keys(choice.hops),
			cost: Math.round(choice.cost), ...(rerouted ? { was: keys(expected) } : {}),
		});
		if (moved) {
			this.cancel(route, "rerouted");
			this.port.send(choice.tile, "ue.route.reserve", { trace: q.trace, unit: choice.unit });
		}
		route.hops = choice.hops;
		route.stop = { tile: choice.tile, unit: choice.unit };
		route.failed = false;
		route.local = false;
		this.port.send(tile, "ue.route.reply", { trace: q.trace, ok: true, hops: choice.hops });
	}

	/** D43: the controller cancels a reservation, with its reason (§4.2). */
	private cancel(route: Route, reason: CancelReason): void {
		if (route.stop) {
			this.port.send(route.stop.tile, "ue.route.cancel", { trace: route.trace, reason });
			route.stop = undefined;
		}
	}

	/** Arrived on the stop's tile (it released its own reservation), lost, or arrived elsewhere: cancel it (§6.6). */
	end(tile: number, trace: string, lost?: string): void {
		const route = this.routes.get(trace);
		if (!route) {
			return;
		}
		if (lost !== undefined || route.stop?.tile !== tile) {
			this.cancel(route, "lost");
		} else if (route.stop) {
			// the tile turned its reservation into a train heading here (script -1, count same); apply that now, as the
			// next row (which replaces this object, and can't come before this message) may be a poll away
			const row = this.tiles.get(tile)?.stations.get(route.stop.unit);
			if (row) {
				row.script -= 1;
			}
		}
		this.routes.delete(trace);
	}

	/** §7.6: the train went manual; its reservation is released, only when its current tile says so (R24). */
	manual(tile: number, trace: string): void {
		const route = this.routes.get(trace);
		if (!route) {
			return;
		}
		route.seen = this.port.now();
		if (route.tile === tile) {
			this.cancel(route, "manual");
		}
	}

	/**
	 * I2 (§7.4): tile's report of the routes it carries (active: refreshes seen; one the controller doesn't know is
	 * forgotten, and the tile asks again) and the reservations it holds (one no route here holds is an orphan, FR M6).
	 * Reserved mentions don't refresh seen: a leaked reservation's own tile would otherwise keep it alive for ever.
	 */
	alive(tile: number, msg: AliveT): void {
		const now = this.port.now();
		const name = this.port.name(tile);
		const forgotten: string[] = [];
		for (const trace of list<string>(msg.active)) {
			const route = this.routes.get(trace);
			if (route) {
				route.seen = now;
			} else {
				this.port.log("ue.route", "forgotten", { trace, tile: name });
				forgotten.push(trace);
			}
		}
		if (forgotten.length > 0) {
			this.port.send(tile, "ue.route.forgotten", { traces: forgotten });
		}
		for (const trace of list<string>(msg.reserved)) {
			if (this.routes.get(trace)?.stop?.tile !== tile) {
				this.port.log("ue.reservation", "orphan", { trace, tile: name });
				this.port.send(tile, "ue.route.cancel", { trace, reason: "orphan" });
			}
		}
	}

	/** The 5-minute rule (§7.4), every 60 s: a route unseen for longer is dropped and its reservation cancelled. */
	gc(): void {
		const now = this.port.now();
		for (const route of [...this.routes.values()]) {
			if (now - route.seen > GC_AGE_MS) {
				this.port.log("ue.route", "gc", {
					trace: route.trace, dest: route.dest, tile: this.port.name(route.tile),
					unseen_s: Math.round((now - route.seen) / 1000),
				}, "warn");
				this.cancel(route, "gc");
				this.routes.delete(route.trace);
			}
		}
	}

	/** A tile that stopped: its table is stale until its next start's full report. */
	drop(tile: number): void {
		this.tiles.delete(tile);
		this.pending.delete(tile);
		this.byName = undefined;
	}

	/** D43: the tile's reservations as the controller knows them, at its start; then the whole station list (§7.3). */
	resync(tile: number): void {
		this.pending.add(tile);
		const reservations = [...this.routes.values()].filter(r => r.stop?.tile === tile)
			.map(r => ({ trace: r.trace, unit: r.stop!.unit }));
		this.port.log("ue.routing", "resync", { tile: this.port.name(tile), reservations: reservations.length });
		this.port.send(tile, "ue.route.resync", { reservations });
		for (const part of stationParts(this.stationEntries(), [], true)) {
			this.port.send(tile, "ue.route.stations", part);
		}
	}

	/** A stop's free slots: limit − trains − the controller's reservations (§6.2); trains_count has the script ones. */
	free(tile: number, s: StationT, held: Map<string, number>): number {
		if (s.limit >= UNLIMITED) {
			return Infinity;
		}
		return s.limit - (s.count - s.script) - (held.get(stopKey(tile, s.unit)) ?? 0);
	}

	/**
	 * Every (surface, name), its tiles and its free slots (-1: some stop of it is unlimited), by surface, then name.
	 * D42 point 7; one entry per pair (R35).
	 */
	stationEntries(): StationEntry[] {
		const { held } = this.load();
		const byKey = new Map<string, StationKey & { tiles: Set<string>; free: number }>();
		for (const [tile, t] of this.tiles) {
			for (const s of t.stations.values()) {
				const key = nameKey(s.surface, s.name);
				const e = byKey.get(key) ?? { surface: s.surface, name: s.name, tiles: new Set<string>(), free: 0 };
				e.tiles.add(this.port.name(tile));
				e.free += Math.max(0, this.free(tile, s, held));
				byKey.set(key, e);
			}
		}
		return [...byKey.values()]
			.sort((a, b) => a.surface.localeCompare(b.surface) || a.name.localeCompare(b.name))
			.map(({ surface, name, tiles, free }) => ({
				surface, name, tiles: [...tiles].sort(), free: Number.isFinite(free) ? free : -1,
			}));
	}

	/**
	 * Every 5 s (controller.ts): the (surface, name) entries that changed and those gone (R35), in parts, to every tile
	 * with a table.
	 */
	broadcastStations(): void {
		const entries = this.stationEntries();
		const now = new Map(entries.map((e): [string, string] => [nameKey(e.surface, e.name), JSON.stringify(e)]));
		const set = entries.filter(e => {
			const key = nameKey(e.surface, e.name);
			return this.sent.get(key) !== now.get(key);
		});
		const gone = [...this.sent.keys()].filter(key => !now.has(key)).map((key): StationKey => {
			const [surface, name] = JSON.parse(key) as [string, string];
			return { surface, name };
		});
		if (set.length === 0 && gone.length === 0) {
			return;
		}
		this.sent = now;
		const parts = stationParts(set, gone);
		for (const tile of this.tiles.keys()) {
			for (const part of parts) {
				this.port.send(tile, "ue.route.stations", part);
			}
		}
	}

	toJSON(): { routes: SavedRoute[] } {
		return {
			routes: [...this.routes.values()].map(r => ({
				trace: r.trace, dest: r.dest, tile: r.tile, hops: r.hops,
				stop: r.stop, failed: r.failed, local: r.local,
			})),
		};
	}

	private names(): Map<string, Named[]> {
		if (!this.byName) {
			const byName = new Map<string, Named[]>();
			for (const [tile, t] of this.tiles) {
				for (const stop of t.stations.values()) {
					const key = nameKey(stop.surface, stop.name);
					byName.set(key, [...(byName.get(key) ?? []), { tile, stop }]);
				}
			}
			this.byName = byName;
		}
		return this.byName;
	}
}
