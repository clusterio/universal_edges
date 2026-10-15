-- The ping operation (spec §7.6): an end-to-end health check across two instances and the controller.
local bridge = require("modules/universal_edges/runtime/bridge")
local trace = require("modules/universal_edges/runtime/trace")

local ping = {}
local send = bridge.channel("universal_edges")

local function phase(trace_id, name, fields)
	fields.trace, fields.op, fields.phase, fields.tick = trace_id, "ue.ping", name, game.tick
	send("trace", fields)
end

--- ue_rt.ping(target instance id): start a ping and return its trace id. Errors before the handshake.
function ping.start(target)
	if type(target) ~= "number" then
		error("ue_rt.ping needs the target instance id")
	end
	local trace_id = trace.new_id()
	phase(trace_id, "start", { target = target })
	send("ue.ping", { trace = trace_id, kind = "ping", target = target })
	return trace_id
end

-- From the instance plugin: { trace, kind = "ping" | "pong", from }. A ping is answered with a pong to its sender.
bridge.on("universal_edges", "ue.ping", function(p)
	if type(p.trace) ~= "string" or type(p.from) ~= "number" or (p.kind ~= "ping" and p.kind ~= "pong") then
		return false
	end
	if p.kind == "ping" then
		phase(p.trace, "received", { from = p.from })
		send("ue.ping", { trace = p.trace, kind = "pong", target = p.from })
	else
		phase(p.trace, "done", { from = p.from })
	end
	return true
end)

return ping
