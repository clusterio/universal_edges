-- The tile's table (D42 point 1, spec §7.8): from each inbound box (a start) to every outbound box and stop here on its
-- surface (the goals, R33), Factorio's own path cost, occupancy included. Starts and goals are re-made when rails change
-- or a box comes or goes; the costs refresh every 5 s, one start a tick, sending only changed rows. Every message stands
-- alone (§7.9, R8). Also the strip of the prototype's edge stops (§5.4).
local scheduler = require("modules/universal_edges/runtime/scheduler")
local geometry = require("modules/universal_edges/edges/geometry_core")
local base = require("modules/universal_edges/routing/base")
local stops = require("modules/universal_edges/routing/stops")

local tables = {}

local function scalar_size(v)
	return #tostring(v) + 2
end

--- Send messages, after the ue.routing table line that describes them (§10).
local function report(fields, messages)
	fields.parts = #messages
	if storage.universal_edges.stream_trace then -- D12's switch: 19 % of a day's log lines otherwise
		base.emit("ue.routing", "table", "verbose", nil, fields)
	end
	for _, m in ipairs(messages) do
		base.send("ue.route.report", m)
	end
end

local function append(into, list)
	for _, x in ipairs(list) do
		into[#into + 1] = x
	end
	return into
end

--- One visit of the cost walk (§7.8): one counted path search from start to every goal on its surface (R33: no row pairs
--- a start and a goal on different surfaces), diffed against the row last sent.
function tables.walk(key, start)
	local r = base.state()
	local goals, keys = {}, {}
	for _, g in ipairs(r.goals) do
		local goal = g.surface == start.surface and base.goal(g)
		if goal then
			goals[#goals + 1], keys[#keys + 1] = goal, g.key
		end
	end
	local row = {}
	if #goals > 0 and start.rail.valid then
		local res = base.path{ starts = { { rail = start.rail, direction = start.direction, is_front = true } }, goals = goals,
			type = "all-goals-penalties" }
		for i, ok in ipairs(res.accessible or {}) do
			if ok then
				row[keys[i]] = res.penalties[i]
			end
		end
	end
	local old, set, gone = r.last[key] or {}, {}, {}
	for to, cost in pairs(row) do
		if old[to] ~= cost then
			set[#set + 1] = { key, to, cost }
		end
	end
	for to in pairs(old) do
		if row[to] == nil then
			gone[#gone + 1] = { key, to }
		end
	end
	r.last[key] = row
	if #set > 0 or #gone > 0 then
		report({ costs = #set, gone = #gone }, append(base.parts("costs", set), base.parts("gone", gone)))
	end
end

tables.walk_safe = base.safe("ue.routing.costs", tables.walk)

scheduler.iterate{
	name = "ue.routing.costs",
	interval = 300,
	per_tick = 1,
	source = function()
		local r = base.state()
		return r and r.live and r.starts or nil
	end,
	fn = tables.walk_safe,
}

--- true when the starts or goals differ from the stored ones: a key added or gone, or its entity replaced.
local function moved(r, starts, goals)
	local n = 0
	for key, s in pairs(starts) do
		local old = r.starts[key]
		if not (old and old.rail == s.rail and old.direction == s.direction) then
			return true
		end
		n = n + 1
	end
	for _ in pairs(r.starts) do
		n = n - 1
	end
	if n ~= 0 or #goals ~= #r.goals then
		return true
	end
	local old = {}
	for _, g in ipairs(r.goals) do
		old[g.key] = g.rail or g.stop
	end
	for _, g in ipairs(goals) do
		if old[g.key] ~= (g.rail or g.stop) then
			return true
		end
	end
	return false
end

--- The full report a resync asks for (§7.8): { full = true } first, then every station and connector row; the walk
--- then sends every cost row again.
local function full(r, rows)
	r.full, r.last, r.conns = false, {}, {}
	local stations, conns = {}, {}
	for _, entry in pairs(r.stops) do
		if entry.stop.valid then
			entry.row = stops.row(entry.stop, entry.surface)
			stations[#stations + 1] = entry.row
		end
	end
	for key, row in pairs(rows) do
		r.conns[key] = row
		conns[#conns + 1] = row
	end
	report({ full = true, stations = #stations, conns = #conns },
		append(append({ { full = true } }, base.parts("stations", stations)), base.parts("conns", conns)))
	scheduler.wake("ue.routing.costs")
end

--- One 60-tick pass (§7.8): starts and goals re-made when the table is dirty or a box came or went (UE builds its boxes
--- without events), with gone for every row of a start that went and the walk woken; then the full report a resync asked
--- for, or the connector rows that changed (R13). No path search. Each start and goal carries its surface index, which
--- the walk matches (R33): a connector's is its edge side's, a stop's its own.
function tables.pass()
	local r = base.state()
	local starts, goals, rows = {}, {}, {}
	for _, c in ipairs(base.connectors()) do
		if c.start then
			starts["c:" .. c.key] = c.start
		end
		if c.goal then
			goals[#goals + 1] = { key = "c:" .. c.key, surface = c.surface, rail = c.goal.rail, dir = c.goal.dir }
		end
		rows[c.key] = c.state
	end
	for unit, entry in pairs(r.stops) do
		if entry.stop.valid and entry.stop.connected_rail then
			goals[#goals + 1] = { key = "s:" .. unit, surface = entry.stop.surface_index, stop = entry.stop }
		end
	end
	if r.dirty or moved(r, starts, goals) then
		local gone = {}
		for key in pairs(r.starts) do
			if not starts[key] then
				for to in pairs(r.last[key] or {}) do
					gone[#gone + 1] = { key, to }
				end
				r.last[key] = nil
			end
		end
		r.starts, r.goals, r.dirty = starts, goals, false
		if #gone > 0 then
			report({ gone = #gone }, base.parts("gone", gone))
		end
		scheduler.wake("ue.routing.costs")
	end
	if r.full then
		full(r, rows)
		return
	end
	local set, gone = {}, {}
	for key, row in pairs(rows) do
		if not base.same(r.conns[key], row) then
			r.conns[key] = row
			set[#set + 1] = row
		end
	end
	for key in pairs(r.conns) do
		if not rows[key] then
			r.conns[key] = nil
			gone[#gone + 1] = key
		end
	end
	if #set > 0 or #gone > 0 then
		report({ conns = #set + #gone }, append(base.parts("conns", set), base.parts("conns_gone", gone, scalar_size)))
	end
end

--- The strip (spec §5.4), once, before routing goes live: the prototype's edge stops destroyed (when their prototype
--- still exists, as in a game test; on a real upgrade Factorio removed them with it, U3), every record naming one removed
--- from every train, last index first, every interrupt target naming one removed, and every prototype station hop
--- cleared so its route asks again. The names are computed from the endpoints, as train.lua's build named them.
function tables.strip()
	local s = base.state()
	local names, destroyed, records, targets, routes = {}, 0, 0, 0, 0
	for _, ep in pairs(storage.universal_edges.eps.train or {}) do
		local d = ep.data
		if d.box == "outbound" then
			names[ep.edge .. " " .. geometry.col(ep.me, ep.frame.length, ep.col, ep.width)] = true
		end
		if d.stop then
			if d.stop.valid then
				d.stop.destroy()
				destroyed = destroyed + 1
			end
			d.stop = nil
		end
	end
	if next(names) then
		for _, tr in pairs(game.train_manager.get_trains{}) do
			local sched = tr.get_schedule()
			local recs = sched.get_records() or {}
			for i = #recs, 1, -1 do
				if recs[i].station and names[recs[i].station] then
					sched.remove_record{ schedule_index = i }
					records = records + 1
				end
			end
			for k, it in ipairs(sched.get_interrupts() or {}) do
				local kept = {}
				for _, target in ipairs(it.targets or {}) do
					if target.station and names[target.station] then
						targets = targets + 1
					else
						kept[#kept + 1] = target
					end
				end
				if #kept < #(it.targets or {}) then
					it.targets = kept
					sched.change_interrupt(k, it)
				end
			end
		end
	end
	for _, r in pairs(s.active) do
		if r.hop and r.hop.station then
			r.hop, r.unrouted = nil, true
			routes = routes + 1
		end
	end
	s.strip = false
	base.emit("ue.routing", "stripped", "info", nil, { stops = destroyed, records = records, targets = targets, routes = routes })
end

scheduler.periodic{
	name = "ue.routing.table",
	interval = 60,
	fn = base.safe("ue.routing.table", function()
		local r = base.state()
		if not r then
			return
		end
		if r.strip then
			tables.strip() -- §5.4, R25: at the first 60-tick pass, or at the first resync, whichever comes first
		end
		if r.live then
			tables.pass()
		end
	end),
}

return tables
