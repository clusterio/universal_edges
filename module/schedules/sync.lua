-- Train groups and interrupts, cluster-wide (train group sync spec, approach B): this tile's half. The cache holds the
-- cluster's groups and interrupts with their versions (§3). A local edit, found from on_train_schedule_changed (§5.1) or
-- by the sweep (§5.4), is reported; a cluster change is written in through a transient helper locomotive on the hidden
-- surface ue-sched (§5.2), so no real train is ever the one written to. sync.join puts a train in a group as vanilla
-- would (§5.6, §5.7). Everything goes out through sync.send and every write through sync.write: module fields, which the
-- game tests wrap to count them.
local bridge = require("modules/universal_edges/runtime/bridge")
local bridge_core = require("modules/universal_edges/runtime/bridge_core")
local scheduler = require("modules/universal_edges/runtime/scheduler")
local core = require("modules/universal_edges/schedules/sync_core")

local sync = { SURFACE = "ue-sched" }
sync.send = bridge.channel("universal_edges")
--- Interrupts first: the controller (and every tile) has an interrupt's content before a group that names it.
local KINDS = { "interrupt", "group" }

--- storage.universal_edges.schedules, or nil before UE's migration 9 has run.
function sync.state()
	local s = storage.universal_edges
	return s and s.schedules
end

--- One ue.sched line (§8): { op, phase, level, tick, kind?, name?, v?, ... }. The instance's own log fields name the tile.
function sync.emit(phase, level, fields)
	fields.op, fields.phase, fields.level, fields.tick = "ue.sched", phase, level, game.tick
	sync.send("trace", fields)
end

--- A train's group, or nil for none (LuaTrain.group reads "" then: spike 16's U1 lines print it empty).
function sync.group_of(tr)
	local g = tr.group
	return g ~= "" and g or nil
end

--- Record h (a canonical content string) as what this tile holds of (kind, name), now.
function sync.mark(kind, name, h)
	sync.state().hash[kind][name] = { h = h, t = game.tick }
end

--- The content of (kind, name) as train tr holds it; nil when tr no longer holds that interrupt or is no longer in that group.
function sync.read(kind, tr, name)
	local sched = tr.get_schedule()
	local its = sched.get_interrupts() or {}
	if kind == "group" then
		if sync.group_of(tr) ~= name then
			return nil
		end
		return core.group_content(sched.get_records() or {}, its)
	end
	for _, it in ipairs(its) do
		if it.name == name then
			return core.interrupt_content(it)
		end
	end
end

-- The helper (§5.2) -----------------------------------------------------------------------------------------------------

--- The hidden surface ue-sched: lab tiles, one row of 9 straight rails at y = 1, hidden from the player force. Made by the
--- ue.sched.full handler, at the tile's start. Gridworld leaves it alone: each of its per-surface handlers looks the
--- surface up in storage.gridworld.tiles, which only planets enter (gridworld/module/tile.lua, W16).
local function surface()
	local s = game.get_surface(sync.SURFACE)
	if s then
		return s
	end
	s = game.create_surface(sync.SURFACE)
	s.generate_with_lab_tiles, s.always_day = true, true
	s.request_to_generate_chunks({ 0, 0 }, 1)
	s.force_generate_chunk_requests()
	for x = 1, 17, 2 do
		s.create_entity{ name = "straight-rail", position = { x, 1 }, direction = defines.direction.east, force = "player" }
	end
	game.forces.player.set_surface_hidden(s, true)
	return s
end

--- Write the cluster's content for (kind, name) into this tile (§5.2) through a manual, unfuelled locomotive on ue-sched,
--- destroyed before this returns. A group's helper joins it, adopting the local version; set_records and set_interrupts
--- then rewrite the whole group. An interrupt's helper adds it and changes it, which pushes the content to every train
--- here holding the name (spike 16 U2b). What the helper reads back is recorded (plan ruling 3), so the write's own echo
--- reports nothing. Returns true, or false when it raised (logged as failed).
function sync.write(kind, name, content)
	local e
	local ok, err = pcall(function()
		e = surface().create_entity{ name = "locomotive", position = { 9, 1 }, orientation = 0.25, force = "player",
			snap_to_train_stop = false }
		local tr = e.train
		tr.manual_mode = true
		if kind == "group" then
			tr.group = name
			local sched = tr.get_schedule()
			local seed = core.schedule_of(content, sync.state().cache.interrupt)
			sched.set_records(seed.records)
			sched.set_interrupts(seed.interrupts)
		else
			local sched = tr.get_schedule()
			sched.add_interrupt(content)
			sched.change_interrupt(1, content)
		end
		sync.mark(kind, name, core.canon(sync.read(kind, tr, name)))
	end)
	if e and e.valid then
		e.destroy()
	end
	if not ok then
		sync.emit("failed", "error", { kind = kind, name = name, error = tostring(err) })
	end
	return ok
