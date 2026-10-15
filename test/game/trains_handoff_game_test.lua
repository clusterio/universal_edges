local t = require("modules/v2_test/testlib")
-- Factorio allows require only while the file loads, never inside a step.
local ue = require("modules/universal_edges")
local connectors = require("modules/universal_edges/edges/connectors")
local lanes = require("modules/universal_edges/edges/lanes")
local train = require("modules/universal_edges/transports/train")
local seams = require("modules/universal_edges/transports/train_seams")

-- Rows 40000-43200 of "sp3b", ticks 600-2100. Each outbound connector sends on ab to a scripted partner. The partner's
-- ep message carries the gate's status (§12.3), and its u.reply settles the crossing. The capture runs in the poll,
-- so its offer leaves the same tick: the steps read the endpoint's ledger and ep.data instead. The reply's handler
-- runs in the step, so its events wait in the bridge's queue.
--
-- Fix round 1 (review task-3-review.md, M8): row 43600 (the H3 case), past this task's original 40000-43200 budget
-- (every row within it is already taken) — the same move trains_spawn_game_test.lua's own fix round 1 made past its
-- 30000-32800 budget. Checked unused by every other file and the bench scenario.
local function live(ctx, tick, id, y, st, layer, station, width)
	ctx.at(tick, function()
		seams.edge(id, y, { { cid = "t1", type = "train", pos = 10, width = width or 6, params = { dir = "ab", layer = layer or "ground" } } })
	end)
	ctx.at(tick + 1, function()
		seams.partner(id, "t1", st)
		seams.track(id, "t1", 150, station)
	end)
end

local function ep_of(id)
	return seams.endpoint(id, "t1")
end

--- The partner's answer to the offer in flight.
local function reply(id, outcome)
	local seq = ep_of(id).tx.ab.inflight.seq
	seams.lane(id, { k = "u.reply", cid = "t1", dir = "ab", seq = seq, outcome = outcome, w = seq })
end

local function events(id, phase)
	local n = 0
	for _, m in ipairs(storage.universal_edges.bridge.out.universal_edges or {}) do
		local p = m.payload
		if m.type == "trace" and p.op == "ue.train" and p.phase == phase and p.edge == id then
			n = n + 1
		end
	end
	return n
end

local function transfer_events(edge, phase)
	local n = 0
	for _, m in ipairs(storage.universal_edges.bridge.out.universal_edges or {}) do
		local p = m.payload
		if m.type == "trace" and p.op == "ue.transfer" and p.phase == phase and p.edge == edge then
			n = n + 1
		end
	end
	return n
end

local function names(tr)
	local out = {}
	for i, r in ipairs(tr.get_schedule().get_records()) do
		out[i] = (r.station or "<rail>") .. (r.temporary and "*" or "")
	end
	return table.concat(out, ",")
end

-- SP4 (§7.5): the restored hook, as an extension sees it: each call's why, per edge, in order ("!" when its train
-- wasn't valid).
local restored = {}
ue.transfers.extend{
	name = "sp3b-restored",
	types = { train = true },
	restored = function(ep, tr, why)
		restored[ep.edge] = (restored[ep.edge] and restored[ep.edge] .. "," or "") .. why .. (tr.valid and "" or "!")
	end,
}

-- Task 1's form (preflight ruling: production never reads LuaTrain.signal, and an unrelated circuit wire elsewhere
-- clears it — an engine quirk, not a hold fact): wait_signal, the signal forced or occupancy shut, and the front
-- stock within margin tiles of it, still on the approach side (larger local y, since every box here runs inward
-- toward negative y).
local MARGIN = 5.5 -- Task 1's box test: a measured ~4.5-tile stop, with headroom
local function shut(sig)
	return sig.signal_state == defines.signal_state.closed or sig.signal_state == defines.signal_state.reserved_by_circuit_network
end
local function held_at(ep, tr, sig, margin)
	local sy, fy = train.local_y(ep, sig.position), train.local_y(ep, tr.front_stock.position)
	return tr.state == defines.train_state.wait_signal and shut(sig) and fy > sy and fy <= sy + margin
