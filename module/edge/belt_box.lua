local util = require("modules/universal_edges/util")
local edge_util = require("modules/universal_edges/edge/util")

local function create_belt_box(offset, edge, is_input, belt_type, surface)
	local edge_target = edge_util.edge_get_local_target(edge)
	local edge_x = edge_util.offset_to_edge_x(offset, edge)

	local loader_pos = edge_util.edge_pos_to_world({edge_x, -1}, edge)
	local loader_type = util.belt_type_to_loader_type[belt_type]
	local loader
	if surface.entity_prototype_collides(loader_type, loader_pos, false, edge_target.direction) then
		-- Is the loader already there?
		loader = surface.find_entity(loader_type, loader_pos)
		if not loader then
			return false
		end
	end

	local chest_pos = edge_util.edge_pos_to_world({edge_x, -2.5}, edge)
	local chest
	if surface.entity_prototype_collides("steel-chest", chest_pos, false) then
		-- Is the chest already there?
		chest = surface.find_entity("steel-chest", chest_pos)
		if not chest then
			return false
		end
	end

	if not loader then
		loader = surface.create_entity {
			name = loader_type,
			position = loader_pos,
			direction = (edge_target.direction + 8) % 16,
		}
	end

	loader.loader_type = is_input and "input" or "output"

	if not chest then
		chest = surface.create_entity {
			name = "steel-chest",
			position = chest_pos,
		}
	end

	if not edge.linked_belts then
		edge.linked_belts = {}
	end

	if edge.linked_belts[offset] then
		edge.linked_belts[offset].chest = chest
		edge.linked_belts[offset].is_input = is_input
		edge.linked_belts[offset].flag_for_removal = false
	else
		edge.linked_belts[offset] = {
			chest = chest,
			is_input = is_input,
			start_index = nil,
			flag_for_removal = nil,
		}
	end

	return true
end

local function remove_belt_box(offset, edge, surface)
	local edge_x = edge_util.offset_to_edge_x(offset, edge)
	if edge.linked_belts and edge.linked_belts[offset] then
		local link = edge.linked_belts[offset]

		if link.chest and link.chest.valid then
			local inventory = link.chest.get_inventory(defines.inventory.chest)
			if inventory and not inventory.is_empty() then
				link.flag_for_removal = true
				return
			end

			link.chest.destroy()
		end

		edge.linked_belts[offset] = nil

	else
		local chest_pos = edge_util.edge_pos_to_world({edge_x, -2.5}, edge)
		local chest = surface.find_entity("steel-chest", chest_pos)

		if chest then
			local inventory = chest.get_inventory(defines.inventory.chest)
			if inventory and inventory.is_empty() then
				chest.destroy()
			end
		end
	end

	local loader_pos = edge_util.edge_pos_to_world({edge_x, -1}, edge)
	for _, loader_type in pairs(util.belt_type_to_loader_type) do
		local loader = surface.find_entity(loader_type, loader_pos)
		if loader then
			loader.destroy()
		end
	end
end

return {
	create = create_belt_box,
	remove = remove_belt_box,
}
