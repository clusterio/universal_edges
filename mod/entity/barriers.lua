--[[
	Create collision barrier entities to prevent players from venturing past an edge
]]

-- Create a 20x20 collision entity that will act as a world barrier
local collision_barrier = {
	type = "simple-entity",
	name = "ue_world_barrier", 
	icon = "__base__/graphics/icons/assembling-machine-1.png",
	icon_size = 64,
	icon_mipmaps = 4,
	flags = {
		"placeable-neutral",
		"not-on-map",
		"not-blueprintable",
		"not-deconstructable",
		"not-upgradable",
		"not-flammable",
		"no-automated-item-removal",
		"no-automated-item-insertion"
	},
	collision_mask = {
		layers = {
			["object"] = true,
			["player"] = true
		},
		not_colliding_with_itself = true
	},
	max_health = 10000,
	collision_box = {{-10, -10}, {10, 10}}, -- 20x20 collision box
	selection_box = {{-10, -10}, {10, 10}}, -- 20x20 selection box
	selectable_in_game = false, -- Make not visible for testing
}

data:extend { collision_barrier }
