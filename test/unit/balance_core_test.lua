local t = require("testlib")
local core = require("modules/universal_edges/transports/balance_core")

t.test("balance: PR #7's target with share 1, scaled by a smaller share, capped by the partner's room", function()
	t.expect_eq(core.amount(100, 100, 0, 100, 100), 50, "half the difference")
	t.expect_eq(core.amount(100, 100, 0, 100, 50), 25, "share 1/2")
	t.expect_eq(core.amount(100, 100, 95, 100, 100), 2, "2.5, floored; the partner has room for 5")
	t.expect_eq(core.amount(100, 400, 50, 100, 400), 0, "a quarter full against half full: nothing")
	t.expect_eq(core.amount(10, 0, 0, 100, 1), 0, "no capacity")
end)

t.test("balance: the partner's status plus what it hasn't counted of ours, at most its capacity", function()
	t.expect_eq(core.partner({ a = 10, c = 100, r = 5 }, 20), 25)
	t.expect_eq(core.partner({ a = 10, c = 100, r = 30 }, 20), 10, "a status newer than our sends")
	t.expect_eq(core.partner({ a = 90, c = 100 }, 50), 100, "capped")
	t.expect_eq(core.partner({ a = 50, c = 100, r = 5, d = 12000 }, 5, 30), 44, "F-PW2: less its drain (J a poll) for half a poll")
	t.expect_eq(core.partner({ a = 50, c = 100, r = 5, d = 1e9 }, 5, 30), 0, "the drain never takes it below 0")
	t.expect_eq(core.partner({ a = 50, c = 100, r = 5 }, 5, 30), 50, "no d (a fluid): unchanged")
end)

t.test("balance: a partner's status shows room for a refused remainder from c/64 free, its re-announce step", function()
	t.expect_true(core.has_room({ a = 0, c = 6400 }), "empty")
	t.expect_true(core.has_room({ a = 6300, c = 6400 }), "exactly c/64 free")
	t.expect_true(not core.has_room({ a = 6301, c = 6400 }), "less: can't be told from full")
	t.expect_true(not core.has_room({ a = 6400, c = 6400 }), "full")
end)

t.test("balance: the write-back keeps one fill ratio and the whole total", function()
	local acc, link = core.split(300, 1000, 500)
	t.expect_eq(acc, 200)
	t.expect_eq(link, 100)
end)

t.test("buffer (D34, D37): 4f, doubling while held back, within [10 MJ, 10 GJ], shrinking only below B/4, never below E",
	function()
		t.expect_eq(core.buffer(10e6, 5e6, 30e6, false), 120e6, "grows to four times the flow")
		t.expect_eq(core.buffer(100e6, 0, 10e6, true), 200e6, "held back: doubles")
		t.expect_eq(core.buffer(100e6, 100e6, 1e6, false), 100e6, "full on an idle network: stays")
		t.expect_eq(core.buffer(100e6, 50e6, 10e6, false), 100e6, "40 MJ wanted is not below a quarter: stays")
		t.expect_eq(core.buffer(1e9, 800e6, 1e6, false), 800e6, "shrinks, but not below the stored energy (D37: kept)")
		t.expect_eq(core.buffer(1e9, 0, 0, false), 10e6, "the floor")
		t.expect_eq(core.buffer(8e9, 0, 8e9, true), 10e9, "D37's ceiling: 10 GJ")
	end)

