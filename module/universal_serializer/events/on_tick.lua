local LuaEntity_deserialize = require("modules/universal_edges/universal_serializer/classes/LuaEntity_deserialize")

local TRAIN_TYPES = {
	["cargo-wagon"] = true,
	["locomotive"] = true,
	["artillery-wagon"] = true,
	["fluid-wagon"] = true
}

local function on_tick()
	-- Iterate backwards so table.remove doesn't skip entries
	local delayed_entities = storage.universal_edges.delayed_entities
	local i = 1
	while i <= #delayed_entities do
		local delayed_entity = delayed_entities[i]
		if not TRAIN_TYPES[delayed_entity.type] then
			log("universal_edges: undefined delayed entity type: " .. delayed_entity.type)
			table.remove(delayed_entities, i)
		else
			local front_stock = delayed_entity.front_stock
			if not (front_stock and front_stock.valid) then
				-- Train no longer exists, discard orphaned delayed entity
				table.remove(delayed_entities, i)
			else
				-- Save train state before connecting a new carriage resets it
				local manual_mode = front_stock.train.manual_mode
				local speed = front_stock.train.speed
				local schedule = front_stock.train.schedule

				delayed_entity.position = get_position_behind_train(front_stock, 7)
				local created_entity = LuaEntity_deserialize(delayed_entity)
				if created_entity then
					front_stock.train.manual_mode = manual_mode
					front_stock.train.schedule = schedule
					front_stock.train.speed = speed
					-- Re-seat driver if this carriage had one
					if delayed_entity.driver_name then
						storage.universal_edges.vehicle_drivers[delayed_entity.driver_name] = created_entity
					end
					table.remove(delayed_entities, i)
				else
					break -- No space yet, try again next tick
				end
			end
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
