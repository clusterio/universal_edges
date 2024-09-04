-- Deserializes a LuaTrain object.
---@param burner LuaBurner
---@param burner_data table
---@return LuaBurner
local function LuaBurner_deserialize(burner, burner_data)
	-- currently_burning must be set first in order to be able to change other propreties
	burner.currently_burning = burner_data.currently_burning
	burner.remaining_burning_fuel = burner_data.remaining_burning_fuel
	burner.heat = burner_data.heat
	return burner
end

return LuaBurner_deserialize
