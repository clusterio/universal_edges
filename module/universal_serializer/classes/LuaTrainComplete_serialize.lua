local LuaEntity_serialize = require("modules/universal_edges/universal_serializer/classes/LuaEntity_serialize")
local LuaTrain_serialize = require("modules/universal_edges/universal_serializer/classes/LuaTrain_serialize")

-- Serializes a complete LuaTrain object, including rolling stock
---@param train_entity LuaEntity
---@param carriages table<number, LuaEntity>
---@return table
local function LuaTrainComplete_serialize(train_entity, carriages)
	local count = 0
	local LuaTrain = train_entity.train ---@cast LuaTrain -nil
	local train_data = {
		train = LuaTrain_serialize(LuaTrain), -- metadata
		carriages = {}, -- entities
	}

	local ordered_carriages = carriages or LuaTrain.carriages
	for _, carriage in ipairs(ordered_carriages) do
		local serialized_carriage = LuaEntity_serialize(carriage)
		---@diagnostic disable-next-line: inject-field
		serialized_carriage.train = nil -- Don't serialize redundant LuaTrain metadata
		-- Add passenger data
		if carriage.get_driver() and carriage.get_driver().player then
			serialized_carriage.driver_name = carriage.get_driver().player.name
		end
		train_data.carriages[#train_data.carriages + 1] = serialized_carriage
		log("Serialized carriage" .. count)
		count = count + 1
	end

	-- check for and stitch together any delayed carriages
	for k = #storage.universal_edges.delayed_entities, 1, -1 do
		local delayed_entity = storage.universal_edges.delayed_entities[k]
		if delayed_entity.locomotive_entity then
			if delayed_entity.locomotive_entity.train then
				if delayed_entity.locomotive_entity.train.front_stock then
					if delayed_entity.locomotive_entity.train.front_stock.unit_number == train_entity.train.front_stock.unit_number then
						log("Stitching delayed entity " .. count)
						count = count + 1
						delayed_entity.locomotive_entity = nil
						train_data.carriages[#train_data.carriages + 1] = delayed_entity
						table.remove(storage.universal_edges.delayed_entities, k) -- Remove from storage after stitching
					else
						count = count + 1
						log("Delayed entity does not match train entity" .. delayed_entity.locomotive_entity.train.front_stock.unit_number .. " vs " .. train_entity.train.front_stock.unit_number)
					end
				else
					log("Delayed entity has no front stock unit number")
					count = count + 1
				end
			else
				log("Delayed entity has no valid train reference")
				count = count + 1
			end
		else
			log("Delayed entity has no locomotive reference")
			count = count + 1
		end
	end
	log("total count: " .. count)
	return train_data
end

return LuaTrainComplete_serialize
