return {
	hooks = require("modules/universal_edges/universal_serializer/hooks"),
	events = {
		on_nth_tick_15 = require("events/on_tick"),
	},
	LuaEntity = {
		serialize = require("classes/LuaEntity_serialize"),
		deserialize = require("classes/LuaEntity_deserialize"),
	},
	-- Only metadata, not entities
	LuaTrain = {
		serialize = require("classes/LuaTrain_serialize"),
		deserialize = require("classes/LuaTrain_deserialize"),
	},
	-- Includes rolling stock
	LuaTrainComplete = {
		serialize = require("classes/LuaTrainComplete_serialize"),
		deserialize = require("classes/LuaTrainComplete_deserialize"),
	}
}
