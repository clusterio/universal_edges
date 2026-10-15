-- Pure scheduler logic (spec §7.1): no Factorio globals, so it runs under lua5.2. The shell (scheduler.lua)
-- keeps `state` and `stats` in storage and rebuilds the task registry at every load: functions are never stored.
local core = {}

local REQUIRED = {
	periodic = { "interval" },
	iterate = { "per_tick" },
	queue = { "cap", "ttl_ticks", "per_tick" },
	once = { "cap", "per_tick" },
}

--- Deterministic string hash (djb2), so tasks with equal intervals get different phases.
function core.hash(s)
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + string.byte(s, i)) % 4294967296
	end
	return h
end

local function positive_integer(v)
	return type(v) == "number" and v >= 1 and v % 1 == 0
end

--- Check a spec and build its task. The per-task limits are mandatory, so no task can grow without bound.
function core.validate(kind, spec)
	local required = REQUIRED[kind]
	if not required then
		error("unknown scheduler task kind " .. tostring(kind))
	end
	if type(spec) ~= "table" or type(spec.name) ~= "string" or type(spec.fn) ~= "function" then
		error(kind .. " task needs a string name and a function fn")
	end
	for _, field in ipairs(required) do
		if not positive_integer(spec[field]) then
			error(kind .. " task " .. spec.name .. " needs a positive integer " .. field)
		end
	end
	if kind == "iterate" and type(spec.source) ~= "function" then
		error("iterate task " .. spec.name .. " needs a source function")
	end
	if kind == "iterate" and spec.interval ~= nil and not positive_integer(spec.interval) then
		error("iterate task " .. spec.name .. " needs a positive integer interval, or none")
	end
	local task = {
		kind = kind, name = spec.name, fn = spec.fn, source = spec.source,
		interval = spec.interval, per_tick = spec.per_tick, cap = spec.cap, ttl_ticks = spec.ttl_ticks,
	}
	if kind == "periodic" then
		task.phase = core.hash(spec.name) % spec.interval
	end
	return task
end

local function count(stats, name, kind, n)
	local s = stats[name]
	if not s then
		s = {}
		stats[name] = s
	end
	s[kind] = (s[kind] or 0) + (n or 1)
end

local function task_state(state, name)
	local ts = state.tasks[name]
	if not ts then
		ts = {}
		state.tasks[name] = ts
	end
	return ts
end

--- The first tick after `tick` with (t + phase) % interval == 0.
local function next_due(task, tick)
	return tick + task.interval - (tick + task.phase) % task.interval
end

-- Per kind: work(task, ts, tick, stats) returns what run needs, or nil when there is nothing to do;
-- run(task, ts, tick, limit, work) does at most `limit` units and returns how many it did.
local work, run = {}, {}

function work.periodic(task, ts, tick)
	ts.due = ts.due or next_due(task, tick - 1)
	return tick >= ts.due or nil
end

function run.periodic(task, ts, tick)
	local units = task.fn(tick)
	ts.due = next_due(task, tick)
	return type(units) == "number" and units or 1
end

function work.iterate(task, ts, tick)
	if ts.rest_until and tick < ts.rest_until then
		return nil
	end
	local source = task.source()
	return type(source) == "table" and next(source) ~= nil and source or nil
end

function run.iterate(task, ts, tick, limit, source)
	local key = ts.cursor
	if key ~= nil and ts.extra and task.interval and tick >= ts.walk_began + task.interval then
		key = nil -- an extra walk still going when a period comes due gives way to that period's walk
	end
	if key == nil then
		-- A walk that starts a period sets the cadence; a walk a wake started is extra and keeps it.
		ts.again = nil
		ts.extra = ts.walk_began ~= nil and tick < ts.walk_began + (task.interval or 0) or nil
		if not ts.extra then
			ts.walk_began = tick
		end
	end
	-- ponytail: a cursor whose key vanished restarts the walk, because Lua's next can't resume from a missing key.
	-- Heavy churn exactly at the cursor revisits early keys; switch to a sorted key snapshot if a registry starves.
	if key ~= nil and source[key] == nil then
		key = nil
	end
	local done = 0
	while done < limit do
		local k, v = next(source, key)
		if k == nil then
			key = nil
			-- With an interval, a walk that ends early rests: visits that can't poll yet cost Lua time for nothing.
			-- A wake during the walk means walk again at once: it may be for an entry already passed.
			ts.rest_until = task.interval and not ts.again and ts.walk_began and ts.walk_began + task.interval or nil
			break
		end
		task.fn(k, v, tick)
		key = k
		done = done + 1
	end
	ts.cursor = key
	return done
