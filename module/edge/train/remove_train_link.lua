local clusterio_api = require("modules/clusterio/api")
local train_box = require("modules/universal_edges/edge/train/train_box")

local function remove_train_link(id, edge, offset, entity)
	train_box.remove_source(offset, edge, entity.surface)
	clusterio_api.send_json("universal_edges:edge_link_update", {
		type = "remove_train_link",
		edge_id = id,
		data = {
			offset = offset,
		}
	})
end

return remove_train_link
