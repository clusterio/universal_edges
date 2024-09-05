--[[
	Create pipe entities used for fluid connections
]]

-- Generate horizontal and vertical pipe
local vertical = table.deepcopy(data.raw["pipe"]["pipe"])
vertical.name = "edge_pipe_vertical"
vertical.fluid_box = {
	volume = 500,
	pipe_connections = {
		{ direction = defines.direction.north, position = { 0, 0 } },
		{ direction = defines.direction.south, position = { 0, 0 } },
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
	volume = 500,
	pipe_connections = {
		{ direction = defines.direction.east, position = { 0, 0 } },
		{ direction = defines.direction.west, position = { 0, 0 } }
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
