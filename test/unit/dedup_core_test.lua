local t = require("testlib")
local dedup = require("modules/universal_edges/runtime/dedup_core")

t.test("the sender is the boot id before the dot; anything else is malformed", function()
	t.expect_eq(dedup.sender("7e570000.12"), "7e570000")
	t.expect_eq(dedup.sender("nodot"), nil)
	t.expect_eq(dedup.sender("7e57.x"), nil)
	t.expect_eq(dedup.sender(12), nil)
end)

t.test("an id is new once; a repeat is refused; other senders are separate", function()
	local seen = {}
	t.expect_true(dedup.first_seen(seen, "aa.1", 0))
	t.expect_eq(dedup.first_seen(seen, "aa.1", 1), false)
	t.expect_true(dedup.first_seen(seen, "bb.1", 1))
end)

t.test("each sender keeps at most cap ids, forgetting the oldest", function()
	local seen = {}
	for i = 1, 3 do
		dedup.first_seen(seen, "aa." .. i, i, 2)
	end
	t.expect_true(dedup.first_seen(seen, "aa.1", 4, 2), "the oldest id was forgotten")
	t.expect_eq(dedup.first_seen(seen, "aa.3", 4, 2), false)
end)

t.test("at the cap the set holds exactly cap ids: the oldest are forgotten, the newest kept", function()
	local seen = {}
	for i = 1, 6 do
		dedup.first_seen(seen, "aa." .. i, i, 4)
	end
	local set = seen.aa
	t.expect_eq(set.tail - set.head + 1, 4)
	for i = 3, 6 do
		t.expect_eq(dedup.first_seen(seen, "aa." .. i, 7, 4), false, "id " .. i .. " is still held")
	end
	t.expect_true(dedup.first_seen(seen, "aa.1", 8, 4), "the oldest id was forgotten")
	t.expect_true(dedup.first_seen(seen, "aa.2", 9, 4), "the second oldest id was forgotten")
	t.expect_eq(set.tail - set.head + 1, 4)
end)

t.test("ids older than max_age are forgotten", function()
	local seen = {}
	dedup.first_seen(seen, "aa.1", 0, 10, 100)
	t.expect_eq(dedup.first_seen(seen, "aa.1", 100, 10, 100), false)
	t.expect_true(dedup.first_seen(seen, "aa.1", 101, 10, 100))
end)

t.test("a sender quiet for longer than max_age is dropped when a new sender appears", function()
	local seen = {}
	dedup.first_seen(seen, "aa.1", 0, 10, 100)
	dedup.first_seen(seen, "bb.1", 500, 10, 100)
	t.expect_eq(seen.aa, nil)
	t.expect_true(seen.bb ~= nil)
end)
