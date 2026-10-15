import { test } from "node:test";
import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { plugin } from "../../index.js";

// Compiled to dist/node/test/unit/; the plugin root is four levels up.
const pluginRoot = join(import.meta.dirname, "..", "..", "..", "..");
const readJson = async (file: string) => JSON.parse(await readFile(join(pluginRoot, file), "utf8"));

test("the declaration names the plugin and its compiled entrypoints exist", async () => {
	assert.equal(plugin.name, "universal_edges");
	for (const entry of [plugin.controllerEntrypoint, plugin.instanceEntrypoint, plugin.ctlEntrypoint]) {
		assert.ok(entry, "entrypoint declared");
		await access(join(pluginRoot, entry));
	}
});

test("entrypoints export a default function, the form master loads without a deprecation warning", async () => {
	for (const entry of [plugin.controllerEntrypoint, plugin.instanceEntrypoint, plugin.ctlEntrypoint]) {
		assert.ok(entry, "entrypoint declared");
		const loaded = await import(pathToFileURL(join(pluginRoot, entry)).href);
		assert.equal(typeof loaded.default, "function", entry);
	}
});

test("module.json carries the name and version the save patcher validates", async () => {
	const moduleJson = await readJson(join("module", "module.json"));
	const pkg = await readJson("package.json");
	assert.equal(moduleJson.name, plugin.name);
	assert.equal(moduleJson.version, pkg.version);
});
