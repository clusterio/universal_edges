local t = require("modules/v2_test/testlib")
local clusterio_api = require("modules/clusterio/api")
local runtime = require("modules/universal_edges").runtime
-- after_batch isn't part of the public runtime API (it's framework-internal, F8), so reached directly, as other
-- SP1b game tests already reach into universal_edges' own modules (e.g. edges/lanes.lua, edges/connectors.lua).
local bridge = require("modules/universal_edges/runtime/bridge")
local bridge_core = require("modules/universal_edges/runtime/bridge_core")

-- Tasks register at load, as every plugin's must. These record into locals, which is fine in a single-process
-- test run; real modules keep their state in storage.
local ran = { periodic = {}, walked = {}, queued = {}, once = {} }
local walk_source = { a = 1, b = 2, c = 3 }
runtime.scheduler.periodic{
	name = "test.periodic", interval = 50,
	fn = function(tick) ran.periodic[#ran.periodic + 1] = tick end,
}
runtime.scheduler.iterate{
	name = "test.iterate", per_tick = 2, source = function() return walk_source end,
	fn = function(key) ran.walked[#ran.walked + 1] = key end,
}
local queue = runtime.scheduler.queue{
	name = "test.queue", cap = 2, ttl_ticks = 600, per_tick = 1,
	fn = function(item) ran.queued[#ran.queued + 1] = item end,
}
local later = runtime.scheduler.once{
	name = "test.once", cap = 4, per_tick = 4,
	fn = function(args, tick) ran.once[#ran.once + 1] = { args.n, tick } end,
}
local send = runtime.bridge.channel("universal_edges")
runtime.bridge.on("universal_edges", "test.throw", function()
	error("boom from a test handler")
end)
local raise_after_batch = false
bridge.after_batch("universal_edges", function()
	if raise_after_batch then
		raise_after_batch = false
		error("boom from a test after_batch hook")
	end
end)

local function handshake(boot_id)
	ue_rt.startup(helpers.table_to_json({ boot_id = boot_id, instance_id = 4242, instance_name = "v2-test" }))
end

t.case("the runtime starts: storage is migrated and the hello carries the handshake's boot id", function(ctx)
	ctx.at(1, function()
		local s = storage.universal_edges
		ctx.expect(s.schema == 11, "universal_edges storage at schema 11 (the biters' tables)")
		ctx.expect(s.rt.boot_id == "7e570000", "boot id from the harness's handshake")
	end)
	ctx.expect_ipc("universal_edges:out", '"type":"runtime.hello"')
	ctx.expect_ipc("universal_edges:out", '"boot_id":"7e570000"')
end)

t.case("the scheduler runs each kind of task within its limits and reports its counters", function(ctx)
	ctx.at(2, function()
		ctx.expect(queue.push("first"), "first push accepted")
		ctx.expect(queue.push("second"), "second push accepted")
		ctx.expect(not queue.push("third"), "a push beyond cap 2 is dropped")
		ctx.expect(later.schedule(10, { n = 7 }), "once scheduled")
	end)
	ctx.at(199, function()
		ctx.expect(#ran.periodic == 4, "every 50 ticks: 4 runs in ticks 0-199, got " .. #ran.periodic)
		for i = 2, #ran.periodic do
			ctx.expect(ran.periodic[i] - ran.periodic[i - 1] == 50, "periodic keeps its interval")
		end
		local walked = {}
		for _, key in ipairs(ran.walked) do
			walked[key] = true
		end
		ctx.expect(walked.a and walked.b and walked.c, "iterate reached every key")
		ctx.expect(#ran.queued == 2 and ran.queued[1] == "first" and ran.queued[2] == "second", "the queue is FIFO")
		ctx.expect(#ran.once == 1 and ran.once[1][1] == 7 and ran.once[1][2] == 12, "once ran at tick 12 with its args")
	end)
	ctx.expect_ipc("universal_edges:out", '"type":"runtime.stats"')
end)

-- About 12 x 470 bytes in one tick: over the 3500-byte soft limit, so the flush is split. A batch of 4000 bytes or
-- more would go through Clusterio's file path, which writes nothing in benchmark mode, and fail the whole run.
t.case("one tick's messages beyond the soft limit leave as several IPC lines, all of them", function(ctx)
	ctx.at(5, function()
		for i = 1, 12 do
			send("test.bulk", { mark = "bulk:" .. i .. ":", pad = string.rep("x", 400) })
		end
	end)
	for i = 1, 12 do
		ctx.expect_ipc("universal_edges:out", "bulk:" .. i .. ":")
	end
end)

t.case("ping and the inbox: phases go out; repeats and malformed input are counted, never run", function(ctx)
	ctx.at(3, function()
		local trace_id = ue_rt.ping(4242)
		ctx.expect(string.find(trace_id, "^7e570000%.%d+$") ~= nil, "a trace id from this boot: " .. trace_id)
		local ping = { id = "0000abcd.1", type = "ue.ping", payload = { trace = "0000abcd.9", kind = "ping", from = 99 } }
		ue_rt.inbox("universal_edges", helpers.table_to_json({
			ping,
			ping,
			{ id = "0000abcd.2", type = "ue.ping", payload = { trace = "0000abcd.10", kind = "pong", from = 99 } },
		}))
		ue_rt.inbox("universal_edges", "{not json")
		ue_rt.inbox("universal_edges", helpers.table_to_json({ { id = "0000abcd.3", type = "ue.ping", payload = { kind = "ping" } } }))
		local counters = storage.universal_edges.stats["ue.bridge"]
		ctx.expect(counters.repeats == 1, "the repeated id was dropped")
		ctx.expect(counters.rejects == 2, "bad JSON and a payload without a trace were rejected")
	end)
	ctx.expect_ipc("universal_edges:out", '"phase":"start"')
	ctx.expect_ipc("universal_edges:out", '"phase":"received"')
	ctx.expect_ipc("universal_edges:out", '"kind":"pong"')
	ctx.expect_ipc("universal_edges:out", '"phase":"done"')
end)

t.case("a second handshake re-runs migrations without wiping anything", function(ctx)
	ctx.at(20, function()
		storage.universal_edges.test_marker = "kept"
		handshake("7e570001")
		local s = storage.universal_edges
		ctx.expect(s.test_marker == "kept", "state survived the migrations")
		ctx.expect(s.schema == 11 and s.rt.boot_id == "7e570001" and s.rt.seq == 0, "a new boot, the same schema")
	end)
end)

t.case("a server startup forgets the boot id: nothing mints ids or leaves until the next handshake", function(ctx)
	ctx.at(3900, function()
		script.raise_event(clusterio_api.events.on_server_startup, {})
		ctx.expect(storage.universal_edges.rt.boot_id == nil, "boot id forgotten")
		ctx.expect(not pcall(ue_rt.ping, 4242), "no ping before the handshake")
		local stats = storage.universal_edges.stats
		local rejects = stats["ue.bridge"] and stats["ue.bridge"].rejects or 0
		ue_rt.inbox("universal_edges", helpers.table_to_json({
			{ id = "0000abcd.7", type = "ue.ping", payload = { trace = "0000abcd.70", kind = "ping", from = 1 } },
		}))
		ctx.expect(stats["ue.bridge"].rejects == rejects + 1, "an inbound batch before the handshake is refused")
		send("test.after_restart", { mark = "held-until-handshake" })
	end)
	ctx.at(3905, function()
		local held = false
		for _, msg in ipairs(storage.universal_edges.bridge.out.universal_edges) do
			held = held or msg.type == "test.after_restart"
		end
		ctx.expect(held, "the message waited in storage")
		handshake("7e570002")
	end)
	ctx.expect_ipc("universal_edges:out", "held-until-handshake")
end)

t.case("flush_every = 0 does not silently stop the bridge from flushing", function(ctx)
	ctx.at(9, function()
		storage.universal_edges.bridge.flush_every = 0
		send("test.zero_flush_every", { mark = "zero-flush-every-still-sent" })
	end)
	ctx.expect_ipc("universal_edges:out", "zero-flush-every-still-sent")
end)

t.case("a nil soft_limit does not crash the flush", function(ctx)
	ctx.at(11, function()
		storage.universal_edges.bridge.flush_every = 1
		storage.universal_edges.bridge.soft_limit = nil
		send("test.nil_soft_limit", { mark = "nil-soft-limit-still-sent" })
	end)
	ctx.expect_ipc("universal_edges:out", "nil-soft-limit-still-sent")
end)

t.case("an unencodable payload is dropped and counted; the rest of the batch still flushes", function(ctx)
	ctx.at(13, function()
		send("test.unencodable", { fn = function() end })
		send("test.after_unencodable", { mark = "flushed-after-unencodable" })
	end)
	ctx.at(15, function()
		local counters = storage.universal_edges.stats["ue.bridge"]
		ctx.expect(counters.invalid == 1, "the unencodable payload was counted as invalid, got " .. tostring(counters.invalid))
	end)
	ctx.expect_ipc("universal_edges:out", "flushed-after-unencodable")
	ctx.expect_ipc("universal_edges:out", '"phase":"invalid"')
end)

t.case("inbound handler errors are counted and traced; unknown types are only counted", function(ctx)
	ctx.at(17, function()
		ue_rt.inbox("universal_edges", helpers.table_to_json({
			{ id = "0bad0001.1", type = "test.throw", payload = {} },
			{ id = "0bad0001.2", type = "test.never_registered", payload = {} },
		}))
		local counters = storage.universal_edges.stats["ue.bridge"]
		ctx.expect(counters.errors == 1, "the throwing handler was counted as an error, got " .. tostring(counters.errors))
		ctx.expect(counters.unknown == 1, "the unregistered type was counted as unknown, got " .. tostring(counters.unknown))
	end)
	ctx.expect_ipc("universal_edges:out", '"phase":"handler_error"')
end)

t.case("an after-batch hook's error is counted and traced, like a handler's (F8)", function(ctx)
	ctx.at(19, function()
		local stats = storage.universal_edges.stats["ue.bridge"]
		stats.errors = nil -- isolate this case's count from any other bridge error in the same stats window
		raise_after_batch = true
		ue_rt.inbox("universal_edges", helpers.table_to_json({}))
		ctx.expect(not raise_after_batch, "the hook ran (and reset its own flag)")
		ctx.expect(stats.errors == 1, "the after-batch hook's error was counted, got " .. tostring(stats.errors))
	end)
	ctx.expect_ipc("universal_edges:out", '"phase":"after_batch_error"')
end)

local function same(a, b)
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
	end
	for k, v in pairs(a) do
		if not same(v, b[k]) then
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

t.case("a flush's batch line, built from each message's own JSON, decodes as send_json's encoding of the batch (I3)",
	function(ctx)
		ctx.at(21, function()
			local msgs = {
				{ id = "7e570000.901", type = "test.a", payload = { n = 1.25, s = 'q"uo\\te', list = { 1, 2, 3 }, empty = {} } },
				{ id = "7e570000.902", type = "test.b", payload = { nested = { k = { true, false } }, big = 1e15 } },
			}
			local parts = {}
			for i, m in ipairs(msgs) do
				parts[i] = helpers.table_to_json(m)
			end
			local line = helpers.json_to_table(bridge_core.batch(game.tick, parts))
			local before = helpers.json_to_table(helpers.table_to_json({ tick = game.tick, msgs = msgs }))
			ctx.expect(line ~= nil and same(line, before), "the same { tick, msgs } as send_json's own encoding")
		end)
	end)
