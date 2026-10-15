-- Extension hooks (SP3 spec §11, D16, D22): a plugin rides a unique transport's crossing without a framework change.
-- ue.transfers.extend{...} registers a hook set at load; ep:materialized (F2) runs every registered hook under pcall.
local bridge = require("modules/universal_edges/runtime/bridge")
local connectors = require("modules/universal_edges/edges/connectors")

local hooks = { extensions = {} }
local send = bridge.channel("universal_edges")

--- hooks.extend(spec) (§11): spec = { name, types = { [type] = true }, capture?(ep, handle) → data,
--- materialized?(ep, handle, data, meta), restored?(ep, handle, why) }. At load only; raises at runtime,
--- on a missing name or types, or a name
--- already registered.
function hooks.extend(spec)
	if game then
		error("register extension hooks while loading, not at runtime")
	end
	if type(spec) ~= "table" or type(spec.name) ~= "string" or type(spec.types) ~= "table" then
		error("an extension needs a name and types = { [type] = true }")
	end
	for _, x in ipairs(hooks.extensions) do
		if x.name == spec.name then
			error("extension " .. spec.name .. " is already registered")
		end
	end
	hooks.extensions[#hooks.extensions + 1] = spec
end

--- The ue.transfer ext_failed line (either hook): an extension's error never fails the crossing.
local function failed(ep, plugin, hook, err)
	send("trace", { op = "ue.transfer", phase = "ext_failed", level = "error", tick = game.tick, trace = ep.trace,
		edge = ep.edge, cid = ep.cid, plugin = plugin, hook = hook, error = tostring(err) })
end

--- hooks.capture(ep, handle) → ext | nil (F2): every extension whose types[ep.type] and capture are set, under pcall;
--- a result that isn't nil goes to ext[name]. An error logs ue.transfer ext_failed and leaves that data out.
function hooks.capture(ep, handle)
	local ext
	for _, x in ipairs(hooks.extensions) do
		if x.types[ep.type] and x.capture then
			local ok, result = pcall(x.capture, ep, handle)
			if ok then
				if result ~= nil then
					ext = ext or {}
					ext[x.name] = result
				end
			else
				failed(ep, x.name, "capture", result)
			end
		end
	end
	return ext
end

--- hooks.restored(ep, handle, why) (SP4 §7.5): every extension's restored hook, under pcall, when UE gives a captured
--- train back to this side: why = "reject" (the destination refused it), "too_big" (F4) or "close" (the lane closed).
--- An error logs ue.transfer ext_failed, hook = "restored", and never stops the restore.
function hooks.restored(ep, handle, why)
	for _, x in ipairs(hooks.extensions) do
		if x.types[ep.type] and x.restored then
			local ok, err = pcall(x.restored, ep, handle, why)
			if not ok then
				failed(ep, x.name, "restored", err)
			end
		end
	end
end

--- ep:materialized(dir, handle, ext, meta) (F2): each extension's hook under pcall, then ue.transfer materialized under
--- the crossing's trace.
function connectors.methods.materialized(ep, dir, handle, ext, meta)
	for _, x in ipairs(hooks.extensions) do
		if x.types[ep.type] and x.materialized then
			local ok, err = pcall(x.materialized, ep, handle, ext and ext[x.name], meta)
			if not ok then
				failed(ep, x.name, "materialized", err) -- the ext_failed line, hook = "materialized"
			end
		end
	end
	send("trace", { op = "ue.transfer", phase = "materialized", level = "info", tick = game.tick, trace = meta.trace,
		edge = ep.edge, cid = ep.cid, dir = dir, seq = meta.seq })
end

return hooks
