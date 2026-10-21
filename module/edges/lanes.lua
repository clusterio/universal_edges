-- The endpoints' lifecycle and their wire (SP1 spec §10–§11): ue.lane in and out, chunking, the activation handshakes,
-- closing, the applied reports' open counts, and the ue.transfer and ue.lane trace events. The ledger's rules live in
-- ledger_core; the transports' hooks run through connectors.call.
local bridge = require("modules/universal_edges/runtime/bridge")
local bridge_core = require("modules/universal_edges/runtime/bridge_core")
local trace = require("modules/universal_edges/runtime/trace")
local connectors = require("modules/universal_edges/edges/connectors")
local core = require("modules/universal_edges/edges/ledger_core")
local edge_core = require("modules/universal_edges/edges/edge_core")

local lanes = { CHUNK = 3000, MAX_BODY = 65536, RESEND = 3600 }
local send = bridge.channel("universal_edges")
local methods = connectors.methods

local function count(kind)
	local stats = storage.universal_edges.stats
	stats["ue.lanes"] = stats["ue.lanes"] or {}
	bridge_core.count(stats["ue.lanes"], kind)
end

local function emit(ep, dir, op, phase, level, fields)
	fields.op, fields.phase, fields.level, fields.tick = op, phase, level, game.tick
	fields.edge, fields.cid, fields.dir = ep.edge, ep.cid, dir
	fields.trace = fields.trace or ep.trace
	send("trace", fields)
end

--- Is dir this side's outbound lane? Side a sends on ab.
local function outbound(side, dir)
	return (dir == "ab") == (side.me == "a")
end

local function each_endpoint(side, fn)
	for cid in pairs(side.eps) do
		local ep = connectors.get(side, cid)
		if ep then
			fn(ep)
		end
	end
end

-- The wire out ---------------------------------------------------------------------------------------------------------

--- Send lane messages for (cid, dir) of an active side. A body over 3000 bytes — a unique offer's, or a big status's
--- (FC3, circuit-link spec §5.2) — leaves as ue.chunk parts keyed <edge>/<cid>/<dir or k>/<seq>, then the message with
--- chunks = n, so no message reaches Clusterio's ≥ 4000-byte file path (§11.2). An ep message has no dir, hence k.
local function send_all(side, cid, dir, msgs)
	for _, m in ipairs(msgs or {}) do
		m.edge, m.epoch, m.cid, m.dir = side.id, side.epoch, cid, dir
		if m.body and #m.body > lanes.CHUNK then
			local n = math.ceil(#m.body / lanes.CHUNK)
			local key = side.id .. "/" .. cid .. "/" .. (dir or m.k) .. "/" .. m.seq
			for i = 1, n do
				send("ue.chunk", { key = key, i = i, n = n, data = string.sub(m.body, (i - 1) * lanes.CHUNK + 1, i * lanes.CHUNK) })
			end
			m.body, m.chunks = nil, n
		end
		send("ue.lane", m)
	end
end

--- Our ep message: state, status, and ask = true to have the partner's ep back (§11.2). full (FC5, circuit-link spec
--- §5.2): a type's full_status instead of ep.status — computed before the state is read, so a hook that raises announces
--- failed (G6) with ep.status. FC3: a big_status type's status whose JSON is over 3000 bytes leaves as a body in parts,
--- keyed by the endpoint's own count of chunked sends (one key per send: reassembly merges parts by key; a full is sent
--- without set_status, so set_status can't count them); at or under it, the status rides as a table, as before, because
--- lanes.ts parses only reassembled bodies.
local function announce(ep, side, ask, full)
	local t = connectors.types[ep.type]
	local status = ep.status
	if full and t.full_status then
		local ok, result = connectors.call(ep, "full_status")
		if ok then
			status = result
		end
	end
	local m = { k = "ep", state = ep.closing and "closing" or ep.state, status = status, ask = ask or nil }
	if status ~= nil and t.big_status then
		local json = helpers.table_to_json(status)
		if #json > lanes.CHUNK then
			ep.chunk_seq = (ep.chunk_seq or 0) + 1
			m.status, m.body, m.seq = nil, json, ep.chunk_seq
		end
	end
	send_all(side, ep.cid, nil, { m })
	ep.announce, ep.status_dirty = nil, nil
