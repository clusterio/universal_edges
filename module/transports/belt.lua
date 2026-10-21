-- The belt connector type (SP3 spec §7): lane parity in exact order (D15, D31) over an ordered lane, stacks whole.
-- Each side has five UE belt stubs, of its border belt's tier (belt spacing spec §4), outside its border column. The
-- source's face outward, fed by the player's border belt; its poll captures every stack on them each poll and times
-- each one (belt spacing spec §5). The destination's face inward and feed the player's belt; its poll puts each
-- credited stack down on a per-lane clock, so the destination's border belt sees the source's gaps (§7).
local connectors = require("modules/universal_edges/edges/connectors")
local geometry = require("modules/universal_edges/edges/geometry_core")
local core = require("modules/universal_edges/transports/belt_core")
local detect = require("modules/universal_edges/transports/detect")
local items = require("modules/universal_edges/transports/items")

local LANES = { defines.transport_line.left_line, defines.transport_line.right_line }

-- ponytail: module-level memos, never evicted. Prototypes are fixed while the game runs and the values are pure
-- functions of them, so a joining client's fresh memo computes the same (as belt_core's key memo).
local tiers, belts, names = {}, nil, nil

--- The loaded transport belts without UE's, sorted by name (belt spacing spec §4), once.
local function transport_belts()
	if not belts then
		belts = {}
		for name, p in pairs(prototypes.get_entity_filtered({ { filter = "type", type = "transport-belt" } })) do
			if string.sub(name, 1, 3) ~= "ue-" then
				belts[#belts + 1] = p
			end
		end
		table.sort(belts, function(a, b) return a.name < b.name end)
	end
	return belts
end

--- The UE belt for a border prototype name (nil: the fastest), memoized (belt spacing spec §4).
local function tier_of(name)
	local key = name or false
	local t = tiers[key]
	if not t then
		t = core.ue_belt(name and prototypes.entity[name], transport_belts())
		tiers[key] = t
	end
	return t
end

--- Every UE belt's name, once.
local function ue_names()
	if not names then
		names = {}
		for i, b in ipairs(transport_belts()) do
			names[i] = core.ue_name(b.name)
		end
	end
	return names
end

local function outbound(ep)
	return (ep.params.dir == "ab") == (ep.me == "a")
end

-- ponytail: one insert spec table, reused for every placed stack (as power.lua's ALL is reused for get_accumulators_
-- energy's filter), its fields reassigned each time instead of a fresh table per stack (perf item 2). insert_at reads
-- the fields synchronously and doesn't keep the table, so nothing else can observe a stale value between calls.
local INSERT = {}

--- Spill on the border tile inside (§7.7, items.spill), counted in stats[field]: "spilled" for a destination's buffer,
--- "stubbed" for what stood on the stubs at teardown (either side), "refunded" for a refund.
local function spill(ep, name, quality, count, field, spoil_percent)
	items.spill(ep, name, quality, count, spoil_percent)
	ep.data.stats[field] = ep.data.stats[field] + count
end

--- §7.4: the destination's limits; announced at build, then whenever one has grown by W/4.
local function announce(ep, force)
	local d = ep.data
	local l1 = core.limit(d.stats.got[1], core.buffered(d.buf[1]))
	local l2 = core.limit(d.stats.got[2], core.buffered(d.buf[2]))
	local old = ep.status and ep.status.lim
	if force or not old or core.grown(old[1], l1) or core.grown(old[2], l2) then
		ep:set_status({ lim = { l1, l2 } })
	end
end

--- The lane's item count, summed with get_item_count over its five stubs (no tables): §7.2 step 2's cheap pre-check,
--- paid before a backed-up lane's read.
local function count_lane(d, lane)
	local n = 0
	for i = 1, core.STUBS do
		n = n + d.lines[i][lane].get_item_count()
	end
	return n
end

--- Belt spacing spec §5: one lane of the source's stubs as runs with a gap a stack, the outer stub (the front) first,
--- every stack read in detail (front first: ascending position [probe]) and timed by core.entry from the stubs' speed.
--- Returns the runs and the lane's last entry tick (the reference for the next capture's first gap). A piled stack's
--- earlier tick never moves the reference back. An item's own data (armor grids, blueprints, tags) crosses as a plain
--- item: that data is dropped, as it already was before D38; ponytail: still true here, and still the belt's whole D38
--- story for it.
local function read_lane(d, lane, now)
	local runs, last = {}, d.last[lane]
	for k = core.STUBS, 1, -1 do
		for _, e in ipairs(d.lines[k][lane].get_detailed_contents()) do
			local t = core.entry(k, e.position, d.speed, now)
			local gap = core.gap(t, last)
			last = math.max(last or t, t)
			local st = e.stack
			local name, q = st.name, st.quality.name
			local p = items.spoilable(name, q) and core.spoil_p(st.spoil_percent) or nil
			core.add_stack(runs, lane, name, q, st.count, p, gap)
		end
	end
	return runs, last
end

--- Belt spacing spec §5 (replaces SP3 spec §7.2 step 1): each lane with items on the stubs, within the window and the
--- run cap, in one send; the stubs are cleared only after the send took the runs (T1: a refused send raises first, and
--- nothing is lost, and d.last stays, so the stacks are timed again next poll). The window (step 2) is checked against
--- the item count alone, before the read (step 3): a backed-up lane, a belt's common steady state, costs nothing past
--- the stub counts (§13 rule 5). `core.may_capture` with runs = unacked = 0 is the window alone, since 0 + 0 never
--- trips the 64-run clause; the run cap (step 4) is checked again, in full, once the runs are known.
local function capture(ep)
	local d, dir = ep.data, ep.params.dir
	local n1, n2 = count_lane(d, 1), count_lane(d, 2)
	if (n1 == 0 and n2 == 0) or not ep:can_send(dir) then
		return -- an idle visit: five item counts a lane, ten in all, no table (§13 rule 5)
	end
	d.last = d.last or {} -- R7: an endpoint built before the deploy has none
	local now = game.tick
	local lim = ep.partner.status and ep.partner.status.lim
	local all, taken, sent = nil, nil, 0
	for lane = 1, 2 do
		local n = lane == 1 and n1 or n2
		if n > 0 then
			local l = type(lim) == "table" and lim[lane] or nil
			if core.may_capture(d.stats.captured[lane], n, l, 0, 0) then
				local runs, last = read_lane(d, lane, now)
				if core.may_capture(d.stats.captured[lane], n, l, sent + #runs, ep:runs(dir)) then
					all, taken = all or {}, taken or {}
					for _, r in ipairs(runs) do
						all[#all + 1] = r
					end
					taken[#taken + 1] = { lane, n, last }
					sent = sent + #runs
				end
			end
		end
	end
	if not all then
		return
	end
	ep:send(dir, all)
	for _, x in ipairs(taken) do
		for i = 1, core.STUBS do
			d.lines[i][x[1]].clear()
		end
		d.stats.captured[x[1]] = d.stats.captured[x[1]] + x[2]
		d.last[x[1]] = x[3]
	end
end

--- The distance from the inner end of the back-most item on a lane's stubs (the largest (k - 1) + position on the first
--- non-empty stub from the outer end); -1 when every stub is empty.
local function back_of(d, lane)
	local back = -1
	for k = core.STUBS, 1, -1 do
		local line = d.lines[k][lane]
		if #line > 0 then
			for _, e in ipairs(line.get_detailed_contents()) do
				back = math.max(back, (k - 1) + e.position)
			end
			break
		end
	end
	return back
end

--- Belt spacing spec §7: each lane's FIFO goes down front first, a stack at a time, at the distance its clock puts it
--- (core.due, core.place_at): 1. an entry from before the deploy is stamped with this tick, once; 2. its due from the
--- lane's clock; 3. its distance, nil (it waits, or the stubs are full) ends the lane's poll; 4. the stack goes onto the
--- stub that distance falls on, a refused insert ends the lane's poll; 5. the clock moves to where the stack went (now
--- + dist / v), late and re-anchored stacks are counted; 6. the FIFO and the back-most distance advance.
local function place(ep)
	local d = ep.data
	d.due = d.due or {}
	local now = game.tick
	for lane = 1, 2 do
		local q = d.buf[lane]
		if q[1] then
			local back = back_of(d, lane)
			while q[1] do
				q[1].at = q[1].at or now
				local due, re = core.due(q[1], d.due[lane], now)
				local dist = core.place_at(due, now, d.speed, back)
				if not dist then
					break
				end
				local k = math.floor(dist) + 1
				local name, quality, c, p = core.next_stack(q)
				INSERT.name, INSERT.quality, INSERT.count = name, quality, c
				-- D38: insert_at takes an ItemStackDefinition, which carries spoil_percent ([api]); cleared to nil
				-- when this stack doesn't spoil, so a previous stack's value never leaks onto this one.
				INSERT.spoil_percent = p and p / 100 or nil
				if not d.lines[k][lane].insert_at(dist - (k - 1), INSERT, c) then
					break
				end
				d.due[lane] = now + dist / d.speed
				if re then
					d.stats.reanchored = (d.stats.reanchored or 0) + 1
				end
				if due < now then
					d.stats.late = (d.stats.late or 0) + 1
				end
				back = dist
				core.consume(q, c)
				d.stats.placed = d.stats.placed + c
			end
		end
	end
	announce(ep, false)
end

--- Belt spacing spec §4, "Swap": the five stubs become `name`, one at a time, in place. Each stub's stacks are copied to
--- plain tables first (an item stack's fields are gone once its entity is), the stub is destroyed and the new one built
--- there with the same direction, and the stacks go back at their positions with their own freshness. A stack that won't
--- go back, or every stack of a stub that couldn't be built (R12, raised), spills at the border tile inside as stubbed.
--- No raise_* anywhere: detection never sees the stubs.
local function swap(ep, name)
	-- before anything is destroyed: create_entity with an unknown name raises after destroy() and the stacks are lost
	if not prototypes.entity[name] then
		error("no prototype " .. name .. ": the UE mod is older than this module, or the belt was added after universal_edges")
	end
	local d = ep.data
	local surface = d.stubs[1].surface
	local failed
	for i = 1, core.STUBS do
		local old = d.stubs[i]
		local kept = {}
		for lane = 1, 2 do
			for _, e in ipairs(d.lines[i][lane].get_detailed_contents()) do
				local st = e.stack
				local sname, q = st.name, st.quality.name
				kept[#kept + 1] = { lane = lane, position = e.position, name = sname, quality = q,
					count = st.count,
					spoil_percent = items.spoilable(sname, q) and st.spoil_percent or nil }
			end
		end
		local position, direction = old.position, old.direction
		old.destroy()
		local stub = surface.create_entity({ name = name, position = position, direction = direction, force = "player",
			create_build_effect_smoke = false })
		if stub then
			stub.destructible, stub.operable = false, false
			d.stubs[i] = stub
			d.lines[i] = { stub.get_transport_line(LANES[1]), stub.get_transport_line(LANES[2]) }
		else
			failed = failed or ("could not build " .. name .. " at " .. serpent.line(position))
		end
		for _, k in ipairs(kept) do
			INSERT.name, INSERT.quality, INSERT.count, INSERT.spoil_percent = k.name, k.quality, k.count, k.spoil_percent
			if not (stub and d.lines[i][k.lane].insert_at(k.position, INSERT, k.count)) then
				spill(ep, k.name, k.quality, k.count, "stubbed", k.spoil_percent)
			end
		end
	end
	d.tier, d.speed = name, prototypes.entity[name].belt_speed
	if failed then
		error(failed) -- R12
	end
end

--- §4: once the border entity is replaced (an upgrade, a downgrade, a hand or robot fast-replace, a belt for an
--- underground) or after a build, the stubs become its tier. While nothing changed this is one .valid and one
--- unit_number read. With no valid border entity it acts only at the first poll after a build (R11): a border that has
--- gone is being removed, and its link keeps its stubs.
local function rematch(ep)
	local d = ep.data
	local b = d.border
	local u = b and b.valid and b.unit_number or false
	if u == d.matched or (not u and d.matched ~= nil) then
		return
	end
	d.matched = u
	local want = tier_of(u and b.name or nil)
	if want ~= d.tier then
		swap(ep, want)
	end
end

connectors.register_type({
	name = "belt",
	lanes = function(params)
		return { [params.dir] = "ordered" }
	end,
	validate = function(params)
		if type(params) ~= "table" or (params.dir ~= "ab" and params.dir ~= "ba") then
			return false, "belt params need dir = ab|ba"
		end
		return true
	end,
	schedule = { per_tick = 4, interval = 32 },
	--- F9: idempotent. Belt spacing spec §4, "Build": the stubs are the border belt's tier (an underground's belt, none
	--- the fastest). Adopts the stubs at their positions (any tier: the first poll re-matches them), creates the
	--- missing ones, caches their lines, and records the tier and the speed the timing uses (d.matched nil: the first
	--- poll checks the tier).
	build = function(ep)
		local surface = game.get_surface(ep.frame.surface_index)
		if not surface then
			return "blocked"
		end
		local d = ep.data
		d.stats = d.stats or { captured = { 0, 0 }, got = { 0, 0 }, placed = 0, spilled = 0, stubbed = 0, refunded = 0,
				late = 0, reanchored = 0 }
		d.last, d.due = {}, {} -- R15: a rebuilt endpoint starts a fresh clock
		d.buf = d.buf or { {}, {} }
		d.stubs, d.lines = d.stubs or {}, {}
		detect.adopt(ep)
		local want = tier_of(d.border and d.border.valid and d.border.name or nil)
		local direction = geometry.dir_to_world(ep.frame, outbound(ep) and 0 or 8)
		for i = 1, core.STUBS do
			local x, y = geometry.to_world(ep.frame, ep.col + 0.5, -0.5 - (i - 1))
			local e = d.stubs[i]
			if not (e and e.valid) then
				e = surface.find_entities_filtered({ position = { x, y }, name = ue_names(), limit = 1 })[1]
					or surface.create_entity({ name = want, position = { x, y }, direction = direction,
						force = "player", create_build_effect_smoke = false })
				if not e then
					return "blocked"
				end
				e.destructible, e.operable = false, false
				d.stubs[i] = e
			end
			d.lines[i] = { e.get_transport_line(LANES[1]), e.get_transport_line(LANES[2]) }
		end
		d.tier = d.stubs[1].name
		for i = 2, core.STUBS do
			if d.stubs[i].name ~= d.tier then
				d.tier = nil
			end
		end
		d.speed = prototypes.entity[d.stubs[1].name].belt_speed
		d.matched = nil
		if not outbound(ep) then
			announce(ep, true)
		end
		return "ready"
	end,
	--- §7.7: the source's stubs, and the destination's buffer and stubs, spill on the border tile inside. D38:
	--- both restore freshness where the item has any — the buffer's runs already carry p (core.take); the stubs are
	--- read in detail (not get_contents) so each stack's own spoil_percent spills with it.
	teardown = function(ep)
		local d = ep.data
		for lane = 1, 2 do
			for _, run in ipairs(d.buf and d.buf[lane] or {}) do
				spill(ep, run[3], run[4], run[2], "spilled", run[6] and run[6] / 100 or nil)
			end
		end
		d.buf = { {}, {} }
		for _, e in ipairs(d.stubs or {}) do
			if e.valid then
				for _, lane in ipairs(LANES) do
					for _, item in ipairs(e.get_transport_line(lane).get_detailed_contents()) do
						spill(ep, item.stack.name, item.stack.quality.name, item.stack.count, "stubbed", item.stack.spoil_percent)
					end
				end
				e.destroy()
			end
		end
		d.stubs, d.lines = nil, nil
		if d.reversed then
			-- Belt-flip: the poll above found this border entity's live direction disagreeing with params.dir and
			-- asked for removal; now that the controller's removal has actually landed and torn this connector down,
			-- the entity (still standing, only rotated or flipped) is proposed again in its new direction.
			local side = storage.universal_edges.edges[ep.edge]
			if side then
				detect.repropose(side, d.reversed)
			end
			d.reversed = nil
		end
	end,
	poll = function(ep)
		detect.check(ep)
		-- Belt-flip (owner, 2026-10-04): the border belt or underground's current direction, re-derived from its live
		-- facts exactly as a fresh build would be, disagrees with this link's own params.dir — rotated or flipped
		-- since it was adopted. Asked for once (d.reversed guards it); detect.repropose (teardown below, once the
		-- controller's removal actually lands) proposes the new direction from the same entity, like a fresh build.
		local d = ep.data
		if not d.reversed and d.border then
			local now = detect.propose_now(ep)
			if now and now.params.dir and now.params.dir ~= ep.params.dir then
				d.reversed = d.border
				ep:request_removal("reversed")
			end
		end
		if not d.reversed then
			rematch(ep)
		end
		-- The stubs' speed (tiles a tick), made here for endpoints built before the deploy (R7).
		d.speed = d.speed or prototypes.entity[d.stubs[1].name].belt_speed
		if outbound(ep) then
			capture(ep)
		else
			place(ep)
		end
	end,
	--- §7.5: the whole ordered list goes into the FIFOs (T2); the window bounds them.
	credit = function(ep, _, list)
		return core.take(ep.data.buf, list, ep.data.stats.got, game.tick)
	end,
	--- T5, with D38: a refund spills at the border tile inside, with the key's own freshness if it had any.
	refund = function(ep, _, bag)
		for k, n in pairs(bag) do
			local _, name, quality, _, p = core.parse(k)
			spill(ep, name, quality, n, "refunded", p and p / 100 or nil)
		end
		return true
	end,
})
