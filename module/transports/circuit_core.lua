-- The circuit link's rules, pure (circuit-link spec §7–§8): signal maps, echo cancellation, K8's caps, the two status
-- forms and their fold, the injector's slot map, the write task's walk, validation, and b′'s groups and forest. No
-- Factorio globals, so it runs on lua5.2. A signal map is nested by type, quality and name,
-- m[type][quality][name] = count, and never holds a 0.
local core = {}

core.COLOURS = { "r", "g" }
core.MAX_SIGNALS = 2000 -- K8: a colour, at both ends
core.MAX_BYTES = 180000 -- K8: one status's signals, encoded: 60 of FC3's 64 parts. Read at each use: a game test lowers it.
--- §8.5: each signal type's prototype table.
core.TYPES = {
	item = "item", fluid = "fluid", virtual = "virtual_signal", entity = "entity", recipe = "recipe", quality = "quality",
	["space-location"] = "space_location", ["asteroid-chunk"] = "asteroid_chunk",
}

--- K4: x as an int32, as a wire's sum wraps (§8.6).
function core.wrap(x)
	return (x + 2147483648) % 4294967296 - 2147483648
end

function core.get(m, t, q, n)
	local a = m[t]
	local b = a and a[q]
	return b and b[n]
end

--- m[t][q][n] = v; v nil removes it, and the levels it empties.
function core.put(m, t, q, n, v)
	local a = m[t]
	if v == nil then
		local b = a and a[q]
		if b then
			b[n] = nil
			if next(b) == nil then
				a[q] = nil
				if next(a) == nil then
					m[t] = nil
				end
			end
		end
		return
	end
	if not a then
		a = {}
		m[t] = a
	end
	local b = a[q]
	if not b then
		b = {}
		a[q] = b
	end
	b[n] = v
end

--- How many signals m holds.
function core.size(m)
	local k = 0
	for _, qs in pairs(m) do
		for _, names in pairs(qs) do
			for _ in pairs(names) do
				k = k + 1
			end
		end
	end
	return k
end

--- Every signal of m into the set todo (todo[t][q][n] = true).
function core.mark_all(todo, m)
	for t, qs in pairs(m) do
		for q, names in pairs(qs) do
			for n in pairs(names) do
				core.put(todo, t, q, n, true)
			end
		end
	end
end

--- Every signal of a whose value differs in b into todo.
local function mark_diff(todo, a, b)
	for t, qs in pairs(a) do
		for q, names in pairs(qs) do
			for n, x in pairs(names) do
				if core.get(b, t, q, n) ~= x then
					core.put(todo, t, q, n, true)
				end
			end
		end
	end
end

--- A circuit endpoint's ep.data fields (§6.2 step 2), fresh. Per colour: what its injector holds (inj, ninj signals),
--- the injector's slot map (slot), free slots (free) and highest slot used (top); this side's own signals as last sent
--- (out, nout; v is their version); the mirror of the far side's (far, nfar); the signals whose slot may be off target
--- (todo); and the carry at the last poll. Also the injectors (comb), the truncation and log flags, and the counters.
function core.data()
	return {
		inj = { r = {}, g = {} }, ninj = { r = 0, g = 0 }, slot = { r = {}, g = {} }, free = { r = {}, g = {} },
		top = { r = 0, g = 0 }, out = { r = {}, g = {} }, nout = { r = 0, g = 0 }, v = 0, far = { r = {}, g = {} },
		nfar = { r = 0, g = 0 }, todo = { r = {}, g = {} }, carry = { r = false, g = false }, comb = {}, trunc = {},
		logged = {}, stats = { sent = 0, applied = 0, dropped = 0, gaps = 0 },
	}
end

--- FC4 (C5 b): forget what the partner gave — the injected record, the slot maps, the mirror and the writes due. This
--- side's own out and v stay.
function core.reset(d)
	for _, c in ipairs(core.COLOURS) do
		d.inj[c], d.slot[c], d.free[c], d.far[c], d.todo[c] = {}, {}, {}, {}, {}
		d.ninj[c], d.top[c], d.nfar[c] = 0, 0, 0
	end
	d.far_v, d.far_epoch, d.gap = nil, nil, nil
	d.rt = nil -- the next poll reads every carrying colour
