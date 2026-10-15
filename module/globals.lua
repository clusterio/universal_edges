-- The RCON entry point of the shared runtime (spec §7.3, §7.5, §7.6).
local bridge = require("modules/universal_edges/runtime/bridge")
local ping = require("modules/universal_edges/runtime/ping")
local startup = require("modules/universal_edges/runtime/startup")
local probe = require("modules/universal_edges/edges/probe")
local connectors = require("modules/universal_edges/edges/connectors")
local players = require("modules/universal_edges/transports/players")
local vehicle = require("modules/universal_edges/transports/vehicle")
local train_seams = require("modules/universal_edges/transports/train_seams")
local circuit_seams = require("modules/universal_edges/transports/circuit_seams")
local radar_seams = require("modules/universal_edges/transports/radar_seams")

ue_rt = {
	--- /sc ue_rt.startup("<json { boot_id, instance_id, instance_name }>"), from the instance plugin's start hook.
	startup = startup.startup,
	--- /sc ue_rt.inbox("<plugin>", "<json array of { id, type, payload }>"), the instance plugin's inbound batches.
	inbox = bridge.inbox,
	--- /sc rcon.print(ue_rt.ping(<target instance id>)) prints the trace id of a new ping.
	ping = ping.start,
	--- /sc ue_rt.probe_add("<edge>", "<cid>", <n> or '{"id":"t1","pad":8000}'): stock or a token for a probe (SP1 §10.6).
	probe_add = probe.add,
	--- /sc ue_rt.probe_set("<edge>", "<cid>", '{"busy":true}'): force a probe destination's busy or reject, or stop.
	probe_set = probe.set,
	--- /sc rcon.print(ue_rt.probe_state("<edge>", "<cid>")) prints a probe's tally and, while it lives, its ledger.
	probe_state = probe.state,
	--- /sc rcon.print(ue_rt.ep_stats("<edge>", "<cid>")): an endpoint's state, its partner's, and its transport's counters.
	ep_stats = function(edge, cid)
		local side = storage.universal_edges.edges[edge]
		local e = side and connectors.get(side, cid)
		if not e then
			return helpers.table_to_json({ gone = true })
		end
		return helpers.table_to_json({ state = e.state, partner = e.partner and e.partner.state, stats = e.data.stats })
	end,
	--- /sc ue_rt.watch(<unit number>): put a vehicle on the watch, as boarding it does (§10.2; tests and E2Es).
	watch = function(unit_number)
		vehicle.watch(game.get_entity_by_unit_number(unit_number))
	end,
	--- /sc rcon.print(ue_rt.player_move("<player>", "<surface>", x, y)): a move without a player (crossing spec §3);
	--- prints the pending crossing's trace after it, or nothing.
	player_move = function(name, surface, x, y)
		local s = game.get_surface(surface)
		players.moved(name, s.index, s.name, x, y)
		local p = storage.universal_edges.players.pending[name]
		return p and p.trace
	end,
	--- /sc rcon.print(ue_rt.player_left("<player>", "<surface>", x, y)): leaving the game there (§4 step 5); prints the
	--- trace of the leave sent, or nothing.
	player_left = function(name, surface, x, y)
		local s = game.get_surface(surface)
		return players.leave(name, s.index, s.name, x, y)
	end,
	--- /sc ue_rt.player_join("<player>", <character unit number>): the character stands in for the player joining (§6.1).
	player_join = function(name, unit_number)
		local s = storage.universal_edges.players
		s.stand_in = s.stand_in or {} -- ponytail: a test seam's table, created on first use; production never has it
		s.stand_in[name] = unit_number
		players.joined(name)
	end,
	--- /sc ue_rt.player_body("<player>", <old controller type>): the character handed back from that controller (§6.1).
	player_body = function(name, old_type)
		players.body(name, old_type)
	end,
	--- /sc rcon.print(ue_rt.train_test("track"|"add"|"state", "<edge>", "<cid>", '<json>')): the train seams (SP3 §15).
	train_test = train_seams.call,
	--- /sc rcon.print(ue_rt.routing_state()): SP4 routing on this tile (§4.5, the playtest): live; each route's dest, hop,
	--- unrouted, manual and captured; each reservation's stop unit (false once the stop is gone); how many (surface,
	--- name) entries the station list holds; and the most path searches routing made in one tick (§8.2).
	routing_state = function()
		local r = storage.universal_edges.routing
		local active, reserved, names = {}, {}, 0
		for trace, route in pairs(r.active) do
			active[trace] = { dest = route.dest, hop = route.hop and (route.hop.edge .. "/" .. route.hop.cid),
				unrouted = route.unrouted, manual = route.manual, captured = route.captured }
		end
		for trace, stop in pairs(r.reserved) do
			reserved[trace] = stop.valid and stop.unit_number or false
		end
		for _, by_name in pairs(r.list) do
			for _ in pairs(by_name) do
				names = names + 1
			end
		end
		return helpers.table_to_json({ live = r.live, active = active, reserved = reserved, stations = names,
			search = r.search.max })
	end,
	--- /sc rcon.print(ue_rt.circuit_test("own"|"read"|"drop"|"state", "<edge>", "<cid>", '<json>')): the circuit seams
	--- (circuit-link spec §13.5).
	circuit_test = circuit_seams.call,
	--- /sc rcon.print(ue_rt.radar_test("rig"|"read"|"clear"|"pole"|"wire"|"state", '<json>')): the radar seams
	--- (radar-sync spec §8).
	radar_test = radar_seams.call,
}
