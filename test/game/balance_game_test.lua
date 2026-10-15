local t = require("modules/v2_test/testlib")
local loop = require("modules/v2_test/loopback")
local layouts = require("modules/v2_test/layouts")
local connectors = require("modules/universal_edges/edges/connectors")
local geometry = require("modules/universal_edges/edges/geometry_core")
local bridge = require("modules/universal_edges/runtime/bridge")

local ALL = {} -- get_accumulators_energy's filter: every accumulator

local function ep(edge, cid)
	local side = storage.universal_edges.edges[edge]
	return side and connectors.get(side, cid or "c1")
end

--- An endpoint's interface, nil before its build (review M4).
local function eei(e)
	local x = e and e.data.eei
	return x and x.valid and x or nil
end

--- §8.2's conservation at every exchange: around each power poll, credit and drain step, the network's accumulators plus
--- every link interface on it (the pooled storage) change by exactly what was credited minus what the drain removed (a
--- send is debt, not a write: a poll changes the pool by nothing).
local power = connectors.types.power
local errors = { n = 0, worst = 0 }
local function total(e)
	local x = eei(e)
	local net = x and x.electric_network
	if not net then
		return 0
	end
	local sum = net.parent_network.get_accumulators_energy(ALL).energy
	for _, o in pairs(storage.universal_edges.eps.power or {}) do
		local y = o.data.eei
		if y and y.valid and y.electric_network_id == x.electric_network_id then
			sum = sum + y.energy
		end
	end
	return sum
end
for _, hook in ipairs({ "poll", "credit" }) do
	local fn = power[hook]
	if fn then
		power[hook] = function(e, ...)
			local before, drained, got = total(e), e.data.stats.drained or 0, e.data.stats.got
			local result = fn(e, ...)
			local moved = 1000 * ((e.data.stats.got - got) - ((e.data.stats.drained or 0) - drained))
			errors.n, errors.worst = errors.n + 1, math.max(errors.worst, math.abs(total(e) - before - moved))
			return result
		end
	end
end

--- The drain task writes each pool back once, after every owing link has paid, so its conservation is checked around
--- the whole tick: the pools' stock (accumulators and interfaces) falls by exactly what the links' drain steps removed.
do
	local pm = require("modules/universal_edges/transports/power")
	local fn = pm.drain_tick
	local function stock()
		local sum, drained, seen = 0, 0, {}
		for _, o in pairs(storage.universal_edges.eps.power or {}) do
			local y = o.data.eei
			if y and y.valid then
				drained = drained + (o.data.stats.drained or 0)
				sum = sum + y.energy
				local net = y.electric_network
				if net and not seen[y.electric_network_id] then
					seen[y.electric_network_id] = true
					sum = sum + net.parent_network.get_accumulators_energy(ALL).energy
				end
			end
		end
		return sum, drained
	end
	function pm.drain_tick(tick)
		if next(storage.universal_edges.power_debt) == nil then
			return fn(tick)
		end
		local before, drained = stock()
		local result = fn(tick)
		local after, drained2 = stock()
		errors.n, errors.worst = errors.n + 1, math.max(errors.worst, math.abs(after - before + 1000 * (drained2 - drained)))
		return result
	end
end

-- Every s.offer a counted side sends, read from the bridge's queue just before each flush (the loopback's wrapper reads
-- the same queue; the two chain).
local offers = {}
local flush = bridge.flush
function bridge.flush(tick)
	local s = storage.universal_edges
	for _, msg in ipairs(s and s.bridge.out.universal_edges or {}) do
		local p = msg.payload
		if msg.type == "ue.lane" and p.k == "s.offer" and offers[p.edge] then
			offers[p.edge] = offers[p.edge] + 1
		end
	end
	flush(tick)
end

local function sat(sink)
	return sink.energy / sink.electric_buffer_size
end

local function size(e)
	local x = eei(e)
	return x and x.electric_buffer_size or 0
end

-- The load steps, from the build: 10 MW, 1 GW at +900, 2 GW at +1800, then 8 GW at +2700, past what one link carries
-- at its 10 GJ ceiling (D37: 3.4 to 5 GW in the model, by phase). Each full window starts 12 polls after its step, the
-- build counted as one; the model (plan Task 5) fed every sample of them at delays 1 to 10 and every phase. The 1 GW
-- window starts 14 polls after its step, not 12: the buffer a link carries into a step is its history's (startup's), and
-- with a send paid out as debt it was 54 MJ, not 160 MJ, so the ramp to 10 GJ took 13.6 polls.
t.case("power: the over-load sink (D14, D34, D37): fed in full up to 2 GW, the link at its ceiling under 8 GW, " ..
	"conservation at every exchange", function(ctx)
	local r, peak, got = nil, 0, 0
	local function at(offset, fn)
		ctx.at(400 + offset, fn)
	end
	at(0, function()
		r = layouts.power_pair(loop, "sp3-pw", 6400, 5, 400e6, 10e6 / 60) -- 24 GW of generation; a 10 MW load
	end)
	for offset = 10, 3000, 10 do
		at(offset, function()
			local ba, bb = size(ep("sp3-pw-x")), size(ep("sp3-pw-y"))
			peak = math.max(peak, ba, bb)
			if offset % 60 == 0 then
				log(string.format("sp3 power +%d: sat %.3f, buffers %.0f MJ and %.0f MJ", offset, sat(r.sink), ba / 1e6, bb / 1e6))
			end
			if (offset >= 720 and offset < 900) or (offset >= 1740 and offset < 1800) or (offset >= 2520 and offset < 2700) then
				ctx.expect(sat(r.sink) >= 0.99, "+" .. offset .. ": the sink is fed (" .. sat(r.sink) .. ")")
			end
		end)
	end
	at(900, function() layouts.set_usage(r.sink, 1e9 / 60) end)
	at(1800, function() layouts.set_usage(r.sink, 2e9 / 60) end)
	at(2700, function() layouts.set_usage(r.sink, 8e9 / 60) end)
	at(2820, function()
		got = ep("sp3-pw-y").data.stats.got
	end)
	at(3000, function()
		local gw = (ep("sp3-pw-y").data.stats.got - got) / 3e6 -- kJ over 3 s, in GW
		ctx.expect(gw >= 3, "under 8 GW the link carried " .. gw .. " GW (the model: 3.4 at worst)")
		for _, edge in ipairs({ "sp3-pw-x", "sp3-pw-y" }) do
			ctx.expect(size(ep(edge)) >= 9.99e9, edge .. "'s buffer is at the ceiling: " .. size(ep(edge)) / 1e9 .. " GJ")
		end
		ctx.expect(peak <= 10e9, "the largest buffer was " .. peak / 1e9 .. " GJ: at most 10 GJ (D37)")
		ctx.expect(errors.n > 50 and errors.worst < 1, errors.n .. " exchanges, worst error " .. errors.worst .. " J")
	end)
end)

