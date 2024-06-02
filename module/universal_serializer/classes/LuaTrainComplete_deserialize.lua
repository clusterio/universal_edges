local LuaEntity_deserialize = require("modules/universal_edges/universal_serializer/classes/LuaEntity_deserialize")
local LuaTrain_deserialize = require("modules/universal_edges/universal_serializer/classes/LuaTrain_deserialize")

-- Deserializes a complete LuaTrain object, including rolling stock
---@param train_data table
---@return LuaTrain | nil
local function LuaTrainComplete_deserialize(train_data)
	local entity = nil
	for _, carriage in ipairs(train_data.carriages) do
		entity = LuaEntity_deserialize(carriage)
		log("Deserialized carriage " .. _)
	end
	log("Entity: "..entity.name)
	if entity ~= nil then
		return LuaTrain_deserialize(entity, train_data.train)
	end
end

return LuaTrainComplete_deserialize
