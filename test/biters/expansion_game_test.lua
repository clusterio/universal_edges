local t = require("modules/v2_test/testlib")
local loop = require("modules/v2_test/loopback")

-- Expansion crossing (cross-border biters spec §7; plan Task 9). Each case on a surface of its own. Loop edges stand for
-- tiles: A is the square [-64, 64), its north side "<id>-x"; each tile beyond stands far from A in the same save, so that
-- no side's outside holds another tile's ground (in a real tile's save every side is that tile's own). A party is four
-- small biters at (0, 30) in A with build_base, as an expansion party is once it has gathered.
local L = 128
local A_NORTH = { -L / 2, -L / 2, 0 }

local function surface_of(name)
	return game.create_surface(name, { seed = 20200, autoplace_controls = { ["enemy-base"] = { size = 0 } } })
end

local function party(surface, dest)
	local g = surface.create_unit_group({ position = { 0, 30 }, force = "enemy" })
	for k = 1, 4 do
		g.add_member(surface.create_entity({ name = "small-biter", position = { -4 + 2 * k, 30 }, force = "enemy" }))
	end
	g.set_command({ type = defines.command.build_base, destination = dest, distraction = defines.distraction.by_enemy })
	g.start_moving()
	return g
end

--- The group of the small biters in area, and how many there are.
local function group_in(surface, area)
	local units = surface.find_entities_filtered({ name = "small-biter", area = area })
	return units[1] and units[1].commandable.parent_group, #units
end

local function at(cmd, x, y)
	return cmd ~= nil and cmd.type == defines.command.build_base and math.abs(cmd.destination.x - x) < 0.5
		and math.abs(cmd.destination.y - y) < 0.5
end

t.case("expansion: a party bound past A's north line, within its span, walks there, crosses, and builds at the same "
	.. "spot on the far side (spec §7)", function(ctx)
	local S, ID = "bt-exp", "bt-ex"
	ctx.at(5, function()
		surface_of(S)
		loop.ground(-80, -140, 80, 80, S)
		loop.ground(420, 150, 580, 310, S) -- B: its south side is the line y = 300, from x 564 west to 436
		loop.sync()
		loop.edge(ID, L, {}, A_NORTH, { 564, 300, 8 }, S)
	end)
	ctx.at(60, function()
		party(game.surfaces[S], { 0, -120 })
	end)
	local function crossed(offset)
		ctx.at(offset, function()
			local g, n = group_in(game.surfaces[S], { { 480, 280 }, { 520, 300 } })
			if n == 0 and offset < 3000 then
				return crossed(offset + 20)
			end
			ctx.expect(n == 4, "four came out inside B's south line; got " .. n)
			ctx.expect(at(g and g.command, 500, 244), "build_base at (500, 244): (0, -120) on A's side, mirrored")
		end)
	end
	crossed(100)
	ctx.expect_ipc("universal_edges:out", '"phase":"crossed"')
end)

t.case("expansion: a party bound for the diagonal tile crosses into the side tile whose line it is further past, then "
	.. "on into the diagonal one, and builds there (spec §7's corner)", function(ctx)
	local S = "bt-corner"
	ctx.at(5, function()
		surface_of(S)
		loop.ground(-80, -140, 120, 80, S) -- A, and the way to its north-east corner
		loop.ground(860, 260, 1050, 410, S) -- B: south side y = 400 (x 1000 west to 872), east side x = 1000 (y 272 to 400)
		loop.ground(-3010, 260, -2860, 410, S) -- C: west side x = -3000 (y 400 north to 272)
		loop.sync()
		loop.edge("bt-cn", L, {}, A_NORTH, { 1000, 400, 8 }, S)
		loop.edge("bt-ce", L, {}, { 1000, 272, 4 }, { -3000, 400, 12 }, S)
	end)
	ctx.at(60, function()
		party(game.surfaces[S], { 100, -120 })
	end)
	local function built(offset)
		ctx.at(offset, function()
			local g, n = group_in(game.surfaces[S], { { -3000, 330 }, { -2980, 360 } })
			if n == 0 and offset < 6000 then
				return built(offset + 20)
			end
			ctx.expect(n == 4, "four came out inside C's west line; got " .. n)
			ctx.expect(at(g and g.command, -2964, 344), "build_base at (-2964, 344): two crossings, the same spot")
		end)
	end
	built(100)
end)

t.case("expansion: a party heading past a side whose edge is down keeps its build_base (Review Focus 4)", function(ctx)
	local S, ID = "bt-exp-off", "bt-exo"
	local g
	ctx.at(5, function()
		surface_of(S)
		loop.ground(-80, -140, 80, 80, S)
		loop.ground(420, 150, 580, 310, S)
		loop.sync()
		loop.edge(ID, L, {}, A_NORTH, { 564, 300, 8 }, S)
	end)
	ctx.at(50, function()
		loop.activation(ID, false)
	end)
	ctx.at(60, function()
		g = party(game.surfaces[S], { 0, -120 })
	end)
	ctx.at(200, function() -- pre-flight D3: well before a route sealed by the barriers fails (400-700 ticks, spike 25 S1)
		ctx.expect(storage.universal_edges.biters.walking[g.unique_id] == nil, "not walking to the border")
		ctx.expect(at(g.valid and g.command, 0, -120), "still bound to build at (0, -120)")
	end)
end)