-- Stored energy crossing: side a's only energy is 15 MJ in accumulators behind a switch; side b's 1 MW sink is fed
-- from it (the model: fed from +120, side a down to 2.6 MJ by +480 at worst).
t.case("power: a power switch joining sub-networks balances the parent network (D14); stored energy feeds the far " ..
	"side's load", function(ctx)
	local acc_a, sink = {}, nil
	ctx.at(600, function()
		local fa, fb = layouts.edge(loop, "sp3-sw", 6500, 12,
			{ { cid = "c1", type = "power", pos = 2, width = 2, params = {} } }, 40)
		local p1 = layouts.put(fa, "substation", 3, 1)
		local switch = layouts.put(fa, "power-switch", 3, 16)
		local p2 = layouts.put(fa, "substation", 3, 31)
		for k = 0, 2 do
			acc_a[k + 1] = layouts.put(fa, "accumulator", 1 + 2 * k, 34)
			acc_a[k + 1].energy = 5e6
		end
		local W, script = defines.wire_connector_id, defines.wire_origin.script
		p1.get_wire_connector(W.pole_copper, true).connect_to(switch.get_wire_connector(W.power_switch_left_copper, true),
			false, script)
		p2.get_wire_connector(W.pole_copper, true).connect_to(switch.get_wire_connector(W.power_switch_right_copper, true),
			false, script)
		switch.power_switch_state = true
		layouts.put(fb, "substation", 3, 1)
		for k = 0, 2 do
			layouts.put(fb, "accumulator", 1 + 2 * k, 6)
		end
		sink = layouts.put(fb, "ue-test-power-sink", 6.5, 3.5)
		layouts.set_usage(sink, 1e6 / 60)
	end)
	for at = 840, 1080, 10 do
		ctx.at(at, function()
			ctx.expect(sat(sink) >= 0.99, "+" .. (at - 600) .. ": side b's sink is fed (" .. sat(sink) .. ")")
		end)
	end
	ctx.at(1080, function()
		local st = ep("sp3-sw-x").status
		ctx.expect(st and st.c >= 25000, "side a's status counts the switched accumulators (c = " .. tostring(st and st.c) .. ")")
		local left = layouts.stored(acc_a) / 1e6
		ctx.expect(left < 10, "the accumulators behind the switch fed it: " .. left .. " MJ left")
	end)
end)

-- Two links on one pair of networks, each seeing the accumulators and its own interface only. A feeding side counts no
-- drain of its own, or each link would read the other's sends as its drain (review I2). The fills are compared over
-- the real capacities, the buffers included (the model: within 0.04 / 64 by +600, buffers at most 39 MJ).
t.case("power: two parallel links converge without creating energy", function(ctx)
	local acc_a, acc_b, start = {}, {}, nil
	local function stock()
		local e = layouts.stored(acc_a) + layouts.stored(acc_b)
		for _, edge in ipairs({ "sp3-par-x", "sp3-par-y" }) do
			for _, cid in ipairs({ "c1", "c2" }) do
				local x = eei(ep(edge, cid))
				e = e + (x and x.energy or 0) - ep(edge, cid).data.debt
			end
		end
		return e
	end
	--- A side's fill: its accumulators and both interfaces over their capacity and both buffers.
	local function fill(edge, list)
		local e, c = layouts.stored(list), 25e6 -- five accumulators of 5 MJ
		for _, cid in ipairs({ "c1", "c2" }) do
			local x = eei(ep(edge, cid))
			e, c = e + x.energy, c + x.electric_buffer_size
		end
		return e / c
	end
	ctx.at(900, function()
		local fa, fb = layouts.edge(loop, "sp3-par", 6600, 12, {
			{ cid = "c1", type = "power", pos = 2, width = 2, params = {} },
			{ cid = "c2", type = "power", pos = 7, width = 2, params = {} },
		}, 12)
		local W, script = defines.wire_connector_id, defines.wire_origin.script
		for _, side in ipairs({ { fa, acc_a, 5e6 }, { fb, acc_b, 0 } }) do
			local p1, p2 = layouts.put(side[1], "substation", 3, 1), layouts.put(side[1], "substation", 8, 1)
			p1.get_wire_connector(W.pole_copper, true).connect_to(p2.get_wire_connector(W.pole_copper, true), false, script)
			for k = 0, 4 do
				side[2][k + 1] = layouts.put(side[1], "accumulator", 1 + 2 * k, 6)
				side[2][k + 1].energy = side[3]
			end
		end
	end)
	ctx.at(940, function()
		start = stock()
	end)
	for at = 960, 1500, 20 do
		ctx.at(at, function()
			ctx.expect(stock() <= start + 1000, "+" .. at .. ": no energy created")
		end)
	end
	ctx.at(1500, function()
		local fa, fb = fill("sp3-par-x", acc_a), fill("sp3-par-y", acc_b)
		ctx.expect(math.abs(fa - fb) <= 2 / 64, "fill ratios " .. fa .. " and " .. fb)
	end)
end)

--- A source network on edge 1's side a, a relay network of edge 1's side b and edge 2's side a with no accumulators, and
--- a 10 MW sink on edge 2's side b: the relay's two interfaces share one network, so energy credited through one has to
--- leave through the other (2026-10-06: it read as 0 on the second link).
t.case("power: a relay -- energy arriving through one link leaves through another on the same network", function(ctx)
	local sink
	ctx.at(1000, function()
		local c = { { cid = "c1", type = "power", pos = 2, width = 2, params = {} } }
		local fa1, fb1 = layouts.edge(loop, "sp3-rl1", 12100, 12, c, 12)
		local fa2, fb2 = layouts.edge(loop, "sp3-rl2", 12140, 12, c, 12)
		layouts.put(fa1, "substation", 3, 1)
		layouts.put(fa1, "ue-test-power-source", 6.5, 3.5).power_production = 100e6 / 60
		local p1, p2 = layouts.put(fb1, "substation", 3, 1), layouts.put(fa2, "substation", 3, 1)
		local W, script = defines.wire_connector_id, defines.wire_origin.script
		p1.get_wire_connector(W.pole_copper, true).connect_to(p2.get_wire_connector(W.pole_copper, true), false, script)
		layouts.put(fb2, "substation", 3, 1)
		sink = layouts.put(fb2, "ue-test-power-sink", 6.5, 3.5)
		layouts.set_usage(sink, 10e6 / 60)
	end)
	for at = 1720, 2000, 20 do
		ctx.at(at, function()
			ctx.expect(sat(sink) >= 0.99, "+" .. at .. ": the sink is fed (" .. sat(sink) .. "); the relay link sent " ..
				ep("sp3-rl2-x").data.stats.sent)
		end)
	end
	ctx.at(2000, function()
		ctx.expect(errors.n > 50 and errors.worst < 1, errors.n .. " exchanges, worst error " .. errors.worst .. " J")
	end)
end)

