local t = require("modules/v2_test/testlib")

-- ue-barrier stops a mech-armor flyer as well as a walker (crossing-arrival spec §3, test 9; spike 39). Two lanes over
-- water on a surface of the test's own: a barrier at x = 60 in lane 1, none in lane 2 (the control).
local S = "ue-test-barrier-flyer"
local LANE = { 0, 40 }

t.case("barrier: a mech-armor flyer is stopped by ue-barrier, and flies through where there is none (spec §3)",
	function(ctx)
		local chars = {}
		ctx.at(3300, function()
			local surface = game.create_surface(S, { width = 400, height = 200, generate_with_lab_tiles = true })
			surface.request_to_generate_chunks({ 60, 20 }, 5)
			surface.force_generate_chunk_requests()
		end)
		ctx.at(3305, function()
			local surface = game.surfaces[S]
			local tiles = {}
			for _, y in ipairs(LANE) do
				for x = 20, 140 do
					for dy = -12, 12 do
						tiles[#tiles + 1] = { name = "water", position = { x, y + dy } }
					end
				end
			end
			surface.set_tiles(tiles)
			local barrier = surface.create_entity({ name = "ue-barrier", position = { 60, LANE[1] }, force = "neutral" })
			ctx.expect(barrier, "the barrier stands")
			for i, y in ipairs(LANE) do
				local c = surface.create_entity({ name = "character", position = { 30, y }, force = "player" })
				c.get_inventory(defines.inventory.character_armor).insert({ name = "mech-armor" })
				chars[i] = c
			end
		end)
		for tick = 3306, 3906 do
			ctx.at(tick, function()
				for _, c in ipairs(chars) do
					if c.valid then
						c.walking_state = { walking = true, direction = defines.direction.east }
					end
				end
			end)
		end
		ctx.at(3910, function()
			ctx.expect(chars[1].valid and chars[2].valid, "both characters are valid")
			ctx.expect(chars[1].position.x < 50, "lane 1 stopped before the barrier, x = " .. chars[1].position.x)
			ctx.expect(chars[1].is_flying, "lane 1's character is flying")
			ctx.expect(chars[2].position.x > 70, "lane 2 (no barrier) flew past x = 70, x = " .. chars[2].position.x)
			game.delete_surface(S)
		end)
	end)