t.test("size (D34): the drain excludes the link's own moves; a starved side, or a dry partner, holds it back", function()
	local B, drain = core.size(10e6, 0, 0, 9e6, 0, nil, true)
	t.expect_eq(drain, 9e6, "9 MJ drawn from the storage")
	t.expect_eq(B, 36e6, "starved: max(4 × 9 MJ, 2 × 10 MJ)")
	B, drain = core.size(10e6, 5e6, 30e6, 20e6, 15000, nil, false)
	t.expect_eq(drain, 5e6, "20 MJ + 15 MJ credited - 30 MJ now: 5 MJ drawn")
	t.expect_eq(B, 20e6)
	local _, after_send = core.size(10e6, 5e6, 30e6, 30e6, 0, nil, false)
	t.expect_eq(after_send, 0, "a_last is taken after this side's send, so the send is not a drain (review M1)")
	B = core.size(10e6, 10e6, 35e6, 35e6, 0, { d = 1e9, dry = true }, false)
	t.expect_eq(B, 4e9, "the feeding side sizes for its partner's drain")
	B, drain = core.size(10e6, 5e6, 20e6, 30e6, 0, nil, false, true)
	t.expect_true(drain == 0 and B == 10e6, "a side that sent at its last poll has no drain of its own (review I2)")
	B = core.size(124e6, 0, 25e6, 25e6, 0, { a = 665000, c = 665000, d = 0 }, false, false)
	t.expect_eq(B, 124e6, "F-PW: an empty interface is not demand while the partner has energy to send: kept")
	B = core.size(124e6, 0, 25e6, 25e6, 0, { a = 0, c = 665000, d = 0 }, false, false)
	t.expect_eq(B, 10e6, "F-PW: the partner empty too: shrinks to the floor")
end)

t.test("size (#8): no shrink within HOLD ticks of the last growth; after it, the usual shrink", function()
	t.expect_eq(core.size(124e6, 0, 0, 0, 0, nil, false, false, core.HOLD - 1), 124e6, "grown HOLD - 1 ticks ago: kept")
	t.expect_eq(core.size(124e6, 0, 0, 0, 0, nil, false, false, core.HOLD), 10e6, "HOLD ticks ago: shrinks")
	t.expect_eq(core.size(124e6, 0, 0, 0, 0, nil, false, false, nil), 10e6, "never grown: shrinks")
end)

t.test("starving (review C1): nearly empty when energy arrives, while the partner had energy to send", function()
	t.expect_true(core.starving(0, 35000, { a = 30000, c = 35000 }), "empty, the partner full")
	t.expect_true(not core.starving(1000, 35000, { a = 30000, c = 35000 }), "more than 1 % left")
	t.expect_true(not core.starving(0, 35000, { a = 3000, c = 35000 }), "the partner had less than an eighth: its brownout")
	t.expect_true(not core.starving(0, 35000, nil), "no status yet")
end)

