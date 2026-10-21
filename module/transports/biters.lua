-- Raids and expansion parties crossing live edges (cross-border biters spec §6.1, §6.2, §6.4, §7): the built-in "biters"
-- connector (cid "b", unique lanes, plan ruling R4) on every live side; a walk watch that captures a group at its hop
-- point and sends its members; the arrival that spawns them on the far side and sends them on, to the next hop, their
-- target or their base. Members are destroyed at capture: a refused, closed or failed crossing drops them, as vanilla
-- loses a failed group.
local bridge = require("modules/universal_edges/runtime/bridge")
local scheduler = require("modules/universal_edges/runtime/scheduler")
local connectors = require("modules/universal_edges/edges/connectors")
local geometry = require("modules/universal_edges/edges/geometry_core")
local crossing = require("modules/universal_edges/transports/crossing_core")
local players = require("modules/universal_edges/transports/players")
local trace = require("modules/universal_edges/runtime/trace")
local core = require("modules/universal_edges/transports/biters_core")

local biters = {}
local send = bridge.channel("universal_edges")
local OPS = { raid = "ue.raid", party = "ue.expansion" }

--- The oracle's prototype per pollutant (spec §6.3; plan ruling R11): Gleba's joined after spike 34 G2.
biters.ORACLES = { pollution = "ue-oracle", spores = "ue-oracle-gleba" }
local UNITS = {} -- each oracle's unit: the prototypes name it "<oracle>-unit"
for _, name in pairs(biters.ORACLES) do
	UNITS[name .. "-unit"] = true
end

local function emit(op, phase, level, fields)
	fields.op, fields.phase, fields.level, fields.tick = op, phase, level, game.tick
	send("trace", fields)
end

--- Gridworld's resolver (plan ruling R6): x on this tile's side route[1] for a raid whose remaining route is route, or nil
--- for the middle of the side. Set at load by ue.biters.on_locate.
biters.locate = function()
	return nil
end

function biters.on_locate(fn)
	if game then
		error("register the biters' locate hook while loading, not at runtime")
	end
	biters.locate = fn
end

--- ue.biters.set_enabled{ raids = bool, expansion = bool }: gridworld's biter toggles (owner, 2026-10-10), at every
--- config. Off, raids get no oracle and no target named, and a party isn't intercepted; either kind is dropped at
--- capture and on arrival.
function biters.set_enabled(flags)
	storage.universal_edges.biters.enabled = { raid = flags.raids ~= false, party = flags.expansion ~= false }
end

--- Whether kind ("raid" or "party") is on; never set, both are.
local function enabled(kind)
	local e = storage.universal_edges.biters.enabled
	return not e or e[kind] ~= false
end

local function b_of(side)
	return side and connectors.get(side, "b")
end

