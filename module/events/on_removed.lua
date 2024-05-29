local util = require("modules/universal_edges/util")
local edge_util = require("modules/universal_edges/edge/util")
local belt_check = require("modules/universal_edges/edge/belt_check")
local remove_belt_link = require("modules/universal_edges/edge/remove_belt_link")

local function on_removed(entity)
	if entity.valid and util.is_transport_belt[entity.name] then
		local pos = {entity.position.x, entity.position.y}
		for id, edge in pairs(global.universal_edges.edges) do
			if game.surfaces[edge_util.edge_get_local_target(edge).surface] == entity.surface then
				local offset = belt_check(pos, entity.direction, edge)
				if offset then
					remove_belt_link(id, edge, offset, entity)
					break
				end
			end
		end
	end
end

return on_removed
