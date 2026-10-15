import { test } from "node:test";
import assert from "node:assert/strict";
import type * as lib from "@clusterio/lib";
import { lifecycle, rateLimited } from "../../runtime/log.js";

type Line = { level: string; message: string; meta: Record<string, any> };

function fakeLogger(lines: Line[]): lib.Logger {
	const log = (level: string, message: string, meta: Record<string, any> = {}) => {
		lines.push({ level, message, meta });
	};
	const warn = (message: string, meta?: Record<string, any>) => log("warn", message, meta);
	return { log, warn } as unknown as lib.Logger;
}

test("lifecycle logs '<op> <phase>' with op, phase and the fields as metadata", () => {
	const lines: Line[] = [];
	lifecycle(fakeLogger(lines), "ue.ping", "relay", { trace: "ab.1" });
	lifecycle(fakeLogger(lines), "gw.selfcheck", "done", {}, "verbose");
	assert.deepEqual(lines, [
		{ level: "info", message: "ue.ping relay", meta: { trace: "ab.1", op: "ue.ping", phase: "relay" } },
		{ level: "verbose", message: "gw.selfcheck done", meta: { op: "gw.selfcheck", phase: "done" } },
	]);
});

test("a repeated warning is logged once per key per window, carrying the count", () => {
	const lines: Line[] = [];
	let now = 0;
	const warn = rateLimited(fakeLogger(lines), 60_000, () => now);
	warn("k", "bad thing", { type: "x" });
	warn("k", "bad thing", { type: "x" });
	warn("k", "bad thing", { type: "x" });
	warn("other", "other thing");
	now = 60_000;
	warn("k", "bad thing", { type: "x" });
	assert.deepEqual(
		lines.map(l => [l.message, l.meta.count]),
		[["bad thing", 1], ["other thing", 1], ["bad thing", 3]],
	);
});