end

-- Cluster changes (§5.2) ------------------------------------------------------------------------------------------------

--- A cluster version of (kind, name): cached, and written in when this tile holds the name (it has a hash) with other
--- content. A report of the name awaiting its answer is answered: a change seen meanwhile is checked now (plan ruling 4).
--- quiet (a full) logs only writes. Returns whether it wrote.
function sync.apply(kind, name, v, content, quiet)
	local st = sync.state()
	st.cache[kind][name] = { v = v, content = content }
	local again = st.pending[kind][name]
	st.pending[kind][name] = nil
	local had = st.hash[kind][name]
	local wrote = had ~= nil and had.h ~= core.canon(content) and sync.write(kind, name, content) or false
	if wrote or not quiet then
		sync.emit("set", "info", { kind = kind, name = name, v = v, wrote = wrote })
	end
	if again and again ~= true and again.valid then
		local c = sync.read(kind, again, name)
		if c then
			sync.check(kind, name, c, again)
		end
	end
	return wrote
end

local function named(p)
	return (p.kind == "group" or p.kind == "interrupt") and type(p.name) == "string"
end

local function entry(p)
	return type(p) == "table" and named(p) and type(p.v) == "number" and type(p.content) == "table"
end

--- ue.sched.set (§5.2): one cluster version.
bridge.on("universal_edges", "ue.sched.set", function(p)
	if not entry(p) then
		return false
	end
	sync.apply(p.kind, p.name, p.v, p.content)
end)

--- ue.sched.drop (§5.5): the cluster's last train holding the name is gone; the cache forgets it.
bridge.on("universal_edges", "ue.sched.drop", function(p)
	if not named(p) then
		return false
	end
	sync.state().cache[p.kind][p.name] = nil
	sync.emit("drop", "info", { kind = p.kind, name = p.name })
end)

--- ue.sched.totals: every group's trains cluster-wide and per tile, replacing the last. Absent until the first one: unknown.
bridge.on("universal_edges", "ue.sched.totals", function(p)
	if type(p.groups) ~= "table" then
		return false
	end
	local totals = {}
	for _, g in ipairs(p.groups) do
		if type(g) ~= "table" or type(g[1]) ~= "string" or type(g[2]) ~= "number" or type(g[3]) ~= "table" then
			return false
		end
		local tiles = {}
		for i, t in ipairs(g[3]) do
			if type(t) ~= "table" or type(t[1]) ~= "string" or type(t[2]) ~= "number" then
				return false
			end
			tiles[i] = { name = t[1], n = t[2], stopped = t[3] == true }
		end
		totals[g[1]] = { n = g[2], tiles = tiles }
	end
	sync.state().totals = totals
end)

--- ue.sched.full (§5.2): the whole cluster set, at this tile's start. The cache is replaced, no report awaits an answer
--- any more, every entry is applied (interrupts first), and the tile is live.
bridge.on("universal_edges", "ue.sched.full", function(p)
	if type(p.entries) ~= "table" then
		return false
	end
	local st = sync.state()
	st.cache, st.pending = { group = {}, interrupt = {} }, { group = {}, interrupt = {} }
	local count, wrote = 0, 0
	for _, kind in ipairs(KINDS) do
		for _, e in ipairs(p.entries) do
			if entry(e) and e.kind == kind then
				count = count + 1
				if sync.apply(kind, e.name, e.v, e.content, true) then
					wrote = wrote + 1
				end
			end
		end
	end
	-- Made here, at the tile's start, not by the first write: creating the surface and generating its chunk costs about
	-- 16 ms (sched-sync bench), a hitch if it fell in a running tile's tick.
	surface()
	st.sent = nil -- the controller may have lost the counts; the next walk's end sends them again
	st.live = true
	sync.emit("full", "info", { entries = count, wrote = wrote })
end)

