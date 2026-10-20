local t = require("testlib")
local core = require("modules/universal_edges/edges/ledger_core")

--- A test ctx: records hook calls, events and counters. credit returns what `accept(deltas)` says (default: all).
local function ctx(fields)
	local c = {
		tick = 1000, boot = "b1", can_credit = true, stream_trace = false, calls = {}, events = {}, counts = {},
		accept = function(deltas) return deltas end,
		outcome = "ok",
		committed = true,
	}
	for k, v in pairs(fields or {}) do
		c[k] = v
	end
	function c.credit(payload)
		c.calls[#c.calls + 1] = { "credit", payload }
		if type(payload) == "table" and c.kind ~= "unique" then
			return c.accept(payload)
		end
		return c.outcome
	end
	function c.commit(entry)
		c.calls[#c.calls + 1] = { "commit", entry.seq }
		return c.committed
	end
	function c.give_back(hook, x)
		c.calls[#c.calls + 1] = { hook, x }
	end
	function c.decode(body)
		return body ~= "garbage" and { body = body } or nil
	end
	function c.event(op, phase, level, f)
		c.events[#c.events + 1] = { op = op, phase = phase, level = level, fields = f }
	end
	function c.count(kind)
		c.counts[kind] = (c.counts[kind] or 0) + 1
	end
	local n = 0
	function c.trace()
		n = n + 1
		return "b1." .. n
	end
	return c
end

local function phases(c)
	local out = {}
	for _, e in ipairs(c.events) do
		out[#out + 1] = e.op .. " " .. e.phase
	end
	return table.concat(out, ",")
end

-- Stream (§11.3) -------------------------------------------------------------------------------------------------------

t.test("stream: a capture is offered at the next visit, then again only after the backoff, which doubles", function()
	local tx, c = core.new("stream", "tx"), ctx()
	core.capture(tx, { iron = 40, copper = 0 }, nil, c)
	t.expect_same(core.pending(tx), { iron = 40 }, "a zero amount is no key")
	local msgs = core.visit(tx, c)
	t.expect_same(msgs, { { k = "s.offer", totals = { iron = 40 } } })
	t.expect_eq(core.visit(tx, c), nil, "not again before the backoff")
	c.tick = 1300
	t.expect_eq(#core.visit(tx, c), 1, "again after 300 ticks")
	c.tick = 1899
	t.expect_eq(core.visit(tx, c), nil, "then 600")
	c.tick = 1900
	t.expect_eq(#core.visit(tx, c), 1)
end)

t.test("stream: a capture checks the whole bag first, and a total never passes MAX_TOTAL", function()
	local tx, c = core.new("stream", "tx"), ctx()
	t.expect_error(function() core.capture(tx, { iron = 5, bad = 1.5 }, nil, c) end, "whole amounts")
	t.expect_same(tx.sent, {}, "nothing of a bad bag is taken")
	t.expect_error(function() core.capture(tx, { [1] = 5 }, nil, c) end, "string keys")
	core.capture(tx, { iron = core.MAX_TOTAL }, nil, c)
	t.expect_error(function() core.capture(tx, { iron = 1 }, nil, c) end, "would pass")
end)

t.test("stream: more than 32 pending keys go out as several offers of at most 32", function()
	local tx, c = core.new("stream", "tx"), ctx()
	local bag = {}
	for i = 1, 70 do
		bag["k" .. i] = i
	end
	core.capture(tx, bag, nil, c)
	local msgs = core.visit(tx, c)
	t.expect_eq(#msgs, 3)
	local keys = 0
	for _, m in ipairs(msgs) do
		local n = 0
		for _ in pairs(m.totals) do
			n = n + 1
		end
		t.expect_true(n <= 32, "at most 32 keys")
		keys = keys + n
	end
	t.expect_eq(keys, 70)
end)

t.test("stream: the destination credits only the delta, clamped to what the transport accepts (partial credit)", function()
	local rx = core.new("stream", "rx")
	local c = ctx({ accept = function(d) return { iron = math.min(d.iron, 25) } end })
	local reply = core.receive(rx, { k = "s.offer", totals = { iron = 40 } }, c)
	t.expect_same(reply, { { k = "s.ack", totals = { iron = 25 } } })
	t.expect_same(c.calls[1], { "credit", { iron = 40 } })
	c.accept = function() return { iron = 999 } end
	reply = core.receive(rx, { k = "s.offer", totals = { iron = 40 } }, c)
	t.expect_same(c.calls[2], { "credit", { iron = 15 } }, "the next offer credits only what is missing")
	t.expect_same(reply[1].totals, { iron = 40 }, "an over-report is clamped to the delta")
end)

t.test("stream: offers are order-free and idempotent: an old or repeated total credits nothing", function()
	local rx, c = core.new("stream", "rx"), ctx()
	core.receive(rx, { k = "s.offer", totals = { iron = 70 } }, c)
	local reply = core.receive(rx, { k = "s.offer", totals = { iron = 40 } }, c)
	t.expect_eq(#c.calls, 1, "the late, smaller total calls no credit")
	t.expect_same(reply[1].totals, { iron = 70 }, "but still acks recv")
	core.receive(rx, { k = "s.offer", totals = { iron = 70 } }, c)
	t.expect_eq(#c.calls, 1, "a repeat calls no credit")
end)

t.test("stream: an unready, failed-hook or closing destination credits nothing but still acks", function()
	local rx = core.new("stream", "rx")
	local reply = core.receive(rx, { k = "s.offer", totals = { iron = 10 } }, ctx({ can_credit = false }))
	t.expect_same(reply[1].totals, { iron = 0 })
	local failing = ctx({ accept = function() return nil end })
	core.receive(rx, { k = "s.offer", totals = { iron = 10 } }, failing)
	t.expect_same(rx.recv, {}, "a failed credit hook changes nothing (G6)")
	core.close(rx, 9, 1000)
	local closed = ctx()
	reply = core.receive(rx, { k = "s.offer", totals = { iron = 10 } }, closed)
	t.expect_eq(#closed.calls, 0, "a closing destination is frozen")
	t.expect_same(reply[1].totals, { iron = 0 })
end)

t.test("stream: a malformed offer or ack is refused (G5)", function()
	local rx, tx, c = core.new("stream", "rx"), core.new("stream", "tx"), ctx()
	t.expect_eq(core.receive(rx, { k = "s.offer", totals = { iron = -1 } }, c), false)
	t.expect_eq(core.receive(rx, { k = "s.offer", totals = "x" }, c), false)
	local big = {}
	for i = 1, 33 do
		big["k" .. i] = 1
	end
	t.expect_eq(core.receive(rx, { k = "s.offer", totals = big }, c), false, "more than 32 keys")
	t.expect_eq(core.receive(tx, { k = "s.ack", totals = { iron = 0.5 } }, c), false)
	t.expect_eq(core.receive(tx, { k = "u.reply" }, c), false, "a message for another lane kind")
end)

t.test("stream: an ack is assigned; a key stays pending while sent > acked; progress resets the backoff", function()
	local tx, c = core.new("stream", "tx"), ctx()
	core.capture(tx, { iron = 40 }, nil, c)
	core.visit(tx, c)
	c.tick = 1300
	core.visit(tx, c)
	t.expect_eq(tx.backoff, 1200, "two offers without progress")
	core.receive(tx, { k = "s.ack", totals = { iron = 25 } }, c)
	t.expect_eq(tx.backoff, 300, "progress resets it")
	t.expect_same(core.pending(tx), { iron = 15 })
	t.expect_same(core.visit(tx, c), { { k = "s.offer", totals = { iron = 40 } } }, "and re-offers at once")
	core.receive(tx, { k = "s.ack", totals = { iron = 40 } }, c)
	t.expect_same(core.pending(tx), {}, "fully acknowledged")
	core.receive(tx, { k = "s.ack", totals = { iron = 30 } }, c)
	t.expect_same(core.pending(tx), { iron = 10 }, "a lower ack (the destination rolled back) makes it pending again")
end)

t.test("stream: a zero-progress ack waits out the backoff; a nudge re-offers at the next visit, from BACKOFF_MIN; a " ..
	"nudge on an idle lane does nothing (final fix wave addendum)", function()
	local tx, c = core.new("stream", "tx"), ctx()
	core.capture(tx, { e = 10 }, nil, c)
	t.expect_true(core.visit(tx, c) ~= nil, "the first offer")
	core.receive(tx, { k = "s.ack", totals = { e = 0 } }, c) -- the destination was full: it took none of it
	c.tick = 1000 + core.BACKOFF_MIN - 1
	t.expect_eq(core.visit(tx, c), nil, "zero progress: still waiting out BACKOFF_MIN (300)")
	core.nudge(tx)
	t.expect_same(core.visit(tx, c), { { k = "s.offer", totals = { e = 10 } } }, "nudged: re-offered at this visit")
	c.tick = c.tick + core.BACKOFF_MIN - 1
	t.expect_eq(core.visit(tx, c), nil, "refused again, it waits BACKOFF_MIN, not the doubled backoff it had")
	c.tick = c.tick + 1
	t.expect_true(core.visit(tx, c) ~= nil, "and re-offers once BACKOFF_MIN has passed")
	local idle = core.new("stream", "tx")
	idle.next_send, idle.backoff = 5000, 1200
	core.nudge(idle)
	t.expect_true(idle.next_send == 5000 and idle.backoff == 1200, "nothing pending: a nudge changes nothing")
end)

t.test("stream: acked above sent means this source rolled back; absorbing is logged once per activation", function()
	local tx, c = core.new("stream", "tx"), ctx()
	core.capture(tx, { iron = 10 }, nil, c)
	core.receive(tx, { k = "s.ack", totals = { iron = 50 } }, c)
	core.receive(tx, { k = "s.ack", totals = { iron = 60 } }, c)
	t.expect_eq(phases(c), "ue.lane absorbing")
	t.expect_eq(c.events[1].level, "warn")
	core.activate(tx)
	core.receive(tx, { k = "s.ack", totals = { iron = 60 } }, c)
	t.expect_eq(phases(c), "ue.lane absorbing,ue.lane absorbing", "again after an activation")
end)

t.test("stream: an activation re-offers every key ever sent, acknowledged or not (§11.2)", function()
	local tx, c = core.new("stream", "tx"), ctx()
	core.capture(tx, { iron = 10, copper = 5 }, nil, c)
	core.receive(tx, { k = "s.ack", totals = { iron = 10, copper = 5 } }, c)
	t.expect_eq(core.visit(tx, c), nil, "nothing pending")
	core.activate(tx)
	t.expect_same(core.visit(tx, c), { { k = "s.offer", totals = { iron = 10, copper = 5 } } })
end)

t.test("stream: the debug switch traces each offer, its credit and its ack under one trace (D12)", function()
	local tx, rx = core.new("stream", "tx"), core.new("stream", "rx")
	local src, dst = ctx({ stream_trace = true }), ctx()
	core.capture(tx, { iron = 10 }, nil, src)
	local offer = core.visit(tx, src)[1]
	t.expect_eq(offer.trace, "b1.1")
	local ack = core.receive(rx, offer, dst)[1]
	t.expect_eq(ack.trace, "b1.1", "the ack carries the offer's trace")
	core.receive(tx, ack, src)
	t.expect_eq(phases(src), "ue.transfer offer,ue.transfer ack")
	t.expect_eq(phases(dst), "ue.transfer credit")
	t.expect_same(dst.events[1].fields.accepted, { iron = 10 })
	local quiet = ctx()
	core.capture(tx, { iron = 1 }, nil, quiet)
	quiet.tick = 99999
	t.expect_eq(core.visit(tx, quiet)[1].trace, nil, "off by default: no trace, no line")
	t.expect_eq(#quiet.events, 0)
end)

-- Closing (§11.7) -------------------------------------------------------------------------------------------------------

t.test("closing: a destination sends its final at once, then every 3600 ticks and on every close, until done", function()
	local rx, c = core.new("stream", "rx"), ctx()
	core.receive(rx, { k = "s.offer", totals = { iron = 30 } }, c)
	t.expect_true(core.close(rx, 9, 1000))
	t.expect_true(not core.close(rx, 10, 1001), "closing twice changes nothing")
	t.expect_same(core.visit(rx, c), { { k = "s.final", recv = { iron = 30 } } }, "at once")
	t.expect_eq(core.visit(rx, c), nil)
	c.tick = 4600
	t.expect_eq(core.visit(rx, c)[1].k, "s.final", "again after 3600")
	t.expect_same(core.receive(rx, { k = "close", rev = 9, kind = "stream" }, c), { { k = "s.final", recv = { iron = 30 } } })
	core.receive(rx, { k = "done" }, c)
	t.expect_true(rx.dropped, "dropped on done")
end)

t.test("closing: a stream source refunds sent − the final recv, sends done at once and is dropped", function()
	local tx, c = core.new("stream", "tx"), ctx()
	core.capture(tx, { iron = 100, copper = 7 }, nil, c)
	core.receive(tx, { k = "s.ack", totals = { iron = 40 } }, c)
	core.close(tx, 9, 1000)
	t.expect_same(core.visit(tx, c), { { k = "close", rev = 9, kind = "stream" } }, "close on the first visit")
	t.expect_eq(core.visit(tx, c), nil, "then every 3600 ticks")
	-- The ack of 40 is stale: the destination had credited 70 when it froze, so the refund is 30, not 60.
	local reply = core.receive(tx, { k = "s.final", recv = { iron = 70 } }, c)
	t.expect_same(reply, { { k = "done" } })
	t.expect_same(c.calls[1], { "refund", { iron = 30, copper = 7 } })
	t.expect_true(tx.dropped)
	t.expect_eq(phases(c), "ue.lane closed")
end)

t.test("closing: a live source ignores a final and counts it; a closing one ignores acks", function()
	local tx, c = core.new("stream", "tx"), ctx()
	core.capture(tx, { iron = 10 }, nil, c)
	t.expect_eq(core.receive(tx, { k = "s.final", recv = {} }, c), nil)
	t.expect_eq(c.counts.finals_ignored, 1)
	t.expect_eq(#c.calls, 0, "no refund")
	core.close(tx, 9, 1000)
	core.receive(tx, { k = "s.ack", totals = { iron = 10 } }, c)
	t.expect_same(tx.acked, {}, "a closing source waits for the final instead")
	t.expect_error(function() core.capture(tx, { iron = 1 }, nil, c) end, "closing lane")
end)

t.test("closing: the unknown-lane rules: done for a final, and a zero-state final gated by the revision", function()
	t.expect_same(core.unknown_final(), { { k = "done" } })
	local close = { k = "close", rev = 9, kind = "stream" }
	t.expect_eq(core.unknown_close(close, 8), nil, "this side hasn't applied the removal yet: it waits")
	t.expect_same(core.unknown_close(close, 9), { { k = "s.final", recv = {} } }, "it never had the lane")
	t.expect_eq(core.unknown_close({ k = "close", rev = "9", kind = "stream" }, 20), nil, "malformed")
end)

t.test("closing: best knowledge refunds sent − acked; a destination lane is simply dropped", function()
	local tx, rx, c = core.new("stream", "tx"), core.new("stream", "rx"), ctx()
	core.capture(tx, { iron = 100 }, nil, c)
	core.receive(tx, { k = "s.ack", totals = { iron = 40 } }, c)
	core.force(tx, c)
	t.expect_same(c.calls[1], { "refund", { iron = 60 } })
	t.expect_true(tx.dropped)
	core.force(rx, c)
	t.expect_true(rx.dropped and #c.calls == 1)
end)

t.test("closing: past 64 unresolved source lanes on a side, the oldest are forced", function()
	local entries = {}
	for i = 1, 66 do
		local lane = core.new("stream", "tx")
		core.close(lane, 1, 1000 + (i % 3))
		entries[i] = { key = string.format("e/c%02d/ab", i), lane = lane }
	end
	local forced = core.over_cap(entries)
	t.expect_eq(#forced, 2)
	t.expect_eq(forced[1].key, "e/c03/ab", "the earliest since_tick first, then by key")
	t.expect_eq(forced[2].key, "e/c06/ab")
	t.expect_same(core.over_cap({ entries[1] }), {}, "under the cap, nothing")
end)

t.test("closing: an activation re-sends a closing lane's close or final at once", function()
	local tx, c = core.new("stream", "tx"), ctx()
	core.close(tx, 9, 1000)
	core.visit(tx, c)
	t.expect_eq(core.visit(tx, c), nil)
	core.activate(tx)
	t.expect_eq(core.visit(tx, c)[1].k, "close")
end)

t.test("idle: a visit with nothing due is skipped without a ctx (§12 rule 4)", function()
	local tx, rx, c = core.new("stream", "tx"), core.new("stream", "rx"), ctx()
	t.expect_true(core.idle(tx, 1000) and core.idle(rx, 1000), "nothing pending, a destination")
	core.capture(tx, { iron = 1 }, nil, c)
	t.expect_true(not core.idle(tx, 1000), "a pending key is due")
	core.visit(tx, c)
	t.expect_true(core.idle(tx, 1000) and not core.idle(tx, 1300), "then after the backoff")
	core.close(rx, 9, 1000)
	t.expect_true(not core.idle(rx, 1000), "a closing destination's final is due at once")
end)

-- Unique (§11.4, §11.5) -------------------------------------------------------------------------------------------------

local function offer(seq, tag, digest, body)
	return { k = "u.offer", seq = seq, tag = tag, digest = digest or ("d" .. seq), body = body or ("t" .. seq),
		trace = "tr." .. seq }
end

--- A destination that has credited seqs 1..n under tag.
local function credited(n, tag, c)
	local rx = core.new("unique", "rx")
	for seq = 1, n do
		core.receive(rx, offer(seq, tag), c)
	end
	return rx
end

t.test("unique: mint gives the lane's next seq, tagged with the capture boot", function()
	local tx = core.new("unique", "tx")
	t.expect_eq(select(2, core.mint(tx, "b1")), "b1")
	t.expect_eq(core.mint(tx, "b2"), 2)
	t.expect_eq(tx.next_seq, 3)
end)

t.test("unique: one capture at a time; the in-flight offer is re-sent every backoff", function()
	local tx, c = core.new("unique", "tx"), ctx({ kind = "unique" })
	t.expect_true(core.can_send(tx))
	t.expect_eq(core.capture(tx, "body1", "tr.1", c), 1)
	t.expect_true(not core.can_send(tx), "nothing more until the reply")
	t.expect_error(function() core.capture(tx, "body2", "tr.2", c) end, "one capture at a time")
	t.expect_eq(core.pending(tx), 1)
	t.expect_same(core.visit(tx, c), { { k = "u.offer", seq = 1, tag = "b1", trace = "tr.1", body = "body1" } })
	t.expect_eq(core.visit(tx, c), nil)
	c.tick = 1300
	t.expect_eq(core.visit(tx, c)[1].seq, 1, "the same seq after the backoff")
end)

t.test("classify: new, gap, and a same-tag repeat without the ring", function()
	local c = ctx({ kind = "unique" })
	local rx = credited(3, "T", c)
	t.expect_eq(core.classify(rx, 4, "T", "d4"), "new")
	t.expect_eq(core.classify(rx, 6, "T", "d6"), "gap")
	rx.ring = {}
	t.expect_eq(core.classify(rx, 2, "T", "anything"), "repeat", "same tag at or below w: no ring needed")
end)

t.test("classify: a same-tag recorded reject is answered reject again", function()
	local c = ctx({ kind = "unique", outcome = "reject" })
	local rx = credited(1, "T", c)
	t.expect_eq(rx.w, 1, "a reject still moves w")
	local reply = core.receive(rx, offer(1, "T"), ctx({ kind = "unique" }))
	t.expect_eq(reply[1].outcome, "reject")
end)

t.test("classify: a different tag goes through the digest: a match is a repeat, a mismatch divergent", function()
	local c = ctx({ kind = "unique" })
	local rx = credited(3, "T", c)
	t.expect_eq(core.classify(rx, 2, "U", "d2"), "repeat", "an identical replay after a source rollback")
	t.expect_eq(core.classify(rx, 2, "U", "other"), "divergent")
	local reply = core.receive(rx, offer(2, "U", "other"), c)
	t.expect_eq(reply[1].outcome, "divergent")
	t.expect_eq(rx.w, 3, "w is never lowered, or moved, by a divergent credit")
	t.expect_eq(rx.tag, "T")
	t.expect_eq(rx.ring[2].digest, "other", "the slot takes the new digest")
end)

t.test("classify: an evicted slot makes a different-tag replay divergent (duplication, never loss)", function()
	local c = ctx({ kind = "unique" })
	local rx = credited(40, "T", c)
	t.expect_eq(core.classify(rx, 3, "U", "d3"), "divergent", "slot 3 now holds seq 35")
	t.expect_eq(core.classify(rx, 35, "U", "d35"), "repeat")
end)

t.test("offer: busy and an unready destination change nothing; an undecodable body is rejected (G5)", function()
	local rx = core.new("unique", "rx")
	local busy = ctx({ kind = "unique", outcome = "busy" })
	t.expect_eq(core.receive(rx, offer(1, "T"), busy)[1].outcome, "busy")
	t.expect_eq(rx.w, 0)
	t.expect_eq(core.receive(rx, offer(1, "T"), ctx({ kind = "unique", can_credit = false }))[1].outcome, "busy")
	local failing = ctx({ kind = "unique" })
	failing.outcome = nil -- credit returns nil: the hook failed
	t.expect_eq(core.receive(rx, offer(1, "T"), failing)[1].outcome, "busy", "a failed credit hook changes nothing")
	local c = ctx({ kind = "unique" })
	local reply = core.receive(rx, offer(1, "T", "d1", "garbage"), c)
	t.expect_eq(reply[1].outcome, "reject")
	t.expect_eq(#c.calls, 0, "credit is never called for an undecodable body")
	t.expect_eq(core.receive(rx, { k = "u.offer", seq = 0, tag = "T", digest = "d", body = "b" }, c), false)
end)

t.test("offer: every reply carries w; a closing destination answers busy without classifying", function()
	local c = ctx({ kind = "unique" })
	local rx = credited(2, "T", c)
	t.expect_same(core.receive(rx, offer(5, "T"), c), { { k = "u.reply", seq = 5, outcome = "gap", w = 2, trace = "tr.5" } })
	core.close(rx, 9, 1000)
	t.expect_eq(core.receive(rx, offer(3, "T"), c)[1].outcome, "busy")
	t.expect_eq(rx.w, 2)
end)

--- A source with seq 1 in flight, and a ctx.
local function inflight()
	local tx, c = core.new("unique", "tx"), ctx({ kind = "unique" })
	core.capture(tx, "body1", "tr.1", c)
	core.visit(tx, c)
	return tx, c
end

local function reply(outcome, seq)
	return { k = "u.reply", seq = seq or 1, outcome = outcome, w = 1, trace = "tr.1" }
end

t.test("reply: credited, repeat and divergent commit once and drop the body (D8)", function()
	for _, outcome in ipairs({ "credited", "repeat", "divergent" }) do
		local tx, c = inflight()
		t.expect_eq(core.receive(tx, reply(outcome), c), nil)
		t.expect_same(c.calls, { { "commit", 1 } }, outcome)
		t.expect_eq(tx.inflight, nil, "nothing is kept")
		t.expect_true(core.can_send(tx))
		t.expect_eq(phases(c), "ue.transfer ack")
	end
end)

t.test("reply: a failed commit hook keeps the entry in flight (G6)", function()
	local tx, c = inflight()
	c.committed = false
	core.receive(tx, reply("credited"), c)
	t.expect_true(tx.inflight ~= nil)
end)

t.test("reply: busy backs off; reject restores; a reply for another seq is counted and ignored", function()
	local tx, c = inflight()
	core.receive(tx, reply("busy"), c)
	t.expect_true(tx.inflight ~= nil and #c.calls == 0)
	core.receive(tx, reply("credited", 7), c)
	t.expect_eq(c.counts.stale_replies, 1)
	core.receive(tx, reply("reject"), c)
	t.expect_eq(c.calls[1][1], "restore")
	t.expect_eq(c.calls[1][2].seq, 1)
	t.expect_eq(tx.inflight, nil)
	t.expect_eq(phases(c), "ue.transfer busy,ue.transfer restore")
end)

t.test("reply: gap is answered with u.skip { to = seq − 1 } and an immediate re-offer", function()
	local tx, c = core.new("unique", "tx"), ctx({ kind = "unique" })
	tx.next_seq = 6
	core.capture(tx, "body6", "tr.6", c)
	core.visit(tx, c)
	t.expect_same(core.receive(tx, reply("gap", 6), c), { { k = "u.skip", to = 5 } })
	t.expect_eq(core.visit(tx, c)[1].seq, 6, "re-offered at once")
end)

t.test("skip: w = max(w, to), and the lost range is logged at error", function()
	local c = ctx({ kind = "unique" })
	local rx = credited(2, "T", c)
	c.events = {}
	core.receive(rx, { k = "u.skip", to = 5 }, c)
	t.expect_eq(rx.w, 5)
	t.expect_same(c.events[1], { op = "ue.transfer", phase = "lost", level = "error", fields = { from = 3, to = 5 } })
	core.receive(rx, { k = "u.skip", to = 4 }, c)
	t.expect_eq(rx.w, 5, "never lowered")
	t.expect_eq(#c.events, 1)
end)

t.test("closing: a unique source commits when the final has exactly its capture, and restores otherwise", function()
	local cases = {
		{ final = { k = "u.final", w = 1, tag = "b1" }, hook = "commit" },
		{ final = { k = "u.final", w = 3, tag = "b1" }, hook = "commit" },
		{ final = { k = "u.final", w = 0 }, hook = "restore" },
		{ final = { k = "u.final", w = 1, tag = "other" }, hook = "restore" },
		{ final = { k = "u.final", w = 1, tag = "b1", rejected = true }, hook = "restore" },
	}
	for i, case in ipairs(cases) do
		local tx, c = inflight()
		core.close(tx, 9, 1000)
		t.expect_same(core.receive(tx, case.final, c), { { k = "done" } }, "case " .. i)
		t.expect_eq(c.calls[1][1], case.hook, "case " .. i)
		t.expect_true(tx.dropped)
	end
end)

t.test("closing: a unique final names a rejected w, so a reply lost before a removal can't turn into a commit", function()
	local c = ctx({ kind = "unique", outcome = "reject" })
	local rx = credited(1, "b1", c)
	core.close(rx, 9, 1000)
	t.expect_same(core.visit(rx, c), { { k = "u.final", w = 1, tag = "b1", rejected = true } })
	local ok = credited(1, "b1", ctx({ kind = "unique" }))
	core.close(ok, 9, 1000)
	t.expect_same(core.visit(ok, c), { { k = "u.final", w = 1, tag = "b1" } })
	t.expect_same(core.unknown_close({ k = "close", rev = 9, kind = "unique" }, 9), { { k = "u.final", w = 0 } })
end)

t.test("closing: best knowledge restores the in-flight entry; a closing source ignores replies", function()
	local tx, c = inflight()
	core.close(tx, 9, 1000)
	core.receive(tx, reply("credited"), c)
	t.expect_eq(#c.calls, 0, "a closing source ignores all replies")
	core.force(tx, c)
	t.expect_eq(c.calls[1][1], "restore")
	t.expect_true(tx.dropped)
end)

t.test("idle: a unique source is due only with something in flight", function()
	local tx, c = core.new("unique", "tx"), ctx({ kind = "unique" })
	t.expect_true(core.idle(tx, 1000))
	core.capture(tx, "b", "tr", c)
	t.expect_true(not core.idle(tx, 1000))
	core.visit(tx, c)
	t.expect_true(core.idle(tx, 1000))
end)

-- Ordered (SP3 spec §7.3, F11) -----------------------------------------------------------------------------------------

--- An ordered ctx: credit takes the list and accepts `accept` items from its front (default: all), recording the list.
local function octx(fields)
	local c = ctx(fields)
	c.taken, c.lists = {}, {}
	function c.credit(list)
		c.lists[#c.lists + 1] = list
		local total = 0
		for _, x in ipairs(list) do
			total = total + x[2]
		end
		local a = math.min(c.accept_items or total, total)
		local left = a
		for _, x in ipairs(list) do
			local take = math.min(x[2], left)
			if take > 0 then
				c.taken[#c.taken + 1] = x[1] .. "x" .. take
			end
			left = left - take
		end
		return a
	end
	return c
end

t.test("ordered: a capture appends every run as it comes, never extending an unacknowledged one, and caps at 64", function()
	local tx, c = core.new("ordered", "tx"), octx()
	core.capture(tx, { { "a", 2 }, { "b", 1 } }, nil, c)
	core.capture(tx, { { "b", 3 }, { "a", 0 }, { "a", 1 } }, nil, c)
	t.expect_same(tx.runs, { { "a", 2, 2 }, { "b", 1, 1 }, { "b", 3, 4 }, { "a", 1, 3 } },
		"b's second send is its own run; a zero amount is no run")
	t.expect_same(tx.sent, { a = 3, b = 4 })
	t.expect_eq(core.runs(tx), 4)
	local many = {}
	for i = 1, 60 do
		many[i] = { i % 2 == 0 and "a" or "b", 1 }
	end
	core.capture(tx, many, nil, c)
	t.expect_eq(core.runs(tx), 64, "4 runs, then 60")
	t.expect_error(function() core.capture(tx, { { "b", 1 } }, nil, c) end, "at most 64 unacknowledged runs")
	t.expect_eq(core.runs(tx), 64, "nothing of a refused capture is taken")
	t.expect_error(function() core.capture(tx, { { "a", 1.5 } }, nil, c) end, "array of at most")
	t.expect_error(function() core.capture(tx, { a = 1 }, nil, c) end, "array of at most")
	t.expect_error(function() core.capture(tx, { { "a", 1, { -1 } } }, nil, c) end, "array of at most")
end)

t.test("ordered: an offer carries every run since the last ack; the ack drops the front runs it covers", function()
	local tx, c = core.new("ordered", "tx"), octx()
	core.capture(tx, { { "a", 2 }, { "b", 1 } }, nil, c)
	t.expect_same(core.visit(tx, c), { { k = "o.offer", runs = { { "a", 2, 2 }, { "b", 1, 1 } } } })
	core.capture(tx, { { "a", 1 } }, nil, c)
	c.tick = 1300
	t.expect_same(core.visit(tx, c), { { k = "o.offer", runs = { { "a", 2, 2 }, { "b", 1, 1 }, { "a", 1, 3 } } } },
		"the first offer's runs again: nothing was acknowledged")
	t.expect_eq(core.receive(tx, { k = "s.ack", totals = { a = 2, b = 0 } }, c), nil)
	t.expect_eq(core.runs(tx), 2, "the covered front run goes; b's isn't covered, so it and what follows stay")
	core.receive(tx, { k = "s.ack", totals = { a = 2, b = 1 } }, c)
	t.expect_same(tx.runs, { { "a", 1, 3 } }, "the two covered front runs are dropped")
	core.receive(tx, { k = "s.ack", totals = { a = 3 } }, c)
	t.expect_eq(core.runs(tx), 0)
	t.expect_eq(tx.npending, 0, "nothing unacknowledged, so ep:idle is true (F6)")
	t.expect_eq(core.visit(tx, c), nil, "and nothing to offer")
end)

t.test("ordered: an offer shares the stored runs, none copied, and a later capture only appends (perf item 3)", function()
	local tx, c = core.new("ordered", "tx"), octx()
	core.capture(tx, { { "a", 2 }, { "b", 1 } }, nil, c)
	local first = core.visit(tx, c)
	t.expect_eq(first[1].runs[2], tx.runs[2], "the tail run is shared too: runs never change after their send")
	core.capture(tx, { { "b", 3 } }, nil, c)
	t.expect_same(first[1].runs, { { "a", 2, 2 }, { "b", 1, 1 } }, "the earlier offer is untouched")
	c.tick = 1300
	t.expect_same(core.visit(tx, c)[1].runs, { { "a", 2, 2 }, { "b", 1, 1 }, { "b", 3, 4 } })
	core.receive(tx, { k = "s.ack", totals = { a = 2, b = 1 } }, c)
	t.expect_same(tx.runs, { { "b", 3, 4 } }, "the ack drops the two covered front runs")
	t.expect_same(first[1].runs, { { "a", 2, 2 }, { "b", 1, 1 } }, "and the earlier offer's runs are still untouched")
end)

t.test("ordered: g rides with its run, and reaches the credit only with the whole run (belt spacing spec §6)", function()
	local tx, c = core.new("ordered", "tx"), octx()
	core.capture(tx, { { "a", 2, { 0, 1.5 } }, { "b", 1 } }, nil, c)
	t.expect_same(core.visit(tx, c), { { k = "o.offer", runs = { { "a", 2, 2, { 0, 1.5 } }, { "b", 1, 1 } } } })
	local rx, cr = core.new("ordered", "rx"), octx()
	core.receive(rx, { k = "o.offer", runs = { { "a", 2, 2, { 0, 1.5 } }, { "b", 1, 1 } } }, cr)
	t.expect_same(cr.lists[1], { { "a", 2, { 0, 1.5 } }, { "b", 1 } }, "whole runs: a's g goes with it; b has none")
	local part, cp = core.new("ordered", "rx"), octx()
	part.recv = { a = 1 }
	core.receive(part, { k = "o.offer", runs = { { "a", 2, 2, { 0, 1.5 } } } }, cp)
	t.expect_same(cp.lists[1], { { "a", 1 } }, "a partial credit has no g")
	local gap, cg = core.new("ordered", "rx"), octx()
	core.receive(gap, { k = "o.offer", runs = { { "a", 1, 3, { 4 } } } }, cg)
	t.expect_same(cg.lists[1], { { "a", 3 } }, "a gap credit (after a destination restore) has no g")
end)

t.test("ordered: the destination credits each run's new part in order, and a repeat or an older offer adds nothing", function()
	local rx, c = core.new("ordered", "rx"), octx()
	local acks = core.receive(rx, { k = "o.offer", runs = { { "a", 2, 2 }, { "b", 1, 1 }, { "a", 1, 3 } } }, c)
	t.expect_same(c.taken, { "ax2", "bx1", "ax1" })
	t.expect_same(acks, { { k = "s.ack", totals = { a = 3, b = 1 } } })
	core.receive(rx, { k = "o.offer", runs = { { "a", 2, 2 }, { "b", 1, 1 } } }, c)
	core.receive(rx, { k = "o.offer", runs = { { "a", 2, 2 }, { "b", 1, 1 }, { "a", 1, 3 } } }, c)
	t.expect_eq(#c.taken, 3, "an older and a repeated offer credit nothing")
	core.receive(rx, { k = "o.offer", runs = { { "a", 1, 3 }, { "b", 2, 3 }, { "a", 2, 5 } } }, c)
	t.expect_same(c.taken, { "ax2", "bx1", "ax1", "bx2", "ax2" }, "only the new parts, in order")
end)

t.test("ordered: a start above recv (a destination restore) is credited at that run's place; items stay exact", function()
	local rx, c = core.new("ordered", "rx"), octx()
	rx.recv = { a = 1 }
	core.receive(rx, { k = "o.offer", runs = { { "b", 1, 4 }, { "a", 1, 3 } } }, c)
	t.expect_same(c.taken, { "bx4", "ax2" }, "b's gap of 3 and a's of 1 arrive with their runs")
	t.expect_same(rx.recv, { a = 3, b = 4 })
end)

t.test("ordered: the transport accepts a prefix; recv rises by exactly that, and the rest is re-offered", function()
	local rx, c = core.new("ordered", "rx"), octx({ accept_items = 3 })
	local acks = core.receive(rx, { k = "o.offer", runs = { { "a", 2, 2 }, { "b", 2, 2 }, { "a", 1, 3 } } }, c)
	t.expect_same(rx.recv, { a = 2, b = 1 })
	t.expect_same(acks[1].totals, { a = 2, b = 1 })
	c.accept_items = nil
	c.taken = {}
	core.receive(rx, { k = "o.offer", runs = { { "a", 2, 2 }, { "b", 2, 2 }, { "a", 1, 3 } } }, c)
	t.expect_same(c.taken, { "bx1", "ax1" }, "the rest, still in order")
	local closing, cc = core.new("ordered", "rx"), octx()
	core.close(closing, 2, 1000)
	local r = core.receive(closing, { k = "o.offer", runs = { { "a", 1, 1 } } }, cc)
	t.expect_eq(#cc.taken, 0, "a closing destination credits nothing")
	t.expect_same(r[1].totals, { a = 0 }, "but still acks")
end)

t.test("ordered: an activation re-offers acknowledged keys as zero-length runs, 64 to an offer", function()
	local tx, c = core.new("ordered", "tx"), octx()
	for i = 1, 70 do
		core.capture(tx, { { "k" .. i, 1 } }, nil, c)
		core.receive(tx, { k = "s.ack", totals = { ["k" .. i] = 1 } }, c)
	end
	core.capture(tx, { { "k1", 2 } }, nil, c)
	core.activate(tx)
	local msgs = core.visit(tx, c)
	t.expect_eq(#msgs, 2, "71 runs: 64, then 7")
	t.expect_same(msgs[1].runs[1], { "k1", 2, 3 }, "the live run first")
	local zero = 0
	for _, m in ipairs(msgs) do
		for _, r in ipairs(m.runs) do
			if r[2] == 0 then
				zero = zero + 1
				t.expect_eq(r[3], tx.sent[r[1]], "a zero-length run ends at sent")
			end
		end
	end
	t.expect_eq(zero, 69, "every other key once")
end)

t.test("ordered: malformed runs are refused (G5); an ack may name up to 64 keys", function()
	local rx, tx, c = core.new("ordered", "rx"), core.new("ordered", "tx"), octx()
	t.expect_eq(core.receive(rx, { k = "o.offer", runs = { { "a", 2, 1 } } }, c), false, "e below n")
	t.expect_eq(core.receive(rx, { k = "o.offer", runs = { { 7, 1, 1 } } }, c), false, "a key that isn't a string")
	t.expect_eq(core.receive(rx, { k = "o.offer", runs = { x = { "a", 1, 1 } } }, c), false, "not an array")
	t.expect_eq(core.receive(rx, { k = "s.offer", totals = { a = 1 } }, c), false, "no stream offer on an ordered lane")
	t.expect_eq(core.receive(rx, { k = "o.offer", runs = { { "a", 2, 2, "x" } } }, c), false, "a g that isn't a table")
	t.expect_eq(core.receive(rx, { k = "o.offer", runs = { { "a", 2, 2, { 1, 2, 3 } } } }, c), false, "more gaps than items")
	t.expect_eq(core.receive(rx, { k = "o.offer", runs = { { "a", 2, 2, { -1 } } } }, c), false, "a negative gap")
	t.expect_eq(core.receive(rx, { k = "o.offer", runs = { { "a", 2, 2, { "1" } } } }, c), false, "a gap that isn't a number")
	t.expect_eq(core.receive(rx, { k = "o.offer", runs = { { "a", 2, 2, { 0 / 0 } } } }, c), false, "NaN")
	t.expect_eq(core.receive(rx, { k = "o.offer", runs = { { "a", 2, 2, { 1 / 0 } } } }, c), false, "an infinite gap")
	t.expect_true(core.receive(rx, { k = "o.offer", runs = { { "a", 2, 2, { 0.5 } } } }, c) ~= false,
		"fewer gaps than items is the transport's call")
	local totals = {}
	for i = 1, 64 do
		totals["k" .. i] = 0
	end
	t.expect_eq(core.receive(tx, { k = "s.ack", totals = totals }, c), nil, "64 keys")
	totals.k65 = 0
	t.expect_eq(core.receive(tx, { k = "s.ack", totals = totals }, c), false, "65 are too many")
end)

t.test("ordered: closing refunds sent − the final recv per key, as stream", function()
	local tx, c = core.new("ordered", "tx"), octx()
	core.capture(tx, { { "a", 5 }, { "b", 2 } }, nil, c)
	core.close(tx, 2, 1000)
	t.expect_same(core.visit(tx, c), { { k = "close", rev = 2, kind = "ordered" } })
	t.expect_same(core.receive(tx, { k = "s.final", recv = { a = 3 } }, c), { { k = "done" } })
	t.expect_same(c.calls[1], { "refund", { a = 2, b = 2 } })
	t.expect_same(core.unknown_close({ k = "close", rev = 2, kind = "ordered" }, 2), { { k = "s.final", recv = {} } })
end)
