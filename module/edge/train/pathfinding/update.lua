local clusterio_api = require("modules/clusterio/api")
local itertools = require("modules/universal_edges/itertools")
local edge_util = require("modules/universal_edges/edge/util")

local function get_reachable_stations(result, train_stops)
	local reachable_stations = {}
	for index, penalty in pairs(result.penalties) do
		--[[ Stacked stations show as not accessible even though they are, but penalty is correct ]]
		if result.accessible[index] or penalty > 0 then
			local backer_name = train_stops[index].train_stop.backer_name
			reachable_stations[#reachable_stations + 1] = backer_name
		end
	end
	return reachable_stations
end

local function has_string_array_changed(new, old)
	if old ~= nil then
		if #new ~= #old then
			-- Number of stations has changed
			print("Number of stations has changed from " .. #old .. " to " .. #new)
			return true
		else
			-- Perform more detailed string comparison
			for index, station in pairs(new) do
				if station ~= old[index] then
					print("Station " .. station .. " has changed from" .. old[index])
					return true
				end
			end
		end
	end
	return false
end

--[[
	Ran for destination connectors. Figure out pathfinding penalty to reach all stations on the instance
	from this destination. Unreachable destinations are excluded from the result. We only care about
	the closest station of each name.
]]
local function update_connector_paths(edge, offset, link)
	if not link.rails[1] or not link.rails[1].valid then
		log("FATAL: Rail does not exist at " .. offset)
		return
	end

	local edge_target = edge_util.edge_get_local_target(edge)
	local train_stops = game.surfaces[edge_util.edge_get_local_target(edge).surface].find_entities_filtered {
		name = "train-stop"
	}
	local source_train_stops = game.surfaces[edge_util.edge_get_local_target(edge).surface].find_entities_filtered {
		name = "ue_source_trainstop"
	}
	local targets = {}
	local sources = {}
	local source_ids = {}
	for _, stop in pairs(train_stops) do
		-- It is possible to create trainstops and deconstructing the rail, this causes the pathfinder to throw
		if stop.valid and stop.connected_rail ~= nil then
			-- Check if stop is not part of an edge
			targets[#targets + 1] = {
				train_stop = stop
			}
			-- Log position and backer_name
			log("Found trainstop at " .. serpent.block(stop.position) .. " with name " .. stop.backer_name)
		end
	end
	for _, stop in pairs(source_train_stops) do
		if stop.valid and stop.connected_rail ~= nil then
			sources[#sources + 1] = {
				train_stop = stop
			}
			source_ids[#source_ids + 1] = stop.backer_name -- edge.id .. " " .. offset
		end
	end

	-- Find paths to stations inside the instance
	local request = {
		goals = targets,
		type = "all-goals-penalties",
	}
	-- Find paths to instance exit points
	local source_request = {
		goals = sources,
		type = "all-goals-penalties",
	}
	--[[
		Front vs back depends on direction.
		Going north you need to check front
		Going south you need to check back.
		Going east you need to check front
		Going west you need to check back
	]]
	if
		edge_target.direction == defines.direction.north -- Trains exit from the north
		or edge_target.direction == defines.direction.east -- Trains exit from the west
	then
		request.starts = { {
			rail = link.rails[1],
			direction = defines.rail_direction.back,
			is_front = false,
		} }
		source_request.starts = request.starts
	end
	if
		edge_target.direction == defines.direction.south -- Trains exit from the south
		or edge_target.direction == defines.direction.west -- Trains exit from the east
	then
		request.starts = { {
			rail = link.rails[1],
			direction = defines.rail_direction.front,
			is_front = true,
		} }
		source_request.starts = request.starts
	end

	local result_targets = game.train_manager.request_train_path(request)
	local reachable_targets = get_reachable_stations(result_targets, targets)
	log("Reachable stations for offset " .. offset .. " " .. serpent.block(reachable_targets))
	local result_sources = game.train_manager.request_train_path(source_request)
	local reachable_sources = {}
	for index, penalty in pairs(result_sources.penalties) do
		--[[ Stacked stations show as not accessible even though they are, but penalty is correct ]]
		if result_sources.accessible[index] or penalty > 0 then
			-- source id is edge id + offset
			reachable_sources[#reachable_sources + 1] = source_ids[index]
		end
	end
	log("Reachable exits for offset " .. offset .. " " .. serpent.block(reachable_sources))

	-- Check if reachability has changed - if so, send an update to the controller
	if true or has_string_array_changed(reachable_targets, link.reachable_targets) or has_string_array_changed(reachable_sources, link.reachable_sources) then
		-- log("Significant change detected, sending new stations and links")
		clusterio_api.send_json("universal_edges:train_layout_update", {
			edge_id = edge.id,
			data = {
				offset = offset,
				reachable_targets = reachable_targets,
				reachable_sources = reachable_sources,
			},
		})
	end

	-- Set scan as completed
	link.reachable_targets = reachable_targets
	link.reachable_sources = reachable_sources
	link.rescan_penalties = false
end

--[[
	Check if any connectors have updated pathfinding penalties
]]
local function poll_connectors(_id, edge, ticks_left)
	if not edge.linked_trains then
		return
	end

	if not edge.poll_connectors_state then
		edge.poll_connectors_state = {}
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

	-- Check if penalty map has changed
	local has_changed = false
	if link.last_penalty_map_update == nil then
		has_changed = true
	else
		for name, penalty in pairs(penalty_map) do
			if link.last_penalty_map_update[name] ~= penalty then
				has_changed = true
				break
			end
		end
		for name, penalty in pairs(link.last_penalty_map_update) do
			if penalty_map[name] ~= penalty then
				has_changed = true
				break
			end
		end
	end
	if not has_changed then
		return
	end
	log("Got penalty update for " .. offset .. " " .. serpent.block(penalty_map))
	link.last_penalty_map_update = penalty_map

	-- Remove old penalty entities
	if link.penalty_rails ~= nil then
		for _index, rail in pairs(link.penalty_rails) do
			if rail and rail.valid then
				rail.destroy()
			end
		end
		link.penalty_rails = nil
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
	-- Each jump is 1 server devider + 1 spot for stations for a total of 4 tiles or 2 rails. Add another 4 tiles to make sure we have enough
	for i = 2, plan_length * 2 + 4 do
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
				direction = (edge_target.direction + 8) % 16,
			}
			local combinator = surface.create_entity {
				name = "constant-combinator",
				position = edge_util.edge_pos_to_world({ edge_x + 1.5, -5.5 - processed_dividers * 4 }, edge),
				direction = (edge_target.direction + 8) % 16,
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
				---@class LuaConstantCombinatorControlBehavior
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
				name = "ue_proxy_trainstop",
				position = edge_util.edge_pos_to_world({ edge_x + 2, -3 - processed_dividers * 4 }, edge),
				direction = edge_target.direction,
				force = "player", -- Neutral/Enemy can be used to hide trainstop name from schedule GUI/map view respectively
			}
			if stop ~= nil then
				stop.backer_name = item.name -- Set station name
				rails[#rails + 1] = stop
			else
				log("Failed to create trainstop")
			end
		end
	end
	link.penalty_rails = rails

	--[[
		Tell other destination links on this server to update their paths.
		This enables propagaiton over multiple instances in a cluster.
		This could be optimized by looking at the changes performed in this sync and only updating
		paths with modificaitons.
	]]
	if (
			global.universal_edges.pathfinder.rescan_connector_paths_after == nil
			or global.universal_edges.pathfinder.rescan_connector_paths_after < game.tick
		)
	then
		global.universal_edges.pathfinder.rescan_connector_paths_after = game.tick + 180
	end
end

return {
	poll_connectors = poll_connectors,
	update_train_penalty_map = update_train_penalty_map,
}
