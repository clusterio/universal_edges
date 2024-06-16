local constants = require("modules/universal_edges/constants")
local edge_util = require("modules/universal_edges/edge/util")

--[[
	Create:
	- rail on border
	- trainstop
	- get parking area length
	- make parking area indestructible?
]]
local function create_train_source_box(offset, edge, surface)
	if not edge.linked_trains then
		edge.linked_trains = {}
	end
	if edge.linked_trains[offset] ~= nil then
		log("FATAL: train edge already exists at " .. offset)
		return
	end

	local edge_target = edge_util.edge_get_local_target(edge)
	local edge_x = edge_util.offset_to_edge_x(offset, edge)

	-- Discover parking area size
	local parking_area_size = 1 -- Initial rail from the event
	local still_looking = true
	while parking_area_size <= 30 and still_looking do
		local rail = surface.find_entity("straight-rail",
			edge_util.edge_pos_to_world({ edge_x, -1 + parking_area_size * 2 }, edge))
		if rail ~= nil then
			parking_area_size = parking_area_size + 1
		else
			still_looking = false
		end
	end

	-- Depends on how many signals/stations we need to make space for
	local number_of_rails_to_spawn = 2

	-- if edge_target.direction % 4 == 0 then -- Entrance is north/south
	local rails = {}
	for i = 1, number_of_rails_to_spawn do
		rails[#rails + 1] = surface.create_entity {
			name = "straight-rail",
			position = edge_util.edge_pos_to_world({ edge_x, 1 - i * 2 }, edge),
			direction = edge_target.direction,
		}
	end

	local stop = surface.create_entity {
		name = "train-stop",
		position = edge_util.edge_pos_to_world({ edge_x + 2, -3 }, edge),
		direction = edge_target.direction,
	}
	local signal = surface.create_entity {
		name = "rail-signal",
		position = edge_util.edge_pos_to_world({ edge_x + 1.5, -0.5 }, edge),
		direction = (edge_target.direction + 4) % 8,
	}

	if not edge.linked_trains then
		edge.linked_trains = {}
	end

	edge.linked_trains[offset] = {
		is_input = true,
		rails = rails,
		stop = stop,
		signal = signal,
		parking_area_size = parking_area_size,
		teleport_area_size = 3, -- Gets longer the more pathfinding stations we have to make space for
	}

	return {
		parking_area_size = parking_area_size
	}
end

local function remove_train_source_box(offset, edge, _surface)
	if not edge.linked_trains then
		edge.linked_trains = {}
	end
	if edge.linked_trains and edge.linked_trains[offset] then
		local link = edge.linked_trains[offset]

		if link.stop and link.stop.valid then
			link.stop.destroy()
		end
		if link.signal and link.signal.valid then
			link.signal.destroy()
		end
		for _index, rail in pairs(link.rails) do
			if rail and rail.valid then
				rail.destroy()
			end
		end
		if link.penalty_rails ~= nil then
			for _index, rail in pairs(link.penalty_rails) do
				if rail and rail.valid then
					rail.destroy()
				end
			end
		end
		-- Rmove old visualizations
		if link.debug_visu then
			for index, visu in ipairs(link.debug_visu) do
				rendering.destroy(visu)
				link.debug_visu[index] = nil
			end
		end

		edge.linked_trains[offset] = nil
	end
end

--[[
	Create train landing areaa
	- rail on border
	- extends back as far as parking_area_size
	- signal on rear end as occopancy detector
]]
local function create_train_destination_box(offset, edge, surface, update)
	log("Creating train destination box" .. serpent.block(update))
	local edge_target = edge_util.edge_get_local_target(edge)
	local edge_x = edge_util.offset_to_edge_x(offset, edge)

	-- Parking length in number of rail tiles (each rail tile is 2x2)
	-- local parking_length = update.data.parking_area_size + 2
	local parking_length = constants.MAX_TRAIN_LENGTH * 4 + 2

	-- Prepare the area with concrete. For some reason we can create rails on water but not trains
	local tiles = {}
	for i = 1, parking_length * 2 do
		-- Make space for signal
		tiles[#tiles + 1] = {
			name = "refined-concrete",
			position = edge_util.edge_pos_to_world({ edge_x - 2, i * -1 }, edge)
		}
		-- Make space for rails
		tiles[#tiles + 1] = {
			name = "refined-concrete",
			position = edge_util.edge_pos_to_world({ edge_x - 1, i * -1 }, edge)
		}
		tiles[#tiles + 1] = {
			name = "refined-concrete",
			position = edge_util.edge_pos_to_world({ edge_x, i * -1 }, edge)
		}
		tiles[#tiles + 1] = {
			name = "refined-concrete",
			position = edge_util.edge_pos_to_world({ edge_x + 1, i * -1 }, edge)
		}
	end
	surface.set_tiles(tiles)

	local rails = {}
	for i = 1, parking_length do
		-- Check if rail already exists - might happen if station was removed while train was on output
		local rail = surface.find_entity(
			"straight-rail",
			edge_util.edge_pos_to_world({ edge_x, 1 - i * 2 }, edge)
		)
		if rail.direction == edge_target.direction then
			rails[#rails + 1] = rail
			-- Skip creating new rail
		else
			rails[#rails + 1] = surface.create_entity {
				name = "straight-rail",
				position = edge_util.edge_pos_to_world({ edge_x, 1 - i * 2 }, edge),
				direction = edge_target.direction,
			}
		end
	end

	local signal = surface.create_entity {
		name = "rail-signal",
		position = edge_util.edge_pos_to_world({ edge_x - 1.5, 0.5 - parking_length * 2 }, edge),
		direction = edge_target.direction,
	}

	if not edge.linked_trains then
		edge.linked_trains = {}
	end

	if edge.linked_trains[offset] then
		edge.linked_trains[offset].is_input = false
		edge.linked_trains[offset].rails = rails
		edge.linked_trains[offset].signal = signal
	else
		edge.linked_trains[offset] = {
			is_input = false,
			rails = rails,
			signal = signal,
		}
	end

	--[[
		Tell other destination links on this server to update their paths.
		This enables propagaiton over multiple instances in a cluster.
	]]
	if (
			global.universal_edges.pathfinder.rescan_connector_paths_after == nil
			or global.universal_edges.pathfinder.rescan_connector_paths_after < game.tick
		)
	then
		global.universal_edges.pathfinder.rescan_connector_paths_after = game.tick + 180
	end

	return true
end

local function remove_train_destination_box(offset, edge, _surface)
	game.print("Removing destination box at " .. offset)
	if edge.linked_trains and edge.linked_trains[offset] then
		local link = edge.linked_trains[offset]

		if link.signal and link.signal.valid then
			link.signal.destroy()
		end
		for _index, rail in pairs(link.rails) do
			if rail and rail.valid then
				rail.destroy()
			end
		end

		edge.linked_trains[offset] = nil
		game.print("Removal complete")
	end
end

return {
	create_source = create_train_source_box,
	remove_source = remove_train_source_box,
	create_destination = create_train_destination_box,
	remove_destination = remove_train_destination_box,
}
