-- oscgard mod menu
-- Reactive UI for device management
--
-- Receives the oscgard core table and registers the mod menu.
-- Follows the reactive UI pattern: watchtable state → pure view → renderer.

local mod = require 'core/mods'
local watchtable = require 'container/watchtable'
local UI = require 'ui'

local function create(oscgard)
	------------------------------------------
	-- reactive UI state
	------------------------------------------

	local function menu_redraw()
		mod.menu.redraw()
	end

	local state = watchtable.new({
		page = "main", -- "main" | "type" | "discover"
		device_type = nil, -- "grid" or "arc" (selected in type page)
		port = nil,   -- 1-4 (auto-assigned, next free port)
		device_idx = 1, -- selected device on main page (N+1 = "add new")
		type_idx = 1, -- 1=grid, 2=arc on type page
		result_idx = 1, -- selected result on discover page
		scan_remaining = 0, -- countdown seconds left
		discovery_pending = false,
		avahi_missing = false,
	}, menu_redraw)

	-- Allow OSC handler in mod.lua to mark menu dirty
	oscgard.mark_menu_dirty = menu_redraw

	local MAX_SLOTS = oscgard.MAX_SLOTS
	local SCAN_DURATION = oscgard.SCAN_DURATION
	local AVAHI_TMP = oscgard.AVAHI_TMP

	------------------------------------------
	-- helpers
	------------------------------------------

	local function clamp_idx(idx, max)
		if max <= 0 then return 1 end
		if idx < 1 then return 1 end
		if idx > max then return max end
		return idx
	end

	local function get_all_connected_devices()
		local devices = {}
		for _, dtype in ipairs({ "grid", "arc" }) do
			local device_module = oscgard[dtype]
			for slot = 1, MAX_SLOTS do
				local device = device_module.vports[slot].device
				if device then
					table.insert(devices, { device_type = dtype, slot = slot, device = device })
				end
			end
		end
		return devices
	end

	local function get_free_ports(dtype)
		local free = {}
		local vports = oscgard[dtype].vports
		for i = 1, MAX_SLOTS do
			if not vports[i].device then
				table.insert(free, i)
			end
		end
		return free
	end

	local function get_available_devices(device_type)
		local available = {}
		for _, entry in pairs(oscgard.discovered_devices) do
			if entry.type == device_type and not oscgard.is_device_assigned(entry.host, entry.port) then
				table.insert(available, entry)
			end
		end
		table.sort(available, function(a, b)
			return (a.name or a.id or "") < (b.name or b.id or "")
		end)
		return available
	end

	------------------------------------------
	-- discovery
	------------------------------------------

	local avahi_checked = false
	local avahi_available = false

	local function start_discovery()
		if oscgard.discovery_clock then
			clock.cancel(oscgard.discovery_clock)
			oscgard.discovery_clock = nil
		end

		oscgard.discovered_devices = {}
		state.discovery_pending = true
		state.scan_remaining = SCAN_DURATION
		state.result_idx = 1

		if not avahi_checked then
			avahi_checked = true
			local check = util.os_capture("which avahi-browse 2>/dev/null")
			avahi_available = check and check ~= ""
		end
		if not avahi_available then
			state.avahi_missing = true
			state.discovery_pending = false
			return
		end
		state.avahi_missing = false

		oscgard.discovery_clock = clock.run(function()
			os.execute("rm -f " .. AVAHI_TMP)
			os.execute("timeout " .. SCAN_DURATION .. " avahi-browse -rtp _osc._udp 2>/dev/null > " .. AVAHI_TMP .. " &")

			local queried = {}

			for s = SCAN_DURATION, 1, -1 do
				if not state.discovery_pending then
					oscgard.discovery_clock = nil
					return
				end
				state.scan_remaining = s
				clock.sleep(1)

				local f = io.open(AVAHI_TMP, "r")
				if f then
					local output = f:read("*a")
					f:close()
					local services = oscgard.parse_avahi_output(output)
					for _, svc in ipairs(services) do
						local key = svc.host .. ":" .. svc.port
						if not queried[key] then
							queried[key] = true
							oscgard.discovered_devices[key] = oscgard.discovered_devices[key] or {
								host = svc.host,
								port = svc.port,
							}
							oscgard.discovered_devices[key].name = svc.name
							osc.send({ svc.host, svc.port }, "/sys/info", {})
						end
					end
				end
			end

			if not state.discovery_pending then
				oscgard.discovery_clock = nil
				return
			end

			local f = io.open(AVAHI_TMP, "r")
			if f then
				local output = f:read("*a")
				f:close()
				local services = oscgard.parse_avahi_output(output)
				for _, svc in ipairs(services) do
					local key = svc.host .. ":" .. svc.port
					if not queried[key] then
						queried[key] = true
						oscgard.discovered_devices[key] = oscgard.discovered_devices[key] or {
							host = svc.host,
							port = svc.port,
						}
						oscgard.discovered_devices[key].name = svc.name
						osc.send({ svc.host, svc.port }, "/sys/info", {})
					end
				end
			end

			clock.sleep(0.5)

			state.discovery_pending = false
			oscgard.discovery_clock = nil
		end)
	end

	------------------------------------------
	-- key handler (state mutations only)
	------------------------------------------

	local m = {}

	m.key = function(n, z)
		if z ~= 1 then return end

		if state.page == "main" then
			if n == 2 then
				mod.menu.exit()
			elseif n == 3 then
				local devices = get_all_connected_devices()
				local has_add = #get_free_ports("grid") > 0 or #get_free_ports("arc") > 0
				if has_add and state.device_idx > #devices then
					state.page = "type"
					state.type_idx = 1
				elseif state.device_idx <= #devices then
					local entry = devices[state.device_idx]
					oscgard.remove_device(entry.slot, entry.device_type)
					local new_devices = get_all_connected_devices()
					state.device_idx = clamp_idx(state.device_idx - 1, #new_devices + (has_add and 1 or 0))
				end
			end
		elseif state.page == "type" then
			if n == 2 then
				state.page = "main"
			elseif n == 3 then
				local types = { "grid", "arc" }
				state.device_type = types[state.type_idx]
				local free = get_free_ports(state.device_type)
				if #free == 0 then
					state.page = "main"
				else
					state.port = free[1]
					state.page = "discover"
					start_discovery()
				end
			end
		elseif state.page == "discover" then
			if n == 2 then
				state.page = "type"
				state.discovery_pending = false
				if oscgard.discovery_clock then
					clock.cancel(oscgard.discovery_clock)
					oscgard.discovery_clock = nil
				end
			elseif n == 3 then
				if state.discovery_pending then
					state.discovery_pending = false
					if oscgard.discovery_clock then
						clock.cancel(oscgard.discovery_clock)
						oscgard.discovery_clock = nil
					end
				else
					local available = get_available_devices(state.device_type)
					if #available > 0 and state.result_idx <= #available then
						local entry = available[state.result_idx]
						oscgard.create_device(state.port, { entry.host, entry.port }, state.device_type,
							entry.cols, entry.rows, entry.id, entry.prefix, entry.rotation)
						print("oscgard: assigned " ..
							state.device_type .. " from " .. entry.host .. ":" .. entry.port ..
							" to port " .. state.port)
						state.page = "main"
						state.device_idx = #get_all_connected_devices()
					end
				end
			end
		end
	end

	------------------------------------------
	-- encoder handler (state mutations only)
	------------------------------------------

	m.enc = function(n, d)
		if state.page == "main" then
			if n == 2 then
				local devices = get_all_connected_devices()
				local has_add = #get_free_ports("grid") > 0 or #get_free_ports("arc") > 0
				local total = #devices + (has_add and 1 or 0)
				state.device_idx = clamp_idx(state.device_idx + d, total)
			elseif n == 3 then
				local devices = get_all_connected_devices()
				if state.device_idx <= #devices then
					local entry = devices[state.device_idx]
					local want_compat = d > 0
					if entry.device.compat_mode ~= want_compat then
						entry.device.compat_mode = want_compat
						menu_redraw()
					end
				end
			end
		elseif state.page == "type" then
			if n == 2 then
				state.type_idx = clamp_idx(state.type_idx + d, 2)
			end
		elseif state.page == "discover" then
			if not state.discovery_pending then
				if n == 2 then
					local available = get_available_devices(state.device_type)
					state.result_idx = clamp_idx(state.result_idx + d, #available)
				elseif n == 3 and d > 0 then
					start_discovery()
				end
			end
		end
	end

	------------------------------------------
	-- view (pure functions of state → node tables)
	------------------------------------------

	-- Node types:
	--   inv_header: {type="inv_header", text=string, x=n, y=n, size=n}
	--   text:       {type="text", text=string, x=n, y=n, level=n, size=n, align="left"|"right"|"center", valign="baseline"|"top"|"center", max_width=n}
	--   pages:      {type="pages", index=n, total=n}

	local function main_view()
		local nodes = {
			{ type = "inv_header", text = "OSCGARD", x = 0, y = 0 },
			{ type = "text", text = "[K2] EXIT", x = 128, y = 2, level = 3, align = "right", valign = 'top' },
		}

		local devices = get_all_connected_devices()
		local has_add = #get_free_ports("grid") > 0 or #get_free_ports("arc") > 0
		local idx = state.device_idx

		if #devices == 0 then
			nodes[#nodes + 1] = {
				type = "text",
				text = "no devices",
				x = 0,
				y = 32,
				level = 15,
				size = 16,
				align =
				"left",
				valign = 'center'
			}
			if has_add then
				nodes[#nodes + 1] = { type = "text", text = "[K3] ADD", x = 0, y = 64, level = 3 }
			end
		elseif idx <= #devices then
			local entry = devices[idx]
			local dev = entry.device
			local name = dev.serial or dev.id or "?"
			local size_str = entry.device_type == "arc"
				and (dev.num_encoders or "?") .. " encs"
				or (dev.cols or "?") .. "x" .. (dev.rows or "?")
			local type_str = entry.device_type
			if dev.compat_mode then type_str = type_str .. " [C]" end

			nodes[#nodes + 1] = {
				type = "text",
				text = string.upper(name),
				x = 0,
				y = 16,
				level = 15,
				size = 16,
				valign = 'top',
				max_width = 100
			}
			nodes[#nodes + 1] = {
				type = "text",
				text = size_str .. " " .. type_str,
				x = 0,
				y = 28,
				level = 7,
				valign =
				'top'
			}

			nodes[#nodes + 1] = {
				type = "text",
				text = entry.device.client[1] .. ":" .. entry.device.client[2] .. " " .. entry.device.prefix,
				x = 0,
				y = 35,
				level = 7,
				valign = 'top'
			}
			if has_add then
				nodes[#nodes + 1] = { type = "text", text = "[K3] REMOVE", x = 0, y = 50, level = 3 }
				nodes[#nodes + 1] = { type = "text", text = "[E2] PREV/NEXT [E3] PERF/CMPT", x = 0, y = 57, level = 3 }
				nodes[#nodes + 1] = { type = "text", text = "SCROLL DOWN TO ADD NEW", x = 0, y = 64, level = 3 }
			else
				nodes[#nodes + 1] = { type = "text", text = "[K3] REMOVE", x = 0, y = 57, level = 3 }
				nodes[#nodes + 1] = { type = "text", text = "[E2] PREV/NEXT [E3] PERF/CMPT", x = 0, y = 64, level = 3 }
			end
		else
			nodes[#nodes + 1] = { type = "text", text = "add new", y = 38, level = 15, size = 16, align = "center" }
			nodes[#nodes + 1] = { type = "text", text = "[K3] ADD", x = 0, y = 64, level = 3 }
		end

		local total = #devices + (has_add and 1 or 0)
		if total > 1 then
			nodes[#nodes + 1] = { type = "pages", index = idx, total = total }
		end

		return nodes
	end

	local function type_view()
		local types_list = { "GRD", "ARC" }
		local nodes = {
			{ type = "inv_header", text = "SELECT TYPE" },
			{
				type = "text",
				text = "[K2] BACK",
				x = 128,
				y = 2,
				level = 3,
				align = "right",
				valign =
				'top'
			}
		}

		local x = 0
		for i, t in ipairs(types_list) do
			local active = state.type_idx == i
			local label = (active and ">" or " ") .. t
			nodes[#nodes + 1] = {
				type = "text",
				text = label,
				x = x,
				y = 32,
				level = active and 15 or 3,
				size = 16,
				valign =
				'center'
			}
			x = x + 40
		end

		nodes[#nodes + 1] = { type = "text", text = "[E3] SELECT [K3] SCAN", x = 0, y = 64, level = 3 }
		return nodes
	end

	local function discover_view()
		local nodes = {}

		if state.avahi_missing then
			nodes[#nodes + 1] = { type = "inv_header", text = "ERROR" }
			nodes[#nodes + 1] = {
				type = "text",
				text = "[K2] BACK",
				x = 128,
				y = 2,
				level = 3,
				align = "right",
				valign =
				'top'
			}
			nodes[#nodes + 1] = { type = "text", text = "avahi-browse not found", x = 0, y = 26, level = 7 }
			nodes[#nodes + 1] = { type = "text", text = "apt install avahi-utils", x = 0, y = 34, level = 7 }
		elseif state.discovery_pending then
			local remaining = state.scan_remaining
			local count = #get_available_devices(state.device_type)

			nodes[#nodes + 1] = { type = "inv_header", text = "SCANNING" }
			nodes[#nodes + 1] = {
				type = "text",
				text = "[K2] BACK",
				x = 128,
				y = 2,
				level = 3,
				align = "right",
				valign =
				'top'
			}
			nodes[#nodes + 1] = {
				type = "text",
				text = remaining .. " sec left",
				x = 0,
				y = 23,
				level = 15,
				size = 16,
				valign =
				'top'
			}
			nodes[#nodes + 1] = {
				type = "text",
				text = count ..
					" " .. state.device_type .. (count ~= 1 and 's ' or ' ') .. "found",
				x = 0,
				y = 35,
				level = 15,
				size = 16,
				valign = 'top'
			}
			nodes[#nodes + 1] = { type = "text", text = "[K3] STOP", x = 0, y = 64, level = 3 }
		else
			local available = get_available_devices(state.device_type)

			nodes[#nodes + 1] = { type = "inv_header", text = "SCANNING RESULTS" }
			nodes[#nodes + 1] = {
				type = "text",
				text = "[K2] BACK",
				x = 128,
				y = 2,
				level = 3,
				align = "right",
				valign =
				'top'
			}

			if #available == 0 then
				nodes[#nodes + 1] = {
					type = "text",
					text = "NOTHING",
					y = 23,
					level = 15,
					size = 16,
					align = "left",
					valign =
					'top'
				}
				nodes[#nodes + 1] = {
					type = "text",
					text = "TO ADD",
					y = 35,
					level = 15,
					size = 16,
					align = "left",
					valign =
					'top'
				}
				nodes[#nodes + 1] = { type = "text", text = "[E3 CW] RESCAN", x = 0, y = 64, level = 3 }
			else
				local result_idx = clamp_idx(state.result_idx, #available)
				local entry = available[result_idx]
				local name = entry.id or entry.name or "?"
				local info = state.device_type == "arc"
					and "encoders: " .. (entry.sensors or entry.cols or "?")
					or "size: " .. (entry.cols or "?") .. "x" .. (entry.rows or "?")

				nodes[#nodes + 1] = {
					type = "text",
					text = string.upper(name),
					x = 0,
					y = 12,
					level = 15,
					size = 16,
					max_width = 100,
					valign =
					'top'
				}
				nodes[#nodes + 1] = {
					type = "text",
					text = 'prefix: ' .. entry.prefix,
					x = 0,
					y = 25,
					level = 7,
					valign =
					'top'
				}
				nodes[#nodes + 1] = { type = "text", text = info, x = 0, y = 33, level = 7, valign = 'top' }
				nodes[#nodes + 1] = {
					type = "text",
					text = "loc: " .. entry.host .. ":" .. entry.port,
					x = 0,
					y = 41,
					level = 7,
					valign =
					'top'
				}
				if #available > 1 then
					nodes[#nodes + 1] = { type = "text", text = "[E2] PREV/NEXT [K3] ADD", x = 0, y = 57, level = 3 }
				else
					nodes[#nodes + 1] = { type = "text", text = "[K3] ADD", x = 0, y = 57, level = 3 }
				end
				nodes[#nodes + 1] = { type = "text", text = "[E3 CW] RESCAN", x = 0, y = 64, level = 3 }
				if #available > 1 then
					nodes[#nodes + 1] = { type = "pages", index = result_idx, total = #available }
				end
			end
		end

		return nodes
	end

	local function view()
		if state.page == "main" then
			return main_view()
		elseif state.page == "type" then
			return type_view()
		elseif state.page == "discover" then
			return discover_view()
		end
		return {}
	end

	------------------------------------------
	-- renderer (draws nodes, never reads state)
	------------------------------------------

	local function render_node(node)
		if node.type == "inv_header" then
			screen.font_face(1)
			local fsize = node.size or 8
			screen.font_size(fsize)
			local cap_h = math.floor(fsize * 5 / 8)
			local w = screen.text_extents(node.text) + 4
			local h = cap_h + 4
			screen.level(15)
			screen.rect(node.x or 0, node.y or 0, w, h)
			screen.fill()
			screen.level(0)
			screen.move((node.x or 0) + 2, (node.y or 0) + cap_h + 2)
			screen.text(node.text)
		elseif node.type == "text" then
			screen.font_face(1)
			local fsize = node.size or 8
			screen.font_size(fsize)
			screen.level(node.level or 15)
			local y = node.y or 0
			local cap_h = math.floor(fsize * 5 / 8)
			local valign = node.valign or "baseline"
			if valign == "top" then
				y = y + cap_h
			elseif valign == "center" then
				y = y + math.floor(cap_h / 2)
			end
			if node.max_width then
				screen.move(node.x or 0, y)
				screen.text_trim(node.text, node.max_width)
			else
				local align = node.align or "left"
				if align == "right" then
					screen.move(node.x or 128, y)
					screen.text_right(node.text)
				elseif align == "center" then
					local cx = node.x or 64
					screen.move(cx - screen.text_extents(node.text) / 2, y)
					screen.text(node.text)
				else
					screen.move(node.x or 0, y)
					screen.text(node.text)
				end
			end
		elseif node.type == "pages" then
			local p = UI.Pages.new(node.index, node.total)
			p:redraw()
		end
	end

	local function render(nodes)
		screen.aa(0)
		for _, node in ipairs(nodes) do
			render_node(node)
		end
	end

	------------------------------------------
	-- redraw
	------------------------------------------

	m.redraw = function()
		screen.clear()
		render(view())
		screen.update()
	end

	------------------------------------------
	-- init / deinit
	------------------------------------------

	m.init = function()
		state.page = "main"
		state.device_type = nil
		state.port = nil
		state.device_idx = 1
		state.type_idx = 1
		state.result_idx = 1
		menu_redraw()
	end

	m.deinit = function()
		screen.font_face(1)
		screen.font_size(8)
		if oscgard.discovery_clock then
			clock.cancel(oscgard.discovery_clock)
			oscgard.discovery_clock = nil
		end
		state.discovery_pending = false
	end

	return m
end

return create
