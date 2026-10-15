local t = require("modules/v2_test/testlib")

t.case("both v2 modules load into a patched Space Age save", function(ctx)
	ctx.at(1, function()
		ctx.expect(script.active_mods["space-age"] ~= nil, "Space Age is enabled")
		ctx.expect(game.surfaces.nauvis ~= nil, "nauvis exists")
	end)
end)
