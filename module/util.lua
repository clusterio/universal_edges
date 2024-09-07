local is_transport_belt = {
	["transport-belt"] = true,
	["fast-transport-belt"] = true,
    ["express-transport-belt"] = true,
	["tungsten-transport-belt"] = true,
}

local is_pipe = {
	["pipe"] = true,
	["pump"] = true,
}

local belt_type_to_loader_type = {
	["transport-belt"] = "loader",
	["fast-transport-belt"] = "fast-loader",
	["express-transport-belt"] = "express-loader",
	["tungsten-transport-belt"] = "tungsten-loader",
}

local function realign_area(posa, posb)
	-- Create box between 2 points where left_top is in the left top and right_bottom is in the right bottom
	-- Smaller number = higher
	-- Smaller number = further left
	return {
		left_top = {
			math.min(posa[1], posb[1]),
			math.min(posa[2], posb[2]),
		},
		right_bottom = {
			math.max(posa[1], posb[1]),
			math.max(posa[2], posb[2]),
		}
	}
end

return {
	is_transport_belt = is_transport_belt,
	is_pipe = is_pipe,
	belt_type_to_loader_type = belt_type_to_loader_type,
	realign_area = realign_area,
}
