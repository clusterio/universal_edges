-- The radar sync on one save (radar-sync spec §8; plan Tasks 4–5). No controller runs: the hosts' reports are read from
-- the bridge queue, and the controller's messages are put in the inbox. Ground and ticks are the plan's table: Nauvis
-- x 20094–20224 at y 5000 (cases 1 and 3), the lab surface rd-lab (case 2), Task 5's row rd-61 at x 20000. Surface-mode
-- radars on Nauvis are one network, so the cases that use them never overlap in time; the radar writes fall in 380–480
-- and 960–1250, clear of the circuit tests' big-write windows (the write budget is one per instance).
local t = require("modules/v2_test/testlib")
local layouts = require("modules/v2_test/layouts")
local bridge = require("modules/universal_edges/runtime/bridge")
local cc = require("modules/universal_edges/transports/circuit_core")
local radar = require("modules/universal_edges/transports/radar")
local seams = require("modules/universal_edges/transports/radar_seams")
local loop = require("modules/v2_test/loopback")
local connectors = require("modules/universal_edges/edges/connectors")

local same, read, map, sig = layouts.same, layouts.read, layouts.map, layouts.sig
local S = "s:nauvis"
local KEY1, KEY2, KEY9 = "u:virtual:signal-1:normal", "u:virtual:signal-2:normal", "u:virtual:signal-9:normal"

local function hosts()
	return storage.universal_edges.radar.hosts
end

--- Ticks as ctx.at offsets: game.tick less the testlib's first tick.
local function offset(tick)
	return tick - (t.first_tick or 0)
end

