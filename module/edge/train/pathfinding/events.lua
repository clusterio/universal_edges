local clusterio_api = require("modules/clusterio/api")

--[[
	Rescan available paths for edges on:
	- Station added
	- Station removed
	- Rail added
		- Connector added
	- Rail removed
		- Connector removed
	- Connector with is_input changed penalty by more than 50k threshold
]]

local function on_server_startup()
	if not storage.universal_edges.pathfinder then
		storage.universal_edges.pathfinder = {}
	end
	for _, edge in pairs(storage.universal_edges.edges) do
		local train_transfers = {}
		if edge.linked_trains then
			for offset, link in pairs(edge.linked_trains) do
				if link.is_input == false then
					--[[
						Force rescan and retransmit, even if there were no changes on this instance
						This is required because the partner instance might have reverted to an older version of the map,
						or maybe this instance reverted to an older version.
					]]
					link.rescan_penalties = true
					link.penalty_map = nil

					-- Update flow (Is destination station blocked by a train?)
					link.set_flow = link.signal and link.signal.signal_state == defines.signal_state.open
					train_transfers[#train_transfers + 1] = {
						offset = offset,
						set_flow = link.set_flow,
					}
				end
			end
		end
		if #train_transfers > 0 then
			log("Updating train flow status " .. serpent.block(train_transfers))
			clusterio_api.send_json("universal_edges:transfer", {
				edge_id = edge.id,
				train_transfers = train_transfers,
			})
		end
	end
end

local types_to_cause_update = {
	["straight-rail"] = true,
	["curved-rail"] = true,
	["rail-signal"] = true,
	["rail-chain-signal"] = true,
	["train-stop"] = true,
}

local function on_built(entity)
	-- Queue rescan
	if types_to_cause_update[entity.type]
		and (
			storage.universal_edges.pathfinder.rescan_connector_paths_after == nil
			or storage.universal_edges.pathfinder.rescan_connector_paths_after < game.tick
		)
	then
		storage.universal_edges.pathfinder.rescan_connector_paths_after = game.tick + 180
	end
end

local function on_removed(entity)
	-- Queue rescan
	if types_to_cause_update[entity.type]
		and (
			storage.universal_edges.pathfinder.rescan_connector_paths_after == nil
			or storage.universal_edges.pathfinder.rescan_connector_paths_after < game.tick
		)
	then
		storage.universal_edges.pathfinder.rescan_connector_paths_after = game.tick + 180
	end
end

local function on_tick()
	if storage.universal_edges.pathfinder.rescan_connector_paths_after == game.tick then
		storage.universal_edges.pathfinder.rescan_connector_paths_after = nil
		-- Add rescan_penalties property to all links
		log("Starting rescan")
		for _, edge in pairs(storage.universal_edges.edges) do
			if edge.linked_trains then
				for _, link in pairs(edge.linked_trains) do
					if link.is_input == false then
						link.rescan_penalties = true
					end
				end
			end
		end
	end
end

return {
	on_server_startup = on_server_startup,
	on_built = on_built,
	on_removed = on_removed,
	on_tick = on_tick,
}
