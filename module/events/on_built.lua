local util = require("modules/universal_edges/util")
local edge_util = require("modules/universal_edges/edge/util")
local belt_check = require("modules/universal_edges/edge/belt_check")
local create_belt_link = require("modules/universal_edges/edge/create_belt_link")

local function on_built(entity)
	if entity.valid and util.is_transport_belt[entity.name] then
		local pos = { entity.position.x, entity.position.y }
		for id, edge in pairs(global.universal_edges.edges) do
			if edge.active and game.surfaces[edge_util.edge_get_local_target(edge).surface] == entity.surface then
				local offset = belt_check(pos, entity.direction, edge)
				if offset ~= nil then
					create_belt_link(id, edge, offset, entity)
					break
				end
			end
		end
	end
end

return on_built
