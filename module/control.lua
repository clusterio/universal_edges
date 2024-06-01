local clusterio_api = require("modules/clusterio/api")
local vectorutil = require("vectorutil")

local edge_util = require("modules/universal_edges/edge/util")
local belt_box = require("modules/universal_edges/edge/belt_box")
local belt_link = require("modules/universal_edges/edge/belt_link")
local fluid_box = require("modules/universal_edges/edge/fluid_box")
local fluid_link = require("modules/universal_edges/edge/fluid_link")
local power_box = require("modules/universal_edges/edge/power_box")
local power_link = require("modules/universal_edges/edge/power_link")
local train_box = require("modules/universal_edges/edge/train/train_box")

local on_built = require("modules/universal_edges/events/on_built")
local on_removed = require("modules/universal_edges/events/on_removed")

--- Top level module table, contains event handlers and public methods
local universal_edges = {
	events = {},
	on_nth_tick = {},
}

local function setupGlobalData()
	local GLOBAL_VERSION = 1
	if global.universal_edges == nil
		or global.universal_edges.GLOBAL_VERSION == nil
		or global.universal_edges.GLOBAL_VERSION < GLOBAL_VERSION
	then
		-- Cleanup old global before resetting
		if global.universal_edges and global.universal_edges.debug_shapes then
			local debug_shapes = global.universal_edges.debug_shapes
			for index, id in ipairs(debug_shapes) do
				rendering.destroy(id)
				debug_shapes[index] = nil
			end
		end

		global.universal_edges = {
			edges = {},
			debug_shapes = {},
			config = {},
			GLOBAL_VERSION = GLOBAL_VERSION,
		}
	end
	global.universal_edges = global.universal_edges
end


local function debug_draw()
	local debug_shapes = global.universal_edges.debug_shapes
	for index, id in ipairs(debug_shapes) do
		rendering.destroy(id)
		debug_shapes[index] = nil
	end

	for id, edge in pairs(global.universal_edges.edges) do
		local edge_target
		if global.universal_edges.config.instance_id == edge.source.instanceId then
			edge_target = edge.source
		elseif global.universal_edges.config.instance_id == edge.target.instanceId then
			edge_target = edge.target
		else
			log("Edge with id " .. id .. " has invalid source/target")
			goto continue
		end
		local color = { 0, 1, 0 }
		if not edge.active then color = { 1, 0, 0 } end
		debug_shapes[#debug_shapes + 1] = rendering.draw_circle {
			color = color,
			radius = 0.25,
			width = 4,
			filled = false,
			target = edge_target.origin,
			surface = edge_target.surface,
		}

		debug_shapes[#debug_shapes + 1] = rendering.draw_text {
			color = { r = 1, g = 1, b = 1 },
			text = id .. " " .. (edge.ready and "ready" or "not ready") .. (edge.active and ", active" or ", inactive"),
			target = vectorutil.vec2_add(edge_target.origin, { 0.4, -0.8 }),
			surface = edge_target.surface,
		}

		local dir = vectorutil.dir_to_vec(edge_target.direction)
		debug_shapes[#debug_shapes + 1] = rendering.draw_line {
			color = color,
			width = 4,
			from = vectorutil.vec2_add(edge_target.origin, vectorutil.vec2_smul(dir, 0.25)),
			to = vectorutil.vec2_add(edge_target.origin, vectorutil.vec2_smul(dir, edge.length - 0.5)),
			surface = edge_target.surface,
		}
		::continue::
	end
end

function universal_edges.set_config(config)
	if global.universal_edges.config == nil then global.universal_edges.config = {} end
	global.universal_edges.config.instance_id = config.instance_id
end

local function cleanup()
	-- Filter out edges that do not have source or target on this instance
	for id, edge in pairs(global.universal_edges.edges) do
		if tostring(global.universal_edges.config.instance_id) ~= tostring(edge.source.instanceId)
			and tostring(global.universal_edges.config.instance_id) ~= tostring(edge.target.instanceId)
		then
			global.universal_edges.edges[id] = nil
		end
	end
end

-- Synchronize edge configuration and status
function universal_edges.edge_update(edge_id, edge_json)
	log("Updating edge " .. edge_id)
	local active_status_has_changed = false
	if edge_id == nil or edge_json == nil then return end
	local edge = game.json_to_table(edge_json)
	if edge == nil then return end
	if edge.isDeleted then
		game.print("Deleting edge " .. edge_id)
		-- Perform cleanup, remove edge
		global.universal_edges.edges[edge_id] = nil
		debug_draw()
		return
	end
	if global.universal_edges.edges[edge_id] == nil then
		game.print("Adding new edge " .. edge_id)
		edge.ready = false
		global.universal_edges.edges[edge_id] = edge
		active_status_has_changed = true
	else
		-- Do a partial update
		local old_edge = global.universal_edges.edges[edge_id]
		old_edge.updatedAtMs = edge.updatedAtMs
		old_edge.source = edge.source
		old_edge.target = edge.target
		old_edge.length = edge.length
		if old_edge.active ~= edge.active then
			active_status_has_changed = true
		end
		old_edge.active = edge.active
	end

	if active_status_has_changed then
		if not edge.active then
			if edge.linked_belts then
				for _offset, link in pairs(edge.linked_belts) do
					if link.is_input and link.chest and link.chest.valid then
						local inventory = link.chest.get_inventory(defines.inventory.chest)
						inventory.set_bar(1) -- Block new inputs
					end
				end
			end
		else
			if edge.linked_belts then
				for _offset, link in pairs(edge.linked_belts) do
					if not link.is_input then
						link.start_index = 1
					end
				end
			end
		end
	end

	debug_draw()
	cleanup()
