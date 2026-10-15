-- Ids of the shared runtime (spec §7.2): "<boot id>.<seq>", minted only after this run's startup handshake.
local core = require("modules/universal_edges/runtime/trace_core")

local trace = {}

--- True once this run's handshake has set a boot id.
function trace.started()
	local s = storage.universal_edges
	return s ~= nil and s.rt.boot_id ~= nil
end

--- A new trace or message id; errors before the handshake.
function trace.new_id()
	return core.new_id(storage.universal_edges.rt)
end

return trace
