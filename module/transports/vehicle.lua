-- The built-in vehicle connector type (SP3 spec §10, F7, D26, D35, D36): cars, tanks and spidertrons cross any edge
-- of a live side (cid "v") over a unique lane in hold mode, with their riders, at corners too. A watch task tests the
-- watched vehicles every 10 ticks; a capture freezes the vehicle until the destination answers, so its position and
-- speed are exact when it spawns there.
local bridge = require("modules/universal_edges/runtime/bridge")
local scheduler = require("modules/universal_edges/runtime/scheduler")
local serialize = require("modules/clusterio/serialize")
local connectors = require("modules/universal_edges/edges/connectors")
local crossing = require("modules/universal_edges/transports/crossing_core")
local body_core = require("modules/universal_edges/transports/body_core")
local hooks = require("modules/universal_edges/transports/hooks")
local players = require("modules/universal_edges/transports/players")
local missing = require("modules/universal_edges/transports/missing_core") -- SP3b review I1: shared with train.lua

local vehicle = { TYPES = { car = true, ["spider-vehicle"] = true } }
local send = bridge.channel("universal_edges")
local EMPTY = {} -- M1: a shared empty table, so an idle surface's watch pass allocates nothing

local function emit(ep, phase, level, fields)
	fields.op, fields.phase, fields.level, fields.tick = "ue.vehicle", phase, level, game.tick
	fields.edge, fields.cid, fields.trace = ep and ep.edge, ep and ep.cid, fields.trace or (ep and ep.trace)
	send("trace", fields)
end

local function out_dir(ep)
	return ep.me == "a" and "ab" or "ba"
end

--- A rider's player name: a character's player, or a LuaPlayer itself.
local function name_of(r)
	if not r then
		return nil
	end
	if r.object_name == "LuaPlayer" then
		return r.name
	end
	return r.player and r.player.name
end

local function occupied(v)
	return v.get_driver() ~= nil or v.get_passenger() ~= nil
end

--- The vehicle endpoint of the first live, active side on v's surface whose line v is past (§10.3): a side that has
--- it within its own [0, L) wins outright; otherwise the first side whose margin reaches it (I3).
--- ponytail: two sides' margins both reaching the same point happens only at a genuine corner square — plain,
--- far-apart sides never do (geometry_core.MARGIN vs. real tile spacing). Picking the first match there is a
--- harmless tie-break since either hop is a legitimate first leg. Add a disambiguator if a layout is ever found
--- where two unrelated (non-corner) sides' margins overlap.
function vehicle.crossed(v)
	local s = storage.universal_edges
	local p = v.position
	local margin
	for id in pairs(s.by_surface[v.surface_index] or EMPTY) do
		local side = s.edges[id]
		-- M4: by the side's cached key (players.v_of), not connectors.get's concatenation per side per pass; ep.frame is
		-- the side's frame, stored once when the endpoint was made.
		local ep = side.active and not side.deleted and players.v_of(side)
		if ep and crossing.vehicle_past(ep.frame, p.x, p.y) then
			if crossing.within(ep.frame, p.x, p.y) then
				return ep
			end
			margin = margin or ep
		end
	end
	return margin
end

--- §10.4, crossing spec §6.4: a waiting vehicle moves on, its driver sat ("driver_sat") or its wait ran out ("ttl",
--- drop: the entry goes). A carriage is never let go here: only vehicle.TYPES are held by this transport.
function vehicle.release(un, why, drop)
	local s = storage.universal_edges
	local w = s.waiting[un]
	if w then
		if why == "driver_sat" then
			w.driver = nil
		end
		if drop or not (w.driver or w.passenger) then
			s.waiting[un] = nil
		end
	end
	local v = game.get_entity_by_unit_number(un)
	if v and v.valid and vehicle.TYPES[v.type] and v.disabled_by_script then
		v.disabled_by_script = false
		emit(nil, "released", "info", { unit_number = un, reason = why })
	end
end

