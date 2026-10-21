import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import * as lib from "@clusterio/lib";
import type { EdgeRecord } from "../../edges/contracts.js";
import { plugin } from "../../index.js";
import { saveDataFile } from "../../runtime/index.js";
import { Report, RouteDownEvent, RouteUpEvent, list } from "../../routing/contracts.js";
import { ROUTES_FILE, loadRoutes } from "../../routing/controller.js";
import {
	UNLIMITED, choose, crossingCost, hopsTo, linkMap, links, shortest, type Link, type TileData,
} from "../../routing/graph.js";
import { BUDGET, Router, keys, stationParts, type Port } from "../../routing/router.js";
import { rng, world59 } from "./world59.js";

type Sent = { to: number; kind: string; payload: any };
type Log = { op: string; phase: string; fields: Record<string, unknown>; level: string };

function edge(id: string, a: number, b: number, cids: string[], surface = "nauvis"): EdgeRecord {
	return {
		id, owner: "test", length: 64, revision: 1, deleted: false, trace: "t", updatedAtMs: 0,
		a: { instanceId: a, surface, origin: [0, 0], facing: 0 },
		b: { instanceId: b, surface, origin: [64, 0], facing: 8 },
		connectors: cids.map((cid, i) => ({ cid, type: "train", pos: 8 * i, width: 6, params: { dir: "ab" } })),
	};
}
const conn = (key: string, box: "inbound" | "outbound", extra: object = {}) => ({
	key, box, live: true, ready: true, ...extra,
});
const station = (unit: number, name: string, extra: object = {}) => ({
	unit, surface: "nauvis", name, limit: UNLIMITED, count: 0, script: 0, priority: 50, ...extra,
});
const reserve = (to: number, trace: string, unit: number) => ({
	to, kind: "ue.route.reserve", payload: { trace, unit },
});
const cancelled = (to: number, trace: string, reason: string) => ({
	to, kind: "ue.route.cancel", payload: { trace, reason },
});

/** A Port that records what it is given; clock.t is its now(). */
function port(edges: EdgeRecord[] = [], clock = { t: 0 }) {
	const sent: Sent[] = [];
	const logs: Log[] = [];
	const p: Port = {
		edges: () => edges,
		name: id => `tile${id}`,
		send: (to, kind, payload) => {
			sent.push({ to, kind, payload });
		},
		log: (op, phase, fields, level = "info") => {
			logs.push({ op, phase, fields, level });
		},
		now: () => clock.t,
	};
	return { port: p, sent, logs, clock };
}

/**
 * Tiles 4 → 3 → 2 → 1 in a row (the dev world's 1_0, 0_0, -1_0, -2_0), westbound: e43/w, then two parallel connectors
 * e32/w (cost 200 on to e21) and e32/w2 (210), then e21/w. HOME4 (41) on tile 4, R MID (21) on tile 2, R WEST (11) on
 * tile 1. Tile 4 has no inbound box: a train there asks with its own costs (firsts, R3), 100 to e43/w's box. Every
 * edge, stop and request is on Nauvis unless a test says otherwise (the surfaces amendment).
 */
function world(opts: {
	tile2?: object[]; tile3?: object[]; stations2?: object[]; stations1?: object[]; stations4?: object[];
} = {}) {
	const edges = [edge("e43", 4, 3, ["w"]), edge("e32", 3, 2, ["w", "w2"]), edge("e21", 2, 1, ["w"])];
	const { port: p, sent, logs, clock } = port(edges);
	const router = new Router(p);
	const report = (tile: number, costs: [string, string, number][], stations: object[], conns: object[]) => {
		router.receive(tile, "ue.route.report", { full: true, costs, stations, conns });
	};
	report(4, [], opts.stations4 ?? [station(41, "HOME4")], [conn("e43/w", "outbound")]);
	report(3, [["c:e43/w", "c:e32/w", 200], ["c:e43/w", "c:e32/w2", 210]], [],
		opts.tile3 ?? [conn("e43/w", "inbound"), conn("e32/w", "outbound"), conn("e32/w2", "outbound")]);
	report(
		2,
		[["c:e32/w", "c:e21/w", 200], ["c:e32/w2", "c:e21/w", 200], ["c:e32/w", "s:21", 50], ["c:e32/w2", "s:21", 50]],
		opts.stations2 ?? [station(21, "R MID")],
		opts.tile2 ?? [conn("e32/w", "inbound"), conn("e32/w2", "inbound"), conn("e21/w", "outbound")],
	);
	report(1, [["c:e21/w", "s:11", 100]], opts.stations1 ?? [station(11, "R WEST")], [conn("e21/w", "inbound")]);
	const ask = (tile: number, trace: string, dest: string, o: object = { firsts: [["c:e43/w", 100]] }) => {
		sent.length = 0;
		router.receive(tile, "ue.route.request", { trace, dest, surface: "nauvis", ...o });
		return sent.slice();
	};
	const reply = (out: Sent[]) => out.find(m => m.kind === "ue.route.reply")!;
	return { router, edges, sent, logs, clock, report, ask, reply };
}

test("UE declares routing's two relay events (R2)", () => {
	assert.ok(plugin.messages!.includes(RouteUpEvent) && plugin.messages!.includes(RouteDownEvent));
	const sent = new RouteDownEvent("ue.route.cancel", { trace: "x.1" });
	const e = RouteDownEvent.fromJSON(JSON.parse(JSON.stringify(sent)));
	assert.equal(e.kind, "ue.route.cancel");
	assert.deepEqual(e.payload, { trace: "x.1" });
});

