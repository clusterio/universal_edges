local t = require("testlib")
local core = require("modules/universal_edges/transports/biters_core")

t.test("the oracle stands in the middle of local column L/64, 3.5 tiles out (spec §6.3, plan ruling R13)", function()
	t.expect_eq(core.oracle_x(64), 48)
	t.expect_eq(core.oracle_x(512), 272)
	t.expect_eq(math.floor(core.oracle_x(512) / 32), 512 / 64, "its column")
	t.expect_eq(core.ORACLE_Y, -3.5)
end)
t.test("hop: x kept 8 from the ends, 4 tiles in (spec §6.1)", function()
	local f = { origin = { 64, -64 }, facing = 4, length = 128 } -- an east side
	t.expect_same({ core.hop(f, 64) }, { 64, 60, 0 })
	t.expect_same({ core.hop(f, 2) }, { 8, 60, -56 })
	t.expect_same({ core.hop(f, 500) }, { 120, 60, 56 })
end)

t.test("densest: the first position of the chunk holding most; nil for none (spec §6.3's fallback)", function()
	t.expect_eq(core.densest({}), nil)
	local p = core.densest({ { x = 5, y = 5 }, { x = 40, y = 2 }, { x = 50, y = 20 }, { x = 33, y = 1 } })
	t.expect_same(p, { x = 40, y = 2 })
end)

t.test("valid: a raid's or a party's body, well formed", function()
	local m = { { name = "small-biter", quality = "normal", health = 15 } }
	t.expect_true(core.valid({ v = 1, kind = "raid", x = 64, members = m, route = {} }))
	t.expect_true(core.valid({ v = 1, kind = "raid", x = 64, members = m, route = { "e1", "e2" } }))
	t.expect_true(core.valid({ v = 1, kind = "party", x = 64, members = m, dest = { 10, -20 } }))
	t.expect_true(not core.valid({ v = 2, kind = "raid", x = 64, members = m, route = {} }), "version")
	t.expect_true(not core.valid({ v = 1, kind = "raid", x = 64, members = {}, route = {} }), "no members")
	t.expect_true(not core.valid({ v = 1, kind = "raid", x = 64, members = m }), "a raid without a route")
	t.expect_true(not core.valid({ v = 1, kind = "party", x = 64, members = m }), "a party without a dest")
	t.expect_true(not core.valid({ v = 1, kind = "raid", x = 64, members = { { name = "small-biter" } }, route = {} }),
		"a member without quality and health")
	t.expect_true(not core.valid({ v = 1, kind = "flock", x = 64, members = m, route = {} }), "kind")
end)

t.test("party_side: the side whose line the destination is past within its span; at a corner, the one it is further "
	.. "past; nil when it is past no line (spec §7)", function()
	local N = { id = "n", frame = { origin = { -64, -64 }, facing = 0, length = 128 } }
	local E = { id = "e", frame = { origin = { 64, -64 }, facing = 4, length = 128 } }
	local s, x = core.party_side({ N, E }, 0, -100)
	t.expect_true(s == N and x == 64, "straight north")
	s, x = core.party_side({ N, E }, 100, -120)
	t.expect_true(s == N and x == 164, "north-east, further past the north line (56 against 36)")
	s, x = core.party_side({ N, E }, 120, -80)
	t.expect_true(s == E and x == -16, "north-east, further past the east line (56 against 16)")
	t.expect_eq(core.party_side({ N, E }, 0, 0), nil, "inside")
	t.expect_eq(core.party_side({ E }, 0, -100), nil, "past no live line")
end)
