-- Serializes a LuaTrain object.
---@param train LuaTrain
---@return table
local function LuaTrain_serialize(train, edge, offset)
	local train_schedule = train.get_schedule()
	local train_data = {
		manual_mode = train.manual_mode,
		speed = train.speed,
		schedule = train.schedule,
		interrupts = train_schedule.get_interrupts()
	}

	-- Remove the current schedule record if it matches the source trainstop we're departing from
	if edge and offset and train.schedule and train.schedule.records then
		local stop_name = edge.id .. " " .. offset
		local record = train.schedule.records[train.schedule.current]
		if record and record.station and record.station == stop_name then
			local new_schedule = table.deepcopy(train.schedule)
			table.remove(new_schedule.records, new_schedule.current)
			train_data.schedule = new_schedule
			log("Modified schedule - current: " .. new_schedule.current .. " records: " .. serpent.block(new_schedule.records))
		end
	end
	return train_data
end

return LuaTrain_serialize
