local LuaEntity_deserialize = require("modules/universal_edges/universal_serializer/classes/LuaEntity_deserialize")
local LuaTrain_deserialize = require("modules/universal_edges/universal_serializer/classes/LuaTrain_deserialize")

-- Deserializes a complete LuaTrain object, including rolling stock
---@param train_data table
---@return LuaEntity | nil
local function LuaTrainComplete_deserialize(train_data)
	local first_locomotive
	local front_stock
	for _, carriage in ipairs(train_data.carriages) do
		local entity = LuaEntity_deserialize(carriage)
		-- Store vehicle entity under player name to re-seat after cross-instance teleport
		if carriage.driver_name then
			storage.universal_edges.vehicle_drivers[carriage.driver_name] = entity
		end
		-- If entity could not be created, delay deserialization
		if not entity then
			if not front_stock then
				front_stock = entity
			end
			carriage.front_stock = front_stock -- the front_stock.unit_number is used as a reference point if the train gets reserialized before fully spawned
			table.insert(storage.universal_edges.delayed_entities, carriage)
		else
			if entity.name == "locomotive" then -- If locomotive, deserialize train data to start the train in motion
				LuaTrain_deserialize(entity, train_data.train)
			elseif first_locomotive then -- each time a carriage is spawned, the game will swap the train to manual_mode
				first_locomotive.train.manual_mode = train_data.train.manual_mode
			end
		end
	end
	return first_locomotive -- Return the first locomotive, at least 1 locomotive should spawn before deserialization is considered a success
end

return LuaTrainComplete_deserialize
