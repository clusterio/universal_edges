local t = require("modules/v2_test/testlib")
-- Factorio allows require only while the file loads, never inside a step.
local ue = require("modules/universal_edges")
local geometry = require("modules/universal_edges/edges/geometry_core")
local core = require("modules/universal_edges/transports/train_core")
local seams = require("modules/universal_edges/transports/train_seams")
local connectors = require("modules/universal_edges/edges/connectors")
local train = require("modules/universal_edges/transports/train")

-- Rows 20000-24000 of the lab surface "sp3b", ticks 400-1900. Edges come from seams.edge (ue.edge.update and an
-- activation, never a sync). This instance is side a, at (0, y), and pos 11, width 4 puts the rail's centre at local x = 13.
local function conn(dir, layer)
	return { cid = "t1", type = "train", pos = 11, width = 4, params = { dir = dir, layer = layer } }
end

--- e's local position and direction in ep's frame.
local function where(ep, e)
	local x, y = geometry.to_local(ep.frame, e.position.x, e.position.y)
	return x, y, geometry.dir_to_local(ep.frame, e.direction)
end

local function names(tr)
	local out = {}
	for i, r in ipairs(tr.get_schedule().get_records()) do
		out[i] = (r.station or "<rail>") .. (r.temporary and "*" or "")
	end
	return table.concat(out, ",")
end

--- A signal for trains heading out at a border rail's inner end, on a rail of layer at local y 3 of side a's row y
--- (facing north: local (x, ly) is world (x, y + ly)). A border rail built after it makes an outbound box's proposal at
--- once (train box direction spec §3).
local function heading_out(x, y, layer)
	local s = game.get_surface("sp3b")
	local rail = assert(s.create_entity{ name = layer == "elevated" and "elevated-straight-rail" or "straight-rail",
		position = { x, y + 3 }, direction = defines.direction.north, force = "player" }, "inside rail")
	for _, dir in pairs(defines.rail_direction) do
		local re = rail.get_rail_end(dir)
		if math.abs(re.location.position.y - (y + 2)) < 0.01 then
			local spot = re.out_signal_location
			assert(s.create_entity{ name = "rail-signal", position = spot.position, direction = spot.direction,
				rail_layer = spot.rail_layer, force = "player" }, "signal")
		end
	end
end

