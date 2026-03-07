local LuaEntity_deserialize = require("modules/universal_edges/universal_serializer/classes/LuaEntity_deserialize")

local function on_tick()
	-- Attempt to deserialize delayed entities
	local count = 0
	for k, delayed_entity in ipairs(storage.universal_edges.delayed_entities) do
		-- log("on_tick: attempting delayed entity deserialization for: " .. delayed_entity.name .. " of type " .. delayed_entity.type)
		-- update cargo-wagon position relative to train
		if delayed_entity.type == "cargo-wagon" or delayed_entity.type == "locomotive" then
			local locomotive_entity = delayed_entity.locomotive_entity
			if (locomotive_entity and locomotive_entity.valid) then
				local manual_mode = locomotive_entity.train.manual_mode
				local locomotive_entity_speed = locomotive_entity.train.speed
				local schedule = locomotive_entity.train.schedule
				-- modify position to be relative to train's back stock, with an offset of 7 tiles and account for train direction
				local offset = 7
				delayed_entity.position = get_position_behind_train(locomotive_entity, offset)
				local created_entity = LuaEntity_deserialize(delayed_entity)
				if created_entity then
					-- log("Successfully deserialized delayed entity: " .. created_entity.name)
					locomotive_entity.train.manual_mode = manual_mode
					locomotive_entity.train.schedule = schedule
					locomotive_entity.train.speed = locomotive_entity_speed
					-- log(serpent.block(storage.universal_edges.delayed_entities))
					table.remove(storage.universal_edges.delayed_entities, k)
					count = count + 1
					-- log("delayed entities spawn count: " .. count .. " remaining: " .. #storage.universal_edges.delayed_entities)
					break -- Only attempt to deserialize one entity per tick to avoid potential performance issues
				else
					-- log("unable to create entity for delayed deserialization, will try again next tick")
					break -- If deserialization fails, try again next tick
				end
			else
				-- log("FATAL: train does not exist!")
			end
		else
			log("gridworld: undefined delayed entity type: " .. delayed_entity.type)
		end
	end
end

---@param entity LuaEntity
---@param spacing number|nil -- optional, defaults to 7
---@return MapPosition|nil
function get_position_behind_train(entity, spacing)
    if not entity then return nil end
    if not entity.train.back_stock then return nil end

    local back_stock = entity.train.back_stock ---@cast back_stock -nil
    spacing = spacing or 7

    -- Convert orientation → unit vector
    local orientation = back_stock.orientation
    local angle = orientation * 2 * math.pi

    local dx = math.sin(angle)
    local dy = -math.cos(angle)

    -- Offset behind the last rolling stock
    local pos = {
        x = back_stock.position.x - dx * spacing,
        y = back_stock.position.y - dy * spacing
    }

    return pos
end


return on_tick
