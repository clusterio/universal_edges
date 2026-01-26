local clusterio_api = require("modules/clusterio/api")
local vectorutil = require("vectorutil")
local universal_serializer = require("modules/universal_edges/universal_serializer/universal_serializer")

local edge_util = require("modules/universal_edges/edge/util")
local belt_box = require("modules/universal_edges/edge/belt_box")
local belt_link = require("modules/universal_edges/edge/belt_link")
local entity_link = require("modules/universal_edges/edge/entity_link")
local fluid_box = require("modules/universal_edges/edge/fluid_box")
local fluid_link = require("modules/universal_edges/edge/fluid_link")
local power_box = require("modules/universal_edges/edge/power_box")
local power_link = require("modules/universal_edges/edge/power_link")
local train_box = require("modules/universal_edges/edge/train/train_box")
local train_link = require("modules/universal_edges/edge/train/train_link")
local pathfinder_update = require("modules/universal_edges/edge/train/pathfinding/update")

local pathfinder_events = require("modules/universal_edges/edge/train/pathfinding/events")
local on_built = require("modules/universal_edges/events/on_built")
local on_removed = require("modules/universal_edges/events/on_removed")

local belt_check = require("modules/universal_edges/edge/belt_check")
local fluid_check = require("modules/universal_edges/edge/fluid_check")
local power_check = require("modules/universal_edges/edge/power_check")
local remove_belt_link = require("modules/universal_edges/edge/remove_belt_link")
local remove_fluid_link = require("modules/universal_edges/edge/remove_fluid_link")
local remove_power_link = require("modules/universal_edges/edge/remove_power_link")
local remove_train_link = require("modules/universal_edges/edge/train/remove_train_link")
local create_belt_link = require("modules/universal_edges/edge/create_belt_link")
local create_fluid_link = require("modules/universal_edges/edge/create_fluid_link")
local create_power_link = require("modules/universal_edges/edge/create_power_link")
local create_train_link = require("modules/universal_edges/edge/train/create_train_link")

local playable_area_cache = {} -- Cache for playable area centers per surface
local PROXIMITY_BUFFER_DISTANCE = 64 -- Additional buffer distance beyond edge starts, this is for diagonal axis

--- Top level module table, contains event handlers and public methods
local universal_edges = {
	events = {},
	on_nth_tick = {},
}

local function setupGlobalData()
	local GLOBAL_VERSION = 3
	if storage.universal_edges == nil
		or storage.universal_edges.GLOBAL_VERSION == nil
		or storage.universal_edges.GLOBAL_VERSION < GLOBAL_VERSION
	then
		-- Cleanup old global before resetting
		if storage.universal_edges and storage.universal_edges.debug_shapes then
			local debug_shapes = storage.universal_edges.debug_shapes
			for index, id in ipairs(debug_shapes) do
				if id.valid then id.destroy() end
				debug_shapes[index] = nil
			end
		end

		storage.universal_edges = {
			edges = {},
			debug_shapes = {},
			config = {},
			vehicle_drivers = {},
			entity_last_positions = {},
			GLOBAL_VERSION = GLOBAL_VERSION,
		}
	end
	if not storage.universal_edges.vehicle_drivers then
		storage.universal_edges.vehicle_drivers = {}
	end
	if not storage.universal_edges.vehicle_passengers then
		storage.universal_edges.vehicle_passengers = {}
	end
	if not storage.universal_edges.players_waiting_to_leave then
		storage.universal_edges.players_waiting_to_leave = {}
	end
	if not storage.universal_edges.players_waiting_to_join then
		storage.universal_edges.players_waiting_to_join = {}
	end
	if not storage.universal_edges.entity_last_positions then
		storage.universal_edges.entity_last_positions = {}
	end
	if not storage.universal_edges.proximity_check then
		storage.universal_edges.proximity_check = true
	end
	storage.universal_edges = storage.universal_edges
end


