-- Raids, expansion parties and the oracle across edges (cross-border biters spec §6, §7), pure. No Factorio global, so
-- lua5.2 runs it. A frame is SP1 §8's { origin, facing, length }.
local geometry = require("modules/universal_edges/edges/geometry_core")
local core = { ORACLE_Y = -3.5, INSIDE = 4, NEAR = 10, RANGE = 200 }

--- The oracle's local x on a side of length L (spec §6.3): the middle of local column L/64, the first-row chunk gridworld
--- leaves unswept (plan ruling R13). ORACLE_Y keeps it 3.5 tiles out, clear of the line and of the barriers' inner face.
function core.oracle_x(L)
	return L / 2 + 16
end

--- Spec §6.1: where a walk to x along a side ends: x kept 8 from the side's ends, INSIDE tiles in. Returns the kept x and
--- the world point.
function core.hop(frame, x)
	x = math.max(8, math.min(frame.length - 8, x))
	local px, py = geometry.to_world(frame, x, core.INSIDE)
	return x, px, py
end

--- Spec §6.3's fallback, "the strongest polluting cluster by emitting-entity count": the first of positions ({ x, y })
--- in the chunk holding most of them; nil for none.
function core.densest(positions)
	local count, first, best = {}, {}, nil
	for _, p in ipairs(positions) do
		local k = math.floor(p.x / 32) .. "," .. math.floor(p.y / 32)
		count[k] = (count[k] or 0) + 1
		first[k] = first[k] or p
		if not best or count[k] > count[best] then
			best = k
		end
	end
	return best and first[best]
end

--- A raid's or a party's body (spec §6.1, §7): v = 1, x, members (at least one { name, quality, health }), and route (a
--- raid's edge ids) or dest (a party's local { x, y }).
function core.valid(body)
	if type(body) ~= "table" or body.v ~= 1 or type(body.x) ~= "number" or type(body.members) ~= "table"
		or #body.members == 0 then
		return false
	end
	for _, m in ipairs(body.members) do
		if type(m) ~= "table" or type(m.name) ~= "string" or type(m.quality) ~= "string" or type(m.health) ~= "number" then
			return false
		end
	end
	if body.kind == "raid" then
		if type(body.route) ~= "table" then
			return false
		end
		for _, id in ipairs(body.route) do
			if type(id) ~= "string" then
				return false
			end
		end
		return true
	end
	return body.kind == "party" and type(body.dest) == "table" and type(body.dest[1]) == "number"
		and type(body.dest[2]) == "number"
end

--- The side a party bound for world (dx, dy) crosses (spec §7), among sides = { { id, frame } }: one whose line dest is
--- past within its span; else, at a corner, the one whose line it is further past. Returns that side and dest's local x on
--- it, or nil when dest is past no line (it is this tile's).
function core.party_side(sides, dx, dy)
	local best, best_x, best_y
	for _, s in ipairs(sides) do
		local x, y = geometry.to_local(s.frame, dx, dy)
		if y < 0 then
			if x >= 0 and x < s.frame.length then
				return s, x
			end
			if not best or y < best_y then
				best, best_x, best_y = s, x, y
			end
		end
	end
	if best then
		return best, best_x
	end
	return nil
end

return core
