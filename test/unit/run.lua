-- A copy of the clusterio-v2 integration repo's harness/lua/run.lua; keep the copies in step.
-- Usage: lua5.2 run.lua <modules root> <test files...>
-- `require("modules/<plugin>/<path>")` resolves to <modules root>/<plugin>/module/<path>.lua, as in a patched save.
local here = string.match(arg[0], "^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path
local root = assert(arg[1], "usage: lua5.2 run.lua <modules root> <test files...>")

table.insert(package.searchers, 2, function(name)
	local plugin, rest = string.match(name, "^modules/([%w_]+)/(.+)$")
	if not plugin then
		return nil
	end
	local file = root .. "/" .. plugin .. "/module/" .. rest .. ".lua"
	local chunk, err = loadfile(file)
	if not chunk then
		return "\n\tno file '" .. file .. "' (" .. tostring(err) .. ")"
	end
	return chunk, file
end)

local testlib = require("testlib")
local failures, total = 0, 0
for i = 2, #arg do
	testlib.cases = {}
	assert(loadfile(arg[i]))()
	for _, case in ipairs(testlib.cases) do
		total = total + 1
		local ok, err = pcall(case.fn)
		if ok then
			print("ok " .. arg[i] .. " :: " .. case.name)
		else
			failures = failures + 1
			print("not ok " .. arg[i] .. " :: " .. case.name)
			print("       " .. tostring(err))
		end
	end
end
print(string.format("%d/%d passed", total - failures, total))
os.exit(failures == 0 and 0 or 1)
