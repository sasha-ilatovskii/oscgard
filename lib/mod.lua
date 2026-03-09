-- oscgard mod
-- OSC-to-grid adapter for norns
--
-- Oscgard intercepts grid/arc API calls and routes them to any OSC client
-- app implementing the oscgard + monome device specifications.
--
-- Devices are discovered via zeroconf (avahi-browse) and assigned to ports
-- through the mod menu. Each emulated device runs its own OSC service
-- advertised as _osc._udp.
--
-- Script integration:
--   local grid = include("oscgard/lib/grid")
-- Or with hardware fallback:
--   local grid = util.file_exists(_path.code.."oscgard") and include("oscgard/lib/grid") or grid

-- Prevent multiple loading
if _G.oscgard_mod_loaded then
	return _G.oscgard_mod_instance
end

print("oscgard mod: loading...")

local mod = require 'core/mods'
-- Virtual device modules
local vport_module = include 'oscgard/lib/vport_module'
local grid_module = include 'oscgard/lib/oscgard_grid'
local arc_module = include 'oscgard/lib/oscgard_arc'

------------------------------------------
-- state
------------------------------------------

local oscgard = {
	-- mod state
	initialized = false,

	-- device modules
	grid = grid_module,
	arc = arc_module,

	-- discovery state
	discovered_devices = {}, -- keyed by "host:port", value = {host, port, type, id, prefix, cols, rows, name}

	-- menu metro (managed in mod_menu init/deinit)
	menu_metro = nil,

	-- discovery clock (managed in mod_menu start_discovery)
	discovery_clock = nil,

	-- callback set by mod_menu for OSC-driven screen updates
	mark_menu_dirty = nil,
}

-- max slots (norns has 4 ports each for grid and arc)
local MAX_SLOTS = vport_module.MAX_SLOTS

-- Temp file for non-blocking avahi-browse output
local AVAHI_TMP = "/tmp/oscgard_avahi_result.txt"
local SCAN_DURATION = 5

-- Expose constants for mod_menu
oscgard.MAX_SLOTS = MAX_SLOTS
oscgard.SCAN_DURATION = SCAN_DURATION
oscgard.AVAHI_TMP = AVAHI_TMP

------------------------------------------
-- slot management
------------------------------------------

local function get_module(device_type)
	return oscgard[device_type]
end

local function find_client_slot(ip, port, device_type)
	local vports = get_module(device_type).vports
	for i = 1, MAX_SLOTS do
		local device = vports[i].device
		if device and device.client[1] == ip and device.client[2] == port then
			return i
		end
	end
	return nil
end

