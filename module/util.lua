local is_transport_belt = {
	["transport-belt"] = true,
	["fast-transport-belt"] = true,
	["express-transport-belt"] = true,
}

local belt_type_to_loader_type = {
	["transport-belt"] = "loader",
	["fast-transport-belt"] = "fast-loader",
	["express-transport-belt"] = "express-loader",
}

return {
	is_transport_belt,
	belt_type_to_loader_type,
}
