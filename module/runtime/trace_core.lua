-- Id minting (spec §7.2), pure. Lua has no source of randomness, so the boot id comes from the instance plugin in
-- the startup handshake; before it, no id can be minted.
local core = {}

--- The next "<boot id>.<seq>" of this boot, counting from 1.
function core.new_id(rt)
	if rt.boot_id == nil then
		error("no ids before the runtime handshake")
	end
	rt.seq = rt.seq + 1
	return rt.boot_id .. "." .. rt.seq
end

return core
