local t = require("modules/v2_test/testlib")
local loop = require("modules/v2_test/loopback")
local connectors = require("modules/universal_edges/edges/connectors")
local biters = require("modules/universal_edges/transports/biters")
local ue = require("modules/universal_edges")

-- Raids crossing (cross-border biters spec §6.1, §6.2; plan Task 6). Each case: a surface of its own, paved over
-- [-128, 128) on each axis, and a loop edge of length 128 joining the square [-64, 64)'s east side (side a, "<id>-x") to
-- its west side ("<id>-y"): a raid that walks to the west line comes out at the east line. Three unfuelled burner drills
-- just inside the east line are the emitters the fallback target finds.
local L = 128
local EAST = { L / 2, -L / 2, 4 }
local WEST = { -L / 2, L / 2, 12 }
local DRILLS = { { 40, 0 }, { 44, 0 }, { 40, 4 } }

local function setup(name, id)
	local surface = game.create_surface(name, { seed = 20200, autoplace_controls = { ["enemy-base"] = { size = 0 } } })
	loop.ground(-L, -L, L, L, name)
	for _, p in ipairs(DRILLS) do
		surface.create_entity({ name = "burner-mining-drill", position = p, force = "player" })
	end
	loop.sync()
	loop.edge(id, L, {}, EAST, WEST, name)
	return surface
end

local function raid(surface, n, at)
	local g = surface.create_unit_group({ position = at, force = "enemy" })
	for k = 1, n do
		g.add_member(surface.create_entity({ name = "small-biter", position = { at[1] + 2 * k, at[2] }, force = "enemy" }))
	end
	return g
end

