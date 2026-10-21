-- The fluid connector type (SP3 spec §8.3): a ue-link-pipe per side, joined to the border pipe's or pump's segment and
-- balanced with the shared rule (balance_core). The bag's keys are fluid names; the temperature rides in the status.
-- The link entity is still called "tank" in code (ep.data.tank, the `tank` locals below) from when it was a
-- storage-tank copy; it's a ue-link-pipe (pipe-to-ground) now, kept for a smaller diff (visuals batch, 2026-10-04).
local bridge = require("modules/universal_edges/runtime/bridge")
local connectors = require("modules/universal_edges/edges/connectors")
local geometry = require("modules/universal_edges/edges/geometry_core")
local balance = require("modules/universal_edges/transports/balance_core")
local detect = require("modules/universal_edges/transports/detect")

local NAME, LINK = "ue-link-pipe", 25000
local send = bridge.channel("universal_edges")

local function out_dir(ep)
	return ep.me == "a" and "ab" or "ba"
end

--- The segment: whole units held, its capacity, its fluid and temperature (nil and nil when empty), and the raw amount.
local function read(ep)
	local tank = ep.data.tank
	local f = tank.get_fluid_segment_fluid(1)
	local raw = f and f.amount or 0
	return math.floor(raw), tank.get_fluid_segment_capacity(1), f and f.name, f and f.temperature, raw
end

local function dropped(ep, fluid, amount)
	ep.data.stats.dropped = ep.data.stats.dropped + amount
	send("trace", { op = "ue.fluid", phase = "refund_dropped", level = "warn", tick = game.tick, trace = ep.trace,
		edge = ep.edge, cid = ep.cid, fluid = fluid, amount = amount })
end

connectors.register_type({
	name = "fluid",
	lanes = function() return { ab = "stream", ba = "stream" } end,
	schedule = { per_tick = 4, interval = 60 },
	--- F9: adopts its tank, or creates it at local (col + 0.5, -0.5) facing inward: its one connection faces the way it
	--- faces, so it joins the border pipe's segment ([probe]).
	build = function(ep)
		local surface = game.get_surface(ep.frame.surface_index)
		if not surface then
			return "blocked"
		end
		local d = ep.data
		if not (d.tank and d.tank.valid) then
			local x, y = geometry.to_world(ep.frame, ep.col + 0.5, -0.5)
			local tank = surface.find_entity(NAME, { x, y }) or surface.create_entity({ name = NAME, position = { x, y },
				direction = geometry.dir_to_world(ep.frame, 8), force = "player", create_build_effect_smoke = false })
			if not tank then
				return "blocked"
			end
			tank.destructible, tank.operable = false, false
			d.tank = tank
		end
		d.stats = d.stats or { sent = 0, got = 0, dropped = 0 }
		detect.adopt(ep)
		return "ready"
	end,
	poll = function(ep, tick)
		detect.check(ep)
		local d, tank = ep.data, ep.data.tank
		if not tank.valid then
			-- The prototype can vanish from under a save (e.g. this batch's tank → pipe rename): rebuild on the next
			-- visit (G1) rather than polling a dead reference forever. Whatever fluid it held is lost (dev worlds only).
			d.tank, ep.state, ep.next_build = nil, "blocked", tick
			return
		end
		local A, C, name, temp = read(ep)
		local st = ep.status
		if not st or math.abs(A - st.a) >= C / 64 or st.fluid ~= name or st.r ~= d.stats.got then
			ep:set_status({ a = A, c = C, r = d.stats.got, fluid = name, t = temp })
		end
		local dir, theirs = out_dir(ep), ep.partner and ep.partner.status
		-- As power's: a refused remainder re-offers once the partner's status shows room, for this fluid.
		if theirs and theirs.c and (theirs.fluid == nil or theirs.fluid == name) and not ep:idle(dir)
			and balance.has_room(theirs) then
			ep:nudge(dir)
		end
		-- §8.3: different fluids on the two sides send nothing, as v1 skipped them (fluid_link.lua:89).
		if not (name and theirs and theirs.c and (theirs.fluid == nil or theirs.fluid == name) and ep:idle(dir)
			and ep:can_send(dir)) then
			return
		end
		local a = balance.amount(A, C, balance.partner(theirs, d.stats.sent), theirs.c, LINK)
		if a > 0 then
			ep:send(dir, { [name] = a }) -- first: a refused send raises before anything is removed
			tank.remove_fluid_segment_fluid(1, a)
			d.stats.sent = d.stats.sent + a
		end
	end,
	--- T2: the segment takes what fits of its own fluid (or of the first key, empty), at the partner's temperature; any
	--- other fluid takes 0 and waits in escrow for a re-offer or a refund (§8.3).
	--- Fix round 1 (open finding): the link entity can go invalid out from under a still-"ready" endpoint (e.g. an
	--- upgraded save's old ue-link-tank, gone before this endpoint's own first poll notices -- poll's guard above).
	--- Request the same rebuild poll does and take nothing this time: an empty accepted bag is the stream lane's
	--- "took 0" (ledger_core.lua kinds.stream.receive's rx.s.offer only credits keys with accepted[k] >= 1), so the
	--- sender's escrow holds the whole bag for a re-offer instead of it being lost to a raise that fails the endpoint.
	credit = function(ep, _, bag)
		local d, tank = ep.data, ep.data.tank
		if not (tank and tank.valid) then
			d.tank, ep.state, ep.next_build = nil, "blocked", game.tick
			return {}
		end
		local _, C, name, _, raw = read(ep)
		local theirs = ep.partner and ep.partner.status
		local accepted = {}
		for k, v in pairs(bag) do
			local x = 0
			if name == nil or name == k then
				x = math.min(v, math.floor(C - raw)) -- the room on the raw amount (review M2)
				if x > 0 then
					x = math.floor(tank.add_fluid_segment_fluid(1, { name = k, amount = x,
						temperature = theirs and theirs.t }))
					raw, name = raw + x, k
				end
			end
			accepted[k] = math.max(0, x)
			d.stats.got = d.stats.got + accepted[k]
		end
		return accepted
	end,
	--- §8.4: the segment keeps what it can hold without the tank ([probe] on 2.1.20: a destroyed tank takes no fluid);
	--- what no longer fits is lost and logged (plan ruling 8). With ten pipes behind it, a half-full link loses 12,000.
	teardown = function(ep)
		local tank = ep.data.tank
		if not (tank and tank.valid) then
			return
		end
		local _, _, name, _, raw = read(ep)
		tank.destroy()
		local border = ep.data.border
		local f = border and border.valid and border.get_fluid_segment_fluid(1)
		local lost = math.floor(raw - (f and f.amount or 0))
		if name and lost > 0 then
			dropped(ep, name, lost)
		end
	end,
	--- §8.4, T5 bent on purpose: into the border entity's segment; the rest dropped and logged.
	refund = function(ep, _, bag)
		local border = ep.data.border
		for k, v in pairs(bag) do
			local put = 0
			if border and border.valid then
				put = math.floor(border.add_fluid_segment_fluid(1, { name = k, amount = v }))
			end
			if put < v then
				dropped(ep, k, v - put)
			end
		end
		return true
	end,
})
