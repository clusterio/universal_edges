local t = require("modules/v2_test/testlib")
local loop = require("modules/v2_test/loopback")
local layouts = require("modules/v2_test/layouts")
local connectors = require("modules/universal_edges/edges/connectors")
local geometry = require("modules/universal_edges/edges/geometry_core")
local bridge = require("modules/universal_edges/runtime/bridge")

local function ep(edge, cid)
	local side = storage.universal_edges.edges[edge]
	return side and connectors.get(side, cid or "c1")
end

--- An endpoint's interface, nil before its build (review M4).
local function eei(e)
	local x = e and e.data.eei
	return x and x.valid and x or nil
end

-- Every s.offer a counted side sends, read from the bridge's queue just before each flush (the loopback's wrapper reads
-- the same queue; the two chain).
local offers = {}
local flush = bridge.flush
function bridge.flush(tick)
	local s = storage.universal_edges
	for _, msg in ipairs(s and s.bridge.out.universal_edges or {}) do
		local p = msg.payload
		if msg.type == "ue.lane" and p.k == "s.offer" and offers[p.edge] then
			offers[p.edge] = offers[p.edge] + 1
		end
	end
	flush(tick)
end

local function water(entity)
	local f = entity.get_fluid_segment_fluid(1)
	return f and f.amount or 0
end

-- Visuals batch (2026-10-04): the link reads as a 1×1 pipe-to-ground joined to the player's border pipe, not a
-- storage tank spilling a tile into the playable area. The prototype's own type and 1×1 size are checked at load
-- (framework_game_test.lua, D11 §5.4); this checks the built entity: connected to the border pipe, and nothing of
-- its selection box past the border line into the playable side.
t.case("fluids: the link entity is joined to the border pipe and clear of the border", function(ctx)
	local r
	ctx.at(1800, function()
		r = layouts.fluid_pair(loop, "sp3-pipe", 7000, 2)
	end)
	ctx.at(1830, function()
		local tank = ep("sp3-pipe-x").data.tank
		ctx.expect(tank.type == "pipe-to-ground", "the link entity is a pipe-to-ground, got " .. tank.type)
		local joined = false
		for _, n in ipairs(tank.get_fluid_box_neighbours(1) or {}) do
			joined = joined or n.entity == r.a
		end
		ctx.expect(joined, "the link's fluidbox is connected to the border pipe")
		local box, max_y = tank.selection_box, -math.huge
		for _, c in ipairs({ { box.left_top.x, box.left_top.y }, { box.right_bottom.x, box.right_bottom.y },
			{ box.left_top.x, box.right_bottom.y }, { box.right_bottom.x, box.left_top.y } }) do
			local _, ly = geometry.to_local(ep("sp3-pipe-x").frame, c[1], c[2])
			max_y = math.max(max_y, ly)
		end
		ctx.expect(max_y <= 1e-6, "the link's selection box is fully past the border line (local y " .. max_y .. ")")
	end)
end)

