
-- The circuit link's envelope (circuit-link spec §13.3; plan Task 5): many links on one edge against the real-wire sum,
-- the guard off, b′'s cache, feedback, the eight signal types and int32, poles, and sizes. Rows on nauvis at x
-- 10500–10980; small cases at ticks 300–2400, the guard off at 2600–3400, the size cases one at a time at 2600–3800
-- (the write budget is one per instance; Task 4's big writes own 1400–1900 and 2000–2500).
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
local ID = defines.wire_connector_id
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

--- Every pole of a row, both sides, reads `want` on red: a real wire's sum when every network is one component.
local function everywhere(r, want)
	for i = 1, #r.cols do
		if not (same(read(r.a[i], "r"), want) and same(read(r.b[i], "r"), want)) then
			return false
		end
	end
	return true
end

--- Each link's red carry on one side, as "1000"-style.
local function carrying(edge, n)
	local out = {}
	for i = 1, n do
		local g = ep(edge, "c" .. i).data.guard
		out[i] = g and g.cr and "1" or "0"
	end
	return table.concat(out)
end

--- Signal X on a pole's colour c, 0 when absent.
local function value(pole, c, name)
	return core.get(read(pole, c), "virtual", "normal", name or "signal-X") or 0
end

--- The ue-link-combinators on one side of a row.
local function injectors(r, side)
	local x1, y1, x2, y2 = geometry.area_to_world(side == "a" and r.fa or r.fb, -1, -4, r.L + 1, 1)
	return game.surfaces.nauvis.count_entities_filtered({ name = "ue-link-combinator", area = { { x1, y1 }, { x2, y2 } } })
end

--- A pool of n signals as own lists, at base + i.
local function pool(n, base)
	local out = {}
	for i, s in ipairs(seams.pool(n)) do
		out[i] = { type = s.type, name = s.name, quality = s.quality, count = base + i }
	end
	return out
end

-- b′'s computations, by edge side: { tick, n } each (K15: one per side per period).
local computes = {}
local compute = circuit.compute
function circuit.compute(list, n, tick)
	local edge = list[1].edge
	computes[edge] = computes[edge] or {}
	table.insert(computes[edge], { tick = tick, n = n })
	return compute(list, n, tick)
end

-- ue.chunk parts and truncated lines, by edge, read from the queue before each flush (wrappers chain).
local parts, truncs = {}, {}
local flush = bridge.flush
function bridge.flush(tick)
	for _, msg in ipairs(storage.universal_edges.bridge.out.universal_edges or {}) do
		local p = msg.payload
		if msg.type == "ue.chunk" then
			local edge = string.match(p.key, "^(.*)/[^/]+/ep/[^/]+$")
			if edge then
				parts[edge] = (parts[edge] or 0) + 1
			end
		elseif msg.type == "trace" and p.op == "ue.circuit" and p.phase == "truncated" then
			truncs[p.edge] = (truncs[p.edge] or 0) + 1
		end
	end
	flush(tick)
end

local injected = 0
--- A ue.lane payload into this save's inbox at once, from sender c1c00001: a direct seam, past the loopback.
local function inject(payload)
	injected = injected + 1
	ue_rt.inbox("universal_edges", helpers.table_to_json({ { id = "c1c00001." .. injected, type = "ue.lane",
		payload = payload } }))
end

--- Power for combinators on a side of a row: an electric-energy-interface beside the border pole.
local function powered(f)
	local eei = layouts.put(f, "electric-energy-interface", 4, 4)
	eei.power_production, eei.electric_buffer_size = 1e5, 1e7
end

--- An arithmetic combinator at local (x, 3) of frame f: out = signal-X + add (signal-X), its input and output wired to
--- pole on the given colours.
local function adder(f, x, pole, add, input, output)
	local ac = layouts.put(f, "arithmetic-combinator", x, 3, 0)
	ac.get_or_create_control_behavior().parameters = { first_signal = { type = "virtual", name = "signal-X" },
		second_constant = add, operation = "+", output_signal = { type = "virtual", name = "signal-X" } }
	local wire = { r = ID.circuit_red, g = ID.circuit_green }
	local into = input == "r" and ID.combinator_input_red or ID.combinator_input_green
	local out = output == "r" and ID.combinator_output_red or ID.combinator_output_green
	ac.get_wire_connector(into, true).connect_to(pole.get_wire_connector(wire[input], true), false, defines.wire_origin.player)
	ac.get_wire_connector(out, true).connect_to(pole.get_wire_connector(wire[output], true), false, defines.wire_origin.player)
	return ac
end

local FOUR = { 2, 5, 8, 11 }

t.case("circuit loops: four links whose poles are joined on both sides — only the lowest cid carries, exact against the " ..
	"real-wire sum, and steady for 20 periods (C2 b′, §7.7)", function(ctx)
	local r
	local total = map(sig({ "signal-A", 1 }), sig({ "signal-B", 10 }))
	ctx.at(300, function()
		r = layouts.circuit_row(loop, "cl-par", 10500, FOUR, 16)
		for i = 1, 3 do
			layouts.wire(r.a[i], r.a[i + 1], "r")
			layouts.wire(r.b[i], r.b[i + 1], "r")
		end
		layouts.own(r, "a", 1, "r", sig({ "signal-A", 1 }))
		layouts.own(r, "b", 1, "r", sig({ "signal-B", 10 }))
	end)
	wait(ctx, 301, 1100, function() return everywhere(r, total) end, function(k)
		ctx.expect(k, "exact by +1100")
		if not k then
			return
		end
		for p = 1, 20 do
			ctx.at(k + p * P, function()
				ctx.expect(everywhere(r, total), "exact " .. p .. " periods on")
				local x, y = carrying("cl-par-x", 4), carrying("cl-par-y", 4)
				ctx.expect(x == "1000" and y == "1000", "only c1 carries: " .. x .. " / " .. y)
			end)
		end
	end)
end)

t.case("circuit loops: X's bus on all four poles, Y wiring only the third — every link carries and every pole reads " ..
	"X's and Y's signals (the review's C-1)", function(ctx)
	local r
	local total = map(sig({ "signal-A", 1 }), sig({ "signal-C", 100 }))
	ctx.at(300, function()
		r = layouts.circuit_row(loop, "cl-asym", 10530, FOUR, 16)
		for i = 1, 3 do
			layouts.wire(r.a[i], r.a[i + 1], "r")
		end
		layouts.own(r, "a", 1, "r", sig({ "signal-A", 1 }))
		layouts.own(r, "b", 3, "r", sig({ "signal-C", 100 }))
	end)
	wait(ctx, 301, 1200, function() return everywhere(r, total) end, function(k)
		ctx.expect(k, "every pole reads A + C by +1200")
		if k then
			ctx.expect(carrying("cl-asym-x", 4) == "1111" and carrying("cl-asym-y", 4) == "1111", "all four carry")
		end
	end)
end)

t.case("circuit loops: two networks a side, cross-wired — a 4-cycle on one edge; three links carry and all four " ..
	"networks are exact", function(ctx)
	local r
	local total = map(sig({ "signal-A", 1, "signal-B", 10, "signal-C", 100, "signal-D", 1000 }))
	ctx.at(300, function()
		r = layouts.circuit_row(loop, "cl-cross", 10560, FOUR, 16)
		layouts.wire(r.a[1], r.a[2], "r")
		layouts.wire(r.a[3], r.a[4], "r")
		layouts.wire(r.b[1], r.b[3], "r")
		layouts.wire(r.b[2], r.b[4], "r")
		layouts.own(r, "a", 1, "r", sig({ "signal-A", 1 }))
		layouts.own(r, "a", 3, "r", sig({ "signal-B", 10 }))
		layouts.own(r, "b", 1, "r", sig({ "signal-C", 100 }))
		layouts.own(r, "b", 2, "r", sig({ "signal-D", 1000 }))
	end)
	wait(ctx, 301, 1300, function() return everywhere(r, total) end, function(k)
		ctx.expect(k, "all four networks exact by +1300")
		if k then
			ctx.expect(carrying("cl-cross-x", 4) == "1110" and carrying("cl-cross-y", 4) == "1110", "c1–c3 carry, c4 is quiet")
		end
	end)
end)

t.case("circuit loops: a join and then a split on one side — exact again within 7 periods of each (6 measured, plus " ..
	"one for the cache), with no runaway (§7.7)", function(ctx)
	local r
	local total = map(sig({ "signal-A", 1, "signal-B", 10, "signal-C", 100 }))
	local function settled(at, what, want, after)
		wait(ctx, at + 1, at + 7 * P, function() return everywhere(r, total) end, function(k)
			ctx.expect(k, what .. ": exact again within 7 periods")
			if not k then
				return
			end
			log("cl rewire: " .. what .. " exact +" .. (k - at))
			ctx.at(k + 3 * P, function()
				ctx.expect(everywhere(r, total), what .. ": still exact 3 periods on, no runaway")
				ctx.expect(carrying("cl-join-x", 4) == want and carrying("cl-join-y", 4) == want, what .. ": carries " .. want)
				if after then
					after(k + 3 * P + 1)
				end
			end)
		end)
	end
	ctx.at(300, function()
		r = layouts.circuit_row(loop, "cl-join", 10590, FOUR, 16)
		layouts.wire(r.a[1], r.a[2], "r")
		layouts.wire(r.a[3], r.a[4], "r")
		for i = 1, 3 do
			layouts.wire(r.b[i], r.b[i + 1], "r")
		end
		layouts.own(r, "a", 1, "r", sig({ "signal-A", 1 }))
		layouts.own(r, "a", 3, "r", sig({ "signal-B", 10 }))
		layouts.own(r, "b", 1, "r", sig({ "signal-C", 100 }))
	end)
	wait(ctx, 301, 1100, function() return everywhere(r, total) end, function(k)
		ctx.expect(k, "exact by +1100")
		if not k then
			return
		end
		ctx.at(k + 1, function() layouts.wire(r.a[2], r.a[3], "r") end) -- X joins: c3 goes quiet
		settled(k + 1, "after the join", "1000", function(at)
			ctx.at(at, function() layouts.wire(r.a[2], r.a[3], "r", true) end) -- X splits: c3 carries again
			settled(at, "after the split", "1010")
		end)
	end)
end)

t.case("circuit loops, the guard off by a seam: two parallel links grow linearly, four about ×9 every 4 periods, and " ..
	"with the guard back on both drain to exact (§7.7, C2's dropped option a)", function(ctx)
	local r2, r4
	local noguard = { ["cl-ng2-x"] = true, ["cl-ng2-y"] = true, ["cl-ng4-x"] = true, ["cl-ng4-y"] = true }
	local ten = map(sig({ "signal-X", 10 }))
	ctx.at(2600, function()
		storage.universal_edges.circuit_noguard = noguard
		r2 = layouts.circuit_row(loop, "cl-ng2", 10620, { 2, 5 }, 8)
		r4 = layouts.circuit_row(loop, "cl-ng4", 10640, FOUR, 16)
		for _, r in ipairs({ r2, r4 }) do
			for i = 1, #r.cols - 1 do
				layouts.wire(r.a[i], r.a[i + 1], "r")
				layouts.wire(r.b[i], r.b[i + 1], "r")
			end
			layouts.own(r, "a", 1, "r", sig({ "signal-X", 10 }))
		end
	end)
	wait(ctx, 2601, 3000, function() return value(r2.a[1], "r") > 10 and value(r4.a[1], "r") > 10 end, function(k)
		ctx.expect(k, "both loops have started to climb")
		if not k then
			return
		end
		local v2, v4 = {}, {}
		for p = 0, 3 do
			local function sample()
				v2[p], v4[p] = value(r2.a[1], "r"), value(r4.a[1], "r")
			end
			if p == 0 then
				sample() -- wait's done runs at offset k itself
			else
				ctx.at(k + 4 * p * P, sample)
			end
		end
		ctx.at(k + 12 * P + 1, function()
			log("cl noguard: two links " .. table.concat({ v2[0], v2[1], v2[2], v2[3] }, ", ") .. "; four "
				.. table.concat({ v4[0], v4[1], v4[2], v4[3] }, ", "))
			local g1, g2 = v2[2] - v2[1], v2[3] - v2[2]
			ctx.expect(g1 > 0 and g2 > 0 and g2 <= 2 * g1 + 10, "two links climb linearly: +" .. g1 .. ", +" .. g2)
			ctx.expect(v4[1] >= 4 * v4[0] and v4[2] >= 4 * v4[1], "four links climb geometrically")
			storage.universal_edges.circuit_noguard = nil
		end)
		wait(ctx, k + 12 * P + 2, k + 22 * P, function()
			return everywhere(r2, ten) and everywhere(r4, ten)
		end, function(e) ctx.expect(e, "the guard back on, both drain to exact within 10 periods") end)
	end)
end)

t.case("circuit b′'s cache: 20 links on one edge compute b′ once per side per period over all 20 (2n reads, not 2n²), " ..
	"and what they hold equals a fresh computation (fix 2, K15)", function(ctx)
	-- The brief's 20 links, at row length 64. They pass now because of two power fixes. F-PW (6eec388): under a load the
	-- link couldn't yet carry, y's buffer fell to the 10 MJ floor (124 to 10 MJ, the sink fed 0.00075). F-PW2's option B
	-- (sdd/2026-10-04-ue-circuit-link/fpw2-report.md): a power endpoint takes the partner's drain since its status off
	-- the estimate of what the partner holds, so a side sends about C/2 a poll, not C/3. Option A (a648cdb): the scheduler
	-- keeps its cadence across a wake's extra walk (spec §4.2).
	local N = 20
	local cols = {}
	for i = 1, N do
		cols[i] = 2 + 3 * (i - 1)
	end
	local r
	local function each_exact()
		for i = 1, N do
			local want = map(sig({ "signal-A", i, "signal-B", 100 + i }))
			if not (same(read(r.a[i], "r"), want) and same(read(r.b[i], "r"), want)) then
				return false
			end
		end
		return true
	end
	ctx.at(300, function()
		r = layouts.circuit_row(loop, "cl-cache", 10680, cols, 64)
		for i = 1, N do
			layouts.own(r, "a", i, "r", sig({ "signal-A", i }))
			layouts.own(r, "b", i, "r", sig({ "signal-B", 100 + i }))
		end
	end)
	wait(ctx, 301, 1000, each_exact, function(k)
		ctx.expect(k, "all 20 links exact by +1000")
		if not k then
			return
		end
		local from = t.first_tick + k
		ctx.at(k + 10 * P, function()
			for _, edge in ipairs({ "cl-cache-x", "cl-cache-y" }) do
				local n, all_n, gap, prev = 0, true, math.huge, nil
				for _, c in ipairs(computes[edge] or {}) do
					if c.tick > from then
						n = n + 1
						all_n = all_n and c.n == N
						gap = prev and math.min(gap, c.tick - prev) or gap
						prev = c.tick
					end
				end
				-- A fact (the first run): the scheduler's walk of the save's circuit endpoints at 4 a tick takes about 80 ticks,
				-- longer than P, so a side computes once a walk (7-8 in 10 periods), never more than once a period.
				log("cl cache: " .. edge .. " " .. n .. " computations in 10 periods, closest " .. gap .. " ticks apart")
				ctx.expect(n >= 5 and gap >= P and all_n, edge .. ": " .. n .. " computations over 10 periods, none within " ..
					P .. " ticks of another, each of all 20")
				local side = storage.universal_edges.edges[edge]
				local list, before = {}, {}
				for cid, ty in pairs(side.eps) do
					if ty == "circuit" then
						local e = connectors.get(side, cid)
						list[#list + 1] = e
						local g = e.data.guard
						before[cid] = { g.gr, g.gg, g.cr, g.cg }
					end
				end
				compute(list, #list, game.tick) -- the seam: a fresh computation, unwrapped
				for _, e in ipairs(list) do
					local g = e.data.guard
					ctx.expect(same(before[e.cid], { g.gr, g.gg, g.cr, g.cg }), edge .. "/" .. e.cid .. ": cached = fresh")
					ctx.expect(g.cr, edge .. "/" .. e.cid .. " carries: every pole is its own network")
				end
			end
			loop.connectors("cl-cache", 2, {}) -- closed once checked: its endpoints would still crowd the other types' walks
		end)
	end)
end)

t.case("circuit feedback: a +1-a-tick source crosses as jumps about a period apart, never ahead of it, with no drift " ..
	"once it stops (§3; spike 9 Q5)", function(ctx)
	local r, comb
	local x, bad, changes, last = 1, 0, 0, nil
	ctx.at(300, function()
		r = layouts.circuit_row(loop, "cl-ramp", 10760, { 2 }, 8)
		comb = layouts.own(r, "a", 1, "r", sig({ "signal-X", 1 }))
	end)
	wait(ctx, 301, 800, function() return exact(r, "r", sig({ "signal-X", 1 })) end, function(k)
		ctx.expect(k, "the link carries by +800")
		if not k then
			return
		end
		local function step()
			local off = game.tick - t.first_tick
			x = x + 1
			layouts.set(comb, sig({ "signal-X", x }))
			local b = value(r.b[1], "r")
			if b > x or x - b > 3 * P + 4 then
				bad = bad + 1
			end
			if b ~= last then
				changes, last = changes + 1, b
			end
			if off < k + 10 * P then
				ctx.at(off + 1, step)
			end
		end
		ctx.at(k + 1, step)
		wait(ctx, k + 10 * P + 2, k + 14 * P, function() return value(r.b[1], "r") == x end, function(e)
			ctx.expect(e, "no drift: B's pole equals the source within 4 periods of its stop")
			ctx.expect(bad == 0, "never ahead of the source, never more than 3P + L + 3 behind: " .. bad)
			ctx.expect(changes >= 5 and changes <= 12, "about one jump a period: " .. changes .. " in 10")
		end)
	end)
end)

t.case("circuit feedback: a powered arithmetic self-loop (+1 a tick) crosses the same way, and B's pole drops it when it " ..
	"goes (spike 9's open question; §17 item 2)", function(ctx)
	local r, ac
	local bad, changes, last = 0, 0, nil
	ctx.at(300, function()
		r = layouts.circuit_row(loop, "cl-self", 10780, { 2 }, 8, { depth = 10 })
		powered(r.fa)
		ac = adder(r.fa, 2.5, r.a[1], 1, "r", "r")
	end)
	wait(ctx, 301, 900, function() return value(r.a[1], "r") > 60 and value(r.b[1], "r") > 0 end, function(k)
		ctx.expect(k, "the counter runs on A and reaches B by +900")
		if not k then
			return
		end
		local function step()
			local off = game.tick - t.first_tick
			local a, b = value(r.a[1], "r"), value(r.b[1], "r")
			if b > a or a - b > 3 * P + 4 then
				bad = bad + 1
			end
			if b ~= last then
				changes, last = changes + 1, b
			end
			if off < k + 10 * P then
				ctx.at(off + 1, step)
			end
		end
		ctx.at(k + 1, step)
		ctx.at(k + 10 * P + 1, function()
			ctx.expect(bad == 0, "B never ahead of A's counter, never more than 3P + L + 3 behind: " .. bad)
			ctx.expect(changes >= 5 and changes <= 12, "about one jump a period: " .. changes .. " in 10")
			ac.destroy()
		end)
		wait(ctx, k + 10 * P + 2, k + 14 * P, function() return value(r.b[1], "r") == 0 end, function(e)
			ctx.expect(e, "the counter gone, B's pole drops it")
		end)
	end)
end)

t.case("circuit feedback: a loop through the border (B adds 1 to A's signal, A copies it back) counts one step per round " ..
	"trip, no faster (§3)", function(ctx)
	local r, acs
	local steps, last, at, fast, jumps = 0, 0, nil, 0, 0
	ctx.at(300, function()
		r = layouts.circuit_row(loop, "cl-trip", 10800, { 2 }, 8, { depth = 10 })
		powered(r.fa)
		powered(r.fb)
		acs = { adder(r.fa, 2.5, r.a[1], 0, "g", "r"), -- A: green's X copied onto red
			adder(r.fb, geometry.col("b", r.L, 2, 1) + 0.5, r.b[1], 1, "r", "g") } -- B: red's X plus 1 onto green
	end)
	local function step()
		local off = game.tick - t.first_tick
		local x = value(r.a[1], "r")
		if x ~= last then
			if x - last ~= 1 then
				jumps = jumps + 1
			end
			if at and game.tick - at < 6 then
				fast = fast + 1 -- a round trip is two hops of at least L + 2 ticks each
			end
			steps, last, at = steps + 1, x, game.tick
		end
		if off < 1100 then
			ctx.at(off + 1, step)
		end
	end
	ctx.at(301, step)
	ctx.at(1101, function()
		for _, ac in ipairs(acs) do
			ac.destroy() -- P3: the loop writes every round trip, so it stops before Task 4's big writes (1400)
		end
		log("cl trip: " .. steps .. " steps in 800 ticks")
		ctx.expect(steps >= 3 and steps <= 17, "one step per round trip: " .. steps .. " in 800 ticks")
		ctx.expect(jumps == 0 and fast == 0, "each step +1, none quicker than a round trip")
	end)
end)

t.case("circuit values: all eight signal types and a non-normal quality cross; at int32's limit both poles read what a " ..
	"real wire reads (§3, §8.6; §17 item 3)", function(ctx)
	local r, rig
	local kinds = {
		{ type = "item", name = "iron-plate", quality = "uncommon", count = 1 },
		{ type = "fluid", name = "water", count = 2 },
		{ type = "virtual", name = "signal-A", count = 3 },
		{ type = "entity", name = "stone-furnace", count = 4 },
		{ type = "recipe", name = "iron-gear-wheel", count = 5 },
		{ type = "quality", name = "rare", count = 6 },
		{ type = "space-location", name = "nauvis", count = 7 },
		{ type = "asteroid-chunk", name = "metallic-asteroid-chunk", count = 8 },
	}
	local max = { { type = "virtual", name = "signal-M", count = 2147483647 } }
	ctx.at(300, function()
		r = layouts.circuit_row(loop, "cl-types", 10820, { 2 }, 8)
		layouts.own(r, "a", 1, "r", kinds)
		layouts.own(r, "a", 1, "g", max)
		layouts.own(r, "b", 1, "g", max)
		rig = layouts.put(r.fa, "medium-electric-pole", 7.5, 5.5) -- the real wire: two combinators of 2^31 - 1, one pole
		for _, x in ipairs({ 6.5, 8.5 }) do
			local c = layouts.put(r.fa, "constant-combinator", x, 6.5)
			layouts.set(c, max)
			layouts.wire(c, rig, "r")
		end
	end)
	wait(ctx, 301, 700, function()
		local real = value(rig, "r", "signal-M")
		return same(read(r.b[1], "r"), map(kinds)) and value(r.a[1], "g", "signal-M") == real
			and value(r.b[1], "g", "signal-M") == real
	end, function(k)
		ctx.expect(k, "every type crossed, and both poles read the real wire's " .. value(rig, "r", "signal-M"))
		log("cl int32: a real wire reads " .. value(rig, "r", "signal-M") .. " for 2 × (2^31 - 1)")
	end)
end)

t.case("circuit poles: with no pole on the far side the link waits, quiet; a pole built there carries within 3P + 2L + 2 " ..
	"of the build (§6.5, K11)", function(ctx)
	local r
	local a = sig({ "signal-A", 6 })
	ctx.at(300, function()
		r = layouts.circuit_row(loop, "cl-nopole", 10860, { 2 }, 8, { no_b = true })
		layouts.own(r, "a", 1, "r", a)
	end)
	ctx.at(600, function()
		local y = ep("cl-nopole-y")
		ctx.expect(y.state == "ready" and y.data.border == nil, "y is ready, with no pole")
		ctx.expect(not (ep("cl-nopole-x").data.guard or {}).cr, "x keeps the link quiet: y sends no group")
		local wx, wy = geometry.to_world(r.fb, geometry.col("b", r.L, 2, 1) + 0.5, 0.5)
		r.b[1] = game.surfaces.nauvis.create_entity({ name = "medium-electric-pole", position = { wx, wy },
			force = "player", raise_built = true }) -- FC2 caches it on both of y's endpoints there
	end)
	wait(ctx, 601, 601 + 4 * P, function() return same(read(r.b[1], "r"), map(a)) end, function(k)
		ctx.expect(k, "A's signal reached the new pole")
		if k then
			log("cl nopole: exact +" .. (k - 600) .. " after the build")
			ctx.expect(k - 600 <= 4 * P + 4, "within 3P + 2L + 2, plus a period (plan ruling 6): " .. (k - 600))
		end
	end)
end)

t.case("circuit poles: a fast-replaced and an upgraded pole keep the link, injectors rewired; a green injector first " ..
	"needed during the replacement waits for the rewire; the far side never reads its own signal cancelled (§6.3, §7.5 " ..
	"step 4, plan ruling 10, Review Focus 5)", function(ctx)
	local X = "cl-swap-x"
	local r, ca, held
	local a, b, g = sig({ "signal-A", 1 }), sig({ "signal-B", 4 }), sig({ "signal-G", 6 })
	local cancelled, crowded = 0, 0
	local function watch()
		if value(r.b[1], "r", "signal-B") ~= 4 then
			cancelled = cancelled + 1
		end
		if injectors(r, "a") > 2 then
			crowded = crowded + 1
		end
	end
	local function both()
		watch()
		return exact(r, "r", a, b) and exact(r, "g", g)
	end
	--- Replace A's pole: name onto the same spot, fast-replaced or (upgrade) the old one destroyed first, in one tick.
	local function replace(name, upgrade)
		local old = r.a[1]
		local s, p = game.surfaces.nauvis, old.position
		if upgrade then
			old.destroy()
		end
		r.a[1] = s.create_entity({ name = name, position = { p.x, p.y }, force = "player", fast_replace = not upgrade,
			spill = false })
		layouts.wire(ca, r.a[1], "r") -- the player wires the combinator to the new pole
		return r.a[1] ~= nil and r.a[1].valid and not old.valid
	end
	ctx.at(300, function()
		r = layouts.circuit_row(loop, "cl-swap", 10880, { 2 }, 8, { pole = "small-electric-pole" })
		ca = layouts.own(r, "a", 1, "r", a)
		layouts.own(r, "b", 1, "r", b)
	end)
	wait(ctx, 301, 800, function() return exact(r, "r", a, b) end, function(k)
		ctx.expect(k, "exact by +800")
		if not k then
			return
		end
		ctx.at(k + 1, function()
			loop.taps[X] = function(copy) -- hold y's status that brings B's first green signal
				local s = copy.payload.status
				if copy.payload.k == "ep" and copy.payload.cid == "c1" and s and s.g then
					loop.taps[X] = nil
					held = copy
					return false
				end
			end
			layouts.own(r, "b", 1, "g", g)
		end)
		wait(ctx, k + 2, k + 3 * P, function() return held ~= nil end, function(h)
			ctx.expect(h, "y's green status was held")
			if not h then
				return
			end
			ctx.at(h + 1, function()
				ctx.expect(replace("medium-electric-pole", false), "fast-replaced")
				inject(held.payload) -- x folds B's green now: a write for a colour with no injector yet
			end)
			wait(ctx, h + 2, h + 5 * P, both, function(e)
				ctx.expect(e, "after the fast-replace, both colours exact on the new pole")
				if not e then
					return
				end
				ctx.expect(injectors(r, "a") == 2 and ep(X).data.unit == r.a[1].unit_number, "two injectors, on the new pole")
				ctx.at(e + 1, function() ctx.expect(replace("medium-electric-pole", true), "upgraded by its effect") end)
				wait(ctx, e + 2, e + 5 * P, both, function(u)
					ctx.expect(u, "after the upgrade, exact again")
					ctx.expect(cancelled == 0, "y never read its own B cancelled: " .. cancelled .. " ticks")
					ctx.expect(crowded == 0, "never a third injector")
					ctx.expect(ep(X).state == "ready" and ep(X, "p1").state == "ready", "both links stayed")
				end)
			end)
		end)
	end)
end)

--- One size case: A's own red (and green, unless g is nil) from the pool, at ticks from..to on its own row; done(k, r).
local function size_case(ctx, id, x0, from, to, reds, greens, done)
	local r, kr, kg
	ctx.at(from, function()
		r = layouts.circuit_row(loop, id, x0, { 2 }, 8)
		layouts.own(r, "a", 1, "r", reds)
		if greens then
			layouts.own(r, "a", 1, "g", greens)
		end
		kr, kg = core.fit(map(reds), map(greens or {})) -- what the sender keeps (K8), under the cap as it stands now
	end)
	wait(ctx, from + 1, to, function()
		return same(read(r.b[1], "r"), kr) and same(read(r.b[1], "g"), kg)
	end, function(k) done(k, r) end)
end

t.case("circuit size: 600 signals a colour cross whole, in parts (C3 b, FC3)", function(ctx)
	size_case(ctx, "cl-s600", 10900, 2600, 2850, pool(600, 0), pool(600, 1000), function(k)
		ctx.expect(k, "600 a colour crossed whole")
		ctx.expect((parts["cl-s600-x"] or 0) >= 2, "in ue.chunk parts: " .. tostring(parts["cl-s600-x"]))
	end)
end)

t.case("circuit size: spike 9d's 2,000 signals a colour on both colours cross whole, with nothing truncated (fix 4)",
	function(ctx)
		size_case(ctx, "cl-s2000", 10920, 2900, 3150, pool(2000, 0), pool(2000, 5000), function(k)
			ctx.expect(k, "2,000 × 2 crossed whole")
			ctx.expect((parts["cl-s2000-x"] or 0) >= 30, "in about 34 parts: " .. tostring(parts["cl-s2000-x"]))
		end)
		ctx.expect_no_ipc("universal_edges:out", '"phase":"truncated"', 2900, 3190)
	end)

t.case("circuit size: 2,100 signals in one colour keep 2,000, in K8's order, with one truncated line (K8)", function(ctx)
	size_case(ctx, "cl-s2100", 10940, 3200, 3450, pool(2100, 0), nil, function(k, r)
		ctx.expect(k, "the first 2,000 in K8's order crossed")
		ctx.expect(layouts.size(read(r.b[1], "r")) == 2000, "2,000 of 2,100")
		ctx.expect(truncs["cl-s2100-x"] == 1, "truncated once: " .. tostring(truncs["cl-s2100-x"]))
	end)
end)

t.case("circuit size: past the byte cap (lowered to 50,000 by a seam: no real names reach 180,000) the status " ..
	"truncates and still arrives (K8, plan ruling 7)", function(ctx)
	ctx.at(3499, function() core.MAX_BYTES = 50000 end)
	size_case(ctx, "cl-sbytes", 10960, 3500, 3780, pool(2000, 0), pool(2000, 5000), function(k, r)
		ctx.expect(k, "what fits under the cap crossed")
		local n = layouts.size(read(r.b[1], "r")) + layouts.size(read(r.b[1], "g"))
		ctx.expect(n > 0 and n < 4000, "truncated, not lost: " .. n .. " signals")
		ctx.expect(truncs["cl-sbytes-x"] ~= nil, "with a truncated line")
	end)
	ctx.at(3790, function() core.MAX_BYTES = 180000 end)
end)
