local t = require("modules/v2_test/testlib")
local loop = require("modules/v2_test/loopback")
local players = require("modules/universal_edges/transports/players")

-- A zone hook of this file's own (crossing spec §7.1), in an area no other file uses: north of y = 3000 for x 7100-7130
-- is its zone "sp3-zone:a" (entered 0.5 past y = 3000, held to 0); x 7130-7140 raises. Registered at load, as any hook
-- must be. Its place clamps to 0.5 south of the line, with a small box, and refuses points north of y = 2970; for
-- y 2985-2990 it returns a point with no box, a bad result that must count as none (§7.1).
players.zones({
	name = "sp3-zone",
	zone = function(surface, x, y, current)
		if surface ~= "nauvis" or x < 7100 or x >= 7140 or y < 2980 or y >= 3000 then
			return nil
		end
		if x >= 7130 then
			error("sp3-zone: a hook that raises")
		end
		if y < 2999.5 or current == "sp3-zone:a" then
			return "sp3-zone:a"
		end
	end,
	place = function(_, _, x, y)
		if y < 2970 then
			return nil
		end
		if y >= 2985 and y < 2990 then
			return x, 3000.5
		end
		local py = math.max(y, 3000.5)
		return x, py, { { x - 2, py }, { x + 2, py + 4 } }
	end,
})

