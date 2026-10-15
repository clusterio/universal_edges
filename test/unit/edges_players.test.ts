import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { destination, resolveKeys, target } from "../../edges/players.js";
import type { EdgeRecord } from "../../edges/contracts.js";

const edge = { id: "e1", a: { instanceId: 1 }, b: { instanceId: 2 }, deleted: false } as unknown as EdgeRecord;
const edges = (id: string) => (id === "e1" ? edge : undefined);
const none = () => undefined;

test("an edge key leads to the edge's partner, from either side; a stranger or unknown edge is refused", () => {
	assert.equal(destination("edge:e1", 1, "nauvis", edges, none), 2);
	assert.equal(destination("edge:e1", 2, "nauvis", edges, none), 1);
	assert.equal(destination("edge:e1", 5, "nauvis", edges, none), "not_a_side");
	assert.equal(destination("edge:nope", 1, "nauvis", edges, none), "unknown_edge");
});

test("another prefix goes to its registered resolver with the key and surface; an unknown prefix is refused", () => {
	const calls: unknown[] = [];
	const resolver = (p: string) => (p === "zone" ? (from: number, key: string, surface: string) => {
		calls.push([from, key, surface]);
		return 7;
	} : undefined);
	assert.equal(destination("zone:se", 1, "fulgora", edges, resolver), 7);
	assert.deepEqual(calls, [[1, "zone:se", "fulgora"]]);
	assert.equal(destination("other:x", 1, "nauvis", edges, resolver), "unknown_zone");
	assert.equal(destination("nokey", 1, "nauvis", edges, resolver), "unknown_zone");
});

test("target: a running instance at its host's public address; why not otherwise", () => {
	const inst = (s: string, port?: number) => () => ({ name: "b", host: 3, status: s, gamePort: port });
	const host = () => ({ publicAddress: "h.example" });
	assert.deepEqual(target(2, inst("running", 34197), host), { ok: true, address: "h.example:34197", name: "b" });
	assert.deepEqual(target(2, inst("stopped", 34197), host), { ok: false, reason: "not_running" });
	assert.deepEqual(target(2, () => undefined, host), { ok: false, reason: "no_instance" });
	assert.deepEqual(target(2, inst("running"), host), { ok: false, reason: "no_address" });
});

test("resolveKeys: the first key that leads to a running instance is chosen; else the last reason", () => {
	// e1 leads 1 → 2; the corner key "zone:se" leads to 9 when its diagonal tile exists, else "no_tile". Both run.
	const facts = (id: number) => ({ name: `i${id}`, host: 3, status: "running", gamePort: 34197 });
	const host = () => ({ publicAddress: "h.example" });
	const corner = (tile: boolean) => (p: string) => (p === "zone" ? () => (tile ? 9 : "no_tile") : undefined);
	const keys = ["zone:se", "edge:e1"];
	assert.deepEqual(resolveKeys(keys, 1, "nauvis", edges, corner(false), facts, host),
		{ result: { ok: true, address: "h.example:34197", name: "i2" }, to: 2, key: "edge:e1" },
		"the corner has no tile: the edge, the fallback, is chosen");
	assert.deepEqual(resolveKeys(keys, 1, "nauvis", edges, corner(true), facts, host),
		{ result: { ok: true, address: "h.example:34197", name: "i9" }, to: 9, key: "zone:se" },
		"both work: the first, the corner, is chosen");
	assert.deepEqual(resolveKeys(["zone:se", "edge:nope"], 1, "nauvis", edges, corner(false), facts, host),
		{ result: { ok: false, reason: "unknown_edge" } }, "all fail: the last reason");
	assert.deepEqual(resolveKeys([], 1, "nauvis", edges, corner(true), facts, host),
		{ result: { ok: false, reason: "no_keys" } }, "no keys");
});

// Ruling 6 (crossing spec §2, §12): the crossing code names no gridworld code, storage or message, in code or comments.
// Compiled to dist/node/test/unit/; the plugin root is four levels up.
test("the six crossing files never name gridworld", async () => {
	const root = join(import.meta.dirname, "..", "..", "..", "..");
	for (const file of ["module/transports/players.lua", "module/transports/crossing_core.lua",
		"module/transports/vehicle.lua", "module/transports/train.lua", "edges/players.ts", "edges/crossings.ts"]) {
		assert.ok(!/gridworld/i.test(await readFile(join(root, file), "utf8")), `${file} names gridworld`);
	}
});
