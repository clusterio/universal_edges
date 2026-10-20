-- Belts (SP3 spec §7; belt spacing spec §5, §7), pure: keys, runs from a lane's stubs with a gap a stack, the credit
-- window, the destination's FIFOs and the per-lane clock a placement is due by. belt.lua reads and writes the
-- transport lines.
-- HOLD and SLACK are belt spacing spec §7's tuning knobs (ticks); stats.late and stats.reanchored count when the clock
-- ran behind or had to be re-anchored, and are the evidence for raising them.
local core = { W = 700, STUBS = 5, RUN_CAP = 64, HOLD = 128, SLACK = 64 }

-- ponytail: a module-level memo, never evicted, nested lane -> name -> quality -> s -> (p or false) -> key (perf item
-- 2; final review perf #3's sibling, for the build direction). Keys are lane × item × quality × stack size × (101
-- freshness buckets, D38), so it grows only with the item types that ever ride a belt connector (two lanes, a few
-- qualities and sizes each); building a key is pure, so a fresh memo (a joining player's control.lua) returns the same
-- values. Evict if a save ever carries unbounded key churn.
local keyed = {}

--- "<lane>|<item>|<quality>|<s>" (§7.2), or with a fifth field "<lane>|<item>|<quality>|<s>|<p>" when the item is
--- spoilable (D38, §7.2 "Spoilage"): lane 1 is the left line, 2 the right, relative to the belt's direction, which
--- continues across the border; s is the stack size; p (core.spoil_p) is the freshness, 0..100, omitted entirely for a
--- non-spoilable item. Memoized per (lane, name, quality, s, p): four table lookups instead of concatenating afresh.
function core.key(lane, name, quality, s, p)
	local by_name = keyed[lane]
	if not by_name then
		by_name = {}
		keyed[lane] = by_name
	end
	local by_quality = by_name[name]
	if not by_quality then
		by_quality = {}
		by_name[name] = by_quality
	end
	local by_s = by_quality[quality]
	if not by_s then
		by_s = {}
		by_quality[quality] = by_s
	end
	local by_p = by_s[s]
	if not by_p then
		by_p = {}
		by_s[s] = by_p
	end
	local pk = p or false -- a table key can't be nil; false stands for "no freshness" (a non-spoilable item)
	local k = by_p[pk]
	if not k then
		k = lane .. "|" .. name .. "|" .. quality .. "|" .. s
		if p then
			k = k .. "|" .. p
		end
		by_p[pk] = k
	end
	return k
end

-- ponytail: a module-level memo, never evicted. Keys are lane × item × quality × stack size × (101 freshness buckets,
-- D38), so it grows only with the item types that ever ride a belt connector (two lanes, a few qualities and sizes
-- each); a parse is pure, so a fresh memo (a joining player's control.lua) returns the same values. Evict if a save
-- ever carries unbounded key churn.
local parsed = {}

--- A key's lane, item, quality, stack size and freshness (D38; p is nil for a non-spoilable, four-field key). The
--- five-field pattern is tried first: it needs one more literal "|" than a real four-field key has. A real one can
--- never supply it, since Factorio restricts every prototype's name — items and qualities included — to
--- alphanumerics, dashes and underscores ([api] PrototypeBase.name): "|" can't occur in a name or quality, for any
--- mod. So a four-field key always falls through to the four-field pattern below it. (The adversarial unit test
--- below, with a "|" baked into a fake item name, covers a key shape that can't occur in practice, but still parses
--- correctly either way.)
function core.parse(key)
	local p = parsed[key]
	if not p then
		local lane, name, quality, s, fresh = string.match(key, "^(%d)|(.+)|([^|]+)|(%d+)|(%d+)$")
		if not lane then
			lane, name, quality, s = string.match(key, "^(%d)|(.+)|([^|]+)|(%d+)$")
		end
		p = { tonumber(lane), name, quality, tonumber(s), tonumber(fresh) }
		parsed[key] = p
	end
	return p[1], p[2], p[3], p[4], p[5]
end

--- Belt spacing spec §5: the tick a stack at line position pos (from the tile's downstream end) of stub k (1 = the inner
--- end) entered the stubs, from the stubs' speed v (tiles a tick) at tick now.
function core.entry(k, pos, v, now)
	return now - ((k - 1) + (1 - pos)) / v
end

--- Belt spacing spec §5: a stack's gap behind the previous one's entry tick prev (0 without one), clamped at 0 and
--- rounded to 1/16 tick.
function core.gap(t, prev)
	if not prev then
		return 0
	end
	return math.max(0, math.floor((t - prev) * 16 + 0.5) / 16)
end

--- One stack (p nil when it doesn't spoil, D38) with its gap appended to runs: consecutive stacks of one item, quality,
--- size and freshness join one run, run[3] holding one gap a stack. read_lane calls this per detailed entry directly
--- (perf item 2), instead of first building a { name, quality, count, p } table per stack and a list per stub.
function core.add_stack(runs, lane, name, quality, count, p, gap)
	local k = core.key(lane, name, quality, count, p)
	local tail = runs[#runs]
	if tail and tail[1] == k then
		tail[2] = tail[2] + count
		tail[3][#tail[3] + 1] = gap
	else
		runs[#runs + 1] = { k, count, { gap } }
	end
	return runs
end

--- D38: p = ceil(spoil_percent × 100), 0..100 — freshness rounded up to 1%, so a stack never arrives fresher than it
--- left. Clamped defensively: spoil_percent is documented 0..1, but floating-point noise at either end shouldn't
--- produce a key outside the ledger's 101 buckets.
function core.spoil_p(spoil_percent)
	return math.max(0, math.min(100, math.ceil(spoil_percent * 100)))
end

--- §7.3, §7.4: a lane may be captured while sent + n stays within the partner's limit (none before its first status:
--- refuse) and the lane's runs plus the unacknowledged ones stay within 64.
function core.may_capture(sent, n, lim, runs, unacked)
	return type(lim) == "number" and sent + n <= lim and runs + unacked <= core.RUN_CAP
end

--- §7.4: the destination's limit for a lane, and whether a new one has grown enough (W/4) to announce.
function core.limit(got, buffered)
	return got + core.W - buffered
end
function core.grown(old, new)
	return old == nil or new >= old + core.W / 4
end

--- §7.5: a credited list { { key, n, g }, ... } goes, in order, into its lanes' FIFOs, buf = { [1] = {}, [2] = {} }, as
--- { key, n, name, quality, s, p, g = g, i = 1, at = at } (parsed once; p nil for a non-spoilable key, D38), one entry
--- a run (belt spacing spec §6: never merged), and got[lane] counts it. g is dropped unless it has one gap a stack
--- (n / s). A lane's first entry of this call also gets span, the sum of the call's gaps on the lane past its first
--- stack's (belt spacing spec §7). Returns the items taken: all of them (T2).
function core.take(buf, list, got, at)
	local total = 0
	local first, sum = {}, { 0, 0 }
	for _, x in ipairs(list) do
		local lane, name, quality, s, p = core.parse(x[1])
		got[lane] = got[lane] + x[2]
		local g = x[3]
		if g and #g ~= x[2] / s then
			g = nil
		end
		local q = buf[lane]
		local e = { x[1], x[2], name, quality, s, p, g = g, i = 1, at = at }
		q[#q + 1] = e
		first[lane] = first[lane] or e
		for _, v in ipairs(g or {}) do
			sum[lane] = sum[lane] + v
		end
		total = total + x[2]
	end
	for lane, e in pairs(first) do
		e.span = sum[lane] - (e.g and e.g[1] or 0)
	end
	return total
end

--- Items waiting in one FIFO.
function core.buffered(q)
	local n = 0
	for _, run in ipairs(q) do
		n = n + run[2]
	end
	return n
end

--- The next stack to put down from a FIFO: item, quality, count min(s, what its run has left), and freshness p (D38;
--- nil when the item doesn't spoil); nil when empty.
function core.next_stack(q)
	local run = q[1]
	if not run then
		return nil
	end
	return run[3], run[4], math.min(run[5], run[2]), run[6]
end

--- A stack of c was put down: it leaves the front run, and the run's next gap is the next stack's.
function core.consume(q, c)
	local run = q[1]
	run[2] = run[2] - c
	run.i = (run.i or 1) + 1
	if run[2] <= 0 then
		table.remove(q, 1)
	end
end

--- §7: when the front stack of FIFO entry e is due to leave the UE belt's inner end, from the lane's clock prev (the
--- last placed stack's due; nil before the first) at tick now. A delivery's first stack (its entry has span, at its
--- first stack) is anchored so the delivery's newest stack is due HOLD after it arrived: with no clock, or when the clock
--- would put it past HOLD + SLACK (re-anchored: the second result). Every other stack is the clock plus its gap (0
--- without g). An entry from before the deploy has no at, i or span: at is now, i is 1 (R7).
function core.due(e, prev, now)
	local i, span, at = e.i or 1, e.span or 0, e.at or now
	local due = prev and prev + (e.g and e.g[i] or 0)
	if prev and not (e.span and i == 1) then
		return due, false
	end
	local anchor = at + core.HOLD - span
	if not prev then
		return anchor, false
	end
	if due + span > at + core.HOLD + core.SLACK then
		return anchor, true
	end
	return due, false
end

--- §7: the distance from the inner end to put a stack due at tick `due` (it moves v tiles a tick), at tick now: nil when
--- that is past the stubs (it waits), else no nearer than 0.25 behind the back-most item (back, -1 when none); nil when
--- that leaves no room on the stubs.
function core.place_at(due, now, v, back)
	if due - now > core.STUBS / v then
		return nil
	end
	local dist = math.max(0, (due - now) * v, back + 0.25)
	if dist > core.STUBS - 0.125 then
		return nil
	end
	return dist
end

--- The UE belt a stub of this name is (belt spacing spec §3): ue-link-belt for the yellow transport-belt, else
--- ue-link-belt-<name>.
function core.ue_name(name)
	return name == "transport-belt" and "ue-link-belt" or "ue-link-belt-" .. name
end

--- The UE belt matching a border entity's prototype p (nil: none), among belts, the loaded transport belts without UE's
--- sorted by name (belt spacing spec §4, "Which UE belt"): a transport belt gives its own; an underground belt gives the
--- belt whose related_underground_belt names it, else the first belt of its belt_speed; anything else, or nothing, the
--- fastest (the first by name among equals).
function core.ue_belt(p, belts)
	if p and p.type == "transport-belt" then
		return core.ue_name(p.name)
	end
	if p and p.type == "underground-belt" then
		for _, b in ipairs(belts) do
			if b.related_underground_belt and b.related_underground_belt.name == p.name then
				return core.ue_name(b.name)
			end
		end
		for _, b in ipairs(belts) do
			if b.belt_speed == p.belt_speed then
				return core.ue_name(b.name)
			end
		end
	end
	local best
	for _, b in ipairs(belts) do
		if not best or b.belt_speed > best.belt_speed then
			best = b
		end
	end
	return core.ue_name(best.name)
end

return core
