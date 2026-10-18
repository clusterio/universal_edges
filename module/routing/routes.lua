-- Routing a train on its tile (spec §6, §7). A train in no_path or destination_full asks, through the waiting set and
-- its walker (§6.1). A reply inserts only the next hop: the outbound box's end rail as a temporary record, found by its
-- rail's identity (D22, §5.3); while the train waits at a stop it is held, and goes in as the train leaves (owner
-- decision B, §6). The sweep visits every route every 5 s: lost, moved-on, manual and dead-hop routes, and
-- the quiet retry (§7.1, §7.2, §7.6). The route rides the crossing: capture; materialized with D22's goal guard; restored
-- for a refused crossing (§6.4, §7.5). Every 60 s the tile reports the routes and reservations it holds (§7.4). Route
-- state is anchored to one carriage, so a join's new train id doesn't lose it (SP3 §11).
local bridge = require("modules/universal_edges/runtime/bridge")
local bridge_core = require("modules/universal_edges/runtime/bridge_core")
local scheduler = require("modules/universal_edges/runtime/scheduler")
local ids = require("modules/universal_edges/runtime/trace")
local hooks = require("modules/universal_edges/transports/hooks")
local train = require("modules/universal_edges/transports/train")
local base = require("modules/universal_edges/routing/base")
local reservations = require("modules/universal_edges/routing/reservations")
local stops = require("modules/universal_edges/routing/stops")
local tables = require("modules/universal_edges/routing/tables")

local routes = { events = {} }
local STATE = defines.train_state
local ASK_WINDOW = 300 -- ticks an unrouted route waits, after its last ask, before check or the quiet retry asks again

local function waiting(state)
	return state == STATE.no_path or state == STATE.destination_full
end

--- A stop named name on surface, the train's own (R33): a stop on another planet of this tile is not local.
function routes.is_local(name, surface)
	return #game.train_manager.get_train_stops{ station_name = name, surface = surface } > 0
end

local function current_station(tr)
	local sched = tr.get_schedule()
	local i = sched.current
	if not (i and i >= 1 and i <= sched.get_record_count()) then
		return nil
	end
	local rec = sched.get_record{ schedule_index = i }
	return rec and rec.station
end

local function has_record(tr, name)
	for _, rec in ipairs(tr.get_schedule().get_records() or {}) do
		if rec.station == name then
			return true
		end
	end
	return false
end

--- The trace of the route this train follows: the first of its carriages that anchors one.
function routes.trace_of(tr)
	local by = base.state().by_unit
	for _, c in ipairs(tr.carriages) do
		local id = by[c.unit_number]
		if id then
			return id
		end
	end
end

--- A route's state on this tile, anchored to the train's first carriage. A trace seen here before (a train back on a
--- tile it crossed) replaces the old entry.
function routes.register(tr, id, dest, hops)
	local r = base.state()
	if r.active[id] then
		r.by_unit[r.active[id].unit] = nil
	end
	local anchor = tr.carriages[1]
	local route = { trace = id, anchor = anchor, unit = anchor.unit_number, dest = dest, hops = hops or {}, unrouted = true }
	r.active[id], r.by_unit[route.unit] = route, id
	return route
end

function routes.forget(id)
	local r = base.state()
	local route = r.active[id]
	if route then
		r.by_unit[route.unit], r.active[id] = nil, nil
	end
end

--- The hop's record: the outbound box's end rail on both layers (§5.3); nil when this tile has no outbound box for it.
local function hop_record(hop)
	local v = train.get(hop.edge, hop.cid)
	if not (v and v.box == "outbound") then
		return nil
	end
	return { rail = v.end_rail, temporary = true }
end

