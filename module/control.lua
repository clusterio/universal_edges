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
			carriage_drivers = {},
			GLOBAL_VERSION = GLOBAL_VERSION,
		}
	end
	if not storage.universal_edges.carriage_drivers then
		storage.universal_edges.carriage_drivers = {}
	end
	if not storage.universal_edges.players_waiting_to_leave then
		storage.universal_edges.players_waiting_to_leave = {}
	end
	if not storage.universal_edges.players_waiting_to_join then
		storage.universal_edges.players_waiting_to_join = {}
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

-- Synchronize edge configuration and status
function universal_edges.edge_update(edge_id, edge_json)
	log("Updating edge " .. edge_id)
	local active_status_has_changed = false
	if edge_id == nil or edge_json == nil then return end
	local edge = game.json_to_table(edge_json)
	if edge == nil then return end
	if edge.isDeleted then
		game.print("Deleting edge " .. edge_id)
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
		old_edge.updatedAtMs = edge.updatedAtMs
		old_edge.source = edge.source
		old_edge.target = edge.target
		old_edge.length = edge.length
		if old_edge.active ~= edge.active then
			active_status_has_changed = true
		end
		old_edge.active = edge.active
		edge = old_edge
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
	end

	debug_draw()
	cleanup()
end

-- Synchronize connector placement with partner
function universal_edges.edge_link_update(json)
	local update = game.json_to_table(json)
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
	local data = game.json_to_table(json)
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

	[defines.events.on_built_entity] = function(event) on_built(event.created_entity) end,
	[defines.events.on_robot_built_entity] = function(event) on_built(event.created_entity) end,
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
		-- Check if we have a pending request to enter a vehicle
		if storage.universal_edges.carriage_drivers[player.name] ~= nil then
			local entity = storage.universal_edges.carriage_drivers[player.name]
			if entity.valid then
				entity.set_driver(player)
			end
			storage.universal_edges.carriage_drivers[player.name] = nil
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
