local clusterio_api = require("modules/clusterio/api")
local belt_box = require("modules/universal_edges/edge/belt_box")
local edge_util = require("modules/universal_edges/edge/util")

local function create_belt_link(id, edge, offset, entity)
	local edge_target = edge_util.edge_get_local_target(edge)
	local is_input = entity.direction == edge_target.direction
	belt_box.create(offset, edge, is_input, entity.name, entity.surface)
	clusterio_api.send_json("universal_edges:edge_link_update", {
		type = "create_belt_link",
		edge_id = id,
		data = {
			offset = offset,
			is_input = not is_input,
			belt_type = entity.name,
		},
	})

end

return create_belt_link
