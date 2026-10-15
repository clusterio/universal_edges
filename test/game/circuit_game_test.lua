-- The circuit link, one link at a time (circuit-link spec §13.3; plan Task 4). Rows on nauvis at x 10000–10420, side a at
-- y = 3000 and side b at y = 2000, over the SP3 loopback (one tick each way). Cases start at tick 300 and write a few
-- slots at a time; the only big writes own 1400–1900 and 2000–2500, because the write budget is one per instance (K16).
-- Bounds the spec states per poll get one period more for the shared save's walk, and each case logs what it measured
-- (plan ruling 6).
local t = require("modules/v2_test/testlib")
local loop = require("modules/v2_test/loopback")
local layouts = require("modules/v2_test/layouts")
local bridge = require("modules/universal_edges/runtime/bridge")
local connectors = require("modules/universal_edges/edges/connectors")
local geometry = require("modules/universal_edges/edges/geometry_core")
local circuit = require("modules/universal_edges/transports/circuit")
local core = require("modules/universal_edges/transports/circuit_core")
local seams = require("modules/universal_edges/transports/circuit_seams")

local P = circuit.P
local sig, map, read, same = layouts.sig, layouts.map, layouts.read, layouts.same

local function ep(edge, cid)
	local side = storage.universal_edges.edges[edge]
	return side and connectors.get(side, cid or "c1")
end

local function wait(ctx, from, to, check, done)
	layouts.wait(t, ctx, from, to, check, done)
end

--- A row's first pole on each side reads exactly the summed lists on colour c.
local function exact(r, c, ...)
	local want = map(...)
	return same(read(r.a[1], c), want) and same(read(r.b[1], c), want)
end

--- How many signals a status carries, both colours.
local function entries(st)
	local n = 0
	for _, c in ipairs({ "r", "g" }) do
		for _, list in pairs(st and st[c] or {}) do
			n = n + #list / 2
		end
	end
	return n
end

--- The ue-link-combinators on one side of a row (local x −1 to L + 1, y −4 to 1).
local function injectors(r, side)
	local x1, y1, x2, y2 = geometry.area_to_world(side == "a" and r.fa or r.fb, -1, -4, r.L + 1, 1)
	return game.surfaces.nauvis.count_entities_filtered({ name = "ue-link-combinator", area = { { x1, y1 }, { x2, y2 } } })
end

