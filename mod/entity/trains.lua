--[[
	To make trains path properly across multiple worlds we need to ensure that there is a sufficiently large pathfinding penalty for crossing a non-optimal number of edges.
	Factorio does not let us create custom penalties for the train pathfinder, but we can adjust the default penalties.
	The penalty that is least likely to screw with our users in-world pathing is the one for circuit disabled signals.
	
	We increase the circuit disabled signal penalty to 100k and place one circuit disabled signal for each edge the path has to cross to reach the destination trainstop.
]]

-- Defaults to 1000
data.raw["utility-constants"]["default"].train_path_finding["signal_reserved_by_circuit_network_penalty"] = 100000

-- We create our own train-stop prototypes to be able to differentiate between normal train-stops, source connector trainstops and proxy trainstops placed at the source connector.

local source_trainstop = table.deepcopy(data.raw["train-stop"]["train-stop"])
source_trainstop.name = "ue_source_trainstop"

local proxy_trainstop = table.deepcopy(data.raw["train-stop"]["train-stop"])
proxy_trainstop.name = "ue_proxy_trainstop"
proxy_trainstop.chart_name = false -- Prevent from showing up on map, just overlaps anyways

log("Adding trainstops")

data:extend { source_trainstop, proxy_trainstop }
