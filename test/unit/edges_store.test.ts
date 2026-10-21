import { test } from "node:test";
import assert from "node:assert/strict";
import type * as lib from "@clusterio/lib";
import type { Connector, ConnectorChange, EdgeEvent, EdgeRecord, EdgeSpec } from "../../edges/contracts.js";
import { EdgeStore, type StoreData, type StoreIo } from "../../edges/store.js";

type Line = { level: string; message: string; meta: Record<string, any> };

const turn = () => new Promise(resolve => {
	setImmediate(resolve);
});

function fakeLogger(lines: Line[] = []) {
	const log = (level: string, message: string, meta: Record<string, any> = {}) => {
		lines.push({ level, message, meta });
	};
	return {
		log,
		error: (message: string) => log("error", message),
		warn: (message: string) => log("warn", message),
		verbose: (message: string) => log("verbose", message),
	} as unknown as lib.Logger;
}

function spec(id = "e1", fields: Partial<EdgeSpec> = {}): EdgeSpec {
	return {
		id,
		owner: "test",
		length: 64,
		a: { instanceId: 1, surface: "nauvis", origin: [0, 0], facing: 0 },
		b: { instanceId: 2, surface: "nauvis", origin: [64, 0], facing: 8 },
		...fields,
	};
}

/** A store whose writes land in `disk` (or go through `save`), recording what it published and logged. */
function open(data?: StoreData, save?: StoreIo["save"]) {
	const disk: StoreData[] = [];
	const published: { changed: string[]; purged: string[] }[] = [];
	const lines: Line[] = [];
	const store = new EdgeStore(data, {
		save: save ?? (async saved => {
			disk.push(structuredClone(saved));
		}),
		published: (changed, purged) => {
			published.push({ changed: changed.map(r => `${r.id}@${r.revision}`), purged: purged.map(r => r.id) });
		},
	}, fakeLogger(lines));
	return { store, disk, published, lines };
}

const code = (value: string) => (err: unknown) => (err as { code?: string }).code === value;

test("ensure creates at the next counter value, returns an identical edge as it is, and refuses the rest", async () => {
	const { store, disk } = open();
	const created = await store.ensure(spec());
	assert.equal(created.revision, 1);
	assert.equal(created.deleted, false);
	assert.deepEqual(created.connectors, []);
	assert.match(created.trace, /^[0-9a-f]{8}\.\d+$/);
	// I1: a fresh copy each time, not the object handed out before — value-equal, not the same reference.
	assert.deepEqual(await store.ensure(spec()), created, "identical: the same record");
	assert.equal(disk.length, 1, "and no second write");
	await assert.rejects(store.ensure(spec("e1", { length: 65 })), code("EdgeConflict"));
	await assert.rejects(store.ensure(spec("has space")), code("EdgeInvalid"));
	await assert.rejects(store.ensure(spec("e2", { length: 0 })), code("EdgeInvalid"));
	const same = spec("e3");
	same.b.instanceId = 1;
	await assert.rejects(store.ensure(same), code("EdgeInvalid"));
	await store.remove("e1", "test");
	await assert.rejects(store.ensure(spec()), code("EdgeDeleting"));
});

