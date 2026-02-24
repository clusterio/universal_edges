local clusterio_api = require("modules/clusterio/api")
local edge_util = require("modules/universal_edges/edge/util")
local vectorutil = require("modules/universal_edges/vectorutil")
local universal_serializer = require("modules/universal_edges/universal_serializer/universal_serializer")

local EDGE_CROSS_THRESHOLD = -0.5
local EDGE_SCAN_PADDING = 16

---@param entity LuaEntity
---@return string
local function get_entity_key(entity)
	if entity.type == "character" and entity.player then
		return "player:" .. entity.player.name
	end
	if entity.unit_number then
		return "unit:" .. entity.unit_number
	end
	return "entity:" .. entity.name
end

---@param prev_edge_pos Vector?
---@param current_edge_pos Vector
---@return nil | table
local function edge_cross_position(prev_edge_pos, current_edge_pos)
	if current_edge_pos[2] > EDGE_CROSS_THRESHOLD then
		return nil
	end
	if not prev_edge_pos or prev_edge_pos[2] > EDGE_CROSS_THRESHOLD then
		if prev_edge_pos and current_edge_pos[2] ~= prev_edge_pos[2] then
			local t = (EDGE_CROSS_THRESHOLD - prev_edge_pos[2]) / (current_edge_pos[2] - prev_edge_pos[2])
			if t < 0 then t = 0 end
			if t > 1 then t = 1 end
			return {
				prev_edge_pos[1] + (current_edge_pos[1] - prev_edge_pos[1]) * t,
				EDGE_CROSS_THRESHOLD,
			}
		end
		return { current_edge_pos[1], EDGE_CROSS_THRESHOLD }
	end
	return nil
end

