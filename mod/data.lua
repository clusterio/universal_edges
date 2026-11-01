-- ue-barrier (SP1 spec §9): a 20×20 invisible wall on the object and player layers. UE's scripts place it outside
-- every live edge side; players can't see, select, mine, blueprint or damage it.
-- trigger_target: a mech-armor flyer's mask is trigger_target only, so without it the barrier stops walkers but not
-- flyers (crossing-arrival spec §3, spike 39).
data:extend({
	{
		type = "simple-entity",
		name = "ue-barrier",
		icon = "__base__/graphics/icons/assembling-machine-1.png",
		hidden = true,
		flags = {
			"placeable-neutral", "not-on-map", "not-blueprintable", "not-deconstructable", "not-upgradable",
			"not-flammable", "no-automated-item-removal", "no-automated-item-insertion",
		},
		collision_mask = { layers = { object = true, player = true, trigger_target = true } },
		collision_box = { { -10, -10 }, { 10, 10 } },
		selectable_in_game = false,
	},
})

-- SP3a (spec §5.4), SP3 visuals batch. UE's link entities: hidden, not minable, blueprintable or upgradable.
-- `ue-link-belt` is the yellow tier's UE belt; data-final-fixes.lua adds one per other tier (belt spacing spec §3).
local NOFLAGS = { "placeable-neutral", "not-blueprintable", "not-deconstructable", "not-upgradable", "not-on-map" }

local belt = table.deepcopy(data.raw["transport-belt"]["transport-belt"])
belt.name, belt.hidden, belt.minable, belt.flags = "ue-link-belt", true, nil, NOFLAGS
belt.next_upgrade, belt.fast_replaceable_group = nil, nil

--- Halve a Sprite's (or each layer's) scale and shift together, so it keeps its proportions at half the size.
local function shrink(sprite, factor)
	for _, layer in ipairs(sprite.layers or { sprite }) do
		layer.scale = (layer.scale or 1) * factor
		if layer.shift then
			layer.shift = { layer.shift[1] * factor, layer.shift[2] * factor }
		end
	end
end

local function interface(name, priority, buffer)
	local i = table.deepcopy(data.raw["electric-energy-interface"]["electric-energy-interface"])
	i.name, i.hidden, i.minable, i.flags = name, true, nil, NOFLAGS
	i.collision_box, i.selection_box = { { -0.35, -0.35 }, { 0.35, 0.35 } }, { { -0.5, -0.5 }, { 0.5, 0.5 } }
	-- collides with nothing and can't be selected: a 2×2 pole across the line covers the link interface's tile, the
	-- partner's interface is often there before the player places that side's pole (power_game_test.lua), and the pole,
	-- not the interface, must take the hover over that tile
	i.selectable_in_game, i.collision_mask = false, { layers = {} }
	i.energy_source = { type = "electric", usage_priority = priority, buffer_capacity = buffer,
		input_flow_limit = "1TW", output_flow_limit = "1TW" }
	i.energy_production, i.energy_usage, i.gui_mode = "0W", "0W", "none"
	-- 2.1.20's vanilla electric-energy-interface draws a `picture` (a Sprite, accumulator art at scale 0.5 — no
	-- `pictures`, `animation` or `animations`: checked against data/base/prototypes/entity/entities.lua:8946); its
	-- ~2×2-tile accumulator picture spills past this 1×1 box, so it's halved again to fit.
	assert(i.picture and not i.pictures and not i.animation and not i.animations, "interface: unexpected picture field")
	shrink(i.picture, 0.5)
	return i
end

-- An underground pipe reads as "joined to the player's border pipe" where a storage tank's bigger picture and
-- corner-drawn pipe covers didn't (owner, 2026-10-04). A copy of vanilla pipe-to-ground, keeping only its
-- above-ground ("normal") connection — the underground one is dropped so it never reaches for a real underground
-- pipe up to 10 tiles away.
local pipe = table.deepcopy(data.raw["pipe-to-ground"]["pipe-to-ground"])
pipe.name, pipe.hidden, pipe.minable, pipe.flags = "ue-link-pipe", true, nil, NOFLAGS
pipe.fast_replaceable_group, pipe.circuit_connector = nil, nil
pipe.fluid_box.volume = 25000
-- Checked against data/base/prototypes/entity/entities.lua:3022-3037: pipe_connections[1] is the normal connection,
-- direction = north, i.e. the same side the unrotated entity faces (not the opposite side) — so built facing inward
-- exactly as the tank was, this connection also faces inward and joins the border pipe's segment ([probe]).
pipe.fluid_box.pipe_connections[2] = nil

