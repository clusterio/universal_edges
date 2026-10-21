local t = require("testlib")
local core = require("modules/universal_edges/edges/edge_core")

local function record(fields)
	local rec = {
		id = "e1", revision = 5, trace = "0000abcd.1", me = "a", length = 64, deleted = false, connectors = {},
		a = { instanceId = 1, surface = "nauvis", origin = { 0, 0 }, facing = 0 },
		b = { instanceId = 2, surface = "nauvis", origin = { 64, 0 }, facing = 8 },
	}
	for k, v in pairs(fields or {}) do
		rec[k] = v
	end
	return rec
end

local function probe(cid, pos)
	return { cid = cid, type = "probe", pos = pos, width = 1, params = {} }
end

t.test("a record is checked field by field, and its connectors must fit the edge", function()
	t.expect_true(core.valid(record()))
	t.expect_true(core.valid(record({ connectors = { probe("c1", 63) } })))
	local bad = {
		{ id = "" }, { revision = 0 }, { revision = 1.5 }, { me = "c" }, { length = 0 }, { deleted = "no" },
		{ trace = 7 },
		{ a = { instanceId = 1, surface = "nauvis", origin = { 0, 0 }, facing = 2 } },
		{ b = { instanceId = 2, surface = "nauvis", origin = { 0.5, 0 }, facing = 8 } },
		{ connectors = { probe("c1", 64) } },
		{ connectors = { { cid = "c1", type = "probe", pos = 0, width = 0, params = {} } } },
	}
	for i, fields in ipairs(bad) do
		t.expect_true(not core.valid(record(fields)), "bad record " .. i)
	end
	t.expect_true(not core.valid(nil) and not core.valid("e1"), "not a table")
end)

t.test("plan: create, stale, update, shell and recreate follow the revision rules", function()
	t.expect_eq(core.plan(nil, record(), false), "create")
	local side = core.new_side(record(), 1)
	t.expect_eq(core.plan(side, record(), false), "stale", "the same revision")
	t.expect_eq(core.plan(side, record({ revision = 4 }), false), "stale", "an older update")
	t.expect_eq(core.plan(side, record({ revision = 4 }), true), "update", "a sync is authoritative")
	t.expect_eq(core.plan(side, record({ revision = 6 }), false), "update")
	t.expect_eq(core.plan(side, record({ revision = 6, deleted = true }), false), "shell")
	side.deleted = true
	t.expect_eq(core.plan(side, record({ revision = 7 }), false), "recreate", "the id came back live")
end)

t.test("plan (I5): a stored side whose a, b, length or me differs is replaced, whatever the revision, unless it's stale", function()
	local side = core.new_side(record(), 1)
	local changes = {
		{ length = 65 }, { me = "b" },
		{ a = { instanceId = 1, surface = "nauvis", origin = { 0, 32 }, facing = 0 } },
		{ b = { instanceId = 3, surface = "nauvis", origin = { 64, 0 }, facing = 8 } },
		{ b = { instanceId = 2, surface = "other", origin = { 64, 0 }, facing = 8 } },
	}
	for i, fields in ipairs(changes) do
		fields.revision = 6
		t.expect_eq(core.plan(side, record(fields), false), "replace", "change " .. i)
	end
	-- M1: staleness is checked before the geometry change, so an old, misordered message is never trusted.
	t.expect_eq(core.plan(side, record({ length = 65, revision = 3 }), false), "stale",
		"a stale revision, whatever it claims about geometry")
end)

t.test("update takes the record's connectors and returns the added and removed cids", function()
	local side = core.new_side(record({ connectors = { probe("c3", 1), probe("c4", 2) } }), 1)
	local added, removed = core.update(side, record({ revision = 9, connectors = { probe("c4", 2), probe("c9", 5) } }))
	t.expect_same(added, { "c9" })
	t.expect_same(removed, { "c3" })
	t.expect_eq(side.revision, 9)
	t.expect_true(side.connectors.c9 ~= nil and side.connectors.c3 == nil, "the stored connectors follow")
end)

t.test("a new side is inactive and keeps the record's facts", function()
	local side = core.new_side(record({ deleted = true }), 7)
	t.expect_true(not side.active and side.epoch == nil and side.deleted and side.surface_index == 7)
	t.expect_same(side.eps, {}, "no endpoints until SP1b's lanes.reconcile creates them")
	t.expect_eq(side.trace, "0000abcd.1")
end)

t.test("activation: a new epoch activates, the same one is a no-op, and a deactivation makes batches stale", function()
	local side = core.new_side(record(), 1)
	t.expect_true(core.set_active(side, true, "e1", true), "activated")
	t.expect_true(not core.set_active(side, true, "e1", true), "the same epoch again changes nothing")
	t.expect_true(core.epoch_ok(side, "e1"))
	t.expect_true(core.set_active(side, true, "e2", true), "a new epoch replaces the old one")
	t.expect_true(not core.epoch_ok(side, "e1"), "a batch of the old epoch is stale")
	t.expect_true(core.set_active(side, false), "deactivated")
	t.expect_true(not core.set_active(side, false), "twice is a no-op")
	t.expect_true(not core.epoch_ok(side, "e2"), "after a deactivation every batch is stale")
end)

t.test("C1: active=true is ignored before this instance has synced since startup", function()
	local side = core.new_side(record(), 1)
	t.expect_true(not core.set_active(side, true, "e1", false), "not synced yet, so ignored")
	t.expect_true(not side.active and side.epoch == nil)
	t.expect_true(core.set_active(side, true, "e1", true), "synced, so it activates")
end)

t.test("reset leaves every side inactive", function()
	local a, b = core.new_side(record(), 1), core.new_side(record({ id = "e2" }), 1)
	core.set_active(a, true, "e1", true)
	local was = core.reset({ e1 = a, e2 = b })
	t.expect_true(not a.active and a.epoch == nil and not b.active)
	t.expect_true(#was == 1 and was[1] == a, "only the side that was active is returned, for its deactivated hooks")
	t.expect_eq(#core.reset({ e1 = a, e2 = b }), 0, "a second reset finds none active")
end)