--- The power link model for Task 5's gate (after the reviews' sim.lua and par.lua). o.nets networks in a row (default 2,
--- a and b), each next two joined by n links. Each network has shared accumulators (capacity o.acc[k], none when
--- missing); each link has an interface per side. Generation on the first network (gen(tick) J a tick; nil = unlimited)
--- fills its interfaces, then its accumulators; a load on the last (load(tick)) draws from all of its storage in
--- proportion. Each link side polls every 60 ticks: o.at(j, i, side) gives the tick % 60 of link j's parallel link i on
--- side "a" (network j) or "b" (j + 1); by default a at 7·i, b at (phase + 11·i). A poll uses balance_core's size,
--- amount, partner, starving and split as power.lua does: a link sees its network's pool, the accumulators and every
--- link's interface on it, written back at one fill ratio, and its drain leaves out every link's moves (power.lua's
--- totals; #8: the share is of the network's interfaces, so a pool seen per link would count the other link's sends as
--- drain and grow without end). A send is debt, paid from the pool in equal steps over 60 ticks (spike 22): the balance,
--- the status and the starving latch leave owed energy out, and a credit's room is the real free space. Statuses and
--- lane messages take `delay` ticks one way; a credit takes what fits, and the rest re-offers as the lane does
--- (ledger_core, final fix wave addendum): at once after an ack with progress; after a refusal, at the first poll whose
--- partner status shows room (has_room: the nudge), else on the lane's backoff, 300 ticks doubling to 3600 from each
--- offer. Returns per-60-tick delivery, the largest buffer, the worst conservation error, the message count, and the
--- links (each { a, b }: its two sides, in network order). o.tick_cb(tick, need, take, links) runs every tick.
local function power_link(o)
	local n, delay, phase, K = o.n or 1, o.delay or 2, o.phase or 30, o.nets or 2
	local at = o.at or function(_, i, side)
		return side == "a" and (7 * i) % 60 or (phase + 11 * i) % 60
	end
	local net, chain = {}, {}
	for k = 1, K do
		net[k] = { ca = o.acc[k] or 0, acc = 0, links = {}, got = 0, drained = 0 }
	end
	for j = 1, K - 1 do
		for i = 1, n do
			local pair = {}
			for _, s in ipairs({ "a", "b" }) do
				local L = { k = s == "a" and j or j + 1, at = at(j, i, s), B = 10e6, el = 0, got = 0, sent = 0, a_last = 0,
					drain = 0, backoff = 300, ggot0 = 0, gdrained0 = 0, debt = 0, due = 0 }
				table.insert(net[L.k].links, L)
				pair[s] = L
			end
			pair.a.P, pair.b.P = pair.b, pair.a
			chain[#chain + 1] = pair
		end
	end
	if o.full_a then
		net[1].acc = net[1].ca
	end
	local queue, seq, inflight, msgs = {}, 0, 0, 0
	local function later(when, fn)
		seq = seq + 1
		queue[#queue + 1] = { at = when, fn = fn, seq = seq }
	end
	local function stored(k)
		local e = net[k].acc
		for _, L in ipairs(net[k].links) do
			e = e + L.el
		end
		return e
	end
	--- What power.lua's share divides by (#8): the network's link interfaces, not its accumulators.
	local function links(k)
		local b = 0
		for _, L in ipairs(net[k].links) do
			b = b + L.B
		end
		return b
	end
	--- What the network's links still owe its pool (J): power.lua's totals.
	local function owed(k)
		local d = 0
		for _, L in ipairs(net[k].links) do
			d = d + L.debt
		end
		return d
	end
	--- A network's pool written back at one fill ratio over its accumulators and every interface (§8.2).
	local function write(k, A2)
		local N = net[k]
		local r = A2 / (N.ca + links(k))
		N.acc = r * N.ca
		for _, L in ipairs(N.links) do
			L.el = r * L.B
		end
	end
	local function total()
		local e = inflight
		for k = 1, K do
			e = e + stored(k) - owed(k)
		end
		return e
	end
	local start, generated, consumed, worst = total(), 0, 0, 0
	local function poll(L, tick)
		local N = net[L.k]
		local moved = (N.got - L.ggot0) - (N.drained - L.gdrained0)
		local B2, drain = core.size(L.B, L.el, stored(L.k), L.a_last, moved, L.theirs, L.starved, L.fed,
			L.grown and tick - L.grown)
		local dry = L.starved == true
		L.starved, L.drain, L.fed = false, drain, false
		if B2 < L.el then
			error("a buffer shrank below its energy")
		end
		if B2 > L.B then
			L.grown = tick
		end
		L.B = B2
		local Ak, Ck = math.max(0, stored(L.k) - owed(L.k)) / 1000, (N.ca + links(L.k)) / 1000
		local st = L.st
		if not st or math.abs(Ak - st.a) >= Ck / 64 or st.r ~= L.got or st.dry ~= dry or math.abs(st.d - drain) > L.B / 8 then
			st = { a = math.floor(Ak), c = math.floor(Ck), r = L.got, d = drain, dry = dry }
			L.st = st
			msgs = msgs + 1
			local P = L.P
			later(tick + delay, function()
				P.theirs, P.seen = st, tick + delay
			end)
		end
		L.a_last, L.ggot0, L.gdrained0 = stored(L.k), N.got, N.drained
		local th = L.theirs
		if L.parked and ((th and core.has_room(th)) or tick >= L.due_offer) then
			if th and core.has_room(th) then
				L.backoff = 300 -- the nudge
			end
			local leave = L.parked
			L.parked = nil
			leave(tick)
		end
		if not th or L.busy then
			return
		end
		local a = core.amount(Ak, Ck, core.partner(th, L.sent, tick - (L.seen or tick)), th.c, L.B / 1000, links(L.k) / 1000)
		if a <= 0 then
			return
		end
		L.debt, L.due = L.debt + 1000 * a, tick + 60
		L.sent, L.busy, L.fed, inflight = L.sent + a, true, true, inflight + 1000 * a
		msgs = msgs + 1
		local P = L.P
		local T = net[P.k]
		local offer
		-- The offer leaves at tick `when`: the lane's next re-offer is due a backoff later, and the backoff doubles.
		local function leave(when)
			L.due_offer, L.backoff = when + L.backoff, math.min(L.backoff * 2, 3600)
			later(when + delay, offer)
		end
		offer = function(when)
			msgs = msgs + 2 -- the offer and its ack
			local TA, TC = stored(P.k), T.ca + links(P.k)
			-- power.lua's latch: the link interfaces only, less what they owe
			if core.starving(TA - T.acc - owed(P.k), links(P.k), P.theirs) then
				P.starved = true
			end
			local x = math.max(0, math.min(a, math.floor((TC - TA) / 1000)))
			write(P.k, TA + 1000 * x)
			P.got, T.got, a, inflight = P.got + x, T.got + x, a - x, inflight - 1000 * x
			if a > 0 and x > 0 then
				L.backoff = 300 -- an ack with progress: the rest leaves at the visit the ack wakes
				later(when + delay, leave)
			elseif a > 0 then
				L.parked = leave -- refused: a nudge or the backoff sends it
			else
				later(when + delay, function() L.backoff, L.busy = 300, false end)
			end
		end
		leave(tick)
	end
	local windows, peak, want, got = {}, 0, 0, 0
	for tick = 1, o.ticks do
		local due, keep = {}, {}
		for _, q in ipairs(queue) do
			if q.at <= tick then
				due[#due + 1] = q
			else
				keep[#keep + 1] = q
			end
		end
		table.sort(due, function(x, y) if x.at ~= y.at then return x.at < y.at end return x.seq < y.seq end)
		queue = keep
		for _, q in ipairs(due) do
			q.fn(tick)
		end
		-- the drain task (spike 22): each owing link's step, at most what its pool holds; one write a pool
		for k = 1, K do
			local have, paid = stored(k), 0
			for _, L in ipairs(net[k].links) do
				if L.debt > 0 then
					local x = core.drain_step(L.debt, L.due, tick, have - paid)
					L.debt, paid = L.debt - x, paid + x
				end
			end
			if paid > 0 then
				write(k, have - paid)
				net[k].drained = net[k].drained + paid / 1000
			end
		end
		local g = o.gen and o.gen(tick) or math.huge
		for _, L in ipairs(net[1].links) do
			local put = math.min(g, L.B - L.el)
			L.el, g, generated = L.el + put, g - put, generated + put
		end
		local put = math.min(g, net[1].ca - net[1].acc)
		net[1].acc, generated = net[1].acc + put, generated + put
		local need, have = o.load(tick), stored(K)
		local take = math.min(need, have)
		if have > 0 then
			local f = 1 - take / have
			net[K].acc = net[K].acc * f
			for _, L in ipairs(net[K].links) do
				L.el = L.el * f
			end
		end
		consumed, want, got = consumed + take, want + need, got + take
		if o.tick_cb then
			o.tick_cb(tick, need, take, chain)
		end
		for k = 1, K do
			for _, L in ipairs(net[k].links) do
				if tick % 60 == L.at then
					poll(L, tick)
				end
			end
		end
		if tick % 60 == 0 then
			windows[tick / 60] = want > 0 and got / want or 1
			want, got = 0, 0
		end
		for k = 1, K do
			for _, L in ipairs(net[k].links) do
				peak = math.max(peak, L.B)
			end
		end
		worst = math.max(worst, math.abs(total() - start - generated + consumed))
	end
	return windows, peak, worst, msgs, chain
end

--- Polls from window `from` until delivery is >= 0.99 in every window up to `to`; nil if never.
local function tofull(w, from, to)
	for i = from + 1, to do
		local ok = true
		for j = i, to do
			if w[j] < 0.99 then
				ok = false
				break
			end
		end
		if ok then
			return i - from
		end
	end
	return nil
end
local PHASES = { 0, 5, 15, 30, 45, 55 }

t.test("gate (D34, D37): 10 MW, 1 GW, 1.5 GW for 8 accumulator mixes, 6 poll phases and 2 delays: each step fully " ..
	"delivered within 12 polls, buffers within 10 GJ, energy conserved", function()
	local function load(tick)
		return (tick <= 300 and 10e6 or tick <= 1500 and 1e9 or 1.5e9) / 60
	end
	local mixes = { { 25e6, 25e6 }, { 0, 0 }, { 250e6, 25e6 }, { 5e9, 5e9 }, { 5e9, 0 }, { 1e9, 0 }, { 0, 5e9 }, { 20e9, 0 } }
	for _, delay in ipairs({ 2, 10 }) do
		for _, acc in ipairs(mixes) do
			for _, phase in ipairs(PHASES) do
				local w, peak, err = power_link({ acc = acc, delay = delay, phase = phase, ticks = 2700, load = load })
				local name = string.format("delay %d, accumulators %d/%d MJ, phase %d", delay, acc[1] / 1e6, acc[2] / 1e6, phase)
				local p1, p2 = tofull(w, 5, 25), tofull(w, 25, 45) -- 1 GW from window 6, 1.5 GW from window 26
				t.expect_true(p1 and p1 <= 12 and p2 and p2 <= 12, name .. ": polls to full " .. tostring(p1) .. ", " .. tostring(p2))
				t.expect_true(peak <= 10e9 and err < 1, name .. ": peak " .. peak .. ", error " .. err)
			end
		end
	end
end)

t.test("gate (D34, D37): brownout and recovery, a step down, a big bank beside the source, past the ceiling, and two " ..
	"parallel links", function()
	for _, delay in ipairs({ 2, 10 }) do
		for _, phase in ipairs(PHASES) do
			local name = "delay " .. delay .. ", phase " .. phase
			-- 1 GW of generation against 2 GW for 30 polls, then 20 GW against 1 GW: full again within 12 polls
			local w, peak, err = power_link({ acc = { 25e6, 25e6 }, delay = delay, phase = phase, ticks = 3600,
				gen = function(tick) return (tick <= 1800 and 1e9 or 20e9) / 60 end,
				load = function(tick) return (tick <= 1800 and 2e9 or 1e9) / 60 end })
			local p = tofull(w, 30, 60)
			t.expect_true(p and p <= 12 and peak <= 10e9 and err < 1, name .. ": brownout, recovered in " .. tostring(p))
			-- 1.5 GW from a cold start (14 polls), then 10 MW: full throughout, the surplus kept (D37)
			w, peak, err = power_link({ acc = { 25e6, 25e6 }, delay = delay, phase = phase, ticks = 3600,
				load = function(tick) return (tick <= 1200 and 1.5e9 or 10e6) / 60 end })
			p = tofull(w, 0, 60)
			t.expect_true(p and p <= 14 and peak <= 10e9 and err < 1, name .. ": step down, full in " .. tostring(p))
			-- 5 GJ beside the source, none beside the load: no fixed point below demand (review C1)
			for _, L in ipairs({ 100e6, 300e6, 1e9 }) do
				w, peak, err = power_link({ acc = { 5e9, 0 }, delay = delay, phase = phase, ticks = 1800,
					load = function() return L / 60 end })
				p = tofull(w, 0, 30)
				t.expect_true(p and p <= 14 and peak <= 10e9 and err < 1, name .. ": " .. L / 1e6 .. " MW beside a bank, full in "
					.. tostring(p))
			end
			-- 20 GW, past one link's ceiling: capped at 10 GJ, at least 2.5 GW still delivered
			w, peak, err = power_link({ acc = { 25e6, 25e6 }, delay = delay, phase = phase, ticks = 3600,
				load = function() return 20e9 / 60 end })
			local sum = 0
			for i = 41, 60 do
				sum = sum + w[i] -- each window's share of 20 GW; their sum over 20 windows is the mean in GW
			end
			t.expect_true(sum >= 2.5 and peak <= 10e9 and err < 1, name .. ": past the ceiling, " .. sum .. " GW")
			t.expect_true(sum >= 4, name .. ": F-PW2: at least 4 GW a poll at the ceiling, " .. sum .. " GW")
			-- two parallel links, each seeing the accumulators and its own interface (review I2): idle, a full bank filling
			-- an empty one grows them a little (with each counting the other's sends as drain, to 10 GJ at 5 GJ banks);
			-- under 1 GW they deliver within 14 polls; past one link's ceiling, two carry twice what one does
			_, peak, err = power_link({ n = 2, acc = { 25e6, 25e6 }, full_a = true, delay = delay, phase = phase, ticks = 1800,
				load = function() return 0 end })
			t.expect_true(peak <= 64e6 and err < 1, name .. ": two idle links, peak " .. peak)
			_, peak, err = power_link({ n = 2, acc = { 5e9, 5e9 }, full_a = true, delay = delay, phase = phase, ticks = 3600,
				gen = function() return 0 end, load = function() return 0 end })
			t.expect_true(peak <= 1e9 and err < 1, name .. ": two idle links between 5 GJ banks, peak " .. peak)
			w, peak, err = power_link({ n = 2, acc = { 25e6, 25e6 }, delay = delay, phase = phase, ticks = 3600,
				load = function() return 20e9 / 60 end })
			sum = 0
			for i = 41, 60 do
				sum = sum + w[i]
			end
			t.expect_true(sum >= 5 and peak <= 10e9 and err < 1, name .. ": two links past the ceiling, " .. sum .. " GW")
			w, peak, err = power_link({ n = 2, acc = { 25e6, 25e6 }, delay = delay, phase = phase, ticks = 1800,
				load = function() return 1e9 / 60 end })
			p = tofull(w, 0, 30)
			t.expect_true(p and p <= 14 and peak <= 10e9 and err < 1, name .. ": two links under 1 GW, full in " .. tostring(p))
		end
	end
	local _, peak = power_link({ acc = { 1e9, 1e9 }, full_a = true, delay = 2, ticks = 1200, gen = function() return 0 end,
		load = function() return 0 end })
	t.expect_true(peak <= 64e6, "a full bank filling an empty one, no load: near the floor (" .. peak .. ")")
end)

--- Windows in [from, to] where the load wasn't fully met: the receiving side ran dry in them.
local function dry(w, from, to)
	local n = 0
	for i = from, to do
		if w[i] < 0.99 then
			n = n + 1
		end
	end
	return n
end

-- Playtest 2026-10-12 #8 (gridworld_-2_0): one link feeds a tile with no accumulators from one with 800 MJ of them.
-- Bursts of 20 MW over 1 MW (drills restarting together) blacked it out at each burst: the share (link / C, C with the
-- accumulators) sent about a tenth of the excess, and the interface shrank back to the average flow after each starve.
local MW = 1e6 / 60
t.test("gate (#8): 800 MJ of accumulators feed a side with none; 1 MW stepping to 20 MW is met within 5 polls (the " ..
	"interface grows from B_MIN by doubling), and 20 MW bursts every 40 s are met in full after the first", function()
	for _, delay in ipairs({ 2, 10 }) do
		for _, phase in ipairs(PHASES) do
			local name = "delay " .. delay .. ", phase " .. phase
			local w, peak, err = power_link({ acc = { 800e6, 0 }, full_a = true, delay = delay, phase = phase, ticks = 7200,
				gen = function() return 30 * MW end, load = function(tick) return (tick <= 3600 and 1 or 20) * MW end })
			local p = tofull(w, 60, 120)
			t.expect_true(p and p <= 5 and peak <= 10e9 and err < 1, name .. ": the step, full from poll " .. tostring(p))
			w, peak, err = power_link({ acc = { 800e6, 0 }, full_a = true, delay = delay, phase = phase, ticks = 36000,
				gen = function() return 30 * MW end, load = function(tick)
					return (tick > 1200 and math.floor(tick / 60) % 40 < 10 and 20 or 1) * MW
				end })
			local d = dry(w, 60, 600)
			t.expect_true(d == 0 and peak <= 10e9 and err < 1, name .. ": bursts, " .. d .. " dry polls after the first")
		end
	end
end)

-- Chains (owner, 2026-10-13: "have you tested the power with a string of 5+ servers?"). Networks in a row, every one
-- between the ends a relay holding only its two links' interfaces; generation on the first beside 800 MJ of full
-- accumulators, and a load on the last: 1 MW stepping to 20 MW at 60 s, or 1 MW bursting to 20 MW for 10 s in every
-- 40 over 10 minutes (#8's loads). Each side of each link polls at its own tick % 60, as the poll walk's order sets it
-- in game: seeded draws.
local function walk(seed)
	local s, drawn = seed, {}
	return function(j, i, side)
		local key = j .. "/" .. i .. side
		if not drawn[key] then
			s = (s * 1103515245 + 12345) % 2147483648
			drawn[key] = math.floor(s / 65536) % 60
		end
		return drawn[key]
	end
end
local function step_load(tick)
	return (tick <= 3600 and 1 or 20) * MW
end
local function burst_load(tick)
	return (tick > 1200 and math.floor(tick / 60) % 40 < 10 and 20 or 1) * MW
end
local function chain(nets, gen, load, ticks, delay, seed)
	return power_link({ nets = nets, acc = { 800e6 }, full_a = true, delay = delay, at = walk(seed), ticks = ticks,
		gen = function() return gen * MW end, load = load })
end

-- The bounds are the model's worst over 60 runs (seeds 1 to 20, delays 1, 2 and 10) with either source, so a change
-- that slows a three-network chain fails. They are what it does, not what #8 asks of one link: bursts after the first
-- are not all met (up to 2 dry polls in 10 minutes from 30 MW, 7 from 8 MW; one link, none).
t.test("chain: three networks, A to B to C with no storage on B: the 20 MW step met within 7 polls (at most 6 dry), " ..
	"bursts at most 6 dry polls in the first and 2 (30 MW) or 7 (8 MW) after it, within 10 GJ, energy conserved", function()
	for _, delay in ipairs({ 2, 10 }) do
		for seed = 1, 10 do
			for _, gen in ipairs({ 30, 8 }) do
				local name = gen .. " MW, delay " .. delay .. ", seed " .. seed
				local w, peak, err = chain(3, gen, step_load, 5400, delay, seed)
				local p, d = tofull(w, 60, 90), dry(w, 61, 90)
				t.expect_true(p and p <= 7 and d <= 6 and peak <= 10e9 and err < 1, name .. ": the step, full from poll " ..
					tostring(p) .. ", " .. d .. " dry, peak " .. peak .. ", error " .. err)
				w, peak, err = chain(3, gen, burst_load, 36000, delay, seed)
				local first, after = dry(w, 40, 59), dry(w, 60, 600)
				t.expect_true(first <= 6 and after <= (gen == 30 and 2 or 7) and peak <= 10e9 and err < 1, name .. ": bursts, " ..
					first .. " dry polls in the first, " .. after .. " after it, peak " .. peak .. ", error " .. err)
			end
		end
	end
end)

-- Not asserted, as the far end isn't fed past three networks (for the owner, §8.2; 60 runs a case as above, 30 MW):
-- 30 polls after the step the far end was still short in 17 runs with four networks, 35 with five and 45 with six
-- (six: 0.04 to 20 MW delivered, median 3.3), and six left 5 to 139 dry polls after the first burst.
-- A link between two relays sees no demand (D34's drain leaves out every link's moves), so it grows only by the starve
-- latch, which a downstream relay's larger, part-full buffer keeps from firing. And a status isn't re-sent when only c
-- grows, so the far side's latch reads a stale c and doubles a buffer to 10 GJ under 1 MW; its relay's other link then
-- has a share of a few %, and carries next to nothing until that 10 GJ fills.
t.test("chain: six networks carry 1 MW from cold within 20 polls, within 10 GJ, energy conserved", function()
	for _, delay in ipairs({ 2, 10 }) do
		for seed = 1, 6 do
			local w, peak, err = chain(6, 30, burst_load, 36000, delay, seed)
			local d = dry(w, 20, 39)
			t.expect_true(d == 0 and peak <= 10e9 and err < 1, "delay " .. delay .. ", seed " .. seed .. ": " .. d ..
				" dry polls at 1 MW, peak " .. peak .. ", error " .. err)
		end
	end
end)

--- Two pools, X (full) and Y (empty), joined by n links, each side of each link polling once a step in a random order.
--- A status ({ a, c, r }) is sent when a side's amount moved by c/64; shipments, acks and statuses take 0 to `delay`
--- steps, in order per link; a link sends only with nothing unacknowledged (F6). Returns the worst overshoot (Y's fill
--- ratio above X's) and the final difference; errors if anything is created or lost.
local function parallel(n, delay, seed)
	local s = seed
	local function r(m)
		s = (s * 1103515245 + 12345) % 2147483648
		return math.floor(s / 65536) % m + 1
	end
	local C, P = { X = 100000, Y = 60000 }, { X = 100000, Y = 0 }
	local link = { X = math.floor(C.X / n), Y = math.floor(C.Y / n) }
	local other = { X = "Y", Y = "X" }
	local links, queue, inflight = {}, {}, 0
	for i = 1, n do
		links[i] = { X = { sent = 0, got = 0, seq = 0 }, Y = { sent = 0, got = 0, seq = 0 } }
	end
	local function later(at, fn)
		queue[#queue + 1] = { at = at + r(delay + 1) - 1, fn = fn }
	end
	local worst = 0
	for step = 1, 10000 do
		local due, keep = {}, {}
		for _, q in ipairs(queue) do
			if q.at <= step then
				due[#due + 1] = q
			else
				keep[#keep + 1] = q
			end
		end
		queue = keep
		for _, q in ipairs(due) do
			q.fn(step)
		end
		local order = {}
		for i = 1, n do
			order[#order + 1] = { i, "X" }
			order[#order + 1] = { i, "Y" }
		end
		for k = #order, 2, -1 do
			local j = r(k)
			order[k], order[j] = order[j], order[k]
		end
		for _, o in ipairs(order) do
			local i, me = o[1], o[2]
			local L, you = links[i][me], other[me]
			if not L.last or math.abs(P[me] - L.last) >= C[me] / 64 then
				L.last, L.seq = P[me], L.seq + 1
				local st = { a = P[me], c = C[me], r = L.got, seq = L.seq }
				later(step, function()
					local R = links[i][you]
					if not R.status or R.status.seq < st.seq then
						R.status = st
					end
				end)
			end
			if not L.busy and L.status then
				local a = core.amount(P[me], C[me], core.partner(L.status, L.sent), L.status.c, link[me])
				if a > 0 then
					P[me], L.busy, L.sent, inflight = P[me] - a, true, L.sent + a, inflight + a
					local function offer(at)
						local R = links[i][you]
						local x = math.min(a, C[you] - P[you])
						P[you], R.got, inflight, a = P[you] + x, R.got + x, inflight - x, a - x
						if a > 0 then
							later(at + 1, offer)
						else
							later(at, function() L.busy = false end)
						end
					end
					later(step, offer)
				end
			end
		end
		if P.X + P.Y + inflight ~= 100000 then
			error("created or lost at step " .. step .. ": " .. (P.X + P.Y + inflight - 100000))
		end
		worst = math.max(worst, P.Y / C.Y - P.X / C.X)
	end
	return worst, math.abs(P.Y / C.Y - P.X / C.X)
end

t.test("balance: 1, 2 and 5 parallel links with stale statuses: exact, converged, no overshoot past the dead band", function()
	for _, n in ipairs({ 1, 2, 5 }) do
		for seed = 1, 3 do
			local worst, final = parallel(n, 1, seed)
			t.expect_true(worst <= 1 / 64, n .. " links, seed " .. seed .. ": overshoot " .. worst)
			t.expect_true(final <= 1 / 64, n .. " links, seed " .. seed .. ": still apart by " .. final)
		end
	end
end)

t.test("balance: one link whose statuses lag two periods doesn't overshoot (plan ruling 2)", function()
	for seed = 1, 3 do
		local worst, final = parallel(1, 2, seed)
		t.expect_true(worst <= 1 / 64 and final <= 1 / 64, "seed " .. seed .. ": " .. worst .. ", " .. final)
	end
end)

t.test("drain_step (spike 22): a send's debt is paid in equal steps over the ticks to its due tick", function()
	t.expect_eq(core.drain_step(60000, 160, 100, 1e9), 1000, "60 kJ over 60 ticks: 1 kJ a tick")
	t.expect_eq(core.drain_step(59000, 160, 101, 1e9), 1000, "the same rate a tick later")
	t.expect_eq(core.drain_step(1000, 160, 159, 1e9), 1000, "the last tick takes what is left")
	t.expect_eq(core.drain_step(1000, 160, 160, 1e9), 1000, "due: the whole debt")
	t.expect_eq(core.drain_step(1000, 160, 170, 1e9), 1000, "overdue: the whole debt")
end)

t.test("drain_step: a pool that can't pay takes what it has, and zero debt takes nothing", function()
	t.expect_eq(core.drain_step(60000, 160, 100, 400), 400, "a shortfall stays as debt")
	t.expect_eq(core.drain_step(60000, 160, 100, 0), 0, "an empty pool")
	t.expect_eq(core.drain_step(0, 160, 100, 1e9), 0, "no debt")
end)
