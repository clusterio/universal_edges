local util = require("modules/universal_edges/util")
local edge_util = require("modules/universal_edges/edge/util")

local belt_check = require("modules/universal_edges/edge/belt_check")
local remove_belt_link = require("modules/universal_edges/edge/remove_belt_link")

local fluid_check = require("modules/universal_edges/edge/fluid_check")
local remove_fluid_link = require("modules/universal_edges/edge/remove_fluid_link")

local power_check = require("modules/universal_edges/edge/power_check")
local remove_power_link = require("modules/universal_edges/edge/remove_power_link")

local remove_train_link = require("modules/universal_edges/edge/train/remove_train_link")

local function on_removed(entity)
	if entity.valid and util.is_transport_belt[entity.name] then
		local pos = { entity.position.x, entity.position.y }
		for id, edge in pairs(global.universal_edges.edges) do
			if edge.active and game.surfaces[edge_util.edge_get_local_target(edge).surface] == entity.surface then
				local offset = belt_check(pos, entity.direction, edge)
				if offset ~= nil then
					remove_belt_link(id, edge, offset, entity)
					break
				end
			end
		end
	end
	if entity.valid and util.is_pipe[entity.name] then
		local pos = { entity.position.x, entity.position.y }
		for id, edge in pairs(global.universal_edges.edges) do
			if edge.active and game.surfaces[edge_util.edge_get_local_target(edge).surface] == entity.surface then
				local offset = fluid_check(pos, entity.direction, edge)
				if offset ~= nil then
					remove_fluid_link(id, edge, offset, entity)
					break
				end
			end
		end
	end
	if entity.valid and entity.name == "substation" then
		local pos = { entity.position.x, entity.position.y }
		for id, edge in pairs(global.universal_edges.edges) do
			if edge.active and game.surfaces[edge_util.edge_get_local_target(edge).surface] == entity.surface then
				local offset = power_check(pos, edge)
				if offset ~= nil then
					remove_power_link(id, edge, offset, entity)
				end
			end
		end
	end
	if entity.valid and entity.name == "straight-rail" then
		local pos = { entity.position.x, entity.position.y }
		for id, edge in pairs(global.universal_edges.edges) do
			if edge.active and game.surfaces[edge_util.edge_get_local_target(edge).surface] == entity.surface then
				-- We can reuse power_check since rail is the same size as substation
				local offset = power_check(pos, edge)
				if offset ~= nil and edge.linked_trains[offset].is_input then
					remove_train_link(id, edge, offset, entity)
				end
			end
		end
	end
end

return on_removed
