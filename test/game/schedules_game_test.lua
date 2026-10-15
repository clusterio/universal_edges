local t = require("modules/v2_test/testlib")
-- Factorio allows require only while the file loads, never inside a step.
local bridge = require("modules/universal_edges/runtime/bridge")
local sync = require("modules/universal_edges/schedules/sync")
local panel = require("modules/universal_edges/routing/panel")
local seams = require("modules/universal_edges/transports/train_seams")

-- Train group sync's game tests (sync spec §8), on the lab surface "sgsync", ticks 190-1350 (the plan's File Structure
-- lists each case's rows and ticks). Group and interrupt names start "SG ", unique per case: both are per save, across
-- surfaces (spike 16 U2, U4). The tile goes live at tick 200, so the sync reads every train in the save from then on; it
-- only writes names this file delivers. sync.send and sync.write are wrapped at load, so a case can count what the sync
-- sent and wrote whatever tick it happened in.

local n = 0
--- One controller message into this tile's Lua, as the instance's bridge delivers it.
local function deliver(msg_type, payload)
	n = n + 1
	bridge.inbox("universal_edges", helpers.table_to_json({ { id = "5c4ed000." .. n, type = msg_type, payload = payload } }))
end

local sent, writes = {}, {}
local send, write = sync.send, sync.write
sync.send = function(msg_type, payload)
	sent[#sent + 1] = { type = msg_type, payload = payload, tick = game.tick }
	return send(msg_type, payload)
end
sync.write = function(kind, name, content)
	writes[#writes + 1] = { kind = kind, name = name, tick = game.tick }
	return write(kind, name, content)
end

--- The ue.sched.report payloads for name sent at or after tick from.
local function reports(name, from)
	local out = {}
	for _, m in ipairs(sent) do
		if m.type == "ue.sched.report" and m.payload.name == name and m.tick >= from then
			out[#out + 1] = m.payload
		end
	end
	return out
end

--- The helper writes of name at or after tick from.
local function writes_of(name, from)
	local out = {}
	for _, w in ipairs(writes) do
		if w.name == name and w.tick >= from then
			out[#out + 1] = w
		end
	end
	return out
end

local function surface()
	local s = game.get_surface("sgsync")
	if not s then
		s = game.create_surface("sgsync")
		s.generate_with_lab_tiles, s.always_day = true, true
	end
	return s
end

--- Straight rails from x = 1 to x2 along row y of sgsync (odd y: rails sit on the 2-tile grid), its chunks generated first.
local function line(y, x2)
	local s = surface()
	for x = 0, x2 + 32, 32 do
		s.request_to_generate_chunks({ x, y }, 0)
	end
	s.force_generate_chunk_requests()
	local rails = {}
	for x = 1, x2, 2 do
		rails[x] = assert(s.create_entity{ name = "straight-rail", position = { x, y }, direction = defines.direction.east,
			force = "player" }, "rail at " .. x .. "," .. y)
	end
	return rails
end

--- A one-locomotive train on its own 61-tile line on row y, facing east, 50 coal, manual (a new train is).
local function loco(y)
	line(y, 61)
	local e = assert(surface().create_entity{ name = "locomotive", position = { 31, y }, orientation = 0.25, force = "player",
		snap_to_train_stop = false }, "locomotive on row " .. y)
	e.get_fuel_inventory().insert{ name = "coal", count = 50 }
	return e.train
end

local WAIT = { { type = "time", ticks = 60 } }
local function recs(...)
	local out = {}
	for i, name in ipairs({ ... }) do
		out[i] = { station = name, wait_conditions = WAIT }
	end
	return out
end

local function interrupt(name, station)
	return { name = name, conditions = { { type = "time", ticks = 100 } }, targets = { { station = station } } }
end

--- A train's records: station names, "<rail>" for a rail record, "*" after a temporary one.
local function names(tr)
	local out = {}
	for i, r in ipairs(tr.get_schedule().get_records() or {}) do
		out[i] = (r.station or "<rail>") .. (r.temporary and "*" or "")
	end
	return table.concat(out, ",")
end

t.case("sync: the first ue.sched.full makes the tile live; before it no train is read (§5.2, plan ruling 9)", function(ctx)
	ctx.at(190, function()
		local st = storage.universal_edges.schedules
		ctx.expect(st ~= nil and st.live == false, "schema 9's state, not live")
		local tr = loco(21)
		tr.get_schedule().set_records(recs("SG Z0")) -- an event, before the tile is live
		ctx.expect(next(st.dirty) == nil, "not live: no train marked")
		ctx.expect(sync.group_of(tr) == nil, "a train with no group reads as none")
	end)
	ctx.at(200, function()
		deliver("ue.sched.full", { entries = {} })
		local st = storage.universal_edges.schedules
		ctx.expect(st.live == true, "live")
		local line_ = sent[#sent]
		ctx.expect(line_ and line_.type == "trace" and line_.payload.phase == "full" and line_.payload.entries == 0,
			"ue.sched full logged with its entry count")
	end)
end)

t.case("sync: a cluster change to a group is written through a helper gone in the same tick and reaches every member; " ..
	"a moving member keeps its temporary record, current and path (§5.2, spike 16 U6)", function(ctx)
	local p1, p2, m, goal
	ctx.at(210, function()
		local rails = line(41, 501)
		m = assert(surface().create_entity{ name = "locomotive", position = { 11, 41 }, orientation = 0.25, force = "player",
			snap_to_train_stop = false }).train
		m.carriages[1].get_fuel_inventory().insert{ name = "coal", count = 50 }
		p1, p2 = loco(61), loco(71)
		p1.get_schedule().set_records(recs("SG A1"))
		p1.group = "SG A" -- seeds the group with [SG A1]
		p2.group = "SG A"
		m.group = "SG A"
		local sched = m.get_schedule()
		sched.go_to_station(sched.add_record{ rail = rails[351], temporary = true, index = { schedule_index = 1 } })
		m.manual_mode = false
	end)
	ctx.at(300, function()
		local r = reports("SG A", 210)
		ctx.expect(#r == 1 and r[1].base == nil, "the new group reported once, however many members raised events: " .. #r)
		goal = m.path_end_rail and m.path_end_rail.unit_number
		ctx.expect(m.state == defines.train_state.on_the_path and m.get_schedule().current == 1 and goal ~= nil,
			"M is on its way to its temporary record")
		deliver("ue.sched.set", { kind = "group", name = "SG A", v = 2,
			content = { records = recs("SG A1", "SG A2"), interrupts = {} } })
		ctx.expect(#writes_of("SG A", 300) == 1, "one helper write")
		ctx.expect(names(p1) == "SG A1,SG A2" and names(p2) == "SG A1,SG A2", "every parked member has it: " .. names(p1))
		ctx.expect(names(m) == "<rail>*,SG A1,SG A2", "and M, its temporary record kept: " .. names(m))
		ctx.expect(#game.train_manager.get_trains{ group = "SG A" } == 3, "three members: the helper is gone")
		local s = game.get_surface("ue-sched")
		ctx.expect(s ~= nil and #s.find_entities_filtered{ type = "locomotive" } == 0, "ue-sched holds no locomotive")
		ctx.expect(s ~= nil and game.forces.player.get_surface_hidden(s), "ue-sched is hidden from the player force")
		ctx.expect(not (storage.gridworld and storage.gridworld.tiles["ue-sched"]), "gridworld has no record for it")
		ctx.expect(m.state == defines.train_state.on_the_path and m.get_schedule().current == 1 and not m.manual_mode
			and (m.path_end_rail and m.path_end_rail.unit_number) == goal, "M undisturbed in the same tick")
	end)
	ctx.at(302, function()
		ctx.expect(#reports("SG A", 300) == 0, "the write's echo reports nothing")
		ctx.expect(m.state == defines.train_state.on_the_path and m.get_schedule().current == 1
			and m.get_schedule().get_record{ schedule_index = 1 }.temporary, "M still on its way, 2 ticks later")
	end)
end)

t.case("sync: an interrupt's cluster change reaches every train holding it, in a group or not; a name held nowhere " ..
	"here is cached only (§5.2, spike 16 U2b)", function(ctx)
	local x1, x2, x3
	ctx.at(220, function()
		x1, x2, x3 = loco(81), loco(91), loco(101)
		x1.get_schedule().add_interrupt(interrupt("SG I", "SG X"))
		x2.get_schedule().add_interrupt(interrupt("SG I", "SG X"))
		x3.get_schedule().set_records(recs("SG B1"))
		x3.get_schedule().add_interrupt(interrupt("SG I", "SG X"))
		x3.group = "SG B" -- the group's interrupt
	end)
	ctx.at(320, function()
		deliver("ue.sched.set", { kind = "interrupt", name = "SG I", v = 3, content = interrupt("SG I", "SG Y") })
		deliver("ue.sched.set", { kind = "interrupt", name = "SG NOWHERE", v = 1, content = interrupt("SG NOWHERE", "SG Y") })
		for i, tr in ipairs({ x1, x2, x3 }) do
			local it = tr.get_schedule().get_interrupt(1)
			ctx.expect(it.name == "SG I" and it.targets[1].station == "SG Y", "holder " .. i .. " has the cluster's interrupt")
		end
		ctx.expect(#writes_of("SG I", 320) == 1 and #writes_of("SG NOWHERE", 320) == 0, "one write, for the held name")
		local st = storage.universal_edges.schedules
		ctx.expect(st.cache.interrupt["SG NOWHERE"].v == 1 and st.hash.interrupt["SG NOWHERE"] == nil, "cached only")
	end)
	ctx.at(322, function()
		ctx.expect(#reports("SG I", 320) == 0 and #reports("SG B", 320) == 0, "the write's echo reports nothing")
	end)
end)

t.case("sync: an edit is reported once, on the cache's version; a second edit before the answer waits for it, then " ..
	"goes on the new version (§5.1, plan ruling 4, Review Focus 1)", function(ctx)
	local c1, c2, first
	ctx.at(230, function()
		c1, c2 = loco(111), loco(121)
		c1.get_schedule().set_records(recs("SG C1"))
		c1.group = "SG C"
		c2.group = "SG C"
	end)
	ctx.at(240, function()
		local r = reports("SG C", 230)
		ctx.expect(#r == 1 and r[1].base == nil and #r[1].content.records == 1, "the new group reported once, no base")
		deliver("ue.sched.set", { kind = "group", name = "SG C", v = 1, content = r[1].content }) -- the controller's answer
		ctx.expect(#writes_of("SG C", 240) == 0, "the answer to this tile's own report writes nothing")
		ctx.expect(storage.universal_edges.schedules.cache.group["SG C"].v == 1, "cached at v1")
	end)
	ctx.at(250, function()
		c1.get_schedule().set_records(recs("SG C1", "SG C2")) -- six events: three on each member
	end)
	ctx.at(252, function()
		local r = reports("SG C", 250)
		ctx.expect(#r == 1 and r[1].base == 1 and #r[1].content.records == 2, "one report for six events, on v1")
		first = r[1] and r[1].content
		c2.get_schedule().set_records(recs("SG C1", "SG C2", "SG C3")) -- a second edit while the first is unanswered
	end)
	ctx.at(254, function()
		ctx.expect(#reports("SG C", 253) == 0, "held while the first waits for its answer")
		deliver("ue.sched.set", { kind = "group", name = "SG C", v = 2, content = first }) -- the first accepted
		ctx.expect(#writes_of("SG C", 254) == 0, "the answer is what this tile reported: nothing written")
		local r = reports("SG C", 254)
		ctx.expect(#r == 1 and r[1].base == 2 and #r[1].content.records == 3, "the second edit goes now, on v2")
		ctx.expect(names(c1) == "SG C1,SG C2,SG C3", "and the player's second edit stands: " .. names(c1))
	end)
end)

t.case("sync: a group first seen here while the cluster has it takes the cluster's schedule, as vanilla's join would " ..
	"(plan ruling 2, Review Focus 2)", function(ctx)
	local d
	ctx.at(260, function()
		deliver("ue.sched.set", { kind = "group", name = "SG D", v = 4,
			content = { records = recs("SG CLUSTER"), interrupts = {} } })
		ctx.expect(#writes_of("SG D", 260) == 0, "no member here: cached only")
		d = loco(131)
		d.get_schedule().set_records(recs("SG MINE"))
		d.group = "SG D" -- a player names a cluster group on a tile with no member: seeded here with their own records
	end)
	ctx.at(262, function()
		ctx.expect(names(d) == "SG CLUSTER" and sync.group_of(d) == "SG D", "the cluster's records: " .. names(d))
		ctx.expect(#writes_of("SG D", 261) == 1 and #reports("SG D", 260) == 0, "written in, not reported")
	end)
end)

t.case("sync: the sweep reports a group seeded with no event and counts it; it forgets a name gone from the tile; " ..
	"counts go only when they change (§5.4, plan ruling 5)", function(ctx)
	local e, gone
	ctx.at(400, function()
		e = loco(151)
		e.group = "SG S" -- seeding raises no event (spike 16 U3): only the sweep sees it
	end)
	ctx.at(402, function()
		ctx.expect(#reports("SG S", 400) == 0, "no event, no report yet")
		gone = loco(161)
		gone.get_schedule().set_records(recs("SG S-GONE1"))
		gone.group = "SG S-GONE"
	end)
	ctx.at(404, function()
		ctx.expect(storage.universal_edges.schedules.hash.group["SG S-GONE"] ~= nil, "held here, so it has a hash")
		gone.carriages[1].destroy()
	end)
	ctx.at(1300, function()
		local st = storage.universal_edges.schedules
		local r = reports("SG S", 400)
		ctx.expect(#r == 1 and r[1].base == nil, "the sweep reported the seeded group as new, once: " .. #r)
		local counted = false
		for _, m in ipairs(sent) do
			if m.type == "ue.sched.counts" and m.tick >= 400 then
				for _, row in ipairs(m.payload.rows) do
					counted = counted or (row[1] == "group" and row[2] == "SG S" and row[3] == 1)
				end
			end
		end
		ctx.expect(counted, "its train is in the counts sent")
		ctx.expect(st.hash.group["SG S-GONE"] == nil, "a name the walk didn't count, untouched since, is forgotten")
		local w = { group = { ["SG S"] = 1, ["SG S2"] = 2 }, interrupt = { ["SG SI"] = 3 } }
		local before = #sent
		sync.send_counts(st, w)
		sync.send_counts(st, w)
		local msgs = {}
		for i = before + 1, #sent do
			if sent[i].type == "ue.sched.counts" then
				msgs[#msgs + 1] = sent[i].payload
			end
		end
		ctx.expect(#msgs == 1 and msgs[1].first == true and #msgs[1].rows == 3, "one message, first, three rows; an "
			.. "unchanged second count sends nothing: " .. #msgs)
	end)
	ctx.at(1310, function()
		-- 105 names new to the cache, all held by one real train; read is stubbed so each has content (ruling C7)
		local st = storage.universal_edges.schedules
		local w = { group = {}, interrupt = {}, began = 0, holder = { group = {}, interrupt = {} } }
		for i = 1, 105 do
			w.holder.interrupt["SG CAP " .. i] = e
		end
		local read = sync.read
		sync.read = function(_, _, name)
			return interrupt(name, "SG Z")
		end
		local before = #sent
		sync.sweep_end(st, w)
		local first = 0
		for i = before + 1, #sent do
			first = first + (sent[i].type == "ue.sched.report" and 1 or 0)
		end
		ctx.expect(first == 100, "a walk's end reports 100 of 105: " .. first)
		before = #sent
		sync.sweep_end(st, w)
		local rest = 0
		for i = before + 1, #sent do
			rest = rest + (sent[i].type == "ue.sched.report" and 1 or 0)
		end
		sync.read = read
		ctx.expect(rest == 5, "the next walk reports the other 5: " .. rest)
	end)
end)

t.case("sync: a full replaces the cache — a name it lacks is forgotten, a changed one written in, nothing awaits an " ..
	"answer — and drop forgets one name (§5.2, §5.5, Review Focus 4)", function(ctx)
	ctx.at(1350, function()
		local st = storage.universal_edges.schedules
		deliver("ue.sched.drop", { kind = "interrupt", name = "SG NOWHERE" })
		ctx.expect(st.cache.interrupt["SG NOWHERE"] == nil, "drop forgets the name")
		deliver("ue.sched.full", { entries = {
			{ kind = "group", name = "SG C", v = 9, content = { records = recs("SG C9"), interrupts = {} } },
			{ kind = "interrupt", name = "SG I", v = 9, content = interrupt("SG I", "SG Z") },
		} })
		ctx.expect(st.cache.group["SG A"] == nil and st.cache.group["SG D"] == nil, "names the full lacks are forgotten")
		ctx.expect(st.cache.group["SG C"].v == 9 and #writes_of("SG C", 1350) == 1, "SG C, changed, written in")
		local c = game.train_manager.get_trains{ group = "SG C" }[1]
		ctx.expect(c ~= nil and names(c) == "SG C9", "its members have it: " .. (c and names(c) or "none"))
		ctx.expect(#writes_of("SG I", 1350) == 1, "SG I written in")
		ctx.expect(next(st.pending.group) == nil and next(st.pending.interrupt) == nil, "no report awaits an answer")
	end)
end)

t.case("sync: an answer doesn't report the train held as pending if it has left the group meanwhile (plan review, Task 3)",
	function(ctx)
		local e, first
		ctx.at(270, function()
			e = loco(141)
			e.get_schedule().set_records(recs("SG E1"))
			e.group = "SG E"
		end)
		ctx.at(280, function()
			local r = reports("SG E", 270)
			ctx.expect(#r == 1, "the new group reported once")
			first = r[1] and r[1].content
			e.get_schedule().set_records(recs("SG E1", "SG E2")) -- a second edit while the first is unanswered
		end)
		ctx.at(282, function()
			ctx.expect(#reports("SG E", 281) == 0, "held while the first waits for its answer")
			e.group = nil -- leaves the group before the answer
			deliver("ue.sched.set", { kind = "group", name = "SG E", v = 1, content = first })
			ctx.expect(#reports("SG E", 282) == 0, "its records aren't reported as the group's edit: " .. #reports("SG E", 282))
		end)
	end)

-- The crossing (§5.6): bodies in capture's wire format offered on inbound connectors with a scripted partner, as
-- trains_spawn_game_test.lua's. The credit runs in the inbox handler, so the train stands, and its ue.train lines wait in
-- the bridge's queue, within the step that offers.
local STOCK = { L = "locomotive", C = "cargo-wagon" }

--- A body for layout (L a locomotive facing in, C a cargo wagon): o.records, o.edge_record, o.current, o.interrupts,
--- o.group, o.manual, o.speed. Locomotives carry 20 coal.
local function body(layout, o)
	local cars = {}
	for k = 1, #layout do
		local c = { name = STOCK[string.sub(layout, k, k)], quality = "normal", flip = false }
		if c.name == "locomotive" then
			c.inv = { { i = defines.inventory.fuel, s = { i = { { n = "coal", c = 20 } } } } }
		end
		cars[k] = c
	end
	return { v = 1, layer = "ground", speed = o.speed or 0, manual = o.manual == true, carriages = cars, group = o.group,
		schedule = { records = o.records, interrupts = o.interrupts or {}, current = o.current or 1 },
		edge_record = o.edge_record }
end

local function offer(id, cid, b)
	seams.lane(id, { k = "u.offer", cid = cid, dir = "ba", seq = 1, tag = "0000beef", trace = id .. "." .. cid,
		body = helpers.encode_string(helpers.table_to_json(b)), digest = id .. "#" .. cid })
end

local function inbound(cid, pos)
	return { cid = cid, type = "train", pos = pos, width = 6, params = { dir = "ba", layer = "ground" } }
end

--- The ue.train grouped line queued in this step for (id, cid).
local function grouped(id, cid)
	for _, m in ipairs(storage.universal_edges.bridge.out.universal_edges or {}) do
		local p = m.payload
		if m.type == "trace" and p.op == "ue.train" and p.phase == "grouped" and p.edge == id and p.cid == cid then
			return p
		end
	end
end

t.case("sync: a grouped train crossing keeps its group — adopted where it has members, seeded from the cache where " ..
	"it has none, seeded from its own schedule where the cluster doesn't know it — with its temporaries and the next " ..
	"record by identity (§5.6)", function(ctx)
	local id = "sg-cross"
	ctx.at(500, function()
		seams.edge(id, 2000, { inbound("t1", 4), inbound("t2", 24), inbound("t3", 44) }, { surface = "sgsync" })
	end)
	ctx.at(501, function()
		for _, cid in ipairs({ "t1", "t2", "t3" }) do
			seams.partner(id, cid)
			seams.track(id, cid, 60, "SG STOP")
		end
		local here = loco(201)
		here.get_schedule().set_records(recs("SG H0", "SG H1", "SG H2"))
		here.group = "SG F-HERE"
		deliver("ue.sched.set", { kind = "interrupt", name = "SG FI", v = 1, content = interrupt("SG FI", "SG K1") })
		deliver("ue.sched.set", { kind = "group", name = "SG F-CACHED", v = 2,
			content = { records = recs("SG K1", "SG K2"), interrupts = { "SG FI" } } })
	end)
	ctx.at(530, function()
		offer(id, "t1", body("L", { group = "SG F-HERE", manual = true, edge_record = 2, current = 2,
			records = { { station = "SG H1" }, { temporary = true }, { station = "SG H2" } } }))
		offer(id, "t2", body("L", { group = "SG F-CACHED", manual = true, edge_record = 2, current = 2,
			records = { { station = "SG OLD" }, { temporary = true },
				{ station = "SG F", temporary = true, created_by_interrupt = true }, { station = "SG K2" } } }))
		offer(id, "t3", body("L", { group = "SG F-NEW", manual = true, edge_record = 2, current = 2,
			interrupts = { interrupt("SG NI", "SG N1") },
			records = { { station = "SG N1" }, { temporary = true }, { station = "SG N2" } } }))
		local a, b, c = seams.trains(id, "t1")[1], seams.trains(id, "t2")[1], seams.trains(id, "t3")[1]
		ctx.expect(a ~= nil and sync.group_of(a) == "SG F-HERE" and names(a) == "SG H0,SG H1,SG H2"
			and a.get_schedule().current == 3, "adopted: this tile's version, going to SG H2 by name: "
			.. (a and names(a) or "no train"))
		ctx.expect(#game.train_manager.get_trains{ group = "SG F-HERE" } == 2, "it joined the local member")
		ctx.expect(b ~= nil and sync.group_of(b) == "SG F-CACHED" and names(b) == "SG K1,SG F*,SG K2"
			and b.get_schedule().current == 2, "seeded from the cache, the interrupt's record before SG K2 and current: "
			.. (b and names(b) or "no train"))
		local rec = b and b.get_schedule().get_record{ schedule_index = 2 }
		ctx.expect(rec ~= nil and rec.created_by_interrupt == true, "still an interrupt's record (add_record took the flag)")
		local it = b and b.get_schedule().get_interrupt(1)
		ctx.expect(it ~= nil and it.name == "SG FI" and it.targets[1].station == "SG K1", "with the cache's interrupt")
		ctx.expect(c ~= nil and sync.group_of(c) == "SG F-NEW" and names(c) == "SG N1,SG N2" and c.get_schedule().current == 2
			and c.get_schedule().get_interrupt(1).name == "SG NI", "unknown to the cluster: seeded from its own schedule")
		local how = {}
		for _, cid in ipairs({ "t1", "t2", "t3" }) do
			local l = grouped(id, cid)
			how[cid] = l and l.how
		end
		ctx.expect(how.t1 == "adopted" and how.t2 == "seeded" and how.t3 == "carried", "ue.train grouped: "
			.. tostring(how.t1) .. "," .. tostring(how.t2) .. "," .. tostring(how.t3))
	end)
	ctx.at(532, function()
		local r = reports("SG F-NEW", 530)
		ctx.expect(#r == 1 and r[1].base == nil, "the group new to the cluster is reported")
		ctx.expect(#reports("SG F-CACHED", 530) == 0 and #reports("SG F-HERE", 530) == 0, "the others hold the cluster's")
	end)
end)

t.case("sync: a grouped train longer than the first batch keeps its group through its joins (§5.6, Review Focus 3)",
	function(ctx)
		local id = "sg-long"
		ctx.at(600, function()
			seams.edge(id, 3000, { inbound("t1", 4) }, { surface = "sgsync" })
		end)
		ctx.at(601, function()
			seams.partner(id, "t1")
			seams.track(id, "t1", 120, "SG LONG STOP")
		end)
		ctx.at(630, function()
			offer(id, "t1", body("L" .. string.rep("C", 13), { group = "SG G-LONG", speed = 0.3, edge_record = 1, current = 1,
				records = { { temporary = true }, { station = "SG LONG STOP" } } }))
			local tr = seams.trains(id, "t1")[1]
			ctx.expect(tr ~= nil and #tr.carriages == 12 and sync.group_of(tr) == "SG G-LONG", "the first batch, grouped")
		end)
		ctx.at(930, function()
			local tr = seams.trains(id, "t1")[1]
			ctx.expect(tr ~= nil and #tr.carriages == 14, "assembled: " .. (tr and #tr.carriages or 0))
			ctx.expect(tr ~= nil and sync.group_of(tr) == "SG G-LONG" and names(tr) == "SG LONG STOP",
				"still in its group after the joins: " .. (tr and (tostring(tr.group) .. " " .. names(tr)) or "no train"))
		end)
	end)

t.case("sync: an ungrouped train carrying an interrupt older than the cluster's doesn't roll the cluster back (§5.3)",
	function(ctx)
		local id = "sg-stale"
		ctx.at(1500, function()
			seams.edge(id, 3500, { inbound("t1", 4) }, { surface = "sgsync" })
		end)
		ctx.at(1501, function()
			seams.partner(id, "t1")
			seams.track(id, "t1", 60, "SG STALE STOP")
			deliver("ue.sched.set", { kind = "interrupt", name = "SG STALE", v = 2, content = interrupt("SG STALE", "SG V2") })
			local holder = loco(211)
			holder.get_schedule().set_interrupts({ interrupt("SG STALE", "SG V2") })
		end)
		ctx.at(1530, function()
			ctx.expect(storage.universal_edges.schedules.hash.interrupt["SG STALE"] ~= nil, "this tile holds the interrupt")
			offer(id, "t1", body("L", { manual = true, edge_record = 1, current = 1, interrupts = { interrupt("SG STALE", "SG V1") },
				records = { { temporary = true }, { station = "SG STALE STOP" } } }))
			local tr = seams.trains(id, "t1")[1]
			local it = tr and tr.get_schedule().get_interrupt(1)
			ctx.expect(it ~= nil and it.targets[1].station == "SG V2", "restored with the cluster's content: "
				.. tostring(it and it.targets[1].station))
		end)
		ctx.at(1540, function()
			ctx.expect(#reports("SG STALE", 1530) == 0, "nothing reported: " .. #reports("SG STALE", 1530))
		end)
	end)

t.case("sync: a full makes the next walk send the counts again, though they didn't change (lost messages)", function(ctx)
	ctx.at(2000, function()
		local st = storage.universal_edges.schedules
		local w = { group = { ["SG R"] = 1 }, interrupt = {} }
		local function count_msgs(f)
			local before, c = #sent, 0
			f()
			for i = before + 1, #sent do
				c = c + (sent[i].type == "ue.sched.counts" and 1 or 0)
			end
			return c
		end
		ctx.expect(count_msgs(function() sync.send_counts(st, w) end) == 1, "sent once")
		ctx.expect(count_msgs(function() sync.send_counts(st, w) end) == 0, "unchanged: not again")
		deliver("ue.sched.full", { entries = {} })
		ctx.expect(count_msgs(function() sync.send_counts(st, w) end) == 1, "after a full: sent again")
	end)
end)

--- A stand-in for a player's GUI (game tests have no LuaPlayer), copied from routing_game_test.lua (plan ruling C6):
--- add, destroy, children, and a child by its name.
local function fake_gui(parent, spec)
	local el = { children = {}, style = {}, valid = true }
	for k, v in pairs(spec or {}) do
		if k == "style" then -- the add spec's style is a name; el.style stays the settable table
			el.style_name = v
		else
			el[k] = v
		end
	end
	function el.add(s)
		local c = fake_gui(el, s)
		el.children[#el.children + 1] = c
		if s.name then
			el[s.name] = c
		end
		return c
	end
	function el.focus() el.focused = true end
	function el.select_all() el.selected = true end
	function el.destroy()
		el.valid = false
		if el.name then
			parent[el.name] = nil
		end
		for i, c in ipairs(parent.children) do
			if c == el then
				table.remove(parent.children, i)
				break
			end
		end
	end
	return el
end

--- A player stand-in with tr's locomotive window open and the panel shown; returns it and the panel's group row.
local function open(tr)
	local player = { index = 1, gui = { screen = fake_gui(), relative = fake_gui() }, opened = tr.carriages[1],
		display_scale = 1, display_resolution = { width = 1920, height = 1080 } }
	panel.show(player)
	return player, player.gui.screen.router_stations.router_sched_row, player.gui.screen.router_stations.router_interrupt_row
end

local function index_of(items, item)
	for i, x in ipairs(items) do
		if x == item then
			return i
		end
	end
end

t.case("sync: the panel's group picker joins a group — seeded from the cache where it has no member here, adopted " ..
	"where it has — and None leaves it; the interrupt picker adds the cache's content (§5.7)", function(ctx)
	ctx.at(1250, function()
		deliver("ue.sched.set", { kind = "interrupt", name = "SG PI", v = 1, content = interrupt("SG PI", "SG P2") })
		deliver("ue.sched.set", { kind = "group", name = "SG P", v = 1,
			content = { records = recs("SG P1"), interrupts = { "SG PI" } } })
		local a, b, c = loco(171), loco(181), loco(191)
		local pa, row = open(a)
		local pick = row.router_group
		ctx.expect(pick.items[1] == "None" and pick.selected_index == 1, "no group: None is selected")
		local at = index_of(pick.items, "SG P")
		ctx.expect(at ~= nil and pick.tags.names[at - 1] == "SG P", "the cache's group is listed")
		pick.selected_index = at
		panel.pick(pa, pick)
		ctx.expect(sync.group_of(a) == "SG P" and names(a) == "SG P1", "seeded from the cache: " .. names(a))
		local it = a.get_schedule().get_interrupt(1)
		ctx.expect(it ~= nil and it.name == "SG PI" and it.targets[1].station == "SG P2", "with its interrupt, from the cache")
		local pb, rowb = open(b)
		rowb.router_group.selected_index = index_of(rowb.router_group.items, "SG P")
		panel.pick(pb, rowb.router_group)
		ctx.expect(sync.group_of(b) == "SG P" and #game.train_manager.get_trains{ group = "SG P" } == 2, "b joined a's group")
		rowb.router_group.selected_index = 1
		panel.pick(pb, rowb.router_group)
		ctx.expect(sync.group_of(b) == nil and names(b) == "SG P1", "None: b left, keeping its own copy")
		local pc, _, irowc = open(c)
		local add = irowc.router_interrupt
		ctx.expect(add.items[1] == "Add interrupt" and add.selected_index == 1, "the interrupt picker shows its title")
		add.selected_index = index_of(add.items, "SG PI")
		panel.pick(pc, add)
		local ci = c.get_schedule().get_interrupt(1)
		ctx.expect(ci ~= nil and ci.name == "SG PI" and ci.targets[1].station == "SG P2" and add.selected_index == 1,
			"the cache's interrupt added, the picker back at its title")
		deliver("ue.sched.set", { kind = "group", name = "SG P9", v = 1, content = { records = recs("SG P9"), interrupts = {} } })
		panel.refresh(pa)
		ctx.expect(index_of(row.router_group.items, "SG P9") ~= nil, "a refresh lists a group the cache gained")
		ctx.expect(row.router_group.items[row.router_group.selected_index] == "SG P", "and keeps a's group selected")
	end)
end)

t.case("sync: the panel shows a group's cluster-wide train count in the picker and a label, with a stopped tile marked", function(ctx)
	ctx.at(2100, function()
		deliver("ue.sched.set", { kind = "group", name = "SG T", v = 1, content = { records = recs("SG T1"), interrupts = {} } })
		local a, b = loco(221), loco(231)
		local pa, row = open(a)
		local pick, label = row.router_group, row.router_group_count
		ctx.expect(label.visible == false, "no totals yet: the label is hidden")
		local pb, rowb = open(b)
		rowb.router_group.selected_index = index_of(rowb.router_group.items, "SG T")
		panel.pick(pb, rowb.router_group)
		deliver("ue.sched.totals", { groups = { { "SG T", 3, { { "gridworld_0_0", 2, false }, { "gridworld_1_-1", 1, true } } } } })
		panel.refresh(pb)
		local at = index_of(rowb.router_group.items, "SG T (3)")
		ctx.expect(at ~= nil and rowb.router_group.selected_index == at, "the item reads with its total, still selected")
		ctx.expect(rowb.router_group.tags.names[at - 1] == "SG T", "its tag still names the group")
		ctx.expect(rowb.router_group_count.visible == true and rowb.router_group_count.caption == "3 trains · 2 tiles",
			"caption: " .. tostring(rowb.router_group_count.caption))
		ctx.expect(rowb.router_group_count.tooltip == "Trains in this group on every tile, counted about every 10 s:\n0,0: 2\n"
			.. "1,-1: 1 (stopped)", "tooltip: " .. tostring(rowb.router_group_count.tooltip))
		panel.refresh(pa)
		ctx.expect(pick.selected_index == 1 and label.visible == false, "a train with no group: None, the label hidden")
		deliver("ue.sched.totals", { groups = { { "SG T", 1, { { "gridworld_0_0", 1, false } } } } })
		panel.refresh(pb)
		ctx.expect(rowb.router_group_count.caption == "1 train · 1 tile" and rowb.router_group.items[at] == "SG T (1)"
			and rowb.router_group.selected_index == at, "a moved total relists the item, keeping the selection")
	end)
end)
