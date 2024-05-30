local clusterio_api = require("modules/clusterio/api")
local power_box = require("modules/universal_edges/edge/power_box")

local function remove_power_link(id, edge, offset, entity)
	power_box.remove(offset, edge, entity.surface)
	clusterio_api.send_json("universal_edges:edge_link_update", {
		type = "remove_power_link",
		edge_id = id,
		data = {
			offset = offset,
		}
	})
end

return remove_power_link
