local t = require("testlib")
local core = require("modules/universal_edges/transports/crossing_core")
local geometry = require("modules/universal_edges/edges/geometry_core")

local L = 64

local function frame(ox, oy, facing)
	return { origin = { ox, oy }, facing = facing, length = L }
end

local function near(a, b)
	return math.abs(a - b) < 1e-9
end

t.test("crossing: past means 0.5 to 26 out; players count within [0, L) only, vehicles within the barrier margin", function()
	for _, facing in ipairs({ 0, 4, 8, 12 }) do
		local f = frame(10, 20, facing)
		local function w(x, y)
			return geometry.to_world(f, x, y)
		end
		t.expect_true(core.player_past(f, w(3, -0.51)), "0.51 out")
		t.expect_true(not core.player_past(f, w(3, -0.5)), "exactly 0.5 out is not past")
		t.expect_true(not core.player_past(f, w(3, 0.2)), "inside")
		t.expect_true(core.vehicle_past(f, w(3, -25.9)) and not core.vehicle_past(f, w(3, -26)), "beyond the barriers")
		t.expect_true(core.player_past(f, w(0, -1)) and not core.player_past(f, w(L, -1)), "[0, L)")
		t.expect_true(not core.player_past(f, w(-0.1, -1)), "a player beyond the end is another zone's")
		t.expect_true(core.vehicle_past(f, w(-0.6, -1)) and core.vehicle_past(f, w(L + 31.9, -1)), "a vehicle at a corner")
		t.expect_true(not core.vehicle_past(f, w(-0.4, -1)) and not core.vehicle_past(f, w(L + 0.4, -1)),
			"within 0.5 beyond an end: not yet past the other line")
		t.expect_true(not core.vehicle_past(f, w(-32.1, -1)) and not core.vehicle_past(f, w(L + 32, -1)), "past the margin")
		t.expect_true(core.within(f, w(0, -3)) and not core.within(f, w(-0.1, -3)) and not core.within(f, w(L, -3)))
	end
end)

t.test("crossing: a point mirrors to (L - x, -y) on the partner for every pair of facings", function()
	for _, fa in ipairs({ 0, 4, 8, 12 }) do
		for _, fb in ipairs({ 0, 4, 8, 12 }) do
			local a, b = frame(5, -7, fa), frame(300, 400, fb)
			local wx, wy = core.mirror(a, b, geometry.to_world(a, 3, -2))
			local x, y = geometry.to_local(b, wx, wy)
			t.expect_true(near(x, L - 3) and near(y, 2), "facings " .. fa .. ", " .. fb)
		end
	end
end)

t.test("crossing: the arrival box lies within 8 of the point and at least 0.5 inside", function()
	for _, facing in ipairs({ 0, 4, 8, 12 }) do
		local f = frame(0, 0, facing)
		local x1, y1, x2, y2 = core.arrival_box(f, geometry.to_world(f, 10, 2))
		for _, c in ipairs({ { x1, y1 }, { x2, y2 } }) do
			local lx, ly = geometry.to_local(f, c[1], c[2])
			t.expect_true(lx >= 2 - 1e-9 and lx <= 18 + 1e-9 and ly >= 0.5 - 1e-9 and ly <= 10 + 1e-9, "facing " .. facing)
		end
	end
end)

t.test("player_stays: past by more than 0, short of FAR, within [-0.5, L + 0.5) (crossing spec §3.1)", function()
	local f = frame(0, 0, 0)
	t.expect_eq(core.player_stays(f, 10, -0.2), true, "0.2 past: in the band")
	t.expect_eq(core.player_stays(f, 10, 0.1), false, "inside")
	t.expect_eq(core.player_stays(f, -0.4, -2), true, "0.4 beyond the start: in the band")
	t.expect_eq(core.player_stays(f, -0.6, -2), false, "0.6 beyond the start")
	t.expect_eq(core.player_stays(f, L + 0.4, -2), true, "0.4 beyond the end")
	t.expect_eq(core.player_stays(f, 10, -26), false, "at FAR")
end)

t.test("inside_point: 0.5 inside the line, within [0.5, L - 0.5) along it; nil from FAR (crossing spec §6.2)", function()
	local f = frame(0, 0, 0)
	local x, y = core.inside_point(f, 10, -3)
	t.expect_eq(x, 10, "along unchanged")
	t.expect_eq(y, 0.5, "pulled to 0.5 inside")
	x, y = core.inside_point(f, L + 4, 4)
	t.expect_eq(x, L - 0.5, "clamped to L - 0.5")
	t.expect_eq(y, 4, "already inside")
	t.expect_eq(core.inside_point(f, 10, -26), nil, "FAR out")
	t.expect_eq(core.inside_point(f, -26, 5), nil, "FAR beyond the start")
	t.expect_eq(core.inside_point(f, L + 26, 5), nil, "FAR beyond the end")
end)

t.test("crossing: a corner takes two edge hops on a 3 × 3 grid and lands in the diagonal tile", function()
	-- Tiles of 64: A = [0, 64)², B east of A, C north of A, D north-east (shared tile coordinates, SP2 §12.1).
	local sides = {
		A = { frame(64, 0, 4), frame(0, 0, 0) },        -- A east (to B), A north (to C)
		B = { frame(64, 64, 12), frame(64, 0, 0) },     -- B west (to A), B north (to D)
		D = { frame(128, 0, 8), frame(64, 0, 12) },     -- D south (to B), D west (to C)
	}
	local partner = { [sides.A[1]] = sides.B[1], [sides.B[2]] = sides.D[1] }
	local function first(list, x, y)
		for _, f in ipairs(list) do
			if core.vehicle_past(f, x, y) then
				return f
			end
		end
	end
	t.expect_eq(first(sides.A, 64.7, -0.3), nil, "(64.7, -0.3): past A's east line but within 0.5 of its north: not yet")
	local x, y = 64.7, -0.8 -- past A's east and north lines
	local hop1 = first(sides.A, x, y)
	t.expect_true(hop1 == sides.A[1], "A's east edge takes it first")
	local bx, by = core.mirror(hop1, partner[hop1], x, y)
	t.expect_true(near(bx, x) and near(by, y), "B spawns it at the same point")
	local hop2 = first(sides.B, bx, by)
	t.expect_true(hop2 == sides.B[2], "past B's north line, so the middle tile sends it on")
	local dx, dy = core.mirror(hop2, partner[hop2], bx, by)
	t.expect_true(near(dx, x) and near(dy, y), "D spawns it at the same point")
	t.expect_eq(first(sides.D, dx, dy), nil, "and D keeps it")
end)
