return {
	events = {
		on_tick = require("events/on_tick"),
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
