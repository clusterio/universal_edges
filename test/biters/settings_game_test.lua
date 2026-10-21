local t = require("modules/v2_test/testlib")
-- Map settings are set field by field in place (spike 17), which luacheck reads as writing a read-only global's field.
-- luacheck: ignore 122

-- The biters run (cross-border biters plan ruling R10) is a save of its own, so its map settings are its own: vanilla's
-- gathering wait cut to spike 17's 120..300 ticks, expansion off. Set at the first tick; every other case starts at 5 or
-- later, each on a surface of its own with no natural enemies.
t.case("biters run: gathering times cut, expansion off", function(ctx)
	ctx.at(0, function()
		local ug = game.map_settings.unit_group
		ug.min_group_gathering_time, ug.max_group_gathering_time, ug.max_wait_time_for_late_members = 120, 300, 120
		game.map_settings.enemy_expansion.enabled = false
		ctx.expect(game.map_settings.unit_group.max_group_gathering_time == 300, "set in place")
	end)
end)
