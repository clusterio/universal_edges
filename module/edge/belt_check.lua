local edge_util = require("modules/universal_edges/edge/util")

local function is_in_1x1_placement_area(edge_pos, edge)
	if edge_pos[2] <= 0 or edge_pos[2] >= 1 then return false end
	if edge_pos[1] <= 0 or edge_pos[1] >= edge.length then return false end

	return true
end

-- Check if a belt at world pos and direction is going to or from the given edge
-- returns edge offset if it does, otherwise nil
local function belt_check(pos, direction, edge)
	-- Check if the axis the belt in is pendicular to the edge
	if edge_util.edge_get_local_target(edge).direction % 4 ~= direction % 4 then
		return nil
	end

	local edge_pos = edge_util.world_to_edge_pos(pos, edge)
	if not is_in_1x1_placement_area(edge_pos, edge) then
		return nil
	end

	return edge_util.edge_pos_to_offset(edge_pos, edge)
end

return belt_check
