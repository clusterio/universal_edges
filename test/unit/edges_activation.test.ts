import { test } from "node:test";
import assert from "node:assert/strict";
import type * as lib from "@clusterio/lib";
import { EdgeActivation, isActive, type Facts } from "../../edges/activation.js";
import {
	EdgeActivationEvent, EdgePurgedEvent, EdgeSyncEvent, EdgeUpdateEvent, type EdgeReadiness, type EdgeRecord,
	type EdgeSpec,
} from "../../edges/contracts.js";
import { edgeApi } from "../../edges/index.js";
import { EdgeStore, type StoreData } from "../../edges/store.js";

const quiet = { log: () => undefined, warn: () => undefined, error: () => undefined, verbose: () => undefined };
const logger = quiet as unknown as lib.Logger;

async function settle() {
	for (let i = 0; i < 3; i++) {
		await new Promise(resolve => {
			setImmediate(resolve);
		});
	}
}

function spec(id = "e1", a = 1, b = 2): EdgeSpec {
	return {
		id,
		owner: "test",
		length: 64,
		a: { instanceId: a, surface: "nauvis", origin: [0, 0], facing: 0 },
		b: { instanceId: b, surface: "nauvis", origin: [64, 0], facing: 8 },
	};
}

/** A controller: a store that writes at once, activation over it, instances 1 and 2 running, and what it sent. */
function controller(data?: StoreData) {
	const shown: EdgeReadiness[] = [];
	const status = new Map<number, string>([[1, "running"], [2, "running"]]);
	const exists = new Set([1, 2]);
	const sent: { to: number; message: object }[] = [];
	const store: EdgeStore = new EdgeStore(data, {
		save: async () => undefined,
		published: (changed, purged) => {
			activation.published(changed, purged);
		},
	}, logger);
	const activation = new EdgeActivation(store, {
		status: id => status.get(id),
		exists: id => exists.has(id),
		send: (to, message) => {
			sent.push({ to, message });
		},
		readiness: r => {
			shown.push(r);
		},
	}, logger);
	return { status, exists, sent, store, activation, shown };
}
type Controller = ReturnType<typeof controller>;

function sentOf<T>(c: Controller, Class: new (...args: any[]) => T) {
	return c.sent.filter(s => s.message instanceof Class) as { to: number; message: T }[];
}

/** The instance says hello under boot, then applies its sync: each edge it is a side of, at its revision. */
function synced(c: Controller, id: number, boot: string) {
	c.activation.onRuntime(id, boot);
	const edges = c.store.list({ instanceId: id }).map(r => ({ id: r.id, revision: r.revision, open: 0 }));
	c.activation.onApplied(id, { boot, sync: true, edges });
}

/** Edge e1 between instances 1 and 2, both synced, so it is active; returns its epoch. */
async function activeEdge(c: Controller): Promise<string> {
	await c.store.ensure(spec());
	synced(c, 1, "b1");
	synced(c, 2, "b2");
	assert.equal(c.activation.isActive("e1"), true);
	return sentOf(c, EdgeActivationEvent).at(-1)!.message.epoch!;
}

test("isActive needs both sides running, synced and applied under their boot; a tombstone, an open side", () => {
	const r = { ...spec(), revision: 1, deleted: false, connectors: [], trace: "t", updatedAtMs: 0 } as EdgeRecord;
	const good: Facts = {
		status: () => "running",
		boot: id => `b${id}`,
		syncedBoot: id => `b${id}`,
		applied: id => ({ boot: `b${id}`, revision: 1, open: 0 }),
	};
	assert.equal(isActive(r, good), true);
	assert.equal(isActive(r, { ...good, status: id => (id === 2 ? "stopped" : "running") }), false, "a side stopped");
	assert.equal(isActive(r, { ...good, boot: () => undefined }), false, "no boot known");
	assert.equal(isActive(r, { ...good, syncedBoot: id => (id === 1 ? "b0" : `b${id}`) }), false, "an old sync");
	assert.equal(isActive(r, { ...good, applied: () => undefined }), false, "nothing applied");
	const oldBoot: Facts["applied"] = id => ({ boot: id === 2 ? "b0" : `b${id}`, revision: 1, open: 0 });
	assert.equal(isActive(r, { ...good, applied: oldBoot }), false, "applied under an old boot");
	const tombstone = { ...r, deleted: true };
	assert.equal(isActive(tombstone, good), false, "a tombstone with nothing open");
	const closing: Facts["applied"] = id => ({ boot: `b${id}`, revision: 1, open: id === 1 ? 2 : 0 });
	assert.equal(isActive(tombstone, { ...good, applied: closing }), true, "a tombstone a side is still closing");
});

