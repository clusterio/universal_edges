-- Deserializes a LuaFluidBox object.
---@param fluidbox LuaFluidBox
---@param fluidbox_data table
---@return LuaFluidBox
local function LuaFluidBox_deserialize(fluidbox, fluidbox_data)
	for i=1, math.min(#fluidbox, #fluidbox_data) do
		fluidbox[i] = fluidbox_data[i]
	end

	return fluidbox
end

return LuaFluidBox_deserialize
