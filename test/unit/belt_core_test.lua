local t = require("testlib")
local core = require("modules/universal_edges/transports/belt_core")

t.test("belt: a key carries lane, item, quality and stack size, and parses back", function()
	t.expect_eq(core.key(2, "advanced-circuit", "legendary", 4), "2|advanced-circuit|legendary|4")
	local lane, name, quality, s, p = core.parse("1|iron-plate|normal|1")
	t.expect_true(lane == 1 and name == "iron-plate" and quality == "normal" and s == 1 and p == nil,
		"a four-field key has no freshness")
end)

t.test("belt: D38's fifth field is the item's freshness, and parses back; a four-field key is unchanged", function()
	t.expect_eq(core.key(1, "fish", "normal", 1, 50), "1|fish|normal|1|50")
	t.expect_eq(core.key(1, "fish", "normal", 1, 0), "1|fish|normal|1|0", "p = 0 (fresh) still gets the fifth field")
	t.expect_eq(core.key(1, "iron-plate", "normal", 4, nil), "1|iron-plate|normal|4", "no p: the plain four-field key")
	local lane, name, quality, s, p = core.parse("1|fish|normal|1|50")
	t.expect_true(lane == 1 and name == "fish" and quality == "normal" and s == 1 and p == 50)
	lane, name, quality, s, p = core.parse("2|fish|normal|1|0")
	t.expect_true(lane == 2 and name == "fish" and quality == "normal" and s == 1 and p == 0, "p = 0 parses back, not nil")
end)