test("a list from Lua is [] or {} (an empty Lua table), never anything else", () => {
	const valid = lib.compile(Report as any);
	assert.ok(valid({ full: true }));
	assert.ok(valid({ costs: {}, gone: {}, stations: {}, stops_gone: {}, conns: {}, conns_gone: {} }));
	assert.ok(valid({ costs: [["c:e/t1", "s:7", 90]], stops_gone: [7], conns_gone: ["e/t1"] }));
	assert.ok(!valid({ costs: { a: 1 } }));
	assert.deepEqual(list({}), []);
	assert.deepEqual(list([1]), [1]);
});

test("a 3-border trip: every hop in order, the stop's tile reserves it, assigned is logged (D42, D43)", () => {
	const w = world();
	const out = w.ask(4, "r1", "R WEST");
	assert.equal(w.reply(out).to, 4);
	assert.equal(w.reply(out).payload.ok, true);
	assert.equal(keys(w.reply(out).payload.hops), "e43/w,e32/w,e21/w");
	assert.deepEqual(out.find(m => m.kind === "ue.route.reserve"), reserve(1, "r1", 11));
	const line = w.logs.find(l => l.phase === "assigned")!;
	assert.equal(line.op, "ue.route");
	assert.equal(line.fields.trace, "r1");
	assert.equal(line.fields.stop_tile, "tile1");
});

test("a costs report after a search drops the tile's cached adjacency: the next route takes the cheaper box", () => {
	const w = world();
	assert.equal(keys(w.reply(w.ask(4, "r1", "R WEST")).payload.hops), "e43/w,e32/w,e21/w");
	w.router.receive(4, "ue.route.arrived", { trace: "r1" }); // r1's planned traffic would otherwise move r2 by itself
	w.router.receive(3, "ue.route.report", { costs: [["c:e43/w", "c:e32/w", 400]] });
	assert.equal(keys(w.reply(w.ask(4, "r2", "R WEST")).payload.hops), "e43/w,e32/w2,e21/w");
});

test("border re-route keeps the plan", () => {
	const w = world();
	w.ask(4, "r1", "R WEST");
	const out = w.ask(3, "r1", "R WEST", { via: "e43/w" });
	assert.equal(keys(w.reply(out).payload.hops), "e32/w,e21/w");
	assert.equal(out.find(m => m.kind === "ue.route.reserve"), undefined);
	assert.equal(out.find(m => m.kind === "ue.route.cancel"), undefined);
	assert.equal(w.logs.at(-1)?.phase, "assigned");
});

test("A-vs-B: a held train sends the next by the other connector (spike 8's open question)", () => {
	const w = world({
		tile3: [conn("e43/w", "inbound"), conn("e32/w", "outbound", { held: true }), conn("e32/w2", "outbound")],
	});
	assert.equal(keys(w.reply(w.ask(4, "r1", "R WEST")).payload.hops), "e43/w,e32/w2,e21/w");
});

test("not ready and queued carriages cost too", () => {
	const notReady = world({
		tile3: [conn("e43/w", "inbound"), conn("e32/w", "outbound", { ready: false }), conn("e32/w2", "outbound")],
	});
	assert.equal(keys(notReady.reply(notReady.ask(4, "r1", "R WEST")).payload.hops), "e43/w,e32/w2,e21/w");
	const queued = world({
		tile2: [conn("e32/w", "inbound", { queued: 20 }), conn("e32/w2", "inbound"), conn("e21/w", "outbound")],
	});
	assert.equal(keys(queued.reply(queued.ask(4, "r1", "R WEST")).payload.hops), "e43/w,e32/w2,e21/w");
});

test("planned traffic spreads, and is released when the crossing commits", () => {
	const w = world();
	assert.equal(keys(w.reply(w.ask(4, "r1", "R WEST")).payload.hops), "e43/w,e32/w,e21/w");
	assert.equal(keys(w.reply(w.ask(4, "r2", "R WEST")).payload.hops), "e43/w,e32/w2,e21/w");
	w.ask(2, "r1", "R WEST", { via: "e32/w" });
	assert.equal(keys(w.reply(w.ask(4, "r3", "R WEST")).payload.hops), "e43/w,e32/w,e21/w");
});

test("a connector not live is never used", () => {
	const w = world({
		tile3: [
			conn("e43/w", "inbound"), conn("e32/w", "outbound", { live: false }),
			conn("e32/w2", "outbound", { live: false }),
		],
	});
	const out = w.ask(4, "r1", "R WEST");
	assert.equal(w.reply(out).payload.ok, false);
	assert.equal(w.reply(out).payload.reason, "no_path");
	const failed = w.logs.filter(l => l.phase === "failed");
	assert.equal(failed.length, 1);
	assert.equal(failed[0].level, "warn");
});

test("failed logs once per trace until it succeeds", () => {
	const w = world();
	assert.equal(w.reply(w.ask(4, "r1", "NOWHERE")).payload.reason, "unknown_station");
	assert.equal(w.reply(w.ask(4, "r1", "NOWHERE")).payload.reason, "unknown_station");
	assert.equal(w.logs.filter(l => l.phase === "failed").length, 1);
});

test("same-name rule: priority, then free slot, then cost (D42 point 2)", () => {
	const cheaper = world({ stations2: [station(21, "R WEST")] });
	assert.deepEqual(cheaper.ask(4, "r1", "R WEST").find(m => m.kind === "ue.route.reserve"), reserve(2, "r1", 21));
	const priority = world({
		stations2: [station(21, "R WEST")], stations1: [station(11, "R WEST", { priority: 60 })],
	});
	assert.deepEqual(priority.ask(4, "r1", "R WEST").find(m => m.kind === "ue.route.reserve"), reserve(1, "r1", 11));
	const full = world({
		stations2: [station(21, "R WEST")], stations1: [station(11, "R WEST", { priority: 60, limit: 1, count: 1 })],
	});
	assert.deepEqual(full.ask(4, "r1", "R WEST").find(m => m.kind === "ue.route.reserve"), reserve(2, "r1", 21));
});

