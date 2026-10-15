local t = require("modules/v2_test/testlib")
local loop = require("modules/v2_test/loopback")
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
local lanes = require("modules/universal_edges/edges/lanes")
local hooks = require("modules/universal_edges/transports/hooks")
local bridge = require("modules/universal_edges/runtime/bridge")

local function queued(msg_type, pred)
	local found = {}
	for _, msg in ipairs(storage.universal_edges.bridge.out.universal_edges or {}) do
		if msg.type == msg_type and (not pred or pred(msg.payload)) then
			found[#found + 1] = msg.payload
		end
	end
	return found
end

local function ep(edge, cid)
	local side = storage.universal_edges.edges[edge]
	return side and connectors.get(side, cid)
end

local NORTH = function(x)
	return { x, 3000, 0 }, { x + 16, 2000, 8 }
end

-- sp3-unique: a unique test type whose source sends what a step hands it and whose credit records meta (F1) and calls
-- ep:materialized (F2). Its capture raises when the payload says so (F12).
local got = {}
ue.connectors.register_type({
	name = "sp3-unique",
	lanes = function() return { ab = "unique" } end,
	schedule = { per_tick = 2, interval = 30 },
	build = function() return "ready" end,
	teardown = function() end,
	poll = function() end,
	capture = function(e, payload)
		if payload.raise then
			error("sp3-unique capture failed on purpose")
		end
		return e:send("ab", payload)
	end,
	credit = function(e, dir, payload, meta)
		got[#got + 1] = { payload = payload, meta = meta }
		e:materialized(dir, nil, payload.ext, meta)
		return "ok"
	end,
	commit = function() return true end,
	restore = function() return true end,
})
local seen = {}
ue.transfers.extend({
	name = "sp3-test", types = { ["sp3-unique"] = true },
	capture = function(_, handle) return { handle = handle } end,
	materialized = function(_, _, data, meta) seen[#seen + 1] = { data = data, meta = meta } end,
})

t.case("framework: a unique offer leaves at once (F3), its credit gets seq and trace (F1), and materialized runs (F2)",
	function(ctx)
		local c = { { cid = "c1", type = "sp3-unique", pos = 2, width = 1, params = {} } }
		ctx.at(1500, function() loop.edge("sp3-f1", 16, c, NORTH(5000)) end)
		ctx.at(1530, function()
			local src = ep("sp3-f1-x", "c1")
			ctx.expect(src and src.partner and src.partner.state == "ready", "the looped partner answered")
			local ext = hooks.capture(src, "h1")
			local ok, seq = connectors.call(src, "capture", { id = "t1", ext = ext })
			ctx.expect(ok and seq == 1, "captured as seq 1")
			ctx.expect(#queued("ue.lane", function(p) return p.k == "u.offer" and p.edge == "sp3-f1-x" end) == 1,
				"the offer is queued in the same call, not at the next visit")
		end)
		ctx.at(1535, function()
			ctx.expect(#got == 1 and got[1].meta.seq == 1 and type(got[1].meta.trace) == "string", "credit saw meta")
			ctx.expect(#seen == 1 and seen[1].data.handle == "h1" and seen[1].meta.seq == 1, "the extension's data came back")
			local ok = connectors.call(ep("sp3-f1-x", "c1"), "capture", { raise = true })
			ctx.expect(not ok and ep("sp3-f1-x", "c1").state == "failed", "a capture error fails the endpoint (F12, G6)")
		end)
		ctx.expect_ipc("universal_edges:out", '"phase":"materialized"')
	end)

t.case("framework: a body over 65,536 bytes is refused with too_big, and nothing is in flight (F4)", function(ctx)
	local c = { { cid = "c1", type = "sp3-unique", pos = 2, width = 1, params = {} } }
	ctx.at(1550, function() loop.edge("sp3-f4", 16, c, NORTH(5040)) end)
	ctx.at(1580, function()
		local src = ep("sp3-f4-x", "c1")
		local pad, x = {}, 7
		for i = 1, 100000 do -- MINSTD (a = 16807, m = 2^31 - 1): exact in lua5.2's doubles, so it deflates to well over 64 KB
			x = (x * 16807) % 2147483647
			pad[i] = string.char(33 + math.floor(x / 65536) % 90)
		end
		local seq, why = src:send("ab", { pad = table.concat(pad) })
		ctx.expect(seq == nil and why == "too_big", "too_big, not an error")
		ctx.expect(src:can_send("ab"), "nothing in flight")
	end)
end)

t.case("framework: the built-in vehicle endpoint lives on every live side, outside the record, and closes only with " ..
	"the side (F7)", function(ctx)
	ctx.at(1600, function() loop.edge("sp3-f7", 16, {}, NORTH(5080)) end)
	-- Not a fixed tick (SP3b T3 finding, widened in the final fix wave): more edges in the shared save mean more
	-- built-in "v" endpoints sharing the vehicle type's own walk (per_tick = 2, interval = 300, vehicle.lua). A
	-- newly built or newly closed one can just miss the walk's current pass and then wait out the rest of it plus a
	-- full next pass before its next visit — budget 2 x interval = 600 ticks for each of "reaches ready" and
	-- "removed after its tombstone", sampling every tick for the real event rather than a fixed offset.
	local BUDGET = 600
	local ready_at
	for k = 1601, 1600 + BUDGET do
		ctx.at(k, function()
			if ready_at then
				return
			end
			local x, y = ep("sp3-f7-x", "v"), ep("sp3-f7-y", "v")
			local ok_x = x and x.type == "vehicle" and x.col == 0 and x.width == 16 and x.state == "ready"
				and x.partner and x.partner.state == "ready"
			local ok_y = y and y.state == "ready" and y.partner and y.partner.state == "ready"
			if ok_x and ok_y then
				ready_at = k
				ctx.expect(x.tx.ab and x.rx.ba and x.tx.ab.kind == "unique", "two unique lanes, ab out of side a")
				loop.connectors("sp3-f7", 2, {})
				ctx.expect(not ep("sp3-f7-x", "v").closing, "a record without v doesn't close it")
				loop.connectors("sp3-f7", 3, {}, true)
				ctx.expect(ep("sp3-f7-x", "v").closing, "a tombstone does")
				local applied = queued("ue.edge.applied", function(p) return p.id == "sp3-f7-x" end)
				ctx.expect(applied[#applied].open == 2 * builtins(), "the shell reports each built-in's two closing lanes")
			end
		end)
	end
	ctx.at(1600 + BUDGET + 1, function()
		ctx.expect(ready_at, "sp3-f7-x and -y: v reached ready, its twin answered, within " .. BUDGET .. " ticks")
	end)
	local closed_x, closed_y
	for k = 1601, 1600 + 2 * BUDGET do
		ctx.at(k, function()
			if not ready_at or k <= ready_at then
				return
			end
			closed_x = closed_x or (ep("sp3-f7-x", "v") == nil and k)
			closed_y = closed_y or (ep("sp3-f7-y", "v") == nil and k)
		end)
	end
	ctx.at(1600 + 2 * BUDGET + 1, function()
		ctx.expect(closed_x and closed_y, "closed within " .. BUDGET .. " ticks of the tombstone: x " ..
			tostring(closed_x) .. ", y " .. tostring(closed_y))
	end)
end)

-- F8: every applied report, counted per side and tick. The loopback delivers one inbox batch a tick.
local per_tick = {}
local report = lanes.report
lanes.report = function(side, sync)
	local key = side.id .. "@" .. game.tick
	per_tick[key] = (per_tick[key] or 0) + 1
	return report(side, sync)
end

t.case("framework: one applied report per inbox batch however many lanes it drops (F8); frames of both sides (F10)",
	function(ctx)
		local list = {}
		for i = 1, 6 do
			list[i] = { cid = "c" .. i, type = "probe", pos = i, width = 1, params = { dir = "ab", kind = "stream" } }
		end
		ctx.at(1680, function() loop.edge("sp3-f8", 16, list, NORTH(5120)) end)
		ctx.at(1710, function()
			local a, b = ue.edges.frame("sp3-f8-x", "a"), ue.edges.frame("sp3-f8-x", "b")
			ctx.expect(a.origin[1] == 5120 and a.origin[2] == 3000 and a.facing == 0 and a.length == 16, "side a's frame")
			ctx.expect(b.origin[1] == 5136 and b.origin[2] == 2000 and b.facing == 8, "side b's frame, from side a's record")
			ctx.expect(ue.edges.frame("no-such-edge", "a") == nil, "unknown edge")
			loop.connectors("sp3-f8", 2, {})
		end)
		ctx.at(1730, function()
			local n = 0
			for key, count in pairs(per_tick) do
				if string.find(key, "^sp3%-f8%-") then
					n = n + count
					ctx.expect(count == 1, key .. ": " .. count .. " reports in one tick")
				end
			end
			ctx.expect(n >= 4, "the apply's two, and at least one per side as its lanes dropped; got " .. n)
			ctx.expect(only_builtins(storage.universal_edges.edges["sp3-f8-x"].eps), "only the built-ins are left: the probes closed")
		end)
	end)

t.case("framework: ep:idle is true with nothing unacknowledged (F6); the prototypes load (D11)", function(ctx)
	local c = { { cid = "c1", type = "probe", pos = 2, width = 1, params = { dir = "ab", kind = "stream" } } }
	ctx.at(1740, function() loop.edge("sp3-f6", 16, c, NORTH(5160)) end)
	ctx.at(1770, function()
		local src = ep("sp3-f6-x", "c1")
		ctx.expect(src:idle("ab") and src:idle("ba"), "idle, and idle for a lane it doesn't send on")
		src:send("ab", { probe = 5 })
		ctx.expect(not src:idle("ab"), "pending")
		for _, name in ipairs({ "ue-link-belt", "ue-link-interface", "ue-link-pipe", "ue-test-power-source",
			"ue-test-power-sink" }) do
			ctx.expect(prototypes.entity[name] ~= nil, name)
		end
		ctx.expect(prototypes.entity["ue-link-belt"].belt_speed == prototypes.entity["turbo-transport-belt"].belt_speed,
			"the link belt runs at the fastest belt's speed")
		-- Visuals batch (2026-10-04): the power link's picture is halved again to fit its 1×1 box (data.lua `shrink`);
		-- the box itself was already 1×1 (D11, §5.4) and is unchanged here.
		local eei = prototypes.entity["ue-link-interface"]
		ctx.expect(eei.tile_width == 1 and eei.tile_height == 1, "ue-link-interface is still a 1×1 prototype")
		local pipe = prototypes.entity["ue-link-pipe"]
		ctx.expect(pipe.type == "pipe-to-ground", "ue-link-pipe is a pipe-to-ground, not a storage-tank")
		ctx.expect(pipe.tile_width == 1 and pipe.tile_height == 1, "ue-link-pipe is a 1×1 prototype")
	end)
	ctx.at(1800, function()
		ctx.expect(ep("sp3-f6-x", "c1"):idle("ab"), "acknowledged over the loopback")
	end)
end)

-- F13: a status a poll sets leaves in that visit. sp3-status records each poll's tick in its status.
local polled = {}
ue.connectors.register_type({
	name = "sp3-status",
	lanes = function() return {} end,
	schedule = { per_tick = 2, interval = 30 },
	build = function() return "ready" end,
	teardown = function() end,
	poll = function(e, tick)
		polled[e.key] = tick
		e:set_status({ polled = tick })
	end,
})

t.case("framework: a status set by a poll reaches the partner in that visit, not a visit later (F13)", function(ctx)
	local c = { { cid = "c1", type = "sp3-status", pos = 2, width = 1, params = {} } }
	ctx.at(1600, function() loop.edge("sp3-f13", 16, c, NORTH(5180)) end)
	for at = 1700, 1760, 7 do
		ctx.at(at, function()
			local last = polled["sp3-f13-x/c1"]
			local status = ep("sp3-f13-y", "c1").partner.status
			if last and game.tick - last >= 3 then
				ctx.expect(status and status.polled == last, "the poll at " .. last .. " is the status side b has")
			end
		end)
	end
end)

-- sp3-ordered: an ordered type whose destination takes at most 3 items a credit, recording their order.
local placed = {}
ue.connectors.register_type({
	name = "sp3-ordered",
	lanes = function() return { ab = "ordered" } end,
	schedule = { per_tick = 2, interval = 10 },
	build = function() return "ready" end,
	teardown = function() end,
	poll = function() end,
	credit = function(_, _, list)
		local n = 0
		for _, x in ipairs(list) do
			local take = math.min(x[2], 3 - n)
			for _ = 1, take do
				placed[#placed + 1] = x[1]
			end
			n = n + take
		end
		return n
	end,
	refund = function() return true end,
})

t.case("framework: an ordered lane credits in capture order over the loopback, a prefix at a time (F11)", function(ctx)
	local c = { { cid = "c1", type = "sp3-ordered", pos = 2, width = 1, params = {} } }
	ctx.at(1800, function() loop.edge("sp3-f11", 16, c, NORTH(5200)) end)
	ctx.at(1830, function()
		local src = ep("sp3-f11-x", "c1")
		src:send("ab", { { "x", 2 }, { "y", 1 }, { "x", 1 } })
		src:send("ab", { { "x", 1 }, { "z", 2 } })
		ctx.expect(src:runs("ab") == 4, "x2 y1 x1, the x extended, then z2: 4 runs; got " .. src:runs("ab"))
		ctx.expect(not pcall(src.send, src, "ab", { { "x", 1.5 } }), "a bad run list is refused")
	end)
	ctx.at(1880, function()
		ctx.expect(table.concat(placed, ",") == "x,x,y,x,x,z,z", "in order, three items a credit: " .. table.concat(placed, ","))
		ctx.expect(ep("sp3-f11-x", "c1"):runs("ab") == 0 and ep("sp3-f11-x", "c1"):idle("ab"), "every run acknowledged")
	end)
	ctx.expect_ipc("universal_edges:out", '"k":"o.offer"')
end)

-- SP3b final review M1/M9: a failed endpoint that one reconcile resets to pending (lanes.lua, on the same ep object)
-- must still run its type's teardown if a second reconcile closes it before its next build visit would have rebuilt
-- it — teardown must key off whether build ever ran, not ep.state. Counted on the built-in probe type (its own
-- teardown is a no-op) rather than a new registered type, so this case adds no extra type to the shared save's walk.
local probe_torn_down = {}
local probe_teardown = connectors.types.probe.teardown
connectors.types.probe.teardown = function(e)
	probe_torn_down[e.key] = (probe_torn_down[e.key] or 0) + 1
	return probe_teardown(e)
end

t.case("framework: a failed endpoint reset to pending by one reconcile still tears down if a second reconcile " ..
	"closes it in the same tick (M1/M9)", function(ctx)
	local c = { { cid = "c1", type = "probe", pos = 2, width = 1, params = { dir = "ab", kind = "stream" } } }
	ctx.at(1900, function() loop.edge("sp3-m9", 16, c, NORTH(5220)) end)
	ctx.at(1930, function()
		local e = ep("sp3-m9-x", "c1")
		ctx.expect(e and e.state == "ready", "built")
		connectors.fail(e, "poll", "forced")
		ctx.expect(e.state == "failed", "failed")
		loop.connectors("sp3-m9", 2, c) -- a reconcile that keeps the connector: resets it to pending (G6)
		ctx.expect(e.state == "pending" and not e.closing, "reset to pending, still open")
		loop.connectors("sp3-m9", 3, {}) -- a reconcile without it, same tick: closes it before its next build visit
		ctx.expect(e.closing, "closing")
		ctx.expect((probe_torn_down["sp3-m9-x/c1"] or 0) == 1, "the type's teardown ran despite the pending reset")
	end)
end)

-- FC3 (circuit-link spec §5.2): sp3-big declares big_status; its poll sets a status padded to big_size bytes.
local big_size = 10
ue.connectors.register_type({
	name = "sp3-big",
	big_status = true,
	lanes = function() return {} end,
	schedule = { per_tick = 2, interval = 30 },
	build = function() return "ready" end,
	teardown = function() end,
	poll = function(e, tick) e:set_status({ tick = tick, pad = string.rep("x", big_size) }) end,
})

-- Every ue.chunk key of sp3-fc3-x, read from the queue before each flush (the loopback's wrapper reads it too; they chain).
local chunk_keys = {}
local flush = bridge.flush
function bridge.flush(tick)
	for _, msg in ipairs(storage.universal_edges.bridge.out.universal_edges or {}) do
		if msg.type == "ue.chunk" and string.find(msg.payload.key, "^sp3%-fc3%-x/") then
			chunk_keys[#chunk_keys + 1] = msg.payload.key
		end
	end
	flush(tick)
end

t.case("framework: a big_status over 3000 bytes of JSON crosses whole in ue.chunk parts, one key per send under " ..
	"edge/cid/ep/<n>; a small one rides as a table (FC3)", function(ctx)
	local c = { { cid = "c1", type = "sp3-big", pos = 2, width = 1, params = {} } }
	ctx.at(1950, function() loop.edge("sp3-fc3", 16, c, NORTH(5240)) end)
	ctx.at(2000, function()
		local status = ep("sp3-fc3-y", "c1").partner.status
		ctx.expect(status and #status.pad == 10, "the small status arrived")
		ctx.expect(#chunk_keys == 0, "with no parts: " .. #chunk_keys)
		big_size = 8000
	end)
	ctx.at(2070, function()
		local status = ep("sp3-fc3-y", "c1").partner.status
		ctx.expect(status and #status.pad == 8000, "the big status arrived whole: " .. tostring(status and #status.pad))
		local keys = {}
		for _, k in ipairs(chunk_keys) do
			keys[k] = true
		end
		ctx.expect(#chunk_keys >= 6 and keys["sp3-fc3-x/c1/ep/1"] and keys["sp3-fc3-x/c1/ep/2"],
			"two sends of three parts each, under their own keys: " .. table.concat(chunk_keys, " "))
	end)
end)

-- FC4 and FC5 (circuit-link spec §5.2): sp3-forms has full_status, on_status and deactivated. Its poll sets a status only
-- while forms.set[edge] is on; forms.got[key] lists every status that reached endpoint key, in order; forms.off[key]
-- counts its deactivations.
local forms = { got = {}, off = {}, set = {} }
ue.connectors.register_type({
	name = "sp3-forms",
	lanes = function() return {} end,
	schedule = { per_tick = 2, interval = 30 },
	build = function() return "ready" end,
	teardown = function() end,
	poll = function(e, tick)
		if forms.set[e.edge] then
			e:set_status({ form = "change", tick = tick })
		end
	end,
	full_status = function() return { form = "full", tick = game.tick } end,
	on_status = function(e, status)
		local list = forms.got[e.key] or {}
		forms.got[e.key] = list
		list[#list + 1] = { form = status.form, at = game.tick, tick = status.tick }
	end,
	deactivated = function(e)
		forms.off[e.key] = (forms.off[e.key] or 0) + 1
	end,
})

--- How many statuses of form reached endpoint key.
local function arrived(key, form)
	local n = 0
	for _, s in ipairs(forms.got[key] or {}) do
		if s.form == form then
			n = n + 1
		end
	end
	return n
end

t.case("framework: the handshake, its re-send while the partner is unheard and the reply to an ask carry full_status's " ..
	"result; F13 and a state change carry ep.status (FC5)", function(ctx)
	local c = { { cid = "c1", type = "sp3-forms", pos = 2, width = 1, params = {} } }
	local X, Y = "sp3-fc5-x/c1", "sp3-fc5-y/c1"
	local n = {}
	ctx.at(2000, function() loop.edge("sp3-fc5", 16, c, NORTH(5250)) end)
	ctx.at(2010, function()
		ctx.expect(arrived(X, "full") >= 1 and arrived(Y, "full") >= 1, "each side's handshake reached the other as a full")
		ctx.expect(arrived(X, "change") == 0 and arrived(Y, "change") == 0, "and nothing else did")
		local e = ep("sp3-fc5-x", "c1")
		e.partner, e.next_ask = nil, 0 -- x has heard nothing: its next visit re-sends, asking
		n.x, n.y = arrived(X, "full"), arrived(Y, "full")
	end)
	ctx.at(2050, function()
		ctx.expect(arrived(Y, "full") > n.y, "x's re-send reached y as a full")
		ctx.expect(arrived(X, "full") > n.x, "and y's reply to its ask reached x as a full")
		n.y = arrived(Y, "full")
		ctx.expect(ep("sp3-fc5-y", "c1"):ask_partner(120), "y asks")
	end)
	ctx.at(2090, function()
		ctx.expect(arrived(Y, "full") == n.y + 1, "x's reply to y's ask reached y as one full")
		forms.set["sp3-fc5-x"] = true
		n.full = arrived(Y, "full")
	end)
	ctx.at(2130, function()
		local list = forms.got[Y]
		ctx.expect(list[#list].form == "change", "F13 sent the poll's own status")
		ctx.expect(arrived(Y, "full") == n.full, "and no full since")
		n.change = arrived(Y, "change")
		forms.set["sp3-fc5-x"] = nil
		connectors.fail(ep("sp3-fc5-x", "c1"), "test", "forced") -- a state change, announced with ep.status
	end)
	ctx.at(2170, function()
		ctx.expect(ep("sp3-fc5-y", "c1").partner.state == "failed", "y heard x fail")
		ctx.expect(arrived(Y, "change") == n.change + 1 and arrived(Y, "full") == n.full, "the state change carried ep.status")
	end)
end)

t.case("framework: on_status runs once per arriving status, in order, two in one inbox batch included (FC5)", function(ctx)
	local c = { { cid = "c1", type = "sp3-forms", pos = 2, width = 1, params = {} } }
	local Y = "sp3-fc5b-y/c1"
	local held, together
	ctx.at(2200, function() loop.edge("sp3-fc5b", 16, c, NORTH(5270)) end)
	ctx.at(2230, function()
		forms.set["sp3-fc5b-x"] = true
		-- Hold x's first change to y, and send it with the next: two statuses in one batch.
		loop.taps["sp3-fc5b-y"] = function(copy)
			local s = copy.payload.status
			if not (copy.payload.k == "ep" and s and s.form == "change") then
				return true
			end
			if not held then
				held = copy
				return false
			end
			loop.taps["sp3-fc5b-y"] = nil
			loop.deliver({ held, copy })
			together = s.tick
			return false
		end
	end)
	ctx.at(2320, function()
		forms.set["sp3-fc5b-x"] = nil
		ctx.expect(together, "two changes were held and sent together")
		local list, k = forms.got[Y] or {}, nil
		for i, s in ipairs(list) do
			if s.tick == together then
				k = i
			end
		end
		ctx.expect(k and k >= 2 and list[k - 1].form == "change" and list[k - 1].at == list[k].at
			and list[k - 1].tick < list[k].tick, "both folded in one batch, in the order sent")
		local once = {}
		for _, s in ipairs(list) do
			if s.form == "change" then
				ctx.expect(not once[s.tick], "change " .. s.tick .. " arrived once")
				once[s.tick] = true
			end
		end
	end)
end)

t.case("framework: ep:ask_partner(120) asks at most once per 120 ticks; ep:ask_partner() keeps its 3600 (FC5)", function(ctx)
	ctx.at(2330, function()
		local e = ep("sp3-fc5b-y", "c1")
		e.asked = nil
		ctx.expect(e:ask_partner(120) == true, "the first ask")
		ctx.expect(e:ask_partner(120) == false, "throttled")
		e.asked = game.tick - 120
		ctx.expect(e:ask_partner(120) == true, "120 ticks later")
		e.asked = game.tick - 200
		ctx.expect(e:ask_partner() == false, "the default is still 3600")
		ctx.expect(e:ask_partner(120) == true, "while 120 has passed")
	end)
end)

t.case("framework: an edge's deactivation calls each endpoint's deactivated hook once; an activation calls none; a " ..
	"type without the hook is untouched (FC4)", function(ctx)
	local c = {
		{ cid = "c1", type = "sp3-forms", pos = 2, width = 1, params = {} },
		{ cid = "c2", type = "sp3-status", pos = 5, width = 1, params = {} },
	}
	local X, Y = "sp3-fc4-x/c1", "sp3-fc4-y/c1"
	ctx.at(2400, function() loop.edge("sp3-fc4", 16, c, NORTH(5290)) end)
	ctx.at(2430, function()
		ctx.expect(forms.off[X] == nil and forms.off[Y] == nil, "none yet")
		loop.activation("sp3-fc4", false)
		ctx.expect(forms.off[X] == 1 and forms.off[Y] == 1, "one call on each side, at once")
		ctx.expect(ep("sp3-fc4-x", "c2").state == "ready", "the hookless type's endpoint is as it was")
	end)
	ctx.at(2440, function()
		loop.activation("sp3-fc4", true)
		ctx.expect(forms.off[X] == 1 and forms.off[Y] == 1, "an activation calls none")
	end)
	ctx.at(2460, function()
		loop.activation("sp3-fc4", false)
		ctx.expect(forms.off[X] == 2 and forms.off[Y] == 2, "the next deactivation, once more")
	end)
end)

-- §5.4 and §17 item 17 (plan ruling 11): the injector prototype, and the two slot facts the write task relies on.
local RED = defines.wire_connector_id.circuit_red

--- A pole's red signals as "name=count", sorted and joined.
local function reds(pole)
	local net = pole.get_circuit_network(RED)
	local list = {}
	for _, s in ipairs(net and net.signals or {}) do
		list[#list + 1] = s.signal.name .. "=" .. s.count
	end
	table.sort(list)
	return table.concat(list, ",")
end

t.case("framework: ue-link-combinator is hidden, unselectable and collides with nothing; a section's slots stop at " ..
	"1,000, so 2,000 signals take two sections, and clear_slot takes out exactly one signal (circuit-link spec §5.4, " ..
	"§17 item 17; plan Ruling T2a)", function(ctx)
	local rig = {}
	ctx.at(2500, function()
		local p = prototypes.entity["ue-link-combinator"]
		ctx.expect(p ~= nil and p.type == "constant-combinator" and p.hidden, "a hidden constant combinator")
		ctx.expect(p ~= nil and not p.selectable_in_game, "players can't select it")
		ctx.expect(p ~= nil and next(p.collision_mask.layers) == nil, "it collides with nothing")
		loop.ground(5300, 3020, 5316, 3030)
		local s = game.surfaces.nauvis
		rig.pole = s.create_entity({ name = "medium-electric-pole", position = { 5302.5, 3025.5 }, force = "player" })
		ctx.expect(s.can_place_entity({ name = "ue-link-combinator", position = { 5302.5, 3025.5 } }),
			"placeable on the pole's own tile")
		rig.comb = s.create_entity({ name = "ue-link-combinator", position = { 5302.5, 3025.5 }, force = "player" })
		rig.comb.get_wire_connector(RED, true).connect_to(rig.pole.get_wire_connector(RED, true), false,
			defines.wire_origin.script)
		local cb = rig.comb.get_or_create_control_behavior()
		rig.section = cb.get_section(1) or cb.add_section()
		log("ue-link-combinator: a fresh section's multiplier reads " .. tostring(rig.section.multiplier))
		rig.section.multiplier = 1
		-- Ruling T2a: 2.1.20 refuses set_slot past 1,000 ("Index out of bounds: 2000 > 1000 (max)"), so a colour's
		-- 2,000 slots (K8) live in two sections: flat slot 2,000 is section 2's slot 1,000
		ctx.expect(not pcall(rig.section.set_slot, 1001, { value = { type = "item", name = "iron-plate",
			quality = "normal" }, min = 7 }), "slot 1,001 is refused")
		rig.second = cb.add_section()
		rig.second.multiplier = 1
		rig.second.set_slot(1000, { value = { type = "item", name = "iron-plate", quality = "normal" }, min = 7 })
		rig.section.set_slot(1000, { value = { type = "virtual", name = "signal-A", quality = "normal" }, min = 3 })
		rig.section.set_slot(1, { value = { type = "item", name = "copper-plate", quality = "normal" }, min = 5 })
	end)
	ctx.at(2502, function()
		ctx.expect(reds(rig.pole) == "copper-plate=5,iron-plate=7,signal-A=3", "slots 1 and 1,000 of section 1 and 1,000 "
			.. "of section 2 all reach the network: " .. reds(rig.pole))
		rig.section.clear_slot(1000)
	end)
	ctx.at(2504, function()
		ctx.expect(reds(rig.pole) == "copper-plate=5,iron-plate=7", "clear_slot took out one signal: " .. reds(rig.pole))
		rig.comb.destroy()
		rig.pole.destroy()
	end)
end)

-- Ruling C1/P1 (controller addition, 2026-10-04): the owner's C5 (b) is "there should be no output if the server is
-- down" — a server that restarts while its partner is still down must still clear FC4's residual state, not only a
-- side that gets a fresh ue.edge.activation(active=false) message. edges.on_server_startup() now walks every side and
-- calls lanes.deactivated(side) too, after core.reset (edges.lua), so a side that was ALREADY inactive going into the
-- restart is deactivated again. Proven here on the shared save's own restarts, not a direct mid-run call (which would
-- reset every side in the whole suite before tick 3850): runtime_game_test.lua raises the real on_server_startup event
-- at tick 3900, and marks_game_test.lua raises it again at 3930 and 3950. sp3-fc4's two endpoints (above) are already
-- inactive from that case's own last deactivation (tick 2460) and nothing reactivates them again before these restarts,
-- so each restart is exactly "lanes.deactivated's own guards still hold for an already-inactive side".
t.case("framework: edges.on_server_startup() deactivates every still-live side, not only one told to by a fresh " ..
	"message, so a restart with the partner still down clears it too (ruling C1/P1, circuit-link spec C5 b)", function(ctx)
	local X, Y = "sp3-fc4-x/c1", "sp3-fc4-y/c1"
	local before
	ctx.at(2470, function()
		before = { x = forms.off[X], y = forms.off[Y] }
		ctx.expect(before.x == 2 and before.y == 2, "the FC4 case above left both sides deactivated exactly twice")
	end)
	ctx.at(3970, function()
		ctx.expect(forms.off[X] > before.x and forms.off[Y] > before.y, "a later restart (runtime_game_test.lua's at " ..
			"3900, marks_game_test.lua's at 3930 and 3950) deactivated this already-inactive side again: " ..
			"edges.on_server_startup() itself called lanes.deactivated for every side, not only edges.lua's activation " ..
			"handler: " .. tostring(forms.off[X]) .. ", " .. tostring(forms.off[Y]))
	end)
end)
