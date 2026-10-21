-- The logistic link (logistic-link spec §12.3), over the SP3 loopback. Ground: nauvis x 11196–11903, side a's line at
-- y 3000 and side b's at y 2000; one 8-long edge per case, 20 tiles apart from x 11200 (Tasks 1–3) and 40 apart from
-- x 11480 (Task 4, whose spills need room). Ticks 300–1300. Edges are "lg-<case>".
local t = require("modules/v2_test/testlib")
local loop = require("modules/v2_test/loopback")
local layouts = require("modules/v2_test/layouts")
local ue = require("modules/universal_edges")
local bridge = require("modules/universal_edges/runtime/bridge")
local connectors = require("modules/universal_edges/edges/connectors")
local logistic = require("modules/universal_edges/transports/logistic")

local MAIN, TRASH = defines.inventory.chest, defines.inventory.logistic_container_trash
local MEMBER = defines.logistic_member_index.logistic_container
local RED = defines.wire_connector_id.circuit_red

t.case("logistic: each link chest keeps its original's inventories at every quality, mines back the placed " ..
	"requester chest, and nothing places, replaces, upgrades or blueprints it (spec §6.3)", function(ctx)
	ctx.at(300, function()
		local P = prototypes.entity
		for _, pair in ipairs({ { "ue-link-requester-chest", "requester-chest" },
			{ "ue-link-provider-requester-chest", "passive-provider-chest" } }) do
			local c, o = P[pair[1]], P[pair[2]]
			ctx.expect(c ~= nil, pair[1] .. " exists")
			if c then
				ctx.expect(c.logistic_mode == o.logistic_mode, pair[1] .. " is a " .. o.logistic_mode)
				ctx.expect(c.hidden and c.has_flag("not-blueprintable") and c.has_flag("not-upgradable")
					and c.has_flag("player-creation"), pair[1] .. ": hidden, not blueprintable, not upgradable")
				-- an unset group reads back as the entity's own name (2.1.20): a group of one, so nothing else shares it
				ctx.expect((c.fast_replaceable_group == nil or c.fast_replaceable_group == c.name) and c.next_upgrade == nil
					and #(c.items_to_place_this or {}) == 0, pair[1] .. ": nothing replaces, upgrades or places it")
				ctx.expect(not c.create_ghost_on_death, pair[1] .. ": no ghost on death")
				local m = c.mineable_properties
				ctx.expect(m.minable and m.products and #m.products == 1 and m.products[1].name == "requester-chest",
					pair[1] .. " mines back the requester chest")
				for _, q in ipairs({ "normal", "legendary" }) do
					for _, id in ipairs({ MAIN, TRASH }) do
						ctx.expect(c.get_inventory_size(id, q) == o.get_inventory_size(id, q),
							pair[1] .. ": inventory " .. id .. " at " .. q .. " is " .. pair[2] .. "'s")
					end
				end
			end
		end
	end)
end)

--- The endpoint of cid c1 on edge, or nil.
local function ep(edge)
	local side = storage.universal_edges.edges[edge]
	return side and connectors.get(side, "c1")
end

--- The proposals queued for edge so far this tick (they wait in the bridge's queue until the tick's flush).
local function proposals(edge)
	local found = {}
	for _, msg in ipairs(storage.universal_edges.bridge.out.universal_edges or {}) do
		if msg.type == "ue.connector.propose" and msg.payload.edge == edge then
			found[#found + 1] = msg.payload
		end
	end
	return found
end

-- Plan ruling 8: whether the requester at the belt's column proposes depends on the circuit plan's FC2 (it does once FC2
-- is in, and the controller refuses the overlap); what both orders share is that the belt doesn't take it.
t.case("logistic: detection — a requester in a border row proposes a logistic connector from its side, with its " ..
	"quality and chest; passive, active, buffer and storage chests propose nothing; a belt's column doesn't take it " ..
	"(spec §5)", function(ctx)
	local fa, fb
	ctx.at(300, function()
		fa, fb = layouts.edge(loop, "lg-det", 11200, 8, { { cid = "c1", type = "belt", pos = 5, width = 1,
			params = { dir = "ab" } } }, 8)
	end)
	ctx.at(302, function()
		layouts.put(fa, "requester-chest", 0.5, 0.5, 0, { quality = "uncommon", raise_built = true })
		for i, name in ipairs({ "passive-provider-chest", "active-provider-chest", "buffer-chest", "storage-chest" }) do
			layouts.put(fa, name, i + 0.5, 0.5, 0, { raise_built = true })
		end
		local covered = layouts.put(fa, "requester-chest", 5.5, 0.5, 0, { raise_built = true })
		layouts.put(fb, "requester-chest", 6.5, 0.5, 0, { raise_built = true })
		local by_pos = {}
		for _, p in ipairs(proposals("lg-det-x")) do
			by_pos[p.pos] = p
		end
		local p = by_pos[0]
		ctx.expect(p and p.type == "logistic" and p.width == 1 and p.params.dir == "ab" and p.params.q == "uncommon"
			and p.params.chest == "requester-chest", "column 0's requester proposes: " .. serpent.line(p))
		for pos = 1, 4 do
			ctx.expect(by_pos[pos] == nil, "column " .. pos .. "'s chest proposes nothing: " .. serpent.line(by_pos[pos]))
		end
		ctx.expect(ep("lg-det-x").data.border ~= covered, "the belt at column 5 doesn't take the requester")
		local q = proposals("lg-det-y")[1]
		ctx.expect(q and q.type == "logistic" and q.pos == 1 and q.params.dir == "ba",
			"side b's requester sends from b: " .. serpent.line(q))
	end)
end)

-- Every ue.logistic trace line this file's edges send, counted by edge and phase, read from the bridge's queue; every
-- removal request, counted per side and, unless the case holds its edge, carried out at the next tick as the
-- controller would (plan ruling 12); and, for lg-nudge, the tick its drained status left and the tick of the first
-- copper offer at or after it. The loopback delivers inside flush (a credit's or a refund's lines are queued there,
-- after the flush wrapper's read), so ue_rt.inbox is scanned too; `scanned` is how much of the queue was counted
-- already, reset when flush drains it.
local traced, scanned, asked, due, hold, nudge = {}, 0, {}, {}, {}, {}
local function scan()
	local s = storage.universal_edges
	local q = s and s.bridge.out.universal_edges or {}
	for i = scanned + 1, #q do
		local msg = q[i]
		local p = msg.payload
		local ours = string.sub(p.edge or "", 1, 3) == "lg-"
		if ours and msg.type == "trace" and p.op == "ue.logistic" then
			traced[p.edge] = traced[p.edge] or {}
			traced[p.edge][p.phase] = (traced[p.edge][p.phase] or 0) + 1
		elseif ours and msg.type == "ue.connector.remove" then
			asked[p.edge] = (asked[p.edge] or 0) + 1
			local id = string.sub(p.edge, 1, -3)
			if not hold[id] then
				due[#due + 1] = id
			end
		elseif p.edge == "lg-nudge-x" and msg.type == "ue.lane" then
			if p.k == "ep" and p.status and p.status.gone == "drained" then
				nudge.drained = nudge.drained or game.tick
			elseif p.k == "s.offer" and nudge.drained and p.totals["copper-plate|normal"] and not nudge.offer then
				nudge.offer = game.tick
			end
		end
	end
	scanned = #q
end
local flush = bridge.flush
function bridge.flush(tick)
	scan()
	flush(tick)
	scanned = 0
end
local inbox = ue_rt.inbox
ue_rt.inbox = function(...) -- luacheck: ignore 122
	inbox(...)
	scan()
end

ue.runtime.scheduler.periodic({ name = "lg-test.controller", interval = 1, fn = function()
	if due[1] == nil then
		return
	end
	local batch = due
	due = {}
	for _, id in ipairs(batch) do
		local side = storage.universal_edges.edges[id .. "-x"]
		if side and next(side.connectors) then
			loop.connectors(id, side.revision + 1, {})
		end
	end
end })

-- Credit seams. rename[edge] = { from, to } makes one real item read as missing on that side (§7.6's refused case, as
-- vehicles_game_test.lua renames one); fill[edge] = true fills the provider's free slots with stone just before the
-- next credit, once (a player or an inserter filling it between its status and the credit).
local rename, fill = {}, {}
local lt = connectors.types.logistic
local credit = lt.credit
lt.credit = function(e, dir, bag)
	local r = rename[e.edge]
	if r and bag[r.from] then
		local copy = {}
		for k, v in pairs(bag) do
			copy[k] = v
		end
		copy[r.to], copy[r.from] = copy[r.from], nil
		bag = copy
	end
	if fill[e.edge] then
		fill[e.edge] = nil
		e.data.inv.insert({ name = "stone", count = 50 * e.data.inv.count_empty_stacks(false, false) })
	end
	return credit(e, dir, bag)
end

-- The build seam: lg-build's link requester as its build left it, before anything could ship from it.
local snap = {}
local build = lt.build
lt.build = function(e)
	local result = build(e)
	local c = e.data.chest
	if e.edge == "lg-build-x" and result == "ready" and not snap.name and c and c.valid then
		local inv = c.get_inventory(MAIN)
		local slot = c.get_logistic_point(MEMBER).get_section(1).get_slot(1)
		snap.name, snap.quality, snap.x, snap.y = c.name, c.quality.name, c.position.x, c.position.y
		snap.copper, snap.bar = inv.get_item_count("copper-plate"), inv.get_bar()
		snap.request, snap.min = slot and slot.value and slot.value.name, slot and slot.min
		snap.wired = c.get_wire_connector(RED, true).is_connected_to(snap.cc.get_wire_connector(RED, true))
	end
	return result
end

-- Fair share (L15): while fair.inv is set, every stack the link puts into that provider is taken out the next tick and
-- its name recorded, so the provider always shows one free slot.
local fair = { order = {} }
ue.runtime.scheduler.periodic({ name = "lg-test.fair", interval = 1, fn = function()
	local inv = fair.inv
	if not (inv and inv.valid) then
		return
	end
	for i = 1, #inv do
		local s = inv[i]
		if s.valid_for_read and s.name ~= "stone" then
			fair.order[#fair.order + 1] = s.name
			s.clear()
		end
	end
end })

--- Looped edge id's link chest on side ("x", the source; "y", the destination), while it stands.
local function chest(id, side)
	local e = ep(id .. "-" .. side)
	local c = e and e.data.chest
	return c and c.valid and c or nil
end

local function inv_of(id, side)
	local c = chest(id, side)
	return c and c.get_inventory(MAIN)
end

--- inv's count of name at quality (default normal); 0 for no inventory.
local function has(inv, name, quality)
	return inv and inv.get_item_count({ name = name, quality = quality or "normal" }) or 0
end

--- How many entities named names (a name or a list) stand in case x0's boxes, both sides.
local function count(x0, names)
	local n = 0
	for _, y in ipairs({ 3000, 2000 }) do
		n = n + game.surfaces.nauvis.count_entities_filtered({ area = { { x0 - 4, y - 8 }, { x0 + 12, y + 8 } }, name = names })
	end
	return n
end

--- From offset from to offset to: fn runs once, in the first tick the source of looped edge id has shipped (its
--- stats.sent > 0), after the shipment left and before it can be credited (the loopback delivers a tick later).
local function on_ship(ctx, id, from, to, fn)
	local done = false
	for k = from, to do
		ctx.at(k, function()
			local src = ep(id .. "-x")
			if not done and src and src.data.stats and src.data.stats.sent > 0 then
				done = true
				fn()
			end
		end)
	end
	ctx.at(to + 1, function()
		ctx.expect(done, id .. ": a shipment left between +" .. from .. " and +" .. to)
	end)
end

t.case("logistic: a requester built in a border row is replaced by a link requester one tile out at its quality, " ..
	"with its requests, wire, contents and bar; the provider stands mirrored at that quality, minable and operable; " ..
	"a legendary requester converts past slot 48 (Review Focus 2)", function(ctx)
	local X = 11220
	local fa
	ctx.at(300, function()
		fa = layouts.edge(loop, "lg-build", X, 8, {}, 8)
		snap.cc = layouts.put(fa, "constant-combinator", 4.5, 2.5)
		local big = layouts.logistic_pair(loop, "lg-legend", 11240, "requester-chest", "legendary")
		big.placed.get_inventory(MAIN)[60].set_stack({ name = "iron-plate", count = 7 })
	end)
	ctx.at(305, function()
		local placed = layouts.put(fa, "requester-chest", 2.5, 0.5, 0, { quality = "uncommon", raise_built = true })
		placed.get_logistic_point(MEMBER).get_section(1).set_slot(1, { value = { name = "iron-plate", quality = "normal" },
			min = 50 })
		placed.get_wire_connector(RED, true).connect_to(snap.cc.get_wire_connector(RED, true), false)
		local inv = placed.get_inventory(MAIN)
		inv.insert({ name = "copper-plate", count = 30 })
		inv.set_bar(20)
		local p = proposals("lg-build-x")[1]
		ctx.expect(p and p.type == "logistic" and p.pos == 2, "proposed: " .. serpent.line(p))
		if p then
			loop.connectors("lg-build", 2, { { cid = "c1", type = "logistic", pos = p.pos, width = 1, params = p.params } })
		end
	end)
	ctx.at(400, function()
		ctx.expect(snap.name == "ue-link-requester-chest" and snap.quality == "uncommon",
			"an uncommon link requester: " .. tostring(snap.name) .. " " .. tostring(snap.quality))
		ctx.expect(snap.x == X + 2.5 and snap.y == 2999.5, "one tile out")
		ctx.expect(snap.request == "iron-plate" and snap.min == 50, "its request")
		ctx.expect(snap.wired == true, "its red wire")
		ctx.expect(snap.copper == 30 and snap.bar == 20, "its contents and bar")
		ctx.expect(game.surfaces.nauvis.find_entity("requester-chest", { X + 2.5, 3000.5 }) == nil, "the row is empty")
		local prov = chest("lg-build", "y")
		ctx.expect(prov and prov.name == "ue-link-provider-requester-chest" and prov.quality.name == "uncommon"
			and prov.force.name == "player" and prov.minable and prov.operable, "the provider: uncommon, minable, operable")
		ctx.expect(prov and prov.position.x == X + 2.5 and prov.position.y == 2000.5, "at the mirrored spot")
		ctx.expect(chest("lg-build", "x") and prov and ue.owns(chest("lg-build", "x")) and ue.owns(prov), "both are UE's")
		ctx.expect(has(prov and prov.get_inventory(MAIN), "copper-plate") == 30, "the 30 copper crossed")
		ctx.expect((traced["lg-build-x"] or {}).converted == 1, "one converted line")
		local big, far = chest("lg-legend", "x"), chest("lg-legend", "y")
		ctx.expect(big and big.quality.name == "legendary" and #big.get_inventory(MAIN)
			== prototypes.entity["requester-chest"].get_inventory_size(MAIN, "legendary"), "a legendary link requester")
		ctx.expect(has(far and far.get_inventory(MAIN), "iron-plate") == 7, "slot 60's plates crossed")
		ctx.expect(ep("lg-legend-y").status.free > 48, "the legendary provider counts its own slots")
	end)
end)

t.case("logistic: a chest or water on either side's outside spot blocks that side, the placed requester staying in " ..
	"its row; cleared, the 600-tick retry builds it (spec §6.1 step 3, §6.2 step 2)", function(ctx)
	local function s()
		return game.surfaces.nauvis
	end
	ctx.at(300, function()
		layouts.logistic_pair(loop, "lg-blk-src", 11260)
		s().create_entity({ name = "wooden-chest", position = { 11262.5, 2999.5 }, force = "player" })
		layouts.logistic_pair(loop, "lg-blk-dst", 11280)
		s().create_entity({ name = "wooden-chest", position = { 11282.5, 2000.5 }, force = "player" })
		layouts.logistic_pair(loop, "lg-blk-water", 11300)
		s().set_tiles({ { name = "water", position = { 11302, 2999 } } })
	end)
	ctx.at(400, function()
		for _, x0 in ipairs({ 11260, 11300 }) do
			local id = x0 == 11260 and "lg-blk-src" or "lg-blk-water"
			ctx.expect(ep(id .. "-x").state == "blocked", id .. "'s source is blocked")
			ctx.expect(s().find_entity("requester-chest", { x0 + 2.5, 3000.5 }) ~= nil, id .. ": the requester stays put")
		end
		ctx.expect(ep("lg-blk-dst-y").state == "blocked" and chest("lg-blk-dst", "y") == nil, "the destination is blocked")
		ctx.expect(chest("lg-blk-dst", "x") ~= nil, "its source converted all the same")
		s().find_entity("wooden-chest", { 11262.5, 2999.5 }).destroy()
		s().find_entity("wooden-chest", { 11282.5, 2000.5 }).destroy()
	end)
	ctx.at(1100, function()
		ctx.expect(ep("lg-blk-src-x").state == "ready" and chest("lg-blk-src", "x") ~= nil, "the retry converted it")
		ctx.expect(s().find_entity("requester-chest", { 11262.5, 3000.5 }) == nil, "and its row is empty")
		ctx.expect(ep("lg-blk-dst-y").state == "ready" and chest("lg-blk-dst", "y") ~= nil, "the retry built the provider")
		ctx.expect(ep("lg-blk-water-x").state == "blocked", "water still blocks")
	end)
end)

t.case("logistic: a failed endpoint's rebuild keeps both chests: no second conversion and no second provider (F9)",
	function(ctx)
		local units = {}
		ctx.at(300, function()
			layouts.logistic_pair(loop, "lg-f9", 11320)
		end)
		ctx.at(400, function()
			units.x, units.y = chest("lg-f9", "x").unit_number, chest("lg-f9", "y").unit_number
			local params = ep("lg-f9-x").params
			connectors.fail(ep("lg-f9-x"), "test", "forced")
			connectors.fail(ep("lg-f9-y"), "test", "forced")
			loop.connectors("lg-f9", 2, { { cid = "c1", type = "logistic", pos = 2, width = 1, params = params } })
		end)
		ctx.at(560, function()
			ctx.expect(ep("lg-f9-x").state == "ready" and ep("lg-f9-y").state == "ready", "both rebuilt")
			ctx.expect(chest("lg-f9", "x").unit_number == units.x and chest("lg-f9", "y").unit_number == units.y,
				"the same two chests")
			ctx.expect(count(11320, "ue-link-requester-chest") == 1 and count(11320, "ue-link-provider-requester-chest") == 1,
				"one of each")
		end)
	end)

t.case("logistic: 1,000 plates in three qualities cross exactly; yumako at three freshness levels merges into one " ..
	"stack at their weighted average, at most 1 % older; an armor with a grid arrives plain (spec §7.7)", function(ctx)
	ctx.at(300, function()
		layouts.logistic_pair(loop, "lg-flow", 11340)
	end)
	ctx.at(360, function()
		local inv = inv_of("lg-flow", "x")
		inv.insert({ name = "power-armor", count = 1 })
		local armor = inv.find_item_stack("power-armor")
		local grid = armor.grid or armor.create_grid()
		grid.put({ name = "battery-equipment" })
		inv.insert({ name = "iron-plate", count = 400 })
		inv.insert({ name = "iron-plate", quality = "uncommon", count = 300 })
		inv.insert({ name = "iron-plate", quality = "rare", count = 300 })
		for i, p in ipairs({ 0.1, 0.3, 0.5 }) do
			inv[39 + i].set_stack({ name = "yumako", count = 10, spoil_percent = p })
		end
	end)
	ctx.at(600, function()
		local far = inv_of("lg-flow", "y")
		ctx.expect(has(far, "iron-plate") == 400 and has(far, "iron-plate", "uncommon") == 300
			and has(far, "iron-plate", "rare") == 300, "1,000 plates, by quality")
		local stacks, fresh = 0, nil
		for i = 1, #far do
			if far[i].valid_for_read and far[i].name == "yumako" then
				stacks, fresh = stacks + 1, far[i].spoil_percent
			end
		end
		ctx.expect(stacks == 1 and has(far, "yumako") == 30, "one stack of 30 yumako")
		-- each batch rounds up to the next 1 % (it decays a tick or two before it ships), so the average is at most
		-- 0.31, plus real decay in transit (about 0.001 over these ticks)
		ctx.expect(fresh and fresh >= 0.3 and fresh <= 0.313, "the weighted average, at most 1 % older: " .. tostring(fresh))
		local armor = far.find_item_stack("power-armor")
		ctx.expect(armor and (armor.grid == nil or #armor.grid.equipment == 0), "the armor arrived without its battery")
		ctx.expect(inv_of("lg-flow", "x").is_empty(), "the requester is empty")
		local src, dst = ep("lg-flow-x").data.stats, ep("lg-flow-y").data.stats
		ctx.expect(src.sent == 1031 and dst.got == 1031, "sent " .. src.sent .. ", credited " .. dst.got)
	end)
end)

t.case("logistic: a full provider ships nothing; one freed slot takes exactly one slot's worth; a bar of 10 slots " ..
	"fills those 10 and no more (spec §7.2, §7.4)", function(ctx)
	ctx.at(300, function()
		layouts.logistic_pair(loop, "lg-win", 11360)
	end)
	ctx.at(330, function()
		local far = inv_of("lg-win", "y")
		far.insert({ name = "stone", count = 50 * #far })
	end)
	ctx.at(420, function()
		inv_of("lg-win", "x").insert({ name = "iron-plate", count = 2000 })
	end)
	ctx.at(560, function()
		ctx.expect(has(inv_of("lg-win", "x"), "iron-plate") == 2000 and ep("lg-win-x").data.stats.sent == 0,
			"a full provider: nothing left the requester")
		inv_of("lg-win", "y")[1].clear()
	end)
	ctx.at(760, function()
		ctx.expect(has(inv_of("lg-win", "y"), "iron-plate") == 100 and has(inv_of("lg-win", "x"), "iron-plate") == 1900,
			"one slot's worth: " .. has(inv_of("lg-win", "y"), "iron-plate"))
		local far = inv_of("lg-win", "y")
		far.clear()
		far.set_bar(11)
	end)
	ctx.at(1000, function()
		ctx.expect(has(inv_of("lg-win", "y"), "iron-plate") == 1000 and has(inv_of("lg-win", "x"), "iron-plate") == 900,
			"10 slots fill and the rest waits: " .. has(inv_of("lg-win", "y"), "iron-plate"))
	end)
end)

t.case("logistic: a provider filled between its status and the credit keeps the remainder in the source's escrow; " ..
	"it is credited as slots empty, once (spec §7.5)", function(ctx)
	ctx.at(300, function()
		layouts.logistic_pair(loop, "lg-part", 11380)
	end)
	ctx.at(420, function()
		fill["lg-part-y"] = true
		inv_of("lg-part", "x").insert({ name = "copper-plate", count = 500 })
	end)
	ctx.at(560, function()
		local src, dst = ep("lg-part-x"), ep("lg-part-y")
		ctx.expect(src.data.stats.sent == 500 and dst.data.stats.got == 0 and not src:idle("ab"), "500 wait in escrow")
		ctx.expect(has(inv_of("lg-part", "y"), "copper-plate") == 0, "none fitted")
		inv_of("lg-part", "y").remove({ name = "stone", count = 100 }) -- two full slots
	end)
	ctx.at(760, function()
		ctx.expect(has(inv_of("lg-part", "y"), "copper-plate") == 200 and ep("lg-part-y").data.stats.got == 200,
			"two slots' worth: " .. has(inv_of("lg-part", "y"), "copper-plate"))
		inv_of("lg-part", "y").remove({ name = "stone", count = 100000 })
	end)
	ctx.at(1000, function()
		ctx.expect(has(inv_of("lg-part", "y"), "copper-plate") == 500 and ep("lg-part-y").data.stats.got == 500
			and ep("lg-part-x"):idle("ab"), "all 500, credited once")
		ctx.expect(inv_of("lg-part", "x").is_empty(), "the requester is empty")
	end)
end)

t.case("logistic: two items through one free slot a cycle take turns going first (L15)", function(ctx)
	ctx.at(300, function()
		layouts.logistic_pair(loop, "lg-fair", 11400)
	end)
	ctx.at(330, function()
		local far = inv_of("lg-fair", "y")
		far.insert({ name = "stone", count = 50 * (#far - 1) })
		fair.inv = far
	end)
	ctx.at(420, function()
		local inv = inv_of("lg-fair", "x")
		inv.insert({ name = "iron-plate", count = 1000 })
		inv.insert({ name = "copper-plate", count = 1000 })
	end)
	ctx.at(1300, function()
		fair.inv = nil
		local o = fair.order
		ctx.expect(#o >= 6, "at least six cycles: " .. #o)
		for i = 2, #o do
			ctx.expect(o[i] ~= o[i - 1], "cycle " .. i .. " took turns: " .. table.concat(o, ", "))
		end
	end)
end)

t.case("logistic: an item the destination lacks is refused and logged once; the link stops, other items waiting " ..
	"too; at an operator's removal its escrow comes back into the requester (spec §7.6)", function(ctx)
	local st
	ctx.at(300, function()
		layouts.logistic_pair(loop, "lg-ref", 11420)
		rename["lg-ref-y"] = { from = "copper-plate|normal", to = "lg-missing-item|normal" }
	end)
	ctx.at(420, function()
		local inv = inv_of("lg-ref", "x")
		inv.insert({ name = "copper-plate", count = 100 })
		inv.insert({ name = "iron-plate", count = 500 })
	end)
	ctx.at(500, function()
		inv_of("lg-ref", "x").insert({ name = "iron-plate", count = 300 })
	end)
	ctx.at(800, function()
		ctx.expect(has(inv_of("lg-ref", "y"), "iron-plate") == 500, "the first shipment's iron only")
		ctx.expect(has(inv_of("lg-ref", "x"), "iron-plate") == 300, "the later iron waits")
		st = { ep("lg-ref-x").data.stats, ep("lg-ref-y").data.stats }
		ctx.expect(st[1].sent == 600 and st[2].got == 500, "the 100 copper refused")
		ctx.expect((traced["lg-ref-y"] or {}).refused == 1, "logged once: " .. serpent.line(traced["lg-ref-y"]))
		loop.connectors("lg-ref", 2, {})
	end)
	ctx.at(1000, function()
		local s = game.surfaces.nauvis
		local req = s.find_entity("ue-link-requester-chest", { 11422.5, 2999.5 })
		local prov = s.find_entity("ue-link-provider-requester-chest", { 11422.5, 2000.5 })
		ctx.expect(ep("lg-ref-x") == nil and ep("lg-ref-y") == nil, "both ends closed")
		ctx.expect(st[1].refunded == 100 and has(req and req.get_inventory(MAIN), "copper-plate") == 100
			and has(req and req.get_inventory(MAIN), "iron-plate") == 300, "the copper is back in the requester")
		ctx.expect(has(prov and prov.get_inventory(MAIN), "iron-plate") == 500, "the provider keeps its iron")
		ctx.expect(st[1].sent == st[2].got + st[1].refunded, "§8.5: sent = credited + refunded")
		ctx.expect((traced["lg-ref-x"] or {}).refunded == 1, "one refunded line")
	end)
end)

t.case("logistic: an operator's removal with both chests standing leaves both, owned by no endpoint but still UE's; " ..
	"what was in flight comes back into the requester (N2, spec §8.6)", function(ctx)
	local st, units = nil, {}
	ctx.at(300, function()
		layouts.logistic_pair(loop, "lg-op", 11440)
	end)
	ctx.at(420, function()
		inv_of("lg-op", "x").insert({ name = "iron-plate", count = 2000 })
	end)
	on_ship(ctx, "lg-op", 421, 520, function()
		st = { ep("lg-op-x").data.stats, ep("lg-op-y").data.stats }
		units.x, units.y = chest("lg-op", "x").unit_number, chest("lg-op", "y").unit_number
		loop.connectors("lg-op", 2, {})
	end)
	ctx.at(700, function()
		local s = game.surfaces.nauvis
		local req = s.find_entity("ue-link-requester-chest", { 11442.5, 2999.5 })
		local prov = s.find_entity("ue-link-provider-requester-chest", { 11442.5, 2000.5 })
		ctx.expect(ep("lg-op-x") == nil and ep("lg-op-y") == nil, "both ends closed")
		ctx.expect(req ~= nil and prov ~= nil, "both chests stand")
		ctx.expect(st and st[1].refunded == 2000 and has(req and req.get_inventory(MAIN), "iron-plate") == 2000,
			"the 2,000 in flight came back")
		ctx.expect(prov and prov.get_inventory(MAIN).is_empty(), "nothing reached the closing provider")
		ctx.expect(st and st[1].sent == st[2].got + st[1].refunded, "§8.5: sent = credited + refunded")
		local owned = storage.universal_edges.owned
		ctx.expect(owned[units.x] == nil and owned[units.y] == nil, "no endpoint owns them")
		ctx.expect(req and ue.owns(req) and prov and ue.owns(prov), "still UE's by name (G8)")
	end)
end)

local LINKS = { "ue-link-requester-chest", "ue-link-provider-requester-chest" }

--- Mine looped edge id's link chest on side into a new 200-slot inventory, which is returned. With as_player, first
--- the mined event a player's mining raises, for player 65536: get_player answers nil, so what lands is spilled.
local function mine(id, side, as_player)
	local c = chest(id, side)
	if as_player then
		logistic.on_mined({ entity = c, player_index = 65536, tick = game.tick, name = defines.events.on_player_mined_entity })
	end
	local bag = game.create_inventory(200)
	c.mine({ inventory = bag })
	return bag
end

--- Every item in case x0's two removal boxes (ground and chests, both sides) and in the inventories in extra, by name;
--- the requester-chest items that mining a link chest gives back are left out.
local function world(x0, extra)
	local n = {}
	local function add(name, c)
		if name ~= "requester-chest" then
			n[name] = (n[name] or 0) + c
		end
	end
	local function inventory(inv)
		for _, c in ipairs(inv.get_contents()) do
			add(c.name, c.count)
		end
	end
	for _, y in ipairs({ 3000, 2000 }) do
		for _, e in ipairs(game.surfaces.nauvis.find_entities_filtered({ area = { { x0 - 15, y - 16 }, { x0 + 23, y + 16 } },
			type = { "item-entity", "logistic-container" } })) do
			if e.type == "item-entity" then
				add(e.stack.name, e.stack.count)
			else
				for _, id in ipairs({ MAIN, TRASH }) do
					local inv = e.get_inventory(id)
					if inv then
						inventory(inv)
					end
				end
			end
		end
	end
	for _, inv in ipairs(extra or {}) do
		inventory(inv)
	end
	return n
end

--- §8.5's equation over two held stats tables (the endpoints are gone by the time it is checked).
local function balanced(src, dst)
	return src.sent + src.drained + dst.drained == src.got + dst.got + src.refunded + dst.refunded
end

local seq = 0
--- One ue.edge.activation for both sides of looped edge id, as the controller sends during an outage; n makes each
--- reactivation's epoch new.
local function activation(id, active, n)
	local batch = {}
	for _, edge in ipairs({ id .. "-x", id .. "-y" }) do
		seq = seq + 1
		batch[#batch + 1] = { id = "1091c000." .. seq, type = "ue.edge.activation", payload = { id = edge,
			active = active, epoch = active and ("1091c001." .. edge .. "." .. n) or nil, trace = "1091c002." .. edge } }
	end
	ue_rt.inbox("universal_edges", helpers.table_to_json(batch))
end

t.case("logistic: a source whose placed chest is gone before its first build reports lost; the provider is drained " ..
	"and removed, and only the source asks (spec §6.1 step 2, F9)", function(ctx)
	local X = 11480
	ctx.at(300, function()
		layouts.edge(loop, "lg-nochest", X, 8, { { cid = "c1", type = "logistic", pos = 2, width = 1,
			params = { dir = "ab", q = "normal", chest = "requester-chest" } } }, 8)
	end)
	ctx.at(700, function()
		ctx.expect(asked["lg-nochest-x"] == 1 and asked["lg-nochest-y"] == nil, "the source asked, once: " .. serpent.line(asked))
		ctx.expect(ep("lg-nochest-x") == nil and ep("lg-nochest-y") == nil, "the connector went on both sides")
		ctx.expect(count(X, LINKS) == 0, "nothing of the link stands")
		ctx.expect((traced["lg-nochest-x"] or {}).lost == 1 and (traced["lg-nochest-y"] or {}).drained == 1,
			"lost, then drained: " .. serpent.line(traced["lg-nochest-y"]))
	end)
end)

t.case("logistic: the requester mined mid-flight: the provider drains back across and is destroyed; what it held " ..
	"and what was in flight land at the source's border; the source asks once (spec §8.2)", function(ctx)
	local X, st, bag = 11520, nil, nil
	ctx.at(300, function()
		layouts.logistic_pair(loop, "lg-mreq", X)
	end)
	ctx.at(330, function()
		inv_of("lg-mreq", "y").set_bar(3) -- two slots a shipment, so 100 plates stay behind
	end)
	layouts.wait(t, ctx, 445, 2000, function()
		return next(storage.gridworld.cleanup) == nil
	end, function(k)
		ctx.expect(k ~= nil, "gridworld's cleanup backlog drained by tick 2000")
		if not k then
			return
		end
		st = { ep("lg-mreq-x").data.stats, ep("lg-mreq-y").data.stats }
		inv_of("lg-mreq", "x").insert({ name = "iron-plate", count = 300 })
		on_ship(ctx, "lg-mreq", k + 1, k + 95, function()
			bag = mine("lg-mreq", "x", true)
			ctx.expect(ep("lg-mreq-x").data.miner == 65536, "the mined handler recorded the miner (L19)")
		end)
		ctx.at(k + 455, function()
			ctx.expect(asked["lg-mreq-x"] == 1 and asked["lg-mreq-y"] == nil, "the source asked, once: " .. serpent.line(asked))
			ctx.expect(ep("lg-mreq-x") == nil and ep("lg-mreq-y") == nil, "the connector went on both sides")
			ctx.expect(count(X, LINKS) == 0, "nothing of the link stands outside either border")
			ctx.expect(st[2].drained == 200 and st[1].got == 200, "the provider's 200 drained back: " .. serpent.line(st))
			ctx.expect(balanced(st[1], st[2]), "§8.5 in stats")
			local w = world(X, { bag })
			ctx.expect(w["iron-plate"] == 300, "300 plates: 100 with the miner, 200 on the ground: " .. serpent.line(w))
			local piles = 0 -- 2B: whole stacks, so the 200 plates on the ground are 2 stacks of 100, not 200 single plates
			for _, y in ipairs({ 3000, 2000 }) do
				piles = piles + game.surfaces.nauvis.count_entities_filtered({ area = { { X - 15, y - 16 }, { X + 23, y + 16 } },
					type = "item-entity" })
			end
			ctx.expect(piles >= 1 and piles <= 2, "the ground holds 1 or 2 item entities, a stack each: " .. piles)
			local lx = traced["lg-mreq-x"] or {}
			ctx.expect(lx.lost == 1 and (lx.landed or 0) >= 1 and (traced["lg-mreq-y"] or {}).drained == 1,
				"lost, landed and drained lines")
		end)
	end)
	ctx.expect_ipc("universal_edges:out", '"reason":"chest_gone"')
end)

t.case("logistic: the provider mined mid-flight: the requester (main and trash, 41 keys) drains across in offers " ..
	"that are all credited before the destination asks; nothing refunded (spec §8.2, Review Focus 3)", function(ctx)
	local X, st, bag = 11560, nil, nil
	ctx.at(300, function()
		layouts.logistic_pair(loop, "lg-mprov", X)
	end)
	ctx.at(330, function()
		inv_of("lg-mprov", "y").set_bar(2) -- one slot a shipment
	end)
	-- Not before gridworld's sliced cleanup has drained: it destroys the item entities a spill leaves on any chunk it
	-- still has queued (the shared save; every plan's cases add chunks, so no fixed tick holds).
	layouts.wait(t, ctx, 420, 2000, function()
		return next(storage.gridworld.cleanup) == nil
	end, function(k)
		ctx.expect(k ~= nil, "gridworld's cleanup backlog drained by tick 2000")
		if not k then
			return
		end
		st = { ep("lg-mprov-x").data.stats, ep("lg-mprov-y").data.stats }
		local inv = inv_of("lg-mprov", "x")
		inv.insert({ name = "iron-plate", count = 100 })
		for j = 2, 41 do
			inv[j].set_stack({ name = "yumako", count = 1, spoil_percent = j / 100 })
		end
		chest("lg-mprov", "x").get_inventory(TRASH).insert({ name = "coal", count = 50 })
		on_ship(ctx, "lg-mprov", k + 1, k + 100, function()
			bag = mine("lg-mprov", "y", true) -- the iron (the first key) is in flight; the provider is empty
		end)
		ctx.at(k + 410, function()
			ctx.expect(asked["lg-mprov-y"] == 1 and asked["lg-mprov-x"] == nil, "the destination asked, once")
			ctx.expect(st[1].drained == 90 and st[2].got == 190, "40 yumako and 50 coal drained; all 190 credited at the lost "
				.. "side: " .. serpent.line(st))
			ctx.expect(st[1].refunded == 0 and st[2].refunded == 0, "nothing refunded")
			ctx.expect(balanced(st[1], st[2]), "§8.5 in stats")
			local w = world(X, { bag })
			ctx.expect(w["iron-plate"] == 100 and w.yumako == 40 and w.coal == 50, "all on the ground: " .. serpent.line(w))
			ctx.expect(count(X, LINKS) == 0, "nothing of the link stands")
		end)
	end)
end)

-- Plan ruling 13: each dying chest is emptied by script first (counted), so the count is exact whatever die() does
-- with a chest's contents.
t.case("logistic: die() on either chest drains the other the same way, and leaves no ghost", function(ctx)
	local XR, XP, st, emptied = 11600, 11640, {}, 0
	ctx.at(300, function()
		layouts.logistic_pair(loop, "lg-die-r", XR)
		layouts.logistic_pair(loop, "lg-die-p", XP)
	end)
	layouts.wait(t, ctx, 420, 2000, function()
		return next(storage.gridworld.cleanup) == nil
	end, function(k)
		ctx.expect(k ~= nil, "gridworld's cleanup backlog drained by tick 2000")
		if not k then
			return
		end
		for _, id in ipairs({ "lg-die-r", "lg-die-p" }) do
			st[id] = { ep(id .. "-x").data.stats, ep(id .. "-y").data.stats }
			inv_of(id, "x").insert({ name = "iron-plate", count = 300 })
		end
		ctx.at(k + 180, function()
			ctx.expect(has(inv_of("lg-die-r", "y"), "iron-plate") == 300, "lg-die-r: the 300 crossed")
			chest("lg-die-r", "x").die() -- empty: it shipped all 300
			emptied = inv_of("lg-die-p", "y").remove({ name = "iron-plate", count = 1000 })
			inv_of("lg-die-p", "x").insert({ name = "copper-plate", count = 50 })
			chest("lg-die-p", "y").die()
		end)
		ctx.at(k + 185, function()
			for _, at in ipairs({ { XR + 2.5, 2999.5 }, { XP + 2.5, 2000.5 } }) do
				ctx.expect(game.surfaces.nauvis.count_entities_filtered({ type = "entity-ghost", position = at, radius = 0.5 })
					== 0, "no ghost at " .. at[1])
			end
		end)
		ctx.at(k + 580, function()
			ctx.expect(asked["lg-die-r-x"] == 1 and asked["lg-die-p-y"] == 1, "each lost side asked: " .. serpent.line(asked))
			ctx.expect((world(XR)["iron-plate"] or 0) == 300, "the provider's 300 came back to the requester's side")
			ctx.expect(emptied == 300 and (world(XP)["copper-plate"] or 0) == 50, "the requester's 50 went to the provider's side")
			for id, s in pairs(st) do
				ctx.expect(balanced(s[1], s[2]), id .. ": §8.5")
			end
			ctx.expect(count(XR, LINKS) == 0 and count(XP, LINKS) == 0, "nothing of either link stands")
		end)
	end)
end)

t.case("logistic: both chests mined in one tick: the source alone asks, once; nothing is lost (spec §8.2)", function(ctx)
	local X, st, bags = 11680, nil, nil
	ctx.at(300, function()
		layouts.logistic_pair(loop, "lg-both", X)
	end)
	ctx.at(420, function()
		st = { ep("lg-both-x").data.stats, ep("lg-both-y").data.stats }
		inv_of("lg-both", "x").insert({ name = "iron-plate", count = 200 })
	end)
	ctx.at(600, function()
		ctx.expect(has(inv_of("lg-both", "y"), "iron-plate") == 200, "the 200 crossed")
		bags = { mine("lg-both", "x"), mine("lg-both", "y") }
	end)
	ctx.at(900, function()
		ctx.expect(asked["lg-both-x"] == 1 and asked["lg-both-y"] == nil, "the source asked, the destination didn't: "
			.. serpent.line(asked))
		ctx.expect(ep("lg-both-x") == nil and ep("lg-both-y") == nil, "the connector went")
		ctx.expect(st[1].drained == 0 and st[2].drained == 0 and balanced(st[1], st[2]), "no drain; §8.5")
		ctx.expect((world(X, bags)["iron-plate"] or 0) == 200, "the 200 went to the provider's miner")
	end)
end)

t.case("logistic: with the far spot water the destination stays blocked; the requester mined, the source asks at " ..
	"once (L16)", function(ctx)
	local X, bag = 11720, nil
	ctx.at(300, function()
		layouts.logistic_pair(loop, "lg-water", X)
		game.surfaces.nauvis.set_tiles({ { name = "water", position = { X + 2, 2000 } } })
	end)
	ctx.at(360, function()
		inv_of("lg-water", "x").insert({ name = "iron-plate", count = 50 })
	end)
	ctx.at(480, function()
		ctx.expect(ep("lg-water-y").state == "blocked" and ep("lg-water-x").state == "ready", "the far side is blocked")
		ctx.expect(has(inv_of("lg-water", "x"), "iron-plate") == 50, "nothing shipped")
		bag = mine("lg-water", "x", true)
	end)
	ctx.at(600, function()
		ctx.expect(asked["lg-water-x"] == 1, "the source asked at once")
		ctx.expect(ep("lg-water-x") == nil and ep("lg-water-y") == nil, "the connector went")
		ctx.expect((world(X, { bag })["iron-plate"] or 0) == 50 and count(X, LINKS) == 0, "the miner holds the 50")
	end)
end)

t.case("logistic: a drain behind a backing-off forward lane offers that lane's remainder in the same visit (L22, " ..
	"plan ruling 6)", function(ctx)
	local X, st, bag = 11760, nil, nil
	ctx.at(300, function()
		layouts.logistic_pair(loop, "lg-nudge", X)
	end)
	layouts.wait(t, ctx, 420, 2000, function()
		return next(storage.gridworld.cleanup) == nil
	end, function(k)
		ctx.expect(k ~= nil, "gridworld's cleanup backlog drained by tick 2000")
		if not k then
			return
		end
		st = { ep("lg-nudge-x").data.stats, ep("lg-nudge-y").data.stats }
		fill["lg-nudge-y"] = true
		inv_of("lg-nudge", "x").insert({ name = "copper-plate", count = 500 })
		ctx.at(k + 120, function()
			ctx.expect(st[1].sent == 500 and st[2].got == 0, "500 copper wait in escrow, backing off")
			inv_of("lg-nudge", "x").insert({ name = "iron-plate", count = 100 })
			bag = mine("lg-nudge", "y", true)
		end)
		ctx.at(k + 480, function()
			ctx.expect(nudge.drained ~= nil and nudge.offer == nudge.drained, "the copper re-offered in the drained visit: "
				.. serpent.line(nudge))
			ctx.expect(st[2].got == 600 and st[1].refunded == 0, "all 600 credited at the lost side, none refunded")
			local w = world(X, { bag })
			ctx.expect(w["copper-plate"] == 500 and w["iron-plate"] == 100, "on the destination's ground: " .. serpent.line(w))
			ctx.expect(balanced(st[1], st[2]), "§8.5")
		end)
	end)
end)

t.case("logistic: an offer reaching a side that has already drained is accepted as 0 there, nothing placed " ..
	"(Review Focus 4)", function(ctx)
	local X, bag = 11800, nil
	ctx.at(300, function()
		hold["lg-late"] = true
		layouts.logistic_pair(loop, "lg-late", X)
	end)
	layouts.wait(t, ctx, 420, 2000, function()
		return next(storage.gridworld.cleanup) == nil
	end, function(k)
		ctx.expect(k ~= nil, "gridworld's cleanup backlog drained by tick 2000")
		if not k then
			return
		end
		inv_of("lg-late", "x").insert({ name = "iron-plate", count = 100 })
		ctx.at(k + 120, function()
			bag = mine("lg-late", "x")
		end)
		ctx.at(k + 380, function()
			local dst = ep("lg-late-y")
			ctx.expect(dst.data.gone == "drained" and asked["lg-late-x"] == 1, "drained, and the source asked")
			local got, before = dst.data.stats.got, serpent.line(world(X, { bag }))
			local accepted = connectors.types.logistic.credit(dst, "ab", { ["iron-plate|normal"] = 10 })
			ctx.expect(accepted["iron-plate|normal"] == 0 and dst.data.stats.got == got, "accepted 0")
			ctx.expect(serpent.line(world(X, { bag })) == before, "nothing placed")
			hold["lg-late"] = nil
			loop.connectors("lg-late", 2, {})
		end)
		ctx.at(k + 580, function()
			ctx.expect(ep("lg-late-x") == nil and ep("lg-late-y") == nil, "released, the connector went")
			ctx.expect((world(X, { bag })["iron-plate"] or 0) == 100, "the 100 came back to the source's side")
		end)
	end)
end)

t.case("logistic: a link requester mined while its edge is down is noticed once the edge is back; then the provider " ..
	"drains back and the connector goes (Review Focus 5)", function(ctx)
	local X, bag = 11840, nil
	ctx.at(300, function()
		layouts.logistic_pair(loop, "lg-down", X)
	end)
	layouts.wait(t, ctx, 420, 2000, function()
		return next(storage.gridworld.cleanup) == nil
	end, function(k)
		ctx.expect(k ~= nil, "gridworld's cleanup backlog drained by tick 2000")
		if not k then
			return
		end
		inv_of("lg-down", "x").insert({ name = "iron-plate", count = 100 })
		ctx.at(k + 120, function()
			ctx.expect(has(inv_of("lg-down", "y"), "iron-plate") == 100, "the plates crossed")
			activation("lg-down", false)
		end)
		ctx.at(k + 125, function()
			bag = mine("lg-down", "x", true)
		end)
		ctx.at(k + 325, function()
			ctx.expect(chest("lg-down", "y") ~= nil and asked["lg-down-x"] == nil, "nothing happens while the edge is down")
			activation("lg-down", true, 2)
		end)
		ctx.at(k + 625, function()
			ctx.expect(asked["lg-down-x"] == 1, "the source asked once the edge was back")
			ctx.expect(ep("lg-down-x") == nil and ep("lg-down-y") == nil and count(X, LINKS) == 0, "the link is gone")
			ctx.expect((world(X, { bag })["iron-plate"] or 0) == 100, "the 100 plates came back to the source's ground")
		end)
	end)
end)

t.case("logistic: the mined handler ignores what it doesn't own: a tree (no unit number) and an unowned chest " ..
	"(Review Focus 1)", function(ctx)
	local X = 11880
	ctx.at(300, function()
		layouts.logistic_pair(loop, "lg-ign", X) -- live endpoints, so "ignored" can be told from "nothing to find"
	end)
	ctx.at(420, function()
		loop.ground(X + 5, 2994, X + 14, 3006)
		local s = game.surfaces.nauvis
		local tree = s.create_entity({ name = "tree-01", position = { X + 6.5, 3000.5 } })
		local box = s.create_entity({ name = "wooden-chest", position = { X + 10.5, 3000.5 }, force = "player" })
		for _, e in ipairs({ tree, box }) do
			logistic.on_mined({ entity = e, player_index = 65536, tick = game.tick, name = defines.events.on_player_mined_entity })
		end
		ctx.expect(tree.valid and box.valid, "both untouched, and nothing raised")
		ctx.expect(ep("lg-ign-x") and ep("lg-ign-y") and ep("lg-ign-x").data.miner == nil and ep("lg-ign-y").data.miner == nil,
			"no live endpoint recorded a miner")
		tree.destroy()
		box.destroy()
	end)
end)
