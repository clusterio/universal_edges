-- Crossings (SP3 spec §9, §10.3), pure: past-the-line tests, mirrored points and orientations, and the arrival box.
-- A frame is SP1 §8's { origin, facing, length }; F10 gives the partner side's.
local geometry = require("modules/universal_edges/edges/geometry_core")

--- PAST: v1's threshold. FAR: the barriers' far side (SP1 §9); nothing lies beyond it in a real world, and a point that
--- far out belongs to some other side's ground (plan ruling 12).
local core = { PAST = 0.5, FAR = geometry.DEPTH + geometry.SIZE / 2 }

local function past(y)
	return y < -core.PAST and y > -core.FAR
end

--- A player at world (wx, wy) is past the side's line by 0.5, within the edge's [0, L) (§9 step 1).
function core.player_past(frame, wx, wy)
	local x, y = geometry.to_local(frame, wx, wy)
	return past(y) and x >= 0 and x < frame.length
end

--- A vehicle is past the line within the edge's [0, L), or beyond an end by more than PAST, up to the barrier margin:
--- a corner vehicle crosses only once it is past both lines, so it reaches the middle tile past that tile's second line
--- (§10.3; review I1: one within 0.5 of the second line would land frozen just short of it).
function core.vehicle_past(frame, wx, wy)
	local x, y = geometry.to_local(frame, wx, wy)
	local L, M = frame.length, geometry.MARGIN
	return past(y) and ((x >= 0 and x < L) or (x >= -M and x < -core.PAST) or (x >= L + core.PAST and x < L + M))
end

--- Within the edge's [0, L): a rider's crossing goes to this edge's partner; beyond its ends, a zone hook decides (crossing spec §7.3).
function core.within(frame, wx, wy)
	local x = geometry.to_local(frame, wx, wy)
	return x >= 0 and x < frame.length
end

--- A world point on this side (frame mine) as the partner's world point (frame theirs, F10).
function core.mirror(mine, theirs, wx, wy)
	local x, y = geometry.to_local(mine, wx, wy)
	return geometry.to_world(theirs, geometry.flip(mine.length, x, y))
end

--- The world box within 8 of (wx, wy) and at least 0.5 inside the side's line, where a crossing player or a vehicle is
--- placed (crossing spec §6.2, SP3 §10.4). find_non_colliding_position_in_box picks a free spot near its centre, so an
--- arrival lands about 4 to 5 tiles inside, not at the mirrored point itself. Empty in y when the point lies more than 8.5 outside.
function core.arrival_box(frame, wx, wy)
	local x, y = geometry.to_local(frame, wx, wy)
	return geometry.area_to_world(frame, x - 8, math.max(y - 8, 0.5), x + 8, math.max(y + 8, 0.5))
end

--- A player's edge zone holds (crossing spec §3.1): past the line by more than 0 (the 0.5 band past PAST), short of FAR,
--- within [-0.5, L + 0.5).
function core.player_stays(frame, wx, wy)
	local x, y = geometry.to_local(frame, wx, wy)
	return y < 0 and y > -core.FAR and x >= -0.5 and x < frame.length + 0.5
end

--- Where a point of this side's world lands inside it (crossing spec §6.2): at least 0.5 inside the line and within
--- [0.5, L - 0.5] along it; nil when it is FAR or more out from the line, or FAR or more past either end.
function core.inside_point(frame, wx, wy)
	local x, y = geometry.to_local(frame, wx, wy)
	local L = frame.length
	if y <= -core.FAR or x <= -core.FAR or x >= L + core.FAR then
		return nil
	end
	return geometry.to_world(frame, math.min(math.max(x, 0.5), L - 0.5), math.max(y, 0.5))
end

return core
