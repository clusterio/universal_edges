-- The logistic connector type (logistic-link spec §4–§8). A requester placed in a border row is replaced, at the
-- connector's first build, by a link requester one tile out (§6.1); the far side gets a link provider (§6.2). Once a
-- second the destination reports its free slots and what it has credited, and the source ships what its requester
-- holds as a count stream, never more than those slots hold (§7). Removing either chest drains the other back (§8).
local bridge = require("modules/universal_edges/runtime/bridge")
local connectors = require("modules/universal_edges/edges/connectors")
local geometry = require("modules/universal_edges/edges/geometry_core")
local belt_core = require("modules/universal_edges/transports/belt_core")
local items = require("modules/universal_edges/transports/items")
local core = require("modules/universal_edges/transports/logistic_core")

local logistic = {}
local send = bridge.channel("universal_edges")
local MAIN, TRASH = defines.inventory.chest, defines.inventory.logistic_container_trash
local CHECK = nil -- L8; P2 V8: script refused neither a chest nor water; the default, ghost_revive, does (P1)
local ASK_AFTER = 300 -- §7.4 step 2 (L11): ticks without a shipment before asking for a status that may be lost
-- ponytail: one insert table, its fields reassigned per key (belt.lua's INSERT); insert keeps no reference to it.
local INSERT = {}
-- ponytail: a module-level memo, never evicted: bounded by the save's item prototypes.
local stack_sizes = {}

--- An item's stack size (§7.2): it doesn't depend on quality ([api] LuaItemPrototype.stack_size).
local function stack_size(name)
	local s = stack_sizes[name]
	if not s then
		s = prototypes.item[name].stack_size
		stack_sizes[name] = s
	end
	return s
end

--- A ue.logistic line (§11).
local function event(ep, phase, level, fields)
	fields.op, fields.phase, fields.level, fields.tick = "ue.logistic", phase, level, game.tick
	fields.edge, fields.cid, fields.trace = ep.edge, ep.cid, ep.trace
	send("trace", fields)
end

--- This side ships: the side the requester was built on (O1).
local function source(ep)
	return (ep.params.dir == "ab") == (ep.me == "a")
end

--- A stack's key (§7.1): the freshness bucket only for an item that spoils.
local function key_of(name, quality, spoil_percent)
	return core.key(name, quality, items.spoilable(name, quality) and belt_core.spoil_p(spoil_percent) or nil)
end

--- §8.2 step 1: this side's chest is gone. It ships and reports nothing more, and tells its partner.
local function lose(ep)
	ep.data.gone = "lost"
	ep:set_status({ gone = "lost" })
	event(ep, "lost", "info", { miner = ep.data.miner })
end

--- §7.6 (L9): a key this save has no item or quality for is refused; logged at error once per endpoint.
local function refuse(ep, item, quality)
	if not ep.data.refusing then
		ep.data.refusing = true
		event(ep, "refused", "error", { item = item, quality = quality })
	end
end

--- §8.3 (L21): into this side's chest if it stands, then its miner if connected, then the ground at the border tile
--- inside, with the key's freshness. Returns what went into the chest, to the miner and onto the ground.
local function land(ep, name, quality, count, p)
	local d = ep.data
	INSERT.name, INSERT.quality, INSERT.count, INSERT.spoil_percent = name, quality, count, p and p / 100 or nil
	local put, given = 0, 0
	if d.chest and d.chest.valid then
		put = d.inv.insert(INSERT)
	end
	local player = d.miner and game.get_player(d.miner)
	if put < count and player and player.connected then
		INSERT.count = count - put
		given = player.insert(INSERT)
	end
	local rest = count - put - given
	if rest > 0 then
		items.spill(ep, name, quality, rest, INSERT.spoil_percent, true)
	end
	d.stats.given, d.stats.spilled = d.stats.given + given, d.stats.spilled + rest
	return put, given, rest
end

--- This side's outbound lane: the forward lane at the source, the return lane at the destination (L17).
local function out_dir(ep)
	return ep.me == "a" and "ab" or "ba"
end

--- §7.3: the destination's { free, r }, set when either changed (sent in this visit, F13).
local function report(ep)
	local d = ep.data
	local free, st = d.inv.count_empty_stacks(false, false), ep.status
	if not st or st.free ~= free or st.r ~= d.stats.got then
		ep:set_status({ free = free, r = d.stats.got })
	end
end

--- §6.1 (L4): replace the placed requester with a link requester one tile out, in one tick: find, guard, create,
--- record, carry over, destroy. A nil create returns before anything is destroyed, and the destroy is last.
local function build_source(ep, surface)
	local d = ep.data
	local ix, iy = geometry.to_world(ep.frame, ep.col + 0.5, 0.5)
	local placed = surface.find_entities_filtered({ position = { ix, iy }, type = "logistic-container", limit = 1 })[1]
	local name = placed and "ue-link-" .. placed.name
	if not (placed and prototypes.entity[name]) then
		lose(ep) -- step 2: mined before the connector arrived, or a connector added by hand
		return "ready"
	end
	local ox, oy = geometry.to_world(ep.frame, ep.col + 0.5, -0.5)
	if not surface.can_place_entity({ name = name, position = { ox, oy }, force = placed.force, build_check_type = CHECK }) then
		return "blocked" -- step 3: a player, an entity (an N2 orphan included) or water on the spot
	end
	local chest = surface.create_entity({ name = name, position = { ox, oy }, force = placed.force,
		quality = placed.quality, create_build_effect_smoke = false })
	if not chest then
		return "blocked"
	end
	d.chest, d.inv = chest, chest.get_inventory(MAIN)
	ep:own(chest) -- step 5, before the copy: a hook error part-way leaves a kept chest and nothing lost (G6)
	chest.copy_settings(placed) -- step 6 (O2): requests, groups, flags and the circuit behaviour (P2 V4)
	for id, c in pairs(placed.get_wire_connectors(false)) do
		local into = chest.get_wire_connector(id, true)
		for _, w in ipairs(c.connections) do
			into.connect_to(w.target, false, w.origin) -- no reach check: the new chest is a tile further from the far end
		end
	end
	for _, id in ipairs({ MAIN, TRASH }) do
		local from, into = placed.get_inventory(id), chest.get_inventory(id)
		for i = 1, from and #from or 0 do
			into[i].swap_stack(from[i]) -- each stack whole, freshness and item data included, into the same slot (P2 V3)
		end
	end
	d.inv.set_bar(placed.get_inventory(MAIN).get_bar())
	local from_name, quality = placed.name, chest.quality.name
	placed.destroy() -- step 7: empty by now; no raise_destroy
	event(ep, "converted", "info", { from = { x = ix, y = iy }, to = { x = ox, y = oy }, name = from_name, quality = quality })
	return "ready"
end

--- §6.2 (L5, L8): adopt a provider already on the spot (only an N2 orphan can stand there), or create one at the placed
--- chest's quality.
local function build_destination(ep, surface)
	local d = ep.data
	local name = "ue-link-provider-" .. ep.params.chest
	local ox, oy = geometry.to_world(ep.frame, ep.col + 0.5, -0.5)
	local chest = surface.find_entity(name, { ox, oy })
	if not chest then
		if not surface.can_place_entity({ name = name, position = { ox, oy }, force = "player", build_check_type = CHECK }) then
			return "blocked"
		end
		chest = surface.create_entity({ name = name, position = { ox, oy }, force = "player", quality = ep.params.q,
			create_build_effect_smoke = false })
		if not chest then
			return "blocked"
		end
	end
	d.chest, d.inv = chest, chest.get_inventory(MAIN)
	ep:own(chest)
	report(ep) -- the first status, as belts announce at build
	return "ready"
end

--- §7.4: ship when the destination's last status counts everything sent (the gate, L2), at most its free slots' worth.
local function ship(ep, tick)
	local d, dir = ep.data, ep.params.dir
	local st = ep.partner and ep.partner.status
	if not core.open(d.stats.sent, st) then
		if st and type(st.free) == "number" and type(st.r) == "number" then -- step 2: shut while sent > r
			if st.free > 0 and not ep:idle(dir) then
				ep:nudge(dir) -- a remainder refused for room re-offers now (fluid's rule; fail-stop's once a second)
			end
			if tick - d.sent_at > ASK_AFTER then
				ep:ask_partner() -- recovers a lost status; throttled to one per 3600 ticks
			end
		end
		return
	end
	local inv = d.inv
	if st.free == 0 or inv.is_empty() or not ep:can_send(dir) then
		return -- step 3: one inventory call, nothing allocated
	end
	local contents, cands, detailed = inv.get_contents(), {}, false
	for _, c in ipairs(contents) do
		if items.spoilable(c.name, c.quality) then
			detailed = true
			break
		end
	end
	if detailed then -- step 4: a stack per candidate, keyed with its freshness
		for i = 1, #inv do
			local s = inv[i]
			if s.valid_for_read then
				local q = s.quality.name
				cands[#cands + 1] = { key_of(s.name, q, s.spoil_percent), s.count, stack_size(s.name), stack = s }
			end
		end
	else -- the fast path: an item and quality per candidate
		for i, c in ipairs(contents) do
			cands[i] = { core.key(c.name, c.quality), c.count, stack_size(c.name), name = c.name, quality = c.quality }
		end
	end
	local bag, total, first = core.plan(cands, st.free, d.last_key)
	d.last_key = first
	if total == 0 then
		return
	end
	ep:send(dir, bag) -- T1, step 6: first; a refused send raises before anything is removed
	for _, c in ipairs(cands) do
		if c.take then
			if c.stack then
				c.stack.clear()
			else
				INSERT.name, INSERT.quality, INSERT.count, INSERT.spoil_percent = c.name, c.quality, c.take, nil
				inv.remove(INSERT) -- exactly that quality (P1 U8)
			end
		end
	end
	d.stats.sent, d.sent_at = d.stats.sent + total, tick
end

--- §8.2 step 4: ship everything this side's chest holds (main and, for a requester, trash), keyed as §7.4's detailed
--- path, on its own outbound lane, then destroy the chest: one call, one tick, the send first (T1). The status and the
--- offers leave in this visit, status first (lanes.visit), so the lost side credits them before it asks.
local function drain(ep)
	local d, bag, n, keys = ep.data, {}, 0, 0
	for _, id in ipairs({ MAIN, TRASH }) do
		local inv = d.chest.get_inventory(id)
		for i = 1, inv and #inv or 0 do
			local s = inv[i]
			if s.valid_for_read then
				local k = key_of(s.name, s.quality.name, s.spoil_percent)
				if not bag[k] then
					keys = keys + 1
				end
				bag[k], n = (bag[k] or 0) + s.count, n + s.count
			end
		end
	end
	local out = out_dir(ep)
	if n > 0 then
		ep:send(out, bag) -- a stream send needs no can_send (lanes.lua's send)
	end
	ep:nudge(out) -- L22 (plan ruling 6): a forward lane backing off offers its remainder in this visit, beside the status
	d.chest.destroy() -- what it held is escrow now
	d.gone, d.stats.drained = "drained", d.stats.drained + n
	ep:set_status({ gone = "drained" })
	event(ep, "drained", "info", { items = n, keys = keys })
end

--- §8.2, every poll before anything else (R16's .valid read). True when the poll stops here.
local function removal(ep)
	local d = ep.data
	if d.requested then
		return true
	end
	if d.gone == nil and not d.chest.valid then
		lose(ep)
	end
	local p = ep.partner
	local act = core.removal(d.gone, p and p.state, p and p.status and p.status.gone, source(ep))
	if act == "request" then
		d.requested = true -- the spec's ep.data.asked (plan ruling 7): once
		ep:request_removal("chest_gone")
		send("trace", { op = "ue.connector", phase = "removal_requested", level = "info", tick = game.tick, trace = ep.trace,
			edge = ep.edge, cid = ep.cid, reason = "chest_gone" })
	elseif act == "drain" then
		drain(ep)
	end
	return d.gone ~= nil
end

--- on_player_mined_entity (§8.1, L19): records who mined a logistic endpoint's chest, so its partner's contents go to
--- them. It finds the removal of nothing (the poll does) and costs one lookup for any mined entity; an entity with no
--- unit number reads owned[nil], which is nil.
function logistic.on_mined(e)
	local s = storage.universal_edges
	local key = s.owned[e.entity.unit_number]
	local ep = key and s.eps.logistic and s.eps.logistic[key]
	if ep then
		ep.data.miner = e.player_index
	end
end

connectors.register_type({
	name = "logistic",
	lanes = function() return { ab = "stream", ba = "stream" } end, -- forward params.dir; return the other (L17)
	validate = function(params)
		if type(params) ~= "table" or (params.dir ~= "ab" and params.dir ~= "ba") or type(params.q) ~= "string"
			or type(params.chest) ~= "string" then
			return false, "logistic params need dir = ab|ba, q and chest"
		end
		return true
	end,
	schedule = { per_tick = 4, interval = 60 }, -- O6, L14
	poll_independent = true, -- L16: a lost side acts while its partner is blocked forever (lanes.lua's gate)
	--- §6, F9: step 0 keeps a chest built before, or finds it removed while the endpoint wasn't polling (G6).
	build = function(ep)
		local d = ep.data
		d.stats = d.stats or { sent = 0, got = 0, drained = 0, given = 0, spilled = 0, refunded = 0 }
		d.sent_at = d.sent_at or 0
		if d.gone or d.chest then
			if not d.gone and not d.chest.valid then
				lose(ep)
			end
			return "ready"
		end
		local surface = game.get_surface(ep.frame.surface_index)
		if not surface then
			return "blocked"
		end
		if source(ep) then
			return build_source(ep, surface)
		end
		return build_destination(ep, surface)
	end,
	poll = function(ep, tick)
		if removal(ep) then
			return
		end
		if source(ep) then
			ship(ep, tick)
		else
			report(ep)
		end
	end,
	--- §7.5 (T2): per key, a missing prototype is refused (§7.6); a drained side takes nothing, which the close refunds
	--- on the sender's side (§8.4); a standing chest takes what fits; a lost side (noticed or not yet) lands it all.
	credit = function(ep, _, bag)
		local d, accepted, given, spilled = ep.data, {}, 0, 0
		for k, n in pairs(bag) do
			local name, quality, p = core.parse(k)
			local x = 0
			if not (name and prototypes.item[name] and prototypes.quality[quality]) then
				refuse(ep, name or k, quality) -- step 1, before any insert: insert raises on an unknown name (P1 U10)
			elseif d.gone == "drained" then
				x = 0 -- step 2
			elseif d.chest and d.chest.valid then
				INSERT.name, INSERT.quality, INSERT.count, INSERT.spoil_percent = name, quality, n, p and p / 100 or nil
				x = d.inv.insert(INSERT) -- step 3: what fits; insert stops at the bar (P1 U5)
			else
				local _, g, sp = land(ep, name, quality, n, p) -- step 4
				given, spilled, x = given + g, spilled + sp, n
			end
			accepted[k] = x
			d.stats.got = d.stats.got + x
		end
		if given + spilled > 0 then
			event(ep, "landed", "info", { given = given, spilled = spilled }) -- once per credit call (plan ruling 5)
		end
		return accepted
	end,
	--- §8.4: sent − the partner's final recv, per key, lands on this side (§8.3). Every key names an item this side
	--- sent from its own chest, so it has a prototype here.
	refund = function(ep, _, bag)
		local inserted, given, spilled = 0, 0, 0
		for k, n in pairs(bag) do
			local name, quality, p = core.parse(k)
			local a, b, c = land(ep, name, quality, n, p)
			inserted, given, spilled = inserted + a, given + b, spilled + c
		end
		ep.data.stats.refunded = ep.data.stats.refunded + inserted + given + spilled
		event(ep, "refunded", "info", { inserted = inserted, given = given, spilled = spilled })
		return true
	end,
	--- §8.4 (L7): nothing. After a chest-caused removal both chests are gone already; after any other they stay (N2).
	--- ep.data.chest stays, because the refund runs after teardown (G1) and land needs it (T5).
	teardown = function() end,
})

return logistic