--- The live sides on a surface, { { id, frame } } (spec §7, plan ruling R17): active, not deleted, with a b endpoint.
function biters.sides(surface_index)
	local s, out = storage.universal_edges, {}
	for id in pairs(s.by_surface[surface_index] or {}) do
		local side = s.edges[id]
		local ep = side.active and not side.deleted and b_of(side)
		if ep then
			out[#out + 1] = { id = id, frame = ep.frame }
		end
	end
	return out
end

local function destroy(group)
	for _, m in ipairs(group.members) do
		m.destroy()
	end
	if group.valid then
		group.destroy()
	end
end

--- Spec §6.1: a group dropped: its members are destroyed, and the line says why.
local function drop(group, kind, edge, reason, id)
	if group.valid then
		destroy(group)
	end
	emit(OPS[kind] or "ue.raid", "dropped", (reason == "gone" or reason == "fail" or reason == "off") and "info" or "warn",
		{ edge = edge, reason = reason, trace = id })
end

--- ue.biters.walk(group, edge, x, data, id) (spec §6.1): the group walks to x along this side of edge, 4 tiles in, and
--- crosses there. data = { kind = "raid", route = { the edges after this one } } or { kind = "party", dest = { x, y } }
--- (a world point). A side that isn't live drops it at once.
function biters.walk(group, edge, x, data, id)
	local side = storage.universal_edges.edges[edge]
	local ep = b_of(side)
	if not (ep and side.active and not side.deleted) then
		return drop(group, data.kind, edge, "edge_inactive", id)
	end
	local kept, px, py = core.hop(ep.frame, x)
	group.set_command({ type = defines.command.go_to_location, destination = { px, py }, radius = 3,
		distraction = defines.distraction.by_enemy })
	group.start_moving()
	storage.universal_edges.biters.walking[group.unique_id] = { group = group, edge = edge, x = kept, px = px, py = py,
		kind = data.kind, route = data.route, dest = data.dest, trace = id }
end

--- Spec §6.1's capture: the members go over the side's b endpoint and are destroyed. A lane with a crossing in flight, or
--- a partner not ready yet, leaves the group waiting for the next pass; a side that went down drops it (Review Focus 1),
--- and so does its kind's toggle being off.
local function capture(id, r)
	local walking = storage.universal_edges.biters.walking
	local side = storage.universal_edges.edges[r.edge]
	local ep = b_of(side)
	if not (ep and side.active and not side.deleted) then
		walking[id] = nil
		return drop(r.group, r.kind, r.edge, "edge_inactive", r.trace)
	end
	if not enabled(r.kind) then
		walking[id] = nil
		return drop(r.group, r.kind, r.edge, "off", r.trace)
	end
	local dir = ep.me == "a" and "ab" or "ba"
	if not ep:can_send(dir) then
		return
	end
	local members = {}
	for _, m in ipairs(r.group.members) do
		members[#members + 1] = { name = m.name, quality = m.quality.name, health = m.health }
	end
	walking[id] = nil
	if #members == 0 then
		return drop(r.group, r.kind, r.edge, "gone", r.trace)
	end
	local body = { v = 1, kind = r.kind, x = r.x, members = members, route = r.route, trace = r.trace }
	if r.dest then
		body.dest = { geometry.to_local(ep.frame, r.dest[1], r.dest[2]) }
	end
	local seq, why = ep:send(dir, body)
	if not seq then
		return drop(r.group, r.kind, r.edge, why, r.trace)
	end
	destroy(r.group)
	emit(OPS[r.kind], "captured", "info", { edge = r.edge, members = #members, trace = r.trace })
end

-- Spec §6.1, every 60 ticks: a walking group within NEAR of its point crosses; one with no members left is dropped (killed
-- on the way: the engine raises nothing, spike 25 W1).
local watch = players.guarded(function()
	local walking = storage.universal_edges.biters.walking
	for id, r in pairs(walking) do
		local g = r.group
		if not (g.valid and #g.members > 0) then
			walking[id] = nil
			drop(g, r.kind, r.edge, "gone", r.trace)
		else
			local p = g.position
			if r.done or (p.x - r.px) ^ 2 + (p.y - r.py) ^ 2 <= core.NEAR ^ 2 then
				capture(id, r) -- r.done: it already reported success but the lane was busy (re-checks the side)
			end
		end
	end
end, "ue.raid")

scheduler.periodic({
	name = "ue.biters.watch",
	interval = 60,
	fn = function(tick)
		if next(storage.universal_edges.biters.walking) ~= nil then
			watch(tick)
		end
	end,
})

--- on_ai_command_completed: a walking group's go_to_location ended. Success crosses (about 8 tiles short of the point,
--- spike 25 W1); anything else drops it.
function biters.on_command_completed(event)
	local walking = storage.universal_edges.biters.walking
	local r = walking[event.unit_number]
	if not r or event.was_distracted then
		return
	end
	if event.result == defines.behavior_result.success then
		if not r.group.valid then
			walking[event.unit_number] = nil
			return drop(r.group, r.kind, r.edge, "gone", r.trace)
		end
		-- a unit's completion can carry a colliding number, and spider-unit groups report success up to 21.5 tiles out
		local p = r.group.position
		if (p.x - r.px) ^ 2 + (p.y - r.py) ^ 2 <= (3 * core.NEAR) ^ 2 then
			r.done = true -- the group idles now: the watch retries the capture whatever its distance
			capture(event.unit_number, r)
		end
	else
		walking[event.unit_number] = nil
		drop(r.group, r.kind, r.edge, "fail", r.trace)
	end
end

--- Per pollutant, the entity names whose energy source emits it, built once from the prototypes (spec §6.3's fallback).
--- ponytail: electric and burner sources only; heat and fluid sources join if a polluter of theirs goes unattacked.
local EMITTERS = {}

local function emitters(pollutant)
	local names = EMITTERS[pollutant]
	if not names then
		names = {}
		for name, p in pairs(prototypes.entity) do
			local src = p.electric_energy_source_prototype or p.burner_prototype
			local e = src and src.emissions_per_joule[pollutant]
			if e and e > 0 then
				names[#names + 1] = name
			end
		end
		EMITTERS[pollutant] = names
	end
	return names
end

--- Spec §6.3: an arriving raid's target on ep's side: the oracle's latest while a player entity still stands within 10 of
--- it; else the densest chunk of the pollutant's emitters within RANGE of where it arrived (the fallback). nil for none.
function biters.target(ep, at)
	local surface = game.get_surface(ep.frame.surface_index)
	local t = storage.universal_edges.biters.targets[ep.edge]
	if t and surface.count_entities_filtered({ position = { t.x, t.y }, radius = 10, force = "player", limit = 1 }) > 0 then
		return { x = t.x, y = t.y }, false
	end
	local p = surface.pollutant_type
	local names = p and emitters(p.name)
	if not (names and #names > 0) then
		return nil
	end
	local r = core.RANGE
	local positions = {}
	for i, e in ipairs(surface.find_entities_filtered({ position = at, radius = r,
		force = "player", name = names })) do
		positions[i] = e.position
	end
	return core.densest(positions), true
end

--- Spec §6.2, §6.4, §7: the members spawned here move on. A raid with edges left walks to the next, where its pollution
--- entered this tile (gridworld's locate); else it attacks its target. A party builds at its destination.
local function arrive(ep, group, body, id)
	local n = #group.members
	if body.kind == "raid" and #body.route > 0 then
		local nxt = body.route[1]
		local side = storage.universal_edges.edges[nxt]
		local x = biters.locate(ep.frame.surface_index, body.route) or (side and side.length or ep.frame.length) / 2
		emit("ue.raid", "arrived", "info", { edge = ep.edge, members = n, next = nxt, trace = id })
		biters.walk(group, nxt, x, { kind = "raid", route = { table.unpack(body.route, 2) } }, id)
	elseif body.kind == "raid" then
		local t, fallback = biters.target(ep, group.position)
		if not t then
			return drop(group, "raid", ep.edge, "no_target", id)
		end
		group.set_command({ type = defines.command.attack_area, destination = t, radius = 10,
			distraction = defines.distraction.by_enemy })
		group.start_moving()
		emit("ue.raid", "arrived", "info", { edge = ep.edge, members = n, x = t.x, y = t.y, fallback = fallback, trace = id })
	else
		local dx, dy = geometry.to_world(ep.frame, geometry.flip(ep.frame.length, body.dest[1], body.dest[2]))
		group.set_command({ type = defines.command.build_base, destination = { dx, dy },
			distraction = defines.distraction.by_enemy })
		group.start_moving()
		emit("ue.expansion", "crossed", "info", { edge = ep.edge, members = n, x = dx, y = dy, trace = id })
	end
end

--- The oracle's force: not "enemy", whose expansion planner counts an oracle as a base and cuts expansion to a quarter
--- (spike 42). AI-controllable, or its group never forms; at cease-fire with enemy, so neither attacks the other.
local function oracle_force()
	local f = game.forces["ue-oracle"]
	if not f then
		f = game.create_force("ue-oracle")
		f.ai_controllable = true
		f.set_cease_fire("enemy", true)
		game.forces.enemy.set_cease_fire(f, true)
	end
	return f
end

--- Spec §6.3: the oracle of ep's side, in the first outside row at local (oracle_x, ORACLE_Y), on a surface whose
--- pollutant has an oracle, once its chunk is generated, while raids are on. The endpoint's build and every poll try again.
local function place(ep)
	local surface = ep.frame.surface_index and game.get_surface(ep.frame.surface_index)
	local name = surface and surface.pollutant_type and biters.ORACLES[surface.pollutant_type.name]
	local oracles = storage.universal_edges.biters.oracles
	if not (name and prototypes.entity[name] and enabled("raid")) or (oracles[ep.edge] and oracles[ep.edge].valid) then
		return -- no prototype: the UE mod in the pack predates it (as barriers.place skips a missing ue-barrier)
	end
	local x, y = geometry.to_world(ep.frame, core.oracle_x(ep.frame.length), core.ORACLE_Y)
	if not surface.is_chunk_generated({ math.floor(x / 32), math.floor(y / 32) }) then
		return
	end
	local e = surface.create_entity({ name = name, position = { x, y }, force = oracle_force() })
	if e then
		e.destructible = false
		oracles[ep.edge] = e
		emit("ue.oracle", "placed", "verbose", { edge = ep.edge })
	end
end

--- on_entity_spawned: an oracle's unit can't be hurt (spike 28 H1), so turrets never target it (spike 27 O4 b).
function biters.on_spawned(event)
	local e = event.entity
	if e.valid and UNITS[e.name] then
		e.destructible = false
	end
end

--- Spec §6.3: an oracle's group finished gathering: its command's destination is the nearest oracle's side's current
--- target, while raids are on, and the members go (spike 28 H1 e: the next group begins within about 170 ticks).
local function named(g)
	local cmd = g.command
	local dest = cmd and (cmd.destination or (cmd.target and cmd.target.valid and cmd.target.position))
	local p, edge, best = g.position, nil, nil
	for id, o in pairs(storage.universal_edges.biters.oracles) do
		if o.valid and o.surface_index == g.surface.index then
			local d = (o.position.x - p.x) ^ 2 + (o.position.y - p.y) ^ 2
			if not best or d < best then
				edge, best = id, d
			end
		end
	end
	if edge and dest and enabled("raid") and not (cmd and cmd.type == defines.command.build_base) then
		-- an expansion party formed from the oracle's units is no attack target
		storage.universal_edges.biters.targets[edge] = { x = dest.x, y = dest.y, tick = game.tick }
		emit("ue.oracle", "target", "info", { edge = edge, x = dest.x, y = dest.y })
	end
	for _, m in ipairs(g.members) do
		m.destroy()
	end
end

--- on_unit_group_finished_gathering: an oracle's group names its side's target (spec §6.3); a party bound past a live
--- side's line walks there and crosses (spec §7, plan ruling R9), while expansion is on. A party that just crossed into a
--- corner's side tile is past that tile's next line and walks on; one bound for this tile, or past no live line, builds as
--- vanilla does.
function biters.on_gathered(event)
	local g = event.group
	if not g.valid then
		return
	end
	local oracle, other = {}, 0
	for _, m in ipairs(g.members) do
		if UNITS[m.name] then
			oracle[#oracle + 1] = m
		else
			other = other + 1
		end
	end
	if #oracle > 0 and other == 0 then
		return named(g)
	end
	for _, m in ipairs(oracle) do -- a mixed group: only the oracle's units go, nothing is recorded (controller ruling O7)
		m.destroy()
	end
	local cmd = g.command
	if cmd and cmd.type == defines.command.build_base and enabled("party") then
		local d = cmd.destination
		local s, x = core.party_side(biters.sides(g.surface.index), d.x, d.y)
		if s then
			biters.walk(g, s.id, x, { kind = "party", dest = { d.x, d.y } }, trace.new_id())
		end
	end
end

connectors.register_type({
	name = "biters",
	builtin = "b",
	lanes = function()
		return { ab = "unique", ba = "unique" }
	end,
	schedule = { per_tick = 2, interval = 600 },
	build = function(ep)
		place(ep)
		return "ready"
	end,
	--- The side is gone: its oracle, the units it already spawned (indestructible, outside the tile) and its target with it.
	teardown = function(ep)
		local s = storage.universal_edges.biters
		local o = s.oracles[ep.edge]
		if o and o.valid then
			local names = {}
			for n in pairs(UNITS) do
				names[#names + 1] = n
			end
			for _, u in ipairs(o.surface.find_entities_filtered({ position = o.position, radius = 40, name = names })) do
				u.destroy()
			end
			o.destroy()
		end
		s.oracles[ep.edge], s.targets[ep.edge] = nil, nil
	end,
	poll = place,
	--- Spec §6.2: the members spawn within 8 of the mirrored point, at least 0.5 inside, as one group; when none fits the
	--- answer is reject (R4a), and the raid is dropped. One whose kind's toggle is off here is dropped, and taken.
	credit = function(ep, _, body, meta)
		if not core.valid(body) then
			return "reject"
		end
		if not enabled(body.kind) then
			emit(OPS[body.kind], "dropped", "info", { edge = ep.edge, reason = "off", trace = body.trace or meta.trace })
			return "ok"
		end
		for _, m in ipairs(body.members) do
			local proto = prototypes.entity[m.name]
			if not (proto and (proto.type == "unit" or proto.type == "spider-unit") and prototypes.quality[m.quality]) then
				return "reject"
			end
		end
		local surface = game.get_surface(ep.frame.surface_index)
		local wx, wy = geometry.to_world(ep.frame, ep.frame.length - body.x, 0)
		local x1, y1, x2, y2 = crossing.arrival_box(ep.frame, wx, wy)
		local units = {}
		for _, m in ipairs(body.members) do
			local pos = surface.find_non_colliding_position_in_box(m.name, { { x1, y1 }, { x2, y2 } }, 0.5)
			local u = pos and surface.create_entity({ name = m.name, quality = m.quality, position = pos, force = "enemy" })
			if u then
				u.health = m.health
				units[#units + 1] = u
			end
		end
		if #units == 0 then
			emit(OPS[body.kind], "no_room", "warn", { edge = ep.edge, trace = body.trace or meta.trace })
			return "reject" -- R4a: the raid is dropped; the source's restore logs it
		end
		-- an error from here on must not read as busy (UE would re-offer, and re-spawn, for ever): drop it, answer ok
		local group
		local ok = pcall(function()
			group = surface.create_unit_group({ position = { (x1 + x2) / 2, (y1 + y2) / 2 }, force = "enemy" })
			for _, u in ipairs(units) do
				group.add_member(u)
			end
			arrive(ep, group, body, body.trace or meta.trace) -- one trace per raid, hop after hop
		end)
		if not ok then
			for _, u in ipairs(units) do
				if u.valid then
					u.destroy()
				end
			end
			if group and group.valid then
				group.destroy()
			end
			emit(OPS[body.kind], "dropped", "warn", { edge = ep.edge, reason = "error", trace = body.trace or meta.trace })
		end
		return "ok"
	end,
	commit = function()
		return true
	end,
	--- Spec §6.1: a refusal or a close drops what crossed; its members are already gone.
	restore = function(ep, _, _, body)
		emit(type(body) == "table" and OPS[body.kind] or "ue.raid", "dropped", "warn",
			{ edge = ep.edge, reason = ep.closing and "close" or "reject", trace = type(body) == "table" and body.trace or nil })
		return true
	end,
})

return biters
