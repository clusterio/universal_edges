local clusterio_api = require("modules/clusterio/api")
local vectorutil = require("vectorutil")

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
		if global.universal_edges.config.instance_id ~= edge.source.instance_id
			and global.universal_edges.config.instance_id ~= edge.target.instance_id
		then
			global.universal_edges.edges[id] = nil
		end
	end
end

function universal_edges.edge_update(edge_id, edge_json)
	log("Updating edge " .. edge_id)
	if edge_id == nil or edge_json == nil then return end
	local edge = game.json_to_table(edge_json)
	if edge == nil then return end
	if global.universal_edges.edges[edge_id] == nil then
		game.print("Adding new edge " .. edge_id)
		edge.ready = false
		global.universal_edges.edges[edge_id] = edge
		debug_draw()
		return
	end
	if edge.isDeleted then
		game.print("Deleting edge " .. edge_id)
		-- Perform cleanup, remove edge
		global.universal_edges.edges[edge_id] = nil
		debug_draw()
		return
	end
	-- Do a partial update
	local old_edge = global.universal_edges.edges[edge_id]
	old_edge.updatedAtMs = edge.updatedAtMs
	old_edge.source = edge.source
	old_edge.target = edge.target
	old_edge.length = edge.length
	old_edge.active = edge.active
	debug_draw()
	cleanup()
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
