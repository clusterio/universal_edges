local hooks = require("modules/universal_edges/universal_serializer/hooks")

-- Serializes a LuaTrain object.
---@param train LuaTrain
---@return table
local function LuaTrain_serialize(train, edge, offset)
	local context = { train = train, edge = edge, offset = offset }
	hooks.run("LuaTrain", "pre_serialize", {}, context)

	local train_schedule = train.get_schedule()
	local train_data = {
		manual_mode = train.manual_mode,
		speed = train.speed,
		schedule = train.schedule,
		interrupts = train_schedule.get_interrupts()
	}

	train_data = hooks.run("LuaTrain", "post_serialize", train_data, context)

	return train_data
end

return LuaTrain_serialize
