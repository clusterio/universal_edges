local t = require("testlib")
local core = require("modules/universal_edges/transports/logistic_core")

--- A candidate as logistic.lua builds one: { key, count, stack size }.
local function C(key, n, s)
	return { key, n, s }
end

t.test("keys: two fields, or three with the freshness; they parse back; a malformed key parses to nil", function()
	t.expect_eq(core.key("iron-plate", "normal"), "iron-plate|normal")
	t.expect_eq(core.key("yumako", "rare", 37), "yumako|rare|37")
	t.expect_eq(core.key("yumako", "rare", 0), "yumako|rare|0", "fresh is 0, not absent")
	for _, c in ipairs({ { "iron-plate", "normal" }, { "my_mod-item_2", "legendary" }, { "yumako", "uncommon", 100 },
		{ "a-b_c", "q_1-x", 5 } }) do
		local name, quality, p = core.parse(core.key(c[1], c[2], c[3]))
		t.expect_eq(name, c[1], "the name of " .. c[1])
		t.expect_eq(quality, c[2], "the quality of " .. c[1])
		t.expect_eq(p, c[3], "the freshness of " .. c[1])
	end
	for _, bad in ipairs({ "iron-plate", "", "|normal", "iron-plate|" }) do
		t.expect_eq(core.parse(bad), nil, "malformed: '" .. bad .. "'")
	end
end)

t.test("plan: whole slots per key, a partial take of one item's total, several items sharing the slot budget", function()
	local c = { C("iron-plate|normal", 250, 100) }
	local bag, total, first = core.plan(c, 2, nil)
	t.expect_same(bag, { ["iron-plate|normal"] = 200 }, "two slots of a 250 total")
	t.expect_eq(total, 200)
	t.expect_eq(first, "iron-plate|normal")
	t.expect_eq(c[1].take, 200, "the candidate carries its take")
	t.expect_same(core.plan({ C("a|normal", 150, 100), C("b|normal", 30, 50) }, 3, nil),
		{ ["a|normal"] = 150, ["b|normal"] = 30 }, "a takes two slots (150 is 1.5 stacks), b the third")
	t.expect_same(core.plan({ C("a|normal", 150, 100), C("b|normal", 30, 50) }, 2, nil), { ["a|normal"] = 150 },
		"a's two slots spend the budget")
end)

t.test("plan: stack sizes 1, 50 and 200; no free slot takes nothing", function()
	t.expect_same(core.plan({ C("power-armor|normal", 5, 1) }, 3, nil), { ["power-armor|normal"] = 3 })
	t.expect_same(core.plan({ C("yumako|normal", 120, 50) }, 2, nil), { ["yumako|normal"] = 100 })
	t.expect_same(core.plan({ C("copper-cable|normal", 1000, 200) }, 4, nil), { ["copper-cable|normal"] = 800 })
	local bag, total = core.plan({ C("a|normal", 5, 100) }, 0, nil)
	t.expect_same(bag, {}, "free = 0")
	t.expect_eq(total, 0)
end)

t.test("plan: candidates are sorted by key; the rotation starts after last_key and wraps (L15, plan ruling 3)", function()
	local function three()
		return { C("c|normal", 100, 100), C("a|normal", 100, 100), C("b|normal", 100, 100) }
	end
	local bag, _, first = core.plan(three(), 1, nil)
	t.expect_same(bag, { ["a|normal"] = 100 }, "sorted, whatever the input order")
	t.expect_eq(first, "a|normal")
	_, _, first = core.plan(three(), 1, "a|normal")
	t.expect_eq(first, "b|normal", "right after last_key")
	_, _, first = core.plan(three(), 1, "c|normal")
	t.expect_eq(first, "a|normal", "past the last key: wraps to the top")
	_, _, first = core.plan({ C("a|normal", 100, 100), C("c|normal", 100, 100) }, 1, "b|normal")
	t.expect_eq(first, "c|normal", "last_key no longer a candidate: the next key after it in order")
	_, _, first = core.plan({ C("a|normal", 100, 100) }, 1, "b|normal")
	t.expect_eq(first, "a|normal", "last_key gone and nothing after it: the top")
end)

