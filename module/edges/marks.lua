-- Edge marks (visuals batch, 2026-10-04): a border line and connector arrows, always visible, in both the world and
-- the map (chart) view. v1 drew these with `rendering` (read-only reference, universal_edges/module/control.lua:95-160:
-- a solid line along the edge, green when active and red when not, width 4; a grey dashed line 0.2 to one side for the
-- partner side) — not copied, but its colours, width and the partner line's offset are the same facts reused here.
-- render_mode = "game" | "chart" is the official API for targeting the world or the map view
-- (lua-api.factorio.com/2.1.20, ScriptRenderMode on LuaRendering.draw_line/draw_sprite).
--
-- Render objects persist in saves on their own (their ids in storage.universal_edges.marks are only so later code can
-- recolour or destroy them); nothing here runs on load.
local geometry = require("modules/universal_edges/edges/geometry_core")

local marks = {}
local GREEN, RED, GREY = { 0, 1, 0 }, { 1, 0, 0 }, { 0.5, 0.5, 0.5 }
local WIDTH, PARTNER_OFFSET = 4, 0.2

local function store(side)
	local s = storage.universal_edges.marks
	s[side.id] = s[side.id] or { c = {} }
	return s[side.id]
end

--- One line, in both the world and the map view; returns their two object ids. Fix round 2 (2026-10-04): the "game"
--- line draws on the ground, under entities (owner: "draw the edge line(s) on the ground"); "chart" is unused there
--- (LuaRenderObject.draw_on_ground's own doc) so it's left nil, not set to the same value for no reason.
local function line(surface_index, frame, y, color, dashed)
	local x1, y1 = geometry.to_world(frame, 0, y)
	local x2, y2 = geometry.to_world(frame, frame.length, y)
	local ids = {}
	for _, mode in ipairs({ "game", "chart" }) do
		ids[mode] = rendering.draw_line({
			color = color, width = WIDTH, surface = surface_index, render_mode = mode,
			from = { x1, y1 }, to = { x2, y2 },
			gap_length = dashed and 0.5 or nil, dash_length = dashed and 0.5 or nil,
			draw_on_ground = mode == "game" or nil,
		}).id
	end
	return ids
end

--- Fix round 2: a pair drawn before this fix has its "game" line set to draw on the ground in place (the attribute is
--- writable, runtime-api.json's LuaRenderObject.draw_on_ground), not destroyed and redrawn. A no-op once it's set.
local function ground_pair(pair)
	local obj = pair and rendering.get_object_by_id(pair.game)
	if obj and obj.valid and not obj.draw_on_ground then
		obj.draw_on_ground = true
	end
end

local function destroy(id)
	if id then
		local obj = rendering.get_object_by_id(id)
		if obj and obj.valid then
			obj.destroy()
		end
	end
end

--- True when pair (a {game=, chart=} id pair, or nil) still points at two live render objects.
local function valid_pair(pair)
	if not pair then
		return false
	end
	for _, mode in ipairs({ "game", "chart" }) do
		local obj = rendering.get_object_by_id(pair[mode])
		if not (obj and obj.valid) then
			return false
		end
	end
	return true
end

local function destroy_pair(pair)
	if pair then
		destroy(pair.game)
		destroy(pair.chart)
	end
end

--- side's frame (as detect.lua caches one, F9): mine's origin and facing, the side's length.
local function frame_of(side)
	local mine = side[side.me]
	return { surface_index = side.surface_index, origin = { mine.origin[1], mine.origin[2] }, facing = mine.facing,
		length = side.length }
end

--- A side's two lines: the border (green or red by side.active) and, 0.2 outward, the grey dashed partner line.
--- Where barriers.place runs in edges.lua (a live side being created or applied).
function marks.place(side)
	if not side.surface_index then
		return
	end
	local frame, rec = frame_of(side), store(side)
	rec.border = line(side.surface_index, frame, 0, side.active and GREEN or RED, false)
	rec.partner = line(side.surface_index, frame, -PARTNER_OFFSET, GREY, true)
end

--- Recolour the border line for the side's current active state; the grey partner line never changes.
--- Where edges.lua applies an activation that actually changed side.active.
function marks.recolor(side)
	local rec = storage.universal_edges.marks[side.id]
	if not rec or not rec.border then
		return
	end
	local color = side.active and GREEN or RED
	for _, mode in ipairs({ "game", "chart" }) do
		local obj = rendering.get_object_by_id(rec.border[mode])
		if obj and obj.valid then
			obj.color = color
		end
	end
end

--- Destroy a side's lines and any connector arrows still stored for it. Where barriers.remove runs in edges.lua (a
--- side dropped, purged, replaced or tombstoned into a shell).
function marks.remove(side)
	local s = storage.universal_edges.marks
	local rec = s[side.id]
	if not rec then
		return
	end
	for _, pair in ipairs({ rec.border, rec.partner }) do
		if pair then
			destroy(pair.game)
			destroy(pair.chart)
		end
	end
	for _, id in pairs(rec.c) do
		destroy(id)
	end
	s[side.id] = nil
end

--- dir, in 16ths, world space, for the one-way arrow of a single-direction lane; outward if this side sends on it
--- (dir_to_world(frame, 0): the frame's own outward normal), inward if it receives (dir_to_world(frame, 8)).
local function one_way_dir(side, ep, dir)
	local sends = (dir == "ab") == (side.me == "a")
	return geometry.dir_to_world(ep.frame, sends and 0 or 8)
end

--- The arrow sprite and world dir for a connector's endpoint, from its lanes: one key (ab or ba) is one-way (belts,
--- trains); both are two-way (fluids, power); neither (a test type with no lanes) draws nothing.
local function arrow_spec(side, ep)
	local only
	for d in pairs(ep.dirs) do
		if only then
			return "utility/fluid_indication_arrow_both_ways", geometry.dir_to_world(ep.frame, 0)
		end
		only = d
	end
	if not only then
		return nil
	end
	return "utility/indication_arrow", one_way_dir(side, ep, only)
end

--- One arrow at the connector's centre on the border line. Where connectors.create returns a new endpoint; skips the
--- built-in endpoints (F7), which aren't connectors the controller configured.
function marks.connector_created(side, ep)
	if ep.builtin or not side.surface_index then
		return
	end
	local sprite, dir = arrow_spec(side, ep)
	if not sprite then
		return
	end
	local x, y = geometry.to_world(ep.frame, ep.col + ep.width / 2, 0)
	local rec = store(side)
	rec.c[ep.cid] = rendering.draw_sprite({
		sprite = sprite, surface = side.surface_index, target = { x, y }, orientation = dir / 16,
	}).id
end

--- Destroy a connector's arrow. Where connectors.remove forgets the endpoint.
function marks.connector_removed(side, ep)
	local rec = storage.universal_edges.marks[side.id]
	local id = rec and rec.c[ep.cid]
	if id then
		destroy(id)
		rec.c[ep.cid] = nil
	end
end

--- Fix round 2 (2026-10-04): a save upgraded from schema 4 (or any other way marks went missing) has live sides and
--- connectors from before this version, but migration 5 (schema_core.lua) only creates the empty marks table — it
--- can't call module code to draw on an existing save, so this is the post-migration pass instead: edges.lua's
--- on_server_startup calls it, right after core.reset, the same place this codebase already runs module code after
--- migrations.run_all (control.lua's on_server_startup handler).
---
--- Idempotent: it runs on every server start, not just the first one after the upgrade, so a side or connector whose
--- marks already point at live render objects is left untouched beyond ground_pair's draw_on_ground catch-up (also a
--- no-op once it's set); only what's missing or invalid (the ids are stale, e.g. their render objects were destroyed
--- some other way) is redrawn, reusing marks.place/connector_created rather than drawing anything new here.
function marks.backfill()
	local s = storage.universal_edges
	for _, side in pairs(s.edges) do
		if side.surface_index and not side.deleted then
			local rec = s.marks[side.id]
			if rec and valid_pair(rec.border) and valid_pair(rec.partner) then
				ground_pair(rec.border)
				ground_pair(rec.partner)
			else
				if rec then
					destroy_pair(rec.border)
					destroy_pair(rec.partner)
				end
				marks.place(side)
			end
		end
	end
	for _, registry in pairs(s.eps) do
		for _, ep in pairs(registry) do
			-- F7: a built-in endpoint never gets an arrow (marks.connector_created's own skip); checked here too so a
			-- restart doesn't re-run that check for every side's built-ins, only real connectors.
			if not ep.builtin then
				local side = s.edges[ep.edge]
				if side and not side.deleted then
					local rec = s.marks[side.id]
					local existing = rec and rec.c[ep.cid]
					local obj = existing and rendering.get_object_by_id(existing)
					if not (obj and obj.valid) then
						marks.connector_created(side, ep)
					end
				end
			end
		end
	end
end

return marks
