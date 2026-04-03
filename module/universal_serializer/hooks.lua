local hooks = {}

---@type table<string, table<string, table<number, function>>>
local registry = {}
local next_id = 0

local VALID_TYPES = {
	LuaEntity = true,
	LuaTrain = true,
	LuaTrainComplete = true,
}

local VALID_PHASES = {
	pre_serialize = true,
	post_serialize = true,
	pre_deserialize = true,
	post_deserialize = true,
}

--- Register a hook callback.
--- For post_serialize/pre_deserialize phases: callback receives (data, context) and may return
--- a replacement data table, or nil to leave unchanged.
--- For pre_serialize/post_deserialize phases: callback receives (data, context) as notification
--- only — the return value is not used.
---@param serializer_type string "LuaEntity", "LuaTrain", or "LuaTrainComplete"
---@param phase string "pre_serialize", "post_serialize", "pre_deserialize", or "post_deserialize"
---@param callback function
---@return number hook_id for use with hooks.remove()
function hooks.register(serializer_type, phase, callback)
	assert(VALID_TYPES[serializer_type], "Invalid serializer type: " .. tostring(serializer_type))
	assert(VALID_PHASES[phase], "Invalid phase: " .. tostring(phase))
	assert(type(callback) == "function", "Callback must be a function")

	if not registry[serializer_type] then
		registry[serializer_type] = {}
	end
	if not registry[serializer_type][phase] then
		registry[serializer_type][phase] = {}
	end

	next_id = next_id + 1
	registry[serializer_type][phase][next_id] = callback
	return next_id
end

--- Remove a hook by id.
---@param serializer_type string
---@param phase string
---@param id number
function hooks.remove(serializer_type, phase, id)
	local list = registry[serializer_type] and registry[serializer_type][phase]
	if list then
		list[id] = nil
	end
end

--- Run all hooks for a given type and phase.
--- For post_serialize/pre_deserialize: returns the (possibly modified) data table.
--- For pre_serialize/post_deserialize: runs hooks for side effects only.
---@param serializer_type string
---@param phase string
---@param data table the serialized/deserialized data
---@param context table|nil extra context (source entity, edge, offset, etc.)
---@return table data
function hooks.run(serializer_type, phase, data, context)
	local list = registry[serializer_type]
		and registry[serializer_type][phase]
	if not list then return data end

	for _, callback in pairs(list) do
		local result = callback(data, context)
		if result ~= nil then
			data = result
		end
	end
	return data
end

return hooks
