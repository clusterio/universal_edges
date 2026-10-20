-- Belt spacing spec §3: a UE belt per transport-belt tier, so each side's stubs match its border belt (G2). ue-link-belt
-- (data.lua) is the yellow tier's; every other transport belt loaded gets ue-link-belt-<name>, a copy with its own speed
-- and graphics and ue-link-belt's changes. Made here, before the lightning exemptions below, which take them by their
-- ue- prefix. Space Age gives belts heating_energy in its data-updates, after data.lua's copy and before these, and
-- turbo defines its own: none of them heats (surfaces spec S3).
local link = data.raw["transport-belt"]["ue-link-belt"]
local tiers = {} -- collected first: data:extend inside pairs() would add keys mid-traversal
for name, p in pairs(data.raw["transport-belt"]) do
	if name ~= "transport-belt" and string.sub(name, 1, 3) ~= "ue-" then
		local b = table.deepcopy(p)
		b.name, b.hidden, b.minable, b.flags = "ue-link-belt-" .. name, true, nil, table.deepcopy(link.flags)
		b.next_upgrade, b.fast_replaceable_group, b.heating_energy = nil, nil, nil
		tiers[#tiers + 1] = b
	end
end
data:extend(tiers)
link.heating_energy = nil

-- SP3b (SP3 spec §5.4, D11): the train boxes' entities. They are copied here, after every mod's data stage, because
-- elevated-rails sets rail-signal's elevated_picture_set in its data stage (elevated-rails.lua:391). [probe]
-- sp3b-plan: these copies work on both layers. SP4 (§5) removed the edge stop: every hop is the box's end rail.
local function ue_copy(type_name, name, new_name, hidden)
	local p = table.deepcopy(data.raw[type_name][name])
	p.name, p.localised_name = new_name, { "entity-name." .. name }
	p.hidden, p.hidden_in_factoriopedia, p.minable = hidden, true, nil
	p.flags = { "not-blueprintable", "not-deconstructable", "not-upgradable", "not-in-kill-statistics", "player-creation" }
	data:extend({ p })
end
ue_copy("rail-signal", "rail-signal", "ue-rail-signal", true)
ue_copy("constant-combinator", "constant-combinator", "ue-hold-combinator", true)

-- The logistic link (logistic-link spec §6.3): a link requester per requester-mode chest, and a link provider per
-- requester chest, so mining either gives that chest back (owner, 2026-10-04). Made here, after every mod's data stage,
-- so modded requester chests and their final fields are seen (N3). No item places them (no placeable_by, and no
-- item's place_result names them), so nothing can fast-replace, upgrade or blueprint one; they stay deconstructable
-- and repairable (player-creation), and leave no ghost when destroyed.
local function link_chest(p, name)
	local c = table.deepcopy(p)
	c.name, c.localised_name = name, p.localised_name or { "entity-name." .. p.name }
	c.hidden, c.hidden_in_factoriopedia = true, true
	c.flags = { "placeable-player", "player-creation", "not-blueprintable", "not-upgradable" }
	c.fast_replaceable_group, c.next_upgrade, c.placeable_by = nil, nil, nil
	c.create_ghost_on_death = false
	return c
end
local passive = data.raw["logistic-container"]["passive-provider-chest"]
local copies = {} -- collected first: data:extend inside pairs() would add keys mid-traversal
for name, p in pairs(data.raw["logistic-container"]) do
	if p.logistic_mode == "requester" and string.sub(name, 1, 3) ~= "ue-" then
		copies[#copies + 1] = link_chest(p, "ue-link-" .. name) -- keeps minable: mining gives the placed chest back
		local provider = link_chest(passive, "ue-link-provider-" .. name)
		provider.minable = table.deepcopy(p.minable) -- mining the provider gives the placed chest back too (owner)
		copies[#copies + 1] = provider
	end
end
data:extend(copies)

-- The oracle (cross-border biters spec §6.3; spikes 25, 27, 28; spike 34 O5): a hidden copy of an enemy spawner that
-- spawns only "<name>-unit", an invisible copy of the planet's smallest unit that does no damage (spike 28 H1) and, like
-- its spawner, collides with nothing (plan ruling R14), so it names vanilla's target without touching anything or
-- blocking building (small-things 15). On Factorio 2.1.22 a collision-less unit with no buildable_entities, together with
-- gridworld removing units as they spawn outside the tile, desyncs joining clients (the next expansion party gathers
-- 15*k tiles off); Wube fixed it for the release after 2.1.22 (forums t=136571). The vanilla-mask workaround (a303a52)
-- was reverted (owner, 2026-10-20): cross-border raids stay off until the fixed release (raids are what place oracles).
-- UE places one outside each live side and makes each unit indestructible as it spawns. In data-final-fixes, beside
-- Gleba's copy
-- (plan Task 13), whose prototypes Space Age defines. The control script places it on force ue-oracle, not enemy: the
-- expansion planner counts an enemy oracle as a base (spike 42).
local function oracle(spawner, unit, name)
	local EMPTY = { filename = "__core__/graphics/empty.png", width = 1, height = 1, frame_count = 1, direction_count = 1 }
	local u = table.deepcopy(data.raw.unit[unit])
	u.name, u.hidden = name .. "-unit", true
	u.factoriopedia_simulation, u.corpse, u.dying_explosion, u.water_reflection = nil, nil, nil, nil
	u.run_animation, u.attack_parameters.animation = table.deepcopy(EMPTY), table.deepcopy(EMPTY)
	u.collision_mask = { layers = {} }
	u.selectable_in_game = false
	-- no bases from oracle units: the copy kept small-biter's buildable_entities, so vanilla formed expansion parties at
	-- oracles and UE then destroyed their members (spikes 37 and 38; owner, 2026-10-15)
	u.buildable_entities = nil
	-- silent: every top-level *sound field of either copy (working, walking, dying; the spawner's too), the attack roar
	-- and the pentapods' warcry
	local function silence(t)
		for k in pairs(t) do
			if type(k) == "string" and string.find(k, "sound", 1, true) and k ~= "running_sound_animation_positions" then
				t[k] = nil
			end
		end
	end
	silence(u)
	u.attack_parameters.sound, u.warcry = nil, nil
	u.flags = { "placeable-enemy", "placeable-off-grid", "not-on-map", "not-repairable" } -- no red dot on the map
	local function zero(x)
		if type(x) ~= "table" then
			return
		end
		if x.type == "damage" and x.damage then
			x.damage.amount = 0
		end
		for _, v in pairs(x) do
			zero(v)
		end
	end
	zero(u.attack_parameters.ammo_type)
	-- spike 34 G2: Gleba's wriggler has join_attacks false, so its oracle would never form a group; small-biter already
	-- has it true, so the Nauvis oracle is unchanged.
	u.ai_settings = u.ai_settings or {}
	u.ai_settings.join_attacks = true
	local s = table.deepcopy(data.raw["unit-spawner"][spawner])
	s.name, s.hidden, s.autoplace, s.corpse, s.dying_explosion, s.dying_trigger_effect = name, true, nil, nil, nil, nil
	s.graphics_set = { animations = { { filename = EMPTY.filename, width = 1, height = 1, frame_count = 1 } } }
	silence(s)
	s.selectable_in_game, s.collision_mask = false, { layers = {} }
	s.flags = { "placeable-enemy", "not-on-map", "not-repairable" } -- no red dot on the map
	s.result_units = { { u.name, { { 0.0, 1 }, { 1.0, 1 } } } }
	s.spawn_decoration, s.spawn_decorations_on_expansion = nil, false
	data:extend({ u, s })
end
oracle("biter-spawner", "small-biter", "ue-oracle")
if data.raw["unit-spawner"]["gleba-spawner"] and data.raw.unit["small-wriggler-pentapod"] then
	oracle("gleba-spawner", "small-wriggler-pentapod", "ue-oracle-gleba") -- spike 34 G2
end

-- The sink absorbs Gleba's spores too (spike 34 G1), once Space Age defines them.
if data.raw["airborne-pollutant"] and data.raw["airborne-pollutant"].spores then
	data.raw.tree["ue-pollution-sink"].emissions_per_second.spores = -5000
end

-- Lightning ignores everything UE places (owner, 2026-10-15; small-things 13): the entities are indestructible, but
-- every strike raised an alert on Fulgora. Last, so every ue- entity above exists, whatever its type.
for _, planet in pairs(data.raw.planet) do
	local lightning = planet.lightning_properties
	if lightning then
		lightning.exemption_rules = lightning.exemption_rules or {}
		for type_name in pairs(defines.prototypes.entity) do
			for name in pairs(data.raw[type_name] or {}) do
				if string.sub(name, 1, 3) == "ue-" then
					table.insert(lightning.exemption_rules, { type = "id", string = name })
				end
			end
		end
	end
end
