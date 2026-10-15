-- Idempotency (spec §7.3): per sender boot id, a bounded set of recently seen message ids.
local dedup = {}

dedup.CAP = 1024
dedup.MAX_AGE = 36000 -- ticks (10 minutes)

--- The boot id of "<boot id>.<seq>", or nil when id is malformed.
function dedup.sender(id)
	if type(id) ~= "string" then
		return nil
	end
	return string.match(id, "^(%x+)%.%d+$")
end

local function forget_oldest(set)
	set.ids[set.order[set.head]] = nil
	set.order[set.head] = nil
	set.head = set.head + 1
end

--- True the first time id is seen (and records it), false for a repeat. id must be well formed (see sender).
--- A sender keeps at most cap ids, none older than max_age ticks; a sender quiet for longer is dropped.
function dedup.first_seen(seen, id, tick, cap, max_age)
	cap = cap or dedup.CAP
	max_age = max_age or dedup.MAX_AGE
	local boot = dedup.sender(id)
	local set = seen[boot]
	if not set then
		for other, s in pairs(seen) do
			if s.last + max_age < tick then
				seen[other] = nil
			end
		end
		set = { ids = {}, order = {}, head = 1, tail = 0, last = tick }
		seen[boot] = set
	end
	while set.head <= set.tail and set.ids[set.order[set.head]] + max_age < tick do
		forget_oldest(set)
	end
	if set.ids[id] then
		return false
	end
	set.tail = set.tail + 1
	set.order[set.tail] = id
	set.ids[id] = tick
	set.last = tick
	-- Add first, then evict: a rehash then counts cap + 1 keys and doubles the table. Evicting first leaves cap keys,
	-- which fill a power-of-two table exactly, so every add would rehash. This needs CAP to be a power of two (1023 would not do).
	if set.tail - set.head + 1 > cap then
		forget_oldest(set)
	end
	return true
end

return dedup
