import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadDataFile, saveDataFile, upgrade } from "../../runtime/datafile.js";

const toV2 = (data: { n: number }) => ({ count: data.n });

test("upgrade applies the migrations above the file's schema", () => {
	assert.deepEqual(upgrade({ schema: 1, data: { n: 3 } }, [toV2]), { count: 3 });
	assert.deepEqual(upgrade({ schema: 2, data: { count: 3 } }, [toV2]), { count: 3 });
});

test("a file from newer code, or not a data file at all, is an error, never a reset", () => {
	assert.throws(() => upgrade({ schema: 3, data: {} }, [toV2]), /schema 3/);
	assert.throws(() => upgrade({ data: {} }, []), /schema undefined/);
	assert.throws(() => upgrade("junk", []), /schema/);
});

test("a missing file loads as undefined; a saved file round-trips at the latest schema", async () => {
	const file = join(await mkdtemp(join(tmpdir(), "ue-datafile-")), "runtime.json");
	assert.equal(await loadDataFile(file, [toV2]), undefined);
	await saveDataFile(file, [toV2], { count: 5 });
	assert.deepEqual(JSON.parse(await readFile(file, "utf8")), { schema: 2, data: { count: 5 } });
	assert.deepEqual(await loadDataFile(file, [toV2]), { count: 5 });
});

test("a corrupt file is an error, not an empty load", async () => {
	const file = join(await mkdtemp(join(tmpdir(), "ue-datafile-")), "runtime.json");
	await writeFile(file, "{\"schema\": 1, \"da");
	await assert.rejects(loadDataFile(file, []), SyntaxError);
});
