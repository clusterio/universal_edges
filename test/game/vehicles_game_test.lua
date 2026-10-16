local t = require("modules/v2_test/testlib")
local layouts = require("modules/v2_test/layouts")
local loop = require("modules/v2_test/loopback")
local connectors = require("modules/universal_edges/edges/connectors")
local body_core = require("modules/universal_edges/transports/body_core")
local vehicle = require("modules/universal_edges/transports/vehicle")
local ue_control = require("modules/universal_edges/control")
local ue = require("modules/universal_edges")

local function S()
	return storage.universal_edges
end

local L = 32
local function EDGE(x)
	return { x, 3000, 0 }, { x + L, 2000, 8 }
end

-- Every capture and every credit, recorded: speeds, destinations, ticks, and the spawned speed at once. A --benchmark
-- run has no LuaPlayer, so a rider commit should prompt is named in held_names[edge], or held_names[unit number] for one
-- vehicle only, at capture instead.
local captures, spawns, reject_edge, held_names, corrupt_item, raise_restore = {}, {}, {}, {}, {}, {}
-- SP4 §7.5: the restored hook, as an extension sees it: each call's why, per edge, in order.
local restored = {}
ue.transfers.extend{
	name = "sp3-vrestored",
	types = { vehicle = true },
	restored = function(ep, v, why)
		restored[ep.edge] = (restored[ep.edge] and restored[ep.edge] .. "," or "") .. why .. (v.valid and "" or "!")
	end,
}
local before_credit, busy_edge = {}, {} -- edge -> function run right before the destination's credit (a far side that differs)
local vt = connectors.types.vehicle
local capture, credit = vt.capture, vt.credit
vt.capture = function(ep, v)
	local held = ep.data.held and ep.data.held[ep.me == "a" and "ab" or "ba"]
	capture(ep, v)
	local now = ep.data.held and ep.data.held[ep.me == "a" and "ab" or "ba"]
	if now and now ~= held then
		captures[#captures + 1] = { edge = ep.edge, tick = game.tick, speed = v.speed, name = v.name,
			dest = v.type == "spider-vehicle" and v.autopilot_destinations or nil }
		local name = held_names[ep.edge] or held_names[v.unit_number]
		if name then
			now.passenger = name
		end
	end
