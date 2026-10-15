-- The balance rule (SP3 spec §8.1, D14) and the power link's buffer (§8.2, D34), pure. Amounts are in a link's units:
-- kJ for power, fluid units for fluids.
local core = { B_MIN = 10e6, B_MAX = 10e9 } -- D37: at most 10 GJ a side, about 5 GW a link

--- What one link sends this visit (§8.1): PR #7's target (A + ap) / (C + cp) × C, the excess over it times the link's
--- share of its side (link / links, links defaulting to C), at most the partner's room, floored. 0 when a capacity is 0.
--- (The room is not scaled by this side's share, as §8.1 has it: with a large accumulator bank beside a small interface
--- that product throttles the link to nothing, and a credit takes only what fits anyway. Plan ruling 18.) Power passes
--- links, its pool's link interfaces only (playtest 2026-10-12 #8): over C, which counts the accumulators, a sole link
--- beside 800 MJ of them sent a tenth of the excess, and a side with no storage of its own blacked out at every burst.
function core.amount(A, C, ap, cp, link, links)
	if C <= 0 or cp <= 0 then
		return 0
	end
	local share = math.min(1, link / (links or C))
	local target = (A + ap) / (C + cp) * C
	return math.max(0, math.floor(math.min(math.max(0, A - target) * share, math.max(0, cp - ap))))
end

--- The partner's amount as this link should see it (plan ruling 2): its status's a, plus what this link sent that the
--- status hadn't counted (status.r is the partner's credited total when it was made), at most its capacity. With an
--- age (ticks since the status arrived) and a status.d (J a poll: power only), less the partner's drain for that age:
--- the status was made before our last credit landed, and the partner burnt it since (F-PW2).
function core.partner(status, sent, age)
	local a = status.a + math.max(0, sent - (status.r or 0))
	if age and type(status.d) == "number" then
		a = math.max(0, a - status.d / 1000 * age / 60)
	end
	return math.min(a, status.c)
end

--- Whether a partner's status shows room for a remainder it refused (final fix wave addendum): at least c/64 free. A
--- side re-announces its status when its amount moves by c/64, so a status stale by less than that still means room,
--- and a re-offer it prompts takes something. Less room than that can't be told from full: the lane's backoff waits.
function core.has_room(status)
	return status.c - status.a >= status.c / 64
end

--- D34 (plan ruling 18): the interface's next buffer size, from its size B, its energy E, the flow f to carry per
--- poll, and whether the link is holding a side back. 4f: an exchange carries about B / 2, so 4f carries two periods
--- (§8.2's headroom 2 assumed it carried B). Doubled while held back. Within [10 MJ, 10 GJ] (D37); shrunk only below B / 4,
--- and never below E, which a smaller buffer would destroy. Not shrunk while keep: an empty interface with the partner
--- holding energy to send (core.starving) read empty because the link is short, so its flow is not demand (F-PW).
function core.buffer(B, E, f, held, keep)
	local want = 4 * f
	if held then
		want = math.max(want, 2 * B)
	end
	want = math.min(math.max(want, core.B_MIN), core.B_MAX)
	if want > B then
		return want
	end
	if want < B / 4 and not keep then
		return math.max(want, E)
	end
	return B
end

--- D34 at each poll (plan ruling 18). A side's demand is what the network drew from its storage (accumulators and
--- interface, J) since the last poll, the links' own moves aside: drain = a_last - A + 1000 × moved, with a_last the
--- storage's energy after the last poll's writes (its send included) and moved the kJ the links on that storage put
--- into it since (credits positive, sends negative; every link interface on the network is storage, §8.2). A side that
--- sent at its last poll feeds the link, and its drain is 0: the link carries the partner's, and a parallel link's sends from
--- the same network would read as this one's drain and grow both without end (review I2). Both sides size for the
--- larger drain of the two (the partner's comes in its status, theirs = { d, dry }) and double while either was
--- starved, a flag the credit latches (core.starving) and the poll clears. since is the ticks since the buffer last grew
--- (nil: never): within HOLD it doesn't shrink, so it stays sized for the last peak (playtest 2026-10-12 #8: shrunk to the
--- average flow after each starve, it was empty again by the next burst). Returns the next B and this side's drain.
core.HOLD = 18000
function core.size(B, E, A, a_last, moved, theirs, starved, fed, since)
	local drain = fed and 0 or math.max(0, a_last - A + 1000 * moved)
	local f = math.max(drain, theirs and type(theirs.d) == "number" and theirs.d or 0)
	local keep = (since ~= nil and since < core.HOLD) or core.starving(E, B, theirs)
	return core.buffer(B, E, f, starved or (theirs ~= nil and theirs.dry == true), keep), drain
end

--- The credit's latch (review C1), tested before the credit adds: this side was nearly empty (1 % of C) when energy
--- arrived while its partner, by its status, had an eighth of its capacity to send: the link, not the source, was short.
--- Sampled at every credit, not at a poll whose phase against the partner's nobody controls.
function core.starving(A, C, theirs)
	return A <= 0.01 * C and theirs ~= nil and type(theirs.a) == "number" and type(theirs.c) == "number"
		and theirs.a >= theirs.c / 8
end

--- Spike 22: this tick's step of a send's debt (J, the pool's unit): the debt over the ticks left to its due tick (the
--- whole of it once due), at most what the pool holds; a shortfall stays as debt for the next tick.
function core.drain_step(debt, due, tick, available)
	return math.max(0, math.min(debt / math.max(1, due - tick), available))
end

--- §8.2: a new total A2 written back at one fill ratio: the accumulators' part and the interface's part.
function core.split(A2, c_acc, B)
	local C = c_acc + B
	return A2 * c_acc / C, A2 * B / C
end

return core
