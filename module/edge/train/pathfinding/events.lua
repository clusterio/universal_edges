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
	if not global.universal_edges.pathfinder then
		global.universal_edges.pathfinder = {}
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
			global.universal_edges.pathfinder.rescan_connector_paths_after == nil
			or global.universal_edges.pathfinder.rescan_connector_paths_after < game.tick
		)
	then
		global.universal_edges.pathfinder.rescan_connector_paths_after = game.tick + 180
	end
end

local function on_removed(entity)
	-- Queue rescan
	if types_to_cause_update[entity.type]
		and (
			global.universal_edges.pathfinder.rescan_connector_paths_after == nil
			or global.universal_edges.pathfinder.rescan_connector_paths_after < game.tick
		)
	then
		global.universal_edges.pathfinder.rescan_connector_paths_after = game.tick + 180
	end
end

local function on_tick()
	if global.universal_edges.pathfinder.rescan_connector_paths_after == game.tick then
		global.universal_edges.pathfinder.rescan_connector_paths_after = nil
		-- Add rescan_penalties property to all links
		log("Starting rescan")
		for _, edge in pairs(global.universal_edges.edges) do
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
