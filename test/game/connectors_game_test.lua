local t = require("modules/v2_test/testlib")
-- Factorio allows require only while the file loads, never inside a step.
local ue = require("modules/universal_edges")
local connectors = require("modules/universal_edges/edges/connectors")

--- The built-in endpoints' cids (connectors.register_type's builtin): v, and the biters' b and gridworld's p when loaded.
local function builtins()
	local n = 0
	for _, ty in pairs(connectors.types) do
		if ty.builtin then
			n = n + 1
		end
	end
	return n
end

--- Whether every endpoint of eps is built in, and there is at least one.
local function only_builtins(eps)
	for cid, type_name in pairs(eps) do -- side.eps maps a cid to its type's name
		if connectors.types[type_name].builtin ~= cid then
			return false
		end
	end
	return next(eps) ~= nil
end

-- The partner and the controller are scripted: TS → Lua messages go straight to ue_rt.inbox. What Lua sends from a
-- message handler waits in the bridge's outbound queue until the next tick's flush, so a step can read it back; what
-- the poll task sends is flushed in the same tick, so ctx.expect_ipc checks it instead.
-- Every case uses ue.edge.update, never a sync: a sync is authoritative for the whole instance and would drop the
-- other cases' sides. Each case has its own edge, and the edges' endpoints share the type's poll task.
local seq = 0
local function deliver(msg_type, payload)
	seq = seq + 1
	local batch = { { id = "0000c0e0." .. seq, type = msg_type, payload = payload } }
	ue_rt.inbox("universal_edges", helpers.table_to_json(batch))
end

-- Activation needs this boot's sync (SP1a C1: storage.synced_boot). An empty sync, after SP1a's cases (ticks 2-70)
-- and before this file's (from 100): a sync drops every side it doesn't list, and at this tick there are none.
t.case("connectors: this file's sync", function(ctx)
	ctx.at(90, function()
		deliver("ue.edge.sync", { edges = {} })
		local s = storage.universal_edges
		ctx.expect(s.synced_boot == s.rt.boot_id, "synced under this boot")
	end)
end)