end

-- Reading ---------------------------------------------------------------------------------------------------------------

--- §7.5 step 7 without building anything: is the network (sigs: the API's .signals, nil when silent) minus inj (ninj
--- signals) exactly out (nout signals)? A read signal with no type is an item, with no quality normal (§7.1). False also
--- when an injected signal is missing from the network: its remainder is -inj, which only building the remainder finds.
--- Every poll runs it over every signal of the network, so core.get is inlined (radar perf P1: 20–30% of the call at
--- 1,000 signals), and a count with nothing injected is already an int32, so only a difference is wrapped.
function core.unchanged(sigs, inj, ninj, out, nout)
	local seen, nrem = 0, 0
	for i = 1, sigs and #sigs or 0 do
		local s = sigs[i]
		local id = s.signal
		local t, q, n = id.type or "item", id.quality or "normal", id.name
		local a = inj[t]
		local b = a and a[q]
		local iv = b and b[n]
		local r = s.count
		if iv then
			seen = seen + 1
			r = core.wrap(r - iv)
		end
		a = out[t]
		b = a and a[q]
		local o = b and b[n]
		if r ~= 0 then
			if o ~= r then
				return false
			end
			nrem = nrem + 1
		elseif o ~= nil then
			return false
		end
	end
	return seen == ninj and nrem == nout
end

--- §7.2: the network (sigs) minus this link's own injector (inj), int32-wrapped, zeros dropped.
function core.remainder(sigs, inj)
	local rem = {}
	for t, qs in pairs(inj) do
		for q, names in pairs(qs) do
			for n, v in pairs(names) do
				core.put(rem, t, q, n, core.wrap(-v))
			end
		end
	end
	for i = 1, sigs and #sigs or 0 do
		local s = sigs[i]
		local id = s.signal
		local t, q, n = id.type or "item", id.quality or "normal", id.name
		local r = core.wrap((core.get(rem, t, q, n) or 0) + s.count)
		core.put(rem, t, q, n, r ~= 0 and r or nil)
	end
	return rem
end

--- remainder and diff in one walk of the network (radar perf proposal 4): the network (sigs) minus inj (ninj signals),
--- int32-wrapped, zeros dropped, as remainder gives it; and the change from out (nout signals) to it, as
--- diff(out, rem) gives it, with its size. out and inj are only walked when the network walk can't account for every
--- entry of theirs: a signal that left (out has keys rem lacks), or an injected signal missing from the network.
--- Returns rem, ch, k (the change's signals) and n (rem's signals). A missing injected signal is found by building the
--- network's key set on that path only. Assumes unique keys in sigs and a ninj/nout that match inj and out.
-- ponytail: saves remainder's inj pre-pass and put/get pass, core.size(rem) and diff's two walks (about 1.25 ms of a
-- changing poll at 1,000 signals); the cost is a longer function.
function core.remainder_diff(sigs, inj, ninj, out, nout)
	local rem, ch, k, n, seen, same = {}, {}, 0, 0, 0, 0
	local put, wrap = core.put, core.wrap
	for i = 1, sigs and #sigs or 0 do
		local s = sigs[i]
		local id = s.signal
		local t, q, name = id.type or "item", id.quality or "normal", id.name
		local a = inj[t]
		local b = a and a[q]
		local iv = b and b[name]
		local r = s.count
		if iv then
			seen = seen + 1
			r = wrap(r - iv)
		end
		a = out[t]
		b = a and a[q]
		local o = b and b[name]
		if r ~= 0 then
			put(rem, t, q, name, r)
			n = n + 1
			if o == r then
				same = same + 1
			else
				put(ch, t, q, name, r)
				k = k + 1
				if o ~= nil then
					same = same + 1
				end
			end
		elseif o ~= nil then
			put(ch, t, q, name, 0)
			k, same = k + 1, same + 1 -- accounted for: a signal that went to 0 needs no walk of out
		end
	end
	if seen < ninj then
		local net = {}
		for i = 1, sigs and #sigs or 0 do
			local id = sigs[i].signal
			put(net, id.type or "item", id.quality or "normal", id.name, true)
		end
		for t, qs in pairs(inj) do
			for q, names in pairs(qs) do
				for name, iv in pairs(names) do
					if core.get(net, t, q, name) == nil then
						local r = wrap(-iv)
						local o = core.get(out, t, q, name)
						put(rem, t, q, name, r)
						n = n + 1
						if o == r then
							same = same + 1
						else
							put(ch, t, q, name, r)
							k = k + 1
							if o ~= nil then
								same = same + 1
							end
						end
					end
				end
			end
		end
	end
	if same < nout then
		for t, qs in pairs(out) do
			for q, names in pairs(qs) do
				for name in pairs(names) do
					if core.get(rem, t, q, name) == nil and core.get(ch, t, q, name) == nil then
						put(ch, t, q, name, 0)
						k = k + 1
					end
				end
			end
		end
	end
	return rem, ch, k, n
