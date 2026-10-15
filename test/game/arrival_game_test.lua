local t = require("modules/v2_test/testlib")
local loop = require("modules/v2_test/loopback")
local players = require("modules/universal_edges/transports/players")

-- Crossing arrival's guard (crossing-arrival spec §5.1): a player who left a tile starts no crossing until UE has placed
-- them after their next join. Own area: a loopback edge "ar-pl", side a's line y = 3500 (past is north), side b's line
-- y = 2500 (past is south, inside north), x 7300-7340; side a's (x, y) is side b's (x, y - 1000).

-- A hook with an outside (crossing-arrival spec §5.2), registered at load, in its own area x 2570-2590, y 2570-2580:
-- x below 2580 raises, from 2580 it answers a point with no box. The area lies inside gridworld's shared test tile
-- (x, y 2528-2592), whose own hook comes first and answers nil there, so this hook is reached.
players.zones({
	name = "ar-out",
	zone = function() end,
	place = function() end,
	outside = function(surface, x, y)
		if surface ~= "nauvis" or x < 2570 or x >= 2590 or y < 2570 or y >= 2580 then
			return nil
		end
		if x < 2580 then
			error("ar-out: an outside that raises")
		end
		return x, y
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

local seq = 0 -- message ids must differ from other files' (the bridge drops repeats)
local function deliver(msg_type, payload)
	seq = seq + 1
	ue_rt.inbox("universal_edges", helpers.table_to_json({ { id = "0000c4bd." .. seq, type = msg_type, payload = payload } }))
end

local function stand_in(x, y)
	return game.surfaces.nauvis.create_entity({ name = "character", position = { x, y }, force = "player" })
end

--- name left from 4.5 past side b's line, then rejoined with a stand-in body at the same place (no reply yet).
local function left_and_joined(ctx, name, x)
	local body = stand_in(x, 2504.5)
	ctx.expect(ue_rt.player_left(name, "nauvis", x, 2504.5) ~= nil, name .. " left from the zone")
	ue_rt.player_join(name, body.unit_number)
	return body
end

local function reply(name, x)
	deliver("ue.player.arrival", { player = name, entry = { key = "edge:ar-pl-y", surface = "nauvis", x = x, y = 3498.5,
		trace = "t-" .. name } })
end

t.case("arrival: a move before or after the join, before the reply, crosses nothing (crossing-arrival spec §1, §5.1)",
	function(ctx)
	ctx.at(2111, function()
		loop.ground(7300, 3490, 7340, 3510)
		loop.ground(7300, 2490, 7340, 2510)
		loop.edge("ar-pl", 32, {}, { 7300, 3500, 0 }, { 7332, 2500, 8 })
	end)
	-- wa: the move before the join; wb: after it. Each left from 4.5 past side b's line, then a 0.71 step out
	-- (live's 0.7109375, crossing a tile boundary), before any arrival reply.
	ctx.at(2120, function()
		local wa_body, wb_body = stand_in(7310.5, 2504.5), stand_in(7320.5, 2504.5)
		ctx.expect(ue_rt.player_left("wa", "nauvis", 7310.5, 2504.5) ~= nil, "wa left from the zone")
		ctx.expect(ue_rt.player_left("wb", "nauvis", 7320.5, 2504.5) ~= nil, "wb left from the zone")
		local before = #queued("ue.player.cross")
		ctx.expect(ue_rt.player_move("wa", "nauvis", 7310.5, 2505.21) == nil, "wa: a move before the join crosses nothing")
		ue_rt.player_join("wa", wa_body.unit_number)
		ue_rt.player_join("wb", wb_body.unit_number)
		ctx.expect(ue_rt.player_move("wb", "nauvis", 7320.5, 2505.21) == nil, "wb: a move after the join, before the reply, crosses nothing")
		ctx.expect(#queued("ue.player.cross") == before, "no ue.player.cross sent")
	end)
end)

t.case("arrival: placement ends the guard (§5.1)", function(ctx)
	local body
	ctx.at(2122, function()
		body = left_and_joined(ctx, "wc", 7312.5)
		reply("wc", 7312.5)
	end)
	ctx.at(2124, function()
		ctx.expect(body.position.y <= 2499.5, "wc: placed inside side b")
		ctx.expect(not players.arriving("wc"), "wc: the guard is off")
		local before = #queued("ue.player.cross")
		ctx.expect(ue_rt.player_move("wc", "nauvis", 7312.5, 2501.5) ~= nil, "wc: a move 1.5 past the line crosses")
		local sent = queued("ue.player.cross")
		ctx.expect(#sent == before + 1 and sent[#sent].keys[1] == "edge:ar-pl-y", "a cross for edge:ar-pl-y")
	end)
end)

t.case("arrival: a joined player's guard runs out; a late reply restarts it from the reply (§5.1)", function(ctx)
	ctx.at(2126, function()
		left_and_joined(ctx, "wd", 7314.5)
		ctx.expect(players.arriving("wd"), "wd: arriving after the join")
		ctx.expect(ue_rt.player_move("wd", "nauvis", 7314.5, 2505.21) == nil, "wd: no crossing while it stands")
		storage.universal_edges.players.arriving.wd = game.tick - 1 -- as 3601 ticks without a reply
		ctx.expect(ue_rt.player_move("wd", "nauvis", 7314.5, 2505.21) ~= nil, "wd: the guard ran out, the move crosses")
		left_and_joined(ctx, "we", 7316.5)
		local tick = game.tick
		reply("we", 7316.5)
		ctx.expect(storage.universal_edges.players.arriving.we == tick + players.PLACING, "we: one clock, reply tick + PLACING")
	end)
end)

t.case("arrival: leaving while arriving sends nothing; leaving after placement does (§5.1)", function(ctx)
	local body
	ctx.at(2128, function()
		left_and_joined(ctx, "wf", 7318.5)
		local n = #queued("ue.player.left")
		ctx.expect(ue_rt.player_left("wf", "nauvis", 7318.5, 2504.5) == nil, "wf: leaving while arriving")
		ctx.expect(#queued("ue.player.left") == n, "no ue.player.left sent")
		body = left_and_joined(ctx, "wg", 7322.5)
		reply("wg", 7322.5)
	end)
	ctx.at(2132, function()
		ctx.expect(not players.arriving("wg"), "wg: placed")
		ue_rt.player_move("wg", "nauvis", 7322.5, 2501.5)
		local n = #queued("ue.player.left")
		ctx.expect(ue_rt.player_left("wg", "nauvis", 7322.5, 2501.5) ~= nil, "wg: leaving in the zone")
		local sent = queued("ue.player.left")
		ctx.expect(#sent == n + 1 and sent[#sent].player == "wg" and sent[#sent].y == 2501.5, "one ue.player.left, at that point")
		ctx.expect(body.valid, "stand-in kept")
	end)
end)

t.case("arrival: a server start leaves every player away (spec ruling 7)", function(ctx)
	ctx.at(2134, function()
		players.away_all({ "st" })
		local before = #queued("ue.player.cross")
		ctx.expect(ue_rt.player_move("st", "nauvis", 7324.5, 2505.21) == nil, "st: a move crosses nothing")
		ctx.expect(#queued("ue.player.cross") == before, "no ue.player.cross sent")
	end)
end)

t.case("arrival: a first-time player (never left) is not guarded; a move into a zone crosses (spec §5.1)", function(ctx)
	ctx.at(2137, function()
		local body = stand_in(7330.5, 2504.5)
		ue_rt.player_join("ft", body.unit_number)
		ctx.expect(not players.arriving("ft"), "ft: never left, no guard")
		ctx.expect(ue_rt.player_move("ft", "nauvis", 7330.5, 2501.5) ~= nil, "ft: a move into the zone crosses")
	end)
end)

t.case("arrival: a respawn ends the guard, and a move into a zone then crosses (spec §5.1 End)", function(ctx)
	ctx.at(2136, function()
		players.away_all({ "rs" })
		ctx.expect(players.arriving("rs"), "rs: arriving")
		ctx.expect(ue_rt.player_move("rs", "nauvis", 7326.5, 2505.21) == nil, "rs: no crossing while it stands")
		players.respawned("rs")
		ctx.expect(not players.arriving("rs"), "rs: respawned, the guard is gone")
		ctx.expect(ue_rt.player_move("rs", "nauvis", 7326.5, 2501.5) ~= nil, "rs: a move into the zone now crosses")
	end)
end)

t.case("arrival: an outside that raises or answers without a box counts as none, and the raise is logged (spec §5.2)",
	function(ctx)
	ctx.at(2140, function()
		local function failures()
			local n = 0
			for _, p in ipairs(queued("trace")) do
				n = n + ((p.phase == "hook_failed" and p.fn == "outside") and 1 or 0)
			end
			return n
		end
		local before = failures()
		ctx.expect(players.outside("nauvis", 2575, 2575) == nil, "a raising outside: none")
		ctx.expect(players.outside("nauvis", 2585, 2575) == nil, "a point with no box: none")
		ctx.expect(players.outside("nauvis", 2565, 2575) == nil, "outside the hook's area: none")
		ctx.expect(failures() == before + 1, "one hook_failed naming outside")
	end)
end)
