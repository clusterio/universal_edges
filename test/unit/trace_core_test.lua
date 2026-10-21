local t = require("testlib")
local core = require("modules/universal_edges/runtime/trace_core")

t.test("no id before the handshake: Lua has no randomness of its own", function()
	t.expect_error(function() core.new_id({ seq = 0 }) end, "handshake")
end)

t.test("ids are <boot id>.<seq>, counting from 1 for each boot", function()
	local rt = { boot_id = "7e570000", seq = 0 }
	t.expect_eq(core.new_id(rt), "7e570000.1")
	t.expect_eq(core.new_id(rt), "7e570000.2")
	rt.boot_id, rt.seq = "7e570001", 0
	t.expect_eq(core.new_id(rt), "7e570001.1")
end)
