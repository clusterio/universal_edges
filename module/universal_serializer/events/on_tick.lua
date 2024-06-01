local LuaEntity_deserialize = require("modules/universal_edges/universal_serializer/classes/LuaEntity_deserialize")

local function on_tick()
	if global.universal_edges.delayed_entities_tick ~= nil
		and global.universal_edges.delayed_entities_tick <= game.tick
		and #(global.universal_edges.delayed_entities or {}) > 0
	then
		-- Attempt to deserialize delayed entities
		for i = #global.universal_edges.delayed_entities, 1, -1 do
			local entity = global.universal_edges.delayed_entities[i]
			LuaEntity_deserialize(entity, true)
			table.remove(global.universal_edges.delayed_entities, i)
		end
	end
end

return on_tick
