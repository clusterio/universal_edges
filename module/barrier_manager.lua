local edge_util = require("modules/universal_edges/edge/util")
local vectorutil = require("modules/universal_edges/vectorutil")

local barrier_manager = {}

-- Constants for barrier placement
local BARRIER_DISTANCE_FROM_EDGE = 16  -- 15 tiles away from the outside of the edge
local BARRIER_SIZE = 20                 -- 20x20 barrier entity
local BARRIER_OVERLAP = 1              -- 1 tile overlap between barriers
local BARRIER_SPACING = BARRIER_SIZE - BARRIER_OVERLAP  -- 19 tiles between barrier centers

-- Create barriers along an edge
local function create_edge_barriers(edge_id, edge)
	local edge_target = edge_util.edge_get_local_target(edge)
	if not edge_target then
		return
	end

	local surface = game.surfaces[edge_target.surface]
	if not surface then
		return
	end
	-- Calculate barrier length (110% of edge length)
	local barrier_length = math.ceil(edge.length * 1.10)
	local num_barriers = math.ceil(barrier_length / BARRIER_SPACING)
	-- Calculate starting position offset to center the barriers
	local start_offset = (edge.length - barrier_length) / 2
	-- Calculate the perpendicular direction for barrier placement
	local edge_direction = edge_target.direction
	local dir_vec = vectorutil.dir_to_vec(edge_direction)
	-- Initialize barrier storage for this edge if it doesn't exist
	if not storage.universal_edges.barriers then
		storage.universal_edges.barriers = {}
	end
	storage.universal_edges.barriers[edge_id] = {}

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
		-- Create the barrier entity
		local barrier = surface.create_entity{
			name = "ue_world_barrier",
			position = world_pos,
			raise_built = false
		}
		if barrier then
			barrier.destructible = false  -- Make completely indestructible
			-- Store reference to the barrier
			table.insert(storage.universal_edges.barriers[edge_id], barrier)
		else
			log("Failed to create barrier at world position " .. world_pos[1] .. ", " .. world_pos[2] .. " for edge " .. edge_id)
		end
	end
end

-- Remove all barriers for an edge
local function remove_edge_barriers(edge_id)
	if not storage.universal_edges.barriers or not storage.universal_edges.barriers[edge_id] then
		return
	end

	for _, barrier in ipairs(storage.universal_edges.barriers[edge_id]) do
		if barrier and barrier.valid then
			barrier.destroy()
		end
	end

	storage.universal_edges.barriers[edge_id] = nil
	log("Removed all barriers for edge " .. edge_id)
end

-- Update barriers when an edge changes
local function update_edge_barriers(edge_id, edge)
	-- Remove existing barriers
	remove_edge_barriers(edge_id)
	-- Create new barriers if edge is active
	if edge and edge.active then
		create_edge_barriers(edge_id, edge)
	end
end

barrier_manager.create_edge_barriers = create_edge_barriers
barrier_manager.remove_edge_barriers = remove_edge_barriers
barrier_manager.update_edge_barriers = update_edge_barriers

return barrier_manager
