-- The power connector type (SP3 spec §8.2, D14, D34): a tertiary ue-link-interface beside each side's border pole,
-- balanced with PR #7's rule over the pole's whole network: its accumulators and every link interface on it (a tertiary
-- interface never passes energy to another, so energy that came in through one link would be invisible to the next on a
-- relay tile), written back at one fill ratio. Each interface's buffer follows the demand the link carries (D34, plan
-- ruling 18), up to 10 GJ (D37). The bag is { e = kJ }.
-- A send is not removed from the pool at once: that refills at full generator output for up to 20 ticks, a sawtooth on the
-- sender's production once a period (spike 22). It becomes debt (d.debt, J), paid every tick by the drain task in equal
-- steps over the poll interval, from the pool, a shortfall carried to the next tick. The poll counts the debt as spent.
local bridge = require("modules/universal_edges/runtime/bridge")
local scheduler = require("modules/universal_edges/runtime/scheduler")
local connectors = require("modules/universal_edges/edges/connectors")
local geometry = require("modules/universal_edges/edges/geometry_core")
local balance = require("modules/universal_edges/transports/balance_core")
local detect = require("modules/universal_edges/transports/detect")
local trace = require("modules/universal_edges/runtime/trace")

local power = {}
local NAME, KEY = "ue-link-interface", "e"
local ALL = {} -- get_accumulators_energy's filter: {} is every accumulator; one shared table (review M3)
local send = bridge.channel("universal_edges")

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

