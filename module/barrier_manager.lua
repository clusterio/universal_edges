local edge_util = require("modules/universal_edges/edge/util")

local barrier_manager = {}

-- Constants for barrier placement
local BARRIER_DISTANCE_FROM_EDGE = 16  -- 15 tiles away from the outside of the edge
local BARRIER_SIZE = 20                 -- 20x20 barrier entity
local BARRIER_OVERLAP = 1              -- 1 tile overlap between barriers
local BARRIER_SPACING = BARRIER_SIZE - BARRIER_OVERLAP  -- 19 tiles between barrier centers

-- Create barriers along an edge
---@param edge UniversalEdge
function barrier_manager.create_edge_barriers(edge)
	local edge_id = edge.id
	local local_target = edge_util.edge_get_local_target(edge)
	if not local_target then return end
	local surface = game.surfaces[local_target.surface]
	if not surface then return end
	local surface_index = surface.index
	-- Calculate barrier length (110% of edge length)
	local barrier_length = math.ceil(edge.length * 1.20)
	local num_barriers = math.ceil(barrier_length / BARRIER_SPACING)
	-- Calculate starting position offset to center the barriers
	local start_offset = (edge.length - barrier_length) / 2
	-- Initialize barrier storage if it doesn't exist
	if not storage.universal_edges.barriers then
		storage.universal_edges.barriers = {}
	end
	if not storage.universal_edges.barriers[surface_index] then
		storage.universal_edges.barriers[surface_index] = {}
	end
	if not storage.universal_edges.barriers[surface_index][edge_id] then
		storage.universal_edges.barriers[surface_index][edge_id] = {}
	else
		barrier_manager.remove_edge_barriers(edge)
		storage.universal_edges.barriers[surface_index][edge_id] = {}
	end
	-- Determine which side is the "outside" based on edge direction
	-- The outside is the side that leads away from the partner instance
	local outside_side = -1  -- Default to negative side (left/up relative to edge direction)
	-- Create barriers only on the outside edge
	for i = 0, num_barriers - 1 do
		-- Calculate position along the edge
		local along_edge = start_offset + (i * BARRIER_SPACING)
		-- Position along the edge in edge coordinates (no clamping to allow proper spacing)
		local edge_pos_x = along_edge
		-- Position perpendicular to the edge (32 tiles away from edge boundary on outside)
		local edge_pos_y = outside_side * BARRIER_DISTANCE_FROM_EDGE
		-- Convert edge position to world coordinates
		local world_pos = edge_util.edge_pos_to_world({edge_pos_x, edge_pos_y}, edge)
		local chunk_pos = {x = math.floor(world_pos[1] / 32), y = math.floor(world_pos[2] / 32)}
		-- Create the barrier entity
		if surface.is_chunk_generated(chunk_pos) then
			local barrier = surface.create_entity{
				name = "ue_world_barrier",
				position = world_pos,
				raise_built = false
			}
			if barrier then
				barrier.destructible = false  -- Make completely indestructible
				-- Store reference to the barrier
				table.insert(storage.universal_edges.barriers[surface_index][edge_id], barrier)
			else
				log("Failed to create barrier at world position " .. world_pos[1] .. ", " .. world_pos[2] .. " for edge " .. edge_id)
			end
		else
			if not storage.universal_edges.barriers[surface_index]["pending"] then
				storage.universal_edges.barriers[surface_index]["pending"] = {}
			end
			if not storage.universal_edges.barriers[surface_index]["pending"][chunk_pos.x] then
				storage.universal_edges.barriers[surface_index]["pending"][chunk_pos.x] = {}
			end
			if not storage.universal_edges.barriers[surface_index]["pending"][chunk_pos.x][chunk_pos.y] then
				storage.universal_edges.barriers[surface_index]["pending"][chunk_pos.x][chunk_pos.y] = {}
			end
			table.insert(storage.universal_edges.barriers[surface_index]["pending"][chunk_pos.x][chunk_pos.y], {position = world_pos, edge_id = edge_id})
		end
	end