-- §10.2: the watch. It runs under players.guarded (F12): outside a hook, a raise would stop the server.
local watch = players.guarded(function(tick)
	local s = storage.universal_edges
	for un, v in pairs(s.watch) do
		if not v.valid or s.rejected[un] then
			s.watch[un] = nil
		else
			local ep = vehicle.crossed(v)
			if ep then
				connectors.call(ep, "capture", v) -- F12
			elseif not (occupied(v) or (v.type == "spider-vehicle" and v.autopilot_destination)) then
				s.watch[un] = nil
			end
		end
	end
	for un, f in pairs(s.waiting) do
		if tick >= f.expires then
			vehicle.release(un, "ttl", true)
		end
	end
end, "ue.vehicle")

-- §13 rule 1: an empty watch and no waiting seat cost one next() each, before the guard's pcall (final review M5).
scheduler.periodic({
	name = "ue.vehicle.watch",
	interval = 10,
	fn = function(tick)
		local s = storage.universal_edges
		if next(s.watch) == nil and next(s.waiting) == nil then
			return
		end
		watch(tick)
	end,
})

--- A property of v, nil when v's type has none: some of these raise on a type without them (§10.2).
local function read(v, key)
	local ok, value = pcall(function() return v[key] end)
	if ok then
		return value -- false is a setting too (destructible, operable, driver_is_gunner, …): never "ok and value or nil"
	end
end

local SCALARS = { "selected_gun_index", "driver_is_gunner", "allow_dispatching_robots", "enable_logistics_while_moving",
	"consumption_modifier", "effectivity_modifier", "friction_modifier", "torso_orientation", "destructible", "operable" }

--- The requester point of v, which a car has none of.
local function requester(v)
	local ok, points = pcall(v.get_logistic_point)
	if not (ok and points) then
		return nil
	end
	if points.object_name == "LuaLogisticPoint" then
		points = { points }
	end
	for _, point in ipairs(points) do
		if point.mode == defines.logistic_mode.requester then
			return point
		end
	end
end

