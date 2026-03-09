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
local UI = require 'ui'

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
	discovery_pending = false,
	avahi_missing = false,

	-- menu state
	menu_page = "main", -- "main" | "type" | "port" | "discover"
	menu_list = nil, -- UI.List or UI.ScrollingList widget
	menu_message = nil, -- UI.Message widget (for status screens)
	menu_type = nil, -- "grid" or "arc" (selected in type page)
	menu_port = nil, -- 1-4 (selected in port page)
	menu_metro = nil,
}

-- max slots (norns has 4 ports each for grid and arc)
local MAX_SLOTS = vport_module.MAX_SLOTS

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

------------------------------------------
-- zeroconf discovery
------------------------------------------

-- Ensure avahi-utils is installed; called once at system_post_startup
local function ensure_avahi_installed()
	local check = util.os_capture("which avahi-browse 2>/dev/null")
	if check and check ~= "" then
		return true
	end
	print("oscgard: avahi-utils not found, installing...")
	os.execute("sudo apt-get install -y avahi-utils >/dev/null 2>&1")
	-- verify installation succeeded
	local recheck = util.os_capture("which avahi-browse 2>/dev/null")
	if recheck and recheck ~= "" then
		print("oscgard: avahi-utils installed successfully")
		return true
	end
	print("oscgard: failed to install avahi-utils")
	return false
end

-- Cache avahi-browse availability (checked once, not on every scan)
local avahi_checked = false
local avahi_available = false

-- Scan network for _osc._udp services using avahi-browse
-- Returns array of {name, host, port} or nil if avahi not available
local function scan_osc_services()
	-- Check if avahi-browse is available (once)
	if not avahi_checked then
		avahi_checked = true
		local check = util.os_capture("which avahi-browse 2>/dev/null")
		avahi_available = check and check ~= ""
	end
	if not avahi_available then
		oscgard.avahi_missing = true
		return nil
	end
	oscgard.avahi_missing = false

	local output = util.os_capture("timeout 3 avahi-browse -rtp _osc._udp 2>/dev/null")
	if not output or output == "" then
		return {}
	end

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

local rebuild_menu_list

-- Send /sys/info query to each discovered service
local function query_discovered_services(services)
	oscgard.discovered_devices = {}
	oscgard.discovery_pending = true

	for _, svc in ipairs(services) do
		-- Send /sys/info to each service; they respond with /sys/type, /sys/id, /sys/prefix, /sys/size
		osc.send({ svc.host, svc.port }, "/sys/info", {})
		-- Pre-populate name from avahi
		local key = svc.host .. ":" .. svc.port
		if not oscgard.discovered_devices[key] then
			oscgard.discovered_devices[key] = {
				host = svc.host,
				port = svc.port,
				name = svc.name,
			}
		else
			oscgard.discovered_devices[key].name = svc.name
		end
	end

	-- Set a timeout to mark discovery complete (reuse existing timer)
	if not oscgard.discovery_timer then
		oscgard.discovery_timer = metro.init()
		oscgard.discovery_timer.time = 1.5
		oscgard.discovery_timer.count = 1
		oscgard.discovery_timer.event = function()
			oscgard.discovery_pending = false
			rebuild_menu_list()
			mod.menu.redraw()
		end
	else
		oscgard.discovery_timer:stop()
	end
	oscgard.discovery_timer:start()
end

-- Start a full discovery scan (avahi-browse + /sys/info queries)
local function start_discovery()
	oscgard.discovered_devices = {}
	oscgard.discovery_pending = true

	local services = scan_osc_services()
	if services == nil then
		-- avahi not installed
		oscgard.discovery_pending = false
		return
	end

	if #services == 0 then
		oscgard.discovery_pending = false
		return
	end

	query_discovered_services(services)
end

-- Get filtered list of discovered devices for menu display
-- Returns array of discovered device entries matching the selected type
-- and not already assigned to any port
local function get_available_devices(device_type)
	local available = {}
	for _, entry in pairs(oscgard.discovered_devices) do
		if entry.type == device_type and not is_device_assigned(entry.host, entry.port) then
			table.insert(available, entry)
		end
	end
	-- Sort by name/id for stable ordering
	table.sort(available, function(a, b)
		return (a.name or a.id or "") < (b.name or b.id or "")
	end)
	return available
end

------------------------------------------
-- mod hooks
------------------------------------------

-- Store original _norns.osc.event handler
local original_norns_osc_event = nil

