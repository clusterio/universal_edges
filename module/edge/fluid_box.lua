local edge_util = require("modules/universal_edges/edge/util")

local function create_fluid_box(offset, edge, surface)
	local edge_target = edge_util.edge_get_local_target(edge)
	local edge_x = edge_util.offset_to_edge_x(offset, edge)

	local pipe_pos = edge_util.edge_pos_to_world({ edge_x, -0.5 }, edge)
	local pipe_type
	if edge_target.direction % 8 == 0 then -- Entrance is north/south
		pipe_type = "edge_pipe_vertical"
	else
		pipe_type = "edge_pipe_horizontal"
	end
	local pipe
	if surface.entity_prototype_collides(pipe_type, pipe_pos, false, edge_target.direction) then
		-- Is the pipe already there?
		pipe = surface.find_entity(pipe_type, pipe_pos)
		if not pipe then
			return false
		end
	end

	if not pipe then
		pipe = surface.create_entity {
			name = pipe_type,
			position = pipe_pos,
		}
	end

	if not edge.linked_fluids then
		edge.linked_fluids = {}
	end

	if edge.linked_fluids[offset] then
		edge.linked_fluids[offset].pipe = pipe
		edge.linked_fluids[offset].flag_for_removal = false
	else
		edge.linked_fluids[offset] = {
			pipe = pipe,
			start_index = nil,
			flag_for_removal = nil,
		}
	end

	return true
end

local function remove_fluid_box(offset, edge, surface)
	local edge_x = edge_util.offset_to_edge_x(offset, edge)
	if edge.linked_fluids and edge.linked_fluids[offset] then
		local link = edge.linked_fluids[offset]

		if link.pipe and link.pipe.valid then
			link.pipe.destroy()
		end

		edge.linked_fluids[offset] = nil
	elseif surface ~= nil then
		local pipe_pos = edge_util.edge_pos_to_world({ edge_x, -0.5 }, edge)
		local pipe_vertical = surface.find_entity("edge_pipe_vertical", pipe_pos)
		if pipe_vertical then
			pipe_vertical.destroy()
			return
		end
		local pipe_horizontal = surface.find_entity("edge_pipe_horizontal", pipe_pos)
		if pipe_horizontal then
			pipe_horizontal.destroy()
		end
	end
end

return {
	create = create_fluid_box,
	remove = remove_fluid_box,
}
