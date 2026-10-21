local t = require("modules/v2_test/testlib")
-- Factorio allows require only while the file loads, never inside a step.
local ue = require("modules/universal_edges")
local geometry = require("modules/universal_edges/edges/geometry_core")
local core = require("modules/universal_edges/transports/train_core")
local seams = require("modules/universal_edges/transports/train_seams")

-- Rows 30000-32800 of "sp3b", ticks 500-1100. Each inbound connector receives on ba from a scripted partner, whose
-- offers carry bodies built here in capture's wire format (§12.4). The credit runs in the inbox handler, so its reply
-- and events wait in the bridge's queue for the step to read; the joins run in the scheduler, so the steps sample
-- the train instead.
local NAMES = { L = "locomotive", l = "locomotive", C = "cargo-wagon", F = "fluid-wagon", A = "artillery-wagon" }

-- An extension that sends the train to data.hop (a station) or data.rail (an outbound box's end rail, SP4 §5) first, as
-- SP4's route state does (D22). ep:materialized runs every train extension for every crossing (C2), so it checks for its
-- own data.
ue.transfers.extend{
	name = "sp3b-test",
	types = { train = true },
	materialized = function(_, tr, data)
		local rec = data and (data.hop and { station = data.hop }
			or data.rail and { rail = seams.endpoint(data.rail.edge, data.rail.cid).data.rails[core.OUT_RAILS] })
		if rec then
			rec.temporary, rec.index = true, { schedule_index = 1 }
			local sched = tr.get_schedule()
			sched.add_record(rec)
			sched.go_to_station(1)
		end
	end,
}

local function inbound(cid, pos, layer)
	return { cid = cid or "t1", type = "train", pos = pos or 10, width = 6, params = { dir = "ba", layer = layer or "ground" } }
end

--- A body for layout (L/l locomotive facing in/out, C, F, A); o: records, edge_record, current, interrupts, speed,
--- manual, ext, layer, and extra[k], fields for carriage k.
local function body(layout, o)
	local cars = {}
	for k = 1, #layout do
		local l = string.sub(layout, k, k)
		local c = { name = NAMES[l], quality = "normal", flip = l == "l" }
		if c.name == "locomotive" then
			c.inv = { { i = defines.inventory.fuel, s = { i = { { n = "coal", c = 20 } } } } }
		end
		for key, v in pairs((o.extra or {})[k] or {}) do
			c[key] = v
		end
		cars[k] = c
	end
	return { v = 1, layer = o.layer or "ground", speed = o.speed or 0.5, manual = o.manual == true, carriages = cars,
		schedule = { records = o.records or { { station = "SP3B Z" } }, interrupts = o.interrupts or {}, current = o.current or 1 },
		edge_record = o.edge_record, ext = o.ext }
end

local function offer(id, seq, b, cid)
	seams.lane(id, { k = "u.offer", cid = cid or "t1", dir = "ba", seq = seq, tag = "0000beef", trace = id .. "." .. seq,
		body = helpers.encode_string(helpers.table_to_json(b)), digest = id .. "#" .. seq })
end

--- Messages of msg_type for edge id waiting in the bridge's queue this tick.
local function queued(msg_type, id, pred)
	local out = {}
	for _, m in ipairs(storage.universal_edges.bridge.out.universal_edges or {}) do
		if m.type == msg_type and m.payload.edge == id and (not pred or pred(m.payload)) then
			out[#out + 1] = m.payload
		end
	end
	return out
end

local function reply(id, seq)
	local r = queued("ue.lane", id, function(p) return p.k == "u.reply" and p.seq == seq end)[1]
	return r and r.outcome
end

local function event(id, phase)
	return queued("trace", id, function(p) return p.op == "ue.train" and p.phase == phase end)[1]
end

-- A join whose arrival has no entry (crossing spec §6.1): the stand-in joins and the controller answers with none, so
-- placement only seats them in a carriage waiting for them (§6.4).
local joins = 0
local function join(name, unit_number)
	joins = joins + 1
	ue_rt.player_join(name, unit_number)
	ue_rt.inbox("universal_edges", helpers.table_to_json({ { id = "0000c4bb." .. joins, type = "ue.player.arrival",
		payload = { player = name } } }))
end

local function names(tr)
	local out = {}
	for i, r in ipairs(tr.get_schedule().get_records()) do
		out[i] = (r.station or "<rail>") .. (r.temporary and "*" or "")
	end
	return table.concat(out, ",")
end

--- The edge at tick, then the partner and a 120-rail track with stop SP3B Z for each of its connectors.
local function live(ctx, tick, id, y, list, o)
	ctx.at(tick, function()
		seams.edge(id, y, list, o)
	end)
	ctx.at(tick + 1, function()
		for _, c in ipairs(list) do
			seams.partner(id, c.cid)
			seams.track(id, c.cid, 120, "SP3B Z")
		end
	end)
end

local function local_y(id, e)
	local _, y = geometry.to_local(seams.endpoint(id, "t1").frame, e.position.x, e.position.y)
	return y
end

--- Sample a long train every tick from `from` to `to`: it moves only inward; after each pass its tail is still in the
--- box, and the check holds.
local function follow(ctx, id, from, to, check)
	local s = { n = 0 }
	for k = from, to do
		ctx.at(k, function()
			local q = seams.endpoint(id, "t1").data.queue
			s.front = q and q.front or s.front
			if not (s.front and s.front.valid) then
				return
			end
			local tr, y = s.front.train, local_y(id, s.front)
			ctx.expect(s.y == nil or y >= s.y, id .. ": the front only moves inward (tick " .. k .. ")")
			s.y = y
			if #tr.carriages ~= s.n then
				ctx.expect(#tr.carriages > s.n, id .. ": carriages only join")
				-- v1's pass fills the box. One carriage per 15-tick try put carriages 23 and 24 past the border at 1 tile/tick
				-- ([probe] sp3b-review), where a curve or a fork would wedge the box (review I1).
				local outer = math.min(local_y(id, tr.front_stock), local_y(id, tr.back_stock))
				ctx.expect(outer <= core.FIRST, id .. ": the tail is inside the box after every join: " .. outer)
				check(tr, #tr.carriages)
				s.n = #tr.carriages
			end
		end)
	end
	return s
end

t.case("trains: a 24-carriage push-pull train spawns 12, then the rest behind its moving front (§12.5)", function(ctx)
	local id = "sp3b-long"
	live(ctx, 500, id, 30000, { inbound() })
	ctx.at(530, function()
		-- H4: records {SP3B ELSEWHERE, SP3B Z} with current = 2, and current == 2 expected after every join. A join
		-- resets current to 1 (spike 5); only a body that starts past record 1 can tell "restored" from "never reset".
		offer(id, 1, body("L" .. string.rep("C", 22) .. "l",
			{ speed = 1, records = { { station = "SP3B ELSEWHERE" }, { station = "SP3B Z" } }, current = 2 }))
		ctx.expect(reply(id, 1) == "credited", "credited: " .. tostring(reply(id, 1)))
		local ep = seams.endpoint(id, "t1")
		ctx.expect(#seams.trains(id, "t1") == 1 and #seams.trains(id, "t1")[1].carriages == 12, "the first batch is twelve")
		ctx.expect(ep.data.queue and ep.data.queue.next == 13, "twelve wait")
		ctx.expect(ep.status.ready == false and ep.status.w == 1, "not ready; w is the credited seq")
	end)
	local s = follow(ctx, id, 531, 760, function(tr, n)
		ctx.expect(names(tr) == "SP3B ELSEWHERE,SP3B Z" and tr.get_schedule().current == 2, "records and current after join " .. n)
		ctx.expect(not tr.manual_mode and math.abs(tr.speed) > 0.3, "automatic and moving after join " .. n .. ": " .. tr.speed)
	end)
	ctx.at(761, function()
		ctx.expect(s.n == 24, "all 24 joined: " .. s.n)
		ctx.expect(seams.endpoint(id, "t1").data.queue == nil, "the queue is empty")
	end)
	ctx.at(1100, function()
		ctx.expect(seams.endpoint(id, "t1").status.ready == true, "ready again once the train has left the box")
	end)
end)

t.case("trains: the front destroyed mid-assembly sends the rest to limbo (R15)", function(ctx)
	local id = "sp3b-lost"
	live(ctx, 502, id, 30400, { inbound() })
	ctx.at(532, function()
		offer(id, 1, body("L" .. string.rep("C", 19), { speed = 0.6 }))
		seams.endpoint(id, "t1").data.queue.front.destroy()
	end)
	ctx.at(560, function()
		ctx.expect(seams.endpoint(id, "t1").data.queue == nil, "the queue went to limbo")
	end)
	ctx.expect_file("universal_edges/limbo/sp3b-lost.1.txt")
	ctx.expect_ipc("universal_edges:out", "sp3b-lost.1.txt")
end)

t.case("trains: a spawn across another layer's rail is credited and keeps its own layer (D18)", function(ctx)
	local id = "sp3b-layer"
	-- t1: the brief's own geometry, an elevated box with a ground rail crossing it. t2: the reverse, a ground box
	-- with an elevated rail crossing it. Both at carriage 2's spawn point, local (col + 3, -13).
	live(ctx, 504, id, 30800, { inbound("t1", 10, "elevated"), inbound("t2", 40, "ground") }, { facing = 4 })
	ctx.at(520, function()
		-- the two rail layers stay apart on 2.1.20 ([probe] sp3b-review), confirmed in both directions: neither crossing
		-- rail ever joins the train that spawns across it (checked below), whatever its orientation to the box's axis.
		local frame = seams.endpoint(id, "t1").frame
		local x1, y1 = geometry.to_world(frame, 13, core.spawn_y(2))
		ctx.expect(game.get_surface("sp3b").create_entity{ name = "straight-rail", position = { x1, y1 },
			direction = defines.direction.north, force = "player" } ~= nil, "the ground rail crossing t1's elevated box")
		local x2, y2 = geometry.to_world(frame, 43, core.spawn_y(2))
		ctx.expect(game.get_surface("sp3b").create_entity{ name = "elevated-straight-rail", position = { x2, y2 },
			direction = defines.direction.north, force = "player" } ~= nil, "the elevated rail crossing t2's ground box")
	end)
	--- Offer a plain 4-carriage train to cid on layer; it is credited whole, as one train, on the box's own rails only.
	local function check(cid, layer)
		local b = body("LCCC", { layer = layer })
		offer(id, 1, b, cid)
		local r = queued("ue.lane", id, function(p) return p.k == "u.reply" and p.seq == 1 and p.cid == cid end)[1]
		ctx.expect(r and r.outcome == "credited", cid .. ": credited despite the foreign-layer rail: " .. tostring(r and r.outcome))
		local trs = seams.trains(id, cid)
		ctx.expect(#trs == 1 and #trs[1].carriages == #b.carriages, cid .. ": one train, every carriage made")
		local ep = seams.endpoint(id, cid)
		local foreign = false
		for _, rr in pairs(trs[1] and trs[1].get_rails() or {}) do
			if not ep.data.rail_ids[rr.unit_number] then
				foreign = true
			end
		end
		ctx.expect(not foreign, cid .. ": every rail under the train is the box's own")
	end
	ctx.at(534, function()
		check("t1", "elevated")
		check("t2", nil)
	end)
end)

t.case("trains: quality, fuel, fluid and cargo arrive as they left; a rider's seat is stored (§12.4)", function(ctx)
	local id = "sp3b-stock"
	local loco, stand_in, seated = nil, nil, false
	live(ctx, 506, id, 31200, { inbound() })
	ctx.at(536, function()
		offer(id, 1, body("LFC", { extra = {
			{ quality = "legendary", burning = { name = "nuclear-fuel", quality = "normal", remaining = 1000000000 },
				label = "SP3B LOCO", color = { r = 1, g = 0, b = 0, a = 1 }, copy_color_from_train_stop = false,
				riders = { driver = "sp3b-rider" } },
			{ fluid = { name = "steam", amount = 1000, temperature = 500 } },
			{ quality = "rare", inv = { { i = defines.inventory.cargo_wagon, s = { b = 5, i = { { n = "iron-plate", q = "epic", c = 100 },
				{ s = 2, f = { name = "copper-plate", quality = "rare", comparator = "=" } } } } } } },
		} }))
		ctx.expect(reply(id, 1) == "credited", "credited")
		local cars = seams.trains(id, "t1")[1].carriages
		local tank, wagon
		loco, tank, wagon = cars[1], cars[2], cars[3]
		-- M1: on 2.1.20, a locomotive's default_copy_color_from_train_stop is true, so a custom colour is overwritten by
		-- whatever stop it's sent to (here, SP3B Z's own default) unless the source says copy_color_from_train_stop = false.
		ctx.expect(loco.quality.name == "legendary" and loco.backer_name == "SP3B LOCO" and loco.color.r == 1, "the locomotive")
		ctx.expect(loco.burner.currently_burning.name.name == "nuclear-fuel" and loco.burner.remaining_burning_fuel == 1000000000,
			"burning nuclear fuel")
		ctx.expect(loco.get_fuel_inventory().get_item_count("coal") == 20, "its fuel")
		local f = tank.get_fluid(1)
		ctx.expect(f and f.name == "steam" and f.amount == 1000 and f.temperature == 500, "the fluid wagon's steam")
		local inv = wagon.get_inventory(defines.inventory.cargo_wagon)
		ctx.expect(wagon.quality.name == "rare" and inv.get_item_count({ name = "iron-plate", quality = "epic" }) == 100, "epic plates")
		ctx.expect(inv.get_bar() == 5 and inv.get_filter(2) and inv.get_filter(2).name == "copper-plate", "the bar and a filter")
		local w = storage.universal_edges.waiting[loco.unit_number]
		ctx.expect(w and w.driver == "sp3b-rider", "the locomotive waits for its driver")
		ctx.expect(w and w.trace == id .. ".1", "with the crossing's trace, for its seated line (M12): " .. tostring(w and w.trace))
		local ep = seams.endpoint(id, "t1")
		-- H15: a waiting carriage seat is taken by players.seat once the rider is placed (crossing spec §6.4), which
		-- releases only vehicle.TYPES — a locomotive seated there is never released. Confirm with a stand-in, the way
		-- ue_rt.player_join and an arrival drive a join in a game test. The train is automatic and moving (default speed
		-- 0.5), so the stand-in goes 3 tiles off the rail's centreline (ep.col + 3 is the centreline, + 3 more clears
		-- it), not in its path, or the train runs it over before the placement (scheduled 1 tick out) can seat it.
		local sx, sy = geometry.to_world(ep.frame, ep.col + 3 + 3, local_y(id, loco))
		stand_in = game.get_surface(loco.surface_index).create_entity{ name = "character", position = { sx, sy }, force = "player" }
		join("sp3b-rider", stand_in.unit_number)
	end)
	for k = 537, 545 do
		ctx.at(k, function()
			if not seated and loco.get_driver() == stand_in then
				seated = true
			elseif not seated and k == 545 then
				ctx.expect(false, "sp3b-rider seated as the locomotive's driver by tick " .. k)
			end
		end)
	end
	-- the log is read from the process's full IPC output, not the in-tick bridge queue: the seat runs from the
	-- scheduled placement, a tick the bridge may already have flushed and cleared by the time a step samples it.
	-- N1: the closing quote stops "sp3b-rider" also matching "sp3b-rider2" (the immediate-seat case, same save);
	-- only a ue.player line carries "player", so this also pins the phase without a separate needle.
	ctx.expect_ipc("universal_edges:out", "\"player\":\"sp3b-rider\"")
end)

t.case("trains: the edge record and interrupts: temporary stripped, permanent kept, created_by_interrupt kept (§12.4)", function(ctx)
	local id = "sp3b-records"
	live(ctx, 508, id, 31600, { inbound("t1", 4), inbound("t2", 40) })
	ctx.at(538, function()
		local fuel = { first_signal = { type = "item", name = "coal" }, comparator = "<", constant = 5 }
		offer(id, 1, body("LC", { edge_record = 1, records = { { station = "SP3B EDGE", temporary = true },
			{ station = "SP3B HOP", temporary = true, created_by_interrupt = true }, { station = "SP3B Z" } },
			interrupts = { { name = "sp3b refuel", conditions = { { type = "fuel_item_count_any", condition = fuel } },
				targets = { { station = "SP3B Z" } }, inside_interrupt = true } } }), "t1")
		offer(id, 1, body("LC", { edge_record = 2, current = 2,
			records = { { station = "SP3B A" }, { station = "SP3B E" }, { station = "SP3B B" } } }), "t2")
		local one = seams.trains(id, "t1")[1]
		ctx.expect(names(one) == "SP3B HOP*,SP3B Z" and one.get_schedule().current == 1, "temporary edge record gone: " .. names(one))
		ctx.expect(one.get_schedule().get_record{ schedule_index = 1 }.created_by_interrupt == true, "created_by_interrupt kept")
		local it = one.get_schedule().get_interrupts()[1]
		ctx.expect(it and it.name == "sp3b refuel" and it.inside_interrupt == true, "the interrupt, inside_interrupt included")
		local two = seams.trains(id, "t2")[1]
		ctx.expect(names(two) == "SP3B A,SP3B E,SP3B B" and two.get_schedule().current == 3, "permanent kept; the next: " .. names(two))
	end)
end)

t.case("trains: an extension's data applied at materialized survives every join (§11)", function(ctx)
	local id = "sp3b-ext"
	live(ctx, 510, id, 32000, { inbound() })
	ctx.at(540, function()
		offer(id, 1, body("L" .. string.rep("C", 19), { speed = 0.8, records = { { station = "SP3B ELSEWHERE" } },
			ext = { ["sp3b-test"] = { hop = "SP3B Z" } } }))
		ctx.expect(#queued("trace", id, function(p) return p.op == "ue.transfer" and p.phase == "materialized" end) == 1,
			"ue.transfer materialized, once")
	end)
	local s = follow(ctx, id, 541, 720, function(tr, n)
		ctx.expect(names(tr) == "SP3B Z*,SP3B ELSEWHERE" and tr.get_schedule().current == 1, "the hop holds after join " .. n)
	end)
	ctx.at(721, function()
		ctx.expect(s.n == 20, "all 20 joined: " .. s.n)
	end)
end)

t.case("trains: a body naming what this server lacks is rejected and leaves nothing; busy while carriages wait (G5)", function(ctx)
	local id = "sp3b-reject"
	live(ctx, 512, id, 32400, { inbound() })
	ctx.at(542, function()
		local b = body("LC", {})
		b.carriages[2].name = "sp3b-missing-wagon"
		offer(id, 1, b)
		ctx.expect(reply(id, 1) == "reject", "an unknown carriage: rejected")
		local rejected = event(id, "rejected")
		ctx.expect(rejected ~= nil and #seams.trains(id, "t1") == 0, "logged, and nothing built")
		ctx.expect(rejected.carriages == 2, "M5: the rejected line carries carriages")
		ctx.expect(seams.endpoint(id, "t1").data.w == 1, "w covers a reject too, so the source's gate opens (§12.3)")
		-- I1: an unknown item is caught by the pre-check (missing_core), before any carriage exists — unlike the fluid
		-- and signal cases below, which still raise inside first_batch, after the carriages do.
		offer(id, 2, body("LC", { extra = { [2] = { inv = { { i = defines.inventory.cargo_wagon,
			s = { i = { { n = "sp3b-missing-item", c = 5 } } } } } } } }))
		ctx.expect(reply(id, 2) == "reject" and #seams.trains(id, "t1") == 0, "an unknown item: rejected, nothing built")
		-- a fluid this server lacks raises in set_fluid, after the carriages exist (review I2)
		offer(id, 3, body("LF", { extra = { [2] = { fluid = { name = "sp3b-missing-fluid", amount = 10, temperature = 15 } } } }))
		ctx.expect(reply(id, 3) == "reject" and #seams.trains(id, "t1") == 0, "an unknown fluid: rejected, nothing left")
		-- so does a signal this server lacks, in set_interrupts
		local odd = { first_signal = { type = "virtual", name = "sp3b-missing-signal" }, comparator = ">", constant = 0 }
		offer(id, 4, body("LC", { interrupts = { { name = "x", conditions = { { type = "circuit", condition = odd } } } } }))
		ctx.expect(reply(id, 4) == "reject" and #seams.trains(id, "t1") == 0, "an unknown signal: rejected, nothing left")
		ctx.expect(seams.endpoint(id, "t1").data.w == 4, "w moved with each reject")
		offer(id, 5, body("L" .. string.rep("C", 19), {}))
		ctx.expect(reply(id, 5) == "credited", "the next train comes")
		offer(id, 6, body("LC", {}))
		ctx.expect(reply(id, 6) == "busy", "busy while carriages wait")
	end)
end)

t.case("trains: teardown of an inbound box mid-assembly keeps the rails and sends the queue to limbo (§12.8)", function(ctx)
	local id = "sp3b-tdq"
	local v
	live(ctx, 514, id, 32800, { inbound() })
	ctx.at(546, function()
		offer(id, 1, body("L" .. string.rep("C", 23), { speed = 0.5 }))
	end)
	ctx.at(560, function()
		v = ue.trains.get(id, "t1")
		ctx.expect(v.box_signal.signal_state == defines.signal_state.closed, "the train is in the box")
		seams.edge(id, 32800, {}, { rev = 2 })
		local ev = event(id, "front_lost")
		ctx.expect(ev and ev.reason == "teardown", "front_lost, reason teardown")
	end)
	ctx.at(562, function()
		for i, r in ipairs(v.rails) do
			ctx.expect(r.valid and r.minable_flag and not ue.owns(r), "rail " .. i .. " kept, the player's now")
		end
		ctx.expect(not v.box_signal.valid, "the outer signal is gone")
	end)
	ctx.expect_file("universal_edges/limbo/sp3b-tdq.1.txt")
end)

-- Fix round 1 (review task-2-review.md): rows 33200-34000, past Task 2's original 30000-32800 budget — nothing else
-- on "sp3b" claims this range, and Task 3 starts at 40000 (global-constraints.md).

t.case("trains: a rider already online is seated at once, not stored (H1, H2, M4)", function(ctx)
	local id = "sp3b-rider2"
	live(ctx, 516, id, 33200, { inbound() })
	local stand_in
	ctx.at(548, function()
		local ep = seams.endpoint(id, "t1")
		-- 3 tiles off the rail's centreline (ep.col + 3), so the locomotive's own spawn point doesn't collide with it.
		local x, y = geometry.to_world(ep.frame, ep.col + 3 + 3, core.spawn_y(1))
		stand_in = game.get_surface(ep.frame.surface_index).create_entity{ name = "character", position = { x, y }, force = "player" }
		storage.universal_edges.players.stand_in = storage.universal_edges.players.stand_in or {}
		storage.universal_edges.players.stand_in["sp3b-rider2"] = stand_in.unit_number
		-- registered before the offer (M4): players.online finds it during credit itself, so seat() takes the
		-- set_driver-at-once branch, not the waiting-seat one the other rider's case covers.
		-- M5: an arrival fetched before the train came; seated at once, its placing must go with it.
		storage.universal_edges.players.placing["sp3b-rider2"] = { expires = game.tick + 3600 }
		-- crossing-arrival spec §5.1: still guarded as arriving; the credit seat must settle the rider too.
		local a = storage.universal_edges.players; a.arriving = a.arriving or {}; a.arriving["sp3b-rider2"] = true
		offer(id, 1, body("LC", { extra = { { riders = { driver = "sp3b-rider2" } } } }))
		ctx.expect(reply(id, 1) == "credited", "credited")
		local loco = seams.trains(id, "t1")[1].carriages[1]
		ctx.expect(loco.get_driver() == stand_in, "seated at once, during credit, not after")
		ctx.expect(storage.universal_edges.waiting[loco.unit_number] == nil, "never waiting: it was already seated")
		ctx.expect(storage.universal_edges.players.placing["sp3b-rider2"] == nil,
			"seated at once, the rider has no placing left (M5)")
		ctx.expect(not storage.universal_edges.players.arriving["sp3b-rider2"], "seated at once, the arrival guard ends (spec §5.1)")
	end)
	-- N1: the closing quote stops a prefix match against another rider's name.
	ctx.expect_ipc("universal_edges:out", "\"player\":\"sp3b-rider2\"")
end)

t.case("trains: a raise during a later join restores the front train's schedule and mode, not stuck (I2)", function(ctx)
	local id = "sp3b-rejoin"
	live(ctx, 518, id, 33600, { inbound() })
	ctx.at(550, function()
		-- 13 carriages: 12 in the first batch, 1 queued (the fluid wagon, carriage 13). Its join raises in
		-- write_carriage's set_fluid (an unknown fluid), after it has already coupled to front.train (review I2).
		-- current = 2 pins the restore the same way H4 does.
		offer(id, 1, body("L" .. string.rep("C", 11) .. "F",
			{ speed = 0.7, records = { { station = "SP3B ELSEWHERE" }, { station = "SP3B Z" } }, current = 2,
				extra = { [13] = { fluid = { name = "sp3b-missing-fluid", amount = 10, temperature = 15 } } } }))
		ctx.expect(reply(id, 1) == "credited", "credited: " .. tostring(reply(id, 1)))
	end)
	local checked = false
	for k = 552, 630 do
		ctx.at(k, function()
			if checked then
				return
			end
			local ep = seams.endpoint(id, "t1")
			if ep.data.queue == nil then
				checked = true
				local trs = seams.trains(id, "t1")
				ctx.expect(#trs == 1, "the front train still stands alone, not split in two: " .. #trs)
				local tr = trs[1]
				ctx.expect(not tr.manual_mode, "I2: automatic again after the raise (tick " .. k .. ")")
				ctx.expect(tr.get_schedule().current == 2, "I2: current restored to 2 after the raise (tick " .. k .. ")")
			elseif k == 630 then
				ctx.expect(false, "the queue never resolved by tick " .. k)
			end
		end)
	end
	ctx.expect_file("universal_edges/limbo/sp3b-rejoin.1.txt")
end)

t.case("trains: a foreign wagon coupled onto the first batch is destroyed, not grown into, and stays intact (M2)", function(ctx)
	local id = "sp3b-foreign"
	local foreign
	live(ctx, 520, id, 34000, { inbound() })
	ctx.at(552, function()
		local ep = seams.endpoint(id, "t1")
		-- one GAP (7 tiles) past carriage 12's spawn point: Factorio auto-couples adjacent rolling stock at that
		-- spacing, so the fresh 12-carriage batch and this standing wagon become one 13-carriage train.
		local x, y = geometry.to_world(ep.frame, ep.col + 3, core.spawn_y(12) - 7)
		foreign = game.get_surface(ep.frame.surface_index).create_entity{ name = "cargo-wagon", position = { x, y },
			force = "player", orientation = core.orientation(ep.frame.facing, false) }
		ctx.expect(foreign ~= nil, "the foreign wagon")
	end)
	ctx.at(554, function()
		-- the review's cheap repro (M2): force the outer signal open, so credit proceeds past the busy gate straight
		-- to the post-spawn check this case targets, regardless of whether the foreign wagon's presence closed it.
		local d = seams.endpoint(id, "t1").data
		local real_outer = d.outer
		d.outer = { valid = true, signal_state = defines.signal_state.open }
		offer(id, 1, body("L" .. string.rep("C", 11), {}))
		ctx.expect(reply(id, 1) == "busy", "busy: the foreign wagon coupled into the batch: " .. tostring(reply(id, 1)))
		local trs = seams.trains(id, "t1")
		ctx.expect(#trs == 1 and #trs[1].carriages == 1, "none of this offer's carriages are left, only the foreign wagon")
		ctx.expect(event(id, "spawn_failed") ~= nil, "ue.train spawn_failed")
		ctx.expect(foreign.valid, "the foreign wagon is intact")
		-- m5: put the real signal back, or teardown later would destroy this fake table instead of it.
		d.outer = real_outer
	end)
end)

t.case("trains: a spawn blocked by something other than a train answers busy with a reason, so spawn_failed logs " ..
	"(final review I1); then a waiting seat whose carriage is gone is dropped, the rider left where placement put them " ..
	"(M2, crossing spec §6.4)", function(ctx)
	-- One edge for both checks (not two): each new edge also adds a built-in "v" vehicle endpoint per side, sharing
	-- the vehicle type's own walk budget with every other test in the save (framework_game_test.lua's F7 comment).
	local id = "sp3b-i1m2"
	local un, stand_in, at
	live(ctx, 522, id, 34400, { inbound() })
	ctx.at(554, function()
		local ep = seams.endpoint(id, "t1")
		-- I1: a non-rolling-stock blocker sitting exactly on carriage 1's own spawn point (Task 4's E2E hit this
		-- live, with biters standing on the inbound rails): the outer signal stays open (no train occupies the
		-- box), but create_entity for the first carriage collides and returns nil.
		local x, y = geometry.to_world(ep.frame, ep.col + 3, core.spawn_y(1))
		local blocker = game.get_surface(ep.frame.surface_index).create_entity{ name = "small-biter", position = { x, y },
			force = "enemy" }
		ctx.expect(blocker ~= nil, "the blocker")
		offer(id, 1, body("LC", {}))
		ctx.expect(reply(id, 1) == "busy", "busy: no room for the first carriage")
		ctx.expect(#seams.trains(id, "t1") == 0, "nothing built")
		local ev = event(id, "spawn_failed")
		ctx.expect(ev ~= nil and ev.reason == "no room for the first carriage", "ue.train spawn_failed, with the reason")
		if blocker.valid then
			blocker.destroy()
		end
		-- M2: busy doesn't consume the seq (stop-and-wait unique lane, D20): a real source backs off and retries the
		-- same train, so the retry reuses seq 1 — a fresh seq here would be an invalid gap at the ledger, not what a
		-- real re-offer looks like. The box is clear now, so this retry is credited. Both this tick's seq-1 replies
		-- (busy, then credited) sit in the same queue, so take the last one instead of reply()'s first match.
		offer(id, 1, body("LC", { extra = { { riders = { driver = "sp3b-rider3" } } } }))
		local seq1_replies = queued("ue.lane", id, function(p) return p.k == "u.reply" and p.seq == 1 end)
		ctx.expect(seq1_replies[#seq1_replies] and seq1_replies[#seq1_replies].outcome == "credited", "credited")
		local loco = seams.trains(id, "t1")[1].carriages[1]
		un = loco.unit_number
		local w = storage.universal_edges.waiting[un]
		ctx.expect(w and w.driver == "sp3b-rider3", "the locomotive waits for its driver")
		loco.destroy() -- the carriage is gone by the time the rider joins (the train crossed on, or went to limbo)
		-- inside the line, 3 tiles off the rail's centreline: in no zone, so placement leaves the stand-in where it is
		local sx, sy = geometry.to_world(ep.frame, ep.col + 3 + 3, 1)
		stand_in = game.get_surface(ep.frame.surface_index).create_entity{ name = "character", position = { sx, sy },
			force = "player" }
		at = stand_in.position
		join("sp3b-rider3", stand_in.unit_number)
	end)
	ctx.at(557, function()
		ctx.expect(storage.universal_edges.waiting[un] == nil, "the waiting seat is dropped")
		ctx.expect(stand_in.valid and stand_in.position.x == at.x and stand_in.position.y == at.y,
			"the rider stays where placement left them")
	end)
	-- N1 (players_game_test.lua convention): the closing quote keeps this from matching "sp3b-rider"/"sp3b-rider2"; the
	-- join's request for the rider's arrival carries it.
	ctx.expect_ipc("universal_edges:out", "\"player\":\"sp3b-rider3\"")
end)

-- The owner's playtest (2026-10-03), row 34800: a curve 12 tiles past the border. Copied from the owner's track on
-- gridworld_-1_0 in the box's local frame: rail type, x from the rail's centre, local y, local direction.
local CURVE = {
	{ "curved-rail-a", 0, 12, 8 }, { "half-diagonal-rail", 2, 17, 0 }, { "curved-rail-b", 4, 21, 8 },
	{ "curved-rail-b", 8, 25, 14 }, { "curved-rail-a", 13, 27, 14 },
}

t.case("trains: joins behind a front that has turned through a curve keep it moving forward (owner playtest)", function(ctx)
	local id = "sp3b-curve"
	local RUN = 120 -- straight rails along the edge after the curve; the station is beside the last but one
	ctx.at(524, function()
		seams.edge(id, 34800, { inbound() })
	end)
	ctx.at(525, function()
		seams.partner(id, "t1")
		seams.track(id, "t1", 5) -- local y 1-9, as on the owner's map
		local ep = seams.endpoint(id, "t1")
		local s, f, x = game.get_surface("sp3b"), ep.frame, ep.col + 3
		seams.generate(s, f, x - 8, 0, x + 16 + 2 * RUN + 8, 40)
		local function place(name, dx, y, dir)
			local wx, wy = geometry.to_world(f, x + dx, y)
			local e = s.create_entity{ name = name, position = { wx, wy }, direction = geometry.dir_to_world(f, dir), force = "player" }
			ctx.expect(e ~= nil, name .. " at " .. dx .. "," .. y)
			return e
		end
		for _, r in ipairs(CURVE) do
			place(r[1], r[2], r[3], r[4])
		end
		for i = 0, RUN - 1 do
			place("straight-rail", 16 + 2 * i, 27, 12)
		end
		place("train-stop", 16 + 2 * (RUN - 2), 29, 4).backer_name = "SP3B CURVE"
	end)
	ctx.at(556, function()
		offer(id, 1, body("LL" .. string.rep("C", 22), { speed = 1, records = { { station = "SP3B CURVE" } } }))
		ctx.expect(reply(id, 1) == "credited", "credited: " .. tostring(reply(id, 1)))
	end)
	local s = follow(ctx, id, 557, 800, function(tr, n)
		ctx.expect(not tr.manual_mode and tr.speed > 0.3, "automatic and moving forward after join " .. n .. ": " .. tr.speed)
	end)
	ctx.at(801, function()
		ctx.expect(s.n == 24, "all 24 joined: " .. s.n)
		ctx.expect(seams.endpoint(id, "t1").data.queue == nil, "the queue is empty")
	end)
end)

-- Row 35200: a push-pull train with three reversed locomotives at its tail. The joins tie, then turn the front to the
-- outer end, where each later join makes the new carriage front_stock without turning the train (the hook review).
t.case("trains: joins at an outer front keep the train moving inward (L, 20 wagons, lll)", function(ctx)
	local id = "sp3b-lll"
	live(ctx, 526, id, 35200, { inbound() })
	ctx.at(558, function()
		offer(id, 1, body("L" .. string.rep("C", 20) .. "lll", { speed = 1 }))
		ctx.expect(reply(id, 1) == "credited", "credited: " .. tostring(reply(id, 1)))
	end)
	local s = follow(ctx, id, 559, 800, function(tr, n)
		ctx.expect(not tr.manual_mode and math.abs(tr.speed) > 0.3, "automatic and moving after join " .. n .. ": " .. tr.speed)
	end)
	ctx.at(801, function()
		ctx.expect(s.n == 24, "all 24 joined: " .. s.n)
		ctx.expect(seams.endpoint(id, "t1").data.queue == nil, "the queue is empty")
	end)
end)

-- The owner's short loop on gridworld_-1_0 (2026-10-04), rows 35600 and 36000: an inbound connector and, 26 columns
-- to its left, an outbound one, joined by straight rails to local y 91 and two U-turns, the far one 72 tiles past the
-- near one. Rail type, x from the inbound rail's centre, local y, local direction.
local LOOP = {
	{ "curved-rail-a", 0, 22, 10 }, { "curved-rail-b", -2, 27, 10 }, { "curved-rail-b", -6, 31, 4 },
	{ "curved-rail-a", -11, 33, 4 }, { "curved-rail-a", -15, 33, 14 }, { "curved-rail-b", -20, 31, 14 },
	{ "curved-rail-b", -24, 27, 8 }, { "curved-rail-a", -26, 22, 8 },
}

--- The loop at row y from tick: the edge, its partners and the rails at tick, and at tick + 32 a 30-carriage train
--- (5 locomotives, then 25 wagons) offered on t1 and bound for t2's end rail. Each tick after, until tick + 472, it
--- calls on_capture(inflight) once, the first tick t2 has the train in flight; returns a table whose .seen is that tick.
local function loop(ctx, id, y, tick, on_capture)
	ctx.at(tick, function()
		seams.edge(id, y, { inbound("t1", 40),
			{ cid = "t2", type = "train", pos = 14, width = 6, params = { dir = "ab", layer = "ground" } } })
	end)
	ctx.at(tick + 1, function()
		seams.partner(id, "t1")
		seams.partner(id, "t2", { ready = true })
		local ep = seams.endpoint(id, "t1")
		local s, f, x = game.get_surface("sp3b"), ep.frame, ep.col + 3
		seams.generate(s, f, x - 40, 0, x + 10, 112)
		local function place(name, dx, ly, dir)
			local wx, wy = geometry.to_world(f, x + dx, ly)
			if not s.find_entity(name, { wx, wy }) then
				local e = s.create_entity{ name = name, position = { wx, wy }, direction = geometry.dir_to_world(f, dir), force = "player" }
				ctx.expect(e ~= nil, name .. " at " .. dx .. "," .. ly)
			end
		end
		for ly = 1, 91, 2 do
			place("straight-rail", 0, ly, 0)
			place("straight-rail", -26, ly, 0)
		end
		for _, dy in ipairs({ 0, 72 }) do
			for _, r in ipairs(LOOP) do
				place(r[1], r[2], r[3] + dy, r[4])
			end
		end
	end)
	ctx.at(tick + 32, function()
		-- SP4 (§5): t2 has no edge stop; the extension sends the train to t2's end rail on arrival
		offer(id, 1, body("LLLLL" .. string.rep("C", 25), { speed = 1, ext = { ["sp3b-test"] = { rail = { edge = id, cid = "t2" } } } }))
		ctx.expect(reply(id, 1) == "credited", "credited: " .. tostring(reply(id, 1)))
	end)
	local st = {}
	for k = tick + 33, tick + 472 do
		ctx.at(k, function()
			local inflight = seams.endpoint(id, "t2").tx.ab.inflight
			if not st.seen and inflight then
				st.seen = k
				on_capture(inflight)
			end
		end)
	end
	ctx.at(tick + 473, function()
		ctx.expect(st.seen ~= nil, "t2 captured the train")
	end)
	return st
end

t.case("trains: a train captured while its tail still joins carries the tail on, front first (owner playtest)", function(ctx)
	local id = "sp3b-loop"
	loop(ctx, id, 35600, 528, function(inflight)
		local b = helpers.json_to_table(helpers.decode_string(inflight.body))
		local out = {}
		for i, c in ipairs(b.carriages) do
			out[i] = (c.name == "locomotive" and "L" or "C") .. (c.flip and "f" or "")
		end
		ctx.expect(table.concat(out) == "LLLLL" .. string.rep("C", 25), "the whole train, front first: " .. table.concat(out))
		ctx.expect(seams.endpoint(id, "t1").data.queue ~= nil, "captured while the tail still joined (the case under test)")
		seams.lane(id, { k = "u.reply", cid = "t2", dir = "ab", seq = inflight.seq, outcome = "credited", w = inflight.seq })
		ctx.expect(seams.endpoint(id, "t1").data.queue == nil, "the commit drops the tail's queue: it crossed")
		ctx.expect(event(id, "front_lost") == nil, "nothing went to limbo")
	end)
end)

t.case("trains: a refused crossing gives a carried tail back to its joins (owner playtest)", function(ctx)
	local id = "sp3b-loop2"
	loop(ctx, id, 36000, 530, function(inflight)
		local q = seams.endpoint(id, "t1").data.queue
		ctx.expect(q ~= nil and q.handed == true, "joins pause while the tail is carried")
		seams.lane(id, { k = "u.reply", cid = "t2", dir = "ab", seq = inflight.seq, outcome = "reject", w = inflight.seq })
		ctx.expect(seams.endpoint(id, "t1").data.queue == q and q.handed == nil, "the reject resumes the joins")
	end)
end)
