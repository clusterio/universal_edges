local t = require("testlib")
local core = require("modules/universal_edges/transports/train_core")
local detect_core = require("modules/universal_edges/transports/detect_core") -- SP3a Task 3 (C7)

t.test("rail_rule: a rail across the edge in the border row proposes four columns around it (§6.1)", function()
	t.expect_eq(core.rail_rule(13, 1, 0, 64), 11)
	t.expect_eq(core.rail_rule(17, 1, 0, 64), 15, "a double track's second rail (4 apart) is a link of its own, not inside the first")
	t.expect_eq(core.rail_rule(13, 1, 8, 64), 11, "south runs across the edge too")
	t.expect_eq(core.rail_rule(13, 1, 4, 64), nil, "along the edge")
	t.expect_eq(core.rail_rule(13, 3, 0, 64), nil, "not in the border row")
	t.expect_eq(core.rail_rule(13, -1, 0, 64), nil, "outside")
	t.expect_eq(core.rail_rule(2, 1, 0, 64), 0, "the first column")
	t.expect_eq(core.rail_rule(1, 1, 0, 64), nil, "it would start before column 0")
	t.expect_eq(core.rail_rule(62, 1, 0, 64), 60, "the last column")
	t.expect_eq(core.rail_rule(63, 1, 0, 64), nil, "it would end past L")
end)

t.test("box geometry: v1's lengths, the hold signal before the stop, the outer signal at v1's spot (§12.1)", function()
	t.expect_eq(core.rail_y(1), -1)
	t.expect_eq(core.rail_y(core.OUT_RAILS), -39, "20 rails, 40 tiles (v1: 12, lengthened 2026-10-05)")
	t.expect_eq(core.rail_y(core.IN_RAILS), -109, "55 rails, 110 tiles (v1 train_box.lua:159)")
	t.expect_eq(core.rail_y(core.HOLD_RAIL) + 1, core.HOLD_END, "the hold signal sits at rail 19's inward end")
	t.expect_true(core.HOLD_END > core.rail_y(core.OUT_RAILS) + 1, "and before the end rail, the box's target (SP4 §5)")
	t.expect_eq(core.STOP_Y, nil, "no edge stop (SP4 §5)")
	t.expect_eq(core.rail_y(core.OUTER_RAIL) - 1, core.OUTER_END, "the outer signal at rail 55's outward end")
	t.expect_true(core.OUTER_END < core.FIRST_SPAWN_LIMIT, "beyond every spawned carriage")
end)

t.test("box_dir: a signal for trains heading out makes this side the sender, one for trains coming in the neighbour; " ..
	"both or neither, no direction (train box direction spec §3)", function()
	t.expect_eq(core.box_dir("a", true, false), "ab")
	t.expect_eq(core.box_dir("b", true, false), "ba")
	t.expect_eq(core.box_dir("a", false, true), "ba")
	t.expect_eq(core.box_dir("b", false, true), "ab")
	t.expect_eq(core.box_dir("a", true, true), nil, "both ways")
	t.expect_eq(core.box_dir("b", false, false), nil, "no signal")
end)

t.test("detect_core: the rail row proposes a 4-wide train connector with its layer, its direction left to a signal " ..
	"(§6.1; train box direction spec §6.1)", function()
	local f = { origin = { 0, 0 }, facing = 0, length = 64 }
	t.expect_same(detect_core.propose("a", f, { type = "straight-rail", x = 13, y = 1, direction = 0 }),
		{ type = "train", col = 11, width = 4, params = { layer = "ground" } })
	t.expect_same(detect_core.propose("b", f, { type = "elevated-straight-rail", x = 13, y = 1, direction = 8 }),
		{ type = "train", col = 11, width = 4, params = { layer = "elevated" } })
	t.expect_eq(detect_core.propose("a", f, { type = "straight-rail", x = 13, y = 1, direction = 4 }), nil, "along the edge")
	t.expect_eq(detect_core.propose("a", f, { type = "straight-rail", x = 1, y = 1, direction = 0 }), nil, "before column 0")
	t.expect_same(detect_core.BORDER_TYPES.train, { "straight-rail", "elevated-straight-rail" })
end)

local function rail(id)
	return { unit_number = id }
end

local function stations(records)
	local out = {}
	for i, r in ipairs(records) do
		out[i] = r.station or "<marker>"
	end
	return table.concat(out, ",")