end

function work.queue(task, ts, tick, stats)
	local items = ts.items
	if not items then
		return nil
	end
	while items.first <= items.last and items[items.first].tick + task.ttl_ticks < tick do
		items[items.first] = nil
		items.first = items.first + 1
		count(stats, task.name, "expiries")
	end
	return items.first <= items.last and items or nil
end

function run.queue(task, _, tick, limit, items)
	local done = 0
	while done < limit and items.first <= items.last do
		local entry = items[items.first]
		items[items.first] = nil
		items.first = items.first + 1
		task.fn(entry.item, tick)
		done = done + 1
	end
	return done
end

-- ts.next_due (maintained by core.schedule below and recomputed here) lets this return in O(1) instead of
-- scanning every pending entry on every tick: that scan cost 22.8 µs/tick with 1,000 pending entries.
function work.once(_, ts, tick)
	return ts.next_due ~= nil and ts.next_due <= tick and ts.pending or nil
end

function run.once(task, ts, tick, limit, pending)
	-- ponytail: named min_due, not next_due, to avoid shadowing the next_due(task, tick) upvalue above (luacheck warns).
	local done, i, min_due = 0, 1, nil
	while i <= #pending do
		local entry = pending[i]
		if done < limit and entry.due <= tick then
			table.remove(pending, i)
			task.fn(entry.args, tick)
			done = done + 1
		else
			min_due = (min_due == nil or entry.due < min_due) and entry.due or min_due
			i = i + 1
		end
	end
	ts.next_due = min_due
	return done
end

--- Add item to a queue task. Returns false, and counts a drop, when the queue is at its cap (the newest is dropped).
function core.push(state, stats, task, item, tick)
	local ts = task_state(state, task.name)
	ts.items = ts.items or { first = 1, last = 0 }
	local items = ts.items
	if items.last - items.first + 1 >= task.cap then
		count(stats, task.name, "drops")
		return false
	end
	items.last = items.last + 1
	items[items.last] = { tick = tick, item = item }
	return true
end

--- Schedule a once task's handler for tick `due` with `args` (plain data). Returns false, and counts a drop, at cap.
function core.schedule(state, stats, task, due, args)
	local ts = task_state(state, task.name)
	ts.pending = ts.pending or {}
	if #ts.pending >= task.cap then
		count(stats, task.name, "drops")
		return false
	end
	ts.pending[#ts.pending + 1] = { due = due, args = args }
	ts.next_due = (ts.next_due == nil or due < ts.next_due) and due or ts.next_due
	return true
end

--- One tick. The work cap (state.cap, in work units) is nil by default, and then every task with work runs.
--- With a cap, a task whose turn comes after the budget is spent counts a deferral and stays due. The first
--- task rotates each tick, so the same tasks are not always the deferred ones.
function core.tick(state, stats, registry, tick)
	local n = #registry
	local budget = state.cap
	for offset = 0, n - 1 do
		local task = registry[(tick + offset) % n + 1]
		local ts = task_state(state, task.name)
		local pending = work[task.kind](task, ts, tick, stats)
		if pending ~= nil then
			if budget ~= nil and budget <= 0 then
				count(stats, task.name, "deferrals")
			else
				local limit = task.per_tick or 1
				if budget ~= nil and budget < limit then
					limit = budget
				end
				local units = run[task.kind](task, ts, tick, limit, pending)
				count(stats, task.name, "runs")
				count(stats, task.name, "units", units)
				if budget ~= nil then
					budget = budget - units
				end
			end
		end
	end
end

--- End an iterate task's rest, so the next tick starts an extra walk; a walk in progress walks again when it ends.
--- Extra walks don't move the cadence, so an entry polled every interval still is.
function core.wake(state, name)
	local ts = state.tasks[name]
	if ts then
		ts.rest_until, ts.again = nil, true
	end
end

return core
