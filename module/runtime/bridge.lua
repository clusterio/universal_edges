-- The message bridge between this instance's Lua and its plugins' TypeScript (spec §7.3).
-- Outbound: channel(plugin) queues in storage; flush sends one "<plugin>:out" batch per tick, split under the soft
-- limit. Inbound: the instance plugin calls ue_rt.inbox, and handlers registered by type at load take the messages.
local clusterio_api = require("modules/clusterio/api")
local core = require("modules/universal_edges/runtime/bridge_core")
local trace_core = require("modules/universal_edges/runtime/trace_core")

local bridge = {}
local handlers = {}

local function counters()
	local stats = storage.universal_edges.stats
	stats["ue.bridge"] = stats["ue.bridge"] or {}
	return stats["ue.bridge"]
end

--- send(type, payload) on plugin's channel. A full queue drops the message and counts it.
function bridge.channel(plugin)
	return function(msg_type, payload)
		local b = storage.universal_edges.bridge
		b.out[plugin] = b.out[plugin] or {}
		if not core.enqueue(b.out[plugin], msg_type, payload, b.out_cap) then
			core.count(counters(), "drops")
		end
	end
end

--- Register fn(payload) for inbound msg_type messages to plugin, at load. fn returns false to reject a bad payload.
function bridge.on(plugin, msg_type, fn)
	if game then
		error("register bridge handlers while loading, not at runtime")
	end
	handlers[plugin] = handlers[plugin] or {}
	handlers[plugin][msg_type] = fn
end

local afters = {}
--- Register fn() to run once after each inbox batch for plugin, at load (SP3 F8). An error is counted, not raised.
function bridge.after_batch(plugin, fn)
	if game then
		error("register bridge hooks while loading, not at runtime")
	end
	afters[plugin] = afters[plugin] or {}
	table.insert(afters[plugin], fn)
end

-- ponytail: each message is JSON-encoded once, here, and its batch line is that JSON joined (bridge_core.batch) and
-- printed with Clusterio's IPC framing exactly as send_json prints a line under 4000 bytes (modules/clusterio/api.lua
-- at Clusterio 2efb53aa: print("\f$ipc:" .. channel .. "?j" .. data)). send_json would encode the whole batch again;
-- the bench priced that as the largest belt cost (final review I3). This couples flush to the pinned framing: on a
-- Clusterio upgrade, re-check api.lua's prefix, its channel escaping ([\x00-\x1f?\\], which leaves "<plugin>:out" for
-- our plugin names unchanged) and its 4000-byte cut-over to the file path, and match them here. A line of 4000 bytes
-- or more (one message over the soft limit) still goes through send_json, which writes it to a file.
local IPC_LIMIT = 4000

--- End of the tick: mint ids and send each channel in as few IPC lines as the soft limit allows.
--- Nothing leaves before the handshake; the queue waits in storage. The limit is capped at 3900 regardless of
--- the storage setting, to keep every batch under Clusterio's 4000-byte stdout path (spec §7.3, Global Constraints).
function bridge.flush(tick)
	local s = storage.universal_edges
	if not (s and s.rt.boot_id) then
		return
	end
	-- Operator settings come straight from storage (schema_core.lua's comment), so a typo must not wedge or
	-- crash the bridge: flush_every clamps to at least 1; soft_limit clamps to at most 3900 (unset falls back
	-- to 3500 first, same as flush_every, but an operator-set 0 or negative number is not a fix this covers).
	local flush_every = math.max(1, tonumber(s.bridge.flush_every) or 1)
	if tick % flush_every ~= 0 then
		return
	end
	local soft_limit = math.min(tonumber(s.bridge.soft_limit) or 3500, 3900)
	for plugin, msgs in pairs(s.bridge.out) do
		if #msgs > 0 then
			s.bridge.out[plugin] = {}
			local good, json = {}, {}
			for _, msg in ipairs(msgs) do
				msg.id = trace_core.new_id(s.rt)
				-- An unencodable payload (e.g. a function value) must not lose the rest of the batch, or the tick.
				local ok, encoded = pcall(helpers.table_to_json, msg)
				if ok then
					good[#good + 1] = msg
					json[msg] = encoded
				else
					core.count(counters(), "invalid")
					bridge.channel(plugin)("trace", {
						op = "ue.bridge", phase = "invalid", level = "error", type = msg.type, error = tostring(encoded),
					})
				end
			end
			local channel = plugin .. ":out"
			for _, batch in ipairs(core.split(good, function(msg) return #json[msg] end, soft_limit)) do
				local parts = {}
				for i, msg in ipairs(batch) do
					parts[i] = json[msg]
				end
				local data = core.batch(tick, parts)
				if #data < IPC_LIMIT then
					print("\f$ipc:" .. channel .. "?j" .. data)
				else
					clusterio_api.send_json(channel, { tick = tick, msgs = batch })
				end
			end
		end
	end
end

--- ue_rt.inbox(plugin, json): untrusted input. Malformed messages, repeats and unknown types are counted, never run.
--- A handler is run through pcall: accept() has already marked the batch as seen, so a handler that errors must
--- not silently drop the rest of the batch.
function bridge.inbox(plugin, json)
	local s = storage.universal_edges
	local stats = counters()
	if not s.rt.boot_id then
		core.count(stats, "rejects")
		return
	end
	local batch = type(json) == "string" and helpers.json_to_table(json) or nil
	for _, msg in ipairs(core.accept(batch, s.bridge.seen, game.tick, stats)) do
		local fn = handlers[plugin] and handlers[plugin][msg.type]
		if not fn then
			core.count(stats, "unknown")
		else
			local ok, result = pcall(fn, msg.payload)
			if not ok then
				core.count(stats, "errors")
				-- One detailed trace per stats window (stats.errors resets to nil with the rest of s.stats every
				-- 3600 ticks in startup.lua's ue.stats task): a handler that keeps failing must not flood the log.
				-- The window's full count still reaches the instance plugin via runtime.stats regardless.
				if stats.errors == 1 then
					bridge.channel(plugin)("trace", {
						op = "ue.bridge", phase = "handler_error", level = "error", type = msg.type, error = tostring(result),
					})
				end
			elseif result == false then
				core.count(stats, "rejects")
			end
		end
	end
	for _, fn in ipairs(afters[plugin] or {}) do
		local ok, err = pcall(fn)
		if not ok then
			core.count(stats, "errors")
			-- Same one-trace-per-stats-window rule as a handler's error, just above.
			if stats.errors == 1 then
				bridge.channel(plugin)("trace", {
					op = "ue.bridge", phase = "after_batch_error", level = "error", error = tostring(err),
				})
			end
		end
	end
end

return bridge
