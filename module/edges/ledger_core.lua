-- The transfer ledger (SP1 spec §11), pure: stream and unique lanes, closing, and the id scheme, which only mint and
-- classify know (§11.5). No Factorio globals: the shell (lanes.lua) and ledger_sim_test.lua pass a ctx with the tick,
-- this side's boot id, the transport's hooks and the log. Nothing is kept after an ack, and nothing waits for a save
-- (D8, owner check-in 2026-09-29).
--
-- A lane is { kind = "stream" | "unique", role = "tx" | "rx", ... }. core.visit and core.receive return the messages
-- to send (each { k = ..., fields }; the shell adds edge, epoch, cid and dir), nil for none, or false for a malformed
-- message. A lane with dropped = true is finished: the shell removes it. An inbound u.offer carries a digest of its body,
-- which the destination's TypeScript adds on the way in (§11.2); Lua never hashes.
--
-- ctx = {
--   tick,                    -- game.tick
--   boot,                    -- this side's rt.boot_id: a unique capture's tag
--   can_credit,              -- the destination endpoint is ready
--   credit(payload, meta),   -- stream: delta bag → accepted bag; unique: payload, meta = { seq, trace } →
--                            --   "ok" | "busy" | "reject"; nil = the hook failed
--   commit(entry) → boolean, -- unique source: the destination has it; false = the hook failed
--   give_back(hook, x),      -- "refund" with a bag, or "restore" with an entry; the shell writes limbo if it fails
--   decode(body),            -- a unique body → payload, or nil when it can't be decoded (G5)
--   event(op, phase, level, fields),
--   count(kind),             -- a stats counter
--   trace(),                 -- a new trace id, used only while stream_trace is on
--   stream_trace,            -- D12's debug switch
-- }
local core = {}

core.BACKOFF_MIN = 300
core.BACKOFF_MAX = 3600
core.RESEND = 3600
core.CLOSE_CAP = 64
core.KEYS_PER_OFFER = 32
core.RUN_CAP = 64
-- ponytail: 2^49 - 1, not the spec's 2^53 - 1. Factorio 2.1.20's table_to_json writes odd integers above 2^52
-- inexactly, and 10^15 - 2 and 10^15 - 1 with a leading zero, which isn't JSON; every integer probed below 2^49 round
-- trips. A total that would pass this errors at capture; re-add the connector (a new cid starts at 0) if one ever does.
core.MAX_TOTAL = 562949953421311

local function whole(v)
	return type(v) == "number" and v >= 0 and v == math.floor(v) and v <= core.MAX_TOTAL
end
core.whole = whole

--- A bag from the wire: string keys and whole amounts, at most max keys. Anything else is malformed (G5).
local function valid_bag(bag, max)
	if type(bag) ~= "table" then
		return false
	end
	local n = 0
	for k, v in pairs(bag) do
		n = n + 1
		if type(k) ~= "string" or not whole(v) or (max and n > max) then
			return false
		end
	end
	return true
end
core.valid_bag = valid_bag

--- Each lane kind: new(role), visit[role](lane, ctx), receive["<role>.<k>"](lane, msg, ctx), capture, busy, pending,
--- resolve (against a final), final, zero_final and best (best-knowledge resolution).
local kinds = {}

--- A new lane. kind is "stream", "ordered" or "unique"; role is "tx" where this side sends, "rx" where it receives.
function core.new(kind, role)
	local lane = kinds[kind].new(role)
	lane.kind, lane.role = kind, role
	return lane
end

-- Stream lanes (§11.3) ------------------------------------------------------------------------------------------------

local function mark(lane, k)
	if not lane.pending[k] then
		lane.pending[k] = true
		lane.npending = lane.npending + 1
	end
end

local function unmark(lane, k)
	if lane.pending[k] then
		lane.pending[k] = nil
		lane.npending = lane.npending - 1
	end
end

--- Refund sent − recv per key, where recv is the destination's final recv, or acked for best knowledge.
local function refund(lane, recv, ctx)
	local bag, any = {}, false
	for k, v in pairs(lane.sent) do
		local r = type(recv[k]) == "number" and recv[k] or 0
		if v > r then
			bag[k], any = v - r, true
		end
	end
	if any then
		ctx.give_back("refund", bag)
	end
	return bag
end

