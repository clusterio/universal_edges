local t = require("testlib")
local core = require("modules/universal_edges/runtime/migrations_core")
local schema = require("modules/universal_edges/runtime/schema_core")

-- luacheck: globals storage
-- Migration 7 (SP4) reads the router prototype's storage.router beside UE's own table (spec §4.3): these tests set the
-- global, and clear it after.

local function runtime_state()
	return {
		rt = { seq = 3, boot_id = "7e570000" },
		scheduler = { tasks = {} },
		stats = { x = { runs = 1 } },
		bridge = { out = {}, seen = {}, soft_limit = 3500, out_cap = 1000, flush_every = 1 },
	}
end

t.test("migration 2 adds the edge tables to a schema-1 state and keeps everything else", function()
	local before = runtime_state()
	before.schema = 1
	local after = runtime_state()
	after.schema, after.edges, after.by_surface, after.barriers = 2, {}, {}, {}
	t.expect_same(core.run(before, { schema[1], schema[2] }), after)
end)

t.test("migration 3 adds the endpoint tables and the debug switch, and gives each stored side its eps", function()
	local before = runtime_state()
	before.schema, before.by_surface, before.barriers = 2, { [1] = { e1 = true } }, {}
	before.edges = { e1 = { id = "e1", revision = 4, connectors = { c3 = { cid = "c3" } }, barrier_chunks = {} } }
	local after = runtime_state()
	after.schema, after.by_surface, after.barriers = 3, { [1] = { e1 = true } }, {}
	after.edges = { e1 = { id = "e1", revision = 4, connectors = { c3 = { cid = "c3" } }, barrier_chunks = {}, eps = {} } }
	after.eps, after.owned, after.stream_trace = {}, {}, false
	t.expect_same(core.run(before, { schema[1], schema[2], schema[3] }), after)
end)

t.test("migration 4 adds the players, watch, rejected and waiting tables and keeps everything else (crossing spec §5, " ..
	"§6.4)", function()
	local state = core.run({ schema = 0 }, { schema[1], schema[2], schema[3] })
	state.edges.e1 = { id = "e1", eps = {} }
	local after = core.run(state, { schema[1], schema[2], schema[3], schema[4] })
	t.expect_eq(after.schema, 4)
	t.expect_same(after.players, { pending = {}, placing = {}, hook_failed = {} })
	t.expect_same({ after.watch, after.rejected, after.waiting }, { {}, {}, {} })
	t.expect_eq(after.edges.e1.id, "e1")
end)

t.test("a fresh state reaches schema 11 through migrations 1 to 11, in its final shape", function()
	storage = {}
	local state = core.run({ schema = 0 }, schema)
	storage = nil
	t.expect_eq(state.schema, 11)
	t.expect_same(state.players, { pending = {}, placing = {}, hook_failed = {} })
	t.expect_same({ state.watch, state.rejected, state.waiting }, { {}, {}, {} })
	t.expect_eq(state.frozen, nil)
	t.expect_same(state.biters, { walking = {}, oracles = {}, targets = {} })
	t.expect_same(state.radar, { hosts = {} })
	t.expect_same(state.power_debt, {})
	t.expect_same(state.edges, {})
	t.expect_same(state.eps, {})
	t.expect_eq(state.stream_trace, false)
	t.expect_eq(state.rt.seq, 0)
	t.expect_same(state.marks, {})
	t.expect_same(state.circuit_writing, {})
	t.expect_eq(state.routing.live, false)
	t.expect_eq(state.schedules.live, false)
end)

t.test("migration 5 adds the marks table and keeps everything else", function()
	local state = core.run({ schema = 0 }, { schema[1], schema[2], schema[3], schema[4] })
	state.edges.e1 = { id = "e1", eps = {} }
	local after = core.run(state, { schema[1], schema[2], schema[3], schema[4], schema[5] })
	t.expect_eq(after.schema, 5)
	t.expect_same(after.marks, {})
	t.expect_eq(after.edges.e1.id, "e1")
end)

t.test("migration 6 adds the circuit link's write set and keeps everything else (circuit-link FC6)", function()
	local state = core.run({ schema = 0 }, { schema[1], schema[2], schema[3], schema[4], schema[5] })
	state.edges.e1 = { id = "e1", eps = {} }
	local after = core.run(state, { schema[1], schema[2], schema[3], schema[4], schema[5], schema[6] })
	t.expect_eq(after.schema, 6)
	t.expect_same(after.circuit_writing, {})
	t.expect_eq(after.edges.e1.id, "e1")
end)

