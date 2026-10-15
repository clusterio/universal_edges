local t = require("testlib")
local core = require("modules/universal_edges/transports/detect_core")
local geometry = require("modules/universal_edges/edges/geometry_core")

local FACINGS = { 0, 4, 8, 12 }
local L = 16

local function frame(facing)
	return { origin = { 100, -50 }, facing = facing, length = L }
end

--- An entity of type at local (x, y) facing local direction d, as the world sees it.
local function at(f, type, x, y, d, size)
	local wx, wy = geometry.to_world(f, x, y)
	return { type = type, x = wx, y = wy, direction = geometry.dir_to_world(f, d or 0), size = size }
end

t.test("detect: belts in the border row, across the edge, propose a belt; outward makes this side the source", function()
	for _, facing in ipairs(FACINGS) do
		local f = frame(facing)
		for _, type in ipairs({ "transport-belt", "underground-belt" }) do
			t.expect_same(core.propose("a", f, at(f, type, 3.5, 0.5, 0)),
				{ type = "belt", col = 3, width = 1, params = { dir = "ab" } }, type .. " outward on a, facing " .. facing)
			t.expect_same(core.propose("a", f, at(f, type, 3.5, 0.5, 8)).params, { dir = "ba" }, "inward on a")
			t.expect_same(core.propose("b", f, at(f, type, 3.5, 0.5, 0)).params, { dir = "ba" }, "outward on b")
			t.expect_same(core.propose("b", f, at(f, type, 3.5, 0.5, 8)).params, { dir = "ab" }, "inward on b")
			t.expect_eq(core.propose("a", f, at(f, type, 3.5, 0.5, 4)), nil, "along the edge")
			t.expect_eq(core.propose("a", f, at(f, type, 3.5, 1.5, 0)), nil, "inside, past the border row")
			t.expect_eq(core.propose("a", f, at(f, type, 3.5, -0.5, 0)), nil, "outside")
		end
	end
end)

t.test("detect: ends — columns outside [0, L - width] are ignored", function()
	local f = frame(4)
	t.expect_eq(core.propose("a", f, at(f, "pipe", 0.5, 0.5)).col, 0)
	t.expect_eq(core.propose("a", f, at(f, "pipe", L - 0.5, 0.5)).col, L - 1)
	t.expect_eq(core.propose("a", f, at(f, "pipe", -0.5, 0.5)), nil)
	t.expect_eq(core.propose("a", f, at(f, "pipe", L + 0.5, 0.5)), nil)
	t.expect_eq(core.propose("a", f, at(f, "electric-pole", L, 1, 0, 2)), nil, "a 2×2 pole whose second column is past L")
	t.expect_eq(core.propose("a", f, at(f, "electric-pole", L - 1, 1, 0, 2)).col, L - 2)
end)

t.test("detect: pipes, pipe-to-ground and 1×1 poles in the row; pumps across it at y = 1; 2×2 poles at y = 1", function()
	for _, facing in ipairs(FACINGS) do
		local f = frame(facing)
		t.expect_same(core.propose("a", f, at(f, "pipe-to-ground", 5.5, 0.5, 4)),
			{ type = "fluid", col = 5, width = 1, params = {} }, "any direction")
		t.expect_same(core.propose("b", f, at(f, "pump", 5.5, 1, 8)), { type = "fluid", col = 5, width = 1, params = {} })
		t.expect_eq(core.propose("a", f, at(f, "pump", 5.5, 1, 4)), nil, "a pump along the edge")
		t.expect_eq(core.propose("a", f, at(f, "pump", 5.5, 0, 0)), nil, "a pump straddling the line")
		t.expect_same(core.propose("a", f, at(f, "electric-pole", 7.5, 0.5, 0, 1)),
			{ type = "power", col = 7, width = 1, params = {} })
		t.expect_same(core.propose("a", f, at(f, "electric-pole", 8, 1, 0, 2)),
			{ type = "power", col = 7, width = 2, params = {} }, "a substation over columns 7 and 8")
		t.expect_eq(core.propose("a", f, at(f, "electric-pole", 8, 2, 0, 2)), nil, "a 2×2 pole one row in")
		t.expect_eq(core.propose("a", f, at(f, "assembling-machine", 7.5, 0.5)), nil, "not a detected type")
	end
end)

t.test("detect: the border area covers the connector's columns of the border row and nothing else", function()
	local f = frame(8)
	local x1, y1, x2, y2 = core.border_area(f, 3, 2)
	local lx1, ly1 = geometry.to_local(f, x1, y1)
	local lx2, ly2 = geometry.to_local(f, x2, y2)
	t.expect_true(math.min(lx1, lx2) > 3 and math.max(lx1, lx2) < 5, "columns 3 and 4")
	t.expect_true(math.min(ly1, ly2) > 0 and math.max(ly1, ly2) < 1, "the border row")
end)

--- A logistic container's facts as detect.lua builds them: link says a ue-link-<name> prototype exists.
local function chest(f, x, y, link, q)
	local e = at(f, "logistic-container", x, y)
	e.name, e.q, e.link = "requester-chest", q or "normal", link
	return e
end

t.test("detect: a requester (link) in the border row proposes logistic, width 1, from the side it was built on, " ..
	"with its quality and chest; anything else, or anywhere else, nothing (logistic-link spec §5)", function()
	for _, facing in ipairs(FACINGS) do
		local f = frame(facing)
		t.expect_same(core.propose("a", f, chest(f, 3.5, 0.5, true, "uncommon")), { type = "logistic", col = 3, width = 1,
			params = { dir = "ab", q = "uncommon", chest = "requester-chest" } }, "built on a, facing " .. facing)
		t.expect_same(core.propose("b", f, chest(f, 3.5, 0.5, true)).params,
			{ dir = "ba", q = "normal", chest = "requester-chest" }, "built on b")
		t.expect_eq(core.propose("a", f, chest(f, 3.5, 1.5, true)), nil, "inside, past the row")
		t.expect_eq(core.propose("a", f, chest(f, 3.5, -0.5, true)), nil, "outside: where a link chest stands")
		t.expect_eq(core.propose("a", f, chest(f, 3.5, 0.5, false)), nil, "no link prototype: not a requester")
	end
end)

t.test("detect: a requester at each end of the row proposes; past the ends, nothing", function()
	local f = frame(4)
	t.expect_eq(core.propose("a", f, chest(f, 0.5, 0.5, true)).col, 0)
	t.expect_eq(core.propose("a", f, chest(f, L - 0.5, 0.5, true)).col, L - 1)
	t.expect_eq(core.propose("a", f, chest(f, -0.5, 0.5, true)), nil)
	t.expect_eq(core.propose("a", f, chest(f, L + 0.5, 0.5, true)), nil)
end)
