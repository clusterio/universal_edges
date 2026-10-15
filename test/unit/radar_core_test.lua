local t = require("testlib")
local core = require("modules/universal_edges/transports/radar_core")
local cc = require("modules/universal_edges/transports/circuit_core")

t.test("key: surface mode by planet, universe by channel (item and normal by default); nil off a planet or with no "
	.. "channel (§4, plan ruling 3)", function()
	t.expect_eq(core.key(false, "nauvis", nil), "s:nauvis")
	t.expect_eq(core.key(false, nil, nil), nil, "surface mode off a planet")
	t.expect_eq(core.key(true, "nauvis", { type = "virtual", name = "signal-A" }), "u:virtual:signal-A:normal")
	t.expect_eq(core.key(true, nil, { name = "iron-plate", quality = "rare" }), "u:item:iron-plate:rare")
	t.expect_eq(core.key(true, "nauvis", nil), nil, "universe mode with no channel")
end)

t.test("sum: injectors added as a wire adds them, int32-wrapped, zeros dropped (guard 6.2)", function()
	local a, b = {}, {}
	cc.put(a, "virtual", "normal", "signal-A", 2147483647)
	cc.put(b, "virtual", "normal", "signal-A", 1)
	cc.put(a, "item", "normal", "iron-plate", 5)
	cc.put(b, "item", "normal", "iron-plate", -5)
	cc.put(b, "item", "rare", "iron-plate", 3)
	local m = core.sum({ a, b })
	t.expect_eq(cc.get(m, "virtual", "normal", "signal-A"), -2147483648)
	t.expect_eq(cc.get(m, "item", "normal", "iron-plate"), nil, "5 - 5 is dropped")
	t.expect_eq(cc.get(m, "item", "rare", "iron-plate"), 3)
	t.expect_eq(cc.size(m), 2)
	t.expect_eq(cc.get(a, "virtual", "normal", "signal-A"), 2147483647, "the inputs are untouched")
end)

t.test("own on a merged network: network − both injectors; an injected signal the network lacks is −inj "
	.. "(guard 6.2, circuit §7.2)", function()
	local inj1, inj2 = {}, {}
	cc.put(inj1, "virtual", "normal", "signal-X", 3)
	cc.put(inj2, "virtual", "normal", "signal-X", 4)
	cc.put(inj2, "virtual", "normal", "signal-Y", 2)
	-- the API's read: signal-X is 3 + 4 injected and 3 own; signal-Y's injected 2 is cancelled by a real -2
	local sigs = { { signal = { type = "virtual", name = "signal-X" }, count = 10 } }
	local own = cc.remainder(sigs, core.sum({ inj1, inj2 }))
	t.expect_eq(cc.get(own, "virtual", "normal", "signal-X"), 3)
	t.expect_eq(cc.get(own, "virtual", "normal", "signal-Y"), -2)
	t.expect_eq(cc.size(own), 2)
end)

t.test("join and common: sorted key lists, and whether two name a whole key in common (guard 6.1)", function()
	t.expect_eq(core.join({}), nil)
	t.expect_eq(core.join({ "u:virtual:signal-A:normal", "s:nauvis" }), "s:nauvis,u:virtual:signal-A:normal")
	t.expect_eq(core.common("s:nauvis,u:virtual:signal-A:normal", "u:virtual:signal-A:normal"), true)
	t.expect_eq(core.common("s:nauvis", "s:vulcanus"), false)
	t.expect_eq(core.common("s:nauvis", "s:nauvis-2"), false, "whole keys only")
	t.expect_eq(core.common(nil, "s:nauvis"), false)
	t.expect_eq(core.common("s:nauvis", nil), false)
end)
