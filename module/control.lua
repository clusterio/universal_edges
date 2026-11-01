-- Universal Edges v2 module entry: the shared runtime's event handlers (spec §7).
local clusterio_api = require("modules/clusterio/api")
local bridge = require("modules/universal_edges/runtime/bridge")
local scheduler = require("modules/universal_edges/runtime/scheduler")
local startup = require("modules/universal_edges/runtime/startup")
local edges = require("modules/universal_edges/edges/edges")
require("modules/universal_edges/transports/hooks")
local vehicle = require("modules/universal_edges/transports/vehicle")
require("modules/universal_edges/transports/belt")
require("modules/universal_edges/transports/power")
require("modules/universal_edges/transports/fluid")
require("modules/universal_edges/transports/circuit")
local radar = require("modules/universal_edges/transports/radar")
local logistic = require("modules/universal_edges/transports/logistic")
local detect = require("modules/universal_edges/transports/detect")
local players = require("modules/universal_edges/transports/players")
local train = require("modules/universal_edges/transports/train")
local biters = require("modules/universal_edges/transports/biters")
local barriers = require("modules/universal_edges/edges/barriers")
local sync = require("modules/universal_edges/schedules/sync")
require("modules/universal_edges/runtime/ping")

local control = { events = {} }

-- A player's (or a robot's) build in a border row proposes a connector; a script-raised build does too (v1's set).
for _, name in ipairs({ "on_built_entity", "on_robot_built_entity", "script_raised_built", "script_raised_revive" }) do
	control.events[defines.events[name]] = function(e)
		detect.on_built(e)
		radar.on_built(e)
	end
end
control.events[defines.events.on_entity_cloned] = radar.on_built

control.on_init = startup.on_init
-- A start, crash or rollback: the runtime forgets its boot id (0B), then every edge side goes inactive (SP1 §6.2).
control.events[clusterio_api.events.on_server_startup] = function()
	startup.on_server_startup()
	edges.on_server_startup()
	players.away_all() -- crossing-arrival spec ruling 7: nobody is connected at a start, so everyone is away
	train.migrate() -- box shape 2 (owner 2026-10-05): old boxes rebuilt once; not in edges.lua (train requires it via players)
end

-- World barriers wait for their chunk, and wait again when it is deleted (SP1 spec §9).
control.events[defines.events.on_chunk_generated] = barriers.on_chunk_generated
control.events[defines.events.on_chunk_deleted] = barriers.on_chunk_deleted
-- S1 (surfaces spec §11): a side whose surface is made after its record takes it.
control.events[defines.events.on_surface_created] = edges.on_surface_created

-- Players crossing a border (player-crossing spec): a move into a zone, a departure, and a join.
control.events[defines.events.on_player_changed_position] = players.guarded(players.on_moved, "ue.player")
control.events[defines.events.on_player_left_game] = players.guarded(players.on_left, "ue.player")
control.events[defines.events.on_player_joined_game] = players.guarded(players.on_joined, "ue.player")
-- A respawn ends the arrival guard (crossing-arrival spec §5.1).
control.events[defines.events.on_player_respawned] = players.guarded(players.on_respawned, "ue.player")
-- §6.1: player_sync hands a joining player's character back; a waiting arrival places them again.
control.events[defines.events.on_player_controller_changed] = players.guarded(players.on_controller, "ue.player")

-- Vehicles crossing with their riders (SP3 spec §10): a driver change, and a spidertron remote's selection.
control.events[defines.events.on_player_driving_changed_state] = players.guarded(vehicle.on_driving, "ue.vehicle")
control.events[defines.events.on_cargo_pod_finished_descending] = players.guarded(players.on_pod_landed, "ue.player")
control.events[defines.events.on_player_used_spidertron_remote] = players.guarded(vehicle.on_remote, "ue.vehicle")
control.events[defines.events.on_player_cursor_stack_changed] = players.guarded(vehicle.on_cursor, "ue.vehicle")

-- Raids and parties walking to a crossing (cross-border biters spec §6.1): their go_to_location ends.
control.events[defines.events.on_ai_command_completed] = players.guarded(biters.on_command_completed, "ue.raid")
-- The oracle (spec §6.3): its group's target, and its units made indestructible.
control.events[defines.events.on_unit_group_finished_gathering] = players.guarded(biters.on_gathered, "ue.raid")
control.events[defines.events.on_entity_spawned] = players.guarded(biters.on_spawned, "ue.raid")

-- The logistic link (logistic-link spec §8.1, L19): who mined a link chest, so its partner's contents go to them.
control.events[defines.events.on_player_mined_entity] = players.guarded(logistic.on_mined, "ue.logistic")

-- The only per-tick handler of v2 code: the scheduler's tasks, then the bridge's flush. The flush sits outside the
-- scheduler, so a work cap can never hold messages back.
control.events[defines.events.on_tick] = function(event)
	scheduler.on_tick(event.tick)
	bridge.flush(event.tick)
end

-- Train group sync (sync spec §5.1): a changed schedule is read by the next tick's pass.
control.events[defines.events.on_train_schedule_changed] = sync.on_changed

-- SP4 routing (spec §4.1): its modules' events join UE's, each behind the latch (§4.3). Where UE handles the same event
-- (the four build events; the logistic link's on_player_mined_entity), UE's handler runs first, then routing's (plan
-- ruling 6).
local routing_base = require("modules/universal_edges/routing/base")
for _, feature in ipairs({
	require("modules/universal_edges/routing/stops"),
	require("modules/universal_edges/routing/routes"),
	require("modules/universal_edges/routing/panel"),
}) do
	for id, fn in pairs(feature.events) do
		local before, guarded = control.events[id], routing_base.guard(fn)
		control.events[id] = before and function(e)
			before(e)
			guarded(e)
		end or guarded
	end
end

return control
