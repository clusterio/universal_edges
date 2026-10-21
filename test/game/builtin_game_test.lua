local t = require("modules/v2_test/testlib")
local loop = require("modules/v2_test/loopback")
local connectors = require("modules/universal_edges/edges/connectors")

-- Built-in endpoints (cross-border biters plan Task 2): a type registered with builtin = <cid> gets that endpoint on
-- every live side, outside the controller's record, with no arrow, and an update that drops every configured connector
-- leaves it open. Its own surface, so no other case's sides or marks are touched.
local S = "ue-builtin"

t.case("builtin: the vehicle type's v is built in on both sides, has no arrow, and outlives the configured connectors",
	function(ctx)
		ctx.at(1900, function()
			game.create_surface(S, { seed = 20200, autoplace_controls = { ["enemy-base"] = { size = 0 } } })
			loop.ground(-40, -40, 104, 70, S)
			loop.edge("bi", 64, {}, { 0, 0, 0 }, { 64, 30, 8 }, S)
		end)
		ctx.at(1960, function()
			for _, id in ipairs({ "bi-x", "bi-y" }) do
				local side = storage.universal_edges.edges[id]
				local v = side and connectors.get(side, "v")
				ctx.expect(v ~= nil and v.builtin == true, id .. ": a built-in v")
				local rec = storage.universal_edges.marks[id]
				ctx.expect(rec ~= nil and rec.c.v == nil, id .. ": no arrow for v")
			end
			loop.connectors("bi", 2, {})
		end)
		ctx.at(1970, function()
			local v = connectors.get(storage.universal_edges.edges["bi-x"], "v")
			ctx.expect(v ~= nil and not v.closing, "v stays open after an update with no connectors")
		end)
	end)
