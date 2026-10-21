local t = require("modules/v2_test/testlib")
local bridge = require("modules/universal_edges/runtime/bridge")
local geometry = require("modules/universal_edges/edges/geometry_core")
local core = require("modules/universal_edges/transports/train_core")
local seams = require("modules/universal_edges/transports/train_seams")
local loop = require("modules/v2_test/loopback")
local connectors = require("modules/universal_edges/edges/connectors")
local detect = require("modules/universal_edges/transports/detect")

-- Train box direction (spec 2026-10-15): a border rail builds a generic box, and the first signal up the line decides
-- its direction. The lab surface "tbd": seams edges "tbd-<case>" (side a at (0, y) facing north, so local (x, ly) is
-- world (x, y + ly); side b scripted) in rows 1000 to 5400, 400 apart; looped pairs at x 200, 300 and 400, y 12000.
-- Columns 10 apart in a row. Ticks 300-352.
local S = "tbd"

--- The lab surface S, made on first use as seams.edge makes it.
local function surface()
	local s = game.get_surface(S)
	if not s then
		s = game.create_surface(S)
		s.generate_with_lab_tiles, s.always_day = true, true
	end
	return s
end

--- Side a's frame of the seams edge at row y.
local function row(y)
	return { origin = { 0, y }, facing = 0, length = 64 }
end

--- Every ue.connector.propose this file's edges sent, by edge, in order. The bridge empties its queue at each tick's
--- flush, and a proposal made in a step may only go at the next tick's: read sent from a later step.
local sent = {}
local flush = bridge.flush
function bridge.flush(tick)
	for _, m in ipairs(storage.universal_edges.bridge.out.universal_edges or {}) do
		if m.type == "ue.connector.propose" and string.sub(m.payload.edge, 1, 4) == "tbd-" then
			sent[m.payload.edge] = sent[m.payload.edge] or {}
			table.insert(sent[m.payload.edge], m.payload)
		end
	end
	flush(tick)
end

--- edge's proposals so far, by pos (on side a, pos is the column).
local function by_pos(edge)
	local out = {}
	for _, p in ipairs(sent[edge] or {}) do
		out[p.pos] = p
	end
	return out
end

--- name at frame f's local (x, ly), facing local direction d (0, across the edge, by default); raised when raise.
local function put(f, name, x, ly, raise, d)
	local wx, wy = geometry.to_world(f, x, ly)
	return surface().create_entity{ name = name, position = { wx, wy }, force = "player",
		direction = geometry.dir_to_world(f, d or 0), raise_built = raise }
end

local function rail_name(layer)
	return layer == "elevated" and "elevated-straight-rail" or "straight-rail"
end

--- The player's track at column x: rails of layer at local y 3 to `to` (21), not raised (inside the border row they
--- propose nothing anyway). Returns them by local y.
local function track(f, x, layer, to)
	local rails = {}
	for ly = 3, to or 21, 2 do
		rails[ly] = assert(put(f, rail_name(layer), x, ly), rail_name(layer) .. " at " .. x .. "," .. ly)
	end
	return rails
end

--- A rail or chain signal at rail's end at local y ey (spike 35's probe): "out" for trains leaving the rail there, so
--- toward the border (heading out); "in" for trains entering it (coming in). With ghost, its ghost instead.
local function signal(f, rail, ey, which, name, ghost)
	for _, dir in pairs(defines.rail_direction) do
		local re = rail.get_rail_end(dir)
		local _, ly = geometry.to_local(f, re.location.position.x, re.location.position.y)
		if math.abs(ly - ey) < 0.01 then
			local spot = which == "in" and re.in_signal_location or re.out_signal_location
			local p = { name = name or "rail-signal", position = spot.position, direction = spot.direction,
				rail_layer = spot.rail_layer, force = "player", raise_built = true }
			if ghost then
				p.name, p.inner_name, p.raise_built = "entity-ghost", name or "rail-signal", nil
			end
			return assert(surface().create_entity(p), "signal at " .. ey)
		end
	end
	error("no end of that rail at local y " .. ey)
end

--- The border rail at column x (its centre at local y 1), raised as a player's or a robot's build is.
local function border(f, x, layer)
	return assert(put(f, rail_name(layer), x, 1, true), "border rail at " .. x)
