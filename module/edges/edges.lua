-- The instance edge lifecycle (SP1 spec §5.3, §6): storage.universal_edges.edges, the ue.edge.* handlers, the
-- per-edge applied reports, the startup reset and the read-only views. The rules live in edge_core.
local bridge = require("modules/universal_edges/runtime/bridge")
local bridge_core = require("modules/universal_edges/runtime/bridge_core")
local core = require("modules/universal_edges/edges/edge_core")
local barriers = require("modules/universal_edges/edges/barriers")
local marks = require("modules/universal_edges/edges/marks")
local lanes = require("modules/universal_edges/edges/lanes")
local connectors = require("modules/universal_edges/edges/connectors")

local edges = {}
local send = bridge.channel("universal_edges")

local function count(kind)
	local stats = storage.universal_edges.stats
	stats["ue.edges"] = stats["ue.edges"] or {}
	bridge_core.count(stats["ue.edges"], kind)
end

--- S1 (surfaces spec §11): index side by surface. Its endpoints copied side.surface_index into their frame when they
--- were made (connectors.create), so a side that takes its surface late updates theirs too.
local function attach(side, surface)
	local s = storage.universal_edges
	side.surface_index = surface.index
	s.by_surface[surface.index] = s.by_surface[surface.index] or {}
	s.by_surface[surface.index][side.id] = true
	for cid in pairs(side.eps) do
		local ep = connectors.get(side, cid)
		if ep then
			ep.frame.surface_index = surface.index
		end
	end
end

local function create(rec)
	local s = storage.universal_edges
	local side = core.new_side(rec, nil)
	s.edges[side.id] = side
	local surface = game.get_surface(rec[rec.me].surface)
	if surface then
		attach(side, surface)
	end
	if not side.deleted then
		barriers.place(side)
		marks.place(side)
	end
	return side
end

local function drop(side)
	lanes.drop(side)
	barriers.remove(side)
	marks.remove(side)
	local s = storage.universal_edges
	local ids = side.surface_index and s.by_surface[side.surface_index]
	if ids then
		ids[side.id] = nil
		if next(ids) == nil then
			s.by_surface[side.surface_index] = nil
		end
	end
	s.edges[side.id] = nil
end

--- Apply one valid record, then report the side's revision, even for a stale record (§6.3 step 2).
local function apply(rec, sync)
	local side = storage.universal_edges.edges[rec.id]
	local action = core.plan(side, rec, sync)
	if action == "replace" then
		send("trace", { op = "ue.edge", phase = "replaced", level = "warn", trace = rec.trace, tick = game.tick,
			edge = rec.id, revision = rec.revision, old_revision = side.revision })
	end
	if action == "create" or action == "replace" or action == "recreate" then
		if side then
			drop(side)
		end
		side = create(rec)
	elseif action == "shell" then
		barriers.remove(side)
		marks.remove(side)
		core.update(side, rec)
	elseif action == "update" then
		core.update(side, rec)
	end
	if action ~= "stale" then
		-- §5.2 step 5, §11.7 step 8: the partner's instance is gone, so the survivor's lanes resolve at once.
		lanes.reconcile(side, rec.deleted and (rec.reason == "instance_deleted" or rec.reason == "instance_missing"))
	end
	-- ponytail: one report per edge, so a sync of about 1000 edges fills the bridge's 1000-message outbox (0B's
	-- out_cap); batch the reports if an instance is ever a side of that many edges.
	lanes.report(side, sync)
end

