local clusterio_api = require("modules/clusterio/api")
local vectorutil = require("vectorutil")

local edge_util = require("modules/universal_edges/edge/util")
local belt_box = require("modules/universal_edges/edge/belt_box")
local belt_link = require("modules/universal_edges/edge/belt_link")
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

function universal_edges.edge_link_update(json)
	local update = game.json_to_table(json)
	if update == nil then return end

	local data = update.data
	local edge = global.universal_edges.edges[update.edge_id]
	if not edge then
		log("Got update for unknown edge " .. serpent.line(update))
		log("Unknown edge update:"..update.edge_id)
		log("Edges: "..serpent.block(global.universal_edges.edges))
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
	else
		log("Unknown link update: " .. serpent.line(update.type))
	end
end

function universal_edges.transfer(json)
	local data = game.json_to_table(json)
	if data == nil then return end

	local edge = global.universal_edges.edges[data.edge_id]
	if not edge then
		rcon.print("invalid edge")
		return
	end

	local response_transfers = {}
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
					response_transfers[#response_transfers + 1] = update
				end
			end
		end
	end

	if #response_transfers > 0 then
		clusterio_api.send_json("universal_edges:transfer", {
			edge_id = data.edge_id,
			belt_transfers = response_transfers,
		})
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

		if edge.active then
			belt_link.poll_links(id, edge, ticks_left)
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
