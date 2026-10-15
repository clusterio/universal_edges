local t = require("modules/v2_test/testlib")
-- Factorio allows require only while the file loads, never inside a step.
local ue = require("modules/universal_edges")
local connectors = require("modules/universal_edges/edges/connectors")
local lanes = require("modules/universal_edges/edges/lanes")
local ledger = require("modules/universal_edges/edges/ledger_core")

-- The partner is scripted: its ue.lane messages go straight to ue_rt.inbox, stamped with the epoch the case
-- activated. Replies sent from a message handler wait in the bridge's outbound queue until the next tick, so a step can
-- read them back; what the poll task sends leaves in the same tick, so ctx.expect_ipc checks it instead. Every case
-- builds its own edge with ue.edge.update, never a sync, which would drop the other cases' sides.
local seq = 0
local function deliver(msg_type, payload)
	seq = seq + 1
	local batch = { { id = "0000a1e5." .. seq, type = msg_type, payload = payload } }
	ue_rt.inbox("universal_edges", helpers.table_to_json(batch))
end

-- Activation needs this boot's sync (SP1a C1: storage.synced_boot). An empty sync, after SP1a's cases (ticks 2-70)
-- and before this file's (from 100): a sync drops every side it doesn't list, and at this tick there are none.
t.case("lanes: this file's sync", function(ctx)
	ctx.at(95, function()
		deliver("ue.edge.sync", { edges = {} })
		local s = storage.universal_edges
		ctx.expect(s.synced_boot == s.rt.boot_id, "synced under this boot")
	end)
end)

