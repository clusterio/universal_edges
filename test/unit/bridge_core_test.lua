local t = require("testlib")
local core = require("modules/universal_edges/runtime/bridge_core")

local function sized(n)
	return { type = "x", payload = { size = n } }
end

local function size_of(msg)
	return msg.payload.size
end

t.test("enqueue keeps type and payload and refuses beyond cap", function()
	local queue = {}
	t.expect_true(core.enqueue(queue, "a", { n = 1 }, 2))
	t.expect_true(core.enqueue(queue, "b", {}, 2))
	t.expect_eq(core.enqueue(queue, "c", {}, 2), false)
	t.expect_same(queue, { { type = "a", payload = { n = 1 } }, { type = "b", payload = {} } })
	t.expect_error(function() core.enqueue(queue, "d", "not a table", 5) end, "payload")
end)

t.test("a flush is split so each batch's JSON stays under the soft limit", function()
	local batches = core.split({ sized(1000), sized(1000), sized(1000), sized(1000), sized(1000) }, size_of, 3500)
	t.expect_eq(#batches, 2)
	t.expect_eq(#batches[1], 3)
	t.expect_eq(#batches[2], 2)
end)

t.test("a single message over the limit goes alone; an empty flush sends nothing", function()
	local batches = core.split({ sized(100), sized(5000), sized(100) }, size_of, 3500)
	t.expect_eq(#batches, 3)
	t.expect_eq(batches[2][1].payload.size, 5000)
	t.expect_eq(#core.split({}, size_of, 3500), 0)
end)

t.test("a batch line is its messages' own JSON in send_json's { tick, msgs } shape, within split's estimate (I3)", function()
	t.expect_eq(core.batch(12345, { '{"id":"a.1","type":"x","payload":{"n":1}}', '{"payload":{}}' }),
		'{"tick":12345,"msgs":[{"id":"a.1","type":"x","payload":{"n":1}},{"payload":{}}]}')
	t.expect_eq(core.batch(0, { "{}" }), '{"tick":0,"msgs":[{}]}')
	-- split counts ENVELOPE plus a byte a message, so every line it passes stays under the soft limit (ticks to 14 digits).
	local parts = { string.rep("x", 1000), string.rep("y", 2000), "{}" }
	local batches = core.split(parts, string.len, 3500)
	t.expect_eq(#batches, 1)
	t.expect_true(#core.batch(99999999999999, batches[1]) <= 32 + 1001 + 2001 + 3, "the line fits split's estimate")
end)

t.test("inbound: well-formed first-seen messages pass; malformed and repeated ones are only counted", function()
	local seen, counters = {}, {}
	local ok = { id = "aa.1", type = "ue.ping", payload = {} }
	local accepted = core.accept({
		ok,
		{ id = "aa.1", type = "ue.ping", payload = {} },
		{ id = "aa.2", type = "ue.ping" },
		{ id = "bogus", type = "ue.ping", payload = {} },
		{ id = "aa.3", payload = {} },
		"not a message",
	}, seen, 0, counters)
	t.expect_eq(#accepted, 1)
	t.expect_eq(accepted[1], ok)
	t.expect_eq(counters.repeats, 1)
	t.expect_eq(counters.rejects, 4)
	t.expect_eq(#core.accept(nil, seen, 0, counters), 0)
	t.expect_eq(counters.rejects, 5)
end)

t.test("inbound: an object-shaped batch (no array part) is rejected and counted, not silently empty", function()
	local counters = {}
	local accepted = core.accept({ note = { id = "aa.1", type = "ue.ping", payload = {} } }, {}, 0, counters)
	t.expect_eq(#accepted, 0)
	t.expect_eq(counters.rejects, 1)
end)

t.test("inbound: a batch with a hole rejects the whole batch instead of dropping the tail", function()
	local m1 = { id = "aa.1", type = "ue.ping", payload = {} }
	local m2 = { id = "aa.2", type = "ue.ping", payload = {} }
	local m3 = { id = "aa.3", type = "ue.ping", payload = {} }
	local holey = { m1, m2, m3 }
	holey[2] = nil
	local counters = {}
	local accepted = core.accept(holey, {}, 0, counters)
	t.expect_eq(#accepted, 0)
	t.expect_eq(counters.rejects, 1)
end)

-- #21: a chunked body's parts end on UTF-8 character boundaries, so the host decodes each part to the same text.
local function boundary_ok(parts, s, size)
	t.expect_eq(table.concat(parts), s, "the parts join to the body, byte for byte")
	for k, p in ipairs(parts) do
		t.expect_true(#p >= 1 and #p <= size, "part " .. k .. " is 1.." .. size .. " bytes: " .. #p)
		local b = string.byte(p, 1)
		t.expect_true(b < 0x80 or b >= 0xC0, "part " .. k .. " starts a character")
	end
end

t.test("chunks: ASCII is cut at exactly size bytes; a body of exactly size is one part; empty has none", function()
	local s = string.rep("abcdefghij", 30)
	local parts = core.chunks(s, 100)
	t.expect_eq(#parts, 3)
	boundary_ok(parts, s, 100)
	t.expect_same(core.chunks(string.rep("x", 100), 100), { string.rep("x", 100) })
	t.expect_eq(#core.chunks(string.rep("x", 101), 100), 2)
	t.expect_same(core.chunks("", 100), {})
end)

t.test("chunks: a 2, 3 or 4-byte character straddling every cut position moves the cut back to its start", function()
	for _, ch in ipairs({ "\195\166", "\226\130\172", "\240\159\152\128" }) do -- æ, €, 😀
		for pad = 0, 12 do
			local s = string.rep("a", pad) .. string.rep(ch, 10) .. "z"
			for size = 4, 13 do
				boundary_ok(core.chunks(s, size), s, size)
			end
		end
	end
end)

t.test("chunks: the issue's case, æø cut at 3 bytes, keeps each character whole", function()
	t.expect_same(core.chunks("\195\166\195\184", 3), { "\195\166", "\195\184" })
	t.expect_same(core.chunks("\195\166\195\184", 4), { "\195\166\195\184" })
end)
