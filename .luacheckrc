-- "pure" Lua runs on plain Lua 5.2 (unit tests); everything under module/ and test/game/ runs inside Factorio.
std = "lua52"
max_line_length = 140
exclude_files = { "**/node_modules/**", "**/dist/**" }
stds.factorio = {
	-- storage is the one Factorio global our code writes: each plugin owns storage[<plugin name>].
	globals = { "storage" },
	read_globals = {
		"game", "script", "defines", "helpers", "prototypes", "settings", "remote",
		"commands", "rendering", "rcon", "log", "serpent", "table_size", "localised_print",
		"clusterio_private",
	},
}
files["**/module/**/*.lua"] = { std = "lua52+factorio" }
files["**/module/**/*_core.lua"] = { std = "lua52" }
files["**/test/game/**/*.lua"] = { std = "lua52+factorio", read_globals = { "ue_rt" } }
-- The biters run's cases (cross-border biters plan ruling R10), like the plugins run's.
files["**/test/biters/**/*.lua"] = { std = "lua52+factorio", read_globals = { "ue_rt" } }
-- The shared runtime's RCON entry point is the one global a module defines.
files["module/globals.lua"] = { globals = { "ue_rt" } }
-- The data stage of UE's Factorio mod (SP1 spec §9) reads Factorio's data global and, in data-final-fixes (SP3a §5.4),
-- patches another mod's prototype in data.raw; luacheck's bare "data" shorthand is read-only at any depth, so data.raw
-- itself is spelled out as mutable (its own mutation of data.raw.<type>.<name>.<field> isn't itself type-checked).
files["mod/**/*.lua"] = { read_globals = { "defines", table = { fields = { "deepcopy" } },
	data = { other_fields = true, fields = { raw = { other_fields = true, read_only = false } } } } }