--- The pooled storage of this interface's network (§8.2): the accumulators and every power endpoint's interface here
--- with the same electric_network_id, this one included. Returns { parent, a, c, ca, ae, eps }: the pole's whole network
--- (D14: parent_network), the pool's energy and capacity and the accumulators' capacity and energy in J, and the
--- endpoints whose interfaces are in it. nil while the interface stands on no network.
--- ponytail: grouping by electric_network_id doesn't join sub-networks behind a power switch (parent_network does): the
--- accumulators are read from the parent, the interfaces only from the same sub-network. Join them by parent if a relay
--- ever sits behind a switch.
local function read(ep, nets)
	local eei = ep.data.eei
	local net = eei and eei.valid and eei.electric_network
	local parent = net and net.parent_network
	if not parent then
		return nil
	end
	local acc = parent.get_accumulators_energy(ALL)
	local g = { parent = parent, a = acc.energy, c = acc.capacity, ca = acc.capacity, ae = acc.energy, eps = {} }
	local id = eei.electric_network_id
	if nets then
		-- the drain task's tick: one pass over the endpoints groups them by network for every pool read this tick
		if not nets.by_id then
			local by_id = {}
			for _, o in pairs(storage.universal_edges.eps.power) do
				local x = o.data.eei
				local nid = x and x.valid and x.electric_network_id
				if nid then
					by_id[nid] = by_id[nid] or {}
					table.insert(by_id[nid], o)
				end
			end
			nets.by_id = by_id
		end
		for _, o in ipairs(nets.by_id[id]) do
			local x = o.data.eei
			g.eps[#g.eps + 1] = o
			g.a, g.c = g.a + x.energy, g.c + x.electric_buffer_size
		end
		return g
	end
	for _, o in pairs(storage.universal_edges.eps.power) do
		local x = o.data.eei
		if x and x.valid and x.electric_network_id == id then
			g.eps[#g.eps + 1] = o
			g.a, g.c = g.a + x.energy, g.c + x.electric_buffer_size
		end
	end
	return g
end

--- §8.2: a new total A2 (J) written back at one fill ratio over the pool.
local function write(g, A2)
	local r = A2 / g.c
	g.parent.set_accumulators_energy({ energy = r * g.ca, equalize = false })
	for _, o in ipairs(g.eps) do
		o.data.eei.energy = r * o.data.eei.electric_buffer_size
	end
end

--- What the group's links have been credited and have drained so far (kJ), and what they still owe the pool (J): D34's
--- drain excludes every link's credits and drain steps, not only this one's; A_eff leaves the debt out of the stock.
local function totals(g)
	local got, drained, debt = 0, 0, 0
	for _, o in ipairs(g.eps) do
		local d = o.data
		got, drained, debt = got + d.stats.got, drained + (d.stats.drained or 0), debt + (d.debt or 0)
	end
	return got, drained, debt
end

--- §8.4: put joules into the border pole's network's accumulators; returns what didn't fit.
local function to_accumulators(ep, joules)
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

--- §8.4: put a removed link's joules into the network's other pooled interfaces and the accumulators, at one fill ratio
--- as write does (this interface is about to go: it takes none); returns what fits nowhere. Without a network, the
--- border pole's accumulators alone.
local function to_pool(ep, joules)
	local g = read(ep)
	if not g then
		return to_accumulators(ep, joules)
	end
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
	end
	return joules - put
end

local function dropped(ep, joules)
	local kj = math.floor(joules / 1000)
	ep.data.stats.dropped = ep.data.stats.dropped + kj
	send("trace", { op = "ue.power", phase = "refund_dropped", level = "warn", tick = game.tick, trace = ep.trace,
		edge = ep.edge, cid = ep.cid, amount = kj })
end

local schedule = { per_tick = 4, interval = 60 }

--- Pay one tick of this link's debt (spike 22): its due share, from its own interface first (one read, one write of
--- eei.energy, no pool), and only what that can't cover from the pool, as much as it holds. The pool is read once a
--- tick per network (pools, by electric_network_id) and written back by drain_tick when the last link has paid, so links
--- sharing a pool cost one read and one write between them. A link whose network already has a pool this tick pays from
--- it, not from its interface: the pool's write would overwrite the interface's. A fast-path interface falls below the
--- pool's fill ratio; the next credit or pooled write re-levels it. True when nothing is owed.
function power.drain(ep, tick, pools)
	local d = ep.data
	local eei = d.eei
	local id = eei and eei.valid and eei.electric_network_id
	if not id then
		return false
	end
	local due = math.max(0, d.debt / math.max(1, d.debt_until - tick)) -- balance.drain_step with nothing capping it
	local paid = 0
	if not pools.g[id] then
		local own = eei.energy
		paid = math.min(due, own)
		if paid > 0 then
			eei.energy = own - paid
		end
	end
	if paid < due then
		local g = pools.g[id] or read(ep, pools.n and pools)
		if g then
			pools.g[id], pools.n = g, true -- from the second pool on, one pass groups the endpoints for all the reads
			local x = math.min(due - paid, g.a)
			if x > 0 then
				g.a, g.paid = g.a - x, true
				paid = paid + x
			end
		end
	end
	if paid > 0 then
		d.debt = d.debt - paid
		d.stats.drained = (d.stats.drained or 0) + paid / 1000
	end
	return d.debt < 1
end

local pools = { g = {} } -- reused every tick; drain_tick clears it

--- The drain task's tick: the links in storage.universal_edges.power_debt, which leave it when paid. A link that is gone,
--- closing or not ready leaves it too (its teardown settles what it owes; a rebuilt endpoint's poll enrols it again). With
--- nothing owed, a tick costs one next().
function power.drain_tick(tick)
	local set = storage.universal_edges.power_debt
	if next(set) == nil then
		return
	end
	pools.n, pools.by_id = nil, nil
	for id in pairs(pools.g) do
		pools.g[id] = nil
	end
	for key, ep in pairs(set) do
		local d = ep.data
		if ep.closing or ep.state ~= "ready" or (d.debt or 0) <= 0 then
			set[key] = nil
		else
			local ok, paid = connectors.call(ep, "drain", tick, pools)
			if not ok or paid then
				set[key] = nil
				if ok then
					d.debt = 0
				end
			end
		end
	end
	for _, g in pairs(pools.g) do
		if g.paid then
			write(g, g.a)
		end
	end
end

scheduler.periodic({ name = "ue.power.drain", interval = 1, fn = function(tick) return power.drain_tick(tick) end })

connectors.register_type({
	name = "power",
	lanes = function() return { ab = "stream", ba = "stream" } end,
	schedule = schedule,
	drain = power.drain,
	--- F9: adopts its interface, or creates it at local (col + 0.5, -0.5), inside the border pole's supply area (§8.2).
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
		d.stats = d.stats or { sent = 0, got = 0, dropped = 0, drained = 0 }
		d.debt = d.debt or 0
		d.a_last, d.drain = d.a_last or 0, d.drain or 0
		detect.adopt(ep)
		return "ready"
	end,
	--- F-PW2: when the partner's status arrived, so balance.partner can take off its drain since.
	on_status = function(ep)
		ep.data.seen = game.tick
	end,
	poll = function(ep, tick)
		detect.check(ep)
		propose_circuit(ep, tick) -- §6.1: before the network read, which returns early off-network
		local d, eei = ep.data, ep.data.eei
		local g = read(ep)
		if not g then
			return
		end
		local theirs = ep.partner and ep.partner.status
		-- D34 (plan ruling 18): size for the larger drain of the two sides; double while either was starved, which the
		-- credit latched (review C1). a_last is the pool at the last poll, and a send changes the pool only as the drain task
		-- steps it, so the pool's other moves since are no drain either: moved is what the group's links put into the pool
		-- since (kJ: credits less drain steps), none while there is no snapshot (an old save has gsent0 only). A side that
		-- sent at its last poll has no drain of its own (review I2).
		local got, drained, debt = totals(g)
		local moved = d.gdrained0 and (got - d.ggot0) - (drained - d.gdrained0) or 0
		local bl, el = eei.electric_buffer_size, eei.energy
		local dry = d.starved == true
		local B2
		B2, d.drain = balance.size(bl, el, g.a, d.a_last, moved, theirs, dry, d.fed, d.grown and tick - d.grown)
		d.starved, d.fed = nil, nil
		if B2 > bl then
			d.grown = tick -- #8: held at this size for balance.HOLD ticks
		end
		if B2 ~= bl then
			eei.electric_buffer_size = B2
			g.c, bl = g.c + B2 - bl, B2
		end
		local A, C = math.max(0, g.a - debt) / 1000, g.c / 1000 -- what the pool will hold once its debt is paid
		local st = ep.status
		-- A loaded link exchanges 3 to 4 messages a period, both ways: statuses, an offer and its ack (Task 8 reports it).
		if not st or math.abs(A - st.a) >= C / 64 or st.r ~= d.stats.got or st.dry ~= dry
			or math.abs((st.d or 0) - d.drain) > bl / 8 then
			ep:set_status({ a = math.floor(A), c = math.floor(C), r = d.stats.got, d = d.drain, dry = dry })
		end
		d.a_last, d.gdrained0, d.ggot0 = g.a, drained, got
		if (d.debt or 0) > 0 then
			storage.universal_edges.power_debt[ep.key] = ep -- a rebuilt endpoint, or an old save's, owing still
		end
		local dir = out_dir(ep)
		-- A remainder the partner refused re-offers as soon as its status shows room; with none, the lane's backoff
		-- spaces the re-offers out, 300 to 3600 ticks (final fix wave addendum).
		if theirs and theirs.c and not ep:idle(dir) and balance.has_room(theirs) then
			ep:nudge(dir)
		end
		if not (theirs and theirs.c and ep:idle(dir) and ep:can_send(dir)) then
			return
		end
		-- #8: the share is of the pool's link interfaces (g.c - g.ca), not of C with its accumulators
		local a = balance.amount(A, C, balance.partner(theirs, d.stats.sent, tick - (d.seen or tick)), theirs.c, bl / 1000,
			(g.c - g.ca) / 1000)
		if a > 0 then
			ep:send(dir, { [KEY] = a }) -- first: a refused send (MAX_TOTAL) raises before anything is owed
			d.stats.sent, d.fed = d.stats.sent + a, true
			d.debt, d.debt_until = (d.debt or 0) + 1000 * a, tick + schedule.interval
			storage.universal_edges.power_debt[ep.key] = ep
		end
	end,
	--- T2: add only what fits, at one fill ratio, and credit exactly that.
	credit = function(ep, _, bag)
		local g = read(ep)
		-- #8: the link interfaces only; accumulators give back at 300 kW each, so with a credit spread at one fill ratio
		-- they kept the pool above 1 % while the load starved, and the buffer stopped doubling (100 MW: 14 polls, not 9)
		if g and balance.starving(g.a - g.ae - select(3, totals(g)), g.c - g.ca, ep.partner and ep.partner.status) then
			ep.data.starved = true -- before adding: this side ran dry while its partner had energy (review C1)
		end
		local x = g and math.min(bag[KEY] or 0, math.floor((g.c - g.a) / 1000)) or 0
		if x <= 0 then
			return { [KEY] = 0 }
		end
		write(g, g.a + 1000 * x)
		ep.data.stats.got = ep.data.stats.got + x
		return { [KEY] = x }
	end,
	--- §8.4: what the link still owes the pool is removed at once, as much as the pool holds (energy sent and not removed
	--- is created if it can't be paid: logged). Then the interface's energy goes into the network's other interfaces and
	--- the accumulators before the interface goes; what fits nowhere, up to the whole 10 GJ buffer beside small or full
	--- accumulators (D37), is dropped and logged.
	teardown = function(ep)
		local d, eei = ep.data, ep.data.eei
		storage.universal_edges.power_debt[ep.key] = nil
		local owed = d.debt or 0
		d.debt = 0
		if owed > 0 then
			local g = read(ep)
			local x = g and math.min(owed, g.a) or 0
			if x > 0 then
				write(g, g.a - x)
				d.stats.drained = (d.stats.drained or 0) + x / 1000
			end
			if owed - x >= 1 then
				send("trace", { op = "ue.power", phase = "debt_unpaid", level = "warn", tick = game.tick, trace = ep.trace,
					edge = ep.edge, cid = ep.cid, amount = (owed - x) / 1000 })
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
	--- §8.4, T5 bent on purpose: what the link still owes is cancelled first (that energy never left the pool); the
	--- rest goes back into the border pole's accumulators, and what doesn't fit is dropped and logged.
	refund = function(ep, _, bag)
		local d, joules = ep.data, (bag[KEY] or 0) * 1000
		local cancel = math.min(d.debt or 0, joules)
		if cancel > 0 then
			d.debt = d.debt - cancel
		end
		local left = to_accumulators(ep, joules - cancel)
		if left > 0 then
			dropped(ep, left)
		end
		return true
	end,
})

return power
