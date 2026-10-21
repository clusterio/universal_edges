-- The connector framework (SP1 spec §10): the type registry, one endpoint per connector on each side, one poll task per
-- type, pcall containment (G6), limbo files and UE ownership (G8). lanes.lua owns the endpoints' lifecycle and wire, and
-- sets connectors.visit, which each type's poll task calls.
local bridge = require("modules/universal_edges/runtime/bridge")
local bridge_core = require("modules/universal_edges/runtime/bridge_core")
local geometry = require("modules/universal_edges/edges/geometry_core")
local marks = require("modules/universal_edges/edges/marks")
local scheduler = require("modules/universal_edges/runtime/scheduler")
local trace = require("modules/universal_edges/runtime/trace")

local connectors = { BLOCKED_RETRY = 600, ASK_THROTTLE = 3600 }
local send = bridge.channel("universal_edges")
local types = {}
connectors.types = types

--- The endpoint methods transports call (§10.2); lanes.lua adds can_send, send and pending. The metatable is
--- registered, so storage keeps each endpoint's link to it across save and load.
local methods = {}
connectors.methods = methods
local Endpoint = { __index = methods }
script.register_metatable("universal_edges.endpoint", Endpoint)

local function count(kind)
	local stats = storage.universal_edges.stats
	stats["ue.connectors"] = stats["ue.connectors"] or {}
	bridge_core.count(stats["ue.connectors"], kind)
end

--- A ue.connector lifecycle event for ep (§13).
local function event(ep, phase, level, fields)
	fields.op, fields.phase, fields.level, fields.tick = "ue.connector", phase, level, game.tick
	fields.edge, fields.cid, fields.type = ep.edge, ep.cid, ep.type
	fields.trace = fields.trace or ep.trace
	send("trace", fields)
end

local function positive_integer(v)
	return type(v) == "number" and v >= 1 and v == math.floor(v)
end

--- ue.connectors.register_type{ ... } at load (§10.1): the type, and its poll task ue.poll.<name> over eps[name]. A type
--- with builtin = "<cid>" gets an endpoint of that cid on every live side, outside the controller's record (F7: the
--- vehicle's "v", the biters' "b", gridworld's "p"; cross-border biters plan Task 2).
function connectors.register_type(spec)
	if game then
		error("register connector types while loading, not at runtime")
	end
	if type(spec) ~= "table" or type(spec.name) ~= "string" or types[spec.name] then
		error("a connector type needs a name that isn't registered yet")
	end
	for _, hook in ipairs({ "lanes", "build", "teardown", "poll" }) do
		if type(spec[hook]) ~= "function" then
			error("connector type " .. spec.name .. " needs a " .. hook .. " function")
		end
	end
	local schedule = spec.schedule
	if type(schedule) ~= "table" or not positive_integer(schedule.per_tick) or not positive_integer(schedule.interval) then
		error("connector type " .. spec.name .. " needs schedule = { per_tick, interval }, positive integers")
	end
	if spec.builtin ~= nil and type(spec.builtin) ~= "string" then
		error("connector type " .. spec.name .. "'s builtin must be a cid string")
	end
	types[spec.name] = spec
	local name = spec.name
	scheduler.iterate{
		name = "ue.poll." .. name,
		per_tick = schedule.per_tick,
		interval = schedule.interval,
		source = function()
			local s = storage.universal_edges
			return s and s.eps and s.eps[name]
		end,
		fn = function(_, ep, tick)
			connectors.visit(ep, tick)
		end,
	}
end

--- An edge event (sync, update, activation) wakes every type's poll walk from its rest, and so does connectors.fail;
--- an ep message wakes its endpoint's type only when the partner's state changed, and an ordinary lane message (ack,
--- offer, close, done, …) wakes nothing — its own lane is visited inline instead, in the same batch (D39 perf item 1;
--- SP1b final review I1; SP3 spec §4.2, §17 risk 3).
function connectors.wake(type_name)
	if type_name then
		scheduler.wake("ue.poll." .. type_name)
		return
	end
	for name in pairs(types) do
		scheduler.wake("ue.poll." .. name)
	end
