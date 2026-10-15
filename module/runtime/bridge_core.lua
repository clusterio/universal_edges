-- Pure logic of the message bridge (spec §7.3): the outbound queue, splitting a flush under the soft limit, and
-- checking an inbound batch, which is untrusted input.
local dedup = require("modules/universal_edges/runtime/dedup_core")

local core = {}

-- Bytes around one flush's messages, {"tick":<n>,"msgs":[...]}, rounded up.
local ENVELOPE = 32

function core.count(counters, kind, n)
	counters[kind] = (counters[kind] or 0) + (n or 1)
end

--- Append { type, payload } to a channel's queue; false when it is at cap. Ids are minted at flush.
function core.enqueue(queue, msg_type, payload, cap)
	if type(msg_type) ~= "string" or type(payload) ~= "table" then
		error("bridge send needs a type string and a payload table")
	end
	if #queue >= cap then
		return false
	end
	queue[#queue + 1] = { type = msg_type, payload = payload }
	return true
end

--- Group msgs into batches whose JSON, estimated with size_of(msg), stays under limit. A message bigger than the
--- limit goes in a batch of its own; Clusterio then sends it through a file (api.lua:33-41).
function core.split(msgs, size_of, limit)
	local batches, current, size = {}, {}, ENVELOPE
	for _, msg in ipairs(msgs) do
		local bytes = size_of(msg) + 1
		if #current > 0 and size + bytes > limit then
			batches[#batches + 1] = current
			current, size = {}, ENVELOPE
		end
		current[#current + 1] = msg
		size = size + bytes
	end
	if #current > 0 then
		batches[#batches + 1] = current
	end
	return batches
end

--- One batch's JSON, { tick, msgs }, from its messages' own JSON, so the flush encodes each message once (final review
--- I3). split's ENVELOPE covers the bytes around the parts for ticks of up to 14 digits.
function core.batch(tick, parts)
	return '{"tick":' .. tick .. ',"msgs":[' .. table.concat(parts, ",") .. "]}"
end

--- The well-formed, first-seen messages of an inbound batch. Everything else is only counted: rejects (a malformed
--- batch or message) and repeats (an id already seen from that sender).
function core.accept(batch, seen, tick, counters)
	local accepted = {}
	if type(batch) ~= "table" then
		core.count(counters, "rejects")
		return accepted
	end
	local n = 0
	for _ in pairs(batch) do
		n = n + 1
	end
	if n ~= #batch then
		core.count(counters, "rejects")
		return accepted
	end
	for _, msg in ipairs(batch) do
		if type(msg) ~= "table" or type(msg.type) ~= "string" or type(msg.payload) ~= "table" or not dedup.sender(msg.id) then
			core.count(counters, "rejects")
		elseif dedup.first_seen(seen, msg.id, tick) then
			accepted[#accepted + 1] = msg
		else
			core.count(counters, "repeats")
		end
	end
	return accepted
end

return core
