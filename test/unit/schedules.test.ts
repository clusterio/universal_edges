import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import * as lib from "@clusterio/lib";
import { plugin } from "../../index.js";
import { saveDataFile } from "../../runtime/index.js";
import { Counts, Report, SchedDownEvent, SchedUpEvent } from "../../schedules/contracts.js";
import { SCHEDULES_FILE, loadSchedules } from "../../schedules/controller.js";
import { GRACE, ScheduleSync, type Port } from "../../schedules/sync.js";

type Sent = { to: number; kind: string; payload: any };
type Log = { op: string; phase: string; fields: Record<string, unknown> };

/** A Port that records what it is given; tiles 1, 2 and 3 are running. */
function port(tiles = [1, 2, 3]) {
	const sent: Sent[] = [];
	const logs: Log[] = [];
	const p: Port = {
		tiles: () => tiles,
		name: id => `tile${id}`,
		send: (to, kind, payload) => {
			sent.push({ to, kind, payload });
		},
		log: (op, phase, fields) => {
			logs.push({ op, phase, fields });
		},
	};
	return { port: p, sent, logs };
}
/** A group's content: its records' station names, and its interrupts' names. */
const group = (stations: string[], interrupts: string[] = []) => ({
	records: stations.map(station => ({ station })), interrupts,
});
const report = (kind: "group" | "interrupt", name: string, content: unknown, base?: number) => (
	base === undefined ? { kind, name, content } : { kind, name, base, content }
);

test("UE declares the sync's two relay events (sync §6)", () => {
	assert.ok(plugin.messages!.includes(SchedUpEvent) && plugin.messages!.includes(SchedDownEvent));
	const down = new SchedDownEvent("ue.sched.drop", { kind: "group", name: "G" });
	const e = SchedDownEvent.fromJSON(JSON.parse(JSON.stringify(down)));
	assert.equal(e.kind, "ue.sched.drop");
	assert.deepEqual(e.payload, { kind: "group", name: "G" });
});

test("contracts: a report needs a kind, a name and content; counts' rows may be Lua's {} (§6)", () => {
	const validReport = lib.compile(Report as any);
	assert.ok(validReport(report("group", "G", group(["A"]))));
	assert.ok(validReport(report("interrupt", "I", {}, 3)));
	assert.ok(!validReport({ kind: "train", name: "G", content: {} }), "an unknown kind");
	assert.ok(!validReport({ kind: "group", name: "G" }), "no content");
	assert.ok(!validReport(report("group", "G", {}, 1.5)), "a base that isn't an integer");
	const validCounts = lib.compile(Counts as any);
	assert.ok(validCounts({ first: true, rows: {} }));
	assert.ok(validCounts({ rows: [["group", "G", 2], ["interrupt", "I", 5]] }));
	assert.ok(!validCounts({ rows: [["train", "G", 2]] }));
});

test("a new name is accepted at version 1 and goes to every running tile, the reporter's too (§5.3)", () => {
	const { port: p, sent, logs } = port();
	const sync = new ScheduleSync(p);
	sync.receive(2, "ue.sched.report", report("group", "G", group(["A"])));
	assert.deepEqual(sync.entries.group.get("G"), { v: 1, content: group(["A"]) });
	assert.deepEqual(sent.map(m => [m.to, m.kind, m.payload.v]), [
		[1, "ue.sched.set", 1], [2, "ue.sched.set", 1], [3, "ue.sched.set", 1],
	]);
	assert.deepEqual(sent[0].payload, { kind: "group", name: "G", v: 1, content: group(["A"]) });
	assert.equal(logs[0].phase, "report");
	assert.equal(logs[0].fields.tile, "tile2");
	assert.equal(logs[0].fields.v, 1);
});

