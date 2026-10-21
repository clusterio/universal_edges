-- Storage migrations (spec §7.4), pure, so every migration gets a lua5.2 test with a before/after fixture.
local core = {}

--- Apply list[i] for every i above state.schema, in order, recording the schema after each. It never wipes: a table
--- whose schema is newer than the list (a save from newer code) is an error, and the table is left untouched.
function core.run(state, list)
	local schema = state.schema or 0
	if type(schema) ~= "number" or schema > #list then
		error("storage schema " .. tostring(schema) .. " is newer than this code's " .. #list .. "; refusing to touch it")
	end
	for i = schema + 1, #list do
		list[i](state)
		state.schema = i
	end
	return state
end

return core
