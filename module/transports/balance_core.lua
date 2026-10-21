-- The balance rule (SP3 spec §8.1), pure, for fluids; power left it for the power hub (power hub spec §9). Amounts are in fluid units.
local core = {}

--- What one link sends this visit (§8.1; only fluids call it now): PR #7's target (A + ap) / (C + cp) × C, the excess over it times
--- the link's share of its side (link / links, links defaulting to C), at most the partner's room, floored. 0 when a capacity is 0.
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
--- status hadn't counted (status.r is the partner's credited total when it was made), at most its capacity.
function core.partner(status, sent)
	return math.min(status.a + math.max(0, sent - (status.r or 0)), status.c)
end

--- Whether a partner's status shows room for a remainder it refused (final fix wave addendum): at least c/64 free. A
--- side re-announces its status when its amount moves by c/64, so a status stale by less than that still means room,
--- and a re-offer it prompts takes something. Less room than that can't be told from full: the lane's backoff waits.
function core.has_room(status)
	return status.c - status.a >= status.c / 64
end

return core