--- §10.2, owner 2026-10-07 ("vehicles should cross exactly as they are"): what a vehicle is set to besides what it
--- holds, each only when v has it: weapons, logistics (the requester's switches and its manual sections, in order,
--- a section's group by name) and a car's modifiers. Not follow_target, which is local to this server.
local function settings(v)
	local st = {}
	for _, key in ipairs(SCALARS) do
		st[key] = read(v, key)
	end
	st.targeting = read(v, "vehicle_automatic_targeting_parameters")
	local point = requester(v)
	if point then
		st.point = { enabled = point.enabled, trash_not_requested = point.trash_not_requested }
	end
	local ok, secs = pcall(v.get_logistic_sections)
	if ok and secs then
		st.sections = {}
		for _, sec in ipairs(secs.sections) do
			if sec.is_manual then
				st.sections[#st.sections + 1] = { group = sec.group, active = sec.active, multiplier = sec.multiplier,
					filters = sec.filters }
			end
		end
	end
	return st
end

--- The facts body_core needs, read from v; riders' names live or carried in (§10.3).
local function facts(v, carried)
	local inv = {}
	for i = 1, v.get_max_inventory_index() do
		local x = v.get_inventory(i)
		if x then
			inv[i] = serialize.serialize_inventory(x)
		end
	end
	local burning
	local burner = v.burner
	if burner and burner.currently_burning then
		local cb = burner.currently_burning
		burning = { name = cb.name.name, quality = cb.quality and cb.quality.name, remaining = burner.remaining_burning_fuel }
	end
	return {
		name = v.name, quality = v.quality.name, type = v.type, x = v.position.x, y = v.position.y,
		orientation = v.orientation, speed = v.speed, health = v.health, color = v.color, label = v.entity_label,
		inventories = inv, grid = v.grid and serialize.serialize_equipment_grid(v.grid), burning = burning,
		destinations = v.type == "spider-vehicle" and v.autopilot_destinations or nil,
		patrol = v.type == "spider-vehicle" and v.autopilot_patrol_size or nil,
		driver = name_of(v.get_driver()) or carried.driver, passenger = name_of(v.get_passenger()) or carried.passenger,
		state = settings(v),
	}
end

--- A vehicle's logistic sections from the body, in order (§10.4, owner: "seed if missing"): a section whose group
--- exists on this force joins it and the group's filters here win; a group not here yet is made by this section's.
local function restore_sections(v, sections)
	local secs = v.get_logistic_sections()
	if not secs then
		return
	end
	for i = secs.sections_count, 1, -1 do
		secs.remove_section(i) -- only manual ones go; the rest are the game's own
	end
	local force = v.force
	for _, data in ipairs(sections) do
		local group = data.group ~= "" and data.group or nil
		local joined = group and force.get_logistic_group(group) ~= nil
		local sec = secs.add_section(joined and group or nil)
		if sec then
			if group and not joined then
				sec.group = group
			end
			if not joined then
				sec.filters = data.filters
			end
			sec.active, sec.multiplier = data.active, data.multiplier
		end
	end
end

--- §10.4: a credited vehicle's state from its body: health, colour, label, inventories, grid, burner, speed (D36), a
--- spidertron's destinations in order with their patrol size, and its settings (see settings).
function vehicle.restore_body(v, body, dest)
	v.health = body.health or v.health
	if body.color then
		v.color = body.color
	end
	if body.label then
		v.entity_label = body.label
	end
	for i, data in pairs(body.inv or {}) do
		local inv = v.get_inventory(tonumber(i))
		if inv then
			serialize.deserialize_inventory(inv, data)
		end
	end
	if body.grid and v.grid then
		serialize.deserialize_equipment_grid(v.grid, body.grid)
	end
	if body.burning and v.burner then
		v.burner.currently_burning = { name = body.burning.name, quality = body.burning.quality }
		v.burner.remaining_burning_fuel = body.burning.remaining
	end
	if body.speed then
		v.speed = body.speed -- D36: the speed at capture
	end
	for _, p in ipairs(dest or {}) do
		v.add_autopilot_destination(p)
	end
	if body.patrol then
		v.autopilot_patrol_size = body.patrol
	end
	local st = body.state or {}
	for _, key in ipairs(SCALARS) do
		if st[key] ~= nil then
			v[key] = st[key]
		end
	end
	if st.targeting then
		v.vehicle_automatic_targeting_parameters = st.targeting
	end
	local point = st.point and requester(v)
	if point then
		point.enabled, point.trash_not_requested = st.point.enabled, st.point.trash_not_requested
	end
	if st.sections then
		restore_sections(v, st.sections)
	end
end

--- Crossing spec §6.4: seat name in the vehicle or carriage waiting for them, once they are placed. A driver sitting
--- releases a held vehicle. A seat whose vehicle is gone (crossed on, destroyed) is dropped, logged, and the next one
--- naming them is tried. Returns whether they sat.
players.seat = function(name, target)
	local s = storage.universal_edges
	for un, w in pairs(s.waiting) do
		local role = (w.driver == name and "driver") or (w.passenger == name and "passenger") or nil
		if role and not w.onward then
			local v = game.get_entity_by_unit_number(un)
			if v and v.valid then
				-- set_passenger exists only for cars, spidertrons and cargo pods: rolling stock has one seat.
				if role == "driver" or not vehicle.TYPES[v.type] then
					v.set_driver(target)
				else
					v.set_passenger(target)
				end
				send("trace", { op = "ue.player", phase = "seated", level = "info", tick = game.tick, trace = w.trace,
					player = name, unit_number = un, seat = role })
				if role == "driver" then
					vehicle.release(un, "driver_sat")
				else
					w.passenger = nil
					if not w.driver then
						s.waiting[un] = nil
					end
				end
				return true
			end
			s.waiting[un] = nil -- clearing a field pairs() is on is allowed
			send("trace", { op = "ue.player", phase = "seat_gone", level = "warn", tick = game.tick, trace = w.trace,
				player = name, unit_number = un })
		end
	end
	return false
end

connectors.register_type({
	name = "vehicle",
	builtin = "v", -- F7
	lanes = function() return { ab = "unique", ba = "unique" } end,
	schedule = { per_tick = 2, interval = 300 },
	build = function() return "ready" end,
	teardown = function() end,
	poll = function() end, -- §5.1: vehicles capture in the watch, never in a poll
	--- §10.2: encode, send at once (F3), freeze and hold. A vehicle that is disabled but isn't a waiting arrival is held
	--- by another edge (a corner is past two lines) or by some script: it is left alone.
	capture = function(ep, v)
		local s = storage.universal_edges
		local un = v.unit_number
		local dir = out_dir(ep)
		if (v.disabled_by_script and not s.waiting[un]) or not ep:can_send(dir) then
			return
		end
		local body = body_core.body(ep.frame, facts(v, s.waiting[un] or {}))
		body.ext = hooks.capture(ep, v)
		local seq, why = ep:send(dir, body)
		if not seq then
			s.rejected[un] = true
			emit(ep, "rejected", "error", { unit_number = un, reason = why })
			hooks.restored(ep, v, why) -- SP4 §7.5: an extension's state rides on, refused (why: "too_big", F4)
			return
		end
		if v.type == "spider-vehicle" and v.follow_target then
			-- M3: only once the send actually took it, not on every attempt (a too_big body drops nothing)
			emit(ep, "follow_dropped", "info", { unit_number = un }) -- §10.2: the target is local to this server
		end
		v.disabled_by_script = true
		s.watch[un], s.waiting[un] = nil, nil
		ep.data.held = ep.data.held or {}
		-- I2: the live rider here, not the body's name — a carried name rides on in the body only; held is for
		-- commit's prompt, which must fire only for someone truly seated on this vehicle, on this server.
		ep.data.held[dir] = { v = v, driver = name_of(v.get_driver()), passenger = name_of(v.get_passenger()) }
	end,
	--- §10.4: place within 8 of the mirrored point and inside, restore, seat who is here, freeze for a missing driver.
	credit = function(ep, dir, body, meta)
		if type(body) ~= "table" or body.v ~= 1 then
			return "reject"
		end
		-- review I1: the same silent void as train.lua's credit, through the same deserialize_inventory. Checked
		-- before anything is created (G5); this also covers body.name/body.quality, replacing the old ad hoc
		-- prototypes.entity[body.name] check.
		local inventories = {}
		for _, s in pairs(body.inv or {}) do
			inventories[#inventories + 1] = s
		end
		if missing.missing(body.name, body.quality, inventories,
			{ entity = prototypes.entity, item = prototypes.item, quality = prototypes.quality }) then
			return "reject"
		end
		local surface = game.get_surface(ep.frame.surface_index)
		local x, y, o, dest = body_core.landing(ep.frame, body)
		local x1, y1, x2, y2 = crossing.arrival_box(ep.frame, x, y)
		local pos = surface and surface.find_non_colliding_position_in_box(body.name, { { x1, y1 }, { x2, y2 } }, 0.5)
		local v = pos and surface.create_entity({ name = body.name, quality = body.quality, position = pos, orientation = o,
			force = "player" })
		if not v then
			emit(ep, "no_room", "warn", { trace = meta.trace })
			return "busy"
		end
		-- Atomic: restoring and seating both run before the vehicle is trusted; a raise from either (I1: set_driver
		-- raises for a player without a character, same as restoring) destroys it, so the source's re-offer can't
		-- make a second one (G6).
		local waiting = {}
		local ok, err = pcall(function()
			vehicle.restore_body(v, body, dest)
			for _, role in ipairs({ "driver", "passenger" }) do
				local name = body[role]
				local here = name and players.online(name)
				if here and players.seatable(here) then
					if role == "driver" then
						v.set_driver(here)
					else
						v.set_passenger(here)
					end
					-- M4: seated straight away logs the same as a rider seated later (players.seat, above)
					send("trace", { op = "ue.player", phase = "seated", level = "info", tick = game.tick,
						trace = meta.trace, player = name, edge = ep.edge, unit_number = v.unit_number, seat = role })
					-- Seated, so an arrival still placing them is done: inventory_sync handing their character back
					-- would otherwise place them again, out of the seat (crossing spec §6.1 step 4).
					storage.universal_edges.players.placing[name] = nil
				elseif name then
					-- A character-less online rider (dead, respawning) is treated like an offline one: set_driver/
					-- set_passenger would raise for them (F12), so the vehicle waits for them instead.
					waiting[role] = name
				end
			end
		end)
		if not ok then
			-- Refuse on raise (final review, matching trains' H1): a raise here is a credit-time reject (a
			-- characterless online rider, or the deserialize_inventory void review I1 already checks for), not a
			-- framework failure. error(err) used to fail the edge's shared v endpoint on every re-offer of the
			-- same body (a poison pill, stopping vehicle crossings both ways until the next reconcile).
			if v.valid then
				v.destroy()
			end
			emit(ep, "rejected", "error", { trace = meta.trace, reason = tostring(err) })
			return "reject"
		end
		local s, un = storage.universal_edges, v.unit_number
		-- A corner's middle tile: already past another line, so the next watch pass sends it on (§10.3).
		local onward = vehicle.crossed(v) ~= nil
		if waiting.driver or waiting.passenger or onward then
			-- D36: a driven vehicle waits held still for its driver; at a middle tile every vehicle waits held still with
			-- the body's speed for its onward capture (M3), its riders' names riding on in the body, not seated here (I2).
			v.disabled_by_script = waiting.driver ~= nil or onward
			s.waiting[un] = { driver = waiting.driver, passenger = waiting.passenger, expires = game.tick + players.WAIT,
				onward = onward or nil, trace = meta.trace }
		end
		s.watch[un] = v -- arrived past a line, perhaps (a corner's middle tile): the next pass sends it on, or drops it
		ep:materialized(dir, v, body.ext, meta)
		return "ok"
	end,
	--- §10.4, crossing spec §7.3: the destination has it. Its riders are prompted for where it ends up (players.route),
	--- under the vehicle crossing's trace, held until answered.
	commit = function(ep, dir, _, id)
		local held = ep.data.held and ep.data.held[dir]
		if ep.data.held then
			ep.data.held[dir] = nil
		end
		local v = held and held.v
		if v and v.valid then
			local p = v.position
			local key = players.route(ep, p.x, p.y)
			-- §4 step 2: a hook's key carries the edge crossed as its fallback, so a corner with no diagonal tile still
			-- takes the rider across that edge, as it takes the vehicle.
			local edge = "edge:" .. ep.edge
			local fallback = key ~= edge and edge or nil
			if key then
				for _, name in ipairs({ held.driver or false, held.passenger or false }) do
					if name then
						players.cross(name, key, fallback, v.surface.name, p.x, p.y, id, true)
					end
				end
			end
			v.destroy({ raise_destroy = true })
		end
		return true
	end,
	--- A reject (M8) unfreezes and marks the vehicle until a driver change; a close only unfreezes it (§10.4).
	restore = function(ep, dir)
		local held = ep.data.held and ep.data.held[dir]
		if ep.data.held then
			ep.data.held[dir] = nil
		end
		local v = held and held.v
		if v and v.valid then
			v.disabled_by_script = false
			if ep.closing then
				storage.universal_edges.watch[v.unit_number] = v
			else
				storage.universal_edges.rejected[v.unit_number] = true
				emit(ep, "rejected", "error", { unit_number = v.unit_number })
			end
			hooks.restored(ep, v, ep.closing and "close" or "reject") -- SP4 §7.5, as trains do
		end
		return true
	end,
})

--- on_player_driving_changed_state: a driver change clears a reject (M8), an occupied vehicle is watched, and a waiting
--- vehicle's driver sitting releases it (§10.2, §10.4).
function vehicle.on_driving(event)
	local v = event.entity
	if not (v and v.valid and vehicle.TYPES[v.type]) then
		return
	end
	local s, un = storage.universal_edges, v.unit_number
	s.rejected[un] = nil
	if occupied(v) then
		s.watch[un] = v
	end
	local f = s.waiting[un]
	if f and f.driver and name_of(v.get_driver()) == f.driver then
		vehicle.release(un, "driver_sat")
	end
end

--- The vehicles export (ue.vehicles.watch, for any module that steers vehicles by script): v goes on the watch, as
--- boarding it does (§10.2), and a rejected mark is cleared, as a driver change does (§10.4). The caller decides when to
--- retry; the restored hook tells it why a crossing was refused (D-3, owner 2026-10-09).
function vehicle.watch(v)
	if v and v.valid and vehicle.TYPES[v.type] then
		storage.universal_edges.rejected[v.unit_number] = nil
		storage.universal_edges.watch[v.unit_number] = v
	end
end

--- The spidertrons a remote steers go on the watch (§10.2).
function vehicle.watch_selection(list)
	for _, sp in pairs(list) do
		if sp.valid then
			storage.universal_edges.watch[sp.unit_number] = sp
		end
	end
end

--- on_player_used_spidertron_remote.
function vehicle.on_remote(event)
	local player = game.get_player(event.player_index)
	vehicle.watch_selection(player and player.spidertron_remote_selection or {})
end

return vehicle