end

-- Synchronize connector placement with partner
function universal_edges.edge_link_update(json)
	local update = game.json_to_table(json)
	if update == nil then return end

	local data = update.data
	local edge = global.universal_edges.edges[update.edge_id]
	if not edge then
		log("Got update for unknown edge " .. serpent.line(update))
		return
	end
	local surface = game.surfaces[edge_util.edge_get_local_target(edge).surface]
	if not surface then
		log("Invalid surface for edge id " .. update.edge_id)
	end

	if update.type == "create_belt_link" then
		belt_box.create(data.offset, edge, data.is_input, data.belt_type, surface)
	elseif update.type == "remove_belt_link" then
		belt_box.remove(data.offset, edge, surface)
	elseif update.type == "create_fluid_link" then
		fluid_box.create(data.offset, edge, surface)
	elseif update.type == "remove_fluid_link" then
		fluid_box.remove(data.offset, edge, surface)
	elseif update.type == "create_power_link" then
		power_box.create(data.offset, edge, surface)
	elseif update.type == "remove_power_link" then
		power_box.remove(data.offset, edge, surface)
	elseif update.type == "create_train_link" then
		train_box.create_destination(data.offset, edge, surface, update)
	elseif update.type == "remove_train_link" then
		train_box.remove_destination(data.offset, edge, surface)
	else
		log("Unknown link update: " .. serpent.line(update.type))
	end
end