local function queued(msg_type)
	local found = {}
	for _, msg in ipairs(storage.universal_edges.bridge.out.universal_edges or {}) do
		if msg.type == msg_type then
			found[#found + 1] = msg.payload
		end
	end
	return found
end

local seq = 0
local function deliver(msg_type, payload)
	seq = seq + 1
	ue_rt.inbox("universal_edges", helpers.table_to_json({ { id = "0000c4b9." .. seq, type = msg_type, payload = payload } }))
end

local function traced(phase)
	local found = {}
	for _, p in ipairs(queued("trace")) do
		if p.phase == phase then
			found[#found + 1] = p
		end
	end
	return found
end

local function stand_in(x, y)
	return game.surfaces.nauvis.create_entity({ name = "character", position = { x, y }, force = "player" })
end

t.case("players: a move past the line crosses once with the edge's key and position; a none retries after 300 ticks " ..
	"(crossing spec §3.1, §4)", function(ctx)
	local id
	ctx.at(1500, function()
		loop.ground(7000, 2990, 7040, 3010)
		loop.ground(7000, 1990, 7040, 2010)
		loop.edge("sp3-pl", 32, {}, { 7000, 3000, 0 }, { 7032, 2000, 8 })
	end)
	ctx.at(1520, function()
		ctx.expect(ue_rt.player_move("ann", "nauvis", 7010.5, 2999.6) == nil, "0.4 past the line: no zone")
		id = ue_rt.player_move("ann", "nauvis", 7010.5, 2999.4)
		local all = queued("ue.player.cross")
		local c = all[#all]
		ctx.expect(id ~= nil and c and c.player == "ann" and c.keys[1] == "edge:sp3-pl-x" and c.keys[2] == nil
			and c.trace == id and c.surface == "nauvis" and math.abs(c.y - 2999.4) < 1e-9, "one cross: key, place, surface")
		ctx.expect(ue_rt.player_move("ann", "nauvis", 7011, 2998) == id, "still in the zone: the same crossing")
		ctx.expect(#queued("ue.player.cross") == #all, "nothing new sent")
		deliver("ue.player.none", { player = "ann", reason = "not_running", trace = id })
	end)
	ctx.at(1700, function()
		ctx.expect(ue_rt.player_move("ann", "nauvis", 7011, 2998) == id, "answered none: no retry before 300 ticks")
	end)
	ctx.at(1821, function()
		local again = ue_rt.player_move("ann", "nauvis", 7011, 2998)
		ctx.expect(again ~= nil and again ~= id, "retried after 300 ticks, under a new trace")
	end)
	ctx.expect_ipc("universal_edges:out", '"phase":"crossed"')
end)

t.case("players: the 0.5 band keeps a crossing; back inside clears it; a later prompt for it is stale", function(ctx)
	ctx.at(1530, function()
		local id = ue_rt.player_move("bea", "nauvis", 7012.5, 2999.0)
		ctx.expect(id ~= nil, "crossed")
		ctx.expect(ue_rt.player_move("bea", "nauvis", 7012.5, 2999.8) == id, "0.2 past: held")
		ctx.expect(ue_rt.player_move("bea", "nauvis", 7012.5, 3000.2) == nil, "back inside: cleared")
		deliver("ue.player.prompt", { player = "bea", address = "h:1", name = "b", trace = id })
		local skipped = traced("prompt_skipped")
		local last = skipped[#skipped]
		ctx.expect(last and last.trace == id and last.reason == "stale", "the prompt is stale")
	end)
end)

t.case("players: a leave in a zone sends the leave point; a leave from inside sends nothing (§4 step 5)", function(ctx)
	ctx.at(1540, function()
		local id = ue_rt.player_move("cal", "nauvis", 7014.5, 2998.5)
		ctx.expect(ue_rt.player_left("cal", "nauvis", 7015.5, 2997.0) == id, "left under the crossing's trace")
		local left = queued("ue.player.left")
		local l = left[#left]
		ctx.expect(l and l.player == "cal" and l.x == 7015.5 and l.y == 2997.0 and l.surface == "nauvis", "the leave point")
		local n = #queued("ue.player.left")
		ue_rt.player_move("dee", "nauvis", 7016.5, 2998.5)
		ctx.expect(ue_rt.player_left("dee", "nauvis", 7016.5, 3004) == nil, "from inside: nothing")
		ctx.expect(#queued("ue.player.left") == n, "no leave sent")
		ctx.expect(storage.universal_edges.players.pending.dee == nil, "and the crossing is gone")
	end)
end)

t.case("players: the leave point within reach places them there; one out of reach, or none, gives the crossing point " ..
	"(§6.2)", function(ctx)
	local eli, fay, gil
	ctx.at(1560, function()
		eli, fay, gil = stand_in(7035, 1995), stand_in(7036, 1995), stand_in(7037, 1995)
		ue_rt.player_join("eli", eli.unit_number)
		ue_rt.player_join("fay", fay.unit_number)
		ue_rt.player_join("gil", gil.unit_number)
		ctx.expect(#queued("ue.player.joined") >= 3, "each join asks the controller")
		local crossed = { key = "edge:sp3-pl-y", surface = "nauvis", x = 7012.5, y = 2998.5 }
		deliver("ue.player.arrival", { player = "eli", entry = { key = crossed.key, surface = "nauvis", x = 7012.5,
			y = 2998.5, trace = "t-eli", left = { x = 7020.5, y = 2997.0, surface = "nauvis" } } })
		deliver("ue.player.arrival", { player = "fay", entry = { key = crossed.key, surface = "nauvis", x = 7012.5,
			y = 2998.5, trace = "t-fay", left = { x = 6950, y = 2998, surface = "nauvis" } } })
		deliver("ue.player.arrival", { player = "gil", entry = { key = crossed.key, surface = "nauvis", x = 7012.5,
			y = 2998.5, trace = "t-gil" } })
	end)
	ctx.at(1562, function()
		-- side a's (x, y) is side b's (x, y - 1000); side b's inside is north of y = 2000
		local function near(e, x, y)
			return math.abs(e.position.x - x) <= 8 and math.abs(e.position.y - y) <= 8 and e.position.y <= 1999.5
		end
		ctx.expect(near(eli, 7020.5, 1997.0), "eli: at the leave point, inside")
		ctx.expect(near(fay, 7012.5, 1998.5) and fay.position.x > 7000, "fay: the leave point is 50 beyond the edge's end, so the crossing point")
		ctx.expect(near(gil, 7012.5, 1998.5), "gil: no leave point (a late accept), the crossing point")
	end)
	ctx.expect_ipc("universal_edges:out", '"phase":"arrived"')
	ctx.expect_ipc("universal_edges:out", '"phase":"arrival_fetched"')
end)

t.case("players: no arrival and an old body past a line: pulled to the nearest point inside (§6.3)", function(ctx)
	local hal
	ctx.at(1580, function()
		hal = stand_in(7020, 2003) -- side b's world: 3 past its line, which is y = 2000, inside north
		ue_rt.player_join("hal", hal.unit_number)
		deliver("ue.player.arrival", { player = "hal" })
	end)
	ctx.at(1582, function()
		ctx.expect(hal.position.y <= 1999.5 and math.abs(hal.position.x - 7020) <= 8, "pulled inside")
	end)
	ctx.expect_ipc("universal_edges:out", '"phase":"pulled_in"')
end)

t.case("players: placed again only when the character comes back from spectator or god (§6.1)", function(ctx)
	local ivy
	ctx.at(1600, function()
		ivy = stand_in(7038, 1995)
		ue_rt.player_join("ivy", ivy.unit_number)
		deliver("ue.player.arrival", { player = "ivy", entry = { key = "edge:sp3-pl-y", surface = "nauvis", x = 7010.5,
			y = 2998.5, trace = "t-ivy" } })
	end)
	ctx.at(1602, function()
		ctx.expect(math.abs(ivy.position.x - 7010.5) <= 8, "placed")
		ivy.teleport({ 7038, 1995 })
		ue_rt.player_body("ivy", defines.controllers.ghost) -- a death and respawn
		ue_rt.player_body("ivy", defines.controllers.editor)
	end)
	ctx.at(1605, function()
		ctx.expect(ivy.position.x == 7038, "a respawn or the editor never moves them back")
		ue_rt.player_body("ivy", defines.controllers.spectator) -- inventory_sync handing the character back
	end)
	ctx.at(1607, function()
		ctx.expect(math.abs(ivy.position.x - 7010.5) <= 8, "spectator → character: placed again")
		storage.universal_edges.players.placing.ivy.expires = game.tick - 1
		ivy.teleport({ 7038, 1995 })
		ue_rt.player_body("ivy", defines.controllers.spectator)
	end)
	ctx.at(1609, function()
		ctx.expect(ivy.position.x == 7038, "expired: not placed again")
	end)
end)

t.case("players: a hook claims its zone first and the edge rides as the fallback, on a retry too; a raising hook is " ..
	"logged once and ignored; a hook's key is placed by the hook, and a point with no box counts as none (§3.1, §4, §7.1)",
	function(ctx)
	local jo, pat, kim
	ctx.at(1620, function()
		loop.ground(7100, 2980, 7140, 3010)
		loop.ground(7100, 1990, 7140, 2010)
		loop.edge("sp3-pz", 32, {}, { 7100, 3000, 0 }, { 7132, 2000, 8 })
	end)
	ctx.at(1640, function()
		kim = ue_rt.player_move("kim", "nauvis", 7105, 2999)
		local all = queued("ue.player.cross")
		local c = all[#all]
		ctx.expect(c and c.player == "kim" and c.keys[1] == "sp3-zone:a" and c.keys[2] == "edge:sp3-pz-x",
			"the hook's key, then the edge's")
		ctx.expect(ue_rt.player_move("kim", "nauvis", 7105, 2999.8) ~= nil, "held by the hook's own stay rule")
		deliver("ue.player.none", { player = "kim", reason = "no_instance", trace = kim })
		local before = #traced("hook_failed")
		ue_rt.player_move("lee", "nauvis", 7135, 2999)
		ue_rt.player_move("lee", "nauvis", 7135.5, 2999)
		ctx.expect(#traced("hook_failed") == before + 1, "logged once in its window")
		ctx.expect(storage.universal_edges.players.pending.lee == nil, "treated as no zone (beyond the edge's end too)")
		jo = stand_in(7120, 3008)
		ue_rt.player_join("jo", jo.unit_number)
		deliver("ue.player.arrival", { player = "jo", entry = { key = "sp3-zone:a", surface = "nauvis", x = 7106,
			y = 2995, trace = "t-jo" } })
		pat = stand_in(7120, 2999) -- in the hook's zone, so with no placement it is pulled in
		ue_rt.player_join("pat", pat.unit_number)
		deliver("ue.player.arrival", { player = "pat", entry = { key = "sp3-zone:a", surface = "nauvis", x = 7106,
			y = 2987, trace = "t-pat" } })
	end)
	ctx.at(1642, function()
		ctx.expect(jo.position.x >= 7104 and jo.position.x <= 7108 and jo.position.y >= 3000.5, "placed by the hook")
		ctx.expect(pat.position.y >= 3000.5 and math.abs(pat.position.x - 7120) <= 2,
			"a point with no box is no placement: pulled in instead, no raise")
	end)
	ctx.at(1941, function()
		local again = ue_rt.player_move("kim", "nauvis", 7105, 2999)
		local all = queued("ue.player.cross")
		local c = all[#all]
		ctx.expect(again ~= nil and again ~= kim and c and c.trace == again and c.keys[1] == "sp3-zone:a"
			and c.keys[2] == "edge:sp3-pz-x", "answered none: the retry still offers the edge as the fallback (§4 step 4)")
	end)
	ctx.expect_ipc("universal_edges:out", '"phase":"hook_failed"')
	ctx.expect_ipc("universal_edges:out", '"reason":"no_zone"')
end)

t.case("players: a held rider crossing ignores moves until it is answered, or until RETRY ticks pass unanswered " ..
	"(§4 step 4, §7.3)", function(ctx)
	ctx.at(1680, function()
		local id = players.cross("max", "edge:sp3-pl-x", nil, "nauvis", 7020.5, 2998.5, nil, true)
		players.cross("ned", "edge:sp3-pl-x", nil, "nauvis", 7022.5, 2998.5, nil, true)
		ctx.expect(ue_rt.player_move("max", "nauvis", 7020.5, 3004) == id, "inside, unanswered: held")
		deliver("ue.player.none", { player = "max", reason = "not_running", trace = id })
		ctx.expect(ue_rt.player_move("max", "nauvis", 7020.5, 3004) == nil, "answered: a move inside lets it go")
	end)
	ctx.at(1681, function()
		ctx.expect(ue_rt.player_move("ned", "nauvis", 7022.5, 3004) ~= nil, "inside, unanswered: still held")
	end)
	ctx.at(1981, function()
		ctx.expect(ue_rt.player_move("ned", "nauvis", 7022.5, 3004) == nil,
			"unanswered past RETRY ticks: the normal rules, so inside clears it")
	end)
end)

-- off_body gates every controller but the character (fix round 2, playtest 2 #6c). No connected player exists in a game
-- test, so on_moved can't be driven end to end; off_body takes anything with a controller_type field.
t.case("players: off_body gates every controller but the character (§3.1)", function(ctx)
	ctx.at(1660, function()
		for _, name in ipairs({ "remote", "spectator", "god", "ghost", "editor" }) do
			ctx.expect(players.off_body({ controller_type = defines.controllers[name] }) == true, name .. " gates")
		end
		ctx.expect(players.off_body({ controller_type = defines.controllers.character }) == false, "a character doesn't")
	end)
end)
