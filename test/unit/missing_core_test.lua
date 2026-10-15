local t = require("testlib")
local core = require("modules/universal_edges/transports/missing_core")

local HAVE = { entity = { locomotive = true, ["cargo-wagon"] = true }, item = { coal = true, ["iron-plate"] = true },
	quality = { normal = true, rare = true } }

t.test("missing: entity, then quality, then every inventory's items and filters, in order; nil when all known (I1, M3)", function()
	t.expect_eq(core.missing("locomotive", "normal", {}, HAVE), nil)
	local kind, name = core.missing("sp3b-missing", "normal", {}, HAVE)
	t.expect_eq(kind, "entity")
	t.expect_eq(name, "sp3b-missing")
	kind, name = core.missing("locomotive", "sp3b-missing", {}, HAVE)
	t.expect_eq(kind, "quality")
	t.expect_eq(name, "sp3b-missing")
	kind, name = core.missing("locomotive", "normal", { { i = { { n = "sp3b-missing" } } } }, HAVE)
	t.expect_eq(kind, "item")
	t.expect_eq(name, "sp3b-missing")
	kind, name = core.missing("locomotive", "normal", { { i = { { n = "coal", q = "sp3b-missing" } } } }, HAVE)
	t.expect_eq(kind, "quality")
	t.expect_eq(name, "sp3b-missing")
	kind, name = core.missing("locomotive", "normal", { { i = { { s = 2, f = { name = "sp3b-missing" } } } } }, HAVE)
	t.expect_eq(kind, "item")
	t.expect_eq(name, "sp3b-missing")
	kind, name = core.missing("locomotive", "normal",
		{ { i = { { s = 2, f = { name = "coal", quality = "sp3b-missing" } } } } }, HAVE)
	t.expect_eq(kind, "quality")
	t.expect_eq(name, "sp3b-missing")
	t.expect_eq(core.missing("locomotive", "normal", { { b = 1, i = { { n = "coal", c = 5 } } } }, HAVE), nil)
	-- a second carriage's inventory is reached, and a nil name/quality (a wagon with no riders, no quality field) is
	-- never checked: the caller decides whether a missing name/quality means anything.
	kind, name = core.missing(nil, nil, { { i = {} }, { i = { { n = "sp3b-missing" } } } }, HAVE)
	t.expect_eq(kind, "item")
	t.expect_eq(name, "sp3b-missing")
	t.expect_eq(core.missing(nil, nil, {}, HAVE), nil)
end)