-- TS → Lua (§6.1). A handler returns false for a malformed payload, which the bridge counts as a reject.
bridge.on("universal_edges", "ue.edge.sync", function(p)
	if type(p.edges) ~= "table" then
		return false
	end
	connectors.wake()
	if #p.edges > 900 then
		-- M4: an early warning below Lua's 1000-message outbox cap (ruling 8); the ceiling itself stays at 900.
		send("trace", { op = "ue.edge", phase = "sync_large", level = "error", trace = "sync." .. game.tick,
			tick = game.tick, n = #p.edges })
	end
	local s = storage.universal_edges
	-- FC4 (circuit-link spec C5 b): a side the sync turns inactive reads as silence, as after activation(active=false).
	-- The controller sends no such message first when it knows of no active state, e.g. after its own restart.
	for _, side in ipairs(core.reset(s.edges)) do
		marks.recolor(side)
		lanes.deactivated(side)
	end
	local listed = {}
	for _, rec in ipairs(p.edges) do
		if type(rec) == "table" and type(rec.id) == "string" then
			listed[rec.id] = true
		end
		if core.valid(rec) then
			apply(rec, true)
		else
			count("rejects")
		end
	end
	-- Absent from an authoritative sync means purged (§6.2 step 3); an invalid record never drops its side.
	for id, stored in pairs(s.edges) do
		if not listed[id] then
			drop(stored)
		end
	end
	-- C1: storage, not a file-local — a joining player's control.lua starts fresh, so a local gate reads wrong on
	-- their machine even though the server already applied this sync (0B keeps rt.boot_id the same way).
	s.synced_boot = s.rt.boot_id
	send("ue.edge.synced", { n = #p.edges })
	return true
end)

bridge.on("universal_edges", "ue.edge.update", function(p)
	if not core.valid(p.edge) then
		return false
	end
	connectors.wake()
	apply(p.edge, false)
	return true
end)

bridge.on("universal_edges", "ue.edge.activation", function(p)
	if type(p.id) ~= "string" or type(p.active) ~= "boolean" or type(p.trace) ~= "string"
		or (p.active and type(p.epoch) ~= "string") then
		return false
	end
	connectors.wake()
	local s = storage.universal_edges
	local side = s.edges[p.id]
	if not side then
		count("unknown")
		return true
	end
	local ended = side.epoch
	local synced = s.synced_boot ~= nil and s.synced_boot == s.rt.boot_id
	if core.set_active(side, p.active, p.epoch, synced) then
		send("trace", { op = "ue.edge", phase = p.active and "activated" or "deactivated", trace = p.trace,
			tick = game.tick, edge = p.id, epoch = p.active and p.epoch or ended, reason = p.reason })
		marks.recolor(side)
		if p.active then
			lanes.activated(side)
		else
			lanes.deactivated(side) -- FC4 (circuit-link spec C5 b): a stopped far server reads as silence
		end
	end
	return true
end)

bridge.on("universal_edges", "ue.edge.purged", function(p)
	if type(p.id) ~= "string" then
		return false
	end
	local side = storage.universal_edges.edges[p.id]
	if side then
		drop(side)
	end
	return true
end)

--- Clusterio's on_server_startup: a start, crash or rollback leaves every side inactive until the next sync.
--- Fix round 2 (2026-10-04): also where a save upgraded from schema 4 catches up on marks migration 5 couldn't draw
--- (marks.backfill's own doc comment); idempotent, so it costs nothing on every other restart.
--- Ruling C1/P1 (circuit-link spec C5 b, 2026-10-04): every side is reset to inactive here, whatever it was before —
--- so FC4's hook must run for each one too, not only a side that gets a fresh ue.edge.activation(active=false). A
--- server that restarts while its partner is still down must still clear a type's residual far values; lanes.deactivated
--- is safe to call again on a side that was already inactive (its only guards are ep.closing and the type's own hook).
function edges.on_server_startup()
	core.reset(storage.universal_edges.edges)
	for _, side in pairs(storage.universal_edges.edges) do
		lanes.deactivated(side)
	end
	marks.backfill()
end

--- S1 (surfaces spec §11, accepted by the owner 2026-10-04): a surface made after a side's record — a planet a gridworld
--- tile creates at its start, when UE's record came first (a replaced instance, or a crash that lost the surface, §5.3).
--- The side takes it now: indexed, its endpoints' frames, walls, marks and arrows, and a wake so its pending endpoints
--- build. O(sides) per new surface, which is rare.
function edges.on_surface_created(event)
	local s = storage.universal_edges
	local surface = s and game.get_surface(event.surface_index)
	if not surface then
		return
	end
	for _, side in pairs(s.edges) do
		if side.surface_index == nil and side[side.me].surface == surface.name then
			attach(side, surface)
			if not side.deleted then
				barriers.place(side)
				marks.place(side)
				for cid in pairs(side.eps) do
					local ep = connectors.get(side, cid)
					if ep then
						marks.connector_created(side, ep)
					end
				end
			end
			connectors.wake()
			send("trace", { op = "ue.edge", phase = "surface_found", level = "info", trace = side.trace, tick = game.tick,
				edge = side.id, surface = surface.name })
		end
	end
end

local function view(side)
	local mine = side[side.me]
	return {
		id = side.id, me = side.me, length = side.length, active = side.active, epoch = side.epoch,
		deleted = side.deleted,
		frame = { surface_index = side.surface_index, origin = { mine.origin[1], mine.origin[2] }, facing = mine.facing,
			length = side.length },
	}
end

--- ue.edges.get(edge_id): a read-only copy of this instance's side of the edge, or nil (§7.3).
function edges.get(edge_id)
	local side = storage.universal_edges.edges[edge_id]
	return side and view(side)
end

--- ue.edges.frame(edge_id, which) (F10): side which's ("a" or "b") frame { origin, facing, length } from this instance's
--- record of the edge, for mirrored positions; nil for an edge this instance doesn't have.
function edges.frame(edge_id, which)
	local side = storage.universal_edges.edges[edge_id]
	local s = side and side[which]
	return s and { origin = { s.origin[1], s.origin[2] }, facing = s.facing, length = side.length }
end

--- ue.edges.list(surface_index?): every side, or those on one surface.
function edges.list(surface_index)
	local s, out = storage.universal_edges, {}
	local ids = s.edges
	if surface_index then
		ids = s.by_surface[surface_index] or {}
	end
	for id in pairs(ids) do
		out[#out + 1] = view(s.edges[id])
	end
	return out
end

return edges
