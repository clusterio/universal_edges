local vectorutil = require("modules/universal_edges/vectorutil")

local edge_util = {}

---@param edge UniversalEdge
---@return EdgeSourceOrTarget
function edge_util.edge_get_local_target(edge)
	if storage.universal_edges.config.instance_id == edge.source.instanceId then
		return edge.source
	else
		return edge.target
	end
end

---@param edge UniversalEdge
---@return EdgeSourceOrTarget
function edge_util.edge_get_remote_target(edge)
	if storage.universal_edges.config.instance_id == edge.source.instanceId then
		return edge.target
	else
		return edge.source
	end
end

---@param pos MapPosition
---@return nil | Vector
function edge_util.pos_to_array(pos)
	if pos == nil then
		return nil
	end
	if pos[1] ~= nil then
		return { pos[1], pos[2] }
	end
	return { pos.x, pos.y }
end

---@param pos table
---@return nil | MapPosition
function edge_util.array_to_pos(pos)
	if pos == nil then
		return nil
	end
	if pos.x ~= nil then
		return { x = pos.x, y = pos.y }
	end
	return { x = pos[1], y = pos[2] }
end

---@param pos MapPosition
---@param edge UniversalEdge
---@return Vector
function edge_util.world_to_edge_pos(pos, edge)
	local array = edge_util.pos_to_array(pos)
	local local_edge_target = edge_util.edge_get_local_target(edge)
	return vectorutil.vec2_rot(vectorutil.vec2_sub(array, local_edge_target.origin), -local_edge_target.direction % 16)
end

---@param edge_pos Vector
---@param edge UniversalEdge
---@return Vector
function edge_util.edge_pos_to_world(edge_pos, edge)
	local array = edge_util.pos_to_array(edge_pos)
	local local_edge_target = edge_util.edge_get_local_target(edge)
	return vectorutil.vec2_add(vectorutil.vec2_rot(array, local_edge_target.direction), local_edge_target.origin)
end

-- Flip needed to make coordinates match up when crossing an edge
---@param edge_pos Vector
---@param edge UniversalEdge
---@return table
function edge_util.flip_edge_pos(edge_pos, edge)
	local array = edge_util.pos_to_array(edge_pos)
	return {edge.length - array[1], -array[2]}
end

---@param edge_pos Vector
---@param edge UniversalEdge
---@return number
function edge_util.edge_pos_to_offset(edge_pos, edge)
	local array = edge_util.pos_to_array(edge_pos)
	local local_edge_target = edge_util.edge_get_local_target(edge)
	local offset = array[1]
	if local_edge_target.direction >= 8 then
		offset = edge.length - offset
	end
	return offset
end

---@param offset number
---@param edge UniversalEdge
---@return number
function edge_util.offset_to_edge_x(offset, edge)
	local local_edge_target = edge_util.edge_get_local_target(edge)
	local edge_x = offset
	if local_edge_target.direction >= 8 then
		edge_x = edge.length - edge_x
	end
	return edge_x
end

return edge_util
