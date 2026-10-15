-- Runs every plugin's storage migrations (spec §7.4). Each plugin owns storage[<plugin name>] and registers its list at
-- load; the runtime brings each table to its latest schema.
local core = require("modules/universal_edges/runtime/migrations_core")

local migrations = {}
local lists, order = {}, {}

--- Register plugin's list at load: list[i] upgrades storage[plugin] from schema i - 1 to i.
function migrations.register(plugin, list)
	if game then
		error("register migrations while loading, not at runtime")
	end
	if lists[plugin] then
		error("migrations for " .. plugin .. " are already registered")
	end
	lists[plugin] = list
	order[#order + 1] = plugin
end

--- Bring every registered table to its latest schema. It never wipes: a table newer than its code is an error.
function migrations.run_all()
	for _, plugin in ipairs(order) do
		storage[plugin] = core.run(storage[plugin] or { schema = 0 }, lists[plugin])
	end
end

--- { [plugin] = schema } for the hello.
function migrations.schemas()
	local schemas = {}
	for _, plugin in ipairs(order) do
		schemas[plugin] = storage[plugin].schema
	end
	return schemas
end

return migrations
