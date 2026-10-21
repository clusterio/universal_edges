import { test } from "node:test";
import assert from "node:assert/strict";
import { newBootId, newId } from "../../runtime/ids.js";

test("a boot id is 8 hex digits, fresh on every call", () => {
	assert.match(newBootId(), /^[0-9a-f]{8}$/);
	assert.notEqual(newBootId(), newBootId());
});

test("ids are <process boot id>.<seq>, counting up", () => {
	const [boot, seq] = newId().split(".");
	assert.match(boot, /^[0-9a-f]{8}$/);
	assert.equal(newId(), `${boot}.${Number(seq) + 1}`);
});
