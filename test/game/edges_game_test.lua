local t = require("modules/v2_test/testlib")
local layouts = require("modules/v2_test/layouts")
local clusterio_api = require("modules/clusterio/api")
local core = require("modules/universal_edges/edges/edge_core")
-- Factorio allows require only while the file loads, never inside a step.
local ue = require("modules/universal_edges")
local connectors = require("modules/universal_edges/edges/connectors")
local geometry = require("modules/universal_edges/edges/geometry_core")

-- The controller and the instance plugin are scripted. TS → Lua messages go straight to ue_rt.inbox, and what Lua
-- sends is read from the bridge's outbound queue within the same step (it is flushed at the end of each tick).
-- A sync is authoritative for the whole instance, so each case starts with its own sync in a tick window of its own.
local seq = 0
local function deliver(msg_type, payload)
	seq = seq + 1
	local batch = { { id = "0000ed9e." .. seq, type = msg_type, payload = payload } }
	ue_rt.inbox("universal_edges", helpers.table_to_json(batch))
end

local function record(id, revision, fields)
	local rec = {
		id = id, revision = revision, trace = "0000ed9e.t" .. revision, me = "a", owner = "test", length = 64,
		deleted = false, connectors = {},
		a = { instanceId = 4242, surface = "nauvis", origin = { 0, 0 }, facing = 0 },
		b = { instanceId = 4243, surface = "nauvis", origin = { 64, 0 }, facing = 8 },
	}
	for k, v in pairs(fields or {}) do
		rec[k] = v
	end
	return rec
end

