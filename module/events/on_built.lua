local util = require("modules/universal_edges/util")

local function on_built(entity)
	if entity.valid and util.is_transport_belt[entity.name] then
		local pos = {entity.position.x, entity.position.y}
		for id, edge in pairs(global.edge_transports.edges) do
			if edge.active and game.surfaces[edge.surface] == entity.surface then
				local offset = belt_check(pos, entity.direction, edge)
				if offset then
					create_belt_link(id, edge, offset, entity)
					break
				end
			end
		end
	end
end

return on_built
