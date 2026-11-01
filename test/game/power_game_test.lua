-- The power hub's game tests (power hub spec §11.3; plan ruling 12): ground x 26000-28999, cases from tick 500.
local t = require("modules/v2_test/testlib")
local loop = require("modules/v2_test/loopback")
local layouts = require("modules/v2_test/layouts")

local MODE = defines.electric_interface_mode

local connectors = require("modules/universal_edges/edges/connectors")
local geometry = require("modules/universal_edges/edges/geometry_core")
local bridge = require("modules/universal_edges/runtime/bridge")

local function ep(edge, cid)
	local side = storage.universal_edges.edges[edge]
	return side and connectors.get(side, cid or "c1")
end

--- An endpoint's interface, nil before its build.
local function eei(e)
	local x = e and e.data.eei
	return x and x.valid and x or nil
end

--- A looped edge with one power connector (column 2, width 2) and a substation on each side, nothing else (the
--- loopback's edges id-x, side a, and id-y, side b). Returns the two local frames.
local function bare(id, x0)
	local fa, fb = layouts.edge(loop, id, x0, 12, { { cid = "c1", type = "power", pos = 2, width = 2, params = {} } }, 12)
	layouts.put(fa, "substation", 3, 1)
	layouts.put(fb, "substation", 3, 1)
	return fa, fb
end

--- The pair's endpoints once both are ready with each other, or nil.
local function pair(id)
	local x, y = ep(id .. "-x"), ep(id .. "-y")
	if x and y and x.state == "ready" and y.state == "ready" and x.partner and x.partner.state == "ready" then
		return x, y
	end
end

local seq = 0
--- ue.power.targets as the instance delivers it: l = { [key] = { n, b, m?, k } }.
local function targets(l)
	seq = seq + 1
	ue_rt.inbox("universal_edges", helpers.table_to_json({ { id = "0000c9f0." .. seq, type = "ue.power.targets",
		payload = { l = l } } }))
end

--- From tick at, the pair's side `from` ("x" or "y") sends n kJ in one poll. Its targets say n until the send shows, then
--- 0; polls are 60 ticks apart, so the next poll sees 0. Buffers are bx and by kJ; no mode (the built state).
local function one_send(ctx, at, id, from, n, bx, by)
	local sender, start
	local function deliver(amount)
		local x, y = pair(id)
		targets({ [x.key] = { n = from == "x" and amount or 0, b = bx, k = 0 },
			[y.key] = { n = from == "y" and amount or 0, b = by, k = 0 } })
	end
	ctx.at(at, function()
		local x, y = pair(id)
		sender = from == "x" and x or y
		start = sender.data.stats.sent
		deliver(n)
	end)
	for k = at + 1, at + 75 do
		ctx.at(k, function()
			if start and sender.data.stats.sent ~= start then
				start = nil
				deliver(0)
			end
		end)
	end
end

--- A source's cumulative production on its network (J): its step between ticks is a tick's output (spike 22's method).
local function counter(source)
	return source.electric_network.parent_network.statistics.output_counts["ue-test-power-source"] or 0
end

-- Every ue.power.report and ue.power trace this save queues, read just before each flush (the loopback's wrapper reads
-- the same queue; the two chain).
-- (Task 8b: a report in parts is put back together, as radar's helper does; parts counts those and holds the largest message's bytes.)
local reports, traces, parts = {}, {}, { reports = 0, max = 0 }
do
	local flush = bridge.flush
	function bridge.flush(tick)
		local s = storage.universal_edges
		local held = {}
		for _, msg in ipairs(s and s.bridge.out.universal_edges or {}) do
			if msg.type == "ue.power.chunk" or msg.type == "ue.power.report" then
				parts.max = math.max(parts.max, #helpers.table_to_json(msg))
			end
			if msg.type == "ue.power.chunk" then
				held[msg.payload.key] = held[msg.payload.key] or {}
				held[msg.payload.key][msg.payload.i] = msg.payload.data
			elseif msg.type == "ue.power.report" then
				local nets = msg.payload.nets
				if msg.payload.chunks then
					parts.reports = parts.reports + 1
					nets = helpers.json_to_table(table.concat(held["power/" .. msg.payload.seq])).nets
				end
				reports[#reports + 1] = { tick = tick, nets = nets }
			elseif msg.type == "trace" and msg.payload.op == "ue.power" then
				traces[#traces + 1] = msg.payload
			end
		end
		flush(tick)
	end
end

--- The ue.power traces of one phase, oldest first.
local function traced(phase)
	local found = {}
	for _, p in ipairs(traces) do
		if p.phase == phase then
			found[#found + 1] = p
		end
	end
	return found
end

--- The reported network holding key in a report from tick from to tick to: the latest, or with first the earliest.
local function reported(key, from, to, first)
	local found
	for _, r in ipairs(reports) do
		if r.tick >= from and r.tick <= to then
			for _, n in ipairs(r.nets) do
				for _, l in ipairs(n.l) do
					if l[1] == key and not (first and found) then
						found = n
					end
				end
			end
		end
	end
	return found
end

-- A 2×2 pole across the line (owner, 2026-11-01): centred on it, it is its own mirror, so one blueprint pastes on both
-- tiles. Each side's interface stands inside that pole's footprint. Side a's pole is there before its interface; side b's
-- interface is there before its pole, which a player must still be able to place over it.
t.case("power: a substation across the line takes the link's interface on its network, on either side, in either " ..
	"order", function(ctx)
	local fa, fb, sa, sb
	ctx.at(500, function()
		fa, fb = layouts.edge(loop, "ph-across", 27800, 12, { { cid = "c1", type = "power", pos = 2, width = 2, params = {} } }, 12)
		sa = layouts.put(fa, "substation", 3, 0)
	end)
	ctx.at(700, function()
		local x, y = pair("ph-across")
		ctx.expect(x ~= nil, "the pair is ready")
		ctx.expect(eei(x) ~= nil and eei(x).electric_network_id == sa.electric_network_id,
			"side a's interface, made under its substation, is on its network")
		local bx, by = geometry.flip(12, 3, 0) -- side b counts its columns from the other end
		local wx, wy = geometry.to_world(fb, bx, by)
		ctx.expect(y ~= nil and eei(y) ~= nil and game.surfaces.nauvis.can_place_entity({ name = "substation",
			position = { wx, wy }, force = "player", build_check_type = defines.build_check_type.manual }),
			"a player can place side b's substation over its interface")
		sb = layouts.put(fb, "substation", bx, by)
	end)
	ctx.at(701, function()
		local _, y = pair("ph-across")
		ctx.expect(y ~= nil and eei(y) ~= nil and eei(y).electric_network_id == sb.electric_network_id,
			"side b's interface is on its substation's network")
	end)
end)

-- §5, spike 45 P1 and P6: a strip of its own at y 3500 (no edge), so no poll touches its interface.
t.case("power hub: ue-link-interface and the test source are dynamic: new ones start in tertiary_input_output, and " ..
	"mode and limit writes act on the next tick (§5)", function(ctx)
	local x, src
	ctx.at(500, function()
		loop.ground(25990, 3490, 26030, 3510)
		local s = game.surfaces.nauvis
		assert(s.create_entity({ name = "substation", position = { 26005, 3500 }, force = "player" }), "substation")
		x = assert(s.create_entity({ name = "ue-link-interface", position = { 26002.5, 3502.5 }, force = "player" }))
		src = assert(s.create_entity({ name = "ue-test-power-source", position = { 26008.5, 3502.5 }, force = "player" }))
		local sink = assert(s.create_entity({ name = "ue-test-power-sink", position = { 26010.5, 3502.5 }, force = "player" }))
		layouts.set_usage(sink, 3e6 / 60)
	end)
	ctx.at(501, function()
		ctx.expect(x.electric_interface_mode == MODE.tertiary_input_output, "a new interface reads " .. x.electric_interface_mode)
		ctx.expect(src.electric_interface_mode == MODE.tertiary_input_output, "so does a new test source")
		src.electric_interface_mode = MODE.secondary_output
		src.power_production, src.electric_buffer_size, src.output_flow_limit = 5e6 / 60, 5e6 / 60, 5e6 / 60
		x.electric_interface_mode, x.output_flow_limit, x.input_flow_limit = MODE.primary_output, 1e6 / 60, 0
		x.energy = 5e6
	end)
	ctx.at(504, function()
		local flow = x.electric_network.parent_network.flow_last_tick
		ctx.expect(x.electric_interface_mode == MODE.primary_output, "the mode write reads back")
		ctx.expect(math.abs(flow.primary_output - 1e6 / 60) < 1, "the interface offers its 1 MW cap: " .. flow.primary_output)
		ctx.expect(math.abs(flow.secondary_output_usage - 0.4) < 0.01, "primary first, then the secondary source covers " ..
			"the other 2 MW of its 5 (plan review B2): " .. flow.secondary_output_usage)
	end)
end)

-- §6.2: the class and cap act in the game. Side a exports: secondary_input capped at 3 MW beside a 10 MW source and no
-- load, so the source makes 3 MW. Side b imports: primary_output capped at 2 MW beside a 10 MW secondary source and a
-- 6 MW sink, so the import gives its whole cap first and the source makes 4 MW (spike 43 D, spike 45 P5).
t.case("power hub: a capped import displaces a generator by its cap; a capped export draws its cap (§6.2)", function(ctx)
	local src_a, src_b, c0, e0
	ctx.at(500, function()
		local fa, fb = bare("ph-cap", 26100)
		src_a, src_b = layouts.source(fa, 6.5, 3.5, 10, "secondary_output"), layouts.source(fb, 6.5, 3.5, 10, "secondary_output")
		layouts.set_usage(layouts.put(fb, "ue-test-power-sink", 9.5, 3.5), 6e6 / 60)
	end)
	ctx.at(700, function()
		local x, y = pair("ph-cap")
		ctx.expect(x ~= nil, "the link is ready at both ends")
		if not x then
			return
		end
		-- two statements, size first: a multiple assignment runs right to left, so energy would be capped by the old buffer
		eei(x).electric_buffer_size = 100e6
		eei(x).energy = 10e6 -- room to draw (it filled while in the built state)
		eei(y).electric_buffer_size = 100e6
		eei(y).energy = 50e6
		targets({ [x.key] = { n = 0, b = 100000, m = "secondary_input", k = 3000 },
			[y.key] = { n = 0, b = 100000, m = "primary_output", k = 2000 } })
	end)
	ctx.at(720, function()
		c0 = { counter(src_a), counter(src_b) }
		e0 = { eei(ep("ph-cap-x")).energy, eei(ep("ph-cap-y")).energy }
	end)
	ctx.at(780, function()
		local a, b = (counter(src_a) - c0[1]) / 60, (counter(src_b) - c0[2]) / 60
		ctx.expect(math.abs(a - 3e6 / 60) < 500, "a's source makes the export's 3 MW: " .. a * 60 / 1e6 .. " MW")
		ctx.expect(math.abs(b - 4e6 / 60) < 500, "b's source makes 4 of the sink's 6 MW: " .. b * 60 / 1e6 .. " MW")
		ctx.expect(math.abs(eei(ep("ph-cap-x")).energy - e0[1] - 3e6) < 3e4, "a's interface took 3 MW for a second")
		ctx.expect(math.abs(e0[2] - eei(ep("ph-cap-y")).energy - 2e6) < 3e4, "b's interface gave 2 MW for a second")
	end)
end)

t.case("power hub: targets with no m, or none for 300 ticks, put the interface in the built state (§6.2, §6.3)", function(ctx)
	ctx.at(500, function() bare("ph-stale", 26200) end)
	ctx.at(700, function()
		local x = pair("ph-stale")
		ctx.expect(x ~= nil, "the link is ready at both ends")
		if not x then
			return
		end
		local i = eei(x)
		targets({ [x.key] = { n = 0, b = 10000, m = "secondary_output", k = 1000 } })
		ctx.expect(i.electric_interface_mode == MODE.secondary_output, "the mode applies at once")
		ctx.expect(math.abs(i.output_flow_limit - 1e6 / 60) < 1e-6 and i.input_flow_limit == 0,
			"the cap on the output side, 0 on the input side")
		targets({ [x.key] = { n = 0, b = 10000, k = 0 } })
		ctx.expect(i.electric_interface_mode == MODE.tertiary_input_output and i.output_flow_limit > 1e10
			and i.input_flow_limit > 1e10, "no m: the built state at once")
		targets({ [x.key] = { n = 0, b = 10000, m = "primary_output", k = 1000 } })
	end)
	ctx.at(950, function()
		ctx.expect(eei(ep("ph-stale-x")).electric_interface_mode == MODE.primary_output, "still fresh 250 ticks on")
	end)
	ctx.at(1100, function()
		local i = eei(ep("ph-stale-x"))
		ctx.expect(i.electric_interface_mode == MODE.tertiary_input_output, "stale past 300 ticks: the next poll built it")
		ctx.expect(i.input_flow_limit > 1e10 and i.output_flow_limit > 1e10, "both limits back at 1 TW")
	end)
end)

-- §6.3: a link sends its target's n once per poll; what its pool lacks it owes, at most its buffer, and the owe is paid
-- from the next credit into its pool (plan review M10). No source or load: only UE moves energy here.
t.case("power hub: a link sends n, owes what its pool lacks, and pays it from the next credit (§6.3)", function(ctx)
	local x, y
	ctx.at(500, function() bare("ph-owe", 26300) end)
	ctx.at(699, function()
		x, y = pair("ph-owe")
		ctx.expect(x ~= nil, "the link is ready at both ends")
		eei(x).energy, eei(y).energy = 5e6, 0
	end)
	one_send(ctx, 700, "ph-owe", "x", 3000, 10000, 20000)
	ctx.at(800, function()
		ctx.expect(x.data.stats.sent == 3000 and y.data.stats.got == 3000, "one poll sent 3,000 kJ, credited: " ..
			x.data.stats.sent .. ", " .. y.data.stats.got)
		ctx.expect(math.abs(eei(x).energy - 2e6) < 1 and x.data.owe == 0, "taken from a's pool at once: " .. eei(x).energy)
	end)
	one_send(ctx, 800, "ph-owe", "x", 8000, 10000, 20000)
	ctx.at(900, function()
		ctx.expect(x.data.stats.sent == 11000, "8,000 more sent: " .. x.data.stats.sent)
		ctx.expect(eei(x).energy < 1 and math.abs(x.data.owe - 6e6) < 1, "the pool's 2 MJ taken, 6 MJ owed: " .. x.data.owe)
	end)
	one_send(ctx, 900, "ph-owe", "y", 7000, 10000, 20000) -- b sends 7 MJ back: a's next energy is a credit
	ctx.at(1050, function()
		ctx.expect(x.data.stats.got == 7000, "a credited 7,000 kJ: " .. x.data.stats.got)
		ctx.expect(x.data.owe == 0 and math.abs(eei(x).energy - 1e6) < 1, "the 6 MJ paid from it: owe " .. x.data.owe ..
			", left " .. eei(x).energy)
		ctx.expect(x.data.stats.sent == 11000, "a sent nothing more")
	end)
end)

-- Plan ruling 26 (model F3): a buffer change rewrites the pool at one fill ratio, so an interface shrunk to its stored
-- energy isn't left full (room 0, drawing nothing) until the pool's next write. Side a: two links on one network, c1 at
-- 40 of 100 MJ given b = 20 MJ (so it shrinks to 40 MJ), c2 empty at 10 MJ: after c1's poll they hold 32 and 8 MJ.
t.case("power hub: a buffer change rewrites the pool at one fill ratio (§6.3 step 3)", function(ctx)
	local seen
	ctx.at(500, function()
		local fa = layouts.edge(loop, "ph-f3", 27400, 12, {
			{ cid = "c1", type = "power", pos = 2, width = 2, params = {} },
			{ cid = "c2", type = "power", pos = 7, width = 2, params = {} },
		}, 12)
		local p1, p2 = layouts.put(fa, "substation", 3, 1), layouts.put(fa, "substation", 8, 1)
		local W, script = defines.wire_connector_id, defines.wire_origin.script
		p1.get_wire_connector(W.pole_copper, true).connect_to(p2.get_wire_connector(W.pole_copper, true), false, script)
	end)
	ctx.at(700, function()
		local c1, c2 = ep("ph-f3-x", "c1"), ep("ph-f3-x", "c2")
		ctx.expect(c1 and c2 and c1.state == "ready" and c2.state == "ready", "both links ready")
		if not (c1 and c2) then
			return
		end
		eei(c1).electric_buffer_size = 100e6 -- size first: a multiple assignment runs right to left, energy would be capped
		eei(c1).energy, eei(c2).energy = 40e6, 0
		targets({ [c1.key] = { n = 0, b = 20000, k = 0 } })
	end)
	-- the first tick c1's buffer has changed: its poll's write (later polls shrink it further, so look only at the first)
	for k = 701, 770 do
		ctx.at(k, function()
			local c1, c2 = ep("ph-f3-x", "c1"), ep("ph-f3-x", "c2")
			if not seen and eei(c1).electric_buffer_size ~= 100e6 then
				seen = { b = eei(c1).electric_buffer_size, e1 = eei(c1).energy, e2 = eei(c2).energy }
			end
		end)
	end
	ctx.at(771, function()
		ctx.expect(seen ~= nil, "c1 polled")
		if seen then
			ctx.expect(seen.b == 40e6, "shrunk to the 40 MJ it held: " .. seen.b)
			ctx.expect(math.abs(seen.e1 - 32e6) < 1 and math.abs(seen.e2 - 8e6) < 1,
				"40 of 50 MJ at one fill ratio: " .. seen.e1 .. ", " .. seen.e2)
		end
	end)
end)

t.case("power hub: the buffer is written to b, never below the stored energy (§6.3 step 3)", function(ctx)
	local x
	ctx.at(500, function() bare("ph-buf", 26400) end)
	ctx.at(700, function()
		x = pair("ph-buf")
		ctx.expect(x ~= nil, "the link is ready at both ends")
		if x then
			targets({ [x.key] = { n = 0, b = 50000, k = 0 } })
		end
	end)
	ctx.at(800, function()
		ctx.expect(eei(x).electric_buffer_size == 50e6, "grown to b: " .. eei(x).electric_buffer_size)
		eei(x).energy = 40e6
		targets({ [x.key] = { n = 0, b = 20000, k = 0 } })
	end)
	ctx.at(900, function()
		ctx.expect(eei(x).electric_buffer_size == 40e6, "shrunk only to the 40 MJ it holds: " .. eei(x).electric_buffer_size)
		ctx.expect(eei(x).energy == 40e6, "nothing destroyed")
	end)
end)

-- §6.2: a remainder the partner refused (its pool full) waits on the lane's backoff (300 ticks or more) until targets
-- find it still pending from the targets before (plan review M1), and then re-offers at the link's next visit.
t.case("power hub: a refused remainder re-offers when the next targets find it still pending (§6.2)", function(ctx)
	local x, y
	ctx.at(500, function() bare("ph-nudge", 26500) end)
	ctx.at(699, function()
		x, y = pair("ph-nudge")
		ctx.expect(x ~= nil, "the link is ready at both ends")
		eei(x).energy, eei(y).energy = 10e6, 10e6 -- b's pool full: it refuses
	end)
	one_send(ctx, 700, "ph-nudge", "x", 5000, 10000, 10000) -- its last targets (n = 0) find the offer pending
	ctx.at(800, function()
		ctx.expect(x.data.stats.sent == 5000 and not x:idle("ab") and y.data.stats.got == 0, "sent and refused: pending")
		eei(y).energy = 0
		targets({ [x.key] = { n = 0, b = 10000, k = 0 }, [y.key] = { n = 0, b = 10000, k = 0 } })
	end)
	ctx.at(900, function()
		ctx.expect(y.data.stats.got == 5000 and x:idle("ab"), "re-offered within 100 ticks of the targets, before the " ..
			"lane's own backoff: got " .. y.data.stats.got)
	end)
end)

-- §6.4: a removed link pays its owe from the pool, then its interface's energy goes into the other link interface and
-- then the accumulator. Side a: two power connectors on one network (two substations wired) and one empty accumulator.
t.case("power hub: teardown pays the owe and moves the energy to the other interface, then the accumulators (§6.4)",
	function(ctx)
	local acc, before
	ctx.at(500, function()
		local fa = layouts.edge(loop, "ph-td", 26600, 12, {
			{ cid = "c1", type = "power", pos = 2, width = 2, params = {} },
			{ cid = "c2", type = "power", pos = 7, width = 2, params = {} },
		}, 12)
		local p1, p2 = layouts.put(fa, "substation", 3, 1), layouts.put(fa, "substation", 8, 1)
		local W, script = defines.wire_connector_id, defines.wire_origin.script
		p1.get_wire_connector(W.pole_copper, true).connect_to(p2.get_wire_connector(W.pole_copper, true), false, script)
		acc = layouts.put(fa, "accumulator", 1, 6)
	end)
	ctx.at(700, function()
		local c1, c2 = ep("ph-td-x", "c1"), ep("ph-td-x", "c2")
		ctx.expect(c1 and c2 and c1.state == "ready" and c2.state == "ready", "both links ready")
		if not (c1 and c2) then
			return
		end
		eei(c1).energy, eei(c2).energy, acc.energy, c1.data.owe = 9e6, 9e6, 0, 3e6
		before = eei(c1).energy + eei(c2).energy + acc.energy -- 18 MJ: 3 owed, c2 has 1 MJ of room, the accumulator 5
		loop.connectors("ph-td", 2, { { cid = "c2", type = "power", pos = 7, width = 2, params = {} } })
	end)
	ctx.at(850, function()
		ctx.expect(ep("ph-td-x", "c1") == nil, "c1 is gone")
		local c2 = ep("ph-td-x", "c2")
		local after = eei(c2).energy + acc.energy
		ctx.expect(math.abs(before - 3e6 - after) < 10, "every joule kept but the 3 MJ owed: " .. before .. " → " .. after)
		ctx.expect(math.abs(eei(c2).energy - 10e6) < 10 and math.abs(acc.energy - 5e6) < 10,
			"c2 filled, the rest in the accumulator: " .. eei(c2).energy .. ", " .. acc.energy)
	end)
end)

-- §6.4, plan review S4 and M10: teardown pays what the pool holds of the owe and leaves the rest owed, logged with the
-- most a refund may cancel; the lane's later refund cancels the owe first, puts the rest into the accumulators, and
-- drops and logs what fits nowhere. Side a: one link holding 1 MJ, owing 3 MJ, and an accumulator 1 MJ short of full.
t.case("power hub: teardown leaves the unpaid owe for the refund to cancel; the refund puts the rest into the " ..
	"accumulators and logs what fits nowhere (§6.4)", function(ctx)
	local acc, held
	ctx.at(500, function()
		local fa = bare("ph-tr", 27100)
		acc = layouts.put(fa, "accumulator", 1, 6)
	end)
	ctx.at(700, function()
		held = pair("ph-tr")
		ctx.expect(held ~= nil, "the link is ready at both ends")
		if not held then
			return
		end
		eei(held).energy, acc.energy, held.data.owe = 1e6, 4e6, 3e6
		loop.connectors("ph-tr", 2, {})
	end)
	ctx.at(850, function()
		ctx.expect(ep("ph-tr-x") == nil, "the link is gone")
		ctx.expect(held.data.owe == 2e6, "1 MJ paid from the pool, 2 MJ left owed: " .. held.data.owe)
		ctx.expect(math.abs(acc.energy - 4e6) < 1, "the emptied interface gave the accumulator nothing")
		local unpaid = traced("debt_unpaid")
		local last = unpaid[#unpaid]
		ctx.expect(last and last.edge == "ph-tr-x" and last.amount == 2000 and last.refundable == 0,
			"debt_unpaid logged with what a refund may cancel: " .. helpers.table_to_json(last or {}))
		connectors.types.power.refund(held, "ab", { e = 3000 }) -- a lane's refund comes after teardown (lanes.lua close)
		ctx.expect(held.data.owe == 0, "the refund cancels the 2 MJ owed first")
		ctx.expect(math.abs(acc.energy - 5e6) < 1, "its other 1 MJ fills the accumulator: " .. acc.energy)
		connectors.types.power.refund(held, "ab", { e = 2000 })
		ctx.expect(held.data.stats.dropped == 2000, "2,000 kJ fit nowhere: dropped")
	end)
	ctx.at(851, function() -- the trace is read at the flush, after the refund's tick
		local dropped = traced("refund_dropped")
		ctx.expect(dropped[#dropped] and dropped[#dropped].amount == 2000, "and logged")
	end)
end)

-- Plan review S3: a side the controller deactivates doesn't poll, so its interface leaves the hub's class and cap at once.
t.case("power hub: a deactivated side's interface goes back to the built state and ignores targets (§10, plan " ..
	"ruling 27)", function(ctx)
	ctx.at(500, function() bare("ph-deact", 27200) end)
	ctx.at(700, function()
		local x = pair("ph-deact")
		ctx.expect(x ~= nil, "the link is ready at both ends")
		if not x then
			return
		end
		targets({ [x.key] = { n = 0, b = 10000, m = "secondary_output", k = 100 } })
		ctx.expect(eei(x).electric_interface_mode == MODE.secondary_output, "the hub's class")
		loop.activation("ph-deact", false)
	end)
	ctx.at(701, function()
		local x = ep("ph-deact-x")
		ctx.expect(eei(x).electric_interface_mode == MODE.tertiary_input_output, "deactivated: the built state")
		targets({ [x.key] = { n = 0, b = 10000, m = "secondary_output", k = 100 } })
	end)
	ctx.at(702, function()
		ctx.expect(eei(ep("ph-deact-x")).electric_interface_mode == MODE.tertiary_input_output,
			"a target while the side is inactive is ignored")
		loop.activation("ph-deact", true)
	end)
end)

t.case("power hub: an endpoint from before the deploy (no owe, D34's fields, a grown buffer) polls and takes targets " ..
	"without failing, and keeps its energy (Review Focus 1)", function(ctx)
	local x
	ctx.at(500, function() bare("ph-old", 26700) end)
	ctx.at(700, function()
		x = pair("ph-old")
		ctx.expect(x ~= nil, "the link is ready at both ends")
		if not x then
			return
		end
		local d = x.data
		d.owe, d.debt, d.debt_until, d.a_last, d.drain, d.stats.drained = nil, 5e6, 0, 1, 0, 3
		eei(x).electric_buffer_size = 2e9 -- size first: a multiple assignment runs right to left, energy would be capped
		eei(x).energy = 1.5e9
	end)
	ctx.at(800, function()
		ctx.expect(x.state == "ready" and x.data.owe == 0, "a poll with no target: still ready, owe 0 (" .. x.state .. ")")
		targets({ [x.key] = { n = 0, b = 10000, m = "secondary_output", k = 100 } })
	end)
	ctx.at(900, function()
		ctx.expect(x.state == "ready", "a poll with a target: still ready")
		ctx.expect(eei(x).electric_buffer_size == 1.5e9 and eei(x).energy == 1.5e9,
			"the buffer shrank only to the energy it holds: " .. eei(x).electric_buffer_size)
	end)
end)

t.case("power hub: targets for a key this tile doesn't hold, or a malformed or negative entry, are skipped and the " ..
	"rest apply (Review Focus 3, plan review M2)", function(ctx)
	ctx.at(500, function() bare("ph-keys", 26800) end)
	ctx.at(700, function()
		local x, y = pair("ph-keys")
		ctx.expect(x ~= nil, "the link is ready at both ends")
		if not x then
			return
		end
		local errors = (storage.universal_edges.stats["ue.bridge"] or {}).errors or 0
		targets({ ["no-such-edge/c9"] = { n = 5, b = 10000, k = 0 }, [x.key] = { n = "lots", b = 10000, k = 0 },
			[y.key] = { n = 0, b = 10000, m = "secondary_output", k = 10 } })
		targets({ [x.key] = { n = 0, b = 10000, m = "secondary_output", k = -5 } })
		ctx.expect(eei(y).electric_interface_mode == MODE.secondary_output, "the good entry applied")
		ctx.expect(x.data.tat == nil and eei(x).electric_interface_mode == MODE.tertiary_input_output,
			"the malformed and the negative one skipped")
		ctx.expect(((storage.universal_edges.stats["ue.bridge"] or {}).errors or 0) == errors, "no handler error")
	end)
end)

-- §6.1, spike 45 P4: each report's f is the network's flows less UE's own interfaces, whatever mode they are in. Side a:
-- a 10 MW secondary source and a 4 MW sink; its link interface goes through every mode in turn, capped at 1 MW. Every f
-- reads se 10,000 and sd 4,000 kW and the rest 0 (floored: within 1 kW). The built-state step holds the interface full,
-- so it neither charges nor discharges and the read after the update is exact (§6.1's ponytail). The first report with
-- the link comes from a cycle the link joined part-way and still reads whole (Review Focus 2).
t.case("power hub: the report's f is the network's flows without UE's interfaces, in every mode (§6.1)", function(ctx)
	local key
	local steps = { "solar_output", "primary_output", "secondary_output", "tertiary_output", "secondary_input", false }
	local function check(n, what, all)
		ctx.expect(n ~= nil, what .. ": a report with the link")
		if not n then
			return
		end
		local f = n.f
		ctx.expect(math.abs(f.se - 10000) <= 1 and math.abs(f.sd - 4000) <= 1, what .. ": se " .. f.se .. ", sd " .. f.sd)
		if all then
			ctx.expect(f.so <= 1 and f.po <= 1 and f.to <= 1 and f.pd <= 1 and f.td <= 1, what .. ": " ..
				helpers.table_to_json(f))
		end
	end
	ctx.at(500, function()
		local fa = bare("ph-rep", 26900)
		layouts.source(fa, 6.5, 3.5, 10, "secondary_output")
		layouts.set_usage(layouts.put(fa, "ue-test-power-sink", 9.5, 3.5), 4e6 / 60)
	end)
	ctx.at(700, function()
		local x = pair("ph-rep")
		ctx.expect(x ~= nil, "the link is ready at both ends")
		key = x and x.key
		-- se and sd only: before its first target the interface is in the built state, charging from the surplus
		local first = key and reported(key, 0, 700, true)
		check(first, "the first report")
		log("ue.power.report (first, " .. tostring(key) .. "): " .. helpers.table_to_json(first or {}))
	end)
	for i, m in ipairs(steps) do
		local T = 700 + 150 * i
		ctx.at(T, function()
			local x = ep("ph-rep-x")
			eei(x).electric_buffer_size = 100e6
			eei(x).energy = m and 50e6 or 100e6
			targets({ [x.key] = { n = 0, b = 100000, m = m or nil, k = 1000 } })
		end)
		ctx.at(T + 140, function()
			local n = key and reported(key, T + 61, T + 140)
			check(n, m or "tertiary_input_output (the built state)", true)
			if n and not m then
				ctx.expect(n.a == 100000 and n.c == 100000, "a and c: the full 100 MJ, nothing owed: " .. n.a .. ", " .. n.c)
			end
		end)
	end
end)

-- Plan review S3: a failed endpoint doesn't poll, so the report's walk puts its interface in the built state within 10
-- ticks rather than leaving it in the hub's class and cap.
t.case("power hub: a failed endpoint's interface goes back to the built state within 10 ticks (§6.3, §10)", function(ctx)
	local x
	ctx.at(500, function() bare("ph-fail", 27300) end)
	ctx.at(700, function()
		x = pair("ph-fail")
		ctx.expect(x ~= nil, "the link is ready at both ends")
		if not x then
			return
		end
		targets({ [x.key] = { n = 0, b = 10000, m = "secondary_input", k = 100 } })
		connectors.fail(x, "poll", "power hub plan test")
	end)
	ctx.at(712, function()
		ctx.expect(x.state == "failed", "failed: " .. tostring(x and x.state))
		ctx.expect(eei(x).electric_interface_mode == MODE.tertiary_input_output, "the built state, by the report's walk")
	end)
end)

-- Plan ruling 28 (model F4): the own terms are what the network update saw. Tick order: v2_test loads after UE, so its
-- steps run after UE's scheduler in a tick, and a step can't write between the update and the sample. A wrapper of
-- scheduler.on_tick stands in for what does: it runs a poll (the type's own, n = the pool's energy) before the tasks on one sample
-- tick (a lane isn't idle for a second send within a few hundred ticks). The poll takes the interface's whole 50 MJ at
-- once, so a sample that reads the interface after it counts an own offer of 0 against a flow_last_tick that still holds
-- the 1 MW cap: a phantom 1,000 kW in se for that sample (167 kW in the report's mean). Refilled the next tick.
local scheduler = require("modules/universal_edges/runtime/scheduler")
local drain, emptied = {}, {}
do
	local on_tick = scheduler.on_tick
	function scheduler.on_tick(tick)
		if drain[tick] then
			local x = drain[tick]
			x.data.n = math.ceil(x.data.eei.energy / 1000) -- the pool's whole energy, so no debt is left to drain the refill
			connectors.types.power.poll(x, tick)
			x.data.n = 0
			emptied[tick] = x.data.eei.energy < 1 and true or ("energy " .. x.data.eei.energy .. ", idle " ..
				tostring(x:idle("ab")) .. ", " .. tostring(x:idle("ba")) .. ", sent " .. x.data.stats.sent)
		end
		on_tick(tick)
	end
end

t.case("power hub: the own terms are the interface as the update saw it, not after a poll's write (§6.1, F4)", function(ctx)
	local x, key, last, phase, drains = nil, nil, nil, nil, {}
	ctx.at(500, function()
		local fa = bare("ph-f4", 27500)
		layouts.source(fa, 6.5, 3.5, 10, "secondary_output")
		layouts.set_usage(layouts.put(fa, "ue-test-power-sink", 9.5, 3.5), 4e6 / 60)
	end)
	ctx.at(700, function()
		x = pair("ph-f4")
		ctx.expect(x ~= nil, "the link is ready at both ends")
		key = x and x.key
		eei(x).electric_buffer_size = 100e6
		eei(x).energy = 50e6
	end)
	for k = 701, 1500 do
		ctx.at(k, function()
			if not x then
				return
			end
			if k % 30 == 0 then
				targets({ [x.key] = { n = 0, b = 100000, m = "secondary_output", k = 1000 } })
			end
			local n = storage.universal_edges.power_report.n
			if last ~= nil and n ~= last and not phase then
				phase = k % 10 -- the sample ran in this tick, ahead of this step
			end
			last = n
			if phase and k == 800 then
				-- a sample tick ahead of this step, so the wrapper sees it
				drain[900 + phase] = x
				drains[1] = 900 + phase
			end
			for _, d in ipairs(drains) do
				if k == d + 1 then
					eei(x).energy = 50e6 -- refill (a poll's lane send may refund meanwhile; the offer stays the cap)
				end
			end
		end)
	end
	ctx.at(1500, function()
		ctx.expect(phase ~= nil and #drains == 1, "the sample ticks were found: phase " .. tostring(phase))
		for _, d in ipairs(drains) do
			ctx.expect(emptied[d] == true, "the poll at " .. d .. " took the interface's whole energy: " .. tostring(emptied[d]))
		end
		local seen = 0
		for _, r in ipairs(reports) do
			for _, n in ipairs(r.nets) do
				for _, l in ipairs(n.l) do
					if l[1] == key and r.tick > 750 then
						seen = seen + 1
						ctx.expect(math.abs(n.f.se - 10000) <= 1, "report at " .. r.tick .. ": se " .. n.f.se)
					end
				end
			end
		end
		ctx.expect(seen >= 5, "reports with the link: " .. seen)
	end)
end)

-- §6.1 (review of Task 8): flow_last_tick holds the offers and demands the update saw before its transfer, and a link
-- interface in the built state (both limits 1 TW) charges or discharges its whole per-tick surplus in that update, so its
-- energy read after it is off by that. Side a: a 10 MW secondary source and a 4 MW sink (a 6 MW surplus), a hub-class link
-- c1 (secondary_output, 1 MW, 50 of 100 MJ) and a built-state link c2 (50 of 100 MJ, charging from the surplus) on one
-- pool. The network has no accumulator of its own, so every report's to and td are 0 (within the floor's 1 kW).
t.case("power hub: a built-state interface's charge isn't reported as tertiary demand or output (§6.1)", function(ctx)
	local key
	ctx.at(500, function()
		local fa = layouts.edge(loop, "ph-bs", 28100, 12, {
			{ cid = "c1", type = "power", pos = 2, width = 2, params = {} },
			{ cid = "c2", type = "power", pos = 7, width = 2, params = {} },
		}, 12)
		local p1, p2 = layouts.put(fa, "substation", 3, 1), layouts.put(fa, "substation", 8, 1)
		local W, script = defines.wire_connector_id, defines.wire_origin.script
		p1.get_wire_connector(W.pole_copper, true).connect_to(p2.get_wire_connector(W.pole_copper, true), false, script)
		layouts.source(fa, 6.5, 3.5, 10, "secondary_output")
		layouts.set_usage(layouts.put(fa, "ue-test-power-sink", 9.5, 3.5), 4e6 / 60)
	end)
	for k = 700, 1300, 30 do
		ctx.at(k, function()
			local c1, c2 = ep("ph-bs-x", "c1"), ep("ph-bs-x", "c2")
			if not (c1 and c2 and c1.state == "ready" and c2.state == "ready") then
				ctx.expect(k > 700, "both links ready")
				return
			end
			key = c1.key
			if k == 700 then
				eei(c1).electric_buffer_size, eei(c2).electric_buffer_size = 100e6, 100e6
				eei(c1).energy, eei(c2).energy = 50e6, 50e6
			end
			targets({ [c1.key] = { n = 0, b = 100000, m = "secondary_output", k = 1000 } })
		end)
	end
	ctx.at(1300, function()
		local seen = 0
		for _, r in ipairs(reports) do
			for _, n in ipairs(r.nets) do
				for _, l in ipairs(n.l) do
					if l[1] == key and r.tick > 800 then
						seen = seen + 1
						ctx.expect(n.f.td <= 1 and n.f.to <= 1 and math.abs(n.f.se - 10000) <= 1,
							"report at " .. r.tick .. ": " .. helpers.table_to_json(n.f))
					end
				end
			end
		end
		ctx.expect(seen >= 5, "reports with the link: " .. seen)
	end)
end)

-- Review of Task 8, §6.3: a ready endpoint whose partner isn't ready is never polled (lanes.visit), so it doesn't count as
-- polling: its interface is built within 10 ticks and the report leaves it out of l.
t.case("power hub: a ready endpoint whose partner isn't ready is in the built state and out of l (§6.3)", function(ctx)
	local x, y
	ctx.at(500, function() bare("ph-part", 28300) end)
	ctx.at(700, function()
		x, y = pair("ph-part")
		ctx.expect(x ~= nil, "the link is ready at both ends")
		if not x then
			return
		end
		targets({ [x.key] = { n = 0, b = 10000, m = "secondary_input", k = 100 } })
		ctx.expect(eei(x).electric_interface_mode == MODE.secondary_input, "the target applies while the partner is ready")
		connectors.fail(y, "poll", "power hub partner test")
	end)
	ctx.at(800, function() -- the partner's failure reaches x with y's next visit
		ctx.expect(x.state == "ready" and x.partner.state ~= "ready", "x ready, its partner not: " .. tostring(x.state) ..
			", " .. tostring(x.partner.state))
		ctx.expect(eei(x).electric_interface_mode == MODE.tertiary_input_output, "the built state, by the report's walk")
		targets({ [x.key] = { n = 0, b = 10000, m = "secondary_input", k = 100 } })
		ctx.expect(eei(x).electric_interface_mode == MODE.tertiary_input_output, "and a target doesn't take it out")
	end)
	ctx.at(900, function()
		ctx.expect(reported(x.key, 830, 900) == nil, "a network whose only link has no ready partner isn't reported")
	end)
end)

-- Smooth (power hub spec §3.6, §11.3; spike 22's method): over 5 sends and 5 credits, each side's generator output per
-- tick (its network's output_counts step) has a standard deviation under 1 % of its mean. Side a exports 6 MW
-- (secondary_input capped at 6 MW) beside a capped 20 MW source and a 5 MW sink, so its source runs a steady 11 MW. Side
-- b imports (primary_output capped at 6 MW) beside a capped 20 MW source and a 15 MW sink, so its source runs a steady
-- 9 MW. Spike 22 measured a 115 kJ deviation against a 183 kJ mean with the old rule's one-step removal.
t.case("power hub: a steady export and import leave both generators flat over 5 sends and credits (§3.6)", function(ctx)
	local S, x, y, src_a, src_b = 1500, nil, nil, nil, nil
	local ca, cb = {}, {}
	ctx.at(S, function()
		local fa, fb = bare("ph-smooth", 27000)
		src_a, src_b = layouts.source(fa, 6.5, 3.5, 20, "secondary_output"), layouts.source(fb, 6.5, 3.5, 20, "secondary_output")
		layouts.set_usage(layouts.put(fa, "ue-test-power-sink", 9.5, 3.5), 5e6 / 60)
		layouts.set_usage(layouts.put(fb, "ue-test-power-sink", 9.5, 3.5), 15e6 / 60)
	end)
	-- every second from S + 200: a sends 6,000 kJ a poll (n, a rate); b sends nothing; both buffers 48 MJ (8 × the
	-- flow, plan ruling 29), started half full (the hub's stock target)
	for k = 0, 14 do
		ctx.at(S + 200 + 60 * k, function()
			x, y = pair("ph-smooth")
			if not x then
				return
			end
			if k == 0 then
				-- size first, as its own statement: a multiple assignment runs right to left, so the energy would be capped
				-- by the old 10 MJ buffer (Task 7 review)
				eei(x).electric_buffer_size = 48e6
				eei(x).energy = 24e6
				eei(y).electric_buffer_size = 48e6
				eei(y).energy = 24e6
			end
			targets({ [x.key] = { n = 6000, b = 48000, m = "secondary_input", k = 6000 },
				[y.key] = { n = 0, b = 48000, m = "primary_output", k = 6000 } })
		end)
	end
	for at = S + 599, S + 899 do
		ctx.at(at, function()
			ca[at], cb[at] = counter(src_a), counter(src_b)
		end)
	end
	ctx.at(S + 900, function()
		ctx.expect(x ~= nil, "the link was ready at both ends")
		local function stats(c)
			local sum, n, lo, hi = 0, 0, math.huge, 0
			for at = S + 600, S + 899 do
				local d = c[at] - c[at - 1]
				sum, n, lo, hi = sum + d, n + 1, math.min(lo, d), math.max(hi, d)
			end
			local mean, var = sum / n, 0
			for at = S + 600, S + 899 do
				var = var + ((c[at] - c[at - 1]) - mean) ^ 2
			end
			return math.sqrt(var / n), mean, lo, hi
		end
		local sa, na, la, ha = stats(ca)
		local sb, nb, lb, hb = stats(cb)
		log(string.format("power hub smooth: a std %.2f kJ mean %.2f kJ min %.2f max %.2f; b std %.2f kJ mean %.2f kJ min %.2f max %.2f",
			sa / 1e3, na / 1e3, la / 1e3, ha / 1e3, sb / 1e3, nb / 1e3, lb / 1e3, hb / 1e3))
		ctx.expect(math.abs(na - 11e6 / 60) < 0.02 * 11e6 / 60, "a's source runs 11 MW: " .. na * 60 / 1e6 .. " MW")
		ctx.expect(math.abs(nb - 9e6 / 60) < 0.02 * 9e6 / 60, "b's source runs 9 MW: " .. nb * 60 / 1e6 .. " MW")
		ctx.expect(sa < 0.01 * na, "a's output per tick: std " .. sa .. " J against a mean of " .. na)
		ctx.expect(sb < 0.01 * nb, "b's output per tick: std " .. sb .. " J against a mean of " .. nb)
		ctx.expect(x and x.data.stats.sent >= 30000 and y.data.stats.got >= 30000, "the link carried at least 5 sends")
	end)
end)

-- Task 8b: a report over the one-line limit leaves in ue.power.chunk parts and a header, and nothing takes send_json's file
-- path. 16 looped edges make 32 linked networks (about 5 KB of report).
t.case("power hub: a report too big for one line goes in parts that put back together to every network (Task 8b)", function(ctx)
	local N = 16
	ctx.at(600, function()
		for k = 0, N - 1 do
			bare("ph-big" .. k, 28500 + 24 * k)
		end
	end)
	ctx.at(2500, function()
		local biggest = 0
		for _, r in ipairs(reports) do
			if r.tick > 1800 then
				biggest = math.max(biggest, #r.nets)
			end
		end
		ctx.expect(biggest >= 2 * N, "a report holds all " .. 2 * N .. " new networks: " .. biggest)
		ctx.expect(parts.reports >= 5, "reports came in parts: " .. parts.reports)
		ctx.expect(parts.max < 3900, "no message reaches send_json's file path (4000 bytes): " .. parts.max)
	end)
end)

-- 2026-10-20: the hub's round is one wall-clock second, so at game.speed 10 targets arrive every 600 ticks. The stale
-- limit scales by game.speed (§6.3). All inside one tick, so no other case sees the speed. The report walk's own check
-- (networks(), local to power.lua) isn't reachable from a test helper, so only the poll's is covered.
t.case("power hub: a 400-tick-old target is fresh at game.speed 10 and stale at 1 (§6.3)", function(ctx)
	ctx.at(500, function() bare("ph-speed", 28950) end)
	ctx.at(3800, function()
		local x = pair("ph-speed")
		if not x then
			ctx.expect(false, "the link is ready at both ends")
			return
		end
		targets({ [x.key] = { n = 0, b = 10000, m = "solar_output", k = 1000 } })
		x.data.tat = game.tick - 400
		local poll = connectors.types.power.poll
		game.speed = 10 -- luacheck: ignore 122
		local ok, err = pcall(poll, x, game.tick)
		local mode10 = eei(x).electric_interface_mode
		game.speed = 1 -- luacheck: ignore 122
		ctx.expect(ok, "poll at speed 10: " .. tostring(err))
		ctx.expect(mode10 == MODE.solar_output, "400 ticks old at speed 10: still the target's mode")
		poll(x, game.tick)
		ctx.expect(eei(x).electric_interface_mode == MODE.tertiary_input_output, "400 ticks old at speed 1: built")
	end)
end)