t.case("trains: v1's boxes on ground and elevated rails, in four facings, with v1's signal spots (§12.1)", function(ctx)
	local rows = {
		{ id = "sp3b-box-g0", y = 20000, facing = 0, c = conn("ab", "ground") },
		{ id = "sp3b-box-e4", y = 20400, facing = 4, c = conn("ab", "elevated") },
		{ id = "sp3b-box-g8", y = 20800, facing = 8, c = conn("ba", "ground") },
		{ id = "sp3b-box-e12", y = 21200, facing = 12, c = conn("ba", "elevated") },
	}
	ctx.at(400, function()
		for _, k in ipairs(rows) do
			seams.edge(k.id, k.y, { k.c }, { facing = k.facing })
		end
	end)
	ctx.at(460, function()
		for _, k in ipairs(rows) do
			local ep, v = seams.endpoint(k.id, "t1"), ue.trains.get(k.id, "t1")
			local out = k.c.params.dir == "ab"
			ctx.expect(ep.state == "ready", k.id .. ": built")
			ctx.expect(v.box == (out and "outbound" or "inbound") and v.layer == k.c.params.layer, k.id .. ": box and layer")
			ctx.expect(#v.rails == (out and core.OUT_RAILS or core.IN_RAILS), k.id .. ": v1's length")
			local rail = k.c.params.layer == "elevated" and "elevated-straight-rail" or "straight-rail"
			for i, r in ipairs(v.rails) do
				local x, y = where(ep, r)
				ctx.expect(r.name == rail and x == 13 and y == core.rail_y(i), k.id .. ": rail " .. i .. " at " .. x .. "," .. y)
				ctx.expect(not r.minable_flag and not r.destructible and ue.owns(r), k.id .. ": rail " .. i .. " is UE's")
			end
			local sx, sy, sd = where(ep, v.box_signal)
			if out then
				ctx.expect(sx == 14.5 and sy == -0.5 and sd == 8, k.id .. ": the box signal at v1's spot: " .. sx .. "," .. sy .. "," .. sd)
				local hx, hy = where(ep, v.hold)
				ctx.expect(hx == 14.5 and hy == -36.5, k.id .. ": the hold signal at rail 19's inward end: " .. hx .. "," .. hy)
				ctx.expect(v.hold.signal_state == defines.signal_state.reserved_by_circuit_network, k.id .. ": closed for good")
				ctx.expect(v.box_signal.signal_state == defines.signal_state.open, k.id .. ": the empty box is open")
				-- SP4 (§5): no edge stop on either layer; the end rail, rail 20, is the trains' target
				ctx.expect(v.stop == nil and v.end_rail.unit_number == v.rails[20].unit_number, k.id .. ": no stop; the end rail is rail 20")
				local x1, y1, x2, y2 = geometry.area_to_world(ep.frame, 8, -42, 18, 2)
				ctx.expect(#game.get_surface("sp3b").find_entities_filtered{ area = { { x1, y1 }, { x2, y2 } }, type = "train-stop" } == 0,
					k.id .. ": no train stop at the box")
			else
				ctx.expect(sx == 11.5 and sy == -109.5 and sd == 0, k.id .. ": the outer signal at rail 55's end: " .. sx .. "," .. sy .. "," .. sd)
				ctx.expect(v.box_signal.signal_state == defines.signal_state.open, k.id .. ": the empty box is open")
			end
		end
	end)
end)

t.case("trains: a train held at the hold signal keeps its edge record, on ground and elevated rails (D22, the hold probe)", function(ctx)
	local rows = { { id = "sp3b-hold-g", y = 21600, layer = "ground" }, { id = "sp3b-hold-e", y = 22000, layer = "elevated" } }
	local front = {}
	ctx.at(402, function()
		for _, k in ipairs(rows) do
			seams.edge(k.id, k.y, { conn("ab", k.layer) })
		end
	end)
	ctx.at(420, function()
		for _, k in ipairs(rows) do
			ctx.expect(seams.endpoint(k.id, "t1").state == "ready", k.id .. ": built")
			seams.track(k.id, "t1", 60)
			seams.add(k.id, "t1", { layout = "LCC", at = 40, next = "SP3B NEXT", speed = 1 })
		end
	end)
	for _, tick in ipairs({ 1100, 1700 }) do
		ctx.at(tick, function()
			for _, k in ipairs(rows) do
				local trs, v = seams.trains(k.id, "t1"), ue.trains.get(k.id, "t1")
				local tr = trs[1]
				ctx.expect(#trs == 1 and tr.state == defines.train_state.wait_signal, k.id .. ": waiting at a signal (" .. tick .. ")")
				local _, y = geometry.to_local(seams.endpoint(k.id, "t1").frame, tr.front_stock.position.x, tr.front_stock.position.y)
				local _, hold_y = geometry.to_local(seams.endpoint(k.id, "t1").frame, v.hold.position.x, v.hold.position.y)
				-- Not tr.signal (ruling: an unrelated circuit wire elsewhere clears it, an engine quirk production
				-- code never reads): the hold still forced shut, and the front stopped within §12.6's margin of it.
				ctx.expect(v.hold.signal_state == defines.signal_state.reserved_by_circuit_network and y > hold_y and y <= hold_y + 5.5,
					k.id .. ": held at the hold signal, " .. (y - hold_y) .. " tiles short")
				local edge_name = "<rail>*" -- SP4 (§5): the end rail on both layers (U5 on ground)
				ctx.expect(names(tr) == edge_name .. ",SP3B NEXT" and tr.get_schedule().current == 1, k.id .. ": records " .. names(tr))
				ctx.expect(y > core.HOLD_END and y < -10, k.id .. ": short of the hold signal: " .. y)
				ctx.expect(front[k.id] == nil or front[k.id] == y, k.id .. ": it hasn't moved")
				front[k.id] = y
				ctx.expect(v.box_signal.signal_state == defines.signal_state.closed, k.id .. ": the box is occupied")
			end
		end)
	end
end)

t.case("trains: teardown keeps the rails under an approaching or waiting train and removes an empty box (§12.8)", function(ctx)
	local rows = {
		wait = { id = "sp3b-td-wait", y = 22400, c = conn("ab", "ground") },
		near = { id = "sp3b-td-near", y = 22800, c = conn("ab", "elevated") },
		empty = { id = "sp3b-td-empty", y = 23200, c = conn("ab", "ground") },
		inbound = { id = "sp3b-td-in", y = 23600, c = conn("ba", "ground") },
	}
	local kept, trains = {}, {}
	ctx.at(404, function()
		for _, k in pairs(rows) do
			seams.edge(k.id, k.y, { k.c })
		end
	end)
	ctx.at(422, function()
		ctx.expect(seams.endpoint(rows.wait.id, "t1").state == "ready", rows.wait.id .. ": built")
		seams.track(rows.wait.id, "t1", 60)
		seams.add(rows.wait.id, "t1", { layout = "LCC", at = 40, next = "SP3B NEXT", speed = 1 })
		seams.track(rows.near.id, "t1", 80)
		-- a wagon parked in the inbound box closes its outer signal
		local ep = seams.endpoint(rows.inbound.id, "t1")
		ctx.expect(ep.state == "ready", rows.inbound.id .. ": built")
		local x, y = geometry.to_world(ep.frame, 13, -40)
		ctx.expect(game.get_surface("sp3b").create_entity{ name = "cargo-wagon", position = { x, y },
			orientation = (geometry.dir_to_world(ep.frame, 8) / 16) % 1, force = "player" } ~= nil, "a wagon in the inbound box")
	end)
	ctx.at(1180, function()
		-- moving, so its path reservation reaches the box signal at once ([probe]: reserved one tick after it set off)
		seams.add(rows.near.id, "t1", { layout = "LC", at = 60, next = "SP3B NEXT", speed = 1 })
	end)
	ctx.at(1183, function()
		local wait, near = ue.trains.get(rows.wait.id, "t1"), ue.trains.get(rows.near.id, "t1")
		ctx.expect(wait.box_signal.signal_state == defines.signal_state.closed, "a train waits in the box")
		ctx.expect(near.box_signal.signal_state == defines.signal_state.reserved, "a train approaches: it reserved the box")
		ctx.expect(ue.trains.get(rows.inbound.id, "t1").box_signal.signal_state == defines.signal_state.closed, "inbound occupied")
		for name, k in pairs(rows) do
			kept[name] = ue.trains.get(k.id, "t1")
			if name ~= "empty" then
				trains[name] = seams.trains(k.id, "t1")[1] -- a reference to check against, once the endpoint below is gone
			end
			seams.edge(k.id, k.y, {}, { rev = 2 }) -- the connector leaves the record: the endpoint closes and tears down
		end
	end)
	ctx.at(1185, function()
		for name, v in pairs(kept) do
			for _, e in pairs({ v.box_signal, v.hold }) do
				ctx.expect(not e.valid, name .. ": its signals are gone")
			end
			if name ~= "empty" then
				ctx.expect(trains[name] and trains[name].valid, name .. ": its train survives teardown")
			end
			for i, r in ipairs(v.rails) do
				if name == "empty" then
					ctx.expect(not r.valid, name .. ": rail " .. i .. " removed")
				else
					ctx.expect(r.valid and r.minable_flag and not ue.owns(r), name .. ": rail " .. i .. " kept, the player's now")
				end
			end
		end
		-- §12.8, M5: the box's own hold is gone, so the train that was waiting at it is let go, not just un-destroyed: an
		-- automatic schedule to one of its own kept rails, past where the hold stood, actually finds a path there (a
		-- manual nudge proves nothing: 2.1.20 [probe], an un-reserved block doesn't stop manually-driven movement,
		-- hold or no hold; only automatic pathing respects a closed signal the way the hold case already relies on).
		local wait = trains.wait
		if wait and wait.valid and kept.wait.rails[core.OUT_RAILS] then
			local sched = wait.get_schedule()
			sched.set_records({ { rail = kept.wait.rails[core.OUT_RAILS] } })
			sched.go_to_station(1)
		end
	end)
	ctx.at(1300, function() -- [probe]: settled (arrived) by here if let go; still wait_signal throughout if not
		local wait = trains.wait
		ctx.expect(wait and wait.valid, "wait: its train still exists")
		if wait and wait.valid then
			ctx.expect(wait.state ~= defines.train_state.wait_signal,
				"wait: let go, found a path past the old hold instead of staying wait_signal (state " .. wait.state .. ")")
		end
	end)
end)

t.case("trains: a rail built across the border row proposes a train connector; one along it doesn't (§6.1)", function(ctx)
	ctx.at(406, function()
		seams.edge("sp3b-detect", 24000, {})
	end)
	ctx.at(440, function()
		heading_out(21, 24000)
		heading_out(41, 24000, "elevated")
		local s = game.get_surface("sp3b")
		-- side a: origin (0, 24000) facing north, so local (x, 1) is world (x, 24001)
		s.create_entity{ name = "straight-rail", position = { 21, 24001 }, direction = defines.direction.north, force = "player",
			raise_built = true }
		s.create_entity{ name = "elevated-straight-rail", position = { 41, 24001 }, direction = defines.direction.north,
			force = "player", raise_built = true }
		s.create_entity{ name = "straight-rail", position = { 31, 24001 }, direction = defines.direction.east, force = "player",
			raise_built = true }
		local got = {}
		for _, m in ipairs(storage.universal_edges.bridge.out.universal_edges or {}) do
			if m.type == "ue.connector.propose" and m.payload.edge == "sp3b-detect" then
				got[m.payload.pos] = m.payload
			end
		end
		local g, e = got[19], got[39]
		ctx.expect(g and g.type == "train" and g.width == 4 and g.params.dir == "ab" and g.params.layer == "ground", "the ground rail")
		ctx.expect(e and e.type == "train" and e.width == 4 and e.params.layer == "elevated", "the elevated rail")
		local n = 0
		for _ in pairs(got) do
			n = n + 1
		end
		ctx.expect(n == 2, "nothing for the rail along the edge: " .. n .. " proposals")
	end)
end)

-- Box shape 2 (owner 2026-10-05), rows 80000-83200 of "sp3b", ticks 3600-3660 (free: the save's cases end by 3850, and no
-- other case uses these rows).

--- Every entity of ep's box, supports included.
local function box_entities(ep)
	local d, out = ep.data, {}
	for _, r in ipairs(d.rails) do
		out[#out + 1] = r
	end
	for _, e in ipairs(d.supports or {}) do
		out[#out + 1] = e
	end
	for _, e in pairs({ d.box_signal, d.hold, d.comb, d.exit, d.outer }) do
		out[#out + 1] = e
	end
	return out
end

local function supports_in(ep)
	local s = game.get_surface(ep.frame.surface_index)
	local x1, y1, x2, y2 = geometry.area_to_world(ep.frame, 0, -112, 64, 3)
	return s.count_entities_filtered{ area = { { x1, y1 }, { x2, y2 } }, name = "rail-support" }
end

t.case("trains: a double track, the second rail proposed as its own link, both built (box shape 2)", function(ctx)
	-- each row: an existing connector, and a rail built across the border row beside it. The existing link's columns end
	-- where the new rail's would start, so the new rail is no longer taken as its border entity.
	local rows = {
		{ id = "sp3b-dt-r", y = 80000, have = { cid = "t1", type = "train", pos = 11, width = 4, params = { dir = "ba", layer = "ground" } },
			x = 17, col = 15, dir = "ab" }, -- the inbound on the left, an outbound proposed on the right
		{ id = "sp3b-dt-l", y = 80400, have = { cid = "t1", type = "train", pos = 15, width = 4, params = { dir = "ba", layer = "ground" } },
			x = 13, col = 11, dir = "ab" }, -- the inbound on the right, an outbound proposed on the left
	}
	ctx.at(3600, function()
		for _, k in ipairs(rows) do
			seams.edge(k.id, k.y, { k.have })
		end
	end)
	ctx.at(3640, function()
		for _, k in ipairs(rows) do
			ctx.expect(seams.endpoint(k.id, "t1").state == "ready", k.id .. ": the first link built")
			heading_out(k.x, k.y)
			game.get_surface("sp3b").create_entity{ name = "straight-rail", position = { k.x, k.y + 1 },
				direction = defines.direction.north, force = "player", raise_built = true }
			local got
			for _, m in ipairs(storage.universal_edges.bridge.out.universal_edges or {}) do
				if m.type == "ue.connector.propose" and m.payload.edge == k.id then
					got = m.payload
				end
			end
			ctx.expect(got and got.type == "train" and got.pos == k.col and got.width == 4 and got.params.dir == k.dir,
				k.id .. ": proposed as its own width-4 link, pos " .. tostring(got and got.pos))
			-- the proposal comes back as a connector: both links in the record
			local second = { cid = "t2", type = "train", pos = k.col, width = 4, params = { dir = k.dir, layer = "ground" } }
			seams.edge(k.id, k.y, { k.have, second }, { rev = 2 })
		end
	end)
	ctx.at(3680, function()
		for _, k in ipairs(rows) do
			local a, b = seams.endpoint(k.id, "t1"), seams.endpoint(k.id, "t2")
			ctx.expect(a.state == "ready" and b.state == "ready", k.id .. ": both built ready")
			for _, ep in ipairs({ a, b }) do
				for _, e in ipairs(box_entities(ep)) do
					local x = where(ep, e)
					ctx.expect(x > ep.col and x < ep.col + ep.width, k.id .. "/" .. ep.cid .. ": " .. e.name .. " at x " .. x
						.. " is inside its own columns " .. ep.col .. ".." .. ep.col + ep.width)
				end
			end
		end
	end)
end)

t.case("trains: the box shape: 20 rails out and 55 in, the hold at rail 19, the combinator beside it, the outer signal last", function(ctx)
	local out, inn = { id = "sp3b-shape-o", y = 80800, c = conn("ab", "ground") }, { id = "sp3b-shape-i", y = 81200, c = conn("ba", "ground") }
	ctx.at(3600, function()
		seams.edge(out.id, out.y, { out.c })
		seams.edge(inn.id, inn.y, { inn.c })
	end)
	ctx.at(3640, function()
		local ep, v = seams.endpoint(out.id, "t1"), ue.trains.get(out.id, "t1")
		ctx.expect(ep.state == "ready" and #v.rails == 20 and v.end_rail == v.rails[20], "outbound: 20 rails, the end rail last")
		local hx, hy = where(ep, v.hold)
		local cx, cy = where(ep, ep.data.comb)
		ctx.expect(hx == 14.5 and hy == -36.5, "the hold signal at rail 19's inward end: " .. hx .. "," .. hy)
		ctx.expect(cx == hx and cy == hy + 1, "the combinator in the signal column, one tile toward the border: " .. cx .. "," .. cy)
		ctx.expect(cy == core.COMB_Y and cx == 13 + core.COMB_DX, "and the constants say so")
		for _, e in ipairs(box_entities(ep)) do
			local x = where(ep, e)
			ctx.expect(x >= 12 and x <= 15, "outbound: " .. e.name .. " within cx - 1 .. cx + 2 (x " .. x .. ")")
		end
		local iep, iv = seams.endpoint(inn.id, "t1"), ue.trains.get(inn.id, "t1")
		local ox, oy = where(iep, iv.box_signal)
		ctx.expect(iep.state == "ready" and #iv.rails == 55 and ox == 11.5 and oy == -109.5,
			"inbound: the outer signal at rail 55's end: " .. ox .. "," .. oy)
		ctx.expect(oy == core.OUTER_END + 0.5, "at OUTER_END")
		ctx.expect(supports_in(ep) == 0 and supports_in(iep) == 0, "a ground box has no supports")
	end)
end)

t.case("trains: an elevated box has rail supports, 3 under an outbound one and 7 under an inbound one; teardown removes them", function(ctx)
	local out, inn = { id = "sp3b-sup-o", y = 81600, c = conn("ab", "elevated") }, { id = "sp3b-sup-i", y = 82000, c = conn("ba", "elevated") }
	local held = {}
	ctx.at(3600, function()
		seams.edge(out.id, out.y, { out.c })
		seams.edge(inn.id, inn.y, { inn.c })
	end)
	ctx.at(3640, function()
		for _, k in ipairs({ { out, 3 }, { inn, 7 } }) do
			local ep = seams.endpoint(k[1].id, "t1")
			ctx.expect(ep.state == "ready", k[1].id .. ": built")
			ctx.expect(#ep.data.supports == k[2] and supports_in(ep) == k[2],
				k[1].id .. ": supports " .. #ep.data.supports .. " recorded, " .. supports_in(ep) .. " standing")
			for _, e in ipairs(ep.data.supports) do
				ctx.expect(not e.minable_flag and not e.destructible, k[1].id .. ": a support is UE's")
				held[#held + 1] = e
			end
			seams.edge(k[1].id, k[1].y, {}, { rev = 2 })
		end
	end)
	ctx.at(3660, function()
		for i, e in ipairs(held) do
			ctx.expect(not e.valid, "support " .. i .. " removed by teardown")
		end
	end)
end)

t.case("trains: a width-6 link, as the owner's existing ones, still builds with its rail at col + 3", function(ctx)
	local id = "sp3b-w6"
	ctx.at(3600, function()
		seams.edge(id, 82400, { { cid = "t1", type = "train", pos = 10, width = 6, params = { dir = "ab", layer = "ground" } } })
	end)
	ctx.at(3640, function()
		local ep = seams.endpoint(id, "t1")
		ctx.expect(ep.state == "ready" and train.cx(ep) == 13, "built, the rail's centre at 13")
		local x = where(ep, ue.trains.get(id, "t1").rails[1])
		ctx.expect(x == 13, "rail 1 at x " .. x)
	end)
end)

t.case("trains: a box built in the old shape is rebuilt once into the new one (box shape 2)", function(ctx)
	local out, inn = { id = "sp3b-mig-o", y = 82800, c = conn("ab", "elevated") }, { id = "sp3b-mig-i", y = 83200, c = conn("ba", "ground") }
	local before = {}

	--- A ue-rail-signal at rail's "in" spot at local y ey, as v1's boxes had them.
	local function old_signal(ep, rail, ey)
		local s = game.get_surface(ep.frame.surface_index)
		for _, dir in pairs(defines.rail_direction) do
			local e = rail.get_rail_end(dir)
			if math.abs(train.local_y(ep, e.location.position) - ey) < 0.01 then
				local spot = e.in_signal_location
				return s.create_entity{ name = "ue-rail-signal", position = spot.position, direction = spot.direction,
					rail_layer = spot.rail_layer, force = "player" }
			end
		end
	end

	ctx.at(3600, function()
		seams.edge(out.id, out.y, { out.c })
		seams.edge(inn.id, inn.y, { inn.c })
	end)
	ctx.at(3640, function()
		-- put both back into the old shape: shorter outbound with its hold at rail 11 and its combinator at the old spot, the
		-- inbound's outer signal at rail 50, no supports, and no shape mark
		local oep, iep = seams.endpoint(out.id, "t1"), seams.endpoint(inn.id, "t1")
		ctx.expect(oep.state == "ready" and iep.state == "ready", "both built")
		for _, ep in ipairs({ oep, iep }) do
			local d = ep.data
			for _, e in pairs({ d.hold, d.comb, d.outer }) do
				e.destroy()
			end
			for _, e in ipairs(d.supports) do
				e.destroy()
			end
			for i = #d.rails, 13, -1 do
				if ep == iep then
					break -- the old inbound box was 55 rails too, only its outer signal stood at rail 50
				end
				d.rail_ids[d.rails[i].unit_number] = nil
				d.rails[i].destroy()
				d.rails[i] = nil
			end
			d.supports, d.shape = {}, nil
		end
		oep.data.hold = old_signal(oep, oep.data.rails[11], -20)
		local cx, cy = train.world(oep, 13 + 2.5, -18.5)
		oep.data.comb = game.get_surface("sp3b").create_entity{ name = "ue-hold-combinator", position = { cx, cy }, force = "player" }
		iep.data.outer = old_signal(iep, iep.data.rails[50], -100)
		ctx.expect(oep.data.hold and oep.data.comb and iep.data.outer, "the old hold, combinator and outer signal stand")
		before[1] = oep.data.rails[1].unit_number
		train.migrate()
		before[2] = oep.data.hold.unit_number
		train.migrate() -- a second start changes nothing
		ctx.expect(oep.data.hold.unit_number == before[2] and oep.data.rails[1].unit_number == before[1], "a second pass changes nothing")
	end)
	ctx.at(3680, function()
		local oep, iep = seams.endpoint(out.id, "t1"), seams.endpoint(inn.id, "t1")
		ctx.expect(oep.state == "ready" and iep.state == "ready" and oep.data.shape == core.SHAPE and iep.data.shape == core.SHAPE,
			"rebuilt and marked")
		local v = ue.trains.get(out.id, "t1")
		local hx, hy = where(oep, v.hold)
		local cx, cy = where(oep, oep.data.comb)
		ctx.expect(#v.rails == 20 and hx == 14.5 and hy == -36.5 and cx == 14.5 and cy == -35.5,
			"outbound: 20 rails, the new hold and combinator")
		ctx.expect(oep.data.hold.signal_state == defines.signal_state.reserved_by_circuit_network, "the new hold is closed")
		ctx.expect(oep.data.rails[1].unit_number == before[1], "the old rails are adopted, not replaced")
		ctx.expect(#oep.data.supports == 3, "the supports are added: " .. #oep.data.supports)
		local iv = ue.trains.get(inn.id, "t1")
		local _, oy = where(iep, iv.box_signal)
		ctx.expect(#iv.rails == 55 and oy == -109.5, "inbound: 55 rails, the outer signal at the end")
		local m = 0
		for _ in pairs(game.get_surface("sp3b").find_entities_filtered{ name = "ue-rail-signal",
			area = { { 0, 83200 - 120 }, { 40, 83200 + 5 } } }) do
			m = m + 1
		end
		ctx.expect(m == 2, "inbound: the exit signal and the new outer only (old outer gone): " .. m)
		local n = 0
		for _ in pairs(game.get_surface("sp3b").find_entities_filtered{ name = "ue-rail-signal",
			area = { { 0, 82800 - 120 }, { 40, 82800 + 5 } } }) do
			n = n + 1
		end
		ctx.expect(n == 2, "outbound: the box signal and the new hold only (old hold gone): " .. n)
	end)
end)

t.case("trains: an old-shape endpoint that isn't ready is rebuilt by its normal build, leaving no orphans (box shape 2)", function(ctx)
	local out, inn = { id = "sp3b-nr-o", y = 83600, c = conn("ab", "ground") }, { id = "sp3b-nr-i", y = 84000, c = conn("ba", "ground") }
	local function old_signal(ep, rail, ey)
		local s = game.get_surface(ep.frame.surface_index)
		for _, dir in pairs(defines.rail_direction) do
			local e = rail.get_rail_end(dir)
			if math.abs(train.local_y(ep, e.location.position) - ey) < 0.01 then
				local spot = e.in_signal_location
				return s.create_entity{ name = "ue-rail-signal", position = spot.position, direction = spot.direction,
					rail_layer = spot.rail_layer, force = "player" }
			end
		end
	end
	local function count(y)
		return game.get_surface("sp3b").count_entities_filtered{ area = { { 0, y - 120 }, { 40, y + 5 } }, name = "ue-rail-signal" }
	end
	ctx.at(3600, function()
		seams.edge(out.id, out.y, { out.c })
		seams.edge(inn.id, inn.y, { inn.c })
	end)
	ctx.at(3720, function()
		local oep, iep = seams.endpoint(out.id, "t1"), seams.endpoint(inn.id, "t1")
		ctx.expect(oep.state == "ready" and iep.state == "ready", "both built")
		-- the old shape, not ready: the new hold, combinator and outer signal are swapped for the old ones
		for _, ep in ipairs({ oep, iep }) do
			for _, e in pairs({ ep.data.hold, ep.data.comb, ep.data.outer }) do
				e.destroy()
			end
			ep.data.shape = nil
		end
		oep.data.hold = old_signal(oep, oep.data.rails[11], -20)
		local cx, cy = train.world(oep, 13 + 2.5, -18.5)
		oep.data.comb = game.get_surface("sp3b").create_entity{ name = "ue-hold-combinator", position = { cx, cy }, force = "player" }
		iep.data.outer = old_signal(iep, iep.data.rails[50], -100)
		oep.state, iep.state = "blocked", "pending"
		connectors.build(oep, game.tick)
		connectors.build(iep, game.tick)
	end)
	ctx.at(3780, function()
		local oep, iep = seams.endpoint(out.id, "t1"), seams.endpoint(inn.id, "t1")
		ctx.expect(oep.state == "ready" and iep.state == "ready" and oep.data.shape == core.SHAPE and iep.data.shape == core.SHAPE,
			"rebuilt into the new shape")
		ctx.expect(count(out.y) == 2, "outbound: the box signal and the new hold only: " .. count(out.y))
		ctx.expect(count(inn.y) == 2, "inbound: the exit signal and the new outer only: " .. count(inn.y))
		local combs = game.get_surface("sp3b").count_entities_filtered{
			area = { { 0, out.y - 120 }, { 40, out.y + 5 } }, name = "ue-hold-combinator" }
		ctx.expect(combs == 1, "outbound: one combinator: " .. combs)
	end)
end)