end

-- The ledger's ctx -----------------------------------------------------------------------------------------------------

local function decode(body)
	local json = type(body) == "string" and helpers.decode_string(body)
	return json and helpers.json_to_table(json)
end

--- Refund a bag or restore a unique entry through the transport; a failure writes a limbo file (G6).
local function give_back(ep, dir, hook, x)
	local ok, placed
	if hook == "refund" then
		ok, placed = connectors.call(ep, "refund", dir, x)
	else
		local payload = decode(x.body)
		if payload ~= nil then
			ok, placed = connectors.call(ep, "restore", dir, x.seq, payload)
		end
	end
	if not (ok and placed) then
		local file = connectors.limbo(ep, dir, hook, hook == "refund" and x or x.body, x.trace)
		emit(ep, dir, "ue.transfer", "unplaceable", "error", { hook = hook, seq = x.seq, trace = x.trace, file = file })
	end
end

-- perf item 4: one ctx per (ep, dir), kept here and reused; only its hot fields change call to call. Weak-keyed on ep
-- (an ephemeron table, Lua 5.2+) so a removed endpoint's cached ctxs — closures and all, even though each closure's
-- own upvalue is ep itself — die with it rather than lingering forever. Re-entry on the same (ep, dir) mid-use would
-- corrupt a still-in-use ctx's fields; none does (checked again for SP3b's train.lua: credit, commit and restore
-- never themselves receive on or visit a lane, and the vehicle corner hop captures in the watch task, not a credit).
local ctx_cache = setmetatable({}, { __mode = "k" })

--- The ctx ledger_core runs with, for one lane of ep (see ledger_core.lua). The closures are built once per (ep, dir)
--- and reused; tick, boot, can_credit and stream_trace are refreshed on every call, so a cached ctx reads the same as
--- a fresh one would. Built only when a message arrives or a visit has something due, so an idle visit allocates
--- nothing (§12 rule 4).
local function ctx_for(ep, dir)
	local by = ctx_cache[ep]
	local ctx = by and by[dir]
	if not ctx then
		ctx = {
			credit = function(payload, meta)
				local ok, result = connectors.call(ep, "credit", dir, payload, meta)
				return ok and result or nil
			end,
			commit = function(e) -- the hook gets the crossing's trace too, for its riders' lines (§9, final review M2)
				return (connectors.call(ep, "commit", dir, e.seq, e.trace))
			end,
			give_back = function(hook, x)
				give_back(ep, dir, hook, x)
			end,
			decode = decode,
			event = function(op, phase, level, fields)
				emit(ep, dir, op, phase, level, fields)
			end,
			count = count,
			trace = trace.new_id,
		}
		by = by or {}
		by[dir] = ctx
		ctx_cache[ep] = by
	end
	local s = storage.universal_edges
	ctx.tick, ctx.boot = game.tick, s.rt.boot_id
	ctx.can_credit, ctx.stream_trace = ep.state == "ready" and not ep.closing, s.stream_trace == true
	return ctx
end

-- Endpoints: create, close, remove, report ------------------------------------------------------------------------------

--- How many of the side's lanes are closing and not yet dropped: the applied report's open (§5.2).
function lanes.open(side)
	local n = 0
	each_endpoint(side, function(ep)
		if ep.closing then
			for _ in pairs(ep.tx) do
				n = n + 1
			end
			for _ in pairs(ep.rx) do
				n = n + 1
			end
		end
	end)
	return n
end

--- The side's applied report (§6.2), with its open count. It goes out after every apply and whenever open changes.
function lanes.report(side, sync)
	send("ue.edge.applied", { id = side.id, revision = side.revision, open = lanes.open(side), sync = sync,
		trace = side.trace })
end

--- A closing endpoint whose lanes are all dropped is removed, and the side reports its lower open count.
local function finish(ep, side)
	if ep.closing and next(ep.tx) == nil and next(ep.rx) == nil then
		connectors.remove(ep, side)
		return true
	end
	return false