t.test("belt: parse is memoized per key, with unchanged results (final review perf #3; extended for D38)", function()
	local match, calls = string.match, 0
	string.match = function(...) -- luacheck: ignore 122
		calls = calls + 1
		return match(...)
	end
	local ok, err = pcall(function()
		for _ = 1, 3 do
			local lane, name, quality, s, p = core.parse("2|pipe|uncommon|4")
			t.expect_true(lane == 2 and name == "pipe" and quality == "uncommon" and s == 4 and p == nil)
			lane, name, quality, s, p = core.parse("1|a|b|c|legendary|12") -- an item name may hold "|": the last two fields split
			t.expect_true(lane == 1 and name == "a|b|c" and quality == "legendary" and s == 12 and p == nil)
			lane, name, quality, s, p = core.parse("2|fish|normal|1|50") -- D38: a spoilable key, its fifth field
			t.expect_true(lane == 2 and name == "fish" and quality == "normal" and s == 1 and p == 50)
		end
	end)
	string.match = match -- luacheck: ignore 122
	t.expect_true(ok, tostring(err))
	-- Each four-field key tries the five-field pattern first (it can't match, D38) and falls back: 2 match calls.
	-- The five-field key matches at once: 1 call. 2 + 2 + 1 = 5, and memoized after, so 3 iterations cost the same as 1.
	t.expect_eq(calls, 5, "one or two matches per distinct key, memoized after")
end)

t.test("belt: D38's p rounds freshness up to 1%, 0..100, never fresher than the stack left", function()
	t.expect_eq(core.spoil_p(0.0), 0)
	t.expect_eq(core.spoil_p(0.001), 1)
	t.expect_eq(core.spoil_p(0.5), 50)
	t.expect_eq(core.spoil_p(1.0), 100)
	t.expect_eq(core.spoil_p(0.994999), 100, "rounds up, never down")
end)

t.test("belt: a single-type lane is one run whose stack size is n over the stacks; a mixed lane keeps its order", function()
	t.expect_same(core.fast_run(1, "iron-plate", "normal", 16, 4), { "1|iron-plate|normal|4", 16 })
	t.expect_same(core.fast_run(2, "iron-plate", "normal", 15, 4), { "2|iron-plate|normal|4", 15 }, "a short last stack")
	local runs = {}
	for _, st in ipairs({ { "iron-plate", "normal", 4 }, { "copper-plate", "normal", 4 },
		{ "copper-plate", "normal", 4 }, { "copper-plate", "normal", 3 }, { "iron-plate", "rare", 4 } }) do
		core.add_stack(runs, 1, st[1], st[2], st[3])
	end
	t.expect_same(runs, { { "1|iron-plate|normal|4", 4 }, { "1|copper-plate|normal|4", 8 }, { "1|copper-plate|normal|3", 3 },
		{ "1|iron-plate|rare|4", 4 } }, "stacks of another size or quality start a run")
end)

t.test("belt: D38 groups consecutive stacks by item, quality, size and freshness; a different p starts a new run", function()
	t.expect_same(core.fast_run(1, "fish", "normal", 16, 4, 50), { "1|fish|normal|4|50", 16 }, "the fast path carries p too")
	local runs = {}
	for _, st in ipairs({
		{ "fish", "normal", 1, 50 }, { "fish", "normal", 1, 50 }, { "fish", "normal", 1, 60 },
		{ "iron-plate", "normal", 4, nil }, { "iron-plate", "normal", 4, nil },
	}) do
		core.add_stack(runs, 1, st[1], st[2], st[3], st[4])
	end
	t.expect_same(runs, {
		{ "1|fish|normal|1|50", 2 }, { "1|fish|normal|1|60", 1 }, { "1|iron-plate|normal|4", 8 },
	}, "the same p merges; a different p, or no p at all, is its own run")
end)

t.test("belt: core.key is memoized per (lane, name, quality, s, p), equal to the concatenated key, and add_stack "
	.. "extends and appends (perf item 2)", function()
	local a = core.key(1, "iron-plate", "normal", 4)
	t.expect_eq(a, "1|iron-plate|normal|4")
	t.expect_eq(core.key(1, "iron-plate", "normal", 4), a, "the memo returns an equal key the second time")
	local b = core.key(2, "fish", "normal", 1, 50)
	t.expect_eq(b, "2|fish|normal|1|50")
	t.expect_eq(core.key(2, "fish", "normal", 1, 50), b, "the memo covers the freshness bucket too (D38)")
	t.expect_eq(core.key(2, "fish", "normal", 1, 60), "2|fish|normal|1|60",
		"a different p is a different key, not the memo's stale one for the same (lane, name, quality, s)")
	local runs = {}
	core.add_stack(runs, 1, "iron-plate", "normal", 4)
	core.add_stack(runs, 1, "iron-plate", "normal", 4)
	core.add_stack(runs, 1, "copper-plate", "normal", 4)
	t.expect_same(runs, { { "1|iron-plate|normal|4", 8 }, { "1|copper-plate|normal|4", 4 } },
		"a repeated key extends the run; a different one appends")
end)

t.test("belt: the window refuses past the limit, with no limit yet, and past 64 runs", function()
	t.expect_true(core.may_capture(100, 80, 180, 2, 10))
	t.expect_true(not core.may_capture(100, 81, 180, 2, 10), "past a (possibly stale) limit")
	t.expect_true(not core.may_capture(0, 1, nil, 1, 0), "no status yet")
	t.expect_true(not core.may_capture(0, 4, 400, 5, 60), "65 runs")
	t.expect_eq(core.limit(1000, 120), 1280)
	t.expect_true(core.grown(nil, 400) and core.grown(400, 500) and not core.grown(400, 499))
end)

t.test("belt: credited runs queue per lane in order and go down in stacks of min(s, remaining)", function()
	local buf, got = { {}, {} }, { 0, 0 }
	t.expect_eq(core.take(buf, { { "1|iron-plate|normal|4", 6 }, { "2|coal|normal|1", 2 }, { "1|iron-plate|normal|4", 4 },
		{ "1|copper-plate|normal|4", 4 } }, got), 16)
	t.expect_same(got, { 14, 2 }, "counted per lane")
	t.expect_eq(#buf[1], 2, "a repeated key joins its run")
	t.expect_eq(core.buffered(buf[1]), 14)
	local placed = {}
	while true do
		local name, _, c = core.next_stack(buf[1])
		if not name then
			break
		end
		placed[#placed + 1] = name .. "x" .. c
		core.consume(buf[1], c)
	end
	t.expect_eq(table.concat(placed, ","), "iron-platex4,iron-platex4,iron-platex2,copper-platex4",
		"uniform stacks, the run's last one holding the remainder")
	t.expect_eq(core.buffered(buf[2]), 2)
end)

t.test("belt: D38's freshness threads through credit and placement; a non-spoilable key is still four fields", function()
	local buf, got = { {}, {} }, { 0, 0 }
	core.take(buf, { { "1|fish|normal|1|50", 2 }, { "1|iron-plate|normal|4", 4 } }, got)
	local name, quality, c, p = core.next_stack(buf[1])
	t.expect_true(name == "fish" and quality == "normal" and c == 1 and p == 50, "the spoilable run carries p")
	core.consume(buf[1], c)
	name, quality, c, p = core.next_stack(buf[1])
	t.expect_true(name == "fish" and quality == "normal" and c == 1 and p == 50, "the run's second stack, same p")
	core.consume(buf[1], c)
	name, quality, c, p = core.next_stack(buf[1])
	t.expect_true(name == "iron-plate" and quality == "normal" and c == 4 and p == nil, "a non-spoilable run carries no p")
end)

t.test("belt: placement starts behind the back-most item, front slot first", function()
	t.expect_eq(core.first_slot(-1), 1, "an empty stub: the inner tile's front slot")
	t.expect_same(core.SLOTS[1], { 1, 0.125 })
	t.expect_eq(core.first_slot(0.25), 3, "behind an item at 0.25 on the inner tile: 0.625 there")
	t.expect_same(core.SLOTS[core.first_slot(2.75)], { 4, 0.125 }, "behind tile 3's back slot: tile 4's front")
	t.expect_eq(core.first_slot(4.75), nil, "the outer tile's back slot is taken: full")
end)
