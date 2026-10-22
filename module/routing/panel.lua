-- The station list (D42 point 7, spec §9): a draggable window on the screen (the 2.1 train window is a left sidebar over
-- a map view, so a train_gui anchor would cover the map) lists the train's own planet's stations, their tiles and free
-- slots (from the controller, in parts applied as upserts by surface and name, R35), filtered by a search box, and adds
-- a name to the train's schedule or to an interrupt's targets, as the "Add to" drop-down says. Only this planet's
-- stations are listed: a train can't reach another planet's stop (R36). The window's spot is remembered per player. A
-- train given a remote name waits in no_path until routing routes it. Above it, the group and interrupt pickers (train
-- group sync spec §5.7) list the cluster's groups and interrupts from the sync's cache: picking a group joins it,
-- picking an interrupt adds it. The pickers act only while routing is live (the routing latch, plan ruling C5).
-- Beside a train stop's window, on its left, a second panel lists the same planet's station names from every tile, each
-- with a pencil that renames the open stop to it (docs/superpowers/specs/2026-10-22-stop-name-picker-design.md).
local bridge = require("modules/universal_edges/runtime/bridge")
local base = require("modules/universal_edges/routing/base")
local scheduler = require("modules/universal_edges/runtime/scheduler")
local sync = require("modules/universal_edges/schedules/sync")

local panel = { events = {} }
local NAME = "router_stations"
local STOP_NAME = "router_stop_names"
local DEFAULT_AT = { x = 460, y = 44 } -- right of the train sidebar at UI scales 1.25 to 1.75, before UI scale

--- Only a locomotive's window is the train window: a wagon's opens its inventory, and the panel stays shut (owner,
--- 2026-10-06).
function panel.is_locomotive(e)
	return e ~= nil and e.object_name == "LuaEntity" and e.valid and e.type == "locomotive"
end

--- The train whose window the player has open, or nil.
local function opened_train(player)
	local e = player.opened
	if panel.is_locomotive(e) then
		return e.train
	end
end

