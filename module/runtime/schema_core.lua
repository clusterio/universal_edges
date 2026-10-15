-- Universal Edges' storage migrations (spec §7.4): list[i] upgrades storage.universal_edges from schema i - 1 to i.
-- State shapes are final for new worlds (owner, 2026-10-14); a live world is upgraded outside the plugins,
-- with throwaway one-time commands at deploy. Operators tune the runtime through this state:
--   /sc storage.universal_edges.scheduler.cap = 500        (work units per tick; nil, the default, is off)
--   /sc storage.universal_edges.bridge.soft_limit = 3500   (bytes per send_json)
--   /sc storage.universal_edges.bridge.flush_every = 1     (ticks between flushes)
--   /sc storage.universal_edges.stream_trace = true        (D12: one ue.transfer line per stream offer, per phase; also
--                                                          one ue.routing table line per routing report)
return {
	-- 1: the shared runtime. rt.boot_id stays unset until a startup handshake.
	function(state)
		state.rt = { seq = 0 }
		state.scheduler = { tasks = {} }
		state.stats = {}
		state.bridge = { out = {}, seen = {}, soft_limit = 3500, out_cap = 1000, flush_every = 1 }
	end,
	-- 2 (SP1a): this instance's side of each edge, the per-surface index and the barrier index (SP1 spec §5.3).
	function(state)
		state.edges = {}
		state.by_surface = {}
		state.barriers = {}
	end,
	-- 3 (SP1b): the connector endpoints by type, the entities they own, and D12's stream debug switch (SP1 spec §5.3).
	function(state)
		state.eps = {}
		state.owned = {}
		state.stream_trace = false
		for _, side in pairs(state.edges) do
			side.eps = side.eps or {}
		end
	end,
	-- 4 (SP3a; player-crossing spec 2026-10-13): players' pending crossings, the arrivals waiting for a body and hook
	-- failures' log times (the arrival record is the controller's); the vehicle watch, rejected vehicles, and the seats
	-- waiting for riders by unit number, vehicles and carriages alike (§6.4).
	function(state)
		state.players = { pending = {}, placing = {}, hook_failed = {} }
		state.watch = {}
		state.rejected = {}
		state.waiting = {}
	end,
	-- 5 (visuals batch, 2026-10-04): edge marks' render object ids, per side (marks[id] = { line objects }) and per
	-- connector (marks[id].c[cid] = arrow object id). Render objects persist across save and load on their own.
	function(state)
		state.marks = {}
	end,
	-- 6 (circuit link, FC6): the circuit endpoints with injector slots still to write, ep.key → endpoint. In storage, not a
	-- file-local: a joining player's Lua must write what the server writes (circuit-link spec §5.2, §7.4).
	function(state)
		state.circuit_writing = {}
	end,
	-- 7 (SP4, spec §4.3): train routing moves in from the router prototype's storage.router (D42), or starts empty. Pure
	-- apart from reading and clearing that global (the prototype's table sits beside this one): the work that needs game
	-- (deleting edge stops, stripping records) is flagged by strip and runs in routing/tables.lua (§5.4). goals and errs
	-- are plan ruling 5: the cost walk's goal list (§7.8) and R7's once-per-3600-ticks record.
	function(state)
		-- luacheck: globals storage
		local old = storage.router or {}
		state.routing = {
			live = false, -- the controller's first ue.route.resync sets it (R5)
			active = old.active or {}, -- [trace] = { trace, anchor, unit, dest, hops, hop?, held?, unrouted, captured?, manual?, reask? }
			by_unit = old.by_unit or {}, -- [anchor carriage unit] = trace
			reserved = old.reserved or {}, -- [trace] = the train stop holding that route's reservation (D43)
			waiting = {}, -- [carriage unit] = true: trains for check() (§6.1)
			starts = {}, goals = {}, last = {}, -- the cost walk's starts and goals, and the rows last sent (§7.8); no d: rows (R3)
			conns = {}, -- [connector key] = the row last sent
			stops = {}, fast = {}, -- D17's registry and its circuit tier (§7.7)
			list = {}, -- the station list, list[surface][name], for the panel (R35)
			search = { tick = 0, n = 0, max = 0 }, -- path searches per tick (§8.2)
			errs = {}, -- [task] = the tick its last failure was logged (R7)
			dirty = true, full = true,
			strip = true, -- the edge-stop strip is still to run (§5.4)
		}
		storage.router = nil
	end,
	-- 8 (power link, spike 22): the power endpoints with a send's debt still to pay out of their pool, ep.key → endpoint.
	-- In storage, as circuit_writing is: the drain task runs in every Lua state.
	function(state)
		state.power_debt = {}
	end,
	-- 9 (train group sync, sync spec §4): the cluster's groups and interrupts as this tile last heard them
	-- (cache[kind][name] = { v, content }); what this tile last applied, reported or read of each name it holds
	-- (hash[kind][name] = { h, t }: the canonical content and the tick it was recorded, plan ruling 3); the names whose
	-- report awaits its answer (pending, plan ruling 4); the trains whose schedule changed (dirty, by train id). The sweep
	-- adds walk (while one runs) and sent (the counts last sent). The controller's first ue.sched.full sets live.
	function(state)
		state.schedules = {
			live = false,
			cache = { group = {}, interrupt = {} },
			hash = { group = {}, interrupt = {} },
			pending = { group = {}, interrupt = {} },
			dirty = {},
		}
	end,
	-- 10 (radar sync, plan 2026-10-07): the tile's radar hosts, key → host (radar-sync spec §4). A host's writes queue in
	-- the circuit link's circuit_writing (plan ruling 2).
	function(state)
		state.radar = { hosts = {} }
	end,
	-- 11 (cross-border biters plan, Task 2): built-in endpoints carry a mark (connectors.register_type's builtin), so
	-- lanes and marks stop naming "v"; and the biters' tables (cross-border biters spec §6): groups walking to a crossing
	-- by their unique_id, each live side's oracle and the target it last named, by edge id.
	function(state)
		for _, registry in pairs(state.eps or {}) do
			for _, ep in pairs(registry) do
				if ep.cid == "v" then
					ep.builtin = true
				end
			end
		end
		state.biters = { walking = {}, oracles = {}, targets = {} }
	end,
}
