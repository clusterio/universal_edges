local clusterio_api = require("modules/clusterio/api")
local itertools = require("modules/universal_edges/itertools")
local edge_util = require("modules/universal_edges/edge/util")

--[[
	Ran for destination connectors. Figure out pathfinding penalty to reach all stations on the instance
	from this destination. Unreachable destinations are excluded from the result. We only care about
	the closest station of each name.
]]
local function update_connector_paths(edge, offset, link)
	local edge_target = edge_util.edge_get_local_target(edge)
	local train_stops = game.surfaces[1].find_entities_filtered {
		type = "train-stop"
	}
	local goals = {}
	for _, stop in pairs(train_stops) do
		-- It is possible to create trainstops and deconstructing the rail, this causes the pathfinder to throw
		if stop.connected_rail ~= nil then
			goals[#goals + 1] = {
				train_stop = stop
			}
		end
	end

	--[[
		Front vs back depends on direction.
		Going north you need to check front
		Going south you need to check back.
		Going east you need to check front
		Going west you need to check back
	]]
	local request = {
		goals = goals,
		type = "all-goals-penalties",
	}
	if
		edge_target.direction == defines.direction.north -- Trains exit from the north
		or edge_target.direction == defines.direction.west -- Trains exit from the west
	then
		request.from_back = {
			rail = link.rails[1],
			direction = defines.rail_direction.back,
		}
	end
	if
		edge_target.direction == defines.direction.south -- Trains exit from the south
		or edge_target.direction == defines.direction.east -- Trains exit from the east
	then
		request.from_front = {
			rail = link.rails[1],
			direction = defines.rail_direction.front,
		}
	end

	local result = game.request_train_path(request)

	--[[
		Map penalties to backer name

		Penalties:
		- Distance has a bit
		- Station has 2000
		- Signal has 0 impact
		- Circuit red signal has 1000
		- Red block with train has ~7100, varies with distance etc
	]]
	local penalty_map = {}
	for index, penalty in pairs(result.penalties) do
		--[[ Stacked stations show as not accessible even though they are, but penalty is correct ]]
		if result.accessible[index] or penalty > 0 then
			local backer_name = train_stops[index].backer_name
			--[[ Set it to whichever is smaller ]]
			local lowest_penalty = math.min(penalty_map[backer_name] or 10000000, penalty)

			--[[ Penalties of 10m and higher are considered unreachable ]]
			if lowest_penalty < 10000000 then
				---@diagnostic disable-next-line: need-check-nil
				penalty_map[backer_name] = lowest_penalty
			end
		end
	end
	log("Penalty map for offset " .. offset .. " " .. serpent.block(penalty_map))

	-- Check if new penalty map is significantly different from old penalty map
	-- If it is, update the penalty map on the source side of the connector
	local send_update = false
	local old_penalty_map = link.penalty_map
	if old_penalty_map ~= nil then
		local penalty_diff = 0
		for backer_name, penalty in pairs(penalty_map) do
			-- A new stop was added, we need to send the update
			if old_penalty_map[backer_name] == nil then
				send_update = true
			end
			local old_penalty = old_penalty_map[backer_name] or 0
			penalty_diff = penalty_diff + math.abs(penalty - old_penalty)
		end
		for backer_name, _ in pairs(old_penalty_map) do
			-- A stop was removed, we need to send the update
			if penalty_map[backer_name] == nil then
				send_update = true
			end
		end
		if penalty_diff > 50000 then
			send_update = true
		end
	else
		send_update = true
	end

	-- Set scan as completed
	link.penalty_map = penalty_map
	link.rescan_penalties = false

	if send_update then
		log("Significant change detected, sending penalty map")
		clusterio_api.send_json("universal_edges:edge_link_update", {
			type = "update_train_penalty_map",
			edge_id = edge.id,
			data = {
				offset = offset,
				penalty_map = link.penalty_map,
			},
		})
	end
end

--[[
	Check if any connectors have updated pathfinding penalties
]]
local function poll_connectors(id, edge, ticks_left)
	if not edge.poll_connectors_state then
		edge.poll_connectors_state = {}
	end

	if not edge.pending_train_transfers then
		edge.pending_train_transfers = {}
	end

	for offset, link in itertools.partial_pairs(
		edge.linked_trains, edge.poll_connectors_state, ticks_left
	) do
		-- Only check penalties for outputs
		if link.is_input == false and link.rescan_penalties then
			update_connector_paths(edge, offset, link)
		end
	end
