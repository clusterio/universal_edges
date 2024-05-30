local clusterio_api = require("modules/clusterio/api")
local itertools = require("modules/universal_edges/itertools")

local function poll_links(id, edge, ticks_left)
	if not edge.linked_fluids then
		return
	end

	if not edge.linked_fluids_state then
		edge.linked_fluids_state = {}
	end

	local fluid_transfers = {}
	for offset, link in itertools.partial_pairs(
		edge.linked_fluids, edge.linked_fluids_state, ticks_left
	) do
		local fluidbox = link.pipe.fluidbox

		if link.pipe.get_fluid_count() > 10 then
			fluid_transfers[#fluid_transfers + 1] = {
				offset = offset,
				name = fluidbox[1].name,
				amount = fluidbox[1].amount,
				temperature = fluidbox[1].temperature,
			}
		end
	end

	if #fluid_transfers > 0 then
		clusterio_api.send_json("universal_edges:transfer", {
			edge_id = id,
			fluid_transfers = fluid_transfers,
		})
	end
end

return {
	poll_links = poll_links,
}
