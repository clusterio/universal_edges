local t = require("testlib")
local core = require("modules/universal_edges/runtime/scheduler_core")

local function fresh()
	return { tasks = {} }, {}
end

local function run_ticks(state, stats, registry, first, last)
	for tick = first, last do
		core.tick(state, stats, registry, tick)
	end
end

t.test("hash is deterministic, so equal intervals get different phases per name", function()
	t.expect_eq(core.hash("a"), 177670)
	t.expect_eq(core.validate("periodic", { name = "a", interval = 10, fn = print }).phase, 0)
	t.expect_eq(core.validate("periodic", { name = "b", interval = 10, fn = print }).phase, 1)
end)

t.test("periodic runs every interval at its phase", function()
	local state, stats = fresh()
	local ran = {}
	local registry = {
		core.validate("periodic", { name = "b", interval = 10, fn = function(tick) ran[#ran + 1] = tick end }),
	}
	run_ticks(state, stats, registry, 0, 30)
	t.expect_same(ran, { 9, 19, 29 })
	t.expect_eq(stats.b.runs, 3)
	t.expect_eq(stats.b.units, 3)
end)

t.test("the work cap is off by default: every due task runs and may report its units", function()
	local state, stats = fresh()
	local registry = {
		core.validate("periodic", { name = "a", interval = 10, fn = function() return 50 end }),
		core.validate("periodic", { name = "k", interval = 10, fn = function() return 50 end }),
	}
	run_ticks(state, stats, registry, 0, 0)
	t.expect_eq(stats.a.runs, 1)
	t.expect_eq(stats.k.runs, 1)
	t.expect_eq(stats.a.units, 50)
	t.expect_eq(stats.k.deferrals, nil)
end)

t.test("with a cap, a task whose turn comes after the budget is deferred to the next tick, keeping its phase", function()
	local state, stats = fresh()
	state.cap = 1
	local ran = {}
	local function task(name)
		return core.validate("periodic", {
			name = name, interval = 10, fn = function(tick) ran[#ran + 1] = name .. "@" .. tick end,
		})
	end
	run_ticks(state, stats, { task("a"), task("k") }, 0, 11)
	t.expect_same(ran, { "a@0", "k@1", "a@10", "k@11" })
	t.expect_eq(stats.k.deferrals, 2)
	t.expect_eq(stats.a.deferrals, nil)
end)

t.test("iterate walks per_tick entries per tick and resumes from its cursor", function()
	local state, stats = fresh()
	local source = { "a", "b", "c", "d", "e" }
	local seen = {}
	local registry = { core.validate("iterate", {
		name = "walk", per_tick = 2, source = function() return source end,
		fn = function(key, value, tick) seen[#seen + 1] = tick .. ":" .. key .. value end,
	}) }
	run_ticks(state, stats, registry, 0, 3)
	t.expect_same(seen, { "0:1a", "0:2b", "1:3c", "1:4d", "2:5e", "3:1a", "3:2b" })
	t.expect_eq(stats.walk.units, 7)
end)

t.test("iterate with an interval rests after a whole walk until interval ticks after the walk began", function()
	local state, stats = fresh()
	local source = { "a", "b", "c" }
	local seen = {}
	local registry = { core.validate("iterate", {
		name = "walk", per_tick = 2, interval = 5, source = function() return source end,
		fn = function(key, value, tick) seen[#seen + 1] = tick .. ":" .. key .. value end,
	}) }
	run_ticks(state, stats, registry, 0, 6)
	t.expect_same(seen, { "0:1a", "0:2b", "1:3c", "5:1a", "5:2b", "6:3c" })
	t.expect_eq(stats.walk.runs, 4)
	t.expect_error(function()
		core.validate("iterate", { name = "i", per_tick = 1, interval = 0.5, source = print, fn = print })
	end, "interval")
end)

t.test("wake ends an iterate task's rest, so the next tick starts a new walk", function()
	local state, stats = fresh()
	local source = { "a" }
	local seen = {}
	local registry = { core.validate("iterate", {
		name = "walk", per_tick = 2, interval = 50, source = function() return source end,
		fn = function(key, value, tick) seen[#seen + 1] = tick .. ":" .. key .. value end,
	}) }
	run_ticks(state, stats, registry, 0, 2)
	core.wake(state, "walk")
	core.wake(state, "never-ran")
	run_ticks(state, stats, registry, 3, 4)
	t.expect_same(seen, { "0:1a", "3:1a" })
end)

t.test("a woken walk is extra: the regular walks keep their cadence", function()
	local state, stats = fresh()
	local source = { "a" }
	local seen = {}
	local registry = { core.validate("iterate", {
		name = "walk", per_tick = 1, interval = 10, source = function() return source end,
		fn = function(key, value, tick) seen[#seen + 1] = tick .. ":" .. key .. value end,
	}) }
	run_ticks(state, stats, registry, 0, 4)
	core.wake(state, "walk")
	run_ticks(state, stats, registry, 5, 12)
	t.expect_same(seen, { "0:1a", "5:1a", "10:1a" })
end)

t.test("an extra walk still going when a period comes due gives way to that period's walk", function()
	local state, stats = fresh()
	local source = { "a", "b", "c" }
	local seen = {}
	local registry = { core.validate("iterate", {
		name = "walk", per_tick = 1, interval = 10, source = function() return source end,
		fn = function(key, value, tick) seen[#seen + 1] = tick .. ":" .. key .. value end,
	}) }
	run_ticks(state, stats, registry, 0, 7)
	core.wake(state, "walk")
	run_ticks(state, stats, registry, 8, 13)
	t.expect_same(seen, { "0:1a", "1:2b", "2:3c", "8:1a", "9:2b", "10:1a", "11:2b", "12:3c" })
end)

t.test("a wake during a walk means that walk doesn't rest when it ends", function()
	local state, stats = fresh()
	local source = { "a", "b", "c" }
	local seen = {}
	local registry = { core.validate("iterate", {
		name = "walk", per_tick = 2, interval = 50, source = function() return source end,
		fn = function(key, value, tick) seen[#seen + 1] = tick .. ":" .. key .. value end,
	}) }
	core.tick(state, stats, registry, 0)
	core.wake(state, "walk")
	run_ticks(state, stats, registry, 1, 2)
	t.expect_same(seen, { "0:1a", "0:2b", "1:3c", "2:1a", "2:2b" })
end)

t.test("a cursor whose key vanished restarts the walk instead of failing", function()
	local state, stats = fresh()
	local source = { x = 1, y = 2, z = 3 }
	local seen = {}
	local registry = { core.validate("iterate", {
		name = "walk", per_tick = 1, source = function() return source end,
		fn = function(key) seen[#seen + 1] = key end,
	}) }
	core.tick(state, stats, registry, 0)
	source[seen[1]] = nil
	core.tick(state, stats, registry, 1)
	t.expect_eq(#seen, 2)
	t.expect_true(seen[2] ~= seen[1], "the next visit is a key that still exists")
	t.expect_true(source[seen[2]] ~= nil)
end)

t.test("queue: FIFO within per_tick; a push beyond cap is dropped; items past ttl expire unprocessed", function()
	local state, stats = fresh()
	local done = {}
	local q = core.validate("queue", {
		name = "q", cap = 2, ttl_ticks = 5, per_tick = 1,
		fn = function(item, tick) done[#done + 1] = item .. "@" .. tick end,
	})
	t.expect_true(core.push(state, stats, q, "a", 0))
	t.expect_true(core.push(state, stats, q, "b", 0))
	t.expect_eq(core.push(state, stats, q, "c", 0), false)
	run_ticks(state, stats, { q }, 1, 2)
	t.expect_same(done, { "a@1", "b@2" })
	t.expect_true(core.push(state, stats, q, "late", 3))
	run_ticks(state, stats, { q }, 9, 9)
	t.expect_same(done, { "a@1", "b@2" })
	t.expect_eq(stats.q.drops, 1)
	t.expect_eq(stats.q.expiries, 1)
	t.expect_eq(stats.q.runs, 2)
end)

t.test("once runs its handler with its args at the due tick, within cap", function()
	local state, stats = fresh()
	local calls = {}
	local later = core.validate("once", {
		name = "later", cap = 1, per_tick = 1,
		fn = function(args, tick) calls[#calls + 1] = args.n .. "@" .. tick end,
	})
	t.expect_true(core.schedule(state, stats, later, 5, { n = 7 }))
	t.expect_eq(core.schedule(state, stats, later, 6, { n = 8 }), false)
	run_ticks(state, stats, { later }, 0, 6)
	t.expect_same(calls, { "7@5" })
	t.expect_eq(stats.later.drops, 1)
	t.expect_eq(#state.tasks.later.pending, 0)
end)

t.test("limits are mandatory: a task without them is refused at registration", function()
	t.expect_error(function() core.validate("periodic", { name = "p", fn = print }) end, "interval")
	t.expect_error(function() core.validate("iterate", { name = "i", per_tick = 1, fn = print }) end, "source")
	t.expect_error(function() core.validate("queue", { name = "q", cap = 2, per_tick = 1, fn = print }) end, "ttl_ticks")
	t.expect_error(function() core.validate("once", { name = "o", cap = 0, per_tick = 1, fn = print }) end, "cap")
	t.expect_error(function() core.validate("sometimes", { name = "s", fn = print }) end, "unknown")
end)

t.test("once entries run at their own due ticks, in any scheduling order", function()
	local state, stats = fresh()
	local calls = {}
	local later = core.validate("once", {
		name = "later", cap = 3, per_tick = 1,
		fn = function(args, tick) calls[#calls + 1] = args.n .. "@" .. tick end,
	})
	core.schedule(state, stats, later, 5, { n = 5 })
	core.schedule(state, stats, later, 3, { n = 3 })
	core.schedule(state, stats, later, 3, { n = 33 })
	run_ticks(state, stats, { later }, 0, 6)
	t.expect_same(calls, { "3@3", "33@4", "5@5" })
end)
