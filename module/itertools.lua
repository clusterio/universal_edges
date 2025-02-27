local itertools = {}

function itertools.partial_pairs(tbl, state, ticks_left)
	-- Guard against nil or non-table arguments
	if not tbl or type(tbl) ~= "table" then
		return function() return nil end, {}, nil
	end

	-- Reset corrupted state
	if state and state.index ~= nil then
		-- Check if index is valid in the table
		local valid = false
		for k, _ in pairs(tbl) do
			if k == state.index then
				valid = true
				break
			end
		end

		-- If index is invalid, reset it to avoid errors
		if not valid then
			state.index = nil
			state.pos = 0
		end
	end

	if ticks_left == 0 then
		local index = state and state.index
		if state then
			state.index = nil
			state.pos = 0
		end
		return next, tbl, index
	end

	local function iterator(itstate, index)
		-- Extra safety check for invalid state
		if not itstate or not tbl then
			return nil, nil
		end

		if itstate.pos >= itstate.endpoint then
			itstate.index = index
			return nil, nil
		elseif itstate.pos > 0 and index == nil then
			return nil, nil
		end

		itstate.pos = itstate.pos + 1

		-- Guard against invalid keys when calling next()
		local success, nextIndex = pcall(next, tbl, index)
		if not success or nextIndex == nil then
			-- Return nil if next() fails or returns nil to safely end iteration
			return nil, nil
		end

		itstate.index = nextIndex
		return itstate.index, tbl[itstate.index]
	end

	state = state or {}
	state.pos = state.pos or 0

	-- Handle potential errors in table_size for corrupted tables
	local size = 0
	local success, tsize = pcall(table_size, tbl)
	if success then
		size = tsize
	else
		-- Count manually if table_size fails
		for _ in pairs(tbl) do
			size = size + 1
		end
	end

	state.endpoint = state.pos + math.max(0, math.ceil((size - state.pos) / (ticks_left + 1)))
	return iterator, state, state.index
end

return itertools
