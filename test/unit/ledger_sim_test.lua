-- The ledger's guarantees, checked over ledger_core alone (SP1 spec §11.9): fixed no-crash removal cases, a bounded
-- enumeration that mirrors docs/superpowers/specs/2026-09-28-sp1-ledger-model.mjs, and a seeded model check with a
-- lossy network. SIM_RUNS sets the seeded schedules (default 500); SIM_SEED replays one. SP3 (§7.3) adds the ordered
-- kind: its world is a sequence of typed items, and with no crash the destination credits them in capture order.
local t = require("testlib")
local core = require("modules/universal_edges/edges/ledger_core")

local function copy(v)
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in pairs(v) do
		out[k] = copy(x)
	end
	return out
end

--- A side's ctx, built once per run: S[name] is looked up on every call, because a crash replaces the side. world
--- holds items and tokens ({ [name] = true } at the source, counts at the destination). S.policy (destination only)
--- decides credits: policy.cap limits a stream credit and an ordered one's prefix, policy.outcome answers a unique one.
--- An ordered world: A holds oq (the items, in order) from ohead on, its capture log ocap and refunds orefund; B the
--- credited sequence oseq.
local function side_ctx(S, name)
	local ctx = { tick = 0, can_credit = true, stream_trace = false }
	function ctx.credit(p)
		local w, policy = S[name].world, S.policy
		if type(p[1]) == "table" then -- an ordered list: accept up to policy.cap items from its front, in order
			local room, a = policy and policy.cap or math.huge, 0
			for _, x in ipairs(p) do
				local take = math.min(x[2], room - a)
				for _ = 1, take do
					w.oseq[#w.oseq + 1] = x[1]
				end
				if x[3] and take == x[2] then -- a whole run brings its g (belt spacing spec §6)
					for j = 1, #x[3] do
						w.ogaps[#w.ogaps + 1] = x[3][j]
					end
				end
				a = a + take
			end
			return a
		end
		if p.token then
			local o = policy and policy.outcome or "ok"
			if o == "ok" then
				w.tokens[p.token] = (w.tokens[p.token] or 0) + 1
			end
			return o
		end
		local n = math.min(p.items or 0, policy and policy.cap or math.huge)
		w.items = w.items + n
		return { items = n }
	end
	function ctx.commit(e)
		local w = S[name].world
		w.tokens[e.body], w.held[e.body] = nil, nil -- hold mode: the token leaves the source only now
		return true
	end
	function ctx.give_back(hook, x)
		local w = S[name].world
		if hook == "refund" then
			for k, v in pairs(x) do
				if k == "items" then
					w.items = w.items + v
				else
					w.orefund[k] = (w.orefund[k] or 0) + v
				end
			end
		else
			w.tokens[x.body], w.held[x.body] = true, nil -- restore: unhold, or re-add from the payload
		end
	end
	function ctx.decode(body)
		return { token = body }
	end
	function ctx.event(_, phase)
		local phases = S[name].phases
		phases[phase] = (phases[phase] or 0) + 1
	end
	function ctx.count() end
	function ctx.trace()
		return "x"
	end
	return ctx
end

--- Deliver one message to side `to` for lane id l (s or u), as the destination's TypeScript would: a u.offer gains
--- the digest of its body (here the body itself: a token's name). Returns the replies; a malformed message fails.
local function deliver(to, l, msg, ctx)
	if msg.k == "u.offer" then
		msg = copy(msg)
		msg.digest = msg.body
	end
	local lane = to.lanes[l]
	local replies
	if lane then
		replies = core.receive(lane, msg, ctx)
		if lane.dropped then
			to.lanes[l] = nil
		end
	elseif msg.k == "close" then
		replies = core.unknown_close(msg, to.rev)
	elseif msg.k == "s.final" or msg.k == "u.final" then
		replies = core.unknown_final()
	end
	if replies == false then
		error("a malformed " .. msg.k .. " reached " .. l .. " at " .. to.boot)
	end
	return replies or {}
end

local function tokens(w)
	local n = 0
	for _, v in pairs(w.tokens) do
		n = n + (v == true and 1 or v)
	end
	return n
end

-- The bounded enumeration: the model's rounds, run on ledger_core ------------------------------------------------------

local SIDE = { A = "tx", B = "rx" }

local LANE = { stream = "s", unique = "u", ordered = "o" }

--- An ordered world's items: n keys in blocks of `block` (x, y, z, x, ...), so a capture makes few runs.
local function sequence(n, block)
	local q, keys = {}, { "x", "y", "z" }
	for i = 1, n do
		q[i] = keys[math.floor((i - 1) / block) % 3 + 1]
	end
	return q
end

--- The items S.oq (outside the worlds, so saves don't copy them); A's world gains its place in them, its capture log and
--- its refunds, and B's world the sequence it credited.
local function ordered_world(S, n, block)
	S.oq = sequence(n, block)
	S.A.world.ohead, S.A.world.ocap, S.A.world.orefund = 1, {}, {}
	S.B.world.oseq, S.B.world.orefund, S.B.world.ogaps = {}, {}, {}
end

--- Take up to n items from A's queue as runs and capture them, unless that would pass RUN_CAP (as a transport checks).
local function capture_items(S, lane, n, ctx)
	local w, runs = S.A.world, {}
	local stop = math.min(w.ohead + n - 1, #S.oq)
	for i = w.ohead, stop do
		local tail = runs[#runs]
		if tail and tail[1] == S.oq[i] then
			tail[2] = tail[2] + 1
			tail[3][#tail[3] + 1] = i
		else
			runs[#runs + 1] = { S.oq[i], 1, { i } }
		end
	end
	if #runs == 0 or core.runs(lane) + #runs > core.RUN_CAP then
		return
	end
	core.capture(lane, runs, nil, ctx)
	for i = w.ohead, stop do
		w.ocap[#w.ocap + 1] = S.oq[i]
	end
	w.ohead = stop + 1
end

--- The ordered properties: per key, A's rest + A's refunds + B's credits equal the items (at least them when `atleast`);
--- with `in_order`, B's credited sequence is a prefix of A's capture log. nil when they hold, or what broke.
local function ordered_verdict(S, atleast, in_order)
	local want, have = {}, {}
	for _, k in ipairs(S.oq) do
		want[k] = (want[k] or 0) + 1
	end
	for i = S.A.world.ohead, #S.oq do
		have[S.oq[i]] = (have[S.oq[i]] or 0) + 1
	end
	for k, n in pairs(S.A.world.orefund) do
		have[k] = (have[k] or 0) + n
	end
	for _, k in ipairs(S.B.world.oseq) do
		have[k] = (have[k] or 0) + 1
	end
	for k, n in pairs(want) do
		local h = have[k] or 0
		if h < n or (not atleast and h ~= n) then
			return "ordered total of " .. k .. " is " .. h .. " of " .. n
		end
	end
	if in_order then
		for i, k in ipairs(S.B.world.oseq) do
			if S.A.world.ocap[i] ~= k then
				return "ordered sequence differs at item " .. i
			end
		end
	end
	return nil
end

local function fresh(kind, role)
	return core.new(kind, role)
end

--- One model run (the .mjs's streamRun or uniqueRun): events over a two-sided lane, then removal and three rounds of
--- quiescence. Returns the conserved total and whether any lane is left open.
local function run(kind, setup, events)
	local S = {
		A = { world = { items = 1000, tokens = { T = true }, held = {} }, lanes = {}, boot = "a1", rev = 1, phases = {} },
		B = { world = { items = 0, tokens = {}, held = {} }, lanes = {}, boot = "b1", rev = 1, phases = {} },
		live = false, removed = false, tick = 0, boots = 1,
	}
	if kind == "ordered" then
		ordered_world(S, 40, 5) -- a tenth of the stream's 1000 items, so the enumerations stay quick
	end
	S.sA, S.sB = copy(S.A), copy(S.B)
	local ca, cb = side_ctx(S, "A"), side_ctx(S, "B")
	local l = LANE[kind]
	local function close_all(side)
		side.rev = 2
		if side.lanes[l] then
			core.close(side.lanes[l], 2, S.tick)
		end
	end
	local act = {}
	function act.create()
		S.live = true
		S.A.lanes[l], S.B.lanes[l] = fresh(kind, "tx"), fresh(kind, "rx")
	end
	function act.cap(n)
		local lane = S.A.lanes[l]
		if not lane or not core.can_send(lane) then
			return
		end
		ca.tick, ca.boot = S.tick, S.A.boot
		if kind == "stream" then
			S.A.world.items = S.A.world.items - n
			core.capture(lane, { items = n }, nil, ca)
		elseif kind == "ordered" then
			capture_items(S, lane, n / 10, ca)
		elseif S.A.world.tokens.T and not S.A.world.held.T then
			S.A.world.held.T = true
			core.capture(lane, "T", "tr", ca)
		end
	end
	--- Every round is a fresh activation, as the model re-offers every round: visits and deliveries until quiet.
	function act.round()
		S.tick = S.tick + 10000
		ca.tick, ca.boot, cb.tick, cb.boot = S.tick, S.A.boot, S.tick, S.B.boot
		for _, side in ipairs({ S.A, S.B }) do
			for _, lane in pairs(side.lanes) do
				core.activate(lane)
			end
		end
		for _ = 1, 10 do
			local ab = S.A.lanes[l] and core.visit(S.A.lanes[l], ca) or {}
			local ba = S.B.lanes[l] and core.visit(S.B.lanes[l], cb) or {}
			if #ab == 0 and #ba == 0 then
				break
			end
			while #ab > 0 or #ba > 0 do
				local next_ab, next_ba = {}, {}
				for _, m in ipairs(ab) do
					for _, r in ipairs(deliver(S.B, l, m, cb)) do
						next_ba[#next_ba + 1] = r
					end
				end
				for _, m in ipairs(ba) do
					for _, r in ipairs(deliver(S.A, l, m, ca)) do
						next_ab[#next_ab + 1] = r
					end
				end
				ab, ba = next_ab, next_ba
			end
		end
	end
	function act.saveA()
		S.sA = copy(S.A)
	end
	function act.saveB()
		S.sB = copy(S.B)
	end
	local function crash(name)
		local side = copy(S["s" .. name])
		if name == "A" then
			S.boots = S.boots + 1
			side.boot = "a" .. S.boots
		end
		S[name] = side
		if S.removed then
			close_all(side)
		elseif S.live and not side.lanes[l] then
			side.lanes[l] = fresh(kind, SIDE[name])
		end
	end
	function act.crashA()
		crash("A")
	end
	function act.crashB()
		crash("B")
	end
	function act.remove()
		S.removed, S.live = true, false
		close_all(S.A)
		close_all(S.B)
	end
	for _, e in ipairs(setup) do
		if type(e) == "table" then
			act[e[1]](e[2])
		else
			act[e]()
		end
	end
	for _, e in ipairs(events) do
		act[e]()
	end
	if not S.removed then
		act.remove()
	end
	-- The model quiesces with round, saveA, saveB, round three times. Nothing waits for a save any more (D8) and no
	-- crash follows, so only its six rounds matter.
	for _ = 1, 6 do
		act.round()
	end
	local open = next(S.A.lanes) ~= nil or next(S.B.lanes) ~= nil
	if kind == "ordered" then
		-- 1000 when the 40 items are exact and in order, as the stream's total; the third value: exact at all
		return ordered_verdict(S, false, true) and 0 or 1000, open, ordered_verdict(S, false, false) == nil
	end
	local total = kind == "stream" and S.A.world.items + S.B.world.items or tokens(S.A.world) + tokens(S.B.world)
	return total, open
end

--- Every sequence over alpha of length ≤ depth with at most one "remove" (the model's seqs), filtered by allow.
local function each_sequence(alpha, depth, allow, fn)
	local seq = {}
	local function walk(n, removed)
		fn(seq)
		if n == 0 then
			return
		end
		for _, x in ipairs(alpha) do
			if not (x == "remove" and removed) and (not allow or allow(seq, x, removed)) then
				seq[#seq + 1] = x
				walk(n - 1, removed or x == "remove")
				seq[#seq] = nil
			end
		end
	end
	walk(depth, false)
end

--- Run every schedule; returns schedules, violations (bad) and duplications, with the first violation's sequence.
local function check(kind, alpha, depth, setups, want, allow)
	local n, bad, dup, example = 0, 0, 0, nil
	for _, setup in ipairs(setups) do
		each_sequence(alpha, depth, allow, function(seq)
			n = n + 1
			local total, open, exact = run(kind, setup, seq)
			if kind == "ordered" then
				-- total is 1000 when the items are exact and in order; exact says whether they are exact at all.
				total = (want == "in_order" and total) or (exact and 1000) or 0
			end
			local base = kind == "stream" and 1000 or 1
			if kind == "ordered" then
				base = 1000
			end
			if open or total < base or (want == "exact" and total ~= base) then
				bad = bad + 1
				example = example or table.concat(seq, ",")
			elseif total > base then
				dup = dup + 1
			end
		end)
	end
	return n, bad, dup, example
end

local SS = {
	{ "create", { "cap", 100 }, "round", "saveB", { "cap", 300 }, "round" },
	{ "create", { "cap", 100 }, "round", { "cap", 300 }, "round" },
	{ "create", { "cap", 100 }, "round", "saveA", "saveB", { "cap", 300 }, "round" },
}
local US = { { "create", "cap", "round" }, { "create", "saveB", "cap", "round" }, { "create", "cap", "round", "saveA" },
	{ "create", "cap" } }

local function crash_before_remove(_, x, removed)
	return not (x == "crashB" and removed)
end

t.test("enumeration, stream, no crash: exact and every lane closed (model: 31164 schedules at depth 7)", function()
	local n, bad, _, ex = check("stream", { "round", "saveA", "saveB", "remove" }, 7, SS, "exact")
	t.expect_eq(n, 31164)
	t.expect_eq(bad, 0, "violation: " .. tostring(ex))
end)

t.test("enumeration, stream, source crashes: never loss, every lane closed (model: 39594, 19890 duplicated)", function()
	local n, bad, dup, ex = check("stream", { "round", "saveA", "saveB", "crashA", "remove" }, 6, SS, "no_loss")
	t.expect_eq(n, 39594)
	t.expect_eq(bad, 0, "violation: " .. tostring(ex))
	t.expect_eq(dup, 19890)
end)

t.test("enumeration, stream, destination crashes before the removal: exact (model: 121230 at depth 7)", function()
	local n, bad, _, ex = check("stream", { "round", "saveA", "saveB", "crashB", "remove" }, 7, SS, "exact",
		crash_before_remove)
	t.expect_eq(n, 121230)
	t.expect_eq(bad, 0, "violation: " .. tostring(ex))
end)

t.test("enumeration, ordered, no crash: exact, in capture order, and every lane closed (the stream's 31164)", function()
	local n, bad, _, ex = check("ordered", { "round", "saveA", "saveB", "remove" }, 7, SS, "in_order")
	t.expect_eq(n, 31164)
	t.expect_eq(bad, 0, "violation: " .. tostring(ex))
end)

t.test("enumeration, ordered, destination crashes before the removal: exact (the stream's 121230)", function()
	local n, bad, _, ex = check("ordered", { "round", "saveA", "saveB", "crashB", "remove" }, 7, SS, "exact",
		crash_before_remove)
	t.expect_eq(n, 121230)
	t.expect_eq(bad, 0, "violation: " .. tostring(ex))
end)

t.test("enumeration, unique, no crash: one train and every lane closed (model: 52792)", function()
	local n, bad, _, ex = check("unique", { "round", "saveA", "saveB", "remove", "cap" }, 6, US, "exact")
	t.expect_eq(n, 52792)
	t.expect_eq(bad, 0, "violation: " .. tostring(ex))
end)

t.test("enumeration, unique, source crashes: never loss, every lane closed (model: 167968, 41249 duplicated)", function()
	local n, bad, dup, ex = check("unique", { "round", "saveA", "saveB", "crashA", "remove", "cap" }, 6, US, "no_loss")
	t.expect_eq(n, 167968)
	t.expect_eq(bad, 0, "violation: " .. tostring(ex))
	t.expect_eq(dup, 41249)
end)

-- The seeded model check (§11.9): a message-level network ---------------------------------------------------------------

--- A two-sided world: A sends on a stream lane (s) and a unique lane (u), B receives. Messages cross per-epoch queues.
local function world(b_has_lanes)
	local S = {
		A = { world = { items = 1000, tokens = {}, held = {} }, lanes = {}, boot = "a1", rev = 1, phases = {} },
		B = { world = { items = 0, tokens = {}, held = {} }, lanes = {}, boot = "b1", rev = 0, phases = {} },
		net = { A = {}, B = {} }, tick = 1, epoch = nil, epochs = 0, boots = 1, removed = false, policy = {}, lost = 0,
	}
	for i = 1, 5 do
		S.A.world.tokens["t" .. i] = true
	end
	ordered_world(S, 400, 3)
	S.A.lanes.s, S.A.lanes.u, S.A.lanes.o = core.new("stream", "tx"), core.new("unique", "tx"), core.new("ordered", "tx")
	if b_has_lanes then
		S.B.rev = 1
		S.B.lanes.s, S.B.lanes.u, S.B.lanes.o = core.new("stream", "rx"), core.new("unique", "rx"), core.new("ordered", "rx")
	end
	S.ctx = { A = side_ctx(S, "A"), B = side_ctx(S, "B") }
	S.sA, S.sB = copy(S.A), copy(S.B)
	return S
end

local ROLE = { A = "tx", B = "rx" }
local OTHER = { A = "B", B = "A" }

--- The side applies the controller's record (§6.2): the removal closes its lanes; a live connector it lacks is created.
local function apply(S, name)
	local side = S[name]
	if S.removed then
		side.rev = 2
		for _, lane in pairs(side.lanes) do
			core.close(lane, 2, S.tick)
		end
	else
		side.rev = 1
		for kind, l in pairs(LANE) do
			side.lanes[l] = side.lanes[l] or core.new(kind, ROLE[name])
		end
	end
end

local function ctx_of(S, name)
	local c = S.ctx[name]
	c.tick, c.boot = S.tick, S[name].boot
	return c
end

local function activate(S)
	S.epochs = S.epochs + 1
	S.epoch = S.epochs
	for _, name in ipairs({ "A", "B" }) do
		for _, lane in pairs(S[name].lanes) do
			core.activate(lane)
		end
	end
end

local function send(S, from, l, msgs)
	for _, m in ipairs(msgs or {}) do
		local q = S.net[OTHER[from]]
		q[#q + 1] = { epoch = S.epoch, l = l, msg = m }
	end
end

local function visit(S, name)
	if not S.epoch then
		return -- an inactive side sends nothing (§11.2)
	end
	for _, l in ipairs({ "s", "u", "o" }) do
		local lane = S[name].lanes[l]
		if lane then
			send(S, name, l, core.visit(lane, ctx_of(S, name)))
		end
	end
end

--- Deliver queue entry i of side `name`: a batch of an ended or unseen epoch is dropped, as the receiver's checks and
--- Lua's epoch check do (§11.2).
local function deliver_at(S, name, i)
	local item = table.remove(S.net[name], i)
	if item.epoch ~= S.epoch then
		return
	end
	send(S, name, item.l, deliver(S[name], item.l, item.msg, ctx_of(S, name)))
end

local function crash(S, name)
	local side = copy(S["s" .. name])
	S.boots = S.boots + 1
	side.boot = string.lower(name) .. S.boots
	S[name] = side
	S.epoch = nil -- the controller deactivates the edge (new_boot) until both sides sync again
	apply(S, name)
end

--- Capture from the source's world (T1): items leave at once; a token is held until commit or restore.
local function capture(S, kind, n)
	local A = S.A
	local lane = A.lanes[LANE[kind]]
	if not lane or not core.can_send(lane) then
		return
	end
	if kind == "ordered" then
		capture_items(S, lane, n, ctx_of(S, "A"))
	elseif kind == "stream" then
		if A.world.items >= n then
			A.world.items = A.world.items - n
			core.capture(lane, { items = n }, nil, ctx_of(S, "A"))
		end
	elseif S.epoch then
		for i = 1, 5 do
			local token = "t" .. i
			if A.world.tokens[token] and not A.world.held[token] then
				A.world.held[token] = true
				core.capture(lane, token, "tr." .. token, ctx_of(S, "A"))
				return
			end
		end
	end
end

--- Remove the connector if it still exists, let both sides apply it, activate, and deliver everything without faults
--- until no lane is left: the drain that ends every schedule.
local function drain(S)
	S.removed = true
	apply(S, "A")
	apply(S, "B")
	S.policy = {}
	activate(S)
	for _ = 1, 50 do
		S.tick = S.tick + 4000
		visit(S, "A")
		visit(S, "B")
		while #S.net.A > 0 or #S.net.B > 0 do
			if #S.net.B > 0 then
				deliver_at(S, "B", 1)
			end
			if #S.net.A > 0 then
				deliver_at(S, "A", 1)
			end
		end
		if next(S.A.lanes) == nil and next(S.B.lanes) == nil then
			return
		end
	end
end

--- The properties of §11.9 for one mode: nil when they hold, or what broke.
local function verdict(S, mode)
	if next(S.A.lanes) ~= nil or next(S.B.lanes) ~= nil then
		return "a lane was left open"
	end
	local items = S.A.world.items + S.B.world.items
	if items < 1000 or (mode ~= "source" and items ~= 1000) then
		return "stream total " .. items
	end
	if mode ~= "dest" then
		for i = 1, 5 do
			local token = "t" .. i
			local n = (S.A.world.tokens[token] and 1 or 0) + (S.B.world.tokens[token] or 0)
			if n < 1 or (mode == "clean" and n ~= 1) then
				return token .. " exists " .. n .. " times"
			end
		end
	end
	-- Ordered: exact with no crash and under a destination crash, never a loss under source crashes; with no crash
	-- at all, B's credited sequence is A's capture order (a source rollback re-captures, so there is no one order).
	local broke = ordered_verdict(S, mode == "source", mode == "clean")
	if broke == nil and mode == "clean" and not S.capped then -- R5: with no crash and no partial acceptance
		local ogaps, oseq = S.B.world.ogaps, S.B.world.oseq
		if #ogaps ~= #oseq then
			return "ordered credited " .. #oseq .. " items but " .. #ogaps .. " runs with their g"
		end
		for i = 1, #oseq do
			if ogaps[i] ~= i then
				return "ordered run " .. i .. " was not credited whole with its g"
			end
		end
	end
	return broke
end

--- A tiny LCG, so a seed replays the same schedule on any Lua. Its high bits: the low ones of an LCG repeat quickly.
local function rng(seed)
	local s = seed
	return function(n)
		s = (s * 1103515245 + 12345) % 2147483648
		return math.floor(s / 65536) % n + 1
	end
end

local MODES = { "clean", "source", "dest" }
local STEPS = { "capS", "capS", "capU", "capO", "capO", "visitA", "visitB", "visitA", "visitB", "deliver", "deliver",
	"deliver", "deliver", "drop", "dup", "activate", "deactivate", "saveA", "saveB", "crash", "remove", "applyA",
	"applyB", "policy" }

--- One seeded schedule of `n` steps in `mode`; returns nil or the broken property, and the steps taken.
local function schedule(seed, mode, n)
	local r = rng(seed)
	local S = world(r(2) == 1)
	local steps = {}
	for _ = 1, n do
		S.tick = S.tick + r(2000)
		local step = STEPS[r(#STEPS)]
		steps[#steps + 1] = step
		if step == "capS" then
			capture(S, "stream", r(60))
		elseif step == "capU" then
			capture(S, "unique")
		elseif step == "capO" then
			capture(S, "ordered", r(8))
		elseif step == "visitA" then
			visit(S, "A")
		elseif step == "visitB" then
			visit(S, "B")
		elseif step == "deliver" then
			local name = r(2) == 1 and "A" or "B"
			local q = S.net[name]
			if #q > 0 then
				deliver_at(S, name, r(3) == 1 and r(#q) or 1) -- mostly in order, sometimes reordered
			end
		elseif step == "drop" then
			local q = S.net[r(2) == 1 and "A" or "B"]
			if #q > 0 then
				table.remove(q, r(#q))
			end
		elseif step == "dup" then
			local q = S.net[r(2) == 1 and "A" or "B"]
			if #q > 0 then
				table.insert(q, r(#q + 1), copy(q[r(#q)]))
			end
		elseif step == "activate" then
			activate(S) -- a new epoch: queued batches of the old one become stale
		elseif step == "deactivate" then
			S.epoch = nil
		elseif step == "saveA" then
			S.sA = copy(S.A)
		elseif step == "saveB" then
			S.sB = copy(S.B)
		elseif step == "crash" then
			if mode == "source" then
				crash(S, "A")
			elseif mode == "dest" and S.B.rev < 2 then
				crash(S, "B") -- only while B hasn't closed its lanes: §11.6 case 2 is an accepted loss
			end
		elseif step == "remove" then
			S.removed = true
		elseif step == "applyA" then
			apply(S, "A")
		elseif step == "applyB" and (S.B.rev > 0 or r(2) == 1) then
			apply(S, "B")
		elseif step == "policy" then
			S.policy = { cap = r(3) == 1 and r(40) or nil, outcome = ({ "ok", "ok", "busy", "reject" })[r(4)] }
			S.capped = S.capped or S.policy.cap ~= nil
		end
	end
	drain(S)
	return verdict(S, mode), steps
end

local SEEDED = "seeded model check: the §11.9 properties hold under loss, duplication, reordering and stale epochs; "
	.. "with no crash and no partial acceptance, every ordered run is credited whole with its g (belt spacing spec §6)"
t.test(SEEDED, function()
	local only = tonumber(os.getenv("SIM_SEED"))
	local runs = only and 1 or (tonumber(os.getenv("SIM_RUNS")) or 500)
	for i = 1, runs do
		local seed = only or i
		local mode = MODES[seed % #MODES + 1]
		local broken, steps = schedule(seed, mode, 80)
		if broken then
			error("seed " .. seed .. " (" .. mode .. "): " .. broken .. "; replay with SIM_SEED=" .. seed
				.. "\n       steps: " .. table.concat(steps, ","))
		end
	end
end)

-- Fixed cases (§11.9): no-crash removals with a reply on its way, and source-rollback dedupe -----------------------------

--- Run steps on a world where both sides have their lanes and the edge is active.
local function scripted(steps)
	local S = world(true)
	activate(S)
	for _, step in ipairs(steps) do
		S.tick = S.tick + 5000
		step(S)
	end
	return S
end

local function deliver_all(name)
	return function(S)
		while #S.net[name] > 0 do
			deliver_at(S, name, 1)
		end
	end
end

local function removed(S)
	S.removed = true
	apply(S, "A")
	apply(S, "B")
end

t.test("fixed: a removal while a stream ack is on its way refunds nothing for the credited offer", function()
	local S = scripted({
		function(s) capture(s, "stream", 100) end,
		function(s) visit(s, "A") end,
		deliver_all("B"), -- B credits 100; its s.ack waits in A's queue
		removed,
	})
	t.expect_eq(S.A.world.items + S.B.world.items, 1000)
	drain(S)
	t.expect_eq(S.B.world.items, 100, "B keeps what it credited")
	t.expect_eq(S.A.world.items, 900, "and A refunds nothing of it")
	t.expect_true(next(S.A.lanes) == nil and next(S.B.lanes) == nil, "every lane closed")
end)

t.test("fixed: a removal while a unique reply is on its way commits the capture", function()
	local S = scripted({
		function(s) capture(s, "unique") end,
		function(s) visit(s, "A") end,
		deliver_all("B"), -- B credits t1; its u.reply waits in A's queue
		removed,
	})
	drain(S)
	t.expect_eq(S.B.world.tokens.t1, 1)
	t.expect_eq(S.A.world.tokens.t1, nil, "committed at the source")
	t.expect_eq(verdict(S, "clean"), nil)
end)

t.test("fixed: a removal while a reject reply is on its way restores the capture (u.final names a rejected w)", function()
	local S = scripted({
		function(s) s.policy = { outcome = "reject" } end,
		function(s) capture(s, "unique") end,
		function(s) visit(s, "A") end,
		deliver_all("B"), -- B rejects t1 (w = 1); its reply waits in A's queue
		removed,
	})
	drain(S)
	t.expect_eq(S.A.world.tokens.t1, true, "restored at the source")
	t.expect_eq(S.B.world.tokens.t1, nil)
	t.expect_eq(verdict(S, "clean"), nil)
end)

t.test("fixed: after a source rollback, a restored in-flight offer is a repeat", function()
	local S = scripted({
		function(s) capture(s, "unique") end,
		function(s) s.sA = copy(s.A) end, -- A saves with t1 in flight
		function(s) visit(s, "A") end,
		deliver_all("B"), -- B credits t1; the reply is lost with A's crash
		function(s) crash(s, "A"); activate(s) end,
		function(s) visit(s, "A") end,
		deliver_all("B"),
		deliver_all("A"),
	})
	t.expect_eq(S.B.phases["repeat"], 1, "the same tag at or below w")
	t.expect_eq(S.A.world.tokens.t1, nil, "committed")
	t.expect_eq(S.B.world.tokens.t1, 1, "credited once")
end)

t.test("fixed: after a source rollback, an identical replay under a new tag is a repeat, not a second credit", function()
	local S = scripted({
		function(s) s.sA = copy(s.A) end, -- A saves before it captures t1
		function(s) capture(s, "unique") end,
		function(s) visit(s, "A") end,
		deliver_all("B"),
		deliver_all("A"), -- committed: t1 is at B
		function(s) crash(s, "A"); activate(s) end, -- A has t1 again, and next_seq 1 again, under a new boot
		function(s) capture(s, "unique") end,
		function(s) visit(s, "A") end,
		deliver_all("B"),
		deliver_all("A"),
	})
	t.expect_eq(S.B.phases["repeat"], 1, "a different tag, the same digest")
	t.expect_eq(S.B.world.tokens.t1, 1, "not credited twice")
	t.expect_eq(S.A.world.tokens.t1, nil)
end)

--- Capture explicit runs on A's ordered lane, logging them, outside A's queue (the ordered fixed cases).
local function capture_runs(S, runs)
	core.capture(S.A.lanes.o, runs, nil, ctx_of(S, "A"))
	for _, r in ipairs(runs) do
		for _ = 1, r[2] do
			S.A.world.ocap[#S.A.world.ocap + 1] = r[1]
		end
	end
end

t.test("fixed: an older ordered offer, delivered after a newer one and twice, credits nothing twice, in order", function()
	local old
	local S = scripted({
		function(s) capture_runs(s, { { "x", 2 }, { "y", 1 } }) end,
		function(s)
			visit(s, "A")
			old = table.remove(s.net.B, 1) -- offer 1 (x2 y1) is held back
		end,
		function(s) capture_runs(s, { { "x", 1 }, { "z", 2 } }) end,
		function(s) visit(s, "A") end, -- offer 2: x2 y1 x1 z2, every run since the last ack
		function(s)
			table.insert(s.net.B, copy(s.net.B[1])) -- offer 2 twice
			table.insert(s.net.B, old) -- then offer 1, late
			deliver_all("B")(s)
		end,
		deliver_all("A"),
	})
	t.expect_eq(table.concat(S.B.world.oseq, ","), "x,x,y,x,z,z")
	t.expect_eq(core.runs(S.A.lanes.o), 0, "every run acknowledged")
end)

t.test("fixed: a destination restored below the ack gets every item again from zero-length runs", function()
	local S = scripted({
		function(s) capture_runs(s, { { "x", 2 }, { "y", 1 } }) end,
		function(s) visit(s, "A") end,
		deliver_all("B"),
		deliver_all("A"), -- acknowledged: A's runs are dropped
		function(s) crash(s, "B"); activate(s) end, -- B restores its first save: recv and oseq empty
		function(s) visit(s, "A") end, -- { x, 0, 2 } and { y, 0, 1 }
		deliver_all("B"),
	})
	local n = {}
	for _, k in ipairs(S.B.world.oseq) do
		n[k] = (n[k] or 0) + 1
	end
	t.expect_same(n, { x = 2, y = 1 }, "exact; the order isn't kept after a destination crash")
end)

t.test("fixed: a destination crash on a live stream lane is exact after the activation re-offer", function()
	local S = scripted({
		function(s) capture(s, "stream", 100) end,
		function(s) visit(s, "A") end,
		deliver_all("B"),
		deliver_all("A"),
		function(s) crash(s, "B"); activate(s) end, -- B restores its first save: recv 0, world 0
		function(s) visit(s, "A") end,
		deliver_all("B"),
	})
	t.expect_eq(S.B.world.items, 100, "credited again")
	drain(S)
	t.expect_eq(S.A.world.items + S.B.world.items, 1000)
end)