local function oscgard_osc_handler(path, args, from)
	-- Debug: print all incoming OSC
	-- print("oscgard osc:", path, from[1], from[2])

	local ip = from[1]
	local port = tonumber(from[2])
	if not port then return end

	-- ========================================
	-- /sys/* → discovery responses
	-- ========================================
	if path:sub(1, 5) == "/sys/" then
		if path == "/sys/type" and args[1] then
			accumulate_discovery(ip, port, "type", args[1])
			mod.menu.redraw()
			return
		end
		if path == "/sys/id" and args[1] then
			accumulate_discovery(ip, port, "id", args[1])
			mod.menu.redraw()
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
			mod.menu.redraw()
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
			avahi_available = ensure_avahi_installed()
			avahi_checked = true
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

-- Helper to get all connected devices for menu display
-- Returns: array of { device_type, slot, device }
local function get_all_connected_devices()
	local devices = {}
	for _, dtype in ipairs({ "grid", "arc" }) do
		local device_module = get_module(dtype)
		for slot = 1, MAX_SLOTS do
			local device = device_module.vports[slot].device
			if device then
				table.insert(devices, { device_type = dtype, slot = slot, device = device })
			end
		end
	end
	return devices
end

-- Get free ports for a device type
local function get_free_ports(dtype)
	local free = {}
	local vports = get_module(dtype).vports
	for i = 1, MAX_SLOTS do
		if not vports[i].device then
			table.insert(free, i)
		end
	end
	return free
end

local m = {}

-- Build/rebuild the UI list widget for the current menu page
rebuild_menu_list = function(preserve_index)
	local index = (preserve_index and oscgard.menu_list) and oscgard.menu_list.index or 1
	oscgard.menu_list = nil
	oscgard.menu_message = nil

	if oscgard.menu_page == "main" then
		local devices = get_all_connected_devices()
		local entries = {}
		for _, entry in ipairs(devices) do
			entries[#entries + 1] = entry.device_type .. " " .. entry.slot .. ": " .. (entry.device.serial or "?")
		end
		entries[#entries + 1] = "+ add device"
		oscgard.menu_list = UI.ScrollingList.new(0, 12, index, entries)
		oscgard.menu_list.num_visible = 4

	elseif oscgard.menu_page == "type" then
		oscgard.menu_list = UI.List.new(0, 12, index, { "grid", "arc" })

	elseif oscgard.menu_page == "port" then
		local free = get_free_ports(oscgard.menu_type)
		local entries = {}
		for _, port_num in ipairs(free) do
			entries[#entries + 1] = "port " .. port_num
		end
		if #entries > 0 then
			oscgard.menu_list = UI.List.new(0, 12, index, entries)
		else
			oscgard.menu_message = UI.Message.new({ "no free ports" })
		end

	elseif oscgard.menu_page == "discover" then
		if oscgard.avahi_missing then
			oscgard.menu_message = UI.Message.new({ "avahi-browse not found", "apt install avahi-utils" })
		elseif oscgard.discovery_pending then
			oscgard.menu_message = UI.Message.new({ "scanning..." })
		else
			local available = get_available_devices(oscgard.menu_type)
			if #available == 0 then
				oscgard.menu_message = UI.Message.new({ "no devices found", "K3:rescan" })
			else
				local entries = {}
				for _, entry in ipairs(available) do
					local label = entry.name or entry.id or (entry.host .. ":" .. entry.port)
					if entry.cols and entry.rows then
						label = label .. " " .. entry.cols .. "x" .. entry.rows
					end
					entries[#entries + 1] = label
				end
				oscgard.menu_list = UI.ScrollingList.new(0, 12, index, entries)
				oscgard.menu_list.num_visible = 4
			end
		end
	end
end

------------------------------------------
-- menu: key handler
------------------------------------------
m.key = function(n, z)
	if z ~= 1 then return end

	if oscgard.menu_page == "main" then
		if n == 2 then
			mod.menu.exit()
		elseif n == 3 and oscgard.menu_list then
			local devices = get_all_connected_devices()
			local total = #devices + 1 -- +1 for "add device" entry
			if oscgard.menu_list.index == total then
				-- "add device" selected -> go to type page
				oscgard.menu_page = "type"
				rebuild_menu_list()
			elseif oscgard.menu_list.index <= #devices then
				-- remove selected device
				local entry = devices[oscgard.menu_list.index]
				remove_device(entry.slot, entry.device_type)
				rebuild_menu_list(true)
			end
		end
	elseif oscgard.menu_page == "type" then
		if n == 2 then
			oscgard.menu_page = "main"
			rebuild_menu_list()
		elseif n == 3 and oscgard.menu_list then
			local types = { "grid", "arc" }
			oscgard.menu_type = types[oscgard.menu_list.index]
			local free = get_free_ports(oscgard.menu_type)
			if #free == 0 then
				oscgard.menu_page = "main"
				rebuild_menu_list()
			else
				oscgard.menu_page = "port"
				rebuild_menu_list()
			end
		end
	elseif oscgard.menu_page == "port" then
		if n == 2 then
			oscgard.menu_page = "type"
			rebuild_menu_list()
		elseif n == 3 and oscgard.menu_list then
			local free = get_free_ports(oscgard.menu_type)
			if oscgard.menu_list.index <= #free then
				oscgard.menu_port = free[oscgard.menu_list.index]
				oscgard.menu_page = "discover"
				start_discovery()
				rebuild_menu_list()
			end
		end
	elseif oscgard.menu_page == "discover" then
		if n == 2 then
			oscgard.menu_page = "port"
			oscgard.discovery_pending = false
			if oscgard.discovery_timer then
				oscgard.discovery_timer:stop()
				oscgard.discovery_timer = nil
			end
			rebuild_menu_list()
		elseif n == 3 and not oscgard.discovery_pending then
			local available = get_available_devices(oscgard.menu_type)
			if #available == 0 then
				start_discovery()
				rebuild_menu_list()
			elseif oscgard.menu_list and oscgard.menu_list.index <= #available then
				local entry = available[oscgard.menu_list.index]
				create_device(oscgard.menu_port, { entry.host, entry.port }, oscgard.menu_type, entry.cols, entry.rows,
					entry.id, entry.prefix, entry.rotation)
				print("oscgard: assigned " ..
					oscgard.menu_type .. " from " .. entry.host .. ":" .. entry.port .. " to port " .. oscgard.menu_port)
				oscgard.menu_page = "main"
				rebuild_menu_list()
			end
		end
	end

	mod.menu.redraw()
end

------------------------------------------
-- menu: encoder handler
------------------------------------------
m.enc = function(n, d)
	if n == 2 and oscgard.menu_list then
		oscgard.menu_list:set_index_delta(d)
	end
	mod.menu.redraw()
end

------------------------------------------
-- menu: redraw
------------------------------------------
m.redraw = function()
	screen.clear()

	-- Draw header
	screen.level(15)
	screen.move(64, 10)
	if oscgard.menu_page == "main" then
		screen.text_center("oscgard devices")
	elseif oscgard.menu_page == "type" then
		screen.text_center("select device type")
	elseif oscgard.menu_page == "port" then
		screen.text_center("select " .. oscgard.menu_type .. " port")
	elseif oscgard.menu_page == "discover" then
		screen.text_center(oscgard.menu_type .. " > port " .. oscgard.menu_port)
	end

	-- Draw content (list or message)
	if oscgard.menu_list then
		oscgard.menu_list:redraw()
	elseif oscgard.menu_message then
		oscgard.menu_message:redraw()
	end

	-- Draw footer hints
	screen.level(1)
	screen.move(0, 62)
	if oscgard.menu_page == "main" then
		screen.text("E2:sel K2:exit")
		screen.move(128, 62)
		if oscgard.menu_list then
			local devices = get_all_connected_devices()
			screen.text_right(oscgard.menu_list.index <= #devices and "K3:remove" or "K3:add")
		end
	elseif oscgard.menu_page == "type" then
		screen.text("E2:sel K2:back")
		screen.move(128, 62)
		screen.text_right("K3:select")
	elseif oscgard.menu_page == "port" then
		screen.text("E2:sel K2:back")
		screen.move(128, 62)
		if oscgard.menu_list then
			screen.text_right("K3:select")
		end
	elseif oscgard.menu_page == "discover" then
		screen.text("E2:sel K2:back")
		if not oscgard.avahi_missing and not oscgard.discovery_pending then
			screen.move(128, 62)
			if oscgard.menu_list then
				screen.text_right("K3:assign")
			else
				screen.text_right("K3:rescan")
			end
		end
	end

	screen.update()
end

------------------------------------------
-- menu: init/deinit
------------------------------------------
m.init = function()
	oscgard.menu_page = "main"
	oscgard.menu_type = nil
	oscgard.menu_port = nil
	rebuild_menu_list()
	-- Start metro for real-time menu updates (2 Hz = every 0.5 seconds)
	if oscgard.menu_metro then
		oscgard.menu_metro:stop()
	end
	oscgard.menu_metro = metro.init()
	oscgard.menu_metro.time = 0.5
	oscgard.menu_metro.event = function()
		mod.menu.redraw()
	end
	oscgard.menu_metro:start()
end

m.deinit = function()
	-- Stop metros when leaving menu
	if oscgard.menu_metro then
		oscgard.menu_metro:stop()
		oscgard.menu_metro = nil
	end
	if oscgard.discovery_timer then
		oscgard.discovery_timer:stop()
		oscgard.discovery_timer = nil
	end
	oscgard.discovery_pending = false
end

mod.menu.register("oscgard", m)

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
