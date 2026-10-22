-- SP4 routing's game tests (spec §11.4), moved from the router prototype's (plan 2026-10-04-router-prototype) and
-- extended. Rows 60000-77800 of UE's "sp3b" lab surface; the File Structure's table in
-- docs/superpowers/plans/2026-10-04-sp4-routing.md lists each case's ground and ticks.
-- Ticks 860-3850, after most of UE's cases. Router cases share this save with UE's and GW's
-- game tests. Each case's edge has a scripted partner (UE's train seams). A router.resync enables the router for the
-- whole save from then on: the search cap case's, at tick 900, is the save's first.
local t = require("modules/v2_test/testlib")
-- Factorio allows require only while the file loads, never inside a step.
local ue = require("modules/universal_edges") -- luacheck: ignore
local seams = require("modules/universal_edges/transports/train_seams")
local hooks = require("modules/universal_edges/transports/hooks")
local bridge = require("modules/universal_edges/runtime/bridge")
local tables = require("modules/universal_edges/routing/tables")
local base = require("modules/universal_edges/routing/base")
local routes = require("modules/universal_edges/routing/routes")
local panel = require("modules/universal_edges/routing/panel")
local stops = require("modules/universal_edges/routing/stops")
local ue_train = require("modules/universal_edges/transports/train")
local lanes = require("modules/universal_edges/edges/lanes")
local layouts = require("modules/v2_test/layouts")

local n = 0
--- One controller message into the router's Lua, as the instance plugin's bridge delivers it.
local function deliver(msg_type, payload) -- luacheck: ignore
	n = n + 1
	bridge.inbox("universal_edges", helpers.table_to_json({ { id = "a0a00000." .. n, type = msg_type, payload = payload } }))
