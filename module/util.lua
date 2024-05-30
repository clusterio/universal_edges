local is_transport_belt = {
	["transport-belt"] = true,
	["fast-transport-belt"] = true,
	["express-transport-belt"] = true,
}

local is_pipe = {
	["pipe"] = true,
	["pump"] = true,
}

local belt_type_to_loader_type = {
	["transport-belt"] = "loader",
	["fast-transport-belt"] = "fast-loader",
	["express-transport-belt"] = "express-loader",
}

return {
	is_transport_belt = is_transport_belt,
	is_pipe = is_pipe,
	belt_type_to_loader_type = belt_type_to_loader_type,
}
