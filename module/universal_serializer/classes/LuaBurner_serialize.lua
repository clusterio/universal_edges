-- Serializes a LuaBurner object.
---@param burner LuaBurner
---@return table
local function LuaBurner_serialize(burner)
	return {
		heat = burner.heat,
		remaining_burning_fuel = burner.remaining_burning_fuel,
		currently_burning = burner.currently_burning and {
			name = burner.currently_burning.name.name,  -- convert prototype → string
			quality = burner.currently_burning.quality -- may be nil
		} or nil,
	}
end

return LuaBurner_serialize