end

-- Remove all barriers for an edge
---@param edge UniversalEdge
function barrier_manager.remove_edge_barriers(edge)
	local edge_id = edge.id
	local local_target = edge_util.edge_get_local_target(edge)
	if not local_target then return end
	local surface = game.surfaces[local_target.surface]
	if not surface then return end
	local surface_index = surface.index
	if not storage.universal_edges.barriers then return end
	if not storage.universal_edges.barriers[surface_index] then return end
	if not storage.universal_edges.barriers[surface_index][edge_id] then return end
	-- destroy existing barriers for this edge
	for _, barrier in ipairs(storage.universal_edges.barriers[surface_index][edge_id]) do
		if barrier and barrier.valid then
			barrier.destroy()
		end
	end
	storage.universal_edges.barriers[surface_index][edge_id] = nil
	-- clean up pending barriers for this edge
	if storage.universal_edges.barriers[surface_index]["pending"] then
		for chunk_x, column in pairs(storage.universal_edges.barriers[surface_index]["pending"]) do
			for chunk_y, pending in pairs(column) do
				for i = #pending, 1, -1 do
					if pending[i].edge_id == edge_id then
						table.remove(pending, i)
					end
				end
				-- Clean up empty lists
				if #pending == 0 then
					storage.universal_edges.barriers[surface_index]["pending"][chunk_x][chunk_y] = nil
				end
				if not next(storage.universal_edges.barriers[surface_index]["pending"][chunk_x]) then
					storage.universal_edges.barriers[surface_index]["pending"][chunk_x] = nil
				end
				if not next(storage.universal_edges.barriers[surface_index]["pending"]) then
					storage.universal_edges.barriers[surface_index]["pending"] = nil
				end
			end
		end
	end
	log("Removed all barriers for edge " .. edge_id .. " on surface " .. surface.name)
end

-- Event handler for when a chunk is generated, to create any pending barriers in that chunk
---@param event EventData.on_chunk_generated
function barrier_manager.on_chunk_generated(event)
	local chunk_pos = event.position
	local surface_index = event.surface.index
	-- Check if any barriers need to be created in this chunk
	if not storage.universal_edges.barriers then return end
	if not storage.universal_edges.barriers[surface_index] then return end
	if not storage.universal_edges.barriers[surface_index]["pending"] then return end
	if not storage.universal_edges.barriers[surface_index]["pending"][chunk_pos.x] then return end
	if not storage.universal_edges.barriers[surface_index]["pending"][chunk_pos.x][chunk_pos.y] then return end
	local surface = event.surface
	local pending_list = storage.universal_edges.barriers[surface_index]["pending"][chunk_pos.x][chunk_pos.y]
	-- Process all pending entities in this chunk
	for _, pending in ipairs(pending_list) do
		local world_pos = pending.position
		local barrier = surface.create_entity{
			name = "ue_world_barrier",
			position = world_pos,
			raise_built = false
		}
		if barrier then
			barrier.destructible = false  -- Make completely indestructible
			-- Store reference to the barrier
			-- Ensure the barriers table exists for this edge
			if not storage.universal_edges.barriers[surface_index][pending.edge_id] then
				storage.universal_edges.barriers[surface_index][pending.edge_id] = {}
			end
			table.insert(storage.universal_edges.barriers[surface_index][pending.edge_id], barrier)
		else
			log("Failed to create barrier at world position " .. world_pos[1] .. ", " .. world_pos[2] .. " for edge " .. pending.edge_id)
		end
	end
	-- Clean up the pending list for this chunk
	storage.universal_edges.barriers[surface_index]["pending"][chunk_pos.x][chunk_pos.y] = nil
	if not next(storage.universal_edges.barriers[surface_index]["pending"][chunk_pos.x]) then
		storage.universal_edges.barriers[surface_index]["pending"][chunk_pos.x] = nil
	end
end

return barrier_manager