-- Local edits (§5.1) ----------------------------------------------------------------------------------------------------

--- Report (kind, name)'s content as this tile's edit of the cache's version, or as a new name (no base); it awaits its
--- answer (pending).
function sync.report(kind, name, content, h)
	local st = sync.state()
	local cached = st.cache[kind][name]
	sync.mark(kind, name, h)
	st.pending[kind][name] = true
	sync.send("ue.sched.report", { kind = kind, name = name, base = cached and cached.v, content = content })
	sync.emit("report", "info", { kind = kind, name = name, base = cached and cached.v })
end

--- (kind, name)'s content as train tr holds it now (§5.1). As recorded: nothing (a write's echo). A report of the name
--- awaits its answer: this change is checked once it comes (plan ruling 4). First seen here (no hash) while the cluster
--- has the name: the cluster's content is written in, as vanilla's join would give it (plan ruling 2). Otherwise it is
--- reported.
function sync.check(kind, name, content, tr)
	local st = sync.state()
	local h = core.canon(content)
	local had, cached = st.hash[kind][name], st.cache[kind][name]
	if had and had.h == h then
		had.t = game.tick
	elseif st.pending[kind][name] then
		st.pending[kind][name] = tr or true
	elseif not had and cached then
		if core.canon(cached.content) == h then
			sync.mark(kind, name, h)
		elseif sync.write(kind, name, cached.content) then
			sync.emit("set", "info", { kind = kind, name = name, v = cached.v, wrote = true, appeared = true })
		end
	else
		sync.report(kind, name, content, h)
	end
end

--- One changed train (§5.1): each of its interrupts, then its group, each name read once per pass (seen).
function sync.inspect(tr, seen)
	local sched = tr.get_schedule()
	local its = sched.get_interrupts() or {}
	for _, it in ipairs(its) do
		if not seen.interrupt[it.name] then
			seen.interrupt[it.name] = true
			sync.check("interrupt", it.name, core.interrupt_content(it), tr)
		end
	end
	local g = sync.group_of(tr)
	if g and not seen.group[g] then
		seen.group[g] = true
		sync.check("group", g, core.group_content(sched.get_records() or {}, its), tr)
	end
end

--- on_train_schedule_changed (§5.1): the train is read once by the next pass, however many events it raised. A tile that
--- isn't live yet marks nothing.
function sync.on_changed(e)
	local st = sync.state()
	if st and st.live and e.train.valid then
		st.dirty[e.train.id] = e.train
	end
end

-- Joining (§5.6, §5.7) --------------------------------------------------------------------------------------------------

