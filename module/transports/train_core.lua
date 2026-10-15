-- The train transport's pure rules (SP3 spec §12): v1's box geometry and the rail detection rule; Task 2 adds the
-- body, edge-record identity, restore plan and spawn plan, Task 3 the ready gate. No Factorio globals: it runs on
-- lua5.2, and train.lua passes plain values in.
local core = {}

-- v1's boxes (universal_edges/module/edge/train/train_box.lua): 55 rails in (:159); the outbound box is 20 rails (v1's
-- 12, lengthened by owner 2026-10-05). Rail i's centre is at local y = 1 - 2i, so both boxes run outward from the
-- border at y = 0.
core.OUT_RAILS, core.IN_RAILS = 20, 55
-- A train connector's columns (§5.1, owner 2026-10-05: 4, so an outbound and an inbound link fit a double track 4 tiles
-- apart); the rail's centre is col + WIDTH / 2. Links built at 6 keep their recorded width.
core.WIDTH = 4
-- The hold signal: rail 19's inward end, so the end rail (20), the trains' target, lies behind it (§12.1, D22, R8).
core.HOLD_RAIL, core.HOLD_END = 19, -36
-- The outer signal: rail 55's outward end, the very end of the inbound box.
core.OUTER_RAIL, core.OUTER_END = 55, -110
-- The hold combinator: in the signal column (the hold signal's x), one tile toward the border from the hold signal.
core.COMB_DX, core.COMB_Y = 1.5, -35.5
-- The capture search box, local x and y around the rail's centre: the outbound box plus 2 tiles inside, where the front
-- carriage's centre still is when the box signal turns red ([probe] sp3b-plan: y = 1.7).
core.AREA = { -1, -40, 1, 2 }
-- No spawned carriage reaches past this local y (Task 2's spawn plan: -6 - 94 - 3).
core.FIRST_SPAWN_LIMIT = -103
-- The box shape's number (owner 2026-10-05); older ready endpoints are rebuilt once (train.migrate).
core.SHAPE = 2

--- Local y of rail i's centre.
function core.rail_y(i)
	return 1 - 2 * i
end

--- §6.1's rail row (v1 on_built.lua:52-66, with power_check's 2×2 area): a straight rail whose centre is in the border
--- row (local y in (0.5, 1.5)), running across the edge (local direction north or south). Returns the connector's
--- lowest local column, the rail's centre minus WIDTH / 2, or nil; a connector reaching outside [0, L) is ignored.
function core.rail_rule(lx, ly, ldir, L)
	if ly <= 0.5 or ly >= 1.5 or ldir % 8 ~= 0 then
		return nil
	end
	local col = lx - core.WIDTH / 2
	if col < 0 or col > L - core.WIDTH then
		return nil
	end
	return col
end

--- The direction a generic box's first signals give (train box direction spec §3, spike 35). entering: a signal lets
--- trains into the border rail's block, so they head out (outbound: this side sends). leaving: one lets them out of it,
--- so they come in (inbound: the neighbour sends). Both or neither: nil, the box stays generic.
function core.box_dir(me, entering, leaving)
	if entering == leaving then
		return nil
	end
	return (entering == (me == "a")) and "ab" or "ba"
end

-- Task 2: the body (§12.4) and the spawn plan (§12.5) ---------------------------------------------------------------

core.VERSION = 1
-- v1's first batch: carriages at -6 - 7k (train_link.lua:271), at most 12 (LuaTrainComplete_deserialize.lua:12).
core.FIRST, core.GAP, core.MAX_SPAWN = -6, 7, 12
-- A queued carriage stays within MAX_DEPTH of the front's spawn point (on_tick.lua:37): v1's 84, plus 10: the inbound box's
-- outer signal moved 10 tiles out, so the spawn room grew.
core.MAX_DEPTH = core.MAX_SPAWN * core.GAP + 10
core.RETRY = 15 -- v1's delayed-spawn pass (on_tick.lua)

--- A record without what can't cross: rails are entities of this server, so v1 dropped rail records.
local function keep(r)
	return { station = r.station, temporary = r.temporary, created_by_interrupt = r.created_by_interrupt,
		wait_conditions = r.wait_conditions }
end

--- The records a body carries (§12.4), the edge record's position among them, and current's. The edge record is found
--- by identity, never by `current` (spike 6): its rail is the outbound box's end rail (SP4 §5.3: no edge stops). Other
--- rail records are dropped, as v1 did. The edge record stays as a marker without a station, so the destination knows
--- what came after it. A dropped current moves to the next kept record.
function core.split(records, current, end_rail_id)
	local kept, edge, at = {}, nil, nil
	for i, r in ipairs(records) do
		local is_edge = r.rail ~= nil and r.rail.unit_number == end_rail_id
		local kept_here = r.station ~= nil or is_edge
		if kept_here then
			kept[#kept + 1] = keep(r)
			if is_edge and (not edge or i == current) then
				edge = #kept -- two records naming the edge: the current one wins
			end
		end
		if i == current then
			at = kept_here and #kept or #kept + 1
		end
	end
	if at and at > #kept then
		at = 1
	end
	if #kept == 0 then
		at = nil
	end
	return kept, edge, at
end

--- Interrupts as they cross: rail targets dropped (rails are local); inside_interrupt travels in each one.
function core.interrupts(list)
	local out = {}
	for i, it in ipairs(list) do
		local targets = {}
		for _, r in ipairs(it.targets or {}) do
			if r.station then
				targets[#targets + 1] = keep(r)
			end
		end
		out[i] = { name = it.name, conditions = it.conditions, targets = targets, inside_interrupt = it.inside_interrupt }
	end
	return out
end

--- The body (§12.4), deterministic (D21): the same train gives the same table, and nothing in it varies with time,
--- the boot or the crossing — no tick, trace, train id or unit number. Its group crosses by name (sync spec §5.6,
--- replacing D19). s = { layer, speed, manual, carriages, records, current, interrupts, end_rail_id, group?, ext? },
--- read by train.lua.
function core.body(s)
	local records, edge, current = core.split(s.records, s.current, s.end_rail_id)
	return {
		v = core.VERSION, layer = s.layer, speed = math.abs(s.speed), manual = s.manual == true, carriages = s.carriages,
		schedule = { records = records, interrupts = core.interrupts(s.interrupts), current = current },
		edge_record = edge, group = s.group, ext = s.ext,
	}
end

--- A body this side can read (G5); anything else is rejected.
function core.valid(b)
	if type(b) ~= "table" or b.v ~= core.VERSION or type(b.speed) ~= "number" or type(b.carriages) ~= "table"
		or #b.carriages == 0 or type(b.schedule) ~= "table" or type(b.schedule.records) ~= "table"
		or (b.group ~= nil and type(b.group) ~= "string") then
		return false
	end
	for _, c in ipairs(b.carriages) do
		if type(c) ~= "table" or type(c.name) ~= "string" or type(c.quality) ~= "string" then
			return false
		end
	end
	return true
end

--- What the destination sets (§12.5 step 4): the records minus the edge record when it is temporary or a rail marker,
--- and the record after the edge record to go to, by identity (D22). With no edge record, the carried current. go is
--- nil when no record is left.
function core.restore_plan(schedule, edge)
	local list, records = schedule.records, {}
	local e = edge and list[edge]
	local strip = e ~= nil and (e.temporary or e.station == nil)
	for i, r in ipairs(list) do
		if not (strip and i == edge) then
			records[#records + 1] = r
		end
	end
	local n = #records
	if n == 0 then
		return records, nil
	end
	if e == nil then
		local go = schedule.current
		return records, (type(go) == "number" and go >= 1 and go <= n) and go or 1
	end
	if strip then
		return records, edge <= n and edge or 1
	end
	return records, edge % n + 1
end

--- One occurrence key per station name, counted in seen: "A" twice gives "A#1", then "A#2".
local function occurrence(seen, station)
	seen[station] = (seen[station] or 0) + 1
	return station .. "#" .. seen[station]
end

--- A crossing into a group (sync spec §5.6 steps 2-3). records and go are restore_plan's, temporaries included; adopted
--- is the group's records as this tile has them. Returns the carried temporary records with the schedule index each goes
--- in at (add them in order, each at its index), and the index to go to. A temporary record keeps its place before the
--- permanent record that followed it; permanent records are matched by station name and occurrence, so a group edited
--- since the train left still places them. Temporaries past the last match go at the end. go follows its record the
--- same way; when the group here lacks it, the train goes to record 1. go is nil when the schedule ends up empty.
function core.group_plan(records, go, adopted)
	local where, seen = {}, {}
	for i, r in ipairs(adopted) do
		if r.station then
			where[occurrence(seen, r.station)] = i
		end
	end
	local before, pending, count, go_temp, go_at = {}, {}, {}, nil, nil
	for i, r in ipairs(records) do
		if r.temporary then
			pending[#pending + 1] = r
			if i == go then
				go_temp = r
			end
		elseif r.station then
			local j = where[occurrence(count, r.station)]
			if j then
				before[j], pending = pending, {}
				if i == go then
					go_at = j
				end
			end
		end
	end
	before[#adopted + 1] = pending
	local adds, at, target = {}, 0, nil
	for j = 1, #adopted + 1 do
		for _, r in ipairs(before[j] or {}) do
			at = at + 1
			adds[#adds + 1] = { at = at, record = r }
			if r == go_temp then
				target = at
			end
		end
		if j <= #adopted then
			at = at + 1
			if j == go_at then
				target = at
			end
		end
	end
	if at == 0 then
		return adds, nil
	end
	return adds, target or 1
end

--- The first batch: how many carriages are created at once, and carriage k's local y, travel-front innermost.
function core.first_count(n)
	return math.min(n, core.MAX_SPAWN)
end

function core.spawn_y(k)
	return core.FIRST - core.GAP * (k - 1)
end

--- A queued carriage goes 7 tiles behind the train's outer end, and only within MAX_DEPTH of the front's spawn point
--- (v1 on_tick.lua:33-44): nil until the train has moved far enough.
function core.join_y(outer_y)
	local y = outer_y - core.GAP
	if core.FIRST - y > core.MAX_DEPTH then
		return nil
	end
	return y
end

--- A carriage's world orientation at the destination: inward, or outward when it faced against travel. facing is the
--- side's outward normal in 16ths.
function core.orientation(facing, flip)
	local out = facing / 16
	if flip then
		return out
	end
	return (out + 0.5) % 1
end

--- At capture: a carriage faces against travel when it points away from the end that leads.
function core.flip(headed_to_front, travel_is_front)
	return headed_to_front ~= travel_is_front
end

--- The speed's sign to move inward at spawn, where the front is on the box's straight rails: positive when moving
--- forward goes inward. front_dir is train.front_end.location.direction ([probe] sp3b-plan). Joins keep the coupling's
--- own speed instead, since past the box the front can be on a curve (owner playtest 2026-10-03).
function core.sign(front_dir, inward_dir)
	return front_dir == inward_dir and 1 or -1
end

--- ready (§12.3): the outer signal is open and no carriages wait to spawn.
function core.ready(outer_open, queued)
	return outer_open and not queued
end

-- Task 3: the ready gate (§12.3) -------------------------------------------------------------------------------------

--- The source captures only on the partner's ready, and only if that status was sent after the partner took this
--- side's last train: w ≥ its seq (D20, R9). The gate also opens for any status of a later activation, because a
--- destination crash always brings a new epoch, and a w that rolled back mustn't stall it. last = { seq, epoch } of
--- this side's last capture.
function core.gate(status, last, epoch)
	if type(status) ~= "table" or status.ready ~= true then
		return false
	end
	if last == nil or last.epoch ~= epoch then
		return true
	end
	return type(status.w) == "number" and status.w >= last.seq
end

return core
