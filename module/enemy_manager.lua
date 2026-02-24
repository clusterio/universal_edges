
local edge_util = require("modules/universal_edges/edge/util")
local vectorutil = require("modules/universal_edges/vectorutil")

local enemy_manager = {}

-- Determine the play area based on the 'box' created by the edges
---@return BoundingBox | nil
enemy_manager.get_play_area = function(surface)
    local min_x, min_y = math.huge, math.huge
    local max_x, max_y = -math.huge, -math.huge
    local surface_name = surface.name
    local edge_count = 0
    -- Collect all edge endpoints from active edges on this instance
    for _, edge in pairs(storage.universal_edges.edges) do
		local local_target = edge_util.edge_get_local_target(edge)
		if local_target then
			if surface_name ~= local_target.surface then
				goto continue -- Skip edges on different surfaces
			end
			local origin = local_target.origin
			local direction = local_target.direction
			local length = edge.length or 2
			-- Calculate both endpoints of the edge
			local dir_vec = vectorutil.dir_to_vec(direction)
			local end_pos = vectorutil.vec2_add(origin, vectorutil.vec2_smul(dir_vec, length))
			-- Expand bounding box to include both points
			min_x = math.min(min_x, origin[1], end_pos[1])
			min_y = math.min(min_y, origin[2], end_pos[2])
			max_x = math.max(max_x, origin[1], end_pos[1])
			max_y = math.max(max_y, origin[2], end_pos[2])
			edge_count = edge_count + 1
		end
        ::continue::
    end
    -- Need at least 2 edges to define a meaningful play area
    if edge_count < 2 or not surface_name then
        return
    end
    return {
        left_top = {min_x, min_y},
        right_bottom = {max_x, max_y}
    }
end

---Check for enemies within the play area defined by the edges on the given surface
---@param surface any
---@return boolean
enemy_manager.check_for_enemies = function(surface)
	local play_area = enemy_manager.get_play_area(surface)
	if not play_area then
		game.print("FATAL: Unable to determine play area on surface: " .. surface.name .. ". Enemies will not be disabled.")
		return false
	end
	local enemies = surface.find_entities_filtered{
		area = {play_area.left_top, play_area.right_bottom},
		type = "unit-spawner",
		force = "enemy"
	}
	return #enemies == 0
end

---Disable all enemies on the given surface
---@param surface LuaSurface
enemy_manager.disable_enemies = function(surface)
	for _, enemy in pairs(surface.find_entities_filtered{force = "enemy"}) do
		enemy.destroy()
	end
	local mgs = surface.map_gen_settings
	mgs.autoplace_controls["enemy-base"].size = "none"
	surface.map_gen_settings = mgs
end

--- Periodically check for enemies and disable them if none are found in the play area
script.on_nth_tick(36000, function()
	for _, surface in pairs(game.surfaces) do
		if not storage.universal_edges.enemy_checks_disabled[surface.name] then
			local no_enemies = enemy_manager.check_for_enemies(surface)
			if no_enemies then
				enemy_manager.disable_enemies(surface)
				storage.universal_edges.enemy_checks_disabled[surface.name] = true -- Stop checking after disabling enemies
			end
		end
	end
end)

return enemy_manager
