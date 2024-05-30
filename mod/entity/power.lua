--[[
	Create electric energy interfaces used for power connections
]]

local eei_input = table.deepcopy(data.raw["electric-energy-interface"]["electric-energy-interface"])
eei_input.name = "ue_eei_input"
eei_input.energy_production = "0MW"
eei_input.energy_source.usage_priority = "secondary-input"
eei_input.energy_source.buffer_capacity = "100MJ"

local eei_output = table.deepcopy(data.raw["electric-energy-interface"]["electric-energy-interface"])
eei_output.name = "ue_eei_output"
eei_output.energy_production = "0MW"
eei_output.energy_source.usage_priority = "secondary-output"
eei_output.energy_source.buffer_capacity = "100MJ"

local eei_tertiary = table.deepcopy(data.raw["electric-energy-interface"]["electric-energy-interface"])
eei_tertiary.name = "ue_eei_tertiary"
eei_tertiary.energy_production = "0MW"
eei_tertiary.energy_source.usage_priority = "tertiary"
eei_tertiary.energy_source.buffer_capacity = "100MJ"

data:extend { eei_input, eei_output, eei_tertiary }