--- The schedule index of the route's hop, by its rail's identity (D22), or nil. T2-1: when the hop's rail is gone
--- (destroyed), the record Factorio left is a blank temporary one (no rail, no station); it is the hop's, the first such.
--- Records with a target are matched by rail identity only.
local function find_hop(sched, route)
	local rail = route.hop and route.hop.rail
	if not rail then
		return nil
	end
	local recs = sched.get_records() or {}
	if not rail.valid then
		for i, rec in ipairs(recs) do
			if rec.temporary and not rec.rail and (rec.station or "") == "" then
				return i
			end
		end
		return nil
	end
	for i, rec in ipairs(recs) do
		if rec.temporary and rec.rail and rec.rail.valid and rec.rail.unit_number == rail.unit_number then
			return i
		end
	end
end

function routes.remove_hop(tr, route)
	local sched = tr.get_schedule()
	local i = find_hop(sched, route)
	if i then
		sched.remove_record{ schedule_index = i }
	end
	route.hop, route.held = nil, nil
end

--- The train still runs the route's leg: its current record is the route's hop, or names its destination (review C1).
local function on_leg(tr, route)
	local sched = tr.get_schedule()
	local i = find_hop(sched, route)
	return (i ~= nil and i == sched.current) or current_station(tr) == route.dest
end

--- Put hop's record in at schedule index i (§5.3), and go there when i is the current record. False if hop isn't here.
--- add_record's own return value is where it went (U3, checked).
local function put(tr, route, hop, i)
	local rec = hop_record(hop)
	if not rec then
		return false
	end
	local sched = tr.get_schedule()
	local cur = sched.current
	rec.index = { schedule_index = i }
	local at = sched.add_record(rec)
	if i == cur then
		sched.go_to_station(at)
	end
	route.hop = { edge = hop.edge, cid = hop.cid, rail = rec.rail }
	base.emit("ue.route", "applied", "info", route.trace, { hop = hop.edge .. "/" .. hop.cid, train = tr.id })
	return true
end

--- Put hop's record ahead of the current record and go there (§5.3); nothing for no hop. An unchanged hop still found
--- by identity is left in place. False if hop isn't here. Owner decision B (§6's amendment, spike 15): 2.1.20 checks a
--- train's interrupts only as it leaves a stop, and skips them when its next record is temporary, so while the train
--- waits at a stop the hop is held on the route (route.held) and put in as it leaves (depart).
function routes.set_hop(tr, route, hop)
	if route.hop and hop and route.hop.edge == hop.edge and route.hop.cid == hop.cid and find_hop(tr.get_schedule(), route) then
		return true
	end
	routes.remove_hop(tr, route)
	if not hop then
		return true
	end
	if tr.state == STATE.wait_station and hop_record(hop) then
		route.held = { edge = hop.edge, cid = hop.cid }
		return true
	end
	return put(tr, route, hop, tr.get_schedule().current)
end

