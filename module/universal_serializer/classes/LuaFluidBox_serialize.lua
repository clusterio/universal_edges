-- Serializes a LuaFluidBox object.
---@param burner LuaFluidBox
---@return table
local function LuaFluidBox_serialize(fluidbox)
	local fluidbox_data = {}

	for i=1, #fluidbox do
		fluidbox_data[i] = fluidbox[i]
	end

	return fluidbox_data
end

return LuaFluidBox_serialize
