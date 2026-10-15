-- D17's stop detection (spec §7.7): a registry of this tile's train stops, kept by build, removal and rename events and
-- rebuilt at every resync; each stop polled every 10 s, circuit-controlled ones every ~1 s, a row sent only when it
-- changed. A rail or signal built or removed marks the table dirty (§7.8). The GUI re-read is not built (R18).
local scheduler = require("modules/universal_edges/runtime/scheduler")
local base = require("modules/universal_edges/routing/base")

local stops = { events = {} }

--- The station row (contracts.ts Station): surface is its registry entry's, read once at registration (R31); limit is
--- 4294967295 when the stop has none; count includes reservations.
function stops.row(stop, surface)
	return { unit = stop.unit_number, surface = surface, name = stop.backer_name, limit = stop.trains_limit,
		count = stop.trains_count, script = stop.script_reservations_count, priority = stop.train_stop_priority }
end

--- A registry entry (§7.7): the stop, its surface's name (a stop never changes surface), and later its last row.
local function entry_of(stop)
	return { stop = stop, surface = stop.surface.name }
end

--- Circuit-controlled: its control behaviour sets the limit or the priority (U2's field names, Task 1's record). Nothing
--- announces a stop becoming one, so slow visits and builds refresh it.
local function circuit(stop)
	local cb = stop.get_control_behavior()
	return cb ~= nil and (cb.set_trains_limit or cb.set_priority) == true
end

--- Forget a stop that is gone: its removal goes at once, and the table's goals change.
function stops.forget(unit)
	local r = base.state()
	if r.stops[unit] then
		r.stops[unit], r.fast[unit] = nil, nil
		r.dirty = true
		base.send("ue.route.report", { stops_gone = { unit } })
	end
end

--- Read one stop: a changed row goes at once, as one small report. slow: a 10 s visit or a build, which also refreshes
--- its tier.
function stops.poll(unit, entry, slow)
	local r = base.state()
	local stop = entry.stop
	if not stop.valid then
		stops.forget(unit)
		return
	end
	if slow then
		r.fast[unit] = circuit(stop) and entry or nil
	end
	local now = stops.row(stop, entry.surface)
	if not base.same(entry.row, now) then
		entry.row = now
		base.send("ue.route.report", { stations = { now } })
	end
end

function stops.add(stop)
	local r = base.state()
	local entry = entry_of(stop)
	r.stops[stop.unit_number] = entry
	r.dirty = true -- a new goal
	stops.poll(stop.unit_number, entry, true)
end

--- At each resync (§7.7): the registry from every stop there is, on every surface, so a missed event heals. Rows go
--- with the full report.
function stops.rebuild()
	local r = base.state()
	r.stops, r.fast = {}, {}
	for _, stop in pairs(game.train_manager.get_train_stops{}) do
		local entry = entry_of(stop)
		r.stops[stop.unit_number] = entry
		r.fast[stop.unit_number] = circuit(stop) and entry or nil
	end
end

local function track(ent)
	return string.find(ent.type, "rail", 1, true) ~= nil -- rails of every kind, rail and chain signals
end

function stops.on_built(e)
	local ent = e.entity
	if not (ent and ent.valid) then
		return
	end
	if ent.type == "train-stop" then
		stops.add(ent)
	elseif track(ent) then
		base.state().dirty = true
	end
end

function stops.on_removed(e)
	local ent = e.entity
	if not (ent and ent.valid) then
		return
	end
	if ent.type == "train-stop" then
		stops.forget(ent.unit_number)
	elseif track(ent) then
		base.state().dirty = true
	end
end

function stops.on_renamed(e)
	local ent = e.entity
	local entry = ent and ent.valid and ent.type == "train-stop" and base.state().stops[ent.unit_number]
	if entry then
		stops.poll(ent.unit_number, entry, false)
	end
end

for _, name in ipairs({ "on_built_entity", "on_robot_built_entity", "script_raised_built", "script_raised_revive" }) do
	stops.events[defines.events[name]] = stops.on_built
end
for _, name in ipairs({ "on_player_mined_entity", "on_robot_mined_entity", "on_entity_died", "script_raised_destroy" }) do
	stops.events[defines.events[name]] = stops.on_removed
end
stops.events[defines.events.on_entity_renamed] = stops.on_renamed

scheduler.iterate{
	name = "ue.routing.stops",
	interval = 600,
	per_tick = 2,
	source = function()
		local r = base.state()
		return r and r.live and r.stops or nil
	end,
	fn = base.safe("ue.routing.stops", function(unit, entry)
		stops.poll(unit, entry, true)
	end),
}

-- ponytail: each circuit stop every ~1 s while the fast tier holds at most 120; beyond that the walk is the cadence (D17).
scheduler.iterate{
	name = "ue.routing.stops_fast",
	interval = 60,
	per_tick = 2,
	source = function()
		local r = base.state()
		return r and r.live and r.fast or nil
	end,
	fn = base.safe("ue.routing.stops_fast", function(unit, entry)
		stops.poll(unit, entry, false)
	end),
}

return stops
