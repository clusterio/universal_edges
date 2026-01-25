local vectorutil = require("modules/universal_edges/vectorutil")

local function edge_get_local_target(edge)
	if storage.universal_edges.config.instance_id == edge.source.instanceId then
		return edge.source
	elseif storage.universal_edges.config.instance_id == edge.target.instanceId then
		return edge.target
	end
end
local function edge_get_remote_target(edge)
	if storage.universal_edges.config.instance_id == edge.source.instanceId then
		return edge.target
	elseif storage.universal_edges.config.instance_id == edge.target.instanceId then
		return edge.source
	end
end
local function pos_to_array(pos)
	if pos == nil then
		return nil
	end
	if pos[1] ~= nil then
		return { pos[1], pos[2] }
	end
	return { pos.x, pos.y }
end

local function array_to_pos(pos)
	if pos == nil then
		return nil
	end
	if pos.x ~= nil then
		return { x = pos.x, y = pos.y }
	end
	return { x = pos[1], y = pos[2] }
end

local function world_to_edge_pos(pos, edge)
	pos = pos_to_array(pos)
	local local_edge_target = edge_get_local_target(edge)
	return vectorutil.vec2_rot(vectorutil.vec2_sub(pos, local_edge_target.origin), -local_edge_target.direction % 16)
end
local function edge_pos_to_world(edge_pos, edge)
	edge_pos = pos_to_array(edge_pos)
	local local_edge_target = edge_get_local_target(edge)
	return vectorutil.vec2_add(vectorutil.vec2_rot(edge_pos, local_edge_target.direction), local_edge_target.origin)
end
-- Flip needed to make coordinates match up when crossing an edge
local function flip_edge_pos(edge_pos, edge)
	edge_pos = pos_to_array(edge_pos)
	return {edge.length - edge_pos[1], -edge_pos[2]}
end
local function edge_pos_to_offset(edge_pos, edge)
	edge_pos = pos_to_array(edge_pos)
	local local_edge_target = edge_get_local_target(edge)
	local offset = edge_pos[1]
	if local_edge_target.direction >= 8 then
		offset = edge.length - offset
	end
	return offset
end
local function offset_to_edge_x(offset, edge)
	local local_edge_target = edge_get_local_target(edge)
	local edge_x = offset
	if local_edge_target.direction >= 8 then
		edge_x = edge.length - edge_x
	end
	return edge_x
end

return {
	edge_get_local_target = edge_get_local_target,
	edge_get_remote_target = edge_get_remote_target,
	world_to_edge_pos = world_to_edge_pos,
	edge_pos_to_world = edge_pos_to_world,
	flip_edge_pos = flip_edge_pos,
	edge_pos_to_offset = edge_pos_to_offset,
	offset_to_edge_x = offset_to_edge_x,
	pos_to_array = pos_to_array,
	array_to_pos = array_to_pos,
}
