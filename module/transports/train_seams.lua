-- Test seams for the train transport (SP3 spec §15). They ship with the module, inert unless called, like the probe
-- type (SP1 §10.6): test edges with a scripted partner, a player's track, trains on it, and what is there. The game
-- tests call them directly; the E2E and the bench through ue_rt.train_test.
local bridge = require("modules/universal_edges/runtime/bridge")
local geometry = require("modules/universal_edges/edges/geometry_core")
local connectors = require("modules/universal_edges/edges/connectors")
local train = require("modules/universal_edges/transports/train")
local core = require("modules/universal_edges/transports/train_core")
local hooks = require("modules/universal_edges/transports/hooks") -- SP3a Task 1: hooks.extend (§11, C4)

local seams = {}
local L = 64
local CARRIAGE = { L = "locomotive", l = "locomotive", C = "cargo-wagon", F = "fluid-wagon", A = "artillery-wagon" }
local STATE = {}
for name, value in pairs(defines.train_state) do
	STATE[value] = name
end

-- The E2E's extension (§15): with storage.universal_edges.train_test_hop set at the source, a crossing train is sent to
-- that station first on arrival, as SP4's route state will do (D22). Inert while unset.
hooks.extend{
	name = "ue-test",
	types = { train = true },
	capture = function()
		local hop = storage.universal_edges.train_test_hop
		return hop and { hop = hop } or nil
	end,
	materialized = function(_, tr, data)
		if data and data.hop then
			local sched = tr.get_schedule()
			sched.add_record{ station = data.hop, temporary = true, index = { schedule_index = 1 } }
			sched.go_to_station(1)
		end
	end,
}

--- One message into this instance's inbox, from the sender 5eed0000 (its own dedup range, SP1b house facts).
local function deliver(msg_type, payload)
	local s = storage.universal_edges
	s.train_seam_n = (s.train_seam_n or 0) + 1
	bridge.inbox("universal_edges", helpers.table_to_json({ { id = "5eed0000." .. s.train_seam_n, type = msg_type, payload = payload } }))
end

local function generate(s, frame, x1, y1, x2, y2)
	local ax, ay, bx, by = geometry.area_to_world(frame, x1, y1, x2, y2)
	for cx = ax, bx + 31, 32 do
		for cy = ay, by + 31, 32 do
			s.request_to_generate_chunks({ cx, cy }, 0)
		end
	end
	s.force_generate_chunk_requests()
	return { { ax, ay }, { bx, by } }
end
seams.generate = generate -- a game test's own track past seams.track's strip

--- This instance's train endpoint of (edge, cid); errors when there is none.
function seams.endpoint(edge, cid)
	local side = storage.universal_edges.edges[edge]
	local ep = side and connectors.get(side, cid)
	if not (ep and ep.type == "train") then
		error("no train endpoint " .. tostring(edge) .. "/" .. tostring(cid))
	end
	return ep
end

