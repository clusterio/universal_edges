-- Players crossing a border (player-crossing spec, 2026-10-13): one zone rule (registered hooks first, then this
-- instance's edges), one prompt per zone entered, and a record of where the player crossed and left, kept on the
-- controller (§5). The instance they join asks for it and places them once they have a body (§6). No ledger: nothing
-- in the world moves (SP3 §17 risk 7).
local bridge = require("modules/universal_edges/runtime/bridge")
local scheduler = require("modules/universal_edges/runtime/scheduler")
local trace = require("modules/universal_edges/runtime/trace")
local edges = require("modules/universal_edges/edges/edges")
local crossing = require("modules/universal_edges/transports/crossing_core")

local players = { RETRY = 300, PLACING = 3600, HOOK_LOG = 3600, WAIT = 36000, hooks = {} }
local send = bridge.channel("universal_edges")
local EMPTY = {}

local function state()
	return storage.universal_edges.players
end

local function emit(phase, level, id, fields)
	fields.op, fields.phase, fields.level, fields.tick, fields.trace = "ue.player", phase, level, game.tick, id
	send("trace", fields)
end

--- side's built-in vehicle endpoint (cid "v", always type "vehicle", F7), by a key cached on the side record once
--- (storage, not a file-local) so repeated lookups across ticks never rebuild `side.id .. "/v"` (review Important 1).
--- A side's id, and so this key, never changes once created. Shared with vehicle.crossed (final review M4).
local function v_of(side)
	local key = side.v_key
	if not key then
		key = side.id .. "/v"
		side.v_key = key
	end
	local registry = storage.universal_edges.eps.vehicle
	return registry and registry[key]
end
players.v_of = v_of

--- True while player isn't standing in the world in their character: remote view (panning moves player.position and
--- fires on_player_changed_position without the body moving), or a spectator (inventory_sync's while a joining player's
--- inventory downloads, playtest 2 #6c), god, ghost or editor. Takes anything with a controller_type field, so a game
--- test (no connected player exists in one) can drive it with made-up facts.
local function off_body(player)
	return player.controller_type ~= defines.controllers.character
end
players.off_body = off_body

--- F12: an event handler has no endpoint, so an error is caught here and logged as op ("ue.player", "ue.vehicle" or
--- "ue.logistic") failed, once per stats window (3600 ticks).
function players.guarded(fn, op)
	return function(event)
		local ok, err = pcall(fn, event)
		if not ok then
			local stats = storage.universal_edges.stats
			stats[op] = stats[op] or {}
			stats[op].errors = (stats[op].errors or 0) + 1
			if stats[op].errors == 1 then
				send("trace", { op = op, phase = "failed", level = "error", tick = game.tick, error = tostring(err) })
			end
		end
	end
end

--- ue.players.zones{ name, zone, place } (§7.1), at load only. zone(surface, x, y, current) → a key "<name>:…" or nil,
--- current being the player's key now; place(surface, key, x, y) → x, y, box: where a recorded point lands in this
--- instance, or nil when it doesn't.
function players.zones(spec)
	if game then
		error("register zone hooks while loading, not at runtime")
	end
	if type(spec) ~= "table" or type(spec.name) ~= "string" or type(spec.zone) ~= "function"
		or type(spec.place) ~= "function" then
		error("a zone hook needs a name, zone and place")
	end
	for _, h in ipairs(players.hooks) do
		if h.name == spec.name then
			error("zone hook " .. spec.name .. " is already registered")
		end
	end
	players.hooks[#players.hooks + 1] = spec
end

local function hook_of(key)
	local prefix = string.match(key, "^([^:]+):")
	for _, h in ipairs(players.hooks) do
		if h.name == prefix then
			return h
		end
	end
end

--- A hook's function under pcall (§7.1): a raise is logged at most once per HOOK_LOG ticks per hook and function, and
--- counts as nil.
local function call(h, fn, ...)
	local ok, a, b, c = pcall(h[fn], ...)
	if ok then
		return a, b, c
	end
	local failed = state().hook_failed
	local k = h.name .. "." .. fn
	if not failed[k] or game.tick - failed[k] >= players.HOOK_LOG then
		failed[k] = game.tick
		emit("hook_failed", "error", nil, { hook = h.name, fn = fn, error = tostring(a) })
	end
end

local function edge_side(key)
	local id = string.match(key, "^edge:(.+)$")
	local side = id and storage.universal_edges.edges[id]
	if side and not side.deleted then
		return side, id
	end
end

--- The first live side on this surface whose line (x, y) is past by more than 0.5, within its [0, L) (§3.1 step 3).
local function edge_enter(surface_index, x, y)
	local s = storage.universal_edges
	for id in pairs(s.by_surface[surface_index] or EMPTY) do
		local side = s.edges[id]
		local v = not side.deleted and v_of(side)
		if v and crossing.player_past(v.frame, x, y) then
			return "edge:" .. id
		end
	end
end

--- The zone (x, y) on this surface is in (§3.1): current while its own stay test holds; else the first hook's; else
--- the first edge's. When a hook's zone holds or wins, the edge's key comes second: the controller's fallback, for a
--- hook zone whose destination doesn't exist, on a retry too (§4 steps 2 and 4). nil when in none.
function players.zone(surface_index, surface_name, x, y, current)
	if current then
		local h = hook_of(current)
		if h then
			if call(h, "zone", surface_name, x, y, current) == current then
				return current, edge_enter(surface_index, x, y)
			end
		else
			local side = edge_side(current)
			local v = side and side.surface_index == surface_index and v_of(side)
			if v and crossing.player_stays(v.frame, x, y) then
				return current
			end
		end
	end
	for _, h in ipairs(players.hooks) do
		local key = call(h, "zone", surface_name, x, y, nil)
		if key then
			return key, edge_enter(surface_index, x, y)
		end
	end
	return edge_enter(surface_index, x, y)
end

--- §4 step 1: name, at (x, y) on surface, asks for key's destination (fallback second). Returns the crossing's trace: id,
--- a vehicle or train crossing's own when a rider crosses with it (one trace per crossing), or a new one. held marks a
--- rider's crossing: moves leave it alone until it is answered (§7.3), since the rider may stand inside once their
--- vehicle or carriage is gone.
function players.cross(name, key, fallback, surface, x, y, id, held)
	id = id or trace.new_id()
	state().pending[name] = { key = key, tick = game.tick, trace = id, held = held }
	send("ue.player.cross", { player = name, keys = { key, fallback }, surface = surface, x = x, y = y, trace = id })
	emit("crossed", "info", id, { player = name, key = key, fallback = fallback, surface = surface, x = x, y = y })
	return id
end

--- §3.1, §4 step 4: a move. A new or changed zone crosses; the same zone is never prompted twice, and retries after
--- RETRY ticks only when unanswered or answered none; no zone clears the crossing. A held rider crossing ignores
--- moves until it is answered, or for RETRY ticks unanswered (a lost answer mustn't stop the rider's zones for good).
function players.moved(name, surface_index, surface_name, x, y)
	local pending = state().pending[name]
	if pending and pending.held and not pending.answered and game.tick - pending.tick <= players.RETRY then
		return
	end
	local key, fallback = players.zone(surface_index, surface_name, x, y, pending and pending.key)
	if not key then
		state().pending[name] = nil
		return
	end
	if pending and pending.key == key and (pending.prompted or game.tick - pending.tick <= players.RETRY) then
		return
	end
	players.cross(name, key, fallback, surface_name, x, y)
end

function players.on_moved(event)
	local player = game.get_player(event.player_index)
	if not player or player.physical_vehicle or off_body(player) then
		return
	end
	local p, surface = player.physical_position, player.physical_surface
	players.moved(player.name, surface.index, surface.name, p.x, p.y)
end

--- §4 step 3: offer the server, unless the reply is stale or the player has gone.
bridge.on("universal_edges", "ue.player.prompt", function(p)
	if type(p.player) ~= "string" or type(p.address) ~= "string" or type(p.name) ~= "string"
		or type(p.trace) ~= "string" then
		return false
	end
	local pending = state().pending[p.player]
	local player = game.get_player(p.player)
	local reason
	if not (pending and pending.trace == p.trace) then
		reason = "stale"
	elseif not (player and player.connected) then
		reason = "left"
	end
	if pending and pending.trace == p.trace then
		pending.answered = true
	end
	if reason then
		emit("prompt_skipped", "verbose", p.trace, { player = p.player, reason = reason })
		return true
	end
	pending.prompted = true
	-- v1: the cursor goes to the inventory, which inventory sync carries. Only with a prompt: a crossing answered none
	-- (a zone with no destination at the world's rim, retried every RETRY ticks there) leaves the cursor alone.
	player.clear_cursor()
	player.connect_to_server({ address = p.address, name = p.name, description = "Universal Edges: across this border" })
	emit("prompt", "info", p.trace, { player = p.player, key = pending.key })
	return true
end)

--- No destination for any key (§4 step 4): logged; the crossing stays and retries after RETRY ticks.
bridge.on("universal_edges", "ue.player.none", function(p)
	if type(p.player) ~= "string" or type(p.reason) ~= "string" or type(p.trace) ~= "string" then
		return false
	end
	local pending = state().pending[p.player]
	if pending and pending.trace == p.trace then
		pending.answered = true
	end
	emit("none", "verbose", p.trace, { player = p.player, reason = p.reason })
	return true
end)

--- §4 step 5: name left the game at (x, y). In a zone (its 0.5 band included), the leave point goes to the controller;
--- inside, nothing does. The crossing goes either way. Returns the trace sent, or nil.
function players.leave(name, surface_index, surface_name, x, y)
	local pending = state().pending[name]
	state().pending[name] = nil
	if not players.zone(surface_index, surface_name, x, y, pending and pending.key) then
		return nil
	end
	local id = pending and pending.trace or trace.new_id()
	send("ue.player.left", { player = name, surface = surface_name, x = x, y = y, trace = id })
	emit("left", "info", id, { player = name, surface = surface_name, x = x, y = y })
	return id
end

function players.on_left(event)
	local player = game.get_player(event.player_index)
	if player then
		local p, surface = player.physical_position, player.physical_surface
		players.leave(player.name, surface.index, surface.name, p.x, p.y)
	end
end

--- A connected player of that name, or the character a test registered for it (ue_rt.player_join's stand-in).
function players.online(name)
	local player = game.get_player(name)
	if player and player.connected then
		return player
	end
	local un = state().stand_in and state().stand_in[name]
	local e = un and game.get_entity_by_unit_number(un)
	return e and e.valid and e or nil
end

--- A players.online() result has a body to place or seat (F12): a connected LuaPlayer who is dead, or a spectator
--- mid-download, has none; a character entity (a test's stand-in) is its own.
function players.seatable(target)
	return target.object_name ~= "LuaPlayer" or target.character ~= nil
end

--- Where a recorded point (x, y) lands in this instance for key (§6.2): surface, x, y, box; nil when this instance has
--- no such zone or the point is out of reach. An edge key's point is in the partner's world: mirrored into this side's.
--- A hook's result without a numeric point and a box counts as nil (§7.1), so placement never raises on it.
function players.target(key, surface_name, x, y)
	local h = hook_of(key)
	if h then
		local px, py, box = call(h, "place", surface_name, key, x, y)
		local surface = type(px) == "number" and type(py) == "number" and type(box) == "table"
			and game.get_surface(surface_name)
		if surface then
			return surface, px, py, box
		end
		return nil
	end
	local side, id = edge_side(key)
	local surface = side and v_of(side) and game.get_surface(side.surface_index)
	if not surface then
		return nil
	end
	local mine, theirs = edges.frame(id, side.me), edges.frame(id, side.me == "a" and "b" or "a")
	local mx, my = crossing.mirror(theirs, mine, x, y)
	local px, py = crossing.inside_point(mine, mx, my)
	if not px then
		return nil
	end
	local x1, y1, x2, y2 = crossing.arrival_box(mine, px, py)
	return surface, px, py, { { x1, y1 }, { x2, y2 } }
end

--- Teleport target to a free spot in box, or to (x, y) itself, unchecked, when the box has none (water: playtest 2
--- #3). Returns whether it moved, where it went, and whether that was unchecked.
local function put(target, surface, x, y, box)
	local pos = surface.find_non_colliding_position_in_box("character", box, 0.5)
	if pos then
		return target.teleport(pos, surface), pos, false
	end
	return target.teleport({ x, y }, surface), { x = x, y = y }, true
end

--- §6.3: a body standing in one of this instance's zones goes to the nearest point inside. Returns whether it did.
function players.pull_in(name, target)
	local p, surface = target.position, target.surface
	local key = players.zone(surface.index, surface.name, p.x, p.y, nil)
	if not key then
		return false
	end
	local px, py, box
	if hook_of(key) then
		local _
		_, px, py, box = players.target(key, surface.name, p.x, p.y)
	else
		local side, id = edge_side(key)
		local frame = edges.frame(id, side.me)
		px, py = crossing.inside_point(frame, p.x, p.y)
		if px then
			local x1, y1, x2, y2 = crossing.arrival_box(frame, px, py)
			box = { { x1, y1 }, { x2, y2 } }
		end
	end
	if not px then
		return false
	end
	local moved, pos = put(target, surface, px, py, box)
	emit("pulled_in", "info", nil, { player = name, key = key, x = p.x, y = p.y, placed_x = pos.x, placed_y = pos.y,
		moved = moved })
	return moved
end

--- §6.4: seat name in a vehicle or carriage waiting for them; vehicle.lua fills this. Returns whether they sat.
players.seat = function()
	return false
end

--- §6.1–6.4: name has a body here. Placed from their arrival (the leave point within reach, else the crossing point),
--- or pulled inside when there is none, then seated if a vehicle waits for them.
function players.place(name)
	local s = state()
	local pl = s.placing[name]
	if pl and game.tick > pl.expires then
		s.placing[name], pl = nil, nil
	end
	local target = players.online(name)
	if not (pl and target and players.seatable(target)) then
		return
	end
	local e = pl.entry
	local placed = false
	if e then
		local surface, x, y, box, point
		if e.left then
			surface, x, y, box = players.target(e.key, e.left.surface, e.left.x, e.left.y)
			point = "left"
		end
		if not surface then
			surface, x, y, box = players.target(e.key, e.surface, e.x, e.y)
			point = "crossed"
		end
		if surface then
			local moved, pos, unchecked = put(target, surface, x, y, box)
			placed = moved
			emit(moved and "arrived" or "arrive_skipped", (unchecked or not moved) and "warn" or "info", e.trace, {
				player = name, key = e.key, point = point, x = x, y = y, placed_x = pos.x, placed_y = pos.y,
				reason = (not moved and "placement_failed") or (unchecked and "no_free_spot") or nil,
			})
		else
			emit("arrive_skipped", "warn", e.trace, { player = name, key = e.key, reason = "no_zone" })
		end
	end
	if not placed then
		players.pull_in(name, target)
	end
	if players.seat(name, target) then
		s.placing[name] = nil
	end
end

local place_task = scheduler.once({
	name = "ue.player.place",
	cap = 256,
	per_tick = 8,
	fn = players.guarded(function(a)
		players.place(a.name)
	end, "ue.player"),
})

--- §6.1: name joined; the controller is asked for their arrival here.
function players.joined(name)
	state().placing[name] = nil
	send("ue.player.joined", { player = name })
end

function players.on_joined(event)
	local player = game.get_player(event.player_index)
	if player then
		players.joined(player.name)
	end
end

--- §6.1: the controller's answer. Kept for PLACING ticks; placed the tick after, if they already have a body.
bridge.on("universal_edges", "ue.player.arrival", function(p)
	local e = p.entry
	if type(p.player) ~= "string" or (e ~= nil and (type(e) ~= "table" or type(e.key) ~= "string"
		or type(e.surface) ~= "string" or type(e.x) ~= "number" or type(e.y) ~= "number" or type(e.trace) ~= "string")) then
		return false
	end
	state().placing[p.player] = { entry = e, expires = game.tick + players.PLACING }
	if e then
		emit("arrival_fetched", "info", e.trace, { player = p.player, key = e.key, x = e.x, y = e.y,
			left_x = e.left and e.left.x, left_y = e.left and e.left.y })
	end
	local target = players.online(p.player)
	if target and players.seatable(target) then
		place_task.schedule(1, { name = p.player })
	end
	return true
end)

--- §6.1: name's character handed back from old_type. Only from spectator or god (inventory_sync's download ending)
--- while an arrival waits: a respawn, the editor or remote view never moves them.
function players.body(name, old_type)
	if old_type ~= defines.controllers.spectator and old_type ~= defines.controllers.god then
		return
	end
	local pl = state().placing[name]
	if pl and game.tick <= pl.expires then
		place_task.schedule(1, { name = name })
	end
end

function players.on_controller(event)
	local player = game.get_player(event.player_index)
	if player and player.controller_type == defines.controllers.character then
		players.body(player.name, event.old_type)
	end
end

--- §7.3: a rider's key at a vehicle's commit: its edge when it crossed within [0, L), else the first hook's zone for
--- its position (where its second hop ends), else nil (no prompt).
function players.route(ep, x, y)
	if crossing.within(ep.frame, x, y) then
		return "edge:" .. ep.edge
	end
	local surface = game.get_surface(ep.frame.surface_index)
	if not surface then
		return nil
	end
	for _, h in ipairs(players.hooks) do
		local key = call(h, "zone", surface.name, x, y, nil)
		if key then
			return key
		end
	end
end

return players