-- The circuit type's hooks, wrapped (connectors.call looks each up at every call): each poll's tick and each write
-- hook's slots by tick, per endpoint; observers run after a poll; and raises on purpose for the containment case.
local polls, wrote, after, boom = {}, {}, {}, {}
local hooks = connectors.types.circuit
local poll, write = hooks.poll, hooks.write
function hooks.poll(e, tick)
	if boom[e.key] == "poll" then
		error("cl test: the poll raises on purpose")
	end
	poll(e, tick)
	local list = polls[e.key] or {}
	polls[e.key] = list
	list[#list + 1] = tick
	if after[e.key] then
		after[e.key](e, tick)
	end
end
function hooks.write(e, budget, tick)
	if boom[e.key] == "write" then
		error("cl test: the write raises on purpose")
	end
	local used = write(e, budget, tick)
	local w = wrote[e.key] or {}
	wrote[e.key] = w
	w[tick] = (w[tick] or 0) + used
	return used
end

-- The slots the whole write task wrote, by tick.
local per_tick = {}
local write_tick = circuit.write_tick
function circuit.write_tick(tick)
	local used = write_tick(tick)
	per_tick[tick] = used
	return used
end

-- ue.connector.propose and ue.connector.remove payloads, read from the queue before each flush (wrappers chain).
local proposed, removals = {}, {}
local flush = bridge.flush
function bridge.flush(tick)
	for _, msg in ipairs(storage.universal_edges.bridge.out.universal_edges or {}) do
		if msg.type == "ue.connector.propose" then
			proposed[#proposed + 1] = msg.payload
		elseif msg.type == "ue.connector.remove" then
			removals[#removals + 1] = msg.payload
		end
	end
	flush(tick)
end

--- The first poll tick of endpoint key after tick.
local function first_poll(key, tick)
	for _, p in ipairs(polls[key] or {}) do
		if p > tick then
			return p
		end
	end
end

--- The slots endpoint key's write hook wrote in ticks (from, to].
local function slots(key, from, to)
	local n = 0
	for tick, used in pairs(wrote[key] or {}) do
		if tick > from and tick <= to then
			n = n + used
		end
	end
	return n
end

local injected = 0
--- A ue.lane payload into this save's inbox at once, from sender c1c00000: a direct seam, past the loopback.
local function inject(payload)
	injected = injected + 1
	ue_rt.inbox("universal_edges", helpers.table_to_json({ { id = "c1c00000." .. injected, type = "ue.lane",
		payload = payload } }))
end

t.case("circuit: power's poll proposes a circuit connector at a wired pole's columns, none at an unwired one, one from " ..
	"each side when both are wired; once added it carries (§6.1, K9)", function(ctx)
	local r
	local function mine()
		local out = {}
		for _, p in ipairs(proposed) do
			if string.find(p.edge, "^cl%-prop%-") then
				out[#out + 1] = p.edge .. " " .. p.type .. " " .. p.pos .. " " .. p.width
			end
		end
		table.sort(out)
		return table.concat(out, "; ")
	end
	local want = "cl-prop-x circuit 2 1; cl-prop-x circuit 8 1; cl-prop-y circuit 8 1"
	ctx.at(300, function()
		r = layouts.circuit_row(loop, "cl-prop", 10000, { 2, 5, 8 }, 12, { no_circuit = true })
	end)
	ctx.at(340, function()
		layouts.own(r, "a", 1, "r", sig({ "signal-A", 1 }))
		layouts.own(r, "a", 3, "r", sig({ "signal-B", 2 }))
		layouts.own(r, "b", 3, "r", sig({ "signal-C", 3 }))
	end)
	ctx.at(340 + 2 * P + 40, function()
		ctx.expect(mine() == want, "proposals: " .. mine())
		local list = {}
		for i, c in ipairs(r.list) do
			list[i] = c
		end
		list[#list + 1] = { cid = "c1", type = "circuit", pos = 2, width = 1, params = {} }
		loop.connectors("cl-prop", 2, list) -- the controller adds the first (the store refuses the other as overlap, FC1)
	end)
	wait(ctx, 501, 900, function() return same(read(r.b[1], "r"), map(sig({ "signal-A", 1 }))) end, function(k)
		ctx.expect(k, "the added connector carries A's signal to B's pole by +900")
		ctx.at((k or 900) + 1, function()
			ctx.expect(mine() == want, "and nothing proposes again while it stands: " .. mine())
		end)
	end)
	ctx.expect_ipc("universal_edges:out", '"type":"circuit"')
end)

t.case("circuit: both colours cross both ways and hold for 10 periods; a change crosses as one signal in one status and " ..
	"one slot; unwiring a side clears it from the far pole, and rewiring carries again (§3, §7, Review Focus 3)",
	function(ctx)
		local X, Y = "cl-steady-x/c1", "cl-steady-y/c1"
		local r, ca
		local ar, br = sig({ "signal-A", 5, "signal-C", 9 }), sig({ "signal-B", 13, "signal-C", 21 })
		local ag, bg = sig({ "signal-D", 4 }), { { type = "item", name = "iron-plate", count = 2 } }
		local function all()
			return exact(r, "r", ar, br) and exact(r, "g", ag, bg)
		end
		local function rewire(at)
			ctx.at(at, function()
				layouts.wire(ca, r.a[1], "r")
				ar = sig({ "signal-A", 5, "signal-C", 90 })
			end)
			wait(ctx, at + 1, at + 3 * P, all, function(k) ctx.expect(k, "rewired, it carries again") end)
		end
		local function unwire(at)
			ctx.at(at, function()
				layouts.wire(ca, r.a[1], "r", true)
				ar = {}
			end)
			wait(ctx, at + 1, at + 3 * P, all, function(k)
				ctx.expect(k, "unwired, A's red left both poles")
				if not k then
					return
				end
				local st = ep("cl-steady-y").partner.status
				ctx.expect(st.base == nil and st.r == nil, "as a full with red left out")
				rewire(k + 1)
			end)
		end
		ctx.at(300, function()
			r = layouts.circuit_row(loop, "cl-steady", 10040, { 2 }, 8)
			ca = layouts.own(r, "a", 1, "r", ar)
			layouts.own(r, "b", 1, "r", br)
			layouts.own(r, "a", 1, "g", ag)
			layouts.own(r, "b", 1, "g", bg)
		end)
		wait(ctx, 301, 800, all, function(k)
			ctx.expect(k, "both colours exact on both poles by +800")
			if not k then
				return
			end
			for p = 1, 10 do
				ctx.at(k + p * P, function() ctx.expect(all(), "still exact " .. p .. " periods on") end)
			end
			ctx.at(k + 10 * P + 1, function()
				local changed, applied = game.tick, ep("cl-steady-y").data.stats.applied
				ar = sig({ "signal-A", 5, "signal-C", 90 })
				layouts.set(ca, ar)
				wait(ctx, k + 10 * P + 2, k + 13 * P, all, function(h)
					ctx.expect(h, "the change crossed")
					if not h then
						return
					end
					local at, seen = t.first_tick + h, first_poll(X, changed)
					log(string.format("cl change: x polled +%d after the change; both poles exact +%d", seen - changed,
						at - changed))
					ctx.expect(at - changed <= 2 * P + 4, "within 2P + L + 3 of the change: " .. (at - changed))
					ctx.expect(at - seen <= 4, "within L + 3 of the poll that saw it: " .. (at - seen))
					local st = ep("cl-steady-y").partner.status
					ctx.expect(st.base ~= nil and entries(st) == 1, "a change of one signal")
					ctx.expect(ep("cl-steady-y").data.stats.applied == applied + 1, "in one status")
					ctx.expect(slots(Y, changed, at) == 1, "written as one slot: " .. slots(Y, changed, at))
					unwire(h + 1)
				end)
			end)
		end)
	end)

t.case("circuit: a status that reaches an endpoint before its first build is folded without an error, and the link " ..
	"then runs exact (Review Focus 1)", function(ctx)
	local r
	local a = sig({ "signal-A", 7 })
	ctx.at(300, function()
		r = layouts.circuit_row(loop, "cl-early", 10080, { 2 }, 8)
		layouts.own(r, "a", 1, "r", a)
		local e = ep("cl-early-y")
		ctx.expect(e and e.state == "pending" and e.data.inj == nil, "pending, never built")
		inject({ k = "ep", edge = "cl-early-y", epoch = storage.universal_edges.edges["cl-early-y"].epoch, cid = "c1",
			state = "ready", status = { v = 0, gr = "c1", r = { virtual = { "signal-E", 3 } } } })
		ctx.expect(e.state == "pending", "still pending: on_status raised nothing")
		ctx.expect(core.get(e.data.far.r, "virtual", "normal", "signal-E") == 3, "folded into the mirror before any build")
	end)
	wait(ctx, 301, 800, function() return exact(r, "r", a) end, function(k)
		ctx.expect(k, "exact by +800: the real handshake's full replaced the early one")
	end)
end)

t.case("circuit: a lost change is a gap — one gap, one ask, one full, then exact with no second ask; a change on a base " ..
	"the receiver lacks writes nothing; two changes in one batch both apply (C9 c, K17)", function(ctx)
	local Y, YK = "cl-gap-y", "cl-gap-y/c1"
	local r, ca
	local a, b = sig({ "signal-A", 1, "signal-P", 1, "signal-Q", 1 }), sig({ "signal-B", 2 }) -- P, Q: a change of A is
	local asks = 0 -- smaller than the full form (core.status), so it goes as a change
	local function ok()
		return exact(r, "r", a, b)
	end
	local function set(v)
		a = sig({ "signal-A", v, "signal-P", 1, "signal-Q", 1 })
		layouts.set(ca, a)
	end
	--- Stage 3: hold x's next change and send it with the one after: both fold in one batch, in order, with no gap.
	local function batch(at)
		local held, delivered
		ctx.at(at, function()
			loop.taps[Y] = function(copy)
				local s = copy.payload.status
				if not (copy.payload.k == "ep" and s and s.base) then
					return true
				end
				if not held then
					held = copy
					return false
				end
				loop.taps[Y] = nil
				loop.deliver({ held, copy })
				delivered = game.tick + 1
				return false
			end
			set(40)
		end)
		wait(ctx, at + 1, at + 3 * P, function() return held ~= nil end, function(h)
			ctx.expect(h, "x's change was held")
			if not h then
				return
			end
			local st = ep(Y).data.stats
			local applied, gaps, asked = st.applied, st.gaps, asks
			ctx.at(h + 1, function() set(50) end)
			wait(ctx, h + 2, h + 4 * P, function() return delivered ~= nil and game.tick > delivered end, function(k)
				ctx.expect(k, "the two changes were delivered together")
				if not k then
					return
				end
				ctx.expect(st.applied == applied + 2 and st.gaps == gaps and asks == asked, "both applied: no gap, no ask")
				wait(ctx, k + 1, k + 10, ok, function(e) ctx.expect(e, "exact at A = 50") end)
			end)
		end)
	end
	--- Stage 2: a change on a base the receiver doesn't have writes nothing; the full it asks for makes the pole exact.
	local function wrong_base(at)
		local bad_at
		ctx.at(at, function()
			loop.taps[Y] = function(copy)
				local s = copy.payload.status
				if copy.payload.k == "ep" and s and s.base then
					loop.taps[Y] = nil
					s = helpers.json_to_table(helpers.table_to_json(s)) -- a copy: the sender keeps its own
					s.base = s.base + 100
					copy.payload.status = s
					bad_at = game.tick + 1 -- folded at the next tick's flush
				end
			end
			set(30)
		end)
		wait(ctx, at + 1, at + 3 * P, function() return bad_at ~= nil and game.tick > bad_at end, function(k)
			ctx.expect(k, "the change on a wrong base was delivered")
			if not k then
				return
			end
			ctx.expect(core.get(ep(Y).data.far.r, "virtual", "normal", "signal-A") == 20, "the mirror kept A = 20")
			ctx.expect(slots(YK, bad_at - 1, game.tick) == 0, "and nothing was written")
			wait(ctx, k + 1, k + 3 * P, ok, function(e)
				ctx.expect(e, "the full that followed made the pole exact at A = 30")
				if e then
					batch(e + 1)
				end
			end)
		end)
	end
	ctx.at(300, function()
		r = layouts.circuit_row(loop, "cl-gap", 10120, { 2 }, 8)
		ca = layouts.own(r, "a", 1, "r", a)
		layouts.own(r, "b", 1, "r", b)
		loop.taps["cl-gap-x"] = function(copy) -- y's asks reach x as ep messages with ask = true
			if copy.payload.k == "ep" and copy.payload.ask then
				asks = asks + 1
			end
		end
	end)
	wait(ctx, 301, 800, ok, function(k)
		ctx.expect(k, "exact by +800")
		if not k then
			return
		end
		local lost -- Stage 1: lose one change, then change again
		ctx.at(k + 1, function()
			loop.taps[Y] = function(copy)
				local s = copy.payload.status
				if copy.payload.k == "ep" and s and s.base then
					loop.taps[Y] = nil
					lost = game.tick
					return false
				end
			end
			set(10)
		end)
		wait(ctx, k + 2, k + 3 * P, function() return lost ~= nil end, function(d)
			ctx.expect(d, "x's change was lost")
			if not d then
				return
			end
			local gaps, asked = ep(Y).data.stats.gaps, asks
			ctx.at(d + 1, function() set(20) end)
			wait(ctx, d + 2, d + 4 * P, ok, function(e)
				ctx.expect(e, "exact again after the loss")
				if not e then
					return
				end
				ctx.expect(ep(Y).data.stats.gaps == gaps + 1, "one gap")
				ctx.at(e + 2 * P, function()
					ctx.expect(asks == asked + 1, "one ask, and no second: " .. (asks - asked))
					wrong_base(e + 2 * P + 1)
				end)
			end)
		end)
	end)
	ctx.expect_ipc("universal_edges:out", '"phase":"gap"')
end)

t.case("circuit: a link turning quiet clears its injector at its next poll, and turning back to carrying restores the " ..
	"far set from its mirror — neither needs a status from the far side (§7.4, §8.3, plan ruling 4)", function(ctx)
	local Y = "cl-quiet-y"
	local r
	local a, b1, b2 = sig({ "signal-A", 3 }), sig({ "signal-B", 4 }), sig({ "signal-D", 6 })
	local everyone = map(a, b1, b2)
	local held = {}
	local function c2_inj()
		return ep(Y, "c2").data.inj.r
	end
	local function tree()
		return same(read(r.a[1], "r"), everyone) and same(read(r.a[2], "r"), everyone)
			and same(read(r.b[1], "r"), everyone) and same(read(r.b[2], "r"), everyone)
	end
	ctx.at(300, function()
		r = layouts.circuit_row(loop, "cl-quiet", 10160, { 2, 5 }, 8)
		layouts.own(r, "a", 1, "r", a)
		layouts.own(r, "b", 1, "r", b1)
		layouts.own(r, "b", 2, "r", b2)
		layouts.wire(r.a[1], r.a[2], "r") -- x's two poles are one network, y's are two: a tree, both links carry
	end)
	wait(ctx, 301, 900, tree, function(k)
		ctx.expect(k, "the tree is exact by +900")
		if not k then
			return
		end
		ctx.expect(same(ep(Y, "c2").data.far.r, map(a, b1)), "y's c2 mirror holds A + B (x's network less D)")
		ctx.at(k + 1, function()
			loop.taps[Y] = function(copy) -- hold everything x sends y from now on
				if copy.payload.k == "ep" then
					held[#held + 1] = copy
					return false
				end
			end
			layouts.wire(r.b[1], r.b[2], "r") -- y joins its poles: c2 now closes a loop
		end)
		wait(ctx, k + 2, k + 3 * P, function() return next(c2_inj()) == nil end, function(q)
			ctx.expect(q, "y's c2 turned quiet and cleared its injector while x's statuses were held")
			if not q then
				return
			end
			ctx.expect(not ep(Y, "c2").data.guard.cr, "quiet in y's own forest")
			ctx.expect(same(ep(Y, "c2").data.far.r, map(a, b1)), "its mirror stays")
			ctx.at(q + 1, function() layouts.wire(r.b[1], r.b[2], "r", true) end) -- y parts its poles again
			wait(ctx, q + 2, q + 3 * P, function() return same(c2_inj(), map(a, b1)) end, function(c)
				ctx.expect(c, "carrying again, y's c2 injector holds its mirror's A + B, x's statuses still held")
				if not c then
					return
				end
				ctx.at(c + 1, function()
					loop.taps[Y] = nil
					loop.deliver(held)
				end)
				wait(ctx, c + 2, c + 6 * P, tree, function(e) ctx.expect(e, "exact everywhere once released") end)
			end)
		end)
	end)
	ctx.expect_ipc("universal_edges:out", '"phase":"quiet"')
	ctx.expect_ipc("universal_edges:out", '"phase":"carrying"')
end)

t.case("circuit: a poll in a tick whose write task wrote this link's injector before it skips its read and send; the " ..
	"next poll is exact (K2, §7.5 step 6)", function(ctx)
	local Y, YK = "cl-batch-y", "cl-batch-y/c1"
	local r, ca, cb, held
	local a, b = sig({ "signal-A", 1, "signal-P", 1, "signal-Q", 1 }), sig({ "signal-B", 2 }) -- P, Q: as in the gap case
	ctx.at(300, function()
		r = layouts.circuit_row(loop, "cl-batch", 10240, { 2 }, 8)
		ca = layouts.own(r, "a", 1, "r", a)
		cb = layouts.own(r, "b", 1, "r", b)
	end)
	wait(ctx, 301, 800, function() return exact(r, "r", a, b) end, function(k)
		ctx.expect(k, "exact by +800")
		if not k then
			return
		end
		ctx.at(k + 1, function()
			loop.taps[Y] = function(copy)
				local s = copy.payload.status
				if copy.payload.k == "ep" and s and s.base then
					loop.taps[Y] = nil
					held = copy
					return false
				end
			end
			a = sig({ "signal-A", 5, "signal-P", 1, "signal-Q", 1 })
			layouts.set(ca, a)
		end)
		wait(ctx, k + 2, k + 3 * P, function() return held ~= nil end, function(h)
			ctx.expect(h, "x's change was held")
			if not h then
				return
			end
			after[YK] = function() -- right after y's next scheduled poll, so no other poll of y falls in between
				after[YK] = nil
				local q = game.tick - t.first_tick
				ctx.at(q + 1, function()
					b = sig({ "signal-B", 9 })
					layouts.set(cb, b)
				end)
				ctx.at(q + 4, function()
					local e = ep(Y)
					local v = e.data.v
					inject(held.payload) -- x's change folds at once and enrols the link
					circuit.write_tick(game.tick) -- the write task writes A's slot before the poll, this tick
					ctx.expect(e.data.wtick == game.tick, "a batch of this link was written this tick")
					e.last_poll = nil
					connectors.visit(e, game.tick) -- y's poll, in the same tick, after the batch
					ctx.expect(polls[YK][#polls[YK]] == game.tick, "the poll ran")
					ctx.expect(e.data.v == v, "and sent nothing, though B's own signal had changed")
				end)
				wait(ctx, q + 5, q + 3 * P, function() return exact(r, "r", a, b) end, function(e)
					ctx.expect(e, "the next poll sent B's change: exact")
					ctx.expect(same(ep(Y).data.out.r, map(b)), "with nothing of A's echoed back")
				end)
			end
		end)
	end)
end)

t.case("circuit: 2,000 signals a colour on both colours arrive at most 300 slots a tick and finish within 14 ticks; the " ..
	"far pole grows by at most 300 a tick and ends exact; every poll meanwhile sends exactly its own signals (fix 3, " ..
	"K2, K16)", function(ctx)
	local X, Y = "cl-spread-x/c1", "cl-spread-y/c1"
	local r, ar, ag, start
	local own_r, own_g, b = {}, {}, sig({ "signal-B", 7 })
	local on, bad = false, {}
	local function watch_y(e)
		if not (same(e.data.out.r, map(b)) and next(e.data.out.g) == nil) then
			bad[#bad + 1] = "y@" .. game.tick
		end
	end
	local function watch_x(e)
		if not (same(e.data.out.r, on and map(own_r) or {}) and same(e.data.out.g, on and map(own_g) or {})) then
			bad[#bad + 1] = "x@" .. game.tick
		end
	end
	local function far()
		return same(read(r.b[1], "r"), map(own_r, b)) and same(read(r.b[1], "g"), map(own_g))
	end
	ctx.at(1400, function()
		for i, s in ipairs(seams.pool(2000)) do
			own_r[i] = { type = s.type, name = s.name, quality = s.quality, count = 100 + i }
			own_g[i] = { type = s.type, name = s.name, quality = s.quality, count = 5000 + i }
		end
		r = layouts.circuit_row(loop, "cl-spread", 10200, { 2 }, 8)
		ar = layouts.own(r, "a", 1, "r", own_r)
		ag = layouts.own(r, "a", 1, "g", own_g)
		ar.get_control_behavior().enabled = false
		ag.get_control_behavior().enabled = false
		layouts.own(r, "b", 1, "r", b)
	end)
	wait(ctx, 1401, 1650, function() return exact(r, "r", b) end, function(k)
		ctx.expect(k, "B's signal crossed first")
		if not k then
			return
		end
		ctx.at(k + 1, function()
			ar.get_control_behavior().enabled = true
			ag.get_control_behavior().enabled = true
			on, start = true, game.tick
			after[X], after[Y] = watch_x, watch_y -- from here, every poll on either side
		end)
		for p = 1, 4 do -- A's own red changes once a period from here: during the spread and after it
			ctx.at(k + p * P - 29, function()
				local e = own_r[p]
				e.count = e.count + 1
				ar.get_control_behavior().get_section(1).set_slot(p, { value = { type = e.type, name = e.name,
					quality = e.quality }, min = e.count })
			end)
		end
		local last, grow = 0, 0
		wait(ctx, k + 2, k + 8 * P, function()
			local n = layouts.size(read(r.b[1], "r")) + layouts.size(read(r.b[1], "g"))
			grow, last = math.max(grow, n - last), n
			return game.tick > t.first_tick + k + 5 * P and far()
		end, function(e)
			ctx.expect(e, "the far pole ends exact")
			local cb = ep("cl-spread-y").data.comb.r.get_control_behavior() -- T2a: slots past 1,000 sit in the second section
			ctx.expect(#cb.get_section(1).filters == 1000 and #cb.get_section(2).filters == 1000,
				"y's red injector holds A's 2,000 as 1,000 in each section: " .. #cb.get_section(1).filters .. ", " ..
				#cb.get_section(2).filters)
			ctx.expect(grow <= 300, "it grew by at most 300 signals a tick: " .. grow)
			local first, stop, max = nil, nil, 0
			for tick = start, start + 6 * P do
				local u = per_tick[tick] or 0
				max = math.max(max, u)
				if u > 0 and not first then
					first, stop = tick, tick
				elseif u > 0 and stop == tick - 1 then
					stop = tick
				end
			end
			ctx.expect(max <= 300, "no tick wrote more than 300 slots: " .. max)
			ctx.expect(first ~= nil and stop - first + 1 <= 14, "the arrival's write took " ..
				tostring(first and stop - first + 1) .. " ticks")
			ctx.expect(#bad == 0, "every poll sent exactly its own signals; not at " .. table.concat(bad, " "))
			after[X], after[Y] = nil, nil
		end)
	end)
end)

t.case("circuit: the edge going down one batch into a 1,200-slot write clears both injectors, inj, the slot maps, the " ..
	"mirror and todo on both sides, and leaves the write set; back up, each side's first status is a full, the far set " ..
	"returns exact, and the first reads send no negated echo (C5 b, FC4, FC5; Review Focus 2)", function(ctx)
	local X, Y, XK, YK = "cl-down-x", "cl-down-y", "cl-down-x/c1", "cl-down-y/c1"
	local r, ar, ag, arrived
	local own_r, own_g, b = {}, {}, sig({ "signal-B", 2 })
	local function cleared(e)
		local d = e.data
		for _, c in ipairs({ "r", "g" }) do
			local comb = d.comb[c]
			if comb and comb.valid then
				for s = 1, 2 do -- T2a: both sections
					if #comb.get_control_behavior().get_section(s).filters > 0 then
						return false
					end
				end
			end
			if next(d.inj[c]) or next(d.slot[c]) or next(d.free[c]) or d.top[c] ~= 0 or next(d.far[c]) or next(d.todo[c]) then
				return false
			end
		end
		return d.far_v == nil and storage.universal_edges.circuit_writing[e.key] == nil
	end
	ctx.at(2000, function()
		for i, s in ipairs(seams.pool(600)) do
			own_r[i] = { type = s.type, name = s.name, quality = s.quality, count = 100 + i }
			own_g[i] = { type = s.type, name = s.name, quality = s.quality, count = 900 + i }
		end
		r = layouts.circuit_row(loop, "cl-down", 10280, { 2 }, 8)
		ar = layouts.own(r, "a", 1, "r", own_r)
		ag = layouts.own(r, "a", 1, "g", own_g)
		ar.get_control_behavior().enabled = false
		ag.get_control_behavior().enabled = false
		layouts.own(r, "b", 1, "r", b)
	end)
	wait(ctx, 2001, 2250, function() return exact(r, "r", b) end, function(k)
		ctx.expect(k, "B's signal crossed")
		if not k then
			return
		end
		ctx.at(k + 1, function()
			loop.taps[Y] = function(copy)
				local s = copy.payload.status
				if not arrived and copy.payload.k == "ep" and copy.payload.cid == "c1" and s and s.r then
					arrived = game.tick + 1 -- folded at the next tick's flush; the first batch is written the tick after
				end
			end
			ar.get_control_behavior().enabled = true
			ag.get_control_behavior().enabled = true
		end)
		wait(ctx, k + 2, k + 3 * P, function() return arrived ~= nil and game.tick > arrived end, function(w)
			ctx.expect(w, "A's 1,200 signals reached y")
			if not w then
				return
			end
			local vx, vy = ep(X).data.v, ep(Y).data.v
			ctx.expect(per_tick[game.tick] == 300 and next(ep(Y).data.todo.r) ~= nil, "one batch in, the rest to go")
			loop.activation("cl-down", false)
			ctx.expect(cleared(ep(X)) and cleared(ep(Y)), "both sides cleared at once, mid-write")
			ctx.expect(ep(X).data.v == vx and ep(Y).data.v == vy, "each side's own version stays")
			ctx.at(w + 1, function()
				ctx.expect(same(read(r.b[1], "r"), map(b)) and next(read(r.b[1], "g")) == nil, "y reads silence from x")
				ctx.expect(same(read(r.a[1], "r"), map(own_r)), "x reads only its own")
			end)
			local firsts = {}
			ctx.at(w + 30, function()
				loop.taps[Y] = function(copy)
					if copy.payload.k == "ep" and not firsts.y then
						firsts.y = copy.payload.status
					end
				end
				loop.taps[X] = function(copy)
					if copy.payload.k == "ep" and not firsts.x then
						firsts.x = copy.payload.status
					end
				end
				-- every poll from here: out is silent (the link is quiet while the far side is down) or exactly the side's
				-- own signals, never its own less an echo
				firsts.ypoll, firsts.xpoll = true, true
				after[YK] = function(e)
					local o = e.data.out
					if not ((next(o.r) == nil and next(o.g) == nil) or (same(o.r, map(b)) and next(o.g) == nil)) then
						firsts.ypoll = false
					end
				end
				after[XK] = function(e)
					local o = e.data.out
					if not ((next(o.r) == nil and next(o.g) == nil) or (same(o.r, map(own_r)) and same(o.g, map(own_g)))) then
						firsts.xpoll = false
					end
				end
				loop.activation("cl-down", true)
			end)
			wait(ctx, w + 31, w + 31 + 3 * P, function()
				return exact(r, "r", own_r, b) and exact(r, "g", own_g)
			end, function(e)
				ctx.expect(e, "the far set returned exact")
				ctx.expect(firsts.y and firsts.y.base == nil and firsts.x and firsts.x.base == nil,
					"each side's first status after the reactivation is a full")
				ctx.expect(ep(Y).data.far_v == ep(X).data.v, "y applied x's full")
				ctx.expect(firsts.ypoll and firsts.xpoll, "the reads after the reactivation sent no negated echo")
				after[XK], after[YK] = nil, nil
				loop.taps[X], loop.taps[Y] = nil, nil
			end)
		end)
	end)
end)

t.case("circuit: a mined pole has both its connectors ask for removal; removed, the far pole loses the near signals from " ..
	"the next tick, no injector is left and the write set is clean; a circuit link whose power link is gone asks for its " ..
	"own removal (§6.3, §6.4, C8)", function(ctx)
	local r, r2
	local a, b = sig({ "signal-A", 3 }), sig({ "signal-B", 4 })
	local function asked(edge, reason)
		local got = {}
		for _, m in ipairs(removals) do
			if m.edge == edge and m.reason == reason then
				got[m.cid] = true
			end
		end
		return got
	end
	ctx.at(300, function()
		r = layouts.circuit_row(loop, "cl-mine", 10320, { 2 }, 8)
		layouts.own(r, "a", 1, "r", a)
		layouts.own(r, "b", 1, "r", b)
		r2 = layouts.circuit_row(loop, "cl-c8", 10340, { 2 }, 8)
		layouts.own(r2, "a", 1, "r", a)
	end)
	wait(ctx, 301, 800, function() return exact(r, "r", a, b) and exact(r2, "r", a) end, function(k)
		ctx.expect(k, "both rows exact by +800")
		if not k then
			return
		end
		ctx.at(k + 1, function()
			r.b[1].destroy()
			loop.connectors("cl-c8", 2, { r2.list[2] }) -- cl-c8's power connector is gone, its circuit one left (C8)
		end)
		wait(ctx, k + 2, k + 3 * P, function()
			local m, c8x, c8y = asked("cl-mine-y", "mined"), asked("cl-c8-x", "no_power"), asked("cl-c8-y", "no_power")
			return m.p1 and m.c1 and c8x.c1 and c8y.c1
		end, function(d)
			ctx.expect(d, "y's power and circuit endpoints asked as mined; cl-c8's circuit links asked, no_power")
			if not d then
				return
			end
			ctx.at(d + 1, function()
				loop.connectors("cl-mine", 2, {}) -- the controller removes both connectors: they close and tear down
				local ex, ey = ep("cl-mine-x"), ep("cl-mine-y")
				ctx.expect((not ex or ex.closing) and (not ey or ey.closing), "closed on both sides")
			end)
			ctx.at(d + 2, function()
				ctx.expect(same(read(r.a[1], "r"), map(a)), "from the next tick x's pole has only its own")
				ctx.expect(injectors(r, "a") == 0 and injectors(r, "b") == 0, "no ue-link-combinator is left")
				for key in pairs(storage.universal_edges.circuit_writing) do
					ctx.expect(not string.find(key, "^cl%-mine"), "the write set holds no torn-down link: " .. key)
				end
			end)
		end)
	end)
	ctx.expect_ipc("universal_edges:out", '"reason":"no_power"')
end)

t.case("circuit: a failed endpoint's rebuild keeps its injectors and slot maps (F9); a raise in the poll or in the write " ..
	"fails only the circuit endpoint, and its power link keeps polling (G6, C1 a)", function(ctx)
	local X, Y = "cl-f9-x", "cl-f9-y"
	local r, ca
	local a, b = sig({ "signal-A", 3, "signal-C", 5 }), sig({ "signal-B", 4 })
	local rev = 1
	local function retry()
		rev = rev + 1
		loop.connectors("cl-f9", rev, r.list) -- a reconfiguration that keeps the connector: G6's retry
	end
	--- Wait from offset `from` for power endpoint p1 to poll again (last_poll > polled), then done(). The power poll
	--- (power.lua schedule) walks per_tick = 4 endpoints a tick, a walk starting every interval = 60 ticks, and a visit
	--- polls an endpoint only if tick - last_poll >= 60. A visit just after p1's last poll can be too soon and skip to the
	--- next walk: worst case 2 * 60 ticks, plus that walk's length, ceil(N / 4), N = the power endpoints live now.
	--- Bound = 2 * 60 + ceil(N / 4) ticks after `from`.
	local function power_polled(p1, polled, from, done)
		local n = 0
		for _ in pairs(storage.universal_edges.eps.power or {}) do
			n = n + 1
		end
		wait(ctx, from, from + 2 * 60 + math.ceil(n / 4), function() return p1.last_poll > polled end, function(k)
			ctx.expect(k ~= nil and p1.state == "ready", "the power link kept polling")
			done()
		end)
	end
	--- A raise in y's write: its circuit endpoint fails, its power link keeps polling, and a retry makes it exact.
	local function in_write(at)
		ctx.at(at, function()
			boom[Y .. "/c1"] = "write"
			a = sig({ "signal-A", 4, "signal-C", 5 })
			layouts.set(ca, a)
		end)
		wait(ctx, at + 1, at + 3 * P, function() return ep(Y).state == "failed" end, function(h)
			ctx.expect(h, "the write's raise failed y's circuit endpoint")
			if not h then
				return
			end
			local p1 = ep(Y, "p1")
			local polled = p1.last_poll
			power_polled(p1, polled, h + 1, function()
				boom[Y .. "/c1"] = nil
				retry()
				wait(ctx, game.tick - t.first_tick + 1, h + 5 * P, function() return exact(r, "r", a, b) end, function(e)
					ctx.expect(e, "retried, the link is exact again")
				end)
			end)
		end)
	end
	--- A raise in x's poll: likewise, then on to the write.
	local function in_poll(at)
		ctx.at(at, function() boom[X .. "/c1"] = "poll" end)
		wait(ctx, at + 1, at + 2 * P, function() return ep(X).state == "failed" end, function(g)
			ctx.expect(g, "the poll's raise failed x's circuit endpoint")
			if not g then
				return
			end
			local p1 = ep(X, "p1")
			local polled = p1.last_poll
			power_polled(p1, polled, g + 1, function()
				boom[X .. "/c1"] = nil
				retry()
				wait(ctx, game.tick - t.first_tick + 1, g + 4 * P, function() return ep(X).state == "ready" end, function(f)
					ctx.expect(f, "x retried")
					if f then
						in_write(f + P)
					end
				end)
			end)
		end)
	end
	ctx.at(300, function()
		r = layouts.circuit_row(loop, "cl-f9", 10360, { 2 }, 8)
		ca = layouts.own(r, "a", 1, "r", a)
		layouts.own(r, "b", 1, "r", b)
	end)
	wait(ctx, 301, 800, function() return exact(r, "r", a, b) end, function(k)
		ctx.expect(k, "exact by +800")
		if not k then
			return
		end
		local e = ep(Y)
		local unit, top, n = e.data.comb.r.unit_number, e.data.top.r, layouts.size(e.data.slot.r)
		ctx.at(k + 1, function()
			connectors.fail(e, "test", "forced")
			retry()
		end)
		wait(ctx, k + 2, k + 2 * P, function() return e.state == "ready" end, function(f)
			ctx.expect(f, "rebuilt")
			if not f then
				return
			end
			ctx.expect(e.data.comb.r.valid and e.data.comb.r.unit_number == unit, "the same injector")
			ctx.expect(e.data.top.r == top and layouts.size(e.data.slot.r) == n, "the same slot map")
			ctx.expect(injectors(r, "b") == 1, "and no second injector")
			in_poll(f + 1)
		end)
	end)
end)

t.case("circuit: a signal the receiver's mods lack is dropped with one unknown_signal; the rest apply, and the steady " ..
	"state is exact on the rest (§8.5)", function(ctx)
	local Y = "cl-mod-y"
	local r, renamed
	local a, b = sig({ "signal-A", 1, "signal-E", 2 }), sig({ "signal-B", 3 })
	local rest = map(sig({ "signal-A", 1 }), b)
	ctx.at(300, function()
		r = layouts.circuit_row(loop, "cl-mod", 10400, { 2 }, 8)
		layouts.own(r, "a", 1, "r", a)
		layouts.own(r, "b", 1, "r", b)
		loop.taps[Y] = function(copy)
			local s = copy.payload.status
			local list = copy.payload.k == "ep" and copy.payload.cid == "c1" and s and s.r and s.r.virtual -- not power's r
			for i = 1, list and #list or 0, 2 do
				if list[i] == "signal-E" then
					s = helpers.json_to_table(helpers.table_to_json(s)) -- a copy: the sender keeps its own
					s.r.virtual[i] = "cl-no-such-signal"
					copy.payload.status = s
					loop.taps[Y], renamed = nil, game.tick
					return
				end
			end
		end
	end)
	wait(ctx, 301, 800, function() return renamed ~= nil and same(read(r.b[1], "r"), rest) end, function(k)
		ctx.expect(k, "y is exact on the rest by +800")
		if not k then
			return
		end
		local e = ep(Y)
		ctx.expect(core.get(e.data.far.r, "virtual", "normal", "cl-no-such-signal") == nil, "it left the mirror")
		ctx.expect(e.data.stats.dropped == 1 and e.state == "ready", "dropped once; the endpoint is fine")
		ctx.at(k + 4 * P, function() ctx.expect(same(read(r.b[1], "r"), rest), "and it stays so") end)
	end)
	ctx.expect_ipc("universal_edges:out", '"phase":"unknown_signal"')
	ctx.expect_ipc("universal_edges:out", '"phase":"wired"')
end)

t.case("circuit: a 2,000-signal restore, written as one filters assignment per touched section, reaches the far pole " ..
	"exactly, and the injector holds it as 1,000 in each section (owner decision 1B)", function(ctx)
	local r
	local own = {}
	ctx.at(2520, function()
		for i, s in ipairs(seams.pool(2000)) do
			own[i] = { type = s.type, name = s.name, quality = s.quality, count = 300 + i }
		end
		r = layouts.circuit_row(loop, "cl-1b", 11000, { 2 }, 8)
		layouts.own(r, "a", 1, "r", own)
	end)
	wait(ctx, 2521, 2850, function() return same(read(r.b[1], "r"), map(own)) end, function(k)
		ctx.expect(k, "every one of the 2,000 signals reached the far pole")
		if not k then
			return
		end
		local d = ep("cl-1b-y").data
		local cb = d.comb.r.get_control_behavior()
		ctx.expect(#cb.get_section(1).filters == 1000 and #cb.get_section(2).filters == 1000,
			"y's red injector holds 1,000 in each section: " .. #cb.get_section(1).filters .. ", " .. #cb.get_section(2).filters)
		ctx.expect(d.fl and #d.fl.r[1] == 1000 and #d.fl.r[2] == 1000, "and so does its Lua copy")
	end)
end)

t.case("circuit: a section assignment that raises fails the endpoint, resets the colour's record, and the retry writes the " ..
	"colour again from the mirror (owner 1B review, Important 1)", function(ctx)
	local Y = "cl-as-y"
	local r, ca
	local a, b = sig({ "signal-A", 3, "signal-C", 5 }), sig({ "signal-B", 4 })
	ctx.at(2870, function()
		r = layouts.circuit_row(loop, "cl-as", 11100, { 2 }, 8)
		ca = layouts.own(r, "a", 1, "r", a)
		layouts.own(r, "b", 1, "r", b)
	end)
	wait(ctx, 2871, 3000, function() return exact(r, "r", a, b) end, function(k)
		ctx.expect(k, "exact by 3000")
		if not k then
			return
		end
		local e = ep(Y)
		ctx.at(k + 1, function()
			-- a filter the section rejects (no such item) in a slot past the live ones, which a change of two signals
			-- rewrites (one changed slot is written alone, by set_slot: radar perf P1)
			e.data.fl.r[1][5] = { value = { type = "item", name = "cl-no-such-item", quality = "normal" }, min = 1 }
			a = sig({ "signal-A", 4, "signal-C", 6 })
			layouts.set(ca, a)
		end)
		wait(ctx, k + 2, k + 2 * P + 20, function() return e.state == "failed" end, function(h)
			ctx.expect(h, "the assignment's raise failed y's circuit endpoint")
			if not h then
				return
			end
			ctx.expect(next(e.data.slot.r) == nil and e.data.top.r == 0 and e.data.ninj.r == 0, "its slot map was reset")
			ctx.expect(core.size(e.data.todo.r) == 2, "and both mirror signals are due again: " .. core.size(e.data.todo.r))
			ctx.expect(#e.data.comb.r.get_control_behavior().get_section(1).filters == 0, "the section was emptied")
			loop.connectors("cl-as", 2, r.list) -- G6's retry
			wait(ctx, game.tick - t.first_tick + 1, h + 3 * P, function() return exact(r, "r", a, b) end, function(f)
				ctx.expect(f, "retried, the far pole shows exactly the desired set")
				ctx.expect(f and #e.data.fl.r[1] == 2 and #e.data.comb.r.get_control_behavior().get_section(1).filters == 2,
					"from two slots, the copy and the section agreeing")
			end)
		end)
	end)
end)

t.case("circuit: an injector destroyed and made again starts from an empty slot map, writes the colour again, and a later " ..
	"clear leaves no hole; the far pole shows exactly the desired set (owner 1B review, Important 2)", function(ctx)
	local Y = "cl-rc-y"
	local r, ca
	local a, b = sig({ "signal-A", 3, "signal-C", 5, "signal-D", 7 }), sig({ "signal-B", 4 })
	ctx.at(3000, function()
		r = layouts.circuit_row(loop, "cl-rc", 11200, { 2 }, 8)
		ca = layouts.own(r, "a", 1, "r", a)
		layouts.own(r, "b", 1, "r", b)
	end)
	wait(ctx, 3001, 3300, function() return exact(r, "r", a, b) end, function(k)
		ctx.expect(k, "exact by 3300")
		if not k then
			return
		end
		local e = ep(Y)
		ctx.at(k + 1, function()
			e.data.comb.r.destroy()
			a = sig({ "signal-A", 4, "signal-D", 7 }) -- one changed, one cleared: the clear's slot is in the old map
			layouts.set(ca, a)
		end)
		wait(ctx, k + 2, k + 4 * P, function() return exact(r, "r", a, b) end, function(h)
			ctx.expect(h, "the far pole shows exactly A = 4, D = 7 and B")
			local copy = e.data.fl.r[1]
			local n = 0
			for i = 1, #copy do
				n = n + (next(copy[i]) ~= nil and 1 or 0)
			end
			ctx.expect(injectors(r, "b") == 1 and n == 2 and #e.data.comb.r.get_control_behavior().get_section(1).filters == #copy,
				"one injector; the copy has 2 filled slots and no gap, as the section does")
		end)
	end)
end)

t.case("circuit: a link saved before 1B (no Lua copy) rebuilds the copy from the section on its next write, keeping the " ..
	"slots a freed slot left empty (owner 1B review, Minor 3)", function(ctx)
	local Y = "cl-mg-y"
	local r, ca
	local a, b = sig({ "signal-A", 1, "signal-C", 2, "signal-D", 3 }), sig({ "signal-B", 4 })
	ctx.at(3200, function()
		r = layouts.circuit_row(loop, "cl-mg", 11300, { 2 }, 8)
		ca = layouts.own(r, "a", 1, "r", a)
		layouts.own(r, "b", 1, "r", b)
	end)
	wait(ctx, 3201, 3450, function() return exact(r, "r", a, b) end, function(k)
		ctx.expect(k, "exact by 3450")
		if not k then
			return
		end
		local e = ep(Y)
		local first -- the signal in slot 1, which leaves a hole there when it goes
		for _, s in ipairs(a) do
			if core.get(e.data.slot.r, "virtual", "normal", s.name) == 1 then
				first = s.name
			end
		end
		ctx.expect(first ~= nil, "a signal holds slot 1")
		local rest = {}
		for _, s in ipairs(a) do
			if s.name ~= first then
				rest[#rest + 1] = s
			end
		end
		ctx.at(k + 1, function()
			a = rest
			layouts.set(ca, a)
		end)
		wait(ctx, k + 2, k + 2 * P + 20, function() return exact(r, "r", a, b) end, function(h)
			ctx.expect(h, "exact without " .. tostring(first))
			if not h then
				return
			end
			ctx.at(h + 1, function()
				e.data.fl = nil -- a save from before 1B
				a = { rest[1], rest[2], { type = "virtual", name = "signal-E", count = 9 } }
				a[1] = { type = "virtual", name = rest[1].name, count = rest[1].count + 10 }
				layouts.set(ca, a)
			end)
			wait(ctx, h + 2, h + 2 * P + 20, function() return e.data.fl ~= nil and exact(r, "r", a, b) end, function(f)
				ctx.expect(f, "the copy was rebuilt and the far pole shows exactly the desired set")
				if not f then
					return
				end
				local filters = e.data.comb.r.get_control_behavior().get_section(1).filters
				local copy, agree = e.data.fl.r[1], #e.data.fl.r[1] == #filters
				for i = 1, #filters do
					agree = agree and (copy[i].value and copy[i].value.name) == (filters[i].value and filters[i].value.name)
				end
				ctx.expect(agree, "the copy is the section's filters, slot for slot")
			end)
		end)
	end)
end)

t.case("circuit: a one-slot write at a slot past the engine's live filters (slots 9 and 10 cleared in two writes, then one " ..
	"new signal into slot 10) fails nothing, reaches the far pole, and the section equals the Lua copy (radar perf P1)", function(ctx)
	local Y = "cl-sl-y"
	local r, ca
	local names = { "signal-A", "signal-B", "signal-C", "signal-D", "signal-E", "signal-F", "signal-G", "signal-H", "signal-I",
		"signal-J" }
	local list = {}
	for i, n in ipairs(names) do
		list[#list + 1] = n
		list[#list + 1] = i
	end
	local a, b = sig(list), sig({ "signal-X", 4 })
	ctx.at(3350, function()
		r = layouts.circuit_row(loop, "cl-sl", 11400, { 2 }, 8)
		ca = layouts.own(r, "a", 1, "r", a)
		layouts.own(r, "b", 1, "r", b)
	end)
	wait(ctx, 3351, 3500, function() return exact(r, "r", a, b) end, function(k)
		ctx.expect(k, "exact by 3500")
		if not k then
			return
		end
		local e = ep(Y)
		local function without(list_, name)
			local out = {}
			for _, s in ipairs(list_) do
				if s.name ~= name then
					out[#out + 1] = s
				end
			end
			return out
		end
		local at9, at10
		for _, n in ipairs(names) do
			local i = core.get(e.data.slot.r, "virtual", "normal", n)
			at9 = i == 9 and n or at9
			at10 = i == 10 and n or at10
		end
		ctx.expect(at9 ~= nil and at10 ~= nil, "signals hold slots 9 and 10")
		if not (at9 and at10) then
			return
		end
		ctx.at(k + 1, function()
			a = without(a, at9)
			layouts.set(ca, a)
		end)
		wait(ctx, k + 2, k + 2 * P + 20, function() return exact(r, "r", a, b) end, function(h)
			ctx.expect(h, "exact without slot 9's signal")
			if not h then
				return
			end
			ctx.at(h + 1, function()
				a = without(a, at10)
				layouts.set(ca, a)
			end)
			wait(ctx, h + 2, h + 2 * P + 20, function() return exact(r, "r", a, b) end, function(f)
				ctx.expect(f, "exact without slot 10's signal too")
				if not f then
					return
				end
				ctx.at(f + 1, function()
					local live = #e.data.comb.r.get_control_behavior().get_section(1).filters
					ctx.expect(live < 10, "the engine holds " .. live .. " filters before the write, so slot 10 is past them")
					a[#a + 1] = { type = "virtual", name = "signal-K", count = 11 } -- takes slot 10, past the copy's 8
					layouts.set(ca, a)
				end)
				wait(ctx, f + 2, f + 2 * P + 20, function() return exact(r, "r", a, b) end, function(g)
					ctx.expect(g, "the far pole shows the new signal")
					ctx.expect(g and g <= 3850, "the case ends by 3850 (at " .. tostring(g) .. ")")
					ctx.expect(e.state ~= "failed", "the endpoint did not fail")
					ctx.expect(core.get(e.data.slot.r, "virtual", "normal", "signal-K") == 10, "it went to slot 10")
					local filters = e.data.comb.r.get_control_behavior().get_section(1).filters
					local copy = e.data.fl.r[1]
					local agree = #filters == #copy
					for i = 1, math.min(#filters, #copy) do
						agree = agree and (copy[i].value and copy[i].value.name) == (filters[i].value and filters[i].value.name)
					end
					ctx.expect(agree, "the section equals the copy: " .. #filters .. " filters, " .. #copy .. " in the copy")
				end)
			end)
		end)
	end)
end)

t.case("circuit: a one-slot write that raises fails the endpoint, resets the colour's record, and the retry writes the " ..
	"colour again from the mirror (radar perf P1)", function(ctx)
	local Y = "cl-os-y"
	local r, ca
	local a, b = sig({ "signal-A", 3, "signal-C", 5 }), sig({ "signal-B", 4 })
	ctx.at(3350, function()
		r = layouts.circuit_row(loop, "cl-os", 11500, { 2 }, 8)
		ca = layouts.own(r, "a", 1, "r", a)
		layouts.own(r, "b", 1, "r", b)
	end)
	wait(ctx, 3351, 3500, function() return exact(r, "r", a, b) end, function(k)
		ctx.expect(k, "exact by 3500")
		if not k then
			return
		end
		local e = ep(Y)
		ctx.at(k + 1, function()
			-- the copy stores a filter the section rejects (no such item) for the next new slot, and nothing else
			local bad = { value = { type = "item", name = "cl-no-such-item", quality = "normal" }, min = 1 }
			e.data.fl.r[1] = setmetatable({ table.unpack(e.data.fl.r[1]) }, {
				__newindex = function(copy, j) rawset(copy, j, bad) end,
			})
			a = sig({ "signal-A", 3, "signal-C", 5, "signal-D", 6 })
			layouts.set(ca, a)
		end)
		wait(ctx, k + 2, k + 2 * P + 20, function() return e.state == "failed" end, function(h)
			ctx.expect(h, "the one-slot write's raise failed y's circuit endpoint")
			if not h then
				return
			end
			ctx.expect(next(e.data.slot.r) == nil and e.data.top.r == 0 and e.data.ninj.r == 0, "its slot map was reset")
			ctx.expect(core.size(e.data.todo.r) == 3, "and the three mirror signals are due again: " .. core.size(e.data.todo.r))
			ctx.expect(#e.data.comb.r.get_control_behavior().get_section(1).filters == 0, "the section was emptied")
			loop.connectors("cl-os", 2, r.list) -- G6's retry
			wait(ctx, game.tick - t.first_tick + 1, h + 3 * P, function() return exact(r, "r", a, b) end, function(f)
				ctx.expect(f, "retried, the far pole shows exactly the desired set")
				ctx.expect(f and #e.data.fl.r[1] == 3 and #e.data.comb.r.get_control_behavior().get_section(1).filters == 3,
					"from three slots, the copy and the section agreeing")
			end)
		end)
	end)
end)

t.case("circuit: a quiet network is not read again (get_signals_changed, spike 29): the skips grow while nothing is sent, "
	.. "and a change at the near pole still crosses within a period and a half", function(ctx)
	local X = "cl-sg-x"
	local r, ca
	local a = sig({ "signal-A", 3 })
	ctx.at(3100, function()
		r = layouts.circuit_row(loop, "cl-sg", 11600, { 2 }, 8)
		ca = layouts.own(r, "a", 1, "r", a)
	end)
	wait(ctx, 3101, 3400, function() return exact(r, "r", a) end, function(k)
		ctx.expect(k, "exact by 3400")
		if not k then
			return
		end
		local d = ep(X).data
		local skipped, sent
		ctx.at(k + P + 5, function() skipped, sent = d.stats.skipped or 0, d.stats.sent end)
		ctx.at(k + 4 * P, function()
			ctx.expect((d.stats.skipped or 0) >= skipped + 2, "the quiet network's polls skipped the read: " .. (d.stats.skipped or 0))
			ctx.expect(d.stats.sent == sent, "and sent nothing")
			a = sig({ "signal-A", 3, "signal-B", 4 })
			layouts.set(ca, a)
		end)
		wait(ctx, k + 4 * P + 1, k + 4 * P + P + 10, function() return exact(r, "r", a) end, function(h)
			ctx.expect(h, "a change at the near pole is exact on the far pole within P + 10 ticks")
		end)
	end)
end)

t.case("circuit: a colour that stops carrying and carries again, on a network nobody touched, reads again and the far "
	.. "pole shows the near signals again (spike 29: the quiet branch clears the read tick)", function(ctx)
	local X = "cl-sg2-x"
	local r
	local a = sig({ "signal-A", 3 })
	ctx.at(3100, function()
		r = layouts.circuit_row(loop, "cl-sg2", 11700, { 2, 5 }, 8)
		layouts.own(r, "a", 1, "r", a)
		layouts.wire(r.a[1], r.a[2], "r") -- x's poles are one network, y's are two: a tree
	end)
	wait(ctx, 3101, 3400, function() return exact(r, "r", a) and same(read(r.b[2], "r"), map(a)) end, function(k)
		ctx.expect(k, "the tree is exact by 3400")
		if not k then
			return
		end
		ctx.at(k + 1, function() layouts.wire(r.b[1], r.b[2], "r") end) -- y joins its poles: c2 closes a loop
		wait(ctx, k + 2, k + 4 * P, function() return ep(X, "c2").data.carry.r == false end, function(q)
			ctx.expect(q, "x's c2 stopped carrying red, its own network untouched")
			if not q then
				return
			end
			ctx.at(q + 1, function() layouts.wire(r.b[1], r.b[2], "r", true) end) -- y parts its poles again
			wait(ctx, q + 2, q + 5 * P, function() return ep(X, "c2").data.carry.r == true end, function(c)
				ctx.expect(c, "x's c2 carries red again")
				wait(ctx, (c or q) + 1, (c or q) + 3 * P, function() return exact(r, "r", a) and same(read(r.b[2], "r"), map(a)) end,
					function(e) ctx.expect(e, "and the far side shows A again") end)
			end)
		end)
	end)
end)
