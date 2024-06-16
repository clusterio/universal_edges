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
		if not link.eei then
			log("FATAL: received power for a link that does not have an eei " .. power_transfer.offset)
			goto continue
		end

		if power_transfer.energy then
			local eei = link.eei
			local eei_pos = eei.position
			local remote_energy = power_transfer.energy
			local local_energy = eei.energy
			local buffer_size = eei.electric_buffer_size
			local surface = eei.surface
			local average = (remote_energy + local_energy) / 2

			-- Only transfer balance in one direction - the partner will handle balancing the other way
			if average > local_energy then
				-- Send how much fluid we balanced as response
				power_response_transfers[#power_response_transfers + 1] = {
					offset = power_transfer.offset,
					amount_balanced = average - local_energy,
				}
				-- Update accumulator
				eei.energy = average
			end

			--[[
				Figure out correct type of eei to use. We have 3 eei variants
				- tertiary - Acts as accumulator, use when we are low on power
				- secondary-input - Acts as roboport, use when good on power but EEI is low
				- secondary-output - Acts as generator, use when good on power and EEI is full
			]]
			local fill_percent = (local_energy / buffer_size) * 100
			local eei_entity_to_use
			if (link.charge_sensor.energy / link.charge_sensor.electric_buffer_size) < 0.1 and fill_percent > 10 then
				-- Accumulators are empty, emergency charge accumulators if we can
				eei_entity_to_use = "ue_eei_output"
			else
				if fill_percent < 20 then
					-- Transition to ue_eei_input to scavenge power from accumulators
					eei_entity_to_use = "ue_eei_input"
				elseif fill_percent < 80 then
					eei_entity_to_use = "ue_eei_tertiary"
				else
					-- Transition to ue_eei_output to store power in accumulators
					eei_entity_to_use = "ue_eei_output"
				end
			end

			-- Swap entity
			if eei_entity_to_use ~= eei.name then
				local energy_before = eei.energy
				eei.destroy()
				link.eei = surface.create_entity {
					name = eei_entity_to_use,
					position = eei_pos,
					create_build_effect_smoke = false,
					spawn_decorations = false,
				}
				eei = link.eei
				eei.energy = energy_before
			end
		end
		if power_transfer.amount_balanced then
			-- Partner balanced power, we need to remove to compensate
			link.eei.energy = math.max(0, link.eei.energy - power_transfer.amount_balanced)
		end
		::continue::
	end
	return power_response_transfers
end

return {
	poll_links = poll_links,
	receive_transfers = receive_transfers,
}
