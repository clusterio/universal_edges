--[[
	To make trains path properly across multiple worlds we need to ensure that there is a sufficiently large pathfinding penalty for crossing a non-optimal number of edges.
	Factorio does not let us create custom penalties for the train pathfinder, but we can adjust the default penalties.
	The penalty that is least likely to screw with our users in-world pathing is the one for circuit disabled signals.
	
	We increase the circuit disabled signal penalty to 100k and place one circuit disabled signal for each edge the path has to cross to reach the destination trainstop.
]]

-- Defaults to 1000
data.raw["utility-constants"]["default"].train_path_finding["signal_reserved_by_circuit_network_penalty"] = 100000