end

--- The endpoint for connector c of side, registered in eps[c.type] and side.eps, PENDING (§5.4). Its dirs are the
--- type's lanes(params). A type that isn't registered, or params its validate refuses, get no endpoint: that logs
--- ue.connector failed at error, and the next apply of the edge tries again.
function connectors.create(side, c)
	local t = types[c.type]
	local problem, dirs
	if not t then
		problem = "no connector type " .. c.type .. " is registered"
	elseif t.validate then
		local ok, good, reason = pcall(t.validate, c.params)
		if not ok then
			problem = tostring(good)
		elseif not good then
			problem = tostring(reason or "invalid params")
		end
	end
	if not problem then
		local ok, result = pcall(t.lanes, c.params)
		if not ok or type(result) ~= "table" then
			problem = "lanes: " .. tostring(result)
		else
			dirs = {}
			for dir, kind in pairs(result) do
				if (dir ~= "ab" and dir ~= "ba") or (kind ~= "stream" and kind ~= "ordered" and kind ~= "unique") then
					problem = "lanes: " .. tostring(dir) .. " = " .. tostring(kind)
						.. " is not ab|ba = stream|ordered|unique"
				end
				dirs[dir] = kind
			end
		end
	end
	if problem then
		count("rejects")
		send("trace", { op = "ue.connector", phase = "failed", level = "error", tick = game.tick, trace = side.trace,
			edge = side.id, cid = c.cid, type = c.type, hook = "create", error = problem })
		return nil
	end
	local mine = side[side.me]
	local ep = setmetatable({
		key = side.id .. "/" .. c.cid, edge = side.id, cid = c.cid, type = c.type, params = c.params, me = side.me,
		col = geometry.col(side.me, side.length, c.pos, c.width), width = c.width, dirs = dirs,
		frame = { surface_index = side.surface_index, origin = { mine.origin[1], mine.origin[2] }, facing = mine.facing,
			length = side.length },
		state = "pending", data = {}, tx = {}, rx = {}, trace = side.trace, next_build = 0, builtin = t.builtin == c.cid or nil,
	}, Endpoint)
	local s = storage.universal_edges
	s.eps[c.type] = s.eps[c.type] or {}
	s.eps[c.type][ep.key] = ep
	side.eps[c.cid] = c.type
	marks.connector_created(side, ep)
	return ep
end

--- side's endpoint for cid, or nil.
function connectors.get(side, cid)
	local type_name = side.eps[cid]
	local registry = type_name and storage.universal_edges.eps[type_name]
	return registry and registry[side.id .. "/" .. cid]
end

--- Run a transport hook under pcall (G6). An error is logged at error; a live endpoint becomes failed, and its next
--- visit tells the partner, whose lanes then stop. Returns ok and the hook's result.
function connectors.call(ep, hook, ...)
	local fn = types[ep.type] and types[ep.type][hook]
	if not fn then
		return false, "no " .. hook .. " hook"
	end
	local ok, result = pcall(fn, ep, ...)
	if not ok then
		connectors.fail(ep, hook, result)
	end
	return ok, result
end

function connectors.fail(ep, hook, err)
	count("errors")
	event(ep, "failed", "error", { hook = hook, error = tostring(err) })
	if not ep.closing and ep.state ~= "failed" then
		ep.state, ep.announce = "failed", true
		connectors.wake()
	end
end

--- G1: build runs from the poll task on the endpoint's first visit, and every 600 ticks while it is blocked.
function connectors.build(ep, tick)
	-- M1/M9: set before the hook runs, so a build that raises part-way still counts — teardown must still run the
	-- type's hook for it (below), to match this function's own doc comment, "teardown runs once, if build ever ran".
	ep.built = true
	local ok, result = connectors.call(ep, "build")
	if not ok then
		return
	end
	local was = ep.state
	ep.state = result == "ready" and "ready" or "blocked"
	ep.next_build = tick + connectors.BLOCKED_RETRY
	if ep.state ~= was then
		ep.announce = true
		if ep.state == "ready" then
			event(ep, "built", "verbose", {})
		else
			event(ep, "blocked", "warn", {})
		end
	end
