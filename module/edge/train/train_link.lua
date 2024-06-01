local clusterio_api = require("modules/clusterio/api")
local itertools = require("modules/universal_edges/itertools")
local util = require("modules/universal_edges/util")
local edge_util = require("modules/universal_edges/edge/util")
local universal_serializer = require("modules/universal_edges/universal_serializer/universal_serializer")

--[[
	Attempt sending trains to partner
]]
local function poll_links(id, edge, ticks_left)
	if not edge.linked_trains then
		return
	end

	if not edge.linked_trains_state then
		edge.linked_trains_state = {}
	end

	if not edge.pending_train_transfers then
		edge.pending_train_transfers = {}
	end

	local train_transfers = {}
	for offset, link in itertools.partial_pairs(
		edge.linked_trains, edge.linked_trains_state, ticks_left
	) do
		if link.is_input and link.signal.valid then
			local signal_state = link.signal.signal_state
			if -- Signal has turned red
				signal_state ~= link.previous_signal_state
				and signal_state == defines.signal_state.closed
			then
				game.print("Signal turned red, initializing teleport at " .. offset)

				local surface = game.surfaces[edge_util.edge_get_local_target(edge).surface]
				local edge_x = edge_util.offset_to_edge_x(offset, edge)

				-- Find area filtered requires left_top to actually be in the left top.
				-- This means we have to handle rotations properly
				local area = realign_area(
					edge_util.edge_pos_to_world({
						edge_x + 1,
						0,
					}, edge),
					edge_util.edge_pos_to_world({
						edge_x - 1,
						1 - link.teleport_area_size * 2
					}, edge)
				)

				local entities = surface.find_entities_filtered {
					area = area,
					type = {
						"cargo-wagon",
						"locomotive",
						"fluid-wagon",
						"artillery-wagon",
					},
				}

				game.print("Found " .. #entities .. " entities to use for train base")
				if #entities > 0 then
					local luaTrain = entities[1].train
					if luaTrain then
						game.print("Sending train #" .. luaTrain.id .. " at offset " .. offset)
						local train = universal_serializer.LuaTrainComplete.serialize(luaTrain)

						-- Translate carriage positions to be relative to edge
						for _, carriage in ipairs(train.carriages) do
							log("Carriage remote position " .. serpent.line(carriage.position))
							-- Translate to edge position
							local edge_position = edge_util.world_to_edge_pos(carriage.position, edge)
							log("Position relative to edge " .. serpent.line(edge_position))
							carriage.position = edge_position
						end

						train_transfers[#train_transfers + 1] = {
							offset = offset,
							train = train,
							train_id = luaTrain.id, -- Used to delete train after successfull spawning
						}
					end
				else
					game.print(serpent.block(area))
				end
			end
			link.previous_signal_state = signal_state
		end
	end

	if #train_transfers > 0 then
		clusterio_api.send_json("universal_edges:transfer", {
			edge_id = id,
			train_transfers = train_transfers,
		})
	end
end

--[[
	Spawn received train and return success status
]]
---@param offset number
---@param link table
---@param train table
---@returns boolean
local function push_train_link(edge, offset, link, train)
	log("Attempting to spawn train " .. serpent.block(train))

	for _, carriage in ipairs(train.carriages) do
		log("Carriage edge position " .. serpent.line(carriage.position))
		-- Translate from edge position to work position
		local world_pos = edge_util.edge_pos_to_world(carriage.position, edge)
		log("Carriage world position " .. serpent.line(world_pos))
		carriage.position = world_pos
	end

	local luaTrain = universal_serializer.LuaTrainComplete.deserialize(train)

	return luaTrain ~= nil
end

return {
	poll_links = poll_links,
	push_train_link = push_train_link,
}
