-- A copy of the clusterio-v2 integration repo's harness/lua/testlib.lua; keep the copies in step.
-- Minimal test library for plain Lua 5.2 (unit tests of *_core.lua files).
local testlib = { cases = {} }

function testlib.test(name, fn)
	testlib.cases[#testlib.cases + 1] = { name = name, fn = fn }
end

local function describe(value)
	if type(value) == "string" then
		return string.format("%q", value)
	end
	return tostring(value)
end

local function same(a, b)
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return a == b
	end
	for k, v in pairs(a) do
		if not same(v, b[k]) then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end

function testlib.expect_eq(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": expected " .. describe(expected) .. ", got " .. describe(actual), 2)
	end
end

function testlib.expect_true(value, message)
	if not value then
		error(message or "expected a truthy value", 2)
	end
end

function testlib.expect_same(actual, expected, message)
	if not same(actual, expected) then
		error(message or "tables differ", 2)
	end
end

function testlib.expect_error(fn, pattern)
	local ok, err = pcall(fn)
	if ok then
		error("expected an error", 2)
	end
	if pattern and not string.find(tostring(err), pattern) then
		error("error " .. describe(tostring(err)) .. " does not match " .. describe(pattern), 2)
	end
end

return testlib