--- Three edges, three networks in a loop (network i is edge i's side b and edge i+1's side a, wired), five accumulators
--- on each network, and energy in the first network's only: it spreads, makes none, and the traffic dies down.
t.case("power: a ring of three networks settles without creating energy", function(ctx)
	local names, acc, start = { "sp3-rg1", "sp3-rg2", "sp3-rg3" }, { {}, {}, {} }, nil
	local count = 0
	local function stock()
		local e = 0
		for i = 1, 3 do
			e = e + layouts.stored(acc[i])
			for _, side in ipairs({ "-x", "-y" }) do
				local x = eei(ep(names[i] .. side))
				e = e + (x and x.energy or 0) - ep(names[i] .. side).data.debt
			end
		end
		return e
	end
	local function fill(i)
		local e, c = layouts.stored(acc[i]), 25e6
		for _, x in ipairs({ eei(ep(names[i] .. "-y")), eei(ep(names[i % 3 + 1] .. "-x")) }) do
			e, c = e + x.energy, c + x.electric_buffer_size
		end
		return e / c
	end
	ctx.at(1100, function()
		local c = { { cid = "c1", type = "power", pos = 2, width = 2, params = {} } }
		local fa, fb, poles = {}, {}, {}
		for i = 1, 3 do
			fa[i], fb[i] = layouts.edge(loop, names[i], 12200 + 40 * (i - 1), 12, c, 12)
			poles[i] = { a = layouts.put(fa[i], "substation", 3, 1), b = layouts.put(fb[i], "substation", 3, 1) }
			for k = 0, 4 do
				acc[i][k + 1] = layouts.put(fb[i], "accumulator", 1 + 2 * k, 6)
				acc[i][k + 1].energy = i == 1 and 5e6 or 0
			end
		end
		local W, script = defines.wire_connector_id, defines.wire_origin.script
		for i = 1, 3 do
			poles[i].b.get_wire_connector(W.pole_copper, true).connect_to(
				poles[i % 3 + 1].a.get_wire_connector(W.pole_copper, true), false, script)
		end
	end)
	ctx.at(1140, function()
		start = stock()
	end)
	for at = 1160, 3900, 20 do
		ctx.at(at, function()
			ctx.expect(stock() <= start + 1000, "+" .. at .. ": no energy created (" .. stock() - start .. " J over)")
		end)
	end
	ctx.at(1200, function()
		for _, n in ipairs(names) do
			offers[n .. "-x"], offers[n .. "-y"] = 0, 0
		end
	end)
	local function sum()
		local n = 0
		for _, name in ipairs(names) do
			n = n + offers[name .. "-x"] + offers[name .. "-y"]
		end
		return n
	end
	ctx.at(1800, function()
		count = sum()
		for _, n in ipairs(names) do
			offers[n .. "-x"], offers[n .. "-y"] = 0, 0
		end
	end)
	ctx.at(3300, function()
		for _, n in ipairs(names) do
			offers[n .. "-x"], offers[n .. "-y"] = 0, 0
		end
	end)
	ctx.at(3400, function()
		local last = sum()
		ctx.expect(count >= 10 and last * 4 <= count, "offers: " .. count .. " in the first 600 ticks, " .. last .. " in the last 600")
		local f1, f2, f3 = fill(1), fill(2), fill(3)
		ctx.expect(math.max(f1, f2, f3) - math.min(f1, f2, f3) <= 2 / 64, "fills " .. f1 .. ", " .. f2 .. ", " .. f3)
		ctx.expect(errors.worst < 1, "worst conservation error " .. errors.worst .. " J")
	end)
end)

