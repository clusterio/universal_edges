local edge_util = require("modules/universal_edges/edge/util")

local function create_power_box(offset, edge, surface, powerpole)
	local edge_x = edge_util.offset_to_edge_x(offset, edge)

	local accumulator_pos = edge_util.edge_pos_to_world({ edge_x, -1 }, edge)
	local accumulator = surface.find_entity("accumulator", accumulator_pos)
	local powerpole_pos = accumulator_pos
	local powerpole_created = false
	local link_powerpole = powerpole
	if surface.entity_prototype_collides("accumulator", accumulator_pos, false) then
		-- Is the accumulator already there?
		if not accumulator then
			return false
		end
	end

	if not link_powerpole or not link_powerpole.valid then
		link_powerpole = surface.find_entity("substation", powerpole_pos)
	end
	if not link_powerpole then
		link_powerpole = surface.create_entity {
			name = "substation",
			position = powerpole_pos,
		}
		powerpole_created = true
	end

	if not accumulator then
		accumulator = surface.create_entity {
			name = "accumulator",
			position = accumulator_pos,
		}
	end

	if not edge.linked_power then
		edge.linked_power = {}
	end

	if edge.linked_power[offset] then
		if not powerpole_created
			and edge.linked_power[offset].powerpole_created
			and edge.linked_power[offset].powerpole == link_powerpole
		then
			powerpole_created = true
		end
		edge.linked_power[offset].accumulator = accumulator
		edge.linked_power[offset].powerpole = link_powerpole
		edge.linked_power[offset].powerpole_created = powerpole_created
	else
		edge.linked_power[offset] = {
			accumulator = accumulator,
			powerpole = link_powerpole,
			powerpole_created = powerpole_created,
		}
	end

	return true
end

local function remove_power_box(offset, edge, surface)
	local edge_x = edge_util.offset_to_edge_x(offset, edge)
	if edge.linked_power and edge.linked_power[offset] then
		local link = edge.linked_power[offset]

		if link.accumulator and link.accumulator.valid then
			link.accumulator.destroy()
		end
		if link.powerpole_created and link.powerpole and link.powerpole.valid then
			link.powerpole.destroy()
		end

		edge.linked_power[offset] = nil
	else
		local accumulator_pos = edge_util.edge_pos_to_world({ edge_x, -1 }, edge)
		local accumulator = surface.find_entity("accumulator", accumulator_pos)
		if accumulator then
			accumulator.destroy()
		end
	end
end

return {
	create = create_power_box,
	remove = remove_power_box,
}
