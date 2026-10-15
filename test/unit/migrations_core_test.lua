local t = require("testlib")
local core = require("modules/universal_edges/runtime/migrations_core")
local ue_schema = require("modules/universal_edges/runtime/schema_core")

local function counting_list(calls)
	return {
		function(state)
			calls[#calls + 1] = 1
			state.a = true
		end,
		function(state)
			calls[#calls + 1] = 2
			state.b = true
		end,
	}
end

t.test("a new table gets every migration in order and the latest schema", function()
	local calls = {}
	t.expect_same(core.run({ schema = 0 }, counting_list(calls)), { schema = 2, a = true, b = true })
	t.expect_same(calls, { 1, 2 })
end)

t.test("only migrations above the table's schema run; a current table is left alone", function()
	local calls = {}
	local state = core.run({ schema = 1, a = "kept" }, counting_list(calls))
	t.expect_same(state, { schema = 2, a = "kept", b = true })
	core.run(state, counting_list(calls))
	t.expect_same(calls, { 2 })
end)

t.test("a table newer than the code is an error, never a reset", function()
	local state = { schema = 3, precious = true }
	t.expect_error(function() core.run(state, counting_list({})) end, "newer")
	t.expect_same(state, { schema = 3, precious = true })
end)

t.test("universal_edges migration 1: before/after fixture", function()
	t.expect_same(core.run({ schema = 0 }, { ue_schema[1] }), {
		schema = 1,
		rt = { seq = 0 },
		scheduler = { tasks = {} },
		stats = {},
		bridge = { out = {}, seen = {}, soft_limit = 3500, out_cap = 1000, flush_every = 1 },
	})
end)