test("an edge activates once both sides are synced, under one epoch that re-evaluation keeps", async () => {
	const c = controller();
	await c.store.ensure(spec());
	synced(c, 1, "b1");
	assert.equal(c.activation.isActive("e1"), false, "one side is not enough");
	synced(c, 2, "b2");
	const on = sentOf(c, EdgeActivationEvent).filter(s => s.message.active);
	assert.deepEqual(on.map(s => s.to).sort(), [1, 2], "both sides are told");
	assert.equal(on[0].message.epoch, on[1].message.epoch);
	assert.equal(on[0].message.trace, on[0].message.epoch, "the activation's trace is its epoch");
	c.sent.length = 0;
	c.activation.reconcile();
	c.activation.onRuntime(1, "b1");
	const again = sentOf(c, EdgeActivationEvent);
	assert.ok(again.length > 0, "the state is re-asserted");
	assert.ok(again.every(s => s.message.active && s.message.epoch === on[0].message.epoch), "without a new epoch");
});

test("a new boot deactivates (new_boot) before its sync, and re-activation takes a new epoch", async () => {
	const c = controller();
	const epoch = await activeEdge(c);
	c.sent.length = 0;
	c.activation.onRuntime(1, "b1-restarted");
	const kinds = c.sent.map(s => s.message.constructor.name);
	assert.ok(kinds.lastIndexOf("EdgeActivationEvent") < kinds.indexOf("EdgeSyncEvent"), kinds.join(","));
	assert.ok(sentOf(c, EdgeActivationEvent).every(s => !s.message.active && s.message.reason === "new_boot"));
	assert.equal(c.activation.isActive("e1"), false);
	synced(c, 1, "b1-restarted");
	const next = sentOf(c, EdgeActivationEvent).at(-1)!.message;
	assert.equal(next.active, true);
	assert.notEqual(next.epoch, epoch);
});

test("I1: after a controller restart, an edge ensured before the first sync waits for that sync", async () => {
	const c = controller();
	await c.store.ensure(spec());
	const report = [{ id: "e1", revision: 1, open: 0 }];
	// The update is applied before the controller has heard any hello: not a known boot, so ignored.
	c.activation.onApplied(1, { boot: "b1", sync: false, edges: report });
	assert.equal(sentOf(c, EdgeSyncEvent).length, 0, "a boot comes only from a hello or a heartbeat");
	c.activation.onRuntime(1, "b1");
	c.activation.onRuntime(2, "b2");
	assert.deepEqual(sentOf(c, EdgeSyncEvent).map(s => s.to), [1, 2]);
	c.activation.onApplied(1, { boot: "b1", sync: false, edges: report });
	c.activation.onApplied(2, { boot: "b2", sync: false, edges: report });
	assert.equal(c.activation.isActive("e1"), false, "applied, but the syncs are still in flight");
	c.activation.onApplied(1, { boot: "b1", sync: true, edges: report });
	c.activation.onApplied(2, { boot: "b2", sync: true, edges: report });
	assert.equal(c.activation.isActive("e1"), true);
});

