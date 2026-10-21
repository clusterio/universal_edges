-- Station-slot reservations (D43, spec §6.2, §7.3): 2.1 script reservations (spike 1). The controller picks the stop
-- and asks its tile to reserve it; the tile releases it when the train arrives here (routes.lua, materialized); the
-- controller cancels on a re-route, a failure, a lost or manual train, the 5-minute rule or an orphan, and re-syncs a
-- tile's reservations at its start (they survive saves, so a rollback can leave stale ones).
local bridge = require("modules/universal_edges/runtime/bridge")
local base = require("modules/universal_edges/routing/base")

local reservations = {}

local function add(stop, delta)
	stop.script_reservations_count = math.max(0, stop.script_reservations_count + delta)
end

--- Drop route trace's reservation if this tile holds it: phase "released" (the train arrived) or "cancelled".
function reservations.drop(trace, phase, reason)
	local r = base.state()
	local stop = r.reserved[trace]
	if stop == nil then
		return false
	end
	r.reserved[trace] = nil
	local fields = { reason = reason }
	if stop.valid then
		add(stop, -1)
		fields.stop, fields.name, fields.count = stop.unit_number, stop.backer_name, stop.script_reservations_count
	end
	base.emit("ue.reservation", phase, "info", trace, fields)
	return true
end

--- Reserve one slot at stop unit for route trace. A trace already holding another stop moves (R14): a re-ask after a
--- forgotten route can pick a different stop on this tile.
function reservations.reserve(trace, unit)
	local r = base.state()
	local held = r.reserved[trace]
	if held and held.valid and held.unit_number == unit then
		return
	end
	local stop = game.get_entity_by_unit_number(unit)
	if not (stop and stop.valid and stop.type == "train-stop") then
		base.emit("ue.reservation", "missing", "warn", trace, { stop = unit })
		return
	end
	if held then
		reservations.drop(trace, "cancelled", "rerouted")
	end
	add(stop, 1)
	r.reserved[trace] = stop
	base.emit("ue.reservation", "reserved", "info", trace,
		{ stop = unit, name = stop.backer_name, count = stop.script_reservations_count })
end

--- The controller's list is the truth (§7.3): drop what it doesn't list (or lists on another stop), take what's missing.
function reservations.resync(list)
	local r = base.state()
	local want, added, removed = {}, 0, 0
	for _, x in ipairs(list) do
		if type(x) == "table" and type(x.trace) == "string" and type(x.unit) == "number" then
			want[x.trace] = x.unit
		end
	end
	for trace, stop in pairs(r.reserved) do
		if not (stop.valid and want[trace] == stop.unit_number) then
			reservations.drop(trace, "cancelled", "resync")
			removed = removed + 1
		end
	end
	for trace, unit in pairs(want) do
		if not r.reserved[trace] then
			reservations.reserve(trace, unit)
			added = added + 1
		end
	end
	base.emit("ue.reservation", "resynced", "info", nil, { added = added, removed = removed })
end

bridge.on("universal_edges", "ue.route.reserve", function(p)
	if type(p.trace) ~= "string" or type(p.unit) ~= "number" then
		return false
	end
	reservations.reserve(p.trace, p.unit)
end)

--- ue.route.cancel (§4.2): reason is rerouted, failed, lost, manual, gc or orphan.
bridge.on("universal_edges", "ue.route.cancel", function(p)
	if type(p.trace) ~= "string" then
		return false
	end
	reservations.drop(p.trace, "cancelled", type(p.reason) == "string" and p.reason or nil)
end)

return reservations
