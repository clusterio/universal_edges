-- The radar sync (radar-sync spec, docs/superpowers/specs/2026-10-06-ue-radar-sync-design.md): every radar network a
-- tile's real radars use (a planet's surface-mode network, or a universe channel) gets a hidden host radar at the spawn
-- position with an injector per colour (§4). Each host's poll reads its network, subtracts its own injectors and sends
-- what changed to the controller (§5; circuit §7.1–7.4 and §8). The controller's targets fold into the host's mirror as
-- they arrive, and the circuit link's write task writes them in its one budget (plan ruling 2). A discovery every 10 s
-- makes and removes hosts (§4's hosting rule); guard 6.2 keeps two hosts on one network from reporting it twice (§6.2).
local bridge = require("modules/universal_edges/runtime/bridge")
local scheduler = require("modules/universal_edges/runtime/scheduler")
local circuit = require("modules/universal_edges/transports/circuit")
local cc = require("modules/universal_edges/transports/circuit_core")
local core = require("modules/universal_edges/transports/radar_core")

--- P: the poll period (§5: circuit C4); DISCOVER: the hosting poll (§4); ASK: a gap's ask throttle (circuit K17);
--- CHUNK: one ue.radar.chunk part's bytes (circuit FC3).
local radar = { P = 60, DISCOVER = 600, ASK = 120, CHUNK = 3000 }
local COLOURS = cc.COLOURS
local W = { r = defines.wire_connector_id.circuit_red, g = defines.wire_connector_id.circuit_green }
local RM = defines.control_behavior.radar.mode
local PLUGIN = "universal_edges"
local send = bridge.channel(PLUGIN)

local function hosts()
	return storage.universal_edges.radar.hosts
end

--- A ue.radar line (§8): signals never enter one.
local function event(h, phase, level, fields)
	fields.op, fields.phase, fields.level, fields.tick, fields.key = "ue.radar", phase, level, game.tick, h.key
	send("trace", fields)
end

local function quality_ok(q)
	return prototypes.quality[q] ~= nil
end

--- §5: this host's own signals to the controller as status st (a change, or the full form). A body over CHUNK bytes
--- leaves as ue.radar.chunk parts keyed <key>/<seq>, then ue.radar.own with chunks = n (plan ruling 12), so nothing
--- reaches Clusterio's unordered ≥ 4000-byte file path.
local function report(h, st)
	st.key = h.key
	local json = helpers.table_to_json(st)
	if storage.universal_edges.stream_trace then
		event(h, "own", "verbose", { v = st.v, base = st.base, bytes = #json }) -- counts only, never signals
	end
	if #json <= radar.CHUNK then
		send("ue.radar.own", st)
		return
	end
	h.seq = (h.seq or 0) + 1
	local n, key = math.ceil(#json / radar.CHUNK), h.key .. "/" .. h.seq
	for i = 1, n do
		send("ue.radar.chunk", { key = key, i = i, n = n, data = string.sub(json, (i - 1) * radar.CHUNK + 1, i * radar.CHUNK) })
	end
	send("ue.radar.own", { key = h.key, chunks = n, seq = h.seq })
end

--- §5: ask the controller for this host's full target, at most once per ASK ticks. True when it asked.
local function ask(h)
	local tick = game.tick
	if h.asked and tick - h.asked < radar.ASK then
		return false
	end
	h.asked = tick
	send("ue.radar.ask", { key = h.key })
	return true
end

--- A host with slots to write joins the circuit link's write set (plan ruling 2).
local function enrol(h)
	if next(h.todo.r) ~= nil or next(h.todo.g) ~= nil then
		storage.universal_edges.circuit_writing[h.wkey] = h
	end
end

--- §4: a host for key at surface's spawn position: a ue-link-radar on the player force in key's mode (channel for a
--- universe key) and its two injectors (plan ruling 6). It asks for its full target at once.
local function host(key, surface, channel)
	local force = game.forces.player
	local pos = force.get_spawn_position(surface)
	if not surface.is_chunk_generated({ math.floor(pos.x / 32), math.floor(pos.y / 32) }) then
		surface.request_to_generate_chunks(pos, 0)
		return nil -- the next discovery (10 s) hosts it once the chunk exists; an entity made before generation may not survive it
	end
	local e = surface.create_entity({ name = "ue-link-radar", position = pos, force = force,
		create_build_effect_smoke = false })
	if not e then
		event({ key = key }, "host_failed", "error", { surface = surface.name })
		return nil -- discovery tries again in 10 s: no host is registered
	end
	e.destructible = false
	local cb = e.get_or_create_control_behavior() -- R1: a radar joins a network only once it has one
	if channel then
		cb.mode, cb.universe_channel = RM.universe, channel
	else
		cb.mode = RM.surface
	end
	local h = cc.data()
	h.kind, h.key, h.wkey, h.radar = "radar", key, "radar:" .. key, e
	h.carry = { r = true, g = true }
	for _, c in ipairs(COLOURS) do
		h.comb[c] = circuit.make_injector(surface, pos.x, pos.y, force, e, c)
	end
	hosts()[key] = h
	event(h, "host", "info", { surface = surface.name })
	ask(h)
	return h
end

--- §4: the last real radar of h's key went: own reported empty (unhost), the injectors and the host destroyed.
local function unhost(h)
	send("ue.radar.unhost", { key = h.key })
	for _, c in ipairs(COLOURS) do
		local e = h.comb[c]
		if e and e.valid then
			e.destroy()
		end
	end
	if h.radar.valid then
		h.radar.destroy()
	end
	storage.universal_edges.circuit_writing[h.wkey] = nil
	hosts()[h.key] = nil
	event(h, "unhost", "info", {})
end

--- §4's hosting rule, every DISCOVER ticks: a key is hosted while a real radar of the player force uses it, in surface
--- mode on a planet's surface or on a universe channel on any surface (plan rulings 3–5). The game tests call it.
function radar.discover()
	local want = {}
	local state = storage.universal_edges.radar
	if not state.known then
		-- ponytail: one full scan seeds the registry (5–10 ms once, on the first discovery after a deploy or an old save);
		-- a radar a script makes without raising script_raised_built is missed from then on, and nothing rescans.
		state.known = {}
		for _, s in pairs(game.surfaces) do
			for _, e in pairs(s.find_entities_filtered({ type = "radar", force = "player" })) do
				if e.name ~= "ue-link-radar" then
					state.known[e.unit_number] = e
				end
			end
		end
	end
	for unit, e in pairs(state.known) do
		if not e.valid then
			state.known[unit] = nil
		else
			local s = e.surface
			local cb = e.get_or_create_control_behavior() -- plan ruling 5
			if cb then -- documented to return nil as well; such a radar is skipped
				local universe = cb.mode == RM.universe
				local channel = universe and cb.universe_channel or nil
				local key = core.key(universe, s.planet and s.planet.name, channel)
				if key and not want[key] then
					want[key] = { surface = universe and game.surfaces.nauvis or s, channel = channel }
				end
			end
		end
	end
	for key, h in pairs(hosts()) do
		if not want[key] then
			unhost(h)
		end
	end
	for key, w in pairs(want) do
		if not hosts()[key] then
			host(key, w.surface, w.channel)
		end
	end
end

--- A build (or clone) of a real player radar joins the registry; before the seed scan the scan finds it.
function radar.on_built(e)
	local ent = e.entity or e.destination
	local known = storage.universal_edges.radar.known
	if known and ent and ent.valid and ent.type == "radar" and ent.force.name == "player" and ent.name ~= "ue-link-radar" then
		known[ent.unit_number] = ent
	end
end

-- ponytail: twins circuit.lua's `changes` (this one over a host, that one over a link endpoint); merge if a third appears.
--- §5 steps 1–3 for both colours (circuit §7.5 steps 7–8): own = network − injectors, compared with what was last
--- sent; on a change, the change (or the full form when no bigger) goes up. A merged colour (6.2) reports nothing: its
--- lead reports the network, less both injectors.
local function changes(h, nets)
	local fresh, chg
	for _, c in ipairs(COLOURS) do
		local x = nets[c]
		if x.lead then
			if h.rt then
				h.rt[c] = nil -- out[c] changes without a read below: the next unmerge must read
			end
			if h.nout[c] > 0 then
				fresh = fresh or {}
				fresh[c] = {}
			end
		elseif h.rt and h.rt[c] and h.radar.get_signals_changed(W[c], h.rt[c]) == false then
			-- ponytail: spike 29's rule: after a read at R, get_signals_changed(wire, R) is false exactly when nothing changed.
			h.stats.skipped = (h.stats.skipped or 0) + 1
		else
			h.rt = h.rt or {}
			h.rt[c] = game.tick
			local sigs = x.net and x.net.signals
			local inj, ninj = h.inj[c], h.ninj[c]
			if x.peers then
				inj = core.sum(x.peers)
				ninj = cc.size(inj)
			end
			if not cc.unchanged(sigs, inj, ninj, h.out[c], h.nout[c]) then
				fresh = fresh or {}
				local rem, ch, k, n = cc.remainder_diff(sigs, inj, ninj, h.out[c], h.nout[c])
				chg = chg or {}
				fresh[c], chg[c] = rem, { ch, k, n }
			end
		end
	end
	if not fresh then
		return
	end
	local r, g, dr, dg = cc.fit(fresh.r or h.out.r, fresh.g or h.out.g)
	local kept, dropped, old, pre = { r = r, g = g }, { r = dr, g = dg }, {}, {}
	for _, c in ipairs(COLOURS) do
		if kept[c] ~= h.out[c] then
			local pc = chg and chg[c]
			local whole = pc and kept[c] == fresh[c] -- fit kept it whole: remainder_diff's change and size hold
			if whole then
				pre[c] = { pc[1], pc[2] }
			end
			old[c], h.out[c], h.nout[c] = h.out[c], kept[c], whole and pc[3] or cc.size(kept[c])
		end
		if dropped[c] > 0 and not h.trunc[c] then
			event(h, "truncated", "warn", { colour = c, kept = h.nout[c], dropped = dropped[c] })
		end
		h.trunc[c] = dropped[c] > 0 or nil
	end
	local st, k = cc.status(h.v + 1, nil, nil, h.out, old, h.nout.r + h.nout.g, pre)
	if k == 0 then
		return -- the remainder came back the same: an over-cap network re-sorted to the same signals
	end
	h.v = h.v + 1
	h.stats.sent = h.stats.sent + 1
	report(h, st)
end

--- §5's poll, every P ticks a host. Guard 6.2 per colour: hosts of this tile on h's network with a lower key make h
--- merged (its lead reports); higher ones are its peers, whose injectors it subtracts too (plan ruling 10). Then, unless
--- a write in this tick would make the read stale (K2, h's or a peer's), read and report; then enrol writes and repeat a
--- gap's ask.
local function poll(_, h, tick)
	if not h.radar.valid then
		return -- destroyed by a script: left as it is (plan ruling 13)
	end
	local nets, stale = {}, h.wtick == tick
	for _, c in ipairs(COLOURS) do
		local net = h.radar.get_circuit_network(W[c])
		local x = { net = net }
		nets[c] = x
		if net then
			local id = net.network_id
			for key, o in pairs(hosts()) do
				local on = o ~= h and o.radar.valid and o.radar.get_circuit_network(W[c])
				if on and on.network_id == id then
					if key < h.key then
						x.lead = (x.lead == nil or key < x.lead) and key or x.lead
					else
						x.peers = x.peers or { h.inj[c] }
						x.peers[#x.peers + 1] = o.inj[c]
						stale = stale or o.wtick == tick
					end
				end
			end
		end
	end
	for _, c in ipairs(COLOURS) do
		local carry = nets[c].lead == nil
		if carry ~= h.carry[c] then -- 6.2: a merged colour writes nothing; one that parted writes its target again
			cc.mark_all(h.todo[c], h.far[c])
			cc.mark_all(h.todo[c], h.inj[c])
			h.carry[c] = carry
			event(h, carry and "unmerged" or "merged", "info", { colour = c, into = nets[c].lead })
		end
	end
	if not stale then
		changes(h, nets)
	end
	enrol(h)
	if h.gap then
		ask(h)
	end
end

--- §5: the controller's ue.radar.full or ue.radar.delta for a host, folded into its mirror as it arrives (circuit §8.3;
--- the epoch is this run's boot id, plan ruling 7). A gap asks for the full target. Writes nothing (K2).
local function target(p)
	local h = type(p) == "table" and type(p.key) == "string" and hosts()[p.key]
	if not h then
		return false -- a key this tile no longer hosts
	end
	local result, bad = cc.fold(h, p, storage.universal_edges.rt.boot_id, quality_ok)
	h.stats.dropped = h.stats.dropped + bad
	if p.base ~= nil and storage.universal_edges.stream_trace then
		event(h, "delta", "verbose", { v = p.v, base = p.base, result = result }) -- counts only, never signals
	end
	if result == "gap" then
		h.stats.gaps = h.stats.gaps + 1
		if ask(h) then
			event(h, "gap", "info", { base = p.base, have = h.far_v })
		end
	elseif result == "full" or result == "change" then
		h.stats.applied = h.stats.applied + 1
	end
	enrol(h)
end

bridge.on(PLUGIN, "ue.radar.full", target)
bridge.on(PLUGIN, "ue.radar.delta", target)

--- The controller missed one of this host's reports (plan ruling 7): the full form, at the current version.
bridge.on(PLUGIN, "ue.radar.resend", function(p)
	local h = type(p) == "table" and type(p.key) == "string" and hosts()[p.key]
	if not h then
		return false
	end
	report(h, cc.full(h.v, nil, nil, h.out))
end)

--- The controller (re)learnt this tile: its start, or the controller's own restart (plan ruling 8). Every host reports
--- its own as a full and asks for its full target (§5: "reports its own signals afresh and asks").
bridge.on(PLUGIN, "ue.radar.resync", function()
	for _, h in pairs(hosts()) do
		report(h, cc.full(h.v, nil, nil, h.out))
		h.asked = nil
		ask(h)
	end
end)

--- The write task's step for a host (circuit.write_tick, plan ruling 2): its injectors toward the target, at most left
--- slots. A raise (a section that refused its filters) is logged once and leaves the set; the next poll enrols it again.
function circuit.host_write(h, left, tick)
	if not h.radar.valid then
		return 0, true
	end
	local valid = circuit.checker(h, function(fields) event(h, "unknown_signal", "warn", fields) end)
	local ok, used = pcall(circuit.write_colours, h, left, tick, function(c) return h.comb[c] end, valid)
	if not ok then
		if not h.logged.write then
			h.logged.write = true
			event(h, "write_failed", "error", { error = tostring(used) })
		end
		return 0, true
	end
	return used, next(h.todo.r) == nil and next(h.todo.g) == nil
end

scheduler.iterate({ name = "ue.radar.poll", source = hosts, per_tick = 1, interval = radar.P, fn = poll })
scheduler.periodic({ name = "ue.radar.discover", interval = radar.DISCOVER, fn = function() radar.discover() end })

return radar
