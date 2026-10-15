-- Game shell for the scheduler (spec §7.1): binds scheduler_core to storage.universal_edges and the runtime's one
-- on_tick. Tasks are registered at load, by name; storage holds only their state.
local core = require("modules/universal_edges/runtime/scheduler_core")

local scheduler = {}
local registry, names = {}, {}

local function register(kind, spec)
	if game then
		error("register scheduler tasks while loading, not at runtime: " .. tostring(type(spec) == "table" and spec.name))
	end
	local task = core.validate(kind, spec)
	if names[task.name] then
		error("scheduler task " .. task.name .. " is already registered")
	end
	names[task.name] = true
	registry[#registry + 1] = task
	return task
end

--- periodic{ name, interval, fn(tick) }: fn runs when (tick + phase) % interval == 0, with the phase taken from the
--- name. fn may return how many work units it used (default 1).
function scheduler.periodic(spec)
	register("periodic", spec)
end

--- iterate{ name, source, per_tick, interval?, fn(key, value, tick) }: walks source() per_tick entries per tick,
--- resuming from a cursor in storage. With an interval, a walk that ends early waits until interval ticks after it
--- began. Keys must be strings or numbers, and fn must not add keys to the source.
function scheduler.iterate(spec)
	register("iterate", spec)
end

--- queue{ name, cap, ttl_ticks, per_tick, fn(item, tick) } returns { push(item) }: a bounded FIFO in storage (items
--- must be plain data). push returns false when it dropped the item.
function scheduler.queue(spec)
	local task = register("queue", spec)
	return {
		push = function(item)
			local s = storage.universal_edges
			return core.push(s.scheduler, s.stats, task, item, game.tick)
		end,
	}
end

--- once{ name, cap, per_tick, fn(args, tick) } returns { schedule(delay, args) }: a persisted one-shot. Only args (plain
--- data) are stored; fn is found by name at run time. schedule returns false when it dropped the call.
function scheduler.once(spec)
	local task = register("once", spec)
	return {
		schedule = function(delay, args)
			local s = storage.universal_edges
			return core.schedule(s.scheduler, s.stats, task, game.tick + delay, args)
		end,
	}
end

--- The only per-tick handler of v2 code runs this (control.lua).
--- End the rest of iterate task name, so it walks again from the next tick.
function scheduler.wake(name)
	local s = storage.universal_edges
	if s then
		core.wake(s.scheduler, name)
	end
end

function scheduler.on_tick(tick)
	local s = storage.universal_edges
	if s then
		core.tick(s.scheduler, s.stats, registry, tick)
	end
end

return scheduler
