-- The train transport (SP3 spec §12, D32): v1's outbound and inbound boxes on either rail layer (D18, D25), a held
-- train waiting at a closed signal (D22), and the read-only box view for SP4 (§12.9). Task 2 adds the spawn side,
-- Task 3 the handoff. The pure rules live in train_core; the test seams in train_seams.lua.
-- A border rail's generic box (train box direction spec) waits here for the first signal up the line to decide.
local geometry = require("modules/universal_edges/edges/geometry_core")
local connectors = require("modules/universal_edges/edges/connectors")
local bridge = require("modules/universal_edges/runtime/bridge")
local detect = require("modules/universal_edges/transports/detect") -- SP3a Task 3: the border entity (§6.2, C8)
local serialize = require("modules/clusterio/serialize")
local scheduler = require("modules/universal_edges/runtime/scheduler")
local players = require("modules/universal_edges/transports/players") -- SP3a Task 6: riders (§9, C9)
local missing = require("modules/universal_edges/transports/missing_core") -- review I1, M3
local hooks = require("modules/universal_edges/transports/hooks") -- SP3a Task 1: F2 (§11, C3)
local core = require("modules/universal_edges/transports/train_core")
local sync = require("modules/universal_edges/schedules/sync") -- train group sync (§5.6)

local train = {}
-- ponytail: the boxes and spawned trains belong to the "player" force; carry the force in the body if a map uses others.
train.FORCE = "player"
train.STOCK = { "locomotive", "cargo-wagon", "fluid-wagon", "artillery-wagon" }
local SIGNAL = defines.signal_state
local send = bridge.channel("universal_edges")

-- Helpers -------------------------------------------------------------------------------------------------------------

function train.world(ep, x, y)
	return geometry.to_world(ep.frame, x, y)
end

function train.local_y(ep, pos)
	local _, y = geometry.to_local(ep.frame, pos.x, pos.y)
	return y
end

--- The rail's centre: the connector spans local columns [col, col + width); links built at 6 keep their width.
function train.cx(ep)
	return ep.col + ep.width / 2
end

--- This side sends on the connector's lane: side a sends ab.
function train.outbound(ep)
	return (ep.params.dir == "ab") == (ep.me == "a")
end

--- The world direction of travel inward (local south).
function train.inward(ep)
	return geometry.dir_to_world(ep.frame, 8)
end

--- A ue.train event (§14), under the crossing's trace when there is one.
function train.event(ep, phase, level, fields)
	fields.op, fields.phase, fields.level, fields.tick = "ue.train", phase, level, game.tick
	fields.edge, fields.cid = ep.edge, ep.cid
	fields.trace = fields.trace or ep.trace
	send("trace", fields)
end

--- An error event, at most once per 3600 ticks per endpoint and phase (§14: anomalies are rate-limited).
function train.error(ep, phase, fields)
	local d = ep.data
	d.errors = d.errors or {}
	local last = d.errors[phase]
	if last and game.tick - last < 3600 then
		return
	end
	d.errors[phase] = game.tick
	train.event(ep, phase, "error", fields)
end

-- Boxes (§12.1, §12.8) --------------------------------------------------------------------------------------------------

--- Our entity named name at world (x, y): adopted if it is already there (F9), else created; nil if it can't be. With
--- axis, an adopted rail must run the same way, or the box is blocked. Also returns whether it was created here and, if
--- adopted, its flags from before (rollback restores them).
local function place(s, name, x, y, fields, axis)
	local e = s.find_entity(name, { x, y })
	if e and axis and e.direction % 8 ~= fields.direction % 8 then
		return nil
	end
	local created = not e
	if not e then
		local p = { name = name, position = { x, y }, force = train.FORCE }
		for k, v in pairs(fields) do
			p[k] = v
		end
		e = s.create_entity(p)
	end
	local was
	if e then
		if not created then
			was = { e.minable_flag, e.destructible, e.operable }
		end
		e.minable_flag, e.destructible, e.operable = false, false, false
	end
	return e, created, was
end

--- Undo place()s noted in undo as { entity, created, was }: destroy what was created, give what was adopted its flags back.
local function rollback(undo)
	for _, u in ipairs(undo) do
		local e = u[1]
		if e.valid then
			if u[2] then
				e.destroy()
			else
				e.minable_flag, e.destructible, e.operable = table.unpack(u[3])
			end
		end
	end
end

--- Destroy list's entities that are still valid.
local function destroy_all(list)
	for _, e in ipairs(list) do
		if e.valid then
			e.destroy()
		end
	end
end

--- A ue-rail-signal at rail's end at local y = ey: "in" for trains entering the rail there, "out" for trains leaving
--- it. [probe] sp3b-plan, facing north: rail 1's "in" spot is v1's box signal, (x + 1.5, -0.5) facing south; rail 50's
--- "in" spot is v1's outer signal, (x - 1.5, -99.5); rail 1's "out" spot is (x - 1.5, -0.5). The spot carries the layer.
local function signal(ep, s, rail, ey, which)
	for _, dir in pairs(defines.rail_direction) do
		local e = rail.get_rail_end(dir)
		if math.abs(train.local_y(ep, e.location.position) - ey) < 0.01 then
			local spot = which == "in" and e.in_signal_location or e.out_signal_location
			return place(s, "ue-rail-signal", spot.position.x, spot.position.y,
				{ direction = spot.direction, rail_layer = spot.rail_layer })
		end
	end
	return nil
end

--- Close the hold signal for good (D22, R8): a wired combinator holds signal-H at 1, and the signal closes on H > 0.
--- [hold probe], [probe] sp3b-plan: trains path through it to the stop or end rail behind it, and wait there.
local function close_for_good(comb, sig)
	local cb = comb.get_or_create_control_behavior()
	local section = cb.get_section(1) or cb.add_section()
	section.set_slot(1, { value = { type = "virtual", name = "signal-H", quality = "normal" }, min = 1 })
	local red = defines.wire_connector_id.circuit_red
	-- script-origin (review M1): players can neither see nor cut this wire, so they can't silently reopen the hold.
	comb.get_wire_connector(red, true).connect_to(sig.get_wire_connector(red, true), true, defines.wire_origin.script)
	local scb = sig.get_or_create_control_behavior()
	scb.close_signal = true
	scb.circuit_condition = { first_signal = { type = "virtual", name = "signal-H" }, comparator = ">", constant = 0 }
