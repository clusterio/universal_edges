local edge_util = require("modules/universal_edges/edge/util")

local eei_type = "ue_eei_tertiary"

local function create_power_box(offset, edge, surface)
	local edge_x = edge_util.offset_to_edge_x(offset, edge)

	local eei_pos = edge_util.edge_pos_to_world({ edge_x, -1 }, edge)
	local charge_sensor = surface.find_entity("accumulator", eei_pos)
	local powerpole = surface.find_entity("substation", eei_pos)
	local eei
	if surface.entity_prototype_collides(eei_type, eei_pos, false) then
		-- Is the eei already there?
		eei = surface.find_entity(eei_type, eei_pos)
		if not eei then
			return false
		end
	end

	if not eei then
		eei = surface.create_entity {
			name = eei_type,
			position = eei_pos,
		}
	end

	if not charge_sensor then
		charge_sensor = surface.create_entity {
			name = "accumulator",
			position = eei_pos,
		}
	end

	if not powerpole then
		powerpole = surface.create_entity {
			name = "substation",
			position = eei_pos,
		}
	end

	if not edge.linked_power then
		edge.linked_power = {}
	end

	if edge.linked_power[offset] then
		edge.linked_power[offset].eei = eei
		edge.linked_power[offset].charge_sensor = charge_sensor
		edge.linked_power[offset].powerpole = powerpole
	else
		edge.linked_power[offset] = {
			eei = eei,
			charge_sensor = charge_sensor,
		}
	end

	return true
end

local function remove_power_box(offset, edge, surface)
	local edge_x = edge_util.offset_to_edge_x(offset, edge)
	if edge.linked_power and edge.linked_power[offset] then
		local link = edge.linked_power[offset]

		if link.eei and link.eei.valid then
			link.eei.destroy()
		end
		if link.charge_sensor and link.charge_sensor.valid then
			link.charge_sensor.destroy()
		end
		if link.powerpole and link.powerpole.valid then
			link.powerpole.destroy()
		end

		edge.linked_power[offset] = nil
	else
		local eei_pos = edge_util.edge_pos_to_world({ edge_x, -1 }, edge)
		local eei = surface.find_entity(eei_type, eei_pos)
		if eei then
			eei.destroy()
		end
		local charge_sensor = surface.find_entity("accumulator", eei_pos)
		if charge_sensor then
			charge_sensor.destroy()
		end
		local powerpole = surface.find_entity("substation", eei_pos)
		if powerpole then
			powerpole.destroy()
		end
	end
end

return {
	create = create_power_box,
	remove = remove_power_box,
}
