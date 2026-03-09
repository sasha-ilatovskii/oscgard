-- vport_module.lua
-- Shared vport module factory for oscgard device modules
-- Provides common vport management (connect, disconnect, slot lookup)
-- so that oscgard_grid and oscgard_arc only define device-specific logic.

local vport_module = {}

-- Single source of truth for max device slots (norns has 4 ports each)
vport_module.MAX_SLOTS = 4

--- Create a new device module with shared vport management.
-- @param device_type: string label for logging (e.g. "grid", "arc")
-- @param create_vport_fn: function() returning a fresh vport table
-- @return module table with vports, shared functions, and add/remove callback slots
function vport_module.new(device_type, create_vport_fn)
	local max_slots = vport_module.MAX_SLOTS

	-- Initialize vports
	local vports = {}
	for i = 1, max_slots do
		vports[i] = create_vport_fn()
	end

	local module = {
		vports = vports,
		add = nil, -- callback function(vport) called when device connects
		remove = nil, -- callback function(vport) called when device disconnects
	}

	-- Remove device from vport
	function module.destroy_vport(slot)
		local vport = vports[slot]
		local device = vport.device
		if not device then return end

		if module.remove then
			module.remove(vport)
		end

		device:cleanup()

		print("oscgard: " .. device_type .. " removed from slot " .. slot)

		vport.device = nil
		vport.name = "none"
	end

	-- Public API (matches norns connect style)
	function module.connect(port)
		port = port or 1
		return vports[port]
	end

	function module.connect_any()
		for i = 1, max_slots do
			if vports[i].device then
				return vports[i]
			end
		end
		return nil
	end

	function module.disconnect(slot)
		module.destroy_vport(slot)
	end

	function module.get_slots()
		return vports
	end

	function module.get_device(slot)
		return vports[slot] and vports[slot].device
	end

	return module
end

return vport_module