local function debug_draw()
	local debug_shapes = storage.universal_edges.debug_shapes
	for index, id in ipairs(debug_shapes) do
		if id.valid then id.destroy() end
		debug_shapes[index] = nil
	end

	for id, edge in pairs(storage.universal_edges.edges) do
		local edge_target
		if storage.universal_edges.config.instance_id == edge.source.instanceId then
			edge_target = edge.source
		elseif storage.universal_edges.config.instance_id == edge.target.instanceId then
			edge_target = edge.target
		else
			log("Edge with id " .. id .. " has invalid source/target")
			goto continue
		end
		local color = { 0, 1, 0 }
		if not edge.active then color = { 1, 0, 0 } end
		debug_shapes[#debug_shapes + 1] = rendering.draw_circle {
			color = color,
			radius = 0.25,
			width = 4,
			filled = false,
			target = edge_target.origin,
			surface = edge_target.surface,
		}

		debug_shapes[#debug_shapes + 1] = rendering.draw_text {
			color = { r = 1, g = 1, b = 1 },
			text = id .. " " .. (edge.active and "active" or "inactive"),
			target = vectorutil.vec2_add(edge_target.origin, { 0.4, -0.8 }),
			surface = edge_target.surface,
		}

		local dir = vectorutil.dir_to_vec(edge_target.direction)
		debug_shapes[#debug_shapes + 1] = rendering.draw_line {
			color = color,
			width = 4,
			from = vectorutil.vec2_add(edge_target.origin, vectorutil.vec2_smul(dir, 0.25)),
			to = vectorutil.vec2_add(edge_target.origin, vectorutil.vec2_smul(dir, edge.length - 0.5)),
			surface = edge_target.surface,
		}

		-- Draw gray line on left hand side of the beam (represents the remote side)
		local offset = { 0, 0 }
		if edge_target.direction == defines.direction.north then
			offset = { 0, -0.2 }
		elseif edge_target.direction == defines.direction.south then
			offset = { 0, 0.2 }
		elseif edge_target.direction == defines.direction.east then
			offset = { 0.2, 0 }
		elseif edge_target.direction == defines.direction.west then
			offset = { -0.2, 0 }
		end
		debug_shapes[#debug_shapes + 1] = rendering.draw_line {
			color = { 0.5, 0.5, 0.5 },
			width = 4,
			gap_length = 0.5,
			dash_length = 0.5,
			from = vectorutil.vec2_add(
				vectorutil.vec2_add(edge_target.origin, offset),
				vectorutil.vec2_smul(dir, 0.25)
			),
			to = vectorutil.vec2_add(
				vectorutil.vec2_add(edge_target.origin, offset),
				vectorutil.vec2_smul(dir, edge.length - 0.5)
			),
			surface = edge_target.surface,
		}
		::continue::
	end
end

function universal_edges.set_config(config)
	if storage.universal_edges.config == nil then storage.universal_edges.config = {} end
	storage.universal_edges.config.instance_id = config.instance_id
end

local function cleanup()
	-- Filter out edges that do not have source or target on this instance
	for id, edge in pairs(storage.universal_edges.edges) do
		if tostring(storage.universal_edges.config.instance_id) ~= tostring(edge.source.instanceId)
			and tostring(storage.universal_edges.config.instance_id) ~= tostring(edge.target.instanceId)
		then
			storage.universal_edges.edges[id] = nil
		end
	end
end


