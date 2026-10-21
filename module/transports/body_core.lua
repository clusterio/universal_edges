-- Vehicle bodies (SP3 spec §10.2, §10.4), pure parts: the body from the facts vehicle.lua read, in edge-local
-- coordinates, and where it lands on the partner. Deterministic (D21): a fixed shape, no tick, trace or id.
local geometry = require("modules/universal_edges/edges/geometry_core")

local core = {}

--- The body of a vehicle captured on side frame. f = { name, quality, type, x, y, orientation, speed, health, color?,
--- label?, state?, inventories, grid?, burning?, destinations?, patrol?, driver?, passenger? }, read by vehicle.lua; rider
--- fields are player names, carried-in ones included (§10.3). Spidertrons keep their destinations, not their speed.
function core.body(frame, f)
	local x, y = geometry.to_local(frame, f.x, f.y)
	local b = {
		v = 1, name = f.name, quality = f.quality, type = f.type, x = x, y = y, o = (f.orientation - frame.facing / 16) % 1,
		health = f.health, color = f.color, label = f.label, inv = f.inventories, grid = f.grid, burning = f.burning,
		driver = f.driver, passenger = f.passenger, state = f.state,
	}
	if f.type ~= "spider-vehicle" then
		b.speed = f.speed
	elseif f.destinations and #f.destinations > 0 then
		b.dest = {}
		for i, p in ipairs(f.destinations) do
			local dx, dy = geometry.to_local(frame, p.x, p.y)
			b.dest[i] = { dx, dy }
		end
		b.patrol = f.patrol
	end
	return b
end

--- The body's mirrored point on the destination side frame, (x, y) → (L - x, -y), its world orientation, turned with
--- it (outward on one side is inward here), and its world destinations in order. The credit looks for a free spot near
--- the point (crossing_core.arrival_box), so the vehicle lands a few tiles further in.
function core.landing(frame, body)
	local x, y = geometry.to_world(frame, geometry.flip(frame.length, body.x, body.y))
	local o = (body.o + 0.5 + frame.facing / 16) % 1
	local dest
	if body.dest then
		dest = {}
		for i, p in ipairs(body.dest) do
			local dx, dy = geometry.to_world(frame, geometry.flip(frame.length, p[1], p[2]))
			dest[i] = { x = dx, y = dy }
		end
	end
	return x, y, o, dest
end

return core
