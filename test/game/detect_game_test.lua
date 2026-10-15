local t = require("modules/v2_test/testlib")
local loop = require("modules/v2_test/loopback")
local ue = require("modules/universal_edges")
local connectors = require("modules/universal_edges/edges/connectors")
local detect = require("modules/universal_edges/transports/detect")
local geometry = ue.geometry

-- sp3-detect: lane-less; its border entity is a belt's, which its build adopts and its poll checks.
ue.connectors.register_type({
	name = "sp3-detect",
	border = "belt",
	lanes = function() return {} end,
	schedule = { per_tick = 2, interval = 10 },
	build = function(ep) detect.adopt(ep) return "ready" end,
	teardown = function() end,
	poll = function(ep) detect.check(ep) end,
})

local asked = {}
local request_removal = connectors.methods.request_removal
connectors.methods.request_removal = function(ep, reason)
	asked[ep.key] = (asked[ep.key] or 0) + 1
	return request_removal(ep, reason)
end

local L, X = 16, 5300
local FA = { origin = { X, 3000 }, facing = 0, length = L }
local FB = { origin = { X + L, 2000 }, facing = 8, length = L }

local function proposals()
	local found = {}
	for _, msg in ipairs(storage.universal_edges.bridge.out.universal_edges or {}) do
		if msg.type == "ue.connector.propose" then
			found[#found + 1] = msg.payload
		end
	end
	return found
end

--- Build name at local (x, y) of frame f, facing local direction d, raising script_raised_built.
local function build(f, name, x, y, d)
	local wx, wy = geometry.to_world(f, x, y)
	return game.surfaces.nauvis.create_entity({ name = name, position = { wx, wy }, force = "player",
		direction = geometry.dir_to_world(f, d or 0), raise_built = true })
end

local function ep(edge, cid)
	return connectors.get(storage.universal_edges.edges[edge], cid)
end

t.case("detect: script builds in a border row propose connectors with their columns and params", function(ctx)
	ctx.at(1500, function()
		loop.ground(X - 4, 2994, X + L + 4, 3006)
		loop.ground(X - 4, 1994, X + L + 4, 2006)
		loop.edge("sp3-det", L, { { cid = "c1", type = "sp3-detect", pos = 3, width = 1, params = {} } },
			{ X, 3000, 0 }, { X + L, 2000, 8 })
	end)
	ctx.at(1530, function()
		build(FA, "transport-belt", 6.5, 0.5, 0)
		build(FA, "pipe", 8.5, 0.5)
		build(FA, "pump", 10.5, 1, 0)
		build(FA, "small-electric-pole", 12.5, 0.5)
		build(FA, "substation", 14, 1)
		build(FB, "fast-transport-belt", 4.5, 0.5, 0)
		build(FA, "wooden-chest", 0.5, 0.5) -- not a detected type
		build(FA, "transport-belt", 5.5, 0.5, 4) -- along the edge
		local got = {}
		for _, p in ipairs(proposals()) do
			got[#got + 1] = table.concat({ p.edge, p.type, p.pos, p.width, p.params.dir or "-" }, " ")
		end
		ctx.expect(table.concat(got, "; ") == "sp3-det-x belt 6 1 ab; sp3-det-x fluid 8 1 -; sp3-det-x fluid 10 1 -; "
			.. "sp3-det-x power 12 1 -; sp3-det-x power 13 2 -; sp3-det-y belt 11 1 ba", "proposals: " .. table.concat(got, "; "))
		-- I4: each side's own frame is cached on the side in storage at its first detected build, not rebuilt per build.
		for edge, f in pairs({ ["sp3-det-x"] = FA, ["sp3-det-y"] = FB }) do
			local frame = storage.universal_edges.edges[edge].frame
			ctx.expect(frame and frame.origin[1] == f.origin[1] and frame.origin[2] == f.origin[2] and frame.facing == f.facing
				and frame.length == L, edge .. "'s frame is cached on its side")
		end
	end)
	ctx.expect_ipc("universal_edges:out", '"phase":"proposed"')
end)

-- Belt-flip (owner, 2026-10-04): a rotation that doesn't change the link's direction still keeps the connector,
-- exactly as before — and still does here, since this test's type (sp3-detect) is lane-less, with no params.dir to
-- ever disagree with a live entity's: the reversal check belt.lua's poll added lives on the real "belt" type, keyed
-- off its own params.dir, not in detect.check (shared by every border-adopting type, this one included). A rotation
-- that DOES reverse a real belt or underground's link now does reverse it instead: see belts_game_test.lua's
-- "rotating the border belt 180 reverses its link" and "flipping a border underground belt" cases.
t.case("detect: a build at an endpoint's columns is adopted, not proposed; upgrades, fast-replaces and a rotation " ..
	"that doesn't change this (lane-less) type's direction keep the connector; a removal asks once (I1)", function(ctx)
	local belt
	ctx.at(1560, function()
		local before = #proposals()
		belt = build(FA, "transport-belt", 3.5, 0.5, 0)
		-- circuit plan Ruling T1a: under FC2 (C8) only an endpoint of the proposal's own type suppresses it, and this
		-- test type is not "belt", so the belt proposes once (the store refuses the overlap); a belt endpoint wouldn't
		ctx.expect(#proposals() == before + 1, "one belt proposal at c1's column: no belt-type endpoint covers it")
		ctx.expect(ep("sp3-det-x", "c1").data.border == belt, "c1 adopted it")
	end)
	ctx.at(1580, function()
		belt.rotate()
		local wx, wy = geometry.to_world(FA, 3.5, 0.5)
		local s = game.surfaces.nauvis
		s.create_entity({ name = "fast-transport-belt", position = { wx, wy }, direction = belt.direction, force = "player",
			fast_replace = true, spill = false })
	end)
	ctx.at(1600, function()
		local b = ep("sp3-det-x", "c1").data.border
		ctx.expect(b and b.valid and b.name == "fast-transport-belt", "the poll adopted the fast-replaced belt")
		-- A robot upgrade, by its effect: the old belt gone and its successor in place in one tick (plan ruling 7).
		local wx, wy = geometry.to_world(FA, 3.5, 0.5)
		local dir = b.direction
		b.destroy({ raise_destroy = true })
		game.surfaces.nauvis.create_entity({ name = "express-transport-belt", position = { wx, wy }, direction = dir,
			force = "player" })
	end)
	ctx.at(1620, function()
		local b = ep("sp3-det-x", "c1").data.border
		ctx.expect(b and b.valid and b.name == "express-transport-belt", "the upgrade was adopted")
		ctx.expect(asked["sp3-det-x/c1"] == nil, "no removal so far")
		b.destroy()
	end)
	ctx.at(1660, function()
		ctx.expect(asked["sp3-det-x/c1"] == 1, "the removal was requested once; got " .. tostring(asked["sp3-det-x/c1"]))
	end)
	ctx.expect_ipc("universal_edges:out", '"phase":"removal_requested"')
end)

-- FC2 (circuit-link spec §5.2, C8): sp3-pole stands in for the circuit type (Task 4): no lanes, its border entity a
-- power pole, so its kind is "power" while its ep.type isn't.
ue.connectors.register_type({
	name = "sp3-pole",
	border = "power",
	lanes = function() return {} end,
	schedule = { per_tick = 2, interval = 10 },
	build = function(e) detect.adopt(e) return "ready" end,
	teardown = function() end,
	poll = function(e) detect.check(e) end,
})

local X2, L2 = 5340, 8
local F2 = { origin = { X2, 3000 }, facing = 0, length = L2 }

t.case("detect: a pole built at a power and a circuit endpoint's columns is cached on both and proposes nothing; at a " ..
	"lone circuit endpoint's it is cached there and proposes power (FC2, C8)", function(ctx)
	ctx.at(1700, function()
		loop.ground(X2 - 4, 2994, X2 + L2 + 4, 3006)
		loop.ground(X2 - 4, 1994, X2 + L2 + 4, 2006)
		loop.edge("sp3-fc2", L2, {
			{ cid = "c1", type = "power", pos = 2, width = 1, params = {} },
			{ cid = "c2", type = "sp3-pole", pos = 2, width = 1, params = {} },
			{ cid = "c3", type = "sp3-pole", pos = 5, width = 1, params = {} },
		}, { X2, 3000, 0 }, { X2 + L2, 2000, 8 })
	end)
	ctx.at(1730, function()
		local before = #proposals()
		local shared = build(F2, "medium-electric-pole", 2.5, 0.5)
		ctx.expect(#proposals() == before, "a pole at a power and a circuit endpoint's columns proposes nothing")
		ctx.expect(ep("sp3-fc2-x", "c1").data.border == shared and ep("sp3-fc2-x", "c2").data.border == shared,
			"it is the border entity of both")
		local lone = build(F2, "medium-electric-pole", 5.5, 0.5)
		local got = proposals()
		local p = got[#got]
		ctx.expect(#got == before + 1 and p.edge == "sp3-fc2-x" and p.type == "power" and p.pos == 5 and p.width == 1,
			"a lone circuit endpoint's pole proposes power")
		ctx.expect(ep("sp3-fc2-x", "c3").data.border == lone, "and is the circuit endpoint's border entity")
	end)
end)

-- Refusal messages (owner, 2026-10-05): X3 = 5400, ticks 3750-3770 (the save's cases end by 3850). detect.notify is the
-- seam: the test replaces it, as no LuaPlayer exists in a game test. The width-6 link builds as any other (its state
-- doesn't matter: detection only reads the side's endpoints), so no other case's train boxes are disturbed.
local bridge = require("modules/universal_edges/runtime/bridge")
local X3 = 5400
local F3 = { origin = { X3, 3000 }, facing = 0, length = L }
local FB3 = { origin = { X3 + L, 2000 }, facing = 8, length = L }
local said, real_notify = {}, detect.notify

t.case("detect: a player's train rail beside a width-6 link says so, once; at the link's own rail it is silent; " ..
	"a refusal reaches the builder", function(ctx)
	ctx.at(3750, function()
		detect.notify = function(player, text) said[#said + 1] = { player = player, text = text } end
		loop.ground(X3 - 4, 2994, X3 + L + 4, 3006)
		loop.ground(X3 - 4, 1994, X3 + L + 4, 2006)
		loop.edge("sp3-ref", L, { { cid = "c1", type = "train", pos = 4, width = 6, params = { dir = "ab", layer = "ground" } } },
			{ X3, 3000, 0 }, { X3 + L, 2000, 8 })
	end)
	ctx.at(3760, function()
		local before = #proposals()
		-- the link's rail centre is local x 7 (col 4 + 3); a rail 4 tiles on, at 11, proposes columns [9, 13): inside [4, 10)
		local wx, wy = geometry.to_world(F3, 11, 1)
		local rail = game.surfaces.nauvis.create_entity({ name = "straight-rail", position = { wx, wy }, force = "player", direction = 0 })
		detect.on_built({ entity = rail, player_index = 7 })
		ctx.expect(#proposals() == before, "no proposal")
		ctx.expect(#said == 1 and said[1].player == 7, "one line for the builder: " .. #said)
		local text = said[1] and said[1].text or ""
		local _, tags = text:gsub("%[gps=", "")
		ctx.expect(tags == 2 and text:find("not made: its rail is too close", 1, true), "both gps tags: " .. text)
		-- a rail at the link's own centre (local 7) stays silent
		said = {}
		wx, wy = geometry.to_world(F3, 7, 1)
		local own = game.surfaces.nauvis.create_entity({ name = "straight-rail", position = { wx, wy }, force = "player", direction = 0 })
		detect.on_built({ entity = own, player_index = 7 })
		ctx.expect(#said == 0, "the link's own rail: silent")
		-- a robot or script build is remembered without a player: no one to tell, but its proposal can be withdrawn
		storage.universal_edges.proposals = nil
		build(FB3, "transport-belt", 3.5, 0.5, 0)
		local _, robot = next(storage.universal_edges.proposals or {})
		ctx.expect(robot and robot.player == nil, "no player: remembered without one")
		storage.universal_edges.proposals = nil
		-- a player's belt is remembered, and the refusal names it
		wx, wy = geometry.to_world(F3, 12.5, 0.5)
		local belt = game.surfaces.nauvis.create_entity({ name = "transport-belt", position = { wx, wy }, force = "player", direction = 0 })
		detect.on_built({ entity = belt, player_index = 7 })
		local trace
		for k in pairs(storage.universal_edges.proposals) do
			trace = k
		end
		ctx.expect(trace ~= nil, "remembered")
		local refusals = 0
		local function refuse(tr)
			refusals = refusals + 1 -- the bridge takes ids "<hex>.<n>" only; its own sender, so no other case's ids clash
			bridge.inbox("universal_edges", helpers.table_to_json({ { id = "d0d00000." .. refusals,
				type = "ue.connector.refused", payload = { trace = tr, reason = "overlap" } } }))
		end
		said = {}
		refuse("unknown")
		ctx.expect(#said == 0, "unknown trace: nothing")
		refuse(trace)
		ctx.expect(#said == 1 and said[1].text:find("Belt link at [gps=", 1, true)
			and said[1].text:find("overlaps another link's columns", 1, true), "overlap text: " .. (said[1] and said[1].text or "none"))
		ctx.expect(next(storage.universal_edges.proposals) == nil, "the entry is gone")
	end)
	ctx.at(3770, function()
		detect.notify = real_notify
	end)
end)

-- Playtest 2026-10-10: a border build whose entity goes before its connector arrives (mined, or destroyed by a script)
-- left the controller a connector nothing ever removed, as its endpoint never had a border entity (§6.2 step 3). The side
-- that proposed it withdraws it when its endpoint is built. X4 = 5364, ticks 3772-3830.
local X4, L4 = 5364, 8
local F4 = { origin = { X4, 3000 }, facing = 0, length = L4 }

t.case("detect: a proposal whose entity went before its connector arrived is withdrawn once the endpoint is built; " ..
	"one whose entity stands is adopted, and the partner side asks nothing", function(ctx)
	ctx.at(3772, function()
		loop.ground(X4 - 4, 2994, X4 + L4 + 4, 3006)
		loop.ground(X4 - 4, 1994, X4 + L4 + 4, 2006)
		loop.edge("sp3-wd", L4, {}, { X4, 3000, 0 }, { X4 + L4, 2000, 8 })
	end)
	ctx.at(3774, function()
		local before = #proposals()
		local gone = build(F4, "transport-belt", 3.5, 0.5, 0)
		build(F4, "transport-belt", 5.5, 0.5, 0)
		ctx.expect(#proposals() == before + 2, "two proposals")
		gone.destroy() -- as gridworld's §9.4 does: no event
		local c = { { cid = "c1", type = "belt", pos = 3, width = 1, params = { dir = "ab" } },
			{ cid = "c2", type = "belt", pos = 5, width = 1, params = { dir = "ab" } } }
		loop.connectors("sp3-wd", 2, c)
	end)
	ctx.at(3830, function()
		ctx.expect(ep("sp3-wd-x", "c1").built and ep("sp3-wd-x", "c2").built, "both endpoints built")
		ctx.expect(asked["sp3-wd-x/c1"] == 1, "the gone belt's connector withdrawn once; got " .. tostring(asked["sp3-wd-x/c1"]))
		ctx.expect(asked["sp3-wd-x/c2"] == nil and ep("sp3-wd-x", "c2").data.border ~= nil, "the standing belt adopted")
		ctx.expect(asked["sp3-wd-y/c1"] == nil and asked["sp3-wd-y/c2"] == nil, "the partner side asks nothing")
	end)
	ctx.expect_ipc("universal_edges:out", '"reason":"withdrawn"')
end)