test("I1: ensure's result and a changed event's edge are copies; mutating either never reaches the store", async () => {
	const { store, disk } = open();
	const bogus: Connector = { cid: "bogus", type: "probe", pos: 0, width: 1, params: {} };

	// The new-record path.
	const created = await store.ensure(spec("e1"));
	created.owner = "someone-else";
	created.connectors.push(bogus);

	// The identical-ensure path: a repeat ensure resolves without a new write, so it must not still hand back the
	// very object the first mutation reached (the M11 "copy" guarantee applies here too, per the store's docs).
	await store.ensure(spec("e2"));
	const again = await store.ensure(spec("e2"));
	again.owner = "also-someone-else";
	again.connectors.push(bogus);

	// The changed-event path.
	let heard: EdgeRecord | undefined;
	store.on(event => {
		if (event.kind === "changed" && event.edge.id === "e3") {
			heard = event.edge;
		}
	});
	await store.ensure(spec("e3"));
	heard!.owner = "yet-another-someone-else";
	heard!.connectors.push(bogus);

	// An unrelated write: were any of the store's own records mutated in place, this is what would carry it to disk.
	await store.ensure(spec("e4"));

	assert.equal(store.get("e1")?.owner, "test", "ensure's new-record result never aliased the store");
	assert.deepEqual(store.get("e1")?.connectors, []);
	assert.equal(store.get("e2")?.owner, "test", "ensure's identical-path result never aliased the store");
	assert.deepEqual(store.get("e2")?.connectors, []);
	assert.equal(store.get("e3")?.owner, "test", "a changed event's edge never aliased the store");
	assert.deepEqual(store.get("e3")?.connectors, []);

	const saved = disk.at(-1)!.edges;
	for (const id of ["e1", "e2", "e3"]) {
		const r = saved.find(row => row.id === id)!;
		assert.equal(r.owner, "test", `${id} unmutated on disk too`);
		assert.deepEqual(r.connectors, []);
	}
});

test("the counter is global and survives a reload, so a re-created id gets a higher revision", async () => {
	const first = open();
	await first.store.ensure(spec("e1"));
	await first.store.ensure(spec("e2"));
	await first.store.remove("e1", "test");
	await first.store.purge("e1");
	const saved = first.disk.at(-1)!;
	assert.equal(saved.counter, 3);
	assert.deepEqual(saved.edges.map(r => r.id), ["e2"]);
	const second = open(saved);
	assert.equal((await second.store.ensure(spec("e1"))).revision, 4, "above all the first store gave out");
});

test("I2: nothing is readable, heard or published before its write resolves", async () => {
	let release!: () => void;
	const gate = new Promise<void>(resolve => {
		release = resolve;
	});
	const { store, published } = open(undefined, () => gate);
	const heard: EdgeEvent[] = [];
	store.on(event => {
		heard.push(event);
	});
	let done = false;
	const ensured = store.ensure(spec()).then(() => {
		done = true;
	});
	await turn();
	await turn();
	assert.equal(store.get("e1"), undefined, "not readable");
	assert.equal(heard.length, 0, "not heard");
	assert.deepEqual(published, [], "not published");
	assert.equal(done, false, "not resolved");
	release();
	await ensured;
	assert.equal(store.get("e1")?.revision, 1);
	assert.deepEqual(heard.map(e => e.kind), ["changed"]);
	assert.deepEqual(published, [{ changed: ["e1@1"], purged: [] }]);
});

test("I2: changes in one turn share one write and publish each edge once, with its final record", async () => {
	const { store, disk, published } = open();
	await Promise.all([
		store.ensure(spec("e1")),
		store.connector({ edge: "e1", op: "add", type: "probe", pos: 0, trace: "t.1" }),
		store.connector({ edge: "e1", op: "add", type: "probe", pos: 1, trace: "t.2" }),
		store.ensure(spec("e2")),
	]);
	assert.equal(disk.length, 1, "one write");
	assert.deepEqual(published, [{ changed: ["e1@3", "e2@4"], purged: [] }], "one update per edge");
	assert.deepEqual(store.get("e1")?.connectors.map(c => c.cid), ["c2", "c3"]);
});

test("I2: a store lost before its write resolves never reuses a revision or cid it published", async () => {
	const disk: StoreData[] = [];
	const firstPublished: string[] = [];
	const first = new EdgeStore(undefined, {
		save: async saved => {
			if (saved.counter > 1) {
				// The controller dies during this write.
				await new Promise(() => undefined);
			}
			disk.push(structuredClone(saved));
		},
		published: changed => {
			firstPublished.push(...changed.map(r => `${r.id}@${r.revision}`));
		},
	}, fakeLogger());
	await first.ensure(spec());
	first.connector({ edge: "e1", op: "add", type: "probe", pos: 0, trace: "t.1" }).catch(() => undefined);
	await turn();
	await turn();
	// It restarts from what reached the disk.
	const second = open(disk.at(-1));
	const result = await second.store.connector({ edge: "e1", op: "add", type: "probe", pos: 0, trace: "t.2" });
	assert.deepEqual(firstPublished, ["e1@1"], "the lost change was never published");
	assert.equal(result.cid, "c2", "so its counter value may be taken again");
	assert.deepEqual(second.published, [{ changed: ["e1@2"], purged: [] }]);
});

