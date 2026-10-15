-- The circuit connector type (circuit-link spec, docs/superpowers/specs/2026-10-04-ue-circuit-link-design.md): a border
-- pole's red and green networks joined across the edge, colour by colour. Each side reads its pole and subtracts what its
-- own injector put there (§7.2); what changed leaves in its status, as a change on the version before or, at a handshake
-- and on ask, the full form (§8.2, FC5). The other side folds each status into its mirror as it arrives (§8.3), and its
-- write task writes the changed slots of a hidden combinator wired to its pole, at most B a tick (§7.4, K16). b′ (§7.7)
-- keeps one edge's links a forest, computed once per side per period (K15). Nothing is conserved: no lanes (K1).
local bridge = require("modules/universal_edges/runtime/bridge")
local scheduler = require("modules/universal_edges/runtime/scheduler")
local connectors = require("modules/universal_edges/edges/connectors")
local geometry = require("modules/universal_edges/edges/geometry_core")
local detect = require("modules/universal_edges/transports/detect")
local core = require("modules/universal_edges/transports/circuit_core")
local rcore = require("modules/universal_edges/transports/radar_core")

--- P: the poll period (C4, K14); B: slots written a tick per instance (K16: the one constant the bench may tune); ASK: a
--- gap's ask throttle (K17).
local circuit = { P = 60, B = 300, ASK = 120 }
local COLOURS = core.COLOURS
local W = { r = defines.wire_connector_id.circuit_red, g = defines.wire_connector_id.circuit_green }
local Y = { r = -1.5, g = -2.5 } -- K6: the injectors' local y, outside the border
local GROUP, CARRY = { r = "gr", g = "gg" }, { r = "cr", g = "cg" }
local KEYS, QUIET = { r = "kr", g = "kg" }, { r = "qr", g = "qg" } -- guard 6.1 (radar-sync spec §6.1)
local send = bridge.channel("universal_edges")
local SLOTS, SECTIONS = 1000, 2 -- T2a: slots a section holds, sections an injector has (K8's 2,000 a colour)

--- A ue.circuit or ue.connector line (§12): signals never enter one.
local function event(ep, op, phase, level, fields)
	fields.op, fields.phase, fields.level, fields.tick = op, phase, level, game.tick
	fields.edge, fields.cid, fields.trace = ep.edge, ep.cid, ep.trace
	send("trace", fields)
end

--- §6.2 step 2: the endpoint's fields, when absent. A status can arrive before the first build (FC5), and the edge can go
--- down before it (FC4), so every hook runs this first (plan ruling 13).
local function init(d)
	if d.inj == nil then
		for k, v in pairs(core.data()) do
			d[k] = v
		end
	end
end

local function quality_ok(q)
	return prototypes.quality[q] ~= nil
end

--- §8.5's check at the write, as core.write's valid: the name exists among its type's prototypes and isn't a special
--- virtual signal. A failure is counted in d.stats, and warn(fields) logs it once per d and signal (plan ruling 14). The
--- radar's hosts use it too (radar-sync plan Task 4).
function circuit.checker(d, warn)
	return function(t, q, n)
		local p = prototypes[core.TYPES[t]][n]
		if p and not (t == "virtual" and p.special) then
			return true
		end
		d.stats.dropped = d.stats.dropped + 1
		local key = t .. "|" .. q .. "|" .. n
		if not d.logged[key] then
			d.logged[key] = true
			warn({ type = t, name = n, quality = q })
		end
		return false
	end
end

--- §7.4: one colour's script wire, which a player can't cut, from an injector to the pole. Distance doesn't matter.
local function wire(comb, pole, c)
	comb.get_wire_connector(W[c], true).connect_to(pole.get_wire_connector(W[c], true), false, defines.wire_origin.script)
end

--- T2a: the API refuses a slot past 1,000 in a section, so an injector has SECTIONS of them and flat slot i (1..2,000,
--- the core's numbering) is slot i - 1000 * (s - 1) of section s = ceil(i / 1000). Returns that section's number and slot.
local function section_at(i)
	local s = math.ceil(i / SLOTS)
	return s, i - SLOTS * (s - 1)
end

--- 1B: Lua's copy of colour c's section s filters (ep.data.fl[c][s]), which the write task edits and writes (apply). It is
--- indexed by slot with {} for an empty one (2.1's read returns that, and an assignment of it keeps the slots; a nil gap
--- would squeeze them together), and ends at the highest filled slot. Missing (an injector from before this, or after a
--- load): read once from the section. A new injector forgets it, FC4 empties it.
local function copy_of(d, c, cb, s)
	d.fl = d.fl or { r = {}, g = {} }
	local copy = d.fl[c][s]
	if not copy then
		copy = cb.get_section(s).filters
		d.fl[c][s] = copy
	end
	return copy
end

--- 1B: colour c's injector and its record disagree (a new injector, or an assignment that raised): forget the slot map and
--- the copies, and put every signal of the mirror back in todo so the write task writes the colour again in full.
local function rewrite(d, c)
	d.inj[c], d.slot[c], d.free[c], d.todo[c] = {}, {}, {}, {}
	d.ninj[c], d.top[c] = 0, 0
	if d.fl then
		d.fl[c] = {}
	end
	core.mark_all(d.todo[c], d.far[c])
end

--- K6, §7.4: a ue-link-combinator at (x, y) on surface for force, wired by script to target (a border pole, or a radar
--- host: radar-sync spec §4) on colour c only, each section's multiplier 1. A nil from create_entity raises.
function circuit.make_injector(surface, x, y, force, target, c)
	local comb = surface.create_entity({ name = "ue-link-combinator", position = { x, y }, force = force,
		create_build_effect_smoke = false })
	if not comb then
		error("ue-link-combinator not created at " .. x .. ", " .. y)
	end
	comb.destructible = false
	wire(comb, target, c)
	local cb = comb.get_or_create_control_behavior()
	for i = 1, SECTIONS do
		local section = cb.get_section(i) or cb.add_section()
		section.multiplier = 1
	end
	return comb
end

--- K6: colour c's injector, made on first use just outside the border at the pole's column, on the pole's force
--- (§7.4). A raise fails this endpoint only (G6).
local function injector(ep, c)
	local d = ep.data
	local comb = d.comb[c]
	if comb and comb.valid then
		return comb
	end
	local pole = d.border
	local x, y = geometry.to_world(ep.frame, ep.col + 0.5, Y[c])
	comb = circuit.make_injector(pole.surface, x, y, pole.force, pole, c)
	d.comb[c], d.unit = comb, pole.unit_number
	rewrite(d, c)
	event(ep, "ue.circuit", "wired", "info", { colour = c, pole = pole.unit_number })
	return comb
end

--- §7.4: a link with signals to write joins the write set (FC6).
local function enrol(ep)
	local d = ep.data
	if next(d.todo.r) ~= nil or next(d.todo.g) ~= nil then
		storage.universal_edges.circuit_writing[ep.key] = ep
	end
end

--- §7.4, §6.3: both injectors onto a successor pole (an upgrade or a fast-replace).
local function rewire(ep, pole)
	local d = ep.data
	for _, c in ipairs(COLOURS) do
		local comb = d.comb[c]
		if comb and comb.valid then
			wire(comb, pole, c)
			event(ep, "ue.circuit", "wired", "info", { colour = c, pole = pole.unit_number })
		end
	end
	d.unit = pole.unit_number
end

--- K8's warn, once until the colour fits again.
local function truncated(ep, d, c, dropped)
	if dropped > 0 and not d.trunc[c] then
		d.trunc[c] = true
		event(ep, "ue.circuit", "truncated", "warn", { colour = c, kept = d.nout[c], dropped = dropped })
	elseif dropped == 0 then
		d.trunc[c] = nil
	end
end

--- §7.5 steps 7–8: read each carrying colour, compare network − inj with out, and set the status when a remainder or a
--- group changed: the change, or the full form when that is no bigger (§8.2). F13 sends it at the end of this visit.
local function changes(ep, d, pole, g)
	local fresh, chg
	for _, c in ipairs(COLOURS) do
		if g[CARRY[c]] then
			-- ponytail: spike 29's rule: after a read at R, get_signals_changed(wire, R) is false exactly when nothing changed.
			local rt = d.rt and d.rt[c]
			if rt and pole.get_signals_changed(W[c], rt) == false then
				d.stats.skipped = (d.stats.skipped or 0) + 1
			else
				d.rt = d.rt or {}
				d.rt[c] = game.tick
				local net = pole.get_circuit_network(W[c])
				local sigs = net and net.signals
				if not core.unchanged(sigs, d.inj[c], d.ninj[c], d.out[c], d.nout[c]) then
					fresh = fresh or {}
					local rem, ch, k, n = core.remainder_diff(sigs, d.inj[c], d.ninj[c], d.out[c], d.nout[c])
					chg = chg or {}
					fresh[c], chg[c] = rem, { ch, k, n }
				end
			end
		else
			if d.rt then
				d.rt[c] = nil -- out[c] changes without a read below: the next carry must read
			end
			if d.nout[c] > 0 then
				fresh = fresh or {}
				fresh[c] = {} -- a quiet colour's remainder is empty (§7.5 step 5)
			end
		end
	end
	local regroup = g.gr ~= d.gr or g.gg ~= d.gg or g.kr ~= d.kr or g.kg ~= d.kg -- guard 6.1's keys travel as groups do
	if not (fresh or regroup) then
		return
	end
	local old, pre = {}, {}
	if fresh then
		local r, gg, dr, dg = core.fit(fresh.r or d.out.r, fresh.g or d.out.g)
		local kept, dropped = { r = r, g = gg }, { r = dr, g = dg }
		for _, c in ipairs(COLOURS) do
			if kept[c] ~= d.out[c] then
				local pc = chg and chg[c]
				local whole = pc and kept[c] == fresh[c] -- fit kept it whole: remainder_diff's change and size hold
				if whole then
					pre[c] = { pc[1], pc[2] }
				end
				old[c], d.out[c], d.nout[c] = d.out[c], kept[c], whole and pc[3] or core.size(kept[c])
			end
			if fresh[c] then
				truncated(ep, d, c, dropped[c])
			end
		end
	end
	local st, k = core.status(d.v + 1, g.gr, g.gg, d.out, old, d.nout.r + d.nout.g, pre)
	if k == 0 and not regroup then
		return -- the remainder came back the same: an over-cap network re-sorted to the same signals
	end
	st.kr, st.kg = g.kr, g.kg -- guard 6.1: this side's radar keys, per colour
	d.v, d.gr, d.gg, d.kr, d.kg = d.v + 1, g.gr, g.gg, g.kr, g.kg
	d.stats.sent = d.stats.sent + 1
	ep:set_status(st)
end

local links, scratch = {}, {} -- b′'s records and scratch: filled and read within one compute
local rkeys = { r = {}, g = {} } -- guard 6.1's scratch: network id → this tile's radar keys on it, filled per compute
local function by_cid(a, b)
	return a.cid < b.cid
end

--- Guard 6.1 (radar-sync spec §6.1): rkeys[c][network id] = the keys of this tile's radar hosts on that network,
--- joined (radar_core.join). Two reads a host; nothing when the tile hosts none.
-- ponytail: a few small tables a compute while the tile hosts radars; keep them across computes if that ever shows.
local function radar_keys()
	for _, c in ipairs(COLOURS) do
		for id in pairs(rkeys[c]) do
			rkeys[c][id] = nil
		end
	end
	local hosts = storage.universal_edges.radar.hosts
	if next(hosts) == nil then
		return
	end
	for key, h in pairs(hosts) do
		if h.radar.valid then
			for _, c in ipairs(COLOURS) do
				local net = h.radar.get_circuit_network(W[c])
				if net then
					local list = rkeys[c][net.network_id] or {}
					rkeys[c][net.network_id] = list
					list[#list + 1] = key
				end
			end
		end
	end
	for _, c in ipairs(COLOURS) do
		for id, list in pairs(rkeys[c]) do
			rkeys[c][id] = rcore.join(list)
		end
	end
end

--- K15: b′ for every circuit link of this edge side (list[1..n], from this poll's walk), stored in place in each link's
--- data.guard = { tick, gr, gg, cr, cg, kr, kg, qr, qg }: one get_circuit_network and network_id read per link and
--- colour, so 2n a period per side. Guard 6.1: a colour whose two ends name a radar key in common is joined already, so
--- the link leaves that colour's forest (its far group is ignored) and is quiet (plan ruling 9). In storage, not a
--- file-local: it decides what each link injects.
function circuit.compute(list, n, tick)
	radar_keys()
	for i = 1, n do
		local e = list[i]
		local l = links[i] or {}
		links[i] = l
		local pole = e.data.border
		local valid = pole ~= nil and pole.valid
		local nr = valid and pole.get_circuit_network(W.r)
		local ng = valid and pole.get_circuit_network(W.g)
		local p = e.partner
		local st = p and p.status
		l.ep, l.cid, l.pole = e, e.cid, valid
		l.arc = e.state == "ready" and not e.closing and p ~= nil and p.state == "ready"
		l.ir, l.ig = nr and nr.network_id or nil, ng and ng.network_id or nil
		l.fr, l.fg = st and st.gr or nil, st and st.gg or nil
		l.kr = nr and rkeys.r[nr.network_id] or nil
		l.kg = ng and rkeys.g[ng.network_id] or nil
		l.qr, l.qg = rcore.common(l.kr, st and st.kr), rcore.common(l.kg, st and st.kg)
		if l.qr then
			l.fr = nil
		end
		if l.qg then
			l.fg = nil
		end
	end
	for i = #links, n + 1, -1 do
		links[i] = nil
	end
	table.sort(links, by_cid)
	core.group(links, n, "ir", "gr", scratch)
	core.group(links, n, "ig", "gg", scratch)
	local off = storage.universal_edges.circuit_noguard -- a test seam (plan Task 5): b′ off on one side of one edge
	if off and off[list[1].edge] then
		for i = 1, n do
			local l = links[i]
			l.cr = l.arc and l.gr ~= nil and l.fr ~= nil
			l.cg = l.arc and l.gg ~= nil and l.fg ~= nil
		end
	else
		core.forest(links, n, "gr", "fr", "cr", scratch)
		core.forest(links, n, "gg", "fg", "cg", scratch)
	end
	for i = 1, n do
		local l = links[i]
		local d = l.ep.data
		local g = d.guard or {}
		d.guard = g
		for _, c in ipairs(COLOURS) do
			if l[QUIET[c]] and not g[QUIET[c]] then
				event(l.ep, "ue.radar", "loop_quiet", "info", { colour = c, keys = l[KEYS[c]] })
			end
		end
		g.tick, g.gr, g.gg, g.cr, g.cg = tick, l.gr, l.gg, l.cr, l.cg
		g.kr, g.kg, g.qr, g.qg = l.kr, l.kg, l.qr, l.qg
	end
end

local sibs = {} -- this edge side's circuit links, from each poll's walk (§7.5 step 2): filled and read within one poll

--- The lowest-cid link of this side carrying colour c in g's group, for the quiet and carrying lines (plan ruling 3).
local function carrier(n, g, c)
	local best
	for i = 1, n do
		local o = sibs[i].data.guard
		if o and o[GROUP[c]] == g[GROUP[c]] and o[CARRY[c]] and (best == nil or sibs[i].cid < best) then
			best = sibs[i].cid
		end
	end
	return best
end

--- §7.5, in order. The reads (step 7) come before any write of this link's injectors in the same tick, or are skipped
--- (step 6): K2.
local function poll(ep, tick)
	local d = ep.data
	init(d)
	if d.removal then
		return -- asked for removal (C8); the controller's update closes this endpoint (plan ruling 9)
	end
	local had = d.border ~= nil
	detect.check(ep) -- 1
	if had and d.border == nil then
		return -- the pole went with no successor: removal requested (R16)
	end
	local side = storage.universal_edges.edges[ep.edge]
	local n, power = 0, nil
	for cid, type_name in pairs(side.eps) do -- 2: the edge's circuit links for b′, and this pole's power link (C8)
		if type_name == "circuit" then
			n = n + 1
			sibs[n] = connectors.get(side, cid)
		elseif type_name == "power" then
			local p = connectors.get(side, cid)
			if p and p.col == ep.col and p.width == ep.width then
				power = p
			end
		end
	end
	for i = #sibs, n + 1, -1 do
		sibs[i] = nil
	end
	if not power or power.closing then
		d.removal = true
		ep:request_removal("no_power")
		event(ep, "ue.connector", "removal_requested", "info", { reason = "no_power" })
		return
	end
	local pole = d.border
	if not (pole and pole.valid) then
		return -- 3: no pole yet; statuses still fold as they arrive (§6.5)
	end
	if d.unit and d.unit ~= pole.unit_number then
		rewire(ep, pole) -- 4: a successor; its wires show next tick, so this poll reads nothing (K2, review I-2)
		return
	end
	local g = d.guard
	if not g or tick - g.tick >= circuit.P then
		circuit.compute(sibs, n, tick) -- 5: b′ for every link of this side, once a period (K15)
		g = d.guard
	end
	if d.wtick ~= tick then
		changes(ep, d, pole, g) -- 7–8; 6: skipped when a batch of this link's injectors was written earlier this tick
	end
	for _, c in ipairs(COLOURS) do -- 9
		local carry = g[CARRY[c]] == true
		if carry ~= d.carry[c] then
			core.mark_all(d.todo[c], d.far[c])
			core.mark_all(d.todo[c], d.inj[c])
			d.carry[c] = carry
			event(ep, "ue.circuit", carry and "carrying" or "quiet", "info", { colour = c, carrier = carrier(n, g, c) })
		end
	end
	enrol(ep)
	if d.gap then
		ep:ask_partner(circuit.ASK)
	end
end

--- 1B: section's Lua copy into the injector, once. A section whose walk touched one slot j writes that slot alone, by
--- set_slot or clear_slot, which costs less than the assignment at every size (radar perf P1, in place on a wired
--- ue-link-combinator: 0.24–0.98 ms a slot against 0.69–1.40 ms an assignment, at 1,000–2,000 filters); any other is
--- assigned whole.
local function apply(section, copy, j)
	if j == 0 then
		section.filters = copy
	elseif copy[j] and copy[j].value then
		section.set_slot(j, copy[j])
	else
		section.clear_slot(j)
	end
end

--- K5, K16, 1B: at most budget slots of d's colours, each towards its target (the mirror d.far[c] while d.carry[c],
--- else nothing), into the injector comb_for(c) returns. It is asked before the colour's walk, since a new injector
--- resets the colour's slot map and todo (rewrite). valid is circuit.checker's. Returns the slots written, and sets
--- d.wtick when any (K2). The circuit link's write hook runs it, and so do the radar's hosts (radar-sync plan ruling 2).
function circuit.write_colours(d, budget, tick, comb_for, valid)
	local used = 0
	for _, c in ipairs(COLOURS) do
		if used < budget and next(d.todo[c]) ~= nil then
			-- asked before the walk: a new injector resets the colour's slot map and todo, which the walk holds
			local cb = comb_for(c).get_control_behavior()
			-- 1B: the callbacks edit Lua's copy; each touched section is written once, after the walk (or the raise).
			-- touched[s] is the slot while it is the only one the walk wrote in section s, else 0 (inline: per slot).
			local touched = {}
			local ok, got = pcall(core.write, d, c, budget - used, d.carry[c], valid,
				function(i, t, q, n, count)
					local s, j = section_at(i)
					local copy = copy_of(d, c, cb, s)
					for k = #copy + 1, j - 1 do
						copy[k] = {}
					end
					copy[j] = { value = { type = t, name = n, quality = q }, min = count }
					local was = touched[s]
					touched[s] = (was == nil or was == j) and j or 0
				end,
				function(i)
					local s, j = section_at(i)
					local copy = copy_of(d, c, cb, s)
					if j > #copy then
						return -- nothing there to clear
					end
					copy[j] = {}
					while #copy > 0 and next(copy[#copy]) == nil do
						copy[#copy] = nil
					end
					local was = touched[s]
					touched[s] = (was == nil or was == j) and j or 0
				end)
			for s, j in pairs(touched) do
				local aok, aerr = pcall(function() apply(cb.get_section(s), d.fl[c][s], j) end)
				if not aok then
					-- the section may not hold the copy: empty both, and write the colour again from the mirror
					for k = 1, SECTIONS do
						cb.get_section(k).filters = {}
					end
					rewrite(d, c)
					ok, got = false, ok and aerr or got
					break
				end
			end
			if not ok then
				error(got, 0)
			end
			used = used + got
		end
	end
	if used > 0 then
		d.wtick = tick -- K2: this link's poll reads nothing in this tick (§7.5 step 6)
	end
	return used
end

connectors.register_type({
	name = "circuit",
	border = "power", -- detection adopts and checks electric poles (§5.2)
	big_status = true, -- FC3
	lanes = function() return {} end, -- nothing is conserved (K1)
	schedule = { per_tick = 4, interval = circuit.P }, -- K14
	--- F9: idempotent; ready with or without a pole, since the far side may not have one yet (K11, §6.5).
	build = function(ep)
		init(ep.data)
		detect.adopt(ep)
		return "ready"
	end,
	poll = poll,
	--- §6.4, K12: both injectors go, and the link leaves the write set; nothing to refund.
	teardown = function(ep)
		for _, c in ipairs(COLOURS) do
			local comb = ep.data.comb and ep.data.comb[c]
			if comb and comb.valid then
				comb.destroy()
			end
		end
		storage.universal_edges.circuit_writing[ep.key] = nil
	end,
	--- FC5: the whole of out, at this side's version, with the groups and guard 6.1's radar keys last sent.
	full_status = function(ep)
		local d = ep.data
		init(d)
		local st = core.full(d.v, d.gr, d.gg, d.out)
		st.kr, st.kg = d.kr, d.kg
		return st
	end,
	--- FC5, K17: fold each arriving status into the mirror, writing no entity (K2); a gap asks, at most once per 120 ticks.
	on_status = function(ep, status)
		local d = ep.data
		init(d)
		local drop = storage.universal_edges.circuit_drop -- the E2E's lost status (circuit_seams "drop")
		if drop and drop[ep.key] then
			drop[ep.key] = nil
			return
		end
		local epoch = storage.universal_edges.edges[ep.edge].epoch
		local result, bad = core.fold(d, status, epoch, quality_ok)
		if bad > 0 then
			d.stats.dropped = d.stats.dropped + bad
			if d.logged.malformed ~= epoch then
				d.logged.malformed = epoch
				event(ep, "ue.circuit", "malformed", "warn", {})
			end
		end
		if result == "gap" then
			d.stats.gaps = d.stats.gaps + 1
			if ep:ask_partner(circuit.ASK) then
				event(ep, "ue.circuit", "gap", "info", { base = status.base, have = d.far_v })
			end
		elseif result == "full" or result == "change" then
			d.stats.applied = d.stats.applied + 1
		end
		enrol(ep)
	end,
	--- FC4 (C5 b): the edge went down: both sections empty in one write each, and the partner's part forgotten.
	deactivated = function(ep)
		local d = ep.data
		init(d)
		for _, c in ipairs(COLOURS) do
			local comb = d.comb[c]
			if comb and comb.valid then
				local cb = comb.get_control_behavior()
				for s = 1, SECTIONS do
					cb.get_section(s).filters = {}
				end
				d.fl = d.fl or { r = {}, g = {} }
				d.fl[c] = { {}, {} }
			end
		end
		core.reset(d)
		storage.universal_edges.circuit_writing[ep.key] = nil
	end,
	--- K5, K16: at most budget slots of this link, each colour towards its target; the write task calls it.
	write = function(ep, budget, tick)
		local valid = circuit.checker(ep.data, function(fields) event(ep, "ue.circuit", "unknown_signal", "warn", fields) end)
		return circuit.write_colours(ep.data, budget, tick, function(c) return injector(ep, c) end, valid)
	end,
})

--- K16: one tick's writes, at most circuit.B slots across the write set (FC6), in its order: circuit links, and the radar
--- sync's hosts (kind = "radar"), whose step radar.lua sets as circuit.host_write (radar-sync plan ruling 2). A link that
--- isn't ready, is closing, has no pole, or whose pole was replaced and not yet rewired (plan ruling 10) leaves the set;
--- its poll enrols it again (§7.5 step 9). The game tests and the bench wrap this function.
function circuit.write_tick(tick)
	local set = storage.universal_edges.circuit_writing
	if next(set) == nil then
		return
	end
	return core.drain(set, circuit.B, function(ep, left)
		if ep.kind == "radar" then
			return circuit.host_write(ep, left, tick)
		end
		local d, pole = ep.data, ep.data.border
		if ep.closing or ep.state ~= "ready" or not (pole and pole.valid) or (d.unit and d.unit ~= pole.unit_number) then
			return 0, true
		end
		local ok, used = connectors.call(ep, "write", left, tick)
		if not ok then
			return 0, true
		end
		return used, next(d.todo.r) == nil and next(d.todo.g) == nil
	end)
end

-- §11, SP3 §13 rule 1: with nothing to write, a tick costs one next().
scheduler.periodic({ name = "ue.circuit.write", interval = 1, fn = function(tick) return circuit.write_tick(tick) end })

return circuit