--- A game-test edge with a scripted partner: this instance is side a of edge id, of length 64, on the lab surface
--- o.surface (default "sp3b"; SP4's two-planets cases make a second, "sp4v"), made on first use.
--- Side a is at (0, y) facing o.facing (default north), and side b is coincident at its far end. The chunks around each
--- connector are generated first, so the boxes build on their first visit. The revision is o.rev (default 1), and
--- revision 1 also activates the edge under epoch "<id>.e". A later revision replaces the connector list.
function seams.edge(id, y, list, o)
	o = o or {}
	local name = o.surface or "sp3b"
	local s = game.get_surface(name)
	if not s then
		s = game.create_surface(name)
		s.generate_with_lab_tiles, s.always_day = true, true
	end
	local f, rev = o.facing or 0, o.rev or 1
	local dx, dy = geometry.rot(1, 0, f)
	local a = { instanceId = 1, surface = name, origin = { 0, y }, facing = f }
	local b = { instanceId = 2, surface = name, origin = { L * dx, y + L * dy }, facing = (f + 8) % 16 }
	local frame = { origin = a.origin, facing = f, length = L }
	for _, c in ipairs(list) do
		local cx = c.pos + (c.width or core.WIDTH) / 2
		generate(s, frame, cx - 8, core.rail_y(core.IN_RAILS) - 8, cx + 8, 320)
	end
	deliver("ue.edge.update", { edge = { id = id, revision = rev, trace = id .. ".t", me = "a", owner = "test", length = L,
		deleted = false, connectors = list, a = a, b = b } })
	if rev == 1 then
		deliver("ue.edge.activation", { id = id, active = true, epoch = id .. ".e", trace = id .. ".e" })
	end
end

--- The partner endpoint of (id, cid) announces itself ready, with status (§10.2).
function seams.partner(id, cid, status)
	deliver("ue.lane", { edge = id, epoch = id .. ".e", k = "ep", cid = cid, state = "ready", status = status })
end

--- Any lane message from the partner, in the edge's epoch.
function seams.lane(id, fields)
	fields.edge, fields.epoch = id, id .. ".e"
	deliver("ue.lane", fields)
end

--- A connector's strip at local x, from past the inbound box out to local y depth inward: generated, cleared of trees,
--- rocks, cliffs and fish, and its water landfilled (dev maps aren't lab tiles). Returns the world area.
local function clear(s, frame, x, depth)
	local area = generate(s, frame, x - 3, core.rail_y(core.IN_RAILS) - 8, x + 3, depth)
	for _, e in pairs(s.find_entities_filtered{ area = area, type = { "tree", "simple-entity", "cliff", "fish" } }) do
		if not connectors.owns(e) then
			e.destroy()
		end
	end
	local water = {}
	for _, tile in pairs(s.find_tiles_filtered{ area = area, collision_mask = "water_tile" }) do
		water[#water + 1] = { name = "landfill", position = tile.position }
	end
	s.set_tiles(water)
	return area
end

--- The player's side of the connector: `rails` straight rails inward from the border row, of the connector's layer.
--- The strip is generated, cleared of trees, rocks and cliffs, and has its water landfilled (dev maps aren't lab
--- tiles). With station, on ground rails, there is a stop for inward travel beside the last rail but one.
function seams.track(edge, cid, rails, station)
	local ep = seams.endpoint(edge, cid)
	local s = game.get_surface(ep.frame.surface_index)
	local x = train.cx(ep)
	clear(s, ep.frame, x, 2 * rails + 2)
	local name = ep.params.layer == "elevated" and "elevated-straight-rail" or "straight-rail"
	local axis = geometry.dir_to_world(ep.frame, 0)
	for i = 1, rails do
		local wx, wy = train.world(ep, x, 2 * i - 1)
		if not s.find_entity(name, { wx, wy }) then
			assert(s.create_entity{ name = name, position = { wx, wy }, direction = axis, force = train.FORCE }, "track rail " .. i)
		end
	end
	-- so seams.trains searches exactly as far as the track this call built (review I1): no fixed reach fits every
	-- task's rows, since later tasks build longer tracks than this one's.
	storage.universal_edges.train_seam_reach = storage.universal_edges.train_seam_reach or {}
	storage.universal_edges.train_seam_reach[ep.key] = 2 * rails + 2
	if station and ep.params.layer ~= "elevated" then
		local wx, wy = train.world(ep, x - 2, 2 * rails - 3)
		local stop = s.find_entity("train-stop", { wx, wy })
		local made = stop == nil
		stop = stop or assert(s.create_entity{ name = "train-stop", position = { wx, wy }, direction = train.inward(ep),
			force = train.FORCE }, "stop")
		stop.backer_name = station
		if made then
			-- a script-made stop raises nothing, so routing's registry (SP4 stops.lua) wouldn't know it until a resync (SP4 Task 9)
			script.raise_script_built{ entity = stop }
		end
	end
end

--- The player's side of a train link not made yet (train box direction spec §9), at local column col of side `edge` (this
--- instance's): the strip cleared, old player rails and signals included; `rails` straight rails inward from local y 3;
--- a rail signal at the border rail's inner end for trains heading out ("out") or coming in ("in"); then the border rail,
--- raised. The signal goes first, as robots build a blueprint's, so the generic box decides at its build.
function seams.border(edge, col, which, rails)
	local side = storage.universal_edges.edges[edge]
	local mine = side[side.me]
	local f = { origin = mine.origin, facing = mine.facing, length = side.length }
	local s = game.get_surface(side.surface_index)
	local x = col + core.WIDTH / 2
	local area = clear(s, f, x, 2 * rails + 2)
	for _, e in pairs(s.find_entities_filtered{ area = area, type = { "straight-rail", "rail-signal", "rail-chain-signal" } }) do
		if not connectors.owns(e) then
			e.destroy()
		end
	end
	local axis = geometry.dir_to_world(f, 0)
	local inner
	for i = 2, rails do
		local wx, wy = geometry.to_world(f, x, 2 * i - 1)
		local r = assert(s.create_entity{ name = "straight-rail", position = { wx, wy }, direction = axis, force = train.FORCE },
			"track rail " .. i)
		inner = inner or r
	end
	-- rail centres snap to odd columns, so an even x lands one column over: fail here, not as a link at another pos
	local bx = geometry.to_local(f, inner.position.x, inner.position.y)
	assert(math.abs(bx - x) < 0.01, "border rail stands at local column " .. (bx - core.WIDTH / 2) .. ", not the requested " .. col
		.. " (use an odd column)")
	local signaled = false
	for _, dir in pairs(defines.rail_direction) do
		local re = inner.get_rail_end(dir)
		local _, ly = geometry.to_local(f, re.location.position.x, re.location.position.y)
		if math.abs(ly - 2) < 0.01 then
			local spot = which == "in" and re.in_signal_location or re.out_signal_location
			assert(s.create_entity{ name = "rail-signal", position = spot.position, direction = spot.direction,
				force = train.FORCE, raise_built = true }, "signal")
			signaled = true
		end
	end
	assert(signaled, "no rail end at local y 2 to place the signal at")
	local wx, wy = geometry.to_world(f, x, 1)
	assert(s.create_entity{ name = "straight-rail", position = { wx, wy }, direction = axis, force = train.FORCE,
		raise_built = true }, "border rail")
end

--- A train on the track heading out to the box: o.layout's carriages front first from local y = o.at, 7 apart (L a
--- locomotive facing out, l one facing in, C, F, A wagons). Its records are the edge record (the box's end rail),
--- temporary unless o.permanent, then o.next; with o.interrupts. Locomotives get o.coal (50) coal,
--- and the first cargo wagon o.cargo iron plates. It runs automatic unless o.manual, at speed o.speed (0) outward.
--- Returns the front carriage's unit number.
function seams.add(edge, cid, o)
	local ep = seams.endpoint(edge, cid)
	local s = game.get_surface(ep.frame.surface_index)
	local d, x = ep.data, train.cx(ep)
	local outward = geometry.dir_to_world(ep.frame, 0)
	local first, cargo = nil, o.cargo
	for i = 1, #o.layout do
		local letter = string.sub(o.layout, i, i)
		local wx, wy = train.world(ep, x, o.at + 7 * (i - 1))
		local p = { name = CARRIAGE[letter], position = { wx, wy }, force = train.FORCE,
			orientation = (outward / 16 + (letter == "l" and 0.5 or 0)) % 1 }
		if p.name == "locomotive" then
			p.snap_to_train_stop = false
		end
		local c = assert(s.create_entity(p), "carriage " .. i .. " of " .. o.layout)
		if p.name == "locomotive" then
			c.get_fuel_inventory().insert{ name = "coal", count = o.coal or 50 }
		elseif p.name == "cargo-wagon" and cargo then
			c.get_inventory(defines.inventory.cargo_wagon).insert{ name = "iron-plate", count = cargo }
			cargo = nil
		end
		first = first or c
	end
	local tr = first.train
	assert(#tr.carriages == #o.layout, "the carriages of " .. o.layout .. " didn't join")
	local rec = { rail = d.rails[core.OUT_RAILS] } -- SP4 (§5): the end rail on both layers
	rec.temporary = not o.permanent
	local sched = tr.get_schedule()
	sched.set_records({ rec, o.next and { station = o.next } or nil })
	if o.interrupts then
		sched.set_interrupts(o.interrupts)
	end
	sched.go_to_station(1)
	tr.manual_mode = o.manual == true
	tr.speed = (tr.front_end.location.direction == outward and 1 or -1) * (o.speed or 0)
	return first.unit_number
end

--- Every train with a carriage on the connector's strip: its box and the player's track.
function seams.trains(edge, cid)
	local ep = seams.endpoint(edge, cid)
	local x = train.cx(ep)
	-- The box alone when seams.track was never called for this endpoint (review I1): no fixed reach fits every
	-- track a caller might build, so the search goes only as far as the track this endpoint actually has.
	local reach = (storage.universal_edges.train_seam_reach or {})[ep.key] or 0
	local x1, y1, x2, y2 = geometry.area_to_world(ep.frame, x - 1, core.rail_y(core.IN_RAILS) - 2, x + 1, reach)
	local seen, out = {}, {}
	local found = game.get_surface(ep.frame.surface_index).find_entities_filtered{ area = { { x1, y1 }, { x2, y2 } }, type = train.STOCK }
	for _, c in pairs(found) do
		if not seen[c.train.id] then
			seen[c.train.id] = true
			out[#out + 1] = c.train
		end
	end
	return out
end

--- JSON of what the endpoint holds and of every train on its strip.
function seams.state(edge, cid)
	local ep = seams.endpoint(edge, cid)
	local d = ep.data
	local list = {}
	for i, tr in ipairs(seams.trains(edge, cid)) do
		local sched, names, cars = tr.get_schedule(), {}, {}
		for k, r in ipairs(sched.get_records() or {}) do
			names[k] = (r.station or "<rail>") .. (r.temporary and "*" or "")
		end
		for k, c in ipairs(tr.carriages) do
			cars[k] = c.name
		end
		list[i] = { carriages = cars, records = table.concat(names, ","), current = sched.current, state = STATE[tr.state],
			manual = tr.manual_mode, speed = tr.speed, cargo = tr.get_item_count("iron-plate") }
	end
	return helpers.table_to_json({ box = d.box, state = ep.state, partner = ep.partner and ep.partner.state, status = ep.status,
		held = d.held and d.held.seq, queued = d.queue and (#d.queue.carriages - d.queue.next + 1), w = d.w,
		last = d.last and d.last.seq, rejected = d.rejected, trains = list })
end

--- A wagon parked in the inbound box (on), or taken out: it closes or opens the box's outer signal.
function seams.block(edge, cid, on)
	local ep = seams.endpoint(edge, cid)
	local d = ep.data
	if on and not (d.blocker and d.blocker.valid) then
		local x, y = train.world(ep, train.cx(ep), -40)
		d.blocker = game.get_surface(ep.frame.surface_index).create_entity{ name = "cargo-wagon", position = { x, y },
			orientation = core.orientation(ep.frame.facing, false), force = train.FORCE }
	elseif not on and d.blocker and d.blocker.valid then
		d.blocker.destroy()
		d.blocker = nil
	end
end

--- Destroy the trains on the connector's strip; with arrived, only those standing at a station.
function seams.clear(edge, cid, arrived)
	for _, tr in ipairs(seams.trains(edge, cid)) do
		if not arrived or tr.state == defines.train_state.wait_station then
			for _, c in ipairs(tr.carriages) do
				c.destroy()
			end
		end
	end
end

--- ue_rt.train_test(op, edge, cid, json): the seams over RCON. Returns "ok", a unit number, or state JSON.
function seams.call(op, edge, cid, json)
	local o = type(json) == "string" and helpers.json_to_table(json) or json or {}
	if op == "hop" then
		storage.universal_edges.train_test_hop = o.hop
		return "ok"
	elseif op == "track" then
		seams.track(edge, cid, o.rails, o.station)
	elseif op == "add" then
		return tostring(seams.add(edge, cid, o))
	elseif op == "state" then
		return seams.state(edge, cid)
	elseif op == "set" then
		seams.endpoint(edge, cid).data.force_busy = o.busy == true or nil
	elseif op == "block" then
		seams.block(edge, cid, o.on == true)
	elseif op == "clear" then
		seams.clear(edge, cid, o.arrived == true)
	elseif op == "border" then
		seams.border(edge, o.col, o.which, o.rails or 10)
	else
		error("ue_rt.train_test: unknown op " .. tostring(op))
	end
	return "ok"
end

return seams