test("a failed write rejects its turn and publishes nothing; the next write carries the change", async () => {
	let fail = true;
	const { store, disk, published } = open(undefined, async saved => {
		if (fail) {
			throw new Error("disk full");
		}
		disk.push(structuredClone(saved));
	});
	await assert.rejects(store.ensure(spec("e1")), /disk full/);
	assert.equal(store.get("e1"), undefined, "not readable");
	assert.deepEqual(published, []);
	fail = false;
	await store.ensure(spec("e2"));
	assert.deepEqual(disk[0].edges.map(r => r.id), ["e1", "e2"], "the next write holds both");
	assert.deepEqual(published, [{ changed: ["e1@1", "e2@2"], purged: [] }], "and publishes both");
});

test("remove tombstones for the owner only; absent and deleted ids are no-ops; purge frees the id", async () => {
	const { store, published } = open();
	await store.ensure(spec());
	await assert.rejects(store.remove("e1", "someone"), code("EdgeOwner"));
	await store.remove("e1", "test");
	const tombstone = store.get("e1")!;
	assert.equal(tombstone.deleted, true);
	assert.equal(tombstone.reason, "removed");
	assert.equal(tombstone.revision, 2);
	await store.remove("e1", "test");
	await store.remove("nope", "test");
	assert.equal(store.get("e1")?.revision, 2, "a second remove changes nothing");
	await store.purge("e1");
	assert.equal(store.get("e1"), undefined);
	assert.deepEqual(published.at(-1), { changed: [], purged: ["e1"] });
	assert.equal((await store.ensure(spec())).revision, 3, "the id can be re-created");
});

test("tombstoneInstance tombstones every live edge of the instance, with its reason", async () => {
	const { store } = open();
	await store.ensure(spec("e1"));
	await store.ensure(spec("e2", { b: { instanceId: 3, surface: "nauvis", origin: [64, 0], facing: 8 } }));
	await store.tombstoneInstance(2, "instance_deleted");
	assert.equal(store.get("e1")?.reason, "instance_deleted");
	assert.equal(store.get("e2")?.deleted, false, "an edge between 1 and 3 is untouched");
});

test("connectors stay in bounds, never overlap, keep params under 1 KB, and only a side may ask", async () => {
	const { store } = open();
	await store.ensure(spec());
	const add = (fields: Partial<ConnectorChange>, requester?: number) => store.connector(
		{ edge: "e1", op: "add", type: "probe", pos: 0, trace: "t.1", ...fields },
		requester,
	);
	const first = await add({ pos: 10, params: { layer: "elevated" } });
	assert.deepEqual(first, { ok: true, cid: "c2" }, "the cid is the change's counter value");
	const stored = { cid: "c2", type: "probe", pos: 10, width: 1, params: { layer: "elevated" } };
	assert.deepEqual(store.get("e1")?.connectors[0], stored, "params reach the record as given");
	assert.equal((await add({ pos: 12 })).ok, true);
	assert.equal((await add({ pos: 10 })).reason, "overlap");
	assert.equal((await add({ pos: 9, width: 2 })).reason, "overlap");
	assert.equal((await add({ pos: 63, width: 2 })).reason, "out_of_bounds");
	assert.equal((await add({ pos: -1 })).reason, "out_of_bounds");
	assert.equal((await add({ pos: 20, width: 0 })).reason, "out_of_bounds");
	assert.equal((await add({ pos: 20, params: { pad: "x".repeat(1024) } })).reason, "params_too_large");
	assert.equal((await add({ pos: 20, type: undefined })).reason, "invalid");
	assert.equal((await add({ pos: 20 }, 3)).reason, "not_a_side");
	assert.equal((await add({ pos: 20 }, 2)).ok, true, "side b may ask");
	const remove = (cid: string) => store.connector({ edge: "e1", op: "remove", cid, trace: "t.2" });
	assert.equal((await remove("c99")).reason, "unknown_connector");
	assert.deepEqual(await remove("c2"), { ok: true });
	assert.deepEqual(store.get("e1")?.connectors.map(c => c.cid), ["c3", "c4"]);
	const elsewhere = await store.connector({ edge: "nope", op: "add", type: "probe", pos: 0, trace: "t.3" });
	assert.equal(elsewhere.reason, "unknown_edge");
});

