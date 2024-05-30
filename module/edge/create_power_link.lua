local clusterio_api = require("modules/clusterio/api")
local power_box = require("modules/universal_edges/edge/power_box")

local function create_power_link(id, edge, offset, entity)
	power_box.create(offset, edge, entity.surface)
	clusterio_api.send_json("universal_edges:edge_link_update", {
		type = "create_power_link",
		edge_id = id,
		data = {
			offset = offset,
		},
	})
end

return create_power_link
