import { test } from "node:test";
import assert from "node:assert/strict";
import { RuntimeTracker, rollbackListeners, type Rollback } from "../../runtime/tracker.js";

test("the first report sets lastTick and later ones move it forward", () => {
	const tracker = new RuntimeTracker({});
	assert.equal(tracker.observe(7, 100), undefined);
	assert.equal(tracker.observe(7, 700), undefined);
	assert.deepEqual(tracker.toJSON(), { 7: 700 });
});

test("a tick below lastTick is a rollback, and lastTick follows the server back", () => {
	const tracker = new RuntimeTracker({ 7: 5000, 8: 10 });
	assert.deepEqual(tracker.observe(7, 1200), { instanceId: 7, tick: 1200, lastTick: 5000 });
	assert.deepEqual(tracker.toJSON(), { 7: 1200, 8: 10 });
	assert.equal(tracker.observe(7, 1800), undefined);
});

test("saved state that isn't a tick per instance is ignored, not trusted", () => {
	const tracker = new RuntimeTracker({ 7: 50, 8: "x" } as unknown as Record<string, number>);
	assert.deepEqual(tracker.toJSON(), { 7: 50 });
});

test("every rollback reaches the listeners, and a failing listener does not stop the others", () => {
	const heard: Rollback[] = [];
	const errors: Error[] = [];
	const failing = () => {
		throw new Error("listener bug");
	};
	const listening = (rollback: Rollback) => {
		heard.push(rollback);
	};
	rollbackListeners.add(failing);
	rollbackListeners.add(listening);
	try {
		new RuntimeTracker({ 1: 900 }, err => errors.push(err)).observe(1, 300);
	} finally {
		rollbackListeners.delete(failing);
		rollbackListeners.delete(listening);
	}
	assert.deepEqual(heard, [{ instanceId: 1, tick: 300, lastTick: 900 }]);
	assert.deepEqual(errors.map(e => e.message), ["listener bug"]);
});