test("reservations count against free slots", () => {
	const w = world({
		stations2: [station(21, "R WEST", { limit: 1 })], stations1: [station(11, "R WEST", { limit: 1 })],
	});
	assert.deepEqual(w.ask(4, "r1", "R WEST").find(m => m.kind === "ue.route.reserve"), reserve(2, "r1", 21));
	assert.deepEqual(w.ask(4, "r2", "R WEST").find(m => m.kind === "ue.route.reserve"), reserve(1, "r2", 11));
	assert.equal(w.reply(w.ask(4, "r3", "R WEST")).payload.reason, "destination_full");
});

test("a booking holds when the limit drops: the re-ask keeps the stop, the next route is turned away", () => {
	const w = world({ stations1: [station(11, "R WEST", { limit: 2 })] });
	assert.deepEqual(w.ask(4, "r1", "R WEST").find(m => m.kind === "ue.route.reserve"), reserve(1, "r1", 11));
	w.report(
		1, [["c:e21/w", "s:11", 100]], [station(11, "R WEST", { limit: 0, script: 1 })], [conn("e21/w", "inbound")],
	);
	const out = w.ask(3, "r1", "R WEST", { via: "e43/w" });
	assert.equal(w.reply(out).payload.ok, true);
	assert.equal(w.logs.at(-1)?.phase, "assigned");
	assert.equal(out.find(m => m.kind === "ue.route.cancel"), undefined);
	assert.equal(w.reply(w.ask(4, "r2", "R WEST")).payload.reason, "destination_full");
	const better = world({
		stations1: [station(11, "R WEST", { limit: 2 })], stations2: [station(21, "R WEST", { limit: 1, count: 1 })],
	});
	better.ask(4, "r1", "R WEST");
	better.report(
		1, [["c:e21/w", "s:11", 100]], [station(11, "R WEST", { limit: 0, script: 1 })], [conn("e21/w", "inbound")],
	);
	better.report(
		2, [["c:e32/w", "c:e21/w", 200], ["c:e32/w", "s:21", 50]], [station(21, "R WEST", { priority: 60 })],
		[conn("e32/w", "inbound"), conn("e21/w", "outbound")],
	);
	const moved = better.ask(3, "r1", "R WEST", { via: "e43/w" });
	assert.deepEqual(moved.find(m => m.kind === "ue.route.reserve"), reserve(2, "r1", 21));
	assert.equal(better.logs.at(-1)?.phase, "rerouted");
});

/** Limit-1 stop on tile 1 with route r1 booked to it; row is what the tile reports for it before r1 arrives. */
function arrival(row: object) {
	const w = world({ stations1: [station(11, "R WEST", { limit: 1 })] });
	assert.deepEqual(w.ask(4, "r1", "R WEST").find(m => m.kind === "ue.route.reserve"), reserve(1, "r1", 11));
	const rows = (extra: object) => w.report(
		1, [["c:e21/w", "s:11", 100]], [station(11, "R WEST", { limit: 1, ...extra })], [conn("e21/w", "inbound")],
	);
	rows(row);
	w.router.receive(1, "ue.route.arrived", { trace: "r1" });
	return { w, rows };
}
const isFull = (w: ReturnType<typeof world>) => w.reply(w.ask(4, "r2", "R WEST")).payload.reason === "destination_full";

test("an arrival frees no slot before the tile's next row (the stop's script reservation became a train)", () => {
	const { w, rows } = arrival({ count: 1, script: 1 });
	assert.ok(isFull(w), "stale row: arrival applied at once");
	rows({ count: 1, script: 0 });
	assert.ok(isFull(w), "the row that shows the train heading there");
	rows({ count: 0, script: 0 });
	assert.deepEqual(w.ask(4, "r2", "R WEST").find(m => m.kind === "ue.route.reserve"), reserve(1, "r2", 11));
});

test("an arrival whose reservation the row never showed still holds the slot", () => {
	const { w } = arrival({ count: 0, script: 0 });
	assert.ok(isFull(w));
});

test("arrived from a tile that isn't the stop's leaves its free slots as they were", () => {
	const w = world({ stations1: [station(11, "R WEST", { limit: 1 })] });
	w.ask(4, "r1", "R WEST");
	w.router.receive(2, "ue.route.arrived", { trace: "r1" });
	assert.deepEqual(w.ask(4, "r2", "R WEST").find(m => m.kind === "ue.route.reserve"), reserve(1, "r2", 11));
});

test("a stop gone from a report: the next request fails and its reservation is cancelled (failed)", () => {
	const w = world();
	assert.deepEqual(w.ask(4, "r1", "R WEST").find(m => m.kind === "ue.route.reserve"), reserve(1, "r1", 11));
	w.report(1, [["c:e21/w", "s:11", 100]], [], [conn("e21/w", "inbound")]);
	const out = w.ask(3, "r1", "R WEST", { via: "e43/w" });
	assert.equal(w.reply(out).payload.reason, "unknown_station");
	assert.deepEqual(out.find(m => m.kind === "ue.route.cancel"), cancelled(1, "r1", "failed"));
});

