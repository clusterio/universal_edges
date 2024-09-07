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
			energy = local_energy + (link.lua_buffered_energy or 0),
		}
	end

	if #power_transfers > 0 then
		clusterio_api.send_json("universal_edges:transfer", {
			edge_id = id,
			power_transfers = power_transfers,
		})
	end

	-- Add power to the eei from the lua buffer to get smooth graphs
	for _, edge in pairs(global.universal_edges.edges) do
		if not edge.linked_power then
			goto continue
		end
		for _offset, link in pairs(edge.linked_power) do
			if not link then
				log("FATAL: Received power for non-existant link at offset " .. link.offset)
				goto continue2
			end
			if not link.eei then
				log("FATAL: received power for a link that does not have an eei " .. link.offset)
				goto continue2
			end
			if global.universal_edges.linked_power_update_tick ~= nil and link.lua_buffered_energy ~= nil and link.lua_buffered_energy > 0 then
				local ticks_until_next_frame = 5 +
					math.max(0,
						global.universal_edges.linked_power_update_tick +
						(global.universal_edges.linked_power_update_period or 60) - game.tick)
				link.eei.energy = link.eei.energy + link.lua_buffered_energy / ticks_until_next_frame
				link.lua_buffered_energy = math.max(0,
					link.lua_buffered_energy - link.lua_buffered_energy / ticks_until_next_frame)
			end
			::continue2::
		end
		::continue::
	end

    -- Balance links in the same power network
    local networks = {}
    for _, edge in pairs(global.universal_edges.edges) do
        if not edge.linked_power then
            goto continue
        end
        for _offset, link in pairs(edge.linked_power) do
            if not link then
                log("FATAL: Received power for non-existant link at offset " .. link.offset)
                goto continue2
            end
            if not link.eei then
                log("FATAL: received power for a link that does not have an eei " .. link.offset)
                goto continue2
            end
            if link.eei.valid then
                local network = link.eei.electric_network_id
                if not networks[network] then
                    networks[network] = {}
                end
                networks[network][#networks[network] + 1] = link
            end
            ::continue2::
        end
        ::continue::
    end
	for _id, network in pairs(networks) do
		local total_energy = 0
		for _, link in pairs(network) do
			total_energy = total_energy + link.eei.energy + (link.lua_buffered_energy or 0)
		end
		local average_energy = total_energy / #network
        for _, link in pairs(network) do
			link.eei.electric_buffer_size = math.max(link.eei.electric_buffer_size, link.eei.energy + (link.lua_buffered_energy or 0), average_energy)
			link.eei.energy = average_energy
		end
	end
end

local function receive_transfers(edge, power_transfers)
	if global.universal_edges.linked_power_update_tick then
		global.universal_edges.linked_power_update_period = game.tick - global.universal_edges.linked_power_update_tick
	end
	global.universal_edges.linked_power_update_tick = game.tick
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
			local remote_energy = power_transfer.energy
			local local_energy = eei.energy + (link.lua_buffered_energy or 0)
			local average = (remote_energy + local_energy) / 2
			local balancing_amount = math.abs(remote_energy - local_energy) / 2

			-- Only transfer balance in one direction - the partner will handle balancing the other way
			if average > local_energy then
				-- Send how much fluid we balanced as response
				power_response_transfers[#power_response_transfers + 1] = {
					offset = power_transfer.offset,
					amount_balanced = average - local_energy,
				}
				-- Update internal buffer
				link.lua_buffered_energy = average - eei.energy
			end

			-- Set dynamic buffer size
			eei.electric_buffer_size = math.max(balancing_amount * 6, 1000000, local_energy)
		end
		if power_transfer.amount_balanced then
			-- Partner balanced power, we need to remove to compensate
			link.eei.energy = math.max(0,
				(link.eei.energy + (link.lua_buffered_energy or 0)) - power_transfer.amount_balanced)
		end
		::continue::
	end
	return power_response_transfers
end

return {
	poll_links = poll_links,
	receive_transfers = receive_transfers,
}
