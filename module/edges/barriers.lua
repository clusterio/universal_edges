-- World barriers (SP1 spec §9): ue-barrier entities outside every live side, each one built once its centre's chunk
-- is generated. storage.universal_edges.barriers[surface_index]["cx,cy"][edge_id] = { { x, y, entity? }, ... }.
-- ponytail: nothing handles a surface that is deleted or cleared under a live side; its barriers stay missing until
-- the side is re-created. Add on_surface_deleted/on_surface_cleared handlers if surfaces ever come and go under edges.
local bridge = require("modules/universal_edges/runtime/bridge")
local geometry = require("modules/universal_edges/edges/geometry_core")

local barriers = {}
local send = bridge.channel("universal_edges")
local NAME = "ue-barrier"

--- "%d" also prints a -0 as "0", so a key always matches the chunk position of on_chunk_generated.
local function key(cx, cy)
	return string.format("%d,%d", cx, cy)
end

local function build(surface, entry)
	local entity = surface.create_entity({
		name = NAME, position = { entry.x, entry.y }, force = "neutral", raise_built = false,
		create_build_effect_smoke = false,
	})
	if entity then
		entity.destructible = false
		entry.entity = entity
	end
end

--- Place a live side's barriers: at once where the chunk is generated, pending elsewhere. Without the surface or the
--- prototype (the UE mod is missing) it logs barrier_skipped, at error, and carries on: barriers are safety only.
function barriers.place(side)
	local surface = side.surface_index and game.get_surface(side.surface_index)
	if not surface or not prototypes.entity[NAME] then
		send("trace", { op = "ue.edge", phase = "barrier_skipped", level = "error", trace = side.trace, tick = game.tick,
			edge = side.id, reason = surface and "prototype" or "surface" })
		return
	end
	local index = storage.universal_edges.barriers
	index[surface.index] = index[surface.index] or {}
	local chunks = index[surface.index]
	for k = 0, geometry.barrier_count(side.length) - 1 do
		local x, y = geometry.to_world(side[side.me], geometry.barrier_centre(k))
		local cx, cy = math.floor(x / 32), math.floor(y / 32)
		local ck = key(cx, cy)
		chunks[ck] = chunks[ck] or {}
		chunks[ck][side.id] = chunks[ck][side.id] or {}
		local entry = { x = x, y = y }
		table.insert(chunks[ck][side.id], entry)
		side.barrier_chunks[ck] = true
		if surface.is_chunk_generated({ cx, cy }) then
			build(surface, entry)
		end
	end
end

--- Destroy a side's barriers and forget them, walking only the side's own chunks (§9).
function barriers.remove(side)
	local chunks = side.surface_index and storage.universal_edges.barriers[side.surface_index]
	for ck in pairs(side.barrier_chunks) do
		local chunk = chunks and chunks[ck]
		if chunk then
			for _, entry in ipairs(chunk[side.id] or {}) do
				if entry.entity and entry.entity.valid then
					entry.entity.destroy()
				end
			end
			chunk[side.id] = nil
			if next(chunk) == nil then
				chunks[ck] = nil
			end
		end
	end
	side.barrier_chunks = {}
end

--- on_chunk_generated: build the chunk's pending barriers. An O(1) lookup; no scan.
function barriers.on_chunk_generated(event)
	local index = storage.universal_edges and storage.universal_edges.barriers
	local chunks = index and index[event.surface.index]
	local chunk = chunks and chunks[key(event.position.x, event.position.y)]
	for _, list in pairs(chunk or {}) do
		for _, entry in ipairs(list) do
			if not (entry.entity and entry.entity.valid) then
				build(event.surface, entry)
			end
		end
	end
end

--- on_chunk_deleted: the chunks' barriers went with them, so they wait for the chunk again.
function barriers.on_chunk_deleted(event)
	local index = storage.universal_edges and storage.universal_edges.barriers
	local chunks = index and index[event.surface_index]
	if not chunks then
		return
	end
	for _, position in ipairs(event.positions) do
		for _, list in pairs(chunks[key(position.x, position.y)] or {}) do
			for _, entry in ipairs(list) do
				entry.entity = nil
			end
		end
	end
end

return barriers
