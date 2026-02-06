local edge_util = require("modules/universal_edges/edge/util")

---@param edge_pos Vector
---@param edge UniversalEdge
---@return boolean
local function is_in_1x1_placement_area(edge_pos, edge)
	if edge_pos[2] <= 0 or edge_pos[2] >= 1 then return false end
	if edge_pos[1] <= 0 or edge_pos[1] >= edge.length then return false end

	return true
end

---@param edge_pos Vector
---@param direction uint32
---@param edge UniversalEdge
---@return boolean
local function is_pump_in_placement_area(edge_pos, direction, edge)
	-- Pumps are 2x1 entities and need to be perpendicular to the edge to transfer fluids across it
	-- The pump should span across the edge boundary (Y=0 line)
	
	local edge_direction = edge_util.edge_get_local_target(edge).direction
	
	-- Check if pump is perpendicular to edge (same logic as belts)
	if edge_direction % 8 ~= direction % 8 then
		return false
	end
	
	-- For a pump to work across an edge, it needs to span the edge line (Y=0)
	-- Pump position is at center, so for a 2x1 pump:
	-- - If direction is north(0)/south(4): pump extends 1 unit in Y direction from center
	-- - If direction is east(2)/west(6): pump extends 0.5 units in Y direction from center
	
	-- Check if the pump spans across the edge (Y=0 line)
	if direction == 0 or direction == 4 then
		-- Vertical pump (2 tall, 1 wide)
		if edge_pos[2] >= -1 and edge_pos[2] <= 1 then
			-- Check if pump is within the edge bounds
			if edge_pos[1] > 0 and edge_pos[1] < edge.length then
				return true
			end
		end
	elseif direction == 2 or direction == 6 then
		-- Horizontal pump (1 tall, 2 wide) - check if it crosses the edge line
		if edge_pos[2] >= -0.5 and edge_pos[2] <= 0.5 then
			-- Check if pump is within the edge bounds  
			if edge_pos[1] > 0.5 and edge_pos[1] < edge.length - 0.5 then
				return true
			end
		end
	end
	
	return false
end

-- Check if a fluid entity at world pos and direction is going to or from the given edge
-- returns edge offset if it does, otherwise nil
---@param pos MapPosition
---@param direction uint32
---@param edge UniversalEdge
---@param entity LuaEntity
---@return nil | number
local function fluid_check(pos, direction, edge, entity)
	local edge_pos = edge_util.world_to_edge_pos(pos, edge)

	-- Handle pumps separately due to their 2x1 size and directional requirements
	if entity and entity.name == "pump" then
		if is_pump_in_placement_area(edge_pos, direction, edge) then
			return edge_util.edge_pos_to_offset(edge_pos, edge)
		else
			return nil
		end
	end

	-- Handle pipes and pipe-to-ground (1x1 entities)
	if not is_in_1x1_placement_area(edge_pos, edge) then
		return nil
	end

	return edge_util.edge_pos_to_offset(edge_pos, edge)
end

return fluid_check
