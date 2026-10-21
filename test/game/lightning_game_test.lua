local t = require("modules/v2_test/testlib")

-- Lightning ignores UE's entities (owner, 2026-10-15; small-things 13). A destructible ue-link-belt and a vanilla
-- transport-belt, far apart on a surface of their own; a strike at each. The vanilla belt is hurt, the UE one is not.
local S = "fulgora"

t.case("lightning: a strike at a ue- entity does nothing, a strike at a vanilla belt hurts it (small-things 13)",
	function(ctx)
		local ue_belt, vanilla
		ctx.at(5, function()
			local surface = game.planets.fulgora.create_surface()
			surface.request_to_generate_chunks({ 0, 0 }, 3)
			surface.force_generate_chunk_requests()
		end)
		ctx.at(20, function()
			local surface = game.surfaces[S]
			ue_belt = surface.create_entity({ name = "ue-link-belt", position = { -40.5, 0.5 }, force = "player" })
			vanilla = surface.create_entity({ name = "transport-belt", position = { 64.5, 0.5 }, force = "player" })
			ctx.expect(ue_belt and ue_belt.destructible and vanilla, "both belts stand, the UE one destructible")
			surface.execute_lightning({ name = "lightning", position = ue_belt.position })
			surface.execute_lightning({ name = "lightning", position = vanilla.position })
		end)
		ctx.at(200, function()
			ctx.expect(ue_belt.valid and ue_belt.health == ue_belt.max_health, "the UE belt is untouched")
			ctx.expect(not vanilla.valid or vanilla.health < vanilla.max_health, "the vanilla belt was struck")
		end)
	end)
