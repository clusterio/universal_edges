-- Edge marks (visuals batch, 2026-10-04; spec §9a): the side's border and partner lines, and connector arrows.
-- No loopback needed for the side's own lines (§9a's lifecycle hooks fire from this side's own apply/activation), but
-- a connector's teardown needs its partner's close handshake, so that case uses the loopback (as belts_game_test.lua's
-- removal case does).
local t = require("modules/v2_test/testlib")
local loop = require("modules/v2_test/loopback")
local clusterio_api = require("modules/clusterio/api")
local marks = require("modules/universal_edges/edges/marks")

local seq = 0
local function deliver(msg_type, payload)
	seq = seq + 1
	ue_rt.inbox("universal_edges", helpers.table_to_json({ { id = "0000face." .. seq, type = msg_type, payload = payload } }))
end

--- A one-sided record (no partner instance needed for the side's own lines): me = "a", at an x far from every other
-- file's world positions (checked: nothing else in test/game or harness/lua goes past 30000).
local function record_of(id, revision, fields)
	local rec = {
		id = id, revision = revision, trace = "0000face.t" .. revision, me = "a", owner = "test", length = 16,
		deleted = false, connectors = {},
		a = { instanceId = 9242, surface = "nauvis", origin = { 40300, 3000 }, facing = 0 },
		b = { instanceId = 9243, surface = "nauvis", origin = { 40316, 2000 }, facing = 8 },
	}
	for k, v in pairs(fields or {}) do
		rec[k] = v
	end
	return rec
end

local function marks_of(id)
	return storage.universal_edges.marks[id]
end

local function obj(id)
	return id and rendering.get_object_by_id(id)
end

local function is_color(o, r, g, b)
	return o ~= nil and o.valid and math.abs(o.color.r - r) < 1e-6 and math.abs(o.color.g - g) < 1e-6
		and math.abs(o.color.b - b) < 1e-6
end

local function gone(id)
	local o = obj(id)
	return o == nil or not o.valid
end

t.case("marks: a side's border and partner lines are red/grey in both render modes; activation recolours " ..
	"the border only; a tombstone destroys both", function(ctx)
	local saved
	ctx.at(2000, function()
		deliver("ue.edge.update", { edge = record_of("sp-mk-a", 1) })
	end)
	ctx.at(2020, function()
		local rec = marks_of("sp-mk-a")
		ctx.expect(rec ~= nil and rec.border and rec.partner, "the side's lines are stored under its id")
		saved = { bg = rec.border.game, bc = rec.border.chart, pg = rec.partner.game, pc = rec.partner.chart }
		ctx.expect(is_color(obj(saved.bg), 1, 0, 0), "border red while inactive (world)")
		ctx.expect(is_color(obj(saved.bc), 1, 0, 0), "border red while inactive (map)")
		ctx.expect(is_color(obj(saved.pg), 0.5, 0.5, 0.5), "partner line grey (world)")
		ctx.expect(is_color(obj(saved.pc), 0.5, 0.5, 0.5), "partner line grey (map)")
		ctx.expect(obj(saved.bg).render_mode == "game", "the border's first object renders in the world")
		ctx.expect(obj(saved.bc).render_mode == "chart", "the border's second object renders on the map")
		ctx.expect(obj(saved.pg).render_mode == "game" and obj(saved.pc).render_mode == "chart",
			"the partner line is in both render modes too")
		-- Fix round 2 (2026-10-04, owner: "draw the edge line(s) on the ground"): a new mark's "game" lines draw on
		-- the ground, under entities; "chart" is unused there (LuaRenderObject.draw_on_ground's own doc), so it's
		-- never set, not even cosmetically.
		ctx.expect(obj(saved.bg).draw_on_ground == true, "the border's world line draws on the ground")
		ctx.expect(obj(saved.pg).draw_on_ground == true, "the partner's world line draws on the ground")
		ctx.expect(obj(saved.bc).draw_on_ground ~= true, "the border's map line is untouched")
		ctx.expect(obj(saved.pc).draw_on_ground ~= true, "the partner's map line is untouched")
	end)
	ctx.at(2030, function()
		deliver("ue.edge.activation", { id = "sp-mk-a", active = true, epoch = "0000face.e1", trace = "0000face.e1" })
	end)
	ctx.at(2040, function()
		ctx.expect(is_color(obj(saved.bg), 0, 1, 0), "border turns green once active (world)")
		ctx.expect(is_color(obj(saved.bc), 0, 1, 0), "...and on the map")
		ctx.expect(is_color(obj(saved.pg), 0.5, 0.5, 0.5), "the partner line is unaffected by activation")
	end)
	ctx.at(2050, function()
		deliver("ue.edge.activation", { id = "sp-mk-a", active = false, epoch = "0", trace = "0000face.e2" })
	end)
	ctx.at(2060, function()
		ctx.expect(is_color(obj(saved.bg), 1, 0, 0), "border turns red again once deactivated")
	end)
	ctx.at(2070, function()
		-- A live side tombstoned (edges.lua's "shell" branch), as a controller's delete does (SP1 §6.2): marks.remove
		-- runs next to barriers.remove there, same as it does in drop() for a fully purged side.
		deliver("ue.edge.update", { edge = record_of("sp-mk-a", 2, { deleted = true }) })
	end)
	ctx.at(2080, function()
		ctx.expect(marks_of("sp-mk-a") == nil, "the tombstoned side's marks entry is gone")
		ctx.expect(gone(saved.bg) and gone(saved.bc), "the border's two objects are destroyed")
		ctx.expect(gone(saved.pg) and gone(saved.pc), "the partner line's two objects are destroyed")
	end)
end)

t.case("marks: a belt and a fluid connector each draw one correctly oriented arrow; removing one destroys " ..
	"only its own", function(ctx)
	local connectors_ = {
		{ cid = "b1", type = "belt", pos = 2, width = 1, params = { dir = "ab" } }, -- side x (me a) sends: outward
		{ cid = "b2", type = "belt", pos = 5, width = 1, params = { dir = "ba" } }, -- side x receives: inward
		{ cid = "f1", type = "fluid", pos = 8, width = 1, params = {} }, -- two-way
	}
	ctx.at(2100, function()
		loop.edge("sp-mk-c", 16, connectors_, { 40000, 3000, 0 }, { 40016, 2000, 8 })
	end)
	ctx.at(2120, function()
		local rec = marks_of("sp-mk-c-x")
		ctx.expect(rec ~= nil and rec.c.b1 and rec.c.b2 and rec.c.f1, "all three connectors drew an arrow")
		local b1, b2, f1 = obj(rec.c.b1), obj(rec.c.b2), obj(rec.c.f1)
		ctx.expect(b1.sprite == "utility/indication_arrow", "b1's sprite is the one-way arrow")
		ctx.expect(math.abs(b1.orientation - 0) < 1e-6, "b1 (sends, ab on side a) points outward: orientation 0")
		ctx.expect(b2.sprite == "utility/indication_arrow", "b2's sprite is the one-way arrow")
		ctx.expect(math.abs(b2.orientation - 0.5) < 1e-6, "b2 (receives, ba on side a) points inward: orientation 0.5")
		ctx.expect(f1.sprite == "utility/fluid_indication_arrow_both_ways", "f1's sprite is the two-way arrow")
	end)
	ctx.at(2140, function()
		-- Drop b1 only (as belts_game_test.lua's removal case does, over the loopback so the close handshake
		-- completes on both ends without a real partner instance).
		loop.connectors("sp-mk-c", 2, { connectors_[2], connectors_[3] })
	end)
	ctx.at(2340, function()
		local rec = marks_of("sp-mk-c-x")
		ctx.expect(rec.c.b1 == nil, "b1's arrow id is forgotten")
		ctx.expect(gone(rec.c.b2) == false and gone(rec.c.f1) == false, "b2 and f1 are untouched")
	end)
end)

-- Fix round 2 (2026-10-04): a save upgraded from schema 4 already has live sides and connectors, but migration 5
-- (schema_core.lua) only creates the empty storage.universal_edges.marks table — it never drew anything for what
-- already existed, so an upgraded world shows no border lines, map lines or connector arrows at all (the live finding
-- that sent this round back). edges.on_server_startup (control.lua's existing post-migration hook, run right after
-- startup.on_server_startup's migrations.run_all — the same place this codebase already does post-migration module
-- work, e.g. core.reset) now also calls marks.backfill(). The whole plugin suite runs one shared 4000-tick
-- simulation (harness/src/game.ts); the latest tick any other file schedules is runtime_game_test.lua's 3905,
-- which finishes and emits its result at that tick (nothing of it is still pending afterward) — ticks 3910+ are
-- clear, with margin before the 4000 cutoff, and nothing else uses this world position.
--
-- Simulating the upgrade only tears down THIS case's own side's marks and render objects, not the whole shared
-- table: script.raise_event(on_server_startup) resets every side in the whole suite (as edges_game_test.lua and
-- runtime_game_test.lua already do), and destroying every other test's render objects here would be a self-inflicted
-- false failure elsewhere, not a more faithful simulation — every edge's marks entry is independently empty on a
-- real upgraded save, so clearing just this one is representative.
t.case("marks: an upgraded save with live sides and connectors but no marks (migration 5's gap) gets them " ..
	"backfilled on the next startup, without double-drawing on the one after that", function(ctx)
	local connectors_ = { { cid = "b1", type = "belt", pos = 2, width = 1, params = { dir = "ab" } } }
	local first
	ctx.at(3910, function()
		deliver("ue.edge.update", { edge = record_of("sp-mk-bf", 1, { connectors = connectors_ }),
			a = { instanceId = 9242, surface = "nauvis", origin = { 90300, 3000 }, facing = 0 },
			b = { instanceId = 9243, surface = "nauvis", origin = { 90316, 2000 }, facing = 8 } })
	end)
	ctx.at(3920, function()
		local rec = marks_of("sp-mk-bf")
		ctx.expect(rec ~= nil and rec.border and rec.partner and rec.c.b1, "the normal, non-upgraded path draws everything")
		first = { bg = rec.border.game, bc = rec.border.chart, pg = rec.partner.game, pc = rec.partner.chart, c = rec.c.b1 }
		-- As a pre-migration-5 save would look right before this instance's module code loads: the table entry gone,
		-- and (unlike a real upgrade, where the prototypes simply never existed) the render objects explicitly
		-- destroyed, since this save actually drew them a moment ago.
		storage.universal_edges.marks["sp-mk-bf"] = nil
		for _, id in ipairs({ first.bg, first.bc, first.pg, first.pc, first.c }) do
			rendering.get_object_by_id(id).destroy()
		end
		ctx.expect(gone(first.bg) and gone(first.pg) and gone(first.c), "torn down like an upgraded save's would be")
	end)
	ctx.at(3930, function()
		-- The exact event control.lua's on_server_startup handler runs on every server start (the same seam
		-- edges_game_test.lua and runtime_game_test.lua already use to invoke it for real, not a direct function call).
		script.raise_event(clusterio_api.events.on_server_startup, {})
	end)
	local second
	ctx.at(3940, function()
		local rec = marks_of("sp-mk-bf")
		ctx.expect(rec ~= nil and rec.border and rec.partner and rec.c.b1, "backfilled: all four line objects and the arrow exist again")
		-- core.reset runs immediately before marks.backfill in the same on_server_startup handler, so every side
		-- (including a freshly backfilled one) is inactive again by the time the border is redrawn: red, not green.
		ctx.expect(is_color(obj(rec.border.game), 1, 0, 0) and is_color(obj(rec.border.chart), 1, 0, 0),
			"the backfilled border is red (world and map): the side is inactive again post-restart")
		ctx.expect(is_color(obj(rec.partner.game), 0.5, 0.5, 0.5) and is_color(obj(rec.partner.chart), 0.5, 0.5, 0.5),
			"the backfilled partner line is grey (world and map)")
		ctx.expect(obj(rec.c.b1).sprite == "utility/indication_arrow", "the backfilled arrow is the one-way sprite")
		second = { bg = rec.border.game, bc = rec.border.chart, pg = rec.partner.game, pc = rec.partner.chart, c = rec.c.b1 }
		ctx.expect(second.bg ~= first.bg and second.bc ~= first.bc and second.pg ~= first.pg and second.pc ~= first.pc
			and second.c ~= first.c, "freshly drawn objects, not the destroyed ones come back somehow")
	end)
	ctx.at(3950, function()
		-- Idempotent: running the exact same startup path again over a save whose marks are already valid must not
		-- double-draw. A fresh rendering.draw_line/draw_sprite call always returns a brand new id, so identical ids
		-- before and after is proof nothing new was drawn (not just that the count stayed the same).
		script.raise_event(clusterio_api.events.on_server_startup, {})
	end)
	ctx.at(3960, function()
		local rec = marks_of("sp-mk-bf")
		ctx.expect(rec.border.game == second.bg and rec.border.chart == second.bc, "border objects untouched (no new ids)")
		ctx.expect(rec.partner.game == second.pg and rec.partner.chart == second.pc, "partner objects untouched")
		ctx.expect(rec.c.b1 == second.c, "the arrow is untouched")
		ctx.expect(not gone(second.bg) and not gone(second.pg) and not gone(second.c), "and still valid, not destroyed")
	end)
end)

-- Fix round 2 (2026-10-04): a save upgraded straight from before this fix (not from before migration 5, the case
-- above) has live, valid marks — marks.backfill's valid_pair branch leaves those untouched — but their "game" lines
-- were drawn without draw_on_ground, since that's all rendering.draw_line took at the time. ground_pair's loop inside
-- backfill catches these up in place (same ids, not destroyed and redrawn) whenever a server start runs the backfill
-- pass, not only right after a schema upgrade. Ground x 95000-95016 (nothing else in test/game or harness/lua goes
-- near there). Ticks 2200-2215, not this file's own 3900s range: runtime_game_test.lua forgets storage.universal_
-- edges.rt.boot_id at tick 3900 and this file's own "upgraded save" case above forgets it again at 3930 and 3950
-- with no handshake afterward (unlike runtime_game_test.lua's own case, which re-handshakes at 3905) — ue_rt.inbox
-- (deliver, below) silently rejects every message from then on for the rest of the run (bridge.inbox's own early
-- "not s.rt.boot_id" guard), which a first pass at tick 3965 hit (found empirically: marks_of(id) came back nil,
-- no error, for exactly this reason).
t.case("marks: backfill sets draw_on_ground on an already-valid line drawn before this fix, without redrawing it",
	function(ctx)
		local id = "sp-mk-dg"
		local saved
		ctx.at(2200, function()
			deliver("ue.edge.update", { edge = record_of(id, 1, {
				a = { instanceId = 9242, surface = "nauvis", origin = { 95000, 3000 }, facing = 0 },
				b = { instanceId = 9243, surface = "nauvis", origin = { 95016, 2000 }, facing = 8 } }) })
		end)
		ctx.at(2205, function()
			local rec = marks_of(id)
			ctx.expect(rec ~= nil and rec.border and rec.partner, "the side's lines exist")
			saved = { bg = rec.border.game, pg = rec.partner.game }
			-- Simulate a pre-fix save: these lines were drawn the old way, so their "game" objects never got
			-- draw_on_ground. The attribute is writable (runtime-api.json's LuaRenderObject.draw_on_ground), so this
			-- stands in for "drawn before this fix" without needing an actual old save.
			obj(saved.bg).draw_on_ground = false
			obj(saved.pg).draw_on_ground = false
			ctx.expect(obj(saved.bg).draw_on_ground == false and obj(saved.pg).draw_on_ground == false,
				"simulated pre-fix state: drawn without draw_on_ground")
		end)
		ctx.at(2210, function()
			-- marks.backfill() directly, not edges.on_server_startup(): the latter resets every side in the shared
			-- save (edges.lua's on_server_startup also runs core.reset and lanes.deactivated for each one), which
			-- would be a self-inflicted false failure for every other case's side, not a more faithful simulation.
			marks.backfill()
		end)
		ctx.at(2215, function()
			local rec = marks_of(id)
			ctx.expect(rec.border.game == saved.bg and rec.partner.game == saved.pg,
				"the same objects, not recreated: backfill only flips draw_on_ground on an already-valid pair")
			ctx.expect(obj(saved.bg).draw_on_ground == true, "backfill set draw_on_ground on the border line")
			ctx.expect(obj(saved.pg).draw_on_ground == true, "...and the partner line")
		end)
	end)