end

--- G1: teardown runs once, if build ever ran, and the endpoint's owned entities stop being UE's.
function connectors.teardown(ep)
	if ep.torn_down then
		return
	end
	ep.torn_down = true
	-- M1/M9: `or ep.state ~= "pending"` covers endpoints built before ep.built existed. Without ep.built, a failed
	-- endpoint that reconcile resets to "pending" (lanes.lua) skips this hook if it closes before its next build
	-- visit, leaving its owned entities unminable for good (teardown still clears ownership below either way).
	if ep.built or ep.state ~= "pending" then
		connectors.call(ep, "teardown")
	end
	local owned = storage.universal_edges.owned
	for _, unit_number in ipairs(ep.owned or {}) do
		owned[unit_number] = nil
	end
	ep.owned = nil
end

--- Forget the endpoint: it leaves the poll task's registry and its side.
function connectors.remove(ep, side)
	connectors.teardown(ep)
	marks.connector_removed(side, ep)
	storage.universal_edges.eps[ep.type][ep.key] = nil
	side.eps[ep.cid] = nil
end

--- G6: a payload that refund or restore couldn't place is appended, as one JSON line, to
--- script-output/universal_edges/limbo/<trace or lane>.txt (the server's copy only, in multiplayer). Returns the file
--- name, which the error event carries.
function connectors.limbo(ep, dir, hook, payload, trace_id)
	local stem = string.gsub(trace_id or (ep.key .. "-" .. dir), "[^%w%.%-]", "_")
	local name = "universal_edges/limbo/" .. stem .. ".txt"
	local line = helpers.table_to_json({ edge = ep.edge, cid = ep.cid, dir = dir, hook = hook, trace = trace_id,
		tick = game.tick, payload = payload })
	helpers.write_file(name, line .. "\n", true, game.is_multiplayer() and 0 or nil)
	return name
end

--- G8: UE's own "ue-" entities, and every entity an endpoint registered with ep:own.
function connectors.owns(entity)
	if not entity.valid then
		return false
	end
	if string.sub(entity.name, 1, 3) == "ue-" then
		return true
	end
	local unit_number = entity.unit_number
	return unit_number ~= nil and storage.universal_edges.owned[unit_number] ~= nil
end

-- The endpoint API (§10.2) --------------------------------------------------------------------------------------------

--- ep:set_status(tbl): the latest small status for the partner, sent on the next visit and never queued twice.
function methods.set_status(ep, status)
	if type(status) ~= "table" then
		error("ep:set_status needs a table")
	end
	ep.status, ep.status_dirty = status, true
end

--- ep:ask_partner(ticks?): ask the partner to send its ep again — its full status, for a type with full_status (FC5) —
--- at most once per ticks (default ASK_THROTTLE, 3600; the circuit type passes 120, K17). False when throttled.
function methods.ask_partner(ep, ticks)
	local tick = game.tick
	if ep.asked and tick - ep.asked < (ticks or connectors.ASK_THROTTLE) then
		return false
	end
	ep.asked, ep.ask = tick, true
	return true
end

--- ep:own(entity): the entity is UE's until teardown (G8). It needs a unit_number.
function methods.own(ep, entity)
	if not (entity and entity.valid and entity.unit_number) then
		error("ep:own needs a valid entity with a unit_number")
	end
	storage.universal_edges.owned[entity.unit_number] = ep.key
	ep.owned = ep.owned or {}
	ep.owned[#ep.owned + 1] = entity.unit_number
end

--- ep:request_removal(reason): ask the controller to remove this connector (a ConnectorChangeRequest, lanes.ts).
function methods.request_removal(ep, reason)
	send("ue.connector.remove", { edge = ep.edge, cid = ep.cid, reason = tostring(reason or ""), trace = trace.new_id() })
end

return connectors
