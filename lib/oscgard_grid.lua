-- oscgard_grid.lua
-- Virtual grid module for oscgard
-- Manages grid devices, vports, and grid-specific OSC protocol

local Buffer = include 'oscgard/lib/buffer'
local vport_module = include 'oscgard/lib/vport_module'

------------------------------------------
-- OscgardGrid device class (internal)
------------------------------------------

local OscgardGrid = {}
OscgardGrid.__index = OscgardGrid

------------------------------------------
-- coordinate operations
------------------------------------------

local function grid_to_index(x, y, cols)
	return (y - 1) * cols + (x - 1) + 1
end

------------------------------------------
-- OscgardGrid class
------------------------------------------

-- Create new OscgardGrid instance
-- @param id: unique device id
-- @param client: {ip, port} tuple
-- @param cols: number of columns (default 16)
-- @param rows: number of rows (default 8)
-- @param serial: optional serial number (default: generated from client)
function OscgardGrid.new(id, client, cols, rows, serial)
	local self = setmetatable({}, OscgardGrid)

	-- Grid properties (monome API compatible)
	self.id = id
	self.cols = cols or 16
	self.rows = rows or 8
	self.port = nil -- assigned by mod
	self.name = tostring(client[1]):gsub("%D", "") .. "|" .. tostring(client[2]):gsub("%D", "")
	self.serial = serial or ("oscgard-" .. tostring(client[1]) .. ":" .. tostring(client[2]))

	-- Device type for serialosc protocol
	self.device_type = "grid"

	-- Derive type name from dimensions
	local total_leds = self.cols * self.rows
	if total_leds == 64 then
		self.type = "monome 64"
	elseif total_leds == 128 then
		self.type = "monome 128"
	elseif total_leds == 256 then
		self.type = "monome 256"
	else
		self.type = "monome " .. total_leds
	end

	-- Serialosc-compatible settings
	self.prefix = "/" .. self.serial -- configurable OSC prefix

	-- Client connection
	self.client = client

	-- LED state buffer (packed bitwise storage with dirty flags)
	self.buffer = Buffer.new(total_leds)

	-- Refresh throttling
	self.last_refresh_time = 0
	self.refresh_interval = 1 / 60 -- 60Hz

	-- Rotation state
	self.rotation_val = 0
	self.logical_cols = self.cols
	self.logical_rows = self.rows

	-- Callbacks (set by scripts)
	self.key = nil
	self.tilt = nil

	return self
end

function OscgardGrid:led(x, y, z)
	if x < 1 or x > self.logical_cols or y < 1 or y > self.logical_rows then
		return
	end

	local index = grid_to_index(x, y, self.logical_cols)
	self.buffer:set(index, z)
end

function OscgardGrid:all(z)
	self.buffer:set_all(z)
end

function OscgardGrid:refresh()
	local now = util.time()
	if (now - self.last_refresh_time) < self.refresh_interval then
		return
	end
	self.last_refresh_time = now

	if self.buffer:has_dirty() then
		if self.buffer:has_changes() then
			local hex_string = self.buffer:to_hex_string()
			self:send_level_full(hex_string)
		end
		self.buffer:commit()
		self.buffer:clear_dirty()
	end
end

function OscgardGrid:force_refresh()
	self.buffer:mark_all_dirty()
	local hex_string = self.buffer:to_hex_string()
	self:send_level_full(hex_string)
	self.buffer:commit()
	self.buffer:clear_dirty()
end

function OscgardGrid:intensity(i)
	-- Not implemented
end

function OscgardGrid:rotation(val)
	val = val % 4
	self.rotation_val = val
	if val == 1 or val == 3 then
		self.logical_cols = self.rows
		self.logical_rows = self.cols
	else
		self.logical_cols = self.cols
		self.logical_rows = self.rows
	end
	osc.send(self.client, "/sys/rotation", { val })
end