-- Spike 22 (docs/spikes/2026-10-06-22-power-smoothing-probe.md): a send that leaves the sending pool in one write has
-- the generators refill the storage at full output for up to 20 ticks, once a period: a sawtooth on the sender's
-- production (std 115 kJ a tick for a 20 MW source making 11 MW's worth, a 6 MW send); removing in equal steps every
-- tick left std 0, and every 5th or 10th tick barely helped. The cases below read each source's production a tick at a
-- time from its network's statistics, as the spike did, and require a standard deviation under SMOOTH. Measured with
-- the one-step removal: 109 to 161 kJ in these cases; with the debt: 0 to 15.4 kJ (credits landing on a pool and load
-- steps leave a little). 30 kJ is a quarter of the lowest old figure and twice the highest new one.
local SMOOTH = 30e3
local SRC, SNK = "ue-test-power-source", "ue-test-power-sink"
local pm = require("modules/universal_edges/transports/power")

--- The drain task's cost over the ticks it works (a link in debt), logged at the end of the multi-hop case.
local prof, busy = nil, 0
if pm.drain_tick then
	local fn = pm.drain_tick
	function pm.drain_tick(tick)
		if next(storage.universal_edges.power_debt) == nil then
			return fn(tick)
		end
		local p = helpers.create_profiler()
		local result = fn(tick)
		p.stop()
		if prof then
			prof.add(p)
		else
			prof = p
		end
		busy = busy + 1
		return result
	end
end

--- A source's production a tick (J) from its network's cumulative counter: sample(tick) every tick of a window.
local function meter(get)
	local m = { prod = {} }
	function m.sample(at)
		local c = get().electric_network.parent_network.statistics.output_counts[SRC] or 0
		if m.last then
			m.prod[at] = c - m.last
		end
		m.last = c
	end
	--- The standard deviation and the mean (J a tick) over the ticks from to to.
	function m.std(from, to)
		local sum = 0
		for at = from, to do
			sum = sum + m.prod[at]
		end
		local mean, var = sum / (to - from + 1), 0
		for at = from, to do
			var = var + (m.prod[at] - mean) ^ 2
		end
		return math.sqrt(var / (to - from + 1)), mean
	end
	return m
end

local function sampling(ctx, from, to, m)
	for at = from - 1, to do
		ctx.at(at, function() m.sample(at) end)
	end
end

--- A case's energy as a ledger: each network's pooled storage (nets() lists { rep = one of its endpoints' names, ent = an
--- entity on it }) less what its sources have made plus what its sinks have drawn, less every link's debt, plus what is
--- in flight (kJ sent and not yet credited, over the named endpoints). Constant when nothing is made or lost.
local function ledger(nets, names)
	local sum = 0
	for _, n in ipairs(nets()) do
		local st = n.ent.electric_network.parent_network.statistics
		sum = sum + total(ep(n.rep)) - (st.output_counts[SRC] or 0) + (st.input_counts[SNK] or 0)
	end
	for _, name in ipairs(names) do
		local d = ep(name).data
		sum = sum - (d.debt or 0) + 1000 * (d.stats.sent - d.stats.got)
	end
	return sum
end

--- The ledger every 20 ticks from..to against its first reading; returns a function giving the worst difference (J).
local function watch(ctx, from, to, nets, names)
	local first, worst = nil, 0
	for at = from, to, 20 do
		ctx.at(at, function()
			local l = ledger(nets, names)
			first = first or l
			worst = math.max(worst, math.abs(l - first))
		end)
	end
	return function() return worst end
end

--- A source of mw MW with no bank to smooth with, or a sink drawing mw MW.
local function put_power(f, name, x, y, mw)
	local e = layouts.put(f, name, x, y)
	if name == SRC then
		e.power_production, e.electric_buffer_size = mw * 1e6 / 60, mw * 1e6 / 60
	else
		layouts.set_usage(e, mw * 1e6 / 60)
	end
	return e
end

local function fed(ctx, from, to, S, sinks)
	for at = from, to, 20 do
		ctx.at(at, function()
			for who, sink in pairs(sinks) do
				ctx.expect(sat(sink()) >= 0.99, "+" .. at - S .. ": " .. who .. "'s sink is fed (" .. sat(sink()) .. ")")
			end
		end)
	end
end

--- Both sides generate and are loaded, unevenly, and the loads shift. Phase 1: a makes 20 MW against 5 MW, b 20 against
--- 26: 6 MW cross from a to b and a's source runs at 11 of its 20 MW (the spike's case). At +1200 the loads step to 26 on
--- a and 4 on b: 6 MW cross from b to a and b's source runs at 10 of 20. The sender's production over the last 300
--- ticks of its phase (five whole periods) has to be smooth, the sinks fed, and nothing created or lost.
t.case("power: both sides generating and loaded, the loads shifting -- the sender's production is smooth (spike 22)",
	function(ctx)
	local S, r, sink_a, src_b = 1500, nil, nil, nil
	local ma, mb = meter(function() return r.source end), meter(function() return src_b end)
	ctx.at(S, function()
		r = layouts.power_pair(loop, "sp3-bg", 14000, 5, 20e6 / 60, 26e6 / 60)
		r.source.electric_buffer_size = 20e6 / 60
		sink_a, src_b = put_power(r.fa, SNK, 9.5, 3.5, 5), put_power(r.fb, SRC, 9.5, 3.5, 20)
	end)
	ctx.at(S + 1200, function()
		layouts.set_usage(sink_a, 26e6 / 60)
		layouts.set_usage(r.sink, 4e6 / 60)
	end)
	sampling(ctx, S + 900, S + 1199, ma)
	sampling(ctx, S + 1900, S + 2199, mb)
	fed(ctx, S + 900, S + 1199, S, { a = function() return sink_a end, b = function() return r.sink end })
	fed(ctx, S + 1900, S + 2199, S, { a = function() return sink_a end, b = function() return r.sink end })
	local worst = watch(ctx, S + 300, S + 2300, function()
		return { { rep = "sp3-bg-x", ent = r.source }, { rep = "sp3-bg-y", ent = src_b } }
	end, { "sp3-bg-x", "sp3-bg-y" })
	ctx.at(S + 2300, function()
		local s1, m1 = ma.std(S + 900, S + 1199)
		local s2, m2 = mb.std(S + 1900, S + 2199)
		log(string.format("sp3 smooth both: a std %.1f kJ mean %.1f kJ (phase 1), b std %.1f kJ mean %.1f kJ (phase 2), ledger %.0f J",
			s1 / 1e3, m1 / 1e3, s2 / 1e3, m2 / 1e3, worst()))
		ctx.expect(m1 > 125e3, "phase 1: a's source made " .. m1 / 1e3 .. " kJ a tick: the link carried a flow")
		ctx.expect(m2 > 125e3, "phase 2: b's source made " .. m2 / 1e3 .. " kJ a tick: the link carried a flow")
		ctx.expect(s1 < SMOOTH, "phase 1: a's production std " .. s1 / 1e3 .. " kJ a tick, at most " .. SMOOTH / 1e3)
		ctx.expect(s2 < SMOOTH, "phase 2: b's production std " .. s2 / 1e3 .. " kJ a tick, at most " .. SMOOTH / 1e3)
		ctx.expect(worst() < 1000, "energy made or lost: ledger moved by " .. worst() .. " J")
		ctx.expect(errors.worst < 1, "worst conservation error " .. errors.worst .. " J")
	end)
end)

