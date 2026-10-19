import { test } from "node:test";
import assert from "node:assert/strict";
import * as lib from "@clusterio/lib";
import { plugin } from "../../index.js";
import {
	PowerDownEvent, PowerUpEvent, Report, ReportIn, Targets, type ReportT, type TargetsT,
} from "../../power/contracts.js";

type Link = [string, number, number];

/** A report of one network with n links, keyed as production keys look (an edge id, then the cid). */
const report = (a: number, n = 1): ReportT => ({
	nets: [{
		a, c: 20_000, f: { so: 0, po: 0, se: 5, to: 0, pd: 0, sd: 3, td: 0 },
		l: Array.from({ length: n }, (_, i) => [`gridworld_${i}_0-gridworld_${i}_1/${i + 1}`, 10, 4] as Link),
	}],
});

test("ue.power.report: a may be negative; flows and totals may not; a net needs a link and a report a net; " +
	"200 links pass (over 4000 bytes: Review Focus 4 and 5)", () => {
	const ok = lib.compile<ReportT>(Report as any);
	assert.equal(ok(report(-5)), true, "a relay owing more than it holds");
	assert.equal(ok(report(3, 200)), true, "no item cap");
	assert.ok(JSON.stringify(report(3, 200)).length > 4000);
	const one = report(1).nets[0];
	assert.equal(ok({ nets: [{ ...one, f: { ...one.f, se: -1 } }] }), false, "a negative flow");
	assert.equal(ok({ nets: [{ ...one, l: [["e1/1", -1, 0]] }] }), false, "a negative total");
	assert.equal(ok({ nets: [{ ...one, l: [] }] }), false, "a net without a link");
	assert.equal(ok({ nets: [] }), false, "a tile with no linked network sends nothing");
});

test("ue.power.targets: m is optional and one of the five modes; n and b are whole kJ; k may be fractional", () => {
	const ok = lib.compile<TargetsT>(Targets as any);
	assert.equal(ok({ l: { "e1/1": { n: 5, b: 10_000, k: 0 } } }), true, "no m: the built state");
	assert.equal(ok({ l: { "e1/1": { n: 5, b: 10_000, m: "secondary_input", k: 1500.5 } } }), true);
	assert.equal(ok({ l: { "e1/1": { n: 5, b: 10_000, m: "accumulator", k: 1 } } }), false);
	assert.equal(ok({ l: { "e1/1": { n: 5.5, b: 10_000, k: 1 } } }), false);
	assert.equal(ok({ l: { "e1/1": { t: 5, b: 10_000, k: 1 } } }), false, "a cumulative t is gone (plan review B1)");
});

test("the events carry their payloads through JSON and their own schemas; the declaration registers both", () => {
	const up = new PowerUpEvent(report(-5));
	const json = JSON.parse(JSON.stringify(up));
	assert.equal(lib.compile(PowerUpEvent.jsonSchema as any)(json), true);
	assert.deepEqual(PowerUpEvent.fromJSON(json).report, report(-5));
	const targets: TargetsT = { l: { "e1/1": { n: 5, b: 10_000, m: "secondary_output", k: 3 } } };
	const down = JSON.parse(JSON.stringify(new PowerDownEvent(targets)));
	assert.equal(lib.compile(PowerDownEvent.jsonSchema as any)(down), true);
	assert.deepEqual(PowerDownEvent.fromJSON(down).targets, targets);
	assert.ok(plugin.messages!.includes(PowerUpEvent) && plugin.messages!.includes(PowerDownEvent));
});

test("ue.power.report in parts: a whole report or a header { chunks >= 1, seq >= 0 } passes (8b)", () => {
	const ok = lib.compile<unknown>(ReportIn as any);
	assert.equal(ok(report(1)), true);
	assert.equal(ok({ chunks: 3, seq: 0 }), true);
	assert.equal(ok({ chunks: 0, seq: 1 }), false);
	assert.equal(ok({ chunks: 2, seq: -1 }), false);
	assert.equal(ok({ chunks: 2 }), false);
	assert.equal(ok({}), false);
});