end

t.case("trains: captured within 20 ticks of entering the outbound box, deleted at commit (§12.2, §12.7)", function(ctx)
	local id, seen = "sp3b-cap", {}
	live(ctx, 600, id, 40000, { ready = true }, nil, nil, 4) -- width 4: the crossing runs at col + 2
	ctx.at(620, function()
		seams.add(id, "t1", { layout = "LCC", at = 40, next = "SP3B NEXT", speed = 1, cargo = 77 })
	end)
	for k = 621, 900 do
		ctx.at(k, function()
			local d = ep_of(id).data
			seen.closed = seen.closed or (d.box_signal.signal_state == defines.signal_state.closed and k)
			seen.held = seen.held or (d.held ~= nil and k)
		end)
	end
	ctx.at(901, function()
		-- H5: not a fixed 10 — a lane message or any edge event wakes every type's poll walk (connectors.wake), and
		-- the next poll can land several ticks out depending on hash order and how many train endpoints share the
		-- walk (this count grows as more cases are added, so not pinned here). One poll interval plus one walk
		-- after a wake. Measured delay under this task's full row count (review M8): 3 ticks.
		ctx.expect(seen.closed and seen.held and seen.held - seen.closed <= 20,
			"captured within 20 ticks: the box closed at " .. tostring(seen.closed) .. ", held at " .. tostring(seen.held))
		local ep = ep_of(id)
		ctx.expect(ep.data.held.seq == 1 and #ep.data.held.carriages == 3 and ep.tx.ab.inflight.seq == 1, "seq 1 in flight")
		ctx.expect(#seams.trains(id, "t1") == 1, "held: still in this world until the destination has it (D20)")
		reply(id, "credited")
		ctx.expect(ep.data.held == nil and ep.tx.ab.inflight == nil and #seams.trains(id, "t1") == 0, "the commit deleted it")
		ctx.expect(ep.data.last.seq == 1, "the gate remembers seq 1")
	end)
end)

t.case("trains: a manual train in the outbound box is captured (M9)", function(ctx)
	local id = "sp3b-manual"
	live(ctx, 602, id, 40400, { ready = true })
	ctx.at(622, function()
		seams.add(id, "t1", { layout = "LC", at = 30, next = "SP3B NEXT", speed = 0.6, manual = true })
	end)
	ctx.at(760, function()
		ctx.expect(ep_of(id).data.held ~= nil, "the coasting manual train was captured")
		reply(id, "credited")
		ctx.expect(#seams.trains(id, "t1") == 0, "and deleted at commit")
	end)
end)

t.case("trains: with the gate shut a train waits at the hold signal; captured on a ready whose w covers it (D20)", function(ctx)
	local id = "sp3b-gate"
	live(ctx, 604, id, 40800, { ready = false })
	ctx.at(624, function()
		seams.add(id, "t1", { layout = "LCC", at = 40, next = "SP3B NEXT", speed = 1 })
	end)
	ctx.at(900, function()
		local ep, tr = ep_of(id), seams.trains(id, "t1")[1]
		local d = ep.data
		ctx.expect(d.held == nil and d.logged == true, "not captured; already logged by the natural poll")
		-- review M3: events(id, "waiting") == 1 pins the actual log line, not just the d.logged flag (which would
		-- still read true even if train.event's call at train.lua were deleted). The natural poll runs inside UE's
		-- own on_tick, which flushes the bridge's outbound queue in that same call (control.lua: scheduler, then
		-- flush, nothing else runs between them) — no later step can ever observe it. Reset the flag and force one
		-- poll here, in this step's own call, to prove the log line itself fires, not only the flag.
		d.logged = nil
		connectors.call(ep, "poll")
		ctx.expect(d.logged == true and events(id, "waiting") == 1, "ue.train waiting logged once")
		ctx.expect(held_at(ep, tr, ue.trains.get(id, "t1").hold, MARGIN), "it waits at the hold signal, never at the stop (D22)")
		seams.partner(id, "t1", { ready = true })
	end)
	-- H5: sample every tick instead of a fixed check, deadline 930 (900 + the same wake/poll slack as the delay case).
	local first_capture
	for k = 901, 930 do
		ctx.at(k, function()
			if not first_capture and ep_of(id).data.held ~= nil then
				first_capture = k
				reply(id, "credited")
				seams.add(id, "t1", { layout = "LCC", at = 40, next = "SP3B NEXT", speed = 1 })
			end
		end)
	end
	ctx.at(931, function()
		ctx.expect(first_capture ~= nil, "captured on ready by tick 930")
	end)
	ctx.at(1200, function()
		ctx.expect(ep_of(id).data.held == nil, "the second train: a ready without w is stale")
		seams.partner(id, "t1", { ready = true, w = 0 })
	end)
	ctx.at(1215, function()
		ctx.expect(ep_of(id).data.held == nil, "w = 0 is below the last seq, 1")
		seams.partner(id, "t1", { ready = true, w = 1 })
	end)
	-- H5: deadline 1245 instead of a fixed check at 1230.
	local second_capture
	for k = 1216, 1245 do
		ctx.at(k, function()
			local d = ep_of(id).data
			second_capture = second_capture or (d.held ~= nil and d.held.seq == 2 and k)
		end)
	end
	ctx.at(1246, function()
		ctx.expect(second_capture ~= nil, "captured once w covers seq 1, by tick 1245")
	end)
end)

t.case("trains: D22 — held at the hold and box signals; a fuel-low interrupt doesn't move them", function(ctx)
	local rows = { { id = "sp3b-d22-g", y = 41200, layer = "ground" }, { id = "sp3b-d22-e", y = 41600, layer = "elevated" } }
	local low = { first_signal = { type = "item", name = "coal" }, comparator = "<", constant = 10 }
	local interrupts = {
		{ name = "sp3b fuel", conditions = { { type = "fuel_item_count_any", condition = low } }, targets = { { station = "SP3B DEPOT" } } },
		-- [probe] 2.1.20: this interrupt's own condition is never true here, even with trains_limit = 0 on the
		-- ground row's own stop while that row's train is already bound to it as its current record (tried and
		-- measured, review I1/H7) — kept in the list so both interrupts are still exercised structurally (D22 must
		-- hold against whichever ones a train carries), but the no-path half of D22 itself is the owner's playtest.
		{ name = "sp3b no path", conditions = { { type = "destination_full_or_no_path" } }, targets = { { station = "SP3B DEPOT" } } },
	}
	local fronts, was = {}, {}
	for _, k in ipairs(rows) do
		live(ctx, 606, k.id, k.y, { ready = false }, k.layer, "SP3B DEPOT")
	end
	ctx.at(626, function()
		for _, k in ipairs(rows) do
			-- double-headed, so either could drive back to the depot if an interrupt took it
			fronts[k.id] = {
				seams.add(k.id, "t1", { layout = "LCl", at = 40, next = "SP3B NEXT", speed = 1, interrupts = interrupts }),
				seams.add(k.id, "t1", { layout = "LCl", at = 80, next = "SP3B NEXT", speed = 0, interrupts = interrupts }),
			}
		end
	end)
	ctx.at(1200, function()
		for _, k in ipairs(rows) do
			for i, n in ipairs(fronts[k.id]) do
				local tr = game.get_entity_by_unit_number(n).train
				for _, c in ipairs(tr.carriages) do
					if c.type == "locomotive" then
						c.get_fuel_inventory().clear()
						c.get_fuel_inventory().insert{ name = "coal", count = 1 } -- the fuel interrupt's condition is now true
					end
				end
				was[k.id .. i] = tr.front_stock.position
			end
		end
	end)
	ctx.at(2100, function()
		for _, k in ipairs(rows) do
			local ep, v = ep_of(k.id), ue.trains.get(k.id, "t1")
			local at_signal = { v.hold, v.box_signal }
			local edge_record = "<rail>*" -- SP4 (§5)
			for i, n in ipairs(fronts[k.id]) do
				local tr, label = game.get_entity_by_unit_number(n).train, k.id .. " train " .. i
				ctx.expect(held_at(ep, tr, at_signal[i], MARGIN), label .. ": waiting at its signal")
				ctx.expect(names(tr) == edge_record .. ",SP3B NEXT" and tr.get_schedule().current == 1, label .. ": records " .. names(tr))
				local p, q = tr.front_stock.position, was[k.id .. i]
				ctx.expect(p.x == q.x and p.y == q.y, label .. ": it hasn't moved")
			end
		end
		-- these four trains never get captured or destroyed on their own (the gate stays shut, D22's whole point);
		-- past this case's own checks nothing else needs them, so they're cleared rather than left running interrupt
		-- conditions and pathfinding for the other ~1900 ticks of the shared save.
		for _, k in ipairs(rows) do
			for _, n in ipairs(fronts[k.id]) do
				local tr = game.get_entity_by_unit_number(n) and game.get_entity_by_unit_number(n).train
				for _, c in ipairs(tr and tr.carriages or {}) do
					c.destroy()
				end
			end
		end
	end)
end)

t.case("trains: a rejected train goes manual and isn't captured again until the box empties; the next one is (R10)", function(ctx)
	local id = "sp3b-rej"
	live(ctx, 608, id, 42000, { ready = true })
	ctx.at(628, function()
		seams.add(id, "t1", { layout = "LC", at = 40, next = "SP3B NEXT", speed = 1 })
	end)
	ctx.at(800, function()
		local ep = ep_of(id)
		ctx.expect(ep.data.held ~= nil, "captured")
		reply(id, "reject")
		ctx.expect(restored[id] == "reject", "UE's restored hook ran once, why = reject (SP4 §7.5): " .. tostring(restored[id]))
		-- as a real destination does after a reject (P15): ready, with w at the rejected seq, so the gate is open and only
		-- the rejected mark keeps the poll from capturing the same train again (review I3)
		seams.partner(id, "t1", { ready = true, w = 1 })
		ctx.expect(ep.data.held == nil and ep.data.rejected == true and seams.trains(id, "t1")[1].manual_mode, "manual, and marked")
		ctx.expect(events(id, "rejected") == 1, "ue.train rejected")
	end)
	ctx.at(950, function()
		local ep = ep_of(id)
		ctx.expect(ep.tx.ab.next_seq == 2 and ep.tx.ab.inflight == nil, "not captured again while it stands in the box")
		for _, c in ipairs(seams.trains(id, "t1")[1].carriages) do
			c.destroy() -- a player drives it away
		end
	end)
	-- review M8: sample to a deadline instead of a fixed tick — this was the tightest remaining fixed window (30
	-- ticks), tighter than H5's own measured poll slack.
	local cleared
	for k = 951, 990 do
		ctx.at(k, function()
			if not cleared and ep_of(id).data.rejected == nil then
				cleared = k
				seams.add(id, "t1", { layout = "LC", at = 40, next = "SP3B NEXT", speed = 1 })
			end
		end)
	end
	ctx.at(991, function()
		ctx.expect(cleared ~= nil, "the mark clears once the box is empty, by tick 990")
	end)
	ctx.at(1200, function()
		local held = ep_of(id).data.held
		ctx.expect(held ~= nil and held.seq == 2, "the next train is captured")
	end)
end)

t.case("trains: removal while a train is in flight restores it on the kept rails (§12.7, §12.8)", function(ctx)
	local id, v, front = "sp3b-rm"
	live(ctx, 610, id, 42400, { ready = true })
	ctx.at(630, function()
		seams.add(id, "t1", { layout = "LCC", at = 40, next = "SP3B NEXT", speed = 1 })
	end)
	ctx.at(800, function()
		local ep = ep_of(id)
		ctx.expect(ep.data.held ~= nil, "in flight")
		front, v = ep.data.held.carriages[1], ue.trains.get(id, "t1")
		seams.edge(id, 42400, {}, { rev = 2 }) -- the connector leaves the record: teardown, then the lane closes
		seams.lane(id, { k = "u.final", cid = "t1", dir = "ab", w = 0 }) -- the destination never had it, settled now
		-- review M3: restore returning true (placed) vs. nil (not placed) look the same to the case's other checks —
		-- a nil return writes a limbo file and logs this line, which the case didn't catch before. Checked the same
		-- tick as the u.final above, not later: the bridge flushes (and clears) its outbound queue every tick
		-- (bridge.lua's flush, once per tick from control.lua), so a later tick would always read zero regardless.
		ctx.expect(transfer_events(id, "unplaceable") == 0, "restore placed it: no ue.transfer unplaceable for this edge")
		ctx.expect(restored[id] == "close", "UE's restored hook ran once, why = close (SP4 §7.5): " .. tostring(restored[id]))
	end)
	ctx.at(802, function()
		ctx.expect(front.valid and #front.train.carriages == 3 and not front.train.manual_mode, "the train is here, whole, let go")
		ctx.expect(connectors.get(storage.universal_edges.edges[id], "t1") == nil, "the endpoint closed and is gone")
		for i, r in ipairs(v.rails) do
			ctx.expect(r.valid and r.minable_flag, "rail " .. i .. " kept under it")
		end
	end)
end)

t.case("trains: two captures of the same standing train encode to the same bytes; its group crosses by name, no ids " ..
	"(D21, sync §5.6)", function(ctx)
	local id, first = "sp3b-d21"
	live(ctx, 612, id, 42800, { ready = false })
	ctx.at(632, function()
		seams.add(id, "t1", { layout = "LCC", at = 40, next = "SP3B NEXT", speed = 1 })
		local tr = seams.trains(id, "t1")[1]
		tr.group = "sp3b-group" -- a new group, seeded with the train's records (spike 5 §4)
		-- temporary records are per train; put the edge record back if seeding the group dropped it
		local sched = tr.get_schedule()
		local head = sched.get_record{ schedule_index = 1 }
		if not (head and head.temporary) then
			sched.add_record{ rail = ue.trains.get(id, "t1").end_rail, temporary = true, index = { schedule_index = 1 } }
		end
		sched.go_to_station(1)
	end)
	ctx.at(1100, function()
		local tr = seams.trains(id, "t1")[1]
		ctx.expect(tr.state == defines.train_state.wait_signal and tr.group == "sp3b-group", "standing at the hold signal, grouped")
		-- H14: capture_body returns two values; table_to_json takes one argument.
		local body = train.capture_body(ep_of(id), tr)
		first = helpers.table_to_json(body)
	end)
	ctx.at(1300, function()
		local body = train.capture_body(ep_of(id), seams.trains(id, "t1")[1])
		local again = helpers.table_to_json(body)
		ctx.expect(again == first, "the same bytes 200 ticks later")
		for _, key in ipairs({ '"tick"', '"trace"', '"unit_number"', '"id"' }) do
			ctx.expect(not string.find(first, key, 1, true), "no " .. key .. " in the body")
		end
		local b = helpers.json_to_table(first)
		ctx.expect(b.edge_record == 1 and b.schedule.records[1].station == nil and b.schedule.records[1].temporary == true
			and b.schedule.records[2].station == "SP3B NEXT",
			"its own records, the end rail's record first as a marker")
		ctx.expect(b.group == "sp3b-group", "its group crosses by name (sync spec §5.6, replacing D19)")
		ctx.expect(#b.carriages == 3 and b.carriages[1].name == "locomotive" and b.carriages[1].flip == false, "travel-front first")
		ctx.expect(b.carriages[1].copy_color_from_train_stop == true, "a fresh locomotive's default crosses too")
	end)
end)

t.case("trains: a body over 64 KB puts the train in manual mode with too_big (F4)", function(ctx)
	local id = "sp3b-big"
	live(ctx, 614, id, 43200, { ready = false })
	ctx.at(634, function()
		seams.add(id, "t1", { layout = "LC", at = 40, next = "SP3B NEXT", speed = 1 })
	end)
	ctx.at(1100, function()
		local ep, tr = ep_of(id), seams.trains(id, "t1")[1]
		-- F4's limit (C5), lowered for this one call only, so no other file's capture sees it
		lanes.MAX_BODY = 64
		local ok, err = pcall(train.capture, ep, ep.data, tr, storage.universal_edges.edges[id])
		lanes.MAX_BODY = 65536
		ctx.expect(ok, "the capture doesn't raise: " .. tostring(err))
		ctx.expect(tr.manual_mode and ep.data.rejected == true and ep.data.held == nil and ep.tx.ab.inflight == nil,
			"manual, marked, nothing sent")
		ctx.expect(events(id, "too_big") == 1, "ue.train too_big")
		ctx.expect(restored[id] == "too_big", "UE's restored hook ran once, why = too_big (SP4 §7.5): " .. tostring(restored[id]))
	end)
end)

t.case("trains: a rider past the third carriage still crosses at commit, though its carriage stands outside the line (H3)",
	function(ctx)
		local id, rider_name = "sp3b-h3", "sp3b-h3-rider"
		live(ctx, 616, id, 43600, { ready = true })
		ctx.at(636, function()
			seams.add(id, "t1", { layout = "LCCCCCCL", at = 40, next = "SP3B NEXT", speed = 1 })
		end)
		ctx.at(1100, function()
			local ep = ep_of(id)
			ctx.expect(ep.data.held ~= nil, "captured")
			-- the outermost (tail) carriage, third or later in travel order: the one commit's loop destroys that
			-- stands inside this world, past the zone's 0.5 band, once the train is held (H3's premise)
			local index, y
			for i, c in ipairs(ep.data.held.carriages) do
				local cy = train.local_y(ep, c.position)
				if not y or cy > y then
					index, y = i, cy
				end
			end
			ctx.expect(y > 0, "its carriage stands inside, past the 0.5 band: local y " .. y)
			-- a game test has no connected LuaPlayer, so train.capture's own rider() lookup can never resolve a name
			-- from a bare stand-in character here — the structural limitation vehicles_game_test.lua documents and
			-- works around with its own capture override (held_names[edge]: "a --benchmark run has no LuaPlayer").
			-- Same trick here, one level later: inject the resolved name into held.riders, the array train.capture
			-- itself fills from rider(c) when a real driver exists, so the real commit() below drives the rest of
			-- the path (the real players.cross call, the real held crossing, the real trace) with no shortcuts past it.
			local outer = ep.data.held.carriages[index]
			ep.data.held.riders[index] = rider_name
			local crossing_trace = ep.tx.ab.inflight.trace -- before reply/commit: the capture's own trace (review M3)
			local outer_x, outer_y, outer_surface = outer.position.x, outer.position.y, outer.surface.name
			reply(id, "credited")
			-- M3: the crossing point is the box's border point, 1 tile past A's line at its column, not the carriage
			-- (inside this world, so its mirror is far outside the partner's: no zone there to place the rider by).
			local sent
			for _, m in ipairs(storage.universal_edges.bridge.out.universal_edges or {}) do
				if m.type == "ue.player.cross" and m.payload.player == rider_name then
					sent = m.payload
				end
			end
			local bx, by = train.world(ep, train.cx(ep), -1)
			ctx.expect(sent and math.abs(sent.x - bx) < 1e-9 and math.abs(sent.y - by) < 1e-9,
				"the rider's crossing point is the box's border point (" .. bx .. ", " .. by .. "): "
				.. tostring(sent and sent.x) .. ", " .. tostring(sent and sent.y))
			local pending = storage.universal_edges.players.pending[rider_name]
			ctx.expect(pending ~= nil and pending.held == true and pending.key == "edge:" .. id and pending.trace == crossing_trace,
				"commit crossed it as a held rider crossing, under the crossing's own trace (H3)")
			-- The carriage is gone and the rider stands inside: a move must not clear a held crossing before it is answered.
			ue_rt.player_move(rider_name, outer_surface, outer_x, outer_y)
			ctx.expect(storage.universal_edges.players.pending[rider_name] ~= nil, "a move inside leaves the held crossing alone")
			ctx.expect(not outer.valid, "commit destroyed the carriage it crossed")
		end)
	end)