--- The stations on surface here (the train's own planet, R36: a train can't reach another planet's stop) whose name
--- contains q (case-insensitive, plain; none or empty q: all), in name order.
function panel.sorted(here, q)
	local list = {}
	for _, st in pairs(base.state().list[here] or {}) do
		if not q or string.find(st.name:lower(), q:lower(), 1, true) then
			list[#list + 1] = st
		end
	end
	table.sort(list, function(a, b) return a.name < b.name end)
	return list
end

--- A record for station name at the end, with no wait condition (owner, 2026-10-07): the player adds them in the train
--- window.
function panel.add_record(tr, name)
	tr.get_schedule().add_record{ station = name }
end

--- station name as the last target of the first interrupt named interrupt (R16; U14: the first of two with one name).
--- A no-op when the player removed it meanwhile.
function panel.add_target(tr, interrupt, name)
	local sched = tr.get_schedule()
	for k, it in ipairs(sched.get_interrupts()) do
		if it.name == interrupt then
			local found = sched.get_interrupt(k)
			found.targets = found.targets or {}
			found.targets[#found.targets + 1] = { station = name }
			sched.change_interrupt(k, found)
			return
		end
	end
end

--- Two lists of names are equal, item for item.
local function same_list(a, b)
	if #a ~= #b then
		return false
	end
	for i, x in ipairs(a) do
		if x ~= b[i] then
			return false
		end
	end
	return true
end

--- The group picker's items (sync spec §5.7): "None", then every group the cache holds and the train's own, by name; the
--- index of the train's own (1, None, when it has none); and the names behind items 2 onward.
function panel.group_items(tr)
	local cache, own, names = sync.state().cache.group, sync.group_of(tr), {}
	for name in pairs(cache) do
		names[#names + 1] = name
	end
	if own and not cache[own] then
		names[#names + 1] = own
	end
	table.sort(names)
	local totals = sync.state().totals
	local items, index = { "None" }, 1
	for i, name in ipairs(names) do
		local total = totals and totals[name]
		items[i + 1] = total and name .. " (" .. total.n .. ")" or name
		if name == own then
			index = i + 1
		end
	end
	return items, index, names
end

--- The interrupt picker's items: its title, then every interrupt the cache holds, by name; and the names behind items 2
--- onward. Vanilla's own list still shows the interrupts this tile has.
function panel.interrupt_items()
	local names = {}
	for name in pairs(sync.state().cache.interrupt) do
		names[#names + 1] = name
	end
	table.sort(names)
	local items = { "Add interrupt" }
	for i, name in ipairs(names) do
		items[i + 1] = name
	end
	return items, names
end

local function free_text(st)
	return st.free < 0 and "∞" or tostring(st.free)
end

--- A tile's name for display: gridworld's "gridworld_<x>_<y>" shortened to "<x>,<y>", others in full. ponytail: UE
--- knows gridworld's instance naming here only for display.
local function short(tile)
	return (tile:gsub("^gridworld_(%-?%d+)_(%-?%d+)$", "%1,%2"))
end

--- The tiles' text, shortened and joined with " · " (a coordinate holds a comma).
local function tiles_text(st)
	local out = {}
	for i, tile in ipairs(st.tiles) do
		out[i] = short(tile)
	end
	return table.concat(out, " · ")
end

local COLS = 3 -- the train panel's station table: name, free, add; its header is one row of COLS cells

--- The index of cell c (1 to cols) of the grid's i-th station row.
local function cell(i, c, cols)
	cols = cols or COLS
	return cols * i + c
end

--- The grid's rows (cols cells each, after the header) name exactly list's stations and tiles, in order: only free
--- counts can differ.
local function same_rows(grid, list, cols)
	cols = cols or COLS
	local kids = grid.children
	if #kids ~= cols * (#list + 1) then
		return false
	end
	for i, st in ipairs(list) do
		local name = kids[cell(i, 1, cols)]
		if name.caption ~= st.name or name.tooltip ~= "On tiles: " .. tiles_text(st) then
			return false
		end
	end
	return true
end

local GROUP_TIP = "Trains in one group share one schedule on every tile. Edit it here or on any tile and every train in "
	.. "the group follows. None leaves the group; joining a group gives this train its schedule."
local INTERRUPT_TIP = "Add an interrupt to this train. Interrupts with the same name are shared by every tile: edit one "
	.. "in the train window and every copy updates."
local ADD_TO_TIP = "Where the + buttons put a station: the end of this train's schedule, or the targets of one of its "
	.. "interrupts."
local SEARCH_TIP = "Show only stations whose name contains this text."
local STATION_TIP = "Every station name on this planet, on every tile. A train sent to a name goes to the nearest stop with "
	.. "that name that has room, crossing tiles if it needs to."
local FREE_TIP = "How many more trains the stops with this name can take: their train limits minus the trains already "
	.. "heading to them, added up over every tile. ∞: at least one of them has no limit."
local LABEL_WIDTH = 72 -- "Interrupt [img=info]", so the drop-downs line up

local COUNT_TIP = "Trains in this group on every tile, counted about every 10 s:"

--- Set the label beside the group picker: the group's cluster-wide train count and tiles, hidden with no group or no total.
local function group_count(label, tr)
	local own = sync.group_of(tr)
	local totals = sync.state().totals
	local total = own and totals and totals[own]
	label.visible = total ~= nil
	if not total then
		return
	end
	local k = #total.tiles
	label.caption = total.n .. (total.n == 1 and " train" or " trains") .. " · " .. k .. (k == 1 and " tile" or " tiles")
	local lines = { COUNT_TIP }
	for _, t in ipairs(total.tiles) do
		lines[#lines + 1] = short(t.name) .. ": " .. t.n .. (t.stopped and " (stopped)" or "")
	end
	label.tooltip = table.concat(lines, "\n")
end

--- A row of a label, then the element spec (stretchable), in a horizontal flow named name.
local function labelled(frame, name, caption, tip, spec)
	local row = frame.add{ type = "flow", name = name, direction = "horizontal" }
	local label = row.add{ type = "label", caption = caption, tooltip = tip }
	label.style.minimal_width = LABEL_WIDTH
	local el = row.add(spec)
	el.style.horizontally_stretchable = true
	return row
end

--- Put the player's panel at its remembered spot (or the default, right of the train sidebar), both scale-free.
local function place(player, frame)
	local at = base.state().panel_at
	at = at and at[player.index] or DEFAULT_AT
	local s = player.display_scale
	frame.location = { x = math.floor(at.x * s + 0.5), y = math.floor(at.y * s + 0.5) }
end

--- The scroll pane of rows for list: name (its tooltip lists the tiles), free and a "+" that adds the name to the choice
--- in "Add to", under a header.
local function fill_pane(player, frame, list)
	local pane = frame.add{ type = "scroll-pane", name = "router_pane" }
	pane.style.maximal_height = math.floor(player.display_resolution.height / player.display_scale / 2)
	local grid = pane.add{ type = "table", name = "router_grid", column_count = COLS }
	grid.add{ type = "label", caption = "Station [img=info]", tooltip = STATION_TIP, style = "bold_label" }
	grid.add{ type = "label", caption = "Free [img=info]", tooltip = FREE_TIP, style = "bold_label" }
	grid.add{ type = "empty-widget" }
	for _, st in ipairs(list) do
		local name = grid.add{ type = "label", caption = st.name, tooltip = "On tiles: " .. tiles_text(st) } -- a string reads back as set
		name.style.horizontally_stretchable = true
		local free = grid.add{ type = "label", caption = free_text(st), tooltip = FREE_TIP }
		free.style.minimal_width = 36
		free.style.horizontal_align = "right"
		grid.add{ type = "sprite-button", sprite = "utility/add_white", style = "tool_button",
			tooltip = { "", "Add ", st.name, " to the choice in Add to" }, tags = { router = "add", name = st.name } }
	end
end

local STOP_TIP = "Every station name on this planet, on every tile. Click the pencil beside a name to rename this stop to "
	.. "it, and trains sent to that name can come here."

--- The stop whose window the player has open, or nil.
local function opened_stop(player)
	local e = player.opened
	if e ~= nil and e.object_name == "LuaEntity" and e.valid and e.type == "train-stop" then
		return e
	end
end

--- The stop panel's scroll pane of rows for list: the name (its tooltip lists the tiles) and a pencil that renames the
--- open stop to it, under a header. A pencil, not the train panel's "+": this replaces the name (owner, 2026-10-22).
local function fill_stop_pane(player, frame, list)
	local pane = frame.add{ type = "scroll-pane", name = "router_stop_pane" }
	pane.style.maximal_height = math.floor(player.display_resolution.height / player.display_scale / 2)
	local grid = pane.add{ type = "table", name = "router_stop_grid", column_count = 2 }
	grid.add{ type = "label", caption = "Station [img=info]", tooltip = STOP_TIP, style = "bold_label" }
	grid.add{ type = "empty-widget" }
	for _, st in ipairs(list) do
		local name = grid.add{ type = "label", caption = st.name, tooltip = "On tiles: " .. tiles_text(st) }
		name.style.horizontally_stretchable = true
		grid.add{ type = "sprite-button", sprite = "utility/rename_icon", style = "tool_button",
			tooltip = { "", "Rename this stop to ", st.name, "\nIts current name is replaced. Trains sent to ", st.name,
				" can then stop here too." },
			tags = { router = "rename", name = st.name } }
	end
end

--- (Re)build the stop panel, a frame on the left of the train stop window, for the stop the player has open; none if no
--- stop window is open. keep: an open panel whose filtered rows have the same names and tiles is left alone; otherwise
--- only the rows are rebuilt, so the search text (and its focus) survive.
function panel.show_stop(player, keep)
	local stop = opened_stop(player)
	local frame = player.gui.relative[STOP_NAME]
	if not stop then
		if frame then
			frame.destroy()
		end
		return
	end
	if frame and keep then
		local list = panel.sorted(stop.surface.name, frame.router_stop_search_row.router_stop_search.text)
		if not same_rows(frame.router_stop_pane.router_stop_grid, list, 2) then
			frame.router_stop_pane.destroy()
			fill_stop_pane(player, frame, list)
		end
		return
	end
	if frame then
		frame.destroy()
	end
	frame = player.gui.relative.add{ type = "frame", name = STOP_NAME, direction = "vertical", anchor = {
		gui = defines.relative_gui_type.train_stop_gui, position = defines.relative_gui_position.left } }
	local surface = stop.surface
	local planet = surface.planet
	frame.add{ type = "label", caption = { "", planet and planet.prototype.localised_name or surface.name, " stations, all tiles" },
		style = "frame_title" }
	labelled(frame, "router_stop_search_row", "Search", SEARCH_TIP, { type = "textfield", name = "router_stop_search" })
	fill_stop_pane(player, frame, panel.sorted(surface.name))
end

--- A click on a row's "+" in the stop panel: the stop whose window is open takes the name; nothing if none is open.
function panel.rename(player, tags)
	local stop = opened_stop(player)
	if stop then
		stop.backer_name = tags.name
	end
end

--- (Re)build the panel, a draggable window on player.gui.screen, for the train window the player has open; none if no
--- train window is open. keep (a list or search change, review I3): an open panel whose filtered rows have the same
--- names and tiles only gets its free counts updated in place; otherwise only the rows are rebuilt, so the "Add to"
--- pick, the search text (and its focus) survive.
function panel.show(player, keep)
	local tr = opened_train(player)
	local old = player.gui.relative[NAME] -- a leftover of the relative frame saves made before the screen window have
	if old then
		old.destroy()
	end
	local frame = player.gui.screen[NAME]
	if not tr then
		if frame then
			frame.destroy()
		end
		return
	end
	if frame and keep then
		local list = panel.sorted(tr.front_stock.surface.name, frame.router_search_row.router_search.text)
		local grid = frame.router_pane.router_grid
		if same_rows(grid, list) then
			local kids = grid.children
			for i, st in ipairs(list) do
				kids[cell(i, 2)].caption = free_text(st)
			end
		else
			frame.router_pane.destroy()
			fill_pane(player, frame, list)
		end
		return
	end
	if frame then
		frame.destroy()
	end
	frame = player.gui.screen.add{ type = "frame", name = NAME, direction = "vertical" }
	place(player, frame)
	local bar = frame.add{ type = "flow", direction = "horizontal" }
	bar.drag_target = frame
	local surface = tr.front_stock.surface
	local planet = surface.planet
	bar.add{ type = "label", caption = { "", planet and planet.prototype.localised_name or surface.name, " stations, all tiles" },
		style = "frame_title", ignored_by_interaction = true }
	local grip = bar.add{ type = "empty-widget", style = "draggable_space_header" }
	grip.style.horizontally_stretchable = true
	grip.style.height = 24
	grip.drag_target = frame
	local gitems, gindex, gnames = panel.group_items(tr)
	labelled(frame, "router_sched_row", "Group [img=info]", GROUP_TIP, { type = "drop-down", name = "router_group",
		items = gitems, selected_index = gindex, tags = { names = gnames } })
	frame.router_sched_row.add{ type = "label", name = "router_group_count" }
	group_count(frame.router_sched_row.router_group_count, tr)
	local iitems, inames = panel.interrupt_items()
	labelled(frame, "router_interrupt_row", "Interrupt [img=info]", INTERRUPT_TIP, { type = "drop-down",
		name = "router_interrupt", items = iitems, selected_index = 1, tags = { names = inames } })
	local items, interrupts = { "Schedule" }, {}
	for _, it in ipairs(tr.get_schedule().get_interrupts()) do
		items[#items + 1] = "Interrupt: " .. it.name
		interrupts[#interrupts + 1] = it.name
	end
	labelled(frame, "router_add_row", "Add to [img=info]", ADD_TO_TIP, { type = "drop-down", name = "router_add_to",
		items = items, selected_index = 1, tags = { interrupts = interrupts } })
	labelled(frame, "router_search_row", "Search", SEARCH_TIP, { type = "textfield", name = "router_search" })
	fill_pane(player, frame, panel.sorted(tr.front_stock.surface.name))
end

--- Keep the group and interrupt pickers (sync spec §5.7) in step with the cache and the train's group: relisted when the
--- names changed, and the train's group selected.
function panel.refresh_sched(row, irow, tr)
	local items, index, names = panel.group_items(tr)
	local pick = row.router_group
	if not same_list(names, pick.tags.names) or not same_list(items, pick.items) then
		pick.items, pick.tags = items, { names = names }
	end
	if row.router_group_count then -- a panel opened before the label existed has none until it is rebuilt
		group_count(row.router_group_count, tr)
	end
	if pick.selected_index ~= index then
		pick.selected_index = index
	end
	local add = irow.router_interrupt
	local iitems, inames = panel.interrupt_items()
	if not same_list(inames, add.tags.names) then
		add.items, add.tags, add.selected_index = iitems, { names = inames }, 1
	end
end

--- Keep the pickers and the "Add to" drop-down in step with the cache and the train's interrupts: when
--- their names changed, relist them and keep the choice by name (Schedule
--- stays; a gone interrupt falls back to Schedule). Nothing changes when the names are the same.
function panel.refresh(player)
	local frame = player.gui.screen[NAME]
	local tr = frame and opened_train(player)
	if not (tr and tr.valid) then
		return
	end
	panel.refresh_sched(frame.router_sched_row, frame.router_interrupt_row, tr)
	local pick = frame.router_add_row.router_add_to
	local names = {}
	for _, it in ipairs(tr.get_schedule().get_interrupts()) do
		names[#names + 1] = it.name
	end
	local old = pick.tags.interrupts
	if same_list(names, old) then
		return
	end
	local chosen = pick.selected_index > 1 and old[pick.selected_index - 1]
	local items, index = { "Schedule" }, 1
	for i, n in ipairs(names) do
		items[i + 1] = "Interrupt: " .. n
		if n == chosen and index == 1 then
			index = i + 1
		end
	end
	pick.items, pick.selected_index, pick.tags = items, index, { interrupts = names }
end

--- A click on a row's "+", for the train the player has open: the "Add to" choice decides between a record and an
--- interrupt's target. The interrupt is found by the name picked, at click time (R16), so a reorder meanwhile can't
--- send the station to another one.
function panel.click(player, tags)
	local tr = opened_train(player)
	local frame = player.gui.screen[NAME]
	local pick = tr and frame and frame.router_add_row.router_add_to
	if not pick then
		return
	end
	local i = pick.selected_index
	if i == 1 then
		panel.add_record(tr, tags.name)
	elseif i > 1 and pick.tags.interrupts[i - 1] then
		panel.add_target(tr, pick.tags.interrupts[i - 1], tags.name)
	end
end

--- A pick in the group or interrupt picker (sync spec §5.7), for the train the player has open, by the names listed at
--- build time (tags). Group: "None" leaves the group, keeping the train's copy; a name joins it (sync.join: adopted
--- where it has members here, else seeded from the cache). Interrupt: the cache's content is added to the train, and the
--- picker goes back to its title.
function panel.pick(player, element)
	local tr = opened_train(player)
	if not tr then
		return
	end
	local i, names = element.selected_index, element.tags.names
	if element.name == "router_group" then
		if i == 1 then
			tr.group = nil
		elseif names[i - 1] then
			sync.join(tr, names[i - 1])
		end
	elseif i > 1 then
		local cached = names[i - 1] and sync.state().cache.interrupt[names[i - 1]]
		if cached then
			tr.get_schedule().add_interrupt(cached.content)
		end
		element.selected_index = 1
	end
end

--- Focus the player's open panel's search box, its text selected so typing replaces it; nothing if no panel is open.
function panel.focus(player)
	local frame = player.gui.screen[NAME]
	if frame then
		local box = frame.router_search_row.router_search
		box.focus()
		box.select_all()
	end
end

--- Closing a locomotive's window takes the panel with it, so list changes stop updating a hidden frame (§9).
function panel.close(player)
	local old = player.gui.relative[NAME] -- a leftover of an older save's relative frame
	if old then
		old.destroy()
	end
	local frame = player.gui.screen[NAME]
	if frame then
		frame.destroy()
	end
end

--- The player dragged element: if it is their panel, remember where, scale-free.
function panel.moved(player, element)
	if element.valid and element.name == NAME and player.gui.screen[NAME] == element then
		local r = base.state()
		r.panel_at = r.panel_at or {}
		local s = player.display_scale
		r.panel_at[player.index] = { x = element.location.x / s, y = element.location.y / s }
	end
end

--- The player's UI scale changed: an open panel goes to its remembered spot at the new scale.
function panel.rescale(player)
	local frame = player.gui.screen[NAME]
	if frame then
		place(player, frame)
	end
end

panel.events[defines.events.on_gui_opened] = function(e)
	if e.gui_type == defines.gui_type.entity and panel.is_locomotive(e.entity) then
		panel.show(game.get_player(e.player_index))
	elseif e.gui_type == defines.gui_type.entity and e.entity and e.entity.valid and e.entity.type == "train-stop" then
		panel.show_stop(game.get_player(e.player_index))
	end
end

--- Closing a stop's window takes the stop panel with it.
local function close_stop(player)
	local frame = player.gui.relative[STOP_NAME]
	if frame then
		frame.destroy()
	end
end

panel.events[defines.events.on_gui_closed] = function(e)
	if e.gui_type == defines.gui_type.entity and panel.is_locomotive(e.entity) then
		panel.close(game.get_player(e.player_index))
	elseif e.gui_type == defines.gui_type.entity and e.entity and e.entity.valid and e.entity.type == "train-stop" then
		close_stop(game.get_player(e.player_index))
	end
end

-- A screen frame outlives a disconnect; a player joins with no train window open, so a leftover panel goes (review M4).
panel.events[defines.events.on_player_joined_game] = function(e)
	panel.close(game.get_player(e.player_index))
	close_stop(game.get_player(e.player_index))
end

panel.events[defines.events.on_gui_location_changed] = function(e)
	panel.moved(game.get_player(e.player_index), e.element)
end

panel.events[defines.events.on_player_display_scale_changed] = function(e)
	panel.rescale(game.get_player(e.player_index))
end

panel.events[defines.events.on_gui_text_changed] = function(e)
	if e.element.valid and e.element.name == "router_search" then
		panel.show(game.get_player(e.player_index), true)
	elseif e.element.valid and e.element.name == "router_stop_search" then
		panel.show_stop(game.get_player(e.player_index), true)
	end
end

-- Ctrl+F (the player's own "focus-search" binding, data.lua's ue-focus-search): an open panel's search box takes focus.
panel.events["ue-focus-search"] = function(e)
	panel.focus(game.get_player(e.player_index))
end

panel.events[defines.events.on_gui_click] = function(e)
	local tags = e.element.valid and e.element.tags
	if tags and tags.router == "rename" then
		panel.rename(game.get_player(e.player_index), tags)
	elseif tags and tags.router then
		panel.click(game.get_player(e.player_index), tags)
	end
end

panel.events[defines.events.on_gui_selection_state_changed] = function(e)
	local el = e.element
	if el.valid and (el.name == "router_group" or el.name == "router_interrupt") then
		panel.pick(game.get_player(e.player_index), el)
	end
end

local function strings(list)
	if type(list) ~= "table" then
		return false
	end
	for _, s in ipairs(list) do
		if type(s) ~= "string" then
			return false
		end
	end
	return true
end

--- ue.route.stations (§7.9): full (first part) empties the list; set entries are upserts into list[surface][name], each
--- with a string surface and name, string tiles and a number free, or skipped; gone entries must be { surface, name }
--- (R35). ponytail: a planet whose last name went keeps an empty table; it lists nothing.
bridge.on("universal_edges", "ue.route.stations", function(p)
	if type(p.set) ~= "table" or type(p.gone) ~= "table" then
		return false
	end
	local r = base.state()
	if p.full then
		r.list = {}
	end
	for _, e in ipairs(p.set) do
		if type(e) == "table" and type(e.surface) == "string" and type(e.name) == "string" and strings(e.tiles)
			and type(e.free) == "number" then
			r.list[e.surface] = r.list[e.surface] or {}
			r.list[e.surface][e.name] = { surface = e.surface, name = e.name, tiles = e.tiles, free = e.free }
		end
	end
	for _, g in ipairs(p.gone) do
		local names = type(g) == "table" and type(g.surface) == "string" and type(g.name) == "string" and r.list[g.surface]
		if names then
			names[g.name] = nil
		end
	end
	for _, player in pairs(game.connected_players) do
		if player.gui.screen[NAME] then
			panel.show(player, true)
		end
		if player.gui.relative[STOP_NAME] then
			panel.show_stop(player, true)
		end
	end
end)

-- ponytail: polling, not on_train_schedule_changed: unverified that interrupt edits raise that event in 2.1.
scheduler.periodic{
	name = "ue.routing.panel",
	interval = 30,
	fn = base.safe("ue.routing.panel", function()
		for _, player in pairs(game.connected_players) do
			panel.refresh(player)
		end
	end),
}

return panel