end

-- Sending ---------------------------------------------------------------------------------------------------------------

--- An entry's share of an encoded status: its name, its count, two quotes and two commas (§8.2). A group's key is left
--- out: a few bytes per type and quality, inside the 4 parts between K8's 60 and FC3's 64.
local function bytes(n, c)
	return #n + #tostring(c) + 4
end

local function total(m)
	local b = 0
	for _, qs in pairs(m) do
		for _, names in pairs(qs) do
			for n, c in pairs(names) do
				b = b + bytes(n, c)
			end
		end
	end
	return b
end

--- How many signals m holds, and a bound on total(m) that needs no tostring: a count is an int32 (K4), at most 11
--- characters ("-2147483648"), so an entry takes at most #n + 15 (radar perf P1: total's tostring was 0.94 ms at 1,000
--- signals, this walk 0.03–0.04 ms).
local function bound(m)
	local k, b = 0, 0
	for _, qs in pairs(m) do
		for _, names in pairs(qs) do
			for n in pairs(names) do
				k, b = k + 1, b + #n
			end
		end
	end
	return k, b + 15 * k
end

local function before(a, b)
	if a[1] ~= b[1] then
		return a[1] < b[1]
	end
	if a[2] ~= b[2] then
		return a[2] < b[2]
	end
	return a[3] < b[3]
end

