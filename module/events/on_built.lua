local util = require("modules/universal_edges/util")
local edge_util = require("modules/universal_edges/edge/util")

local belt_check = require("modules/universal_edges/edge/belt_check")
local create_belt_link = require("modules/universal_edges/edge/create_belt_link")

local fluid_check = require("modules/universal_edges/edge/fluid_check")
local create_fluid_link = require("modules/universal_edges/edge/create_fluid_link")

local power_check = require("modules/universal_edges/edge/power_check")
local create_power_link = require("modules/universal_edges/edge/create_power_link")

local create_train_link = require("modules/universal_edges/edge/train/create_train_link")
local pathfinder_events = require("modules/universal_edges/edge/train/pathfinding/events")

local function on_built(entity)
	if entity.valid and util.is_transport_belt[entity.name] then
		local pos = { entity.position.x, entity.position.y }
		for id, edge in pairs(storage.universal_edges.edges) do
			if edge.active and game.surfaces[edge_util.edge_get_local_target(edge).surface] == entity.surface then
				local offset = belt_check(pos, entity.direction, edge)
				if offset ~= nil then
					create_belt_link(id, edge, offset, entity)
					break
				end
			end
		end
	end
	if entity.valid and util.is_pipe[entity.name] then
		local pos = { entity.position.x, entity.position.y }
		for id, edge in pairs(storage.universal_edges.edges) do
			if edge.active and game.surfaces[edge_util.edge_get_local_target(edge).surface] == entity.surface then
				local offset = fluid_check(pos, entity.direction, edge)
				if offset ~= nil then
					create_fluid_link(id, edge, offset, entity)
				end
			end
		end
	end
	if entity.valid and entity.name == "substation" then
		local pos = { entity.position.x, entity.position.y }
		for id, edge in pairs(storage.universal_edges.edges) do
			if edge.active and game.surfaces[edge_util.edge_get_local_target(edge).surface] == entity.surface then
				local offset = power_check(pos, edge)
				if offset ~= nil then
					create_power_link(id, edge, offset, entity)
				end
			end
		end
	end
	if entity.valid and entity.name == "straight-rail" then
		local pos = { entity.position.x, entity.position.y }
		for id, edge in pairs(storage.universal_edges.edges) do
			if edge.active and game.surfaces[edge_util.edge_get_local_target(edge).surface] == entity.surface then
				-- We can reuse power_check since rail is the same size as substation
				local offset = power_check(pos, edge)
				if offset ~= nil then
					create_train_link(id, edge, offset, entity)
				end
			end
		end
	end
	if entity.valid then
		pathfinder_events.on_built(entity)
	end
end

return on_built