test("the reservation lifecycle: re-routed, arrived on the stop's tile, lost (D43)", () => {
	const w = world({
		stations2: [station(21, "R WEST")],
		stations1: [station(11, "R WEST", { priority: 60, limit: 1 })],
	});
	assert.deepEqual(w.ask(4, "r1", "R WEST").find(m => m.kind === "ue.route.reserve"), reserve(1, "r1", 11));
	w.report(
		1, [["c:e21/w", "s:11", 100]], [station(11, "R WEST", { priority: 40, limit: 1, count: 1 })],
		[conn("e21/w", "inbound")], // a booking only moves to a better stop
	);
	const out = w.ask(3, "r1", "R WEST", { via: "e43/w" });
	assert.deepEqual(out.find(m => m.kind === "ue.route.cancel"), cancelled(1, "r1", "rerouted"));
	assert.deepEqual(out.find(m => m.kind === "ue.route.reserve"), reserve(2, "r1", 21));
	assert.equal(w.logs.at(-1)?.phase, "rerouted");
	assert.ok("was" in w.logs.at(-1)!.fields);
	w.sent.length = 0;
	w.router.receive(2, "ue.route.arrived", { trace: "r1" });
	assert.equal(w.sent.length, 0, "arrived on the stop's tile: the tile already released it");
	assert.equal(w.router.routes.has("r1"), false);
	assert.deepEqual(w.ask(4, "r2", "R WEST").find(m => m.kind === "ue.route.reserve"), reserve(2, "r2", 21));
	w.sent.length = 0;
	w.router.receive(4, "ue.route.lost", { trace: "r2", reason: "destroyed" });
	assert.deepEqual(w.sent.find(m => m.kind === "ue.route.cancel"), cancelled(2, "r2", "lost"));
});

test("resync sends the tile's reservations and the whole station list; routes round-trip through toJSON", () => {
	const w = world();
	w.ask(4, "r1", "R WEST");
	w.sent.length = 0;
	w.router.resync(1);
	assert.deepEqual(
		w.sent.find(m => m.kind === "ue.route.resync"),
		{ to: 1, kind: "ue.route.resync", payload: { reservations: [{ trace: "r1", unit: 11 }] } },
	);
	const stations = w.sent.filter(m => m.kind === "ue.route.stations" && m.to === 1);
	assert.equal(stations[0].payload.full, true, "a resync's list replaces the tile's");
	assert.ok(w.logs.some(l => l.op === "ue.routing" && l.phase === "resync" && l.fields.reservations === 1));
	const saved = JSON.parse(JSON.stringify(w.router.toJSON()));
	const router2 = new Router(port().port, saved);
	assert.deepEqual(router2.routes.get("r1")?.stop, { tile: 1, unit: 11 });
});

test("a train's own costs as the origin, its keys whole (R23)", () => {
	const w = world();
	assert.equal(w.reply(w.ask(4, "r1", "R WEST", { firsts: [["c:e43/w", 40]] })).payload.ok, true);
	const out = w.ask(4, "r1", "R WEST", { firsts: {} });
	assert.equal(w.reply(out).payload.ok, false);
	assert.equal(w.reply(out).payload.reason, "no_path");
});

test("a partial report from an unknown tile asks for a resync", () => {
	const w = world();
	w.sent.length = 0;
	w.router.receive(9, "ue.route.report", { costs: {} });
	assert.equal(w.sent.filter(m => m.kind === "ue.route.resync" && m.to === 9).length, 1);
});

test("a tile with no table gets one resync, not one per non-full report, until its full report lands", () => {
	const w = world();
	w.sent.length = 0;
	w.router.receive(9, "ue.route.report", { costs: {} });
	w.router.receive(9, "ue.route.report", { costs: {} });
	assert.equal(w.sent.filter(m => m.kind === "ue.route.resync" && m.to === 9).length, 1);
	w.router.receive(9, "ue.route.report", { full: true });
	w.router.drop(9);
	w.router.receive(9, "ue.route.report", { costs: {} });
	assert.equal(w.sent.filter(m => m.kind === "ue.route.resync" && m.to === 9).length, 2, "a dropped tile asks anew");
});

test("the station list: names, their tiles, free slots (-1 when unlimited)", () => {
	const w = world({ stations2: [station(21, "R WEST", { limit: 2 })] });
	w.ask(4, "r1", "R WEST");
	const list1 = w.router.stationEntries();
	assert.deepEqual(
		list1.find(s => s.name === "HOME4"),
		{ surface: "nauvis", name: "HOME4", tiles: ["tile4"], free: -1 },
	);
	assert.equal(list1.find(s => s.name === "R MID"), undefined);
	assert.deepEqual(
		list1.find(s => s.name === "R WEST"),
		{ surface: "nauvis", name: "R WEST", tiles: ["tile1", "tile2"], free: -1 },
	);
	const w2 = world({
		stations2: [station(21, "R WEST", { limit: 2 })], stations1: [station(11, "R WEST", { limit: 1 })],
	});
	w2.ask(4, "r1", "R WEST");
	assert.deepEqual(
		w2.router.stationEntries().find(s => s.name === "R WEST"),
		{ surface: "nauvis", name: "R WEST", tiles: ["tile1", "tile2"], free: 2 },
	);
});

// The surfaces amendment (§6.2, R31): tile 1 has R WEST on Nauvis (11) and on Vulcanus (12, priority 60), and tile 2
// a Vulcanus box to it (v21/w). Tile 1's report also carries a Nauvis row to the Vulcanus stop, which no tile sends
// (R33): only the surface rule keeps a Nauvis request off it.
test("per planet: a Nauvis request never chooses the same-named Vulcanus stop; a Vulcanus request does (R31)", () => {
	const w = world({
		stations1: [station(11, "R WEST"), station(12, "R WEST", { surface: "vulcanus", priority: 60 })],
	});
	w.edges.push(edge("v21", 2, 1, ["w"], "vulcanus"));
	w.router.receive(2, "ue.route.report", { conns: [conn("v21/w", "outbound")] });
	w.router.receive(1, "ue.route.report", {
		costs: [["c:v21/w", "s:12", 30], ["c:e21/w", "s:12", 100]], conns: [conn("v21/w", "inbound")],
	});
	assert.deepEqual(w.ask(4, "r1", "R WEST").find(m => m.kind === "ue.route.reserve"), reserve(1, "r1", 11));
	const out = w.ask(2, "r2", "R WEST", { surface: "vulcanus", firsts: [["c:v21/w", 50]] });
	assert.equal(keys(w.reply(out).payload.hops), "v21/w");
	assert.deepEqual(out.find(m => m.kind === "ue.route.reserve"), reserve(1, "r2", 12));
	const line = w.logs.find(l => l.phase === "assigned" && l.fields.trace === "r2")!;
	assert.equal(line.fields.surface, "vulcanus", "§10: assigned carries the surface");
});