local function queued(msg_type, pred)
	local found = {}
	for _, msg in ipairs(storage.universal_edges.bridge.out.universal_edges or {}) do
		if msg.type == msg_type and (not pred or pred(msg.payload)) then
			found[#found + 1] = msg.payload
		end
	end
	return found
end

local function lane_msgs(edge, k)
	return queued("ue.lane", function(p) return p.edge == edge and p.k == k end)
end

local function traced(op, phase, edge)
	return queued("trace", function(p) return p.op == op and p.phase == phase and p.edge == edge end)
end

local function probe(cid, pos, params)
	return { cid = cid, type = "probe", pos = pos, width = 1, params = params }
end

local function wake_conn(cid, pos)
	return { cid = cid, type = "d39-wake", pos = pos, width = 1, params = {} }
end

local function record_of(id, revision, list, y, fields)
	local rec = {
		id = id, revision = revision, trace = "0000a1e5.t" .. revision, me = "a", owner = "test", length = 64,
		deleted = false, connectors = list or {},
		a = { instanceId = 4242, surface = "nauvis", origin = { 0, y }, facing = 0 },
		b = { instanceId = 4243, surface = "nauvis", origin = { 64, y }, facing = 8 },
	}
	for k, v in pairs(fields or {}) do
		rec[k] = v
	end
	return rec
end

local function endpoint(id, cid)
	local side = storage.universal_edges.edges[id]
	return side and connectors.get(side, cid)
end

--- Create the edge, activate it under epoch, and have the partner announce each cid ready.
local function live(ctx, at, id, list, y, epoch)
	ctx.at(at, function()
		deliver("ue.edge.update", { edge = record_of(id, 1, list, y) })
		deliver("ue.edge.activation", { id = id, active = true, epoch = epoch, trace = epoch })
	end)
	ctx.at(at + 1, function()
		for _, c in ipairs(list) do
			deliver("ue.lane", { edge = id, epoch = epoch, k = "ep", cid = c.cid, state = "ready" })
		end
		for _, ty in pairs(connectors.types) do -- the partner's built-in endpoints (v, and p when gridworld is loaded)
			if ty.builtin then
				deliver("ue.lane", { edge = id, epoch = epoch, k = "ep", cid = ty.builtin, state = "ready" })
			end
		end
	end)
end

local function from_partner(id, epoch, fields)
	fields.edge, fields.epoch = id, epoch
	deliver("ue.lane", fields)
end

local function state(id, cid)
	return helpers.json_to_table(ue_rt.probe_state(id, cid))
end

-- A stream type whose refund always fails, for G6's limbo path.
ue.connectors.register_type{
	name = "sp1b-refuse",
	lanes = function() return { ab = "stream" } end,
	schedule = { per_tick = 2, interval = 60 },
	build = function() return "ready" end,
	teardown = function() end,
	poll = function() end,
	refund = function() return false end,
}

-- D39 item 1: a stream type private to its own wake tests below, so steady lane traffic on one endpoint can't be
-- confused with any other case's traffic sharing another type's poll task.
ue.connectors.register_type{
	name = "d39-wake",
	lanes = function() return { ab = "stream" } end,
	schedule = { per_tick = 4, interval = 40 },
	build = function() return "ready" end,
	teardown = function() end,
	poll = function() end,
}

t.case("lanes: an idle, synced edge sends nothing for 3600 ticks (§11.2)", function(ctx)
	local E = "0000a1e5.idle"
	live(ctx, 100, "sp1b-idle", {
		probe("c1", 1, { dir = "ab", kind = "stream" }),
		probe("c2", 3, { dir = "ba", kind = "stream" }),
		probe("c3", 5, { dir = "ab", kind = "unique" }),
	}, 3000, E)
	ctx.at(150, function()
		for _, cid in ipairs({ "c1", "c2", "c3" }) do
			local ep = endpoint("sp1b-idle", cid)
			ctx.expect(ep.state == "ready" and ep.partner and ep.partner.state == "ready", cid .. " ready, partner ready")
		end
	end)
	ctx.expect_ipc("universal_edges:out", '"phase":"synced"')
	ctx.expect_no_ipc("universal_edges:out", '"edge":"sp1b-idle"', 260, 3880)
end)

t.case("lanes: stream offers and acks, partial credit, and a stale epoch discarded", function(ctx)
	local E = "0000a1e5.s1"
	live(ctx, 120, "sp1b-stream", {
		probe("c1", 1, { dir = "ab", kind = "stream" }),
		probe("c2", 3, { dir = "ba", kind = "stream", cap = 150 }),
	}, 3100, E)
	ctx.at(125, function()
		ue_rt.probe_add("sp1b-stream", "c1", 250)
		from_partner("sp1b-stream", E, { k = "s.offer", cid = "c2", dir = "ba", totals = { probe = 400 } })
		local acks = lane_msgs("sp1b-stream", "s.ack")
		ctx.expect(#acks == 1 and acks[1].totals.probe == 150 and acks[1].cid == "c2", "credited up to the cap of 150")
		ctx.expect(state("sp1b-stream", "c2").received_items == 150, "and the probe holds 150")
		from_partner("sp1b-stream", E, { k = "s.offer", cid = "c2", dir = "ba", totals = { probe = 400 } })
		ctx.expect(state("sp1b-stream", "c2").received_items == 150, "nothing more past the cap")
		from_partner("sp1b-stream", "0000a1e5.old", { k = "s.offer", cid = "c2", dir = "ba", totals = { probe = 999 } })
		ctx.expect(storage.universal_edges.stats["ue.lanes"].stale >= 1, "a stale epoch's message is counted")
		ctx.expect(state("sp1b-stream", "c2").lanes.ba.recv.probe == 150, "and changes nothing")
	end)
	ctx.at(170, function()
		local s = state("sp1b-stream", "c1")
		ctx.expect(s.stock == 0 and s.lanes.ab.sent.probe == 250, "250 captured in batches of 100")
		from_partner("sp1b-stream", E, { k = "s.ack", cid = "c1", dir = "ab", totals = { probe = 100 } })
		ctx.expect(state("sp1b-stream", "c1").lanes.ab.acked.probe == 100, "acked is assigned")
	end)
	ctx.at(200, function()
		from_partner("sp1b-stream", E, { k = "s.ack", cid = "c1", dir = "ab", totals = { probe = 250 } })
		ctx.expect(next(endpoint("sp1b-stream", "c1"):pending("ab")) == nil, "fully acknowledged")
	end)
	ctx.expect_ipc("universal_edges:out", '"totals":{"probe":100}')
	ctx.expect_ipc("universal_edges:out", '"totals":{"probe":250}')
	ctx.expect_ipc("universal_edges:out", '"free":0')
end)

t.case("lanes: a unique source chunks a big body, and handles every reply outcome", function(ctx)
	local E = "0000a1e5.u1"
	live(ctx, 420, "sp1b-unique", { probe("c1", 1, { dir = "ab", kind = "unique" }) }, 3200, E)
	ctx.at(422, function()
		ue_rt.probe_add("sp1b-unique", "c1", '{"id":"t-big","pad":8000}')
		ue_rt.probe_add("sp1b-unique", "c1", { id = "t2" })
	end)
	local function reply(outcome, n, w)
		from_partner("sp1b-unique", E, { k = "u.reply", cid = "c1", dir = "ab", seq = n, outcome = outcome, w = w or 0,
			trace = "x" })
	end
	ctx.at(450, function()
		ctx.expect(state("sp1b-unique", "c1").lanes.ab.inflight == 1, "t-big is in flight as seq 1")
		reply("busy", 1)
		ctx.expect(state("sp1b-unique", "c1").lanes.ab.inflight == 1, "busy changes nothing")
		reply("credited", 7)
		ctx.expect(storage.universal_edges.stats["ue.lanes"].stale_replies >= 1, "a reply for another seq is counted")
		reply("credited", 1, 1)
		local s = state("sp1b-unique", "c1")
		ctx.expect(s.lanes.ab.inflight == nil and s.tokens[1] == "t2", "committed: t-big left the probe")
		ctx.expect(#traced("ue.transfer", "ack", "sp1b-unique") == 1, "ue.transfer ack")
	end)
	ctx.at(480, function()
		ctx.expect(state("sp1b-unique", "c1").lanes.ab.inflight == 2, "t2 in flight as seq 2")
		reply("gap", 2)
		local skip = lane_msgs("sp1b-unique", "u.skip")
		ctx.expect(#skip == 1 and skip[1].to == 1, "a gap is answered with u.skip { to = seq - 1 }")
	end)
	ctx.at(500, function()
		reply("reject", 2)
		local s = state("sp1b-unique", "c1")
		ctx.expect(s.lanes.ab.inflight == nil and s.tokens[1] == "t2", "rejected: t2 restored to the probe")
		local restored = traced("ue.transfer", "restore", "sp1b-unique")
		ctx.expect(#restored == 1 and restored[1].level == "warn", "ue.transfer restore, at warn")
		deliver("ue.edge.activation", { id = "sp1b-unique", active = false, trace = "0000a1e5.d1", reason = "stopped" })
	end)
	-- A 12,000-byte body can only leave as parts: a message of 4000 bytes or more would take Clusterio's file path, which
	-- writes nothing in benchmark mode and would fail this whole run (0B Review Focus 3).
	ctx.expect_ipc("universal_edges:out", '"type":"ue.chunk"')
	ctx.expect_ipc("universal_edges:out", '"chunks":')
	ctx.expect_ipc("universal_edges:out", '"phase":"offer"')
end)

t.case("lanes: a unique destination classifies, credits, repeats, and logs a skipped range as lost", function(ctx)
	local E = "0000a1e5.u2"
	live(ctx, 720, "sp1b-dest", {
		probe("c1", 1, { dir = "ba", kind = "unique" }),
		probe("c2", 3, { dir = "ba", kind = "unique", reject = true }),
	}, 3300, E)
	local body = helpers.encode_string(helpers.table_to_json({ id = "x" }))
	local function offer(cid, n, tag, digest, b)
		from_partner("sp1b-dest", E, { k = "u.offer", cid = cid, dir = "ba", seq = n, tag = tag, digest = digest,
			body = b or body, trace = "0000a1e5.o" .. n })
		local replies = lane_msgs("sp1b-dest", "u.reply")
		return replies[#replies]
	end
	ctx.at(730, function()
		ctx.expect(offer("c1", 1, "T1", "d1").outcome == "credited", "new")
		ctx.expect(#state("sp1b-dest", "c1").received == 1, "credited once")
		ctx.expect(offer("c1", 1, "T1", "d1").outcome == "repeat", "the same tag again")
		ctx.expect(offer("c1", 1, "T2", "d1").outcome == "repeat", "another tag, the same digest")
		ctx.expect(offer("c1", 1, "T2", "d9").outcome == "divergent", "another tag, another digest")
		ctx.expect(#state("sp1b-dest", "c1").received == 2, "a divergent replay is credited")
		ctx.expect(#traced("ue.transfer", "divergent", "sp1b-dest") == 1, "and logged")
		local gap = offer("c1", 5, "T1", "d5")
		ctx.expect(gap.outcome == "gap" and gap.w == 1, "a gap reply carries w")
		from_partner("sp1b-dest", E, { k = "u.skip", cid = "c1", dir = "ba", to = 3 })
		local lost = traced("ue.transfer", "lost", "sp1b-dest")
		ctx.expect(#lost == 1 and lost[1].from == 2 and lost[1].to == 3 and lost[1].level == "error", "lost 2..3")
		ctx.expect(state("sp1b-dest", "c1").lanes.ba.w == 3, "w = max(w, to)")
		ctx.expect(offer("c1", 4, "T1", "d4", "not base64 !!").outcome == "reject", "an undecodable body is refused")
		ctx.expect(offer("c2", 1, "T1", "d1").outcome == "reject", "params.reject")
		ctx.expect(offer("c2", 1, "T1", "d1").outcome == "reject", "and the recorded reject is repeated")
		ue_rt.probe_set("sp1b-dest", "c1", '{"busy":true}')
		ctx.expect(offer("c1", 5, "T1", "d5").outcome == "busy", "ue_rt.probe_set forces busy")
		ue_rt.probe_set("sp1b-dest", "c1", "{}")
		ctx.expect(offer("c1", 5, "T1", "d5").outcome == "credited", "and lifts it")
		deliver("ue.edge.activation", { id = "sp1b-dest", active = false, trace = "0000a1e5.d2", reason = "stopped" })
	end)
end)

t.case("lanes: closing sends the final at once, resolves on it, and done drops both ends (§11.7)", function(ctx)
	local E = "0000a1e5.c1"
	local list = { probe("c1", 1, { dir = "ab", kind = "stream" }), probe("c2", 3, { dir = "ba", kind = "stream" }) }
	live(ctx, 820, "sp1b-close", list, 3400, E)
	-- After one whole poll walk (10 probe endpoints by now, 4 a tick): c2 is built and credits the offer.
	ctx.at(825, function()
		ue_rt.probe_add("sp1b-close", "c1", 100)
		from_partner("sp1b-close", E, { k = "s.offer", cid = "c2", dir = "ba", totals = { probe = 30 } })
	end)
	ctx.at(850, function()
		from_partner("sp1b-close", E, { k = "s.ack", cid = "c1", dir = "ab", totals = { probe = 40 } })
		deliver("ue.edge.update", { edge = record_of("sp1b-close", 2, {}, 3400) })
		ctx.expect(#traced("ue.lane", "closing", "sp1b-close") == 2, "both lanes close")
		local applied = queued("ue.edge.applied", function(p) return p.id == "sp1b-close" end)
		ctx.expect(applied[#applied].open == 2, "open = 2 while they close")
	end)
	ctx.at(860, function()
		-- The partner froze at 70, not at the stale ack of 40: the refund is 100 - 70 = 30.
		from_partner("sp1b-close", E, { k = "s.final", cid = "c1", dir = "ab", recv = { probe = 70 } })
		local done = lane_msgs("sp1b-close", "done")
		ctx.expect(#done == 1 and done[1].cid == "c1", "the source answers done")
		ctx.expect(endpoint("sp1b-close", "c1") == nil, "and is gone")
		local left = state("sp1b-close", "c1")
		ctx.expect(left.gone and left.refunded == 30 and left.stock == 30, "its tally outlives it: 30 refunded")
		local applied = queued("ue.edge.applied", function(p) return p.id == "sp1b-close" end)
		ctx.expect(applied[#applied].open == 1, "open = 1")
		from_partner("sp1b-close", E, { k = "done", cid = "c2", dir = "ba" })
		ctx.expect(endpoint("sp1b-close", "c2") == nil, "done drops the destination")
		applied = queued("ue.edge.applied", function(p) return p.id == "sp1b-close" end)
		ctx.expect(applied[#applied].open == 0, "open = 0")
		from_partner("sp1b-close", E, { k = "close", cid = "c77", dir = "ba", rev = 2, kind = "stream" })
		local finals = lane_msgs("sp1b-close", "s.final")
		ctx.expect(#finals == 1 and finals[1].cid == "c77" and next(finals[1].recv) == nil, "a zero-state final")
		from_partner("sp1b-close", E, { k = "close", cid = "c78", dir = "ba", rev = 9, kind = "stream" })
		ctx.expect(#lane_msgs("sp1b-close", "s.final") == 1, "none before this side applied revision 9")
		from_partner("sp1b-close", E, { k = "s.final", cid = "c79", dir = "ab", recv = {} })
		ctx.expect(#lane_msgs("sp1b-close", "done") == 2, "a final for a lane it doesn't have is answered done")
		deliver("ue.edge.activation", { id = "sp1b-close", active = false, trace = "0000a1e5.d3", reason = "stopped" })
	end)
	ctx.expect_ipc("universal_edges:out", '"k":"close"')
	ctx.expect_ipc("universal_edges:out", '"recv":{"probe":30}')
end)

t.case("lanes: a refund the transport can't place goes to a limbo file (G6)", function(ctx)
	local E = "0000a1e5.l1"
	local c = { cid = "c1", type = "sp1b-refuse", pos = 1, width = 1, params = {} }
	live(ctx, 1120, "sp1b-limbo", { c }, 3500, E)
	ctx.at(1130, function()
		endpoint("sp1b-limbo", "c1"):send("ab", { probe = 5 })
		deliver("ue.edge.update", { edge = record_of("sp1b-limbo", 2, {}, 3500) })
		from_partner("sp1b-limbo", E, { k = "s.final", cid = "c1", dir = "ab", recv = {} })
		local lost = traced("ue.transfer", "unplaceable", "sp1b-limbo")
		ctx.expect(#lost == 1 and lost[1].level == "error" and lost[1].file == "universal_edges/limbo/sp1b-limbo_c1-ab.txt",
			"unplaceable, at error, naming the file")
		deliver("ue.edge.activation", { id = "sp1b-limbo", active = false, trace = "0000a1e5.d4", reason = "stopped" })
	end)
	ctx.expect_file("universal_edges/limbo/sp1b-limbo_c1-ab.txt")
end)

t.case("lanes: the stream debug switch, off by default, traces each offer, credit and ack (D12)", function(ctx)
	local E = "0000a1e5.t1"
	live(ctx, 1220, "sp1b-trace", {
		probe("c1", 1, { dir = "ab", kind = "stream" }), probe("c2", 3, { dir = "ba", kind = "stream" }),
	}, 3600, E)
	ctx.at(1230, function()
		ctx.expect(storage.universal_edges.stream_trace == false, "off by default")
		local ep = endpoint("sp1b-trace", "c1")
		ep:send("ab", { probe = 10 })
		lanes.visit(ep, game.tick)
		local offers = lane_msgs("sp1b-trace", "s.offer")
		ctx.expect(#offers == 1 and offers[1].trace == nil, "no trace while off")
		ctx.expect(#traced("ue.transfer", "offer", "sp1b-trace") == 0, "and no line")
		storage.universal_edges.stream_trace = true
		from_partner("sp1b-trace", E, { k = "s.ack", cid = "c1", dir = "ab", totals = { probe = 10 } })
		ep:send("ab", { probe = 5 })
		lanes.visit(ep, game.tick)
		offers = lane_msgs("sp1b-trace", "s.offer")
		local on = offers[#offers]
		ctx.expect(on.trace ~= nil, "an offer carries a trace while on")
		local line = traced("ue.transfer", "offer", "sp1b-trace")
		ctx.expect(#line == 1 and line[1].trace == on.trace and line[1].level == "info", "ue.transfer offer, at info")
		from_partner("sp1b-trace", E, { k = "s.offer", cid = "c2", dir = "ba", totals = { probe = 7 }, trace = "0000a1e5.x" })
		local credit = traced("ue.transfer", "credit", "sp1b-trace")
		ctx.expect(#credit == 1 and credit[1].trace == "0000a1e5.x" and credit[1].accepted.probe == 7, "credit, same trace")
		from_partner("sp1b-trace", E, { k = "s.ack", cid = "c1", dir = "ab", totals = { probe = 15 }, trace = on.trace })
		ctx.expect(#traced("ue.transfer", "ack", "sp1b-trace") == 1, "ack, same trace")
		storage.universal_edges.stream_trace = false
		deliver("ue.edge.activation", { id = "sp1b-trace", active = false, trace = "0000a1e5.d5", reason = "stopped" })
	end)
end)

t.case("lanes: bodies encode deterministically, and JSON keeps every integer up to MAX_TOTAL (Minor 4)", function(ctx)
	ctx.at(1400, function()
		local payload = { id = "t1", cars = { { name = "locomotive", fuel = 3 }, { name = "cargo-wagon" } }, n = 7 }
		local a = helpers.encode_string(helpers.table_to_json(payload))
		local b = helpers.encode_string(helpers.table_to_json(payload))
		ctx.expect(a == b, "the same payload encodes to the same body, so the digest rule can recognise a replay")
		ctx.expect(helpers.json_to_table(helpers.decode_string(a)).cars[1].fuel == 3, "and decodes back")
		local x = 12345
		for _ = 1, 2000 do
			x = (x * 1103515245 + 12345) % 2147483648
			local v = (x % 262144) * 2147483648 + (x * 69069 + 1) % 2147483648
			local json = helpers.table_to_json({ v = v })
			if helpers.json_to_table(json).v ~= v then
				ctx.expect(false, "inexact below MAX_TOTAL: " .. string.format("%d", v))
				break
			end
			-- Lua's own round trip can't see 2.1.20's leading-zero defect (the motivation for MAX_TOTAL): it would
			-- make `"v":0<digit>`, which isn't valid JSON, and Node's JSON.parse would drop the whole IPC line.
			if json:find('"v":0%d') then
				ctx.expect(false, "leading zero in encoded JSON: " .. string.format("%d", v))
				break
			end
		end
		-- 99999999999999 is the largest all-nines value that fits under MAX_TOTAL (2^49 − 1); 15 nines would not.
		for _, v in ipairs({ 0, 1, 999999999999, 99999999999999, ledger.MAX_TOTAL - 1, ledger.MAX_TOTAL }) do
			local json = helpers.table_to_json({ v = v })
			ctx.expect(helpers.json_to_table(json).v == v, "exact: " .. string.format("%d", v))
			ctx.expect(not json:find('"v":0%d'), "no leading zero in JSON for: " .. string.format("%d", v))
		end
	end)
end)

-- D39 item 1: a lane message stops waking its type's whole poll walk (SP1's wake rule, SP1b final review I1; SP3
-- spec §4.2, §17 risk 3).

t.case("lanes: steady lane traffic on one endpoint no longer wakes its type's whole walk", function(ctx)
	local E = "0000a1e5.wake"
	live(ctx, 1500, "d39-wake", { wake_conn("busy", 1), wake_conn("quiet", 3) }, 3700, E)
	local base
	ctx.at(1510, function()
		base = (storage.universal_edges.stats["ue.poll.d39-wake"] or {}).runs or 0
	end)
	-- Steady inbound traffic on "busy" alone, every tick for 200 ticks. Under the old rule, every ue.lane message for
	-- a known cid woke the WHOLE type (connectors.wake(woken.type), lanes.lua:408-411 before this change), so the
	-- walk never rested and both "busy" and the untouched "quiet" endpoint were revisited far more than the
	-- schedule's own cadence (per_tick = 4, interval = 40: about one run every 40 ticks at rest).
	for i = 1, 200 do
		ctx.at(1510 + i, function()
			from_partner("d39-wake", E, { k = "s.ack", cid = "busy", dir = "ab", totals = { x = 0 } })
		end)
	end
	ctx.at(1715, function()
		local runs = (storage.universal_edges.stats["ue.poll.d39-wake"] or {}).runs or 0
		local delta = runs - base
		-- Resting cadence over these 205 ticks is about 5-6 runs (one per 40-tick cycle). The old, unconditional
		-- per-message wake pushed this past 150 (nearly an extra run a tick for 200 ticks of traffic).
		ctx.expect(delta < 20, "the walk rested through 200 ticks of lane traffic on one endpoint: delta runs = " .. delta)
	end)
end)

t.case("lanes: an ack that leaves keys pending re-offers the remainder in the same batch", function(ctx)
	local E = "0000a1e5.reoffer"
	live(ctx, 1750, "sp1b-reoffer", { probe("c1", 1, { dir = "ab", kind = "stream" }) }, 3750, E)
	ctx.at(1755, function()
		ue_rt.probe_add("sp1b-reoffer", "c1", 100)
	end)
	ctx.at(1770, function()
		-- One whole poll walk in (probe's schedule: per_tick 4, interval 10): c1 captured and offered its 100.
		local s = state("sp1b-reoffer", "c1")
		ctx.expect(s.stock == 0 and s.lanes.ab.sent.probe == 100, "captured and offered")
		from_partner("sp1b-reoffer", E, { k = "s.ack", cid = "c1", dir = "ab", totals = { probe = 40 } })
		-- 40 of 100 acked is progress, with 60 still pending: under the old rule the remainder waited for the type's
		-- walk to be woken and visit this lane again, up to a tick later; now it rides out with the ack's own reply.
		local offers = lane_msgs("sp1b-reoffer", "s.offer")
		ctx.expect(#offers == 1 and offers[1].totals.probe == 100, "the remainder re-offered at once, in this same batch")
	end)
end)

t.case("lanes: a partner's status alone doesn't wake the walk; a state change does", function(ctx)
	local E = "0000a1e5.statewake"
	live(ctx, 1800, "d39-wake-ep", { wake_conn("a1", 1) }, 3800, E)
	ctx.at(1850, function()
		local task = storage.universal_edges.scheduler.tasks["ue.poll.d39-wake"]
		ctx.expect(task ~= nil and task.rest_until ~= nil, "the shared walk has settled and rests")
		local resting_at = task.rest_until
		from_partner("d39-wake-ep", E, { k = "ep", cid = "a1", state = "ready", status = { n = 1 } })
		ctx.expect(task.rest_until == resting_at, "a status-only ep message (the same state again) wakes nothing")
		from_partner("d39-wake-ep", E, { k = "ep", cid = "a1", state = "blocked", status = { n = 1 } })
		ctx.expect(task.rest_until == nil, "a partner state change wakes the walk")
	end)
end)
