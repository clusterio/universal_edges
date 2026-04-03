local hooks = require("modules/universal_edges/universal_serializer/hooks")

-- Deserializes a LuaTrain object.
---@param entity LuaEntity
---@param train_data table
---@return LuaTrain
local function LuaTrain_deserialize(entity, train_data)
	local context = { entity = entity }
	train_data = hooks.run("LuaTrain", "pre_deserialize", train_data, context)

	local train = entity.train
	if train == nil then
		error("Failed to find train")
	end
	local train_schedule = train.get_schedule()
	train_schedule.set_interrupts(train_data.interrupts)
	train.schedule = train_data.schedule
	train.manual_mode = train_data.manual_mode
	train.speed = train_data.speed

	context.result_train = train
	hooks.run("LuaTrain", "post_deserialize", train_data, context)

	return train
end

return LuaTrain_deserialize