test("per planet: a name only on Vulcanus is unknown_station to a Nauvis train (R31)", () => {
	const w = world({ stations1: [station(11, "R WEST"), station(13, "V ONLY", { surface: "vulcanus" })] });
	assert.equal(w.reply(w.ask(4, "r1", "V ONLY")).payload.reason, "unknown_station");
});

test("the station list holds one entry per (surface, name) (R35)", () => {
	const w = world({
		stations1: [station(11, "R WEST"), station(12, "R WEST", { surface: "vulcanus", limit: 1 })],
	});
	assert.deepEqual(w.router.stationEntries().filter(s => s.name === "R WEST"), [
		{ surface: "nauvis", name: "R WEST", tiles: ["tile1"], free: -1 },
		{ surface: "vulcanus", name: "R WEST", tiles: ["tile1"], free: 1 },
	]);
});

// Ruling P1: the same-name rule runs over every tile including the asking one; R4 puts the asking tile's own stops of
// that name among the train's own goals (s: keys in firsts).
test("P1: a full local stop and a free remote one route remotely, reserved there", () => {
	const w = world({ stations4: [station(41, "R WEST", { limit: 1, count: 1 })] });
	const out = w.ask(4, "r1", "R WEST", { firsts: [["c:e43/w", 100], ["s:41", 50]] });
	assert.equal(w.reply(out).payload.ok, true);
	assert.equal(keys(w.reply(out).payload.hops), "e43/w,e32/w,e21/w");
	assert.deepEqual(out.find(m => m.kind === "ue.route.reserve"), reserve(1, "r1", 11));
});

test("P1: a free local stop answers local, nothing reserved", () => {
	const w = world({ stations4: [station(41, "R WEST")] });
	const out = w.ask(4, "r1", "R WEST", { firsts: [["c:e43/w", 100], ["s:41", 50]] });
	assert.equal(w.reply(out).payload.ok, false);
	assert.equal(w.reply(out).payload.reason, "local");
	assert.equal(out.find(m => m.kind === "ue.route.reserve"), undefined);
	assert.equal(w.router.routes.get("r1")?.local, true, "kept, with no stop and no hops (R30)");
});

test("P1: a local stop reached only out and back is routed through the other tile, reserved on the asking tile", () => {
	const { port: p, sent } = port([edge("eAB", 5, 6, ["x"]), edge("eBA", 6, 5, ["y"])]);
	const router = new Router(p);
	router.receive(5, "ue.route.report", {
		full: true, costs: [["c:eBA/y", "s:51", 30]], stations: [station(51, "LOOP")],
		conns: [conn("eAB/x", "outbound"), conn("eBA/y", "inbound")],
	});
	router.receive(6, "ue.route.report", {
		full: true, costs: [["c:eAB/x", "c:eBA/y", 100]], stations: [],
		conns: [conn("eAB/x", "inbound"), conn("eBA/y", "outbound")],
	});
	router.receive(5, "ue.route.request", { trace: "r1", dest: "LOOP", surface: "nauvis", firsts: [["c:eAB/x", 10]] });
	const reply = sent.find(m => m.kind === "ue.route.reply")!;
	assert.equal(reply.payload.ok, true);
	assert.equal(keys(reply.payload.hops), "eAB/x,eBA/y");
	assert.deepEqual(sent.find(m => m.kind === "ue.route.reserve"), reserve(5, "r1", 51));
});

test("P1: a via re-ask whose local stop is reached only out and back keeps the hops and the reservation", () => {
	const { port: p, sent } = port([edge("eAB", 5, 6, ["x"]), edge("eBA", 6, 5, ["y", "z"])]);
	const router = new Router(p);
	router.receive(5, "ue.route.report", {
		full: true, costs: [["c:eBA/y", "c:eAB/x", 20], ["c:eBA/z", "s:51", 30]], stations: [station(51, "LOOP")],
		conns: [conn("eAB/x", "outbound"), conn("eBA/y", "inbound"), conn("eBA/z", "inbound")],
	});
	router.receive(6, "ue.route.report", {
		full: true, costs: [["c:eAB/x", "c:eBA/z", 100]], stations: [],
		conns: [conn("eAB/x", "inbound"), conn("eBA/y", "outbound"), conn("eBA/z", "outbound")],
	});
	const ask = (o: object) => {
		sent.length = 0;
		router.receive(5, "ue.route.request", { trace: "r1", dest: "LOOP", surface: "nauvis", ...o });
	};
	ask({ firsts: [["c:eAB/x", 10]] });
	ask({ via: "eBA/y" });
	const reply = sent.find(m => m.kind === "ue.route.reply")!;
	assert.equal(reply.payload.ok, true);
	assert.equal(keys(reply.payload.hops), "eAB/x,eBA/z");
	assert.equal(sent.find(m => m.kind === "ue.route.cancel"), undefined);
});

test("a report in standalone parts builds the same table as the report sent whole (§7.9, R8)", () => {
	const costs: [string, string, number][] = [["c:a", "s:1", 10], ["c:a", "s:2", 20], ["c:b", "s:1", 30]];
	const stations = [station(1, "ONE"), station(2, "TWO")];
	const conns = [conn("a", "inbound"), conn("b", "outbound")];
	const whole = new Router(port().port);
	whole.receive(5, "ue.route.report", { full: true, costs, stations, conns });
	const split = new Router(port().port);
	split.receive(5, "ue.route.report", { full: true });
	split.receive(5, "ue.route.report", { stations: [stations[0]] });
	split.receive(5, "ue.route.report", { costs: [costs[0], costs[1]] });
	split.receive(5, "ue.route.report", { stations: [stations[1]], conns });
	split.receive(5, "ue.route.report", { costs: [costs[2]] });
	assert.deepEqual(split.tiles.get(5), whole.tiles.get(5));
});