local function queued(msg_type)
	local found = {}
	for _, msg in ipairs(storage.universal_edges.bridge.out.universal_edges or {}) do
		if msg.type == msg_type then
			found[#found + 1] = msg.payload
		end
	end
	return found
end

local function traced(phase, edge)
	local found = {}
	for _, p in ipairs(queued("trace")) do
		if p.phase == phase and p.edge == edge then
			found[#found + 1] = p
		end
	end
	return found
end

local function side(id)
	return storage.universal_edges.edges[id]
end

t.case("edges: sync, update, tombstone and purge apply in revision order; a stale update is still reported", function(ctx)
	ctx.at(2, function()
		deliver("ue.edge.sync", { edges = {
			record("sp1a-live", 5, { connectors = { { cid = "c3", type = "probe", pos = 10, width = 1, params = {} } } }),
			record("sp1a-gone", 4, { deleted = true }),
			{ id = "sp1a-bad", revision = "five" },
		} })
		local live, gone = side("sp1a-live"), side("sp1a-gone")
		ctx.expect(live and live.revision == 5 and live.connectors.c3 ~= nil and not live.active, "a live side, inactive")
		ctx.expect(gone and gone.deleted, "a tombstone arrives as a shell")
		ctx.expect(side("sp1a-bad") == nil, "an invalid record is skipped")
		ctx.expect(storage.universal_edges.stats["ue.edges"].rejects >= 1, "and counted")
		local synced = queued("ue.edge.synced")
		ctx.expect(#synced == 1 and synced[1].n == 3, "the sync ends with ue.edge.synced")
		ctx.expect(#queued("ue.edge.applied") == 2, "one applied report per valid record")
	end)
	ctx.at(3, function()
		local elevated = { cid = "c6", type = "train", pos = 20, width = 2, params = { layer = "elevated" } }
		deliver("ue.edge.update", { edge = record("sp1a-live", 7, { connectors = { elevated } }) })
		local live = side("sp1a-live")
		ctx.expect(live.revision == 7 and live.connectors.c3 == nil, "a newer update replaces the connectors")
		ctx.expect(live.connectors.c6.params.layer == "elevated", "and a transport's params arrive intact")
		deliver("ue.edge.update", { edge = record("sp1a-live", 6) })
		ctx.expect(side("sp1a-live").revision == 7, "an older update is ignored")
		local applied = queued("ue.edge.applied")
		local last = applied[#applied]
		ctx.expect(last.id == "sp1a-live" and last.revision == 7 and last.sync == false, "but reported at the stored revision")
	end)
	ctx.at(4, function()
		deliver("ue.edge.update", { edge = record("sp1a-live", 8, { deleted = true }) })
		ctx.expect(side("sp1a-live").deleted, "a tombstone turns the side into a shell")
		deliver("ue.edge.purged", { id = "sp1a-live" })
		ctx.expect(side("sp1a-live") == nil, "a purge drops the shell")
	end)
	ctx.at(5, function()
		local moved = { instanceId = 4242, surface = "nauvis", origin = { 0, 640 }, facing = 0 }
		deliver("ue.edge.update", { edge = record("sp1a-gone", 9, { a = moved }) })
		local gone = side("sp1a-gone")
		ctx.expect(gone and not gone.deleted and gone.a.origin[2] == 640, "a re-created id with other geometry replaces it")
		local replaced = traced("replaced", "sp1a-gone")
		ctx.expect(#replaced == 1 and replaced[1].level == "warn", "and says so, at warn")
	end)
	-- M8: the old needle ('"id":"sp1a-gone"') only proved the id appeared somewhere; this proves the replace itself
	-- reached the wire, not just that ue.edge.applied mentioned the id.
	ctx.expect_ipc("universal_edges:out", '"phase":"replaced"')
	ctx.expect_ipc("universal_edges:out", '"edge":"sp1a-gone"')
end)

t.case("edges: activation takes an epoch once, a deactivation stales old batches, a server start resets", function(ctx)
	ctx.at(10, function()
		deliver("ue.edge.sync", { edges = { record("sp1a-act", 1) } })
		deliver("ue.edge.activation", { id = "sp1a-act", active = true, epoch = "0000ed9e.e1", trace = "0000ed9e.e1" })
		local s = side("sp1a-act")
		ctx.expect(s.active and s.epoch == "0000ed9e.e1", "activated under its epoch")
		deliver("ue.edge.activation", { id = "sp1a-act", active = true, epoch = "0000ed9e.e1", trace = "0000ed9e.e1" })
		ctx.expect(#traced("activated", "sp1a-act") == 1, "the same state again changes nothing, and logs nothing")
		deliver("ue.edge.activation", { id = "sp1a-act", active = false, trace = "0000ed9e.d1", reason = "stopped" })
		ctx.expect(not s.active and s.epoch == nil, "deactivated")
		ctx.expect(not core.epoch_ok(s, "0000ed9e.e1"), "a batch stamped with the old epoch is stale")
		local off = traced("deactivated", "sp1a-act")
		ctx.expect(#off == 1 and off[1].epoch == "0000ed9e.e1" and off[1].reason == "stopped", "logged with its epoch")
		deliver("ue.edge.activation", { id = "sp1a-nope", active = false, trace = "0000ed9e.d2" })
		ctx.expect(storage.universal_edges.stats["ue.edges"].unknown >= 1, "an unknown edge is counted")
	end)
	ctx.at(12, function()
		deliver("ue.edge.activation", { id = "sp1a-act", active = true, epoch = "0000ed9e.e2", trace = "0000ed9e.e2" })
		script.raise_event(clusterio_api.events.on_server_startup, {})
		ctx.expect(not side("sp1a-act").active and side("sp1a-act").epoch == nil, "a server start leaves sides inactive")
		-- The runtime forgot its boot id too (0B); hand it a new one, as the instance plugin would.
		ue_rt.startup(helpers.table_to_json({ boot_id = "7e57ed9e", instance_id = 4242, instance_name = "v2-test" }))
	end)
	ctx.expect_ipc("universal_edges:out", '"phase":"deactivated"')
end)

t.case("edges: a sync is authoritative: absent sides are dropped and every side is left inactive", function(ctx)
	ctx.at(20, function()
		deliver("ue.edge.sync", { edges = { record("sp1a-keep", 1), record("sp1a-drop", 2) } })
		deliver("ue.edge.activation", { id = "sp1a-keep", active = true, epoch = "0000ed9e.e3", trace = "0000ed9e.e3" })
	end)
	ctx.at(21, function()
		deliver("ue.edge.sync", { edges = { record("sp1a-keep", 1) } })
		ctx.expect(side("sp1a-drop") == nil, "a side absent from the sync is dropped")
		ctx.expect(side("sp1a-keep") and not side("sp1a-keep").active, "the others are left inactive")
		local applied = queued("ue.edge.applied")
		ctx.expect(#applied == 1 and applied[1].sync == true and applied[1].revision == 1, "reported, marked sync")
	end)
end)

t.case("edges: 40 edges in one sync leave as 40 applied reports under the soft limit", function(ctx)
	ctx.at(30, function()
		local edges = {}
		for i = 1, 40 do
			edges[i] = record("sp1a-bulk-" .. i, i)
		end
		deliver("ue.edge.sync", { edges = edges })
		ctx.expect(#queued("ue.edge.applied") == 40, "one applied report per edge")
		ctx.expect(ue.api_version == 1, "the Lua API version is unchanged")
		ctx.expect(ue.edges.get("sp1a-bulk-7").frame.origin[1] == 0 and #ue.edges.list() == 40, "the read-only views")
		ctx.expect(#traced("sync_large", nil) == 0, "40 is well under the 900-edge ceiling (M4, M8)")
	end)
	ctx.expect_ipc("universal_edges:out", '"id":"sp1a-bulk-1"')
	ctx.expect_ipc("universal_edges:out", '"id":"sp1a-bulk-40"')
	ctx.expect_ipc("universal_edges:out", '"n":40')
end)

local function barriers_in(surface, area)
	return surface.count_entities_filtered({ name = "ue-barrier", area = area })
end

-- Side a's band for origin (0, 0), facing 0 and L = 64: centres at y = -16 and x = -22, -3, …, 92 (spec §9).
local BAND = { { -40, -30 }, { 110, -2 } }

t.case("barriers: the ue-barrier prototype, 7 at once on generated chunks, UE-owned, gone with a tombstone", function(ctx)
	ctx.at(40, function()
		local p = prototypes.entity["ue-barrier"]
		ctx.expect(p ~= nil and p.type == "simple-entity", "the UE mod defines ue-barrier")
		ctx.expect(p ~= nil and p.collision_mask.layers.player and p.collision_mask.layers.object, "player and object layers")
		local surface = game.surfaces.nauvis
		surface.request_to_generate_chunks({ 0, 0 }, 4)
		surface.force_generate_chunk_requests()
		deliver("ue.edge.sync", { edges = { record("sp1a-wall", 1) } })
		local found = surface.find_entities_filtered({ name = "ue-barrier", area = BAND })
		ctx.expect(#found == 7, "7 barriers for L = 64, got " .. #found)
		ctx.expect(found[1] ~= nil and ue.owns(found[1]) and not found[1].destructible, "UE's, and indestructible")
		local chest = surface.create_entity({ name = "wooden-chest", position = { 0, 40 }, force = "player" })
		ctx.expect(chest ~= nil and not ue.owns(chest), "a vanilla entity is not UE's")
		if chest then
			chest.destroy()
		end
	end)
	ctx.at(41, function()
		deliver("ue.edge.update", { edge = record("sp1a-wall", 2, { deleted = true }) })
		ctx.expect(barriers_in(game.surfaces.nauvis, BAND) == 0, "a tombstone removes them")
		local left = 0
		for _, chunk in pairs(storage.universal_edges.barriers[game.surfaces.nauvis.index] or {}) do
			if chunk["sp1a-wall"] then
				left = left + 1
			end
		end
		ctx.expect(left == 0, "and forgets them")
	end)
end)

t.case("barriers: pending until their chunk is generated, pending again once it is deleted", function(ctx)
	-- Far from spawn, where nothing is generated: centres at y = 3184 and x = 3178, 3197, …, 3292 (chunks 99 to 102,
	-- row 99). The one at x = 3216 is alone in chunk (100, 99).
	local far = { a = { instanceId = 4242, surface = "nauvis", origin = { 3200, 3200 }, facing = 0 } }
	local function entries()
		local chunk = storage.universal_edges.barriers[game.surfaces.nauvis.index]["100,99"]
		return chunk and chunk["sp1a-far"]
	end
	ctx.at(50, function()
		deliver("ue.edge.sync", { edges = { record("sp1a-far", 1, far) } })
		local list = entries()
		ctx.expect(list ~= nil and #list == 1 and list[1].entity == nil, "the barrier waits in the index")
		game.surfaces.nauvis.request_to_generate_chunks({ 3216, 3184 }, 0)
		game.surfaces.nauvis.force_generate_chunk_requests()
	end)
	ctx.at(52, function()
		local list = entries()
		ctx.expect(list ~= nil and list[1].entity ~= nil and list[1].entity.valid, "on_chunk_generated built it")
		game.surfaces.nauvis.delete_chunk({ 100, 99 })
	end)
	ctx.at(54, function()
		local list = entries()
		ctx.expect(list ~= nil and list[1].entity == nil, "on_chunk_deleted put it back to waiting")
		deliver("ue.edge.sync", { edges = {} })
		ctx.expect(entries() == nil, "a dropped side leaves nothing in the index")
	end)
end)

t.case("barriers: script-created rails and train stops fit inside the barrier band", function(ctx)
	ctx.at(60, function()
		local surface = game.surfaces.nauvis
		deliver("ue.edge.sync", { edges = { record("sp1a-rails", 1) } })
		ctx.expect(barriers_in(surface, BAND) == 7, "the band is walled")
		local north = defines.direction.north
		local rail = surface.create_entity({ name = "straight-rail", position = { 11, -15 }, direction = north, force = "player" })
		local stop = surface.create_entity({ name = "train-stop", position = { 13, -15 }, direction = north, force = "player" })
		ctx.expect(rail ~= nil and rail.valid, "a rail is created inside a barrier")
		ctx.expect(stop ~= nil and stop.valid, "and a train stop")
		if rail then
			rail.destroy()
		end
		if stop then
			stop.destroy()
		end
		deliver("ue.edge.sync", { edges = {} })
	end)
end)

t.case("edges: activation reads the synced marker from storage, not a file-local (C1)", function(ctx)
	ctx.at(80, function()
		deliver("ue.edge.sync", { edges = { record("sp1a-c1", 1) } })
		local s = storage.universal_edges
		-- A freshly joined peer's control.lua starts this tick with no sync of its own applied; simulate that view
		-- directly, since a file-local gate (the pre-fix bug) can't be reached from here at all.
		s.synced_boot = nil
		deliver("ue.edge.activation", { id = "sp1a-c1", active = true, epoch = "0000ed9e.c1", trace = "0000ed9e.c1" })
		ctx.expect(not side("sp1a-c1").active, "an activation is ignored while the synced marker doesn't match this boot")
		s.synced_boot = s.rt.boot_id
		deliver("ue.edge.activation", { id = "sp1a-c1", active = true, epoch = "0000ed9e.c1", trace = "0000ed9e.c1" })
		ctx.expect(side("sp1a-c1").active and side("sp1a-c1").epoch == "0000ed9e.c1", "and honored once it matches")
	end)
end)

t.case("barriers: a side on a missing surface logs barrier_skipped once, at error", function(ctx)
	ctx.at(70, function()
		local nowhere = { a = { instanceId = 4242, surface = "no-such-surface", origin = { 0, 0 }, facing = 0 } }
		deliver("ue.edge.sync", { edges = { record("sp1a-nowhere", 1, nowhere) } })
		local s = side("sp1a-nowhere")
		ctx.expect(s ~= nil and s.surface_index == nil, "the side exists, without a surface")
		local skipped = traced("barrier_skipped", "sp1a-nowhere")
		ctx.expect(#skipped == 1 and skipped[1].level == "error" and skipped[1].reason == "surface", "once, at error")
		deliver("ue.edge.sync", { edges = {} })
	end)
end)

-- S1 (surfaces spec §11): a side whose surface is made after its record. ue.edge.update, not a sync: a sync drops every
-- side it doesn't list, and the save's last one is lanes_game_test.lua's at tick 95. "ue-s1" is a lab surface and no
-- planet, so gridworld never tiles it; the side is purged by tick 800, before routing's first resync (900) can see its
-- train box.
t.case("edges (S1): a side whose surface appears after its record takes it — indexed, walled, its endpoint built", function(ctx)
	local id = "s1-late"
	local function ep()
		local s = side(id)
		return s and connectors.get(s, "t1")
	end
	ctx.at(200, function()
		ctx.expect(game.get_surface("ue-s1") == nil, "no surface yet")
		deliver("ue.edge.update", { edge = record(id, 1, {
			a = { instanceId = 4242, surface = "ue-s1", origin = { 0, 0 }, facing = 0 },
			b = { instanceId = 4243, surface = "ue-s1", origin = { 64, 0 }, facing = 8 },
			connectors = { { cid = "t1", type = "train", pos = 10, width = 6, params = { dir = "ab", layer = "ground" } } },
		}) })
		ctx.expect(side(id) ~= nil and side(id).surface_index == nil, "the side exists, without a surface")
	end)
	ctx.at(230, function()
		local e = ep()
		ctx.expect(e ~= nil and e.state == "pending" and not e.built,
			"its endpoint waits: nothing is built without a surface; state " .. tostring(e and e.state))
		local surface = game.create_surface("ue-s1")
		surface.generate_with_lab_tiles = true
		surface.request_to_generate_chunks({ 32, 0 }, 3)
		surface.force_generate_chunk_requests()
	end)
	ctx.at(231, function()
		local surface = game.get_surface("ue-s1")
		local s, e = side(id), ep()
		ctx.expect(s.surface_index == surface.index, "it took the surface")
		local indexed = storage.universal_edges.by_surface[surface.index]
		ctx.expect(indexed ~= nil and indexed[id] == true, "indexed by surface")
		ctx.expect(e ~= nil and e.frame.surface_index == surface.index, "and so did its endpoint")
		ctx.expect(surface.count_entities_filtered({ name = "ue-barrier" }) == geometry.barrier_count(64),
			"its barriers, on the generated chunks")
	end)
	local function built(offset)
		ctx.at(offset, function()
			local e = ep()
			if not (e and e.state == "ready") and offset < 780 then
				built(offset + 20)
				return
			end
			ctx.expect(e ~= nil and e.state == "ready",
				"the train endpoint was built once the surface came; state " .. tostring(e and e.state))
			deliver("ue.edge.purged", { id = id })
			ctx.expect(side(id) == nil and game.get_surface("ue-s1").count_entities_filtered({ name = "ue-barrier" }) == 0,
				"purged, barriers and all")
		end)
	end
	built(240)
	ctx.expect_ipc("universal_edges:out", '"phase":"surface_found"')
end)

-- S3 (surfaces spec §11, U8): UE's link belt and pipe are deep copies of vanilla's, which Space Age gives heating_energy;
-- on Aquilo, where entities need heat, they would freeze. A vanilla belt beside them shows the case can see freezing.
-- Aquilo exists from tick 100 (gridworld's tile config makes every planet); x 2996-3007, y 2996-3003 is this case's.
t.case("S3: the link belt and pipe carry no heating, so a link belt doesn't freeze on Aquilo", function(ctx)
	local link, control
	ctx.at(700, function()
		local belt, pipe = prototypes.entity["ue-link-belt"], prototypes.entity["ue-link-pipe"]
		ctx.expect(belt.heating_energy == 0, "ue-link-belt: no heating, got " .. belt.heating_energy)
		ctx.expect(pipe.heating_energy == 0, "ue-link-pipe: no heating, got " .. pipe.heating_energy)
		local planet = game.planets.aquilo
		local surface = planet.surface or planet.create_surface()
		surface.request_to_generate_chunks({ 3000, 3000 }, 0)
		surface.force_generate_chunk_requests()
		local tiles = {}
		for x = 2996, 3007 do
			for y = 2996, 3003 do
				tiles[#tiles + 1] = { name = "concrete", position = { x, y } }
			end
		end
		surface.set_tiles(tiles)
		link = surface.create_entity({ name = "ue-link-belt", position = { 3000.5, 3000.5 }, force = "player" })
		control = surface.create_entity({ name = "transport-belt", position = { 3004.5, 3000.5 }, force = "player" })
		ctx.expect(link ~= nil and control ~= nil, "both belts on Aquilo")
	end)
	-- The vanilla belt takes about 600 ticks to freeze; wait for it (bounded) and judge the link belt at that tick.
	layouts.wait(t, ctx, 700, 3000, function()
		return control ~= nil and control.valid and control.frozen
	end, function(k)
		ctx.expect(k ~= nil, "the vanilla belt froze: this case can see freezing")
		ctx.expect(link ~= nil and link.valid and not link.frozen, "the link belt didn't")
		for _, e in ipairs({ link, control }) do
			if e and e.valid then
				e.destroy()
			end
		end
	end)
end)
