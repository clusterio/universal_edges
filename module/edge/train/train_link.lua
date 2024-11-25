local clusterio_api = require("modules/clusterio/api")
local itertools = require("modules/universal_edges/itertools")
local util = require("modules/universal_edges/util")
local edge_util = require("modules/universal_edges/edge/util")
local universal_serializer = require("modules/universal_edges/universal_serializer/universal_serializer")
local train_box = require("modules/universal_edges/edge/train/train_box")

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
		-- If link has no signal, remove and cleanup
		if not link.signal or not link.signal.valid then
			edge.linked_trains[offset] = nil
			if edge.is_input then
				train_box.remove_source(offset, edge)
			else
				train_box.remove_destination(offset, edge)
			end
			goto continue
		end

		local signal_state
		if link.is_input and link.signal.valid then
			signal_state = link.signal.signal_state
			-- Update debug visualization of flow status
			if link.debug_visu == nil then
				link.debug_visu = {}
			end

			-- Rmove old visualizations
			for index, visu in ipairs(link.debug_visu) do
				if visu.valid then visu.destroy() end
				link.debug_visu[index] = nil
			end

			local edge_x = edge_util.offset_to_edge_x(offset, edge)
			-- Visualize set_flow
			if link.set_flow == false then
				local pos = edge_util.edge_pos_to_world({ edge_x, 0 }, edge)
				link.debug_visu[#link.debug_visu + 1] = rendering.draw_text {
					text = "Destination blocked",
					surface = game.surfaces[edge_util.edge_get_local_target(edge).surface],
					target = pos,
					color = { r = 1, g = 1, b = 1 },
					scale = 1.5,
				}
			elseif link.set_flow == nil then
				local pos = edge_util.edge_pos_to_world({ edge_x, 0 }, edge)
				link.debug_visu[#link.debug_visu + 1] = rendering.draw_text {
					text = "offset: " .. offset .. "signal: " .. signal_state .. " flow: " .. tostring(link.set_flow),
					surface = game.surfaces[edge_util.edge_get_local_target(edge).surface],
					target = pos,
					color = { r = 1, g = 1, b = 1 },
					scale = 1.5,
				}
			end

			if ( -- Signal has turned red
					link.set_flow
					and signal_state ~= link.previous_signal_state
					and signal_state == defines.signal_state.closed
				) or ( -- Retry if flow just opened up
					link.set_flow
					and link.previous_flow_state == false
					and signal_state == defines.signal_state.closed
				) -- No need to check on active state change as poll_links is only called when active
			then
				local surface = game.surfaces[edge_util.edge_get_local_target(edge).surface]

				-- Find area filtered requires left_top to actually be in the left top.
				-- This means we have to handle rotations properly
				local area = util.realign_area(
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

				if #entities > 0 then
					local luaTrain = entities[1].train
					if luaTrain then
						-- Check that none of the wagons are rotated. Rotated wagons cause issues when spawning
						local rotated_wagons = false
						for _, carriage in ipairs(luaTrain.carriages) do
							if carriage.orientation % 0.25 ~= 0 then
								rotated_wagons = true
								break
							end
						end

						if rotated_wagons then
							game.print(
								"Train at "
								.. serpent.line(luaTrain.carriages[1].position)
								.. " is attempting to teleport with wagons on a curve, this is not supported yet."
							)
						else
							-- Serialize train
							local train = universal_serializer.LuaTrainComplete.serialize(luaTrain)

							-- Translate carriage positions to be relative to edge
							for _, carriage in ipairs(train.carriages) do
								-- Translate to edge position
								local edge_position = edge_util.world_to_edge_pos(carriage.position, edge)
								-- Compensate for edge direction
								edge_position[1] = edge.length - edge_position[1]
								carriage.position = edge_position
							end

							train_transfers[#train_transfers + 1] = {
								offset = offset,
								train = train,
								train_id = luaTrain.id, -- Used to delete train after successfull spawning
							}
						end
					end
				end
			end
		end
		if not link.is_input and link.signal.valid then
			-- Update connector flow status
			signal_state = link.signal.signal_state
			if link.previous_signal_state ~= signal_state then
				train_transfers[#train_transfers + 1] = {
					offset = offset,
					set_flow = signal_state == defines.signal_state.open,
				}
			end
		end
		link.previous_signal_state = signal_state
		link.previous_flow_state = link.set_flow
		::continue::
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
---@param _offset number
---@param link table
---@param train table
---@returns boolean
local function push_train_link(edge, _offset, link, train)
	-- Check if the spawn location is free using link signal
	if link.signal.signal_state ~= defines.signal_state.open then
		return false
	end

	-- Normalize edge position of carriages to fit outside of the edge (y is negative)
	local train_start_position = -4
	-- Find position of first wagon (lowest y position)
	local first_wagon = train.carriages[1].position[2]
	for _, carriage in ipairs(train.carriages) do
		local y = carriage.position[2]
		if y < first_wagon then
			first_wagon = y
		end
	end

	-- Sort carriages by y position
	table.sort(train.carriages, function(a, b)
		return a.position[2] < b.position[2]
	end)

	-- Update position
	for _, carriage in ipairs(train.carriages) do
		local y = carriage.position[2]
		-- Invert y because it was on the outside of the border and is now going to be on the inside of the border (on the partner side)
		-- This effectively inverts the train
		y = y * -1 + first_wagon + train_start_position
		carriage.position[2] = y
	end

	for _, carriage in ipairs(train.carriages) do
		-- Translate from edge position to world position
		log("Edge position " .. serpent.line(carriage.position))
		local world_pos = edge_util.edge_pos_to_world(carriage.position, edge)
		carriage.position = world_pos
		log("World position " .. serpent.line(carriage.position))
	end

	local luaTrain = universal_serializer.LuaTrainComplete.deserialize(train)

	return luaTrain ~= nil
end

local function receive_transfers(edge, train_transfers)
	if train_transfers == nil then
		return {}
	end
	local train_response_transfers = {}
	for _, train_transfer in ipairs(train_transfers) do
		-- log("TrainTransfer: " .. serpent.line(train_transfer))
		local link = (edge.linked_trains or {})[train_transfer.offset]
		if not link then
			log("FATAL: Received train for non-existant link at offset " .. train_transfer.offset)
			goto continue
		end

		if train_transfer.set_flow ~= nil then
			link.set_flow = train_transfer.set_flow
			link.previous_flow_state = not train_transfer.set_flow
		end

		if train_transfer.train then
			-- Attempt to spawn train in world
			local success = push_train_link(edge, train_transfer.offset, link, train_transfer.train)

			-- If successful, return train_id without a train
			if success then
				log("Success! Telling source to go away")
				-- Sending a transfer with a `train_id` and no `train` will delete train on destination
				train_response_transfers[#train_response_transfers + 1] = {
					offset = train_transfer.offset,
					-- Delete origin train (when provided without `train`)
					train_id = train_transfer.train_id,
					-- Prevent immediately sending another before this one has cleared the station
					set_flow = link.signal.signal_state == defines.signal_state.open,
				}
			else
				-- Station was blocked, disable flow
				train_response_transfers[#train_response_transfers + 1] = {
					offset = train_transfer.offset,
					set_flow = false,
				}
			end
		elseif train_transfer.train_id ~= nil then
			-- The train was successfully spawned in on partner - delete the local train
			local train = game.train_manager.get_train_by_id(train_transfer.train_id)
			if train then
				log("Transfer successful, deleting local train " .. train_transfer.train_id)
				for _, carriage in ipairs(train.carriages) do
					-- Remove driver from carriage and ask them to teleport
					if carriage.get_driver() then
						-- Teleport player to the other side of the edge
						local player = carriage.get_driver().player
						if player ~= nil then
							-- Check if both sides of the edge are on the same instanceId
							if edge.source.instanceId == edge.target.instanceId then
								local new_carriage = storage.universal_edges.carriage_drivers[player.name]
								if new_carriage ~= nil and new_carriage.valid then
									new_carriage.set_driver(player)
								else
									player.print("Carriage not found, did you miss your train?")
								end
								storage.universal_edges.carriage_drivers[player.name] = nil
							else
								-- Cross server train rides need talking to the controller to figure out where to go
								clusterio_api.send_json("universal_edges:teleport_player_to_server", {
									player_name = player.name,
									edge_id = edge.id,
									offset = train_transfer.offset, -- Might want to use player position instead
								})
							end
						end
					end
					carriage.destroy()
				end
			else
				log("FATAL: Train teleported successfully but origin train dissappeared")
			end
		end
		::continue::
	end
	return train_response_transfers
end

return {
	poll_links = poll_links,
	receive_transfers = receive_transfers,
}
