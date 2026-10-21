-- SP4 routing's shared pieces (spec §4.1): the routing state, trace lines on UE's own bridge channel, the guards on
-- events and tasks (§4.3, R7), every path search, counted (§8.2), message parts (§7.9, R9), and UE's train endpoints as
-- routing sees them. Routing is UE's own code: it reads UE's endpoint storage directly.
local bridge = require("modules/universal_edges/runtime/bridge")
local bridge_core = require("modules/universal_edges/runtime/bridge_core")
local geometry = require("modules/universal_edges/edges/geometry_core")
local train = require("modules/universal_edges/transports/train")
-- Box lengths only (fix round 2): train.get's rails/end_rail are only trustworthy once the box is this long.
local train_core = require("modules/universal_edges/transports/train_core")

local base = {}
base.send = bridge.channel("universal_edges")
--- Every routing message's JSON stays within this many bytes (§7.9): UE's stdout line is 4000, less the batch framing.
base.BUDGET = 3000

--- storage.universal_edges.routing, or nil before UE's migration 7 has run (U7: a train event on the first tick after a
--- patch can come before Clusterio's on_server_startup).
function base.state()
	local s = storage.universal_edges
	return s and s.routing
end

--- One lifecycle line (SP3 §14): { op, phase, level, trace, tick, … } on the bridge as "trace".
function base.emit(op, phase, level, trace, fields)
	fields = fields or {}
	fields.op, fields.phase, fields.level, fields.trace, fields.tick = op, phase, level, trace, game.tick
	base.send("trace", fields)
end

--- An event handler that runs only once routing is live (§4.3's guard, R5).
function base.guard(fn)
	return function(e)
		local r = base.state()
		if r and r.live then
			fn(e)
		end
	end
end

local WINDOW = 3600

--- A task body under pcall (R7): a raise logs ue.routing failed at error, at most once per 3600 ticks per task, and never
--- reaches UE's on_tick (the scheduler itself doesn't pcall).
function base.safe(name, fn)
	return function(...)
		local ok, err = pcall(fn, ...)
		if ok then
			return err
		end
		local r, tick = base.state(), game.tick
		if r and tick - (r.errs[name] or -WINDOW) >= WINDOW then
			r.errs[name] = tick
			base.emit("ue.routing", "failed", "error", nil, { task = name, error = tostring(err) })
		end
	end
end

--- request_train_path, counted (§8.2): routing.search holds this tick's count (n) and the most in any tick (max), and
--- stats["ue.routing"].searches reaches Prometheus with UE's other counters every 3600 ticks.
function base.path(args)
	local r, tick = base.state(), game.tick
	local c = r.search
	if c.tick ~= tick then
		c.tick, c.n = tick, 0
	end
	c.n = c.n + 1
	if c.n > c.max then
		c.max = c.n
	end
	local stats = storage.universal_edges.stats
	local mine = stats["ue.routing"] or {}
	stats["ue.routing"] = mine
	mine.searches = (mine.searches or 0) + 1
	return game.train_manager.request_train_path(args)
end

--- Two flat rows hold the same fields and values (rows are kept as tables, plan ruling 14).
function base.same(a, b)
	if a == nil or b == nil then
		return a == b
	end
	for k, v in pairs(a) do
		if b[k] ~= v then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function json_size(row)
	return #helpers.table_to_json(row)
end

--- rows as messages { [field] = chunk }, each within BUDGET bytes of JSON (R9: UE's own packer); none for no rows. size
--- is a row's JSON size (default: encode it; pass one for scalars, which table_to_json doesn't take).
function base.parts(field, rows, size)
	local envelope = #helpers.table_to_json({ [field] = { 0 } })
	local out = {}
	for _, chunk in ipairs(bridge_core.split(rows, size or json_size, base.BUDGET - envelope)) do
		out[#out + 1] = { [field] = chunk }
	end
	return out
end

--- The defines.rail_direction of rail whose end faces world direction compass (spike 8's end_dir).
function base.end_dir(rail, compass)
	for _, d in pairs(defines.rail_direction) do
		if rail.get_rail_end(d).location.direction == compass then
			return d
		end
	end
end

local function endpoint(key)
	local eps = storage.universal_edges.eps.train
	return eps and eps[key]
end

--- A connector a train can cross now: the edge active, both endpoints built (UE's can_send and partner test).
function base.live(edge, cid)
	local side = storage.universal_edges.edges[edge]
	local ep = endpoint(edge .. "/" .. cid)
	return side ~= nil and side.active == true and ep ~= nil and ep.state == "ready" and not ep.closing
		and ep.partner ~= nil and ep.partner.state == "ready"
end

--- true once every one of a box's rails is placed and still valid (fix round 2): a stalled build leaves train.get
--- returning a short or empty rails list, not nil.
local function fully_built(rails, n)
	if #rails ~= n then
		return false
	end
	for _, rail in ipairs(rails) do
		if not rail.valid then
			return false
		end
	end
	return true
end

--- Every train endpoint here (§7.8): { key, edge, cid, box, surface, start?, goal?, state }. surface: its edge side's
--- surface index (R33). start = { rail, direction, surface }: an inbound box's innermost rail, heading inward. goal =
--- { rail, dir }: an outbound box's end rail and its outward end, on both layers (§5). Entities and numbers only: a
--- LuaRailEnd is made per call, never stored (R10). state: the ConnState row. A box whose build stalled gets neither
--- start nor goal, and is reported live = false.
function base.connectors()
	local out = {}
	for key, ep in pairs(storage.universal_edges.eps.train or {}) do
		local v = train.get(ep.edge, ep.cid)
		if v then
			local d = ep.data
			local n = v.box == "inbound" and train_core.IN_RAILS or train_core.OUT_RAILS
			local built = fully_built(v.rails, n)
			local live = built and base.live(ep.edge, ep.cid)
			local c = { key = key, edge = ep.edge, cid = ep.cid, box = v.box, surface = ep.frame.surface_index }
			if v.box == "inbound" then
				if built then
					local rail = v.rails[1]
					c.start = { rail = rail, direction = base.end_dir(rail, geometry.dir_to_world(ep.frame, 8)), surface = c.surface }
				end
				c.state = { key = key, box = "inbound", live = live, ready = d.st_ready == true,
					queued = d.queue and (#d.queue.carriages - d.queue.next + 1) or 0 }
			else
				if built then
					c.goal = { rail = v.end_rail, dir = base.end_dir(v.end_rail, geometry.dir_to_world(ep.frame, 0)) }
				end
				local st = ep.partner and ep.partner.status
				c.state = { key = key, box = "outbound", live = live, ready = type(st) == "table" and st.ready == true,
					held = d.waiting ~= nil and d.waiting.valid, inflight = d.held ~= nil }
			end
			out[#out + 1] = c
		end
	end
	return out
end

--- The path goal for a stored goal, { stop } or { rail, dir }; nil once its entity is gone, or its stop on no rail.
function base.goal(g)
	if g.stop then
		return g.stop.valid and g.stop.connected_rail and g.stop or nil
	end
	return g.rail.valid and g.rail.get_rail_end(g.dir) or nil
end

return base
