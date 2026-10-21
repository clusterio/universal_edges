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
-- empty stub (back_of = -1) and the "behind the back-most item" branch (belt.lua's place, back >= 0)
-- never runs under an order check. A short dead end backs the destination's own belt up behind the
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
	-- real, measured 44 vs 35 at this tick (recorded below), not a theoretical gap. The destination now holds each
	-- delivery HOLD = 128 ticks (belt spacing spec §7), so the same count arrives four polls later: 2050 + 12 * 32 = 2434.
	ctx.at(2434, function()
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
		row("sp3-block", 5540, "turbo-transport-belt", 6, true, always("iron-plate"), always("copper-plate"), 4)
	end)
	ctx.at(3300, function() -- W = 700 a lane in stacks of 4 fills it at 120 items a second
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
-- endpoints a tick, a walk starting every interval = 32 ticks, from a persistent cursor; lanes.visit polls an endpoint
-- only if tick - last_poll >= 3/4 of 32 (plan Task 3 ruling). An endpoint that changed just after its poll is visited
-- in the next walk, but at a slightly earlier offset in the walk it can be too soon (< 24 since last_poll) and so skip
-- to the walk after: worst case 2 * 32 ticks, plus the last walk's length, ceil(N / 4) ticks, N = the belt endpoints in
-- the save when the flip happens. Teardown and the new proposal run synchronously inside loop.connectors, so they add
-- nothing.
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

-- Belt spacing spec §9 (plan R8): stacks fed at known ticks, timed by the first tick each shows on each side's border
-- belt (by unique_id). timed[id] feeds a row's left lane one iron plate at a time, gaps[i] ticks apart; seen[key] keeps,
-- in order, the first tick each item appears on one transport line.
local GAPS_Y = { 10, 45, 12, 80, 10, 33, 150, 11, 60, 20 } -- ticks at yellow: 10 is 0.31 tiles, 150 is 4.7
local GAPS_T = { 3, 11, 3, 20, 4, 9, 37, 3, 15, 5 } -- ticks at turbo: 3 is 0.375 tiles, 37 is 4.6
local timed, seen = {}, {}

ue.runtime.scheduler.periodic({ name = "sp3-test.timed", interval = 1, fn = function()
	for _, f in pairs(timed) do
		if f.fed <= #f.gaps and game.tick >= f.next and f.line.valid
			and f.line.insert_at_back({ name = "iron-plate", count = 1 }, 1) then
			f.fed = f.fed + 1
			f.next = game.tick + (f.gaps[f.fed] or 0)
		end
	end
	for _, w in pairs(seen) do
		if w.line.valid then
			for _, e in ipairs(w.line.get_detailed_contents()) do
				if not w.ids[e.unique_id] then
					w.ids[e.unique_id] = true
					w.ticks[#w.ticks + 1] = game.tick
				end
			end
		end
	end
end })

--- Inside a step: a free-flowing row (layouts.belt_row, 8 tiles into a loader) whose left lane is fed at `gaps` from
--- 120 ticks on (the link built and its window announced by then), both border belts' left lanes timed.
local function timed_row(id, x0, tier, gaps, tier_b)
	local r = layouts.belt_row(loop, id, x0, tier, 8, false, tier_b)
	rows[id] = r
	timed[id] = { line = r.feed.get_transport_line(LANES[1]), gaps = gaps, fed = 0, next = game.tick + 120 }
	seen[id .. "/a"] = { line = r.feeds[1].get_transport_line(LANES[1]), ids = {}, ticks = {} }
	seen[id .. "/b"] = { line = r.belts[1].get_transport_line(LANES[1]), ids = {}, ticks = {} }
end

--- §9: every stack crossed, the feed kept its gaps, and after the first stack each gap at the destination's border is
--- the source's within 1 tick.
local function expect_spacing(ctx, id, gaps)
	local src, dst = seen[id .. "/a"].ticks, seen[id .. "/b"].ticks
	ctx.expect(#src == #gaps + 1 and #dst == #gaps + 1, id .. ": " .. #src .. " stacks at the source's border and "
		.. #dst .. " at the destination's, of " .. (#gaps + 1))
	for i = 2, math.min(#src, #dst) do
		local a, b = src[i] - src[i - 1], dst[i] - dst[i - 1]
		ctx.expect(a == gaps[i - 1], id .. ": the feed's gap " .. (i - 1) .. " is " .. a .. ", not " .. gaps[i - 1])
		ctx.expect(math.abs(b - a) <= 1, id .. ": gap " .. (i - 1) .. " is " .. b .. " ticks at the destination, "
			.. a .. " at the source")
	end
	timed[id], seen[id .. "/a"], seen[id .. "/b"] = nil, nil, nil
end

-- Ground x 6000-6036, ticks 2100-3150: yellow's last stack is fed by 2651 and crosses by about 3004.
t.case("belts: spacing - stacks fed at irregular gaps reach the destination's border with the same gaps, yellow and "
	.. "turbo (belt spacing spec §9 test 1)", function(ctx)
	ctx.at(2100, function()
		timed_row("sp3-gap-y", 6000, "transport-belt", GAPS_Y)
		timed_row("sp3-gap-t", 6020, "turbo-transport-belt", GAPS_T)
	end)
	ctx.at(3150, function()
		expect_spacing(ctx, "sp3-gap-y", GAPS_Y)
		expect_spacing(ctx, "sp3-gap-t", GAPS_T)
		for _, id in ipairs({ "sp3-gap-y", "sp3-gap-t" }) do
			local st = ep(id .. "-y").data.stats
			ctx.expect((st.late or 0) == 0 and (st.reanchored or 0) == 0, id .. ": late " .. tostring(st.late)
				.. " and reanchored " .. tostring(st.reanchored) .. " at the destination, both 0")
		end
	end)
end)

-- A late stack onto an empty UE belt: core.place_at gives dist 0, so belt.lua inserts at position 0 on stub 1, whose
-- downstream neighbour is the player's border belt. Proves insert_at takes it (else the lane would stall for good).
-- Ground x 6440-6460, ticks 3200-3400.
t.case("belts: a stack already due when the UE belt is empty is placed at the front, not stalled", function(ctx)
	local st, before_placed, before_late
	ctx.at(3200, function()
		local r = layouts.belt_row(loop, "sp3-due", 6440, "transport-belt", 8, false)
		rows["sp3-due"] = r
		seen["sp3-due/b"] = { line = r.belts[1].get_transport_line(LANES[1]), ids = {}, ticks = {} }
	end)
	ctx.at(3300, function()
		local d = ep("sp3-due-y").data
		st = d.stats
		before_placed, before_late = st.placed, st.late or 0
		d.due = d.due or {}
		d.due[1] = game.tick - 300
		table.insert(d.buf[1], { "1|iron-plate|normal|1", 1, "iron-plate", "normal", 1, nil, g = { 0 }, i = 1,
			at = game.tick - 400 })
		st.got[1] = st.got[1] + 1
		ctx.at(game.tick + poll_bound() + 5, function()
			ctx.expect(st.placed == before_placed + 1, "the late stack was placed: " .. st.placed .. " from " .. before_placed)
			ctx.expect(st.late == before_late + 1, "and counted late: " .. st.late .. " from " .. before_late)
			ctx.expect(#seen["sp3-due/b"].ticks == 1, "and it showed on the border belt: " .. #seen["sp3-due/b"].ticks)
			seen["sp3-due/b"] = nil
		end)
	end)
end)

local BELT_TIERS = { "transport-belt", "fast-transport-belt", "express-transport-belt", "turbo-transport-belt" }
local UNDERGROUNDS = { "underground-belt", "fast-underground-belt", "express-underground-belt", "turbo-underground-belt" }

--- edge's endpoint's five stubs, by name.
local function stub_names(edge)
	local names = {}
	for i, e in ipairs(ep(edge).data.stubs) do
		names[i] = e.valid and e.name or "invalid"
	end
	return table.concat(names, ",")
end

local function five(name)
	return table.concat({ name, name, name, name, name }, ",")
end

-- Ground x 6040-6056, ticks 2120-3150 (plan R9: the yellow gaps, since a turbo 3-tick gap is under yellow's 0.25 tiles).
t.case("belts: spacing - a turbo source and a yellow destination keep the same time gaps (belt spacing spec §9 test 2)",
	function(ctx)
	ctx.at(2120, function()
		timed_row("sp3-gap-mix", 6040, "turbo-transport-belt", GAPS_Y, "transport-belt")
	end)
	ctx.at(3150, function()
		ctx.expect(ep("sp3-gap-mix-x").data.tier == "ue-link-belt-turbo-transport-belt"
			and ep("sp3-gap-mix-y").data.tier == "ue-link-belt", "each side's stubs are its own border's tier")
		expect_spacing(ctx, "sp3-gap-mix", GAPS_Y)
	end)
end)

-- Ground x 6056-6216, ticks 2130-2400.
t.case("belts: tiers - each side's stubs are its border belt's tier at build, an underground's too (spec §9 test 4)",
	function(ctx)
	ctx.at(2130, function()
		for i, tier in ipairs(BELT_TIERS) do
			layouts.belt_row(loop, "sp3-tier-" .. i, 6060 + 20 * (i - 1), tier, 4, true)
		end
		for i, ug in ipairs(UNDERGROUNDS) do
			local fa = layouts.edge(loop, "sp3-tierug-" .. i, 6140 + 20 * (i - 1), 8, { { cid = "c1", type = "belt",
				pos = 2, width = 1, params = { dir = "ab" } } }, 8)
			layouts.put(fa, ug, 2.5, 0.5, 0, { type = "input" })
		end
	end)
	ctx.at(2400, function()
		for i, tier in ipairs(BELT_TIERS) do
			local want = core.ue_name(tier)
			for _, s in ipairs({ "-x", "-y" }) do
				local e = "sp3-tier-" .. i .. s
				ctx.expect(stub_names(e) == five(want), e .. ": " .. stub_names(e))
				ctx.expect(ep(e).data.tier == want and ep(e).data.speed == prototypes.entity[tier].belt_speed,
					e .. ": tier " .. tostring(ep(e).data.tier) .. ", speed " .. tostring(ep(e).data.speed))
			end
			local u = "sp3-tierug-" .. i .. "-x"
			ctx.expect(stub_names(u) == five(want), u .. " (" .. UNDERGROUNDS[i] .. "): " .. stub_names(u))
		end
	end)
end)

--- An upgrade or a downgrade as it lands (belt spacing spec §9 test 5): name built over e by fast-replace, no event.
local function replace(e, name)
	return assert(e.surface.create_entity({ name = name, position = e.position, direction = e.direction,
		force = "player", fast_replace = true }), name)
end

--- From offset `from` until edge's tier is `want`, at most poll_bound() ticks; then the tier and the stubs are checked.
local function wait_tier(ctx, edge, from, want, done)
	layouts.wait(t, ctx, from, from + poll_bound(), function()
		return ep(edge).data.tier == want
	end, function(k)
		ctx.expect(k ~= nil, edge .. " re-matched to " .. want .. " within a poll: " .. tostring(ep(edge).data.tier))
		ctx.expect(stub_names(edge) == five(want), edge .. ": " .. stub_names(edge))
		if done then
			done(k)
		end
	end)
end

-- Ground x 6276-6292, ticks 2140-~2420.
t.case("belts: tiers - a side with no border belt has the fastest UE belt, and a red belt built later re-matches it (spec §9 test 7)",
	function(ctx)
	local fa
	ctx.at(2140, function()
		fa = layouts.edge(loop, "sp3-late", 6280, 8, { { cid = "c1", type = "belt", pos = 2, width = 1,
			params = { dir = "ab" } } }, 8)
	end)
	ctx.at(2300, function()
		local turbo = five("ue-link-belt-turbo-transport-belt")
		ctx.expect(stub_names("sp3-late-x") == turbo, "no border yet, x: the fastest: " .. stub_names("sp3-late-x"))
		ctx.expect(stub_names("sp3-late-y") == turbo, "no border yet, y: the fastest: " .. stub_names("sp3-late-y"))
		layouts.put(fa, "fast-transport-belt", 2.5, 0.5, 0, { raise_built = true })
		layouts.wait(t, ctx, 2301, 2301 + poll_bound(), function()
			return ep("sp3-late-x").data.tier == "ue-link-belt-fast-transport-belt"
		end, function(k)
			ctx.expect(k ~= nil, "side x re-matched to the red belt within a poll")
			ctx.expect(stub_names("sp3-late-x") == five("ue-link-belt-fast-transport-belt"),
				"x: " .. stub_names("sp3-late-x"))
			ctx.expect(stub_names("sp3-late-y") == turbo, "y is still the fastest: " .. stub_names("sp3-late-y"))
			ctx.expect(removal_asked["sp3-late-x/c1"] == nil, "no removal asked")
		end)
	end)
end)

-- Ground x 6256-6272, ticks 2150-2800.
t.case("belts: tiers - legacy ue-link-belt stubs under a red border are re-matched at the first poll, items and freshness kept; "
	.. "an endpoint from before the deploy keeps working (spec §9 test 6, Review Focus 1 and 2)",
	function(ctx)
	local legacy = {}
	local want = "ue-link-belt-fast-transport-belt"
	local function lay(stub, lane, list)
		for _, it in ipairs(list) do
			local stack = { name = it[1], count = 1 }
			stack.spoil_percent = it[3]
			assert(stub.get_transport_line(LANES[lane]).insert_at(it[2], stack, 1), it[1] .. " at " .. it[2])
		end
	end
	ctx.at(2150, function()
		local fa, fb = layouts.edge(loop, "sp3-legacy", 6260, 8, { { cid = "c1", type = "belt", pos = 2, width = 1,
			params = { dir = "ab" } } }, 8)
		local cb = ue.geometry.col("b", 8, 2, 1)
		layouts.put(fa, "fast-transport-belt", 2.5, 0.5, 0)
		layouts.put(fb, "fast-transport-belt", cb + 0.5, 0.5, 8)
		local sa, sb = {}, {}
		for i = 1, 5 do
			sa[i] = layouts.put(fa, "ue-link-belt", 2.5, -0.5 - (i - 1), 0)
			sb[i] = layouts.put(fb, "ue-link-belt", cb + 0.5, -0.5 - (i - 1), 8)
			legacy[#legacy + 1] = sa[i]
			legacy[#legacy + 1] = sb[i]
		end
		lay(sa[2], 2, { { "iron-plate", 0.125 }, { "iron-plate", 0.375 }, { "iron-plate", 0.625 },
			{ "iron-plate", 0.875 } })
		lay(sb[1], 1, { { "iron-plate", 0.125 }, { "iron-plate", 0.375 }, { "iron-plate", 0.625 },
			{ "iron-plate", 0.875 } })
		lay(sb[2], 1, { { "iron-plate", 0.125 }, { "iron-plate", 0.375 }, { "yumako", 0.625, 0.37 },
			{ "yumako", 0.875, 0.37 } })
		layouts.wait(t, ctx, 2151, 2151 + 3 * poll_bound(), function()
			local x, y = ep("sp3-legacy-x"), ep("sp3-legacy-y")
			return x and y and x.data.tier == want and y.data.tier == want
		end, function(k)
			ctx.expect(k ~= nil, "both sides re-matched at the first polls")
			ctx.expect(stub_names("sp3-legacy-x") == five(want), "x: " .. stub_names("sp3-legacy-x"))
			ctx.expect(stub_names("sp3-legacy-y") == five(want), "y: " .. stub_names("sp3-legacy-y"))
			for _, e in ipairs(legacy) do
				ctx.expect(not e.valid, "a legacy stub was rebuilt, not kept")
			end
		end)
	end)
	ctx.at(2450, function()
		local x, y = ep("sp3-legacy-x").data, ep("sp3-legacy-y").data
		local src, dst = x.stats, y.stats
		ctx.expect(src.captured[2] == 4, "side a's legacy stacks were captured: " .. src.captured[2])
		ctx.expect(dst.got[2] == 4, "and received: " .. dst.got[2])
		ctx.expect(src.stubbed == 0 and dst.stubbed == 0, "nothing spilled by the swap: " .. src.stubbed .. ", " .. dst.stubbed)
		local n = y.border.get_transport_line(LANES[1]).get_item_count()
		local yumako = {}
		for _, line in ipairs({ y.border.get_transport_line(LANES[1]) }) do
			for _, e in ipairs(line.get_detailed_contents()) do
				if e.stack.name == "yumako" then yumako[#yumako + 1] = e.stack.spoil_percent end
			end
		end
		for i = 1, core.STUBS do
			n = n + y.lines[i][1].get_item_count()
			for _, e in ipairs(y.lines[i][1].get_detailed_contents()) do
				if e.stack.name == "yumako" then yumako[#yumako + 1] = e.stack.spoil_percent end
			end
		end
		ctx.expect(n == 8, "side b's left lane still holds all 8: " .. n)
		ctx.expect(#yumako == 2, "two yumako on side b's left lane: " .. #yumako)
		for _, p in ipairs(yumako) do
			ctx.expect(p >= 0.37 and p <= 0.39, "a yumako kept its freshness: " .. p)
		end
	end)
	-- Part 2 (R7): an endpoint from before the deploy has none of the new fields.
	local before_placed
	ctx.at(2500, function()
		for _, id in ipairs({ "sp3-legacy-x", "sp3-legacy-y" }) do
			local d = ep(id).data
			d.tier, d.speed, d.matched, d.last, d.due = nil, nil, nil, nil, nil
			d.stats.late, d.stats.reanchored = nil, nil
		end
		local y = ep("sp3-legacy-y").data
		table.insert(y.buf[2], { "2|iron-plate|normal|1", 1, "iron-plate", "normal", 1 })
		before_placed = y.stats.placed
	end)
	-- Spec §8: swaps only on an upgrade or the first poll after the deploy. 2700 is after part 2's re-match (the poll
	-- bound is about 70 ticks after 2500), so a rematch that swapped every poll would change these by 2800.
	local units = {}
	local function stub_units()
		local u = {}
		for _, id in ipairs({ "sp3-legacy-x", "sp3-legacy-y" }) do
			for _, s in ipairs(ep(id).data.stubs) do
				u[#u + 1] = s.valid and s.unit_number or -1
			end
		end
		return table.concat(u, ",")
	end
	ctx.at(2700, function() units = stub_units() end)
	ctx.at(2800, function()
		ctx.expect(stub_units() == units, "no swap without a change: " .. units .. " then " .. stub_units())
		for _, id in ipairs({ "sp3-legacy-x", "sp3-legacy-y" }) do
			local e = ep(id)
			ctx.expect(e.state == "ready", id .. " is still ready: " .. tostring(e.state))
			ctx.expect(e.data.tier == want and e.data.speed == prototypes.entity["fast-transport-belt"].belt_speed,
				id .. " re-matched again: " .. tostring(e.data.tier))
			ctx.expect(e.data.stats.stubbed == 0, id .. " stubbed is 0")
		end
		local placed = ep("sp3-legacy-y").data.stats.placed
		ctx.expect(placed == before_placed + 1, "the old FIFO entry went down: " .. placed .. " from " .. before_placed)
	end)
end)

-- Ground x 6236-6252, ticks 2600-3600.
t.case("belts: tiers - upgrading and downgrading each border belt mid-flow re-matches its stubs within a poll; "
	.. "no removal, nothing spilled, conservation holds (spec §9 test 5)",
	function(ctx)
	local src_border
	ctx.at(2600, function()
		row("sp3-upg", 6240, "transport-belt", 8, false, always("iron-plate"), always("copper-plate"))
	end)
	ctx.at(2800, function()
		src_border = replace(rows["sp3-upg"].feeds[1], "fast-transport-belt")
		wait_tier(ctx, "sp3-upg-x", 2801, "ue-link-belt-fast-transport-belt")
	end)
	ctx.at(2950, function()
		replace(rows["sp3-upg"].belts[1], "fast-transport-belt")
		wait_tier(ctx, "sp3-upg-y", 2951, "ue-link-belt-fast-transport-belt")
	end)
	ctx.at(3100, function()
		replace(src_border, "transport-belt")
		wait_tier(ctx, "sp3-upg-x", 3101, "ue-link-belt")
	end)
	ctx.at(3250, function()
		feeds["sp3-upg"] = nil
	end)
	ctx.at(3600, function()
		ctx.expect(removal_asked["sp3-upg-x/c1"] == nil and removal_asked["sp3-upg-y/c1"] == nil, "no removal asked")
		local src, dst = ep("sp3-upg-x").data.stats, ep("sp3-upg-y").data
		local st = dst.stats
		ctx.expect(src.stubbed == 0 and st.stubbed == 0, "nothing spilled by a swap: " .. src.stubbed .. ", " .. st.stubbed)
		local shipped = src.captured[1] + src.captured[2]
		local got = st.got[1] + st.got[2]
		ctx.expect(shipped > 0 and shipped == got, "shipped = received: " .. shipped .. " and " .. got)
		ctx.expect(got == st.placed + core.buffered(dst.buf[1]) + core.buffered(dst.buf[2]),
			"conservation: got " .. got .. ", placed " .. st.placed)
	end)
end)