-- Every ue.radar.* message and ue.radar trace, read from the queue before each flush (wrappers chain), with the offset
-- of the tick it left in.
local sent = {}
local flush = bridge.flush
function bridge.flush(tick)
	for _, msg in ipairs(storage.universal_edges.bridge.out.universal_edges or {}) do
		if string.sub(msg.type, 1, 9) == "ue.radar." or (msg.type == "trace" and msg.payload.op == "ue.radar") then
			sent[#sent + 1] = { type = msg.type, payload = msg.payload, at = offset(tick) }
		end
	end
	flush(tick)
end

--- The payloads of msg_type for key (nil: any; a chunk's key starts "<key>/") and, for a trace, phase, from offset from
--- on: flushed, or still queued in this tick.
local function got(msg_type, key, from, phase)
	local out = {}
	local function take(m, at)
		local p = m.payload
		if m.type ~= msg_type or at < from then
			return -- this plugin's queue also holds other transports' messages, some without a key
		end
		local mine = key == nil or p.key == key
			or (msg_type == "ue.radar.chunk" and string.sub(p.key, 1, #key + 1) == key .. "/")
		if mine and (phase == nil or p.phase == phase) then
			out[#out + 1] = p
		end
	end
	for _, m in ipairs(sent) do
		take(m, m.at)
	end
	for _, m in ipairs(storage.universal_edges.bridge.out.universal_edges or {}) do
		take(m, offset(game.tick))
	end
	return out
end

--- key's own reports from tick from, in order, chunked ones put back together; and how many came in parts.
local function owns(key, from)
	local parts, list, chunked = {}, {}, 0
	for _, p in ipairs(got("ue.radar.chunk", key, from)) do
		parts[p.key] = parts[p.key] or {}
		parts[p.key][p.i] = p.data
	end
	for _, p in ipairs(got("ue.radar.own", key, from)) do
		if p.chunks then
			chunked = chunked + 1
			list[#list + 1] = helpers.json_to_table(table.concat(parts[key .. "/" .. p.seq]))
		else
			list[#list + 1] = p
		end
	end
	return list, chunked
end

--- What the controller would hold of an own after these reports (circuit_core's fold, from nothing): { r, g } maps.
local function folded(list)
	local d = cc.data()
	for _, st in ipairs(list) do
		cc.fold(d, st, "e", function() return true end)
	end
	return d.far
end

local n = 0
--- msg_type with payload into the inbox, as the controller's relay sends it (ids under 4ad40000, this file's).
local function inject(msg_type, payload)
	n = n + 1
	ue_rt.inbox("universal_edges", helpers.table_to_json({ { id = "4ad40000." .. n, type = msg_type, payload = payload } }))
end

t.case("radar: a host joins its planet's network at spawn and reads the total; its first report is its own in full, "
	.. "in parts past 3000 bytes; a full and a delta write the target, echo-cancelled; an unknown signal is dropped and "
	.. "logged once; a delta off its base asks; a resync reports and asks again; the last radar's going unhosts (§4, "
	.. "§5, R1/R4; Review Focus 2, 4, 5)", function(ctx)
	local r1, h
	ctx.at(300, function()
		local p = prototypes.entity["ue-link-radar"]
		ctx.expect(p and p.type == "radar" and p.hidden and not p.selectable_in_game and next(p.collision_mask.layers) == nil,
			"ue-link-radar: a hidden radar, unselectable, colliding with nothing")
		r1 = seams.rig({ x = 20100, y = 5000, signals = { { name = "signal-A", count = 5 } } })
		seams.rig({ x = 20120, y = 5000, colour = "g", n = 200, base = 1000 })
		radar.discover()
		h = hosts()[S]
		ctx.expect(h and h.radar.valid and h.radar.name == "ue-link-radar" and h.radar.surface.name == "nauvis",
			"a host for s:nauvis")
		ctx.expect(h and h.comb.r.valid and h.comb.g.valid, "with its two injectors")
		local spawn = game.forces.player.get_spawn_position(game.surfaces.nauvis)
		ctx.expect(h and math.abs(h.radar.position.x - spawn.x) <= 2 and math.abs(h.radar.position.y - spawn.y) <= 2,
			"at the spawn position")
		ctx.expect(#got("ue.radar.ask", S, 300) == 1, "it asked for its full target")
	end)
	ctx.at(380, function()
		local list, chunked = owns(S, 300)
		local own = folded(list)
		ctx.expect(#list >= 1 and list[1].base == nil, "its first report is the full form")
		ctx.expect(same(own.r, map(sig({ "signal-A", 5 }))) and cc.size(own.g) == 200, "its own: signal-A and 200 green")
		ctx.expect(chunked >= 1, "a report over 3000 bytes left in ue.radar.chunk parts")
		inject("ue.radar.full", { key = S, v = 1, r = { virtual = { "signal-T", 7 }, item = { "no-such-item", 3 } } })
	end)
	ctx.at(384, function()
		ctx.expect(same(read(r1, "r"), map(sig({ "signal-A", 5, "signal-T", 7 }))), "the real radar reads own and target")
		ctx.expect(#got("trace", S, 380, "unknown_signal") == 1, "the unknown item: dropped, logged once")
		inject("ue.radar.delta", { key = S, v = 2, base = 1, r = { virtual = { "signal-T", 0, "signal-U", 3 } } })
	end)
	ctx.at(388, function()
		ctx.expect(same(read(r1, "r"), map(sig({ "signal-A", 5, "signal-U", 3 }))), "a delta: T out, U in")
	end)
	ctx.at(470, function()
		ctx.expect(#got("ue.radar.own", S, 381) == 0, "the target is echo-cancelled: no report since it was written")
		inject("ue.radar.delta", { key = S, v = 9, base = 8, r = { virtual = { "signal-U", 4 } } })
		ctx.expect(h.gap == true, "a delta off its base is a gap")
		ctx.expect(#got("ue.radar.ask", S, 470) == 1, "which asks")
		inject("ue.radar.full", { key = S, v = 3, r = { virtual = { "signal-U", 4 } } })
		ctx.expect(not h.gap, "a full ends it")
	end)
	ctx.at(474, function()
		ctx.expect(same(read(r1, "r"), map(sig({ "signal-A", 5, "signal-U", 4 }))), "the full's target written")
		inject("ue.radar.resync", {})
		local own = folded((owns(S, 474)))
		ctx.expect(same(own.r, map(sig({ "signal-A", 5 }))) and cc.size(own.g) == 200, "resync: its own again, in full")
		ctx.expect(#got("ue.radar.ask", S, 474) == 1, "and an ask")
	end)
	ctx.at(490, function()
		seams.clear({ x1 = 20090, y1 = 4995, x2 = 20130, y2 = 5010 })
		radar.discover()
		ctx.expect(hosts()[S] == nil and not h.radar.valid and not h.comb.r.valid and not h.comb.g.valid,
			"the last radar gone: the host and its injectors destroyed")
		ctx.expect(#got("ue.radar.unhost", S, 490) == 1, "unhost reported")
	end)
end)

t.case("radar: discovery hosts a universe channel on Nauvis whatever the radar's surface, follows a channel change (no "
	.. "event fires: R6), never hosts surface mode off a planet, and unhosts when the last radar goes (§4; Review "
	.. "Focus 3)", function(ctx)
	local u
	ctx.at(300, function()
		u = seams.rig({ surface = "rd-lab", x = 0, y = 0, channel = "signal-1", signals = { { name = "signal-D", count = 1 } } })
		seams.rig({ surface = "rd-lab", x = 20, y = 0, signals = { { name = "signal-E", count = 1 } } })
		radar.discover()
		local h = hosts()[KEY1]
		ctx.expect(h and h.radar.surface.name == "nauvis", "the channel's host stands on Nauvis")
		local lab = 0
		for key in pairs(hosts()) do
			if string.sub(key, 1, 2) == "s:" and key ~= S then
				lab = lab + 1
			end
		end
		ctx.expect(lab == 0 and game.surfaces["rd-lab"].count_entities_filtered({ name = "ue-link-radar" }) == 0,
			"a lab surface's surface mode is never hosted")
	end)
	ctx.at(310, function()
		u.get_control_behavior().universe_channel = { type = "virtual", name = "signal-2" }
		radar.discover()
		ctx.expect(hosts()[KEY1] == nil and hosts()[KEY2] ~= nil, "the channel change moved the host")
		ctx.expect(#got("ue.radar.unhost", KEY1, 310) == 1, "the old key unhosted")
	end)
	ctx.at(320, function()
		u.destroy()
		radar.discover()
		ctx.expect(hosts()[KEY2] == nil, "the channel's last radar gone: unhosted")
		seams.clear({ surface = "rd-lab", x1 = -10, y1 = -5, x2 = 30, y2 = 10 })
	end)
end)

t.case("radar: a wire joining a surface network and a universe channel on one tile reports it once, under the first "
	.. "key; the second key's injector is cleared while they are joined, and its target comes back when they part "
	.. "(guard 6.2)", function(ctx)
	local rs, ru
	ctx.at(950, function()
		rs = seams.rig({ x = 20200, y = 5000, signals = { { name = "signal-B", count = 2 } } })
		ru = seams.rig({ x = 20220, y = 5000, channel = "signal-9", signals = { { name = "signal-C", count = 3 } } })
		radar.discover()
		ctx.expect(hosts()[S] ~= nil and hosts()[KEY9] ~= nil, "both keys hosted")
	end)
	ctx.at(960, function()
		inject("ue.radar.full", { key = S, v = 1, r = { virtual = { "signal-W", 6 } } })
		inject("ue.radar.full", { key = KEY9, v = 1, r = { virtual = { "signal-V", 4 } } })
	end)
	ctx.at(970, function()
		ctx.expect(same(read(rs, "r"), map(sig({ "signal-B", 2, "signal-W", 6 }))), "apart: the surface network")
		ctx.expect(same(read(ru, "r"), map(sig({ "signal-C", 3, "signal-V", 4 }))), "apart: the channel")
		layouts.wire(rs, ru, "r")
	end)
	ctx.at(1100, function()
		local u = hosts()[KEY9]
		ctx.expect(u.carry.r == false and u.carry.g == true, "the channel's red is merged into s:nauvis; green stays apart")
		ctx.expect(#got("trace", KEY9, 970, "merged") == 1, "logged once")
		ctx.expect(same(read(rs, "r"), map(sig({ "signal-B", 2, "signal-C", 3, "signal-W", 6 }))),
			"joined: one network, the channel's target cleared")
		ctx.expect(same(folded((owns(S, 950))).r, map(sig({ "signal-B", 2, "signal-C", 3 }))),
			"s:nauvis reports the joined network's own")
		ctx.expect(next(folded((owns(KEY9, 950))).r) == nil, "the channel reports nothing")
		ctx.expect((hosts()[S].stats.skipped or 0) >= 1, "the joined, quiet network is not read again (spike 29): "
			.. tostring(hosts()[S].stats.skipped))
		layouts.wire(rs, ru, "r", true)
	end)
	ctx.at(1250, function()
		ctx.expect(hosts()[KEY9].carry.r == true, "parted: the channel carries again")
		ctx.expect(same(read(ru, "r"), map(sig({ "signal-C", 3, "signal-V", 4 }))), "its target back")
		ctx.expect(same(read(rs, "r"), map(sig({ "signal-B", 2, "signal-W", 6 }))), "the surface network as before")
		ctx.expect(same(folded((owns(S, 950))).r, map(sig({ "signal-B", 2 })))
			and same(folded((owns(KEY9, 950))).r, map(sig({ "signal-C", 3 }))), "each reports its own again")
	end)
	ctx.at(1300, function()
		seams.clear({ x1 = 20190, y1 = 4995, x2 = 20230, y2 = 5010 })
		radar.discover()
	end)
end)

local function ep(edge)
	local side = storage.universal_edges.edges[edge]
	return side and connectors.get(side, "c1")
end

t.case("radar: a circuit link whose two poles are in one synced radar network carries nothing on that colour: each "
	.. "status names the key, both sides quiet the colour, and the poles stay exact (guard 6.1)", function(ctx)
	local r
	local want = map(sig({ "signal-L", 5 }))
	ctx.at(2500, function()
		r = layouts.circuit_row(loop, "rd-61", 20000, { 2 }, 8)
		local ra = seams.rig({ x = 20010, y = 3012, signals = { { name = "signal-L", count = 5 } } })
		local rb = seams.rig({ x = 20010, y = 1984 })
		radar.discover()
		-- one save: both poles join one Nauvis radar network, as two tiles' networks are joined by the sync
		layouts.wire(r.a[1], ra, "r")
		layouts.wire(r.b[1], rb, "r")
	end)
	ctx.at(2900, function()
		for _, edge in ipairs({ "rd-61-x", "rd-61-y" }) do
			local e = ep(edge)
			ctx.expect(e and e.data.guard and e.data.guard.qr == true and e.data.carry.r == false,
				edge .. ": red quiet by guard 6.1")
			ctx.expect(e and e.status and e.status.kr == S, edge .. "'s status names its radar key")
		end
		ctx.expect(same(read(r.a[1], "r"), want) and same(read(r.b[1], "r"), want), "both poles exact")
		ctx.expect(#got("trace", nil, 2500, "loop_quiet") >= 2, "loop_quiet on both sides")
	end)
	ctx.at(3300, function()
		ctx.expect(same(read(r.a[1], "r"), want) and same(read(r.b[1], "r"), want), "still exact 400 ticks on: no growth")
	end)
	ctx.at(3400, function()
		seams.clear({ x1 = 20000, y1 = 3005, x2 = 20020, y2 = 3020 })
		seams.clear({ x1 = 20000, y1 = 1980, x2 = 20020, y2 = 1995 })
		radar.discover()
	end)
end)

-- The registry (rd-lab, x 100–260 at y 0; ticks 3500–3800): a built radar joins `known`, a destroyed one leaves it, and a
-- radar made without raise_built is found only by the seed scan.
local KEY3, KEY4 = "u:virtual:signal-3:normal", "u:virtual:signal-4:normal"

t.case("radar: a radar built after the registry exists is hosted at the next discovery, a destroyed one leaves the "
	.. "registry, and the seed scan finds a radar made without raise_built", function(ctx)
	local r, plain
	ctx.at(3500, function()
		radar.discover()
		ctx.expect(storage.universal_edges.radar.known ~= nil, "the registry exists after a discovery")
		r = seams.rig({ surface = "rd-lab", x = 100, y = 0, channel = "signal-3" })
		ctx.expect(storage.universal_edges.radar.known[r.unit_number] == r, "the build event registered the radar")
		radar.discover()
		ctx.expect(hosts()[KEY3] ~= nil, "hosted at the next discovery")
	end)
	ctx.at(3600, function()
		local unit = r.unit_number
		r.destroy()
		radar.discover()
		ctx.expect(storage.universal_edges.radar.known[unit] == nil and hosts()[KEY3] == nil, "the entry left and the host went")
		seams.clear({ surface = "rd-lab", x1 = 94, y1 = -2, x2 = 104, y2 = 6 })
	end)
	ctx.at(3700, function()
		seams.rig({ surface = "rd-lab", x = 200, y = 0 })
		plain = game.surfaces["rd-lab"].create_entity({ name = "radar", position = { 212.5, 0.5 }, force = "player" })
		plain.get_or_create_control_behavior().mode = defines.control_behavior.radar.mode.universe
		plain.get_control_behavior().universe_channel = { type = "virtual", name = "signal-4" }
		storage.universal_edges.radar.known = nil
		radar.discover()
		ctx.expect(storage.universal_edges.radar.known[plain.unit_number] == plain and hosts()[KEY4] ~= nil,
			"the seed scan found the radar made without raise_built")
	end)
	ctx.at(3800, function()
		plain.destroy()
		radar.discover()
		ctx.expect(hosts()[KEY4] == nil, "unhosted")
		seams.clear({ surface = "rd-lab", x1 = 194, y1 = -2, x2 = 216, y2 = 6 })
		radar.discover()
	end)
end)
