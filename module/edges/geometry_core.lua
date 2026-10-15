-- Edge geometry (SP1 spec §8), pure: frames, rotation, flip, connector columns and barrier centres. It runs on lua5.2
-- and returns several values instead of tables, so nothing allocates on hot paths.
-- A frame is { origin = { ox, oy }, facing, length }: the map turned so the side faces north, with local +x along the
-- edge from the origin (to the right when facing out), +y inward and -y outward. facing is the outward normal.
local core = {}

core.DEPTH, core.SIZE, core.OVERLAP, core.MARGIN = 16, 20, 1, 32

--- Turn (x, y) clockwise on the map by d, in 16ths of a turn (0, 4, 8 or 12); +x is east and +y is south.
function core.rot(x, y, d)
	if d == 0 then
		return x, y
	elseif d == 4 then
		return -y, x
	elseif d == 8 then
		return -x, -y
	elseif d == 12 then
		return y, -x
	end
	error("direction must be 0, 4, 8 or 12, got " .. tostring(d))
end

function core.to_world(f, x, y)
	local rx, ry = core.rot(x, y, f.facing)
	return f.origin[1] + rx, f.origin[2] + ry
end

function core.to_local(f, wx, wy)
	return core.rot(wx - f.origin[1], wy - f.origin[2], (16 - f.facing) % 16)
end

function core.dir_to_world(f, d)
	return (d + f.facing) % 16
end

function core.dir_to_local(f, d)
	return (d - f.facing) % 16
end

--- Side a's local point as side b's, and back: the two frames face each other, for any pair of facings.
function core.flip(L, x, y)
	return L - x, -y
end

function core.flip_dir(d)
	return (d + 8) % 16
end

--- The local column of a connector's lowest tile on side me ("a" or "b"); its own inverse for a fixed width.
function core.col(me, L, pos, w)
	if me == "a" then
		return pos
	end
	return L - pos - w
end

--- The world box of a local box, with min and max re-normalised.
function core.area_to_world(f, x1, y1, x2, y2)
	local ax, ay = core.to_world(f, x1, y1)
	local bx, by = core.to_world(f, x2, y2)
	return math.min(ax, bx), math.min(ay, by), math.max(ax, bx), math.max(ay, by)
end

--- True when fb is fa seen from the other side: same length, opposite facing, and fb's origin at fa's far end.
function core.coincident(fa, fb)
	local dx, dy = core.rot(1, 0, fa.facing)
	return fa.length == fb.length and fb.facing == (fa.facing + 8) % 16
		and fb.origin[1] == fa.origin[1] + fa.length * dx and fb.origin[2] == fa.origin[2] + fa.length * dy
end

--- How many barriers cover a side of length L: x in [-MARGIN, L + MARGIN], SIZE-wide, overlapping by OVERLAP (§9).
function core.barrier_count(L)
	return math.ceil((L + 2 * core.MARGIN - core.SIZE) / (core.SIZE - core.OVERLAP)) + 1
end

--- The local centre of barrier k (0-based): DEPTH tiles outside, along the edge from -MARGIN.
function core.barrier_centre(k)
	return -core.MARGIN + core.SIZE / 2 + k * (core.SIZE - core.OVERLAP), -core.DEPTH
end

return core
