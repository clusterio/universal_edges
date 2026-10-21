-- The logistic link (logistic-link spec §7, §8.2), pure: keys and their parse, the slot plan, the gate and the removal
-- step. logistic.lua reads and writes the chests.
local core = {}

--- "<item>|<quality>", or "<item>|<quality>|<p>" for an item that spoils (§7.1, L3): belt keys (belt_core.key) minus
--- the lane and the stack size; p is belt_core.spoil_p's 0..100.
function core.key(name, quality, p)
	if p then
		return name .. "|" .. quality .. "|" .. p
	end
	return name .. "|" .. quality
end

-- ponytail: a module-level memo, never evicted, as belt_core's: bounded by the keys partners ever sent (item × quality
-- × 101 freshness buckets). A parse is pure, so a fresh memo (a joining player's Lua) returns the same values.
local parsed = {}

--- A key's item, quality and freshness (nil for an item that doesn't spoil); nil for a malformed key (§7.6). The
--- three-field form is tried first; no prototype name contains "|" ([api] PrototypeBase.name), so the two can't be
--- confused.
function core.parse(key)
	local p = parsed[key]
	if p == nil then
		local name, quality, fresh = string.match(key, "^(.+)|([^|]+)|(%d+)$")
		if not name then
			name, quality = string.match(key, "^(.+)|([^|]+)$")
		end
		p = name and { name, quality, tonumber(fresh) } or false
		parsed[key] = p
	end
	if p then
		return p[1], p[2], p[3]
	end
	return nil
end

--- §7.4 step 5 (L15): the candidates ({ key, n, stack size }) sorted by key, rotated to start at the first key after
--- last_key in key order (wrapping; plan ruling 3), take up to free slots in turn: take = min(n, slots × stack size),
--- then slots -= ceil(take / stack size). A single stack (the detailed path's candidate) goes whole once a slot is left,
--- since its n is at most its stack size. Each taken candidate gets .take, and the takes are summed by key into bag.
--- Returns bag, its total, and the rotated list's first key (nil with no candidates), which the poll keeps as last_key.
function core.plan(cands, free, last_key)
	table.sort(cands, function(a, b) return a[1] < b[1] end)
	local n, start = #cands, 1
	if last_key then
		for i = 1, n do
			if cands[i][1] > last_key then
				start = i
				break
			end
		end
	end
	local bag, total, slots = {}, 0, free
	for j = 0, n - 1 do
		if slots <= 0 then
			break
		end
		local c = cands[(start - 1 + j) % n + 1]
		local take = math.min(c[2], slots * c[3])
		if take > 0 then
			c.take, slots = take, slots - math.ceil(take / c[3])
			bag[c[1]], total = (bag[c[1]] or 0) + take, total + take
		end
	end
	return bag, total, cands[start] and cands[start][1]
end

--- §7.4's gate (L2): the destination's last status has free and r, and r counts everything this source has sent.
function core.open(sent, status)
	return type(status) == "table" and type(status.free) == "number" and type(status.r) == "number" and sent <= status.r
end

--- §8.2 step 2 (L18): what this side does about a removal. gone is this side's (nil, "lost" or "drained");
--- partner_state the partner's endpoint state (nil before it is heard from); partner_gone its status's gone.
function core.removal(gone, partner_state, partner_gone, is_source)
	if gone == "lost" then
		if partner_gone == "drained" or (partner_gone == "lost" and is_source)
			or (partner_state ~= nil and partner_state ~= "ready") then
			return "request"
		end
		return nil
	end
	if gone == nil and partner_gone == "lost" then
		return "drain"
	end
	return nil
end

return core
