-- Test seams for the radar sync (radar-sync spec §8; plan Task 4): inert unless called, as circuit_seams.lua is. The
-- game tests and the bench call rig and clear directly; the E2E calls every op through ue_rt.radar_test.
local cseams = require("modules/universal_edges/transports/circuit_seams")

local seams = {}
local W = { r = defines.wire_connector_id.circuit_red, g = defines.wire_connector_id.circuit_green }
local RM = defines.control_behavior.radar.mode
local RIG = { "radar", "medium-electric-pole", "electric-energy-interface", "constant-combinator" }

--- o.surface (default nauvis), made with lab tiles when missing (spike_lib's track.surface).
local function surface(o)
	local name = o.surface or "nauvis"
	local s = game.get_surface(name)
	if not s then
		s = game.create_surface(name)
		s.generate_with_lab_tiles, s.always_day = true, true
	end
	return s
end

--- Generate (x, y)'s chunks, pave x1..x2 × y1..y2 and clear it of everything but characters and UE's own entities.
local function ground(s, x, y, x1, y1, x2, y2)
	s.request_to_generate_chunks({ x, y }, 1)
	s.force_generate_chunk_requests()
	local tiles = {}
	for tx = x1, x2 do
		for ty = y1, y2 do
			tiles[#tiles + 1] = { name = "refined-concrete", position = { tx, ty } }
		end
	end
	s.set_tiles(tiles)
	for _, e in pairs(s.find_entities_filtered({ area = { { x1, y1 }, { x2 + 1, y2 + 1 } } })) do
		if e.type ~= "character" and string.sub(e.name, 1, 3) ~= "ue-" then
			e.destroy()
		end
	end
end

--- "rig" (spike 18's rig): a real radar at (o.x - 3.5, o.y + 0.5) with its medium pole at (o.x + 0.5, o.y + 0.5) and a
--- vanilla electric-energy-interface at (o.x, o.y + 4) powering it, and a constant combinator at (o.x + 2.5, o.y + 0.5)
--- holding o.signals or pool o.n (circuit_seams.fill), wired to the radar on o.colour (default "r") by a player's wire.
--- o.channel (a virtual signal's name) puts the radar in universe mode on it. Returns the radar and the combinator.
function seams.rig(o)
	local s = surface(o)
	local x, y = o.x, o.y
	ground(s, x, y, x - 6, y - 2, x + 4, y + 6)
	local function put(name, px, py)
		return assert(s.create_entity({ name = name, position = { px, py }, force = "player" }), name)
	end
	put("medium-electric-pole", x + 0.5, y + 0.5)
	put("electric-energy-interface", x, y + 4)
	local radar = assert(s.create_entity({ name = "radar", position = { x - 3.5, y + 0.5 }, force = "player", raise_built = true }), "radar")
	local cb = radar.get_or_create_control_behavior()
	if o.channel then
		cb.mode, cb.universe_channel = RM.universe, { type = "virtual", name = o.channel }
	end
	local comb = put("constant-combinator", x + 2.5, y + 0.5)
	cseams.fill(comb, o)
	local w = W[o.colour or "r"]
	comb.get_wire_connector(w, true).connect_to(radar.get_wire_connector(w, true), false, defines.wire_origin.player)
	return radar, comb
end

--- "read": the rig radar of (o.x, o.y) on o.surface: its network of colour o.colour (circuit_seams.describe).
function seams.read(o)
	local r = surface(o).find_entity("radar", { o.x - 3.5, o.y + 0.5 })
	return cseams.describe(r and r.get_circuit_network(W[o.colour or "r"]))
end

--- "clear": every rig entity in the box (o.x1, o.y1)–(o.x2, o.y2) of o.surface goes.
function seams.clear(o)
	local s = game.get_surface(o.surface or "nauvis")
	if s then
		for _, e in pairs(s.find_entities_filtered({ area = { { o.x1, o.y1 }, { o.x2, o.y2 } }, name = RIG })) do
			e.destroy()
		end
	end
end

--- "pole": a medium pole at (o.x, o.y) on o.surface, its tile paved and cleared.
function seams.pole(o)
	local s = surface(o)
	local x, y = math.floor(o.x), math.floor(o.y)
	ground(s, x, y, x, y, x, y)
	assert(s.create_entity({ name = "medium-electric-pole", position = { o.x, o.y }, force = "player" }), "pole")
end

--- "wire": the pole at o.pole ({ x, y }) and the rig radar of (o.x, o.y) joined on o.colour (default "r") by a
--- player's wire, reach unchecked.
function seams.wire(o)
	local s = surface(o)
	local p = s.find_entity("medium-electric-pole", o.pole)
	local r = s.find_entity("radar", { o.x - 3.5, o.y + 0.5 })
	local w = W[o.colour or "r"]
	p.get_wire_connector(w, true).connect_to(r.get_wire_connector(w, true), false, defines.wire_origin.player)
end

--- "state": this tile's hosts, { [key] = { v, far_v, gap, carry, nout, nfar, stats } }.
function seams.state()
	local out = {}
	for key, h in pairs(storage.universal_edges.radar.hosts) do
		out[key] = { v = h.v, far_v = h.far_v, gap = h.gap, carry = h.carry, nout = h.nout, nfar = h.nfar, stats = h.stats }
	end
	return helpers.table_to_json(out)
end

--- ue_rt.radar_test(op, json): "rig", "read", "clear", "pole", "wire" or "state". Returns "ok" or JSON.
function seams.call(op, json)
	local o = type(json) == "string" and helpers.json_to_table(json) or {}
	if op == "rig" then
		seams.rig(o)
	elseif op == "read" then
		return seams.read(o)
	elseif op == "clear" then
		seams.clear(o)
	elseif op == "pole" then
		seams.pole(o)
	elseif op == "wire" then
		seams.wire(o)
	elseif op == "state" then
		return seams.state()
	else
		error("ue_rt.radar_test: unknown op " .. tostring(op))
	end
	return "ok"
end

return seams
