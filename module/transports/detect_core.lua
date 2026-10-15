-- Build detection (SP3 spec §6.1), pure: an entity built in a side's border row → the connector it proposes, or nil.
-- The local frame is SP1 §8's: +x along the edge, +y inward; the border row is local y in (0, 1). Directions are 16ths.
local geometry = require("modules/universal_edges/edges/geometry_core")
local train_core = require("modules/universal_edges/transports/train_core")

local core = {}

--- The connector type each detected entity type proposes.
core.KIND = {
	["transport-belt"] = "belt", ["underground-belt"] = "belt",
	pipe = "fluid", ["pipe-to-ground"] = "fluid", pump = "fluid",
	["electric-pole"] = "power",
	["straight-rail"] = "train", ["elevated-straight-rail"] = "train",
	["logistic-container"] = "logistic",
}
--- The entity types a connector type adopts as its border entity (§6.2 steps 2 and 3).
core.BORDER_TYPES = {
	belt = { "transport-belt", "underground-belt" },
	fluid = { "pipe", "pipe-to-ground", "pump" },
	power = { "electric-pole" },
	train = { "straight-rail", "elevated-straight-rail" },
}

--- The proposal for entity e = { type, x, y, direction, size } (world centre and direction; size 2 for a 2×2 pole) on
--- side me with frame (origin, facing, length): { type, col, width, params }, col this side's local column; or nil.
--- A belt facing outward makes this side the source. A pump lies across the edge with its centre at local y = 1, so
--- its footprint (0, 2) holds the border row and leaves the link tank's tile free (plan ruling 4).
function core.propose(me, frame, e)
	local kind = core.KIND[e.type]
	if not kind then
		return nil
	end
	local x, y = geometry.to_local(frame, e.x, e.y)
	local d = geometry.dir_to_local(frame, e.direction or 0)
	local across = d == 0 or d == 8
	local row = y > 0 and y < 1
	-- params is built only on a returned proposal (not for every side's rejection test): a rail drag raises one
	-- event per rail, and detect_core.propose runs once per side per event (final re-review Minor 1).
	local col, width, params = math.floor(x), 1, nil
	if kind == "belt" then
		if not (across and row) or col < 0 or col + width > frame.length then
			return nil
		end
		local source = d == 0
		params = { dir = (source == (me == "a")) and "ab" or "ba" }
	elseif e.type == "pump" then
		if not (across and y > 0.5 and y < 1.5) then
			return nil
		end
	elseif kind == "power" and e.size == 2 then
		if not (y > 0.5 and y < 1.5) then
			return nil
		end
		col, width = math.floor(x + 0.5) - 1, 2
	elseif kind == "train" then -- SP3b: §6.1's rail row, 2×2 across the border row. A signal decides its direction
		-- later (train box direction spec §6.1, train_core.box_dir), so the proposal carries only its layer.
		col = across and train_core.rail_rule(x, y, d, frame.length)
		if not col then
			return nil
		end
		width = train_core.WIDTH
		params = { layer = e.type == "elevated-straight-rail" and "elevated" or "ground" }
	elseif kind == "logistic" then
		-- logistic-link spec §5: a requester-mode chest (its facts say link: a ue-link-<name> prototype exists, §6.3);
		-- the side that built it sends (O1).
		if not (e.link and row) then
			return nil
		end
		params = { dir = me == "a" and "ab" or "ba", q = e.q, chest = e.name }
	elseif not row then
		return nil
	end
	if col < 0 or col + width > frame.length then
		return nil
	end
	return { type = kind, col = col, width = width, params = params or {} }
end

--- The world box of a connector's border row (columns [col, col + width), local y in (0, 1)), shrunk by 0.1 so it
--- touches no neighbour: where its border entity is looked for.
function core.border_area(frame, col, width)
	return geometry.area_to_world(frame, col + 0.1, 0.1, col + width - 0.1, 0.9)
end

return core
