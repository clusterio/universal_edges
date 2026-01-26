local clusterio_serialize = require("modules/clusterio/serialize")
local LuaTrain_serialize = require("modules/universal_edges/universal_serializer/classes/LuaTrain_serialize")
local LuaBurner_serialize = require("modules/universal_edges/universal_serializer/classes/LuaBurner_serialize")
local LuaFluidBox_serialize = require("modules/universal_edges/universal_serializer/classes/LuaFluidBox_serialize")
--[[
	Function to serialize an entity to a string.
]]
---@param entity LuaEntity
local function entity_serialize(entity)
	local entity_data = {
		surface = entity.surface.name,
		name = entity.name,
		type = entity.type,
		position = { entity.position.x, entity.position.y },
		direction = entity.direction,
		orientation = entity.orientation,
		force = entity.force.name,
		player = entity.last_user and entity.last_user.name or nil,
		energy = entity.energy,
		temperature = entity.temperature,
	}
	if entity.supports_backer_name() then
		entity_data.backer_name = entity.backer_name
	end
	if entity.type == "entity-ghost" then
		entity_data.ghost_name = entity.ghost_name
		entity_data.time_to_live = entity
			.time_to_live --[[ Applies to ghost, combat robot, highlight box, smoke with trigger and sticker ]]
	end
	if entity.type == "unit" then
		entity_data.unit_number = entity.unit_number
	end
	if entity.type == "assembling-machine" then
		entity_data.recipe = entity.get_recipe() and entity.get_recipe().name
	end
	if entity.type == "container" then
		entity_data.supports_bar = entity.get_inventory(defines.inventory.chest).supports_bar()
		if entity_data.supports_bar then
			entity_data.bar = entity.get_inventory(defines.inventory.chest).get_bar()
		end
	end
	if entity.type == "cliff" then
		entity_data.cliff_orientation = entity.cliff_orientation
	end
	if entity.type == "entity-ghost" then
		entity_data.ghost_name = entity.ghost_name
		entity_data.item_requests = entity.item_requests
	end
	if entity.type == "logistic-container" then
		-- entity_data.request_filters = entity.request_filters -- Request_filters is not a property
		-- Read request slots individually
		local slot_count = entity.request_slot_count
		if slot_count > 0 then
			local request_slots = {}
			for i = 1, slot_count do
				local item_stack = entity.get_request_slot(i)
				if item_stack ~= nil then
					request_slots[i] = item_stack
				end
			end
			entity_data.request_slots = request_slots
			entity_data.request_slot_count = slot_count
			-- This line crashes when read on a storage chest (any entity without request slots)
			entity_data.request_from_buffers = entity.request_from_buffers
		end
	end
	if entity.type == "item-entity" and entity.name == "item-on-ground" then
		entity_data.stack = {
			name = entity.stack.name,
			count = entity.stack.count,
		}
	end
	if entity.type == "train-stop" then
		entity_data.trains_limit = entity.trains_limit
	end
	-- Vehicle speed (car, tank, spidertron)
	if entity.type == "car" or entity.type == "spider-vehicle" then
		entity_data.speed = entity.speed
	end
	-- Circuit connection
	local control_behavior = entity.get_control_behavior()
	if control_behavior ~= nil then
		entity_data.control_behavior = {}
		entity_data.control_behavior.object_name = control_behavior.object_name
		---@param cb LuaGenericOnOffControlBehavior
		local function LuaGenericOnOffControlBehavior_serialize(cb)
			entity_data.control_behavior.connect_to_logistic_network = cb.connect_to_logistic_network
			if cb.circuit_condition ~= nil then
				entity_data.control_behavior.circuit_condition = {
					condition = cb.circuit_condition.condition
				}
			end
			if cb.logistic_condition ~= nil then
				entity_data.control_behavior.logistic_condition = {
					condition = cb.logistic_condition.condition
				}
			end
		end
		if control_behavior.object_name == "LuaTrainStopControlBehavior" then
			entity_data.control_behavior.send_to_train = control_behavior.send_to_train
			entity_data.control_behavior.read_from_train = control_behavior.read_from_train
			entity_data.control_behavior.read_stopped_train = control_behavior.read_stopped_train
			entity_data.control_behavior.set_trains_limit = control_behavior.set_trains_limit
			entity_data.control_behavior.read_trains_count = control_behavior.read_trains_count
			entity_data.control_behavior.enable_disable = control_behavior.enable_disable
			entity_data.control_behavior.stopped_train_signal = control_behavior.stopped_train_signal
			entity_data.control_behavior.trains_count_signal = control_behavior.trains_count_signal
			entity_data.control_behavior.trains_limit_signal = control_behavior.trains_limit_signal
			LuaGenericOnOffControlBehavior_serialize(control_behavior)
		end
		if control_behavior.object_name == "LuaInserterControlBehavior" then
			entity_data.control_behavior.circuit_read_hand_contents = control_behavior.circuit_read_hand_contents
			entity_data.control_behavior.circuit_mode_of_operation = control_behavior.circuit_mode_of_operation
			entity_data.control_behavior.circuit_hand_read_mode = control_behavior.circuit_hand_read_mode
			entity_data.control_behavior.circuit_set_stack_size = control_behavior.circuit_set_stack_size
			entity_data.control_behavior.circuit_stack_control_signal = control_behavior.circuit_stack_control_signal
			LuaGenericOnOffControlBehavior_serialize(control_behavior)
		end
		if control_behavior.object_name == "LuaGenericOnOffControlBehavior" then
			LuaGenericOnOffControlBehavior_serialize(control_behavior)
		end
		-- LuaCircuitNetwork (not implemented, needs red and green)
	end

	-- Trains
	if entity.train ~= nil then
		entity_data.train = LuaTrain_serialize(entity.train)
	end

	-- Cars & Tanks
	if entity.type == "car" then
		if entity.name == "car" then
			entity_data.car = {}
			-- Health
			entity_data.car.health = entity.health
		elseif entity.name == "tank" then
			entity_data.tank = {}
			-- Health
			entity_data.tank.health = entity.health
			-- Logistic requests
			entity_data.tank.enable_logistics_while_moving = entity.enable_logistics_while_moving
			-- trash_unrequested
			entity_data.tank.logistic_requests = {}
			local logistic_point = entity.get_logistic_point(0) ---@cast logistic_point -nil
			entity_data.tank.trash_not_requested = logistic_point.trash_not_requested
			if logistic_point then
				local logistic_sections = logistic_point.sections
				if logistic_sections then
					for section_index, logistic_section in pairs(logistic_sections) do
						entity_data.tank.logistic_requests[section_index] = {
							active = logistic_section.active,
							filters = logistic_section.filters
						}
					end
				end
			end
		end
	end

	-- Spidertron
	if entity.type == "spider-vehicle" then
		entity_data.spidertron = {}
		-- Name
		entity_data.spidertron.entity_label = entity.entity_label
		-- Color
		entity_data.spidertron.color = entity.color
		-- Health
		entity_data.spidertron.health = entity.health
		-- Autopilot destinations
		entity_data.spidertron.autopilot_destinations = {[1] = entity.autopilot_destination}
		for _, destination in pairs(entity.autopilot_destinations) do
			table.insert(entity_data.spidertron.autopilot_destinations, destination)
		end
		-- Logistic requests
		entity_data.spidertron.logistic_requests = {}
		local logistic_point = entity.get_logistic_point(0) ---@cast logistic_point -nil
		if logistic_point then
			local logistic_sections = logistic_point.sections
			if logistic_sections then
				for section_index, logistic_section in pairs(logistic_sections) do
					entity_data.spidertron.logistic_requests[section_index] = {
						active = logistic_section.active,
						filters = logistic_section.filters
					}
				end
			end
		end
		-- Spider settings
		entity_data.spidertron.enable_logistics_while_moving = entity.enable_logistics_while_moving
		entity_data.spidertron.trash_not_requested = logistic_point.trash_not_requested
		entity_data.spidertron.driver_is_gunner = entity.driver_is_gunner
		entity_data.spidertron.vehicle_automatic_targeting_parameters = entity.vehicle_automatic_targeting_parameters
	end

	-- Equipment grid for vehicles (spidertron, car, tank)
	if entity.grid then
		entity_data.equipment_grid = clusterio_serialize.serialize_equipment_grid(entity.grid)
	end

	-- Burner
	if entity.burner ~= nil then
		entity_data.burner = LuaBurner_serialize(entity.burner)
	end

	-- Fluidbox
	if #entity.fluidbox then
		entity_data.fluidbox = LuaFluidBox_serialize(entity.fluidbox)
	end

	--[[ Handle inventories ]]
	entity_data.inventories = {}
	--[[ Inventories are indexed from 1 to n, we don't care about their names. ]]
	for i = 1, entity.get_max_inventory_index() do
		if entity.get_inventory(i) ~= nil then
			entity_data.inventories[i] = clusterio_serialize.serialize_inventory(entity.get_inventory(i))
		end
	end

	return entity_data
end

return entity_serialize
