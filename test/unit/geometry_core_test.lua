local t = require("testlib")
local g = require("modules/universal_edges/edges/geometry_core")

local FACINGS = { 0, 4, 8, 12 }
-- One world step north, east, south and west (Factorio: +x east, +y south).
local STEP = { [0] = { 0, -1 }, [4] = { 1, 0 }, [8] = { 0, 1 }, [12] = { -1, 0 } }

local function frame(ox, oy, facing, length)
	return { origin = { ox, oy }, facing = facing, length = length }
end

local function pair(x, y)
	return { x, y }
end

t.test("rot turns clockwise on the map, as the table in spec §8", function()
	t.expect_same(pair(g.rot(3, 5, 0)), { 3, 5 })
	t.expect_same(pair(g.rot(3, 5, 4)), { -5, 3 })
	t.expect_same(pair(g.rot(3, 5, 8)), { -3, -5 })
	t.expect_same(pair(g.rot(3, 5, 12)), { 5, -3 })
	t.expect_error(function() g.rot(1, 0, 2) end, "direction")
end)

t.test("to_local undoes to_world for every facing", function()
	for _, facing in ipairs(FACINGS) do
		local f = frame(256, -256, facing, 512)
		for _, p in ipairs({ { 0, 0 }, { 10, -6 }, { 511, 3 }, { -32, -26 } }) do
			t.expect_same(pair(g.to_local(f, g.to_world(f, p[1], p[2]))), p, "facing " .. facing)
		end
	end
end)

t.test("facing is the outward normal: local -y points out, and +x runs along the edge to the right", function()
	for _, facing in ipairs(FACINGS) do
		local f = frame(0, 0, facing, 10)
		t.expect_same(pair(g.to_world(f, 0, -1)), STEP[facing], "outward, facing " .. facing)
		t.expect_same(pair(g.to_world(f, 1, 0)), STEP[(facing + 4) % 16], "along, facing " .. facing)
		t.expect_eq(g.dir_to_world(f, 0), facing, "local north is outward")
	end
end)

t.test("16-way directions round-trip through every frame", function()
	for _, facing in ipairs(FACINGS) do
		local f = frame(0, 0, facing, 10)
		for d = 0, 15 do
			t.expect_eq(g.dir_to_local(f, g.dir_to_world(f, d)), d)
		end
	end
end)

t.test("flip, flip_dir and col are involutions", function()
	for _, p in ipairs({ { 0, 0 }, { 3, -6 }, { 512, 7 } }) do
		t.expect_same(pair(g.flip(512, g.flip(512, p[1], p[2]))), p)
	end
	for d = 0, 15 do
		t.expect_eq(g.flip_dir(g.flip_dir(d)), d)
	end
	for _, me in ipairs({ "a", "b" }) do
		for pos = 0, 10 do
			t.expect_eq(g.col(me, 12, g.col(me, 12, pos, 2), 2), pos)
		end
	end
end)

t.test("the worked example of spec §8 (v1 data): a point and a connector land on one world tile", function()
	local a, b = frame(256, -256, 8, 512), frame(-256, -256, 0, 512)
	t.expect_true(g.coincident(a, b), "the two sides stitch")
	t.expect_same(pair(g.to_world(a, 256, -6)), { 0, -250 })
	t.expect_same(pair(g.to_world(b, g.flip(512, 256, -6))), { 0, -250 })
	t.expect_eq(g.col("b", 512, 10, 1), 501)
	-- A column's centre, floored, is its world tile: a-column 10 and b-column 501 are both world x = 245.
	t.expect_eq(math.floor(g.to_world(a, 10.5, 0.5)), 245)
	t.expect_eq(math.floor(g.to_world(b, 501.5, -0.5)), 245)
end)

t.test("coincident frames map every point through flip, for every facing", function()
	for _, facing in ipairs(FACINGS) do
		local a = frame(100, 200, facing, 64)
		local dx, dy = g.rot(1, 0, facing)
		local b = frame(100 + 64 * dx, 200 + 64 * dy, (facing + 8) % 16, 64)
		t.expect_true(g.coincident(a, b), "facing " .. facing)
		for _, p in ipairs({ { 0, 0 }, { 7, -3 }, { 64, 20 } }) do
			t.expect_same(pair(g.to_world(b, g.flip(64, p[1], p[2]))), pair(g.to_world(a, p[1], p[2])))
		end
	end
	t.expect_true(not g.coincident(frame(0, 0, 0, 64), frame(64, 0, 0, 64)), "the same facing is not coincident")
end)

t.test("area_to_world re-normalises the corners", function()
	t.expect_same({ g.area_to_world(frame(0, 0, 8, 10), 0, -26, 10, -6) }, { -10, 6, 0, 26 })
end)

t.test("barriers: the count, the centres and the cover for L = 512, 1 and 19 (spec §9)", function()
	t.expect_eq(g.barrier_count(512), 31)
	t.expect_same(pair(g.barrier_centre(0)), { -22, -16 })
	t.expect_same(pair(g.barrier_centre(30)), { 548, -16 })
	t.expect_eq(g.barrier_count(1), 4)
	t.expect_eq(g.barrier_count(19), 5)
	for _, L in ipairs({ 512, 1, 19 }) do
		local n = g.barrier_count(L)
		t.expect_eq(g.barrier_centre(0) - g.SIZE / 2, -g.MARGIN, "L = " .. L .. " starts at -MARGIN")
		t.expect_true(g.barrier_centre(n - 1) + g.SIZE / 2 >= L + g.MARGIN, "L = " .. L .. " reaches L + MARGIN")
		t.expect_true(g.barrier_centre(n - 2) + g.SIZE / 2 < L + g.MARGIN, "L = " .. L .. " has no spare barrier")
		t.expect_eq(g.barrier_centre(1) - g.barrier_centre(0), g.SIZE - g.OVERLAP, "neighbours overlap by OVERLAP")
	end
end)