test("removals apply on their own, and full starts the tile's table again (§7.9)", () => {
	const r = new Router(port().port);
	r.receive(5, "ue.route.report", {
		full: true, costs: [["c:a", "s:1", 10], ["c:a", "s:2", 20]], stations: [station(1, "ONE"), station(2, "TWO")],
		conns: [conn("a", "inbound")],
	});
	r.receive(5, "ue.route.report", { gone: [["c:a", "s:2"]], stops_gone: [2], conns_gone: ["a"] });
	const t = r.tiles.get(5)!;
	assert.deepEqual([...t.costs.get("c:a")!], [["s:1", 10]]);
	assert.deepEqual([...t.stations.keys()], [1]);
	assert.equal(t.conns.size, 0);
	r.receive(5, "ue.route.report", { full: true });
	assert.equal(r.tiles.get(5)!.costs.size + r.tiles.get(5)!.stations.size, 0);
});

test("the station list goes in parts of at most 3000 bytes, full on the first; in order, the whole list", () => {
	const set = Array.from({ length: 200 }, (_, i) => ({
		surface: "nauvis", name: `STATION ${i} ${"x".repeat(20)}`, tiles: ["gridworld_0_0", "gridworld_1_0"], free: i,
	}));
	const parts = stationParts(set, [{ surface: "vulcanus", name: "OLD" }], true);
	assert.ok(parts.length > 1, `${parts.length} parts`);
	for (const p of parts) {
		assert.ok(JSON.stringify(p).length <= BUDGET, `a part of ${JSON.stringify(p).length} bytes`);
	}
	assert.equal(parts[0].full, true);
	assert.ok(parts.slice(1).every(p => p.full === undefined));
	assert.deepEqual(parts.flatMap(p => p.set), set);
	assert.deepEqual(parts.flatMap(p => p.gone), [{ surface: "vulcanus", name: "OLD" }]);
	assert.deepEqual(stationParts([], [], true), [{ full: true, set: [], gone: [] }]);
	assert.equal(stationParts([], []).length, 0);
});

test("routes load from universal_edges_routes.json, or once from the prototype's router_state.json (R27)", async () => {
	const dir = await mkdtemp(join(tmpdir(), "routing-"));
	assert.equal(await loadRoutes(dir), undefined, "neither file: no saved routes");
	const old = { routes: [{ trace: "old.1", dest: "X", tile: 1, hops: [] }] };
	await saveDataFile(join(dir, "router_state.json"), [], old);
	assert.equal((await loadRoutes(dir))?.routes?.[0].trace, "old.1", "the prototype's file while ours is missing");
	await saveDataFile(join(dir, ROUTES_FILE), [], { routes: [{ trace: "new.1", dest: "X", tile: 1, hops: [] }] });
	assert.equal((await loadRoutes(dir))?.routes?.[0].trace, "new.1", "ours, once it exists");
});

/** The prototype's search (router/graph.ts before SP4): adjacency rebuilt per call, an array scan for the minimum. */
function scan(tiles: Map<number, TileData>, ls: Link[], traffic: Map<string, number>, origins: [string, number][]) {
	const out = new Map<string, { to: string; cost: number; link?: Link }[]>();
	const add = (from: string, to: string, cost: number, link?: Link) => {
		const edges = out.get(from) ?? [];
		edges.push({ to, cost, link });
		out.set(from, edges);
	};
	for (const [tile, t] of tiles) {
		for (const [from, row] of t.costs) {
			for (const [to, cost] of row) {
				add(`${tile}|${from}`, `${tile}|${to}`, cost);
			}
		}
	}
	for (const link of ls) {
		const cost = crossingCost(link, tiles, traffic);
		if (Number.isFinite(cost)) {
			add(`${link.from}|c:${link.key}`, `${link.to}|c:${link.key}`, cost, link);
		}
	}
	const dist = new Map<string, number>();
	const prev = new Map<string, { prev: string; link?: Link }>();
	for (const [node, cost] of origins) {
		if (cost < (dist.get(node) ?? Infinity)) {
			dist.set(node, cost);
		}
	}
	const done = new Set<string>();
	for (;;) {
		let u: string | undefined;
		let best = Infinity;
		for (const [node, d] of dist) {
			if (!done.has(node) && d < best) {
				best = d;
				u = node;
			}
		}
		if (u === undefined) {
			return { dist, prev };
		}
		done.add(u);
		for (const e of out.get(u) ?? []) {
			if (best + e.cost < (dist.get(e.to) ?? Infinity)) {
				dist.set(e.to, best + e.cost);
				prev.set(e.to, { prev: u, link: e.link });
			}
		}
	}
}

/** Every stop node of a router's tiles. */
const stopNodes = (router: Router) => [...router.tiles]
	.flatMap(([tile, t]) => [...t.stations.keys()].map(unit => `${tile}|s:${unit}`));

/** A router fed world59's reports. */
function big(seed: number) {
	const w = world59(seed);
	const { port: p, sent, logs } = port(w.edges);
	const router = new Router(p);
	for (const [tile, report] of w.reports) {
		router.receive(tile, "ue.route.report", report);
	}
	return { w, router, sent, logs };
}