-- Receive fluid from partner over RCON
function universal_edges.transfer(json)
	local data = game.json_to_table(json)
	if data == nil then return end

	local edge = global.universal_edges.edges[data.edge_id]
	if not edge then
		rcon.print("invalid edge")
		return
	end

	local belt_response_transfers = {}
	local fluid_response_transfers = {}
	local power_response_transfers = {}
	if data.belt_transfers then
		for _offset, belt_transfer in ipairs(data.belt_transfers) do
			local link = (edge.linked_belts or {})[belt_transfer.offset]
			if not link then
				log("FATAL: recevied items for non-existant link at offset " .. belt_transfer.offset)
				return
			end

			if link.is_input and belt_transfer.set_flow ~= nil then
				local inventory = link.chest.get_inventory(defines.inventory.chest)
				if belt_transfer.set_flow then
					inventory.set_bar()
				else
					inventory.set_bar(1)
				end
			end

			if belt_transfer.item_stacks then
				local update = belt_link.push_belt_link(belt_transfer.offset, link, belt_transfer.item_stacks)
				if update then
					belt_response_transfers[#belt_response_transfers + 1] = update
				end
			end
		end
	end

	if data.fluid_transfers then
		for _offset, fluid_transfer in ipairs(data.fluid_transfers) do
			local link = (edge.linked_fluids or {})[fluid_transfer.offset]
			if not link then
				log("FATAL: received fluids for non-existant link at offset " .. fluid_transfer.offset)
				return
			end

			if not link.pipe then
				log("FATAL: received fluids for a link that does not have a pipe " .. fluid_transfer.offset)
				return
			end

			if fluid_transfer.amount ~= nil
				and fluid_transfer.name ~= nil
				and fluid_transfer.temperature ~= nil
			then
				local local_fluid = link.pipe.fluidbox[1]
				-- Make sure the fluid exists
				if local_fluid == nil then
					link.pipe.insert_fluid {
						name = fluid_transfer.name,
						amount = 1,
					}
					local_fluid = link.pipe.fluidbox[1]
				end
				local average = (fluid_transfer.amount + local_fluid.amount) / 2
				-- Weighted average temperature
				local average_temperature = (fluid_transfer.amount * fluid_transfer.temperature + local_fluid.amount * local_fluid.temperature) /
					(fluid_transfer.amount + local_fluid.amount)
				-- Only transfer balance in one direction - the partner will handle balancing the other way
				if average > local_fluid.amount then
					-- Send how much fluid we balanced as response
					fluid_response_transfers[#fluid_response_transfers + 1] = {
						offset = fluid_transfer.offset,
						name = fluid_transfer.name,
						amount_balanced = average - local_fluid.amount,
					}

					-- Update local fluid level
					local_fluid.name = fluid_transfer.name
					local_fluid.amount = average
					local_fluid.temperature = average_temperature
					link.pipe.fluidbox[1] = local_fluid
				end
			end
			if fluid_transfer.name and fluid_transfer.amount_balanced then
				-- The partner instance took some fluid to maintain balance, subtract that from the local storage
				link.pipe.remove_fluid {
					name = fluid_transfer.name,
					amount = fluid_transfer.amount_balanced,
				}
			end
		end
	end

	if data.power_transfers then
		for _offset, power_transfer in ipairs(data.power_transfers) do
			local link = (edge.linked_power or {})[power_transfer.offset]
			if not link then
				log("FATAL: Received power for non-existant link at offset " .. power_transfer.offset)
				return
			end
			if not link.eei then
				log("FATAL: received power for a link that does not have an eei " .. power_transfer.offset)
				return
			end

			if power_transfer.energy then
				local eei = link.eei
				local eei_pos = eei.position
				local remote_energy = power_transfer.energy
				local local_energy = eei.energy
				local buffer_size = eei.electric_buffer_size
				local surface = eei.surface
				local average = (remote_energy + local_energy) / 2

				-- Only transfer balance in one direction - the partner will handle balancing the other way
				if average > local_energy then
					-- Send how much fluid we balanced as response
					power_response_transfers[#power_response_transfers + 1] = {
						offset = power_transfer.offset,
						amount_balanced = average - local_energy,
					}
					-- Update accumulator
					eei.energy = average
				end

				--[[
					Figure out correct type of eei to use. We have 3 eei variants
					- tertiary - Acts as accumulator, use when we are low on power
					- secondary-input - Acts as roboport, use when good on power but EEI is low
					- secondary-output - Acts as generator, use when good on power and EEI is full
				]]
				local fill_percent = (local_energy / buffer_size) * 100
				local eei_entity_to_use
				if (link.charge_sensor.energy / link.charge_sensor.electric_buffer_size) < 0.1 and fill_percent > 10 then
					-- Accumulators are empty, emergency charge accumulators if we can
					eei_entity_to_use = "ue_eei_output"
				else
					if fill_percent < 20 then
						-- Transition to ue_eei_input to scavenge power from accumulators
						eei_entity_to_use = "ue_eei_input"
					elseif fill_percent < 80 then
						eei_entity_to_use = "ue_eei_tertiary"
					else
						-- Transition to ue_eei_output to store power in accumulators
						eei_entity_to_use = "ue_eei_output"
					end
				end

				-- Swap entity
				if eei_entity_to_use ~= eei.name then
					local energy_before = eei.energy
					eei.destroy()
					link.eei = surface.create_entity {
						name = eei_entity_to_use,
						position = eei_pos,
						create_build_effect_smoke = false,
						spawn_decorations = false,
					}
					eei = link.eei
					eei.energy = energy_before
				end
			end
			if power_transfer.amount_balanced then
				-- Partner balanced power, we need to remove to compensate
				link.eei.energy = math.max(0, link.eei.energy - power_transfer.amount_balanced)
			end
		end
	end

	local transfer = {
		edge_id = data.edge_id,
	}
	if #belt_response_transfers > 0 then
		transfer.belt_transfers = belt_response_transfers
	end
	if #fluid_response_transfers > 0 then
		transfer.fluid_transfers = fluid_response_transfers
	end
	if #power_response_transfers > 0 then
		transfer.power_transfers = power_response_transfers
	end
	if #belt_response_transfers + #fluid_response_transfers + #power_response_transfers > 0 then
		clusterio_api.send_json("universal_edges:transfer", transfer)
	end
end

universal_edges.events = {
	[clusterio_api.events.on_server_startup] = function(_event)
		log("Universal edges startup")
		setupGlobalData()
		if not global.universal_edges.config.ticks_per_edge then
			global.universal_edges.config.ticks_per_edge = 15
		end
	end,

	[defines.events.on_tick] = function(_event)
		local ticks_left = -game.tick % global.universal_edges.config.ticks_per_edge
		local id = global.universal_edges.current_edge_id
		if id == nil then
			id = next(global.universal_edges.edges)
			if id == nil then
				return -- no edges
			end
			global.universal_edges.current_edge_id = id
		end
		local edge = global.universal_edges.edges[id]

		-- edge may have been removed while iterating over it
		if edge == nil then
			global.universal_edges.current_edge_id = nil
			return
		end

		-- Attempt to send items and fluids to partner
		if edge.active then
			belt_link.poll_links(id, edge, ticks_left)
			fluid_link.poll_links(id, edge, ticks_left)
			power_link.poll_links(id, edge, ticks_left)
		end

		if ticks_left == 0 then
			global.universal_edges.current_edge_id = next(global.universal_edges.edges, id)
		end
	end,

	[defines.events.on_built_entity] = function(event) on_built(event.created_entity) end,
	[defines.events.on_robot_built_entity] = function(event) on_built(event.created_entity) end,
	[defines.events.script_raised_built] = function(event) on_built(event.entity) end,
	[defines.events.script_raised_revive] = function(event) on_built(event.entity) end,

	[defines.events.on_player_mined_entity] = function(event) on_removed(event.entity) end,
	[defines.events.on_robot_mined_entity] = function(event) on_removed(event.entity) end,
	[defines.events.on_entity_died] = function(event) on_removed(event.entity) end,
	[defines.events.script_raised_destroy] = function(event) on_removed(event.entity) end,
}


return universal_edges
