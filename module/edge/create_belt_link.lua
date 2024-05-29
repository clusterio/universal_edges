local belt_box = require("modules/universal_edges/edge/belt_box")
local edge_util = require("modules/universal_edges/edge/util")

local function create_belt_link(id, edge, offset, entity)
	local edge_target = edge_util.edge_get_local_target(edge)
	local is_input = entity.direction == edge_target.direction
	belt_box.create(offset, edge, is_input, entity.name, entity.surface)
end

return create_belt_link
