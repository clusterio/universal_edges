local t = require("modules/v2_test/testlib")
local loop = require("modules/v2_test/loopback")
local connectors = require("modules/universal_edges/edges/connectors")
local biters = require("modules/universal_edges/transports/biters")
local core = require("modules/universal_edges/transports/biters_core")
local ue = require("modules/universal_edges")

-- Gridworld's raid and expansion toggles as UE keeps them (owner, 2026-10-10). The biters run's cases share one save, so
-- a toggle is off only within one step (with), never while another case runs. Raids: raids_game_test's square
-- [-64, 64), its east side ("<id>-x") looped to its west ("<id>-y"). Expansion: expansion_game_test's A, its north side
-- "<id>-x", and B.
local L = 128

local function surface_of(name)
	return game.create_surface(name, { seed = 20200, autoplace_controls = { ["enemy-base"] = { size = 0 } } })
end

--- fn() with ue.biters.set_enabled(flags); what was there is put back, even when fn fails.
local function with(flags, fn)
	local s = storage.universal_edges.biters
	local was = s.enabled
	ue.biters.set_enabled(flags)
	local ok, err = pcall(fn)
	s.enabled = was
	if not ok then
		error(err, 0)
	end
end

--- Whether a dropped line with reason off and this trace is queued this tick.
local function dropped(trace)
	for _, msg in ipairs(storage.universal_edges.bridge.out.universal_edges or {}) do
		local p = msg.payload
		if msg.type == "trace" and p.phase == "dropped" and p.reason == "off" and p.trace == trace then
			return true
		end
	end
	return false
end

local function smalls(surface, area)
	return surface.count_entities_filtered({ name = "small-biter", area = area })
end

local function body(kind, trace)
	local b = { v = 1, kind = kind, x = 64, members = { { name = "small-biter", quality = "normal", health = 15 } },
		trace = trace }
	if kind == "raid" then
		b.route = {}
	else
		b.dest = { 64, 30 }
	end
	return b
end

t.case("toggles: cross_border_raids off, an arriving raid is dropped (off), so is a walking one at its capture, an "
	.. "oracle's group names no target and a side without an oracle gets none; on, the oracle is placed", function(ctx)
	local S, ID = "bt-tg-ue-raid", "bt-tgu"
	ctx.at(5, function()
		surface_of(S)
		loop.ground(-L, -L, L, L, S)
		loop.sync()
		loop.edge(ID, L, {}, { L / 2, -L / 2, 4 }, { -L / 2, L / 2, 12 }, S)
	end)
	ctx.at(60, function()
		local surface = game.surfaces[S]
		local s = storage.universal_edges.biters
		local east = connectors.get(storage.universal_edges.edges[ID .. "-x"], "b")
		local west = connectors.get(storage.universal_edges.edges[ID .. "-y"], "b")
		local o = s.oracles[ID .. "-x"]
		ctx.expect(o and o.valid, "the east side's oracle, placed while on")
		-- a raid at its point on the west line, and an oracle's group with a command, as each is once gathered
		local _, px, py = core.hop(west.frame, L / 2)
		local g = surface.create_unit_group({ position = { px, py }, force = "enemy" })
		g.add_member(surface.create_entity({ name = "small-biter", position = { px, py }, force = "enemy" }))
		local id = g.unique_id
		local at = surface.find_non_colliding_position("ue-oracle-unit", { 90, 16 }, 16, 0.5)
		local og = surface.create_unit_group({ position = at, force = "enemy" })
		og.add_member(surface.create_entity({ name = "ue-oracle-unit", position = at, force = "enemy" }))
		og.set_command({ type = defines.command.attack_area, destination = { 0, 0 }, radius = 10 })
		local answer
		with({ raids = false }, function()
			answer = connectors.types.biters.credit(east, "ba", body("raid", "0000b17e.t1"), { trace = "0000b17e.t1", seq = 1 })
			ue.biters.walk(g, ID .. "-y", L / 2, { kind = "raid", route = {} }, "0000b17e.t2")
			biters.on_command_completed({ unit_number = id, result = defines.behavior_result.success })
			biters.on_gathered({ group = og })
			o.destroy()
			s.oracles[ID .. "-x"] = nil
			connectors.types.biters.poll(east)
		end)
		ctx.expect(answer == "ok" and smalls(surface, { { 48, -16 }, { 64, 16 } }) == 0 and dropped("0000b17e.t1"),
			"off: the arriving raid is taken and dropped (off); got " .. tostring(answer))
		ctx.expect(s.walking[id] == nil and not g.valid and dropped("0000b17e.t2"),
			"off: the walking raid is dropped (off) at its capture")
		ctx.expect(s.targets[ID .. "-x"] == nil and s.targets[ID .. "-y"] == nil, "off: the oracle's group names nothing")
		ctx.expect(not og.valid or #og.members == 0, "off: its units go; the group is "
			.. (og.valid and #og.members .. " strong" or "gone"))
		ctx.expect(s.oracles[ID .. "-x"] == nil, "off: no oracle placed")
		connectors.types.biters.poll(east)
		ctx.expect(s.oracles[ID .. "-x"] and s.oracles[ID .. "-x"].valid, "on: the oracle placed")
	end)
end)

t.case("toggles: cross_border_expansion off, a party bound past a live line isn't intercepted and an arriving party "
	.. "is dropped (off); on, the party is intercepted", function(ctx)
	local S, ID = "bt-tg-exp", "bt-tge"
	ctx.at(5, function()
		surface_of(S)
		loop.ground(-80, -140, 80, 80, S)
		loop.ground(420, 150, 580, 310, S)
		loop.sync()
		loop.edge(ID, L, {}, { -L / 2, -L / 2, 0 }, { 564, 300, 8 }, S)
	end)
	ctx.at(60, function()
		local surface = game.surfaces[S]
		local walking = storage.universal_edges.biters.walking
		local north = connectors.get(storage.universal_edges.edges[ID .. "-x"], "b")
		local g, answer
		with({ expansion = false }, function()
			g = surface.create_unit_group({ position = { 0, 30 }, force = "enemy" })
			for k = 1, 4 do
				g.add_member(surface.create_entity({ name = "small-biter", position = { -4 + 2 * k, 30 }, force = "enemy" }))
			end
			g.set_command({ type = defines.command.build_base, destination = { 0, -120 },
				distraction = defines.distraction.by_enemy })
			g.start_moving()
			biters.on_gathered({ group = g })
			answer = connectors.types.biters.credit(north, "ba", body("party", "0000b17e.t3"), { trace = "0000b17e.t3", seq = 1 })
		end)
		local id, cmd = g.unique_id, g.command
		ctx.expect(walking[id] == nil and cmd and cmd.type == defines.command.build_base and cmd.destination.y == -120,
			"off: not intercepted, still bound to build at (0, -120)")
		ctx.expect(answer == "ok" and smalls(surface, { { -16, -72 }, { 16, -48 } }) == 0 and dropped("0000b17e.t3"),
			"off: the arriving party is taken and dropped (off); got " .. tostring(answer))
		biters.on_gathered({ group = g })
		ctx.expect(walking[id] ~= nil, "on: intercepted")
		walking[id] = nil -- fixture: the party isn't walked on
		for _, m in ipairs(g.members) do
			m.destroy()
		end
		if g.valid then
			g.destroy()
		end
	end)
end)