--- The request's origin away from a border (§6.1, R3, R4): the train's own path costs to every live outbound box and
--- every stop named dest, both on its own surface (R33), as full node keys (R23). A push-pull train's own request finds
--- its reversal (spike 8 Q4). One counted search.
local function firsts(tr, dest)
	local here = tr.front_stock.surface_index
	local goals, keys, out = {}, {}, {}
	for _, c in ipairs(base.connectors()) do
		local goal = c.surface == here and c.goal and c.state.live and base.goal(c.goal)
		if goal then
			goals[#goals + 1], keys[#keys + 1] = goal, "c:" .. c.key
		end
	end
	for _, stop in pairs(game.train_manager.get_train_stops{ station_name = dest, surface = here }) do
		if stop.connected_rail then -- a stop on no rail makes the search raise (playtest 2026-10-10)
			goals[#goals + 1], keys[#keys + 1] = stop, "s:" .. stop.unit_number
		end
	end
	if #goals > 0 then
		local res = base.path{ train = tr, goals = goals, type = "all-goals-penalties" }
		for i, ok in ipairs(res.accessible or {}) do
			if ok then
				out[#out + 1] = { keys[i], res.penalties[i] }
			end
		end
	end
	return out
end

--- Ask the controller (ue.route.request, §4.2), with the train's surface: only stops on it count (R31, R32). start says
--- why, for the requested line: "train", "border", "forgotten" or "automatic"; nil is the quiet 5 s retry, which logs
--- nothing (one line per train, D42 point 4). Logged before it is sent.
function routes.request(tr, route, via, start)
	local surface = tr.front_stock.surface.name
	local q = { trace = route.trace, dest = route.dest, surface = surface, via = via }
	if not via then
		q.firsts = firsts(tr, route.dest)
	end
	route.unrouted = true
	route.asked = game.tick
	if start then
		base.emit("ue.route", "requested", "info", route.trace,
			{ dest = route.dest, surface = surface, train = tr.id, start = start, via = via })
	end
	base.send("ue.route.request", q)
end

local function lose(id, reason, level)
	base.emit("ue.route", "lost", level or "warn", id, { reason = reason })
	base.send("ue.route.lost", { trace = id, reason = reason })
end

--- The route's wait is over: its train left the leg (the full stop freed, an interrupt fired, the player sent it on).
--- The normal end of a wait, not a fault: logged at info (review C1).
local function moved_on(tr, route)
	routes.remove_hop(tr, route)
	routes.forget(route.trace)
	lose(route.trace, "moved_on", "info")
end

--- A train from the waiting set (§6.1). A route the controller forgot asks again under its own trace (§7.4). Otherwise only
--- a train in no_path or destination_full: a route whose train left its leg ends moved_on and the train is treated
--- afresh (C1); a routed train in no_path re-routes mid-tile (§7.2); an unrouted one asks again (plan ruling 10); a train
--- with no route asks (a remote stop, a full one, or a local one only reachable through another tile).
function routes.check(unit)
	local c = game.get_entity_by_unit_number(unit)
	local tr = c and c.valid and c.train
	if not tr then
		return
	end
	local r = base.state()
	local id = routes.trace_of(tr)
	local route = id and r.active[id]
	if route and route.reask then
		route.reask = nil
		if not (route.captured or tr.manual_mode) then
			routes.request(tr, route, nil, "forgotten")
		end
		return
	end
	local state = tr.state
	if not waiting(state) then
		return
	end
	if route and not on_leg(tr, route) then
		moved_on(tr, route)
		route = nil
	end
	if route then
		if not route.unrouted then
			if state ~= STATE.no_path then
				return
			end
			routes.remove_hop(tr, route)
		elseif game.tick - (route.asked or 0) < ASK_WINDOW then
			return -- just asked, by moved_on's register a tick ago, say: the reply or the quiet retry is next
		end
		routes.request(tr, route, nil, "train")
		return
	end
	local dest = current_station(tr)
	if dest then
		routes.request(tr, routes.register(tr, ids.new_id(), dest, {}), nil, "train")
	end
end

--- At each resync (§6.1): every train already waiting, and any whose event was missed, goes to the walker.
function routes.queue_waiting()
	local r = base.state()
	for _, tr in pairs(game.train_manager.get_trains{}) do
		if waiting(tr.state) then
			r.waiting[tr.carriages[1].unit_number] = true
		end
	end
end

--- One route's sweep visit, every 5 s (§7.1, §7.2, §7.5, §7.6). A captured route is skipped: a held train's schedule is
--- never edited (FR M9), and once the commit destroys it the destination carries the route on. A manual train's route
--- asks the controller to release its reservation, once; back to automatic, it asks again at once. Then: lost, moved
--- on, the quiet retry, arrived by a stop built here after the plan, or a hop whose box stopped being crossable. A train
--- that needs checking again goes to the waiting set, never checked inside this visit.
function routes.visit(id, route)
	local r = base.state()
	if route.captured then
		if not route.anchor.valid then
			routes.forget(id)
		end
		return
	end
	local tr = route.anchor.valid and route.anchor.train
	if not tr then
		routes.forget(id)
		lose(id, "destroyed")
		return
	end
	if tr.manual_mode then
		if not route.manual then
			route.manual = true
			base.emit("ue.route", "manual", "info", id, { train = tr.id })
			base.send("ue.route.manual", { trace = id })
		end
		return
	end
	if route.manual then
		route.manual = nil
		routes.request(tr, route, nil, "automatic")
		return
	end
	if not has_record(tr, route.dest) then
		routes.remove_hop(tr, route)
		routes.forget(id)
		lose(id, "schedule_changed")
		r.waiting[route.unit] = true
	elseif route.held and tr.state == STATE.wait_station then
		return -- B: a held hop waits out the stop; depart() checks the leg as the train leaves
	elseif route.unrouted and not on_leg(tr, route) then
		moved_on(tr, route)
		r.waiting[route.unit] = true
	elseif route.unrouted then
		if waiting(tr.state) and game.tick - (route.asked or 0) >= ASK_WINDOW then
			routes.request(tr, route)
		end
	elseif not route.hop and not route.held and routes.is_local(route.dest, tr.front_stock.surface_index) then
		routes.forget(id)
		base.emit("ue.route", "arrived", "info", id, { dest = route.dest })
		base.send("ue.route.arrived", { trace = id })
		r.waiting[route.unit] = true
	elseif route.hop and not base.live(route.hop.edge, route.hop.cid) then
		routes.remove_hop(tr, route)
		routes.request(tr, route, nil, "train")
	end
end

--- I2's report (§7.4): every route on this tile and every reservation it holds, in parts of at most 3000 bytes that each
--- stand alone. Nothing when both are empty.
function routes.alive()
	local r = base.state()
	local rows = {}
	for id in pairs(r.active) do
		rows[#rows + 1] = { "active", id }
	end
	for id in pairs(r.reserved) do
		rows[#rows + 1] = { "reserved", id }
	end
	if #rows == 0 then
		return
	end
	local envelope = #helpers.table_to_json({ active = { "" }, reserved = { "" } })
	for _, chunk in ipairs(bridge_core.split(rows, function(row) return #row[2] + 3 end, base.BUDGET - envelope)) do
		local part = { active = {}, reserved = {} }
		for _, row in ipairs(chunk) do
			local list = part[row[1]]
			list[#list + 1] = row[2]
		end
		base.send("ue.route.alive", part)
	end
end

--- B: the train has left a stop, after the engine's interrupt check, and the hop held during its wait goes in. Records
--- an interrupt added at this departure are current; the hop goes behind them, ahead of the destination, so the train
--- serves the interrupt on this tile, then takes its hop with its route (§11.4 item 3a); a remote interrupt target puts
--- the train in no_path, and check() ends the route moved_on as before (item 3b). The leg is checked here, not at the
--- reply (a waiting train's current record is its stop): a train whose next record isn't the destination left its leg
--- (C1). A manual train is left alone (FR M1): the manual release's re-ask routes it again (§7.6). True when the hop
--- went in as the current record: the train is routed, not waiting. Under base.safe (R7): it runs in an event.
local depart = base.safe("ue.routing.depart", function(tr)
	local r = base.state()
	local id = routes.trace_of(tr)
	local route = id and r.active[id]
	local hop = route and route.held
	if not hop then
		return false
	end
	route.held = nil -- unrouted stays true until put succeeds: the sweep's retry asks again after a manual or failed hop
	if tr.manual_mode or route.captured then
		return false
	end
	local sched = tr.get_schedule()
	local cur, n = sched.current, sched.get_record_count()
	local i = cur
	while i <= n and sched.get_record{ schedule_index = i }.created_by_interrupt do
		i = i + 1
	end
	if not (i <= n and sched.get_record{ schedule_index = i }.station == route.dest) then
		moved_on(tr, route)
		r.waiting[route.unit] = true
		return false
	end
	if not put(tr, route, hop, i) then
		return false
	end
	route.unrouted = false
	return i == cur
end)

routes.events[defines.events.on_train_changed_state] = function(e)
	local tr = e.train
	if not tr.valid then
		return
	end
	-- B: leaving a stop puts its held hop in; a train whose hop went in as its current record is routed, not waiting
	if e.old_state == STATE.wait_station and depart(tr) then
		return
	end
	if waiting(tr.state) then
		base.state().waiting[tr.carriages[1].unit_number] = true -- O(1); the set dedupes repeated events (§6.1)
	end
end

-- R6: the waiting set and its walker replace the prototype's capped one-tick queue (FR M8). A train's check runs no
-- earlier than the call that raised its event returns, so a crossing's materialized registers its route first.
scheduler.iterate{
	name = "ue.routing.waiting",
	per_tick = 4,
	source = function()
		local r = base.state()
		return r and r.live and r.waiting or nil
	end,
	fn = base.safe("ue.routing.waiting", function(unit)
		base.state().waiting[unit] = nil
		routes.check(unit)
	end),
}

scheduler.iterate{
	name = "ue.routing.sweep",
	interval = 300,
	per_tick = 4,
	source = function()
		local r = base.state()
		return r and r.live and r.active or nil
	end,
	fn = base.safe("ue.routing.sweep", function(id, route)
		routes.visit(id, route)
	end),
}

scheduler.periodic{
	name = "ue.routing.alive",
	interval = 3600,
	fn = base.safe("ue.routing.alive", function()
		local r = base.state()
		if r and r.live then
			routes.alive()
		end
	end),
}

--- The controller's answer (§6.3): no route or no train, ignored; a manual or captured train left alone (FR M1, plan
--- ruling 9); a train off its leg ends moved_on and is checked again; ok puts in the next hop (held while the train
--- waits at a stop, B); local drops the carried hop so the train paths to the local stop that won; any other failure
--- leaves the route unrouted for the quiet retry.
bridge.on("universal_edges", "ue.route.reply", function(p)
	if type(p.trace) ~= "string" or type(p.ok) ~= "boolean" then
		return false
	end
	local r = base.state()
	local route = r and r.active[p.trace]
	local tr = route and route.anchor.valid and route.anchor.train
	if not tr or tr.manual_mode or route.captured then
		return
	end
	-- B: a train waiting at a stop has the stop as its current record; its leg is checked as it leaves (depart)
	if tr.state ~= STATE.wait_station and not on_leg(tr, route) then
		moved_on(tr, route)
		r.waiting[route.unit] = true
		return
	end
	if p.ok then
		local hops = {}
		for _, h in ipairs(type(p.hops) == "table" and p.hops or {}) do
			if type(h) == "table" and type(h.edge) == "string" and type(h.cid) == "string" then
				hops[#hops + 1] = { edge = h.edge, cid = h.cid }
			end
		end
		route.hops = hops
		route.unrouted = not routes.set_hop(tr, route, hops[1]) or route.held ~= nil -- a held hop isn't in yet (B)
	elseif p.reason == "local" then
		routes.remove_hop(tr, route)
	end
end)

--- The controller's resync at a tile's start (§7.3): the strip first if it is still to run (§5.4, R25); routing is
--- live; a full table is due; the stop registry is rebuilt; the reservations become the controller's list; and every
--- waiting train goes to the walker.
bridge.on("universal_edges", "ue.route.resync", function(p)
	if type(p.reservations) ~= "table" then
		return false
	end
	local r = base.state()
	if r.strip then
		tables.strip()
	end
	r.live, r.full, r.dirty = true, true, true
	stops.rebuild()
	reservations.resync(p.reservations)
	routes.queue_waiting()
end)

--- Routes this tile reported that the controller doesn't know (§7.4): each with a valid train that is neither captured
--- nor manual asks again under its own trace, through the walker; one with no train is forgotten silently.
bridge.on("universal_edges", "ue.route.forgotten", function(p)
	if type(p.traces) ~= "table" then
		return false
	end
	local r = base.state()
	for _, id in ipairs(p.traces) do
		local route = type(id) == "string" and r.active[id]
		if route then
			local tr = route.anchor.valid and route.anchor.train
			if not tr then
				routes.forget(id)
			elseif not (route.captured or tr.manual_mode) then
				route.reask = true
				r.waiting[route.unit] = true
			end
		end
	end
end)

-- The route rides the crossing (D42, SP3 §11, §6.4). The name is the prototype's (plan ruling 7). capture runs in the
-- source's capture and is deterministic (D21). materialized runs on the destination once the first batch exists, after
-- UE's records and go_to_station and before manual_mode and speed (SP3 §12.5 step 5). restored runs when UE gives a
-- captured train back (§7.5).
hooks.extend{
	name = "router",
	types = { train = true },
	capture = function(ep, tr)
		local id = routes.trace_of(tr)
		local route = id and base.state().active[id]
		if not route then
			return nil
		end
		route.captured = true
		local rest, past = {}, false
		for _, h in ipairs(route.hops) do
			if past then
				rest[#rest + 1] = { edge = h.edge, cid = h.cid }
			end
			past = past or (h.edge == ep.edge and h.cid == ep.cid)
		end
		return { trace = id, dest = route.dest, hops = rest }
	end,
	materialized = function(ep, tr, data)
		if type(data) ~= "table" or type(data.trace) ~= "string" or type(data.dest) ~= "string" then
			return
		end
		local r = base.state()
		local hops = {}
		for _, h in ipairs(type(data.hops) == "table" and data.hops or {}) do
			if type(h) == "table" and type(h.edge) == "string" and type(h.cid) == "string" then
				hops[#hops + 1] = { edge = h.edge, cid = h.cid }
			end
		end
		-- D22's goal guard (R17): the route is this train's only while its destination is still a record, and is the
		-- record UE made current.
		if not has_record(tr, data.dest) then
			lose(data.trace, "schedule_changed")
			r.waiting[tr.carriages[1].unit_number] = true
			return
		end
		if current_station(tr) ~= data.dest then
			lose(data.trace, "moved_on", "info")
			r.waiting[tr.carriages[1].unit_number] = true
			return
		end
		-- arrived only where the route ends (no carried hops left), not at a stop here that only shares the name (review I1)
		if #hops == 0 and routes.is_local(data.dest, tr.front_stock.surface_index) then
			local sched = tr.get_schedule()
			-- D43: release first, then path again: UE's go_to_station ran while our reservation made the stop look full
			local stop = r.reserved[data.trace]
			local held = reservations.drop(data.trace, "released", "arrived")
			local old
			if held then
				-- the train is new on this tile; vanilla keeps a train heading for a stop when its limit drops. The slot
				-- is taken inside go_to_station and the limit put back in this handler, nothing runs between (spike 48).
				if stop.valid and stop.trains_count >= stop.trains_limit then
					old = stop.trains_limit
					stop.trains_limit = stop.trains_count + 1
				end
				sched.go_to_station(sched.current)
				if old then
					stop.trains_limit = old
				end
			end
			base.emit("ue.route", "arrived", held and "info" or "warn", data.trace,
				{ dest = data.dest, edge = ep.edge, cid = ep.cid, raised = old and true or nil })
			base.send("ue.route.arrived", { trace = data.trace })
			return
		end
		local route = routes.register(tr, data.trace, data.dest, hops)
		routes.set_hop(tr, route, hops[1]) -- the carried next hop at once, so the train doesn't stand in the inbound box
		routes.request(tr, route, ep.key, "border") -- and ask again: the re-route at every border
	end,
	restored = function(ep, tr, why)
		local r = base.state()
		local id = r and routes.trace_of(tr)
		local route = id and r.active[id]
		if not route then
			return
		end
		route.captured = false
		if why ~= "close" then
			base.emit("ue.route", "rejected", "warn", id, { why = why, edge = ep.edge, cid = ep.cid })
		end
	end,
}

return routes
