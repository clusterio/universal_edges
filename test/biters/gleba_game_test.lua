local t = require("modules/v2_test/testlib")
local loop = require("modules/v2_test/loopback")

-- Gleba's oracle (cross-border biters plan Task 13, spike 34 G2). Gleba shares the record the sinks case gives it at tick
-- 5 (tile (0, 0) of T = 128), so the loop edge joins the tile's north side ("<id>-x") to its south ("<id>-y"): the
-- gridworld cases on Gleba use its east and west. The north side's oracle stands at local (80, -3.5): world (16, -67.5).
-- Spike 34 G2's spore source: three powered, seeded agricultural towers just inside the north line, each on 21 x 21
-- natural-yumako-soil with its own substation and electric-energy-interface, grown yumako trees round them. With the
-- biters run's gathering times (120..300) spike 34 saw the first tower named about 6100 ticks after setup.
local L = 128
local TOWERS = { { -5.5, -43.5 }, { 16.5, -43.5 }, { 38.5, -43.5 } }

local function towers(surface)
	local built = {}
	for _, p in ipairs(TOWERS) do
		local cx, cy = p[1], p[2]
		local tiles = {}
		for x = math.floor(cx - 10.5), math.ceil(cx + 10.5) - 1 do
			for y = math.floor(cy - 10.5), math.ceil(cy + 10.5) - 1 do
				tiles[#tiles + 1] = { name = "natural-yumako-soil", position = { x, y } }
			end
		end
		surface.set_tiles(tiles)
		local tower = surface.create_entity({ name = "agricultural-tower", position = { cx, cy }, force = "player" })
		surface.create_entity({ name = "substation", position = { cx + 3.5, cy + 3.5 }, force = "player" })
		local eei = surface.create_entity({ name = "electric-energy-interface", position = { cx + 6.5, cy + 6.5 }, force = "player" })
		eei.electric_buffer_size = 1e9
		eei.power_production = 1e7
		tower.get_inventory(defines.inventory.agricultural_tower_input).insert({ name = "yumako-seed", count = 50 })
		for i = -3, 3 do
			for j = -3, 3 do
				if not (i == j and i >= 0 and i <= 2) and (i + j) % 2 ~= 0 then
					local plant = surface.create_entity({ name = "yumako-tree", position = { cx + 3 * i, cy + 3 * j } })
					if plant then
						plant.tick_grown = game.tick
					end
				end
			end
		end
		built[#built + 1] = tower
	end
	return built
end

--- Every 600 ticks until the case is done: empty each tower's output and top its seeds up (spike 34's upkeep).
local function upkeep(ctx, offset, list, state)
	ctx.at(offset, function()
		if state.done then
			return
		end
		for _, tower in ipairs(list) do
			if tower.valid then
				tower.get_inventory(defines.inventory.agricultural_tower_output).clear()
				local input = tower.get_inventory(defines.inventory.agricultural_tower_input)
				if input.get_item_count("yumako-seed") < 20 then
					input.insert({ name = "yumako-seed", count = 30 })
				end
			end
		end
		upkeep(ctx, offset + 600, list, state)
	end)
end

t.case("gleba oracle: a ue-oracle-gleba at the north side's (80, -3.5), indestructible, and its group names an "
	.. "agricultural tower (spike 34 G2)", function(ctx)
	local ID = "bt-gl-or"
	local list, state = nil, {}
	ctx.at(5, function()
		local surface = game.get_surface("gleba") or game.planets.gleba.create_surface()
		storage.gridworld.tiles.gleba = { world = "bt", x = 0, y = 0, size = L, surface = "gleba", seed = 1,
			x1 = -L / 2, y1 = -L / 2, x2 = L / 2, y2 = L / 2, swept = true }
		surface.request_to_generate_chunks({ 0, 0 }, 5)
		surface.force_generate_chunk_requests()
	end)
	ctx.at(300, function()
		local surface = game.surfaces.gleba
		loop.ground(-L, -L, L, 0, "gleba") -- Gleba's own enemies would raid the towers; the raid case owns y >= -16
		list = towers(surface)
		loop.sync()
		loop.edge(ID, L, {}, { -L / 2, -L / 2, 0 }, { L / 2, L / 2, 8 }, "gleba")
		upkeep(ctx, 600, list, state)
	end)
	ctx.at(360, function()
		local o = storage.universal_edges.biters.oracles[ID .. "-x"]
		ctx.expect(o and o.valid and o.name == "ue-oracle-gleba" and not o.destructible, "the north side's oracle, indestructible")
		ctx.expect(o and math.abs(o.position.x - 16) <= 1 and math.abs(o.position.y + 67.5) <= 1, "at (16, -67.5)")
	end)
	local function named(offset)
		ctx.at(offset, function()
			local tgt = storage.universal_edges.biters.targets[ID .. "-x"]
			if not tgt and offset < 7900 then
				return named(offset + 50)
			end
			state.done = true
			ctx.expect(tgt ~= nil, "the oracle named a target (tick " .. (game.tick - ctx.first_tick) .. ")")
			if tgt then
				ctx.expect(game.surfaces.gleba.count_entities_filtered({ name = "agricultural-tower", position = { tgt.x, tgt.y },
					radius = 2 }) > 0, "an agricultural tower, at (" .. tgt.x .. ", " .. tgt.y .. ") at tick " .. (game.tick - ctx.first_tick))
			end
		end)
	end
	named(400)
	ctx.expect_ipc("universal_edges:out", '"phase":"target"')
end)