--- Step 4, stream and ordered: acked is assigned, so a destination rollback can lower it. A key stays pending while
--- sent > acked; acked > sent means this source rolled back, logged once per activation. max: the keys an ack may carry.
local function ack(lane, msg, ctx, max)
	if not valid_bag(msg.totals, max) then
		return false
	end
	if lane.closing then
		return nil
	end
	local progress = false
	for k, v in pairs(msg.totals) do
		if v > (lane.acked[k] or 0) then
			progress = true
		end
		lane.acked[k] = v
		local sent = lane.sent[k] or 0
		if v > sent and not lane.absorbing then
			lane.absorbing = true
			ctx.event("ue.lane", "absorbing", "warn", { key = k, sent = sent, acked = v })
		end
		if sent > v then
			mark(lane, k)
		else
			unmark(lane, k)
		end
	end
	if progress then
		lane.backoff, lane.next_send = core.BACKOFF_MIN, 0
	end
	if msg.trace then
		ctx.event("ue.transfer", "ack", "info", { trace = msg.trace, totals = msg.totals })
	end
	return nil
end

kinds.stream = {
	new = function(role)
		if role == "tx" then
			return { sent = {}, acked = {}, pending = {}, npending = 0, next_send = 0, backoff = core.BACKOFF_MIN }
		end
		return { recv = {} }
	end,

	--- ep:send (step 1): sent += bag, and its keys are pending. A bad bag changes nothing and errors (T1).
	capture = function(lane, bag)
		if type(bag) ~= "table" then
			error("a stream send needs a bag")
		end
		for k, v in pairs(bag) do
			if type(k) ~= "string" or not whole(v) then
				error("a stream bag holds whole amounts from 0 to " .. core.MAX_TOTAL .. " under string keys")
			end
			if (lane.sent[k] or 0) + v > core.MAX_TOTAL then
				error("the stream total of " .. k .. " would pass " .. core.MAX_TOTAL)
			end
		end
		for k, v in pairs(bag) do
			if v > 0 then
				lane.sent[k] = (lane.sent[k] or 0) + v
				mark(lane, k)
			end
		end
	end,

	busy = function()
		return false
	end,

	idle = function(lane, tick)
		return lane.role == "rx" or lane.npending == 0 or tick < lane.next_send
	end,

	pending = function(lane)
		local bag = {}
		for k in pairs(lane.pending) do
			bag[k] = math.max(0, lane.sent[k] - (lane.acked[k] or 0))
		end
		return bag
	end,

	visit = {
		--- Step 2: every pending key's total, 32 keys to an s.offer, then the backoff doubles.
		tx = function(lane, ctx)
			if lane.npending == 0 or ctx.tick < lane.next_send then
				return nil
			end
			local msgs, totals, n = {}, {}, 0
			for k in pairs(lane.pending) do
				if n == core.KEYS_PER_OFFER then
					msgs[#msgs + 1] = { k = "s.offer", totals = totals }
					totals, n = {}, 0
				end
				totals[k] = lane.sent[k]
				n = n + 1
			end
			msgs[#msgs + 1] = { k = "s.offer", totals = totals }
			lane.next_send = ctx.tick + lane.backoff
			lane.backoff = math.min(lane.backoff * 2, core.BACKOFF_MAX)
			if ctx.stream_trace then
				for _, m in ipairs(msgs) do
					m.trace = ctx.trace()
					ctx.event("ue.transfer", "offer", "info", { trace = m.trace, totals = m.totals })
				end
			end
			return msgs
		end,
		rx = function()
			return nil
		end,
	},

	receive = {
		--- Step 3: credit each positive delta, record what the transport accepted (clamped to the delta), and ack recv
		--- for every offered key. A closing or unready destination credits nothing but still acks.
		["rx.s.offer"] = function(lane, msg, ctx)
			if not valid_bag(msg.totals, core.KEYS_PER_OFFER) then
				return false
			end
			local deltas, any = {}, false
			if ctx.can_credit and not lane.closing then
				for k, total in pairs(msg.totals) do
					local d = total - (lane.recv[k] or 0)
					if d > 0 then
						deltas[k], any = d, true
					end
				end
			end
			if any then
				local accepted, credited = ctx.credit(deltas), {}
				if type(accepted) == "table" then
					for k, d in pairs(deltas) do
						local a = accepted[k]
						if type(a) == "number" and a >= 1 then
							a = math.min(math.floor(a), d)
							lane.recv[k] = (lane.recv[k] or 0) + a
							credited[k] = a
						end
					end
				end
				if msg.trace then
					ctx.event("ue.transfer", "credit", "info", { trace = msg.trace, accepted = credited })
				end
			end
			local totals = {}
			for k in pairs(msg.totals) do
				totals[k] = lane.recv[k] or 0
			end
			return { { k = "s.ack", totals = totals, trace = msg.trace } }
		end,

		["tx.s.ack"] = function(lane, msg, ctx)
			return ack(lane, msg, ctx, core.KEYS_PER_OFFER)
		end,
	},

	--- §11.7 step 3: refund sent − the destination's final recv.
	resolve = function(lane, f, ctx)
		if not valid_bag(f.recv) then
			return nil
		end
		return { refunded = refund(lane, f.recv, ctx) }
	end,

	final = function(lane)
		return { k = "s.final", recv = lane.recv }
	end,

	zero_final = function()
		return { k = "s.final", recv = {} }
	end,

	best = function(lane, ctx)
		refund(lane, lane.acked, ctx)
	end,
}

-- Ordered lanes (SP3 spec §7.3, D31) -----------------------------------------------------------------------------------
-- Stream conservation, plus order. The source keeps runs, a FIFO of { k, n, e } (e = sent[k] at the run's end) since the
-- last ack, and every o.offer carries them all. The destination credits each run's part above recv[k], in order, so a
-- late, repeated or reordered offer only re-covers what it has; a start above recv[k] (only after a destination
-- restore) is credited at that run's place, out of order but exact. Acks, finals and refunds are stream's.

--- A run list: an array of at most RUN_CAP runs, { key, whole n } from a transport, or { key, n, e ≥ n } off the wire.
local function valid_runs(runs, wire)
	if type(runs) ~= "table" or #runs > core.RUN_CAP then
		return false
	end
	local n = 0
	for _ in pairs(runs) do
		n = n + 1
	end
	if n ~= #runs then
		return false
	end
	for _, r in ipairs(runs) do
		if type(r) ~= "table" or type(r[1]) ~= "string" or not whole(r[2])
			or (wire and not (whole(r[3]) and r[3] >= r[2])) then
			return false
		end
	end
	return true
end

kinds.ordered = {
	new = function(role)
		local lane = kinds.stream.new(role)
		if role == "tx" then
			lane.runs = {}
		end
		return lane
	end,

	--- ep:send: sent += each run, in order; a run whose key repeats the last run's extends it. A bad list, a total past
	--- MAX_TOTAL, or more than RUN_CAP unacknowledged runs changes nothing and errors (T1).
	capture = function(lane, runs)
		if not valid_runs(runs, false) then
			error("an ordered send needs an array of at most " .. core.RUN_CAP .. " runs { key, whole amount }")
		end
		local add, count = {}, #lane.runs
		local last = lane.runs[count] and lane.runs[count][1]
		for _, r in ipairs(runs) do
			local k, n = r[1], r[2]
			if n > 0 then
				add[k] = (add[k] or 0) + n
				if (lane.sent[k] or 0) + add[k] > core.MAX_TOTAL then
					error("the stream total of " .. k .. " would pass " .. core.MAX_TOTAL)
				end
				if k ~= last then
					count, last = count + 1, k
				end
			end
		end
		if count > core.RUN_CAP then
			error("an ordered lane holds at most " .. core.RUN_CAP .. " unacknowledged runs: check ep:runs first")
		end
		for _, r in ipairs(runs) do
			local k, n = r[1], r[2]
			if n > 0 then
				local e = (lane.sent[k] or 0) + n
				lane.sent[k] = e
				mark(lane, k)
				local tail = lane.runs[#lane.runs]
				if tail and tail[1] == k then
					tail[2], tail[3] = tail[2] + n, e
				else
					lane.runs[#lane.runs + 1] = { k, n, e }
				end
			end
		end
	end,

	busy = kinds.stream.busy,
	idle = kinds.stream.idle,
	pending = kinds.stream.pending,

	visit = {
		--- Every run since the last ack, then each pending key with no run left (after an activation, or an ack that
		--- went down) as a zero-length run { k, 0, sent[k] }: RUN_CAP runs to an o.offer. Then the backoff doubles.
		--- perf item 3: only the tail run is copied — a later capture extends it in place, but every other run, once
		--- offered, stays immutable (an ack only re-slots lane.runs itself, it never edits a run table), so sharing
		--- them costs nothing. list becomes the one offer's own runs directly when it holds RUN_CAP or fewer.
		tx = function(lane, ctx)
			if lane.npending == 0 or ctx.tick < lane.next_send then
				return nil
			end
			local list, seen, n = {}, {}, #lane.runs
			for i, r in ipairs(lane.runs) do
				list[i] = i == n and { r[1], r[2], r[3] } or r
				seen[r[1]] = true
			end
			for k in pairs(lane.pending) do
				if not seen[k] then
					list[#list + 1] = { k, 0, lane.sent[k] }
				end
			end
			local msgs
			if #list <= core.RUN_CAP then
				msgs = { { k = "o.offer", runs = list } }
			else
				msgs = {}
				for i = 1, #list, core.RUN_CAP do
					msgs[#msgs + 1] = { k = "o.offer", runs = { table.unpack(list, i, math.min(i + core.RUN_CAP - 1, #list)) } }
				end
			end
			lane.next_send = ctx.tick + lane.backoff
			lane.backoff = math.min(lane.backoff * 2, core.BACKOFF_MAX)
			if ctx.stream_trace then
				for _, m in ipairs(msgs) do
					m.trace = ctx.trace()
					ctx.event("ue.transfer", "offer", "info", { trace = m.trace, runs = #m.runs })
				end
			end
			return msgs
		end,
		rx = function()
			return nil
		end,
	},

	receive = {
		--- Each run's part above recv[k], in order, as one list; the transport accepts a prefix of it (a number of
		--- items from its front). A closing or unready destination credits nothing but still acks, as stream.
		["rx.o.offer"] = function(lane, msg, ctx)
			if not valid_runs(msg.runs, true) then
				return false
			end
			local list, cur, total = {}, {}, 0
			for _, r in ipairs(msg.runs) do
				local k, e = r[1], r[3]
				local c = cur[k] or lane.recv[k] or 0
				if e > c then
					list[#list + 1] = { k, e - c }
					total = total + e - c
					cur[k] = e
				end
			end
			if total > 0 and ctx.can_credit and not lane.closing then
				local a = ctx.credit(list)
				a = type(a) == "number" and math.max(0, math.min(math.floor(a), total)) or 0
				local credited = {}
				for _, x in ipairs(list) do
					if a == 0 then
						break
					end
					local take = math.min(x[2], a)
					lane.recv[x[1]] = (lane.recv[x[1]] or 0) + take
					credited[x[1]] = (credited[x[1]] or 0) + take
					a = a - take
				end
				if msg.trace then
					ctx.event("ue.transfer", "credit", "info", { trace = msg.trace, accepted = credited })
				end
			end
			local totals = {}
			for _, r in ipairs(msg.runs) do
				totals[r[1]] = lane.recv[r[1]] or 0
			end
			return { { k = "s.ack", totals = totals, trace = msg.trace } }
		end,

		--- Stream's ack, for up to RUN_CAP keys; then the front runs it covers are dropped.
		["tx.s.ack"] = function(lane, msg, ctx)
			if ack(lane, msg, ctx, core.RUN_CAP) == false then
				return false
			end
			local runs, drop = lane.runs, 0
			while runs[drop + 1] and runs[drop + 1][3] <= (lane.acked[runs[drop + 1][1]] or 0) do
				drop = drop + 1
			end
			if drop > 0 then
				for i = 1, #runs do
					runs[i] = runs[i + drop]
				end
			end
			return nil
		end,
	},

	resolve = kinds.stream.resolve,
	final = kinds.stream.final,
	zero_final = kinds.stream.zero_final,
	best = kinds.stream.best,
}

-- Closing (§11.7) and the engine ----------------------------------------------------------------------------------------

--- The endpoint closed (a removed connector or a tombstone): no more captures, and a destination freezes.
function core.close(lane, rev, tick)
	if lane.closing then
		return false
	end
	lane.closing = { since_tick = tick, rev = rev, next_send = 0 }
	return true
end

--- On the endpoint's first visit after an activation (§11.2): a stream source re-offers every key it ever sent, a
--- unique source re-sends at once, and a closing lane sends its close or its final at once.
function core.activate(lane)
	if lane.closing then
		lane.closing.next_send = 0
	elseif lane.role == "tx" then
		lane.backoff, lane.next_send, lane.absorbing = core.BACKOFF_MIN, 0, nil
		if lane.kind ~= "unique" then
			for k, v in pairs(lane.sent) do
				if v > 0 then
					mark(lane, k)
				end
			end
		end
	end
end

--- True when a visit at tick would send nothing, so the shell skips it without building a ctx (§12 rule 4).
function core.idle(lane, tick)
	local c = lane.closing
	if c then
		return tick < c.next_send
	end
	return kinds[lane.kind].idle(lane, tick)
end

--- One visit of an active side: what is due. A closing source re-sends close, and a closing destination its final,
--- at once and then every 3600 ticks (§11.7 steps 2 and 5).
function core.visit(lane, ctx)
	local c = lane.closing
	if not c then
		return kinds[lane.kind].visit[lane.role](lane, ctx)
	end
	if ctx.tick < c.next_send then
		return nil
	end
	c.next_send = ctx.tick + core.RESEND
	if lane.role == "tx" then
		return { { k = "close", rev = c.rev, kind = lane.kind } }
	end
	return { kinds[lane.kind].final(lane) }
end

--- A closing source resolves against a final (step 3), sends done and is dropped.
local function resolve(lane, f, ctx)
	local counts = kinds[lane.kind].resolve(lane, f, ctx)
	if not counts then
		return false
	end
	ctx.event("ue.lane", "closed", "info", counts)
	lane.dropped = true
	return { { k = "done" } }
end

--- One inbound message for this lane.
function core.receive(lane, msg, ctx)
	local k = msg.k
	if k == "close" then
		if lane.role == "rx" and lane.closing then
			return { kinds[lane.kind].final(lane) }
		end
		return nil -- a live destination closes when it applies the removal itself
	elseif k == "s.final" or k == "u.final" then
		if lane.role ~= "tx" then
			return false
		end
		if not lane.closing then
			ctx.count("finals_ignored")
			return nil -- step 3: a live source ignores a final, and closes when it applies the removal
		end
		return resolve(lane, msg, ctx)
	elseif k == "done" then
		if lane.role == "rx" and lane.closing then
			lane.dropped = true
		end
		return nil
	end
	local fn = kinds[lane.kind].receive[lane.role .. "." .. k]
	if not fn then
		return false
	end
	return fn(lane, msg, ctx)
end

--- What a destination without the lane answers a close with (§11.7 step 6): a zero-state final once its side has
--- applied the removal (revision ≥ rev), since it never had the lane; nothing while it hasn't.
function core.unknown_close(msg, revision)
	if not (whole(msg.rev) and kinds[msg.kind]) or revision < msg.rev then
		return nil
	end
	return { kinds[msg.kind].zero_final() }
end

--- What a source without the lane answers a final with: done. It resolved already, or never had it (step 6).
function core.unknown_final()
	return { { k = "done" } }
end

--- The unresolved closing source lanes of one side beyond the cap of 64, oldest first (§11.7 step 7). entries are
--- { key, lane }; the result lists the ones to force-resolve.
function core.over_cap(entries)
	if #entries <= core.CLOSE_CAP then
		return {}
	end
	table.sort(entries, function(x, y)
		local tx, ty = x.lane.closing.since_tick, y.lane.closing.since_tick
		if tx ~= ty then
			return tx < ty
		end
		return x.key < y.key
	end)
	local out = {}
	for i = 1, #entries - core.CLOSE_CAP do
		out[i] = entries[i]
	end
	return out
end

--- Best knowledge (§11.7 steps 7–9): a stream source refunds sent − acked, a unique source restores its in-flight
--- entry, and a destination keeps nothing. The lane is dropped.
function core.force(lane, ctx)
	if lane.role == "tx" and not lane.dropped then
		kinds[lane.kind].best(lane, ctx)
	end
	lane.dropped = true
end

--- ep:can_send's ledger half: the lane isn't closing, and a unique lane has nothing in flight.
function core.can_send(lane)
	return not lane.closing and not kinds[lane.kind].busy(lane)
end

--- ep:send, a capture: a stream bag, or a unique lane's encoded body with its trace (returns the seq).
function core.capture(lane, x, trace, ctx)
	if lane.closing then
		error("a closing lane takes no captures")
	end
	return kinds[lane.kind].capture(lane, x, trace, ctx)
end

--- ep:pending: a stream's unacknowledged bag, or a unique lane's in-flight seq.
function core.pending(lane)
	return kinds[lane.kind].pending(lane)
end

--- ep:nudge: a lane with keys pending re-offers at its next visit, its backoff back to the minimum; nothing otherwise.
--- The balance types call it when the partner's status shows room for a remainder it refused (final fix wave addendum).
function core.nudge(lane)
	if (lane.npending or 0) > 0 then
		lane.backoff, lane.next_send = core.BACKOFF_MIN, 0
	end
end

--- ep:runs (F11): an ordered lane's unacknowledged runs; 0 for any other kind.
function core.runs(lane)
	return lane.runs and #lane.runs or 0
end

-- Unique lanes (§11.4, §11.5) -----------------------------------------------------------------------------------------

core.RING = 32

--- The id scheme's source half (§11.5): the lane's next seq, tagged with the capture boot.
function core.mint(lane, boot)
	local seq = lane.next_seq
	lane.next_seq = seq + 1
	return seq, boot
end

--- The id scheme's destination half (§11.5): "new", "repeat", "divergent" or "gap", with the ring slot for seq when it
--- still holds that seq.
function core.classify(lane, seq, tag, digest)
	if seq > lane.w + 1 then
		return "gap"
	end
	if seq == lane.w + 1 then
		return "new"
	end
	local slot = lane.ring[seq % core.RING]
	if slot and slot.seq ~= seq then
		slot = nil
	end
	if tag == lane.tag or (slot and slot.digest == digest) then
		return "repeat", slot
	end
	return "divergent", slot
end

--- Step 3 at the destination. A closing destination answers busy without classifying; w is never lowered.
local function offer_outcome(lane, o, ctx)
	if lane.closing then
		return "busy"
	end
	local class, slot = core.classify(lane, o.seq, o.tag, o.digest)
	if class == "gap" then
		return "gap"
	end
	if class == "repeat" then
		ctx.event("ue.transfer", "repeat", "verbose", { seq = o.seq, trace = o.trace })
		return (slot and slot.outcome == "reject") and "reject" or "repeat"
	end
	if not ctx.can_credit then
		return "busy"
	end
	local payload = ctx.decode(o.body)
	local result = "reject" -- G5: a body that can't be decoded is refused without calling credit
	if payload ~= nil then
		result = ctx.credit(payload, { seq = o.seq, trace = o.trace }) -- F1
	end
	if result ~= "ok" and result ~= "reject" then
		ctx.event("ue.transfer", "busy", "verbose", { seq = o.seq, trace = o.trace })
		return "busy" -- busy, or a failed hook (G6): nothing changes
	end
	lane.ring[o.seq % core.RING] = { seq = o.seq, digest = o.digest, outcome = result == "ok" and "credited" or "reject" }
	if class == "new" then
		lane.w, lane.tag = o.seq, o.tag
	end
	if result == "reject" then
		return "reject"
	end
	if class == "divergent" then
		ctx.event("ue.transfer", "divergent", "warn", { seq = o.seq, trace = o.trace, digest = o.digest })
		return "divergent"
	end
	ctx.event("ue.transfer", "credit", "info", { seq = o.seq, trace = o.trace })
	return "credited"
end

local OUTCOMES = { credited = true, ["repeat"] = true, divergent = true, busy = true, reject = true, gap = true }

kinds.unique = {
	new = function(role)
		if role == "tx" then
			return { next_seq = 1, next_send = 0, backoff = core.BACKOFF_MIN }
		end
		return { w = 0, ring = {} }
	end,

	--- Step 1: mint, keep the encoded body in flight, and offer it at the next visit. The caller checked can_send.
	capture = function(lane, body, trace, ctx)
		if lane.inflight then
			error("a unique lane takes one capture at a time: check ep:can_send first")
		end
		local seq, tag = core.mint(lane, ctx.boot)
		lane.inflight = { seq = seq, tag = tag, body = body, trace = trace }
		lane.backoff, lane.next_send = core.BACKOFF_MIN, 0
		return seq
	end,

	busy = function(lane)
		return lane.inflight ~= nil
	end,

	idle = function(lane, tick)
		return lane.role == "rx" or lane.inflight == nil or tick < lane.next_send
	end,

	pending = function(lane)
		return lane.inflight and lane.inflight.seq
	end,

	visit = {
		--- Step 5: the in-flight offer, re-sent every backoff.
		tx = function(lane, ctx)
			local e = lane.inflight
			if not e or ctx.tick < lane.next_send then
				return nil
			end
			lane.next_send = ctx.tick + lane.backoff
			lane.backoff = math.min(lane.backoff * 2, core.BACKOFF_MAX)
			return { { k = "u.offer", seq = e.seq, tag = e.tag, trace = e.trace, body = e.body } }
		end,
		rx = function()
			return nil
		end,
	},

	receive = {
		["rx.u.offer"] = function(lane, msg, ctx)
			if not (whole(msg.seq) and msg.seq >= 1 and type(msg.tag) == "string" and type(msg.body) == "string"
				and type(msg.digest) == "string" and (msg.trace == nil or type(msg.trace) == "string")) then
				return false
			end
			local outcome = offer_outcome(lane, msg, ctx)
			return { { k = "u.reply", seq = msg.seq, outcome = outcome, w = lane.w, trace = msg.trace } }
		end,

		--- Step 4, gap: the destination no longer has (w, to], and the source can't offer it again. w = max(w, to).
		["rx.u.skip"] = function(lane, msg, ctx)
			if not whole(msg.to) then
				return false
			end
			if msg.to > lane.w then
				ctx.event("ue.transfer", "lost", "error", { from = lane.w + 1, to = msg.to })
				lane.w = msg.to
			end
			return nil
		end,

		--- Step 4 at the source. Only the in-flight seq's reply counts, and a closing source ignores every reply.
		["tx.u.reply"] = function(lane, msg, ctx)
			if not (whole(msg.seq) and OUTCOMES[msg.outcome] and whole(msg.w)) then
				return false
			end
			local e = lane.inflight
			if lane.closing or not e or msg.seq ~= e.seq then
				ctx.count("stale_replies")
				return nil
			end
			local o = msg.outcome
			if o == "busy" then
				ctx.event("ue.transfer", "busy", "verbose", { seq = e.seq, trace = e.trace })
				return nil
			end
			if o == "gap" then
				lane.backoff, lane.next_send = core.BACKOFF_MIN, 0
				return { { k = "u.skip", to = e.seq - 1 } }
			end
			if o == "reject" then
				ctx.event("ue.transfer", "restore", "warn", { seq = e.seq, trace = e.trace })
				ctx.give_back("restore", e)
			elseif ctx.commit(e) then
				ctx.event("ue.transfer", "ack", "info", { seq = e.seq, trace = e.trace, outcome = o })
			else
				return nil -- G6: the commit hook failed, so the entry stays in flight
			end
			lane.inflight = nil -- the body is dropped (D8)
			lane.backoff, lane.next_send = core.BACKOFF_MIN, 0
			return nil
		end,
	},

	--- §11.7 step 3: commit when the destination has exactly this capture, otherwise restore. `rejected` means the
	--- final's w was answered reject, so a same-tag entry at w was refused, not taken (planning ruling).
	resolve = function(lane, f, ctx)
		if not (whole(f.w) and (f.tag == nil or type(f.tag) == "string")) then
			return nil
		end
		local e, outcome = lane.inflight, "none"
		if e then
			if e.seq <= f.w and e.tag == f.tag and not (f.rejected == true and e.seq == f.w) then
				ctx.commit(e)
				outcome = "committed"
			else
				ctx.give_back("restore", e)
				outcome = "restored"
			end
			lane.inflight = nil
		end
		return { w = f.w, seq = e and e.seq, outcome = outcome }
	end,

	final = function(lane)
		local slot = lane.ring[lane.w % core.RING]
		local rejected = slot ~= nil and slot.seq == lane.w and slot.outcome == "reject"
		return { k = "u.final", w = lane.w, tag = lane.tag, rejected = rejected or nil }
	end,

	zero_final = function()
		return { k = "u.final", w = 0 }
	end,

	best = function(lane, ctx)
		if lane.inflight then
			ctx.give_back("restore", lane.inflight)
			lane.inflight = nil
		end
	end,
}

return core
