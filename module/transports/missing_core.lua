-- Whether a body names an entity, an item or a quality this server doesn't have (SP3b review I1, M3): the train and
-- vehicle credits share this, since Clusterio's deserialize_inventory only pcalls and prints on an unknown item
-- (module/clusterio/serialize.lua), never raising, so without this check an unknown item vanishes with no limbo
-- file and no log line. Pure: have is prototypes.entity/item/quality themselves, each already a name -> prototype
-- lookup, so the caller passes them straight through.
local core = {}

--- The first missing name in one serialized inventory (module/clusterio/serialize.lua's shape: s.i is a list of item
--- stack entries (n, q) and slot filter entries (f.name, f.quality)). kind is "item" or "quality"; nil when every
--- name in s is known.
function core.missing_in_inventory(s, have)
	for _, entry in ipairs(s and s.i or {}) do
		if entry.n and not have.item[entry.n] then
			return "item", entry.n
		end
		if entry.q and not have.quality[entry.q] then
			return "quality", entry.q
		end
		local f = entry.f
		if f then
			if f.name and not have.item[f.name] then
				return "item", f.name
			end
			if f.quality and not have.quality[f.quality] then
				return "quality", f.quality
			end
		end
	end
	return nil
end

--- The first missing name among an entity's name, its quality, and every inventory's items (the leaf check the train
--- and vehicle credits each feed from their own body shape, review I1). name/quality a caller doesn't have (a
--- carriage with no riders, a vehicle with none) are simply nil, and nil is never looked up. nil when everything
--- passed in is known.
function core.missing(name, quality, inventories, have)
	if name and not have.entity[name] then
		return "entity", name
	end
	if quality and not have.quality[quality] then
		return "quality", quality
	end
	for _, s in ipairs(inventories or {}) do
		local kind, missing_name = core.missing_in_inventory(s, have)
		if kind then
			return kind, missing_name
		end
	end
	return nil
end

return core
