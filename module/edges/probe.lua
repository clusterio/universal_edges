-- The probe connector type (SP1 spec §10.6): built in, inert and never detected; a control request adds one, for example
-- `connector add <edge> probe <pos> --params '{"dir":"ab","kind":"stream"}'`. The reference transport for the tests:
-- a stream of plain stock, or unique tokens in hold mode. params.cap caps a destination's stream credit; params.busy
-- and params.reject, or ue_rt.probe_set, force those unique outcomes.
--
-- Its tallies live in storage.universal_edges.probes[<edge>/<cid>], not in ep.data, so ue_rt.probe_state still reads
-- them after the endpoint has closed and gone: a test sees where every item and token ended up. They roll back with
-- the world, as ep.data would. A key is never reused: cids come from the controller's global counter (SP1 spec §5.1).
local connectors = require("modules/universal_edges/edges/connectors")

local probe = {}
local KEY, BATCH = "probe", 100

local function outbound(ep)
	return (ep.params.dir == "ab") == (ep.me == "a")
end

--- The tally of endpoint key, created on first use.
local function tally(key)
	local s = storage.universal_edges
	s.probes = s.probes or {}
	local t = s.probes[key]
	if not t then
		t = { stock = 0, tokens = {}, received = {}, received_items = 0, refunded = 0 }
		s.probes[key] = t
	end
	return t
end

--- A token's padding: n pseudo-random base64 characters from its id, so a padded token deflates to a big body, and
--- the same token always encodes to the same bytes.
local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function padding(id, n)
	local s, out = 7, {}
	for i = 1, #id do
		s = (s * 31 + string.byte(id, i)) % 2147483648
	end
	for i = 1, n do
		s = (s * 1103515245 + 12345) % 2147483648
		local c = math.floor(s / 65536) % 64 + 1
		out[i] = string.sub(ALPHABET, c, c)
	end
	return table.concat(out)
end

connectors.register_type{
	name = "probe",
	lanes = function(params)
		return { [params.dir] = params.kind }
	end,
	validate = function(params)
		if type(params) ~= "table" or (params.dir ~= "ab" and params.dir ~= "ba")
			or (params.kind ~= "stream" and params.kind ~= "unique") then
			return false, "probe params need dir = ab|ba and kind = stream|unique"
		end
		return true
	end,
	schedule = { per_tick = 4, interval = 10 },
	build = function(ep)
		tally(ep.key)
		return "ready"
	end,
	teardown = function() end,
	--- A source sends min(stock, 100), or its first token, whenever it can; a stream destination with a cap announces
	--- how much it can still take, only when that changes.
	poll = function(ep)
		local p, t = ep.params, tally(ep.key)
		if not outbound(ep) then
			if p.kind == "stream" and type(p.cap) == "number" then
				local free = math.max(0, p.cap - t.received_items)
				if not (ep.status and ep.status.free == free) then
					ep:set_status({ free = free })
				end
			end
			return
		end
		if not ep:can_send(p.dir) then
			return
		end
		if p.kind == "stream" then
			local n = math.min(t.stock, BATCH)
			local free = ep.partner.status and ep.partner.status.free
			if type(free) == "number" then
				n = math.min(n, free - ((ep:pending(p.dir) or {})[KEY] or 0))
			end
			if n > 0 then
				t.stock = t.stock - n
				ep:send(p.dir, { [KEY] = n })
			end
		elseif t.tokens[1] and not t.tokens[1].held then
			local token = t.tokens[1]
			token.held = true -- hold mode: it stays here until commit or restore
			ep:send(p.dir, { id = token.id, pad = token.pad })
		end
	end,
	credit = function(ep, _, payload)
		local p, t = ep.params, tally(ep.key)
		if p.kind == "stream" then
			local n = payload[KEY] or 0
			if type(p.cap) == "number" then
				n = math.min(n, math.max(0, p.cap - t.received_items))
			end
			t.received_items = t.received_items + n
			return { [KEY] = n }
		end
		if p.busy or t.busy then
			return "busy"
		end
		if p.reject or t.reject then
			return "reject"
		end
		t.received[#t.received + 1] = payload
		return "ok"
	end,
	commit = function(ep)
		table.remove(tally(ep.key).tokens, 1) -- the held token: one in flight at a time
	end,
	restore = function(ep, _, _, payload)
		local tokens = tally(ep.key).tokens
		local first = tokens[1]
		if first and first.held and first.id == payload.id then
			first.held = nil
		else
			table.insert(tokens, 1, { id = payload.id, pad = payload.pad })
		end
		return true
	end,
	refund = function(ep, _, bag)
		local t = tally(ep.key)
		t.stock = t.stock + (bag[KEY] or 0)
		t.refunded = t.refunded + (bag[KEY] or 0)
		return true
	end,
}

--- This instance's probe endpoint of (edge, cid), or nil once it has closed; errors when it never was a probe.
local function endpoint(edge, cid)
	local side = storage.universal_edges.edges[edge]
	local ep = side and connectors.get(side, cid)
	local key = edge .. "/" .. cid
	if ep and ep.type ~= "probe" then
		error("endpoint " .. key .. " is not a probe")
	end
	if not ep and not (storage.universal_edges.probes or {})[key] then
		error("no probe " .. key .. " on this instance")
	end
	return ep, key
end

--- ue_rt.probe_add(edge, cid, what): stock (a number), or a token { id, pad = <characters> } as a table or JSON.
function probe.add(edge, cid, what)
	local t = tally(select(2, endpoint(edge, cid)))
	if type(what) == "number" then
		t.stock = t.stock + what
		return
	end
	local token = type(what) == "string" and helpers.json_to_table(what) or what
	if type(token) ~= "table" or type(token.id) ~= "string" then
		error("ue_rt.probe_add needs a number or a token with a string id")
	end
	t.tokens[#t.tokens + 1] = { id = token.id, pad = token.pad and padding(token.id, token.pad) or nil }
end

--- ue_rt.probe_set(edge, cid, '{"busy":true}'): switch a destination's forced busy or reject on or off.
function probe.set(edge, cid, json)
	local t = tally(select(2, endpoint(edge, cid)))
	local flags = type(json) == "string" and helpers.json_to_table(json) or json
	if type(flags) ~= "table" then
		error("ue_rt.probe_set needs a table or JSON of busy and reject")
	end
	t.busy, t.reject = flags.busy == true or nil, flags.reject == true or nil
end

--- ue_rt.probe_state(edge, cid): JSON of the tally, and while the endpoint lives, its state, partner and ledgers.
function probe.state(edge, cid)
	local ep, key = endpoint(edge, cid)
	local t = tally(key)
	local tokens, got = {}, {}
	for i, token in ipairs(t.tokens) do
		tokens[i] = token.id
	end
	for i, token in ipairs(t.received) do
		got[i] = token.id
	end
	local state = { stock = t.stock, received_items = t.received_items, refunded = t.refunded, tokens = tokens,
		received = got, gone = ep == nil, lanes = {} }
	if ep then
		state.state, state.closing = ep.state, ep.closing or false
		state.partner = ep.partner and ep.partner.state
		for _, set in ipairs({ ep.tx, ep.rx }) do
			for dir, lane in pairs(set) do
				state.lanes[dir] = { kind = lane.kind, role = lane.role, sent = lane.sent, acked = lane.acked,
					recv = lane.recv, w = lane.w, inflight = lane.inflight and lane.inflight.seq, next_seq = lane.next_seq,
					closing = lane.closing ~= nil }
			end
		end
	end
	return helpers.table_to_json(state)
end

return probe
