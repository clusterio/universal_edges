local clusterio_api = require("modules/clusterio/api")
local itertools = require("modules/universal_edges/itertools")

--[[
	Send fluid level to partner for balancing
]]
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

local function receive_transfers(edge, fluid_transfers)
	if fluid_transfers == nil then
		return {}
	end
	local fluid_response_transfers = {}
	for _offset, fluid_transfer in ipairs(fluid_transfers) do
		local link = (edge.linked_fluids or {})[fluid_transfer.offset]
		if not link then
			log("FATAL: received fluids for non-existant link at offset " .. fluid_transfer.offset)
			return
		end

		if not link.pipe then
			log("FATAL: received fluids for a link that does not have a pipe " .. fluid_transfer.offset)
			return
		end

		if fluid_transfer.amount ~= nil
			and fluid_transfer.name ~= nil
			and fluid_transfer.temperature ~= nil
		then
			local local_fluid = link.pipe.fluidbox[1]
			-- Make sure the fluid exists
			if local_fluid == nil then
				link.pipe.insert_fluid {
					name = fluid_transfer.name,
					amount = 1,
				}
				local_fluid = link.pipe.fluidbox[1]
			end
			local average = (fluid_transfer.amount + local_fluid.amount) / 2
			-- Weighted average temperature
			local average_temperature = (fluid_transfer.amount * fluid_transfer.temperature + local_fluid.amount * local_fluid.temperature) /
				(fluid_transfer.amount + local_fluid.amount)
			-- Only transfer balance in one direction - the partner will handle balancing the other way
			if average > local_fluid.amount then
				-- Send how much fluid we balanced as response
				fluid_response_transfers[#fluid_response_transfers + 1] = {
					offset = fluid_transfer.offset,
					name = fluid_transfer.name,
					amount_balanced = average - local_fluid.amount,
				}

				-- Update local fluid level
				local_fluid.name = fluid_transfer.name
				local_fluid.amount = average
				local_fluid.temperature = average_temperature
				link.pipe.fluidbox[1] = local_fluid
			end
		end
		if fluid_transfer.name and fluid_transfer.amount_balanced then
			-- The partner instance took some fluid to maintain balance, subtract that from the local storage
			link.pipe.remove_fluid {
				name = fluid_transfer.name,
				amount = fluid_transfer.amount_balanced,
			}
		end
	end
	return fluid_response_transfers
end

return {
	poll_links = poll_links,
	receive_transfers = receive_transfers,
}
