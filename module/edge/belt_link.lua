local clusterio_api = require("modules/clusterio/api")
local serialize = require("modules/clusterio/serialize")
local itertools = require("modules/universal_edges/itertools")

local function poll_input_belt_link(offset, link)
	if not link.chest or not link.chest.valid then
		return
	end

	local inventory = link.chest.get_inventory(defines.inventory.chest)
	local item_stacks = {}
	for index = 1, #inventory do
		local slot = inventory[index]
		if slot.valid_for_read then
			local stack = {}
			serialize.serialize_item_stack(slot, stack)
			item_stacks[#item_stacks + 1] = stack
			slot.clear()
		elseif inventory.is_empty() then
			break
		end
	end

	if #item_stacks > 0 then
		return {
			offset = offset,
			item_stacks = item_stacks
		}
	end
end

local function poll_output_belt_link(offset, link)
	if not link.chest or not link.chest.valid then
		return
	end

	local inventory = link.chest.get_inventory(defines.inventory.chest)
	if link.start_index and not inventory[link.start_index].valid_for_read then
		link.start_index = nil
		return {
			offset = offset,
			set_flow = true,
		}
	end
end

-- Shift the item in the inventory up by the given count of slots
local function shift_inventory(inventory, shift)
	if inventory.is_empty() then
		return shift, shift
	end

	local _, current_index = inventory.find_empty_stack()
	if not current_index then
		return 0, #inventory
	end

	current_index = current_index - 1
	local current_shift = 1
	if current_shift < shift then
		for index = current_index + current_shift, #inventory do
			if inventory[index].valid_for_read then
				break
			end
			current_shift = index - current_index
			if current_shift >= shift then
				break
			end
		end
	end
	local shift_top = current_index + shift

	-- Shift up the item stacks
	while current_index >= 1 do
		inventory[current_index + current_shift].transfer_stack(inventory[current_index])
		current_index = current_index - 1
	end

	return current_shift, shift_top
end

local function push_belt_link(offset, link, item_stacks)
	if not link.chest or not link.chest.valid then
		log("FATAL: recevied items but target chest does not exist at off " .. offset)
		return
	end

	local inventory = link.chest.get_inventory(defines.inventory.chest)
	local item_stacks_count = #item_stacks
	local space, top_index = shift_inventory(inventory, item_stacks_count)
	for index=1, space do
		local slot = inventory[space - index + 1]
		serialize.deserialize_item_stack(slot, item_stacks[index])
		item_stacks[index] = nil
	end

	if item_stacks_count > space then
		for index=1, space - item_stacks_count do
			item_stacks[index] = item_stacks[index + space]
		end

		link.start_index = math.floor(#inventory / 2 + 1)
		log("FATAL: item stacks left over!")

	elseif not link.start_index and top_index > item_stacks_count * 2 + 2 then
		link.start_index = math.min(item_stacks_count + 2, #inventory)
	end

	if link.start_index then
		return {
			offset = offset,
			set_flow = false,
		}
	end
end

local function poll_links(id, edge, ticks_left)
	if not edge.linked_belts then
		return
	end

	if not edge.linked_belts_state then
		edge.linked_belts_state = {}
	end

	local belt_transfers = {}
	for offset, link in itertools.partial_pairs(
		edge.linked_belts, edge.linked_belts_state, ticks_left
	) do
		local update
		if link.is_input then
			update = poll_input_belt_link(offset, link)
		else
			update = poll_output_belt_link(offset, link)
		end

		if update then
			belt_transfers[#belt_transfers + 1] = update
		end
	end

	if #belt_transfers > 0 then
		clusterio_api.send_json("universal_edges:transfer", {
			edge_id = id,
			belt_transfers = belt_transfers,
		})
	end
end

return {
	push_belt_link = push_belt_link,
	poll_links = poll_links,
}
