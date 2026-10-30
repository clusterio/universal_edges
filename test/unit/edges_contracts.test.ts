import { test } from "node:test";
import assert from "node:assert/strict";
import * as lib from "@clusterio/lib";
import {
	AppliedPayload, ConnectorChangeRequest, EdgeActivationEvent, EdgeAppliedEvent, EdgeChangedEvent,
	EdgeConflictError, EdgeDeletingError, EdgeEnsureRequest, EdgeInvalidError, EdgeOwnerError, EdgePurgedEvent,
	EdgeRecordSchema, EdgeRemoveRequest, EdgeSpecSchema, EdgeSyncEvent, EdgeUpdateEvent, LaneBatchEvent, SyncedPayload,
	type EdgeRecord, type EdgeSpec,
} from "../../edges/contracts.js";
import { plugin } from "../../index.js";

/** The worked example of SP1 spec §8 (v1 data): tile (0,-1)'s south border meets tile (0,0)'s north border. */
function spec(): EdgeSpec {
	return {
		id: "gridworld:0,-1:0,0",
		owner: "gridworld",
		length: 512,
		a: { instanceId: 1, surface: "nauvis", origin: [256, -256], facing: 8 },
		b: { instanceId: 2, surface: "nauvis", origin: [-256, -256], facing: 0 },
	};
}

function record(): EdgeRecord {
	return {
		...spec(),
		revision: 3,
		deleted: false,
		trace: "0000abcd.1",
		updatedAtMs: 1,
		connectors: [{ cid: "c3", type: "train", pos: 10, width: 4, params: { layer: "elevated" } }],
	};
}

test("an edge spec is checked field by field (SP1 spec §5.1)", () => {
	const valid = lib.compile(EdgeSpecSchema as any);
	assert.equal(valid(spec()), true);
	const bad: Record<string, unknown>[] = [
		{ id: "" }, { id: "has space" }, { id: "tab\there" }, { id: "x".repeat(129) }, { owner: "" },
		{ length: 0 }, { length: 100001 }, { length: 1.5 },
		{ a: { ...spec().a, facing: 2 } }, { b: { ...spec().b, origin: [0.5, 0] } },
		{ a: { ...spec().a, origin: [1] } },
	];
	for (const fields of bad) {
		assert.equal(valid({ ...spec(), ...fields }), false, JSON.stringify(fields));
	}
});

test("a record's connectors keep their type's params, such as an SP3 train's rail layer (D18)", () => {
	const valid = lib.compile(EdgeRecordSchema as any);
	assert.equal(valid(record()), true);
	const withoutParams = { cid: "c3", type: "train", pos: 10, width: 4 };
	assert.equal(valid({ ...record(), connectors: [withoutParams] }), false, "params");
	assert.equal(valid({ ...record(), revision: 1.5 }), false, "revision");
	assert.equal(valid({ ...record(), deleted: "no" }), false, "deleted");
});

test("every message survives the JSON its link carries", () => {
	const roundTrip = (Class: { jsonSchema: object; fromJSON(json: any): unknown }, message: object) => {
		const json = JSON.parse(JSON.stringify(message));
		assert.equal(lib.compile(Class.jsonSchema as any)(json), true, message.constructor.name);
		assert.deepEqual(Class.fromJSON(json), message);
	};
	roundTrip(EdgeSyncEvent, new EdgeSyncEvent([record()]));
	roundTrip(EdgeUpdateEvent, new EdgeUpdateEvent({ ...record(), deleted: true, reason: "removed" }));
	roundTrip(EdgeActivationEvent, new EdgeActivationEvent("e1", true, "0000abcd.2", "0000abcd.2"));
	roundTrip(EdgeActivationEvent, new EdgeActivationEvent("e1", false, undefined, "0000abcd.3", "stopped"));
	roundTrip(EdgePurgedEvent, new EdgePurgedEvent("e1"));
	roundTrip(EdgeAppliedEvent, new EdgeAppliedEvent("7e570000", true, [{ id: "e1", revision: 3, open: 0 }]));
	const change = { edge: "e1", op: "add" as const, type: "probe", pos: 1, trace: "t.1" };
	roundTrip(ConnectorChangeRequest, new ConnectorChangeRequest(change));
	roundTrip(EdgeEnsureRequest, new EdgeEnsureRequest(spec()));
	roundTrip(EdgeRemoveRequest, new EdgeRemoveRequest("e1", "manual"));
	roundTrip(EdgeChangedEvent, new EdgeChangedEvent([record()]));
	const applied = { id: "e1", revision: 3, open: -1, sync: false, trace: "t" };
	assert.equal(lib.compile(AppliedPayload as any)(applied), false, "open is never negative");
	assert.equal(lib.compile(SyncedPayload as any)({ n: 2 }), true);
});

