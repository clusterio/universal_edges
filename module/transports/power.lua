-- The power connector type (power hub spec, docs/superpowers/specs/2026-10-18-power-hub-design.md): a dynamic
-- ue-link-interface beside each side's border pole. The link interfaces on one electric network are one pool, written at
-- one fill ratio (§4). The controller's hub gives each link the amount it sends this second, a buffer, and the class and
-- cap its interface takes (ue.power.targets, §6.2). A link sends that amount once per poll over its stream lane; a relay
-- may send beyond its stock and owes the rest, paid from the next energy into its pool (§6.3). With no fresh target, or
-- while the link doesn't poll, the interface is in the built state, an accumulator on its own tile (§5, §10). The bag is
-- { e = kJ }. Once a second the tile reports each linked network's per-class flows, stock and link totals to the hub
-- (ue.power.report, §6.1).
local bridge = require("modules/universal_edges/runtime/bridge")
local connectors = require("modules/universal_edges/edges/connectors")
local geometry = require("modules/universal_edges/edges/geometry_core")
local detect = require("modules/universal_edges/transports/detect")
local trace = require("modules/universal_edges/runtime/trace")
local hash = require("modules/universal_edges/runtime/scheduler_core").hash
local scheduler = require("modules/universal_edges/runtime/scheduler")

local power = {}
local NAME, KEY = "ue-link-interface", "e"
local ALL = {} -- get_accumulators_energy's filter: {} is every accumulator; one shared table (review M3)
local send = bridge.channel("universal_edges")
local MODE = defines.electric_interface_mode
local TW = 1e12 / 60 -- the prototype's 1 TW flow limit, J a tick
local STALE = 300 -- §6.3: a target older than this many ticks is none (5 s of real time: see stale())
local function stale() return STALE * math.max(1, game.speed) end -- the hub's round is wall-clock, game.speed times faster in ticks
local OUTPUT = { solar_output = true, primary_output = true, secondary_output = true, tertiary_output = true }

local RED, GREEN = defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green
local REPROPOSE = 3600 -- K9

--- K9 (circuit-link spec §6.1): when the border pole first carries a red or green wire, propose a circuit connector at its
--- columns; look again 3600 ticks later, and propose again only if no circuit endpoint covers them. An unwired pole costs
--- two reads a poll.
local function propose_circuit(ep, tick)
	local d, pole = ep.data, ep.data.border
	if not (pole and pole.valid) or (d.cprop and tick - d.cprop < REPROPOSE) then
		return
	end
	if not (pole.get_circuit_network(RED) or pole.get_circuit_network(GREEN)) then
		return
	end
	d.cprop = tick
	local side = storage.universal_edges.edges[ep.edge]
	for cid, type_name in pairs(side.eps) do
		local c = type_name == "circuit" and connectors.get(side, cid)
		if c and not c.closing and c.col == ep.col and c.width == ep.width then
			return -- the circuit link stands
		end
	end
	local id = trace.new_id()
	local pos = geometry.col(side.me, side.length, ep.col, ep.width)
	send("ue.connector.propose", { edge = ep.edge, type = "circuit", pos = pos, width = ep.width, params = {}, trace = id })
	send("trace", { op = "ue.connector", phase = "proposed", level = "info", tick = tick, trace = id, edge = ep.edge,
		type = "circuit", pos = pos, params = {} })
end

local function out_dir(ep)
	return ep.me == "a" and "ab" or "ba"
end

--- The pool of this interface's network (§4): every power endpoint's interface with the same electric_network_id, this
--- one included. Returns { a, c, eps }: the pool's energy and capacity in J, and the endpoints whose interfaces are in
--- it. nil while the interface stands on no network.
--- ponytail: grouping by electric_network_id doesn't join sub-networks behind a power switch, which share one
--- parent_network. Group by parent if a relay ever sits behind a switch.
local function read(ep)
	local eei = ep.data.eei
	local id = eei and eei.valid and eei.electric_network_id
	if not id then
		return nil
	end
	local g = { a = 0, c = 0, eps = {} }
	for _, o in pairs(storage.universal_edges.eps.power) do
		local x = o.data.eei
		if x and x.valid and x.electric_network_id == id then
			g.eps[#g.eps + 1] = o
			g.a, g.c = g.a + x.energy, g.c + x.electric_buffer_size
		end
	end
	return g
end

--- §6.1, plan ruling 28 (F4): the link interfaces as the last network update saw them. Scripts run between that update
--- and the report's sample (the inbox's credits and targets, the polls, other tasks), so the first script write of a tick
--- calls this first and keeps every interface's mode, limits and energy as they stand then; the sample reads these. Tick
--- order (scheduler.lua, control.lua; spike 15): on_tick before the entity update, so flow_last_tick read in on_tick
--- describes the update after the previous tick's scripts. Local, not storage: a snapshot only serves the tick it is
--- taken in, and is rebuilt by the first write of the next.
--- Only on the report task's own ticks; power.sample takes it unconditionally, for a task a work cap deferred.
local PHASE = hash("ue.power.report") % 10 -- scheduler_core: a periodic task runs when (tick + phase) % interval == 0
local snap = { tick = -1 }
local function snapshot(always)
	if snap.tick == game.tick or not (always or (game.tick + PHASE) % 10 == 0) then
		return
	end
	snap = { tick = game.tick }
	for _, o in pairs(storage.universal_edges.eps.power or {}) do
		local x = o.data.eei
		if x and x.valid then
			snap[o.key] = { mode = x.electric_interface_mode, out = x.output_flow_limit, inp = x.input_flow_limit,
				e = x.energy, size = x.electric_buffer_size }
		end
	end
