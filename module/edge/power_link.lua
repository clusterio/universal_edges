local clusterio_api = require("modules/clusterio/api")
local itertools = require("modules/universal_edges/itertools")

--[[
	Send our current EEI charge to our partner for balancing
]]
local function poll_links(id, edge, ticks_left)
	if not edge.linked_power then
		return
	end

	if not edge.linked_power_state then
		edge.linked_power_state = {}
	end

	local power_transfers = {}
	for offset, link in itertools.partial_pairs(
		edge.linked_power, edge.linked_power_state, ticks_left
	) do
		local local_energy = link.eei.energy

		power_transfers[#power_transfers + 1] = {
			offset = offset,
			energy = local_energy,
		}
	end

	if #power_transfers > 0 then
		clusterio_api.send_json("universal_edges:transfer", {
			edge_id = id,
			power_transfers = power_transfers,
		})
	end
end

return {
	poll_links = poll_links,
}
