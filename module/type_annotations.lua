---@meta
-- DO NOT REQUIRE THIS FILE ANYWHERE! THIS IS ONLY FOR INTELLISENSE



-- [CLASSES]

---@class UniversalEdgesTable
---@field GLOBAL_VERSION number
---@field barriers table<string, table<number, LuaEntity[]>>
---@field config UniversalEdgesConfig
---@field current_edge_id string
---@field debug_shapes table<number, LuaRenderObject>
---@field edges table<string, UniversalEdge>
---@field entity_last_positions table<string, table<string, MapPosition>>
---@field linked_power_update_tick number
---@field pathfinder table<string, number>
---@field players_waiting_to_join table<string, LuaEntity>
---@field players_waiting_to_leave table<string, LuaEntity>
---@field vehicle_drivers table<string, LuaEntity>
---@field vehicle_passengers table<string, LuaEntity>

---@class UniversalEdgesConfig
---@field instance_id number
---@field ticks_per_edge number

---@class UniversalEdge
---@field active boolean
---@field id string
---@field is_deleted boolean
---@field length number
---@field link_destinations table
---@field linked_belts table<number, LinkedBelt>
---@field linked_belts_state LinkedBeltState
---@field linked_fluids table<number, table<string, LuaEntity>>
---@field linked_fluids_state LinkedFluidState
---@field linked_power table<number, LinkedPower>
---@field linked_power_state LinkedPowerState
---@field linked_trains table<number, TrainLink>
---@field linked_trains_state TrainLinkState
---@field pending_train_transfers table
---@field poll_connectors_state PollConnectorsState
---@field source EdgeSourceOrTarget
---@field target EdgeSourceOrTarget
---@field updateAtMs uint

---@class EdgeSourceOrTarget
---@field direction uint32
---@field instanceId uint32
---@field origin Vector
---@field ready boolean
---@field surface string

---@class TrainLink
---@field debug_visu table
---@field is_input boolean
---@field last_penalty_map_update table
---@field parking_area_size number
---@field penalty_rails table<number, LuaEntity>
---@field previous_flow_state boolean
---@field previous_signal_state number
---@field rails table<number, LuaEntity>
---@field set_flow boolean
---@field signal LuaEntity
---@field stop LuaEntity

---@class TrainLinkState
---@field endpoint number
---@field index number
---@field pos number

---@class PollConnectorsState
---@field endpoint number
---@field index number
---@field pos number

---@class LinkedBelt
---@field chest LuaEntity
---@field is_input boolean
---@field start_index number

---@class LinkedBeltState
---@field endpoint number
---@field index number
---@field pos number

---@class LinkedFluid
---@field pipe LuaEntity

---@class LinkedFluidState
---@field endpoint number
---@field index number
---@field pos number

---@class LinkedPower
---@field charge_sensor LuaEntity
---@field eei LuaEntity
---@field powerpole LuaEntity
---@field lua_buffered_energy number

---@class LinkedPowerState
---@field endpoint number
---@field index number
---@field pos number