test("both instances starting at once: hellos while starting, then running, syncs in any order", async () => {
	const c = controller();
	await c.store.ensure(spec());
	c.status.set(1, "starting");
	c.status.set(2, "starting");
	c.activation.onRuntime(2, "b2");
	c.activation.onRuntime(1, "b1");
	assert.equal(sentOf(c, EdgeSyncEvent).length, 0, "no sync to a starting instance");
	for (const id of [2, 1]) {
		c.status.set(id, "running");
		c.activation.onStatus(id, "running");
	}
	assert.deepEqual(sentOf(c, EdgeSyncEvent).map(s => s.to), [2, 1]);
	const report = [{ id: "e1", revision: 1, open: 0 }];
	c.activation.onApplied(2, { boot: "b2", sync: true, edges: report });
	c.activation.onApplied(1, { boot: "b1", sync: true, edges: report });
	const on = sentOf(c, EdgeActivationEvent).filter(s => s.message.active);
	assert.equal(on.length, 2, "one activation, to each side");
});

test("an applied report from a previous boot is ignored", async () => {
	const c = controller();
	await activeEdge(c);
	c.activation.onRuntime(1, "b1-new");
	c.activation.onApplied(1, { boot: "b1", sync: true, edges: [{ id: "e1", revision: 1, open: 0 }] });
	assert.equal(c.activation.isActive("e1"), false);
});

test("a tombstone stays activatable while a side reports open lanes, then closes and is purged", async () => {
	const c = controller();
	await activeEdge(c);
	await c.store.remove("e1", "test");
	assert.equal(c.activation.isActive("e1"), false);
	assert.equal(sentOf(c, EdgeActivationEvent).at(-1)!.message.reason, "deleted");
	c.activation.onApplied(1, { boot: "b1", sync: false, edges: [{ id: "e1", revision: 2, open: 1 }] });
	c.activation.onApplied(2, { boot: "b2", sync: false, edges: [{ id: "e1", revision: 2, open: 0 }] });
	assert.equal(c.activation.isActive("e1"), true, "the closing handshakes can run over the tombstone");
	c.activation.onApplied(1, { boot: "b1", sync: false, edges: [{ id: "e1", revision: 2, open: 0 }] });
	assert.equal(sentOf(c, EdgeActivationEvent).at(-1)!.message.reason, "closed");
	await settle();
	assert.equal(c.store.get("e1"), undefined, "purged once both sides report nothing open");
	assert.deepEqual(sentOf(c, EdgePurgedEvent).map(s => s.to).sort(), [1, 2]);
});

test("a host that drops and returns with the same boot waits for a heartbeat before it re-syncs", async () => {
	const c = controller();
	const epoch = await activeEdge(c);
	c.status.set(2, "unknown");
	c.activation.onStatus(2, "unknown");
	c.sent.length = 0;
	c.status.set(2, "running");
	c.activation.onStatus(2, "running");
	assert.equal(c.activation.isActive("e1"), false, "no activation before a heartbeat names the boot again");
	assert.equal(sentOf(c, EdgeSyncEvent).length, 0, "no sync yet either");
	synced(c, 2, "b2");
	assert.equal(sentOf(c, EdgeSyncEvent).length, 1, "one sync, from the heartbeat");
	const next = sentOf(c, EdgeActivationEvent).at(-1)!.message;
	assert.equal(next.active, true);
	assert.notEqual(next.epoch, epoch);
});

/** C1 (plan review): Clusterio's host notifies `running` before the new boot's hello (`Instance.ts:1067-1069`). */
test("restart: running before the hello does not activate", async () => {
	const c = controller();
	const epoch = await activeEdge(c);
	c.sent.length = 0;
	for (const status of ["stopping", "stopped", "starting", "running"]) {
		c.status.set(2, status);
		c.activation.onStatus(2, status);
	}
	assert.equal(c.activation.isActive("e1"), false, "must not activate before the new boot's sync");
	assert.equal(sentOf(c, EdgeSyncEvent).length, 0, "no sync before the new boot's hello");
	synced(c, 2, "b2b");
	assert.equal(c.activation.isActive("e1"), true);
	assert.notEqual(sentOf(c, EdgeActivationEvent).at(-1)!.message.epoch, epoch);
});

