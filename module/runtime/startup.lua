-- The startup handshake and the runtime's reports to the instance plugin (spec §7.5): hello, heartbeats, counters.
local bridge = require("modules/universal_edges/runtime/bridge")
local migrations = require("modules/universal_edges/runtime/migrations")
local scheduler = require("modules/universal_edges/runtime/scheduler")

local startup = {}
local send = bridge.channel("universal_edges")

migrations.register("universal_edges", require("modules/universal_edges/runtime/schema_core"))

function startup.on_init()
	migrations.run_all()
end

--- Clusterio raises this on the first tick after each (re)patch, which is every server start. A restored save still
--- holds the previous run's boot id and seq, so they are forgotten: nothing mints an id, and nothing leaves the
--- bridge, until this run's handshake.
function startup.on_server_startup()
	migrations.run_all()
	storage.universal_edges.rt.boot_id = nil
end

--- /sc ue_rt.startup("<json>") from the instance plugin's start hook: record the boot id, migrate, and say hello.
function startup.startup(json)
	local args = type(json) == "string" and helpers.json_to_table(json) or nil
	if type(args) ~= "table" or type(args.boot_id) ~= "string" or not string.find(args.boot_id, "^%x%x%x%x%x%x%x%x$") then
		error("ue_rt.startup needs JSON with an 8-hex-digit boot_id")
	end
	migrations.run_all()
	local rt = storage.universal_edges.rt
	rt.boot_id = args.boot_id
	rt.seq = 0
	send("runtime.hello", { boot_id = rt.boot_id, tick = game.tick, schemas = migrations.schemas() })
end

scheduler.periodic{
	name = "ue.heartbeat",
	interval = 600,
	fn = function(tick)
		if storage.universal_edges.rt.boot_id then
			send("runtime.heartbeat", { tick = tick })
		end
	end,
}

--- Every 3600 ticks, the counters since the last report go to the instance plugin (Prometheus, and warnings).
scheduler.periodic{
	name = "ue.stats",
	interval = 3600,
	fn = function()
		local s = storage.universal_edges
		if next(s.stats) ~= nil then
			send("runtime.stats", { tasks = s.stats })
			-- A new table, not a clear: the queued message keeps the old one, which still takes this tick's counts.
			s.stats = {}
		end
	end,
}

return startup
