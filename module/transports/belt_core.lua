-- Belts (SP3 spec §7), pure: keys, runs from a lane's stubs, the credit window, the destination's FIFOs and the slots a
-- placement may use. belt.lua reads and writes the transport lines.
local core = { W = 400, STUBS = 5, RUN_CAP = 64 }

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

--- The fast path (§7.2 step 2): a lane holding one item and quality is one run, its stack size n over the stacks. p
--- (D38) is that item's freshness, nil when it doesn't spoil.
function core.fast_run(lane, name, quality, n, stacks, p)
	return { core.key(lane, name, quality, math.ceil(n / stacks), p), n }
end

--- One stack (p nil when it doesn't spoil, D38) appended to runs: consecutive stacks of one item, quality, size and
--- freshness join one run. read_lane calls this per detailed entry directly (perf item 2), instead of first building
--- a { name, quality, count, p } table per stack and a list per stub.
function core.add_stack(runs, lane, name, quality, count, p)
	local k = core.key(lane, name, quality, count, p)
	local tail = runs[#runs]
	if tail and tail[1] == k then
		tail[2] = tail[2] + count
	else
		runs[#runs + 1] = { k, count }
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

--- §7.5: a credited list { { key, n }, ... } goes, in order, into its lanes' FIFOs, buf = { [1] = {}, [2] = {} }, as
--- { key, n, name, quality, s, p } (parsed once; p nil for a non-spoilable key, D38), and got[lane] counts it. Returns
--- the items taken: all of them (T2).
function core.take(buf, list, got)
	local total = 0
	for _, x in ipairs(list) do
		local lane, name, quality, s, p = core.parse(x[1])
		got[lane] = got[lane] + x[2]
		local q = buf[lane]
		local tail = q[#q]
		if tail and tail[1] == x[1] then
			tail[2] = tail[2] + x[2]
		else
			q[#q + 1] = { x[1], x[2], name, quality, s, p }
		end
		total = total + x[2]
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

--- A stack of c was put down: it leaves the front run.
function core.consume(q, c)
	local run = q[1]
	run[2] = run[2] - c
	if run[2] <= 0 then
		table.remove(q, 1)
	end
end

--- The 20 slots of a destination stub, front first: stub k (1 = the inner end) at line position pos. A position is
--- measured from the tile's downstream end, so 0.125 is a tile's front slot ([probe], plan ruling 1).
core.SLOTS = {}
for k = 1, core.STUBS do
	for j = 0, 3 do
		core.SLOTS[#core.SLOTS + 1] = { k, 0.125 + 0.25 * j }
	end
end

--- The first slot a placement may use: the first one more than 0.25 behind the back-most item on the stub, at distance
--- last from the inner end (-1 when the stub is empty), so new stacks queue behind the ones already there. nil: full.
function core.first_slot(last)
	for i, s in ipairs(core.SLOTS) do
		if (s[1] - 1) + s[2] > last + 0.25 then
			return i
		end
	end
	return nil
end

return core
