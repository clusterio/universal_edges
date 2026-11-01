local t = require("testlib")
local core = require("modules/universal_edges/transports/body_core")
local geometry = require("modules/universal_edges/edges/geometry_core")

local function near(a, b)
	return math.abs(a - b) < 1e-9
end

local function car(f, x, y, o)
	local wx, wy = geometry.to_world(f, x, y)
	return { name = "car", quality = "normal", type = "car", x = wx, y = wy, orientation = o, speed = 0.4, health = 450,
		inventories = { [1] = { item = "coal" } }, driver = "ann", passenger = "bob" }
end

t.test("body: a car lands mirrored, heading inward, at its speed, for every pair of facings", function()
	for _, fa in ipairs({ 0, 4, 8, 12 }) do
		for _, fb in ipairs({ 0, 4, 8, 12 }) do
			local a = { origin = { 0, 0 }, facing = fa, length = 64 }
			local b = { origin = { 500, 500 }, facing = fb, length = 64 }
			local body = core.body(a, car(a, 10, -1, fa / 16)) -- heading straight out of a
			local x, y, o = core.landing(b, body)
			local lx, ly = geometry.to_local(b, x, y)
			t.expect_true(near(lx, 54) and near(ly, 1), "mirrored, facings " .. fa .. ", " .. fb)
			t.expect_true(near(o, ((fb + 8) % 16) / 16), "heading straight into b")
			t.expect_eq(body.speed, 0.4)
			t.expect_eq(body.driver, "ann")
			t.expect_eq(body.passenger, "bob")
		end
	end
end)

t.test("body: in gridworld's shared coordinates a vehicle lands where it was, heading the same way", function()
	local a = { origin = { 64, 0 }, facing = 4, length = 64 } -- tile A's east side
	local b = { origin = { 64, 64 }, facing = 12, length = 64 } -- tile B's west side
	local f = car(a, 3, -1, 0.3)
	local x, y, o = core.landing(b, core.body(a, f))
	t.expect_true(near(x, f.x) and near(y, f.y) and near(o, 0.3))
end)

t.test("body: a spidertron keeps its destinations in order and its patrol size, and no speed", function()
	local a = { origin = { 0, 0 }, facing = 0, length = 64 }
	local b = { origin = { 64, 0 }, facing = 8, length = 64 }
	local f = { name = "spidertron", quality = "rare", type = "spider-vehicle", x = 5, y = -1, orientation = 0, speed = 0.2,
		health = 3000, inventories = {}, destinations = { { x = 5, y = -10 }, { x = 20, y = -20 }, { x = 30, y = -5 } },
		patrol = 2, remote = { hal = true } }
	local body = core.body(a, f)
	t.expect_eq(body.speed, nil, "a spider-vehicle's speed isn't writable")
	t.expect_same(body.remote, { hal = true }, "the riders holding a remote ride on, so it is back in their hand")
	t.expect_eq(body.patrol, 2)
	local _, _, _, dest = core.landing(b, body)
	t.expect_eq(#dest, 3)
	for i, p in ipairs(f.destinations) do
		t.expect_true(near(dest[i].x, p.x) and near(dest[i].y, p.y), "destination " .. i .. " in place, in order")
	end
end)

t.test("body: the same facts make the same body, with no tick, trace or id in it (D21)", function()
	local a = { origin = { 0, 0 }, facing = 4, length = 64 }
	local one, two = core.body(a, car(a, 1, -2, 0.1)), core.body(a, car(a, 1, -2, 0.1))
	t.expect_same(one, two)
	for _, k in ipairs({ "tick", "trace", "id", "unit_number", "seq" }) do
		t.expect_eq(one[k], nil, k)
	end
end)