--[[
	Calculate the center point of the playable area based on all edge endpoints on current surface
	Returns both the center point and the maximum distance from center to edge starts
]]
local function calculate_playable_area_center(surface_name)
	-- Check if we have a cached value
	if playable_area_cache[surface_name] then
		return playable_area_cache[surface_name].center, playable_area_cache[surface_name].max_distance_to_edge
	end

	if not storage.universal_edges.edges then
		return nil, 0
	end

	local edge_endpoints = {}
	local edge_starts = {}
	local current_instance_id = storage.universal_edges.config.instance_id

	-- Collect all edge endpoints and starts on the current surface for this instance
	for _, edge in pairs(storage.universal_edges.edges) do
		if edge.active then
			local local_target = edge_util.edge_get_local_target(edge)
			if local_target and local_target.surface == surface_name then
				-- Add the origin point (start of edge)
				local start_point = {local_target.origin[1], local_target.origin[2]}
				edge_endpoints[#edge_endpoints + 1] = start_point
				edge_starts[#edge_starts + 1] = start_point

				-- Add the end point of the edge
				local end_pos = edge_util.edge_pos_to_world({edge.length, 0}, edge)
				edge_endpoints[#edge_endpoints + 1] = {end_pos[1], end_pos[2]}
			end
		end
	end

	-- If no edge endpoints found, cache nil and return nil
	if #edge_endpoints == 0 then
		playable_area_cache[surface_name] = { center = nil, max_distance_to_edge = 0 }
		return nil, 0
	end

	-- Calculate center point as the average of all edge endpoints
	local sum_x, sum_y = 0, 0
	for _, point in ipairs(edge_endpoints) do
		sum_x = sum_x + point[1]
		sum_y = sum_y + point[2]
	end

	local center = {
		x = sum_x / #edge_endpoints,
		y = sum_y / #edge_endpoints
	}

	-- Calculate the maximum distance from center to any edge start
	local max_distance_to_edge = 0
	for _, start_point in ipairs(edge_starts) do
		local dx = start_point[1] - center.x
		local dy = start_point[2] - center.y
		local distance = math.sqrt(dx * dx + dy * dy)
		if distance > max_distance_to_edge then
			max_distance_to_edge = distance
		end
	end

	-- Cache the result with both center and max distance to edge starts
	playable_area_cache[surface_name] = { center = center, max_distance_to_edge = max_distance_to_edge }
	return center, max_distance_to_edge
end

--[[
	Invalidate the playable area cache for a specific surface
]]
local function invalidate_playable_area_cache(surface_name)
	if surface_name then
		playable_area_cache[surface_name] = nil
	else
		-- Clear all cached values
		for key in pairs(playable_area_cache) do
			playable_area_cache[key] = nil
		end
	end
end

--[[
	Invalidate the playable areacache when edge status changes
]]
local function refresh_playable_area(edge)
	-- Invalidate cache for both source and target surfaces
	local source_target = edge_util.edge_get_local_target(edge)
	if source_target then
		invalidate_playable_area_cache(source_target.surface)
	end
end

--[[
	Check if a player is within proximity of the playable area center
]]
local function is_player_near_playable_area(player_pos, surface_name)
	local center, max_distance_to_edge = calculate_playable_area_center(surface_name)
	if not center then
		return true -- If no center can be determined, assume player is active
	end

	-- Calculate proximity distance: distance to furthest edge start + buffer
	local proximity_distance = max_distance_to_edge + PROXIMITY_BUFFER_DISTANCE

	local dx = player_pos.x - center.x
	local dy = player_pos.y - center.y
	local distance_squared = dx * dx + dy * dy

	return distance_squared <= (proximity_distance * proximity_distance)
end

--[[
	Check if players are out of bounds and teleport them back to the center
]]
local function check_player_proximity(surface)
	-- ingame override /c storage.universal_edges.proximity_check = false
	-- proximity checks are also possible to bypass with editor mode
	if not storage.universal_edges.proximity_check then
		return
	end

	if not storage.universal_edges.config.instance_id then
		return
	end

	local center, max_distance_to_edge = calculate_playable_area_center(surface.name)
	if not center then
		return -- No edges on this surface, skip proximity check
	end

	-- Calculate proximity distance for logging purposes
	local proximity_distance = max_distance_to_edge + PROXIMITY_BUFFER_DISTANCE

	-- Check all players on this surface
	for _, player in pairs(game.connected_players) do
		if player.surface == surface and player.character and player.character.valid then
			if not is_player_near_playable_area(player.physical_position, surface.name) then
				-- Player is out of bounds, teleport them to the center
				local teleport_pos = {center.x, center.y}

				-- Find a safe position near the center
				local safe_pos = surface.find_non_colliding_position("character", teleport_pos, 32, 1)
				if safe_pos then
					teleport_pos = safe_pos
				end

				-- Force player to exit any vehicle they may be in
				local vehicle = player.character.vehicle
				if vehicle ~= nil then
					vehicle.teleport(teleport_pos)
				else
					player.character.teleport(teleport_pos)
				end

				-- Calculate actual distance for the message
				local dx = player.physical_position.x - center.x
				local dy = player.physical_position.y - center.y
				local actual_distance = math.sqrt(dx * dx + dy * dy)

				player.print("You were too far from the playable area and have been teleported back.")
			end
		end
	end
end

-- Synchronize edge configuration and status
function universal_edges.edge_update(edge_id, edge_json)
	log("Updating edge " .. edge_id)
	local active_status_has_changed = false
	local position_or_rotation_changed = false
	if edge_id == nil or edge_json == nil then return end
	local edge = helpers.json_to_table(edge_json)
	if edge == nil then return end
	if edge.isDeleted then
		game.print("Deleting edge " .. edge_id)
		-- Invalidate playable area cache when edge is deleted
		if storage.universal_edges.edges[edge_id] then
			refresh_playable_area(storage.universal_edges.edges[edge_id])
		end
		-- Perform cleanup, remove edge
		storage.universal_edges.edges[edge_id] = nil
		debug_draw()
		return
	end
	if storage.universal_edges.edges[edge_id] == nil then
		game.print("Adding new edge " .. edge_id)
		storage.universal_edges.edges[edge_id] = edge
		active_status_has_changed = true
	else
		-- Do a partial update
		local old_edge = storage.universal_edges.edges[edge_id]

		-- Check if position or rotation has changed by comparing coordinates and direction
		local old_source = old_edge.source
		local new_source = edge.source
		local old_target = old_edge.target
		local new_target = edge.target

		-- Compare source coordinates and direction
		if old_source.instanceId == storage.universal_edges.config.instance_id then
			if old_source.origin[1] ~= new_source.origin[1] or
				old_source.origin[2] ~= new_source.origin[2] or
				old_source.direction ~= new_source.direction or
				old_source.surface ~= new_source.surface then
				position_or_rotation_changed = true
				log("Edge " .. edge_id .. " source position or rotation changed, will rebuild links")
			end
		end

		-- Compare target coordinates and direction
		if old_target.instanceId == storage.universal_edges.config.instance_id then
			if old_target.origin[1] ~= new_target.origin[1] or
				old_target.origin[2] ~= new_target.origin[2] or
				old_target.direction ~= new_target.direction or
				old_target.surface ~= new_target.surface then
				position_or_rotation_changed = true
				log("Edge " .. edge_id .. " target position or rotation changed, will rebuild links")
			end
		end

		-- If position or rotation changed, remove all links and recreate them
		if position_or_rotation_changed then
			local surface = game.surfaces[edge_util.edge_get_local_target(old_edge).surface]
			if surface then
				-- Remove all existing belt links
				if old_edge.linked_belts then
					for offset, _ in pairs(old_edge.linked_belts) do
						remove_belt_link(edge_id, old_edge, offset, { surface = surface })
					end
				end

				-- Remove all existing fluid links
				if old_edge.linked_fluids then
					for offset, _ in pairs(old_edge.linked_fluids) do
						remove_fluid_link(edge_id, old_edge, offset, { surface = surface })
					end
				end

				-- Remove all existing power links
				if old_edge.linked_powers then
					for offset, _ in pairs(old_edge.linked_powers) do
						remove_power_link(edge_id, old_edge, offset, { surface = surface })
					end
				end

				-- Remove all existing train links
				if old_edge.linked_trains then
					for offset, _ in pairs(old_edge.linked_trains) do
						remove_train_link(edge_id, old_edge, offset, { surface = surface })
					end
				end
			end
		end

		old_edge.updatedAtMs = edge.updatedAtMs
		old_edge.source = edge.source
		old_edge.target = edge.target
		old_edge.length = edge.length
		if old_edge.active ~= edge.active then
			active_status_has_changed = true
		end
		old_edge.active = edge.active
		edge = old_edge

		-- After updating the edge properties, check for entities that should be connected at the new position
		if position_or_rotation_changed and edge.active then
			local surface = game.surfaces[edge_util.edge_get_local_target(edge).surface]
			if surface then
				-- Calculate area around the edge based on its position and direction
				local local_target = edge_util.edge_get_local_target(edge)
				local origin = local_target.origin
				local direction = local_target.direction
				local dir_vec = vectorutil.dir_to_vec(direction)
				local length = edge.length or 2

				-- Create a search area with some padding around the edge
				local padding = 2
				local start_pos = { x = origin[1] - padding, y = origin[2] - padding }
				local end_pos = {
					x = origin[1] + dir_vec[1] * length + padding,
					y = origin[2] + dir_vec[2] * length + padding
				}

				-- Make sure start_pos coordinates are smaller than end_pos
				local area = {
					{ math.min(start_pos.x, end_pos.x), math.min(start_pos.y, end_pos.y) },
					{ math.max(start_pos.x, end_pos.x), math.max(start_pos.y, end_pos.y) }
				}

				-- Scan for transport belts in the area
				local belts = surface.find_entities_filtered { area = area, type = "transport-belt" }
				for _, belt in pairs(belts) do
					local pos = { belt.position.x, belt.position.y }
					local offset = belt_check(pos, belt.direction, edge)
					if offset ~= nil then
						create_belt_link(edge_id, edge, offset, belt)
					end
				end

				-- Scan for pipes in the area
				local pipes = surface.find_entities_filtered { area = area, type = { "pipe", "pipe-to-ground" } }
				for _, pipe in pairs(pipes) do
					local pos = { pipe.position.x, pipe.position.y }
					local offset = fluid_check(pos, pipe.direction, edge, pipe)
					if offset ~= nil then
						create_fluid_link(edge_id, edge, offset, pipe)
					end
				end

				-- Scan for pumps in the area
				local pumps = surface.find_entities_filtered { area = area, name = "pump" }
				for _, pump in pairs(pumps) do
					local pos = { pump.position.x, pump.position.y }
					local offset = fluid_check(pos, pump.direction, edge, pump)
					if offset ~= nil then
						create_fluid_link(edge_id, edge, offset, pump)
					end
				end

				-- Scan for power_entities in the area
				local power_entities = surface.find_entities_filtered { area = area, name = util.is_power_entity }
				for _, power_entity in pairs(power_entities) do
					local pos = { power_entity.position.x, power_entity.position.y }
					local offset = power_check(pos, edge, power_entity)
					if offset ~= nil then
						create_power_link(edge_id, edge, offset, power_entity)
					end
				end

				-- Scan for straight rails in the area
				local rails = surface.find_entities_filtered { area = area, name = "straight-rail" }
				for _, rail in pairs(rails) do
					local pos = { rail.position.x, rail.position.y }
					local offset = power_check(pos, edge, rail)
					if offset ~= nil then
						create_train_link(edge_id, edge, offset, rail)
					end
				end
			end
		end

		if position_or_rotation_changed then
			-- Signal the partner instance to update the edge links
			clusterio_api.send_json("universal_edges:edge_update", {
				id = edge_id,
				json = helpers.table_to_json(edge)
			})
			-- Invalidate playable area cache when edge position changes
			refresh_playable_area(edge)
		end
	end

	if active_status_has_changed then
		if not edge.active then
			if edge.linked_belts then
				for _offset, link in pairs(edge.linked_belts) do
					if link.is_input and link.chest and link.chest.valid then
						local inventory = link.chest.get_inventory(defines.inventory.chest)
						inventory.set_bar(1) -- Block new inputs
					end
				end
			end
			-- Disable train pathfinding over this edge
			if edge.linked_trains then
				for offset, link in pairs(edge.linked_trains) do
					if link.is_input then
						pathfinder_update.update_train_penalty_map(offset, edge, {})
					end
				end
			end
		else -- Edge was activated
			if edge.linked_belts then
				for _offset, link in pairs(edge.linked_belts) do
					if not link.is_input then
						link.start_index = 1
					end
				end
			end
			if edge.linked_trains then
				for _, link in pairs(edge.linked_trains) do
					if link.is_input == false then
						--[[
							Force rescan and retransmit, even if there were no changes on this instance
							This is required because the partner instance might have reverted to an older version of the map,
							or maybe this instance reverted to an older version.
						]]
						link.rescan_penalties = true
						link.penalty_map = nil
					end
				end
			end
		end

		-- Invalidate playable area cache when edge status changes
		refresh_playable_area(edge)
	end

	debug_draw()
	cleanup()
end

-- Synchronize connector placement with partner
function universal_edges.edge_link_update(json)
	local update = helpers.json_to_table(json)
	if update == nil then return end

	local data = update.data
	local edge = storage.universal_edges.edges[update.edge_id]
	if not edge then
		log("Got update for unknown edge " .. serpent.line(update))
		return
	end
	local surface = game.surfaces[edge_util.edge_get_local_target(edge).surface]
	if not surface then
		log("Invalid surface for edge id " .. update.edge_id)
	end

	if update.type == "create_belt_link" then
		belt_box.create(data.offset, edge, data.is_input, data.belt_type, surface)
	elseif update.type == "remove_belt_link" then
		belt_box.remove(data.offset, edge, surface)
	elseif update.type == "create_fluid_link" then
		fluid_box.create(data.offset, edge, surface)
	elseif update.type == "remove_fluid_link" then
		fluid_box.remove(data.offset, edge, surface)
	elseif update.type == "create_power_link" then
		power_box.create(data.offset, edge, surface)
	elseif update.type == "remove_power_link" then
		power_box.remove(data.offset, edge, surface)
	elseif update.type == "create_train_link" then
		train_box.create_destination(data.offset, edge, surface, update)
	elseif update.type == "remove_train_link" then
		train_box.remove_destination(data.offset, edge, surface)
	elseif update.type == "update_train_penalty_map" then
		pathfinder_update.update_train_penalty_map(data.offset, edge, data.penalty_map)
	else
		log("Unknown link update: " .. serpent.line(update.type))
	end
end

-- Receive fluid from partner over RCON
function universal_edges.transfer(json)
	local data = helpers.json_to_table(json)
	if data == nil then return end

	local edge = storage.universal_edges.edges[data.edge_id]
	if not edge then
		rcon.print("invalid edge")
		return
	end
	if not edge.active then
		return
	end

	local belt_response_transfers = belt_link.receive_transfers(edge, data.belt_transfers)
	local entity_response_transfers = entity_link.receive_transfers(edge, data.entity_transfers)
	local fluid_response_transfers = fluid_link.receive_transfers(edge, data.fluid_transfers)
	local power_response_transfers = power_link.receive_transfers(edge, data.power_transfers)
	local train_response_transfers = train_link.receive_transfers(edge, data.train_transfers)

	local transfer = {
		edge_id = data.edge_id,
	}
	if #belt_response_transfers > 0 then
		transfer.belt_transfers = belt_response_transfers
	end
	if #entity_response_transfers > 0 then
		transfer.entity_transfers = entity_response_transfers
	end
	if #fluid_response_transfers > 0 then
		transfer.fluid_transfers = fluid_response_transfers
	end
	if #power_response_transfers > 0 then
		transfer.power_transfers = power_response_transfers
	end
	if #train_response_transfers > 0 then
		transfer.train_transfers = train_response_transfers
	end
	if #belt_response_transfers + #entity_response_transfers + #fluid_response_transfers + #power_response_transfers + #train_response_transfers > 0 then
		clusterio_api.send_json("universal_edges:transfer", transfer)
	end
end

function universal_edges.teleport_player_to_server_response(player_name, address)
	if player_name == nil or address == nil then return end
	local player = game.players[player_name]
	if player == nil then
		log("Teleport failed: Player " .. player_name .. " not found")
		return
	end

	player.connect_to_server({
		address = address,
		name = "Follow train",
		description = "Connect to same server as the train went to",
		-- password should be handled in the future
	})
end

universal_edges.events = {
	[clusterio_api.events.on_server_startup] = function(_event)
		log("Universal edges startup")
		setupGlobalData()
		pathfinder_events.on_server_startup()
		if not storage.universal_edges.config.ticks_per_edge then
			storage.universal_edges.config.ticks_per_edge = 15
		end
		-- Refresh belt edge flow status in cases where the belt is not packed
		for _, edge in pairs(storage.universal_edges.edges) do
			-- Active status is remembered from last shutdown, if its wrong this gets overwritten later
			if edge.active and edge.linked_belts then
				for _offset, link in pairs(edge.linked_belts) do
					if not link.is_input then
						link.start_index = 1
					end
				end
			end
		end
	end,

	[defines.events.on_tick] = function(event)
		universal_serializer.events.on_tick(event)
		pathfinder_events.on_tick()

		-- Check player proximity every 600 ticks (10 seconds)
		if game.tick % 600 == 0 then
			for _, surface in pairs(game.surfaces) do
				check_player_proximity(surface)
			end
		end

		local ticks_left = -game.tick % storage.universal_edges.config.ticks_per_edge
		local id = storage.universal_edges.current_edge_id
		if id == nil then
			id = next(storage.universal_edges.edges)
			if id == nil then
				return -- no edges
			end
			storage.universal_edges.current_edge_id = id
		end
		local edge = storage.universal_edges.edges[id]

		-- edge may have been removed while iterating over it
		if edge == nil then
			storage.universal_edges.current_edge_id = nil
			return
		end

		-- Attempt to send items and fluids to partner
		if edge.active then
			belt_link.poll_links(id, edge, ticks_left)
			entity_link.poll_links(id, edge, ticks_left)
			fluid_link.poll_links(id, edge, ticks_left)
			power_link.poll_links(id, edge, ticks_left)
			train_link.poll_links(id, edge, ticks_left)
			pathfinder_update.poll_connectors(id, edge, ticks_left)
		end

		if ticks_left == 0 then
			storage.universal_edges.current_edge_id = next(storage.universal_edges.edges, id)
		end
	end,

	[defines.events.on_built_entity] = function(event) on_built(event.entity) end,
	[defines.events.on_robot_built_entity] = function(event) on_built(event.entity) end,
	[defines.events.script_raised_built] = function(event) on_built(event.entity) end,
	[defines.events.script_raised_revive] = function(event) on_built(event.entity) end,

	[defines.events.on_player_mined_entity] = function(event) on_removed(event.entity) end,
	[defines.events.on_robot_mined_entity] = function(event) on_removed(event.entity) end,
	[defines.events.on_entity_died] = function(event) on_removed(event.entity) end,
	[defines.events.script_raised_destroy] = function(event) on_removed(event.entity) end,

	[defines.events.on_player_joined_game] = function(event)
		if storage.universal_edges == nil then
			setupGlobalData()
		end
		entity_link.on_player_joined_game(event)
		local player = game.players[event.player_index]
		-- Check if we have a pending request to enter a vehicle after cross-instance teleport
		if storage.universal_edges.vehicle_drivers[player.name] ~= nil then
			local entity = storage.universal_edges.vehicle_drivers[player.name]
			if entity.valid then
				entity.set_driver(player)
			end
			storage.universal_edges.vehicle_drivers[player.name] = nil
		end
		if storage.universal_edges.vehicle_passengers[player.name] ~= nil then
			local entity = storage.universal_edges.vehicle_passengers[player.name]
			if entity.valid then
				entity.set_passenger(player)
			end
			storage.universal_edges.vehicle_passengers[player.name] = nil
		end
	end,
	[defines.events.on_player_left_game] = entity_link.on_player_left_game,

	[defines.events.on_entity_renamed] = function(event)
		local entity = event.entity
		if entity.name == "train-stop"
			and entity.backer_name
			and (
				storage.universal_edges.pathfinder.rescan_connector_paths_after == nil
				or storage.universal_edges.pathfinder.rescan_connector_paths_after < game.tick
			)
		then
			storage.universal_edges.pathfinder.rescan_connector_paths_after = game.tick + 180
		end
	end,
}

return universal_edges
