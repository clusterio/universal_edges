
local tungsten_loader = table.deepcopy(data.raw["loader"]["express-loader"])

tungsten_loader.name = "tungsten-loader"
tungsten_loader.speed = 0.125

local tungsten_loader_item = table.deepcopy(data.raw["item"]["express-loader"])
tungsten_loader_item.name = "tungsten-loader"
tungsten_loader_item.place_result = "tungsten-loader"

data:extend { tungsten_loader, tungsten_loader_item }