end

--- §4: a new total A2 (J) written back at one fill ratio over the pool's interfaces.
local function write(g, A2)
	snapshot()
	local r = A2 / g.c
	for _, o in ipairs(g.eps) do
		o.data.eei.energy = r * o.data.eei.electric_buffer_size
	end
end

--- §8.4: put joules into the border pole's network's accumulators; returns what didn't fit.
local function to_accumulators(ep, joules)
	if joules <= 0 then
		return 0
	end
	local pole = ep.data.border
	local net = pole and pole.valid and pole.electric_network
	local parent = net and net.parent_network
	if not parent then
		return joules
	end
	local acc = parent.get_accumulators_energy(ALL)
	local put = math.max(0, math.min(joules, acc.capacity - acc.energy))
	parent.set_accumulators_energy({ energy = acc.energy + put, equalize = false })
	return joules - put
end

--- §6.4: put joules into the network's other link interfaces at one fill ratio (this one is going, or gone: it takes
--- none), then into the border pole's accumulators (plan ruling 19); returns what fits nowhere.
local function to_pool(ep, joules)
	local g = read(ep)
	if g then
		local mine = ep.data.eei
		local others = {}
		for _, o in ipairs(g.eps) do
			if o ~= ep then
				others[#others + 1] = o
			end
		end
		local a, c = g.a - mine.energy, g.c - mine.electric_buffer_size
		local put = math.max(0, math.min(joules, c - a))
		if put > 0 then
			g.eps, g.c = others, c
			write(g, a + put)
			joules = joules - put
		end
	end
	return to_accumulators(ep, joules)
end

local function dropped(ep, joules)
	local kj = math.floor(joules / 1000)
	ep.data.stats.dropped = ep.data.stats.dropped + kj
	send("trace", { op = "ue.power", phase = "refund_dropped", level = "warn", tick = game.tick, trace = ep.trace,
		edge = ep.edge, cid = ep.cid, amount = kj })
end

--- §5: the built state, today's tertiary interface: it charges from its network's surplus and feeds its deficit.
local function built(eei)
	snapshot()
	if eei.electric_interface_mode ~= MODE.tertiary_input_output then
		eei.electric_interface_mode = MODE.tertiary_input_output
		eei.input_flow_limit, eei.output_flow_limit = TW, TW
	end
end

local function number(v)
	return type(v) == "number" and v >= 0
end

--- Plan ruling 27 (spec §6.3): the endpoint polls when it is ready, open, on an active side and its partner is ready too
--- (lanes.visit polls power only then). One that doesn't keeps the built state, its targets are ignored, and the report
--- leaves it out of l.
local function polling(ep)
	local side = storage.universal_edges.edges[ep.edge]
	return ep.state == "ready" and not ep.closing and side ~= nil and side.active and ep.partner ~= nil
		and ep.partner.state == "ready" or false
end

local FIELDS = { "so", "po", "se", "to", "pd", "sd", "td" }
local FLOW = { so = "solar_output", po = "primary_output", se = "secondary_output", to = "tertiary_output",
	pd = "primary_demand", sd = "secondary_demand", td = "tertiary_demand" }
local OWN = { [MODE.solar_output] = "so", [MODE.primary_output] = "po", [MODE.secondary_output] = "se",
	[MODE.tertiary_output] = "to" }
local SAMPLES = 6 -- §6.1: six samples, 10 ticks apart, a report
-- ponytail: radar's 3000 is too tight here: the report's quotes escape inside data and a part must stay under 4000 with
-- its envelope; 2000 leaves room. Past 64 parts (~1000 networks) the instance drops the report.
local CHUNK = 2000
local KW = 60 / 1000 -- J a tick to kW

--- §6.1, plan ruling 5: the sums so far by electric_network_id, and the samples taken; in storage, because every Lua
--- state must queue the same report.
local function sums()
	local s = storage.universal_edges
	s.power_report = s.power_report or { n = 0, nets = {} } -- ponytail: created on first use, no schema step
	return s.power_report
end

--- §4, plan ruling 4: every network with a link interface, by electric_network_id: { parent, eps, ready }, where ready
--- counts the ready, open endpoints among eps; and the interfaces to put in the built state (plan review S3): those whose
--- endpoint isn't polling or has no fresh target, whatever the poll does for its own reasons.
local function networks()
	local by, idle = {}, {}
	for _, ep in pairs(storage.universal_edges.eps.power or {}) do
		local x = ep.data.eei
		local id = x and x.valid and x.electric_network_id
		if id then
			local n = by[id]
			if not n then
				n = { parent = x.electric_network.parent_network, eps = {}, ready = 0 }
				by[id] = n
			end
			n.eps[#n.eps + 1] = ep
			local ready = polling(ep) -- plan ruling 27: an inactive side counts as not polling
			if ready then
				n.ready = n.ready + 1
			end
			if not (ready and ep.data.tat and game.tick - ep.data.tat <= stale()) then
				idle[#idle + 1] = x
			end
		end
	end
	return by, idle
end

--- §6.1: one sample of a network's flows less its own interfaces (J a tick), added to acc. An output mode offers
--- min(output limit, energy) in its field, secondary_input asks min(input limit, room) in sd, and tertiary_input_output
--- does both (spike 45 P4). flow_last_tick holds what the update offered and asked before its transfer, and the snapshot
--- is the interface after it, so each is taken back to what the update saw (F4, §6.1) from the same table's usages:
--- an output gave u of its offer, E = E0 (1 - u), a demand got s of its room, room = room0 (1 - s), and the built state
--- both, E = E0 (1 - u) + s (size - E0), so E0 = (E - s size) / (1 - u - s). A usage of 1 (or a denominator <= 0) leaves
--- the snapshot as it is. A field below 0 counts as 0 (plan ruling 5).
local function sample(acc, n)
	local flow = n.parent.flow_last_tick
	local own = { so = 0, po = 0, se = 0, to = 0, pd = 0, sd = 0, td = 0 }
	local function usage(f)
		local u = flow[FLOW[f] .. "_usage"]
		return type(u) == "number" and u > 0 and u < 1 and u or 0
	end
	for _, ep in ipairs(n.eps) do
		local x = ep.data.eei
		local s = snap[ep.key] or { mode = x.electric_interface_mode, out = x.output_flow_limit,
			inp = x.input_flow_limit, e = x.energy, size = x.electric_buffer_size }
		local field = OWN[s.mode]
		if field then
			own[field] = own[field] + math.min(s.out, s.e / (1 - usage(field)))
		elseif s.mode == MODE.secondary_input then
			own.sd = own.sd + math.min(s.inp, (s.size - s.e) / (1 - usage("sd")))
		elseif s.mode == MODE.tertiary_input_output then
			local u, d = usage("to"), usage("td")
			local e = u + d < 1 and math.max(0, math.min(s.size, (s.e - d * s.size) / (1 - u - d))) or s.e
			own.to = own.to + math.min(s.out, e)
			own.td = own.td + math.min(s.inp, s.size - e)
		end
	end
	for _, f in ipairs(FIELDS) do
		acc[f] = (acc[f] or 0) + math.max(0, flow[FLOW[f]] - own[f])
	end
	acc.k = (acc.k or 0) + 1
end

--- §6.1: every 10 ticks, sample each network with a link interface; every sixth time, report those with a ready link in
--- one ue.power.report (nothing when there are none) and start the sums again. A network's means are over the samples
--- it was seen in (plan ruling 5). A body over CHUNK bytes leaves as ue.power.chunk parts keyed power/<seq>, then a
--- ue.power.report header { chunks, seq } (radar's shape, plan ruling 12), so nothing takes send_json's file path.
function power.sample()
	snapshot(true) -- F4: before anything below writes
	local st = sums()
	local by, idle = networks()
	for id, n in pairs(by) do
		st.nets[id] = st.nets[id] or {}
		sample(st.nets[id], n)
	end
	for _, x in ipairs(idle) do
		built(x)
	end
	st.n = st.n + 1
	if st.n < SAMPLES then
		return
	end
	local nets = {}
	for id, n in pairs(by) do
		if n.ready > 0 then
			local acc, a, c, l = st.nets[id], 0, 0, {}
			for _, ep in ipairs(n.eps) do
				local x, d = ep.data.eei, ep.data
				a, c = a + x.energy - (d.owe or 0), c + x.electric_buffer_size
				if polling(ep) then
					l[#l + 1] = { ep.key, d.stats.sent, d.stats.got }
				end
			end
			local f = {}
			for _, k in ipairs(FIELDS) do
				f[k] = math.floor(acc[k] / acc.k * KW)
			end
			nets[#nets + 1] = { a = math.floor(a / 1000), c = math.floor(c / 1000), f = f, l = l }
		end
	end
	st.n, st.nets = 0, {}
	if #nets > 0 then
		local json = helpers.table_to_json({ nets = nets })
		if #json <= CHUNK then
			send("ue.power.report", { nets = nets })
			return
		end
		st.seq = (st.seq or 0) + 1
		local n, key = math.ceil(#json / CHUNK), "power/" .. st.seq
		for i = 1, n do
			send("ue.power.chunk", { key = key, i = i, n = n, data = string.sub(json, (i - 1) * CHUNK + 1, i * CHUNK) })
		end
		send("ue.power.report", { chunks = n, seq = st.seq })
	end
end

-- Plan review S6: a periodic task runs unguarded in on_tick, so a raise here is contained and logged, once an hour.
scheduler.periodic({ name = "ue.power.report", interval = 10, fn = function(tick)
	local ok, err = pcall(power.sample)
	if not ok then
		local st = sums()
		if not st.err_at or tick - st.err_at >= 3600 then
			st.err_at = tick
			send("trace", { op = "ue.power", phase = "report_failed", level = "error", tick = tick, error = tostring(err) })
		end
	end
end })

--- §6.2: the hub's targets for this tile's links. A key held here stores n, b and the tick, and takes its class and cap
--- at once: m's mode with k kW on that side's limit and 0 on the other (plan ruling 7), or with no m the built state.
--- A remainder already pending at the last targets (refused, or its ack lost) re-offers now instead of waiting out the
--- lane's backoff; one simply waiting for its ack isn't sent twice (plan review M1). Keys not held here and malformed or
--- negative entries are skipped (Review Focus 3, plan review M2).
bridge.on("universal_edges", "ue.power.targets", function(p)
	if type(p.l) ~= "table" then
		return false
	end
	snapshot()
	local eps = storage.universal_edges.eps.power or {}
	for key, x in pairs(p.l) do
		local ep = eps[key]
		local eei = ep and ep.data.eei
		if eei and eei.valid and not polling(ep) then
			built(eei) -- plan ruling 27: it doesn't poll, so it keeps the built state and its target is ignored
		elseif eei and eei.valid and type(x) == "table" and number(x.n) and number(x.b) and number(x.k) then
			local d, cap = ep.data, x.k * 1000 / 60
			d.n, d.b, d.tat = x.n, x.b, game.tick
			if OUTPUT[x.m] then
				eei.electric_interface_mode = MODE[x.m]
				eei.output_flow_limit, eei.input_flow_limit = cap, 0
			elseif x.m == "secondary_input" then
				eei.electric_interface_mode = MODE.secondary_input
				eei.input_flow_limit, eei.output_flow_limit = cap, 0
			else
				built(eei)
			end
			local dir = out_dir(ep)
			local busy = not ep:idle(dir)
			if busy and d.busy then
				ep:nudge(dir)
			end
			d.busy = busy
		end
	end
end)

local schedule = { per_tick = 4, interval = 60 }

connectors.register_type({
	name = "power",
	lanes = function() return { ab = "stream", ba = "stream" } end,
	schedule = schedule,
	--- F9: adopts its interface, or creates it at local (col + 0.5, -0.5), inside the border pole's supply area. A new
	--- interface starts in the built state (power hub spec §5, spike 45).
	build = function(ep)
		local surface = game.get_surface(ep.frame.surface_index)
		if not surface then
			return "blocked"
		end
		local d = ep.data
		if not (d.eei and d.eei.valid) then
			local x, y = geometry.to_world(ep.frame, ep.col + 0.5, -0.5)
			local eei = surface.find_entity(NAME, { x, y }) or surface.create_entity({ name = NAME, position = { x, y },
				force = "player", create_build_effect_smoke = false })
			if not eei then
				return "blocked"
			end
			eei.destructible, eei.operable = false, false
			d.eei = eei
		end
		d.stats = d.stats or { sent = 0, got = 0, dropped = 0 }
		d.owe = d.owe or 0 -- J sent beyond the pool's stock, paid from its next energy (§6.3)
		detect.adopt(ep)
		return "ready"
	end,

	--- Plan review S3: a side the controller deactivates (and every side at a server start, until the controller syncs
	--- it) doesn't poll, so its interface leaves the hub's class and cap now.
	deactivated = function(ep)
		local x = ep.data.eei
		if x and x.valid then
			built(x)
		end
	end,
	--- §6.3, with the pay step before the freshness check (plan ruling 3).
	poll = function(ep, tick)
		snapshot()
		detect.check(ep)
		propose_circuit(ep, tick) -- circuit-link spec §6.1: before the network read, which returns early off-network
		local d, eei = ep.data, ep.data.eei
		local g = read(ep)
		if not g then
			return
		end
		local owe = d.owe or 0 -- plan ruling 6: an endpoint built before the power hub has none
		local p = math.min(owe, g.a)
		if p > 0 then
			write(g, g.a - p)
			g.a, owe = g.a - p, owe - p
		end
		d.owe = owe
		if not d.tat or tick - d.tat > stale() then
			built(eei)
			return
		end
		local B = math.max(1000 * d.b, eei.energy) -- never below the stored energy, which a smaller buffer destroys
		if B ~= eei.electric_buffer_size then
			g.c = g.c + B - eei.electric_buffer_size
			eei.electric_buffer_size = B
			write(g, g.a) -- plan ruling 26: one fill ratio again, so a buffer shrunk to its energy isn't left full
		end
		-- §6.3 step 4: this second's amount, once per poll and nothing carried over (plan review B1), at most the pool's
		-- energy plus this link's buffer less what it owes already.
		-- ponytail: n is a second's worth for a poll every 60 ticks; scale it by the ticks since the last poll if a
		-- type's walk ever stretches polls past that (over about 240 power endpoints on one tile at per_tick 4).
		local dir = out_dir(ep)
		local x = math.min(d.n, math.floor((g.a + 1000 * d.b - owe) / 1000))
		if x > 0 and ep:idle(dir) and ep:can_send(dir) then
			ep:send(dir, { [KEY] = x }) -- first: a refused send (MAX_TOTAL) raises before anything is taken
			d.stats.sent = d.stats.sent + x
			local take = math.min(1000 * x, g.a)
			if take > 0 then
				write(g, g.a - take)
			end
			d.owe = owe + 1000 * x - take
		end
	end,
	--- T2: add only what fits, at one fill ratio over the pool, and credit exactly that (§6.4).
	credit = function(ep, _, bag)
		local g = read(ep)
		local x = g and math.min(bag[KEY] or 0, math.floor((g.c - g.a) / 1000)) or 0
		if x <= 0 then
			return { [KEY] = 0 }
		end
		write(g, g.a + 1000 * x)
		ep.data.stats.got = ep.data.stats.got + x
		return { [KEY] = x }
	end,
	--- §6.4, plan review S4: what the link owes is paid from its pool as far as it holds. The rest stays owed for the
	--- lane's refund, which comes after teardown, to cancel; it is logged with the most a refund may cancel (the lane's
	--- unacknowledged send). Then the interface's energy goes into the network's other link interfaces and then the
	--- border pole's accumulators; what fits nowhere is dropped and logged.
	teardown = function(ep)
		snapshot()
		local d, eei = ep.data, ep.data.eei
		local owe = d.owe or 0
		if owe > 0 then
			local g = read(ep)
			local x = g and math.min(owe, g.a) or 0
			if x > 0 then
				write(g, g.a - x)
			end
			d.owe = owe - x
			if d.owe >= 1 then
				local pending = ep:pending(out_dir(ep))
				send("trace", { op = "ue.power", phase = "debt_unpaid", level = "warn", tick = game.tick, trace = ep.trace,
					edge = ep.edge, cid = ep.cid, amount = d.owe / 1000, refundable = pending and pending[KEY] or 0 })
			end
		end
		if eei and eei.valid then
			local left = to_pool(ep, eei.energy)
			if left > 0 then
				dropped(ep, left)
			end
			eei.destroy()
		end
	end,
	--- §6.4, T5 bent on purpose: what the link owes is cancelled first (that energy never left the pool); the rest goes
	--- back into the pool, then the accumulators; what fits nowhere is dropped and logged.
	refund = function(ep, _, bag)
		local d, joules = ep.data, (bag[KEY] or 0) * 1000
		local cancel = math.min(d.owe or 0, joules)
		if cancel > 0 then
			d.owe = d.owe - cancel
		end
		local left = to_pool(ep, joules - cancel)
		if left > 0 then
			dropped(ep, left)
		end
		return true
	end,
})

return power
