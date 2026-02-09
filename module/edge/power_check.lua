local edge_util = require("modules/universal_edges/edge/util")

---comment
---@param edge_pos Vector
---@param edge UniversalEdge
---@return boolean
local function is_in_1x1_placement_area(edge_pos, edge)
	if edge_pos[2] <= 0 or edge_pos[2] >= 1 then return false end
	if edge_pos[1] <= 0 or edge_pos[1] >= edge.length then return false end

	return true
end

---@param edge_pos Vector
---@param edge UniversalEdge
---@return boolean
local function is_in_2x2_placement_area(edge_pos, edge)
	if edge_pos[2] <= 0.5 or edge_pos[2] >= 1.5 then return false end
	if edge_pos[1] <= 0 or edge_pos[1] >= edge.length then return false end

	return true
end

-- List of 2x2 entities (the rest are assumed to be 1x1)
local entities_2x2 = {
	["substation"] = true,
	["big-electric-pole"] = true,
	["straight-rail"] = true,
}

-- Check if an entity at world pos can connect to or from the given edge
-- returns edge offset if it does, otherwise nil
---@param pos MapPosition
---@param edge UniversalEdge
---@param entity LuaEntity
---@return nil | number
local function power_check(pos, edge, entity)
	local edge_pos = edge_util.world_to_edge_pos(pos, edge)
	
	-- Check if this is a 2x2 entity, otherwise treat as 1x1
	local is_2x2 = entity and entities_2x2[entity.name]
	
	if is_2x2 then
		if not is_in_2x2_placement_area(edge_pos, edge) then
			return nil
		end
	else
		if not is_in_1x1_placement_area(edge_pos, edge) then
			return nil
		end
	end

	return edge_util.edge_pos_to_offset(edge_pos, edge)
end

return power_check
