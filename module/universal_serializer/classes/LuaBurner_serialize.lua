-- Serializes a LuaBurner object.
---@param burner LuaBurner
---@return table
local function LuaBurner_serialize(burner)
	local burner_data = {
		heat = burner.heat,
		remaining_burning_fuel = burner.remaining_burning_fuel,
		currently_burning = burner.currently_burning.name,
	}

	return burner_data
end

return LuaBurner_serialize
