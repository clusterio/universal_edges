local t = require("modules/v2_test/testlib")
local loop = require("modules/v2_test/loopback")
local ue = require("modules/universal_edges")

-- The oracle (cross-border biters spec §6.3; plan Task 7). A surface of its own, paved over [-128, 128), with a gridworld
-- record for the square [-64, 64) (so gridworld's rule for enemies spawned outside its tile applies), and a loop edge
-- joining the square's east side ("<id>-x") to its west side ("<id>-y"). The east side's oracle stands at local (80, -3.5):
-- world (67.5, 16). 40 fuelled burner drills on iron ore just inside the east line pollute; their cloud reaches the
-- oracle's chunk, and its group (gathering cut to 120..300 ticks by the settings case) names one of them.
local L = 128

local function polluters(surface)
	for i = 0, 4 do
		for j = 0, 7 do
			local x, y = 36 + 5 * i, -12 + 6 * j
			for _, d in ipairs({ { -0.5, -0.5 }, { 0.5, -0.5 }, { -0.5, 0.5 }, { 0.5, 0.5 } }) do
				surface.create_entity({ name = "iron-ore", position = { x + d[1], y + d[2] }, amount = 100000 })
			end
			local drill = surface.create_entity({ name = "burner-mining-drill", position = { x, y }, force = "player" })
			drill.insert({ name = "coal", count = 50 })
			local chest = surface.create_entity({ name = "infinity-chest", position = drill.drop_position, force = "player" })
			chest.remove_unfiltered_items = true
		end
	end
end

t.case("oracle: placed indestructible at the east side's (80, -3.5); its units live outside the tile, indestructible; its "
	.. "group names a drill, and a raid coming out there attacks it (spec §6.3)", function(ctx)
	local S, ID = "bt-oracle", "bt-or"
	ctx.at(5, function()
		local surface = game.create_surface(S, { seed = 20200, autoplace_controls = { ["enemy-base"] = { size = 0 } } })
		storage.gridworld.tiles[S] = { world = "bt", x = 0, y = 0, size = L, surface = S, seed = 1,
			x1 = -L / 2, y1 = -L / 2, x2 = L / 2, y2 = L / 2, swept = true }
		loop.ground(-L, -L, L, L, S)
		polluters(surface)
		loop.sync()
		loop.edge(ID, L, {}, { L / 2, -L / 2, 4 }, { -L / 2, L / 2, 12 }, S)
	end)
	ctx.at(60, function()
		local o = storage.universal_edges.biters.oracles[ID .. "-x"]
		ctx.expect(o and o.valid and o.name == "ue-oracle" and not o.destructible, "the east side's oracle, indestructible")
		local f = game.forces["ue-oracle"]
		ctx.expect(o and f and o.force == f and f.ai_controllable, "on force ue-oracle, AI-controllable (spike 42)")
		ctx.expect(f and f.get_cease_fire("enemy") and game.forces.enemy.get_cease_fire(f), "at cease-fire with enemy both ways")
		ctx.expect(o and math.abs(o.position.x - 67.5) <= 1 and math.abs(o.position.y - 16) <= 1, "at (67.5, 16)")
		ctx.expect(prototypes.entity["ue-oracle-unit"].selectable_in_game == false, "its units can't be selected (I2)")
	end)
	ctx.at(1500, function()
		local units = game.surfaces[S].find_entities_filtered({ name = "ue-oracle-unit" })
		local hurtable = 0
		for _, u in ipairs(units) do
			hurtable = hurtable + (u.destructible and 1 or 0)
		end
		ctx.expect(#units > 0 and hurtable == 0, #units .. " oracle units outside the tile, " .. hurtable .. " destructible")
	end)
	local function named(offset)
		ctx.at(offset, function()
			local tgt = storage.universal_edges.biters.targets[ID .. "-x"]
			if not tgt and offset < 6000 then
				return named(offset + 50)
			end
			ctx.expect(tgt ~= nil, "the oracle named a target")
			if not tgt then
				return
			end
			local drills = game.surfaces[S].count_entities_filtered({ name = "burner-mining-drill", position = { tgt.x, tgt.y },
				radius = 1.5 })
			ctx.expect(drills > 0, "a drill, at (" .. tgt.x .. ", " .. tgt.y .. ")")
			local g = game.surfaces[S].create_unit_group({ position = { -20, 0 }, force = "enemy" })
			for k = 1, 3 do
				g.add_member(game.surfaces[S].create_entity({ name = "small-biter", position = { -20 + 2 * k, 0 }, force = "enemy" }))
			end
			ue.biters.walk(g, ID .. "-y", L / 2, { kind = "raid", route = {} }, "0000b17e.6")
		end)
	end
	named(200)
	ctx.expect_ipc("universal_edges:out", '"phase":"target"')
	ctx.expect_ipc("universal_edges:out", '"fallback":false')
end)

t.case("oracle: none on a planet without a pollutant (Vulcanus) (Review Focus 5)", function(ctx)
	ctx.at(10, function()
		if not game.get_surface("vulcanus") then
			game.planets.vulcanus.create_surface()
		end
		loop.ground(-260, -200, -100, -100, "vulcanus")
		loop.sync()
		loop.edge("bt-orv", 64, {}, { -200, -180, 4 }, { -120, -116, 12 }, "vulcanus")
	end)
	ctx.at(700, function()
		local o = storage.universal_edges.biters.oracles
		ctx.expect(o["bt-orv-x"] == nil and o["bt-orv-y"] == nil, "no oracle")
		ctx.expect(storage.universal_edges.edges["bt-orv-x"].active, "on a live side")
	end)
end)

t.case("oracle: a torn-down side's oracle, its target and its already-spawned units all go", function(ctx)
	local S, ID = "bt-orgone", "bt-og"
	ctx.at(5, function()
		local surface = game.create_surface(S, { seed = 20201, autoplace_controls = { ["enemy-base"] = { size = 0 } } })
		storage.gridworld.tiles[S] = { world = "bt", x = 0, y = 0, size = L, surface = S, seed = 1,
			x1 = -L / 2, y1 = -L / 2, x2 = L / 2, y2 = L / 2, swept = true }
		loop.ground(-L, -L, L, L, S)
		polluters(surface)
		loop.sync()
		loop.edge(ID, L, {}, { L / 2, -L / 2, 4 }, { -L / 2, L / 2, 12 }, S)
	end)
	local function down(offset)
		ctx.at(offset, function()
			local n = #game.surfaces[S].find_entities_filtered({ name = "ue-oracle-unit" })
			if n == 0 and offset < 4000 then
				return down(offset + 50)
			end
			ctx.expect(n > 0, "oracle units exist (" .. n .. ")")
			loop.connectors(ID, 2, {}, true)
			ctx.at(offset + 120, function()
				ctx.expect(storage.universal_edges.biters.oracles[ID .. "-x"] == nil, "the oracle is gone")
				ctx.expect(#game.surfaces[S].find_entities_filtered({ name = "ue-oracle-unit" }) == 0, "no oracle unit remains")
			end)
		end)
	end
	down(300)
end)

-- Oracle units must not found bases (spikes 37 and 38: vanilla formed expansion parties at oracles, and UE then destroyed
-- their members). With the oracle's units out, ask the engine for expansion parties and look for a build_base group made
-- of them. buildable_entities isn't readable at runtime, so the behaviour is what is checked.
t.case("oracle: its units form no expansion party (spikes 37 and 38)", function(ctx)
	local S, ID = "bt-orexp", "bt-oe"
	ctx.at(5, function()
		local surface = game.create_surface(S, { seed = 20202, autoplace_controls = { ["enemy-base"] = { size = 0 } } })
		storage.gridworld.tiles[S] = { world = "bt", x = 0, y = 0, size = L, surface = S, seed = 1,
			x1 = -L / 2, y1 = -L / 2, x2 = L / 2, y2 = L / 2, swept = true }
		loop.ground(-L, -L, L, L, S)
		polluters(surface)
		loop.sync()
		loop.edge(ID, L, {}, { L / 2, -L / 2, 4 }, { -L / 2, L / 2, 12 }, S)
	end)
	local function ask(offset)
		ctx.at(offset, function()
			local surface = game.surfaces[S]
			local n = #surface.find_entities_filtered({ name = "ue-oracle-unit" })
			if n == 0 and offset < 4000 then
				return ask(offset + 50)
			end
			ctx.expect(n > 0, "oracle units exist (" .. n .. ")")
			for _, d in ipairs({ { 20, 0 }, { 0, 20 }, { 20, 20 }, { -20, 0 }, { 0, -20 }, { 30, 10 } }) do
				surface.build_enemy_base({ 67.5 + d[1], 16 + d[2] }, 5, "enemy")
			end
			ctx.at(offset + 60, function()
				local settlers = 0
				for _, u in ipairs(game.surfaces[S].find_entities_filtered({ name = "ue-oracle-unit" })) do
					local g = u.commandable and u.commandable.parent_group
					local c = g and g.command
					if c and c.type == defines.command.build_base then
						settlers = settlers + 1
					end
				end
				ctx.expect(settlers == 0, settlers .. " oracle units in build_base groups")
			end)
		end)
	end
	ask(300)
end)

t.case("oracle: its unit and its spawner collide with nothing (plan ruling R14; the vanilla-mask workaround a303a52 "
	.. "reverted, owner 2026-10-20: Wube fixed the desync for the release after 2.1.22)", function(ctx)
	ctx.at(5, function()
		local function layers(name)
			local out = {}
			for k in pairs(prototypes.entity[name].collision_mask.layers) do
				out[#out + 1] = k
			end
			table.sort(out)
			return table.concat(out, ",")
		end
		for _, name in ipairs({ "ue-oracle", "ue-oracle-unit", "ue-oracle-gleba-unit" }) do
			if prototypes.entity[name] then
				ctx.expect(layers(name) == "", name .. " mask " .. layers(name))
			end
		end
	end)
end)
