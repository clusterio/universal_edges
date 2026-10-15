-- The belt connector type (SP3 spec §7): lane parity in exact order (D15, D31) over an ordered lane, stacks whole.
-- Each side has five ue-link-belt stubs outside its border column. The source's face outward, fed by the player's
-- border belt; its poll captures what reached them. The destination's face inward and feed the player's belt; its poll
-- puts down what it was credited, behind what is already on them.
local connectors = require("modules/universal_edges/edges/connectors")
local geometry = require("modules/universal_edges/edges/geometry_core")
local core = require("modules/universal_edges/transports/belt_core")
local detect = require("modules/universal_edges/transports/detect")
local items = require("modules/universal_edges/transports/items")

local NAME = "ue-link-belt"
local LANES = { defines.transport_line.left_line, defines.transport_line.right_line }

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

--- §7.2 step 3: one lane of the source's stubs as runs, the outer stub (the front) first. One item and quality, none
--- of it spoilable: the fast path's single run (get_contents has no freshness, D38). Several items, or any spoilable
--- one (even alone, since its stacks may differ in freshness): the stacks, read front first (get_detailed_contents),
--- grouped into runs. An item's own data (armor grids, blueprints, tags) crosses as a plain item: that data is
--- dropped, as it already was before D38; ponytail: still true here, and still the belt's whole D38 story for it.
local function read_lane(d, lane)
	local name, quality, n, stacks, mixed, spoils = nil, nil, 0, 0, false, false
	for i = core.STUBS, 1, -1 do
		local line = d.lines[i][lane]
		for _, c in ipairs(line.get_contents()) do
			if name and (c.name ~= name or c.quality ~= quality) then
				mixed = true
			end
			name, quality, n = name or c.name, quality or c.quality, n + c.count
			if items.spoilable(c.name, c.quality) then
				spoils = true
			end
		end
		stacks = stacks + #line
	end
	if not mixed and not spoils then
		return { core.fast_run(lane, name, quality, n, stacks) }
	end
	local runs = {}
	for i = core.STUBS, 1, -1 do
		for _, e in ipairs(d.lines[i][lane].get_detailed_contents()) do -- front first: ascending position [probe]
			local q = e.stack.quality.name
			local p = items.spoilable(e.stack.name, q) and core.spoil_p(e.stack.spoil_percent) or nil
			core.add_stack(runs, lane, e.stack.name, q, e.stack.count, p)
		end
	end
	return runs
end

--- Whether a lane has reached the outer two stubs. The front item moves 4 tiles between 32-tick polls at turbo, so it may
--- stand on stub 4 with stub 5 still empty; §7.2 step 1's outer stub alone throttles every tier above fast (review C1).
local function arrived(d, lane)
	return d.lines[core.STUBS][lane].get_item_count() > 0 or d.lines[core.STUBS - 1][lane].get_item_count() > 0
end

--- §7.2: each lane that has reached the outer stubs, within the window and the run cap, in one send; the stubs are
--- cleared only after the send took the runs (T1: a refused send raises first, and nothing is lost). The window
--- (step 2) is checked against the item count alone, before the read (step 3): a backed-up lane, a belt's common
--- steady state, costs nothing past the stub counts (§13 rule 5; Task 4 review Important 4). `core.may_capture` with
--- runs = unacked = 0 is the window alone, since 0 + 0 never trips the 64-run clause; the run cap (step 4) is checked
--- again, in full, once the runs are known.
local function capture(ep)
	local d, dir = ep.data, ep.params.dir
	local left, right = arrived(d, 1), arrived(d, 2)
	if not (left or right) or not ep:can_send(dir) then
		return -- an idle visit: two or four item counts, no table (§13 rule 5)
	end
	local lim = ep.partner.status and ep.partner.status.lim
	local all, taken, sent = nil, nil, 0
	for lane = 1, 2 do
		if (lane == 1 and left) or (lane == 2 and right) then
			local n = count_lane(d, lane)
			local l = type(lim) == "table" and lim[lane] or nil
			if core.may_capture(d.stats.captured[lane], n, l, 0, 0) then
				local runs = read_lane(d, lane)
				if core.may_capture(d.stats.captured[lane], n, l, sent + #runs, ep:runs(dir)) then
					all, taken = all or {}, taken or {}
					for _, r in ipairs(runs) do
						all[#all + 1] = r
					end
					taken[#taken + 1] = { lane, n }
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
	end
end

--- §7.5: each lane's FIFO goes down front first, in stacks of min(s, remaining), into the slots behind the back-most
--- item on the stubs, until the FIFO empties or an insert fails.
local function place(ep)
	local d = ep.data
	for lane = 1, 2 do
		local q = d.buf[lane]
		if q[1] then
			local last = -1
			for k = core.STUBS, 1, -1 do
				local line = d.lines[k][lane]
				if #line > 0 then
					for _, e in ipairs(line.get_detailed_contents()) do
						last = math.max(last, (k - 1) + e.position)
					end
					break
				end
			end
			local i = core.first_slot(last)
			while i and i <= #core.SLOTS and q[1] do
				local slot = core.SLOTS[i]
				local name, quality, c, p = core.next_stack(q)
				INSERT.name, INSERT.quality, INSERT.count = name, quality, c
				-- D38: insert_at takes an ItemStackDefinition, which carries spoil_percent ([api]); cleared to nil
				-- when this stack doesn't spoil, so a previous stack's value never leaks onto this one.
				INSERT.spoil_percent = p and p / 100 or nil
				if not d.lines[slot[1]][lane].insert_at(slot[2], INSERT, c) then
					break
				end
				core.consume(q, c)
				d.stats.placed = d.stats.placed + c
				i = i + 1
			end
		end
	end
	announce(ep, false)
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
	--- F9: idempotent. Adopts the stubs at their positions, creates the missing ones, caches their lines.
	build = function(ep)
		local surface = game.get_surface(ep.frame.surface_index)
		if not surface then
			return "blocked"
		end
		local d = ep.data
		d.stats = d.stats or { captured = { 0, 0 }, got = { 0, 0 }, placed = 0, spilled = 0, stubbed = 0, refunded = 0 }
		d.buf = d.buf or { {}, {} }
		d.stubs, d.lines = d.stubs or {}, {}
		local direction = geometry.dir_to_world(ep.frame, outbound(ep) and 0 or 8)
		for i = 1, core.STUBS do
			local x, y = geometry.to_world(ep.frame, ep.col + 0.5, -0.5 - (i - 1))
			local e = d.stubs[i]
			if not (e and e.valid) then
				e = surface.find_entity(NAME, { x, y }) or surface.create_entity({ name = NAME, position = { x, y },
					direction = direction, force = "player", create_build_effect_smoke = false })
				if not e then
					return "blocked"
				end
				e.destructible, e.operable = false, false
				d.stubs[i] = e
			end
			d.lines[i] = { e.get_transport_line(LANES[1]), e.get_transport_line(LANES[2]) }
		end
		detect.adopt(ep)
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
		if outbound(ep) then
			capture(ep)
		else
			place(ep)
		end
	end,
	--- §7.5: the whole ordered list goes into the FIFOs (T2); the window bounds them.
	credit = function(ep, _, list)
		return core.take(ep.data.buf, list, ep.data.stats.got)
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