end
vt.credit = function(ep, dir, body, meta)
	if reject_edge[ep.edge] then
		return "reject"
	end
	if busy_edge[ep.edge] then
		return "busy"
	end
	if before_credit[ep.edge] then
		before_credit[ep.edge]()
	end
	-- SP3b review I1: rename a real captured item to one this server doesn't have, right before credit sees it, since
	-- a single install can't actually hold fewer items than itself. Proves vehicle.lua's credit shares train.lua's
	-- missing-item pre-check (missing_core), not only that it's imported.
	if corrupt_item[ep.edge] then
		for _, s in pairs(body.inv or {}) do
			if s.i and s.i[1] then
				s.i[1].n = "sp3b-missing-item"
				break
			end
		end
	end
	-- Final review: vehicle refuse-on-raise. missing_core's pre-check only walks entity/item/quality names, so a bad
	-- color value survives it and reaches vehicle.restore_body's v.color = body.color, which raises.
	if raise_restore[ep.edge] then
		body.color = "sp3b-not-a-color"
	end
	local result = credit(ep, dir, body, meta)
	if result == "ok" then
		local x, y = body_core.landing(ep.frame, body)
		local _, _, _, dest = body_core.landing(ep.frame, body)
		local found = game.surfaces.nauvis.find_entities_filtered({ name = body.name, position = { x, y }, radius = 9 })
		local v = found[#found]
		spawns[#spawns + 1] = { edge = ep.edge, tick = game.tick, v = v, body = body, speed = v and v.speed, dest = dest,
			trace = meta.trace }
	end
	return result
end

-- Every UE prompt request, by player and zone key, with its fallback key and the crossing's trace.
local prompts = {}
local players = require("modules/universal_edges/transports/players")
local cross = players.cross
-- forward every argument (SP3b T3 finding): a fixed arity here silently drops any trailing one a caller adds later
-- (a rider's commit passes the crossing's trace and held) for the whole shared save, since this patch replaces the one
-- players.lua table every *_game_test.lua file requires.
players.cross = function(name, key, fallback, surface, x, y, ...)
	local got = cross(name, key, fallback, surface, x, y, ...)
	prompts[#prompts + 1] = { name = name, key = key, fallback = fallback, trace = got }
	return got
end

-- A zone hook for the corner case's square (crossing spec §7.3): a rider beyond an edge's end is prompted for the
-- hook's key, the tile the vehicle's second hop ends on. Nothing here names a plugin.
players.zones({
	name = "sp3-vzone",
	zone = function(surface, x, y)
		if surface == "nauvis" and x >= 7664 and x < 7672 and y >= 3992 and y < 4000 then
			return "sp3-vzone:d"
		end
	end,
	place = function() return nil end,
})

-- A join whose arrival has no entry (crossing spec §6.1): the stand-in joins, and the controller answers with none, so
-- placement only seats them in a vehicle waiting for them (§6.4).
local joins = 0
local function join(name, unit_number)
	joins = joins + 1
	ue_rt.player_join(name, unit_number)
	ue_rt.inbox("universal_edges", helpers.table_to_json({ { id = "0000c4ba." .. joins, type = "ue.player.arrival",
		payload = { player = name } } }))
end

local function ground(x1, y1, x2, y2)
	loop.ground(x1, y1, x2, y2)
end

--- Inside a step: four tiles at their own offsets with gridworld's tile frames (SP2 §12.1), joined by looped edges
--- <p>ab (A east → B west), <p>ac (A north → C south), <p>bd (B north → D south) and <p>cd (C east → D west).
local function corner(p, OA, OB, OC, OD)
	local function at(o, x, y, facing)
		return { o[1] + x, o[2] + y, facing }
	end
	for _, o in ipairs({ OA, OB, OC, OD }) do
		ground(o[1] - 10, o[2] - 74, o[1] + 140, o[2] + 74)
	end
	loop.edge(p .. "ab", 64, {}, at(OA, 64, 0, 4), at(OB, 64, 64, 12))
	loop.edge(p .. "ac", 64, {}, at(OA, 0, 0, 0), at(OC, 64, 0, 8))
	loop.edge(p .. "bd", 64, {}, at(OB, 64, 0, 0), at(OD, 128, 0, 8))
	loop.edge(p .. "cd", 64, {}, at(OC, 64, -64, 4), at(OD, 64, 0, 12))
end

local function spawn(name, x, y, orientation, speed)
	local v = assert(game.surfaces.nauvis.create_entity({ name = name, position = { x, y }, orientation = orientation,
		force = "player" }))
	if v.type == "car" then
		v.get_fuel_inventory().insert({ name = "coal", count = 10 })
		v.speed = speed
	end
	ue_rt.watch(v.unit_number)
	return v
end

local function rider(v, role)
	local c = game.surfaces.nauvis.create_entity({ name = "character", position = v.position, force = "player" })
	if role == "driver" then
		v.set_driver(c)
	else
		v.set_passenger(c)
	end
	return c
end

local function carried(v, driver, passenger)
	S().waiting[v.unit_number] = { driver = driver, passenger = passenger, expires = game.tick + 36000 }
end

local function spawned(edge, name)
	for i = #spawns, 1, -1 do
		if spawns[i].edge == edge and spawns[i].body.name == name then
			return spawns[i]
		end
	end
end

-- The cases below that wait for a crossing don't sample at a fixed tick, so they don't depend on the vehicle walk's
-- phase (which shifts whenever a case adds "v" endpoints). The vehicle type's schedule (vehicle.lua) is per_tick = 2,
-- interval = 300: an endpoint is visited once a walk, and lanes.visit skips a visit that comes less than the interval
-- after the last. A record applied just after its endpoint's visit waits for the next walk, whose start is up to 300
-- ticks away; a visit that comes too early in that walk skips, and the walk after it is another 300 ticks; the walk
-- itself reaches its endpoint after at most ceil(N / 2) ticks, N = the live "v" endpoints in the save at run time.
-- Bound = 300 (to the next walk) + 300 (one skipped visit) + ceil(N / 2) (the walk's length) ticks.
local function walk_bound()
	local n = 0
	for _ in pairs(S().eps.vehicle or {}) do
		n = n + 1
	end
	return 2 * 300 + math.ceil(n / 2)
end

--- From offset `from` until check() holds, at most walk_bound() ticks (plus `more`); then done(offset), in that tick.
local function wait_for(ctx, from, check, what, done, more)
	local limit = from + walk_bound() + (more or 0)
	layouts.wait(t, ctx, from, limit, check, function(k)
		ctx.expect(k ~= nil, what .. " within " .. (limit - from) .. " ticks")
		if k ~= nil then
			done(k)
		end
	end)
end

t.case("vehicles: a car with a driver and a passenger crosses; both are prompted at commit and seated, one already here " ..
	"and one joining after (D35)", function(ctx)
	local car
	ctx.at(1900, function()
		ground(7296, 2990, 7340, 3010)
		ground(7296, 1980, 7340, 2010)
		loop.edge("sp3-v1", L, {}, EDGE(7300))
	end)
	ctx.at(1930, function()
		local bob = game.surfaces.nauvis.create_entity({ name = "character", position = { 7312, 1985 }, force = "player" })
		S().players.stand_in = { bob = bob.unit_number } -- bob is online on side b before the car comes
		-- M5: bob's arrival was fetched before the car came. Seated at credit, his placing must go, or player_sync
		-- handing his character back (spectator to character) would place him again, out of his seat.
		S().players.placing.bob = { expires = game.tick + 3600 }
		-- crossing-arrival spec §5.1: bob is still guarded as arriving; the credit seat must settle him too.
		local a = S().players; a.arriving = a.arriving or {}; a.arriving.bob = true
		car = spawn("car", 7310, 2998, 0, 0.3) -- local (10, -2): past the line
		rider(car, "passenger")
		carried(car, "ann", "bob")
		held_names["sp3-v1-x"] = "hal" -- seated on side a: commit prompts hal
	end)
	wait_for(ctx, 1931, function()
		return spawned("sp3-v1-y", "car") ~= nil and not car.valid -- credited on b, then committed on a (a tick later)
	end, "the car crossed", function(k)
		local got = spawned("sp3-v1-y", "car")
		ctx.expect(got and got.v and got.v.valid and not car.valid, "the car arrived on side b and left side a at commit")
		local hal
		for _, c in ipairs(prompts) do
			hal = c.name == "hal" and c or hal
		end
		-- M2 (§9: one trace per crossing): the rider's crossed line carries the vehicle's offer/credit trace.
		ctx.expect(hal and got and hal.trace == got.trace, "hal's crossing shares the vehicle's trace: "
			.. tostring(hal and hal.trace) .. " vs " .. tostring(got and got.trace))
		ctx.expect(hal and hal.key == "edge:sp3-v1-x" and hal.fallback == nil, "hal's key is the edge itself: no fallback")
		ctx.expect(got.v.disabled_by_script, "frozen: its driver hasn't sat yet (D36)")
		ctx.expect(got.v.get_passenger() ~= nil, "bob, already here, sits at once")
		ctx.expect(S().players.placing.bob == nil, "seated at credit, bob has no placing left (M5)")
		ctx.expect(not players.arriving("bob"), "seated at credit, bob's arrival guard ends (spec §5.1)")
		local w = S().waiting[got.v.unit_number]
		ctx.expect(w and w.driver == "ann", "the car waits for ann, its driver")
		ctx.expect(w and w.trace == got.trace, "the waiting seat keeps the crossing's trace for its seated line (M12)")
		local ann = game.surfaces.nauvis.create_entity({ name = "character", position = { 7310, 1985 }, force = "player" })
		join("ann", ann.unit_number)
		ctx.at(k + 3, function()
			local v = spawned("sp3-v1-y", "car").v
			ctx.expect(v.get_driver() ~= nil and not v.disabled_by_script, "ann, joining after, drives; the car is released")
		end)
	end)
	ctx.expect_ipc("universal_edges:out", '"player":"ann"')
	ctx.expect_ipc("universal_edges:out", '"player":"bob"')
end)

t.case("vehicles: speed survives (D36): coasting car and tank at their captured speed; a driven car frozen until its " ..
	"driver sits 600 ticks on; the TTL releases one whose driver never comes", function(ctx)
	-- One 8-long edge per vehicle: a lane takes one vehicle at a time, and a waiting one would reach the barrier.
	local list = { { "coasting", "car", 0.4 }, { "tank", "tank", 0.3 }, { "cid", "car", 0.35 }, { "dan", "car", 0.25 } }
	local function find(tag)
		for _, s in ipairs(spawns) do
			if s.edge == "sp3-v2" .. tag .. "-y" then
				return s
			end
		end
	end
	ctx.at(1900, function()
		for i, v in ipairs(list) do
			local x = 7380 + 20 * i
			ground(x - 4, 2990, x + 12, 3010)
			ground(x - 4, 1980, x + 12, 2010)
			loop.edge("sp3-v2" .. v[1], 8, {}, { x, 3000, 0 }, { x + 8, 2000, 8 })
		end
	end)
	-- The lane is only 8 tiles long with a barrier at its end (a waiting vehicle would reach it): capture must
	-- succeed before a moving car gets there, which needs the new edge's built-in "v" endpoint to already be ready.
	-- A newly built endpoint on the vehicle type's own walk (per_tick = 2, interval = 300, vehicle.lua) can just
	-- miss the walk's current pass and wait out the rest of it plus a full next pass before its first visit — up to
	-- 2 x interval = 600 ticks. Spawning only once that head start has passed keeps the capture race (not just the
	-- test's own sampling) clear of that budget, so a coasting car's speed is still its spawn speed when it crosses.
	local BUDGET = 600
	local SPAWN_AT = 1900 + BUDGET
	ctx.at(SPAWN_AT, function()
		for i, v in ipairs(list) do
			local car = spawn(v[2], 7380 + 20 * i + 4, 2999, 0, v[3]) -- local y -1: past the line
			rider(car, "passenger")
			if v[1] == "cid" or v[1] == "dan" then
				carried(car, v[1], nil)
			end
		end
	end)
	-- Capture itself runs off ue.vehicle.watch, a periodic task on its own fixed 10-tick interval (not the walk
	-- above), so once the endpoints are ready a short, deadline-sampled window is enough. Still sample every tick
	-- for each vehicle's own arrival, and check it at that moment (not a shared fixed tick), since a coasting car's
	-- speed is only guaranteed to equal its captured speed right then.
	local ARRIVE_BUDGET = 60
	local DEADLINE = SPAWN_AT + ARRIVE_BUDGET
	local arrived = {}
	for k = SPAWN_AT + 1, DEADLINE do
		ctx.at(k, function()
			for _, v in ipairs(list) do
				local tag = v[1]
				if not arrived[tag] then
					local got = find(tag)
					if got then
						arrived[tag] = k
						if tag == "coasting" or tag == "tank" then
							ctx.expect(got.speed == got.body.speed and got.body.speed > 0.2,
								tag .. " spawned at its captured speed")
							ctx.expect(not got.v.disabled_by_script, tag .. ": no driver to wait for, so it moves on at once")
						end
					end
				end
			end
		end)
	end
	ctx.at(DEADLINE + 1, function()
		for _, v in ipairs(list) do
			ctx.expect(arrived[v[1]], v[1] .. " crossed within " .. ARRIVE_BUDGET .. " ticks of spawning")
		end
		S().waiting[find("dan").v.unit_number].expires = game.tick + 5
	end)
	-- The TTL release runs off ue.vehicle.watch, a periodic task on its own fixed 10-tick interval (not the walk
	-- above), so a short fixed gap after setting the expiry is still safe.
	ctx.at(DEADLINE + 31, function()
		ctx.expect(not find("dan").v.disabled_by_script, "the TTL released the car whose driver never came")
	end)
	-- "cid" stays frozen a good while before its carried driver joins, proving nothing released it early. Not a
	-- walk-budget wait (it has already arrived and frozen) — BUDGET is reused here only as an already-justified,
	-- generously long margin.
	ctx.at(DEADLINE + 1 + BUDGET, function()
		local got = find("cid")
		ctx.expect(got.v.disabled_by_script and got.v.speed == got.body.speed, "still frozen at its captured speed")
		local c = game.surfaces.nauvis.create_entity({ name = "character", position = { got.v.position.x, 1985 },
			force = "player" })
		join("cid", c.unit_number)
	end)
	ctx.at(DEADLINE + 1 + BUDGET + 3, function()
		local v = find("cid").v
		ctx.expect(not v.disabled_by_script and v.get_driver() ~= nil, "the driver sat, and it moves on")
	end)
	ctx.expect_ipc("universal_edges:out", '"reason":"ttl"')
end)

t.case("vehicles: a spidertron remote's selection goes on the watch", function(ctx)
	ctx.at(1900, function()
		ground(7780, 2990, 7800, 3010)
		local sp = game.surfaces.nauvis.create_entity({ name = "spidertron", position = { 7790, 3005 }, force = "player" })
		vehicle.watch_selection({ sp })
		ctx.expect(S().watch[sp.unit_number] == sp, "watched")
		ctx.expect(script.get_event_handler(defines.events.on_player_used_spidertron_remote) ~= nil,
			"and the remote's event is handled")
		sp.destroy()
	end)
end)

t.case("vehicles: a reject is not re-captured until the driver changes (M8); busy with no room waits held", function(ctx)
	local car, blocked, walls = nil, nil, {}
	ctx.at(1900, function()
		ground(7596, 2990, 7640, 3010)
		ground(7596, 1980, 7640, 2010)
		ground(7696, 2990, 7740, 3010)
		ground(7696, 1980, 7740, 2010)
		loop.edge("sp3-v4", L, {}, EDGE(7600))
		loop.edge("sp3-v5", L, {}, EDGE(7700))
		reject_edge["sp3-v4-y"] = true
	end)
	ctx.at(1930, function()
		car = spawn("car", 7610, 2998, 0, 0.3)
		rider(car, "passenger")
		blocked = spawn("car", 7710, 2998, 0, 0.3)
		rider(blocked, "passenger")
		for x = 7701, 7739 do -- side b's landing box, full
			for y = 1982, 1999 do
				walls[#walls + 1] = game.surfaces.nauvis.create_entity({ name = "stone-wall", position = { x + 0.5, y + 0.5 },
					force = "player" })
			end
		end
	end)
	wait_for(ctx, 1931, function()
		return car.valid and S().rejected[car.unit_number] ~= nil
	end, "the car was rejected", function(k)
		ctx.expect(car.valid and not car.disabled_by_script and S().rejected[car.unit_number], "rejected: unfrozen, marked")
		ctx.expect(blocked.valid and blocked.disabled_by_script, "busy: still held, frozen")
		ctx.at(k + 100, function()
			local n = 0
			for _, c in ipairs(captures) do
				n = n + ((c.edge == "sp3-v4-x") and 1 or 0)
			end
			ctx.expect(n == 1, "not captured again while marked; captures: " .. n)
			ctx.expect(restored["sp3-v4-x"] == "reject", "the extension's restored hook got reject: " ..
				tostring(restored["sp3-v4-x"]))
			reject_edge["sp3-v4-y"] = nil
			vehicle.on_driving({ entity = car })
			for _, w in ipairs(walls) do
				w.destroy()
			end
			local from = k + 101
			wait_for(ctx, from, function()
				return spawned("sp3-v4-y", "car") ~= nil
			end, "after the driver change it crossed", function() end)
			-- Re-offers back off (300, then 600 ticks) before the walk's next visit, so the busy car's bound adds the
			-- backoff's 600 to the walk bound.
			wait_for(ctx, from, function()
				return spawned("sp3-v5-y", "car") ~= nil and not blocked.valid
			end, "room again: the busy car crossed once", function() end, 600)
		end)
	end)
	ctx.expect_ipc("universal_edges:out", '"phase":"no_room"')
	ctx.expect_ipc("universal_edges:out", '"phase":"rejected"')
end)

t.case("vehicles: a corner takes two hops with no wait at the middle tile, at its captured speed, its riders seated at the " ..
	"diagonal tile; a vehicle held at a corner is captured by one edge only; a spidertron keeps its route in order " ..
	"across an edge and on, and drops a follow_target (D35, D36)",
	function(ctx)
		local OA, OB, OC, OD = { 7600, 4000 }, { 7900, 4000 }, { 7600, 4300 }, { 8200, 4000 }
		local car, spider
		-- Well before the car, as the passenger-only case below: the corner's "v" endpoints are ready only once the
		-- vehicle walk reaches them, and a walk takes ceil(N / 2) ticks (N = 294 with main's and playtest's cases in one
		-- save, 2026-10-14, so made at 2000 they were ready at 2083 and the second hop came after the 2100 sample).
		ctx.at(1800, function()
			corner("sp3-", OA, OB, OC, OD)
		end)
		ctx.at(2030, function()
			car = spawn("car", OA[1] + 64.8, OA[2] - 0.8, 0.125, 0.3) -- in A's corner square: past both of A's lines
			rider(car, "passenger")
			carried(car, "eve", "fay")
			-- Eve is carried, not seated on A: name her as this car's live rider, so A's commit prompts her. By unit
			-- number, not edge: the two spidertrons cross A's edges too, and must not prompt her.
			held_names[car.unit_number] = "eve"
			spider = spawn("spidertron", OA[1] + 40, OA[2] + 40, 0)
			for _, p in ipairs({ { 40, 40 }, { 62, 20 }, { 70, -24 }, { 70, -10 }, { 90, -20 } }) do
				spider.add_autopilot_destination({ OA[1] + p[1], OA[2] + p[2] })
			end
			spider.autopilot_patrol_size = 2
			-- A spidertron following a car across A's north edge: its follow_target stays behind (§10.2).
			local target = game.surfaces.nauvis.create_entity({ name = "car", position = { OA[1] + 20, OA[2] - 3 },
				force = "player" })
			local follower = spawn("spidertron", OA[1] + 20, OA[2] - 1, 0)
			follower.follow_target = target
		end)
		ctx.at(2100, function()
			local hops = {}
			for _, c in ipairs(captures) do
				if c.name == "car" and string.find(c.edge, "^sp3%-[abcd][abcd]%-x$") then
					hops[#hops + 1] = c
				end
			end
			ctx.expect(#hops == 2, "two hops: " .. #hops)
			local middle = hops[1] and (hops[1].edge == "sp3-ab-x" and "b" or "c")
			ctx.expect(hops[2] and hops[2].edge == "sp3-" .. middle .. "d-x", "A, then the middle tile, then D")
			ctx.expect(hops[2] and hops[2].tick - hops[1].tick <= 20, "no wait at the middle tile")
			ctx.expect(hops[2] and hops[2].speed == hops[1].speed, "the captured speed, across both hops")
			local other = middle == "b" and "sp3-ac-y" or "sp3-ab-y"
			ctx.expect(spawned(other, "car") == nil, "held at the corner, it went to one middle tile only")
			local got = spawned("sp3-" .. middle .. "d-y", "car")
			ctx.expect(got and got.speed == hops[1].speed and got.v.disabled_by_script, "D: that speed, frozen for eve")
			for _, name in ipairs({ "eve", "fay" }) do
				local c = game.surfaces.nauvis.create_entity({ name = "character", position = { OD[1] + 100, OD[2] - 30 },
					force = "player" })
				join(name, c.unit_number)
			end
		end)
		ctx.at(2103, function()
			local v = (spawned("sp3-bd-y", "car") or spawned("sp3-cd-y", "car")).v
			ctx.expect(v.get_driver() ~= nil and v.get_passenger() ~= nil and not v.disabled_by_script,
				"seated at the diagonal tile and released")
		end)
		ctx.at(3600, function()
			-- Asserted on the body D credited, not the live queue: with a patrol size of 2 it cycles.
			local got = spawned("sp3-bd-y", "spidertron")
			ctx.expect(got ~= nil, "the spidertron crossed A → B → D")
			local want = { { 70, -24 }, { 70, -10 }, { 90, -20 } } -- not reached when B captured it at its north line
			ctx.expect(got and #got.dest == #want and got.body.patrol == 2, "three destinations and the patrol size")
			for i, w in ipairs(want) do
				local p = got and got.dest[i]
				ctx.expect(p and math.abs(p.x - (OD[1] + w[1])) < 0.01 and math.abs(p.y - (OD[2] + w[2])) < 0.01,
					"destination " .. i .. " in place, in order")
			end
			local followed = spawned("sp3-ac-y", "spidertron")
			ctx.expect(followed and followed.v.valid and followed.v.follow_target == nil, "the follower arrived unfollowing")
		end)
		ctx.expect_ipc("universal_edges:out", '"phase":"follow_dropped"')
		ctx.at(2101, function()
			local first -- the edge A captured the car on: the first hop
			for _, c in ipairs(captures) do
				if c.name == "car" and string.find(c.edge, "^sp3%-a[bc]%-x$") then
					first = first or c.edge
				end
			end
			local hooked
			for _, c in ipairs(prompts) do
				if c.name == "eve" and c.key == "sp3-vzone:d" then
					hooked = c
				end
				ctx.expect(not (c.name == "eve" and string.find(c.key, "^edge:")),
					"neither A nor the middle tile prompts eve for an edge: " .. c.key)
			end
			ctx.expect(hooked, "beyond A's edges, eve is prompted for the hook's zone, where the second hop ends (§7.3)")
			-- M2 (§4 step 2): a hook key carries the edge crossed as its fallback, so a corner with no diagonal tile
			-- still takes her across that edge.
			ctx.expect(hooked and first and hooked.fallback == "edge:" .. first, "eve's fallback is A's edge, "
				.. tostring(first) .. ": " .. tostring(hooked and hooked.fallback))
		end)
	end)

t.case("vehicles: a passenger-only car keeps its speed through a corner's middle tile, frozen there like a driven " ..
	"one (M3, §10.3, D36)", function(ctx)
	local OA, OB, OC, OD = { 7600, 5000 }, { 7900, 5000 }, { 7600, 5300 }, { 8200, 5000 }
	ctx.at(2200, function()
		corner("sp3-p", OA, OB, OC, OD)
	end)
	ctx.at(2430, function() -- well after the edges: the first pass captures it while it still moves
		local car = spawn("car", OA[1] + 64.8, OA[2] - 0.8, 0.125, 0.3) -- in A's corner square: past both of A's lines
		rider(car, "passenger")
		carried(car, nil, "gus") -- a passenger, and no driver anywhere
		-- §10: gus is this car's live rider on A, as eve is in the corner case above. No zone hook covers this corner
		-- (sp3-vzone is the other case's square), so A's commit has no key for him beyond its edges: no prompt.
		held_names[car.unit_number] = "gus"
	end)
	ctx.at(2500, function()
		local hops = {}
		for _, c in ipairs(captures) do
			if c.name == "car" and string.find(c.edge, "^sp3%-p[abcd][abcd]%-x$") then
				hops[#hops + 1] = c
			end
		end
		ctx.expect(#hops == 2, "two hops: " .. #hops)
		ctx.expect(hops[2] and hops[2].speed == hops[1].speed, "the captured speed at the middle tile's capture too: "
			.. tostring(hops[1] and hops[1].speed) .. " then " .. tostring(hops[2] and hops[2].speed))
		local middle = hops[1] and (hops[1].edge == "sp3-pab-x" and "b" or "c")
		local got = spawned("sp3-p" .. tostring(middle) .. "d-y", "car")
		ctx.expect(got and got.speed == hops[1].speed and not got.v.disabled_by_script,
			"D: that speed, moving on (no driver to wait for)")
		for _, c in ipairs(prompts) do
			ctx.expect(c.name ~= "gus", "beyond an edge's end with no hook, gus gets no prompt (§7.3, §10): " .. c.key)
		end
	end)
end)

t.case("vehicles: a waiting seat whose vehicle is gone is dropped and logged, and the rider's other waiting seat " ..
	"still takes them, logged with its crossing's trace (M4, M12, crossing spec §6.4)", function(ctx)
	ctx.at(2600, function()
		ground(7596, 5990, 7640, 6010)
		local function gone()
			local v = game.surfaces.nauvis.create_entity({ name = "car", position = { 7600, 6000 }, force = "player" })
			local un = v.unit_number
			v.destroy()
			return un
		end
		local function traced(phase)
			local found
			for _, m in ipairs(S().bridge.out.universal_edges or {}) do
				if m.type == "trace" and m.payload.phase == phase and m.payload.player == "ida" then
					found = m.payload
				end
			end
			return found
		end
		local ida = game.surfaces.nauvis.create_entity({ name = "character", position = { 7630, 6005 }, force = "player" })
		local un = gone()
		S().waiting[un] = { driver = "ida", expires = game.tick + 36000, trace = "sp3-vg.1" }
		ctx.expect(players.seat("ida", ida) == false, "alone, a gone vehicle's seat seats no one")
		ctx.expect(S().waiting[un] == nil, "and is dropped")
		local g = traced("seat_gone")
		ctx.expect(g and g.op == "ue.player" and g.level == "warn" and g.unit_number == un and g.trace == "sp3-vg.1",
			"logged as ue.player seat_gone at warn, with its unit number and trace")
		-- Beside a live one: whichever pairs() visits first, the live seat takes her.
		local car = game.surfaces.nauvis.create_entity({ name = "car", position = { 7615, 6003 }, force = "player" })
		local un2 = gone()
		S().waiting[un2] = { driver = "ida", expires = game.tick + 36000, trace = "sp3-vg.2" }
		S().waiting[car.unit_number] = { passenger = "ida", expires = game.tick + 36000, trace = "sp3-vg.3" }
		ctx.expect(players.seat("ida", ida) == true and car.get_passenger() == ida, "seated in the car still here")
		ctx.expect(S().waiting[car.unit_number] == nil, "its seat is taken")
		local seated = traced("seated")
		ctx.expect(seated and seated.trace == "sp3-vg.3" and seated.unit_number == car.unit_number,
			"the seated line carries the waiting seat's trace (M12)")
		S().waiting[un2] = nil -- left behind when the live seat came first in pairs(); nothing else reads it
	end)
end)

t.case("vehicles: a vehicle handler's fault is logged as ue.vehicle failed, not ue.player (M6)", function(ctx)
	ctx.at(3700, function()
		local stats = S().stats
		local function errors(op)
			return stats[op] and stats[op].errors or 0
		end
		local vehicle_before, player_before = errors("ue.vehicle"), errors("ue.player")
		-- A car-typed entity with no unit number: on_driving raises (rejected[nil]), inside its guard.
		ue_control.events[defines.events.on_player_driving_changed_state]({ entity = { valid = true, type = "car" } })
		ctx.expect(errors("ue.vehicle") == vehicle_before + 1, "counted under ue.vehicle")
		ctx.expect(errors("ue.player") == player_before, "not under ue.player")
	end)
	ctx.expect_ipc("universal_edges:out", "table index is nil") -- the guard's failed line went out
end)

t.case("vehicles: a failed \"v\" endpoint recovers when a record is applied, and a vehicle crosses again", function(ctx)
	ctx.at(1900, function()
		ground(9500, 2990, 9540, 3010)
		ground(9500, 1980, 9540, 2010)
		loop.edge("sp3-v6", L, {}, EDGE(9500))
		local v_ep = connectors.get(S().edges["sp3-v6-x"], "v")
		connectors.fail(v_ep, "test", "forced")
		ctx.expect(v_ep.state == "failed", "forced into failed")
		loop.connectors("sp3-v6", 2, {}) -- an applied record triggers lanes.reconcile, the same as a real update
		ctx.expect(v_ep.state == "pending" or v_ep.state == "ready", "reconcile revives the built-in endpoint")
	end)
	ctx.at(1930, function()
		local car = spawn("car", 9510, 2998, 0, 0.3) -- local (10, -2): past the line
		rider(car, "passenger")
	end)
	wait_for(ctx, 1931, function()
		return spawned("sp3-v6-y", "car") ~= nil
	end, "a vehicle crosses again once the endpoint recovered", function() end)
end)

t.case("vehicles: a body naming an item this server lacks is rejected, and the source keeps it (I1)", function(ctx)
	local car
	ctx.at(3650, function()
		ground(9600, 2990, 9640, 3010)
		ground(9600, 1980, 9640, 2010)
		loop.edge("sp3-v7", L, {}, EDGE(9600))
		corrupt_item["sp3-v7-y"] = true
		car = spawn("car", 9610, 2998, 0, 0.3) -- fuelled with coal (spawn()): the item corrupt_item renames
	end)
	-- N2: a fixed-tick check can't tell "still crossing" from "credited and the source destroyed" apart this early,
	-- and a fixed margin shrinks as later tasks add edges to the same walk. Sample every tick for a terminal fact
	-- instead: M8's own reject state (rejected, unfrozen) at the source.
	local resolved = false
	for k = 3652, 3840 do
		ctx.at(k, function()
			if resolved then
				return
			end
			if car.valid and S().rejected[car.unit_number] and not car.disabled_by_script then
				resolved = true
				ctx.expect(car.valid, "the source keeps its car: not destroyed")
				ctx.expect(spawned("sp3-v7-y", "car") == nil, "nothing was credited on the far side")
			elseif k == 3840 then
				ctx.expect(false, "no terminal reject state (rejected, unfrozen) by tick " .. k)
			end
		end)
	end
end)

t.case("vehicles: a raise during restore on credit is a reject, not a failed v endpoint; the source keeps its car " ..
	"(final review: vehicle refuse-on-raise, matching trains' H1)", function(ctx)
	local car
	ctx.at(1900, function()
		ground(9700, 2990, 9740, 3010)
		ground(9700, 1980, 9740, 2010)
		loop.edge("sp3-v8", L, {}, EDGE(9700))
		raise_restore["sp3-v8-y"] = true
		car = spawn("car", 9710, 2998, 0, 0.3) -- local (10, -2): past the line
	end)
	local resolved = false
	for k = 1902, 2090 do
		ctx.at(k, function()
			if resolved then
				return
			end
			if car.valid and S().rejected[car.unit_number] and not car.disabled_by_script then
				resolved = true
				ctx.expect(car.valid, "the source keeps its car: not destroyed")
				ctx.expect(spawned("sp3-v8-y", "car") == nil, "nothing was credited on the far side")
				local v_ep = connectors.get(S().edges["sp3-v8-y"], "v")
				ctx.expect(v_ep ~= nil and v_ep.state ~= "failed", "the destination's v endpoint stays live, not " ..
					"failed: " .. tostring(v_ep and v_ep.state))
			elseif k == 2090 then
				ctx.expect(false, "no terminal reject state (rejected, unfrozen) by tick " .. k)
			end
		end)
	end
end)

local FOLLOW_UP_X = 13000

--- A vehicle's settings as the crossing must keep them, read back from the entity (owner 2026-10-07).
local function view(v)
	local out = {}
	for _, key in ipairs({ "selected_gun_index", "driver_is_gunner", "allow_dispatching_robots",
		"enable_logistics_while_moving", "consumption_modifier", "effectivity_modifier", "friction_modifier",
		"torso_orientation", "destructible", "operable" }) do
		local ok, value = pcall(function() return v[key] end)
		if ok then
			out[key] = value -- false is a value: "ok and value or nil" would turn it into nil and hide a lost setting
		end
	end
	local ok, targeting = pcall(function() return v.vehicle_automatic_targeting_parameters end)
	out.targeting = ok and targeting and (tostring(targeting.auto_target_with_gunner) .. "/" ..
		tostring(targeting.auto_target_without_gunner)) or nil
	local points = v.get_logistic_point()
	for _, point in ipairs(type(points) == "table" and points.object_name == nil and points or { points or nil }) do
		if point.mode == defines.logistic_mode.requester then
			out.enabled, out.trash = point.enabled, point.trash_not_requested
		end
	end
	local secs = v.get_logistic_sections()
	if secs then
		out.sections = {}
		for _, sec in ipairs(secs.sections) do
			local f = sec.filters[1]
			out.sections[#out.sections + 1] = { group = sec.group, active = sec.active, multiplier = sec.multiplier,
				n = #sec.filters, name = f and f.value.name, min = f and f.min, max = f and f.max }
		end
	end
	return out
end

local function filter(name, min, max)
	return { value = { type = "item", name = name, quality = "normal", comparator = "=" }, min = min, max = max }
end

--- Every setting of v turned off its default.
local function dress(v)
	v.destructible, v.operable = false, false
	if v.type == "car" then
		v.consumption_modifier, v.effectivity_modifier, v.friction_modifier = 1.5, 0.75, 2
	end
	if v.name ~= "car" then
		v.selected_gun_index = 2
		v.driver_is_gunner = not v.driver_is_gunner
	end
	if v.type == "spider-vehicle" then
		v.vehicle_automatic_targeting_parameters = { auto_target_without_gunner = false, auto_target_with_gunner = false }
		v.torso_orientation = 0.3
		v.allow_dispatching_robots = not v.allow_dispatching_robots
		v.enable_logistics_while_moving = not v.enable_logistics_while_moving
		for _, point in ipairs(v.get_logistic_point()) do
			if point.mode == defines.logistic_mode.requester then
				point.enabled, point.trash_not_requested = false, true
			end
		end
	end
end

t.case("vehicles: a car, a tank and a spidertron cross exactly as they are: weapons, logistics, modifiers, flags; a " ..
	"section's group missing on the far side is created from the carried filters, one already there keeps its own",
	function(ctx)
		local list = { { "car", "car" }, { "tank", "tank" }, { "spider", "spidertron" }, { "known", "spidertron" } }
		local before = {}
		local scratch, shared
		ctx.at(1900, function()
			for i, e in ipairs(list) do
				local x = FOLLOW_UP_X + 100 * (i - 1)
				ground(x - 4, 2990, x + 40, 3010)
				ground(x - 4, 1980, x + 40, 2010)
				loop.edge("sp3-vs" .. e[1], L, {}, EDGE(x))
			end
		end)
		ctx.at(2530, function()
			for i, e in ipairs(list) do
				local v = spawn(e[2], FOLLOW_UP_X + 100 * (i - 1) + 10, 2998, 0, 0.3)
				dress(v)
				if e[2] == "spidertron" then
					local secs = v.get_logistic_sections()
					for j = secs.sections_count, 1, -1 do
						secs.remove_section(j)
					end
					local manual = secs.add_section()
					manual.filters = { filter("iron-plate", 10, 50), filter("copper-plate", 5) }
					manual.multiplier = 2
					local grouped = secs.add_section()
					grouped.group = e[1] == "spider" and "ue-test-new" or "ue-test-known"
					grouped.filters = { filter("coal", 7, 70) }
					grouped.active = false
					if e[1] == "known" then
						-- a section elsewhere holds the group's content, which the far side has and keeps
						scratch = game.surfaces.nauvis.create_entity({ name = "spidertron", position = { 13500, 3100 },
							force = "player" })
						shared = scratch.get_logistic_sections().add_section()
						shared.group = "ue-test-known"
						before_credit["sp3-vsknown-y"] = function()
							shared.filters = { filter("stone", 3, 30) }
						end
					else
						before_credit["sp3-vsspider-y"] = function()
							game.forces.player.delete_logistic_group("ue-test-new")
						end
					end
				end
				before[e[1]] = view(v)
			end
		end)
		wait_for(ctx, 2531, function()
			for _, e in ipairs(list) do
				if spawned("sp3-vs" .. e[1] .. "-y", e[2]) == nil then
					return false
				end
			end
			return true
		end, "all four crossed", function()
			for _, e in ipairs(list) do
				local got = view(spawned("sp3-vs" .. e[1] .. "-y", e[2]).v)
				local want = before[e[1]]
				for key, value in pairs(want) do
					if key ~= "sections" then
						local ok = got[key] == value or (type(value) == "number" and math.abs(got[key] - value) < 0.001)
						ctx.expect(ok, e[1] .. ": " .. key .. " crossed as " .. tostring(value) .. ", got " .. tostring(got[key]))
					end
				end
				if e[1] == "spider" then
					ctx.expect(#got.sections == 2, "spider: two sections: " .. #got.sections)
					for j, w in ipairs(want.sections) do
						local g = got.sections[j] or {}
						for key, value in pairs(w) do
							ctx.expect(g[key] == value, "spider: section " .. j .. " " .. key .. " crossed as " ..
								tostring(value) .. ", got " .. tostring(g[key]))
						end
					end
				elseif e[1] == "known" then
					local manual, grouped = got.sections[1] or {}, got.sections[2] or {}
					ctx.expect(manual.name == "iron-plate" and manual.multiplier == 2, "known: the manual section crossed")
					ctx.expect(grouped.group == "ue-test-known" and grouped.name == "stone" and grouped.max == 30,
						"known: the group's own filters win: " .. tostring(grouped.name))
					ctx.expect(grouped.active == false, "known: the section's own active crossed")
				end
			end
		end)
	end)

t.case("vehicles: a script-watched vehicle crosses with no player; the watch clears a rejected mark; a held " ..
	"vehicle's edge closing gives it back through restored (close)", function(ctx)
	local car, marked
	ctx.at(1900, function()
		ground(13400, 2990, 13440, 3010)
		ground(13400, 1980, 13440, 2010)
		ground(13500, 2990, 13540, 3010)
		ground(13500, 1980, 13540, 2010)
		loop.edge("sp3-vw", L, {}, EDGE(13400))
		loop.edge("sp3-vc", L, {}, EDGE(13500))
		busy_edge["sp3-vc-y"] = true
	end)
	ctx.at(2530, function()
		-- not through ue_rt.watch: the export other modules' Clusterio modules call
		car = game.surfaces.nauvis.create_entity({ name = "car", position = { 13410, 2998 }, force = "player" })
		car.get_fuel_inventory().insert({ name = "coal", count = 10 })
		car.speed = 0.3
		ue.vehicles.watch(car)
		ctx.expect(S().watch[car.unit_number] == car, "watched through the export")
		marked = game.surfaces.nauvis.create_entity({ name = "car", position = { 13310, 2998 }, force = "player" })
		S().rejected[marked.unit_number] = true
		ue.vehicles.watch(marked)
		ctx.expect(S().rejected[marked.unit_number] == nil, "a script watch clears the rejected mark")
		ctx.expect(S().watch[marked.unit_number] == marked, "the marked vehicle is on the watch")
		S().watch[marked.unit_number] = nil
		marked.destroy()
		spawn("car", 13510, 2998, 0, 0.3) -- held at sp3-vc, whose destination is busy
	end)
	wait_for(ctx, 2531, function()
		local ep_x = S().edges["sp3-vc-x"] and connectors.get(S().edges["sp3-vc-x"], "v")
		return spawned("sp3-vw-y", "car") ~= nil and not car.valid and ep_x ~= nil and ep_x.data.held ~= nil
			and ep_x.data.held.ab ~= nil
	end, "the watched car crossed and the other is held", function(k)
		ctx.at(k + 1, function()
			loop.connectors("sp3-vc", 2, {}, true)
		end)
		wait_for(ctx, k + 2, function()
			return (restored["sp3-vc-x"] or ""):find("close", 1, true) ~= nil
		end, "restored got close: " .. tostring(restored["sp3-vc-x"]), function() end)
	end)
end)