--- Put train tr in group name as vanilla would (§5.6 step 1, §5.7). It leaves any other group first, keeping its own
--- copy, so no other group is rewritten. With members here it adopts their version (already the cluster's). With none it
--- is seeded first: from the cache, or from carried ({ records, interrupts }) when the cluster doesn't know the name;
--- set_records and set_interrupts on a group-less train touch nothing else. trace: the crossing's, for the seeded line.
--- Returns how: "adopted", "seeded" or "carried".
function sync.join(tr, name, carried, trace)
	if sync.group_of(tr) == name then
		return "adopted"
	end
	if sync.group_of(tr) then
		tr.group = nil
	end
	local how = "adopted"
	if #game.train_manager.get_trains{ group = name } == 0 then
		local st = sync.state()
		local cached = st.cache.group[name]
		local seed = cached and core.schedule_of(cached.content, st.cache.interrupt) or carried
		how = cached and "seeded" or "carried"
		if seed then
			local sched = tr.get_schedule()
			sched.set_records(seed.records)
			sched.set_interrupts(seed.interrupts)
		end
		sync.emit("seeded", "info", { kind = "group", name = name, v = cached and cached.v, from = how, trace = trace })
	end
	tr.group = name
	return how
end

--- The pass: every train marked since the last one. The set is swapped first, so a write's own events land in the next
--- pass, never in this loop. One next() a tick when nothing changed.
scheduler.periodic{
	name = "ue.sched.dirty",
	interval = 1,
	fn = function()
		local st = sync.state()
		if not (st and next(st.dirty)) then
			return 0
		end
		local dirty, seen = st.dirty, { group = {}, interrupt = {} }
		st.dirty = {}
		for _, tr in pairs(dirty) do
			if tr.valid then
				sync.inspect(tr, seen)
			end
		end
	end,
}

-- The sweep (§5.4, §5.5) ------------------------------------------------------------------------------------------------

--- Trains the walk reads a tick: 1,000 trains in 200 ticks (§7: inside 0.1 ms a tick at U7's read cost, plan ruling C9).
local WALK = 5
--- The counts' messages stay within this many bytes of JSON, as routing's do (base.BUDGET).
local BUDGET = 3000
--- Names one walk's end reports or checks; the rest wait for the next walk (plan ruling C7: a large first start).
local MAX_REPORTS = 100

--- One train's names in the walk's counts, and one holder per name for sweep_end.
function sync.tally(w, tr)
	local g = sync.group_of(tr)
	if g then
		w.group[g] = (w.group[g] or 0) + 1
		w.holder.group[g] = w.holder.group[g] or tr
	end
	for _, it in ipairs(tr.get_schedule().get_interrupts() or {}) do
		w.interrupt[it.name] = (w.interrupt[it.name] or 0) + 1
		w.holder.interrupt[it.name] = w.holder.interrupt[it.name] or tr
	end
end

--- The counts to the controller (§5.4), only when they changed since the last sent, in messages within BUDGET; the
--- first has first = true, which replaces this tile's counts there.
function sync.send_counts(st, w)
	local rows = core.count_rows(w.group, w.interrupt)
	local key = core.canon(rows)
	if key == st.sent then
		return
	end
	st.sent = key
	local parts = bridge_core.split(rows, function(r)
		return #r[2] + 20
	end, BUDGET)
	for i, part in ipairs(#parts > 0 and parts or { {} }) do
		sync.send("ue.sched.counts", { first = i == 1 or nil, rows = part })
	end
	sync.emit("counts", "verbose", { names = #rows, parts = math.max(#parts, 1) })
end

--- A walk's end (§5.4, §5.5). Each name the walk counted that the cache lacks is reported as new: a seed raises no event
--- (spike 16 U3), so this is where a group made on a tile is first seen. Each it counted that this tile has no hash for
--- is checked, which takes the cluster's content (plan ruling 2). At most MAX_REPORTS names a walk; the rest are met
--- again by the next one. A name whose report awaits its answer waits. A hash whose name the walk didn't count,
--- untouched since the walk began, is forgotten: the name is first seen again when it comes back (plan ruling 5). Then
--- the counts.
function sync.sweep_end(st, w)
	local budget = MAX_REPORTS
	for _, kind in ipairs(KINDS) do
		for name, tr in pairs(w.holder[kind]) do
			if budget > 0 and tr.valid and not st.pending[kind][name]
				and not (st.cache[kind][name] and st.hash[kind][name]) then
				local content = sync.read(kind, tr, name)
				if content then
					budget = budget - 1
					if st.cache[kind][name] then
						sync.check(kind, name, content, tr)
					else
						sync.report(kind, name, content, core.canon(content))
					end
				end
			end
		end
		for name, had in pairs(st.hash[kind]) do
			if not w[kind][name] and had.t < w.began then
				st.hash[kind][name] = nil
			end
		end
	end
	sync.send_counts(st, w)
end

--- Every 600 ticks (about 10 s, §5.4) a walk over every train here begins, unless the last one is still going.
scheduler.periodic{
	name = "ue.sched.sweep",
	interval = 600,
	fn = function(tick)
		local st = sync.state()
		if st and st.live and not st.walk then
			st.walk = { list = game.train_manager.get_trains{}, i = 1, began = tick, group = {}, interrupt = {},
				holder = { group = {}, interrupt = {} } }
		end
	end,
}

--- The walk: WALK trains a tick, then sweep_end. One lookup a tick between walks.
scheduler.periodic{
	name = "ue.sched.walk",
	interval = 1,
	fn = function()
		local st = sync.state()
		local w = st and st.walk
		if not w then
			return 0
		end
		local last = math.min(w.i + WALK - 1, #w.list)
		for i = w.i, last do
			local tr = w.list[i]
			if tr.valid then
				sync.tally(w, tr)
			end
		end
		w.i = last + 1
		if w.i > #w.list then
			st.walk = nil
			sync.sweep_end(st, w)
		end
	end,
}

return sync
