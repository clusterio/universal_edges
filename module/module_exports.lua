-- The shared runtime's Lua API for other modules: require("modules/universal_edges"). Register at load time.
local bridge = require("modules/universal_edges/runtime/bridge")
local migrations = require("modules/universal_edges/runtime/migrations")
local scheduler = require("modules/universal_edges/runtime/scheduler")
local trace = require("modules/universal_edges/runtime/trace")
local edges = require("modules/universal_edges/edges/edges")
local connectors = require("modules/universal_edges/edges/connectors")
local hooks = require("modules/universal_edges/transports/hooks")

return {
	api_version = 1,
	runtime = {
		scheduler = { periodic = scheduler.periodic, iterate = scheduler.iterate, queue = scheduler.queue, once = scheduler.once },
		bridge = { channel = bridge.channel, on = bridge.on },
		trace = { new_id = trace.new_id, started = trace.started },
		migrations = { register = migrations.register },
	},
	-- SP1a (SP1 spec §7.3), additive, so api_version stays 1: read-only edge views, the geometry, UE ownership.
	edges = { get = edges.get, list = edges.list, frame = edges.frame },
	geometry = require("modules/universal_edges/edges/geometry_core"),
	-- SP1b (§7.3, §10): connector types for transports, and ownership of the entities their endpoints own.
	connectors = { register_type = connectors.register_type },
	owns = connectors.owns,
	transfers = { extend = hooks.extend }, -- SP3 (§11, F2)
	-- Player-crossing spec §7.1: a plugin's zones, ahead of UE's edges, and where its keys place a joining player.
	players = { zones = require("modules/universal_edges/transports/players").zones },
	-- vehicles.watch(entity) puts a car or spidertron on the crossing watch, as boarding it does, and clears a rejected
	-- mark, so any mod that steers vehicles by script can retry a refused crossing.
	vehicles = { watch = require("modules/universal_edges/transports/vehicle").watch },
	-- Cross-border biters (spec §6, §7): gridworld forms a raid and walks it; its locate hook names a hop's x (R6); and it
	-- passes on its raid and expansion toggles (owner, 2026-10-10).
	biters = {
		walk = require("modules/universal_edges/transports/biters").walk,
		on_locate = require("modules/universal_edges/transports/biters").on_locate,
		set_enabled = require("modules/universal_edges/transports/biters").set_enabled,
	},
	-- SP3b (SP3 spec §12.9): a read-only view of a train connector's box, for SP4.
	trains = { get = require("modules/universal_edges/transports/train").get },
}