test("the heap search gives the prototype scan's costs and hops, on the row and on 59 tiles (§8.1)", () => {
	type Origins = [string, number][];
	const check = (tiles: Map<number, TileData>, edges: EdgeRecord[], origins: Origins, nodes: string[]) => {
		const heap = shortest(tiles, linkMap(edges), new Map(), origins, new Set(nodes));
		const ref = scan(tiles, links(edges), new Map(), origins);
		for (const node of nodes) {
			const d = ref.dist.get(node);
			assert.equal(heap.dist.get(node), d, node);
			if (d !== undefined) {
				assert.equal(keys(hopsTo(heap.prev, node)), keys(hopsTo(ref.prev, node)), node);
			}
		}
	};
	const w = world();
	check(w.router.tiles, w.edges, [["4|c:e43/w", 100]], stopNodes(w.router));
	const b = big(20261004);
	const rand = rng(7);
	const all = stopNodes(b.router);
	for (let i = 0; i < 20; i++) {
		const tile = b.w.tiles[Math.floor(rand() * b.w.tiles.length)];
		const origins = b.w.firsts(tile, rand).map(([key, cost]): [string, number] => [`${tile}|${key}`, cost]);
		check(b.router.tiles, b.w.edges, origins, all);
	}
});

test("the early exit picks what a full search picks (§8.1)", () => {
	const b = big(20261005);
	const rand = rng(11);
	const ls = linkMap(b.w.edges);
	for (let i = 0; i < 30; i++) {
		const tile = b.w.tiles[Math.floor(rand() * b.w.tiles.length)];
		const dest = b.w.names[Math.floor(rand() * b.w.names.length)];
		const origins = b.w.firsts(tile, rand).map(([key, cost]): [string, number] => [`${tile}|${key}`, cost]);
		const named = [...b.router.tiles].flatMap(([t, data]) => [...data.stations.values()]
			.filter(s => s.name === dest).map(stop => ({ tile: t, stop })));
		const targets = new Set(named.map(n => `${n.tile}|s:${n.stop.unit}`));
		const early = shortest(b.router.tiles, ls, new Map(), origins, targets);
		const full = shortest(b.router.tiles, ls, new Map(), origins, new Set(["never"]));
		const one = () => 1;
		const got = choose(named, early.dist, early.prev, one, tile);
		assert.deepEqual(got, choose(named, full.dist, full.prev, one, tile), dest);
	}
});

test("a local winner keeps its route registered, and local is logged once across two requests (R30)", () => {
	const w = world({ stations4: [station(41, "R WEST")] });
	const firsts = { firsts: [["c:e43/w", 100], ["s:41", 50]] };
	assert.equal(w.reply(w.ask(4, "r1", "R WEST", firsts)).payload.reason, "local");
	assert.equal(w.reply(w.ask(4, "r1", "R WEST", firsts)).payload.reason, "local");
	assert.equal(w.router.routes.get("r1")?.stop, undefined);
	assert.equal(w.logs.filter(l => l.op === "ue.route" && l.phase === "local").length, 1);
});

test("a full local-only stop answers destination_full, logged at info (R4, R12)", () => {
	const w = world({ stations4: [station(41, "HOME FULL", { limit: 1, count: 1 })] });
	const out = w.ask(4, "r1", "HOME FULL", { firsts: [["c:e43/w", 100], ["s:41", 50]] });
	assert.equal(w.reply(out).payload.reason, "destination_full");
	const failed = w.logs.filter(l => l.phase === "failed");
	assert.equal(failed.length, 1);
	assert.equal(failed[0].level, "info");
});

test("arrived from a tile that isn't the stop's cancels the reservation (§6.6)", () => {
	const w = world();
	w.ask(4, "r1", "R WEST");
	w.sent.length = 0;
	w.router.receive(2, "ue.route.arrived", { trace: "r1" });
	assert.deepEqual(w.sent.find(m => m.kind === "ue.route.cancel"), cancelled(1, "r1", "lost"));
	assert.equal(w.router.routes.has("r1"), false);
});

test("manual from the route's tile cancels its reservation and keeps the route; from elsewhere, nothing (R24)", () => {
	const w = world();
	w.ask(4, "r1", "R WEST");
	w.sent.length = 0;
	w.router.receive(3, "ue.route.manual", { trace: "r1" });
	assert.equal(w.sent.length, 0, "a late message from a tile the train has left");
	w.router.receive(4, "ue.route.manual", { trace: "r1" });
	assert.deepEqual(w.sent, [cancelled(1, "r1", "manual")]);
	assert.ok(w.router.routes.has("r1"));
	assert.equal(w.router.routes.get("r1")?.stop, undefined);
});

test("the 5-minute rule: a route no message named for more than 300 s is dropped and its reservation cancelled", () => {
	const w = world();
	w.ask(4, "r1", "R WEST");
	w.clock.t = 1_500;
	w.ask(4, "r2", "R WEST");
	w.clock.t = 300_500;
	w.sent.length = 0;
	w.router.gc();
	assert.equal(w.router.routes.has("r1"), false, "unseen for 300.5 s: dropped");
	assert.equal(w.router.routes.has("r2"), true, "unseen for 299 s: kept");
	assert.deepEqual(w.sent, [cancelled(1, "r1", "gc")]);
	const gc = w.logs.find(l => l.phase === "gc")!;
	assert.equal(gc.level, "warn");
	const { trace, dest, tile, unseen_s: unseen } = gc.fields;
	assert.deepEqual([trace, dest, tile, unseen], ["r1", "R WEST", "tile4", 301]);
});