t.case("raids: a raid walks to the west line, crosses, and attacks the densest emitters by the east line; a body naming "
	.. "a unit this game lacks is refused", function(ctx)
	local S, ID = "bt-raid", "bt-rd"
	local id
	ctx.at(5, function()
		setup(S, ID)
	end)
	ctx.at(60, function()
		local g = raid(game.surfaces[S], 5, { -20, 0 })
		id = g.unique_id
		ue.biters.walk(g, ID .. "-y", L / 2, { kind = "raid", route = {} }, "0000b17e.1")
		ctx.expect(storage.universal_edges.biters.walking[id] ~= nil, "walking")
		local ep = connectors.get(storage.universal_edges.edges[ID .. "-x"], "b")
		local answer = connectors.types.biters.credit(ep, "ba", { v = 1, kind = "raid", x = 64, route = {},
			members = { { name = "no-such-biter", quality = "normal", health = 1 } } }, { trace = "0000b17e.2", seq = 1 })
		ctx.expect(answer == "reject", "an unknown unit is refused; got " .. tostring(answer))
		answer = connectors.types.biters.credit(ep, "ba", { v = 1, kind = "raid", x = 64, route = {},
			members = { { name = "stone-wall", quality = "normal", health = 1 } } }, { trace = "0000b17e.2", seq = 2 })
		ctx.expect(answer == "reject", "a non-unit prototype is refused; got " .. tostring(answer))
	end)
	local function landed(offset)
		ctx.at(offset, function()
			local units = game.surfaces[S].find_entities_filtered({ name = "small-biter", area = { { 48, -16 }, { 64, 16 } } })
			if #units == 0 and offset < 2000 then
				return landed(offset + 10)
			end
			ctx.expect(storage.universal_edges.biters.walking[id] == nil, "the walk ended")
			ctx.expect(#units == 5, "5 raiders just inside the east line; got " .. #units)
			local g = units[1] and units[1].commandable.parent_group
			local cmd = g and g.command
			ctx.expect(cmd and cmd.type == defines.command.attack_area and cmd.radius == 10, "attack_area, radius 10")
			local d, hit = cmd and cmd.destination, false
			for _, p in ipairs(DRILLS) do
				hit = hit or (d ~= nil and math.abs(d.x - p[1]) < 1.5 and math.abs(d.y - p[2]) < 1.5)
			end
			ctx.expect(hit, "at a drill: no oracle has named a target, so the fallback")
		end)
	end
	landed(100)
	ctx.expect_ipc("universal_edges:out", '"phase":"captured"')
	ctx.expect_ipc("universal_edges:out", '"fallback":true')
end)

t.case("raids: a raid whose edge goes down while it walks is dropped at the border, its members destroyed (Review Focus 1)",
	function(ctx)
		local S, ID = "bt-raid-down", "bt-rdd"
		local g, id
		ctx.at(5, function()
			setup(S, ID)
		end)
		ctx.at(60, function()
			g = raid(game.surfaces[S], 3, { -20, 0 })
			id = g.unique_id
			ue.biters.walk(g, ID .. "-y", L / 2, { kind = "raid", route = {} }, "0000b17e.3")
			loop.activation(ID, false)
		end)
		ctx.at(1500, function()
			ctx.expect(storage.universal_edges.biters.walking[id] == nil, "not walking")
			ctx.expect(game.surfaces[S].count_entities_filtered({ name = "small-biter" }) == 0, "its members destroyed")
		end)
		ctx.expect_ipc("universal_edges:out", '"reason":"edge_inactive"')
	end)

t.case("raids: a raid killed on the way is dropped as gone; a walk that fails is dropped as fail", function(ctx)
	local S, ID = "bt-raid-lost", "bt-rdl"
	local a, b, ida, idb
	ctx.at(5, function()
		setup(S, ID)
	end)
	ctx.at(60, function()
		local surface = game.surfaces[S]
		a, b = raid(surface, 2, { -20, -30 }), raid(surface, 2, { -20, 30 })
		ida, idb = a.unique_id, b.unique_id
		ue.biters.walk(a, ID .. "-y", 40, { kind = "raid", route = {} }, "0000b17e.4")
		ue.biters.walk(b, ID .. "-y", 90, { kind = "raid", route = {} }, "0000b17e.5")
	end)
	ctx.at(70, function()
		for _, m in ipairs(a.members) do
			m.destroy()
		end
		biters.on_command_completed({ unit_number = idb, result = defines.behavior_result.fail })
	end)
	ctx.at(200, function()
		local w = storage.universal_edges.biters.walking
		ctx.expect(w[ida] == nil and w[idb] == nil, "both dropped")
		ctx.expect(not b.valid or #b.members == 0, "the failed raid's members destroyed")
	end)
	ctx.expect_ipc("universal_edges:out", '"reason":"gone"')
	ctx.expect_ipc("universal_edges:out", '"reason":"fail"')
end)

t.case("raids: a raid with no room at the arrival box is refused, with a no_room line (R4a)", function(ctx)
	local S, ID = "bt-raid-full", "bt-rdf"
	ctx.at(5, function()
		local surface = setup(S, ID)
		for x = 44, 64 do
			for y = -20, 20 do
				surface.create_entity({ name = "stone-wall", position = { x, y }, force = "player" })
			end
		end
	end)
	ctx.at(60, function()
		local ep = connectors.get(storage.universal_edges.edges[ID .. "-x"], "b")
		local answer = connectors.types.biters.credit(ep, "ba", { v = 1, kind = "raid", x = 64, route = {},
			members = { { name = "small-biter", quality = "normal", health = 15 } } }, { trace = "0000b17e.6", seq = 1 })
		ctx.expect(answer == "reject", "no room is a refusal; got " .. tostring(answer))
	end)
	ctx.expect_ipc("universal_edges:out", '"phase":"no_room"')
end)

t.case("raids: a success reported while the lane is busy, beyond NEAR, is captured once the lane frees (I1)", function(ctx)
	local S, ID = "bt-raid-busy", "bt-rdb"
	local id, can_send = nil, connectors.methods.can_send
	ctx.at(5, function()
		setup(S, ID)
	end)
	ctx.at(60, function()
		local g = raid(game.surfaces[S], 3, { -44, 0 }) -- 16-20 tiles from the hop point (-60, 0): past NEAR, within 3 x NEAR
		id = g.unique_id
		ctx.expect((g.position.x + 60) ^ 2 + g.position.y ^ 2 > 10 ^ 2, "the group stands beyond NEAR of its hop point")
		ue.biters.walk(g, ID .. "-y", L / 2, { kind = "raid", route = {} }, "0000b17e.7")
		g.set_command({ type = defines.command.stop, ticks_to_wait = 100000 }) -- idle where it stands
		connectors.methods.can_send = function()
			return false
		end
		biters.on_command_completed({ unit_number = id, result = defines.behavior_result.success })
		ctx.expect(storage.universal_edges.biters.walking[id] ~= nil, "still walking: the lane is busy")
	end)
	ctx.at(200, function()
		ctx.expect(storage.universal_edges.biters.walking[id] ~= nil, "still waiting while the lane is busy")
		connectors.methods.can_send = can_send
	end)
	ctx.at(400, function()
		connectors.methods.can_send = can_send
		ctx.expect(storage.universal_edges.biters.walking[id] == nil, "captured once the lane freed")
	end)
	ctx.expect_ipc("universal_edges:out", '"phase":"captured"')
end)
