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
end)

t.test("balance: a partner's status shows room for a refused remainder from c/64 free, its re-announce step", function()
	t.expect_true(core.has_room({ a = 0, c = 6400 }), "empty")
	t.expect_true(core.has_room({ a = 6300, c = 6400 }), "exactly c/64 free")
	t.expect_true(not core.has_room({ a = 6301, c = 6400 }), "less: can't be told from full")
	t.expect_true(not core.has_room({ a = 6400, c = 6400 }), "full")
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
