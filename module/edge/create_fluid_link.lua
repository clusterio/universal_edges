local clusterio_api = require("modules/clusterio/api")
local fluid_box = require("modules/universal_edges/edge/fluid_box")

local function create_fluid_link(id, edge, offset, entity)
	fluid_box.create(offset, edge, entity.surface)
	clusterio_api.send_json("universal_edges:edge_link_update", {
		type = "create_fluid_link",
		edge_id = id,
		data = {
			offset = offset,
			belt_type = "pipe",
		},
	})
end

return create_fluid_link
