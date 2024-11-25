local clusterio_api = require("modules/clusterio/api")
local edge_util = require("modules/universal_edges/edge/util")
local vectorutil = require("modules/universal_edges/vectorutil")
local universal_serializer = require("modules/universal_edges/universal_serializer/universal_serializer")

--[[
	Send entities across the edege
]]
local function poll_links(id, edge, ticks_left)
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
	local origin = edge_util.edge_pos_to_world({0, 0}, edge)
	local cross = edge_util.edge_pos_to_world({edge.length, -3}, edge)
	local bounds = {vectorutil.vec2_min(origin, cross), vectorutil.vec2_max(origin, cross)}
	local entities = surface.find_entities_filtered{type = {"character"}, area = bounds}
	local entity_transfers = {}
	for _, entity in ipairs(entities) do
		local edge_pos = edge_util.world_to_edge_pos({entity.position.x, entity.position.y}, edge)
		-- make sure the center of the entity has crossed so that the other side doesn't teleport it back
		if edge_pos[2] > -0.5 then
			goto continue
		end
		if entity.type == "character" then
			if entity.player then
				local waiting = storage.universal_edges.players_waiting_to_leave[entity.player.name]
				if waiting == nil or waiting.edge_id ~= edge.id then
					edge_pos = edge_util.world_to_edge_pos({entity.position.x, entity.position.y}, edge)
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
		end
		::continue::
	end
	if #entity_transfers > 0 then
		clusterio_api.send_json("universal_edges:transfer", {
			edge_id = id,
			entity_transfers = entity_transfers,
		})
	end
end

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
	end
	return entity_response_transfers
end

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