-- Send entities across the edege
---@param edge_id any
---@param edge UniversalEdge
---@param ticks_left number
local function poll_links(edge_id, edge, ticks_left)
	if ticks_left ~= 0 then
		return
	end
	if not edge.active then
		return
	end
	if edge.source.instanceId == edge.target.instanceId then 
		return -- Doesn't appear to be possible to correctly handle this
	end

	-- Clear records from players waiting to leave that left the edge again
	for player_name, leave in pairs(storage.universal_edges.players_waiting_to_leave) do
		if leave.edge_id == edge.id then
			local clear = false
			if not leave.entity.valid then
				clear = true
			else
				local edge_pos = edge_util.world_to_edge_pos({leave.entity.position.x, leave.entity.position.y}, edge)
				if edge_pos[2] > 1 then
					clear = true
				end
			end
			if clear then
				storage.universal_edges.players_waiting_to_leave[player_name] = nil
			end
		end
	end

	local surface = game.surfaces[edge_util.edge_get_local_target(edge).surface]
	local origin = edge_util.edge_pos_to_world({0, EDGE_SCAN_PADDING}, edge)
	local cross = edge_util.edge_pos_to_world({edge.length, -EDGE_SCAN_PADDING}, edge)
	local bounds = {vectorutil.vec2_min(origin, cross), vectorutil.vec2_max(origin, cross)}
	local entities = surface.find_entities_filtered{type = {"character", "spider-vehicle", "car", "tank"}, area = bounds}
	local entity_transfers = {}
	if not storage.universal_edges.entity_last_positions then
		storage.universal_edges.entity_last_positions = {}
	end
	local last_positions = storage.universal_edges.entity_last_positions[edge.id] or {}
	local next_positions = {}
	for _, entity in ipairs(entities) do
		local key = get_entity_key(entity)
		local edge_pos = edge_util.world_to_edge_pos({entity.position.x, entity.position.y}, edge)
		local prev_edge_pos = nil
		if key ~= nil then
			prev_edge_pos = last_positions[key]
			next_positions[key] = edge_pos
		end
		local cross_edge_pos = edge_cross_position(prev_edge_pos, edge_pos)
		-- make sure the center of the entity has crossed so that the other side doesn't teleport it back
		if cross_edge_pos == nil then
			goto continue
		end
		if entity.type == "character" then
			if entity.player then
				local waiting = storage.universal_edges.players_waiting_to_leave[entity.player.name]
				if waiting == nil or waiting.edge_id ~= edge.id then
					storage.universal_edges.players_waiting_to_leave[entity.player.name] = {
						edge_id = edge.id,
						entity = entity,
						edge_pos = edge_pos,
					}
					clusterio_api.send_json("universal_edges:teleport_player_to_server", {
						player_name = entity.player.name,
						edge_id = edge.id,
						offset = edge_pos[1],
					})
				end

				--local serialized = LuaEntity_serialize(entity)
				--serialized.position = edge_util.world_to_edge_pos(serialized.position, edge)
				--entity_transfers[#entity_transfers + 1] = serialized
			end
		elseif entity.type == "spider-vehicle" or entity.type == "car" then
			local driver_name = nil
			local passenger_name = nil
			local driver = entity.get_driver()
			if driver and driver.player then
				driver_name = driver.player.name
			end
			local passenger = entity.get_passenger()
			if passenger and passenger.player then
				passenger_name = passenger.player.name
			end
			local serialized = universal_serializer.LuaEntity.serialize(entity)
			if serialized.type == "spider-vehicle" and serialized.spidertron
				and serialized.spidertron.autopilot_destinations then
				for index, destination in pairs(serialized.spidertron.autopilot_destinations) do
					local edge_pos = edge_util.world_to_edge_pos(destination, edge)
					if edge_pos ~= nil then
						serialized.spidertron.autopilot_destinations[index] = edge_pos
					end
				end
			end
			if driver_name ~= nil then
				clusterio_api.send_json("universal_edges:teleport_player_to_server", {
					player_name = driver_name,
					edge_id = edge.id,
					offset = edge_util.edge_pos_to_offset(edge_util.world_to_edge_pos(serialized.position, edge), edge),
				})
			end
			if passenger_name ~= nil then
				clusterio_api.send_json("universal_edges:teleport_player_to_server", {
					player_name = passenger_name,
					edge_id = edge.id,
					offset = edge_util.edge_pos_to_offset(edge_util.world_to_edge_pos(serialized.position, edge), edge),
				})
			end
			entity_transfers[#entity_transfers + 1] = {
				type = "vehicle",
				serialized_entity = serialized,
				edge_pos = edge_util.world_to_edge_pos(serialized.position, edge),
				driver_name = driver_name,
				passenger_name = passenger_name,
			}
			entity.destroy{raise_destroy = true}
		end
		::continue::
	end
	if #entity_transfers > 0 then
		clusterio_api.send_json("universal_edges:transfer", {
			edge_id = edge_id,
			entity_transfers = entity_transfers,
		})
	end
	storage.universal_edges.entity_last_positions[edge.id] = next_positions
end

---@param event EventData.on_player_left_game
local function on_player_left_game(event)
	local player = game.get_player(event.player_index)
	if player == nil then
		return
	end
	if not storage.universal_edges.players_waiting_to_leave then
		return
	end
	if not storage.universal_edges.players_waiting_to_leave[player.name] then
		return
	end
	local leave = storage.universal_edges.players_waiting_to_leave[player.name]
	storage.universal_edges.players_waiting_to_leave[player.name] = nil
	clusterio_api.send_json("universal_edges:transfer", {
		edge_id = leave.edge_id,
		entity_transfers = {
			{
				type = "player",
				player_name = player.name,
				edge_pos = leave.edge_pos,
			},
		},
	})
end

---@param edge UniversalEdge
---@param entity_transfers unknown
---@return table
local function receive_transfers(edge, entity_transfers)
	if entity_transfers == nil then
		return {}
	end

	local entity_response_transfers = {}
	for _, entity_transfer in ipairs(entity_transfers) do
		if entity_transfer.type == "player" then
			storage.universal_edges.players_waiting_to_join[entity_transfer.player_name] = {
				edge_id = edge.id,
				edge_pos = entity_transfer.edge_pos
			}
		end
		if entity_transfer.type == "vehicle" then
			local local_target = edge_util.edge_get_local_target(edge)
			local flipped_pos = edge_util.flip_edge_pos(entity_transfer.edge_pos, edge)
			entity_transfer.serialized_entity.position = edge_util.edge_pos_to_world(flipped_pos, edge)
			entity_transfer.serialized_entity.surface = local_target.surface
			if entity_transfer.serialized_entity.type == "spider-vehicle"
				and entity_transfer.serialized_entity.spidertron
				and entity_transfer.serialized_entity.spidertron.autopilot_destinations then
				for index, destination in pairs(entity_transfer.serialized_entity.spidertron.autopilot_destinations) do
					local world = edge_util.edge_pos_to_world(
						edge_util.flip_edge_pos(destination, edge),
						edge
					)
					if world ~= nil then
						entity_transfer.serialized_entity.spidertron.autopilot_destinations[index] =
							edge_util.array_to_pos(world)
					end
				end
			end
			local entity = universal_serializer.LuaEntity.deserialize(entity_transfer.serialized_entity)
			if entity_transfer.driver_name and entity and entity.valid then
				storage.universal_edges.vehicle_drivers[entity_transfer.driver_name] = entity
			end
			if entity_transfer.passenger_name and entity and entity.valid then
				storage.universal_edges.vehicle_passengers[entity_transfer.passenger_name] = entity
			end
		end
	end
	return entity_response_transfers
end

---@param event EventData.on_player_joined_game
local function on_player_joined_game(event)
	local player = game.get_player(event.player_index)
	if player == nil then
		return
	end
	if not storage.universal_edges.players_waiting_to_join[player.name] then
		return
	end
	local join = storage.universal_edges.players_waiting_to_join[player.name]
	storage.universal_edges.players_waiting_to_join[player.name] = nil
	local edge = storage.universal_edges.edges[join.edge_id]
	if not edge then
		log("Got player joined for unknown edge " .. serpent.line(join))
		return
	end
	player.teleport(edge_util.edge_pos_to_world(edge_util.flip_edge_pos(join.edge_pos, edge), edge))
end

return {
	poll_links = poll_links,
	receive_transfers = receive_transfers,
	on_player_joined_game = on_player_joined_game,
	on_player_left_game = on_player_left_game,
}
