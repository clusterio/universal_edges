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
	if types_to_cause_update[entity.type] and global.universal_edges.pathfinder.rescan_connector_paths_after == nil then
		global.universal_edges.pathfinder.rescan_connector_paths_after = game.tick + 600
	end
end

local function on_removed(entity)
	-- Queue rescan
	if types_to_cause_update[entity.type] and global.universal_edges.pathfinder.rescan_connector_paths_after == nil then
		global.universal_edges.pathfinder.rescan_connector_paths_after = game.tick + 600
	end
end

return {
	on_server_startup = on_server_startup,
	on_built = on_built,
	on_removed = on_removed,
}
