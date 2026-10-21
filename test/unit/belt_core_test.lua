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

t.test("belt: a lane's stacks group into runs by key, one gap a stack; another size or quality starts a run", function()
	local runs = {}
	local gaps = { 0, 2, 2, 2.5, 4 }
	for i, st in ipairs({ { "iron-plate", "normal", 4 }, { "copper-plate", "normal", 4 },
		{ "copper-plate", "normal", 4 }, { "copper-plate", "normal", 3 }, { "iron-plate", "rare", 4 } }) do
		core.add_stack(runs, 1, st[1], st[2], st[3], nil, gaps[i])
	end
	t.expect_same(runs, { { "1|iron-plate|normal|4", 4, { 0 } }, { "1|copper-plate|normal|4", 8, { 2, 2 } },
		{ "1|copper-plate|normal|3", 3, { 2.5 } }, { "1|iron-plate|rare|4", 4, { 4 } } },
		"stacks of another size or quality start a run")
end)

t.test("belt: D38 groups consecutive stacks by item, quality, size and freshness; a different p starts a new run", function()
	local runs = {}
	for i, st in ipairs({
		{ "fish", "normal", 1, 50 }, { "fish", "normal", 1, 50 }, { "fish", "normal", 1, 60 },
		{ "iron-plate", "normal", 4, nil }, { "iron-plate", "normal", 4, nil },
	}) do
		core.add_stack(runs, 1, st[1], st[2], st[3], st[4], i)
	end
	t.expect_same(runs, {
		{ "1|fish|normal|1|50", 2, { 1, 2 } }, { "1|fish|normal|1|60", 1, { 3 } }, { "1|iron-plate|normal|4", 8, { 4, 5 } },
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
	core.add_stack(runs, 1, "iron-plate", "normal", 4, nil, 0)
	core.add_stack(runs, 1, "iron-plate", "normal", 4, nil, 1)
	core.add_stack(runs, 1, "copper-plate", "normal", 4, nil, 2)
	t.expect_same(runs, { { "1|iron-plate|normal|4", 8, { 0, 1 } }, { "1|copper-plate|normal|4", 4, { 2 } } },
		"a repeated key extends the run; a different one appends")
end)

t.test("belt: the window refuses past the limit, with no limit yet, and past 64 runs", function()
	t.expect_true(core.may_capture(100, 80, 180, 2, 10))
	t.expect_true(not core.may_capture(100, 81, 180, 2, 10), "past a (possibly stale) limit")
	t.expect_true(not core.may_capture(0, 1, nil, 1, 0), "no status yet")
	t.expect_true(not core.may_capture(0, 4, 400, 5, 60), "65 runs")
	t.expect_eq(core.limit(1000, 120), 1580)
	t.expect_true(core.grown(nil, 400) and core.grown(400, 575) and not core.grown(400, 574))
end)

t.test("belt: credited runs queue per lane in order and go down in stacks of min(s, remaining)", function()
	local buf, got = { {}, {} }, { 0, 0 }
	t.expect_eq(core.take(buf, { { "1|iron-plate|normal|4", 6 }, { "2|coal|normal|1", 2 }, { "1|iron-plate|normal|4", 4 },
		{ "1|copper-plate|normal|4", 4 } }, got, 900), 16)
	t.expect_same(got, { 14, 2 }, "counted per lane")
	t.expect_eq(#buf[1], 3, "a repeated key is its own entry")
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
	t.expect_eq(table.concat(placed, ","), "iron-platex4,iron-platex2,iron-platex4,copper-platex4",
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

t.test("belt spacing: W, HOLD and SLACK are the spec's", function()
	t.expect_true(core.W == 700 and core.HOLD == 128 and core.SLACK == 64)
end)

t.test("belt spacing: a stack's entry tick from its stub, position and speed; its gap, clamped and rounded", function()
	t.expect_eq(core.entry(1, 1, 0.125, 1000), 1000, "at stub 1's upstream end: it just entered")
	t.expect_eq(core.entry(3, 0.5, 0.125, 1000), 980, "2.5 tiles in at turbo: 20 ticks ago")
	t.expect_eq(core.entry(5, 0, 0.03125, 1000), 840, "the dead end at yellow: 160 ticks ago")
	t.expect_eq(core.gap(500, nil), 0, "the first stack after a build")
	t.expect_eq(core.gap(510.04, 500), 10.0625, "rounded to the nearest 1/16 tick")
	t.expect_eq(core.gap(495, 500), 0, "clamped: a stack that piled at the dead end")
end)

t.test("belt spacing: each credited run is its own FIFO entry with its g and arrival; a lane's first gets the span", function()
	local buf, got = { {}, {} }, { 0, 0 }
	t.expect_eq(core.take(buf, { { "1|iron-plate|normal|4", 8, { 5, 2 } }, { "2|coal|normal|1", 1, { 7 } },
		{ "1|iron-plate|normal|4", 4, { 3 } }, { "1|copper-plate|normal|4", 4 } }, got, 900), 17)
	t.expect_same(got, { 16, 1 })
	t.expect_eq(#buf[1], 3, "a repeated key is a new entry")
	local a, b, c = buf[1][1], buf[1][2], buf[1][3]
	t.expect_true(a[1] == "1|iron-plate|normal|4" and a[2] == 8 and a[3] == "iron-plate" and a[4] == "normal"
		and a[5] == 4 and a[6] == nil, "the item fields stay at their indices (teardown reads them)")
	t.expect_true(a.at == 900 and a.i == 1, "arrival and the next gap's index")
	t.expect_same(a.g, { 5, 2 })
	t.expect_eq(a.span, 5, "lane 1's gaps after its first stack's: 2, then 3; copper has none")
	t.expect_true(b.span == nil and c.span == nil and c.g == nil, "only a delivery's first entry on a lane has span")
	t.expect_eq(buf[2][1].span, 0, "lane 2: one stack")
	core.take(buf, { { "1|iron-plate|normal|4", 8, { 1, 2, 3 } } }, got, 950)
	t.expect_true(buf[1][4].g == nil and buf[1][4].span == 0, "a g whose length isn't n / s is dropped")
	core.consume(buf[1], 4)
	t.expect_eq(buf[1][1].i, 2, "consume moves to the next stack's gap")
end)

t.test("belt spacing: the clock anchors a delivery's first stack at at + HOLD - span; the rest follow by their gaps", function()
	local first = { g = { 0, 40 }, i = 1, at = 1000, span = 40 }
	local due, re = core.due(first, nil, 1000)
	t.expect_true(due == 1088 and not re, "no clock yet: anchored, the newest stack due HOLD after arrival")
	first.i = 2
	t.expect_eq((core.due(first, 1088, 1032)), 1128, "inside a delivery: the clock plus the gap")
	due, re = core.due({ g = { 40 }, i = 1, at = 1040, span = 0 }, 1128, 1064)
	t.expect_true(due == 1168 and not re, "the next delivery keeps its gap: 1168 is within 1040 + HOLD + SLACK")
	due, re = core.due({ g = { 40 }, i = 1, at = 1100, span = 0 }, 1300, 1100)
	t.expect_true(due == 1228 and re, "past at + HOLD + SLACK (the round trip got shorter): re-anchored, counted")
	t.expect_eq((core.due({ g = { 0, 8 }, i = 2 }, 1000, 1000)), 1008,
		"after a late stack belt.lua sets the clock to where it went (now): the next keeps its gap")
	local old = { "1|iron-plate|normal|1", 1, "iron-plate", "normal", 1 } -- from before the deploy: no g, i, at, span
	due, re = core.due(old, nil, 5000)
	t.expect_true(due == 5128 and not re, "no clock and no at: anchored HOLD after the poll that finds it")
	t.expect_eq((core.due(old, 5128, 5032)), 5128, "no g: gap 0, compressed")
end)

t.test("belt spacing: a belt idle for minutes restarts HOLD after its delivery arrives, not re-anchored (RF3)", function()
	local due, re = core.due({ g = { 36000 }, i = 1, at = 37000, span = 0 }, 1128, 37000)
	t.expect_true(due == 37128 and not re, "the gap and the arrival moved together")
end)

t.test("belt spacing: a refused insert retries next poll at the same due; only consume moves the index (RF4)", function()
	local e = { g = { 0, 8 }, i = 2, at = 1000 }
	local a, b = core.due(e, 1100, 1100), core.due(e, 1100, 1132)
	t.expect_true(a == 1108 and b == 1108 and e.i == 2, "pure: the clock and the entry are unchanged")
end)

t.test("belt spacing: placement - exact distance, wait, late, behind the back item, full", function()
	t.expect_eq(core.place_at(1020, 1000, 0.125, -1), 2.5, "due in 20 ticks at turbo: 2.5 tiles out")
	t.expect_eq(core.place_at(1041, 1000, 0.125, -1), nil, "more than 5 tiles ahead: it waits")
	t.expect_eq(core.place_at(990, 1000, 0.125, -1), 0, "late: at the front")
	t.expect_eq(core.place_at(990, 1000, 0.125, 1.5), 1.75, "late, behind an item at 1.5: 0.25 behind it")
	t.expect_eq(core.place_at(1010, 1000, 0.125, 1.5), 1.75, "0.25 behind the back item beats its own 1.25")
	t.expect_eq(core.place_at(1030, 1000, 0.125, 4.7), nil, "behind 4.875: the UE belt is full")
	t.expect_eq(core.place_at(1100, 1000, 0.03125, -1), 3.125, "yellow: 100 ticks is 3.125 tiles")
end)

t.test("belt tiers: the UE belt for a border prototype (belt spacing spec §4)", function()
	local belts = { -- sorted by name, as belt.lua passes them
		{ name = "express-transport-belt", belt_speed = 0.09375 },
		{ name = "fast-transport-belt", belt_speed = 0.0625, related_underground_belt = { name = "fast-underground-belt" } },
		{ name = "transport-belt", belt_speed = 0.03125, related_underground_belt = { name = "underground-belt" } },
		{ name = "turbo-transport-belt", belt_speed = 0.125 },
		{ name = "zz-modded-belt", belt_speed = 0.125 },
	}
	t.expect_eq(core.ue_name("transport-belt"), "ue-link-belt")
	t.expect_eq(core.ue_name("fast-transport-belt"), "ue-link-belt-fast-transport-belt")
	t.expect_eq(core.ue_belt({ type = "transport-belt", name = "transport-belt", belt_speed = 0.03125 }, belts),
		"ue-link-belt", "a transport belt: its own")
	t.expect_eq(core.ue_belt({ type = "transport-belt", name = "fast-transport-belt", belt_speed = 0.0625 }, belts),
		"ue-link-belt-fast-transport-belt")
	t.expect_eq(core.ue_belt({ type = "underground-belt", name = "underground-belt", belt_speed = 0.03125 }, belts),
		"ue-link-belt", "an underground: the belt whose related_underground_belt names it")
	t.expect_eq(core.ue_belt({ type = "underground-belt", name = "express-underground-belt", belt_speed = 0.09375 }, belts),
		"ue-link-belt-express-transport-belt", "none names it: a belt of the same speed")
	t.expect_eq(core.ue_belt({ type = "underground-belt", name = "odd-underground", belt_speed = 0.2 }, belts),
		"ue-link-belt-turbo-transport-belt", "a speed no belt has: the fastest, first by name")
	t.expect_eq(core.ue_belt(nil, belts), "ue-link-belt-turbo-transport-belt", "no border entity: the fastest")
end)
