-- Build detection (SP3 spec §6.2): a player's build in a border row proposes a connector, or becomes the border entity
-- of the endpoint already there; each poll checks that entity with one .valid read (review I1: no removal handlers).
-- A proposal whose entity has gone by the time its endpoint is built is withdrawn there (playtest 2026-10-10).
-- A train rail's proposal goes to the train type's generic box, which sends it once a signal decides its direction.
-- Belt-flip (owner, 2026-10-04): a border belt or underground whose live direction now disagrees with its link's
-- params.dir is proposed again, through the same path a fresh build uses (propose_for_side), once the old connector
-- has torn down — the belt type's own poll drives this (belt.lua), via detect.propose_now and detect.repropose below.
local bridge = require("modules/universal_edges/runtime/bridge")
local trace = require("modules/universal_edges/runtime/trace")
local geometry = require("modules/universal_edges/edges/geometry_core")
local connectors = require("modules/universal_edges/edges/connectors")
local core = require("modules/universal_edges/transports/detect_core")

local detect = {}
local send = bridge.channel("universal_edges")

--- The detect kind an endpoint's border entity has: its type's, or a type's declared `border` (a test type's).
local function kind_of(ep)
	return connectors.types[ep.type].border or ep.type
end

--- side's frame, cached on it (F9, factored out so detect.repropose below reuses the same cache on_built does): a
--- side's geometry never changes, as a change replaces the whole side (edge_core.plan's "replace" → edges.lua's
--- create), which starts without a frame.
local function frame_of(side)
	local frame = side.frame
	if not frame then
		local mine = side[side.me]
		frame = { origin = { mine.origin[1], mine.origin[2] }, facing = mine.facing, length = side.length }
		side.frame = frame
	end
	return frame
end

--- One entity's facts for core.propose. A logistic container also carries name, quality name and link: whether a
--- ue-link-<name> prototype exists, which is exactly a requester-mode chest (logistic-link spec §5, §6.3).
local function facts(e)
	local p = e.position
	local f = { type = e.type, x = p.x, y = p.y, direction = e.direction, size = e.tile_width }
	if e.type == "logistic-container" then
		f.name, f.q, f.link = e.name, e.quality.name, prototypes.entity["ue-link-" .. e.name] ~= nil
	end
	return f
end

--- One chat line for the player who built e (owner, 2026-10-05); a robot or script build has no player. A function on
--- detect so a game test (no LuaPlayer exists in one) can replace it.
function detect.notify(player_index, text)
	local player = player_index and game.get_player(player_index)
	if player and player.connected then
		player.print(text)
	end
end

local function gps(surface, x, y)
	return ("[gps=%s,%s,%s]"):format(x, y, surface)
end

local TYPE_NAMES = { belt = "Belt", fluid = "Fluid", power = "Power", train = "Train", logistic = "Logistic" }
local REMEMBER = 3600 -- ticks a proposal is remembered: for a controller refusal to name its builder, and to withdraw it