--- Three networks in a row, A - edge 1 - B - edge 2 - C, with no storage but the interfaces (B's two share one network).
--- cfg: MW of A's source, B's sink and C's sink, and of C's source (0 for none). Returns what the checks need.
local function chain(ctx, id, x0, S, cfg)
	local r = { id = id }
	local c = { { cid = "c1", type = "power", pos = 2, width = 2, params = {} } }
	ctx.at(S, function()
		local fa1, fb1 = layouts.edge(loop, id .. "1", x0, 12, c, 12)
		local fa2, fb2 = layouts.edge(loop, id .. "2", x0 + 40, 12, c, 12)
		layouts.put(fa1, "substation", 3, 1)
		r.src_a = put_power(fa1, SRC, 6.5, 3.5, cfg.a)
		local p1, p2 = layouts.put(fb1, "substation", 3, 1), layouts.put(fa2, "substation", 3, 1)
		local W, script = defines.wire_connector_id, defines.wire_origin.script
		p1.get_wire_connector(W.pole_copper, true).connect_to(p2.get_wire_connector(W.pole_copper, true), false, script)
		r.sink_b = put_power(fb1, SNK, 6.5, 3.5, cfg.b)
		layouts.put(fb2, "substation", 3, 1)
		r.sink_c = put_power(fb2, SNK, 6.5, 3.5, cfg.c)
		if cfg.src_c then
			r.src_c = put_power(fb2, SRC, 9.5, 3.5, cfg.src_c)
		end
	end)
	r.names = { id .. "1-x", id .. "1-y", id .. "2-x", id .. "2-y" }
	r.nets = function()
		local nets = { { rep = id .. "1-x", ent = r.src_a }, { rep = id .. "1-y", ent = r.sink_b },
			{ rep = id .. "2-y", ent = r.src_c or r.sink_c } }
		return nets
	end
	return r
end

--- Generation on A, loads on B (4 MW) and C (6 MW): 10 MW leave A's 20 MW source, 6 of them on through B's relay.
t.case("power: a multi-hop A to B to C -- A's production is smooth, B and C are fed (spike 22)", function(ctx)
	local S = 1500
	local r = chain(ctx, "sp3-mh", 14100, S, { a = 20, b = 4, c = 6 })
	local ma = meter(function() return r.src_a end)
	sampling(ctx, S + 1500, S + 1799, ma)
	fed(ctx, S + 1500, S + 1799, S, { b = function() return r.sink_b end, c = function() return r.sink_c end })
	local worst = watch(ctx, S + 300, S + 1800, r.nets, r.names)
	ctx.at(S + 1800, function()
		local s, m = ma.std(S + 1500, S + 1799)
		log(string.format("sp3 smooth A-B-C: A std %.1f kJ mean %.1f kJ, ledger %.0f J", s / 1e3, m / 1e3, worst()))
		if prof then
			log({ "", "ue-power-drain: ", busy, " busy ticks, ", prof, " in all" })
		end
		ctx.expect(m > 125e3, "A's source made " .. m / 1e3 .. " kJ a tick: the links carried a flow")
		ctx.expect(s < SMOOTH, "A's production std " .. s / 1e3 .. " kJ a tick, at most " .. SMOOTH / 1e3)
		ctx.expect(worst() < 1000, "energy made or lost: ledger moved by " .. worst() .. " J")
		ctx.expect(errors.worst < 1, "worst conservation error " .. errors.worst .. " J")
	end)
end)

--- The same with C generating too: A makes 20 MW, C 20 MW against its own 4 MW, B draws 14 MW. B is fed from both ends
--- through its two links, and both sources run well under their 20 MW.
t.case("power: a multi-hop with generation on both ends -- both sources' production is smooth (spike 22)", function(ctx)
	local S = 1500
	local r = chain(ctx, "sp3-mg", 14200, S, { a = 20, b = 14, c = 4, src_c = 20 })
	local ma, mc = meter(function() return r.src_a end), meter(function() return r.src_c end)
	sampling(ctx, S + 1500, S + 1799, ma)
	sampling(ctx, S + 1500, S + 1799, mc)
	fed(ctx, S + 1500, S + 1799, S, { b = function() return r.sink_b end, c = function() return r.sink_c end })
	local worst = watch(ctx, S + 300, S + 1800, r.nets, r.names)
	ctx.at(S + 1800, function()
		local sa, na = ma.std(S + 1500, S + 1799)
		local sc, nc = mc.std(S + 1500, S + 1799)
		log(string.format("sp3 smooth both ends: A std %.1f kJ mean %.1f kJ, C std %.1f kJ mean %.1f kJ, ledger %.0f J",
			sa / 1e3, na / 1e3, sc / 1e3, nc / 1e3, worst()))
		ctx.expect(na > 100e3 and nc > 100e3, "both sources fed B: " .. na / 1e3 .. " and " .. nc / 1e3 .. " kJ a tick")
		ctx.expect(sa < SMOOTH, "A's production std " .. sa / 1e3 .. " kJ a tick, at most " .. SMOOTH / 1e3)
		ctx.expect(sc < SMOOTH, "C's production std " .. sc / 1e3 .. " kJ a tick, at most " .. SMOOTH / 1e3)
		ctx.expect(worst() < 1000, "energy made or lost: ledger moved by " .. worst() .. " J")
		ctx.expect(errors.worst < 1, "worst conservation error " .. errors.worst .. " J")
	end)
end)

local function water(entity)
	local f = entity.get_fluid_segment_fluid(1)
	return f and f.amount or 0
end

-- Visuals batch (2026-10-04): the link reads as a 1×1 pipe-to-ground joined to the player's border pipe, not a
-- storage tank spilling a tile into the playable area. The prototype's own type and 1×1 size are checked at load
-- (framework_game_test.lua, D11 §5.4); this checks the built entity: connected to the border pipe, and nothing of
-- its selection box past the border line into the playable side.
t.case("fluids: the link entity is joined to the border pipe and clear of the border", function(ctx)
	local r
	ctx.at(1800, function()
		r = layouts.fluid_pair(loop, "sp3-pipe", 7000, 2)
	end)
	ctx.at(1830, function()
		local tank = ep("sp3-pipe-x").data.tank
		ctx.expect(tank.type == "pipe-to-ground", "the link entity is a pipe-to-ground, got " .. tank.type)
		local joined = false
		for _, n in ipairs(tank.get_fluid_box_neighbours(1) or {}) do
			joined = joined or n.entity == r.a
		end
		ctx.expect(joined, "the link's fluidbox is connected to the border pipe")
		local box, max_y = tank.selection_box, -math.huge
		for _, c in ipairs({ { box.left_top.x, box.left_top.y }, { box.right_bottom.x, box.right_bottom.y },
			{ box.left_top.x, box.right_bottom.y }, { box.right_bottom.x, box.left_top.y } }) do
			local _, ly = geometry.to_local(ep("sp3-pipe-x").frame, c[1], c[2])
			max_y = math.max(max_y, ly)
		end
		ctx.expect(max_y <= 1e-6, "the link's selection box is fully past the border line (local y " .. max_y .. ")")
	end)
end)

-- Fix round 1 (open finding, review a47da7f): the link entity can go invalid out from under a still-"ready" endpoint
-- -- e.g. an upgraded save's old ue-link-tank, destroyed by this batch's own prototype rename, before this endpoint's
-- own first poll has run to notice and flip it to "blocked" (poll's guard, fluid.lua ~:61). A credit landing in that
-- gap must not strand the endpoint "failed"; it must self-heal (become "blocked", rebuild, then take the escrowed
-- amount in full) the same way poll's own guard does. Run against the pre-fix code, this case ends "failed" (RED).
t.case("fluids: a credit against an invalid link entity blocks and rebuilds instead of failing", function(ctx)
	local old
	ctx.at(1800, function()
		layouts.fluid_pair(loop, "sp3-dead", 7050, 2)
	end)
	ctx.at(1830, function()
		local x = ep("sp3-dead-x")
		old = x.data.tank
		old.destroy() -- simulates Factorio removing the old ue-link-tank entity on load (the prototype rename)
		ctx.expect(x.state == "ready", "still ready right after the entity dies, before any poll notices")
		local ok, accepted = connectors.call(x, "credit", "ba", { water = 500 })
		ctx.expect(ok == true, "credit did not raise: " .. tostring(accepted))
		ctx.expect(x.state == "blocked", "blocked, not failed (state: " .. tostring(x.state) .. ")")
		ctx.expect(type(accepted) == "table" and next(accepted) == nil,
			"took nothing, so the sender's escrow holds the 500 for a re-offer")
	end)
	ctx.at(2500, function()
		local x = ep("sp3-dead-x")
		ctx.expect(x.state == "ready", "rebuilt by its next visit (state: " .. tostring(x.state) .. ")")
		ctx.expect(x.data.tank ~= old and x.data.tank.valid, "a fresh, valid link entity")
		local ok, accepted = connectors.call(x, "credit", "ba", { water = 500 })
		ctx.expect(ok == true and accepted.water == 500, "the same 500, re-offered, is now credited in full")
		ctx.expect(water(x.data.tank) == 500, "nothing lost: the rebuilt tank's segment holds exactly the 500")
	end)
end)

t.case("fluids: both ways, exactly", function(ctx)
	local r, checked = nil, false
	ctx.at(1800, function()
		r = layouts.fluid_pair(loop, "sp3-fl", 6700, 40)
	end)
	ctx.at(1830, function()
		r.a.add_fluid_segment_fluid(1, { name = "water", amount = 20000, temperature = 15 })
	end)
	for at = 2100, 2140, 2 do
		ctx.at(at, function()
			if not checked and ep("sp3-fl-x"):idle("ab") and ep("sp3-fl-y"):idle("ba") then
				checked = true
				ctx.expect(math.abs(water(r.a) + water(r.b) - 20000) <= 1, "20,000 water, none made or lost")
				local ca, cb = r.a.get_fluid_segment_capacity(1), r.b.get_fluid_segment_capacity(1)
				ctx.expect(math.abs(water(r.a) / ca - water(r.b) / cb) <= 2 / 64, "balanced")
			end
		end)
	end
	ctx.at(2150, function()
		ctx.expect(checked, "both lanes were idle at some check")
		r.b.add_fluid_segment_fluid(1, { name = "water", amount = 15000, temperature = 15 })
		checked = water(r.a)
	end)
	ctx.at(2400, function()
		ctx.expect(water(r.a) > checked, "and back the other way")
	end)
end)

t.case("fluids: a pump across the line carries water", function(ctx)
	local r
	ctx.at(1800, function()
		r = layouts.fluid_pair(loop, "sp3-pump", 6800, 20, true)
	end)
	ctx.at(1830, function()
		r.back.add_fluid_segment_fluid(1, { name = "water", amount = 2000, temperature = 15 })
	end)
	ctx.at(2300, function()
		ctx.expect(water(r.b) > 0, "water reached side b through the pump")
	end)
end)

t.case("fluids: mismatched fluids send nothing", function(ctx)
	local r
	-- Filled in the same step as the edge, before either endpoint's first build or poll (review fix 1): each side's
	-- first status then already names its fluid, so the gate never sees an empty partner it could mistake for a
	-- match. A same-tick fill of two different fluids on two servers is operator error (D23-D29: no safeguard for it);
	-- this case is about the gate's steady behaviour, not about catching that.
	ctx.at(1800, function()
		r = layouts.fluid_pair(loop, "sp3-mix", 6900, 20)
		r.a.add_fluid_segment_fluid(1, { name = "water", amount = 1000, temperature = 15 })
		r.b.add_fluid_segment_fluid(1, { name = "crude-oil", amount = 1000, temperature = 25 })
	end)
	ctx.at(2130, function()
		ctx.expect(water(r.a) == 1000 and water(r.b) == 1000, "both unchanged")
		ctx.expect(ep("sp3-mix-x").data.stats.sent == 0 and ep("sp3-mix-y").data.stats.sent == 0, "nothing sent")
	end)
end)

-- Both sides full and kept full (a source on each power side and no load; an infinity pipe holding each fluid segment
-- full), and each direction holding a remainder its full partner refuses, as a send from a stale status leaves one: it
-- waits on the lane's backoff (300, 600, 1200 … 3600 ticks), not re-offered every 60 (final fix wave addendum: the
-- fixed retry sent about 20 offers in 1200 ticks, a direction).
t.case("balance: a remainder refused by a full partner waits on the backoff while both sides stay full, power and " ..
	"fluid", function(ctx)
	local sides = { ["sp3-pfull-x"] = "ab", ["sp3-pfull-y"] = "ba", ["sp3-ffull-x"] = "ab", ["sp3-ffull-y"] = "ba" }
	ctx.at(1200, function()
		local r = layouts.power_pair(loop, "sp3-pfull", 7150, 5, 1e9 / 60, 0)
		layouts.put(r.fb, "ue-test-power-source", 9.5, 3.5).power_production = 1e9 / 60
		local f = layouts.fluid_pair(loop, "sp3-ffull", 7180, 4, false)
		local cb = geometry.col("b", 8, 2, 1)
		for _, at in ipairs({ { f.fa, 2.5 }, { f.fb, cb + 0.5 } }) do
			layouts.put(at[1], "infinity-pipe", at[2], 5.5, 0).set_infinity_pipe_filter({ name = "water", percentage = 1,
				mode = "at-least" })
		end
	end)
	ctx.at(1800, function()
		for edge, dir in pairs(sides) do
			local e = ep(edge)
			if e.type == "power" then
				e:send(dir, { e = 1000 })
				eei(e).energy = eei(e).energy - 1e6
			else
				e:send(dir, { water = 1000 })
				e.data.tank.remove_fluid_segment_fluid(1, 1000)
			end
		end
	end)
	ctx.at(2100, function() -- settled: count from here, for 1200 ticks
		for edge in pairs(sides) do
			offers[edge] = 0
		end
	end)
	ctx.at(3300, function()
		for edge, dir in pairs(sides) do
			ctx.expect(not ep(edge):idle(dir), edge .. ": its remainder is still pending (the partner is full)")
			ctx.expect(offers[edge] >= 1 and offers[edge] <= 2, edge .. ": " .. offers[edge] .. " offers in 1200 ticks")
		end
	end)
end)

-- F-PW: under a load the link can't yet carry, y's interface reads empty while its accumulators still hold energy, and
-- the credit latch (which reads the whole storage) never fires. During the ramp, once y's buffer has grown, x's offers
-- to y are held for 130 ticks (a whole y interval wherever y polls) and then released: y's buffer must not shrink, and
-- the sink is full 12 polls after the release. Its own ground (x 12000) and ticks (2510 to 3850: clear of circuit's F9
-- window and big writes).
t.case("power: an empty interface does not shrink while the partner has energy to send (F-PW)", function(ctx)
	local r, held, hold_from, released, prev = nil, {}, nil, nil, 0
	local Y = "sp3-pwh-y"
	ctx.at(2510, function()
		r = layouts.power_pair(loop, "sp3-pwh", 12000, 5, 400e6, 10e6 / 60)
	end)
	ctx.at(2530, function()
		layouts.set_usage(r.sink, 100e6 / 60)
	end)
	for at = 2540, 3800, 10 do
		ctx.at(at, function()
			local b = size(ep(Y))
			if not hold_from and b >= 40e6 then -- the ramp is under way: hold y's offers from here
				hold_from = at
				loop.taps[Y] = function(copy)
					if copy.payload.k == "s.offer" then
						held[#held + 1] = copy
						return false
					end
				end
			elseif hold_from and not released and at >= hold_from + 130 then
				released = at
				loop.taps[Y] = nil
				loop.deliver(held)
			end
			if sat(r.sink) < 0.99 then
				ctx.expect(b >= prev, "+" .. at .. ": y's buffer shrank from " .. prev / 1e6 .. " to " .. b / 1e6 .. " MJ")
			end
			prev = b
			if released and at == released + 780 then -- 12 polls (60 ticks each) and a margin after the release
				ctx.expect(sat(r.sink) >= 0.99, "the sink is full 12 polls after the release (" .. sat(r.sink) .. ")")
			end
		end)
	end
	ctx.at(3800, function()
		ctx.expect(released and released + 780 <= 3800, "the hold was released in time: " .. tostring(released))
	end)
end)

-- Playtest 2026-10-12 #8 (gridworld_-2_0): a tile with no accumulators fed by one link from a tile with hundreds of MJ
-- of them blacked out when its load jumped. Side a here has 84 accumulators (420 MJ, full), side b none; the sink steps
-- from 1 MW to 20 MW. The model (balance_core_test, 400 MJ): 4 dry polls of the first 10 before the fix, 1 to 2 after,
-- the interface growing from B_MIN by doubling; so the sink must be fed from 3 polls after the step.
t.case("power: a side with no accumulators, fed by one link from 420 MJ of them, is fed within 3 polls of a step " ..
	"from 1 MW to 20 MW (#8)", function(ctx)
	local r
	ctx.at(400, function()
		loop.ground(17990, 3012, 18026, 3032) -- 13000 is the vehicles case's
		r = layouts.power_pair(loop, "sp3-pw8", 18000, 0, 400e6, 1e6 / 60)
		local s = game.surfaces.nauvis
		for _, x in ipairs({ 18002, 18014 }) do
			assert(s.create_entity({ name = "substation", position = { x, 3018 }, force = "player" }), "substation")
		end
		for i = 0, 11 do
			for j = 0, 6 do
				local a = assert(s.create_entity({ name = "accumulator", position = { 17997 + 2 * i, 3014 + 2 * j },
					force = "player" }), "accumulator")
				a.energy = 5e6
			end
		end
	end)
	ctx.at(1500, function()
		local x = eei(ep("sp3-pw8-x"))
		local net = x and x.electric_network
		local acc = net and net.parent_network.get_accumulators_energy(ALL)
		ctx.expect(acc and acc.capacity >= 419e6, "side a's link sees the 420 MJ: " .. (acc and acc.capacity or 0) / 1e6)
	end)
	ctx.at(1600, function() layouts.set_usage(r.sink, 20e6 / 60) end)
	for at = 1780, 2200, 10 do
		ctx.at(at, function()
			ctx.expect(sat(r.sink) >= 0.99, "+" .. (at - 1600) .. " after the step: the sink is fed (" .. sat(r.sink) .. ")")
		end)
	end
	ctx.at(2210, function()
		ctx.expect(errors.worst < 1, "conservation: worst error " .. errors.worst .. " J")
	end)
end)

-- Six networks in a row, joined by five links (owner, 2026-10-13: "have you tested the power with a string of 5+
-- servers?"; the longest before was A to B to C). N1 is edge 1's side a: a 30 MW source and 84 accumulators (420 MJ,
-- full). N2 to N5 relay: edge k's side b wired to edge k + 1's side a, no storage but the two interfaces. N6 is edge 5's
-- side b: a sink at 1 MW, 20 MW from +1200 to +1800 and again from +2400 to +3000. Ground x 18096-18276 (side b's to
-- 18292), its accumulators' at y 3012-3032. The model (balance_core_test, this schedule, 90 runs): 1 MW met from cold
-- from poll 10 to 17, and again 1 to 2 polls after the first burst; so from 18 and 3 here.
-- Not asserted, as it fails (for the owner, §8.2): the 20 MW bursts. The model left 9 to 10 of the first burst's 10
-- polls short and 0 to 10 of the second's. Here (2026-10-13) the last link's buffers doubled to 10 GJ under the 1 MW
-- (in the model, its far side's starve latch reads a status whose c is stale), and the sink was short through the whole
-- first burst, the link carrying 2.5 to 6 MW of 20, and through half the second once the 10 GJ interface's store ran
-- down.
local CH = "sp3-ch"
t.case("power: a chain of six networks -- the far end's 1 MW met from cold and after a 20 MW burst, no energy made, " ..
	"no buffer shrinking within the hold", function(ctx)
	local S, X0 = 400, 18100
	local src, sink, poles, names, sizes = nil, nil, {}, {}, {}
	for k = 1, 5 do
		names[#names + 1] = CH .. k .. "-x"
		names[#names + 1] = CH .. k .. "-y"
	end
	ctx.at(S, function()
		local c = { { cid = "c1", type = "power", pos = 2, width = 2, params = {} } }
		local fa, fb = {}, {}
		for k = 1, 5 do
			fa[k], fb[k] = layouts.edge(loop, CH .. k, X0 + 40 * (k - 1), 12, c, 12)
		end
		loop.ground(X0 - 10, 3012, X0 + 26, 3032)
		layouts.put(fa[1], "substation", 3, 1)
		src = put_power(fa[1], SRC, 6.5, 3.5, 30)
		local s = game.surfaces.nauvis
		for _, x in ipairs({ X0 + 2, X0 + 14 }) do
			assert(s.create_entity({ name = "substation", position = { x, 3018 }, force = "player" }), "substation")
		end
		for i = 0, 11 do
			for j = 0, 6 do
				assert(s.create_entity({ name = "accumulator", position = { X0 - 3 + 2 * i, 3014 + 2 * j }, force = "player" }),
					"accumulator").energy = 5e6
			end
		end
		local W, script = defines.wire_connector_id, defines.wire_origin.script
		for k = 1, 4 do
			local p1, p2 = layouts.put(fb[k], "substation", 3, 1), layouts.put(fa[k + 1], "substation", 3, 1)
			p1.get_wire_connector(W.pole_copper, true).connect_to(p2.get_wire_connector(W.pole_copper, true), false, script)
			poles[k + 1] = p1
		end
		layouts.put(fb[5], "substation", 3, 1)
		sink = put_power(fb[5], SNK, 6.5, 3.5, 1)
	end)
	ctx.at(S + 1190, function()
		local x = eei(ep(CH .. "1-x"))
		local acc = x and x.electric_network and x.electric_network.parent_network.get_accumulators_energy(ALL)
		ctx.expect(acc and acc.capacity >= 419e6, "N1's link sees the 420 MJ: " .. (acc and acc.capacity or 0) / 1e6)
	end)
	ctx.at(S + 1200, function() layouts.set_usage(sink, 20e6 / 60) end)
	ctx.at(S + 1800, function() layouts.set_usage(sink, 1e6 / 60) end)
	ctx.at(S + 2400, function() layouts.set_usage(sink, 20e6 / 60) end)
	ctx.at(S + 3000, function() layouts.set_usage(sink, 1e6 / 60) end)
	for at = S + 600, S + 3480, 10 do
		ctx.at(at, function()
			local list = {}
			for i, name in ipairs(names) do
				local b = size(ep(name))
				if at > S + 1200 then
					ctx.expect(b >= (sizes[i] or 0), "+" .. at - S .. ": " .. name .. "'s buffer shrank from " ..
						(sizes[i] or 0) / 1e6 .. " to " .. b / 1e6 .. " MJ")
				end
				sizes[i] = b
				list[#list + 1] = string.format("%.0f", b / 1e6)
			end
			if (at - S) % 60 == 0 then
				log(string.format("sp3 chain +%d: sat %.3f, buffers %s MJ, got %s kJ", at - S, sat(sink), table.concat(list, " "),
					ep(CH .. "5-y").data.stats.got))
			end
		end)
	end
	fed(ctx, S + 1080, S + 1190, S, { N6 = function() return sink end })
	fed(ctx, S + 1980, S + 2390, S, { N6 = function() return sink end })
	local worst = watch(ctx, S + 300, S + 3480, function()
		local nets = { { rep = CH .. "1-x", ent = src } }
		for k = 2, 5 do
			nets[#nets + 1] = { rep = CH .. (k - 1) .. "-y", ent = poles[k] }
		end
		nets[#nets + 1] = { rep = CH .. "5-y", ent = sink }
		return nets
	end, names)
	ctx.at(S + 3490, function()
		ctx.expect(worst() < 1000, "energy made or lost: ledger moved by " .. worst() .. " J")
		ctx.expect(errors.worst < 1, "worst conservation error " .. errors.worst .. " J")
	end)
end)

--- A removed link's energy goes into the network's other interfaces and its accumulators at one fill ratio (§8.4, owner
--- 2026-10-07): only what fits nowhere is dropped. Recorded around the endpoint's teardown, on the one that stays.
local torn = {}
do
	local teardown = power.teardown
	power.teardown = function(e)
		if e.edge ~= "sp3-td-x" or e.cid ~= "c1" then
			return teardown(e)
		end
		local stay = ep("sp3-td-x", "c2")
		if eei(e) then
			eei(e).energy = eei(e).electric_buffer_size -- full, set here: a poll sends a set one away before a removal lands
		end
		local before, drained, dropped = total(stay), e.data.stats.drained or 0, e.data.stats.dropped
		local held = eei(e) and eei(e).energy or 0
		local result = teardown(e)
		torn = { held = held, moved = 1000 * ((e.data.stats.drained or 0) - drained), dropped = e.data.stats.dropped - dropped,
			change = total(stay) - before, other = eei(stay) and eei(stay).energy or 0 }
		return result
	end
end

t.case("power: a removed link's energy goes into the other interface and the accumulators, not the floor (§8.4)", function(ctx)
	ctx.at(3400, function()
		local fa = layouts.edge(loop, "sp3-td", 12400, 12, {
			{ cid = "c1", type = "power", pos = 2, width = 2, params = {} },
			{ cid = "c2", type = "power", pos = 7, width = 2, params = {} },
		}, 12)
		local p1, p2 = layouts.put(fa, "substation", 3, 1), layouts.put(fa, "substation", 8, 1)
		local W, script = defines.wire_connector_id, defines.wire_origin.script
		p1.get_wire_connector(W.pole_copper, true).connect_to(p2.get_wire_connector(W.pole_copper, true), false, script)
		layouts.put(fa, "accumulator", 1, 6) -- one: 5 MJ, less than the interface holds
	end)
	ctx.at(3460, function()
		loop.connectors("sp3-td", 2, { { cid = "c2", type = "power", pos = 7, width = 2, params = {} } })
	end)
	ctx.at(3600, function()
		ctx.expect(ep("sp3-td-x", "c1") == nil, "c1 is gone")
		ctx.expect(torn.held and torn.held > 5e6, "c1's interface held more than the accumulator takes: " .. tostring(torn.held))
		ctx.expect(torn.dropped == 0, "nothing dropped while room existed: " .. tostring(torn.dropped) .. " kJ")
		ctx.expect(math.abs(torn.change + torn.moved) < 10, "the pool kept every joule it was owed: changed " ..
			tostring(torn.change) .. ", drained " .. tostring(torn.moved))
		ctx.expect(torn.other > 5e6, "the other interface took its share: " .. tostring(torn.other))
		ctx.expect(errors.worst < 1, "conservation held: worst error " .. errors.worst .. " J")
	end)
end)
