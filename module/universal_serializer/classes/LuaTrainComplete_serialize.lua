local LuaEntity_serialize = require("modules/universal_edges/universal_serializer/classes/LuaEntity_serialize")
local LuaTrain_serialize = require("modules/universal_edges/universal_serializer/classes/LuaTrain_serialize")

-- Serializes a complete LuaTrain object, including rolling stock
---@param LuaTrain LuaTrain
---@param carriages table<number, LuaEntity>
---@return table
local function LuaTrainComplete_serialize(LuaTrain, carriages)
	local train_data = {
		train = LuaTrain_serialize(LuaTrain), -- metadata
		carriages = {}, -- entities
	}

	local ordered_carriages = carriages or LuaTrain.carriages
	for _, carriage in ipairs(ordered_carriages) do
		local serialized_carriage = LuaEntity_serialize(carriage)
		-- Add passenger data
		if carriage.get_driver() and carriage.get_driver().player then
			serialized_carriage.driver_name = carriage.get_driver().player.name
		end
		train_data.carriages[#train_data.carriages + 1] = serialized_carriage
	end

	-- check for and stitch together any delayed carriages that have not been deserialized yet
	for k = #storage.universal_edges.delayed_entities, 1, -1 do
		local delayed_entity = storage.universal_edges.delayed_entities[k]
		if delayed_entity.front_stock then  -- all delayed carriages should have this reference to the train they are apart of
			local front_stock = delayed_entity.front_stock
			if front_stock.valid and (front_stock.unit_number == LuaTrain.front_stock.unit_number) then
				delayed_entity.front_stock = nil
				train_data.carriages[#train_data.carriages + 1] = delayed_entity
				table.remove(storage.universal_edges.delayed_entities, k)
			end
		else
			table.remove(storage.universal_edges.delayed_entities, k)
		end
	end
	return train_data
end

return LuaTrainComplete_serialize