t.test("migration 7 moves the router prototype's storage.router into routing, or starts it empty (SP4 §4.3)", function()
	local six = { schema[1], schema[2], schema[3], schema[4], schema[5], schema[6] }
	local anchor, stop = { unit_number = 7 }, { unit_number = 11 }
	storage = { router = { schema = 1, enabled = true, full = false, dirty = false,
		active = { ["a.1"] = { trace = "a.1", anchor = anchor, unit = 7, dest = "R WEST", hops = {}, unrouted = true } },
		by_unit = { [7] = "a.1" }, reserved = { ["a.1"] = stop }, last = { ["d:5"] = { ["c:e/t"] = 90 } },
		list = { { name = "R WEST", tiles = { "t" }, free = 1 } } } }
	local state = core.run({ schema = 0 }, six)
	state.edges.e1 = { id = "e1", eps = {} }
	local after = core.run(state, { schema[1], schema[2], schema[3], schema[4], schema[5], schema[6], schema[7] })
	local r = after.routing
	t.expect_eq(after.schema, 7)
	t.expect_eq(r.active["a.1"].anchor, anchor, "a route keeps its anchor entity")
	t.expect_eq(r.by_unit[7], "a.1")
	t.expect_eq(r.reserved["a.1"], stop, "a reservation keeps its stop")
	t.expect_same(r.last, {}, "the d: rows are not carried (R3)")
	t.expect_same(r.list, {})
	t.expect_eq(r.live, false, "not live until the controller's first resync (R5)")
	t.expect_eq(r.strip, true, "the edge-stop strip is still to run (§5.4)")
	t.expect_eq(r.dirty and r.full, true)
	t.expect_same(r.search, { tick = 0, n = 0, max = 0 })
	t.expect_same({ r.waiting, r.starts, r.goals, r.conns, r.stops, r.fast, r.errs }, { {}, {}, {}, {}, {}, {}, {} })
	t.expect_eq(storage.router, nil, "nothing left at the prototype's key")
	t.expect_eq(after.edges.e1.id, "e1")
	storage = {}
	local fresh = core.run(core.run({ schema = 0 }, six), schema).routing
	storage = nil
	t.expect_same(fresh.active, {})
	t.expect_same(fresh.reserved, {})
	t.expect_eq(fresh.strip, true)
end)

t.test("migration 8 adds the power link's debt set and keeps everything else (spike 22)", function()
	storage = {}
	local seven = core.run({ schema = 0 }, { schema[1], schema[2], schema[3], schema[4], schema[5], schema[6], schema[7] })
	seven.edges.e1 = { id = "e1", eps = {} }
	local after = core.run(seven, { schema[1], schema[2], schema[3], schema[4], schema[5], schema[6], schema[7], schema[8] })
	storage = nil
	t.expect_eq(after.schema, 8)
	t.expect_same(after.power_debt, {})
	t.expect_eq(after.edges.e1.id, "e1")
end)

t.test("migration 9 adds train group sync's state, not live, and keeps everything else (sync spec §4)", function()
	storage = {}
	local eight = core.run({ schema = 0 }, { schema[1], schema[2], schema[3], schema[4], schema[5], schema[6], schema[7],
		schema[8] })
	eight.edges.e1 = { id = "e1", eps = {} }
	local after = core.run(eight, { table.unpack(schema, 1, 9) })
	storage = nil
	t.expect_eq(after.schema, 9)
	t.expect_same(after.schedules, { live = false, cache = { group = {}, interrupt = {} }, hash = { group = {}, interrupt = {} },
		pending = { group = {}, interrupt = {} }, dirty = {} })
	t.expect_eq(after.edges.e1.id, "e1")
end)

t.test("migration 10 adds the radar sync's hosts and keeps everything else (radar-sync plan)", function()
	storage = {}
	local nine = core.run({ schema = 0 }, { table.unpack(schema, 1, 9) })
	nine.edges.e1 = { id = "e1", eps = {} }
	local after = core.run(nine, { table.unpack(schema, 1, 10) })
	storage = nil
	t.expect_eq(after.schema, 10)
	t.expect_same(after.radar, { hosts = {} })
	t.expect_eq(after.edges.e1.id, "e1")
end)

t.test("migration 11 marks the built-in vehicle endpoints and adds the biters' tables (cross-border biters plan)", function()
	storage = {}
	local ten = core.run({ schema = 0 }, { table.unpack(schema, 1, 10) })
	ten.eps = { vehicle = { ["e1/v"] = { cid = "v" } }, probe = { ["e1/c1"] = { cid = "c1" } } }
	local after = core.run(ten, schema)
	storage = nil
	t.expect_eq(after.schema, 11)
	t.expect_eq(after.eps.vehicle["e1/v"].builtin, true, "the vehicle endpoint is built in")
	t.expect_eq(after.eps.probe["e1/c1"].builtin, nil, "a configured connector isn't")
	t.expect_same(after.biters, { walking = {}, oracles = {}, targets = {} })
end)
