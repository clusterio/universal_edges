import { test } from "node:test";
import assert from "node:assert/strict";
import { CrossingRecords } from "../../edges/crossings.js";

const base = { key: "edge:e1", from: 1, x: 10, y: -2, surface: "nauvis", trace: "t1" };

test("a join returns the newest entry to the joining instance, with the leave point from that entry's source", () => {
	let now = 0;
	const r = new CrossingRecords(() => now);
	r.cross("ann", { ...base, to: 2 });
	now = 10;
	r.cross("ann", { ...base, to: 3, key: "zone:se", trace: "t2" });
	assert.equal(r.left("ann", { from: 1, x: 12, y: -4, surface: "nauvis" }), true);
	now = 25;
	assert.deepEqual(r.join("ann", 3), { arrival: { key: "zone:se", x: 10, y: -2, surface: "nauvis", trace: "t2",
		left: { x: 12, y: -4, surface: "nauvis" } }, age: 15 }, "the entry's age in ms rides beside it, for the log");
});

test("any join deletes the record, matched or not (crossing spec §5)", () => {
	const r = new CrossingRecords(() => 0);
	r.cross("bea", { ...base, to: 2 });
	assert.equal(r.join("bea", 9), undefined, "no entry for instance 9");
	assert.equal(r.join("bea", 2), undefined, "the record went with the first join");
});

test("a newer entry to the same instance replaces the older; a leave from another source is not attached", () => {
	const r = new CrossingRecords(() => 0);
	r.cross("cal", { ...base, to: 2 });
	r.cross("cal", { ...base, to: 2, x: 20, trace: "t9" });
	r.left("cal", { from: 7, x: 1, y: 1, surface: "nauvis" });
	const a = r.join("cal", 2)?.arrival;
	assert.equal(a?.x, 20);
	assert.equal(a?.trace, "t9");
	assert.equal(a?.left, undefined, "left from instance 7, not the entry's source");
});

test("entries expire after 10 minutes; a leave without a record is not kept", () => {
	let now = 0;
	const r = new CrossingRecords(() => now);
	assert.equal(r.left("dee", { from: 1, x: 0, y: 0, surface: "nauvis" }), false);
	r.cross("dee", { ...base, to: 2 });
	now = CrossingRecords.TTL_MS + 1;
	assert.equal(r.join("dee", 2), undefined);
});

test("at most CAP records: the oldest goes first", () => {
	const r = new CrossingRecords(() => 0);
	for (let i = 0; i <= CrossingRecords.CAP; i++) {
		r.cross(`p${i}`, { ...base, to: 2 });
	}
	assert.equal(r.join("p0", 2), undefined, "the oldest was dropped");
	assert.ok(r.join(`p${CrossingRecords.CAP}`, 2), "the newest is kept");
});