-- Serialosc-compatible: Send LED level map for an 8x8 quad
-- Arguments: x_off, y_off (must be multiples of 8), then 64 brightness values
function OscgardGrid:send_level_map(x_off, y_off)
	local levels = {}

	for row = 0, 7 do
		for col = 0, 7 do
			local x = x_off + col + 1
			local y = y_off + row + 1
			if x <= self.cols and y <= self.rows then
				local index = grid_to_index(x, y, self.cols)
				levels[#levels + 1] = self.buffer:get(index)
			else
				levels[#levels + 1] = 0
			end
		end
	end

	local msg = { x_off, y_off }
	for i = 1, 64 do
		msg[#msg + 1] = levels[i]
	end

	osc.send(self.client, self.prefix .. "/grid/led/level/map", msg)
end

-- Unofficial performant osc command
function OscgardGrid:send_level_full(hex_string)
	osc.send(self.client, self.prefix .. "/grid/led/state", { hex_string })
end

-- Serialosc-compatible: Send all quads as level maps
function OscgardGrid:send_standard_grid_state()
	-- Send all 8x8 quads for the grid dimensions
	for y_off = 0, self.rows - 1, 8 do
		for x_off = 0, self.cols - 1, 8 do
			self:send_level_map(x_off, y_off)
		end
	end
end

-- Serialosc-compatible: Send single LED level
function OscgardGrid:send_level_set(x, y, level)
	-- Convert to 0-indexed for serialosc standard
	osc.send(self.client, self.prefix .. "/grid/led/level/set", { x - 1, y - 1, level })
end

-- Serialosc-compatible: Set all LEDs to same level
function OscgardGrid:send_level_all(level)
	osc.send(self.client, self.prefix .. "/grid/led/level/all", { level })
end

-- Serialosc-compatible: Send row of LED levels
function OscgardGrid:send_level_row(x_off, y, levels)
	local msg = { x_off, y - 1 } -- y is 0-indexed in serialosc
	for i = 1, #levels do
		msg[#msg + 1] = levels[i]
	end
	osc.send(self.client, self.prefix .. "/grid/led/level/row", msg)
end

-- Serialosc-compatible: Send column of LED levels
function OscgardGrid:send_level_col(x, y_off, levels)
	local msg = { x - 1, y_off } -- x is 0-indexed in serialosc
	for i = 1, #levels do
		msg[#msg + 1] = levels[i]
	end
	osc.send(self.client, self.prefix .. "/grid/led/level/col", msg)
end

function OscgardGrid:tilt_enable(id, val)
	-- 1-indexed to 0-indexed
	osc.send(self.client, self.prefix .. "/tilt/set", { id - 1, val })
end

function OscgardGrid:cleanup()
	self.buffer:clear()
	self:force_refresh()
end

------------------------------------------
-- Module state and exports
------------------------------------------

-- Helper to create vport with grid-like interface
local function create_grid_vport()
	return {
		name = "none",
		device = nil,
		key = nil,
		tilt = nil,

		led = function(self, x, y, val)
			if self.device then self.device:led(x, y, val) end
		end,
		all = function(self, val)
			if self.device then self.device:all(val) end
		end,
		refresh = function(self)
			if self.device then self.device:refresh() end
		end,
		rotation = function(self, r)
			if self.device then
				self.device:rotation(r)
				self.cols = self.device.logical_cols
				self.rows = self.device.logical_rows
			end
		end,
		intensity = function(self, i)
			if self.device then self.device:intensity(i) end
		end,
		tilt_enable = function(self, id, val)
			if self.device then self.device:tilt_enable(id, val) end
		end,
		cols = 16,
		rows = 8
	}
end

local module = vport_module.new("grid", create_grid_vport)

-- Create a new grid device and attach to vport
-- Called by mod.lua when a client connects
function module.create_vport(slot, client, cols, rows, serial)
	-- generate unique id
	local id = 100 + slot

	-- default dimensions
	cols = cols or 16
	rows = rows or 8

	-- create device
	local device = OscgardGrid.new(id, client, cols, rows, serial)
	device.port = slot

	-- store in vport
	local vport = module.vports[slot]
	vport.device = device
	vport.name = device.name
	vport.cols = device.logical_cols
	vport.rows = device.logical_rows

	-- set up callbacks
	device.key = function(x, y, z)
		if vport.key then
			vport.key(x, y, z)
		end
	end

	device.tilt = function(n, x, y, z)
		if vport.tilt then
			vport.tilt(n, x, y, z)
		end
	end

	print("oscgard: grid registered on slot " ..
	slot .. " (id=" .. id .. ", client=" .. client[1] .. ":" .. client[2] .. ")")

	-- call add callback if set
	if module.add then
		module.add(vport)
	end

	return device
end

-- Handle grid-specific OSC messages
-- Called by mod.lua for messages that match grid patterns
-- Returns true if message was handled
function module.handle_osc(path, args, device, prefix)
	-- <prefix>/grid/key x y s (0-indexed coordinates, standard monome format)
	if path == prefix .. "/grid/key" then
		if device and device.key and args[1] and args[2] and args[3] then
			local x = math.floor(args[1] + 1) -- Convert 0-indexed to 1-indexed
			local y = math.floor(args[2] + 1)
			local z = math.floor(args[3])
			device.key(x, y, z)
		end
		return true
	end

	-- <prefix>/tilt n x y z (0-indexed sensor id)
	if path == prefix .. "/tilt" then
		if device and device.tilt and args[1] and args[2] and args[3] and args[4] then
			local n = math.floor(args[1]) + 1 -- 0-indexed to 1-indexed
			local x = math.floor(args[2])
			local y = math.floor(args[3])
			local z = math.floor(args[4])
			device.tilt(n, x, y, z)
		end
		return true
	end

	return false
end

return module
