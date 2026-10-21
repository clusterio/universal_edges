-- Train group sync's pure rules (sync spec §4, §5): the content a group or an interrupt syncs, its canonical string,
-- the schedule a group's content gives a train, and the counts' rows. No Factorio globals: it runs on lua5.2, and
-- sync.lua passes plain values in.
local train_core = require("modules/universal_edges/transports/train_core")

local core = {}

--- A canonical string for v (plan ruling 3): equal content gives an equal string, whatever order Lua or JSON built its
--- tables in (keys sorted). It is what a tile stores as a name's "hash", and compares exactly.
function core.canon(v)
	local kind = type(v)
	if kind == "string" then
		return string.format("%q", v)
	elseif kind ~= "table" then
		return tostring(v)
	end
	local keys = {}
	for k in pairs(v) do
		keys[#keys + 1] = k
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	local out = {}
	for i, k in ipairs(keys) do
		out[i] = tostring(k) .. "=" .. core.canon(v[k])
	end
	return "{" .. table.concat(out, ",") .. "}"
end

--- A group's content (spec §4): its permanent station records — a rail record is this tile's own, a temporary record its
--- train's — and its interrupts' names, in order.
function core.group_content(records, interrupts)
	local recs, names = {}, {}
	for _, r in ipairs(records) do
		if r.station and not r.temporary then
			recs[#recs + 1] = { station = r.station, wait_conditions = r.wait_conditions, allows_unloading = r.allows_unloading }
		end
	end
	for i, it in ipairs(interrupts) do
		names[i] = it.name
	end
	return { records = recs, interrupts = names }
end

--- An interrupt's content: as it crosses a border (train_core.interrupts: rail targets dropped).
function core.interrupt_content(it)
	return train_core.interrupts({ it })[1]
end

--- What set_records and set_interrupts take for a group's content: its records, and each interrupt it names from the
--- cache (cache[name] = { v, content }); a name the cache lacks is left out.
function core.schedule_of(content, cache)
	local its = {}
	for _, name in ipairs(content.interrupts or {}) do
		local c = cache[name]
		if c then
			its[#its + 1] = c.content
		end
	end
	return { records = content.records or {}, interrupts = its }
end

--- The counts message's rows (§5.4), { kind, name, n }, sorted by kind then name, so equal counts give equal rows.
function core.count_rows(groups, interrupts)
	local rows = {}
	for name, n in pairs(groups) do
		rows[#rows + 1] = { "group", name, n }
	end
	for name, n in pairs(interrupts) do
		rows[#rows + 1] = { "interrupt", name, n }
	end
	table.sort(rows, function(a, b)
		return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
	end)
	return rows
end

return core
