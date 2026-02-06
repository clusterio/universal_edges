local clusterio_api = require("modules/clusterio/api")
local belt_box = require("modules/universal_edges/edge/belt_box")

---@param edge_id string
---@param edge UniversalEdge
---@param offset number
---@param entity LuaEntity
local function remove_belt_link(edge_id, edge, offset, entity)
	belt_box.remove(offset, edge, entity.surface)
	clusterio_api.send_json("universal_edges:edge_link_update", {
		type = "remove_belt_link",
		edge_id = edge_id,
		data = {
			offset = offset,
		}
	})
end

return remove_belt_link