end

--[[
	This function almost belongs more in train_box
	Basically, it creates stations and circuit locked signals to emulate the pathfinding graph on the source side of the connector
]]
local function update_train_penalty_map(offset, edge, penalty_map)
	if not edge.linked_trains then
		edge.linked_trains = {}
	end
	if edge.linked_trains[offset] == nil then
		log("FATAL: train edge does not exist at " .. offset)
		return
	end

	local link = edge.linked_trains[offset]

	log("Got penalty update for " .. offset .. " " .. serpent.block(penalty_map))

	-- Remove old penalty entities
	if link.penalty_rails ~= nil then
		for _index, rail in pairs(link.penalty_rails) do
			if rail and rail.valid then
				rail.destroy()
			end
		end
	end

	-- Plan layout of stations and seperator signals
	local station_count = 0
	for _, _ in pairs(penalty_map) do
		station_count = station_count + 1
	end
	local penalty_plan = {}
	local processed_stations = 0
	local penalty_bucket = 0
	local plan_length = 0 -- Number of server_dividers in the plan, ~1 per server manhattan distance to furthest stop
	while processed_stations < station_count do
		-- Add new padding to plan
		plan_length = plan_length + 1
		penalty_plan[#penalty_plan + 1] = {
			type = "server_divider",
			penalty = 100000,
		}
		-- Check if any stops belong in this bucket
		for name, penalty in pairs(penalty_map) do
			if penalty >= penalty_bucket and penalty < penalty_bucket + 100000 then
				penalty_plan[#penalty_plan + 1] = {
					name = name,
					penalty = penalty + 100000,
				}
				processed_stations = processed_stations + 1
			end
		end
		penalty_bucket = penalty_bucket + 100000
	end

	local edge_x = edge_util.offset_to_edge_x(offset, edge)
	local edge_target = edge_util.edge_get_local_target(edge)
	local surface = game.surfaces[edge_target.surface]
	local rails = {}
	for i = 2, plan_length + 2 do
		rails[#rails + 1] = surface.create_entity {
			name = "straight-rail",
			position = edge_util.edge_pos_to_world({ edge_x, -1 - i * 2 }, edge),
			direction = edge_target.direction,
		}
	end
	local processed_dividers = 0
	for _, item in ipairs(penalty_plan) do
		if item.type == "server_divider" then
			-- Add huge pathfinding penalty
			local signal = surface.create_entity {
				name = "rail-signal",
				position = edge_util.edge_pos_to_world({ edge_x + 1.5, -4.5 - processed_dividers * 4 }, edge),
				direction = (edge_target.direction + 4) % 8,
			}
			local combinator = surface.create_entity {
				name = "constant-combinator",
				position = edge_util.edge_pos_to_world({ edge_x + 1.5, -5.5 - processed_dividers * 4 }, edge),
				direction = (edge_target.direction + 4) % 8,
			}

			if signal ~= nil and combinator ~= nil then
				rails[#rails + 1] = signal
				rails[#rails + 1] = combinator

				signal.connect_neighbour({
					target_entity = combinator,
					wire = defines.wire_type.red,
				})

				-- Set condition to make signal red
				-- The pathfinding penalty does not apply unless the signal has been made red by a circuit condition
				local control_behaviour = signal.get_or_create_control_behavior()
				control_behaviour.close_signal = true
				control_behaviour.circuit_condition = {
					condition = {
						first_signal = {
							type = "item",
							name = "rail-signal",
						},
						comparator = "<",
						constant = 1,
					}
				}
			end

			processed_dividers = processed_dividers + 1
		else
			-- Add stacked trainstops
			local stop = surface.create_entity {
				name = "train-stop",
				position = edge_util.edge_pos_to_world({ edge_x + 2, -3 - processed_dividers * 4 }, edge),
				direction = edge_target.direction,
				force = "player", -- Neutral/Enemy can be used to hide trainstop name from schedule GUI/map view respectively
			}
			stop.backer_name = item.name -- Set station name
			rails[#rails + 1] = stop
		end
	end
	link.penalty_rails = rails
end

return {
	poll_connectors = poll_connectors,
	update_train_penalty_map = update_train_penalty_map,
}