end

local due = {} -- sides whose open count changed in the current inbox batch; empty between batches (F8)

--- Remove the lane if the ledger dropped it; a destination's drop (on done) is its closed event.
local function settle_lane(ep, side, dir, lane)
	if not lane.dropped then
		return
	end
	if lane.role == "rx" then
		emit(ep, dir, "ue.lane", "closed", "info", { role = "rx" })
	end
	ep.tx[dir], ep.rx[dir] = nil, nil
	if finish(ep, side) or ep.closing then
		due[side.id] = true
	end
end

local function create(side, c)
	local ep = connectors.create(side, c)
	if not ep then
		return
	end
	for dir, kind in pairs(ep.dirs) do
		if outbound(side, dir) then
			ep.tx[dir] = core.new(kind, "tx")
		else
			ep.rx[dir] = core.new(kind, "rx")
		end
	end
	ep.hs = side.active or nil
end

--- The endpoint closes (§11.7 step 1): teardown runs once, and each lane freezes and starts its closing handshake.
local function close(ep, side)
	if ep.closing then
		return
	end
	ep.closing = true
	connectors.teardown(ep)
	for dir, lane in pairs(ep.tx) do
		core.close(lane, side.revision, game.tick)
		emit(ep, dir, "ue.lane", "closing", "info", { role = "tx", rev = side.revision })
	end
	for dir, lane in pairs(ep.rx) do
		core.close(lane, side.revision, game.tick)
		emit(ep, dir, "ue.lane", "closing", "info", { role = "rx", rev = side.revision })
	end
	finish(ep, side)
end

--- Resolve every lane of ep with best knowledge (§11.7 steps 7–9), logged at error, and drop them.
local function force(ep, reason)
	for _, set in ipairs({ ep.tx, ep.rx }) do
		for dir, lane in pairs(set) do
			core.force(lane, ctx_for(ep, dir))
			emit(ep, dir, "ue.lane", "close_forced", "error", { role = lane.role, reason = reason })
			set[dir] = nil
		end
	end
end