data:extend({
	belt,
	-- power hub spec §5: dynamic, so the hub can set each link's class and cap at runtime; a new one starts in
	-- tertiary_input_output, today's tertiary behaviour (spike 45 P1); resized at runtime
	interface("ue-link-interface", "dynamic", "10MJ"),
	-- Test-only (plan ruling 6; power hub plan ruling 13): the game tests', E2Es' and bench's generator, of any class
	-- (electric_interface_mode), and sink. Nothing in UE places them.
	interface("ue-test-power-source", "dynamic", "100GJ"),
	interface("ue-test-power-sink", "secondary-input", "100GJ"),
	pipe,
})

-- The circuit link's injector (circuit-link spec §5.4, D11, C6 a): a constant combinator players can't see, select,
-- wire, mine or collide with. UE writes the far side's signals into it and wires it to the border pole by script.
local injector = table.deepcopy(data.raw["constant-combinator"]["constant-combinator"])
local EMPTY = { filename = "__core__/graphics/empty.png", size = 1 }
injector.name, injector.hidden, injector.minable, injector.flags = "ue-link-combinator", true, nil, NOFLAGS
injector.selectable_in_game, injector.collision_mask, injector.draw_circuit_wires = false, { layers = {} }, false
injector.sprites, injector.activity_led_sprites = EMPTY, EMPTY
injector.fast_replaceable_group, injector.next_upgrade = nil, nil
data:extend({ injector })

-- The radar sync's host (radar-sync spec §4): a radar players can't see, select, mine or collide with, that charts
-- nothing and draws nothing (vanilla's radar is already no military target). UE places one per radar network a tile
-- uses, at the spawn position, and wires its injectors to it by script. Its energy source is plan Task 1's decision.
local host = table.deepcopy(data.raw.radar.radar)
host.name, host.hidden, host.minable, host.flags = "ue-link-radar", true, nil, NOFLAGS
host.selectable_in_game, host.collision_mask, host.draw_circuit_wires = false, { layers = {} }, false
host.max_distance_of_sector_revealed, host.max_distance_of_nearby_sector_revealed = 0, 0
host.connects_to_other_radars, host.energy_usage = true, "1kW"
host.energy_source = { type = "void" }
host.pictures = { filename = EMPTY.filename, size = 1, direction_count = 1 }
host.integration_patch, host.water_reflection, host.frozen_patch, host.working_sound = nil, nil, nil, nil
host.fast_replaceable_group, host.next_upgrade, host.corpse, host.dying_explosion = nil, nil, nil, nil
data:extend({ host })

-- SP4 station panel: Ctrl+F (the player's own "focus-search" binding) focuses its search box; consuming "none" leaves
-- vanilla's own Ctrl+F working.
data:extend({
	{ type = "custom-input", name = "ue-focus-search", key_sequence = "", linked_game_control = "focus-search", consuming = "none" },
})

-- The pollution sink (cross-border biters spec §4, plan ruling R1): an invisible tree that absorbs 5000 of the surface's
-- pollutant per chunk update (spike 27: a tree-type sink of rate R takes R per update, before the chunk spreads), which
-- fire can't kill (spike 28 H2: max_health 1000000 and not-flammable). Gridworld places one in every chunk of each tile's
-- second outside row; the "ue-" name keeps it through gridworld's cleanup (ue.owns). Gleba's spores join in
-- data-final-fixes once spike 34 G1 holds (plan Task 13).
do
	local BLANK = { filename = "__core__/graphics/empty.png", width = 1, height = 1, frame_count = 1, direction_count = 1 }
	local sink = table.deepcopy(data.raw.tree["tree-01"])
	sink.name, sink.localised_name, sink.hidden = "ue-pollution-sink", "Pollution sink", true
	sink.factoriopedia_simulation, sink.factoriopedia_alternative, sink.deconstruction_alternative = nil, nil, nil
	sink.minable, sink.corpse, sink.remains_when_mined, sink.autoplace = nil, nil, nil, nil
	sink.ambient_sounds, sink.ambient_sounds_group, sink.mined_sound, sink.damaged_trigger_effect = nil, nil, nil, nil
	sink.emissions_per_second = { pollution = -5000 }
	sink.collision_mask, sink.collision_box = { layers = {} }, { { -0.1, -0.1 }, { 0.1, 0.1 } }
	sink.selectable_in_game, sink.max_health = false, 1000000
	sink.flags = { "placeable-neutral", "placeable-off-grid", "breaths-air", "not-on-map", "not-blueprintable",
		"not-deconstructable", "not-flammable" }
	-- a tree's shadow needs one frame more than its leaves (spike 27's load error)
	local shadow = { filename = BLANK.filename, width = 1, height = 1, frame_count = 2, direction_count = 1 }
	sink.variations = { { trunk = table.deepcopy(BLANK), leaves = table.deepcopy(BLANK), shadow = shadow } }
	sink.variation_weights = nil
	data:extend({ sink })
end
