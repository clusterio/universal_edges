local LuaEntity_serialize = require("modules/universal_edges/universal_serializer/classes/LuaEntity_serialize")
local LuaTrain_serialize = require("modules/universal_edges/universal_serializer/classes/LuaTrain_serialize")

-- Serializes a complete LuaTrain object, including rolling stock
---@param train LuaTrain
---@return table
local function LuaTrainComplete_serialize(train)
	local train_data = {
		train = LuaTrain_serialize(train), -- metadata
		carriages = {}, -- entities
	}

	for _, carriage in pairs(train.carriages) do
		local serialized_carriage = LuaEntity_serialize(carriage)
		---@diagnostic disable-next-line: inject-field
		serialized_carriage.train = nil -- Don't serialize redundant LuaTrain metadata
		-- Add passenger data
		if carriage.get_driver() and carriage.get_driver().player then
			serialized_carriage.driver_name = carriage.get_driver().player.name
		end
		train_data.carriages[#train_data.carriages + 1] = serialized_carriage
	end
	return train_data
end

return LuaTrainComplete_serialize