--- Send proposal (one built entity's, on side) to the controller as ue.connector.propose, and remember it: for a
--- refusal's chat line to name its builder, and to withdraw it (§6.2 step 3). Returns its trace. The train's generic box
--- calls this once a signal has decided its direction (train box direction spec §6.1).
function detect.propose(side, proposal, surface, position, player_index)
	local id_ = trace.new_id()
	local pos = geometry.col(side.me, side.length, proposal.col, proposal.width)
	send("ue.connector.propose", { edge = side.id, type = proposal.type, pos = pos, width = proposal.width,
		params = proposal.params, trace = id_ })
	local pending = storage.universal_edges.proposals or {}
	storage.universal_edges.proposals = pending
	for k, v in pairs(pending) do
		if game.tick - v.tick > REMEMBER then
			pending[k] = nil
		end
	end
	pending[id_] = { player = player_index, surface = surface, position = { position.x, position.y },
		type = proposal.type, tick = game.tick, edge = side.id, col = proposal.col, width = proposal.width }
	send("trace", { op = "ue.connector", phase = "proposed", level = "info", tick = game.tick, trace = id_,
		edge = side.id, type = proposal.type, pos = pos, params = proposal.params })
	return id_
end

--- built (one entity's facts) against one side's frame: the proposal, absorbed into an existing endpoint of the same
--- kind over its columns (FC2's C8), or sent on as ue.connector.propose if none covers it; a type with a `detected`
--- field (the train's generic box) takes it instead, and its `refused` hears of a refusal. Shared by on_built (every side
--- on the entity's surface) and detect.repropose (the one side a just-torn-down reversed connector belonged to).
local function propose_for_side(side, frame, e, built, player_index)
	local proposal = core.propose(side.me, frame, built)
	if not proposal then
		return
	end
	local taken -- the train endpoint whose columns a train proposal fell into
	-- FC2 (circuit-link spec §5.2): one pole is the border entity of its power and its circuit endpoint, so the build
	-- is cached on every live endpoint over its columns whose kind matches; it proposes only when no endpoint of the
	-- proposal's own type (ep.type, not its kind: C8) covers them.
	local mine = false
	for cid in pairs(side.eps) do
		local ep = connectors.get(side, cid)
		-- a built-in endpoint spans the whole edge and is no pole's endpoint, so it never takes part (F7)
		if ep and not ep.builtin and not ep.closing and proposal.col < ep.col + ep.width and ep.col < proposal.col + proposal.width then
			if kind_of(ep) == proposal.type then
				ep.data.border = e -- a pole beside a belt's column is not that belt's border entity
			end
			if ep.type == proposal.type then
				mine, taken = true, taken or ep
			end
		end
	end
	-- a train rail inside another train link's columns, not at its rail: say why nothing was made (owner, 2026-10-05)
	if taken and proposal.type == "train" and player_index
		and proposal.col + proposal.width / 2 ~= taken.col + taken.width / 2 then
		local x, y = geometry.to_world(frame, taken.col + taken.width / 2, 1)
		detect.notify(player_index, ("[Universal Edges] Train link at %s not made: its rail is too close to the train link at %s. "
			.. "Train links need their rails at least 4 tiles apart; a link built before 2026-10-05 needs 6 — mine both rails "
			.. "and rebuild them to make them 4."):format(gps(e.surface.name, e.position.x, e.position.y), gps(e.surface.name, x, y)))
	end
	if not mine then
		-- a type with detected (the train's) takes the proposal: its generic box proposes once a signal decides
		-- (train box direction spec §4)
		local t = connectors.types[proposal.type]
		if t and t.detected then
			t.detected(side, frame, e, proposal, player_index)
		else
			detect.propose(side, proposal, e.surface.name, e.position, player_index)
		end
	end
end

--- on_built_entity, on_robot_built_entity, script_raised_built and script_raised_revive (v1's set): one type lookup
--- for an unrelated build; a frame test per side on the entity's surface for a detected type. A surface with no side
--- allocates nothing; one with sides allocates the entity's facts once, whatever their number (final review I4).
function detect.on_built(event)
	local e = event.entity
	if not (e and e.valid and core.KIND[e.type]) then
		return
	end
	local s = storage.universal_edges
	local ids = s.by_surface[e.surface_index]
	if not ids then
		return
	end
	local built = facts(e)
	for id in pairs(ids) do
		local side = s.edges[id]
		if not side.deleted then
			propose_for_side(side, frame_of(side), e, built, event.player_index)
		end
	end
end

--- ep's removal, asked for and logged.
local function remove(ep, reason)
	ep:request_removal(reason)
	send("trace", { op = "ue.connector", phase = "removal_requested", level = "info", tick = game.tick, trace = ep.trace,
		edge = ep.edge, cid = ep.cid, reason = reason })
end

--- This side's remembered proposal of ep's columns and type, forgotten as it is taken; nil when there is none.
local function take(ep)
	local pending = storage.universal_edges.proposals
	for k, p in pairs(pending or {}) do
		if p.edge == ep.edge and p.col == ep.col and p.width == ep.width and p.type == ep.type
			and game.tick - p.tick <= REMEMBER then
			pending[k] = nil
			return p
		end
	end
	return nil
end

--- A transport's build (F9): cache the player's border entity at the endpoint's columns, if one stands there. When this
--- side proposed the connector and its entity has gone since (mined, or destroyed by a script, before the connector
--- arrived), the proposal is withdrawn: the poll never would ask, as the endpoint never had the entity (§6.2 step 3).
function detect.adopt(ep)
	local d = ep.data
	local proposed = take(ep)
	if d.border and d.border.valid then
		return
	end
	local surface = game.get_surface(ep.frame.surface_index)
	local x1, y1, x2, y2 = core.border_area(ep.frame, ep.col, ep.width)
	d.border = surface and surface.find_entities_filtered({ area = { { x1, y1 }, { x2, y2 } },
		type = core.BORDER_TYPES[kind_of(ep)], limit = 1 })[1]
	if proposed and not d.border then
		remove(ep, "withdrawn")
	end
end

--- Each poll (§6.2 step 3): while the border entity stands, a .valid read. When it has gone, its columns are searched
--- once for a successor (an upgrade, a fast-replace or a rotation) to adopt; with none, the connector's removal is
--- requested, once. An endpoint that never had a border entity never asks.
function detect.check(ep)
	local d = ep.data
	if d.border == nil or d.border.valid then
		return
	end
	d.border = nil
	detect.adopt(ep)
	if not d.border then
		remove(ep, "mined")
	end
end

--- Belt-flip: the proposal ep's current border entity would make if built fresh right now, fed with its live facts
--- (not an event) through the same core.propose detect_core's build detection uses. nil without a valid border, or
--- when it's no longer a valid build there (e.g. rotated off the border row's axis — out of scope here, same as a
--- fresh build in that spot would be). Read-only: belt.lua's poll compares its params.dir against this to notice a
--- rotation or an underground's flip (its belt_to_ground_type) that reverses the link.
function detect.propose_now(ep)
	local e = ep.data.border
	if not (e and e.valid) then
		return nil
	end
	return core.propose(ep.me, ep.frame, facts(e))
end

--- Belt-flip: once a reversed connector has fully torn down (belt.lua's teardown hook calls this with the entity it
--- remembered), e — its own border entity — is still standing, only rotated or flipped: proposed again through the
--- same path a fresh build uses, so the new direction is proposed like one (owner, 2026-10-04: remove, then re-add).
function detect.repropose(side, e)
	if not (e and e.valid and not side.deleted) then
		return
	end
	propose_for_side(side, frame_of(side), e, facts(e))
end

--- ue.connector.refused: the controller refused a proposal a player's build made; tell them why.
bridge.on("universal_edges", "ue.connector.refused", function(p)
	if type(p.trace) ~= "string" or type(p.reason) ~= "string" then
		return false
	end
	local pending = storage.universal_edges.proposals
	local r = pending and pending[p.trace]
	if r then
		pending[p.trace] = nil
		local why = p.reason == "overlap" and "it overlaps another link's columns; move it clear of the neighbouring link"
			or "refused by the controller (" .. p.reason .. ")"
		detect.notify(r.player, ("[Universal Edges] %s link at %s not made: %s."):format(TYPE_NAMES[r.type] or r.type,
			gps(r.surface, r.position[1], r.position[2]), why))
		local t = connectors.types[r.type]
		if t and t.refused then
			t.refused(p.trace) -- the train's generic box goes (train box direction spec §6.4)
		end
	end
	return true
end)

return detect