test("listeners hear a change after its write and before its messages; a throwing one stops no other", async () => {
	const order: string[] = [];
	const lines: Line[] = [];
	const store = new EdgeStore(undefined, {
		save: async () => {
			order.push("write");
		},
		published: changed => {
			order.push(`publish ${changed.map(r => r.id).join(",")}`);
		},
	}, fakeLogger(lines));
	store.on(() => {
		throw new Error("listener bug");
	});
	store.on(event => {
		order.push(`heard ${event.kind}`);
		if (event.kind === "changed" && event.edge.id === "e1") {
			// A listener may call the API; that change joins a later write.
			store.ensure(spec("e2")).catch(() => undefined);
		}
	});
	await store.ensure(spec("e1"));
	await turn();
	await turn();
	assert.deepEqual(order, ["write", "heard changed", "publish e1", "write", "heard changed", "publish e2"]);
	assert.ok(lines.some(l => l.level === "error" && l.message.startsWith("an edge listener failed")));
});

test("lifecycle lines follow the write and carry the change's trace", async () => {
	const { store, lines } = open();
	const created = await store.ensure(spec());
	await store.connector({ edge: "e1", op: "add", type: "probe", pos: 0, trace: "t.9" });
	await store.connector({ edge: "e1", op: "add", type: "probe", pos: 0, trace: "t.10" });
	await store.remove("e1", "test");
	await store.purge("e1");
	const phases = lines.filter(l => l.meta.op !== undefined).map(l => [l.message, l.meta.trace]);
	assert.deepEqual(phases.map(p => p[0]), [
		"ue.edge ensured", "ue.connector added", "ue.connector rejected", "ue.edge deleted", "ue.edge purged",
	]);
	assert.equal(phases[0][1], created.trace);
	assert.equal(phases[1][1], "t.9");
	assert.equal(phases[2][1], "t.10");
	assert.equal(phases[3][1], phases[4][1], "purged is logged under the tombstone's trace");
});

test("FC1: a circuit connector shares a power connector's exact columns; every other overlap is refused", async () => {
	const { store } = open();
	await store.ensure(spec());
	const add = (type: string, pos: number, width = 1) => store.connector(
		{ edge: "e1", op: "add", type, pos, width, trace: "t.1" },
	);
	assert.equal((await add("power", 10)).ok, true);
	assert.equal((await add("circuit", 10)).ok, true, "a circuit link on its power link's pole");
	assert.equal((await add("circuit", 10)).reason, "overlap", "a second circuit there");
	assert.equal((await add("power", 10)).reason, "overlap", "a second power there");
	assert.equal((await add("power", 20, 2)).ok, true);
	assert.equal((await add("circuit", 20)).reason, "overlap", "a partial overlap: the power connector is two wide");
	assert.equal((await add("circuit", 30)).ok, true, "a lone circuit connector (C8: its power link went first)");
	assert.equal((await add("power", 30)).ok, true, "power beside a lone circuit connector, as FC2 proposes it");
	assert.equal((await add("belt", 40)).ok, true);
	assert.equal((await add("circuit", 40)).reason, "overlap", "circuit over a belt");
	assert.equal((await add("power", 40)).reason, "overlap", "power over a belt, as before");
});
