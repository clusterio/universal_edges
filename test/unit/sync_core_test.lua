local t = require("testlib")
local core = require("modules/universal_edges/schedules/sync_core")

t.test("canon: equal content gives an equal string whatever order its tables were built in (plan ruling 3)", function()
	local a = { records = { { station = "A", wait_conditions = { { type = "time", ticks = 60 } } } }, interrupts = { "I" } }
	local b = { interrupts = { "I" } }
	b.records = { { wait_conditions = { { ticks = 60, type = "time" } }, station = "A" } }
	t.expect_eq(core.canon(a), core.canon(b))
	t.expect_true(core.canon(a) ~= core.canon({ records = { { station = "B" } }, interrupts = { "I" } }), "a different station")
	t.expect_true(core.canon({ "a", "b" }) ~= core.canon({ "b", "a" }), "order inside a list counts")
	t.expect_true(core.canon({ x = "1" }) ~= core.canon({ x = 1 }), "a string is not a number")
	t.expect_eq(core.canon({}), "{}")
end)

t.test("group_content: permanent station records and the interrupts' names; rail and temporary records stay local (§4)",
	function()
		local c = core.group_content({
			{ station = "A", wait_conditions = { { type = "time", ticks = 60 } }, temporary = false, created_by_interrupt = false },
			{ rail = {}, temporary = false }, -- a rail record: this tile's own
			{ station = "T", temporary = true }, -- one train's own
			{ station = "B", allows_unloading = true },
		}, { { name = "I1", conditions = {} }, { name = "I2" } })
		t.expect_same(c, { records = { { station = "A", wait_conditions = { { type = "time", ticks = 60 } } },
			{ station = "B", allows_unloading = true } }, interrupts = { "I1", "I2" } })
	end)

t.test("interrupt_content: rail targets dropped, as at a border (§4)", function()
	local c = core.interrupt_content({ name = "I", conditions = { { type = "time", ticks = 100 } }, inside_interrupt = true,
		targets = { { station = "X" }, { rail = {} } } })
	t.expect_same(c, { name = "I", conditions = { { type = "time", ticks = 100 } }, inside_interrupt = true,
		targets = { { station = "X" } } })
end)

t.test("schedule_of: a group's records and each interrupt it names, from the cache; one the cache lacks is left out", function()
	local cache = { I1 = { v = 2, content = { name = "I1", targets = {} } } }
	t.expect_same(core.schedule_of({ records = { { station = "A" } }, interrupts = { "I1", "GONE" } }, cache),
		{ records = { { station = "A" } }, interrupts = { { name = "I1", targets = {} } } })
	t.expect_same(core.schedule_of({}, cache), { records = {}, interrupts = {} }, "an empty group's content from JSON")
end)

t.test("count_rows: one row per name, groups then interrupts, by name (§5.4)", function()
	t.expect_same(core.count_rows({ B = 1, A = 2 }, { I = 3 }),
		{ { "group", "A", 2 }, { "group", "B", 1 }, { "interrupt", "I", 3 } })
	t.expect_same(core.count_rows({}, {}), {})
end)
