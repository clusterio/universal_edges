local t = require("modules/v2_test/testlib")
local loop = require("modules/v2_test/loopback")
local layouts = require("modules/v2_test/layouts")
local ue = require("modules/universal_edges")
local connectors = require("modules/universal_edges/edges/connectors")
local core = require("modules/universal_edges/transports/belt_core")

local LANES = { defines.transport_line.left_line, defines.transport_line.right_line }
local feeds, rows = {}, {}
local captured_payloads = {} -- D38: the last payload connectors.methods.send saw per edge key, for key-shape checks

ue.runtime.scheduler.periodic({ name = "sp3-test.feed", interval = 1, fn = function()
	layouts.feed(feeds)
end })

-- D38 (owner, 2026-10-03): a hand-driven feed for stacks with an explicit spoil_percent, which layouts.feed can't
-- carry. yumako (Space Age, prototypes.item) is the stand-in spoilable item: a capsule, stack_size 50, spoil_ticks a
-- full hour (216000 ticks), so the few hundred ticks a test takes adds well under 0.01 of real decay on top of it.
local spoil_feeds = {}

ue.runtime.scheduler.periodic({ name = "sp3-test.spoil-feed", interval = 1, fn = function()
	for _, f in pairs(spoil_feeds) do
		local line = f.line
		if line.valid and line.can_insert_at_back() then
			local item = f.items[f.fed + 1]
			if item then
				local stack = { name = item.name, count = f.s }
				if item.p then
					stack.spoil_percent = item.p
				end
				if line.insert_at_back(stack, f.s) then
					f.fed = f.fed + 1
				end
			end
		end
	end
end })

--- A belt row fed by hand (stacks with an explicit spoil_percent on lane 1), registered in rows[id] so arrived() works
--- on it exactly as a row() case does. items = { { name, p? }, ... }, p nil for a non-spoilable item.
local function spoil_row(id, x0, tier, n, dead, items, s)
	rows[id] = layouts.belt_row(loop, id, x0, tier, n, dead)
	spoil_feeds[id] = { line = rows[id].feed.get_transport_line(LANES[1]), items = items, s = s or 1, fed = 0 }
	return rows[id]
end

