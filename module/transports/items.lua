-- Item helpers shared by the item transports (logistic-link spec §4.1, L13): whether an item spoils, and a spill on an
-- endpoint's border tile inside. Moved from belt.lua (SP3 spec §7.7, D38); each caller keeps its own stats line.
local geometry = require("modules/universal_edges/edges/geometry_core")

local items = {}

-- ponytail: module-level, never evicted. Bounded by item name × quality: both are fixed prototype sets at runtime, so
-- this can't grow past the save's loaded mods.
local spoilable_cache = {}

--- D38: whether name/quality spoils at all (prototypes.item[name].get_spoil_ticks(quality) > 0), cached.
function items.spoilable(name, quality)
	local by_quality = spoilable_cache[name]
	if not by_quality then
		by_quality = {}
		spoilable_cache[name] = by_quality
	end
	local v = by_quality[quality]
	if v == nil then
		v = prototypes.item[name].get_spoil_ticks(quality) > 0
		by_quality[quality] = v
	end
	return v
end

--- Spill on the endpoint's border tile inside (SP3 §7.7). spoil_percent (D38) restores freshness where the item has
--- any (the API's ItemStackDefinition carries it, [api] concepts.ItemStackDefinition). Whole stacks when whole_stacks
--- (2B, the logistic link's land): one item entity a stack, not one a plate. Belts leave it nil.
function items.spill(ep, name, quality, count, spoil_percent, whole_stacks)
	local surface = game.get_surface(ep.frame.surface_index)
	local x, y = geometry.to_world(ep.frame, ep.col + 0.5, 0.5)
	if surface then
		local stack = { name = name, quality = quality, count = count }
		if spoil_percent then
			stack.spoil_percent = spoil_percent
		end
		surface.spill_item_stack({ position = { x, y }, stack = stack, enable_looted = true, allow_belts = false,
			drop_full_stack = whole_stacks })
	end
end

return items