test("alive: active keeps a route, reserved doesn't; unknown ones are forgotten, orphans cancelled", () => {
	const w = world();
	w.ask(4, "r1", "R WEST");
	w.ask(4, "r2", "R WEST");
	w.clock.t = 200_000;
	w.sent.length = 0;
	w.router.receive(4, "ue.route.alive", { active: ["r1", "x.9"], reserved: {} });
	assert.deepEqual(w.sent, [{ to: 4, kind: "ue.route.forgotten", payload: { traces: ["x.9"] } }]);
	assert.ok(w.logs.some(l => l.op === "ue.route" && l.phase === "forgotten" && l.fields.trace === "x.9"));
	w.sent.length = 0;
	w.router.receive(1, "ue.route.alive", { active: {}, reserved: ["r2", "x.8"] });
	assert.deepEqual(w.sent, [cancelled(1, "x.8", "orphan")], "r2 is held where the controller has it; x.8 isn't");
	w.sent.length = 0;
	w.router.receive(2, "ue.route.alive", { active: {}, reserved: ["r2"] });
	assert.deepEqual(w.sent, [cancelled(2, "r2", "orphan")], "held on the wrong tile");
	assert.ok(w.logs.some(l => l.op === "ue.reservation" && l.phase === "orphan" && l.fields.tile === "tile2"));
	w.clock.t = 300_500;
	w.router.gc();
	assert.equal(w.router.routes.has("r1"), true, "an active mention refreshed it");
	assert.equal(w.router.routes.has("r2"), false, "reserved mentions don't");
});

test("loaded routes start with seen at the load time; seen is not saved (§4.4)", () => {
	const w = world();
	w.ask(4, "r1", "R WEST");
	const saved = JSON.parse(JSON.stringify(w.router.toJSON()));
	assert.equal(saved.routes[0].seen, undefined);
	const loaded = new Router(port([], { t: 1_000_000 }).port, saved);
	assert.equal(loaded.routes.get("r1")?.seen, 1_000_000);
});

test("the station-list broadcast sends only the names that changed, and gone for removed ones (§7.9)", () => {
	const w = world();
	w.sent.length = 0;
	w.router.broadcastStations();
	const first = w.sent.filter(m => m.kind === "ue.route.stations" && m.to === 1).map(m => m.payload);
	assert.deepEqual(first.flatMap(p => p.set.map((e: { name: string }) => e.name)), ["HOME4", "R MID", "R WEST"]);
	w.sent.length = 0;
	w.router.broadcastStations();
	assert.equal(w.sent.length, 0, "nothing changed, nothing sent");
	w.router.receive(2, "ue.route.report", { stations: [station(21, "R MID", { limit: 3 })] });
	w.router.receive(4, "ue.route.report", { stops_gone: [41] });
	w.sent.length = 0;
	w.router.broadcastStations();
	const parts = w.sent.filter(m => m.kind === "ue.route.stations" && m.to === 1).map(m => m.payload);
	assert.deepEqual(parts.flatMap(p => p.set.map((e: { name: string }) => e.name)), ["R MID"]);
	assert.deepEqual(parts.flatMap(p => p.gone), [{ surface: "nauvis", name: "HOME4" }]);
	assert.ok(parts.every(p => p.full === undefined), "changes only");
});

test("the list's diff and gone go by (surface, name): a name on a second planet comes and goes alone (R35)", () => {
	const w = world();
	w.router.broadcastStations();
	w.router.receive(1, "ue.route.report", { stations: [station(12, "R WEST", { surface: "vulcanus" })] });
	w.sent.length = 0;
	w.router.broadcastStations();
	const added = w.sent.filter(m => m.kind === "ue.route.stations" && m.to === 1).map(m => m.payload);
	assert.deepEqual(added.flatMap(p => p.set), [{ surface: "vulcanus", name: "R WEST", tiles: ["tile1"], free: -1 }]);
	assert.equal(added.flatMap(p => p.gone).length, 0, "Nauvis's R WEST is neither sent again nor gone");
	w.router.receive(1, "ue.route.report", { stops_gone: [12] });
	w.sent.length = 0;
	w.router.broadcastStations();
	const removed = w.sent.filter(m => m.kind === "ue.route.stations" && m.to === 1).map(m => m.payload);
	assert.deepEqual(removed.flatMap(p => p.gone), [{ surface: "vulcanus", name: "R WEST" }]);
	assert.equal(removed.flatMap(p => p.set).length, 0);
	assert.equal(w.reply(w.ask(4, "r1", "R WEST")).payload.ok, true, "Nauvis's R WEST still routes");
});

test("a request while a tile's table is being rebuilt fails once, quietly, and succeeds once its rows land", () => {
	const w = world();
	w.router.receive(2, "ue.route.report", { full: true }); // tile 2's start: its rows are on their way
	assert.equal(w.reply(w.ask(4, "r1", "R WEST")).payload.reason, "no_path");
	w.report(
		2, [["c:e32/w", "c:e21/w", 200], ["c:e32/w2", "c:e21/w", 200]], [station(21, "R MID")],
		[conn("e32/w", "inbound"), conn("e32/w2", "inbound"), conn("e21/w", "outbound")],
	);
	assert.equal(w.reply(w.ask(4, "r1", "R WEST")).payload.ok, true);
	assert.equal(w.logs.filter(l => l.phase === "failed").length, 1);
});

test("a stop renamed: the name index follows its row (Review Focus 4)", () => {
	const w = world();
	assert.equal(w.reply(w.ask(4, "r1", "R WEST")).payload.ok, true);
	w.router.receive(1, "ue.route.report", { stations: [station(11, "R WEST 2")] });
	assert.equal(w.reply(w.ask(4, "r2", "R WEST")).payload.reason, "unknown_station");
	assert.equal(w.reply(w.ask(4, "r3", "R WEST 2")).payload.ok, true);
});

test("a route dropped by the 5-minute rule comes back with its next request (Review Focus 5)", () => {
	const w = world();
	w.ask(4, "r1", "R WEST");
	w.clock.t = 400_000;
	w.router.gc();
	assert.equal(w.router.routes.has("r1"), false);
	const out = w.ask(3, "r1", "R WEST", { via: "e43/w" });
	assert.equal(w.reply(out).payload.ok, true);
	assert.deepEqual(out.find(m => m.kind === "ue.route.reserve"), reserve(1, "r1", 11), "reserved again");
	assert.equal(w.router.routes.get("r1")?.seen, 400_000);
});