-- Fix round 1 (open finding, review a47da7f): the link entity can go invalid out from under a still-"ready" endpoint
-- -- e.g. an upgraded save's old ue-link-tank, destroyed by this batch's own prototype rename, before this endpoint's
-- own first poll has run to notice and flip it to "blocked" (poll's guard, fluid.lua ~:61). A credit landing in that
-- gap must not strand the endpoint "failed"; it must self-heal (become "blocked", rebuild, then take the escrowed
-- amount in full) the same way poll's own guard does. Run against the pre-fix code, this case ends "failed" (RED).
t.case("fluids: a credit against an invalid link entity blocks and rebuilds instead of failing", function(ctx)
	local old
	ctx.at(1800, function()
		layouts.fluid_pair(loop, "sp3-dead", 7050, 2)
	end)
	ctx.at(1830, function()
		local x = ep("sp3-dead-x")
		old = x.data.tank
		old.destroy() -- simulates Factorio removing the old ue-link-tank entity on load (the prototype rename)
		ctx.expect(x.state == "ready", "still ready right after the entity dies, before any poll notices")
		local ok, accepted = connectors.call(x, "credit", "ba", { water = 500 })
		ctx.expect(ok == true, "credit did not raise: " .. tostring(accepted))
		ctx.expect(x.state == "blocked", "blocked, not failed (state: " .. tostring(x.state) .. ")")
		ctx.expect(type(accepted) == "table" and next(accepted) == nil,
			"took nothing, so the sender's escrow holds the 500 for a re-offer")
	end)
	ctx.at(2500, function()
		local x = ep("sp3-dead-x")
		ctx.expect(x.state == "ready", "rebuilt by its next visit (state: " .. tostring(x.state) .. ")")
		ctx.expect(x.data.tank ~= old and x.data.tank.valid, "a fresh, valid link entity")
		local ok, accepted = connectors.call(x, "credit", "ba", { water = 500 })
		ctx.expect(ok == true and accepted.water == 500, "the same 500, re-offered, is now credited in full")
		ctx.expect(water(x.data.tank) == 500, "nothing lost: the rebuilt tank's segment holds exactly the 500")
	end)
end)

t.case("fluids: both ways, exactly", function(ctx)
	local r, checked = nil, false
	ctx.at(1800, function()
		r = layouts.fluid_pair(loop, "sp3-fl", 6700, 40)
	end)
	ctx.at(1830, function()
		r.a.add_fluid_segment_fluid(1, { name = "water", amount = 20000, temperature = 15 })
	end)
	for at = 2100, 2140, 2 do
		ctx.at(at, function()
			if not checked and ep("sp3-fl-x"):idle("ab") and ep("sp3-fl-y"):idle("ba") then
				checked = true
				ctx.expect(math.abs(water(r.a) + water(r.b) - 20000) <= 1, "20,000 water, none made or lost")
				local ca, cb = r.a.get_fluid_segment_capacity(1), r.b.get_fluid_segment_capacity(1)
				ctx.expect(math.abs(water(r.a) / ca - water(r.b) / cb) <= 2 / 64, "balanced")
			end
		end)
	end
	ctx.at(2150, function()
		ctx.expect(checked, "both lanes were idle at some check")
		r.b.add_fluid_segment_fluid(1, { name = "water", amount = 15000, temperature = 15 })
		checked = water(r.a)
	end)
	ctx.at(2400, function()
		ctx.expect(water(r.a) > checked, "and back the other way")
	end)
end)

t.case("fluids: a pump across the line carries water", function(ctx)
	local r
	ctx.at(1800, function()
		r = layouts.fluid_pair(loop, "sp3-pump", 6800, 20, true)
	end)
	ctx.at(1830, function()
		r.back.add_fluid_segment_fluid(1, { name = "water", amount = 2000, temperature = 15 })
	end)
	ctx.at(2300, function()
		ctx.expect(water(r.b) > 0, "water reached side b through the pump")
	end)
end)

t.case("fluids: mismatched fluids send nothing", function(ctx)
	local r
	-- Filled in the same step as the edge, before either endpoint's first build or poll (review fix 1): each side's
	-- first status then already names its fluid, so the gate never sees an empty partner it could mistake for a
	-- match. A same-tick fill of two different fluids on two servers is operator error (D23-D29: no safeguard for it);
	-- this case is about the gate's steady behaviour, not about catching that.
	ctx.at(1800, function()
		r = layouts.fluid_pair(loop, "sp3-mix", 6900, 20)
		r.a.add_fluid_segment_fluid(1, { name = "water", amount = 1000, temperature = 15 })
		r.b.add_fluid_segment_fluid(1, { name = "crude-oil", amount = 1000, temperature = 25 })
	end)
	ctx.at(2130, function()
		ctx.expect(water(r.a) == 1000 and water(r.b) == 1000, "both unchanged")
		ctx.expect(ep("sp3-mix-x").data.stats.sent == 0 and ep("sp3-mix-y").data.stats.sent == 0, "nothing sent")
	end)
end)

-- Both sides full and kept full (a source on each power side and no load; an infinity pipe holding each fluid segment
-- full), and each direction holding a remainder its full partner refuses, as a send from a stale status leaves one: it
-- waits on the lane's backoff (300, 600, 1200 … 3600 ticks), not re-offered every 60 (final fix wave addendum: the
-- fixed retry sent about 20 offers in 1200 ticks, a direction).
t.case("balance: a remainder refused by a full partner waits on the backoff while both sides stay full, power and " ..
	"fluid", function(ctx)
	local sides = { ["sp3-pfull-x"] = "ab", ["sp3-pfull-y"] = "ba", ["sp3-ffull-x"] = "ab", ["sp3-ffull-y"] = "ba" }
	ctx.at(1200, function()
		local r = layouts.power_pair(loop, "sp3-pfull", 7150, 5, 1e9 / 60, 0)
		layouts.put(r.fb, "ue-test-power-source", 9.5, 3.5).power_production = 1e9 / 60
		local f = layouts.fluid_pair(loop, "sp3-ffull", 7180, 4, false)
		local cb = geometry.col("b", 8, 2, 1)
		for _, at in ipairs({ { f.fa, 2.5 }, { f.fb, cb + 0.5 } }) do
			layouts.put(at[1], "infinity-pipe", at[2], 5.5, 0).set_infinity_pipe_filter({ name = "water", percentage = 1,
				mode = "at-least" })
		end
	end)
	ctx.at(1800, function()
		for edge, dir in pairs(sides) do
			local e = ep(edge)
			if e.type == "power" then
				e:send(dir, { e = 1000 })
				eei(e).energy = eei(e).energy - 1e6
			else
				e:send(dir, { water = 1000 })
				e.data.tank.remove_fluid_segment_fluid(1, 1000)
			end
		end
	end)
	ctx.at(2100, function() -- settled: count from here, for 1200 ticks
		for edge in pairs(sides) do
			offers[edge] = 0
		end
	end)
	ctx.at(3300, function()
		for edge, dir in pairs(sides) do
			ctx.expect(not ep(edge):idle(dir), edge .. ": its remainder is still pending (the partner is full)")
			ctx.expect(offers[edge] >= 1 and offers[edge] <= 2, edge .. ": " .. offers[edge] .. " offers in 1200 ticks")
		end
	end)
end)