end

--- Rail supports under an elevated box (owner 2026-10-05): every 8 rails from rail 1, the outbound box's one moved off the
--- combinator. Each stands at its chosen rail's outward end (y -2, -18, ...) on the rail's axis, facing along the rail;
--- in an outbound or generic box (its foundation, train box direction spec §4), one whose 2.8 x 2.8 footprint would cover
--- the hold combinator's tile (the signal column, cx + 1 .. cx + 2) goes one rail outward at a time. Returns the supports
--- made and whether every one was: a box skips one that can't be created, a generic box is blocked by it. With undo, each
--- place is noted there for rollback.
local SUPPORT_HALF = 1.39
local function supports(frame, s, n, x, axis, outbound, undo)
	local made, complete = {}, true
	local function put(i)
		while i <= n do
			local cy = core.rail_y(i) - 1
			if not (outbound and math.abs(cy - core.COMB_Y) < SUPPORT_HALF + 0.5) then
				local wx, wy = geometry.to_world(frame, x, cy)
				local e, created, was = place(s, "rail-support", wx, wy, { direction = axis })
				if e then
					made[#made + 1] = e
					if undo then
						undo[#undo + 1] = { e, created, was }
					end
				else
					complete = false
				end
				return
			end
			i = i + 1
		end
	end
	for i = 1, n, 8 do
		put(i)
	end
	return made, complete
end

-- Generic boxes (train box direction spec, 2026-10-15) -------------------------------------------------------------------

--- The generic boxes by "<edge id>:<col>" (§4), made on first use (owner, 2026-10-15: no migration, as detect's
--- proposals).
local function generic_boxes()
	local s = storage.universal_edges
	s.generic = s.generic or {}
	return s.generic
end

--- §4: the generic box goes, with its record. A train in its block (it can only have come in from the player's track)
--- keeps the rails, minable again, as teardown keeps an occupied box's (§12.8); the supports go either way, as there.
local function generic_remove(key)
	local generic = generic_boxes()
	local g = generic[key]
	generic[key] = nil
	local first = g.rails[1]
	local occupied = first ~= nil and first.valid and first.trains_in_block > 0
	destroy_all(g.supports)
	for _, r in ipairs(g.rails) do
		if r.valid then
			if occupied then
				r.minable_flag, r.destructible = true, true
			else
				r.destroy()
			end
		end
	end
end

--- §3, §6.1: the first signals up the line from the border rail decide (spike 35: the block calls; get_rail_segment_signal
--- gave nil). One letting trains into the border rail's block heads them out, so this side sends; one letting them out
--- of it brings them in, so the neighbour sends. On a decision, the box is proposed with that direction, once.
local function generic_check(g, side)
	local border = g.border
	local dir = core.box_dir(side.me, border.get_inbound_signals()[1] ~= nil, border.get_outbound_signals()[1] ~= nil)
	if dir then
		g.trace = detect.propose(side, { type = "train", col = g.col, width = g.width, params = { dir = dir, layer = g.layer } },
			border.surface.name, border.position, g.player)
	end
end

--- §4, the train type's detected (detect.lua): a border rail no train endpoint covers builds a generic box, the outbound
--- box's 20 rails and, elevated, its supports, so the box built later adopts them. A generic box at overlapping columns
--- stops it, unless its border rail has gone and the poll hasn't seen that yet: then it goes first. A rail or support
--- that can't be placed undoes the rest (blocked). One decision check follows at once, for a signal already up the line
--- (robots building a blueprint's signal before its rail).
local function generic_build(side, frame, e, proposal, player_index)
	local generic = generic_boxes()
	for key, g in pairs(generic) do
		if g.edge == side.id and proposal.col < g.col + g.width and g.col < proposal.col + proposal.width then
			if g.border.valid then
				return
			end
			generic_remove(key)
		end
	end
	local layer = proposal.params.layer
	local s, x = e.surface, proposal.col + proposal.width / 2
	local axis = geometry.dir_to_world(frame, 0)
	local rails, undo = {}, {}
	for i = 1, core.OUT_RAILS do
		local wx, wy = geometry.to_world(frame, x, core.rail_y(i))
		local created, was
		rails[i], created, was = place(s, layer == "elevated" and "elevated-straight-rail" or "straight-rail", wx, wy,
			{ direction = axis }, true)
		if not rails[i] then
			rollback(undo)
			return
		end
		undo[#undo + 1] = { rails[i], created, was }
	end
	local made, complete = {}, true
	if layer == "elevated" and prototypes.entity["rail-support"] then
		made, complete = supports(frame, s, core.OUT_RAILS, x, axis, true, undo)
	end
	if not complete then
		rollback(undo)
		return
	end
	local g = { edge = side.id, col = proposal.col, width = proposal.width, layer = layer, border = e, rails = rails,
		supports = made, player = player_index }
	generic[side.id .. ":" .. proposal.col] = g
	generic_check(g, side)
end

--- §6.4 (owner, 2026-10-15): a refused proposal's generic box goes; detect has told its builder why. A refusal that
--- finds none (the link took it over already) does nothing.
local function generic_refused(trace_id)
	for key, g in pairs(generic_boxes()) do
		if g.trace == trace_id then
			generic_remove(key)
			return
		end
	end
end

--- §5 (owner, 2026-10-15): each generic box about once a second. Its border rail gone, or
--- its side, the box goes (§4); a proposed one waits for its endpoint (§6.2); any other is checked again (§3). A signal
--- mined from a both-ways pair decides here too, as no build event would.
scheduler.iterate{
	name = "ue.train.generic",
	per_tick = 1,
	interval = 60,
	source = function()
		local s = storage.universal_edges
		return s and s.generic
	end,
	fn = function(key, g)
		local side = storage.universal_edges.edges[g.edge]
		if not (g.border.valid and side and not side.deleted) then
			generic_remove(key)
		elseif not g.trace then
			generic_check(g, side)
		end
	end,
}

--- Build (§12.1), idempotent (F9). Outbound: 20 rails, the box signal at the border, the hold signal and its
--- combinator, on either layer (SP4 §5): the end rail is the trains' target, behind the hold (spike 5 §8).
--- Inbound: 55 rails, the exit signal at the border (R13), and v1's outer signal (train_box.lua:152-238). It places at
--- once, as v1 did: entities created in a chunk not yet generated survive its generation ([probe] sp3b-review).
local function build(ep)
	local s = game.get_surface(ep.frame.surface_index)
	local out = train.outbound(ep)
	local n = out and core.OUT_RAILS or core.IN_RAILS
	if not s then
		return "blocked"
	end
	local d, x = ep.data, train.cx(ep)
	local layer = ep.params.layer or "ground"
	local axis = geometry.dir_to_world(ep.frame, 0)
	local owned = storage.universal_edges.owned
	if d.shape ~= core.SHAPE then -- an old-shape endpoint's hold, combinator and outer signal go before the new build
		for _, k in ipairs({ "hold", "comb", "outer" }) do
			if d[k] and d[k].valid then
				d[k].destroy()
			end
			d[k] = nil
		end
	end
	-- Train box direction spec §6.2: a generic box at these columns becomes this box. One on the other layer (a
	-- neighbour's, Review Focus 3) can't be adopted and goes first; the rail loop and supports below adopt the rest.
	local gkey = ep.edge .. ":" .. ep.col
	local g = generic_boxes()[gkey]
	if g and g.layer ~= layer then
		generic_remove(gkey)
		g = nil
	end
	d.box, d.rails, d.rail_ids = out and "outbound" or "inbound", {}, {}
	for i = 1, n do
		local wx, wy = train.world(ep, x, core.rail_y(i))
		local r = place(s, layer == "elevated" and "elevated-straight-rail" or "straight-rail", wx, wy, { direction = axis }, true)
		if not r then
			return "blocked"
		end
		d.rails[i], d.rail_ids[r.unit_number] = r, true
		if owned[r.unit_number] ~= ep.key then
			ep:own(r)
		end
	end
	d.supports = {}
	if layer == "elevated" and prototypes.entity["rail-support"] then
		d.supports = supports(ep.frame, s, n, x, axis, out)
		for _, e in ipairs(d.supports) do
			ep:own(e)
		end
	end
	if g then -- what this box didn't adopt goes (an inbound box makes no outbound support move), and so does the record
		local kept = {}
		for _, list in ipairs({ d.rails, d.supports }) do
			for _, e in ipairs(list) do
				kept[e.unit_number] = true
			end
		end
		for _, list in ipairs({ g.rails, g.supports }) do
			for _, e in ipairs(list) do
				if e.valid and not kept[e.unit_number] then
					e.destroy()
				end
			end
		end
		generic_boxes()[gkey] = nil
	end
	d.shape = core.SHAPE
	if not out then
		d.exit = signal(ep, s, d.rails[1], 0, "out")
		d.outer = signal(ep, s, d.rails[core.OUTER_RAIL], core.OUTER_END, "in")
		if not (d.exit and d.outer) then
			return "blocked"
		end
		detect.adopt(ep) -- §6.2: the player's border rail, if one stands there (C8)
		return "ready"
	end
	d.box_signal = signal(ep, s, d.rails[1], 0, "in")
	d.hold = signal(ep, s, d.rails[core.HOLD_RAIL], core.HOLD_END, "in")
	local cx, cy = train.world(ep, x + core.COMB_DX, core.COMB_Y)
	d.comb = place(s, "ue-hold-combinator", cx, cy, {})
	if not (d.box_signal and d.hold and d.comb) then
		return "blocked"
	end
	close_for_good(d.comb, d.hold)
	local x1, y1, x2, y2 = geometry.area_to_world(ep.frame, x + core.AREA[1], core.AREA[2], x + core.AREA[3], core.AREA[4])
	d.area = { { x1, y1 }, { x2, y2 } }
	detect.adopt(ep)
	return "ready"
end

--- Teardown (§12.8, review I4). One signal read says whether a train is on the box: approaching (reserved), waiting,
--- held or freshly spawned. The signals and the combinator always go. The rails go too, unless a train is
--- on them: then they stay, minable again, and connectors.teardown makes them the player's, so no train is stranded.
local function teardown(ep)
	local d = ep.data
	if d.queue then
		train.lose_queue(ep, "teardown")
	end
	local sig = d.box == "outbound" and d.box_signal or d.outer
	local occupied = sig ~= nil and sig.valid and sig.signal_state ~= SIGNAL.open
	train.event(ep, "teardown", "info", { kept = occupied })
	for _, e in pairs({ d.box_signal, d.hold, d.comb, d.exit, d.outer }) do
		if e.valid then
			e.destroy()
		end
	end
	for _, e in ipairs(d.supports or {}) do
		if e.valid then
			e.destroy()
		end
	end
	for _, r in ipairs(d.rails or {}) do
		if r.valid then
			if occupied then
				r.minable_flag, r.destructible = true, true
			else
				r.destroy()
			end
		end
	end
	d.rails, d.rail_ids, d.area, d.supports, d.shape = nil, nil, nil, nil, nil
	d.box_signal, d.hold, d.comb, d.exit, d.outer = nil, nil, nil, nil, nil
end

--- Box shape 2 (owner 2026-10-05): a ready train endpoint built in the old shape builds again (build drops its old hold,
--- combinator and outer signal), which adopts its rails and adds the longer box, the new signals and the supports. Other
--- endpoints get the same cleanup on their normal rebuild.
--- Called at every server start; an endpoint already at the current shape costs nothing.
function train.migrate()
	for _, ep in pairs(storage.universal_edges.eps.train or {}) do
		local d = ep.data
		if ep.state == "ready" and not ep.closing and d.rails and d.shape ~= core.SHAPE then
			connectors.build(ep, game.tick)
		end
	end
end

--- ue.trains.get(edge, cid) (§12.9): a read-only view of this side's box, or nil. box_signal is the signal that says
--- the box is occupied: the border signal of an outbound box, the outer signal of an inbound one.
function train.get(edge_id, cid)
	local side = storage.universal_edges.edges[edge_id]
	local ep = side and connectors.get(side, cid)
	local d = ep and ep.type == "train" and ep.data
	if not (d and d.rails) then
		return nil
	end
	local rails = {}
	for i, r in ipairs(d.rails) do
		rails[i] = r
	end
	return { box = d.box, layer = ep.params.layer or "ground", end_rail = rails[#rails],
		box_signal = d.box == "outbound" and d.box_signal or d.outer, hold = d.hold, rails = rails }
end

-- Spawn (§12.5) ---------------------------------------------------------------------------------------------------------

--- The destination's status (§12.3): { ready, w }, sent only when it changes (§13 rule 6). w is the larger of what
--- the credit hook saw and the ledger's own watermark. So a reject the ledger makes by itself (G5) also opens the
--- source's gate, and a divergent replay of an older seq can't lower w (review I4).
local function status(ep, d, ready)
	local lane = ep.rx[ep.params.dir]
	local w = math.max(d.w or 0, lane and lane.w or 0)
	if d.st_ready ~= ready or d.st_w ~= w then
		d.st_ready, d.st_w = ready, w
		ep:set_status({ ready = ready, w = w })
	end
end

--- Carriage c at the inbound box's local y, facing inward, or outward when it faced against travel; nil if it can't be
--- placed (no room).
local function create_carriage(ep, c, y)
	local x, wy = train.world(ep, train.cx(ep), y)
	local p = { name = c.name, quality = c.quality, position = { x, wy }, force = train.FORCE,
		orientation = core.orientation(ep.frame.facing, c.flip), color = c.color,
		copy_color_from_train_stop = c.copy_color_from_train_stop }
	if prototypes.entity[c.name].type == "locomotive" then
		p.snap_to_train_stop = false
	end
	return game.get_surface(ep.frame.surface_index).create_entity(p)
end

--- §12.5 step 3 (D18): one train holding exactly the carriages made, and every rail under it one of the box's own,
--- which checks the layer and the line at once.
local function spawned_ok(d, made)
	local tr = made[1].train
	if #tr.carriages ~= #made then
		return false
	end
	for _, e in ipairs(made) do
		if e.train.id ~= tr.id then
			return false
		end
	end
	-- ponytail: on 2.1.20 [probe], a foreign-layer rail at this spot never joins the train's path (D18 game test); this
	-- loop stays as a defence against an engine change that would let one in.
	for _, r in pairs(tr.get_rails()) do
		if not d.rail_ids[r.unit_number] then
			return false
		end
	end
	return true
end

--- A rider's seat (SP3 §12.4, crossing spec §6.4): seated at once when players.seatable holds (H1), else the carriage
--- waits for them (H15: a carriage is never released by the vehicle transport).
local function seat(ep, c, e, trace)
	local name = c.riders and c.riders.driver
	if not name then
		return
	end
	local here = players.online(name)
	if here and players.seatable(here) then
		e.set_driver(here)
		send("trace", { op = "ue.player", phase = "seated", level = "info", tick = game.tick, trace = trace,
			player = name, edge = ep.edge, unit_number = e.unit_number, seat = "driver" })
		storage.universal_edges.players.placing[name] = nil -- seated: no later placing moves them (§6.1 step 4)
	else
		storage.universal_edges.waiting[e.unit_number] = { driver = name, expires = game.tick + players.WAIT,
			trace = trace }
	end
end

--- A carriage's state from its body entry (§12.4): inventories (Clusterio's serialize, UE-C10), fluid, burner, grid,
--- label and health. Colour and copy_color_from_train_stop go in at create_entity time instead (create_carriage):
--- a locomotive's default_copy_color_from_train_stop is true (review M1), so a custom colour set here would be
--- overwritten the moment first_batch's go_to_station runs, by whatever stop the train is sent to. Fuel goes in
--- before the speed is set, since burning nuclear fuel raises the top speed (spike 5 §1).
function train.write_carriage(e, c)
	for _, x in ipairs(c.inv or {}) do
		local inv = e.get_inventory(x.i)
		if inv then
			serialize.deserialize_inventory(inv, x.s)
		end
	end
	if c.fluid then
		e.set_fluid(1, c.fluid)
	end
	if c.burning and e.burner then
		e.burner.currently_burning = { name = c.burning.name, quality = c.burning.quality }
		e.burner.remaining_burning_fuel = c.burning.remaining
	end
	if c.grid and e.grid then
		serialize.deserialize_equipment_grid(e.grid, c.grid)
	end
	if c.label then
		e.backer_name = c.label
	end
	if c.health then
		e.health = c.health
	end
end

--- The gradual spawn's task: one join try per due endpoint, through connectors.call (G6). It runs only while some queue
--- isn't empty (§13 rule 1).
local spawn = scheduler.once{
	name = "ue.train.spawn",
	cap = 64,
	per_tick = 4,
	fn = function(args, tick)
		local eps = storage.universal_edges.eps.train
		local ep = eps and eps[args.key]
		if ep and not ep.closing then
			connectors.call(ep, "join", tick)
		end
	end,
}

--- Queued carriages whose front is gone, or whose box is torn down, go to a limbo file with an error (G6, R15), never
--- dropped as v1 did (on_tick.lua:16-18).
function train.lose_queue(ep, reason)
	local d, q = ep.data, ep.data.queue
	if q.handed then -- its carriages ride in a crossing's body: limbo would copy them
		d.queue = nil
		train.event(ep, "front_lost", "error", { trace = q.trace, reason = reason .. " (tail carried by a crossing)" })
		return
	end
	local rest = {}
	for i = q.next, #q.carriages do
		rest[#rest + 1] = q.carriages[i]
	end
	local file = connectors.limbo(ep, ep.params.dir, "spawn", rest, q.trace)
	d.queue = nil
	train.event(ep, "front_lost", "error", { trace = q.trace, carriages = #rest, reason = reason, file = file })
end

--- A body this side can't build is refused (G5). w still moves (§12.3), so the source's gate opens again. carriages
--- is spec §14's field on the rejected line; nil when body wasn't even carriage-shaped (a malformed body).
local function refuse(ep, d, meta, why, carriages)
	d.w = math.max(d.w or 0, meta.seq)
	status(ep, d, d.st_ready == true)
	train.error(ep, "rejected", { trace = meta.trace, reason = why, carriages = carriages })
	return "reject"
end

--- have = prototypes.entity/item/quality, built fresh per call: cheap (three key assignments), and never stale.
local function have()
	return { entity = prototypes.entity, item = prototypes.item, quality = prototypes.quality }
end

--- The first entity, item or quality in body that this server doesn't have (review I1, M3): checked once, over every
--- carriage (not only the first batch), before any carriage is created. Without this, an unknown item is silently
--- voided by Clusterio's deserialize_inventory (module/clusterio/serialize.lua), never raising: credited, the source
--- commits and destroys its train, and the items exist nowhere, with no limbo file and no log line.
local function missing_in_body(body)
	local h = have()
	for _, c in ipairs(body.carriages) do
		local inventories = {}
		for _, x in ipairs(c.inv or {}) do
			if x.s then
				inventories[#inventories + 1] = x.s
			end
		end
		local kind, name = missing.missing(c.name, c.quality, inventories, h)
		if kind then
			return kind, name
		end
	end
	return nil
end

--- Put each of group_plan's carried temporary records in at its index (sync spec §5.6 step 2). An index past the last
--- record appends.
local function add_temporaries(sched, adds)
	for _, a in ipairs(adds) do
		local r = a.record
		local rec = { station = r.station, rail = r.rail, temporary = true, created_by_interrupt = r.created_by_interrupt,
			wait_conditions = r.wait_conditions }
		if a.at <= sched.get_record_count() then
			rec.index = { schedule_index = a.at }
		end
		sched.add_record(rec)
	end
end

--- The carried interrupts, each replaced by the cluster's content where this tile's cache has the name: a copy taken at
--- the source may be older than a cluster edit made while the train was in flight, and restoring it would be reported
--- as a newer edit (sync spec §5.3).
local function current_interrupts(interrupts)
	local cache = sync.state().cache.interrupt
	local out = {}
	for i, it in ipairs(interrupts or {}) do
		local c = cache[it.name]
		out[i] = c and c.content or it
	end
	return out
end

--- §12.5 steps 2-4, filling `made`:
--- - v1's first batch;
--- - the post-spawn check;
--- - then the carriages' state, the records, the interrupts, and go_to_station by identity.
--- A grouped body joins its group first (sync spec §5.6): adopted, or seeded; then its temporaries, then go_to_station.
--- Returns the new train, or "busy" and a reason (no room, or a split or off-box spawn, already undone). Anything the
--- body names that this server lacks raises here: an entity, a quality, an item, a fluid or a signal (review I2).
local function first_batch(ep, d, body, made, meta)
	for k = 1, core.first_count(#body.carriages) do
		local e = create_carriage(ep, body.carriages[k], core.spawn_y(k))
		if not e then
			break
		end
		made[k] = e
	end
	if not made[1] then
		return "busy", "no room for the first carriage"
	end
	if not spawned_ok(d, made) then
		for _, e in ipairs(made) do
			if e.valid then
				e.destroy()
			end
		end
		return "busy", "split, or off the box's rails"
	end
	for k, e in ipairs(made) do
		train.write_carriage(e, body.carriages[k])
	end
	local tr = made[1].train
	local records, go = core.restore_plan(body.schedule, body.edge_record)
	local sched = tr.get_schedule()
	local interrupts = current_interrupts(body.schedule.interrupts)
	if body.group then
		local kept = {}
		for _, r in ipairs(records) do
			if not r.temporary then
				kept[#kept + 1] = r
			end
		end
		local how = sync.join(tr, body.group, { records = kept, interrupts = interrupts }, meta.trace)
		sched = tr.get_schedule()
		local adds
		adds, go = core.group_plan(records, go, sched.get_records() or {})
		add_temporaries(sched, adds)
		train.event(ep, "grouped", "info", { trace = meta.trace, group = body.group, how = how })
	else
		sched.set_records(records)
		sched.set_interrupts(interrupts)
	end
	if go then
		sched.go_to_station(go)
	end
	return tr
end

--- §12.5 steps 2-7, under one pcall (H1): the first batch, the post-spawn check, ep:materialized, manual_mode, the
--- signed speed, and the seats. A raise anywhere in here — an entity, quality, item, fluid or signal this server
--- lacks (review I2), or set_driver on a characterless online rider (H1) — must destroy every carriage made before
--- the endpoint fails, so the source's re-offer or its restore on close can't make a second train while this one
--- still stands: the duplication class SP3a's T7 I1 fixed for vehicles.
local function credit_spawn(ep, dir, d, body, meta, made)
	local tr, why = first_batch(ep, d, body, made, meta)
	if tr == "busy" then
		return tr, why
	end
	ep:materialized(dir, tr, body.ext, meta)
	tr.manual_mode = body.manual
	tr.speed = core.sign(tr.front_end.location.direction, train.inward(ep)) * body.speed
	for k, e in ipairs(made) do
		seat(ep, body.carriages[k], e, meta.trace)
	end
	return tr
end

--- The credit (§12.5 steps 1-7), with F1's meta = { seq, trace } (C1). credit_spawn runs under pcall. If it raises,
--- every carriage it made is destroyed and the body is rejected, so nothing is left half-built. Never train.schedule =.
local function credit(ep, dir, body, meta)
	local d = ep.data
	if d.force_busy then
		return "busy" -- train_seams "set": a destination that answers busy while it says ready (the E2E)
	end
	if not core.valid(body) then
		return refuse(ep, d, meta, "malformed body")
	end
	local kind, name = missing_in_body(body)
	if kind then
		return refuse(ep, d, meta, kind .. " " .. tostring(name), #body.carriages)
	end
	local outer = d.outer
	if d.queue or not (outer and outer.valid and outer.signal_state == SIGNAL.open) then
		return "busy"
	end
	local made = {}
	local ok, tr, why = pcall(credit_spawn, ep, dir, d, body, meta, made)
	if not ok then
		for _, e in ipairs(made) do
			if e.valid then
				e.destroy()
			end
		end
		return refuse(ep, d, meta, tostring(tr), #body.carriages)
	end
	if tr == "busy" then
		if why then
			train.error(ep, "spawn_failed", { trace = meta.trace, carriages = #made, reason = why })
		end
		return "busy"
	end
	if #made < #body.carriages then
		d.queue = { front = made[1], carriages = body.carriages, next = #made + 1, started = game.tick, trace = meta.trace }
		-- I3 (H10a's other half): a false schedule here would otherwise leave the queue with no task to run it, the
		-- same silent stall the join site already guards against.
		if not spawn.schedule(core.RETRY, { key = ep.key }) then
			train.lose_queue(ep, "schedule_full")
		end
	end
	d.w = math.max(d.w or 0, meta.seq)
	status(ep, d, false)
	return "ok"
end

--- v1's pass of the gradual spawn (§12.5; v1 on_tick.lua:22-59, D32). Queued carriages join one after another, each
--- 7 tiles behind the train's outer end, until the next would be more than MAX_DEPTH (94) tiles from the front's spawn point.
--- So the train fills the box as fast as it leaves it.
---
--- A join resets manual_mode, current and speed (spike 5 §3), and a reversed locomotive's join can turn the train's
--- front around ([probe] sp3b-plan). The saved state goes back after each join, with the speed signed afresh.
---
--- A step that raises (the body names something this server lacks, review M5) destroys that carriage and sends the
--- rest to limbo, so the box clears and ready comes back. A queue stuck more than 3600 ticks (no path for the front)
--- logs a warn once (H10a); a cap-64 scheduler that refuses to take the next try (H10a) sends the queue to limbo the
--- same way, so the box doesn't go permanently not-ready with nothing in the log.
local function join(ep, tick)
	local d = ep.data
	local q = d.queue
	if not q or q.handed then
		return
	end
	local front = q.front
	if not front.valid then
		train.lose_queue(ep, "front_lost")
		return
	end
	if not q.stalled and tick - q.started > 3600 then
		q.stalled = true
		train.event(ep, "assembly_stalled", "warn", { trace = q.trace, carriages = #q.carriages - q.next + 1 })
	end
	local e, saved
	local ok, err = pcall(function()
		while q.next <= #q.carriages do
			local tr = front.train
			local y = core.join_y(math.min(train.local_y(ep, tr.front_stock.position), train.local_y(ep, tr.back_stock.position)))
			if not y then
				return
			end
			saved = { manual = tr.manual_mode, current = tr.get_schedule().current, n = #tr.carriages }
			local c = q.carriages[q.next]
			e = create_carriage(ep, c, y)
			if not e then
				return
			end
			if e.train.id ~= front.train.id or #front.train.carriages ~= saved.n + 1 then
				e.destroy() -- it didn't join this train: try again on the next pass (§12.5 step 3)
				e = nil
				return
			end
			-- The coupling keeps the speed, already signed for the train's front, which a reversed locomotive's join can
			-- move to the new carriage's end ([probe] 2026-10-04). Signing it from the rails instead broke past the box,
			-- where the front can be on a curve: an automatic train raised and lost its tail (owner playtest 2026-10-03).
			local speed = front.train.speed
			train.write_carriage(e, c)
			seat(ep, c, e, q.trace)
			tr = front.train
			local sched = tr.get_schedule()
			if saved.current >= 1 and saved.current <= sched.get_record_count() then
				sched.go_to_station(saved.current)
			end
			tr.manual_mode = saved.manual
			tr.speed = speed
			e, q.next = nil, q.next + 1
		end
	end)
	if not ok then
		if e and e.valid then
			e.destroy()
		end
		-- I2: a raise after the carriage coupled (an unknown fluid, burner or grid in write_carriage, review M5)
		-- destroyed it above, but front.train is still standing — reset to manual, mid-schedule, by the coupling
		-- that just got undone. Put current and manual_mode back, under their own pcall (front.train may itself be
		-- gone by now); the speed is left alone, since that write may be what raised, and an automatic train pulls
		-- away by itself. Without this the box never answers ready again (review I2).
		if saved and front.valid then
			pcall(function()
				local tr = front.train
				local sched = tr.get_schedule()
				if saved.current >= 1 and saved.current <= sched.get_record_count() then
					sched.go_to_station(saved.current)
				end
				tr.manual_mode = saved.manual
			end)
		end
		train.lose_queue(ep, "join failed: " .. tostring(err))
		return
	end
	if q.next <= #q.carriages then
		if not spawn.schedule(core.RETRY, { key = ep.key }) then
			train.lose_queue(ep, "schedule_full")
		end
		return
	end
	d.queue = nil
	local sched = front.train.get_schedule()
	local rec = sched.current >= 1 and sched.get_record{ schedule_index = sched.current } or nil
	train.event(ep, "assembled", "info", { trace = q.trace, carriages = #q.carriages, ticks = tick - q.started,
		next = rec and rec.station })
end

--- The inbound box's poll: ready when the outer signal is open and nothing waits (§12.3). Unchanged, it allocates nothing.
local function poll_inbound(ep, d)
	local outer = d.outer
	status(ep, d, core.ready(outer ~= nil and outer.valid and outer.signal_state == SIGNAL.open, d.queue ~= nil))
end

-- Handoff (§12.2, §12.7) ----------------------------------------------------------------------------------------------

--- The player driving carriage c, if any. Rolling stock has a driver and no passenger: get_passenger is for cars,
--- spidertrons and cargo pods ([api]).
local function rider(c)
	local driver = c.get_driver()
	if not driver then
		return nil
	end
	if driver.object_name == "LuaPlayer" then
		return driver
	end
	return driver.player
end

--- A carriage's body entry (§12.4), deterministic for the same state (D21). Inventories go through Clusterio's
--- serialize (UE-C10), as a list of { i, s }.
local function read_carriage(c, flip)
	local entry = { name = c.name, quality = c.quality.name, flip = flip, health = c.health, color = c.color,
		copy_color_from_train_stop = c.copy_color_from_train_stop }
	local inv = {}
	for i = 1, c.get_max_inventory_index() do
		local x = c.get_inventory(i)
		if x then
			local s = serialize.serialize_inventory(x)
			if #s.i > 0 or s.b then
				inv[#inv + 1] = { i = i, s = s }
			end
		end
	end
	if #inv > 0 then
		entry.inv = inv
	end
	if c.type == "fluid-wagon" then
		local f = c.get_fluid(1)
		entry.fluid = f and { name = f.name, amount = f.amount, temperature = f.temperature } or nil
	end
	local burner = c.burner
	local burning = burner and burner.currently_burning
	if burning then
		entry.burning = { name = burning.name.name, quality = burning.quality.name, remaining = burner.remaining_burning_fuel }
	end
	if c.grid then
		entry.grid = serialize.serialize_equipment_grid(c.grid)
	end
	if c.type == "locomotive" then
		entry.label = c.backer_name
	end
	local player = rider(c)
	if player then
		entry.riders = { driver = player.name }
	end
	return entry
end

local function inside(area, p)
	return p.x >= area[1][1] and p.x <= area[2][1] and p.y >= area[1][2] and p.y <= area[2][2]
end

--- The body of train tr in the outbound box, and its carriages, travel-front first. The leading end is the one in this
--- box's column: the other end can be further out, in another box on this edge (a loop shorter than the train, owner
--- playtest 2026-10-04). A train that fits in the box has both ends in it: then it's the one further out (smaller local
--- y). Each carriage's flip comes from is_headed_to_trains_front, so curves outside the box don't matter.
--- Its group by name (sync spec §5.6).
function train.capture_body(ep, tr)
	local d = ep.data
	local f_in, b_in = inside(d.area, tr.front_stock.position), inside(d.area, tr.back_stock.position)
	local front = f_in
	if f_in == b_in then
		front = train.local_y(ep, tr.front_end.location.position) <= train.local_y(ep, tr.back_end.location.position)
	end
	local list = tr.carriages
	local n, held, cars = #list, {}, {}
	for i = 1, n do
		local c = front and list[i] or list[n + 1 - i]
		held[i] = c
		cars[i] = read_carriage(c, core.flip(c.is_headed_to_trains_front, front))
	end
	local sched = tr.get_schedule()
	return core.body{
		layer = ep.params.layer or "ground", speed = tr.speed, manual = tr.manual_mode, carriages = cars,
		records = sched.get_records() or {}, current = sched.current, interrupts = sched.get_interrupts() or {},
		group = sync.group_of(tr),
		end_rail_id = d.rails[core.OUT_RAILS].unit_number,
		ext = hooks.capture(ep, tr), -- SP3a Task 1: each extension's capture (§11, C3)
	}, held
end

--- The capture (§12.2). The body goes out through ep:send, and the train is held: it keeps braking for the hold
--- signal until commit deletes it. A body over 64 KB (F4, C5) leaves the train in manual mode, marked so the poll
--- doesn't capture it again (R10).
function train.capture(ep, d, tr, side)
	local body, held = train.capture_body(ep, tr)
	-- A train still assembling behind an inbound box here carries its waiting tail on, after its last carriage: joins
	-- pause until commit drops that queue, or a restore resumes them (owner playtest 2026-10-04). Holding the train
	-- until it's whole instead deadlocks on a loop shorter than the train: held, it never makes room for the next join.
	local qep, q = nil, nil
	for _, other in pairs(storage.universal_edges.eps.train) do
		local oq = other.data.queue
		if oq and oq.front.valid and oq.front.train.id == tr.id then
			qep, q = other, oq
		end
	end
	if q then
		for i = q.next, #q.carriages do
			q.carriages[i].riders = nil -- ponytail: a rider still queued is bound for this server; it lands as for limbo
			body.carriages[#body.carriages + 1] = q.carriages[i]
		end
	end
	local seq = ep:send(ep.params.dir, body)
	if not seq then
		tr.manual_mode, d.rejected = true, true
		train.error(ep, "too_big", { carriages = #held })
		hooks.restored(ep, tr, "too_big") -- SP4 §7.5: an extension's state rides on, refused
		return
	end
	-- riders are resolved once, at capture, not re-read at commit (which can run long after): the same capture-time
	-- resolution vehicle.lua uses for its own held.driver/held.passenger, so commit only ever destroys a carriage
	-- whose rider it already knows by name. body.carriages[i] is read_carriage's own entry for held[i] (core.body
	-- passes carriages straight through), which already holds .riders.driver from read_carriage's rider(c) call
	-- (review M6): reused here instead of a second get_driver() per carriage, and it's the same name the body seats
	-- at the destination.
	local riders = {}
	for i, c in ipairs(body.carriages) do
		riders[i] = c.riders and c.riders.driver
	end
	if q then
		q.handed = true
	end
	d.held = { seq = seq, carriages = held, riders = riders, queue = qep and qep.key }
	d.last, d.waiting, d.logged = { seq = seq, epoch = side.epoch }, nil, nil
end

--- The inbound endpoint and queue whose tail held train h carries on, if any.
local function handed(h)
	local qep = h and h.queue and storage.universal_edges.eps.train[h.queue]
	local q = qep and qep.data.queue
	if q and q.handed then
		return qep, q
	end
end

--- The outbound box's poll (§12.2; v1 train_link.lua:88-144). While the box signal is open it does one read. Once it
--- closes, one lookup over the box finds the train, once per arrival. Any train is captured, manual ones included (M9),
--- as soon as nothing is in flight and the gate is open; until then it waits at the hold signal (D22), logged once.
local function poll_outbound(ep, d)
	local sig = d.box_signal
	if not (sig and sig.valid) then
		return
	end
	if sig.signal_state ~= SIGNAL.closed then
		-- ponytail: the mark clears only on an open read here (M1). If the rejected train leaves while another one
		-- brakes just short of the box, the open-or-reserved window can be shorter than the poll period (about 10 to
		-- 20 ticks), and that second train is then held at the hold signal for good, uncaptured, with no "waiting"
		-- line logged (the early return above fires before the log at :727). Rare; the owner's rule accepts it.
		-- Upgrade: clear the mark on a reserved read too, not only open.
		d.waiting, d.logged, d.rejected = nil, nil, nil
		return
	end
	if d.rejected or not ep:can_send(ep.params.dir) then
		return
	end
	local found = d.waiting
	if not (found and found.valid) then
		-- ponytail: a second train, already queued behind the held one and braking toward the box signal, can have
		-- its own front sitting inside AREA (y ≤ +2) before the first clears (H11); this lookup can then latch onto
		-- it instead, swapping the two trains' crossing order with no loss. The d.waiting cache makes that rare,
		-- once some train is already latched onto. Upgrade: keep the hit only if its train has a carriage at local
		-- y < 0 (genuinely inside the box, not just approaching it).
		found = game.get_surface(ep.frame.surface_index).find_entities_filtered{ area = d.area, type = train.STOCK, limit = 1 }[1]
		if not found then
			return
		end
		d.waiting = found
	end
	local side = storage.universal_edges.edges[ep.edge]
	if not core.gate(ep.partner.status, d.last, side.epoch) then
		if not d.logged then
			d.logged = true
			train.event(ep, "waiting", "info", {})
		end
		return
	end
	train.capture(ep, d, found.train, side)
end

--- Commit (§12.7): the destination has the train. Its riders get the server prompt (§9 steps 2-4, R18, C9), under the
--- crossing's own trace (H3), through the references kept at capture.
local function commit(ep, _, seq, trace)
	local d = ep.data
	local h = d.held
	if not (h and h.seq == seq) then
		-- M7: the ledger would still drop the entry (D8), so a held train it doesn't match would be stranded with
		-- no log line; no known path reaches this, but the line costs nothing.
		train.error(ep, "commit_unheld", { seq = seq, trace = trace })
		return
	end
	-- The riders' crossing point: the box's border point, 1 tile past the line at its column, which mirrors to just
	-- inside the partner. A carriage from the third on stands inside this world: its own position mirrors out of reach.
	local bx, by = train.world(ep, train.cx(ep), -1)
	for i, c in ipairs(h.carriages) do
		if c.valid then
			local name = h.riders and h.riders[i]
			if name then
				-- H3: held: the rider stands where the carriage stood, inside the world from the third carriage on; a
				-- held crossing survives that until it is answered (crossing spec §7.3).
				players.cross(name, "edge:" .. ep.edge, nil, c.surface.name, bx, by, trace, true)
			end
			c.destroy{ raise_destroy = true }
		end
	end
	local qep, q = handed(h)
	if q then
		qep.data.queue = nil
		train.event(qep, "handed_on", "info", { trace = q.trace, carriages = #q.carriages - q.next + 1, to = ep.cid })
	end
	d.held = nil
end

--- Restore (§12.7). On close (ep.closing; teardown has run) the train is let go: it never left. On a reject it goes to
--- manual mode, marked so the poll doesn't take it again until the box empties. Manual mode alone wouldn't do that,
--- because M9 captures manual trains (R10). Either way the extensions hear of it (SP4 §7.5), with the first valid held
--- carriage's train.
local function restore(ep, dir, seq)
	local d = ep.data
	local h = d.held
	d.held = nil
	local _, q = handed(h)
	if q then
		q.handed = nil
	end
	local tr
	for _, c in ipairs(h and h.carriages or {}) do
		if c.valid then
			tr = c.train
			break
		end
	end
	if ep.closing then
		if tr then
			hooks.restored(ep, tr, "close")
		end
		return true
	end
	if tr then
		tr.manual_mode = true
	end
	d.rejected = true
	-- M2: under the crossing's own trace, per train.event's contract — ledger_core's give_back runs this before
	-- clearing lane.inflight, so it's still the capture's own entry here. The wire's u.reply carries no reason from
	-- the destination's reject (ledger_core.lua's tx.u.reply only ever reads seq/outcome/w), so reason is this
	-- side's own restore cause: the only live (non-closing) path here is a reject reply.
	local lane = ep.tx[dir]
	local trace = lane and lane.inflight and lane.inflight.trace
	train.error(ep, "rejected", { trace = trace, seq = seq, carriages = h and #h.carriages or 0, reason = "reject" })
	if tr then
		hooks.restored(ep, tr, "reject")
	end
	return true
end

-- The type ------------------------------------------------------------------------------------------------------------

local function poll(ep)
	detect.check(ep)
	local d = ep.data
	if d.box == "outbound" then
		poll_outbound(ep, d)
	elseif d.box == "inbound" then
		poll_inbound(ep, d)
	end
end

connectors.register_type{
	name = "train",
	lanes = function(params)
		return { [params.dir] = "unique" }
	end,
	validate = function(params)
		if type(params) ~= "table" or (params.dir ~= "ab" and params.dir ~= "ba")
			or (params.layer ~= nil and params.layer ~= "ground" and params.layer ~= "elevated") then
			return false, "train params need dir = ab|ba and layer = ground|elevated"
		end
		return true
	end,
	schedule = { per_tick = 4, interval = 10 },
	build = build,
	teardown = teardown,
	poll = poll,
	credit = credit,
	join = join,
	commit = commit,
	restore = restore,
	detected = generic_build, -- train box direction spec §4 (detect.lua)
	refused = generic_refused, -- §6.4 (detect.lua's ue.connector.refused)
}

return train