local function queued(msg_type)
	local found = {}
	for _, msg in ipairs(storage.universal_edges.bridge.out.universal_edges or {}) do
		if msg.type == msg_type then
			found[#found + 1] = msg.payload
		end
	end
	return found
end

local function traced(phase, edge)
	local found = {}
	for _, p in ipairs(queued("trace")) do
		if p.phase == phase and p.edge == edge then
			found[#found + 1] = p
		end
	end
	return found
end

-- The test connector type: its hooks record into these locals (fine in one test process; real types use storage).
-- params.fail names a hook whose first call raises (a connector's params never change under one cid, so a retry
-- after a reconfiguration runs with the same params); params.block makes build return "blocked".
local calls = { build = {}, teardown = {}, poll = {} }
local function record(hook, ep)
	local list = calls[hook]
	list[ep.key] = list[ep.key] or {}
	table.insert(list[ep.key], game.tick)
	if ep.params.fail == hook and #list[ep.key] == 1 then
		error("sp1b-test " .. hook .. " failed on purpose")
	end
end
ue.connectors.register_type{
	name = "sp1b-test",
	lanes = function() return {} end,
	schedule = { per_tick = 2, interval = 30 },
	build = function(ep)
		record("build", ep)
		return ep.params.block and "blocked" or "ready"
	end,
	teardown = function(ep) record("teardown", ep) end,
	poll = function(ep) record("poll", ep) end,
}

local function times(hook, edge, cid)
	return #(calls[hook][edge .. "/" .. cid] or {})
end

local function connector(cid, pos, params)
	return { cid = cid, type = "sp1b-test", pos = pos, width = 1, params = params or {} }
end

local function record_of(id, revision, connectors_, fields)
	local rec = {
		id = id, revision = revision, trace = "0000c0e0.t" .. revision, me = "a", owner = "test", length = 64,
		deleted = false, connectors = connectors_ or {},
		a = { instanceId = 4242, surface = "nauvis", origin = { 0, 2000 }, facing = 0 },
		b = { instanceId = 4243, surface = "nauvis", origin = { 64, 2000 }, facing = 8 },
	}
	for k, v in pairs(fields or {}) do
		rec[k] = v
	end
	return rec
end

local function side(id)
	return storage.universal_edges.edges[id]
end

local function endpoint(id, cid)
	return connectors.get(side(id), cid)
end

local function activate(id, epoch)
	deliver("ue.edge.activation", { id = id, active = true, epoch = epoch, trace = epoch })
end

local function partner(id, epoch, cid, state, ask)
	deliver("ue.lane", { edge = id, epoch = epoch, k = "ep", cid = cid, state = state, ask = ask })
end

t.case("connectors: builds run from the poll task, a few per tick, on an inactive edge too (G1)", function(ctx)
	ctx.at(100, function()
		local list = {}
		for i = 1, 10 do
			list[i] = connector("c" .. i, i)
		end
		deliver("ue.edge.update", { edge = record_of("sp1b-build", 1, list) })
		local ep = endpoint("sp1b-build", "c1")
		ctx.expect(ep ~= nil and ep.state == "pending", "a new connector's endpoint waits for its visit")
		ctx.expect(ep ~= nil and ep.col == 1 and ep.frame.facing == 0 and ep.me == "a", "the endpoint's facts")
		ctx.expect(storage.universal_edges.schema == 11, "storage is at schema 11")
	end)
	ctx.at(102, function()
		local built = 0
		for i = 1, 10 do
			built = built + times("build", "sp1b-build", "c" .. i)
		end
		ctx.expect(built >= 2 and built <= 4, "per_tick = 2 builds at most 2 a tick; got " .. built .. " in 2 ticks")
	end)
	ctx.at(110, function()
		for i = 1, 10 do
			ctx.expect(times("build", "sp1b-build", "c" .. i) == 1, "c" .. i .. " built once")
			ctx.expect(endpoint("sp1b-build", "c" .. i).state == "ready", "and ready")
		end
		deliver("ue.edge.update", { edge = record_of("sp1b-build", 2, {}, { deleted = true }) })
		ctx.expect(only_builtins(side("sp1b-build").eps), "a shell keeps only the closing built-in endpoints")
	end)
end)

t.case("connectors: teardown runs once when a connector leaves the record, and when the side becomes a shell", function(ctx)
	ctx.at(120, function()
		deliver("ue.edge.update", { edge = record_of("sp1b-down", 1, { connector("c1", 1), connector("c2", 2) }) })
	end)
	ctx.at(140, function()
		deliver("ue.edge.update", { edge = record_of("sp1b-down", 2, { connector("c2", 2) }) })
		ctx.expect(times("teardown", "sp1b-down", "c1") == 1, "c1 torn down")
		ctx.expect(endpoint("sp1b-down", "c1") == nil, "and removed, having no lanes")
		ctx.expect(times("teardown", "sp1b-down", "c2") == 0, "c2 stays")
		deliver("ue.edge.update", { edge = record_of("sp1b-down", 3, { connector("c2", 2) }, { deleted = true }) })
		ctx.expect(times("teardown", "sp1b-down", "c2") == 1, "a shell tears down every endpoint")
		deliver("ue.edge.update", { edge = record_of("sp1b-down", 4, {}, { deleted = true }) })
		ctx.expect(times("teardown", "sp1b-down", "c2") == 1, "once")
		local applied = queued("ue.edge.applied")
		local last = applied[#applied]
		ctx.expect(last.id == "sp1b-down" and last.open == 2 * builtins(), "the shell reports each built-in endpoint's two closing lanes")
	end)
end)

t.case("connectors: poll runs only while active, ready and the partner ready, at most once per interval (G2)", function(ctx)
	ctx.at(170, function()
		deliver("ue.edge.update", { edge = record_of("sp1b-poll", 1, { connector("c1", 1) }) })
	end)
	ctx.at(175, function()
		ctx.expect(endpoint("sp1b-poll", "c1").state == "ready", "built while inactive")
		activate("sp1b-poll", "0000c0e0.e1")
	end)
	ctx.at(185, function()
		ctx.expect(times("poll", "sp1b-poll", "c1") == 0, "no poll before the partner's ep arrives")
		partner("sp1b-poll", "0000c0e0.e1", "c1", "ready", true)
		local eps = queued("ue.lane")
		local answer = eps[#eps]
		ctx.expect(answer and answer.k == "ep" and answer.cid == "c1" and answer.state == "ready" and not answer.ask,
			"an ask is answered with our own ep")
		ctx.expect(endpoint("sp1b-poll", "c1").partner.state == "ready", "the partner is known")
	end)
	local polled
	ctx.at(250, function()
		local polls = calls.poll["sp1b-poll/c1"] or {}
		ctx.expect(#polls >= 2, "polled while active; got " .. #polls)
		for i = 2, #polls do
			ctx.expect(polls[i] - polls[i - 1] >= 30, "at most once per interval")
		end
		polled = #polls
		deliver("ue.edge.activation", { id = "sp1b-poll", active = false, trace = "0000c0e0.d1", reason = "stopped" })
	end)
	ctx.at(320, function()
		ctx.expect(#calls.poll["sp1b-poll/c1"] == polled, "no poll while inactive, across two intervals")
		deliver("ue.edge.update", { edge = record_of("sp1b-poll", 2, {}, { deleted = true }) })
	end)
	-- The first visit after the activation sent ep with ask = true (§11.2).
	ctx.expect_ipc("universal_edges:out", '"ask":true')
end)

t.case("connectors: a hook error fails the endpoint, tells the partner, and an update retries it (G6)", function(ctx)
	ctx.at(270, function()
		deliver("ue.edge.update", { edge = record_of("sp1b-fail", 1, { connector("c1", 1, { fail = "poll" }) }) })
		activate("sp1b-fail", "0000c0e0.e2")
	end)
	ctx.at(275, function()
		partner("sp1b-fail", "0000c0e0.e2", "c1", "ready")
	end)
	ctx.at(290, function()
		local ep = endpoint("sp1b-fail", "c1")
		ctx.expect(ep.state == "failed", "the poll error failed the endpoint; state " .. ep.state)
		ctx.expect(times("poll", "sp1b-fail", "c1") == 1, "polled once, then no more")
		deliver("ue.edge.update", { edge = record_of("sp1b-fail", 2, { connector("c1", 1, { fail = "poll" }) }) })
		ctx.expect(ep.state == "pending", "a reconfiguration retries it")
	end)
	ctx.at(325, function()
		ctx.expect(endpoint("sp1b-fail", "c1").state == "ready", "rebuilt")
		ctx.expect(times("poll", "sp1b-fail", "c1") >= 2, "and polled again")
		deliver("ue.edge.update", { edge = record_of("sp1b-fail", 3, {}, { deleted = true }) })
	end)
	ctx.expect_ipc("universal_edges:out", '"phase":"failed"')
	ctx.expect_ipc("universal_edges:out", '"hook":"poll"')
	ctx.expect_ipc("universal_edges:out", '"state":"failed"')
end)

t.case("connectors: an unknown type or refused params get no endpoint, and say so", function(ctx)
	ctx.at(335, function()
		local odd = { cid = "c1", type = "no-such-type", pos = 1, width = 1, params = {} }
		deliver("ue.edge.update", { edge = record_of("sp1b-odd", 1, { odd }) })
		ctx.expect(endpoint("sp1b-odd", "c1") == nil, "no endpoint")
		local failed = traced("failed", "sp1b-odd")
		ctx.expect(#failed == 1 and failed[1].level == "error" and failed[1].hook == "create", "failed at create, at error")
		deliver("ue.edge.update", { edge = record_of("sp1b-odd", 2, {}, { deleted = true }) })
		ctx.expect(not pcall(ue.connectors.register_type, { name = "late" }), "types register at load only")
	end)
end)

t.case("connectors: limbo files, ownership and removal requests", function(ctx)
	ctx.at(360, function()
		deliver("ue.edge.update", { edge = record_of("sp1b-own", 1, { connector("c1", 1) }) })
	end)
	ctx.at(365, function()
		local ep = endpoint("sp1b-own", "c1")
		local surface = game.surfaces.nauvis
		local chest = surface.create_entity({ name = "wooden-chest", position = { 10, 2010 }, force = "player" })
		ep:own(chest)
		ctx.expect(ue.owns(chest), "an owned chest is UE's")
		local tree = surface.create_entity({ name = "tree-01", position = { 12, 2010 } })
		ctx.expect(not pcall(ep.own, ep, tree), "an entity without a unit_number can't be owned")
		local file = connectors.limbo(ep, "ab", "refund", { probe = 7 }, "0000c0e0.limbo")
		ctx.expect(file == "universal_edges/limbo/0000c0e0.limbo.txt", "the limbo file's name: " .. file)
		ep:request_removal("test")
		local asked = queued("ue.connector.remove")
		ctx.expect(#asked == 1 and asked[1].edge == "sp1b-own" and asked[1].cid == "c1" and asked[1].reason == "test",
			"a removal request goes to the instance plugin")
		deliver("ue.edge.update", { edge = record_of("sp1b-own", 2, {}) })
		ctx.expect(not ue.owns(chest), "teardown ends the ownership")
		chest.destroy()
		if tree then
			tree.destroy()
		end
	end)
	ctx.expect_file("universal_edges/limbo/0000c0e0.limbo.txt")
end)
