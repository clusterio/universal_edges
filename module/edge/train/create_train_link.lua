local clusterio_api = require("modules/clusterio/api")
local train_box = require("modules/universal_edges/edge/train/train_box")

---@param edge_id string
---@param edge UniversalEdge
---@param offset number
---@param entity LuaEntity
local function create_train_link(edge_id, edge, offset, entity)
	local data = train_box.create_source(offset, edge, entity.surface)
	if data then
		clusterio_api.send_json("universal_edges:edge_link_update", {
			type = "create_train_link",
			edge_id = edge_id,
			data = {
				offset = offset,
				parking_area_size = data.parking_area_size
			},
		})
	end
end

return create_train_link
