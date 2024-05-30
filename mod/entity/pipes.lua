--[[
	Create pipe entities used for fluid connections
]]

-- Generate horizontal and vertical pipe
local vertical = table.deepcopy(data.raw["pipe"]["pipe"])
vertical.name = "edge_pipe_vertical"
vertical.fluid_box = {
	base_area = 250,
	height = 2,
	pipe_connections = {
		{
			position = {
				0,
				-1
			}
		},
		{
			position = {
				0,
				1
			}
		},
	}
}
local vertical_item = {
	icon = "__base__/graphics/icons/pipe.png",
	icon_mipmaps = 4,
	icon_size = 64,
	name = "vertical_pipe",
	order = "a[pipe]-a[pipe]",
	place_result = "edge_pipe_vertical",
	stack_size = 100,
	subgroup = "energy-pipe-distribution",
	type = "item"
}

local horizontal = table.deepcopy(data.raw["pipe"]["pipe"])
horizontal.name = "edge_pipe_horizontal"
horizontal.fluid_box = {
	base_area = 250,
	height = 2,
	pipe_connections = {
		{
			position = {
				1,
				0
			}
		},
		{
			position = {
				-1,
				0
			}
		}
	}
}
local horizontal_item = {
	icon = "__base__/graphics/icons/pipe.png",
	icon_mipmaps = 4,
	icon_size = 64,
	name = "horizontal_pipe",
	order = "a[pipe]-a[pipe]",
	place_result = "edge_pipe_horizontal",
	stack_size = 100,
	subgroup = "energy-pipe-distribution",
	type = "item"
}

log("Adding pipes")

data:extend { vertical, vertical_item, horizontal, horizontal_item }