test("an edit on the current version is accepted as v + 1; one on an older version is refused, and only its tile " +
	"gets the current one back (§5.3)", () => {
	const { port: p, sent, logs } = port();
	const sync = new ScheduleSync(p);
	sync.receive(1, "ue.sched.report", report("interrupt", "I", { name: "I", targets: [] }));
	sync.receive(1, "ue.sched.report", report("interrupt", "I", { name: "I", targets: [{ station: "X" }] }, 1));
	assert.equal(sync.entries.interrupt.get("I")!.v, 2);
	sent.length = 0;
	sync.receive(3, "ue.sched.report", report("interrupt", "I", { name: "I", targets: [{ station: "OLD" }] }, 1));
	assert.equal(sync.entries.interrupt.get("I")!.v, 2, "unchanged");
	assert.deepEqual(sent, [{
		to: 3, kind: "ue.sched.set",
		payload: { kind: "interrupt", name: "I", v: 2, content: { name: "I", targets: [{ station: "X" }] } },
	}]);
	const reject = logs.find(l => l.phase === "reject")!;
	assert.deepEqual([reject.fields.tile, reject.fields.base, reject.fields.v], ["tile3", 1, 2]);
	sent.length = 0;
	sync.receive(2, "ue.sched.report", report("interrupt", "I", { name: "I" }));
	assert.equal(sent.length, 1, "no base, for a name the controller has: refused too (a sweep's re-report)");
});

test("two edits on one version: the first is kept, the second refused (§5.3, §9)", () => {
	const { port: p } = port();
	const sync = new ScheduleSync(p);
	sync.receive(1, "ue.sched.report", report("group", "G", group(["A"])));
	sync.receive(2, "ue.sched.report", report("group", "G", group(["A", "FROM 2"]), 1));
	sync.receive(3, "ue.sched.report", report("group", "G", group(["A", "FROM 3"]), 1));
	assert.deepEqual(sync.entries.group.get("G"), { v: 2, content: group(["A", "FROM 2"]) });
});

test("a name the controller doesn't have is new whatever its base: accepted at version 1", () => {
	const { port: p } = port();
	const sync = new ScheduleSync(p);
	sync.receive(1, "ue.sched.report", report("group", "G", group(["A"]), 7));
	assert.equal(sync.entries.group.get("G")!.v, 1);
});

test("counts: a first part replaces the tile's counts, a later part adds to them (§5.4)", () => {
	const { port: p } = port();
	const sync = new ScheduleSync(p);
	sync.receive(1, "ue.sched.counts", { first: true, rows: [["group", "G", 2]] });
	sync.receive(1, "ue.sched.counts", { rows: [["interrupt", "I", 1]] });
	assert.deepEqual([...sync.counts.get(1)!.group], [["G", 2]]);
	assert.deepEqual([...sync.counts.get(1)!.interrupt], [["I", 1]]);
	sync.receive(1, "ue.sched.counts", { first: true, rows: [["interrupt", "J", 4]] });
	assert.equal(sync.counts.get(1)!.group.size, 0);
	assert.deepEqual([...sync.counts.get(1)!.interrupt], [["J", 4]]);
});

test("lifetime: a name no tile counts is dropped at the third check in a row, on every tile; a count anywhere keeps " +
	"it (§5.5)", () => {
	const { port: p, sent, logs } = port();
	const sync = new ScheduleSync(p);
	sync.receive(1, "ue.sched.report", report("group", "G", group(["A"])));
	sync.receive(1, "ue.sched.report", report("interrupt", "I", { name: "I" }));
	sync.receive(1, "ue.sched.counts", { first: true, rows: [["group", "G", 2], ["interrupt", "I", 2]] });
	sync.receive(2, "ue.sched.counts", { first: true, rows: [["interrupt", "I", 1]] });
	sync.receive(1, "ue.sched.counts", { first: true, rows: {} }); // tile 1's trains left: G is held nowhere
	sent.length = 0;
	for (let i = 1; i < GRACE; i++) {
		sync.sweep();
	}
	assert.ok(sync.entries.group.has("G") && sent.length === 0, "kept for two sweeps of grace");
	sync.receive(3, "ue.sched.counts", { first: true, rows: [["group", "G", 1]] }); // a train arrived on tile 3
	sync.sweep();
	assert.ok(sync.entries.group.has("G"), "a count resets the grace");
	sync.receive(3, "ue.sched.counts", { first: true, rows: {} });
	for (let i = 1; i < GRACE; i++) {
		sync.sweep();
	}
	assert.ok(sync.entries.group.has("G"), "a fresh grace");
	sync.sweep();
	assert.ok(!sync.entries.group.has("G"), "dropped at the third check in a row");
	assert.ok(sync.entries.interrupt.has("I"), "tile 2 still counts I");
	assert.deepEqual(sent.filter(m => m.kind !== "ue.sched.totals").map(m => [m.to, m.kind, m.payload]),
		[1, 2, 3].map(to => [to, "ue.sched.drop", { kind: "group", name: "G" }]));
	assert.equal(logs.find(l => l.phase === "drop")!.fields.v, 1);
});