end

--- edge's generic record for the rail at local x.
local function generic(edge, x)
	return (storage.universal_edges.generic or {})[edge .. ":" .. (x - core.WIDTH / 2)]
end

--- How many name entities stand within 2 tiles of local x, from local y y1 to y2.
local function count(f, name, x, y1, y2)
	local x1, wy1, x2, wy2 = geometry.area_to_world(f, x - 2, y1, x + 2, y2)
	return surface().count_entities_filtered{ area = { { x1, wy1 }, { x2, wy2 } }, name = name }
end

--- The name entity centred at local (x, ly), or nil.
local function at(f, name, x, ly)
	return surface().find_entity(name, { geometry.to_world(f, x, ly) })
end

-- Task 2: decided at the build -----------------------------------------------------------------------------------------

t.case("trains direction: a bare border rail builds a generic box, the outbound box's 20 rails (and 3 supports when " ..
	"elevated), no signals, nothing proposed; nothing more at overlapping columns; a rail rebuilt before the poll gets " ..
	"the box (spec §4)", function(ctx)
	local id, f = "tbd-bare", row(1000)
	ctx.at(300, function()
		seams.edge(id, 1000, {}, { surface = S })
	end)
	ctx.at(302, function()
		border(f, 9)
		border(f, 19, "elevated")
		border(f, 11) -- columns 9..12, overlapping 9's 7..10
		border(f, 39).destroy() -- mined with no event: its record stays until a poll would see it
		border(f, 39)
	end)
	ctx.at(304, function()
		for _, k in ipairs({ { x = 9, layer = "ground", n = 0 }, { x = 19, layer = "elevated", n = 3 } }) do
			local g = generic(id, k.x)
			ctx.expect(g ~= nil and g.layer == k.layer and g.width == 4 and g.trace == nil, k.x .. ": a generic record")
			if g then
				ctx.expect(#g.rails == core.OUT_RAILS, k.x .. ": 20 rails: " .. #g.rails)
				for i, r in ipairs(g.rails) do
					local rx, ry = geometry.to_local(f, r.position.x, r.position.y)
					ctx.expect(r.name == rail_name(k.layer) and rx == k.x and ry == core.rail_y(i),
						k.x .. ": rail " .. i .. " at " .. rx .. "," .. ry)
					ctx.expect(not r.minable_flag and not r.destructible, k.x .. ": rail " .. i .. " can't be mined or destroyed")
				end
				ctx.expect(#g.supports == k.n and count(f, "rail-support", k.x, -42, 0) == k.n, k.x .. ": supports " .. #g.supports)
			end
			ctx.expect(count(f, "rail-signal", k.x, -42, 2) + count(f, "ue-rail-signal", k.x, -42, 2) == 0, k.x .. ": no signals")
		end
		ctx.expect(generic(id, 11) == nil and at(f, "straight-rail", 11, -1) == nil, "11: nothing over 9's generic box")
		local g = generic(id, 39)
		ctx.expect(g ~= nil and g.border.valid and g.rails[1].valid, "39: the rebuilt rail has the box (Review Focus 1)")
		ctx.expect(sent[id] == nil, "nothing proposed: " .. #(sent[id] or {}))
	end)
end)

t.case("trains direction: a signal already up the line decides at the build: heading out, this side sends; coming in, " ..
	"the neighbour; a chain signal and one at the border rail's inner end count; both ways, nothing (spec §3)", function(ctx)
	local id, f = "tbd-sig", row(1400)
	ctx.at(300, function()
		seams.edge(id, 1400, {}, { surface = S })
	end)
	ctx.at(302, function()
		local a = track(f, 9)
		signal(f, a[11], 10, "out")
		border(f, 9)
		local b = track(f, 19)
		signal(f, b[11], 10, "in")
		border(f, 19)
		local c = track(f, 29)
		signal(f, c[11], 10, "out", "rail-chain-signal")
		border(f, 29)
		local d = track(f, 39)
		signal(f, d[3], 2, "in") -- the border rail's own inner end (spike 35 case G)
		border(f, 39)
		local e = track(f, 49)
		signal(f, e[11], 10, "in")
		signal(f, e[11], 10, "out")
		border(f, 49)
	end)
	ctx.at(304, function()
		local got = by_pos(id)
		for _, k in ipairs({ { 9, "ab" }, { 19, "ba" }, { 29, "ab" }, { 39, "ba" } }) do
			local p, g = got[k[1] - 2], generic(id, k[1])
			ctx.expect(p ~= nil and p.type == "train" and p.width == 4 and p.params.dir == k[2] and p.params.layer == "ground",
				k[1] .. ": proposed " .. k[2] .. ": " .. serpent.line(p))
			ctx.expect(g ~= nil and p ~= nil and g.trace == p.trace, k[1] .. ": the record holds the proposal's trace")
		end
		local both = generic(id, 49)
		ctx.expect(got[47] == nil and both ~= nil and both.trace == nil, "49, both ways: generic, nothing proposed")
		ctx.expect(#(sent[id] or {}) == 4, "one proposal each: " .. #(sent[id] or {}))
	end)
end)

t.case("trains direction: elevated rails and signals decide the same way (spec §9; [api], untried by spike 35)", function(ctx)
	local id, f = "tbd-el", row(1800)
	ctx.at(300, function()
		seams.edge(id, 1800, {}, { surface = S })
	end)
	ctx.at(302, function()
		local a = track(f, 9, "elevated")
		signal(f, a[11], 10, "out")
		border(f, 9, "elevated")
		local b = track(f, 29, "elevated")
		signal(f, b[11], 10, "in")
		border(f, 29, "elevated")
	end)
	ctx.at(304, function()
		local got = by_pos(id)
		ctx.expect(got[7] ~= nil and got[7].params.dir == "ab" and got[7].params.layer == "elevated",
			"heading out: " .. serpent.line(got[7]))
		ctx.expect(got[27] ~= nil and got[27].params.dir == "ba" and got[27].params.layer == "elevated",
			"coming in: " .. serpent.line(got[27]))
	end)
end)

-- trains_spawn_game_test.lua's LOOP (the owner's loop, :590-594): a U-turn from the rail at local x 43 to the one at 17.
-- Rail type, x from 43, local y, local direction.
local LOOP = {
	{ "curved-rail-a", 0, 22, 10 }, { "curved-rail-b", -2, 27, 10 }, { "curved-rail-b", -6, 31, 4 },
	{ "curved-rail-a", -11, 33, 4 }, { "curved-rail-a", -15, 33, 14 }, { "curved-rail-b", -20, 31, 14 },
	{ "curved-rail-b", -24, 27, 8 }, { "curved-rail-a", -26, 22, 8 },
}

t.case("trains direction: a junction to another link's border rail, no signal between, takes the opposite direction: " ..
	"an outbound link's box signal makes it inbound, an inbound link's exit signal outbound (spec §3)", function(ctx)
	local rows = { { id = "tbd-jo", y = 2200, dir = "ab", want = "ba" }, { id = "tbd-ji", y = 2600, dir = "ba", want = "ab" } }
	ctx.at(300, function()
		for _, k in ipairs(rows) do
			seams.edge(k.id, k.y, { { cid = "t1", type = "train", pos = 40, width = 6, params = { dir = k.dir, layer = "ground" } } },
				{ surface = S })
		end
	end)
	ctx.at(350, function()
		for _, k in ipairs(rows) do
			local f = row(k.y)
			ctx.expect(seams.endpoint(k.id, "t1").state == "ready", k.id .. ": the other link built")
			seams.generate(surface(), f, 0, core.rail_y(core.IN_RAILS) - 8, 64, 100)
			for ly = 1, 91, 2 do
				ctx.expect(put(f, "straight-rail", 43, ly) ~= nil, k.id .. ": the other link's track at " .. ly)
				if ly > 1 then
					ctx.expect(put(f, "straight-rail", 17, ly) ~= nil, k.id .. ": this track at " .. ly)
				end
			end
			for _, r in ipairs(LOOP) do
				ctx.expect(put(f, r[1], 43 + r[2], r[3], false, r[4]) ~= nil, k.id .. ": " .. r[1] .. " at " .. r[2] .. "," .. r[3])
			end
			border(f, 17)
		end
	end)
	ctx.at(352, function()
		for _, k in ipairs(rows) do
			local p = by_pos(k.id)[15]
			ctx.expect(p ~= nil and p.params.dir == k.want, k.id .. ": " .. k.want .. ", the other way to t1's " .. k.dir .. ": "
				.. serpent.line(p))
		end
	end)
end)

t.case("trains direction: a generic box that can't be placed leaves nothing and proposes nothing (spec §4)", function(ctx)
	local id, f = "tbd-blk", row(3000)
	ctx.at(300, function()
		seams.edge(id, 3000, {}, { surface = S })
	end)
	ctx.at(302, function()
		ctx.expect(put(f, "straight-rail", 9, core.rail_y(10), false, 4) ~= nil, "a rail along the edge where rail 10 goes")
		local a = track(f, 9)
		signal(f, a[11], 10, "out")
		border(f, 9)
	end)
	ctx.at(304, function()
		ctx.expect(generic(id, 9) == nil, "no record")
		for i = 1, 9 do
			ctx.expect(at(f, "straight-rail", 9, core.rail_y(i)) == nil, "rail " .. i .. " undone")
		end
		local across = at(f, "straight-rail", 9, core.rail_y(10))
		ctx.expect(across ~= nil and across.minable_flag, "the rail in the way is left as it was")
		ctx.expect(sent[id] == nil, "nothing proposed")
	end)
end)

t.case("trains direction: a blocked generic box leaves the player's own rail where it stands, as it was (spec §4)", function(ctx)
	local id, f = "tbd-adopt", row(5400)
	ctx.at(300, function()
		seams.edge(id, 5400, {}, { surface = S })
	end)
	ctx.at(302, function()
		ctx.expect(put(f, "straight-rail", 9, core.rail_y(3), false) ~= nil, "a player rail where rail 3 goes")
		ctx.expect(put(f, "straight-rail", 9, core.rail_y(10), false, 4) ~= nil, "a rail along the edge where rail 10 goes")
		local a = track(f, 9)
		signal(f, a[11], 10, "out")
		border(f, 9)
	end)
	ctx.at(304, function()
		ctx.expect(generic(id, 9) == nil, "no record")
		ctx.expect(at(f, "straight-rail", 9, core.rail_y(2)) == nil, "rail 2 undone")
		local mine = at(f, "straight-rail", 9, core.rail_y(3))
		ctx.expect(mine ~= nil and mine.minable_flag and mine.destructible, "the player's rail 3 is left minable and destructible")
		ctx.expect(sent[id] == nil, "nothing proposed")
	end)
end)

-- Task 3: the endpoint takes over; refusals ----------------------------------------------------------------------------

t.case("trains direction: the endpoint takes the generic box over: outbound and inbound keep its rails; inbound drops " ..
	"the support moved off the combinator; the record goes; a late refusal leaves the box (spec §6.2)", function(ctx)
	local out, inn = { id = "tbd-to", y = 3400, x = 19 }, { id = "tbd-ti", y = 3800, x = 39 }
	local kept = {}
	ctx.at(400, function()
		seams.edge(out.id, out.y, {}, { surface = S })
		seams.edge(inn.id, inn.y, {}, { surface = S })
	end)
	ctx.at(402, function()
		local fo, fi = row(out.y), row(inn.y)
		local a = track(fo, out.x)
		signal(fo, a[11], 10, "out")
		border(fo, out.x)
		local b = track(fi, inn.x, "elevated")
		signal(fi, b[11], 10, "in")
		border(fi, inn.x, "elevated")
		for _, k in ipairs({ out, inn }) do
			local g = generic(k.id, k.x)
			kept[k.id] = { rails = {}, supports = g and g.supports or {} }
			for i, r in ipairs(g and g.rails or {}) do
				kept[k.id].rails[i] = r.unit_number
			end
		end
	end)
	ctx.at(404, function()
		for _, k in ipairs({ out, inn }) do
			local p = by_pos(k.id)[k.x - 2]
			ctx.expect(p ~= nil, k.id .. ": proposed")
			if p then
				k.trace = p.trace
				-- the controller's answer: the proposal comes back as the edge's connector
				seams.edge(k.id, k.y, { { cid = "t1", type = "train", pos = p.pos, width = p.width, params = p.params } },
					{ surface = S, rev = 2 })
			end
		end
	end)
	ctx.at(460, function()
		for _, k in ipairs({ out, inn }) do
			local ep = seams.endpoint(k.id, "t1")
			local d = ep.data
			ctx.expect(ep.state == "ready" and d.box == (k == out and "outbound" or "inbound"), k.id .. ": built " .. tostring(d.box))
			for i = 1, core.OUT_RAILS do
				ctx.expect(d.rails[i].unit_number == kept[k.id].rails[i], k.id .. ": rail " .. i .. " is the generic box's")
			end
			ctx.expect(generic(k.id, k.x) == nil, k.id .. ": the record is gone")
			ctx.expect(d.border ~= nil and d.border.valid, k.id .. ": the player's border rail adopted")
		end
		local s = kept[inn.id].supports
		ctx.expect(#s == 3 and s[1].valid and s[2].valid and not s[3].valid, "inbound: rails 1 and 9's supports kept, rail 19's gone")
		ctx.expect(#seams.endpoint(inn.id, "t1").data.supports == 7 and count(row(inn.y), "rail-support", inn.x, -112, 0) == 7,
			"inbound: its 7 supports and no other")
		-- Review Focus 2: a refusal after the takeover finds no generic box, and the link's rails stay
		bridge.inbox("universal_edges", helpers.table_to_json({ { id = "7bd00000.1", type = "ue.connector.refused",
			payload = { trace = out.trace, reason = "overlap" } } }))
		ctx.expect(seams.endpoint(out.id, "t1").data.rails[1].valid, "a late refusal leaves the box")
	end)
end)

t.case("trains direction: a refused proposal removes its generic box, and the builder hears why (spec §6.4)", function(ctx)
	local id, f, x = "tbd-ref", row(4200), 19
	local said, real_notify = {}, detect.notify
	ctx.at(400, function()
		seams.edge(id, 4200, {}, { surface = S })
	end)
	ctx.at(402, function()
		detect.notify = function(player, text) said[#said + 1] = { player = player, text = text } end
		local a = track(f, x)
		signal(f, a[11], 10, "out")
		local rail = assert(put(f, "straight-rail", x, 1), "border rail")
		detect.on_built({ entity = rail, player_index = 7 }) -- a player's build: the refusal names them
	end)
	ctx.at(404, function()
		local g = generic(id, x)
		ctx.expect(g ~= nil and g.trace ~= nil and g.player == 7, "proposed, its builder remembered")
		local rails = g and g.rails or {}
		bridge.inbox("universal_edges", helpers.table_to_json({ { id = "7bd00000.2", type = "ue.connector.refused",
			payload = { trace = g and g.trace or "none", reason = "overlap" } } }))
		ctx.expect(generic(id, x) == nil, "the record is gone")
		for i, r in ipairs(rails) do
			ctx.expect(not r.valid, "rail " .. i .. " removed")
		end
		local text = said[1] and said[1].text or "none"
		ctx.expect(#said == 1 and said[1].player == 7 and text:find("Train link at [gps=", 1, true) ~= nil
			and text:find("overlaps another link's columns", 1, true) ~= nil, "the chat line: " .. text)
		detect.notify = real_notify
	end)
end)

-- Looped pairs on S: side a at (x0, 12000) facing north, side b at (x0 + 16, 11600) facing south, L = 16. The rail at each
-- side's local x 8 is one world column, col 6 = pos 6 on both.
local function side_a(x0)
	return { origin = { x0, 12000 }, facing = 0, length = 16 }
end

local function side_b(x0)
	return { origin = { x0 + 16, 11600 }, facing = 8, length = 16 }
end

t.case("trains direction: the neighbour's generic box at the link's columns becomes its box there, and its record goes; " ..
	"one on the other rail layer goes, rails too (spec §6.3, ruling 7; Review Focus 3)", function(ctx)
	local cases = { { id = "tbd-nb", x0 = 201, layer = "ground" }, { id = "tbd-lm", x0 = 301, layer = "elevated" } }
	ctx.at(400, function()
		surface()
		loop.sync()
		for _, k in ipairs(cases) do
			loop.ground(k.x0 - 8, 11500, k.x0 + 40, 11610, S)
			loop.ground(k.x0 - 8, 11990, k.x0 + 40, 12080, S)
			loop.edge(k.id, 16, {}, { k.x0, 12000, 0 }, { k.x0 + 16, 11600, 8 }, S)
		end
	end)
	ctx.at(402, function()
		for _, k in ipairs(cases) do
			local fa, fb = side_a(k.x0), side_b(k.x0)
			k.border = border(fb, 8) -- b's player: a ground rail, no signal: a generic box there
			local g = generic(k.id .. "-y", 8)
			ctx.expect(g ~= nil and g.trace == nil, k.id .. ": b's generic box")
			k.rails = g and g.rails or {}
			k.ids = {}
			for i, r in ipairs(k.rails) do
				k.ids[i] = r.unit_number
			end
			local a = track(fa, 8, k.layer)
			signal(fa, a[11], 10, "out")
			border(fa, 8, k.layer)
		end
	end)
	ctx.at(404, function()
		for _, k in ipairs(cases) do
			local p = by_pos(k.id .. "-x")[6]
			ctx.expect(p ~= nil and p.params.dir == "ab" and p.params.layer == k.layer, k.id .. ": a proposes ab: " .. serpent.line(p))
			loop.connectors(k.id, 2, { { cid = "t1", type = "train", pos = 6, width = 4, params = { dir = "ab", layer = k.layer } } })
		end
	end)
	ctx.at(470, function()
		for _, k in ipairs(cases) do
			local ea = connectors.get(storage.universal_edges.edges[k.id .. "-x"], "t1")
			local eb = connectors.get(storage.universal_edges.edges[k.id .. "-y"], "t1")
			ctx.expect(ea ~= nil and ea.state == "ready" and ea.data.box == "outbound", k.id .. ": a's outbound box")
			ctx.expect(eb ~= nil and eb.state == "ready" and eb.data.box == "inbound", k.id .. ": b's inbound box")
			ctx.expect(generic(k.id .. "-x", 8) == nil and generic(k.id .. "-y", 8) == nil, k.id .. ": both records gone")
			for i, r in ipairs(k.rails) do
				if k.layer == "ground" then
					ctx.expect(r.valid and eb ~= nil and eb.data.rails[i].unit_number == k.ids[i], k.id .. ": b's rail " .. i .. " is its box's")
				else
					ctx.expect(not r.valid, k.id .. ": b's ground rail " .. i .. " gone under the elevated link")
				end
			end
			ctx.expect(eb ~= nil and eb.data.border ~= nil and eb.data.border.unit_number == k.border.unit_number,
				k.id .. ": b's border rail adopted")
		end
	end)
end)

-- Task 4: the poll ------------------------------------------------------------------------------------------------------

t.case("trains direction: the poll decides a signal built after the rail, and one left after a both-ways pair loses " ..
	"one; it removes a box whose border rail went, proposed or not, keeping the rails under a train (spec §5, §4; " ..
	"Review Focus 4)", function(ctx)
	local id, f = "tbd-poll", row(4600)
	local k = {}
	ctx.at(600, function()
		seams.edge(id, 4600, {}, { surface = S })
	end)
	ctx.at(602, function()
		k.a = track(f, 9)
		border(f, 9) -- its signal comes after
		local b = track(f, 19)
		k.b_in = signal(f, b[11], 10, "in")
		signal(f, b[11], 10, "out")
		border(f, 19) -- both ways
		track(f, 29)
		k.c = border(f, 29) -- mined while generic
		track(f, 39)
		k.d = border(f, 39) -- mined with a train in its box
		local e = track(f, 49)
		signal(f, e[11], 10, "out")
		k.e = border(f, 49) -- mined after proposing, before any endpoint
	end)
	ctx.at(604, function()
		signal(f, k.a[11], 10, "out")
		for _, x in ipairs({ 29, 39, 49 }) do
			k[x] = generic(id, x).rails
		end
		ctx.expect(generic(id, 49).trace ~= nil, "49 proposed at its build")
		local wx, wy = geometry.to_world(f, 39, core.rail_y(11))
		k.wagon = surface().create_entity{ name = "cargo-wagon", position = { wx, wy }, orientation = 0, force = "player" }
		ctx.expect(k.wagon ~= nil, "a wagon in 39's generic box")
		k.c.destroy() -- no events: the poll notices
		k.d.destroy()
		k.e.destroy()
	end)
	ctx.at(680, function()
		local got = by_pos(id)
		ctx.expect(got[7] ~= nil and got[7].params.dir == "ab", "9: the poll decided: " .. serpent.line(got[7]))
		ctx.expect(got[7] ~= nil and generic(id, 9) ~= nil and generic(id, 9).trace == got[7].trace, "9: proposed once, recorded")
		ctx.expect(got[17] == nil, "19: both ways, still generic")
		for _, x in ipairs({ 29, 49 }) do
			ctx.expect(generic(id, x) == nil, x .. ": the record is gone")
			for i, r in ipairs(k[x]) do
				ctx.expect(not r.valid, x .. ": rail " .. i .. " removed")
			end
		end
		ctx.expect(generic(id, 39) == nil and k.wagon.valid, "39: the record is gone, the wagon stays")
		for i, r in ipairs(k[39]) do
			ctx.expect(r.valid and r.minable_flag and r.destructible, "39: rail " .. i .. " kept under the train, minable")
		end
		k.b_in.destroy()
	end)
	ctx.at(750, function()
		local p = by_pos(id)[17]
		ctx.expect(p ~= nil and p.params.dir == "ab", "19: one signal left, the poll decided: " .. serpent.line(p))
		ctx.expect(#(sent[id] or {}) == 3, "9, 19 and 49 proposed once each: " .. #(sent[id] or {}))
	end)
end)

t.case("trains direction: a generic box goes with its edge (Review Focus 5)", function(ctx)
	local fa, rails = side_a(401), {}
	ctx.at(600, function()
		surface()
		loop.sync()
		loop.ground(393, 11500, 441, 11610, S)
		loop.ground(393, 11990, 441, 12080, S)
		loop.edge("tbd-del", 16, {}, { 401, 12000, 0 }, { 417, 11600, 8 }, S)
	end)
	ctx.at(602, function()
		border(fa, 8)
		local g = generic("tbd-del-x", 8)
		ctx.expect(g ~= nil, "a generic box")
		rails = g and g.rails or {}
		loop.connectors("tbd-del", 2, {}, true) -- the edge deleted
	end)
	ctx.at(680, function()
		ctx.expect(generic("tbd-del-x", 8) == nil, "the record is gone")
		for i, r in ipairs(rails) do
			ctx.expect(not r.valid, "rail " .. i .. " removed")
		end
	end)
end)

t.case("trains direction: robots build a blueprint's border rail and its signal for trains coming in: an inbound link, " ..
	"whichever they build first (spec §9; spike 35 R1)", function(ctx)
	local id, f, x = "tbd-bot", row(5000), 17
	local inside
	ctx.at(800, function()
		seams.edge(id, 5000, {}, { surface = S })
		seams.generate(surface(), f, x - 16, -48, x + 24, 32)
	end)
	ctx.at(802, function()
		inside = track(f, x)
		local eei = assert(put(f, "electric-energy-interface", x + 5, 14), "power")
		eei.power_production, eei.electric_buffer_size = 1e9, 1e10
		assert(put(f, "substation", x + 5, 8), "substation")
		assert(put(f, "roboport", x + 5, 4), "roboport").insert{ name = "construction-robot", count = 20 }
		local chest = assert(put(f, "storage-chest", x + 3, 12), "chest")
		chest.insert{ name = "rail", count = 20 }
		chest.insert{ name = "rail-signal", count = 20 }
		local wx, wy = geometry.to_world(f, x, 1)
		assert(surface().create_entity{ name = "entity-ghost", inner_name = "straight-rail", position = { wx, wy },
			direction = geometry.dir_to_world(f, 0), force = "player" }, "border rail ghost")
		signal(f, inside[11], 10, "in", nil, true)
	end)
	ctx.at(1700, function()
		local p = by_pos(id)[x - 2]
		ctx.expect(p ~= nil and p.params.dir == "ba", "inbound: the neighbour sends: " .. serpent.line(p))
		local x1, y1, x2, y2 = geometry.area_to_world(f, x - 3, 0, x + 3, 12)
		ctx.expect(surface().count_entities_filtered{ area = { { x1, y1 }, { x2, y2 } }, name = "entity-ghost" } == 0,
			"the robots built both ghosts")
	end)
end)