test("the plugin declares its messages and permissions in a form Clusterio registers", () => {
	lib.registerPluginMessages([plugin] as unknown as lib.PluginNodeEnvInfo[]);
	lib.registerPluginPermissions([plugin] as unknown as lib.PluginNodeEnvInfo[]);
	const events = [
		"EdgeSyncEvent", "EdgeUpdateEvent", "EdgeActivationEvent", "EdgePurgedEvent", "EdgeAppliedEvent",
		"LaneBatchEvent",
	];
	for (const name of [...events, "EdgeChangedEvent"]) {
		assert.ok(lib.Link._eventsByName.has(`universal_edges:${name}`), name);
	}
	for (const name of ["ConnectorChangeRequest", "EdgeEnsureRequest", "EdgeRemoveRequest", "EdgeListRequest"]) {
		assert.ok(lib.Link._requestsByName.has(`universal_edges:${name}`), name);
	}
	assert.ok(lib.permissions.has("universal_edges.edges.read"));
	assert.ok(lib.permissions.has("universal_edges.edges.write"));
});

test("a refused edge reaches the requester over a link as the same class and code", () => {
	const refusals = [
		[new EdgeInvalidError("bad"), EdgeInvalidError, lib.ValidationError, "EdgeInvalid"],
		[new EdgeDeletingError("bad"), EdgeDeletingError, lib.ConflictError, "EdgeDeleting"],
		[new EdgeConflictError("bad"), EdgeConflictError, lib.ConflictError, "EdgeConflict"],
		[new EdgeOwnerError("bad"), EdgeOwnerError, lib.ForbiddenError, "EdgeOwner"],
	] as const;
	for (const [sent, Class, Base, code] of refusals) {
		const received = lib.Link.errorFromResponse(lib.Link.errorToResponse(sent));
		assert.ok(received instanceof Class, code);
		assert.ok(received instanceof Base, code);
		assert.equal((received as { code?: string }).code, code);
		assert.equal(received.message, "bad");
	}
});

test("a lane batch caps every trace at 64 characters, and names its edge and epoch (M3, §11.2)", () => {
	const valid = lib.compile(LaneBatchEvent.jsonSchema as any);
	const msgs = [{ k: "s.offer", cid: "c1", dir: "ab", totals: { iron: 3 } }];
	const batch = { edge: "e1", epoch: "0000abcd.2", msgs };
	assert.equal(valid(batch), true);
	const back = LaneBatchEvent.fromJSON(JSON.parse(JSON.stringify(batch)));
	assert.deepEqual(back, new LaneBatchEvent("e1", "0000abcd.2", msgs));
	assert.equal(valid({ ...batch, msgs: [{ k: "u.offer", trace: "x".repeat(65) }] }), false, "trace over 64");
	assert.equal(valid({ ...batch, msgs: [] }), false, "an empty batch");
	assert.equal(valid({ ...batch, epoch: "" }), false, "no epoch");
	assert.equal(LaneBatchEvent.src, "instance");
	assert.equal(LaneBatchEvent.dst, "instance", "sent straight to the partner instance (D6)");
});