--- n copies of the same { name, p } item (one table, shared: spoil_row's feed only ever reads it).
local function const_items(name, p, n)
	local item, items = { name = name, p = p }, {}
	for k = 1, n do
		items[k] = item
	end
	return items
end

local function ep(edge)
	local side = storage.universal_edges.edges[edge]
	return side and connectors.get(side, "c1")
end

--- Belt-flip (2026-10-04): outgoing messages of msg_type on the universal_edges channel. The bridge's outbox is
-- cleared on every tick's flush (bridge.lua), so this only sees what a step sent earlier in the SAME tick, before
-- the flush that ends it — fine for a message a step's own call triggers synchronously (as detect_game_test.lua's
-- proposals() relies on too), not for one a scheduled poll queued on some earlier, unpredictable tick (removal_asked
-- below is how this file catches that instead, the same way its own "a capture the ledger refuses" case above
-- catches connectors.methods.send's calls directly rather than reading the outbox after the fact).
local function out(msg_type)
	local found = {}
	for _, msg in ipairs(storage.universal_edges.bridge.out.universal_edges or {}) do
		if msg.type == msg_type then
			found[#found + 1] = msg.payload
		end
	end
	return found
end

--- Belt-flip: every ep:request_removal(reason) call, by the endpoint's key, as detect_game_test.lua's I1 case already
-- intercepts the same method to prove a removal was asked exactly once.
local removal_asked = {}
local request_removal = connectors.methods.request_removal
connectors.methods.request_removal = function(e, reason)
	removal_asked[e.key] = removal_asked[e.key] or {}
	table.insert(removal_asked[e.key], reason)
	return request_removal(e, reason)
end

--- Inside a step: layouts.belt_row, fed with the item functions left and right in stacks of s.
local function row(id, x0, tier, n, dead, left, right, s)
	rows[id] = layouts.belt_row(loop, id, x0, tier, n, dead)
	feeds[id] = layouts.feeder(rows[id], left, right, s)
	return rows[id]
end

local function always(name)
	return function() return name end
end

--- The destination's lane, front first: the far end of its belt to the border, then its stubs from the inner end.
local function arrived(id, lane)
	local names, r, d = {}, rows[id], ep(id .. "-y").data
	for j = #r.belts, 1, -1 do
		for _, e in ipairs(r.belts[j].get_transport_line(LANES[lane]).get_detailed_contents()) do
			names[#names + 1] = e.stack.name .. "x" .. e.stack.count
		end
	end
	for k = 1, core.STUBS do
		for _, e in ipairs(d.lines[k][lane].get_detailed_contents()) do
			names[#names + 1] = e.stack.name .. "x" .. e.stack.count
		end
	end
	return names
end

--- The source's lane item count: its six feed tiles plus its five stubs (Important 2).
local function source_count(id, lane)
	local n, r = 0, rows[id]
	for _, e in ipairs(r.feeds) do
		n = n + e.get_transport_line(LANES[lane]).get_item_count()
	end
	for _, e in ipairs(ep(id .. "-x").data.stubs) do
		n = n + e.get_transport_line(LANES[lane]).get_item_count()
	end
	return n
end

--- A destination lane's FIFO, front first, each run's count expanded into that many "namex1" entries: a run only
--- merges identical consecutive keys (core.take), so with a feed that never repeats an item back to back, every run
--- holds single items and this lines up one for one with arrived()'s "namexcount" strings (Important 3).
local function queued(id, lane)
	local names = {}
	for _, run in ipairs(ep(id .. "-y").data.buf[lane]) do
		for _ = 1, run[2] do
			names[#names + 1] = run[3] .. "x1"
		end
	end
	return names
end

local TIERS = {
	{ "transport-belt", 15, 1 }, { "fast-transport-belt", 30, 1 }, { "express-transport-belt", 45, 1 },
	{ "turbo-transport-belt", 60, 1 }, { "turbo-transport-belt", 240, 4 },
}

t.case("belts: every tier at full rate, plain and stacked ×4 (≥ 98 %); lanes never mix; stacks kept", function(ctx)
	local placed = {}
	ctx.at(2000, function()
		local force = assert(game.forces.player) -- a call result, so luacheck allows the write
		force.belt_stack_size_bonus = 3 -- stacks of 4 on every belt of the save
		for i, tier in ipairs(TIERS) do
			row("sp3-b" .. i, 5400 + 20 * i, tier[1], 8, false, always("iron-plate"), always("copper-plate"), tier[3])
		end
	end)
	ctx.at(2400, function()
		for i in ipairs(TIERS) do
			placed[i] = ep("sp3-b" .. i .. "-y").data.stats.placed
		end
	end)
	-- 2400 to 3040 is a multiple of the 32-tick poll, so it holds exactly 20 polls whichever phase the poll task
	-- assigns these endpoints (Important 1): a fixed count of ticks since the previous snapshot would instead hold
	-- 18 or 19 polls depending on that phase, swinging the rate below or above the 98 % bar on its own.
	ctx.at(3040, function()
		for i, tier in ipairs(TIERS) do
			local rate = (ep("sp3-b" .. i .. "-y").data.stats.placed - placed[i]) / (640 / 60)
			ctx.expect(rate >= 0.98 * tier[2], tier[1] .. " ×" .. tier[3] .. ": " .. rate .. " items/s of " .. tier[2])
		end
		for lane, want in ipairs({ "iron-platex4", "copper-platex4" }) do
			for _, got in ipairs(arrived("sp3-b5", lane)) do
				if got ~= want then
					ctx.expect(false, "lane " .. lane .. " holds " .. got)
					break
				end
			end
		end
		local d = ep("sp3-b1-x").data
		local stubs = {}
		for i, e in ipairs(d.stubs) do
			stubs[i] = e.unit_number
		end
		connectors.types.belt.build(ep("sp3-b1-x"))
		for i, e in ipairs(d.stubs) do
			ctx.expect(e.unit_number == stubs[i], "a second build adopts stub " .. i .. " (F9)")
		end
	end)
end)

t.case("belts: D38 - a spoilable item crosses with its freshness, never fresher than it left", function(ctx)
	ctx.at(2060, function()
		spoil_row("sp3-spoil", 5640, "turbo-transport-belt", 8, true,
			{ { name = "yumako", p = 0.371 }, { name = "yumako", p = 0.371 }, { name = "yumako", p = 0.371 } })
	end)
	ctx.at(2460, function()
		spoil_feeds["sp3-spoil"] = nil
		local got = arrived("sp3-spoil", 1)
		ctx.expect(#got >= 1, "at least one yumako arrived; got " .. #got)
		for _, name in ipairs(got) do
			ctx.expect(name == "yumakox1", "arrived item is yumako: " .. name)
		end
		local r, checked = rows["sp3-spoil"], 0
		local function check(e)
			checked = checked + 1
			ctx.expect(e.stack.spoil_percent >= 0.371, "never fresher than it left: " .. e.stack.spoil_percent)
			ctx.expect(e.stack.spoil_percent <= 0.39, "within +0.01 of it (plus real decay in transit): "
				.. e.stack.spoil_percent)
		end
		for j = #r.belts, 1, -1 do
			for _, e in ipairs(r.belts[j].get_transport_line(LANES[1]).get_detailed_contents()) do
				check(e)
			end
		end
		for k = 1, core.STUBS do
			for _, e in ipairs(ep("sp3-spoil-y").data.lines[k][1].get_detailed_contents()) do
				check(e)
			end
		end
		ctx.expect(checked >= 1, "checked at least one arrived stack's freshness")
	end)
end)

local ALT, N_ALT = { { name = "yumako", p = 0.5 }, { name = "iron-plate" } }, 40

t.case("belts: D38 - a lane alternating a spoilable and a plain item keeps exact order (D31)", function(ctx)
	ctx.at(2070, function()
		local items = {}
		for k = 1, N_ALT do
			items[k] = ALT[(k - 1) % 2 + 1]
		end
		spoil_row("sp3-spoilorder", 5660, "turbo-transport-belt", 8, true, items)
	end)
	ctx.at(3150, function() -- generous margin, as sushi2's comparable dead-end backlog (Important 3)
		spoil_feeds["sp3-spoilorder"] = nil
		local got = arrived("sp3-spoilorder", 1)
		ctx.expect(#got >= N_ALT - 2, "most of the " .. N_ALT .. " arrived; got " .. #got)
		for i, name in ipairs(got) do
			local want = ALT[(i - 1) % 2 + 1].name .. "x1"
			if name ~= want then
				ctx.expect(false, "item " .. i .. " is " .. name .. ", not " .. want)
				break
			end
		end
	end)
end)

t.case("belts: D38 - a non-spoilable lane's keys are still four fields", function(ctx)
	ctx.at(2080, function()
		row("sp3-plain4", 5680, "turbo-transport-belt", 8, false, always("iron-plate"), nil)
	end)
	ctx.at(2300, function()
		feeds["sp3-plain4"] = nil
		local payload = captured_payloads["sp3-plain4-x/c1"]
		ctx.expect(payload ~= nil, "at least one offer was sent")
		if payload then
			for _, run in ipairs(payload) do
				ctx.expect(string.match(run[1], "^%d|[^|]+|[^|]+|%d+$") ~= nil, "a four-field key: " .. run[1])
			end
		end
	end)
end)

local SUSHI = { "iron-plate", "copper-plate", "copper-plate", "coal", "iron-gear-wheel" }

t.case("belts: a sushi lane arrives in exact order behind items already on the stubs (D31)", function(ctx)
	local function sushi(k)
		return k <= 300 and SUSHI[(k - 1) % #SUSHI + 1] or nil
	end
	ctx.at(2010, function()
		row("sp3-sushi", 5520, "turbo-transport-belt", 100, true, sushi, always("stone"))
	end)
	ctx.at(3200, function()
		local got = arrived("sp3-sushi", 1)
		ctx.expect(#got >= 290, "most of the 300 arrived; got " .. #got)
		for i, name in ipairs(got) do
			if name ~= sushi(i) .. "x1" then
				ctx.expect(false, "item " .. i .. " is " .. name .. ", not " .. sushi(i))
				break
			end
		end
		ctx.expect(loop.forwarded() > 0, "it went over the loopback")
	end)
	ctx.expect_ipc("universal_edges:out", '"k":"o.offer"')
end)

-- Important 3: the first sushi case's 100-tile dead end never fills in 300 items, so every placement starts on an
-- empty stub (core.first_slot(-1)) and the "behind the back-most item" branch (belt.lua's place, first_slot(last)
-- with last ~= -1) never runs under an order check. A short dead end backs the destination's own belt up behind the
-- stubs instead, so later placements must find room behind items a previous poll already put down and left in place.
local SUSHI2 = { "iron-plate", "copper-plate", "coal", "iron-gear-wheel", "steel-plate" }
local N2 = 60

t.case("belts: a sushi lane places behind items already on the stubs, in order, once it backs up (D31)", function(ctx)
	local function sushi2(k)
		return k <= N2 and SUSHI2[(k - 1) % #SUSHI2 + 1] or nil
	end
	ctx.at(2050, function()
		row("sp3-sushi2", 5620, "turbo-transport-belt", 6, true, sushi2, nil)
	end)
	-- 2050 + 8 * 32 = 2306 is a multiple of the 32-tick poll since creation (Important 1's phase fix applies here
	-- too), reached well before the 3100 saturation check. A scan that understates the true back-most position (the
	-- outer-vs-inner mutation Finding 3 named) still only ever lands inside already-occupied territory — insert_at
	-- rejects it and the poll places nothing that round — so it converges to the same 44 eventually, but slower: a
	-- real, measured 44 vs 35 at this tick (recorded below), not a theoretical gap.
	ctx.at(2306, function()
		ctx.expect(#arrived("sp3-sushi2", 1) >= 40, "the chain keeps filling even while partly backed up; got "
			.. #arrived("sp3-sushi2", 1))
	end)
	ctx.at(3100, function()
		feeds["sp3-sushi2"] = nil
		local combined = arrived("sp3-sushi2", 1)
		-- The six destination tiles plus the five stubs hold 44 slots a lane; a broken "always the front slot" placement
		-- would freeze after its first stub-1 collision instead of filling them (review's own mutation test: 1 of 44).
		ctx.expect(#combined >= 35, "placement filled the six tiles and five stubs behind each other; got " .. #combined)
		local q = queued("sp3-sushi2", 1)
		ctx.expect(#q > 0, "the short dead end left items queued, not yet placed; got " .. #q)
		for _, x in ipairs(q) do
			combined[#combined + 1] = x
		end
		ctx.expect(#combined == N2, "arrived plus queued accounts for every fed item: " .. #combined .. " of " .. N2)
		for i = 1, #combined do
			if combined[i] ~= sushi2(i) .. "x1" then
				ctx.expect(false, "item " .. i .. " is " .. combined[i] .. ", not " .. sushi2(i))
				break
			end
		end
	end)
end)

t.case("belts: a blocked destination backs the source up within the window", function(ctx)
	ctx.at(2020, function()
		row("sp3-block", 5540, "turbo-transport-belt", 6, true, always("iron-plate"), always("copper-plate"))
	end)
	ctx.at(3300, function() -- about 490 items a lane fill it at 30 a second
		local src, dst = ep("sp3-block-x").data, ep("sp3-block-y").data
		for lane = 1, 2 do
			local held = core.buffered(dst.buf[lane])
			ctx.expect(held <= core.W, "lane " .. lane .. ": the destination holds " .. held)
			ctx.expect(src.stats.captured[lane] <= dst.stats.got[lane] + core.W - held,
				"lane " .. lane .. ": captured within the window")
			ctx.expect(not feeds["sp3-block"].lines[lane].can_insert_at_back(), "lane " .. lane .. ": the source backed up")
		end
	end)
end)

t.case("belts: removal mid-flow: shipped = received + spilled + refunded", function(ctx)
	local src, dst
	ctx.at(2030, function()
		row("sp3-remove", 5560, "turbo-transport-belt", 8, false, always("iron-plate"), always("copper-plate"))
	end)
	ctx.at(2300, function()
		src, dst = ep("sp3-remove-x").data.stats, ep("sp3-remove-y").data.stats
		feeds["sp3-remove"] = nil
		loop.connectors("sp3-remove", 2, {})
	end)
	ctx.at(2400, function()
		ctx.expect(ep("sp3-remove-x") == nil and ep("sp3-remove-y") == nil, "both ends closed over the loopback")
		local shipped = src.captured[1] + src.captured[2]
		local received = dst.got[1] + dst.got[2]
		ctx.expect(shipped > 0 and shipped == received + src.refunded,
			"shipped " .. shipped .. " = received " .. received .. " + refunded " .. src.refunded)
		ctx.expect(received == dst.placed + dst.spilled, "received = placed + spilled from the buffer")
		local ground = 0
		for _, y in ipairs({ 3000.5, 1999.5 }) do
			for _, e in ipairs(game.surfaces.nauvis.find_entities_filtered({ type = "item-entity",
				area = { { 5546, y - 20 }, { 5582, y + 20 } } })) do
				ground = ground + e.stack.count
			end
		end
		ctx.expect(ground == src.refunded + src.stubbed + dst.spilled + dst.stubbed, "every spill is on the ground: " .. ground)
	end)
end)

-- D38 review Important 1: teardown spill was only checked by doc-reading (runtime-api.json), never by spawning a
-- spoilable item and inspecting the ground. Same shape as "removal mid-flow" above (continuous feed, then an edge
-- removal mid-flow); a one-off debug dump (added, checked, then removed) showed it closes all three spill paths:
-- dst.spilled, dst.stubbed and src.stubbed were each > 0. No refund ran either here or in "removal mid-flow" above
-- (refunded = 0 in both, confirmed the same way): this harness's loopback (harness/lua/loopback.lua) delivers lane
-- messages in-process with no delay, so a captured item is always credited before teardown could ever race it. A
-- real refund needs the E2E layer's delay seam (UE_TEST_LANE_DELAY_MS), out of a game test's reach; report says so.
local SPOIL_P = 0.62

t.case("belts: D38 - teardown spills keep a spoilable item's freshness", function(ctx)
	local src, dst
	ctx.at(2035, function()
		spoil_row("sp3-spoilremove", 5700, "turbo-transport-belt", 8, false, const_items("yumako", SPOIL_P, 300))
	end)
	--- The destination's stubs catching an item mid-transit is a timing window, not a fixed tick: the poll walk's own
	-- cadence decides exactly when the last item lands there before teardown (D39 perf item 1 made a type's walk
	-- rest between passes instead of being kept awake by every lane message, which moved this window by single-digit
	-- ticks and left a hardcoded tick 2300 teardown catching it empty). 245 ticks of feed (2035 to 2280) builds the
	-- same backlog as before on both ends; from there, wait until an item is actually sitting on a destination stub,
	-- then tear down at once — the search window only absorbs the poll walk's own cadence jitter, not the backlog
	-- build-up. The cap still tears down and lets the real checks below fail (loudly, not by hanging the run) if
	-- nothing ever arrives.
	local function wait_for_stub(tick)
		local dep = ep("sp3-spoilremove-y")
		local n = 0
		if dep and dep.data.lines then
			for lane = 1, 2 do
				for k = 1, core.STUBS do
					n = n + dep.data.lines[k][lane].get_item_count()
				end
			end
		end
		if n > 0 or tick >= 2280 + 150 then
			local sep = ep("sp3-spoilremove-x")
			spoil_feeds["sp3-spoilremove"] = nil
			if not (sep and dep) then
				ctx.expect(false, "the connector never came up: x=" .. tostring(sep) .. " y=" .. tostring(dep))
				return
			end
			src, dst = sep.data.stats, dep.data.stats
			loop.connectors("sp3-spoilremove", 2, {})
			ctx.at(tick + 100, function()
				ctx.expect(ep("sp3-spoilremove-x") == nil and ep("sp3-spoilremove-y") == nil,
					"both ends closed over the loopback")
				ctx.expect(dst.spilled > 0, "the destination's FIFO had items: " .. dst.spilled)
				ctx.expect(dst.stubbed > 0, "the destination's stubs had items: " .. dst.stubbed)
				ctx.expect(src.stubbed > 0, "the source's stubs had items: " .. src.stubbed)
				local checked = 0
				for _, y in ipairs({ 3000.5, 1999.5 }) do
					for _, e in ipairs(game.surfaces.nauvis.find_entities_filtered({ type = "item-entity",
						area = { { 5686, y - 20 }, { 5722, y + 20 } } })) do
						if e.stack.name == "yumako" then
							checked = checked + 1
							ctx.expect(e.stack.spoil_percent >= SPOIL_P, "never fresher than it left: "
								.. e.stack.spoil_percent)
							ctx.expect(e.stack.spoil_percent <= SPOIL_P + 0.02,
								"within +0.01 of it (plus real decay in transit): " .. e.stack.spoil_percent)
						end
					end
				end
				ctx.expect(checked > 0, "at least one spilled yumako was on the ground; checked " .. checked)
			end)
		else
			ctx.at(tick + 1, function() wait_for_stub(tick + 1) end)
		end
	end
	ctx.at(2280, function() wait_for_stub(2280) end)
end)

-- Review Focus 5: a send that raises (as a 65th run or MAX_TOTAL would) must find the stubs uncleared. D38 also
-- records each payload here (the last one per edge key), for the four-field-key check.
local refuse = {}
local send = connectors.methods.send
connectors.methods.send = function(e, dir, payload)
	captured_payloads[e.key] = payload
	if refuse[e.key] then
		error("refused on purpose")
	end
	return send(e, dir, payload)
end

local before = {}

t.case("belts: a capture the ledger refuses clears nothing", function(ctx)
	ctx.at(2040, function()
		row("sp3-refuse", 5600, "turbo-transport-belt", 8, false, always("iron-plate"), nil)
	end)
	ctx.at(2200, function()
		refuse["sp3-refuse-x/c1"] = true
		feeds["sp3-refuse"] = nil -- stop feeding, so nothing refills what the refused send would have cleared
		before.n = source_count("sp3-refuse", 1)
		before.captured = ep("sp3-refuse-x").data.stats.captured[1]
	end)
	ctx.at(2300, function()
		local e = ep("sp3-refuse-x")
		ctx.expect(e.state == "failed", "the refused send failed the endpoint (G6)")
		ctx.expect(e.data.lines[core.STUBS][1].get_item_count() > 0, "and its stubs still hold their items")
		ctx.expect(source_count("sp3-refuse", 1) == before.n,
			"lane 1's item count is unchanged: was " .. before.n .. ", now " .. source_count("sp3-refuse", 1))
		ctx.expect(e.data.stats.captured[1] == before.captured, "captured is unchanged: " .. before.captured)
	end)
end)

-- The two belt-flip cases below wait for the poll instead of sampling at a fixed tick, so they don't depend on its
-- phase (which shifts whenever any case adds belt endpoints). The belt poll (belt.lua schedule) walks per_tick = 4
-- endpoints a tick, a walk starting every interval = 32 ticks, from a persistent cursor; lanes.visit polls an
-- endpoint only if tick - last_poll >= 32. An endpoint that changed just after its poll is visited in the next walk,
-- but at a slightly earlier offset in the walk it can be too soon (< 32 since last_poll) and so skip to the walk after:
-- worst case 2 * 32 ticks, plus the last walk's length, ceil(N / 4) ticks, N = the belt endpoints in the save when the
-- flip happens. Teardown and the new proposal run synchronously inside loop.connectors, so they add nothing.
-- Bound = 2 * 32 + ceil(N / 4) ticks after the rotate.
local function poll_bound()
	local n = 0
	for _ in pairs(storage.universal_edges.eps.belt or {}) do
		n = n + 1
	end
	return 2 * 32 + math.ceil(n / 4)
end

--- From offset `from` (the tick after the rotate) until `key` has a removal request, at most poll_bound() ticks;
--- then done(), in that same tick.
local function wait_reversed(ctx, key, from, done)
	local limit = from + poll_bound()
	layouts.wait(t, ctx, from, limit, function()
		return removal_asked[key] ~= nil
	end, function(k)
		ctx.expect(k ~= nil, "the poll noticed the flip within " .. (limit - from) .. " ticks of the rotate")
		done(k)
	end)
end

-- Belt-flip (owner, 2026-10-04): "when a belt or underground is flipped / rotated the expected behaviour is the belt
-- link is flipped." Chosen mechanism (owner): remove, then re-add — the old link's in-flight items settle (refunded
-- on the old source side, as any removal's refund already does — D38 review Important 1's own finding: this
-- harness's zero-delay loopback always credits a capture before a teardown could race it, so refunded is 0 here too;
-- a real refund needs the E2E layer's UE_TEST_LANE_DELAY_MS seam, out of a game test's reach, same gap the "removal
-- mid-flow" case above already has), and a link is proposed in the new direction once the old one is fully gone.
-- Ground x 5900-5912 (clear of every x0 above, the highest of which is 5700 + 12 of paving); ticks 2045-2460, this
-- file's own range (well clear of 3900+, where runtime_game_test.lua and this file's own marks sibling's backfill
-- case leave storage.universal_edges.rt.boot_id nil for the rest of the run).
t.case("belts: rotating the border belt 180 reverses its link: one removal_requested (reversed), a new proposal " ..
	"with the opposite dir once teardown completes, and conservation holds", function(ctx)
	local src, dst
	ctx.at(2045, function()
		row("sp3-flip", 5900, "turbo-transport-belt", 8, false, always("iron-plate"), always("copper-plate"))
	end)
	ctx.at(2315, function()
		src, dst = ep("sp3-flip-x").data.stats, ep("sp3-flip-y").data.stats
		feeds["sp3-flip"] = nil
		local border = ep("sp3-flip-x").data.border
		-- A regular belt's rotate() steps 90 degrees at a time (probed in game: 0, 4, 8, 12, back to 0 over four
		-- calls) — only a full 180 (two calls) is still "across" the border row afterward and actually reverses a
		-- straight border-row belt's flow; one call alone turns it off that axis instead, a rarer in-between state
		-- this fix doesn't need to guard (detect.check doesn't invalidate the entity for it either).
		border.rotate()
		border.rotate()
		wait_reversed(ctx, "sp3-flip-x/c1", 2316, function()
		-- The poll that noticed the mismatch ran on some earlier tick of its own (interval 32); removal_asked caught
		-- ep:request_removal's call directly, so this doesn't depend on catching the resulting ue.connector.remove
		-- message before a later tick's flush clears the outbox (bridge.lua's own per-tick s.bridge.out[plugin] = {}).
		local reasons = removal_asked["sp3-flip-x/c1"]
		ctx.expect(reasons ~= nil and #reasons == 1 and reasons[1] == "reversed",
			"removal requested once, reason reversed: " .. helpers.table_to_json(reasons or {}))
		ctx.expect(ep("sp3-flip-x").data.reversed ~= nil, "remembered until teardown")
		-- The controller's accepted removal, reflected back to both sides, as this file's own "removal mid-flow"
		-- case above simulates it over the loopback. Teardown (and so detect.repropose) runs synchronously inside
		-- this same call, so the new proposal is checked right after it, in the same tick, before this tick's own
		-- flush clears the outbox.
		loop.connectors("sp3-flip", 2, {})
		local mine
		for _, p in ipairs(out("ue.connector.propose")) do
			if p.edge == "sp3-flip-x" and p.params and p.params.dir == "ba" then
				mine = p
			end
		end
		ctx.expect(mine ~= nil, "a new proposal in the opposite direction (ba) once the old connector tore down")
		end)
	end)
	ctx.at(2460, function()
		ctx.expect(ep("sp3-flip-x") == nil and ep("sp3-flip-y") == nil, "both ends closed over the loopback")
		local shipped = src.captured[1] + src.captured[2]
		local received = dst.got[1] + dst.got[2]
		ctx.expect(shipped > 0 and shipped == received + src.refunded,
			"conservation: shipped " .. shipped .. " = received " .. received .. " + refunded " .. src.refunded)
	end)
end)

-- Ground x 5940-5956; ticks 2500-2620, same range, clear of the case above (5900-5912, 2045-2460).
t.case("belts: flipping a border underground belt (its belt_to_ground_type) also reverses its link", function(ctx)
	local fa, fb, ug
	ctx.at(2500, function()
		fa, fb = layouts.edge(loop, "sp3-flipug", 5940, 8, { { cid = "c1", type = "belt", pos = 2, width = 1,
			params = { dir = "ab" } } }, 16)
		for j = 1, 5 do
			layouts.put(fa, "turbo-transport-belt", 2.5, 0.5 + j, 0)
		end
		ug = layouts.put(fa, "underground-belt", 2.5, 0.5, 0, { type = "input" })
		local cb = ue.geometry.col("b", 8, 2, 1)
		for j = 0, 3 do
			layouts.put(fb, "turbo-transport-belt", cb + 0.5, 0.5 + j, 8)
		end
		layouts.put(fb, "turbo-loader", cb + 0.5, 5, 8, { type = "input" })
		layouts.put(fb, "infinity-chest", cb + 0.5, 6.5, 0).remove_unfiltered_items = true
	end)
	ctx.at(2540, function()
		ctx.expect(ep("sp3-flipug-x").data.border == ug, "the underground was adopted as the border entity")
		-- A lone underground's rotate() flips both direction and belt_to_ground_type together, in one call (probed
		-- in game: input/north became output/south) — the only way a single piece "flips" at all; a horizontal
		-- flip() on a north/south-facing one is a no-op for both fields (also probed), so rotate() is what actually
		-- exercises belt_to_ground_type changing, as the owner's design names it.
		ug.rotate()
		wait_reversed(ctx, "sp3-flipug-x/c1", 2541, function(k)
		local reasons = removal_asked["sp3-flipug-x/c1"]
		ctx.expect(reasons ~= nil and #reasons == 1 and reasons[1] == "reversed",
			"removal requested once, reason reversed: " .. helpers.table_to_json(reasons or {}))
		loop.connectors("sp3-flipug", 2, {})
		layouts.wait(t, ctx, (k or 0) + 1, (k or 0) + poll_bound(), function()
			return ep("sp3-flipug-x") == nil and ep("sp3-flipug-y") == nil
		end, function(j)
			ctx.expect(j ~= nil, "both ends closed over the loopback")
		end)
		local mine
		for _, p in ipairs(out("ue.connector.propose")) do
			if p.edge == "sp3-flipug-x" and p.params and p.params.dir == "ba" then
				mine = p
			end
		end
		ctx.expect(mine ~= nil, "a new proposal in the opposite direction (ba), from the same, now-flipped entity")
		end)
	end)
end)