--- §11.7 step 7: past 64 unresolved closing source lanes on a side, the oldest are forced.
local function cap(side)
	local entries = {}
	each_endpoint(side, function(ep)
		if ep.closing then
			for dir, lane in pairs(ep.tx) do
				entries[#entries + 1] = { key = ep.key .. "/" .. dir, lane = lane, ep = ep, dir = dir }
			end
		end
	end)
	for _, e in ipairs(core.over_cap(entries)) do
		core.force(e.lane, ctx_for(e.ep, e.dir))
		emit(e.ep, e.dir, "ue.lane", "close_forced", "error", { role = "tx", reason = "cap" })
		e.ep.tx[e.dir] = nil
		finish(e.ep, side)
	end
end

--- Bring the side's endpoints in line with its connectors (§5.2, §5.4), after the side applied a record: new connectors
--- get PENDING endpoints, a failed endpoint is retried (G6's reconfiguration), and endpoints whose connector left the
--- record, or all of a shell's, close. `gone` (the partner instance was deleted or is missing) forces them at once.
function lanes.reconcile(side, gone)
	if not side.deleted then
		for cid, c in pairs(side.connectors) do
			local ep = connectors.get(side, cid)
			if not ep then
				create(side, c)
			elseif ep.state == "failed" and not ep.closing then
				ep.state = "pending"
			end
		end
		-- F7: the built-in endpoints (a type registered with builtin = <cid>), on every live side and outside the
		-- controller's record (§4.2). They aren't in side.connectors, so the loop above never retries them; a failed one
		-- would otherwise stay failed for good. Types are registered at load in the same order on every peer.
		for name, t in pairs(connectors.types) do
			if t.builtin then
				local ep = connectors.get(side, t.builtin)
				if not ep then
					create(side, { cid = t.builtin, type = name, pos = 0, width = side.length, params = {} })
				elseif ep.state == "failed" and not ep.closing then
					ep.state = "pending"
				end
			end
		end
	end
	local closed = false
	each_endpoint(side, function(ep)
		if side.deleted or (not ep.builtin and not side.connectors[ep.cid]) then
			closed = closed or not ep.closing
			close(ep, side)
		end
	end)
	if gone then
		each_endpoint(side, function(ep)
			force(ep, "partner_gone")
			finish(ep, side)
		end)
	elseif closed then
		cap(side)
	end
end

--- The side is dropped: purged, absent from a sync, or replaced (§11.7 step 9). Unresolved lanes are forced.
function lanes.drop(side)
	each_endpoint(side, function(ep)
		close(ep, side)
		force(ep, "side_dropped")
		finish(ep, side)
	end)
end

--- The side became active under a new epoch (§6.2 step 4): partners are forgotten, and every endpoint does its
--- handshake on its next visit.
function lanes.activated(side)
	local waiting = 0
	each_endpoint(side, function(ep)
		ep.partner, ep.hs = nil, true
		if not ep.closing then
			ep.hs_wait = true
			waiting = waiting + 1
		end
	end)
	side.hs_wait = waiting
end

--- The side went inactive (FC4, circuit-link spec C5 b): each endpoint whose type has a deactivated hook forgets what
--- the partner gave it. Closing endpoints are skipped: their teardown already ran.
function lanes.deactivated(side)
	each_endpoint(side, function(ep)
		if not ep.closing and connectors.types[ep.type].deactivated then
			connectors.call(ep, "deactivated")
		end
	end)
end

-- Visits ---------------------------------------------------------------------------------------------------------------

--- The due messages of one set of lanes, ep.tx or ep.rx. An idle lane costs a comparison: no ctx and no table, so an
--- idle visit allocates nothing (§12 rule 4).
local function visit_lanes(ep, side, tick, set)
	for dir, lane in pairs(set) do
		if not core.idle(lane, tick) then
			send_all(side, ep.cid, dir, core.visit(lane, ctx_for(ep, dir)))
		end
	end
end

--- One visit of the type's poll task (§10.3): builds, the handshake, the transport's poll, then the lanes' sends.
function lanes.visit(ep, tick)
	local side = storage.universal_edges.edges[ep.edge]
	if not side then
		return
	end
	-- S1 (surfaces spec §11): an endpoint whose side has no surface yet isn't built; edges.on_surface_created gives it one.
	if not ep.closing and ep.frame.surface_index
		and (ep.state == "pending" or (ep.state == "blocked" and tick >= ep.next_build)) then
		connectors.build(ep, tick)
	end
	if not side.active then
		return -- an inactive side sends nothing (§11.2)
	end
	if ep.hs then
		ep.hs = nil
		for _, set in ipairs({ ep.tx, ep.rx }) do
			for _, lane in pairs(set) do
				core.activate(lane)
			end
		end
		if not ep.closing then
			announce(ep, side, ep.partner == nil, true)
			ep.next_ask = tick + lanes.RESEND
		end
	elseif not ep.closing then
		if ep.partner == nil and tick >= (ep.next_ask or 0) then
			announce(ep, side, true, true)
			ep.next_ask = tick + lanes.RESEND
		elseif ep.ask then
			ep.ask = nil
			announce(ep, side, true)
		elseif ep.announce or ep.status_dirty then
			announce(ep, side, false)
		end
	end
	local t = connectors.types[ep.type]
	-- L16 (logistic-link spec §8.1): a type with poll_independent polls without a ready partner; every other type is
	-- unchanged, since the flag defaults off.
	if not ep.closing and ep.state == "ready" and (t.poll_independent or (ep.partner and ep.partner.state == "ready"))
		-- An endpoint's place in the walk can shift earlier (registry churn), so its visit arrives a few ticks early;
		-- the strict interval check then skipped a whole period, a 63-tick gap, which broke belt spacing spec §5's
		-- "one capture spans at most one poll" (plan Task 3 ruling). At 3/4 of the interval a visit up to a quarter
		-- early still polls, so the worst gap is 1 1/4 intervals (40 ticks for belts, their stubs' length at turbo).
		-- Wakes are what this lets poll a little early (the old rule skipped a wake's extra visit).
		and (ep.last_poll == nil or tick - ep.last_poll >= t.schedule.interval * 3 / 4) then
		ep.last_poll = tick
		connectors.call(ep, "poll", tick)
	end
	if ep.status_dirty and not ep.closing then
		announce(ep, side, false) -- F13: a status the poll just set goes now; a visit later is a period stale (ruling 18)
	end
	visit_lanes(ep, side, tick, ep.tx)
	visit_lanes(ep, side, tick, ep.rx)
	if ep.closing then
		finish(ep, side)
	end
end
connectors.visit = lanes.visit

-- The wire in ----------------------------------------------------------------------------------------------------------

--- ep: the partner endpoint's state and status in this epoch (§10.2); ask means send ours back.
local function on_ep(side, msg)
	if type(msg.cid) ~= "string" or type(msg.state) ~= "string" or (msg.status ~= nil and type(msg.status) ~= "table") then
		return false
	end
	local ep = connectors.get(side, msg.cid)
	if not ep or ep.closing then
		count("unmatched")
		return true
	end
	local was = ep.partner and ep.partner.state
	ep.partner = { state = msg.state, status = msg.status }
	if was == nil or was ~= msg.state then
		-- perf item 1: only a state change (a handshake, or a partner that recovered) can free a visit to act sooner
		-- than its next scheduled one; a status-only update wakes nothing (SP1's wake rule, SP1b final review I1;
		-- SP3 spec §4.2, §17 risk 3).
		connectors.wake(ep.type)
	end
	if msg.status ~= nil and connectors.types[ep.type].on_status then
		-- FC5: folded as it arrives, in order: ep.partner keeps only the newest (circuit-link spec §8.3). The hook writes
		-- no entity (K2).
		connectors.call(ep, "on_status", msg.status)
	end
	if ep.hs_wait then
		ep.hs_wait = nil
		side.hs_wait = (side.hs_wait or 1) - 1
		if side.hs_wait == 0 then
			send("trace", { op = "ue.lane", phase = "synced", tick = game.tick, trace = side.epoch, edge = side.id,
				endpoints = lanes.count_endpoints(side) })
		end
	end
	if msg.ask then
		announce(ep, side, false, true)
	end
	return true
end

function lanes.count_endpoints(side)
	local n = 0
	each_endpoint(side, function(ep)
		if not ep.closing then
			n = n + 1
		end
	end)
	return n
end

--- One ue.lane from the partner (§11.2): only for the side's current epoch; an ep, or a message for one lane, which
--- ledger_core answers. A close or final for a lane this side doesn't have follows §11.7 step 6.
bridge.on("universal_edges", "ue.lane", function(msg)
	if type(msg.edge) ~= "string" or type(msg.epoch) ~= "string" or type(msg.k) ~= "string" then
		return false
	end
	local side = storage.universal_edges.edges[msg.edge]
	if not side then
		count("unmatched")
		return true
	end
	if not edge_core.epoch_ok(side, msg.epoch) then
		count("stale")
		return true
	end
	if msg.k == "ep" then
		return on_ep(side, msg)
	end
	if type(msg.cid) ~= "string" or (msg.dir ~= "ab" and msg.dir ~= "ba") then
		return false
	end
	local ep = connectors.get(side, msg.cid)
	local out = outbound(side, msg.dir)
	local lane = ep and (out and ep.tx or ep.rx)[msg.dir]
	local replies
	if lane then
		local ctx = ctx_for(ep, msg.dir)
		replies = core.receive(lane, msg, ctx)
		if replies == false then
			return false
		end
		settle_lane(ep, side, msg.dir, lane)
		-- perf item 1: nothing a lane message changes needs a later visit to notice (an ack's progress with keys
		-- still pending, or a unique gap reply's re-offer after its u.skip) — send it now, in this same batch,
		-- instead of waking the whole type to visit this lane again next tick.
		if not lane.dropped and not core.idle(lane, game.tick) then
			local more = core.visit(lane, ctx)
			if more then
				replies = replies or {}
				for _, m in ipairs(more) do
					replies[#replies + 1] = m
				end
			end
		end
	elseif msg.k == "close" and not out then
		replies = core.unknown_close(msg, side.revision)
	elseif (msg.k == "s.final" or msg.k == "u.final") and out then
		replies = core.unknown_final()
	else
		count("unmatched")
		return true
	end
	send_all(side, msg.cid, msg.dir, replies)
	return true
end)

-- The endpoint API's lane half (§10.2) --------------------------------------------------------------------------------

--- ep:can_send(dir): the lane is outbound here, the edge is active, both endpoints are ready, the lane isn't closing,
--- and a unique lane has nothing in flight.
function methods.can_send(ep, dir)
	local lane = ep.tx[dir]
	local side = storage.universal_edges.edges[ep.edge]
	return lane ~= nil and side ~= nil and side.active and not ep.closing and ep.state == "ready"
		and ep.partner ~= nil and ep.partner.state == "ready" and core.can_send(lane)
end

--- ep:send(dir, payload), a capture (§11.3 step 1, §11.4 step 1). Stream: a bag; ordered: an array of runs in order
--- (§7.3); both always taken, even while inactive. Unique: needs can_send (T1); a body over 65536 bytes returns nil,
--- "too_big" (F4); the offer is sent at once (F3).
function methods.send(ep, dir, payload)
	local lane = ep.tx[dir]
	if not lane then
		error("endpoint " .. ep.key .. " has no outbound lane " .. tostring(dir))
	end
	if lane.kind ~= "unique" then
		return core.capture(lane, payload)
	end
	if not methods.can_send(ep, dir) then
		error("ep:send on unique lane " .. dir .. " while ep:can_send is false")
	end
	local body = helpers.encode_string(helpers.table_to_json(payload))
	if not body or #body > lanes.MAX_BODY then
		return nil, "too_big" -- F4: a raise here would fail the whole endpoint (G6); the caller decides
	end
	local id, ctx = trace.new_id(), ctx_for(ep, dir)
	local seq = core.capture(lane, body, id, ctx)
	emit(ep, dir, "ue.transfer", "offer", "info", { seq = seq, trace = id, length = #body })
	-- F3: the offer leaves now. A capture outside the endpoint's visit (the vehicle watch) would otherwise wait for it.
	send_all(storage.universal_edges.edges[ep.edge], ep.cid, dir, core.visit(lane, ctx))
	return seq
end

--- ep:pending(dir): a stream's unacknowledged bag, or a unique lane's in-flight seq.
function methods.pending(ep, dir)
	local lane = ep.tx[dir]
	return lane and core.pending(lane)
end

--- ep:idle(dir) (F6): the outbound stream or ordered lane has nothing unacknowledged; true without one. No allocation.
function methods.idle(ep, dir)
	local lane = ep.tx[dir]
	return lane == nil or lane.npending == nil or lane.npending == 0
end

--- ep:nudge(dir): the outbound lane's unacknowledged remainder re-offers at the next visit instead of waiting out its
--- backoff; nothing when it has nothing pending (final fix wave addendum).
function methods.nudge(ep, dir)
	local lane = ep.tx[dir]
	if lane then
		core.nudge(lane)
	end
end

--- ep:runs(dir) (F11): the outbound ordered lane's unacknowledged runs (0 for other kinds), for the 64-run cap.
function methods.runs(ep, dir)
	local lane = ep.tx[dir]
	return lane and core.runs(lane) or 0
end

-- F8: the open count is re-counted once per inbox batch, not once per dropped lane (review M2: n² at an edge's close).
-- due is taken and reset before the drain runs, so an error partway through (contained by bridge.after_batch's pcall)
-- can't leave an entry stuck across batches: due is empty again the instant the drain starts, win or lose.
bridge.after_batch("universal_edges", function()
	local batch = due
	due = {}
	for id in pairs(batch) do
		local side = storage.universal_edges.edges[id]
		if side then
			lanes.report(side, false)
		end
	end
end)

return lanes