-- Find assigned device by IP, port, and OSC path prefix
-- Used for incoming device messages where we match all three to support
-- multiple devices on the same IP with different ports/prefixes
local function find_device_by_address(ip, port, path)
	for _, device_type in ipairs({ "grid", "arc" }) do
		local vports = get_module(device_type).vports
		for i = 1, MAX_SLOTS do
			local device = vports[i].device

			if device and device.client[1] == ip and device.client[2] == port
				and device.prefix
				and #path > #device.prefix
				and path:sub(1, #device.prefix) == device.prefix
				and path:sub(#device.prefix + 1, #device.prefix + 1) == "/" then
				return i, device_type, device
			end
		end
	end
	return nil, nil, nil
end

-- Check if a device (by host:port) is already assigned to any slot
local function is_device_assigned(host, port)
	for _, device_type in ipairs({ "grid", "arc" }) do
		if find_client_slot(host, port, device_type) then
			return true
		end
	end
	return false
end

oscgard.is_device_assigned = is_device_assigned

------------------------------------------
-- device management
------------------------------------------

local function create_device(slot, client, device_type, cols, rows, serial, prefix, rotation)
	device_type = device_type or "grid"
	local device_module = get_module(device_type)

	-- delegate to module's create_vport
	local device = device_module.create_vport(slot, client, cols, rows, serial)

	-- set prefix from discovery response
	if prefix then
		device.prefix = prefix
	end

	-- apply initial rotation from discovery
	if rotation and device.rotation then
		device:rotation(rotation)
		local vport = device_module.vports[slot]
		vport.cols = device.logical_cols
		vport.rows = device.logical_rows
	end

	return device
end

local function remove_device(slot, device_type)
	device_type = device_type or "grid"
	get_module(device_type).destroy_vport(slot)
end

oscgard.create_device = create_device
oscgard.remove_device = remove_device

------------------------------------------
-- zeroconf discovery (parsing only — scan flow is in mod_menu)
------------------------------------------

-- Parse avahi-browse -rtp output into array of {name, host, port}
local function parse_avahi_output(output)
	if not output or output == "" then return {} end

	local services = {}
	local seen = {} -- dedup by host:port
	for record in output:gmatch("[^%s]+") do
		if record:sub(1, 1) == "=" then
			-- Parse semicolon-delimited fields:
			-- =;interface;protocol;name;type;domain;hostname;address;port;txt
			local fields = {}
			for field in record:gmatch("[^;]+") do
				table.insert(fields, field)
			end
			-- fields[1]="=", [2]=iface, [3]=protocol, [4]=name, [5]=type,
			-- [6]=domain, [7]=hostname, [8]=address, [9]=port
			if fields[3] == "IPv4" and fields[4] and fields[8] and fields[9] then
				local host = fields[8]
				local svc_port = tonumber(fields[9])
				local key = host .. ":" .. svc_port
				-- Skip loopback and already-seen entries
				if host ~= "127.0.0.1" and not seen[key] then
					seen[key] = true
					table.insert(services, {
						name = fields[4],
						host = host,
						port = svc_port
					})
				end
			end
		end
	end
	return services
end

oscgard.parse_avahi_output = parse_avahi_output

-- Accumulate discovery response from a queried device
local function accumulate_discovery(ip, port, field, value)
	local key = ip .. ":" .. port
	if not oscgard.discovered_devices[key] then
		oscgard.discovered_devices[key] = {
			host = ip,
			port = port,
		}
	end
	local entry = oscgard.discovered_devices[key]

	if field == "size" then
		entry.cols = value[1]
		entry.rows = value[2]
	else
		entry[field] = value
	end
end

local function mark_dirty()
	if oscgard.mark_menu_dirty then oscgard.mark_menu_dirty() end
end

------------------------------------------
-- mod hooks
------------------------------------------

-- Store original _norns.osc.event handler
local original_norns_osc_event = nil

local function oscgard_osc_handler(path, args, from)
	local ip = from[1]
	local port = tonumber(from[2])
	if not port then return end

	-- ========================================
	-- /sys/* → discovery responses
	-- ========================================
	if path:sub(1, 5) == "/sys/" then
		if path == "/sys/type" and args[1] then
			accumulate_discovery(ip, port, "type", args[1])
			mark_dirty()
			return
		end
		if path == "/sys/id" and args[1] then
			accumulate_discovery(ip, port, "id", args[1])
			mark_dirty()
			return
		end
		if path == "/sys/prefix" and args[1] then
			accumulate_discovery(ip, port, "prefix", args[1])
			return
		end
		if path == "/sys/size" and args[1] and args[2] then
			local cols = math.floor(args[1])
			local rows = math.floor(args[2])
			accumulate_discovery(ip, port, "size", { cols, rows })
			-- Update live device if already assigned
			for _, dtype in ipairs({ "grid", "arc" }) do
				local slot = find_client_slot(ip, port, dtype)
				if slot then
					local device_module = get_module(dtype)
					local vport = device_module.vports[slot]
					local device = vport.device
					if device and (device.cols ~= cols or device.rows ~= rows) then
						device.cols = cols
						device.rows = rows
						device.logical_cols = cols
						device.logical_rows = rows
						vport.cols = cols
						vport.rows = rows
						-- Re-apply rotation to recompute logical dims
						if device.rotation_val and device.rotation_val ~= 0 then
							device:rotation(device.rotation_val)
							vport.cols = device.logical_cols
							vport.rows = device.logical_rows
						end
					end
				end
			end
			mark_dirty()
			return
		end
		if path == "/sys/sensors" and args[1] then
			accumulate_discovery(ip, port, "sensors", math.floor(args[1]))
			return
		end
		if path == "/sys/rotation" and args[1] then
			local rot = math.floor(args[1])
			accumulate_discovery(ip, port, "rotation", rot)
			-- Update live device if already assigned
			for _, dtype in ipairs({ "grid" }) do
				local slot = find_client_slot(ip, port, dtype)
				if slot then
					local device_module = get_module(dtype)
					local vport = device_module.vports[slot]
					local device = vport.device
					if device and device.rotation_val ~= rot then
						device:rotation(rot)
						vport.cols = device.logical_cols
						vport.rows = device.logical_rows
					end
				end
			end
			return
		end
		return
	end

	-- ========================================
	-- Everything else → match against assigned devices
	-- ========================================
	local _, _, device = find_device_by_address(ip, port, path)

	if device then
		local prefix = device.prefix

		if grid_module.handle_osc(path, args, device, prefix) then
			return
		end

		if arc_module.handle_osc(path, args, device, prefix) then
			return
		end
	end

	-- call original handler for everything else
	if original_norns_osc_event then
		original_norns_osc_event(path, args, from)
	end
end

-- Initialize OSC handler immediately (for script include mode)
-- This allows oscgard to work even when not loaded as a mod
local function init_osc_handler()
	if not oscgard.initialized and _norns and _norns.osc then
		print("oscgard: hooking _norns.osc.event")
		original_norns_osc_event = _norns.osc.event
		_norns.osc.event = oscgard_osc_handler
		oscgard.initialized = true
		print("oscgard: ready for connections")
	end
end

-- Try to initialize immediately (works when included from script after system startup)
init_osc_handler()

-- Also register hooks for proper mod loading (only if mod system is available)
if mod and mod.hook and mod.hook.register then
	-- Check if hooks are already registered by looking for our init flag
	if not _G.oscgard_hooks_registered then
		_G.oscgard_hooks_registered = true

		mod.hook.register("system_post_startup", "oscgard init", function()
			init_osc_handler()
		end)

		mod.hook.register("system_pre_shutdown", "oscgard cleanup", function()
			print("oscgard: shutdown")

			if oscgard.initialized then
				-- Cleanup both grid and arc devices
				for _, dtype in ipairs({ "grid", "arc" }) do
					local device_module = get_module(dtype)
					for slot = 1, MAX_SLOTS do
						if device_module.vports[slot].device then
							remove_device(slot, dtype)
						end
					end
				end

				-- restore original _norns.osc.event
				if original_norns_osc_event then
					_norns.osc.event = original_norns_osc_event
					original_norns_osc_event = nil
				end

				oscgard.initialized = false
			end
		end)

		mod.hook.register("script_post_cleanup", "oscgard script cleanup", function()
			print("calling: oscgard script cleanup")
			-- Clear both grid and arc devices when script changes
			for _, dtype in ipairs({ "grid", "arc" }) do
				local device_module = get_module(dtype)
				for i = 1, MAX_SLOTS do
					local device = device_module.vports[i].device
					if device then
						device:all(0)
						if device.force_refresh then
							device:force_refresh()
						end
					end
				end
			end
		end)
	end
end

------------------------------------------
-- mod menu
------------------------------------------

local create_menu = dofile(_path.code .. "oscgard/lib/mod_menu.lua")
mod.menu.register("oscgard", create_menu(oscgard))

------------------------------------------
-- public API
------------------------------------------

-- Note: The grid and arc modules already export their public APIs
-- (connect, connect_any, disconnect, get_slots, get_device)
-- These are available via oscgard.grid.* and oscgard.arc.*

-- Mark as loaded and store instance for reuse
_G.oscgard_mod_loaded = true
_G.oscgard_mod_instance = oscgard

return oscgard
