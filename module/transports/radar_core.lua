-- The radar sync's rules, pure (radar-sync spec, docs/superpowers/specs/2026-10-06-ue-radar-sync-design.md): a radar
-- network's key (§4), two injectors summed for guard 6.2's echo cancellation, and guard 6.1's key lists. No Factorio
-- globals, so it runs on lua5.2. Signal maps are circuit_core's, m[type][quality][name] = count.
local cc = require("modules/universal_edges/transports/circuit_core")

local core = {}

--- §4's key of a real radar's network: "s:<planet>" in surface mode (nil off a planet: plan ruling 3), and
--- "u:<type>:<name>:<quality>" for a universe channel (a SignalID: type defaults to item, quality to normal; nil with
--- no channel).
function core.key(universe, planet, channel)
	if not universe then
		return planet and ("s:" .. planet) or nil
	end
	if not channel then
		return nil
	end
	return "u:" .. (channel.type or "item") .. ":" .. channel.name .. ":" .. (channel.quality or "normal")
end

--- Guard 6.2: signal maps summed as a wire sums them, int32-wrapped, zeros dropped; a new map.
function core.sum(maps)
	local m = {}
	for _, x in ipairs(maps) do
		for t, qs in pairs(x) do
			for q, names in pairs(qs) do
				for name, v in pairs(names) do
					local s = cc.wrap((cc.get(m, t, q, name) or 0) + v)
					cc.put(m, t, q, name, s ~= 0 and s or nil)
				end
			end
		end
	end
	return m
end

--- Guard 6.1: keys sorted and joined with ",", nil for none.
-- ponytail: a key never holds a comma (a planet or signal name would have to); a list of tables if one ever does.
function core.join(keys)
	if #keys == 0 then
		return nil
	end
	table.sort(keys)
	return table.concat(keys, ",")
end

--- Guard 6.1: do two joined key lists (either may be nil) name a whole key in common?
function core.common(a, b)
	if not (a and b) then
		return false
	end
	local within = "," .. b .. ","
	for k in string.gmatch(a, "[^,]+") do
		if string.find(within, "," .. k .. ",", 1, true) then
			return true
		end
	end
	return false
end

return core
