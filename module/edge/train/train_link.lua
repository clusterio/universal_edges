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
		local signal_state = link.signal.signal_state
		if link.is_input and link.signal.valid then
			-- Update debug visualization of flow status
			if link.debug_visu == nil then
				link.debug_visu = {}
			end

			-- Rmove old visualizations
			for index, visu in ipairs(link.debug_visu) do
				rendering.destroy(visu)
				link.debug_visu[index] = nil
			end

			-- Visualize set_flow
			if link.set_flow == false then
				local edge_x = edge_util.offset_to_edge_x(offset, edge)
				local pos = edge_util.edge_pos_to_world({ edge_x, 0 }, edge)
				link.debug_visu[#link.debug_visu + 1] = rendering.draw_text {
					text = "Destination blocked",
					surface = game.surfaces[edge_util.edge_get_local_target(edge).surface],
					target = pos,
					color = { r = 1, g = 1, b = 1 },
					scale = 1.5,
				}
			end

			if (-- Signal has turned red
					link.set_flow
					and signal_state ~= link.previous_signal_state
					and signal_state == defines.signal_state.closed
				) or ( -- Retry if flow just opened up
					link.set_flow
					and link.previous_flow_state == false
					and signal_state == defines.signal_state.closed
				) -- No need to check on active state change as poll_links is only called when active
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
		elseif not link.is_input and link.signal.valid then
			-- Update connector flow status
			if link.previous_signal_state ~= signal_state then
				train_transfers[#train_transfers + 1] = {
					offset = offset,
					set_flow = signal_state == defines.signal_state.open,
				}
			end
		end
		link.previous_signal_state = signal_state
		link.previous_flow_state = link.set_flow
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

	-- Check if the spawn location is free using link signal
	if link.signal.signal_state ~= defines.signal_state.open then
		return false
	end

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
