local clusterio_api = require("modules/clusterio/api")
local vectorutil = require("vectorutil")

--- Top level module table, contains event handlers and public methods
local universal_edges = {
	events = {},
	on_nth_tick = {},
}

--- global is 'synced' between players, you should use your plugin name to avoid conflicts
-- setupGlobalData should either be removed or called during clusterio_api.events.on_server_startup
local globalData = {}
local function setupGlobalData()
	if global["universal_edges"] == nil then
		global["universal_edges"] = {
			edges = {},
			debug_shapes = {},
			config = {},
		}
	end
	globalData = global["universal_edges"]
end


local function debug_draw()
	local debug_shapes = global.universal_edges.debug_shapes
	for index, id in ipairs(debug_shapes) do
		rendering.destroy(id)
		debug_shapes[index] = nil
	end

	for id, edge in pairs(globalData.edges) do
		local edge_target
		if globalData.config.instance_id == edge.source.instanceId then
			edge_target = edge.source
		elseif globalData.config.instance_id == edge.target.instanceId then
			edge_target = edge.target
		else
			log("Edge with id "..id.." has invalid source/target")
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
	if globalData.config == nil then globalData.config = {} end
	globalData.config.instance_id = config.instance_id
end

function universal_edges.edge_update(edge_id, edge_json)
	log("Updating edge " .. edge_id)
	if edge_id == nil or edge_json == nil then return end
	local edge = game.json_to_table(edge_json)
	if edge == nil then return end
	if globalData.edges[edge_id] == nil then
		edge.ready = false
		globalData.edges[edge_id] = edge
		debug_draw()
		return
	end
	if edge.isDeleted then
		-- Perform cleanup, remove edge
		globalData.edges[edge_id] = nil
		debug_draw()
		return
	end
	-- Do a partial update
	local old_edge = globalData.edges[edge_id]
	old_edge.updatedAtMs = edge.updatedAtMs
	old_edge.source = edge.source
	old_edge.target = edge.target
	old_edge.length = edge.length
	old_edge.active = edge.active
	debug_draw()
end

--- Clusterio provides a few custom events, on_server_startup is the most useful and should be used in place of on_load
universal_edges.events[clusterio_api.events.on_server_startup] = function(event)
	log("Universal edges startup")
	setupGlobalData()
end

--- Factorio events are accessible through defines.events, you can have one handler per event per module
universal_edges.events[defines.events.on_player_crafted_item] = function(event)
	game.print(game.table_to_json(event))
	clusterio_api.send_json("universal_edges-plugin_example_ipc", {
		tick = game.tick, player_name = game.get_player(event.player_index).name
	})
end

return universal_edges