end

t.test("split: the edge record by its end rail's identity, other rail records dropped, current mapped (§12.4, SP4 §5.3)", function()
	local _ -- ponytail: a discard slot for a split() return this test doesn't check before the next call overwrites it
	local kept, edge, cur = core.split({ { station = "A" }, { rail = rail(7), temporary = true }, { rail = rail(99), temporary = true },
		{ station = "B" } }, 3, 99)
	t.expect_same(kept, { { station = "A" }, { temporary = true }, { station = "B" } }, "the edge record kept as a marker")
	t.expect_eq(edge, 2)
	t.expect_eq(cur, 2)
	kept, edge, cur = core.split({ { station = "A" }, { rail = rail(99), temporary = true } }, 2, 99)
	t.expect_same(kept, { { station = "A" }, { temporary = true } })
	t.expect_eq(edge, 2)
	t.expect_eq(cur, 2)
	-- a station record is never the edge record, whatever its name (the prototype's ground stops are gone)
	kept, edge = core.split({ { station = "e 10", temporary = true }, { station = "A" } }, 1, 99)
	t.expect_eq(edge, nil)
	t.expect_eq(stations(kept), "e 10,A")
	-- no edge record (a train driven in by hand): a dropped current moves to the next kept record
	kept, edge, cur = core.split({ { station = "A" }, { rail = rail(5) }, { station = "B" } }, 2, 99)
	t.expect_eq(edge, nil)
	t.expect_eq(stations(kept), "A,B")
	t.expect_eq(cur, 2)
	_, edge = core.split({ { rail = rail(99), temporary = true }, { station = "A" }, { rail = rail(99) } }, 3, 99)
	t.expect_eq(edge, 3, "two records name the end rail: the current one is it")
	kept, _, cur = core.split({}, 1, 99)
	t.expect_eq(#kept, 0)
	t.expect_eq(cur, nil)
end)

t.test("restore_plan: strip a temporary or rail edge record, keep a permanent one, go to the record after it (§12.5)", function()
	local _ -- ponytail: a discard slot for a restore_plan() return this test doesn't check before the next call overwrites it
	local r, go = core.restore_plan({ records = { { station = "A" }, { station = "E", temporary = true }, { station = "B" } },
		current = 2 }, 2)
	t.expect_eq(stations(r), "A,B")
	t.expect_eq(go, 2)
	r, go = core.restore_plan({ records = { { station = "A" }, { station = "B" }, { station = "E", temporary = true } }, current = 3 }, 3)
	t.expect_eq(stations(r), "A,B")
	t.expect_eq(go, 1, "the record after the last wraps to the first")
	r, go = core.restore_plan({ records = { { station = "A" }, { station = "E" }, { station = "B" } }, current = 2 }, 2)
	t.expect_eq(stations(r), "A,E,B", "a permanent edge record stays: the train comes back through it")
	t.expect_eq(go, 3)
	_, go = core.restore_plan({ records = { { station = "A" }, { station = "B" }, { station = "E" } }, current = 3 }, 3)
	t.expect_eq(go, 1)
	r, go = core.restore_plan({ records = { { station = "A" }, { temporary = true } }, current = 2 }, 2)
	t.expect_eq(stations(r), "A", "a rail marker always goes: it can't name a rail here")
	t.expect_eq(go, 1)
	r, go = core.restore_plan({ records = { { station = "E", temporary = true } }, current = 1 }, 1)
	t.expect_eq(#r, 0)
	t.expect_eq(go, nil, "no records left: no go_to_station")
	_, go = core.restore_plan({ records = { { station = "A" }, { station = "B" } }, current = 2 }, nil)
	t.expect_eq(go, 2, "no edge record: the carried current")
	r, go = core.restore_plan({ records = { { station = "E", temporary = true, created_by_interrupt = true },
		{ station = "F", temporary = true, created_by_interrupt = true }, { station = "A" } }, current = 1 }, 1)
	t.expect_eq(stations(r), "F,A")
	t.expect_eq(go, 1)
	t.expect_true(r[1].created_by_interrupt, "a record an interrupt made stays one")
end)

t.test("body: the same state gives the same table, with no time-varying field; rail targets dropped (D21, §12.4)", function()
	local function snap()
		return {
			layer = "ground", speed = -0.41, manual = false, current = 1, end_rail_id = 99,
			carriages = { { name = "locomotive", quality = "normal", flip = false } },
			records = { { rail = rail(99), temporary = true }, { station = "B", wait_conditions = { { type = "time", ticks = 60 } } } },
			interrupts = { { name = "fuel", conditions = {}, inside_interrupt = true, targets = { { station = "F" }, { rail = rail(5) } } } },
		}
	end
	local a = core.body(snap())
	t.expect_same(a, core.body(snap()), "deterministic")
	t.expect_eq(a.v, 1)
	t.expect_eq(a.speed, 0.41, "unsigned: the destination signs it to move inward")
	t.expect_eq(a.edge_record, 1)
	t.expect_same(a.schedule.records[1], { temporary = true }, "the end rail's record crosses as a marker")
	t.expect_eq(a.schedule.current, 1)
	t.expect_same(a.schedule.interrupts, { { name = "fuel", conditions = {}, inside_interrupt = true, targets = { { station = "F" } } } })
	local function walk(x)
		for k, v in pairs(x) do
			t.expect_true(k ~= "tick" and k ~= "trace" and k ~= "id" and k ~= "unit_number" and k ~= "group", "no field " .. tostring(k))
			if type(v) == "table" then
				walk(v)
			end
		end
	end
	walk(a)
end)

t.test("valid: a body this side can read (G5)", function()
	local good = { v = 1, speed = 0, carriages = { { name = "locomotive", quality = "normal" } }, schedule = { records = {} } }
	t.expect_true(core.valid(good))
	t.expect_eq(core.valid({ v = 2, speed = 0, carriages = good.carriages, schedule = good.schedule }), false, "another version")
	t.expect_eq(core.valid({ v = 1, speed = 0, carriages = {}, schedule = good.schedule }), false, "no carriages")
	t.expect_eq(core.valid({ v = 1, speed = 0, carriages = { { name = 3, quality = "normal" } }, schedule = good.schedule }), false)
	t.expect_eq(core.valid({ v = 1, carriages = good.carriages, schedule = good.schedule }), false, "no speed")
	t.expect_eq(core.valid("x"), false)
end)

t.test("spawn plan: twelve at -6 - 7k, the rest within 94 tiles of the front's spawn point (§12.5)", function()
	t.expect_eq(core.first_count(24), 12)
	t.expect_eq(core.first_count(5), 5)
	t.expect_eq(core.spawn_y(1), -6)
	t.expect_eq(core.spawn_y(12), -83)
	t.expect_eq(core.join_y(-83), -90, "the 13th fits at once, 84 tiles behind the front's spawn point (v1 on_tick.lua:37)")
	t.expect_eq(core.join_y(-93), -100, "the last that fits")
	t.expect_eq(core.join_y(-94), nil, "not before the train has moved")
	t.expect_eq(core.join_y(-40), -47)
	t.expect_true(core.spawn_y(12) - 3 > core.FIRST_SPAWN_LIMIT and core.join_y(-83) - 3 >= core.FIRST_SPAWN_LIMIT, "behind the outer signal")
end)

t.test("orientation, flip and the speed's sign ([probe] sp3b-plan)", function()
	t.expect_eq(core.orientation(0, false), 0.5, "facing north: inward is south")
	t.expect_eq(core.orientation(0, true), 0, "a flipped carriage faces out")
	t.expect_eq(core.orientation(4, false), 0.75)
	t.expect_eq(core.orientation(8, false), 0)
	t.expect_eq(core.orientation(12, true), 0.75)
	t.expect_eq(core.flip(true, true), false, "headed to the front, and the front leads")
	t.expect_eq(core.flip(false, true), true)
	t.expect_eq(core.flip(true, false), true, "the train entered backwards")
	t.expect_eq(core.sign(8, 8), 1)
	t.expect_eq(core.sign(0, 8), -1, "a reversed locomotive joined and turned the train's front around")
	t.expect_eq(core.ready(true, false), true)
	t.expect_eq(core.ready(true, true), false, "carriages still wait")
	t.expect_eq(core.ready(false, false), false, "the outer signal is closed")
end)

t.test("gate: ready, and w at or above the last capture's seq, or a later activation (§12.3, R9)", function()
	t.expect_eq(core.gate(nil, nil, "e1"), false, "no status yet")
	t.expect_eq(core.gate({ ready = false }, nil, "e1"), false)
	t.expect_eq(core.gate({ ready = true }, nil, "e1"), true, "the first train")
	local last = { seq = 3, epoch = "e1" }
	t.expect_eq(core.gate({ ready = true, w = 2 }, last, "e1"), false, "a ready sent before the destination took seq 3")
	t.expect_eq(core.gate({ ready = true }, last, "e1"), false, "no w at all")
	t.expect_eq(core.gate({ ready = true, w = 3 }, last, "e1"), true)
	t.expect_eq(core.gate({ ready = true, w = 1 }, last, "e2"), true, "a new epoch: a destination that rolled back can't stall it")
	t.expect_eq(core.gate({ ready = false, w = 9 }, last, "e2"), false)
end)

local function st(name, temp, by_interrupt)
	return { station = name, temporary = temp, created_by_interrupt = by_interrupt }
end

--- group_plan's adds as "<index>:<station>", in order.
local function placed(adds)
	local out = {}
	for i, a in ipairs(adds) do
		out[i] = a.at .. ":" .. a.record.station
	end
	return table.concat(out, ",")
end

t.test("group_plan: the group's records as this tile has them; the record to go to found by name and occurrence (sync §5.6)",
	function()
		local adds, go = core.group_plan({ st("A"), st("B"), st("C") }, 3, { st("A"), st("B"), st("C") })
		t.expect_eq(#adds, 0)
		t.expect_eq(go, 3)
		adds, go = core.group_plan({ st("A"), st("B"), st("C") }, 3, { st("X"), st("A"), st("B"), st("C") })
		t.expect_eq(#adds, 0)
		t.expect_eq(go, 4, "C, behind a record the group gained")
		adds, go = core.group_plan({ st("A"), st("B"), st("A") }, 3, { st("A"), st("B"), st("A") })
		t.expect_eq(go, 3, "the second A, not the first")
		t.expect_eq(#adds, 0)
		adds, go = core.group_plan({ st("A"), st("B") }, 2, { st("A"), st("C") })
		t.expect_eq(go, 1, "the group here lacks B: record 1")
		t.expect_eq(#adds, 0)
		adds, go = core.group_plan({ st("A") }, 1, { { rail = true }, st("A") })
		t.expect_eq(go, 2, "a rail record of this tile's group is passed over")
		t.expect_eq(#adds, 0)
	end)

t.test("group_plan: carried temporaries keep their place before the record that followed them; go to one of them", function()
	local adds, go = core.group_plan({ st("OLD"), st("F", true, true), st("K2") }, 2, { st("K1"), st("K2") })
	t.expect_eq(placed(adds), "2:F")
	t.expect_eq(go, 2, "the interrupt's record, still the one to go to")
	t.expect_true(adds[1].record.created_by_interrupt, "it stays an interrupt's record")
	adds, go = core.group_plan({ st("A"), st("B"), st("T", true) }, 3, { st("A"), st("B") })
	t.expect_eq(placed(adds), "3:T")
	t.expect_eq(go, 3, "temporaries past the last match go at the end")
	adds, go = core.group_plan({ st("T1", true), st("A"), st("T2", true), st("B") }, 4, { st("B"), st("A") })
	t.expect_eq(placed(adds), "1:T2,3:T1", "each before its own follower, in the group's order")
	t.expect_eq(go, 2, "B, second now")
	adds, go = core.group_plan({}, nil, {})
	t.expect_eq(#adds, 0)
	t.expect_eq(go, nil, "nothing to go to")
	adds, go = core.group_plan({ st("T", true) }, 1, {})
	t.expect_eq(placed(adds), "1:T")
	t.expect_eq(go, 1)
end)

t.test("body: a group crosses by name (sync spec §5.6); valid takes a string group or none", function()
	local b = core.body({ layer = "ground", speed = 0.2, manual = false, current = 1, end_rail_id = 99, group = "G",
		carriages = { { name = "locomotive", quality = "normal" } }, records = { { station = "A" } }, interrupts = {} })
	t.expect_eq(b.group, "G")
	t.expect_true(core.valid(b))
	b.group = 7
	t.expect_eq(core.valid(b), false, "a group that isn't a name")
	b.group = nil
	t.expect_true(core.valid(b))
end)
