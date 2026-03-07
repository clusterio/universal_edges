local LuaEntity_deserialize = require("modules/universal_edges/universal_serializer/classes/LuaEntity_deserialize")
local LuaTrain_deserialize = require("modules/universal_edges/universal_serializer/classes/LuaTrain_deserialize")

-- Deserializes a complete LuaTrain object, including rolling stock
---@param train_data table
---@return LuaEntity | nil
local function LuaTrainComplete_deserialize(train_data)
	local first_locomotive
	local front_stock -- tracks the first successfully spawned rolling stock, used as a reference for delayed carriages
	for _, carriage in ipairs(train_data.carriages) do
		local entity = LuaEntity_deserialize(carriage)

		if not entity then
			-- Entity could not be created (no room), delay for on_tick retry
			carriage.front_stock = front_stock
			table.insert(storage.universal_edges.delayed_entities, carriage)
		else
			if not front_stock then
				front_stock = entity
			end

			-- Store vehicle entity under player name to re-seat after cross-instance teleport
			if carriage.driver_name then
				storage.universal_edges.vehicle_drivers[carriage.driver_name] = entity
			end

			if entity.type == "locomotive" and not first_locomotive then
				first_locomotive = entity
			end
		end
	end

	-- Set train state once after all immediate spawns complete
	if first_locomotive then
		LuaTrain_deserialize(first_locomotive, train_data.train)
	end
	return first_locomotive
end

return LuaTrainComplete_deserialize
