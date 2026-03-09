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

	-- [gridworld plugin] Destroy train pathing proxy for the arriving train's destination
	do
		local proxies = storage.gridworld and storage.gridworld.train_proxies
		if not proxies then goto continue end

		local schedule = first_locomotive and first_locomotive.train and first_locomotive.train.schedule
		if not schedule then goto continue end

		local record = schedule.records and schedule.records[schedule.current]
		local destination = record and record.station
		if not destination or not proxies[destination] or #proxies[destination] == 0 then goto continue end

		local loco = table.remove(proxies[destination])
		if loco and loco.valid then
			loco.destroy()
		else
			log("Failed to destroy train proxy for destination " .. destination .. " - invalid entity")
		end
		if #proxies[destination] == 0 then
			proxies[destination] = nil
		end

		::continue::
	end

	return first_locomotive
end

return LuaTrainComplete_deserialize
