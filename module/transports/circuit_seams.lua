-- Test seams for the circuit link (circuit-link spec §13): they ship with the module, inert unless called, as
-- train_seams.lua does. The game tests and the bench call pool directly; the E2E calls the rest through
-- ue_rt.circuit_test.
local connectors = require("modules/universal_edges/edges/connectors")
local hash = require("modules/universal_edges/runtime/scheduler_core").hash

local seams = {}
local W = { r = defines.wire_connector_id.circuit_red, g = defines.wire_connector_id.circuit_green }

local function flag(p, key)
	local ok, v = pcall(function() return p[key] end)
	return ok and v
end

--- n distinct signals a player could carry, the same list in every save with the same mods (spike 9d's pool): every
--- visible item, fluid, virtual signal (not special), recipe and entity at normal quality, then items at the other
--- qualities. Each is { type, name, quality }.
function seams.pool(n)
	local out = {}
	local function take(list, t, q, skip_special)
		for name, p in pairs(list) do
			if #out >= n then
				return
			end
			if not (flag(p, "hidden") or flag(p, "parameter") or (skip_special and p.special)) then
				out[#out + 1] = { type = t, name = name, quality = q }
			end
		end
	end
	take(prototypes.item, "item", "normal")
	take(prototypes.fluid, "fluid", "normal")
	take(prototypes.virtual_signal, "virtual", "normal", true)
	take(prototypes.recipe, "recipe", "normal")
	take(prototypes.entity, "entity", "normal")
	for q, qp in pairs(prototypes.quality) do
		if q ~= "normal" and not qp.hidden then
			take(prototypes.item, "item", q)
		end
	end
	if #out < n then
		error("circuit_seams.pool: only " .. #out .. " signals for " .. n)
	end
	return out
end

local function endpoint(edge, cid)
	local side = storage.universal_edges.edges[edge]
	local ep = side and connectors.get(side, cid)
	if not ep then
		error("ue_rt.circuit_test: no endpoint " .. tostring(edge) .. "/" .. tostring(cid))
	end
	return ep
end

--- A constant combinator holds o.signals ({ type?, name, quality?, count } each; virtual and normal by default) or, with
--- o.n, pool(o.n) at o.base + i: 1,000 a section (T2a). The radar seams use it too.
function seams.fill(comb, o)
	local filters = {}
	if o.n then
		for i, x in ipairs(seams.pool(o.n)) do
			filters[i] = { value = { type = x.type, name = x.name, quality = x.quality }, min = o.base + i }
		end
	else
		for i, x in ipairs(o.signals or {}) do
			filters[i] = { value = { type = x.type or "virtual", name = x.name, quality = x.quality or "normal" },
				min = x.count }
		end
	end
	local cb = comb.get_or_create_control_behavior()
	for i = 1, math.max(1, math.ceil(#filters / 1000), cb.sections_count) do -- 1,000 slots a section (T2a)
		local section = cb.get_section(i) or cb.add_section()
		section.multiplier = 1
		local part = {}
		for j = 1000 * (i - 1) + 1, math.min(#filters, 1000 * i) do -- lua5.2: no table.move
			part[#part + 1] = filters[j]
		end
		section.filters = part
	end
end

--- "own": the constant combinator at world (o.x, o.y), made there on first use, holds o.signals or pool(o.n) (fill), and
--- is wired to the endpoint's border pole on colour o.colour by a player's wire.
local function own(ep, o)
	local pole = ep.data.border
	local s = pole.surface
	local comb = s.find_entity("constant-combinator", { o.x, o.y })
		or s.create_entity({ name = "constant-combinator", position = { o.x, o.y }, force = pole.force })
	seams.fill(comb, o)
	comb.get_wire_connector(W[o.colour], true).connect_to(pole.get_wire_connector(W[o.colour], true), false,
		defines.wire_origin.player)
end

--- A circuit network (nil: none) as JSON { n, hash, list }: list holds the sorted "type|quality|name=count" strings
--- (left out past 40), hash is djb2 of them joined. The radar seams use it too.
function seams.describe(net)
	local list = {}
	for _, s in ipairs(net and net.signals or {}) do
		local id = s.signal
		list[#list + 1] = (id.type or "item") .. "|" .. (id.quality or "normal") .. "|" .. id.name .. "=" .. s.count
	end
	table.sort(list)
	return helpers.table_to_json({ n = #list, hash = hash(table.concat(list, ",")), list = #list <= 40 and list or nil })
end

--- "read": the endpoint's pole's network of colour o.colour (describe).
local function read(ep, o)
	return seams.describe(ep.data.border.get_circuit_network(W[o.colour]))
end

--- "state": { state, partner, v, far_v, gap, stats, last }, last being the partner's newest status: { v, base, n }.
local function state(ep)
	local d = ep.data
	local st = ep.partner and ep.partner.status
	local n = 0
	for _, c in ipairs({ "r", "g" }) do
		for _, list in pairs(st and type(st[c]) == "table" and st[c] or {}) do
			n = n + #list / 2
		end
	end
	return helpers.table_to_json({ state = ep.state, partner = ep.partner and ep.partner.state, v = d.v, far_v = d.far_v,
		gap = d.gap, stats = d.stats, last = st and { v = st.v, base = st.base, n = n } or nil })
end

--- ue_rt.circuit_test(op, edge, cid, json): "own", "read", "drop" (the endpoint drops the next status that reaches it: a
--- lost status, §13.5 step 7) or "state". Returns "ok" or JSON.
function seams.call(op, edge, cid, json)
	local o = type(json) == "string" and helpers.json_to_table(json) or {}
	local ep = endpoint(edge, cid)
	if op == "own" then
		own(ep, o)
	elseif op == "read" then
		return read(ep, o)
	elseif op == "drop" then
		local s = storage.universal_edges
		s.circuit_drop = s.circuit_drop or {} -- ponytail: a test seam's table, made on first use; production never has it
		s.circuit_drop[ep.key] = true
	elseif op == "state" then
		return state(ep)
	else
		error("ue_rt.circuit_test: unknown op " .. tostring(op))
	end
	return "ok"
end

return seams
