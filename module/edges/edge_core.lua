-- Pure rules of the instance edge lifecycle (SP1 spec §5.3, §5.4, §6.2): record checks, what a record means for the
-- stored side, connector diffs, and the activation and epoch rules. Runs on lua5.2 and touches no game state.
local core = {}

local FACINGS = { [0] = true, [4] = true, [8] = true, [12] = true }

local function whole(v, lo, hi)
	return type(v) == "number" and v == math.floor(v) and (lo == nil or v >= lo) and (hi == nil or v <= hi)
end

local function valid_side(s)
	return type(s) == "table" and whole(s.instanceId) and type(s.surface) == "string" and type(s.origin) == "table"
		and whole(s.origin[1]) and whole(s.origin[2]) and FACINGS[s.facing] == true
end

--- True when rec is a well-formed side record from the instance plugin; Lua re-checks every field it reads (§5.1).
function core.valid(rec)
	if type(rec) ~= "table" or type(rec.id) ~= "string" or #rec.id < 1 or #rec.id > 128 or not whole(rec.revision, 1)
		or type(rec.trace) ~= "string" or (rec.me ~= "a" and rec.me ~= "b") or not whole(rec.length, 1, 100000)
		or type(rec.deleted) ~= "boolean" or not valid_side(rec.a) or not valid_side(rec.b)
		or type(rec.connectors) ~= "table" then
		return false
	end
	for _, c in pairs(rec.connectors) do
		if type(c) ~= "table" or type(c.cid) ~= "string" or type(c.type) ~= "string" or not whole(c.pos, 0)
			or not whole(c.width, 1) or c.pos + c.width > rec.length then
			return false
		end
	end
	return true
end

local function same_side(x, y)
	return x.instanceId == y.instanceId and x.surface == y.surface and x.origin[1] == y.origin[1]
		and x.origin[2] == y.origin[2] and x.facing == y.facing
end

--- What applying rec means for side (nil when there is none):
---   "create";
---   "replace", when a, b, length or me changed (I5);
---   "recreate", when a shell's id comes back live with the same geometry;
---   "shell", when the edge is tombstoned;
---   "update"; or "stale".
--- An update applies only above the stored revision. A sync is authoritative and applies any other revision.
function core.plan(side, rec, sync)
	if side == nil then
		return "create"
	end
	-- M1: staleness is checked before the geometry change, so an old, misordered message is never trusted, even
	-- when it claims a, b, length or me changed.
	if not sync and rec.revision <= side.revision then
		return "stale"
	end
	if side.me ~= rec.me or side.length ~= rec.length or not same_side(side.a, rec.a) or not same_side(side.b, rec.b) then
		return "replace"
	end
	if side.deleted and not rec.deleted then
		return "recreate"
	end
	if rec.deleted and not side.deleted then
		return "shell"
	end
	return "update"
end

--- Take rec's revision, trace, tombstone flag and connectors. Returns the added and removed cids, sorted.
function core.update(side, rec)
	local connectors, added, removed = {}, {}, {}
	for _, c in pairs(rec.connectors) do
		connectors[c.cid] = c
		if side.connectors[c.cid] == nil then
			added[#added + 1] = c.cid
		end
	end
	for cid in pairs(side.connectors) do
		if connectors[cid] == nil then
			removed[#removed + 1] = cid
		end
	end
	table.sort(added)
	table.sort(removed)
	side.revision, side.trace, side.deleted, side.connectors = rec.revision, rec.trace, rec.deleted, connectors
	return added, removed
end

--- A new, inactive side (its epoch is nil) from a valid record; surface_index is nil when the surface is missing.
function core.new_side(rec, surface_index)
	local side = {
		id = rec.id, me = rec.me, length = rec.length, a = rec.a, b = rec.b, surface_index = surface_index,
		active = false, connectors = {}, eps = {}, barrier_chunks = {},
	}
	core.update(side, rec)
	return side
end

--- Apply an activation message (§6.1). True when the state changed; the same state again is a no-op (§6.3).
--- `synced` is whether this instance has applied a sync since its last on_server_startup; an active=true before
--- that is ignored (defense in depth: the controller should never send one this early, C1, but Lua doesn't trust
--- it either). Deactivation is always honored.
function core.set_active(side, active, epoch, synced)
	if active then
		if not synced or (side.active and side.epoch == epoch) then
			return false
		end
		side.active, side.epoch = true, epoch
		return true
	end
	if not side.active then
		return false
	end
	side.active, side.epoch = false, nil
	return true
end

--- True when a message stamped epoch belongs to the side's current activation; anything else is stale (§11.2).
function core.epoch_ok(side, epoch)
	return side.active and side.epoch == epoch
end

--- A start, crash or rollback, and every sync, leave every side inactive (§6.2). Returns the sides that were active,
--- which the caller deactivates as if each had been sent a ue.edge.activation(active=false).
function core.reset(sides)
	local was = {}
	for _, side in pairs(sides) do
		if side.active then
			was[#was + 1] = side
		end
		side.active, side.epoch = false, nil
	end
	return was
end

return core
