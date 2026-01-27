local clusterio_api = require("modules/clusterio/api")
local itertools = require("modules/universal_edges/itertools")

local function get_network_charge(link)
	local powerpole = link.powerpole
	if not powerpole or not powerpole.valid then
		return nil, nil
	end
	local energy = powerpole.electric_network_accumulator_energy
	local capacity = powerpole.electric_network_accumulator_capacity
	if energy == nil or capacity == nil then
		return nil, nil
	end
	return energy, capacity
end

--[[
	Send our current network charge to our partner for balancing
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
		local energy, capacity = get_network_charge(link)
		if energy ~= nil and capacity ~= nil then
			power_transfers[#power_transfers + 1] = {
				offset = offset,
				energy = energy,
				capacity = capacity,
			}
		end
	end

	if #power_transfers > 0 then
		clusterio_api.send_json("universal_edges:transfer", {
			edge_id = id,
			power_transfers = power_transfers,
		})
	end
end

local function receive_transfers(edge, power_transfers)
	if power_transfers == nil then
		return {}
	end
	local power_response_transfers = {}
	for _offset, power_transfer in ipairs(power_transfers) do
		local link = (edge.linked_power or {})[power_transfer.offset]
		if not link then
			log("FATAL: Received power for non-existant link at offset " .. power_transfer.offset)
			goto continue
		end

		if power_transfer.energy ~= nil and power_transfer.capacity ~= nil then
			local local_energy, local_capacity = get_network_charge(link)
			if local_energy ~= nil and local_capacity ~= nil then
				local remote_energy = power_transfer.energy
				local remote_capacity = power_transfer.capacity
				local total_capacity = local_capacity + remote_capacity
				if total_capacity > 0 then
					local target_charge = (local_energy + remote_energy) / total_capacity
					local target_local_energy = target_charge * local_capacity

					-- Only transfer balance in one direction - the partner will handle balancing the other way
					if target_local_energy > local_energy then
						local requested = target_local_energy - local_energy
						local powerpole = link.powerpole
						if powerpole and powerpole.valid then
							local max_add = requested
							if local_capacity > 0 then
								max_add = math.max(0, math.min(requested, local_capacity - local_energy))
							end
							if max_add > 0 then
								powerpole.electric_network_accumulator_energy = local_energy + max_add
								power_response_transfers[#power_response_transfers + 1] = {
									offset = power_transfer.offset,
									amount_balanced = max_add,
								}
							end
						end
					end
				end
			end
		end
		if power_transfer.amount_balanced then
			local local_energy, local_capacity = get_network_charge(link)
			local powerpole = link.powerpole
			if local_energy ~= nil and local_capacity ~= nil and powerpole and powerpole.valid then
				local new_energy = math.max(0, local_energy - power_transfer.amount_balanced)
				powerpole.electric_network_accumulator_energy = new_energy
			end
		end
		::continue::
	end
	return power_response_transfers
end

return {
	poll_links = poll_links,
	receive_transfers = receive_transfers,
}