end
--- The router's messages of msg_type queued in the bridge since the last flush (inside one step: this step's own).
local function queued(msg_type, pred)
	local out = {}
	for _, m in ipairs(storage.universal_edges.bridge.out.universal_edges or {}) do
		if m.type == msg_type and (not pred or pred(m.payload)) then
			out[#out + 1] = m.payload
		end
	end
	return out
end
local function traced(op, phase, trace) -- luacheck: ignore
	return queued("trace", function(p) return p.op == op and p.phase == phase and (trace == nil or p.trace == trace) end)
end
--- field's rows merged across every router.report message queued this step (fix round 1: a large report now splits
--- across several consecutive messages, each kept under the bridge's byte budget, instead of always being one).
local function reported(field) -- luacheck: ignore
	local out = {}
	for _, m in ipairs(queued("ue.route.report")) do
		for _, row_ in ipairs(m[field] or {}) do
			out[#out + 1] = row_
		end
	end
	return out
end
--- Forget when tr's route was last asked, so the next check asks at once: a check inside the ask window doesn't.
local function ask_due(tr)
	local route = storage.universal_edges.routing.active[routes.trace_of(tr) or ""]
	if route then
		route.asked = nil
	end
end
local function conn(cid, dir, pos, layer) -- luacheck: ignore
	return { cid = cid, type = "train", pos = pos, width = 6, params = { dir = dir, layer = layer or "ground" } }
end
--- Edge id at row y of surface (default "sp3b") at tick; at tick + 1 every partner ready and tracks[cid] = { rails, station? } built.
local function rig(ctx, tick, id, y, list, tracks, surface) -- luacheck: ignore
	ctx.at(tick, function()
		seams.edge(id, y, list, { surface = surface })
	end)
	ctx.at(tick + 1, function()
		for _, c in ipairs(list) do
			seams.partner(id, c.cid, { ready = true, w = 0 })
			local tr = tracks[c.cid]
			if tr then
				seams.track(id, c.cid, tr.rails, tr.station)
			end
		end
	end)
end
local function stop_named(name) -- luacheck: ignore
	return game.train_manager.get_train_stops{ station_name = name }[1]
end
--- A straight rail and a stop beside it at (x, y) on "sp3b", away from every rig: only its station row matters. With raise,
--- the stop's build raises script_raised_built, as a player's or a robot's build reaches routing.
local function lone_stop(x, y, name, raise) -- luacheck: ignore
	local s = game.get_surface("sp3b")
	s.request_to_generate_chunks({ x, y }, 0)
	s.force_generate_chunk_requests()
	assert(s.create_entity{ name = "straight-rail", position = { x, y }, direction = defines.direction.north, force = "player" },
		"lone rail " .. name)
	local stop = assert(s.create_entity{ name = "train-stop", position = { x + 2, y }, direction = defines.direction.north,
		force = "player", raise_built = raise }, "lone stop " .. name)
	stop.backer_name = name
	return stop
end

--- A constant combinator at (x, y) holding signal-L at value, wired by red to stop; the stop's limit set by signal-L.
local function circuit_limit(stop, x, y, value) -- luacheck: ignore
	local comb = assert(game.get_surface("sp3b").create_entity{ name = "constant-combinator", position = { x, y },
		force = "player" }, "combinator")
	local cb = comb.get_or_create_control_behavior()
	local section = cb.get_section(1) or cb.add_section()
	section.set_slot(1, { value = { type = "virtual", name = "signal-L", quality = "normal" }, min = value })
	local red = defines.wire_connector_id.circuit_red
	comb.get_wire_connector(red, true).connect_to(stop.get_wire_connector(red, true), false)
	local scb = stop.get_or_create_control_behavior()
	scb.set_trains_limit, scb.trains_limit_signal = true, { type = "virtual", name = "signal-L" } -- U2's names (Task 1)
	return comb
end
--- fix round 2 (review finding 3): enough of this case's own stations, each on its own isolated rail spur far from
--- the row's own track and from each other, that a full report exceeds the 3000-byte budget by itself -- regardless
--- of what any other test's fixtures contribute to the same shared save. Isolated so they add no cost rows
--- (unreachable from anywhere), keeping their effect on the rest of the report to the stations list alone.
local FILLER_N, FILLER_X0, FILLER_GAP = 50, 10000, 10 -- luacheck: ignore
local function filler_stations(y) -- luacheck: ignore
	local s = game.get_surface("sp3b")
	local north = defines.direction.north
	for i = 1, FILLER_N do
		s.request_to_generate_chunks({ FILLER_X0 + i * FILLER_GAP, y }, 0)
	end
	s.force_generate_chunk_requests()
	for i = 1, FILLER_N do
		local x = FILLER_X0 + i * FILLER_GAP
		assert(s.create_entity{ name = "straight-rail", position = { x, y }, direction = north, force = "player" }, "filler rail " .. i)
		local stop = assert(s.create_entity{ name = "train-stop", position = { x + 2, y }, direction = north, force = "player" },
			"filler stop " .. i)
		stop.backer_name = "RTBIG-" .. i
	end
end
--- A train's records, "*" marking temporary ones and "<rail>" rail records.
local function names(tr) -- luacheck: ignore
	local out = {}
	for i, r in ipairs(tr.get_schedule().get_records() or {}) do
		out[i] = (r.station or "<rail>") .. (r.temporary and "*" or "")
	end
	return table.concat(out, ",")
end
--- The rail unit numbers of tr's temporary rail records, in order: a route's hops, by identity (D22, SP4 §5.3).
local function hop_rails(tr) -- luacheck: ignore
	local out = {}
	for _, rec in ipairs(tr.get_schedule().get_records() or {}) do
		if rec.temporary and rec.rail then
			out[#out + 1] = rec.rail.unit_number
		end
	end
	return out
end
--- A routed route for tr: its first record is already cid's end rail (seams.add's edge record, a temporary rail record
--- since Task 2), so the route's hop is that record.
local function routed(tr, id, dest, edge, cid) -- luacheck: ignore
	local route = routes.register(tr, id, dest, { { edge = edge, cid = cid } })
	route.hop, route.unrouted = { edge = edge, cid = cid, rail = ue.trains.get(edge, cid).end_rail }, false
	return route
end

--- D22's invariant after a reply (§11.4; plan ruling 13): exactly one hop record, the reply's, by its rail's identity;
--- current names it; the destination's record still there.
local function one_hop(ctx, tr, rail, dest, label) -- luacheck: ignore
	local hops = hop_rails(tr)
	local sched = tr.get_schedule()
	local cur = sched.get_record{ schedule_index = sched.current }
	ctx.expect(#hops == 1 and hops[1] == rail.unit_number, label .. ": one hop, the reply's: " .. names(tr))
	ctx.expect(cur and cur.rail and cur.rail.unit_number == rail.unit_number, label .. ": current names it")
	ctx.expect(string.find("," .. names(tr) .. ",", "," .. dest .. ",", 1, true) ~= nil, label .. ": the destination is still there")
end

--- A train stop for outward travel (toward the box) beside cid's track at local y ly.
local function outward_stop(id, cid, ly, name) -- luacheck: ignore
	local ep = seams.endpoint(id, cid)
	local wx, wy = ue_train.world(ep, ue_train.cx(ep) + 2, ly)
	local stop = assert(game.get_surface("sp3b").create_entity{ name = "train-stop", position = { wx, wy },
		direction = ue.geometry.dir_to_world(ep.frame, 0), force = "player" }, "outward stop " .. name)
	stop.backer_name = name
	return stop
end

--- The fuel-low interrupt of trains_handoff_game_test.lua's D22 case, to target, which waits there wait ticks.
local function fuel_interrupt(name, target, wait) -- luacheck: ignore
	local low = { first_signal = { type = "item", name = "coal" }, comparator = "<", constant = 10 }
	return { name = name, conditions = { { type = "fuel_item_count_any", condition = low } },
		targets = { { station = target, wait_conditions = { { type = "time", ticks = wait } } } } }
end
--- An offer from edge id's scripted partner to inbound cid "t1": layout of L (locomotive, 20 coal) and C (cargo wagon).
local function offer(id, seq, records, ext, layout, speed) -- luacheck: ignore
	local cars = {}
	for k = 1, #layout do
		local loco = string.sub(layout, k, k) == "L"
		cars[k] = { name = loco and "locomotive" or "cargo-wagon", quality = "normal", flip = false,
			inv = loco and { { i = defines.inventory.fuel, s = { i = { { n = "coal", c = 20 } } } } } or nil }
	end
	local body = { v = 1, layer = "ground", speed = speed or 0.5, manual = false, carriages = cars,
		schedule = { records = records, interrupts = {}, current = 1 }, ext = ext }
	seams.lane(id, { k = "u.offer", cid = "t1", dir = "ba", seq = seq, tag = "0000beef", trace = id .. "." .. seq,
		body = helpers.encode_string(helpers.table_to_json(body)), digest = id .. "#" .. seq })
end
--- The destination's answer to offer seq: "credited", "busy", "reject"...
local function reply(id, seq) -- luacheck: ignore
	for _, m in ipairs(storage.universal_edges.bridge.out.universal_edges or {}) do
		if m.type == "ue.lane" and m.payload.edge == id and m.payload.k == "u.reply" and m.payload.seq == seq then
			return m.payload.outcome
		end
	end
end

t.case("routing: UE storage at schema 11 with the routing state, not live until the controller's first resync (§4.3, R5)", function(ctx)
	ctx.at(1, function()
		local s = storage.universal_edges
		ctx.expect(s.schema == 11 and s.routing ~= nil, "schema 11, with the routing state")
		ctx.expect(s.routing.live == false, "not live until a ue.route.resync")
		ctx.expect(storage.router == nil, "nothing at the prototype's key")
	end)
end)

-- Row 60000: an inbound box (t1) with RT2 HOME on its track, an outbound box (t2), an elevated outbound box (t3), and 50
-- filler stations, so a full report's station rows need several messages (§7.8, §7.9).
t.case("routing: the table — a full report in standalone parts, one inbound box's costs, connector rows, only changes after",
	function(ctx)
		local id = "rt-table"
		rig(ctx, 1500, id, 60000, { conn("t1", "ba", 4), conn("t2", "ab", 24), conn("t3", "ab", 44, "elevated") },
			{ t1 = { rails = 60, station = "RT2 HOME" }, t2 = { rails = 40 }, t3 = { rails = 40 } })
		ctx.at(1502, function()
			filler_stations(60000)
		end)
		local home, k1
		local function row(list, from, to)
			for _, r in ipairs(list or {}) do
				if r[1] == from and r[2] == to then
					return r
				end
			end
		end
		local function find(list, field, value)
			for _, r in ipairs(list or {}) do
				if r[field] == value then
					return r
				end
			end
		end
		ctx.at(1540, function()
			local r = storage.universal_edges.routing
			r.live, r.full = true, true -- as a resync makes it (from Task 7, the search-cap case's resync at 900 has)
			stops.rebuild() -- the rig's stop and the filler were made without events: a resync rebuilds the registry
			tables.pass()
			local all = queued("ue.route.report")
			local at -- a gone message for a start that went can come first; the full one opens the full report
			for i, m in ipairs(all) do
				at = at or (m.full and i)
			end
			ctx.expect(at and all[at].stations == nil and all[at].costs == nil and all[at].conns == nil,
				"a full report opens with { full = true } alone")
			local stations_msgs = 0
			for i, m in ipairs(all) do
				ctx.expect(#helpers.table_to_json(m) <= 3000, "every message within 3000 bytes")
				ctx.expect(m.part == nil and m.parts == nil, "no part numbers: each message stands alone (R8)")
				ctx.expect(i == at or m.full == nil, "only one message carries full")
				stations_msgs = stations_msgs + (m.stations and 1 or 0)
			end
			ctx.expect(stations_msgs > 1, "50 filler stations need more than one stations message: " .. stations_msgs)
			home = stop_named("RT2 HOME")
			k1 = "c:" .. id .. "/t1"
			local st = find(reported("stations"), "name", "RT2 HOME")
			ctx.expect(st and st.surface == "sp3b" and st.limit == 4294967295 and st.count == 0 and st.script == 0
				and st.priority == 50, "station row, with its stop's surface (R31)")
			local c1, c2 = find(reported("conns"), "key", id .. "/t1"), find(reported("conns"), "key", id .. "/t2")
			ctx.expect(c1 and c1.box == "inbound" and c1.live and c1.ready and c1.queued == 0, "inbound row")
			ctx.expect(c2 and c2.box == "outbound" and c2.live and c2.ready and not c2.held and not c2.inflight, "outbound row")
			for key in pairs(r.starts) do
				ctx.expect(string.sub(key, 1, 2) == "c:", "inbound boxes are the only starts (R3): " .. key)
			end
			ctx.expect(r.starts[k1] ~= nil, "t1's box is a start")
			ctx.expect(#traced("ue.routing", "table") == 0, "ue.routing table not logged with the debug switch off")
			tables.walk(k1, r.starts[k1])
			local c = row(reported("costs"), k1, "s:" .. home.unit_number)
			ctx.expect(c and c[3] > 0, "the inbound box reaches RT2 HOME")
		end)
		ctx.at(1541, function()
			local r = storage.universal_edges.routing
			tables.walk(k1, r.starts[k1])
			ctx.expect(#reported("costs") == 0, "an unchanged row is not sent again")
			local u = home.unit_number
			home.destroy{ raise_destroy = true }
			ctx.expect(#queued("ue.route.report", function(p) return p.stops_gone and p.stops_gone[1] == u end) == 1,
				"a removed stop goes at once, in stops_gone")
			tables.pass()
			tables.walk(k1, r.starts[k1])
			ctx.expect(row(reported("gone"), k1, "s:" .. u) ~= nil, "and its cost rows go")
		end)
		ctx.at(1545, function()
			seams.block(id, "t1", true)
		end)
		ctx.at(1575, function()
			local r = storage.universal_edges.routing
			r.conns[id .. "/t1"] = nil -- forget the row the table task may have sent since, so this pass sends it again
			storage.universal_edges.stream_trace = true
			tables.pass()
			storage.universal_edges.stream_trace = false
			ctx.expect(#traced("ue.routing", "table") >= 1, "ue.routing table logged with the debug switch on")
			local c1 = find(reported("conns"), "key", id .. "/t1")
			ctx.expect(c1 and c1.ready == false, "a blocked inbound box reports not ready")
			-- both outbound boxes' end rails are goals a train on their track reaches: ground (U6) and elevated
			for _, cid in ipairs({ "t2", "t3" }) do
				local goal
				for _, g in ipairs(r.goals) do
					if g.key == "c:" .. id .. "/" .. cid then
						goal = base.goal(g)
					end
				end
				local tr = game.get_entity_by_unit_number(seams.add(id, cid, { layout = "L", at = 30 })).train
				local res = game.train_manager.request_train_path{ train = tr, goals = { goal }, type = "all-goals-penalties" }
				ctx.expect(res.accessible[1] == true, cid .. "'s end rail is a goal")
			end
			r.dirty = false
			game.get_surface("sp3b").create_entity{ name = "straight-rail", position = { 500, 60500 }, force = "player",
				raise_built = true }
			ctx.expect(r.dirty == true, "a rail build marks the table dirty")
		end)
	end)

-- fix round 2 (Critical/Important, findings 1+2): UE's build() resets d.rails to {} before its rail loop, so a box
-- whose build stalled partway (place() blocked on some rail) leaves ue.trains.get returning a short, not nil, rails
-- list -- base.lua's old code indexed v.rails[1] (inbound) and v.rails[#rails] (outbound) straight off that, which is
-- nil for an empty box and a wrong intermediate rail for a part-built one. Simulated here by truncating a normally-
-- built box's rails afterwards: the simplest honest way to reach that exact state without racing the connector's own
-- poll-task timing (the brief's other option, blocking the first rail's spot with an entity before the box ever
-- builds, depends on placing the blocker before that poll visit runs, which this file's other seams don't control).
t.case("routing: a stalled train box build doesn't crash the table, and isn't a start or goal (fix round 2, 1+2)", function(ctx)
	local id = "rt-stall"
	rig(ctx, 1600, id, 62000, { conn("ti", "ba", 4), conn("to", "ab", 24) }, { ti = { rails = 60 }, to = { rails = 40 } })
	ctx.at(1650, function() -- the box build itself (UE's own poll task) needs more than a couple of ticks to finish
		local epi, epo = seams.endpoint(id, "ti"), seams.endpoint(id, "to")
		ctx.expect(#epi.data.rails > 0 and #epo.data.rails > 0, "both boxes built normally first")
		epi.data.rails, epi.data.rail_ids = {}, {} -- the inbound box: stalled before placing its first rail
		epo.data.rails = { epo.data.rails[1], epo.data.rails[2], epo.data.rails[3] } -- the outbound box: stalled partway
		local r = storage.universal_edges.routing
		r.live = true
		tables.pass() -- must not raise
		ctx.expect(r.starts["c:" .. id .. "/ti"] == nil, "the stalled inbound box is not a start")
		local goal = false
		for _, g in ipairs(r.goals) do
			goal = goal or g.key == "c:" .. id .. "/to"
		end
		ctx.expect(not goal, "the stalled outbound box is not a goal")
		ctx.expect(r.conns[id .. "/ti"] and r.conns[id .. "/ti"].live == false and r.conns[id .. "/to"]
			and r.conns[id .. "/to"].live == false, "both report live = false")
	end)
end)

t.case("routing: reserve, cancel, resync to the controller's list, an unknown and a gone stop (D43)", function(ctx)
	local id = "rt-res"
	rig(ctx, 1600, id, 60400, { conn("t1", "ba", 4) }, { t1 = { rails = 30, station = "RT4 STOP" } })
	ctx.at(1640, function()
		local stop = stop_named("RT4 STOP")
		stop.trains_limit = 1
		local u = stop.unit_number
		deliver("ue.route.reserve", { trace = "rt4.1", unit = u })
		deliver("ue.route.reserve", { trace = "rt4.1", unit = u })
		ctx.expect(stop.script_reservations_count == 1, "one reservation per trace: " .. stop.script_reservations_count)
		ctx.expect(#traced("ue.reservation", "reserved", "rt4.1") == 1, "reserved, logged once")
		deliver("ue.route.cancel", { trace = "rt4.1" })
		ctx.expect(stop.script_reservations_count == 0, "cancelled")
		ctx.expect(#traced("ue.reservation", "cancelled", "rt4.1") == 1, "cancelled, logged")
		deliver("ue.route.reserve", { trace = "rt4.2", unit = u })
		deliver("ue.route.reserve", { trace = "rt4.3", unit = u })
		deliver("ue.route.resync", { reservations = { { trace = "rt4.3", unit = u }, { trace = "rt4.4", unit = u } } })
		local r = storage.universal_edges.routing.reserved
		ctx.expect(r["rt4.2"] == nil and r["rt4.3"] ~= nil and r["rt4.4"] ~= nil, "the controller's list, exactly")
		ctx.expect(stop.script_reservations_count == 2, "rt4.2 dropped, rt4.4 taken: " .. stop.script_reservations_count)
		ctx.expect(#traced("ue.reservation", "resynced") == 1, "resynced, logged")
		local s = storage.universal_edges.routing
		ctx.expect(s.live and s.full and s.dirty, "a resync enables the router and asks for a full table")
		deliver("ue.route.reserve", { trace = "rt4.5", unit = 999999999 })
		ctx.expect(#traced("ue.reservation", "missing", "rt4.5") == 1, "an unknown stop is logged, not raised")
		stop.destroy()
		deliver("ue.route.resync", { reservations = {} })
		ctx.expect(next(storage.universal_edges.routing.reserved) == nil, "a gone stop's reservations drop without error")
	end)
end)

t.case("routing: a remote destination asks on no_path; the reply inserts the next hop only; re-routes replace it by " ..
	"identity; retries are quiet (D42 point 4)", function(ctx)
	local id = "rt-route"
	rig(ctx, 1700, id, 61000, { conn("t2", "ab", 24), conn("t3", "ab", 44) }, { t2 = { rails = 60 }, t3 = { rails = 60 } })
	local unit, trace, s2, s3
	local function train()
		return game.get_entity_by_unit_number(unit).train
	end
	local function r()
		return storage.universal_edges.routing.active[trace]
	end
	ctx.at(1740, function()
		unit = seams.add(id, "t2", { layout = "LC", at = 40, next = "RT5 REMOTE A" })
		local sched = train().get_schedule()
		sched.remove_record{ schedule_index = 1 } -- leave only the remote destination
		sched.go_to_station(1)
		ctx.expect(train().state == defines.train_state.no_path, "no_path for a station no stop here has")
		ctx.expect_ipc("universal_edges:out", "RT5 REMOTE A")
		s2, s3 = ue.trains.get(id, "t2").end_rail.unit_number, ue.trains.get(id, "t3").end_rail.unit_number
	end)
	ctx.at(1742, function()
		trace = routes.trace_of(train())
		ctx.expect(trace and r().dest == "RT5 REMOTE A" and r().unrouted, "registered a tick later, waiting for the controller")
		routes.request(train(), r())
		local q = queued("ue.route.request", function(p) return p.trace == trace end)[1]
		local named = false
		for _, f in ipairs(q and q.firsts or {}) do
			named = named or f[1] == "c:" .. id .. "/t2"
		end
		ctx.expect(named and q.from == nil, "mid-track, the origin is the train's own costs, naming t2's box")
		ctx.expect(#traced("ue.route", "requested", trace) == 0, "a quiet request logs nothing")
		deliver("ue.route.reply", { trace = trace, ok = true, hops = { { edge = id, cid = "t2" }, { edge = "rt-x", cid = "c9" } } })
		ctx.expect(names(train()) == "<rail>*,RT5 REMOTE A" and hop_rails(train())[1] == s2 and train().get_schedule().current == 1,
			"the next hop only, temporary, ahead of the destination: " .. names(train()))
		ctx.expect(r().hop.cid == "t2" and not r().unrouted and #r().hops == 2, "the route kept")
		ctx.expect(#traced("ue.route", "applied", trace) == 1, "applied, logged")
	end)
	ctx.at(1745, function()
		ctx.expect(train().state ~= defines.train_state.no_path, "on its way to t2's box")
		deliver("ue.route.reply", { trace = trace, ok = true, hops = { { edge = id, cid = "t3" } } })
		-- (unverified) U3: remove_record of the current record, then add_record at current, leaves current on the new one
		ctx.expect(names(train()) == "<rail>*,RT5 REMOTE A" and hop_rails(train())[1] == s3 and train().get_schedule().current == 1,
			"re-routed by identity: " .. names(train()))
	end)
	ctx.at(1750, function()
		-- t3's box is on another track: no_path, so the check re-routes mid-tile and drops the unreachable hop
		ctx.expect(names(train()) == "RT5 REMOTE A" and r().hop == nil and r().unrouted, "an unreachable box re-routes")
	end)
	ctx.at(1751, function()
		r().asked = game.tick - 300 -- the sweep's visit is 5 s after the last ask
		routes.visit(trace, r())
		ctx.expect(#queued("ue.route.request", function(p) return p.trace == trace end) == 1, "the 5 s retry asks again")
		ctx.expect(#traced("ue.route", "requested", trace) == 0, "quietly: one log line per train")
	end)
	ctx.at(1752, function()
		deliver("ue.route.reply", { trace = trace, ok = true, hops = { { edge = id, cid = "t2" } } })
		ctx.expect(train().state ~= defines.train_state.no_path, "back on its way to t2's box")
	end)
	-- (checked, not in the brief) deleting the hop in the SAME tick as the deliver above would cancel out: the state
	-- would go no_path -> on_the_path -> no_path within one tick, which Factorio's on_train_changed_state does not
	-- report (it fires once per tick on the net change, confirmed by instrumenting train().state between the two
	-- calls). A tick apart, the player's own delete is a real transition the event does fire for.
	ctx.at(1753, function()
		train().get_schedule().remove_record{ schedule_index = 1 } -- the player deletes the hop by hand
	end)
	ctx.at(1757, function()
		ctx.expect(names(train()) == "RT5 REMOTE A" and r().hop == nil and r().unrouted, "a hop deleted by hand re-routes")
	end)
end)

t.case("routing: an elevated hop is the box's end rail", function(ctx)
	local id = "rt-elev"
	rig(ctx, 1800, id, 61400, { conn("t4", "ab", 24, "elevated") }, { t4 = { rails = 40 } })
	local unit, trace
	local function train()
		return game.get_entity_by_unit_number(unit).train
	end
	local function r()
		return storage.universal_edges.routing.active[trace]
	end
	ctx.at(1840, function()
		unit = seams.add(id, "t4", { layout = "L", at = 30, next = "RT5 REMOTE E" })
		local sched = train().get_schedule()
		sched.remove_record{ schedule_index = 1 }
		sched.go_to_station(1)
		ctx.expect(train().state == defines.train_state.no_path, "no_path: RT5 REMOTE E has no stop here")
	end)
	ctx.at(1842, function()
		trace = routes.trace_of(train())
		ctx.expect(trace ~= nil, "registered")
		deliver("ue.route.reply", { trace = trace, ok = true, hops = { { edge = id, cid = "t4" } } })
		ctx.expect(names(train()) == "<rail>*,RT5 REMOTE E", "an elevated hop is a rail record: " .. names(train()))
		ctx.expect(r().hop.rail == ue.trains.get(id, "t4").end_rail, "the box's end rail, by identity")
	end)
	ctx.at(1847, function()
		ctx.expect(train().state ~= defines.train_state.no_path, "on its way to t4's end rail")
	end)
end)

t.case("routing: a removed box re-routes mid-tile (sweep's base.live test)", function(ctx)
	local id = "rt-gone"
	rig(ctx, 1900, id, 61800, { conn("t2", "ab", 24) }, { t2 = { rails = 60 } })
	local unit, trace
	local function train()
		return game.get_entity_by_unit_number(unit).train
	end
	local function r()
		return storage.universal_edges.routing.active[trace]
	end
	ctx.at(1940, function()
		unit = seams.add(id, "t2", { layout = "LC", at = 40, next = "RT5 REMOTE C" })
		local sched = train().get_schedule()
		sched.remove_record{ schedule_index = 1 }
		sched.go_to_station(1)
		ctx.expect(train().state == defines.train_state.no_path, "no_path: RT5 REMOTE C has no stop here")
	end)
	ctx.at(1942, function()
		trace = routes.trace_of(train())
		deliver("ue.route.reply", { trace = trace, ok = true, hops = { { edge = id, cid = "t2" } } })
		ctx.expect(r().hop and r().hop.cid == "t2" and not r().unrouted, "the hop inserted")
	end)
	ctx.at(1950, function()
		seams.edge(id, 61800, {}, { rev = 2 }) -- the connector list goes empty: t2's box is torn down
	end)
	ctx.at(1955, function()
		routes.visit(trace, r()) -- the sweep's base.live test drops a hop whose box is gone, whether or not its rail survived
	end)
	ctx.at(1990, function()
		ctx.expect(names(train()) == "RT5 REMOTE C" and r().hop == nil and r().unrouted,
			"the removed box's hop is gone: a mid-tile re-route drops it: " .. names(train()))
	end)
end)

t.case("routing: lost trains -- destroyed, schedule changed; a re-anchored trace replaces the old mapping", function(ctx)
	local id = "rt-lost"
	rig(ctx, 2000, id, 62200, { conn("t2", "ab", 24) }, { t2 = { rails = 70 } })
	ctx.at(2040, function()
		local function spawn(at, next_name)
			local unit = seams.add(id, "t2", { layout = "L", at = at, next = next_name })
			return game.get_entity_by_unit_number(unit)
		end
		local A, B, C, D = spawn(30, "RT5 L1"), spawn(60, "RT5 L2"), spawn(90, "x"), spawn(120, "x")
		routes.register(A.train, "rt5l.1", "RT5 L1", {})
		local rB = routes.register(B.train, "rt5l.2", "RT5 L2", {})
		rB.unrouted = false
		local unitA, unitB = A.unit_number, B.unit_number
		A.destroy()
		B.train.get_schedule().remove_record{ schedule_index = 2 } -- the player removes B's destination record
		routes.visit("rt5l.1", storage.universal_edges.routing.active["rt5l.1"])
		routes.visit("rt5l.2", storage.universal_edges.routing.active["rt5l.2"])
		ctx.expect(#queued("ue.route.lost", function(p) return p.trace == "rt5l.1" and p.reason == "destroyed" end) == 1,
			"A: destroyed, without a crossing")
		ctx.expect(#queued("ue.route.lost", function(p) return p.trace == "rt5l.2" and p.reason == "schedule_changed" end) == 1,
			"B: its destination left the schedule")
		ctx.expect(#traced("ue.route", "lost", "rt5l.1") == 1 and #traced("ue.route", "lost", "rt5l.2") == 1,
			"both logged")
		local rs = storage.universal_edges.routing
		ctx.expect(rs.active["rt5l.1"] == nil and rs.active["rt5l.2"] == nil, "both forgotten")
		ctx.expect(rs.by_unit[unitA] == nil and rs.by_unit[unitB] == nil, "and their anchors freed")
		routes.register(C.train, "rt5l.3", "x", {})
		routes.register(D.train, "rt5l.3", "x", {})
		ctx.expect(storage.universal_edges.routing.by_unit[C.unit_number] == nil, "C's mapping is replaced, not kept alongside D's")
		ctx.expect(storage.universal_edges.routing.by_unit[D.unit_number] == "rt5l.3", "D re-anchors rt5l.3")
	end)
end)

t.case("routing: at a station, the origin is its departure (point 3)", function(ctx)
	local id = "rt-station"
	rig(ctx, 2100, id, 62600, { conn("t1", "ba", 10) }, { t1 = { rails = 60, station = "RT5K HOME" } })
	ctx.at(2140, function()
		-- (unverified) U4, checked: tr.station is nil once the train leaves RT5K HOME trying for the next record, even
		-- though it never physically moves (destination_full's own def is "no_path, but every candidate stop is full";
		-- plain no_path here, so the fallback applies): origin() falls to the firsts branch, naming no box (this rig has
		-- no outbound connector), so the request carries start "train" with empty firsts. Recorded for the owner
		-- (Open question 1); the own-train fallback still asks the controller either way. ctx.expect_ipc plays back
		-- against the harness's own stdout at the end of the whole run, so it can be declared before the offer below.
		ctx.expect_ipc("universal_edges:out", '"start":"train"')
		offer(id, 1, { { station = "RT5K HOME", wait_conditions = { { type = "time", ticks = 60 } } },
			{ station = "RT5 REMOTE K" } }, nil, "LC")
	end)
	ctx.at(2700, function()
		local tr = seams.trains(id, "t1")[1]
		ctx.expect(tr ~= nil, "the crossed train is still on this tile")
		if tr then
			ctx.expect(tr.state == defines.train_state.no_path, "no_path: RT5 REMOTE K has no stop here")
			local trace = routes.trace_of(tr)
			local r = trace and storage.universal_edges.routing.active[trace]
			ctx.expect(r ~= nil and r.dest == "RT5 REMOTE K", "an active route for the remote leg")
		end
	end)
end)

t.case("routing: a full local stop also asks (destination_full, Ruling P1); its remote reply is not swept as arrived " ..
	"while still at the full stop (Ruling P2)", function(ctx)
	local id = "rt-full"
	-- Different cids are separate, unconnected tracks (confirmed against case (a)'s own t2/t3: a hop onto a cid other
	-- than the one the train already stands on goes no_path at once -- the pathfinder genuinely can't reach it, same
	-- as a crossing elsewhere would need Task 6's hop-by-hop handoff, out of this task's scope). So the full station and
	-- the "remote" hop both live on t2's own track here, as case (a)'s own t2 hop does: the train starts right there,
	-- trivially reachable, same as a real remote box would be once the train actually arrives at its edge.
	rig(ctx, 2760, id, 63000, { conn("t2", "ab", 24) }, { t2 = { rails = 60, station = "RT5F HOME" } })
	local unit, trace, s2
	local function train()
		return game.get_entity_by_unit_number(unit).train
	end
	local function r()
		return storage.universal_edges.routing.active[trace]
	end
	ctx.at(2800, function()
		local home = stop_named("RT5F HOME")
		home.trains_limit = 1
		home.script_reservations_count = 1 -- D43: a script reservation fills the only slot
		s2 = ue.trains.get(id, "t2").end_rail.unit_number
		unit = seams.add(id, "t2", { layout = "LCl", at = 40, next = "RT5F HOME" })
		local sched = train().get_schedule()
		sched.remove_record{ schedule_index = 1 }
		sched.go_to_station(1)
		ctx.expect(train().state == defines.train_state.destination_full,
			"destination_full: RT5F HOME exists here but its one slot is reserved")
	end)
	ctx.at(2802, function()
		trace = routes.trace_of(train())
		routes.request(train(), r())
		local q = queued("ue.route.request", function(p) return p.trace == trace end)[1]
		local mine = false
		for _, f in ipairs(q and q.firsts or {}) do
			mine = mine or f[1] == "s:" .. stop_named("RT5F HOME").unit_number
		end
		ctx.expect(mine, "R4: the train's own request includes this tile's full RT5F HOME")
		ctx.expect(trace and r().dest == "RT5F HOME" and r().unrouted, "P1: a full local destination asks too")
		deliver("ue.route.reply", { trace = trace, ok = true, hops = { { edge = id, cid = "t2" } } })
		ctx.expect(names(train()) == "<rail>*,RT5F HOME" and hop_rails(train())[1] == s2 and train().get_schedule().current == 1,
			"P1: the remote reply's next hop is inserted: " .. names(train()))
		ctx.expect(r().hop.cid == "t2" and not r().unrouted, "the route kept")
	end)
	ctx.at(2804, function()
		ctx.expect(train().state ~= defines.train_state.no_path, "on its way to t2's own box, trivially reachable")
		routes.visit(trace, r())
		ctx.expect(#queued("ue.route.arrived", function(p) return p.trace == trace end) == 0,
			"P2: a local-named route assigned to a remote stop is not swept as arrived while the train still " ..
			"sits at its full local stop")
		ctx.expect(storage.universal_edges.routing.active[trace] ~= nil and storage.universal_edges.routing.active[trace].hop ~= nil,
			"the route and its hop stay active")
	end)
end)

t.case("routing: capture carries the trace, the destination and the hops after this connector, deterministically", function(ctx)
	local id = "rt-capture"
	rig(ctx, 2200, id, 63000, { conn("t2", "ab", 24) }, { t2 = { rails = 40 } })
	ctx.at(2240, function()
		local tr = game.get_entity_by_unit_number(seams.add(id, "t2", { layout = "LC", at = 30, next = "RT6 F" })).train
		local r = routes.register(tr, "rt6f.1", "RT6 F", { { edge = id, cid = "t2" }, { edge = "rt-next", cid = "c9" } })
		local ext = hooks.capture(seams.endpoint(id, "t2"), tr)
		local d = ext and ext.router
		ctx.expect(d and d.trace == "rt6f.1" and d.dest == "RT6 F" and #d.hops == 1 and d.hops[1].edge == "rt-next",
			"the rest of the route rides the body")
		ctx.expect(r.captured == true, "marked captured: the sweep won't call it lost once commit deletes it")
		ctx.expect(helpers.table_to_json(hooks.capture(seams.endpoint(id, "t2"), tr)) == helpers.table_to_json(ext),
			"the same train gives the same data (D21)")
	end)
end)

t.case("routing: on a transit tile the carried next hop goes in at once, then a border request (re-route at every border)", function(ctx)
	local id = "rt-transit"
	rig(ctx, 2250, id, 63400, { conn("t1", "ba", 4), conn("t2", "ab", 24) }, { t1 = { rails = 60 }, t2 = { rails = 40 } })
	ctx.at(2290, function()
		offer(id, 1, { { station = "RT6 G" } },
			{ router = { trace = "rt6g.1", dest = "RT6 G", hops = { { edge = id, cid = "t2" }, { edge = "rt-next", cid = "c9" } } } }, "LC")
		ctx.expect(reply(id, 1) == "credited", "credited: " .. tostring(reply(id, 1)))
		local tr = seams.trains(id, "t1")[1]
		ctx.expect(names(tr) == "<rail>*,RT6 G" and hop_rails(tr)[1] == ue.trains.get(id, "t2").end_rail.unit_number
			and tr.get_schedule().current == 1,
			"the carried next hop, at once: " .. names(tr))
		local q = queued("ue.route.request", function(p) return p.trace == "rt6g.1" end)[1]
		ctx.expect(q and q.via == id .. "/t1" and q.firsts == nil, "a border request: via, no search")
		ctx.expect(routes.trace_of(tr) == "rt6g.1", "anchored on this tile")
	end)
end)

t.case("routing: at the destination tile the reservation is released, the train re-paths to the stop, arrived goes up (D43)", function(ctx)
	local id = "rt-dest"
	rig(ctx, 2300, id, 63800, { conn("t1", "ba", 4) }, { t1 = { rails = 60, station = "RT6 DEST" } })
	local stop
	ctx.at(2340, function()
		stop = stop_named("RT6 DEST")
		stop.trains_limit = 1
		deliver("ue.route.reserve", { trace = "rt6h.1", unit = stop.unit_number })
		ctx.expect(stop.script_reservations_count == 1, "reserved: full for any other train")
		offer(id, 1, { { station = "RT6 DEST" } }, { router = { trace = "rt6h.1", dest = "RT6 DEST", hops = {} } }, "LC")
		ctx.expect(reply(id, 1) == "credited", "credited")
		ctx.expect(stop.script_reservations_count == 0, "released on arrival")
		ctx.expect(#queued("ue.route.arrived", function(p) return p.trace == "rt6h.1" end) == 1, "arrived, to the controller")
		ctx.expect(#traced("ue.reservation", "released", "rt6h.1") == 1 and #traced("ue.route", "arrived", "rt6h.1") == 1,
			"released and arrived, logged")
		ctx.expect(traced("ue.route", "arrived", "rt6h.1")[1].level == "info", "a held reservation: arrived is info")
	end)
	ctx.at(2345, function()
		local tr = seams.trains(id, "t1")[1]
		ctx.expect(tr.state ~= defines.train_state.destination_full and tr.path_end_stop == stop,
			"heading for the stop it reserved, not destination_full: " .. tr.state)
	end)
end)

-- An arrival with no reservation held (it was cancelled, or never reached this tile) is a warning. Row 80200, ticks
-- 3700-3740 (free: no other rig uses the row).
t.case("routing: arriving at the end of the route with no reservation held logs arrived as a warning", function(ctx)
	local id = "rt-noresv"
	rig(ctx, 3700, id, 80200, { conn("t1", "ba", 4) }, { t1 = { rails = 60, station = "RT6 NORESV" } })
	ctx.at(3740, function()
		offer(id, 1, { { station = "RT6 NORESV" } }, { router = { trace = "rt6w.1", dest = "RT6 NORESV", hops = {} } }, "LC")
		ctx.expect(reply(id, 1) == "credited", "credited")
		ctx.expect(#queued("ue.route.arrived", function(p) return p.trace == "rt6w.1" end) == 1, "arrived, to the controller")
		local line = traced("ue.route", "arrived", "rt6w.1")[1]
		ctx.expect(line and line.level == "warn", "no booking held: arrived is warn")
	end)
end)

-- A booking holds for the whole trip (ILLISIS/universal_edges#2 part 2b, spike 48): the arriving train takes its stop's slot
-- over the limit, and the limit is back at once. Rows 80600-81400, ticks 3740-3820 (free). A first train, unrouted, is
-- already heading for the stop (trains_count 1, limit 1); the booked one materializes behind it.
local function keep_case(label, id, y, name, trace, full, circuit)
	t.case("routing: " .. label, function(ctx)
		rig(ctx, 3740, id, y, { conn("t1", "ba", 4) }, { t1 = { rails = 60, station = name } })
		local stop
		ctx.at(3742, function()
			stop = stop_named(name)
			if circuit then
				circuit_limit(stop, stop.position.x, stop.position.y + 3, 1)
			else
				stop.trains_limit = 1
			end
		end)
		ctx.at(3780, function()
			if full then
				offer(id, 1, { { station = name } }, nil, "LC")
				ctx.expect(reply(id, 1) == "credited", "the first train: " .. tostring(reply(id, 1)))
			end
		end)
		ctx.at(3810, function()
			ctx.expect(not full or stop.trains_count == 1, "a train already heading there: " .. stop.trains_count)
			deliver("ue.route.reserve", { trace = trace, unit = stop.unit_number })
			local seq = full and 2 or 1
			offer(id, seq, { { station = name } }, { router = { trace = trace, dest = name, hops = {} } }, "LC")
			ctx.expect(reply(id, seq) == "credited", "credited: " .. tostring(reply(id, seq)))
			local line = traced("ue.route", "arrived", trace)[1]
			ctx.expect(line and (line.raised == true) == full, "raised only when the stop was full")
			ctx.expect(stop.trains_limit == 1, "the limit is back: " .. stop.trains_limit)
			local heading
			for _, tr in ipairs(seams.trains(id, "t1")) do
				heading = heading or (tr.path_end_stop == stop and tr.state ~= defines.train_state.destination_full)
			end
			ctx.expect(full == false or heading, "the booked train is heading for the stop, not destination_full")
		end)
		ctx.at(3815, function()
			ctx.expect(stop.trains_limit == 1, "the limit stays")
			for _, tr in ipairs(seams.trains(id, "t1")) do
				ctx.expect(tr.state ~= defines.train_state.destination_full, "no train in destination_full")
			end
		end)
	end)
end
keep_case("a full stop: the booked train arriving over the limit is not turned away, the limit is restored", "rt-keep",
	80600, "RT6 KEEP", "rtk.1", true, false)
keep_case("the same with a circuit-controlled limit", "rt-keepc", 81000, "RT6 KEEPC", "rtk.2", true, true)
keep_case("a stop with a free slot: no raise", "rt-keepf", 81400, "RT6 KEEPF", "rtk.3", false, false)

t.case("routing: the route follows the train through every join (new train ids); a reply after assembly applies to it", function(ctx)
	local id = "rt-joins"
	rig(ctx, 2400, id, 64200, { conn("t1", "ba", 4), conn("t2", "ab", 24) },
		{ t1 = { rails = 120, station = "RT6 J HOME" }, t2 = { rails = 40 } })
	local front, ids = nil, {}
	ctx.at(2440, function()
		-- the local record keeps it moving while it assembles, as UE's ext join test does. It is the route's destination
		-- (review C1: a route whose train runs another record is over), and a hop on a later tile, not here, is left
		-- (review I1: so not arrival, and nothing is inserted)
		offer(id, 1, { { station = "RT6 J HOME" } },
			{ router = { trace = "rt6j.1", dest = "RT6 J HOME", hops = { { edge = "rt-nowhere", cid = "zzz" } } } },
			"L" .. string.rep("C", 19), 0.8)
		ctx.expect(reply(id, 1) == "credited", "credited")
		front = seams.endpoint(id, "t1").data.queue.front
	end)
	for k = 2441, 2700 do
		ctx.at(k, function()
			if front and front.valid then
				ids[front.train.id] = true
				ctx.expect(routes.trace_of(front.train) == "rt6j.1", "found on train " .. front.train.id .. " at " .. k)
				ctx.expect(not (storage.universal_edges.routing.active["rt6j.1"] or {}).manual,
					"a join's transient manual reset never reaches the route (§7.6) at " .. k)
			end
		end)
	end
	ctx.at(2701, function()
		local tr = front.train
		local seen = 0
		for _ in pairs(ids) do
			seen = seen + 1
		end
		ctx.expect(#tr.carriages == 20 and seen > 1, "assembled, through " .. seen .. " train ids")
		deliver("ue.route.reply", { trace = "rt6j.1", ok = true, hops = { { edge = id, cid = "t2" } } })
		local sched = tr.get_schedule()
		local rec = sched.get_record{ schedule_index = sched.current }
		ctx.expect(rec.rail and rec.rail.unit_number == ue.trains.get(id, "t2").end_rail.unit_number
			and rec.temporary, "the hop on the joined train")
	end)
end)

-- Carried from Task 5's review (Minor, now load-bearing): sweep's arrival test (`not r.hop and routes.is_local(r.dest)`)
-- is only sound because register() always sets unrouted = true. materialized's transit branch registers a route on
-- the arriving tile too (dest not local here, so it takes the transit branch, not the arrived one), so the same
-- invariant must hold there: a hop that never resolves leaves r.hop nil, same shape sweep's arrival check looks for.
-- sweep()'s own comment already names the risk -- "a stop with the name was built here after the fact" -- so that's
-- exactly what this reproduces: the stop appears only after materialized already registered the route as remote.
t.case("routing: a route materialized as remote is not swept as arrived once a same-named stop is built here after " ..
	"the fact, while still unrouted (carried note, Task 5 review)", function(ctx)
	local id = "rt-coincide"
	rig(ctx, 2750, id, 65000, { conn("t1", "ba", 4) }, { t1 = { rails = 60 } })
	ctx.at(2790, function()
		ctx.expect(routes.is_local("RT6 SAME") == false, "not local yet: no stop anywhere by this name")
		offer(id, 1, { { station = "RT6 SAME" } },
			{ router = { trace = "rt6k.1", dest = "RT6 SAME", hops = { { edge = "rt-nowhere", cid = "zzz" } } } }, "LC")
		ctx.expect(reply(id, 1) == "credited", "credited: " .. tostring(reply(id, 1)))
		local tr = seams.trains(id, "t1")[1]
		local trace = routes.trace_of(tr)
		ctx.expect(trace == "rt6k.1", "registered as a remote (transit) route, anchored on this tile")
		local r = storage.universal_edges.routing.active[trace]
		ctx.expect(r ~= nil and r.hop == nil, "the only hop names a box this tile doesn't have: it never resolved")
		ctx.expect(r ~= nil and r.unrouted == true, "still unrouted: no controller reply yet")
		-- a stop of the very same name is built here after the fact (sweep()'s own comment names this case)
		local s = game.get_surface("sp3b")
		s.request_to_generate_chunks({ 20000, 65000 }, 0)
		s.force_generate_chunk_requests()
		assert(s.create_entity{ name = "straight-rail", position = { 20000, 65000 }, direction = defines.direction.north,
			force = "player" }, "coincidence rail")
		local st = assert(s.create_entity{ name = "train-stop", position = { 20002, 65000 }, direction = defines.direction.north,
			force = "player" }, "coincidence stop")
		st.backer_name = "RT6 SAME"
		ctx.expect(routes.is_local("RT6 SAME") == true, "now local: this tile happens to have a stop of the same name")
		routes.visit(trace, r)
		ctx.expect(#queued("ue.route.arrived", function(p) return p.trace == "rt6k.1" end) == 0,
			"not swept as arrived: still unrouted (register()'s invariant) -- the name turning up local doesn't decide it")
		ctx.expect(storage.universal_edges.routing.active[trace] ~= nil, "the route stays active, waiting on the border request's reply")
	end)
end)

-- T6a (§7.5, §7.6): a rejected crossing restores the train here in manual mode (the box shape of
-- trains_handoff_game_test.lua's rejected case: pos 10, 150 rails, a train at 40, speed 1, captured 172 ticks later).
-- UE's restored hook clears captured and logs rejected; the route survives. The next visit sends manual (the controller
-- releases the reservation); back to automatic, the train asks again; destroyed afterwards, it is lost.
t.case("routing: captured, then rejected — the route survives as manual, asks again once automatic; destroyed, it is lost",
	function(ctx)
		local id = "rt-captured-lost"
		rig(ctx, 2850, id, 65400, { conn("t1", "ab", 10) }, { t1 = { rails = 150 } })
		local unit, trace = nil, "rt6lost.1"
		local function train()
			local e = game.get_entity_by_unit_number(unit)
			return e and e.valid and e.train
		end
		ctx.at(2890, function()
			unit = seams.add(id, "t1", { layout = "LC", at = 40, next = "RT6 LOST", speed = 1 })
			routed(train(), trace, "RT6 LOST", id, "t1")
		end)
		ctx.at(3062, function()
			local ep = seams.endpoint(id, "t1")
			local route = storage.universal_edges.routing.active[trace]
			ctx.expect(ep.data.held ~= nil and route.captured == true, "captured for real, by the box's own poll")
			local seq = ep.tx.ab.inflight.seq
			seams.lane(id, { k = "u.reply", cid = "t1", dir = "ab", seq = seq, outcome = "reject", w = seq })
			ctx.expect(ep.data.held == nil and train().manual_mode == true, "restored here, manual")
			local line = traced("ue.route", "rejected", trace)[1]
			ctx.expect(route.captured == false and line and line.why == "reject" and line.level == "warn" and line.edge == id
				and line.cid == "t1", "restored cleared captured, and rejected is logged")
			ctx.expect(#queued("ue.route.lost", function(p) return p.trace == trace end) == 0, "not lost")
			routes.visit(trace, route)
			ctx.expect(#queued("ue.route.manual", function(p) return p.trace == trace end) == 1 and route.manual,
				"the next visit: manual, so the controller releases its reservation (§7.6)")
			train().manual_mode = false
			routes.visit(trace, route)
			local asked = traced("ue.route", "requested", trace)[1]
			ctx.expect(asked and asked.start == "automatic" and not route.manual, "automatic again: it asks at once")
			for _, c in ipairs(train().carriages) do
				c.destroy()
			end
			routes.visit(trace, route)
			ctx.expect(#queued("ue.route.lost", function(p) return p.trace == trace and p.reason == "destroyed" end) == 1,
				"destroyed after the reject: lost, so the controller's reservation isn't leaked (D43)")
		end)
	end)

t.case("routing: the station list arrives; the panel adds a schedule record and an interrupt target by name (D42 point 7)",
	function(ctx)
		local id = "rt-panel"
		rig(ctx, 3600, id, 64600, { conn("t2", "ab", 24) }, { t2 = { rails = 40 } })
		ctx.at(3640, function()
			deliver("ue.route.stations", { full = true,
				set = { { surface = "sp3b", name = "RT8 FAR", tiles = { "gridworld_-2_0" }, free = 1 } }, gone = {} })
			local list = storage.universal_edges.routing.list
			ctx.expect(list.sp3b and list.sp3b["RT8 FAR"] and list.sp3b["RT8 FAR"].free == 1,
				"stored for the panel, by surface and name (R35)")
			local tr = game.get_entity_by_unit_number(seams.add(id, "t2", { layout = "L", at = 30, manual = true })).train
			local sched = tr.get_schedule()
			sched.set_interrupts{ { name = "RT8 I", conditions = { { type = "time", ticks = 60 } }, targets = {} } }
			panel.add_record(tr, "RT8 FAR")
			panel.add_target(tr, "RT8 I", "RT8 FAR")
			local recs = sched.get_records()
			ctx.expect(recs[#recs].station == "RT8 FAR", "a schedule record")
			ctx.expect(next(recs[#recs].wait_conditions or {}) == nil, "with no wait condition (owner, 2026-10-07)")
			local it = sched.get_interrupt(1)
			ctx.expect(it.targets[#it.targets].station == "RT8 FAR", "an interrupt target")
			ctx.expect(tr.manual_mode, "adding records leaves a manual train manual")
			ctx.expect(pcall(panel.add_target, tr, "RT8 GONE", "RT8 FAR") and #sched.get_interrupt(1).targets == 1,
				"an interrupt the player removed meanwhile: a no-op, not a crash")
		end)
	end)

-- Review C1: a route entry is over once its train's current record is neither the entry's destination nor its inserted
-- hop. The reviewer's scenario, shortest form: the train waits at a full local stop (Ruling P1 asks, the ask fails),
-- then moves on to a remote record. check() ends the old entry and asks for the new record; so does the sweep.
t.case("routing: a train that moved on from a failed ask is routed for its new record; the old entry ends quietly " ..
	"(review C1)", function(ctx)
	local id = "rt-moved"
	rig(ctx, 3160, id, 65800, { conn("t2", "ab", 24) }, { t2 = { rails = 60, station = "RTC1 A" } })
	local unit, first, second
	local function train()
		return game.get_entity_by_unit_number(unit).train
	end
	local function ended(trace)
		return #queued("ue.route.lost", function(p) return p.trace == trace and p.reason == "moved_on" end) == 1
			and storage.universal_edges.routing.active[trace] == nil
	end
	local function asked(trace, dest)
		local r = trace and storage.universal_edges.routing.active[trace]
		return r ~= nil and r.dest == dest and #queued("ue.route.request", function(p) return p.trace == trace and p.dest == dest end) == 1
	end
	ctx.at(3200, function()
		local a = stop_named("RTC1 A")
		a.trains_limit, a.script_reservations_count = 1, 1 -- full: P1 asks the router
		unit = seams.add(id, "t2", { layout = "LC", at = 40 })
		local sched = train().get_schedule()
		sched.set_records{ { station = "RTC1 A" }, { station = "RTC1 B" }, { station = "RTC1 C" } }
		sched.go_to_station(1)
		ctx.expect(train().state == defines.train_state.destination_full, "destination_full at RTC1 A")
	end)
	ctx.at(3202, function()
		first = routes.trace_of(train())
		ctx.expect(first and storage.universal_edges.routing.active[first].dest == "RTC1 A", "P1 asked for RTC1 A")
		deliver("ue.route.reply", { trace = first, ok = false, reason = "no_path" }) -- the ask fails: still unrouted
		train().get_schedule().go_to_station(2) -- RTC1 A's wait is over; RTC1 B has no stop here
		ctx.expect(train().state == defines.train_state.no_path, "no_path for RTC1 B")
		routes.check(unit) -- what on_train_changed_state's check does a tick later
		second = routes.trace_of(train())
		ctx.expect(ended(first), "the RTC1 A entry ended: router.lost moved_on")
		local line = traced("ue.route", "lost", first)[1]
		ctx.expect(line and line.level == "info", "the normal end of a wait: logged at info, not warn")
		ctx.expect(second ~= first and asked(second, "RTC1 B"), "a fresh route, asked for RTC1 B")
	end)
	ctx.at(3203, function()
		routes.check(unit) -- a tick later: the unrouted route was just asked, so it isn't asked again
		ctx.expect(#queued("ue.route.request", function(p) return p.trace == second end) == 0,
			"no second ue.route.request for RTC1 B this tick")
	end)
	ctx.at(3204, function()
		-- no_path to no_path fires no state change: the sweep alone ends the entry, and the waiting walker checks the train
		train().get_schedule().go_to_station(3)
		local s = storage.universal_edges.routing
		routes.visit(second, s.active[second])
		ctx.expect(s.waiting[unit] == true, "the sweep ended the entry and put the train in the waiting set")
		s.waiting[unit] = nil
		routes.check(unit) -- what the waiting walker does at its next visit
		local third = routes.trace_of(train())
		ctx.expect(ended(second), "the sweep ended the RTC1 B entry")
		ctx.expect(third ~= second and asked(third, "RTC1 C"), "and asked for RTC1 C")
	end)
end)

-- Review I1: arrival is where the router's route ends (no carried hops left), not wherever a stop shares the name.
t.case("routing: on a transit tile, a stop sharing the destination's name is not arrival while hops remain (review I1)", function(ctx)
	local id = "rt-same-name"
	rig(ctx, 3250, id, 66200, { conn("t1", "ba", 4), conn("t2", "ab", 24) },
		{ t1 = { rails = 60, station = "RTI1 FUEL" }, t2 = { rails = 40 } })
	ctx.at(3290, function()
		offer(id, 1, { { station = "RTI1 FUEL" } }, { router = { trace = "rti1.1", dest = "RTI1 FUEL",
			hops = { { edge = id, cid = "t2" }, { edge = "rt-next", cid = "c9" } } } }, "LC")
		ctx.expect(reply(id, 1) == "credited", "credited: " .. tostring(reply(id, 1)))
		local tr = seams.trains(id, "t1")[1]
		ctx.expect(#queued("ue.route.arrived", function(p) return p.trace == "rti1.1" end) == 0,
			"not arrived: the route goes on to a later tile")
		ctx.expect(names(tr) == "<rail>*,RTI1 FUEL",
			"the carried next hop, at once: " .. names(tr))
		local q = queued("ue.route.request", function(p) return p.trace == "rti1.1" end)[1]
		ctx.expect(q and q.via == id .. "/t1", "a border request")
		ctx.expect(routes.trace_of(tr) == "rti1.1", "registered as a transit route")
	end)
end)

-- Review M1: go_to_station switches a train to automatic, so a reply must not reach a train the player drives.
t.case("routing: a route reply for a train in manual mode inserts nothing and leaves it manual (review M1)", function(ctx)
	local id = "rt-manual"
	rig(ctx, 3300, id, 66600, { conn("t2", "ab", 24) }, { t2 = { rails = 60 } })
	ctx.at(3340, function()
		local tr = game.get_entity_by_unit_number(seams.add(id, "t2", { layout = "LC", at = 40, next = "RTM1 FAR",
			manual = true })).train
		tr.get_schedule().remove_record{ schedule_index = 1 } -- only the remote destination
		local r = routes.register(tr, "rtm1.1", "RTM1 FAR", {}) -- it asked, then the player took it into manual
		deliver("ue.route.reply", { trace = "rtm1.1", ok = true, hops = { { edge = id, cid = "t2" } } })
		ctx.expect(tr.manual_mode == true, "still manual")
		ctx.expect(names(tr) == "RTM1 FAR" and r.hop == nil and r.unrouted, "nothing inserted, still unrouted: " .. names(tr))
	end)
end)

--- A stand-in for a player's GUI (game tests have no LuaPlayer): add, destroy, children, and a child by its name.
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

-- Review I3: a broadcast changing only free counts updates the open panel in place; a rebuild keeps the pick.
t.case("routing: a station list broadcast keeps an open panel's interrupt pick and updates its free counts in place " ..
	"(review I3)", function(ctx)
	local id = "rt-panel-keep"
	rig(ctx, 3500, id, 67000, { conn("t2", "ab", 24) }, { t2 = { rails = 40 } })
	ctx.at(3540, function()
		local wait = { { type = "time", ticks = 60 } }
		local loco = game.get_entity_by_unit_number(seams.add(id, "t2", { layout = "L", at = 30, manual = true,
			interrupts = { { name = "RT9 I1", conditions = wait, targets = {} }, { name = "RT9 I2", conditions = wait, targets = {} } } }))
		local here = loco.surface.name
		local player = { index = 1, gui = { screen = fake_gui(), relative = fake_gui() }, opened = loco, display_scale = 1.25,
				display_resolution = { width = 2560, height = 2088 } }
		local function change(set)
			deliver("ue.route.stations", { set = set, gone = {} })
			panel.show(player, true) -- what the handler does for each connected player with the panel open
			return player.gui.screen.router_stations
		end
		local function grid(frame)
			return frame.router_pane.router_grid
		end
		local function entry(name, tile, free)
			return { surface = here, name = name, tiles = { tile }, free = free }
		end
		deliver("ue.route.stations", { full = true, set = { entry("RT9 A", "gridworld_0_0", 2) }, gone = {} })
		panel.show(player) -- the player opens the train window
		local frame = player.gui.screen.router_stations
		local pick = frame.router_add_row.router_add_to
		pick.selected_index = 3 -- and picks the second interrupt
		local now = change({ entry("RT9 A", "gridworld_0_0", 1) })
		ctx.expect(now == frame and frame.valid and grid(now) == grid(frame), "only a free count changed: the same panel and rows")
		ctx.expect(pick.selected_index == 3, "the pick stays on interrupt 2: " .. pick.selected_index)
		-- three columns: a header of three cells, then name, free, "+" a row
		local kids = grid(now).children
		ctx.expect(#kids == 6 and kids[1].caption == "Station [img=info]" and kids[2].caption == "Free [img=info]"
			and kids[1].style_name == "bold_label" and kids[3].type == "empty-widget", "the header row")
		ctx.expect(kids[5].caption == "1", "the free count updated: " .. tostring(kids[5].caption))
		ctx.expect(kids[4].tooltip == "On tiles: 0,0", "the name's tooltip holds the shortened tile")
		ctx.expect(kids[6].type == "sprite-button" and kids[6].style_name == "tool_button" and kids[6].sprite == "utility/add_white"
			and kids[6].tags.name == "RT9 A", "the + is a tool button")
		local old = grid(now)
		now = change({ entry("RT9 B", "gridworld_1_0", 1) })
		ctx.expect(grid(now) ~= old and #grid(now).children == 9, "a new name: the rows rebuilt")
		ctx.expect(now.router_add_row.router_add_to.selected_index == 3, "and the pick kept")
		-- the search: case-insensitive substring; the text and the filter survive a free-count broadcast
		change({ entry("RT9 Far", "gridworld_2_0", 1) })
		now.router_search_row.router_search.text = "FAR"
		panel.show(player, true) -- on_gui_text_changed
		ctx.expect(#grid(now).children == 6 and grid(now).children[4].caption == "RT9 Far", "the search lists only the match")
		now = change({ entry("RT9 Far", "gridworld_2_0", 0), entry("RT9 B", "gridworld_1_0", 4) })
		ctx.expect(now.router_search_row.router_search.text == "FAR" and #grid(now).children == 6 and grid(now).children[5].caption == "0",
			"the broadcast keeps the text and the filter")
		now.router_search_row.router_search.text = ""
		panel.show(player, true)
		ctx.expect(#grid(now).children == 12, "an empty search lists all: " .. #grid(now).children)
		ctx.expect(now.router_search_row.children[1].caption == "Search", "the search box has its label")
		-- Ctrl+F: the open panel's search box takes focus; with no panel, nothing happens
		panel.focus(player)
		local box = now.router_search_row.router_search
		ctx.expect(box.focused and box.selected, "focus focuses the search box and selects its text")
		panel.close(player)
		ctx.expect(pcall(panel.focus, player) and pcall(panel.refresh, player), "no panel: focus and refresh do nothing")
		local cin = prototypes.custom_input["ue-focus-search"]
		ctx.expect(cin ~= nil and cin.linked_game_control == "focus-search", "the ue-focus-search prototype follows focus-search")
		-- refresh: the drop-down follows the train's interrupts, keeping the choice by name
		local function it(name) return { name = name, conditions = wait, targets = {} } end
		local sched = loco.train.get_schedule()
		panel.show(player)
		local drop = player.gui.screen.router_stations.router_add_row.router_add_to
		drop.selected_index = 3 -- "RT9 I2"
		sched.set_interrupts{ it("RT9 I2"), it("RT9 I1"), it("RT9 I3") }
		panel.refresh(player)
		ctx.expect(#drop.items == 4 and drop.items[4] == "Interrupt: RT9 I3", "a new interrupt is listed")
		ctx.expect(drop.selected_index == 2, "the chosen interrupt stays chosen by name after a reorder: " .. drop.selected_index)
		local items = drop.items
		panel.refresh(player)
		ctx.expect(drop.items == items, "unchanged names leave items untouched")
		sched.set_interrupts{ it("RT9 I1"), it("RT9 I3") }
		panel.refresh(player)
		ctx.expect(#drop.items == 3 and drop.selected_index == 1, "a removed chosen interrupt falls back to Schedule")
	end)
end)

-- The stop name picker (docs/superpowers/specs/2026-10-22-stop-name-picker-design.md): the panel beside an open train
-- stop's window lists this planet's names from every tile; "+" renames the stop; the stop panel follows broadcasts.
-- Tick 3560 alone; a lone stop at row 79500.
t.case("routing: the stop name picker lists this planet's names, searches, renames the open stop and follows broadcasts", function(ctx)
	ctx.at(3560, function()
		local stop = lone_stop(30000, 79500, "RTSN OWN", false)
		local here = stop.surface.name
		local player = { index = 1, gui = { screen = fake_gui(), relative = fake_gui() }, opened = stop, display_scale = 1.25,
			display_resolution = { width = 2560, height = 2088 } }
		local function entry(surface, name, tile)
			return { surface = surface, name = name, tiles = { tile }, free = 1 }
		end
		local function rows()
			local frame = player.gui.relative.router_stop_names
			local out = {}
			for i = 3, #frame.router_stop_pane.router_stop_grid.children, 2 do
				out[#out + 1] = frame.router_stop_pane.router_stop_grid.children[i].caption
			end
			return table.concat(out, ",")
		end
		deliver("ue.route.stations", { full = true, gone = {}, set = {
			entry(here, "RTSN B", "gridworld_1_0"), entry(here, "RTSN A", "gridworld_0_0"), entry("sp4v", "RTSN OTHER", "t1") } })
		panel.show_stop(player)
		local frame = player.gui.relative.router_stop_names
		ctx.expect(frame and frame.anchor.gui == defines.relative_gui_type.train_stop_gui
			and frame.anchor.position == defines.relative_gui_position.left, "the frame is anchored left of the stop window")
		ctx.expect(rows() == "RTSN A,RTSN B", "this surface's names in order, not the other's: " .. rows())
		local kids = frame.router_stop_pane.router_stop_grid.children
		ctx.expect(kids[1].caption == "Station [img=info]" and kids[2].type == "empty-widget" and kids[3].tooltip == "On tiles: 0,0"
			and kids[4].sprite == "utility/rename_icon" and kids[4].tooltip[3] == "RTSN A" and kids[4].tags.router == "rename"
			and kids[4].tags.name == "RTSN A", "header, then a name and its pencil per row")
		frame.router_stop_search_row.router_stop_search.text = "b"
		panel.show_stop(player, true) -- on_gui_text_changed
		ctx.expect(rows() == "RTSN B", "the search narrows the rows: " .. rows())
		panel.rename(player, frame.router_stop_pane.router_stop_grid.children[4].tags)
		ctx.expect(stop.backer_name == "RTSN B", "+ renames the open stop: " .. stop.backer_name)
		deliver("ue.route.stations", { set = { entry(here, "RTSN BB", "gridworld_2_0") }, gone = {} })
		panel.show_stop(player, true) -- the stations handler's redraw
		ctx.expect(player.gui.relative.router_stop_names == frame and rows() == "RTSN B,RTSN BB"
			and frame.router_stop_search_row.router_stop_search.text == "b", "the new name appears and the search text stays: " .. rows())
		stop.destroy()
		ctx.expect(pcall(panel.rename, player, { router = "rename", name = "RTSN A" }), "no stop: the click does nothing")
		ctx.expect(pcall(panel.show_stop, player, true) and player.gui.relative.router_stop_names == nil, "no stop: the panel is gone")
	end)
end)

-- The edge-stop migration (§5.4, §11.4): a prototype-era tile, rebuilt by hand. A plain train-stop named "<edge> <pos>"
-- stands where the ground box's edge stop stood (local (col + 5, -23), facing out; train_core's old STOP_DX, STOP_Y) and
-- is the endpoint's data.stop; one train has a permanent record and an interrupt target naming it; another has a routed
-- prototype route whose hop is a station record naming it. A resync with strip set removes all of it, once, before
-- routing is live again; the unrouted route is asked for again.
t.case("routing: the strip removes edge stops, the records and interrupt targets naming them, and prototype station hops (§5.4)",
	function(ctx)
		local id = "rt-strip"
		rig(ctx, 1580, id, 67400, { conn("t2", "ab", 24), conn("t3", "ab", 44) }, { t2 = { rails = 60 }, t3 = { rails = 60 } })
		ctx.at(1620, function()
			local ep = seams.endpoint(id, "t2")
			local x, y = ue_train.world(ep, ue_train.cx(ep) + 2, -23)
			local stop = assert(game.get_surface("sp3b").create_entity{ name = "train-stop", position = { x, y },
				direction = ue.geometry.dir_to_world(ep.frame, 0), force = "player" }, "the old edge stop's spot")
			local name = ep.edge .. " " .. ue.geometry.col(ep.me, ep.frame.length, ep.col, ep.width)
			stop.backer_name = name
			ep.data.stop = stop
			local a = game.get_entity_by_unit_number(seams.add(id, "t3", { layout = "L", at = 30 })).train
			local sa = a.get_schedule()
			sa.set_records{ { station = name }, { station = "RTS OTHER" } }
			sa.set_interrupts{ { name = "RTS I", conditions = { { type = "time", ticks = 600 } },
				targets = { { station = name }, { station = "RTS KEEP" } } } }
			local b = game.get_entity_by_unit_number(seams.add(id, "t2", { layout = "L", at = 30 })).train
			b.get_schedule().set_records{ { station = name, temporary = true }, { station = "RTS FAR" } }
			local r = routes.register(b, "rts.1", "RTS FAR", { { edge = id, cid = "t2" } })
			r.hop, r.unrouted = { edge = id, cid = "t2", station = name }, false
			storage.universal_edges.routing.strip = true
			deliver("ue.route.resync", { reservations = {} })
			ctx.expect(not stop.valid and ep.data.stop == nil, "the stop is gone, and data.stop with it")
			ctx.expect(names(a) == "RTS OTHER", "the permanent record naming it is gone: " .. names(a))
			local targets = {}
			for _, g in ipairs(a.get_schedule().get_interrupt(1).targets) do
				targets[#targets + 1] = g.station
			end
			ctx.expect(table.concat(targets, ",") == "RTS KEEP", "the interrupt target naming it is gone: " .. table.concat(targets, ","))
			ctx.expect(names(b) == "RTS FAR" and r.hop == nil and r.unrouted, "the station hop is gone, its route unrouted")
			local lines = traced("ue.routing", "stripped")
			ctx.expect(#lines == 1 and lines[1].stops == 1 and lines[1].records == 2 and lines[1].targets == 1
				and lines[1].routes == 1, "one ue.routing stripped line: " .. helpers.table_to_json(lines))
			local s = storage.universal_edges.routing
			ctx.expect(s.strip == false and s.live, "stripped once, then live")
		end)
		-- the unrouted route asks again under its own trace (the sweep's quiet retry here; Task 7's check() sooner)
		ctx.expect_ipc("universal_edges:out", '"dest":"RTS FAR"')
	end)

-- D17 (§7.7), on lone stops at x 30000 (rows 67800-68600), ticks 2000-2780: no resync is delivered after 1640, so the
-- registry and the walks run undisturbed. A row's arrival is read from the registry (entry.row is the row last sent):
-- the walks send from on_tick, which a step can't see.
t.case("routing: D17 — a stop built, renamed or removed is sent at once; a circuit-driven limit within 70 ticks", function(ctx)
	local stop, comb, unit, bound, seen
	ctx.at(2000, function()
		stop = lone_stop(30000, 67800, "RTD17 CIRCUIT", false)
		comb = circuit_limit(stop, 30006, 67800, 3)
		unit = stop.unit_number
		script.raise_script_built{ entity = stop }
		ctx.expect(#queued("ue.route.report", function(p) return p.stations and p.stations[1].unit == unit end) == 1,
			"a stop built is sent at once")
		ctx.expect(storage.universal_edges.routing.fast[unit] ~= nil, "wired for its limit: in the fast tier from its build (U2)")
		stop.backer_name = "RTD17 RENAMED"
		ctx.expect(#queued("ue.route.report", function(p)
			return p.stations and p.stations[1].unit == unit and p.stations[1].name == "RTD17 RENAMED" end) == 1,
			"a rename is sent at once (Review Focus 4)")
		local gone = lone_stop(30010, 67800, "RTD17 GONE", true)
		local gu = gone.unit_number
		gone.destroy{ raise_destroy = true }
		ctx.expect(#queued("ue.route.report", function(p) return p.stops_gone and p.stops_gone[1] == gu end) == 1,
			"a stop removed is sent at once, in stops_gone")
	end)
	ctx.at(2010, function()
		ctx.expect(stop.trains_limit == 3, "the combinator drives the limit: " .. stop.trains_limit)
		comb.get_control_behavior().get_section(1).set_slot(1,
			{ value = { type = "virtual", name = "signal-L", quality = "normal" }, min = 5 })
		local count = 0
		for _ in pairs(storage.universal_edges.routing.fast) do
			count = count + 1
		end
		bound = 2010 + 70 + math.ceil(count / 2) -- plan ruling 12: the fast walk's own length, at 2 a tick
	end)
	for k = 2011, 2200 do
		ctx.at(k, function()
			local entry = storage.universal_edges.routing.stops[unit]
			if not seen and entry and entry.row and entry.row.limit == 5 then
				seen = k
			end
		end)
	end
	ctx.at(2201, function()
		ctx.expect(seen ~= nil and seen <= bound, "the circuit-driven limit reached its row by " .. bound .. ": " .. tostring(seen))
		log("routing D17: a circuit limit took " .. tostring(seen and seen - 2010) .. " ticks")
	end)
end)

t.case("routing: D17 — a limit set by hand reaches its row within the 10 s walk", function(ctx)
	local stop, unit, bound, seen
	ctx.at(2000, function()
		stop = lone_stop(30000, 68200, "RTD17 MANUAL", true)
		unit = stop.unit_number
	end)
	ctx.at(2010, function()
		stop.trains_limit = 2
		local count = 0
		for _ in pairs(storage.universal_edges.routing.stops) do
			count = count + 1
		end
		bound = 2010 + 610 + math.ceil(count / 2) -- plan ruling 12
	end)
	for k = 2011, 2780 do
		ctx.at(k, function()
			local entry = storage.universal_edges.routing.stops[unit]
			if not seen and entry and entry.row and entry.row.limit == 2 then
				seen = k
			end
		end)
	end
	ctx.at(2781, function()
		ctx.expect(seen ~= nil and seen <= bound, "the limit reached its row by " .. bound .. ": " .. tostring(seen))
		log("routing D17: a manual limit took " .. tostring(seen and seen - 2010) .. " ticks")
	end)
end)

t.case("routing: D17 — a stop wired after its build joins the fast tier at its next slow visit (U2)", function(ctx)
	local stop, unit, bound, seen
	ctx.at(2000, function()
		stop = lone_stop(30000, 68600, "RTD17 LATER", true)
		unit = stop.unit_number
		ctx.expect(storage.universal_edges.routing.fast[unit] == nil, "unwired: the slow tier only")
	end)
	ctx.at(2010, function()
		circuit_limit(stop, 30006, 68600, 4)
		local count = 0
		for _ in pairs(storage.universal_edges.routing.stops) do
			count = count + 1
		end
		bound = 2010 + 610 + math.ceil(count / 2)
	end)
	for k = 2011, 2780 do
		ctx.at(k, function()
			if not seen and storage.universal_edges.routing.fast[unit] then
				seen = k
			end
		end)
	end
	ctx.at(2781, function()
		ctx.expect(seen ~= nil and seen <= bound, "in the fast tier by " .. bound .. ": " .. tostring(seen))
	end)
end)

-- §7.9, §9: the station list in parts, by (surface, name) (R35). Ticks 3700-3725: after the panel cases above (3540,
-- 3640). "sp4v" here is only a key: no surface of that name is needed for the list.
t.case("routing: the station list in parts — upserts by surface and name, removals, a full list replacing, malformed entries skipped",
	function(ctx)
		ctx.at(3700, function()
			local r = storage.universal_edges.routing
			deliver("ue.route.stations", { full = true, set = { { surface = "sp3b", name = "RTP A", tiles = { "t1" }, free = 1 },
				{ surface = "sp3b", name = "RTP B", tiles = { "t2" }, free = -1 },
				{ surface = "sp4v", name = "RTP A", tiles = { "t1" }, free = 3 } }, gone = {} })
			local sp3b, sp4v = r.list.sp3b, r.list.sp4v
			ctx.expect(sp3b["RTP A"] ~= nil and sp3b["RTP B"] ~= nil and sp3b["RT8 FAR"] == nil, "a full list replaces")
			ctx.expect(sp4v["RTP A"].free == 3 and sp3b["RTP A"].free == 1, "one entry per (surface, name)")
			deliver("ue.route.stations", { set = { { surface = "sp3b", name = "RTP A", tiles = { "t1", "t3" }, free = 2 },
				{ surface = "sp3b", name = 5, tiles = {}, free = 1 }, { name = "RTP NOSURFACE", tiles = {}, free = 1 },
				{ surface = "sp3b", name = "RTP BAD", tiles = { 7 }, free = 1 }, { surface = "sp3b", name = "RTP NOFREE", tiles = {} } },
				gone = { { surface = "sp3b", name = "RTP B" }, { surface = "sp4v", name = "RTP A" }, "RTP A", 9 } })
			ctx.expect(sp3b["RTP A"].free == 2 and #sp3b["RTP A"].tiles == 2, "an upsert by surface and name")
			ctx.expect(sp3b["RTP B"] == nil and sp4v["RTP A"] == nil, "gone removes only its own (surface, name)")
			ctx.expect(sp3b["RTP BAD"] == nil and sp3b["RTP NOFREE"] == nil and sp3b["RTP NOSURFACE"] == nil,
				"malformed entries are skipped, a gone entry that is a bare name too")
		end)
	end)

t.case("routing: the panel picks the interrupt by name after a reorder (R16, U14), and goes with the train window", function(ctx)
	local id = "rt-panel-name"
	rig(ctx, 3660, id, 69000, { conn("t2", "ab", 24) }, { t2 = { rails = 40 } })
	ctx.at(3710, function()
		local wait = { { type = "time", ticks = 60 } }
		local loco = game.get_entity_by_unit_number(seams.add(id, "t2", { layout = "L", at = 30, manual = true,
			interrupts = { { name = "RTP I1", conditions = wait, targets = {} }, { name = "RTP I2", conditions = wait, targets = {} } } }))
		local tr = loco.train
		deliver("ue.route.stations", { full = true, set = { { surface = loco.surface.name, name = "RTP FAR", tiles = { "t9" }, free = 1 } },
			gone = {} })
		local player = { index = 1, gui = { screen = fake_gui(), relative = fake_gui() }, opened = loco, display_scale = 1.25,
				display_resolution = { width = 2560, height = 2088 } }
		player.gui.relative.add{ type = "frame", name = "router_stations" } -- an older save's relative frame
		local leftover = player.gui.relative.router_stations
		panel.show(player)
		ctx.expect(not leftover.valid and player.gui.relative.router_stations == nil, "a leftover relative frame is destroyed")
		local frame = player.gui.screen.router_stations
		ctx.expect(frame.location.x == 575 and frame.location.y == 55,
			"the default spot at scale 1.25: " .. frame.location.x .. "," .. frame.location.y)
		frame.location = { x = 1000, y = 500 }
		panel.moved(player, frame)
		local at = storage.universal_edges.routing.panel_at[1]
		ctx.expect(at.x == 800 and at.y == 400, "a move is stored scale-free: " .. at.x .. "," .. at.y)
		player.display_scale = 2.0
		panel.rescale(player)
		ctx.expect(frame.location.x == 1600 and frame.location.y == 800, "a scale change places it again")
		local pick = frame.router_add_row.router_add_to
		ctx.expect(pick.items[1] == "Schedule" and pick.items[2] == "Interrupt: RTP I1" and pick.items[3] == "Interrupt: RTP I2",
			"the drop-down: Schedule, then each interrupt")
		pick.selected_index = 1
		panel.click(player, { router = "add", name = "RTP FAR" })
		local recs = tr.get_schedule().get_records()
		ctx.expect(recs[#recs].station == "RTP FAR", "Add to = Schedule adds a record")
		pick.selected_index = 3 -- "RTP I2"
		local sched = tr.get_schedule()
		sched.set_interrupts{ { name = "RTP I2", conditions = wait, targets = {} }, { name = "RTP I1", conditions = wait, targets = {} } }
		panel.click(player, { router = "add", name = "RTP FAR" })
		local i2, i1 = sched.get_interrupt(1), sched.get_interrupt(2)
		ctx.expect(i2.name == "RTP I2" and #(i2.targets or {}) == 1 and #(i1.targets or {}) == 0,
			"the picked interrupt, found by name after the reorder")
		sched.set_interrupts{ { name = "RTP DUP", conditions = wait, targets = {} }, { name = "RTP DUP", conditions = wait, targets = {} } }
		local kept = #sched.get_interrupts()
		log("routing U14: interrupts kept with one name twice: " .. kept)
		panel.add_target(tr, "RTP DUP", "RTP FAR")
		ctx.expect(#(sched.get_interrupt(1).targets or {}) == 1 and (kept < 2 or #(sched.get_interrupt(2).targets or {}) == 0),
			"U14: two of one name: the first gets the target")
		panel.close(player)
		ctx.expect(player.gui.screen.router_stations == nil and not frame.valid, "closing the window takes the panel")
		storage.universal_edges.routing.panel_at[1] = nil -- later cases' players get the default spot
	end)
end)

t.case("routing: a task that raises logs ue.routing failed once in 3600 ticks, and the tick goes on (R7)", function(ctx)
	ctx.at(3725, function()
		local r = storage.universal_edges.routing
		r.errs["ue.routing.costs"] = nil
		local goals = r.goals
		r.goals = { { surface = "sp3b", key = "rt-bogus" } } -- one goal, so the walk reaches `start.surface` whatever the save holds
		tables.walk_safe("c:rt-bogus", false) -- a start that isn't a table: the walk raises
		tables.walk_safe("c:rt-bogus", false)
		r.goals = goals
		local lines = traced("ue.routing", "failed")
		ctx.expect(#lines == 1 and lines[1].task == "ue.routing.costs" and lines[1].level == "error", "logged once: " .. #lines)
		r.errs["ue.routing.costs"] = nil
	end)
end)

-- The surfaces amendment (R31-R33, R35, R36), ticks 3740-3780: one rig on "sp3b" and the same on a second lab surface,
-- "sp4v" (plan ruling 18), row 73800 of each. Each t1 track has a stop named RTPL SAME. base.path is wrapped for one
-- step, so the case sees every goal each search is given. The list delivered at 3780 replaces every other case's: it
-- comes after their last (3710).
t.case("routing: two planets — rows carry their surface, no search crosses planets, the list and the panel by planet",
	function(ctx)
		local list = { conn("t1", "ba", 4), conn("t2", "ab", 24) }
		local tracks = { t1 = { rails = 60, station = "RTPL SAME" }, t2 = { rails = 40 } }
		rig(ctx, 3740, "rt-pl-n", 73800, list, tracks)
		rig(ctx, 3740, "rt-pl-v", 73800, list, tracks, "sp4v")
		ctx.at(3780, function()
			local r = storage.universal_edges.routing
			local function on(surface)
				return game.train_manager.get_train_stops{ station_name = "RTPL SAME", surface = surface }[1]
			end
			local stop_n, stop_v = on("sp3b"), on("sp4v")
			for _, stop in ipairs({ stop_n, stop_v }) do
				stops.add(stop) -- the rigs' stops were made without events
				local sent = queued("ue.route.report", function(p) return p.stations and p.stations[1].unit == stop.unit_number end)[1]
				ctx.expect(sent and sent.stations[1].surface == stop.surface.name
					and r.stops[stop.unit_number].surface == stop.surface.name,
					"R31: the row and the registry carry the stop's surface, " .. stop.surface.name)
			end
			local real, crossed = base.path, 0
			base.path = function(args)
				local here = (args.train and args.train.front_stock or args.starts[1].rail).surface_index
				for _, g in ipairs(args.goals) do
					local e = g.object_name == "LuaRailEnd" and g.rail or g
					crossed = crossed + (e.surface_index == here and 0 or 1)
				end
				return real(args)
			end
			tables.pass() -- the new stops made the table dirty: starts and goals re-made, each with its surface
			local kn, kv = "c:rt-pl-n/t1", "c:rt-pl-v/t1"
			tables.walk(kn, r.starts[kn])
			tables.walk(kv, r.starts[kv])
			local tr = game.get_entity_by_unit_number(seams.add("rt-pl-v", "t2", { layout = "L", at = 30 })).train
			routes.request(tr, routes.register(tr, "rtpl.1", "RTPL SAME", {}), nil, "train")
			base.path = real
			ctx.expect(crossed == 0, "R33: no search was given a goal on another surface: " .. crossed)
			local reach = {}
			for _, c in ipairs(reported("costs")) do
				reach[c[1] .. ">" .. c[2]] = true
			end
			ctx.expect(reach[kn .. ">s:" .. stop_n.unit_number] and reach[kv .. ">s:" .. stop_v.unit_number]
				and not reach[kn .. ">s:" .. stop_v.unit_number] and not reach[kv .. ">s:" .. stop_n.unit_number],
				"each start reaches its own planet's RTPL SAME, and only that one")
			local q = queued("ue.route.request", function(p) return p.trace == "rtpl.1" end)[1]
			local line = traced("ue.route", "requested", "rtpl.1")[1]
			ctx.expect(q and q.surface == "sp4v" and line and line.surface == "sp4v",
				"R32: the request and its requested line carry the train's surface")
			for _, f in ipairs(q and q.firsts or {}) do
				ctx.expect(f[1] ~= "s:" .. stop_n.unit_number and string.find(f[1], "rt-pl-n", 1, true) == nil,
					"firsts only from the train's surface: " .. f[1])
			end
			deliver("ue.route.stations", { full = true, gone = {}, set = {
				{ surface = "sp3b", name = "RTPL SAME", tiles = { "t1" }, free = 1 },
				{ surface = "sp4v", name = "RTPL SAME", tiles = { "t1" }, free = 2 },
				{ surface = "sp3b", name = "RTPL A", tiles = { "t2" }, free = 1 } } })
			ctx.expect(r.list.sp3b["RTPL SAME"].free == 1 and r.list.sp4v["RTPL SAME"].free == 2, "R35: one entry per (surface, name)")
			local player = { index = 1, gui = { screen = fake_gui(), relative = fake_gui() }, opened = tr.front_stock, display_scale = 1.25,
				display_resolution = { width = 2560, height = 2088 } }
			panel.show(player)
			local kids = player.gui.screen.router_stations.router_pane.router_grid.children
			local rows = {}
			for i = 4, #kids, 3 do
				rows[#rows + 1] = kids[i].caption
			end
			ctx.expect(table.concat(rows, ",") == "RTPL SAME",
				"R36: only the train's planet's rows, by name: " .. table.concat(rows, ","))
			ctx.expect(kids[5].caption == "2", "and the row is the train's planet's own: free " .. kids[5].caption)
			seams.clear("rt-pl-v", "t2")
			routes.forget("rtpl.1")
		end)
	end)

-- §8.2, §11.4 "the search cap": 60 trains put into no_path in one tick, the table dirty, 20 routes due a retry. For 600
-- ticks no tick makes more than 9 path searches, and every train gets its route. Ticks 860-1500 are this case's alone,
-- and its resync at 900 is the save's first: routing is live from here on. U8: the sweep walks active while checks add
-- routes to it. Row 77400 (the 320-rail tracks run along x, clear of the D22 cases' rows).
t.case("routing: at most 9 path searches a tick, however many trains wait (§8.2)", function(ctx)
	local id = "rt-cap"
	rig(ctx, 860, id, 77400, { conn("c1", "ab", 4), conn("c2", "ab", 24) }, { c1 = { rails = 320 }, c2 = { rails = 320 } })
	local units = {}
	ctx.at(900, function()
		-- the save's first resync: routing is live from here, so UE's own train cases (to tick 2100) run partly with it
		deliver("ue.route.resync", { reservations = {} })
		local r = storage.universal_edges.routing
		for i = 1, 30 do
			for _, cid in ipairs({ "c1", "c2" }) do
				local tr = game.get_entity_by_unit_number(seams.add(id, cid, { layout = "L", at = 20 * i, next = "RTCAP FAR" })).train
				tr.get_schedule().remove_record{ schedule_index = 1 } -- only the remote destination: no_path
				tr.get_schedule().go_to_station(1)
				units[#units + 1] = tr.carriages[1].unit_number
				if #units <= 20 then
					routes.register(tr, "rtcap." .. #units, "RTCAP FAR", {}) -- unrouted: due the sweep's quiet retry
				end
			end
		end
		r.dirty = true
		r.search.max, r.errs = 0, {}
	end)
	for k = 901, 1499 do
		ctx.at(k, function()
			local c = storage.universal_edges.routing.search
			ctx.expect(c.tick ~= k or c.n <= 9, "at most 9 searches in tick " .. k .. ": " .. c.n)
		end)
	end
	layouts.wait(t, ctx, 901, 1500, function()
		for _, u in ipairs(units) do
			local e = game.get_entity_by_unit_number(u)
			if not (e and routes.trace_of(e.train)) then
				return false
			end
		end
		return #units == 60
	end, function(k)
		local r = storage.universal_edges.routing
		ctx.expect(k ~= nil, "every train checked and routed by tick 1500")
		ctx.expect(r.search.max >= 1, "a search ran: " .. r.search.max)
		ctx.expect(r.search.max <= 9, "search.max over the case: " .. r.search.max)
		ctx.expect(next(r.errs) == nil, "no routing task failed")
		for _, u in ipairs(units) do
			local e = game.get_entity_by_unit_number(u)
			if e then
				e.destroy()
			end
		end
	end)
end)

-- D22-1a (§11.4): a train reaches a temporary record placed just before its hop; vanilla deletes it one tick later
-- (spike 5). A re-route reply on the deletion tick (lag 0) or the tick after (lag 1) leaves exactly one hop.
local function d22_deletion(id, y, lag)
	t.case("routing: D22-1a — a reply " .. (lag == 0 and "on" or "one tick after") .. " vanilla's deletion of the record "
		.. "before the hop leaves one hop, by identity", function(ctx)
		rig(ctx, 1700, id, y, { conn("t2", "ab", 24) }, { t2 = { rails = 60 } })
		local unit, trace, gone_at = nil, id .. ".1", nil
		local function train()
			return game.get_entity_by_unit_number(unit).train
		end
		ctx.at(1702, function()
			seams.partner(id, "t2", { ready = false }) -- no capture: the case is about the schedule
		end)
		ctx.at(1740, function()
			outward_stop(id, "t2", 31, "RTD TMP " .. id)
			unit = seams.add(id, "t2", { layout = "L", at = 50, next = "RTD DEST" })
			local rail = ue.trains.get(id, "t2").end_rail
			local sched = train().get_schedule()
			sched.set_records{ { station = "RTD TMP " .. id, temporary = true }, { rail = rail, temporary = true }, { station = "RTD DEST" } }
			sched.go_to_station(1)
			routed(train(), trace, "RTD DEST", id, "t2")
		end)
		for k = 1741, 1900 do
			ctx.at(k, function()
				if not gone_at and not string.find(names(train()), "RTD TMP", 1, true) then
					gone_at = k
				end
				if gone_at and k == gone_at + lag then
					deliver("ue.route.reply", { trace = trace, ok = true, hops = { { edge = id, cid = "t2" } } })
					one_hop(ctx, train(), ue.trains.get(id, "t2").end_rail, "RTD DEST", "lag " .. lag)
					ctx.expect(storage.universal_edges.routing.active[trace] ~= nil, "the route goes on")
				end
			end)
		end
		ctx.at(1901, function()
			ctx.expect(gone_at ~= nil, "the train reached RTD TMP and vanilla deleted its record")
		end)
	end)
end
d22_deletion("rt-d22-a0", 70200, 0)
d22_deletion("rt-d22-a1", 70600, 1)

-- D22-1b (§11.4): the hop record itself is reached (the test opens the hold); vanilla deletes it, the train goes no_path
-- toward its remote destination, check() re-routes mid-tile, and the reply puts the hop back by identity.
t.case("routing: D22-1b — the hop record itself reached: the reply re-inserts it by identity, and current names it", function(ctx)
	local id, trace = "rt-d22-b", "rt-d22-b.1"
	rig(ctx, 1700, id, 71000, { conn("t2", "ab", 24) }, { t2 = { rails = 60 } })
	local unit, gone_at, done
	local function train()
		return game.get_entity_by_unit_number(unit).train
	end
	ctx.at(1702, function()
		seams.partner(id, "t2", { ready = false })
	end)
	ctx.at(1740, function()
		unit = seams.add(id, "t2", { layout = "L", at = 20, next = "RTD DEST B" })
		routed(train(), trace, "RTD DEST B", id, "t2")
		ue.trains.get(id, "t2").hold.get_or_create_control_behavior().close_signal = false -- the test opens the hold
	end)
	for k = 1741, 2000 do
		ctx.at(k, function()
			if done then
				return
			end
			if not gone_at and #hop_rails(train()) == 0 then
				gone_at = k
			end
			if gone_at and k == gone_at + 5 then
				done = k
				local route = storage.universal_edges.routing.active[trace]
				ctx.expect(route and route.hop == nil and route.unrouted, "check() re-routed mid-tile: the hop was gone, it asked")
				deliver("ue.route.reply", { trace = trace, ok = true, hops = { { edge = id, cid = "t2" } } })
				one_hop(ctx, train(), ue.trains.get(id, "t2").end_rail, "RTD DEST B", "reached")
				ue.trains.get(id, "t2").hold.get_or_create_control_behavior().close_signal = true
			end
		end)
	end
	ctx.at(2001, function()
		ctx.expect(done ~= nil, "the train reached its hop record and vanilla deleted it")
	end)
end)

-- D22-2 (§11.4): the player edits a routed train's schedule, then a re-route reply arrives (to t3's box); the hop is
-- replaced by identity wherever the edit left it.
local function d22_edit(id, y, label, edit)
	t.case("routing: D22-2 — " .. label .. ", then a reply: one hop, the reply's, by identity", function(ctx)
		rig(ctx, 2100, id, y, { conn("t2", "ab", 24), conn("t3", "ab", 44) }, { t2 = { rails = 60 }, t3 = { rails = 60 } })
		ctx.at(2102, function()
			seams.partner(id, "t2", { ready = false })
			seams.partner(id, "t3", { ready = false })
		end)
		ctx.at(2140, function()
			local tr = game.get_entity_by_unit_number(seams.add(id, "t2", { layout = "L", at = 40, next = "RTD2 DEST" })).train
			routed(tr, id .. ".1", "RTD2 DEST", id, "t2")
			edit(tr.get_schedule(), ue.trains.get(id, "t2").end_rail)
			deliver("ue.route.reply", { trace = id .. ".1", ok = true, hops = { { edge = id, cid = "t3" } } })
			one_hop(ctx, tr, ue.trains.get(id, "t3").end_rail, "RTD2 DEST", label)
		end)
	end)
end
d22_edit("rt-d22-before", 71400, "a record added before the hop", function(sched)
	sched.add_record{ station = "RTD2 EXTRA", index = { schedule_index = 1 } }
end)
d22_edit("rt-d22-after", 71800, "a record added after the hop", function(sched)
	sched.add_record{ station = "RTD2 EXTRA", index = { schedule_index = 2 } }
end)
d22_edit("rt-d22-moved", 72200, "the hop moved behind the destination", function(sched, rail)
	sched.remove_record{ schedule_index = 1 }
	sched.add_record{ rail = rail, temporary = true }
end)

-- D22-3a (§11.4 item 3a, owner decision B): the train waits at a stop on its own tile with low fuel, and its route's
-- reply arrives there: the hop is due during the wait, so it is held on the route and the schedule stays as it is (§6's
-- amendment). At the departure the fuel interrupt fires (2.1.20 checks interrupts only there, and only with a
-- non-temporary next record: spike 15), and the hop goes in behind the interrupt's record. The train refuels at the
-- local RTD3 FUEL, takes its hop and crosses with its route: no lost line, one hop by rail identity ahead of the
-- destination, and the trace in the body.
t.case("routing: D22-3a — a fuel interrupt to a local stop between the hop and the box: refuels, crosses with its route", function(ctx)
	local id, trace = "rt-d22-fuel", "rt-d22-fuel.1"
	rig(ctx, 2200, id, 72600, { conn("t2", "ab", 24) }, { t2 = { rails = 60 } })
	local unit, started, left, gone, refuelled, resumed, crossed
	local function train()
		local e = game.get_entity_by_unit_number(unit)
		return e and e.valid and e.train
	end
	local function waits(tr)
		return tr.state == defines.train_state.wait_station and tr.station and tr.station.backer_name == "RTD3 DEPART"
	end
	ctx.at(2240, function()
		outward_stop(id, "t2", 31, "RTD3 FUEL")
		outward_stop(id, "t2", 37, "RTD3 DEPART")
		unit = seams.add(id, "t2", { layout = "L", at = 50, next = "RTD3 DEST",
			interrupts = { fuel_interrupt("rtd3 fuel", "RTD3 FUEL", 60) } })
		local sched = train().get_schedule()
		sched.remove_record{ schedule_index = 1 } -- seams.add's own edge record: only the remote destination is left
		sched.add_record{ station = "RTD3 DEPART", wait_conditions = { { type = "time", ticks = 40 } },
			index = { schedule_index = 1 } }
		sched.go_to_station(1)
	end)
	for k = 2241, 2700 do
		ctx.at(k, function()
			local tr = train()
			if crossed or not tr then
				return
			end
			local route = storage.universal_edges.routing.active[trace]
			if not started then
				if waits(tr) then
					started = k -- at the stop: fuel low, the route live, and its reply arrives during the wait
					local fuel = tr.locomotives.front_movers[1].get_fuel_inventory()
					fuel.clear()
					fuel.insert{ name = "coal", count = 1 }
					routes.register(tr, trace, "RTD3 DEST", {})
					deliver("ue.route.reply", { trace = trace, ok = true, hops = { { edge = id, cid = "t2" } } })
					route = storage.universal_edges.routing.active[trace]
					ctx.expect(route and route.held and route.hop == nil, "B: the reply at the stop holds the hop on the route")
				end
				return
			end
			gone = gone or (route == nil and k or nil)
			local rail = ue.trains.get(id, "t2").end_rail
			if not left then
				if waits(tr) then
					ctx.expect(names(tr) == "RTD3 DEPART,RTD3 DEST", "B: the schedule is unchanged during the wait: " .. names(tr))
					return
				end
				left = k
				local sched = tr.get_schedule()
				local cur = sched.get_record{ schedule_index = sched.current }
				ctx.expect(cur and cur.created_by_interrupt and cur.station == "RTD3 FUEL",
					"the fuel interrupt fired at the departure: its record is current: " .. names(tr))
				ctx.expect(names(tr) == "RTD3 DEPART,RTD3 FUEL*,<rail>*,RTD3 DEST" and hop_rails(tr)[1] == rail.unit_number,
					"B: the hop went in behind the interrupt's record, by identity: " .. names(tr))
			end
			if not refuelled and tr.station and tr.station.backer_name == "RTD3 FUEL" then
				refuelled = k
				tr.locomotives.front_movers[1].get_fuel_inventory().insert{ name = "coal", count = 50 }
			end
			if refuelled and not resumed and not (tr.station and tr.station.backer_name == "RTD3 FUEL") then
				resumed = k
				one_hop(ctx, tr, rail, "RTD3 DEST", "after the refuel") -- D22's invariant, the hop now current
			end
			local ep = seams.endpoint(id, "t2")
			if ep.data.held then
				local body = helpers.json_to_table(helpers.decode_string(ep.tx.ab.inflight.body))
				ctx.expect(body.ext and body.ext.router and body.ext.router.trace == trace, "the route rides the crossing")
				local seq = ep.tx.ab.inflight.seq
				seams.lane(id, { k = "u.reply", cid = "t2", dir = "ab", seq = seq, outcome = "credited", w = seq })
				crossed = k
			end
		end)
	end
	ctx.at(2701, function()
		ctx.expect(started ~= nil, "the train reached its own-tile stop, and the route's reply arrived there")
		ctx.expect(left ~= nil, "the train left the stop")
		ctx.expect(gone == nil, "the route stayed from the reply to the crossing: no lost (gone at " .. tostring(gone) .. ")")
		ctx.expect(refuelled ~= nil and resumed ~= nil and crossed ~= nil and crossed > resumed,
			"refuelled at RTD3 FUEL, took its hop, then crossed: " .. tostring(refuelled) .. ", " .. tostring(crossed))
	end)
end)

-- D22-3b (§11.4 item 3b, owner decision B): as D22-3a, with the interrupt's target a remote station. The reply at the
-- stop is held; at the departure the interrupt fires and its record is current, so the train is off its leg: the
-- original route ends moved_on and the interrupt's own route asks. When the player clears the interrupt's record, that
-- route ends moved_on too, and the original destination is asked for again, under a new trace.
t.case("routing: D22-3b — an interrupt to a remote station: its own route, then the original destination asked again", function(ctx)
	local id, first = "rt-d22-far", "rt-d22-far.1"
	rig(ctx, 2200, id, 73000, { conn("t2", "ab", 24) }, { t2 = { rails = 60 } })
	local unit, started, fired, ended, second, again
	local function train()
		return game.get_entity_by_unit_number(unit).train
	end
	local function waits(tr)
		return tr.state == defines.train_state.wait_station and tr.station and tr.station.backer_name == "RTD3B DEPART"
	end
	ctx.at(2202, function()
		seams.partner(id, "t2", { ready = false })
	end)
	ctx.at(2240, function()
		outward_stop(id, "t2", 37, "RTD3B DEPART")
		unit = seams.add(id, "t2", { layout = "L", at = 50, next = "RTD3B DEST",
			interrupts = { fuel_interrupt("rtd3b far", "RTD3B FAR", 60) } })
		local sched = train().get_schedule()
		sched.remove_record{ schedule_index = 1 } -- seams.add's own edge record: only the remote destination is left
		sched.add_record{ station = "RTD3B DEPART", wait_conditions = { { type = "time", ticks = 40 } },
			index = { schedule_index = 1 } }
		sched.go_to_station(1)
	end)
	for k = 2241, 2700 do
		ctx.at(k, function()
			local s = storage.universal_edges.routing
			local tr = train()
			if not started then
				if waits(tr) then
					started = k -- at the stop: fuel low, the route live, and its reply arrives during the wait
					local fuel = tr.locomotives.front_movers[1].get_fuel_inventory()
					fuel.clear()
					fuel.insert{ name = "coal", count = 1 }
					routes.register(tr, first, "RTD3B DEST", {})
					deliver("ue.route.reply", { trace = first, ok = true, hops = { { edge = id, cid = "t2" } } })
					local route = s.active[first]
					ctx.expect(route and route.held and route.hop == nil, "B: the reply at the stop holds the hop on the route")
				end
				return
			end
			for _, rec in ipairs(tr.get_schedule().get_records() or {}) do
				fired = fired or (rec.created_by_interrupt and k or nil)
			end
			ended = ended or (s.active[first] == nil and k or nil)
			if not fired and waits(tr) then
				ctx.expect(names(tr) == "RTD3B DEPART,RTD3B DEST", "B: the schedule is unchanged during the wait: " .. names(tr))
			end
			local now = routes.trace_of(tr)
			local route = now and s.active[now]
			if not second and route and route.dest == "RTD3B FAR" then
				second = now
				ctx.expect(s.active[first] == nil and #hop_rails(tr) == 0,
					"the original route ended moved_on, no hop left: " .. names(tr))
				tr.locomotives.front_movers[1].get_fuel_inventory().insert{ name = "coal", count = 50 }
				local sched = tr.get_schedule()
				for i, rec in ipairs(sched.get_records()) do
					if rec.created_by_interrupt then
						sched.remove_record{ schedule_index = i } -- the player gives up on the interrupt
						break
					end
				end
				routes.visit(second, route) -- off its leg now: moved_on, and the train goes to the walker
			elseif second and not again and route and route.dest == "RTD3B DEST" and now ~= first then
				again = k
			end
		end)
	end
	ctx.at(2701, function()
		ctx.expect(started ~= nil, "the train reached its own-tile stop, and the route's reply arrived there")
		ctx.expect(fired ~= nil and ended ~= nil and ended >= fired, "the original route lived through the wait and ended "
			.. "only once the interrupt fired at the departure: fired " .. tostring(fired) .. ", ended " .. tostring(ended))
		ctx.expect(second ~= nil, "the remote interrupt fired at the departure and was routed as its own route")
		ctx.expect(storage.universal_edges.routing.active[second or ""] == nil, "the interrupt's route ended")
		ctx.expect(again ~= nil, "the original destination asked for again, under a new trace")
	end)
end)

-- Owner decision B (§6's amendment, spike 15): a route's reply arriving while its train waits at a stop leaves the
-- schedule as it is for the rest of the wait, the hop held on the route; the hop goes in by identity as the train
-- leaves, current names it, and the destination is still there. Row 77800, its own.
t.case("routing: B — a reply during a wait at a stop: the schedule unchanged in the wait, the hop in by identity at the departure",
	function(ctx)
		local id, trace = "rt-b-held", "rt-b-held.1"
		rig(ctx, 2200, id, 77800, { conn("t2", "ab", 24) }, { t2 = { rails = 60 } })
		local unit
		local function train()
			return game.get_entity_by_unit_number(unit).train
		end
		local function waits(tr)
			return tr.state == defines.train_state.wait_station and tr.station and tr.station.backer_name == "RTB STOP"
		end
		ctx.at(2202, function()
			seams.partner(id, "t2", { ready = false }) -- no capture: the case is about the schedule
		end)
		ctx.at(2240, function()
			outward_stop(id, "t2", 37, "RTB STOP")
			unit = seams.add(id, "t2", { layout = "L", at = 50, next = "RTB DEST" })
			local sched = train().get_schedule()
			sched.remove_record{ schedule_index = 1 } -- seams.add's own edge record: only the remote destination is left
			sched.add_record{ station = "RTB STOP", wait_conditions = { { type = "time", ticks = 40 } },
				index = { schedule_index = 1 } }
			sched.go_to_station(1)
		end)
		layouts.wait(t, ctx, 2241, 2380, function() return waits(train()) end, function(k)
			ctx.expect(k ~= nil, "the train reached RTB STOP and waits there")
			if not k then
				return
			end
			routes.register(train(), trace, "RTB DEST", {})
			deliver("ue.route.reply", { trace = trace, ok = true, hops = { { edge = id, cid = "t2" } } })
			local route = storage.universal_edges.routing.active[trace]
			ctx.expect(route and route.held and route.held.cid == "t2" and route.hop == nil and route.unrouted,
				"the hop is held on the route")
			ctx.expect(names(train()) == "RTB STOP,RTB DEST", "the reply changed nothing in the schedule: " .. names(train()))
			layouts.wait(t, ctx, k + 1, 2480, function()
				local tr = train()
				if not waits(tr) then
					return true
				end
				ctx.expect(names(tr) == "RTB STOP,RTB DEST", "the schedule is unchanged during the wait: " .. names(tr))
				return false
			end, function(left)
				ctx.expect(left ~= nil, "the train left the stop")
				if left then
					one_hop(ctx, train(), ue.trains.get(id, "t2").end_rail, "RTB DEST", "right after the departure")
					ctx.expect(storage.universal_edges.routing.active[trace] ~= nil, "the route goes on")
				end
			end)
		end)
	end)

-- Owner decision B, the dead box: the box goes while the hop is held, so the departure's put fails. No dead hop goes in,
-- and the route stays unrouted for the sweep's retry. Row 78200, its own.
t.case("routing: B — the box removed while the hop is held: the departure inserts no hop, the route stays unrouted",
	function(ctx)
		local id, trace = "rt-b-dead", "rt-b-dead.1"
		rig(ctx, 2500, id, 78200, { conn("t2", "ab", 24) }, { t2 = { rails = 60 } })
		local unit
		local function train()
			return game.get_entity_by_unit_number(unit).train
		end
		local function waits(tr)
			return tr.state == defines.train_state.wait_station and tr.station and tr.station.backer_name == "RTD STOP"
		end
		ctx.at(2502, function()
			seams.partner(id, "t2", { ready = false })
		end)
		ctx.at(2540, function()
			outward_stop(id, "t2", 37, "RTD STOP")
			unit = seams.add(id, "t2", { layout = "L", at = 50, next = "RTD DEST" })
			local sched = train().get_schedule()
			sched.remove_record{ schedule_index = 1 }
			sched.add_record{ station = "RTD STOP", wait_conditions = { { type = "time", ticks = 40 } },
				index = { schedule_index = 1 } }
			sched.go_to_station(1)
		end)
		layouts.wait(t, ctx, 2541, 2680, function() return waits(train()) end, function(k)
			ctx.expect(k ~= nil, "the train reached RTD STOP and waits there")
			if not k then
				return
			end
			routes.register(train(), trace, "RTD DEST", {})
			deliver("ue.route.reply", { trace = trace, ok = true, hops = { { edge = id, cid = "t2" } } })
			local route = storage.universal_edges.routing.active[trace]
			ctx.expect(route and route.held and route.unrouted, "held, and the route is unrouted while the hop is held")
			seams.edge(id, 78200, {}, { rev = 2 }) -- the connector leaves the record: the box is gone during the wait
			layouts.wait(t, ctx, k + 1, 2780, function() return not waits(train()) end, function(left)
				ctx.expect(left ~= nil, "the train left the stop")
				if left then
					ctx.expect(#hop_rails(train()) == 0 and names(train()) == "RTD STOP,RTD DEST",
						"no dead hop inserted: " .. names(train()))
					ctx.expect(route.held == nil and route.hop == nil and route.unrouted == true,
						"nothing held, no hop, still unrouted for the retry")
				end
			end)
		end)
	end)

-- Owner decision B, the sweep: a visit landing in a long wait leaves the held route alone (the sweep runs every 300 ticks,
-- so a 450-tick wait holds at least one visit). Row 78600, its own.
t.case("routing: B — a sweep visit during the wait keeps the held route, and the hop goes in at the departure",
	function(ctx)
		local id, trace = "rt-b-sweep", "rt-b-sweep.1"
		rig(ctx, 3000, id, 78600, { conn("t2", "ab", 24) }, { t2 = { rails = 60 } })
		local unit
		local function train()
			return game.get_entity_by_unit_number(unit).train
		end
		local function waits(tr)
			return tr.state == defines.train_state.wait_station and tr.station and tr.station.backer_name == "RTS STOP"
		end
		ctx.at(3002, function()
			seams.partner(id, "t2", { ready = false })
		end)
		ctx.at(3040, function()
			outward_stop(id, "t2", 37, "RTS STOP")
			unit = seams.add(id, "t2", { layout = "L", at = 50, next = "RTS DEST" })
			local sched = train().get_schedule()
			sched.remove_record{ schedule_index = 1 }
			sched.add_record{ station = "RTS STOP", wait_conditions = { { type = "time", ticks = 450 } },
				index = { schedule_index = 1 } }
			sched.go_to_station(1)
		end)
		layouts.wait(t, ctx, 3041, 3200, function() return waits(train()) end, function(k)
			ctx.expect(k ~= nil, "the train reached RTS STOP and waits there")
			if not k then
				return
			end
			routes.register(train(), trace, "RTS DEST", {})
			deliver("ue.route.reply", { trace = trace, ok = true, hops = { { edge = id, cid = "t2" } } })
			local route = storage.universal_edges.routing.active[trace]
			ctx.expect(route and route.held, "the hop is held on the route")
			layouts.wait(t, ctx, k + 1, 3700, function()
				if not waits(train()) then
					return true
				end
				if storage.universal_edges.routing.active[trace] ~= route or not route.held then
					ctx.expect(false, "the route or its held hop was dropped during the wait at tick " .. game.tick)
					return true
				end
				return false
			end, function(left)
				ctx.expect(left ~= nil and left - k >= 300, "the wait spanned a sweep period: " .. tostring(left and left - k))
				if left then
					ctx.expect(storage.universal_edges.routing.active[trace] == route, "same route, not moved_on")
					one_hop(ctx, train(), ue.trains.get(id, "t2").end_rail, "RTS DEST", "right after the departure")
				end
			end)
		end)
	end)

-- D22-4 (§11.4, R17): the goal guard at materialized. Offers onto an inbound box, as the transit case's.
t.case("routing: D22-4 — the goal guard: a destination gone from the records, or not the record UE made current, ends the route",
	function(ctx)
		local id = "rt-guard"
		rig(ctx, 2300, id, 73400, { conn("t1", "ba", 4) }, { t1 = { rails = 60 } })
		ctx.at(2340, function()
			offer(id, 1, { { station = "RTG OTHER" } },
				{ router = { trace = "rtg.1", dest = "RTG DEST", hops = { { edge = "rt-next", cid = "c9" } } } }, "LC")
			ctx.expect(reply(id, 1) == "credited", "credited: " .. tostring(reply(id, 1)))
			local lost = queued("ue.route.lost", function(p) return p.trace == "rtg.1" end)[1]
			ctx.expect(lost and lost.reason == "schedule_changed", "its destination is no longer a record: lost schedule_changed")
			ctx.expect(storage.universal_edges.routing.active["rtg.1"] == nil, "not registered here")
			seams.clear(id, "t1")
		end)
		ctx.at(2370, function()
			offer(id, 2, { { station = "RTG OTHER" }, { station = "RTG DEST" } },
				{ router = { trace = "rtg.2", dest = "RTG DEST", hops = { { edge = "rt-next", cid = "c9" } } } }, "LC")
			ctx.expect(reply(id, 2) == "credited", "credited: " .. tostring(reply(id, 2)))
			local lost = queued("ue.route.lost", function(p) return p.trace == "rtg.2" end)[1]
			local line = traced("ue.route", "lost", "rtg.2")[1]
			ctx.expect(lost and lost.reason == "moved_on" and line and line.level == "info",
				"UE made RTG OTHER current, not the route's destination: lost moved_on, at info")
			ctx.expect(storage.universal_edges.routing.active["rtg.2"] == nil, "not registered here")
			seams.clear(id, "t1")
		end)
	end)

-- T6a (§7.5): a body too big to send is refused at capture.
t.case("routing: T6a — a body too big: restored clears captured, rejected is logged, no lost; the next visit sends manual",
	function(ctx)
		local id, trace = "rt-big", "rt-big.1"
		rig(ctx, 2850, id, 74600, { conn("t1", "ab", 10) }, { t1 = { rails = 60 } })
		ctx.at(2852, function()
			seams.partner(id, "t1", { ready = false }) -- no capture by the poll: the test captures by hand
		end)
		ctx.at(2890, function()
			local tr = game.get_entity_by_unit_number(seams.add(id, "t1", { layout = "LC", at = 40, next = "RTB FAR" })).train
			local route = routed(tr, trace, "RTB FAR", id, "t1")
			local ep = seams.endpoint(id, "t1")
			lanes.MAX_BODY = 64 -- F4's limit, lowered for this one call only
			local ok, err = pcall(ue_train.capture, ep, ep.data, tr, storage.universal_edges.edges[id])
			lanes.MAX_BODY = 65536
			ctx.expect(ok, "the capture doesn't raise: " .. tostring(err))
			ctx.expect(tr.manual_mode and route.captured == false, "manual, and restored cleared captured")
			local line = traced("ue.route", "rejected", trace)[1]
			ctx.expect(line and line.why == "too_big" and line.level == "warn" and line.edge == id and line.cid == "t1",
				"ue.route rejected, why = too_big")
			ctx.expect(#queued("ue.route.lost", function(p) return p.trace == trace end) == 0, "not lost")
			routes.visit(trace, route)
			ctx.expect(#queued("ue.route.manual", function(p) return p.trace == trace end) == 1 and route.manual,
				"the next visit asks the controller to release its reservation")
		end)
	end)

-- T6a (§7.5): a player switches a held train to manual before the commit, which then succeeds.
t.case("routing: T6a — a held train switched to manual before a commit that succeeds: no lost, no manual, forgotten here",
	function(ctx)
		local id, trace = "rt-held", "rt-held.1"
		rig(ctx, 2850, id, 75000, { conn("t1", "ab", 10) }, { t1 = { rails = 150 } })
		local unit, held
		ctx.at(2890, function()
			unit = seams.add(id, "t1", { layout = "LC", at = 40, next = "RTH FAR", speed = 1 })
			routed(game.get_entity_by_unit_number(unit).train, trace, "RTH FAR", id, "t1")
		end)
		for k = 2891, 3080 do
			ctx.at(k, function()
				local ep = seams.endpoint(id, "t1")
				if held or not ep.data.held then
					return
				end
				held = k
				local route = storage.universal_edges.routing.active[trace]
				ctx.expect(route.captured == true, "captured by the box's own poll")
				game.get_entity_by_unit_number(unit).train.manual_mode = true -- the player, before the commit
				routes.visit(trace, route)
				ctx.expect(#queued("ue.route.manual", function(p) return p.trace == trace end) == 0 and not route.manual,
					"a held train's route sends nothing (§7.5)")
				local seq = ep.tx.ab.inflight.seq
				seams.lane(id, { k = "u.reply", cid = "t1", dir = "ab", seq = seq, outcome = "credited", w = seq })
				ctx.expect(game.get_entity_by_unit_number(unit) == nil, "the commit removed the train")
				routes.visit(trace, route)
				ctx.expect(storage.universal_edges.routing.active[trace] == nil, "forgotten on the source")
				ctx.expect(#queued("ue.route.lost", function(p) return p.trace == trace end) == 0, "silently: no lost")
			end)
		end
		ctx.at(3081, function()
			ctx.expect(held ~= nil, "captured by tick 3080")
		end)
	end)

-- §7.6: the manual release, and the re-ask once automatic.
t.case("routing: manual — sent once, a reply inserts nothing, cancel manual drops the reservation, automatic asks again",
	function(ctx)
		local id, trace = "rt-man", "rt-man.1"
		rig(ctx, 3260, id, 75400, { conn("t2", "ab", 24), conn("t3", "ab", 44) },
			{ t2 = { rails = 60, station = "RTMAN STOP" }, t3 = { rails = 60 } })
		ctx.at(3262, function()
			seams.partner(id, "t2", { ready = false })
		end)
		ctx.at(3300, function()
			local stop = stop_named("RTMAN STOP")
			local tr = game.get_entity_by_unit_number(seams.add(id, "t2", { layout = "L", at = 40, next = "RTMAN FAR" })).train
			local route = routed(tr, trace, "RTMAN FAR", id, "t2")
			deliver("ue.route.reserve", { trace = trace, unit = stop.unit_number })
			local before = stop.script_reservations_count
			tr.manual_mode = true
			routes.visit(trace, route)
			routes.visit(trace, route)
			ctx.expect(#queued("ue.route.manual", function(p) return p.trace == trace end) == 1 and route.manual,
				"manual sent once over two visits")
			ctx.expect(#traced("ue.route", "manual", trace) == 1, "ue.route manual logged")
			deliver("ue.route.reply", { trace = trace, ok = true, hops = { { edge = id, cid = "t3" } } })
			ctx.expect(#hop_rails(tr) == 1 and hop_rails(tr)[1] == ue.trains.get(id, "t2").end_rail.unit_number and tr.manual_mode,
				"a reply inserts nothing into a manual train: " .. names(tr))
			deliver("ue.route.cancel", { trace = trace, reason = "manual" })
			ctx.expect(stop.script_reservations_count == before - 1, "cancel manual drops its reservation")
			local line = traced("ue.reservation", "cancelled", trace)[1]
			ctx.expect(line and line.reason == "manual", "logged with its reason")
			tr.manual_mode = false
			routes.visit(trace, route)
			local asked = traced("ue.route", "requested", trace)[1]
			ctx.expect(asked and asked.start == "automatic" and not route.manual, "automatic again: it asks at once")
		end)
	end)

-- I2 and M6 on the tile (§7.4, R14).
t.case("routing: I2 and M6 — the alive report in parts, forgotten re-asks through the walker, orphan cancels, a reserve moves",
	function(ctx)
		local id = "rt-alive"
		rig(ctx, 3360, id, 75800, { conn("t2", "ab", 24) }, { t2 = { rails = 120, station = "RTA STOP" } })
		local last = 8
		ctx.at(3362, function()
			seams.partner(id, "t2", { ready = false })
		end)
		ctx.at(3400, function()
			local r = storage.universal_edges.routing
			local anchor = game.get_entity_by_unit_number(seams.add(id, "t2", { layout = "L", at = 200, next = "RTA FAR" }))
			for i = 1, 300 do
				r.active["rtalive." .. i] = { trace = "rtalive." .. i, anchor = anchor, unit = anchor.unit_number, dest = "RTA FAR",
					hops = {}, unrouted = true }
			end
			routes.alive()
			local seen, parts = {}, 0
			for _, m in ipairs(queued("ue.route.alive")) do
				parts = parts + 1
				ctx.expect(#helpers.table_to_json(m) <= 3000, "every part within 3000 bytes")
				for _, x in ipairs(m.active) do
					seen[x] = true
				end
			end
			local all = true
			for i = 1, 300 do
				all = all and seen["rtalive." .. i] == true
			end
			ctx.expect(parts > 1 and all, "300 traces over " .. parts .. " parts, each standing alone")
			for i = 1, 300 do
				r.active["rtalive." .. i] = nil
			end
			local traces = {}
			for i = 1, 8 do
				local tr = game.get_entity_by_unit_number(seams.add(id, "t2", { layout = "L", at = 20 * i, next = "RTA FAR" })).train
				tr.get_schedule().remove_record{ schedule_index = 1 }
				tr.get_schedule().go_to_station(1)
				routes.register(tr, "rtf." .. i, "RTA FAR", {})
				traces[i] = "rtf." .. i
			end
			traces[9] = "rtf.unknown"
			deliver("ue.route.forgotten", { traces = traces })
			local flagged = 0
			for i = 1, 8 do
				flagged = flagged + (r.active["rtf." .. i].reask and 1 or 0)
			end
			ctx.expect(flagged == 8, "every forgotten route is marked to ask again")
		end)
		for k = 3401, 3420 do
			ctx.at(k, function()
				local r, left = storage.universal_edges.routing, 0
				for i = 1, 8 do
					left = left + ((r.active["rtf." .. i] or {}).reask and 1 or 0)
				end
				ctx.expect(last - left <= 4, "at most 4 re-asks a tick: " .. (last - left) .. " at " .. k)
				last = left
			end)
		end
		ctx.expect_ipc("universal_edges:out", '"start":"forgotten"')
		layouts.wait(t, ctx, 3421, 3850, function()
			local r, left = storage.universal_edges.routing, 0
			for i = 1, 8 do
				left = left + ((r.active["rtf." .. i] or {}).reask and 1 or 0)
			end
			last = left
			return left == 0
		end, function(k)
			ctx.expect(k ~= nil, "all 8 asked again")
			local a, b = stop_named("RTA STOP"), lone_stop(30000, 75800, "RTA OTHER", false)
			local before = a.script_reservations_count
			deliver("ue.route.reserve", { trace = "rto.1", unit = a.unit_number })
			deliver("ue.route.cancel", { trace = "rto.1", reason = "orphan" })
			local line = traced("ue.reservation", "cancelled", "rto.1")[1]
			ctx.expect(a.script_reservations_count == before and line and line.reason == "orphan", "an orphan cancel drops it")
			deliver("ue.route.reserve", { trace = "rto.2", unit = a.unit_number })
			deliver("ue.route.reserve", { trace = "rto.2", unit = b.unit_number })
			ctx.expect(a.script_reservations_count == before and b.script_reservations_count == 1
				and storage.universal_edges.routing.reserved["rto.2"] == b, "R14: the reservation moved")
			local moved = traced("ue.reservation", "cancelled", "rto.2")[1]
			ctx.expect(moved and moved.reason == "rerouted", "the move logged as a re-route")
			deliver("ue.route.cancel", { trace = "rto.2", reason = "gc" })
		end)
	end)

-- Review Focus 1: 2.0 train groups share records; temporary records are per train.
t.case("routing: a hop goes into the routed train only, not into its train group's other trains", function(ctx)
	local id = "rt-group"
	rig(ctx, 3440, id, 76200, { conn("t2", "ab", 24) }, { t2 = { rails = 80 } })
	ctx.at(3442, function()
		seams.partner(id, "t2", { ready = false })
	end)
	ctx.at(3480, function()
		local a = game.get_entity_by_unit_number(seams.add(id, "t2", { layout = "L", at = 30, next = "RTGR FAR" })).train
		local b = game.get_entity_by_unit_number(seams.add(id, "t2", { layout = "L", at = 70, next = "RTGR FAR" })).train
		for _, tr in ipairs({ a, b }) do
			tr.get_schedule().remove_record{ schedule_index = 1 } -- only the remote destination
		end
		a.group = "rtgr-group" -- a new group, seeded with a's records (spike 5 §4)
		b.group = "rtgr-group"
		a.get_schedule().go_to_station(1)
		b.get_schedule().go_to_station(1)
		ctx.expect(names(a) == "RTGR FAR" and names(b) == "RTGR FAR", "the group's one record: " .. names(a) .. " / " .. names(b))
		routes.register(a, "rtgr.1", "RTGR FAR", {})
		deliver("ue.route.reply", { trace = "rtgr.1", ok = true, hops = { { edge = id, cid = "t2" } } })
		ctx.expect(#hop_rails(a) == 1, "the routed train has its hop: " .. names(a))
		ctx.expect(names(b) == "RTGR FAR", "the group's other train doesn't: " .. names(b))
	end)
end)

-- Review Focus 2: the connector removed while its routed train is held (the handoff test's removal case's shape).
t.case("routing: a connector removed while its routed train is held: restored (close) keeps the route, the dead hop is replaced",
	function(ctx)
		local id, trace = "rt-close", "rt-close.1"
		rig(ctx, 3440, id, 76600, { conn("t1", "ab", 10) }, { t1 = { rails = 150 } })
		local unit, held
		ctx.at(3480, function()
			unit = seams.add(id, "t1", { layout = "LC", at = 40, next = "RTCL FAR", speed = 1 })
			routed(game.get_entity_by_unit_number(unit).train, trace, "RTCL FAR", id, "t1")
		end)
		for k = 3481, 3700 do
			ctx.at(k, function()
				if held or not seams.endpoint(id, "t1").data.held then
					return
				end
				held = k
				seams.edge(id, 76600, {}, { rev = 2 }) -- the connector leaves the record: teardown, then the lane closes
				seams.lane(id, { k = "u.final", cid = "t1", dir = "ab", w = 0 })
				local route = storage.universal_edges.routing.active[trace]
				local tr = game.get_entity_by_unit_number(unit).train
				ctx.expect(route and route.captured == false and #traced("ue.route", "rejected", trace) == 0 and not tr.manual_mode,
					"restored on close: captured cleared, nothing logged, the train let go")
				routes.visit(trace, route)
				local asked = traced("ue.route", "requested", trace)[1]
				ctx.expect(route.hop == nil and #hop_rails(tr) == 0 and asked and asked.start == "train",
					"the dead hop removed by identity, and the route asks again: " .. names(tr))
			end)
		end
		ctx.at(3701, function()
			ctx.expect(held ~= nil, "captured by tick 3700")
		end)
	end)

-- The surfaces amendment (R33), ticks 3740-3782: is_local by surface. RTPL N ONLY is a lone stop on "sp3b" only (x 30000,
-- row 74200); a train on "sp4v" (plan ruling 18, row 74200) is sent there. Its own planet has no such stop, so it waits
-- in no_path and asks the controller; an is_local over every surface would call the name local and ask nothing.
t.case("routing: two planets — a train whose destination is only on another planet of its tile asks the controller (R33)",
	function(ctx)
		local id = "rt-pl-local"
		rig(ctx, 3740, id, 74200, { conn("t2", "ab", 24) }, { t2 = { rails = 40 } }, "sp4v")
		local unit
		ctx.at(3742, function()
			seams.partner(id, "t2", { ready = false }) -- no capture: the case is about the ask
		end)
		ctx.at(3780, function()
			lone_stop(30000, 74200, "RTPL N ONLY", false)
			unit = seams.add(id, "t2", { layout = "L", at = 30, next = "RTPL N ONLY" })
			local sched = game.get_entity_by_unit_number(unit).train.get_schedule()
			sched.remove_record{ schedule_index = 1 } -- only the destination, which sp4v doesn't have: no_path
			sched.go_to_station(1)
		end)
		ctx.at(3782, function()
			local tr = game.get_entity_by_unit_number(unit).train
			ctx.expect(routes.is_local("RTPL N ONLY", "sp3b") and not routes.is_local("RTPL N ONLY", tr.front_stock.surface_index),
				"is_local looks on the given surface only")
			ask_due(tr)
			routes.check(unit) -- what the waiting walker does (it may have asked already; this asks again, visibly)
			local q = queued("ue.route.request", function(p) return p.dest == "RTPL N ONLY" end)[1]
			ctx.expect(q and q.surface == "sp4v", "asked the controller, with the train's surface; state " .. tr.state)
			seams.clear(id, "t2")
		end)
	end)

-- Owner playtest 2026-10-05, ticks 3800-3832, row 79000 (free: no other rig uses it; the save's ticks end by 3850): a train
-- whose destination is a stop of its own surface that its track doesn't reach. Local, so it asked nothing before; in
-- no_path it now asks, and the controller decides whether the way out and back exists.
t.case("routing: a local stop the train cannot path to asks the controller (local via another tile)", function(ctx)
	local id = "rt-lv-local"
	rig(ctx, 3800, id, 79000, { conn("t2", "ab", 24) }, { t2 = { rails = 40 } })
	local unit
	ctx.at(3802, function()
		seams.partner(id, "t2", { ready = false })
	end)
	ctx.at(3830, function()
		lone_stop(30000, 79100, "RTLV ONLY", false)
		unit = seams.add(id, "t2", { layout = "L", at = 30, next = "RTLV ONLY" })
		local sched = game.get_entity_by_unit_number(unit).train.get_schedule()
		sched.remove_record{ schedule_index = 1 }
		sched.go_to_station(1)
	end)
	ctx.at(3832, function()
		local tr = game.get_entity_by_unit_number(unit).train
		ctx.expect(routes.is_local("RTLV ONLY", tr.front_stock.surface_index), "the stop is local")
		ask_due(tr)
		routes.check(unit)
		local q = queued("ue.route.request", function(p) return p.dest == "RTLV ONLY" end)[1]
		ctx.expect(q and q.firsts, "asked the controller, with firsts; state " .. tr.state)
		seams.clear(id, "t2")
	end)
end)

-- Playtest 2026-10-10 (gridworld_0_1 logged "ue.routing failed: Given train stop is not connected to any rails" every
-- ~30 s): a stop named as the train's destination but on no rail made the origin's search raise, so the train never
-- asked. Ticks 3834-3864, row 79800 (free).
t.case("routing: a stop on no rail, named as the destination, is no goal of the origin's search; the ask goes out",
	function(ctx)
	local id = "rt-norail"
	rig(ctx, 3834, id, 79800, { conn("t2", "ab", 24) }, { t2 = { rails = 40 } })
	ctx.at(3864, function()
		local tr = game.get_entity_by_unit_number(seams.add(id, "t2", { layout = "L", at = 30, next = "RTNR NORAIL",
			manual = true })).train
		local s = game.get_surface("sp3b")
		local stop = assert(s.create_entity{ name = "train-stop", position = { 31000, 79800 }, direction = defines.direction.north,
			force = "player" }, "a stop on no rail")
		stop.backer_name = "RTNR NORAIL"
		local ok, err = pcall(routes.request, tr, routes.register(tr, "rtnr.1", "RTNR NORAIL", {}), nil, "train")
		ctx.expect(ok, "the request doesn't raise: " .. tostring(err))
		local q = queued("ue.route.request", function(p) return p.dest == "RTNR NORAIL" end)[1]
		ctx.expect(q and q.firsts, "asked the controller, with firsts")
		for _, f in ipairs(q and q.firsts or {}) do
			ctx.expect(f[1] ~= "s:" .. stop.unit_number, "the railless stop is no first")
		end
		routes.forget("rtnr.1")
		stop.destroy()
		seams.clear(id, "t2")
	end)
end)

-- Owner, 2026-10-06: clicking a cargo or artillery wagon popped the station panel up; only a locomotive's window opens it.
t.case("routing: only a locomotive's window opens the panel, a wagon's doesn't", function(ctx)
	local id = "rt-panel-loco"
	rig(ctx, 3820, id, 79400, { conn("t2", "ab", 24) }, { t2 = { rails = 40 } })
	ctx.at(3860, function()
		local front = game.get_entity_by_unit_number(seams.add(id, "t2", { layout = "LCA", at = 30, manual = true }))
		for _, c in ipairs(front.train.carriages) do
			local player = { index = 1, gui = { screen = fake_gui(), relative = fake_gui() }, opened = c, display_scale = 1.25,
				display_resolution = { width = 2560, height = 2088 } }
			panel.show(player)
			local shown = player.gui.screen.router_stations ~= nil
			ctx.expect(shown == (c.type == "locomotive"), c.type .. "'s window: the panel is " .. (shown and "shown" or "not shown"))
		end
		seams.clear(id, "t2")
	end)
end)