test("a deleted instance tombstones its edges, and the survivor's report of the tombstone purges them", async () => {
	const c = controller();
	await activeEdge(c);
	c.exists.delete(2);
	c.status.set(2, "deleted");
	c.activation.onStatus(2, "deleted");
	await settle();
	const tombstone = c.store.get("e1")!;
	assert.equal(tombstone.reason, "instance_deleted");
	const told = sentOf(c, EdgeUpdateEvent).filter(s => s.message.edge.deleted).map(s => s.to);
	assert.deepEqual(told, [1], "only the survivor hears it");
	const report = [{ id: "e1", revision: tombstone.revision, open: 0 }];
	c.activation.onApplied(1, { boot: "b1", sync: false, edges: report });
	await settle();
	assert.equal(c.store.get("e1"), undefined);
});

test("the reconcile loop re-sends a lost sync and missing updates, and re-asserts each edge's state", async () => {
	const c = controller();
	c.exists.add(3);
	c.status.set(3, "stopped");
	await c.store.ensure(spec("e1"));
	await c.store.ensure(spec("e2", 1, 3));
	synced(c, 1, "b1");
	// Instance 2's sync goes out, but its report is lost; instance 1 never reports the connector's update.
	c.activation.onRuntime(2, "b2");
	await c.store.connector({ edge: "e1", op: "add", type: "probe", pos: 0, trace: "t.1" });
	c.sent.length = 0;
	c.activation.reconcile();
	assert.deepEqual(sentOf(c, EdgeSyncEvent).map(s => s.to), [2], "the unsynced instance");
	const updates = sentOf(c, EdgeUpdateEvent).map(s => `${s.to}:${s.message.edge.id}@${s.message.edge.revision}`);
	assert.deepEqual(updates, ["1:e1@3"], "only the update instance 1 lacks");
	const states = sentOf(c, EdgeActivationEvent).map(s => `${s.to}:${s.message.id}:${s.message.active}`).sort();
	assert.deepEqual(states, ["1:e1:false", "1:e2:false", "2:e1:false"], "inactive too, to running sides only");
});

test("at start, a tombstone whose instances are both gone is purged", async () => {
	const tombstone: EdgeRecord = {
		...spec("old", 5, 6),
		revision: 7,
		deleted: true,
		reason: "removed",
		connectors: [],
		trace: "t.7",
		updatedAtMs: 0,
	};
	const c = controller({ counter: 7, edges: [tombstone] });
	c.activation.reconcile();
	await settle();
	assert.equal(c.store.get("old"), undefined);
});

test("reports from an instance that is not a side, or about an unknown edge, are not kept", async () => {
	const c = controller();
	await activeEdge(c);
	c.status.set(3, "running");
	c.activation.onRuntime(3, "b3");
	const edges = [{ id: "e1", revision: 9, open: 4 }, { id: "nope", revision: 1, open: 0 }];
	c.activation.onApplied(3, { boot: "b3", sync: true, edges });
	assert.equal(c.activation.facts.applied(3, "e1"), undefined);
	assert.equal(c.activation.facts.applied(3, "nope"), undefined);
	assert.equal(c.activation.isActive("e1"), true, "the edge is untouched");
});

test("edgeApi() throws until UE's controller plugin has set it", () => {
	assert.throws(() => edgeApi(), /not ready/);
});

test("readiness (D13): each side's half of isActive is published when it changes, and only then", async () => {
	const c = controller();
	await c.store.ensure(spec());
	await settle();
	synced(c, 1, "b1");
	synced(c, 2, "b2");
	c.activation.reconcile();
	c.status.set(2, "stopped");
	c.activation.onStatus(2, "stopped");
	const seen = c.shown.map(r => `${r.id} ${r.active} ${r.a} ${r.b}`);
	assert.deepEqual(seen, ["e1 false false false", "e1 false true false", "e1 true true true", "e1 false true false"]);
	assert.deepEqual(c.activation.readiness(c.store.get("e1")!), { id: "e1", active: false, a: true, b: false });
});
