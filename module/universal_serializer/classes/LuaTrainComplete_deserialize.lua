local LuaEntity_deserialize = require("modules/universal_edges/universal_serializer/classes/LuaEntity_deserialize")
local LuaTrain_deserialize = require("modules/universal_edges/universal_serializer/classes/LuaTrain_deserialize")

-- Deserializes a complete LuaTrain object, including rolling stock
---@param train_data table
---@return LuaTrain | nil
local function LuaTrainComplete_deserialize(train_data)
	local entity = nil
	for _, carriage in ipairs(train_data.carriages) do
		entity = LuaEntity_deserialize(carriage)
	end

	if entity ~= nil then
		LuaTrain_deserialize(entity, train_data.train)
		return entity.train
	end
end

return LuaTrainComplete_deserialize