test("full: every entry, interrupts first, to the one tile (§5.2)", () => {
	const { port: p, sent } = port();
	const sync = new ScheduleSync(p);
	sync.receive(1, "ue.sched.report", report("group", "G", group(["A"], ["I"])));
	sync.receive(1, "ue.sched.report", report("interrupt", "I", { name: "I" }));
	sent.length = 0;
	sync.receive(1, "ue.sched.counts", { first: true, rows: [["group", "G", 2]] });
	sync.full(2);
	assert.deepEqual(sent, [{
		to: 2, kind: "ue.sched.full", payload: { entries: [
			{ kind: "interrupt", name: "I", v: 1, content: { name: "I" } },
			{ kind: "group", name: "G", v: 1, content: group(["A"], ["I"]) },
		] },
	}, {
		to: 2, kind: "ue.sched.totals", payload: { groups: [["G", 2, [["tile1", 2, false]]]] },
	}]);
});

test("totals: a group's trains on every tile, the stopped tile's counted and marked, sorted (group totals)", () => {
	const { port: p } = port([1, 2]); // tile 3 is stopped
	const sync = new ScheduleSync(p);
	sync.receive(2, "ue.sched.counts", {
		first: true, rows: [["group", "B", 1], ["group", "A", 3], ["interrupt", "I", 4]],
	});
	sync.receive(1, "ue.sched.counts", { first: true, rows: [["group", "A", 2], ["group", "Z", 0]] });
	sync.receive(3, "ue.sched.counts", { first: true, rows: [["group", "A", 1]] });
	assert.deepEqual(sync.totals(), { groups: [
		["A", 6, [["tile1", 2, false], ["tile2", 3, false], ["tile3", 1, true]]],
		["B", 1, [["tile2", 1, false]]],
	] });
});

test("totals: a sweep broadcasts them to every running tile only when they changed", () => {
	const { port: p, sent, logs } = port([1, 2]);
	const sync = new ScheduleSync(p);
	sync.sweep();
	assert.equal(sent.length, 0, "no groups: nothing to say");
	sync.receive(1, "ue.sched.counts", { first: true, rows: [["group", "G", 2]] });
	sync.sweep();
	const payload = { groups: [["G", 2, [["tile1", 2, false]]]] };
	assert.deepEqual(sent.filter(m => m.kind === "ue.sched.totals").map(m => [m.to, m.payload]),
		[[1, payload], [2, payload]]);
	assert.deepEqual(logs.filter(l => l.phase === "totals").map(l => l.fields), [{ groups: 1 }]);
	sent.length = 0;
	sync.sweep();
	assert.equal(sent.length, 0, "unchanged: not again");
	sync.receive(2, "ue.sched.counts", { first: true, rows: [["group", "G", 1]] });
	sync.sweep();
	assert.equal(sent.length, 2, "changed: again");
});

test("the data file keeps versions, contents and counts; __proto__ is an ordinary name (§4)", async () => {
	const dir = await mkdtemp(join(tmpdir(), "ue-sched-"));
	assert.equal(await loadSchedules(dir), undefined, "no file yet");
	const sync = new ScheduleSync(port().port);
	sync.receive(1, "ue.sched.report", report("group", "__proto__", group(["A"])));
	sync.receive(1, "ue.sched.report", report("group", "__proto__", group(["A", "B"]), 1));
	sync.receive(2, "ue.sched.counts", { first: true, rows: [["group", "__proto__", 3]] });
	await saveDataFile(join(dir, SCHEDULES_FILE), [], sync.toJSON());
	const again = new ScheduleSync(port().port, await loadSchedules(dir));
	assert.deepEqual(again.entries.group.get("__proto__"), { v: 2, content: group(["A", "B"]) });
	assert.equal(again.counts.get(2)!.group.get("__proto__"), 3);
});