--- K8 over one status's two colours (plan ruling 2). Within MAX_SIGNALS a colour and MAX_BYTES in all, r and g come back
--- as they are. Past either, each colour keeps its first MAX_SIGNALS signals in the fixed order (type, quality, name),
--- and the kept signals of red, then green, count their bytes until MAX_BYTES, where everything after stops. Returns the
--- kept maps and how many each colour dropped.
-- ponytail: an over-cap network sorts at every poll whose remainder differs from out (about 1–2 ms at 2,100 signals,
-- estimated); keep the sorted order if one is ever seen.
function core.fit(r, g)
	local kr, br = bound(r)
	local kg, bg = bound(g)
	if kr <= core.MAX_SIGNALS and kg <= core.MAX_SIGNALS
		and (br + bg <= core.MAX_BYTES or total(r) + total(g) <= core.MAX_BYTES) then
		return r, g, 0, 0
	end
	local budget, kept, dropped = core.MAX_BYTES, {}, {}
	for i, m in ipairs({ r, g }) do
		local list = {}
		for t, qs in pairs(m) do
			for q, names in pairs(qs) do
				for n, c in pairs(names) do
					list[#list + 1] = { t, q, n, c }
				end
			end
		end
		table.sort(list, before)
		local out, k = {}, 0
		for _, e in ipairs(list) do
			if k < core.MAX_SIGNALS then
				local b = bytes(e[3], e[4])
				if b <= budget then
					core.put(out, e[1], e[2], e[3], e[4])
					k, budget = k + 1, budget - b
				else
					budget = 0 -- the byte cap stops here: nothing after this entry is kept
				end
			end
		end
		kept[i], dropped[i] = out, #list - k
	end
	return kept[1], kept[2], dropped[1], dropped[2]
end

--- The change from old to new: every signal with a new value, and every one that left as 0; and how many.
function core.diff(old, new)
	local ch, k = {}, 0
	for t, qs in pairs(new) do
		for q, names in pairs(qs) do
			for n, c in pairs(names) do
				if core.get(old, t, q, n) ~= c then
					core.put(ch, t, q, n, c)
					k = k + 1
				end
			end
		end
	end
	for t, qs in pairs(old) do
		for q, names in pairs(qs) do
			for n in pairs(names) do
				if core.get(new, t, q, n) == nil then
					core.put(ch, t, q, n, 0)
					k = k + 1
				end
			end
		end
	end
	return ch, k
end

--- §8.2's encoding: { [type, or "type|quality" past normal] = { name, count, … } }, nil when m is empty.
function core.encode(m)
	local enc
	for t, qs in pairs(m) do
		for q, names in pairs(qs) do
			local list, k = {}, 0
			for n, c in pairs(names) do
				list[k + 1], list[k + 2] = n, c
				k = k + 2
			end
			if k > 0 then
				enc = enc or {}
				enc[q == "normal" and t or t .. "|" .. q] = list
			end
		end
	end
	return enc
end

--- §8.2's full form: every signal of out (both colours), at version v, with both groups.
function core.full(v, gr, gg, out)
	return { v = v, gr = gr, gg = gg, r = core.encode(out.r), g = core.encode(out.g) }
end

--- Status v (§8.2, K7): the change { v, base = v - 1, gr, gg, r?, g? } of each colour that changed (old[c] its previous
--- map), or the full form of out when the change holds at least as many signals as the full (nfull). Returns it and how
--- many signals the change holds. pre[c], when given, is { ch, k }: the change of old[c] to out[c], already built.
function core.status(v, gr, gg, out, old, nfull, pre)
	local ch, k = {}, 0
	for _, c in ipairs(core.COLOURS) do
		if old[c] then
			local p = pre and pre[c]
			local m, n
			if p then
				m, n = p[1], p[2]
			else
				m, n = core.diff(old[c], out[c])
			end
			ch[c], k = m, k + n
		end
	end
	if k >= nfull then
		return core.full(v, gr, gg, out), k
	end
	return { v = v, base = v - 1, gr = gr, gg = gg, r = ch.r and core.encode(ch.r), g = ch.g and core.encode(ch.g) }, k
end

-- Receiving -------------------------------------------------------------------------------------------------------------

local function int32(c)
	return type(c) == "number" and c % 1 == 0 and c >= -2147483648 and c <= 2147483647
end

--- §8.5's fold check of one colour's encoding (nil when the colour was left out): fn(t, q, n, count) for each well-formed
--- entry. A group's key names one of the eight types, with a quality quality_ok accepts, and holds an even list; an
--- entry is a string name and an int32 count. Returns how many entries, or whole groups, were malformed.
function core.each_entry(enc, quality_ok, fn)
	if enc == nil then
		return 0
	end
	if type(enc) ~= "table" then
		return 1
	end
	local bad = 0
	for key, list in pairs(enc) do
		local t, q
		if type(key) == "string" then
			t, q = string.match(key, "^([^|]+)|(.+)$")
			if not t then
				t, q = key, "normal"
			end
		end
		if not (t and core.TYPES[t] and quality_ok(q) and type(list) == "table" and #list % 2 == 0) then
			bad = bad + 1
		else
			for i = 1, #list, 2 do
				local n, c = list[i], list[i + 1]
				if type(n) == "string" and int32(c) then
					fn(t, q, n, c)
				else
					bad = bad + 1
				end
			end
		end
	end
	return bad
end

--- K17: fold a partner's status into the mirror (§8.3), in arrival order, in the edge's current epoch. A full replaces
--- the mirror and ends a gap; a change applies only on its base in this epoch, with no gap; a repeat (its v already
--- applied) is ignored; anything else is a gap, after which changes are ignored until a full. Every signal whose mirror
--- value changed goes into todo; the mirror keeps at most MAX_SIGNALS a colour. Returns "full", "change", "repeat",
--- "gap" or "malformed", and how many entries were dropped as malformed or past the cap.
function core.fold(d, status, epoch, quality_ok)
	if type(status.v) ~= "number" then
		return "malformed", 1
	end
	local bad = 0
	if status.base == nil then
		for _, c in ipairs(core.COLOURS) do
			local new, k, over = {}, 0, 0
			local m = core.each_entry(status[c], quality_ok, function(t, q, n, x)
				if x ~= 0 and core.get(new, t, q, n) == nil then
					if k >= core.MAX_SIGNALS then
						over = over + 1
						return
					end
					k = k + 1
					core.put(new, t, q, n, x)
				end
			end)
			bad = bad + m + over
			mark_diff(d.todo[c], d.far[c], new)
			mark_diff(d.todo[c], new, d.far[c])
			d.far[c], d.nfar[c] = new, k
		end
		d.far_v, d.far_epoch, d.gap = status.v, epoch, nil
		return "full", bad
	end
	if d.far_epoch == epoch and status.v == d.far_v then
		return "repeat", 0
	end
	if d.gap or d.far_epoch ~= epoch or status.base ~= d.far_v then
		d.gap = true
		return "gap", 0
	end
	for _, c in ipairs(core.COLOURS) do
		local far, todo, over = d.far[c], d.todo[c], 0
		local function apply(t, q, n, x)
			local had = core.get(far, t, q, n)
			if x == 0 then
				if had ~= nil then
					core.put(far, t, q, n, nil)
					d.nfar[c] = d.nfar[c] - 1
					core.put(todo, t, q, n, true)
				end
			elseif had ~= x then
				if had == nil then
					if d.nfar[c] >= core.MAX_SIGNALS then
						over = over + 1
						return
					end
					d.nfar[c] = d.nfar[c] + 1
				end
				core.put(far, t, q, n, x)
				core.put(todo, t, q, n, true)
			end
		end
		-- Removals first: at the cap, a change that swaps keys must free its room before an addition asks for it.
		core.each_entry(status[c], quality_ok, function(t, q, n, x)
			if x == 0 then
				apply(t, q, n, x)
			end
		end)
		local m = core.each_entry(status[c], quality_ok, function(t, q, n, x)
			if x ~= 0 then
				apply(t, q, n, x)
			end
		end)
		bad = bad + m + over
	end
	d.far_v = status.v
	return "change", bad
end

-- Writing ---------------------------------------------------------------------------------------------------------------

--- K5: the slot for signal (t, q, n) in a colour's section: its own, else a freed one, else the next past top. Returns
--- it and the new top.
function core.take_slot(slot, free, top, t, q, n)
	local i = core.get(slot, t, q, n)
	if i then
		return i, top
	end
	local k = #free
	if k > 0 then
		i, free[k] = free[k], nil
	else
		top = top + 1
		i = top
	end
	core.put(slot, t, q, n, i)
	return i, top
end

--- K5: the slot (t, q, n) held, now free; nil when it held none.
function core.give_slot(slot, free, t, q, n)
	local i = core.get(slot, t, q, n)
	if i then
		core.put(slot, t, q, n, nil)
		free[#free + 1] = i
	end
	return i
end

--- K5, K16: write at most budget of colour c's pending signals (d.todo[c]) to their target — the mirror, d.far[c],
--- while carry, else nothing — one slot each: set(i, t, q, n, count) writes a value at slot i (its own, a freed one or
--- the next past top), clear(i) takes one out. inj changes in the same step as each slot (K2). valid(t, q, n), §8.5's
--- prototype check, runs only for a signal about to be set; one that fails leaves the mirror. A signal already at its
--- target costs no slot. Returns the slots written.
function core.write(d, c, budget, carry, valid, set, clear)
	local todo, far, inj, slot, free = d.todo[c], d.far[c], d.inj[c], d.slot[c], d.free[c]
	local used = 0
	-- Clears first (pass 1), then sets: a set takes a freed slot, so at 2,000 a colour never asks for a third section.
	for pass = 1, 2 do
		for t, qs in pairs(todo) do
			for q, names in pairs(qs) do
				for n in pairs(names) do
					if used >= budget then
						return used
					end
					local want = carry and core.get(far, t, q, n) or nil
					local have = core.get(inj, t, q, n)
					if pass == 1 and want ~= nil and want ~= have then
						goto later -- a set waits for pass 2, in todo
					end
					if want ~= nil and want ~= have and not valid(t, q, n) then
						core.put(far, t, q, n, nil)
						d.nfar[c] = d.nfar[c] - 1
						want = nil
					end
					if want ~= have then
						if want ~= nil then
							local i
							i, d.top[c] = core.take_slot(slot, free, d.top[c], t, q, n)
							set(i, t, q, n, want)
							if have == nil then
								d.ninj[c] = d.ninj[c] + 1
							end
						else
							clear(core.give_slot(slot, free, t, q, n))
							d.ninj[c] = d.ninj[c] - 1
						end
						core.put(inj, t, q, n, want)
						used = used + 1
					end
					names[n] = nil -- only once its slot is written: a raise leaves it for G6's retry
					::later::
				end
				if next(names) == nil then
					qs[q] = nil
				end
			end
			if next(qs) == nil then
				todo[t] = nil
			end
		end
	end
	return used
end

--- K16: one tick of the write task over set (key → item), at most budget slots in all, in the set's order. step(item,
--- left) returns the slots it wrote and whether the item is done; a done item leaves the set. Returns the slots written.
function core.drain(set, budget, step)
	local used = 0
	for key, item in pairs(set) do
		if used >= budget then
			break
		end
		local n, done = step(item, budget - used)
		used = used + n
		if done then
			set[key] = nil
		end
	end
	return used
end

-- b′ (§7.7) ------------------------------------------------------------------------------------------------------------

--- s[key], emptied (made on first use): scratch filled and read within one call.
local function scratch(s, key)
	local x = s[key]
	if x then
		for k in pairs(x) do
			x[k] = nil
		end
	else
		x = {}
		s[key] = x
	end
	return x
end

--- b′'s grouping for one colour: links[1..n] in ascending cid, each with pole (a valid pole stands) and its network id
--- links[i][ik] (nil: no network of that colour). links[i][gk] becomes the lowest cid whose pole shares its network, its
--- own cid when it has none, and nil without a pole: that side sends no group, so the link is left out (§6.5).
function core.group(links, n, ik, gk, s)
	local low = scratch(s, "low")
	for i = 1, n do
		local l = links[i]
		local id = l[ik]
		if not l.pole then
			l[gk] = nil
		elseif id == nil then
			l[gk] = l.cid
		else
			low[id] = low[id] or l.cid
			l[gk] = low[id]
		end
	end
end

--- b′'s forest for one colour: Kruskal over links[1..n] in their (ascending cid) order. A link is an arc when
--- links[i].arc (both ends ready, neither closing) and both its near group links[i][gk] and the partner's group
--- links[i][fk] are known; an arc joining two components carries (links[i][ck] = true), any other link is quiet. Each
--- side names its own groups, so near and far nodes are numbered apart: a far group this side doesn't list is just one
--- more node (Review Focus 4).
function core.forest(links, n, gk, fk, ck, s)
	local near, far, parent = scratch(s, "near"), scratch(s, "far"), scratch(s, "parent")
	local count = 0
	local function node(map, g)
		local i = map[g]
		if not i then
			count = count + 1
			i = count
			map[g] = i
		end
		return i
	end
	local function find(x)
		while parent[x] do
			x = parent[x]
		end
		return x
	end
	for i = 1, n do
		local l = links[i]
		local a, b = l[gk], l[fk]
		l[ck] = false
		if l.arc and a ~= nil and b ~= nil then
			local u, v = find(node(near, a)), find(node(far, b))
			if u ~= v then
				parent[u] = v
				l[ck] = true
			end
		end
	end
end

return core
