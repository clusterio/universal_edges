local t = require("testlib")
local core = require("modules/universal_edges/transports/circuit_core")

local Q = function(q) return q == "normal" or q == "uncommon" or q == "rare" end
local yes = function() return true end
local noop = function() end

--- The API's .signals for { type?, quality?, name, count } entries.
local function sigs(list)
	local out = {}
	for i, e in ipairs(list) do
		out[i] = { signal = { type = e[1], quality = e[2], name = e[3] }, count = e[4] }
	end
	return out
end

--- A map of item signals at normal quality from name, count pairs.
local function items(list)
	local m = {}
	for i = 1, #list, 2 do
		core.put(m, "item", "normal", list[i], list[i + 1])
	end
	return m
end

--- A colour of a map, or of a set, as sorted "name=count" or "name" strings joined.
local function show(m)
	local out = {}
	for _, qs in pairs(m) do
		for q, names in pairs(qs) do
			for n, c in pairs(names) do
				out[#out + 1] = n .. (q ~= "normal" and "|" .. q or "") .. (c ~= true and "=" .. c or "")
			end
		end
	end
	table.sort(out)
	return table.concat(out, ",")
end

t.test("keys and wrap: a read signal without type or quality is an item at normal; counts wrap at int32 (§7.1, K4)",
	function()
		t.expect_eq(core.get(core.remainder({ { signal = { name = "iron-plate" }, count = 5 } }, {}), "item", "normal",
			"iron-plate"), 5)
		t.expect_eq(core.wrap(2147483647), 2147483647)
		t.expect_eq(core.wrap(2147483648), -2147483648)
		t.expect_eq(core.wrap(-2147483649), 2147483647)
		t.expect_eq(core.wrap(2 * 2147483647), -2)
	end)

t.test("remainder (§7.2): the network minus this link's injector, wrapped, zeros dropped", function()
	local inj = items({ "a", 5, "b", 7 })
	core.put(inj, "virtual", "normal", "c", 2)
	local rem = core.remainder(sigs({ { "item", nil, "a", 8 }, { "item", nil, "b", 7 }, { "fluid", nil, "w", -3 } }), inj)
	t.expect_eq(show(rem), "a=3,c=-2,w=-3", "a network-only key, an injector-only key as -inj, a negative, b cancelled")
	t.expect_eq(show(core.remainder(nil, {})), "", "a silent network")
	t.expect_eq(core.get(core.remainder(sigs({ { "item", nil, "x", -2147483648 } }), items({ "x", 1 })), "item", "normal",
		"x"), 2147483647, "wrapped")
end)

t.test("unchanged (§7.5 step 7): true only when network − inj is exactly out", function()
	local inj, out = items({ "a", 5 }), items({ "a", 3 })
	t.expect_true(core.unchanged(sigs({ { "item", nil, "a", 8 } }), inj, 1, out, 1), "the same")
	t.expect_true(not core.unchanged(sigs({ { "item", nil, "a", 9 } }), inj, 1, out, 1), "a value moved")
	t.expect_true(not core.unchanged(sigs({ { "item", nil, "a", 8 }, { "item", nil, "b", 1 } }), inj, 1, out, 1), "a new key")
	t.expect_true(not core.unchanged(sigs({}), inj, 1, out, 1), "an injected key gone from the network")
	t.expect_true(core.unchanged(sigs({ { "item", nil, "a", 5 } }), inj, 1, {}, 0), "nothing of its own")
	t.expect_true(core.unchanged(sigs({ { "item", nil, "x", -2147483648 } }), items({ "x", 1 }), 1,
		items({ "x", 2147483647 }), 1), "the difference wraps, as the remainder's does")
end)

--- A map as sorted "type|quality|name=count" strings joined.
local function canon(m)
	local out = {}
	for tp, qs in pairs(m) do
		for q, names in pairs(qs) do
			for n, c in pairs(names) do
				out[#out + 1] = tp .. "|" .. q .. "|" .. n .. "=" .. c
			end
		end
	end
	table.sort(out)
	return table.concat(out, ",")
end

--- remainder_diff against remainder + diff + size, exactly.
local function same_as_two_walks(list, inj, out, label)
	local network = list and sigs(list) or nil
	local rem0 = core.remainder(network, inj)
	local ch0, k0 = core.diff(out, rem0)
	local rem, ch, k, n = core.remainder_diff(network, inj, core.size(inj), out, core.size(out))
	t.expect_eq(canon(rem), canon(rem0), label .. ": rem")
	t.expect_eq(canon(ch), canon(ch0), label .. ": ch")
	t.expect_eq(k, k0, label .. ": k")
	t.expect_eq(n, core.size(rem0), label .. ": n")
end

t.test("remainder_diff: named cases give what remainder and diff give", function()
	local out = items({ "a", 3, "gone", 4 })
	same_as_two_walks({ { "item", nil, "a", 8 }, { "item", nil, "gone", 4 } }, items({ "a", 5 }), items({ "gone", 4 }),
		"unchanged-ish")
	same_as_two_walks({ { "item", nil, "a", 8 } }, items({ "a", 5 }), out, "a signal that left")
	same_as_two_walks({ { "item", nil, "a", 8 } }, items({ "a", 5, "m", 2 }), out, "an injected signal missing")
	same_as_two_walks({ { "item", nil, "a", 8 }, { "item", nil, "gone", 4 } }, items({ "gone", 4 }), out,
		"cancelled to 0 that out had")
	same_as_two_walks({ { "item", nil, "x", -2147483648 } }, items({ "x", 1 }), items({ "x", 2147483647 }), "int32 wrap")
	same_as_two_walks({ { "item", nil, "x", 2147483647 } }, items({ "x", -1 }), {}, "int32 wrap up")
	same_as_two_walks(nil, items({ "m", 2 }), out, "a silent network with an injected signal")
	same_as_two_walks(nil, {}, out, "a silent network")
	same_as_two_walks(nil, {}, {}, "silence over nothing")
end)

t.test("remainder_diff: a few hundred random networks, injectors and outs give what remainder and diff give", function()
	math.randomseed(20261007)
	local types, quals = { "item", "fluid", "virtual" }, { "normal", "rare" }
	local edge = { 0, 1, -1, 5, -5, 2147483647, -2147483648, 100 }
	local function count()
		return math.random() < 0.3 and edge[math.random(#edge)] or math.random(-50, 50)
	end
	for case = 1, 400 do
		local keys = {}
		for i = 1, math.random(0, 12) do
			keys[i] = { types[math.random(3)], quals[math.random(2)], "s" .. math.random(0, 14) }
		end
		local list, seen_key, inj, out = {}, {}, {}, {}
		for _, key in ipairs(keys) do
			local id = key[1] .. key[2] .. key[3]
			if not seen_key[id] then
				seen_key[id] = true
				list[#list + 1] = { key[1], key[2], key[3], count() }
			end
		end
		for _ = 1, math.random(0, 8) do
			local e = list[math.random(#list + 1)] -- nil: a key probably absent from the network
			local key = e and { e[1], e[2], e[3] } or { types[math.random(3)], quals[math.random(2)], "s" .. math.random(0, 14) }
			local v = e and math.random() < 0.4 and e[4] or count() -- the same value cancels the signal to 0
			if v ~= 0 then
				core.put(inj, key[1], key[2], key[3], v)
			end
		end
		for _ = 1, math.random(0, 10) do
			local e = list[math.random(#list + 1)]
			local key = e and { e[1], e[2], e[3] } or { types[math.random(3)], quals[math.random(2)], "s" .. math.random(0, 14) }
			local v = count()
			if v ~= 0 then
				core.put(out, key[1], key[2], key[3], v)
			end
		end
		if math.random() < 0.5 then -- an out that is exactly the remainder, so same == nout too
			out = core.remainder(sigs(list), inj)
		end
		same_as_two_walks(math.random() < 0.05 and nil or list, inj, out, "case " .. case)
	end
end)

t.test("status with a precomputed change gives what it gives without", function()
	local out, old = { r = items({ "a", 1, "b", 5 }), g = {} }, { r = items({ "a", 1, "b", 2, "c", 3 }) }
	local st, k = core.status(8, "c1", "c2", out, old, 9)
	local ch, ck = core.diff(old.r, out.r)
	local st2, k2 = core.status(8, "c1", "c2", out, old, 9, { r = { ch, ck } })
	t.expect_eq(k2, k)
	local function flat(l) -- an encoded list's name, count pairs, sorted
		local o = {}
		for i = 1, #l, 2 do
			o[#o + 1] = l[i] .. "=" .. l[i + 1]
		end
		table.sort(o)
		return table.concat(o, ",")
	end
	t.expect_eq(flat(st2.r.item), flat(st.r.item))
	t.expect_eq(st2.base, st.base)
end)

t.test("status (K7): a change carries each new value and each signal that left as 0, on base v - 1; unchanged ones " ..
	"aren't sent", function()
	local st, k = core.status(8, "c1", "c2", { r = items({ "a", 1, "b", 5, "d", 4, "e", 5 }), g = {} },
		{ r = items({ "a", 1, "b", 2, "c", 3, "e", 5 }) }, 4)
	t.expect_eq(k, 3)
	t.expect_true(st.v == 8 and st.base == 7 and st.gr == "c1" and st.gg == "c2" and st.g == nil, "a change on 7")
	local got = {}
	core.each_entry(st.r, Q, function(_, _, n, c) got[n] = c end)
	t.expect_same(got, { b = 5, c = 0, d = 4 })
end)

t.test("status (K7): the full form when the change is no smaller — silence sends an empty full, every value moved sends " ..
	"the full; a group change alone is a change with no colours", function()
	local old, moved = items({ "a", 1, "b", 2 }), items({ "a", 9, "b", 9 })
	local st = core.status(3, "c1", nil, { r = {}, g = {} }, { r = old }, 0)
	t.expect_true(st.v == 3 and st.base == nil and st.r == nil, "an empty full")
	st = core.status(4, "c1", nil, { r = moved, g = {} }, { r = old }, 2)
	t.expect_true(st.base == nil and #st.r.item == 4, "the full, both signals")
	local k
	st, k = core.status(5, "c3", nil, { r = moved, g = {} }, {}, 2)
	t.expect_true(st.base == 4 and st.r == nil and st.g == nil and st.gr == "c3" and k == 0, "a group change alone")
end)

t.test("encoding (§8.2): groups by type and type|quality, normal quality left out, empty colours left out; both forms " ..
	"round-trip through the fold", function()
	local out = { r = items({ "iron-plate", 120 }), g = {} }
	core.put(out.r, "item", "rare", "iron-plate", 3)
	core.put(out.r, "virtual", "normal", "signal-A", 1)
	local full = core.full(17, "c3", "c5", out)
	t.expect_same(full.r.item, { "iron-plate", 120 })
	t.expect_same(full.r["item|rare"], { "iron-plate", 3 })
	t.expect_same(full.r.virtual, { "signal-A", 1 })
	t.expect_true(full.g == nil and full.base == nil and full.gr == "c3" and full.gg == "c5", "green left out")
	local d = core.data()
	t.expect_eq(core.fold(d, full, "E", Q), "full")
	t.expect_same(d.far.r, out.r, "the full round-trips")
	local new = items({ "iron-plate", 121 })
	core.put(new, "item", "rare", "iron-plate", 3)
	core.put(new, "virtual", "normal", "signal-A", 1)
	local st = core.status(18, "c3", "c5", { r = new, g = {} }, { r = out.r }, 3)
	t.expect_same(st.r, { item = { "iron-plate", 121 } }, "only what changed")
	t.expect_eq(core.fold(d, st, "E", Q), "change")
	t.expect_same(d.far.r, new, "the change round-trips")
end)

t.test("fold (K17): a full replaces the mirror, marks exactly the signals whose value differs, sets far_v and " ..
	"far_epoch, and ends a gap", function()
	local d = core.data()
	t.expect_eq(core.fold(d, { v = 3, r = { item = { "a", 1, "b", 2 } } }, "E1", Q), "full")
	d.todo.r, d.gap = {}, true
	t.expect_eq(core.fold(d, { v = 7, r = { item = { "a", 1, "b", 5, "c", 3 } } }, "E1", Q), "full")
	t.expect_eq(show(d.far.r), "a=1,b=5,c=3")
	t.expect_eq(show(d.todo.r), "b,c", "a kept its value")
	t.expect_true(d.far_v == 7 and d.far_epoch == "E1" and not d.gap and d.nfar.r == 3, "version, epoch, no gap, count")
	d.todo.r = {}
	core.fold(d, { v = 8 }, "E1", Q)
	t.expect_true(show(d.far.r) == "" and show(d.todo.r) == "a,b,c", "an empty full: silence, every signal to clear")
end)

t.test("fold (K17): a change applies only on its base in the current epoch; two back to back both apply", function()
	local d = core.data()
	core.fold(d, { v = 4, r = { item = { "a", 1, "b", 2 } } }, "E", Q)
	t.expect_eq(core.fold(d, { v = 5, base = 4, r = { item = { "a", 9, "b", 0, "c", 3 } } }, "E", Q), "change")
	t.expect_true(show(d.far.r) == "a=9,c=3" and d.far_v == 5 and d.nfar.r == 2, "set, removed at 0, added")
	t.expect_eq(core.fold(d, { v = 6, base = 5, r = { item = { "c", 0 } } }, "E", Q), "change", "back to back")
	t.expect_true(show(d.far.r) == "a=9" and d.far_v == 6, "both applied")
end)

t.test("fold (K17): a repeat is ignored; another base, an older epoch's mirror and a new epoch's first change are gaps, " ..
	"and changes wait for a full", function()
	local d = core.data()
	core.fold(d, { v = 4, r = { item = { "a", 1 } } }, "E", Q)
	t.expect_eq(core.fold(d, { v = 4, base = 3, r = { item = { "a", 7 } } }, "E", Q), "repeat")
	t.expect_true(show(d.far.r) == "a=1" and not d.gap, "a repeat changes nothing and is no gap")
	t.expect_eq(core.fold(d, { v = 6, base = 5, r = { item = { "a", 7 } } }, "E", Q), "gap", "another base")
	t.expect_eq(core.fold(d, { v = 5, base = 4, r = { item = { "a", 8 } } }, "E", Q), "gap", "ignored until a full")
	t.expect_eq(show(d.far.r), "a=1")
	t.expect_eq(core.fold(d, { v = 6, r = { item = { "a", 7 } } }, "E", Q), "full")
	t.expect_eq(core.fold(d, { v = 7, base = 6, r = { item = { "a", 8 } } }, "E2", Q), "gap", "a mirror from an older epoch")
	t.expect_eq(core.fold(core.data(), { v = 1, base = 0 }, "E", Q), "gap", "a new epoch's first status isn't a full")
end)

t.test("validation at the fold (§8.5, K8): malformed entries are dropped and counted, the rest apply; the mirror keeps " ..
	"2,000 a colour", function()
	local d = core.data()
	local result, bad = core.fold(d, { v = 1, r = {
		item = { "a", 1, "b", 1.5, "c", 2147483648, 7, 4 }, -- not an integer; out of range; not a string name
		["item|legendary"] = { "a", 1 }, -- a quality Q refuses
		nope = { "x", 1 }, -- not a signal type
		fluid = { "w" }, -- an odd list
	} }, "E", Q)
	t.expect_true(result == "full" and bad == 6, "six dropped: " .. tostring(bad))
	t.expect_eq(show(d.far.r), "a=1")
	t.expect_eq(core.fold(d, { v = "x" }, "E", Q), "malformed")
	local list = {}
	for i = 1, 2001 do
		list[2 * i - 1], list[2 * i] = "s" .. i, i
	end
	local e = core.data()
	local _, over = core.fold(e, { v = 1, r = { item = list } }, "E", Q)
	t.expect_true(over == 1 and e.nfar.r == 2000, "2,000 kept")
end)

t.test("the cap (K8) in one change: a change that removes a key and adds one at 2,000 keeps the addition", function()
	local d = core.data()
	local list = {}
	for i = 1, 2000 do
		list[2 * i - 1], list[2 * i] = "s" .. i, i
	end
	core.fold(d, { v = 1, r = { item = list } }, "E", Q)
	-- the sender's order: the addition before the removal
	local result, bad = core.fold(d, { v = 2, base = 1, r = { item = { "new", 5, "s1", 0 } } }, "E", Q)
	t.expect_true(result == "change" and bad == 0, "nothing dropped: " .. tostring(bad))
	t.expect_true(core.get(d.far.r, "item", "normal", "new") == 5 and d.nfar.r == 2000, "the addition kept, 2,000")
end)

t.test("the cap (K8) in one full: sets and clears of a full at 2,000 never take a slot past 2,000", function()
	local d = core.data()
	local function full(v, from, to)
		local list = {}
		for i = from, to do
			list[#list + 1], list[#list + 2] = "s" .. i, i
		end
		core.fold(d, { v = v, r = { item = list } }, "E", Q)
	end
	local top = 0
	local set = function(i) top = math.max(top, i) end
	full(1, 1, 2000)
	core.write(d, "r", 5000, true, yes, set, noop)
	full(2, 1001, 3000) -- 1,000 leave, 1,000 arrive
	core.write(d, "r", 5000, true, yes, set, noop)
	t.expect_true(top == 2000 and d.top.r == 2000 and d.ninj.r == 2000, "no slot past 2,000: " .. top)
end)

t.test("validation at the write (§8.5): an unknown name is dropped from the mirror and never injected; a full equal to " ..
	"the mirror checks no names", function()
	local d = core.data()
	local checked = {}
	local valid = function(_, _, n)
		checked[#checked + 1] = n
		return n ~= "nope"
	end
	core.fold(d, { v = 1, r = { item = { "iron-plate", 2, "nope", 3 } } }, "E", Q)
	t.expect_eq(core.write(d, "r", 300, true, valid, noop, noop), 1)
	t.expect_true(show(d.inj.r) == "iron-plate=2" and show(d.far.r) == "iron-plate=2" and d.nfar.r == 1,
		"nope never injected, and it left the mirror")
	checked = {}
	core.fold(d, { v = 2, r = { item = { "iron-plate", 2 } } }, "E", Q)
	t.expect_eq(core.write(d, "r", 300, true, valid, noop, noop), 0)
	t.expect_eq(#checked, 0, "no name checked")
end)

t.test("slots (K5): a new signal takes a freed slot before a new one; a cleared signal frees its slot; slots stay " ..
	"within the peak; a reset (FC4) empties everything", function()
	local d = core.data()
	local ops = {}
	local set = function(i, _, _, n, c) ops[#ops + 1] = "set " .. i .. " " .. n .. "=" .. c end
	local clear = function(i) ops[#ops + 1] = "clear " .. i end
	core.fold(d, { v = 1, r = { item = { "a", 1, "b", 1, "c", 1 } } }, "E", Q)
	core.write(d, "r", 300, true, yes, set, clear)
	t.expect_true(d.top.r == 3 and d.ninj.r == 3 and #ops == 3, "three slots")
	local sb = core.get(d.slot.r, "item", "normal", "b")
	core.fold(d, { v = 2, base = 1, r = { item = { "b", 0 } } }, "E", Q)
	ops = {}
	t.expect_eq(core.write(d, "r", 300, true, yes, set, clear), 1)
	t.expect_same(ops, { "clear " .. sb })
	t.expect_same(d.free.r, { sb })
	core.fold(d, { v = 3, base = 2, r = { item = { "d", 4 } } }, "E", Q)
	ops = {}
	core.write(d, "r", 300, true, yes, set, clear)
	t.expect_same(ops, { "set " .. sb .. " d=4" }, "the freed slot first")
	t.expect_true(d.top.r == 3 and d.ninj.r == 3 and #d.free.r == 0, "never past the peak of three")
	core.reset(d)
	t.expect_true(next(d.slot.r) == nil and next(d.free.r) == nil and d.top.r == 0 and next(d.inj.r) == nil
		and d.ninj.r == 0 and next(d.far.r) == nil and next(d.todo.r) == nil and d.far_v == nil, "reset")
	t.expect_eq(d.v, 0, "out and v, this side's own, stay")
end)

t.test("budget (K16): two links of 400 slots write 300, then 300, then 200; a signal at its target costs no slot", function()
	local function link(prefix)
		local d = core.data()
		for i = 1, 400 do
			core.put(d.far.r, "item", "normal", prefix .. i, i)
		end
		core.mark_all(d.todo.r, d.far.r)
		return d
	end
	local set = { a = link("a"), b = link("b") }
	local step = function(d, left)
		return core.write(d, "r", left, true, yes, noop, noop), next(d.todo.r) == nil
	end
	local per = {}
	for k = 1, 4 do
		per[k] = core.drain(set, 300, step)
	end
	t.expect_same(per, { 300, 300, 200, 0 })
	t.expect_eq(next(set), nil, "both links left the set when done")
	local d = core.data()
	core.fold(d, { v = 1, r = { item = { "a", 1 } } }, "E", Q)
	core.write(d, "r", 300, true, yes, noop, noop)
	core.put(d.todo.r, "item", "normal", "a", true)
	t.expect_eq(core.write(d, "r", 300, true, yes, noop, noop), 0, "already at its target")
end)

t.test("write: a quiet colour targets nothing, so every injected signal is cleared and the mirror stays", function()
	local d = core.data()
	core.fold(d, { v = 1, r = { item = { "a", 1, "b", 2 } } }, "E", Q)
	core.write(d, "r", 300, true, yes, noop, noop)
	core.mark_all(d.todo.r, d.far.r) -- as the poll does when the carry flips (§7.5 step 9)
	core.mark_all(d.todo.r, d.inj.r)
	local cleared = 0
	t.expect_eq(core.write(d, "r", 300, false, yes, noop, function() cleared = cleared + 1 end), 2)
	t.expect_true(cleared == 2 and next(d.inj.r) == nil and d.ninj.r == 0, "both cleared")
	t.expect_eq(show(d.far.r), "a=1,b=2", "the mirror stays, for when it carries again")
end)

--- One side's links for b′: cids ascending, network ids (nil: a pole with no network of the colour), all ready.
local function links(cids, ids)
	local out = {}
	for i, cid in ipairs(cids) do
		out[i] = { cid = cid, pole = true, ir = ids[i], arc = true }
	end
	return out
end

--- Both sides' carry sets for one of spike 9c's layouts (links c1–c4): X's view and Y's, as "1000"-style strings.
local function carries(xids, yids)
	local cids = { "c1", "c2", "c3", "c4" }
	local x, y, s = links(cids, xids), links(cids, yids), {}
	core.group(x, 4, "ir", "gr", s)
	core.group(y, 4, "ir", "gr", s)
	for i = 1, 4 do
		x[i].fr, y[i].fr = y[i].gr, x[i].gr
	end
	core.forest(x, 4, "gr", "fr", "cr", s)
	core.forest(y, 4, "gr", "fr", "cr", s)
	local function str(l)
		local out = {}
		for i = 1, 4 do
			out[i] = l[i].cr and "1" or "0"
		end
		return table.concat(out)
	end
	return str(x), str(y)
end

t.test("b′ groups (§7.7): the lowest cid on a network in string order; a pole with no network is its own group; no " ..
	"pole, no group (§6.5)", function()
	local l = {
		{ cid = "c10", pole = true, ir = 5 }, { cid = "c2", pole = true, ir = 5 }, { cid = "c3", pole = true },
		{ cid = "c9", pole = true, ir = 5 }, { cid = "c99", pole = false, ir = 5 },
	}
	core.group(l, 5, "ir", "gr", {})
	t.expect_same({ l[1].gr, l[2].gr, l[3].gr, l[4].gr }, { "c10", "c10", "c3", "c10" }, "\"c10\" sorts before \"c9\"")
	t.expect_eq(l[5].gr, nil)
end)

t.test("b′ forest (§7.7): spike 9c's layouts give its final carry sets, and both sides agree [S9c Q2]", function()
	local function both(xids, yids, want, what)
		local x, y = carries(xids, yids)
		t.expect_true(x == want and y == want, what .. ": x " .. x .. ", y " .. y .. ", want " .. want)
	end
	both({ 1, 1, 1, 1 }, { 2, 2, 2, 2 }, "1000", "parallel")
	both({ 1, 1, 1, 1 }, { nil, nil, 7, nil }, "1111", "asym (the review's C-1)")
	both({ 1, 1, 1, 1 }, { 3, 4, 5, 6 }, "1111", "asym-sep")
	both({ 1, 1, 2, 2 }, { 3, 4, 3, 4 }, "1110", "cross: a 4-cycle on one edge")
end)

t.test("b′ forest: a link without its partner's group, or with an end not ready, is left out", function()
	local x = { { cid = "c1", arc = true, gr = "c1" }, { cid = "c2", arc = true, gr = "c1", fr = "c1" } }
	core.forest(x, 2, "gr", "fr", "cr", {})
	t.expect_true(not x[1].cr and x[2].cr, "c1 has no partner group yet, so c2 carries")
	x[2].arc = false
	core.forest(x, 2, "gr", "fr", "cr", {})
	t.expect_true(not x[1].cr and not x[2].cr, "c2's far end isn't ready: neither carries")
end)

t.test("b′ (Review Focus 4): a far group this side doesn't list is one more far network: no error, and the sides agree",
	function()
		-- y still lists c5 (closing on x's side, or not yet removed): its groups name c5, which x has no link for
		local x = { { cid = "c1", arc = true, gr = "c1", fr = "c5" }, { cid = "c2", arc = true, gr = "c1", fr = "c5" } }
		local y = { { cid = "c1", arc = true, gr = "c5", fr = "c1" }, { cid = "c2", arc = true, gr = "c5", fr = "c1" } }
		local s = {}
		core.forest(x, 2, "gr", "fr", "cr", s)
		core.forest(y, 2, "gr", "fr", "cr", s)
		t.expect_true(x[1].cr and not x[2].cr and y[1].cr and not y[2].cr, "c1 carries on both sides; c2 is quiet")
	end)

t.test("b′ cache (K15): one computation for a side's n links gives each link what computing for it alone would", function()
	local xids, yids = { 1, 1, 2, 2 }, { 3, 4, 3, 4 }
	local bx = carries(xids, yids)
	for i = 1, 4 do
		local alone = carries(xids, yids) -- a fresh computation, read for link i only
		t.expect_eq(string.sub(alone, i, i), string.sub(bx, i, i), "link c" .. i)
	end
end)

t.test("K8: within both caps the maps come back as they are; past 2,000 the fixed order keeps the first 2,000; past " ..
	"180,000 bytes red's entries come first and the rest stop; a status of spike 9d's size fits", function()
	local function many(n, width, base)
		local m = {}
		for i = 1, n do
			core.put(m, "item", "normal", string.format("%0" .. width .. "d", i), base + i)
		end
		return m
	end
	local r, g = many(10, 8, 0), many(10, 8, 0)
	local kr, kg, dr, dg = core.fit(r, g)
	t.expect_true(kr == r and kg == g and dr == 0 and dg == 0, "untouched, the same tables")
	local big = many(2001, 8, 0)
	core.put(big, "fluid", "normal", "water", 5) -- "fluid" sorts before "item"
	kr, kg, dr, dg = core.fit(big, {})
	t.expect_true(core.size(kr) == 2000 and next(kg) == nil and dr == 2 and dg == 0, "2,000 kept of 2,002")
	t.expect_true(core.get(kr, "fluid", "normal", "water") == 5 and core.get(kr, "item", "normal", "00001999") == 1999
		and core.get(kr, "item", "normal", "00002000") == nil, "in type, quality, name order")
	kr, kg, dr, dg = core.fit(many(2000, 60, 1000000), many(2000, 60, 1000000))
	-- 71 bytes an entry: red's 142,000 fit; green gets the 38,000 left, 535 entries, and stops
	t.expect_true(core.size(kr) == 2000 and dr == 0 and core.size(kg) == 535 and dg == 1465,
		"the byte cap: " .. dr .. ", " .. dg)
	local _, _, sr, sg = core.fit(many(2000, 16, 10000), many(2000, 16, 20000)) -- 100,000 bytes, as spike 9d's 98,129
	t.expect_true(sr == 0 and sg == 0, "spike 9d's 2,000 × 2 fits")
	r, g = many(2000, 32, 0), many(2000, 32, 0) -- 157,786 bytes in all; the no-tostring bound says 188,000
	kr, kg, dr, dg = core.fit(r, g)
	t.expect_true(kr == r and kg == g and dr == 0 and dg == 0, "past the bound but within the cap: untouched")
end)
