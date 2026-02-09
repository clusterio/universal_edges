local LuaEntity_deserialize = require("modules/universal_edges/universal_serializer/classes/LuaEntity_deserialize")
local LuaTrain_deserialize = require("modules/universal_edges/universal_serializer/classes/LuaTrain_deserialize")

-- Deserializes a complete LuaTrain object, including rolling stock
---@param train_data table
---@return LuaTrain | nil
local function LuaTrainComplete_deserialize(train_data)
	local entity = nil
	local locomotive_entity ---@cast locomotive_entity LuaEntity
	local count = 0
	for _, carriage in ipairs(train_data.carriages) do
		entity = LuaEntity_deserialize(carriage)
		-- log(serpent.block(train_data.carriages))
		-- Store vehicle entity under player name to re-seat after cross-instance teleport
		if carriage.driver_name then
			storage.universal_edges.vehicle_drivers[carriage.driver_name] = entity
		end
		-- If entity could not be created, delay deserialization
		if not entity then
			log("Delaying deserialization for carriage " .. _)
			count = count + 1
			carriage.locomotive_entity = locomotive_entity
			table.insert(storage.universal_edges.delayed_entities, carriage)
		else
			count = count + 1
			-- If locomotive, deserialize train data
			if entity.name == "locomotive" then
				locomotive_entity = entity
				LuaTrain_deserialize(entity, train_data.train)
			elseif locomotive_entity then
				locomotive_entity.train.manual_mode = train_data.train.manual_mode
			end
			-- log("Deserialized carriage " .. _)
		end
	end
	log("Total deserialize count: " .. count)
	return locomotive_entity.train or nil
end

return LuaTrainComplete_deserialize
