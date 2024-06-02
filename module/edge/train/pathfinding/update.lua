local clusterio_api = require("modules/clusterio/api")
local itertools = require("modules/universal_edges/itertools")
local edge_util = require("modules/universal_edges/edge/util")

local function update_connector_paths(edge, offset, link)
	local edge_target = edge_util.edge_get_local_target(edge)
	local train_stops = game.surfaces[1].find_entities_filtered {
		type = "train-stop"
	}
	local goals = {}
	for _, stop in pairs(train_stops) do
		goals[#goals + 1] = {
			train_stop = stop
		}
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
	log("Penalty map " .. serpent.block(penalty_map))

	-- Check if new penalty map is significantly different from old penalty map
	-- If it is, update the penalty map on the source side of the connector
	local send_update = false
	local old_penalty_map = link.penalty_map
	if old_penalty_map ~= nil then
		local penalty_diff = 0
		for backer_name, penalty in pairs(penalty_map) do
			local old_penalty = old_penalty_map[backer_name] or 0
			penalty_diff = penalty_diff + math.abs(penalty - old_penalty)
		end
		if penalty_diff > 50000 then
			link.penalty_map = penalty_map
			send_update = true
		end
	else
		link.penalty_map = penalty_map
		send_update = true
	end

	if send_update then
		log("Significant change detected, sending penalty map")
		return {
			type = "update_train_penalty_map",
			edge_id = edge.id,
			data = {
				offset = offset,
				penalty_map = link.penalty_map,
			},
		}
	end
end

local function poll_connectors(id, edge, ticks_left)
	if not edge.poll_connectors_state then
		edge.poll_connectors_state = {}
	end

	if not edge.pending_train_transfers then
		edge.pending_train_transfers = {}
	end

	local penalty_updates = {}
	for offset, link in itertools.partial_pairs(
		edge.linked_trains, edge.poll_connectors_state, ticks_left
	) do
		-- Only check penalties for outputs
		if not link.is_input then
			local update = update_connector_paths(edge, offset, link)
			penalty_updates[#penalty_updates + 1] = update
		end
	end

	if #penalty_updates > 0 then
		clusterio_api.send_json("universal_edges:transfer", {
			edge_id = id,
			penalty_updates = penalty_updates,
		})
	end
end

--[[
	This function almost belongs more in train_box
	Basically, it creates stations and circuit locked signals to emulate the pathfinding graph
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

	-- Remove old penalty entities
	for _index, rail in pairs(link.penalty_rails) do
		if rail and rail.valid then
			rail.destroy()
		end
	end

	-- Plan layout of stations and seperator signals
	local station_count = 0
	for _, _ in pairs(penalty_map) do
		station_count = station_count + 1
	end
	local penalty_plan = {}
	local processed_stations = 0
	local plan_length = 0 -- Number of server_dividers in the plan, ~1 per server manhattan distance to furthest stop
	while processed_stations < station_count do
		-- Add new padding to plan
		plan_length = plan_length + 1
		penalty_plan[#penalty_plan + 1] = {
			type = "server_divider",
			penalty = 100000,
		}
		-- Check if any stops belong in this bucket
		local current_penalty = penalty_plan[#penalty_plan].penalty
		for name, penalty in pairs(penalty_map) do
			if penalty >= current_penalty and penalty < current_penalty + 100000 then
				penalty_plan[#penalty_plan + 1] = {
					name = name,
					penalty = penalty,
				}
				processed_stations = processed_stations + 1
			end
		end
	end

	local edge_x = edge_util.offset_to_edge_x(offset, edge)
	local edge_target = edge_util.edge_get_local_target(edge)
	local rails = {}
	for i = 3, #plan_length + 2 do
		rails[#rails + 1] = edge_target.surface.create_entity {
			name = "straight-rail",
			position = edge_util.edge_pos_to_world({ edge_x, 1 - i * 2 }, edge),
			direction = edge_target.direction,
		}
	end
	local processed_dividers = 0
	for _, item in ipairs(penalty_plan) do
		if item.type == "server_divider" then
			-- Add huge pathfinding penalty
			local signal = edge_target.surface.create_entity {
				name = "rail-signal",
				position = edge_util.edge_pos_to_world({ edge_x + 1.5, -4.5 + processed_dividers * 4 }, edge),
				direction = (edge_target.direction + 4) % 8,
			}
			rails[#rails + 1] = signal
			local combinator = edge_target.surface.create_entity {
				name = "constant-combinator",
				position = edge_util.edge_pos_to_world({ edge_x + 1.5, -5.5 + processed_dividers * 4 }, edge),
				direction = (edge_target.direction + 4) % 8,
			}
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

			processed_dividers = processed_dividers + 1
		else
			-- Add stacked trainstops
			local stop = edge_target.surface.create_entity {
				name = "train-stop",
				position = edge_util.edge_pos_to_world({ edge_x + 2, -3 + processed_dividers * 4 }, edge),
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