t.test("plan: two keys sharing one free slot take turns going first", function()
	local got, last = {}, nil
	for i = 1, 4 do
		local bag, _, first = core.plan({ C("iron-plate|normal", 500, 100), C("copper-plate|normal", 500, 100) }, 1, last)
		last, got[i] = first, next(bag)
	end
	t.expect_same(got, { "copper-plate|normal", "iron-plate|normal", "copper-plate|normal", "iron-plate|normal" })
end)

t.test("plan: single stacks (the detailed path) go whole or wait; stacks of one key sum into one bag entry", function()
	local c = { C("yumako|normal|30", 50, 50), C("yumako|normal|10", 50, 50), C("yumako|normal|20", 50, 50) }
	t.expect_same(core.plan(c, 2, nil), { ["yumako|normal|10"] = 50, ["yumako|normal|20"] = 50 })
	t.expect_eq(c[3].take, nil, "the third stack (yumako|normal|30, sorted last) waits whole")
	t.expect_same(core.plan({ C("yumako|normal|10", 50, 50), C("yumako|normal|10", 20, 50) }, 2, nil),
		{ ["yumako|normal|10"] = 70 })
end)

t.test("open: only on a status with free and r that counts everything sent (L2)", function()
	t.expect_true(not core.open(0, nil), "no status")
	t.expect_true(not core.open(0, { gone = "lost" }), "a gone status")
	t.expect_true(not core.open(0, { r = 0 }), "no free")
	t.expect_true(not core.open(0, { free = 3 }), "no r")
	t.expect_true(core.open(5, { free = 3, r = 7 }), "sent < r (a source rollback): open")
	t.expect_true(core.open(7, { free = 3, r = 7 }), "sent = r")
	t.expect_true(not core.open(8, { free = 3, r = 7 }), "sent > r: a shipment in flight")
end)

t.test("removal: every row of §8.2 step 2 (L18)", function()
	t.expect_eq(core.removal("lost", "ready", "drained", false), "request", "the partner drained")
	t.expect_eq(core.removal("lost", "ready", "drained", true), "request")
	t.expect_eq(core.removal("lost", "ready", "lost", true), "request", "both lost: the source asks")
	for _, state in ipairs({ "pending", "blocked", "failed", "closing" }) do
		t.expect_eq(core.removal("lost", state, nil, false), "request", "a partner " .. state .. " will never drain")
		t.expect_eq(core.removal("lost", state, nil, true), "request", "a partner " .. state .. ", at the source")
	end
	t.expect_eq(core.removal(nil, "ready", "lost", true), "drain", "the provider gone: the source drains")
	t.expect_eq(core.removal(nil, "ready", "lost", false), "drain", "the requester gone: the destination drains")
end)

t.test("removal: and its negatives", function()
	t.expect_eq(core.removal("lost", "ready", nil, true), nil, "a ready partner that reports nothing yet: wait")
	t.expect_eq(core.removal("lost", nil, nil, true), nil, "a partner not heard from: wait")
	t.expect_eq(core.removal("lost", "ready", "lost", false), nil, "both lost: the destination waits for the source")
	t.expect_eq(core.removal("drained", "ready", "lost", true), nil, "a drained side never acts")
	t.expect_eq(core.removal("drained", "closing", nil, false), nil, "a drained side never acts")
	t.expect_eq(core.removal(nil, "ready", nil, true), nil, "both stand")
	t.expect_eq(core.removal(nil, "ready", "drained", false), nil, "a standing side drains only on lost")
	t.expect_eq(core.removal(nil, "blocked", nil, true), nil, "a standing side ignores a blocked partner")
end)
