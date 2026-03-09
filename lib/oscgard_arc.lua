-- oscgard_arc.lua
-- Virtual arc module for oscgard
-- Manages arc devices, vports, and arc-specific OSC protocol
-- Follows norns arc API: https://monome.org/docs/norns/api/modules/arc.html

local Buffer = include 'oscgard/lib/buffer'
local vport_module = include 'oscgard/lib/vport_module'

------------------------------------------
-- OscgardArc device class (internal)
------------------------------------------

local OscgardArc = {}
OscgardArc.__index = OscgardArc

-- Arc device parameters
local NUM_ENCODERS = 4   -- Max encoders (Arc 2 or Arc 4)
local LEDS_PER_RING = 64 -- 64 LEDs per ring
local LEDS_PER_WORD = 8  -- 8 LEDs packed per 32-bit word (4 bits each)
local WORDS_PER_RING = LEDS_PER_RING / LEDS_PER_WORD

------------------------------------------
-- Helper functions
------------------------------------------

-- Convert ring and LED position to buffer index
-- @param ring: encoder number (1-based)
-- @param x: LED position (1-based, 1-64)
-- @return buffer index (1-based)
local function ring_to_index(ring, x)
	return (ring - 1) * LEDS_PER_RING + x
end

------------------------------------------
-- State management
------------------------------------------

-- Create a new Arc device instance
-- @param id: unique device id
-- @param client: {ip, port} tuple
-- @param num_encoders: number of encoders (default 4)
-- @param serial: optional serial number (default: generated from client)
function OscgardArc.new(id, client, num_encoders, serial)
	local self = setmetatable({}, OscgardArc)

	-- Arc properties (monome API compatible)
	self.id = id or 1
	self.num_encoders = num_encoders or NUM_ENCODERS
	self.port = nil -- assigned by mod
	self.name = tostring(client[1]):gsub("%D", "") .. "|" .. tostring(client[2]):gsub("%D", "")
	self.serial = serial or ("oscgard-" .. tostring(client[1]) .. ":" .. tostring(client[2]))

	-- Device type for serialosc protocol
	self.device_type = "arc"

	-- Derive type name from encoder count
	if self.num_encoders == 2 then
		self.type = "monome arc 2"
	elseif self.num_encoders == 4 then
		self.type = "monome arc 4"
	else
		self.type = "monome arc"
	end

	-- Serialosc-compatible settings
	self.prefix = "/" .. self.serial -- configurable OSC prefix

	-- Client connection
	self.client = client

	-- LED state buffer (packed bitwise storage)
	local total_leds = self.num_encoders * LEDS_PER_RING
	self.buffer = Buffer.new(total_leds)

	-- Compat mode: use standard serialosc map messages instead of atomic state
	self.compat_mode = false

	-- Callbacks (set by scripts)
	self.delta = nil -- function(n, delta) - encoder rotation callback
	self.key = nil -- function(n, z) - encoder key callback
	self.remove = nil -- function() - device disconnect callback

	return self
end

------------------------------------------
-- Norns Arc API Methods
------------------------------------------

-- Set single LED on ring (norns API: led(ring, x, val))
-- @param ring: encoder number (1-based)
-- @param x: LED position (1-based, 1-64)
-- @param val: brightness value (0-15)
function OscgardArc:led(ring, x, val)
	if ring < 1 or ring > self.num_encoders or x < 1 or x > LEDS_PER_RING then
		return
	end

	local index = ring_to_index(ring, x)
	self.buffer:set(index, val)
end

-- Set all LEDs to uniform brightness (norns API: all(val))
-- @param val: brightness value (0-15)
function OscgardArc:all(val)
	self.buffer:set_all(val)
end

-- Anti-aliased arc segment from one angle to another (norns API: segment(ring, from, to, level))
-- Uses the same overlap algorithm as the original norns arc module.
-- Additive: does not clear the ring, so multiple segments can be layered.
-- @param ring: encoder number (1-based)
-- @param from_angle: starting angle in radians
-- @param to_angle: ending angle in radians
-- @param level: brightness value (0-15)
function OscgardArc:segment(ring, from_angle, to_angle, level)
	if ring < 1 or ring > self.num_encoders then
		return
	end

	local tau = math.pi * 2

	-- Calculate overlap between two angular ranges, handling wrapping
	local function overlap(a, b, c, d)
		if a > b then
			return overlap(a, tau, c, d) + overlap(0, b, c, d)
		elseif c > d then
			return overlap(a, b, c, tau) + overlap(a, b, 0, d)
		else
			return math.max(0, math.min(b, d) - math.max(a, c))
		end
	end

	local function overlap_segments(a, b, c, d)
		a = a % tau
		b = b % tau
		c = c % tau
		d = d % tau
		return overlap(a, b, c, d)
	end

	local sl = tau / LEDS_PER_RING

	for i = 1, LEDS_PER_RING do
		local sa = sl * (i - 1)
		local sb = sl * i

		local o = overlap_segments(from_angle, to_angle, sa, sb)
		local val = util.round(o / sl * level)
		if val > 0 then
			local index = ring_to_index(ring, i)
			local current = self.buffer:get(index)
			self.buffer:set(index, math.max(current, val))
		end
	end
end

-- Set all LEDs on ring from array (serialosc protocol: /ring/map)
-- @param ring: encoder number (1-based)
-- @param levels: array of 64 brightness values (0-15)
function OscgardArc:ring_map(ring, levels)
	if ring < 1 or ring > self.num_encoders or #levels ~= LEDS_PER_RING then
		return
	end

	-- Update all LEDs in this ring
	for x = 1, LEDS_PER_RING do
		local index = ring_to_index(ring, x)
		self.buffer:set(index, levels[x])
	end
end

-- Set range of LEDs (serialosc protocol: /ring/range)
-- @param ring: encoder number (1-based)
-- @param x1: start LED position (1-based, 1-64)
-- @param x2: end LED position (1-based, 1-64)
-- @param val: brightness value (0-15)
function OscgardArc:ring_range(ring, x1, x2, val)
	if ring < 1 or ring > self.num_encoders then
		return
	end

	-- Normalize to 1-based and handle wrapping
	x1 = ((x1 - 1) % LEDS_PER_RING) + 1
	x2 = ((x2 - 1) % LEDS_PER_RING) + 1

	-- Update LEDs in range (clockwise with wrapping)
	local pos = x1
	local count = 0
	repeat
		local index = ring_to_index(ring, pos)
		self.buffer:set(index, val)
		count = count + 1
		if pos == x2 or count >= LEDS_PER_RING then break end
		pos = (pos % LEDS_PER_RING) + 1
	until false
end

-- Update display (norns API: refresh())
function OscgardArc:refresh()
	if self.buffer:has_dirty() then
		if self.buffer:has_changes() then
			if self.compat_mode then
				self:send_ring_maps()
			else
				self:send_ring_state()
			end
		end
		self.buffer:commit()
		self.buffer:clear_dirty()
	end
end

function OscgardArc:force_refresh()
	self.buffer:mark_all_dirty()
	if self.compat_mode then
		self:send_ring_maps()
	else
		self:send_ring_state()
	end
	self.buffer:commit()
	self.buffer:clear_dirty()
end

-- Precomputed hex lookup table (indexed by brightness 0-15)
local HEX = {}
for i = 0, 15 do
	HEX[i] = string.format("%X", i)
	HEX[i] = string.format("%x", i)
end

-- Send full state of all rings as n hex strings (one per ring, 64 hex chars each)
-- OSC path: <prefix>/ring/state s s [s s]
function OscgardArc:send_ring_state()
	if not self.client then return end

	local msg = {}
	local buf = self.buffer.new_buffer

	for ring = 1, self.num_encoders do
		local hex_chars = {}
		-- Each ring starts at word offset: (ring-1)*8 + 1 (64 LEDs / 8 per word = 8 words per ring)
		local base_word = (ring - 1) * (WORDS_PER_RING)
		local led = 1
		for w = 1, WORDS_PER_RING do
			local word = buf[base_word + w]
			for _ = 1, LEDS_PER_WORD do
				hex_chars[led] = HEX[word & 0x0F]
				word = word >> 4
				led = led + 1
			end
		end
		msg[ring] = table.concat(hex_chars)
	end

	osc.send(self.client, self.prefix .. "/ring/state", msg)
end

-- Serialosc-compatible: Send each ring as individual /ring/map messages
-- OSC path: <prefix>/ring/map i i*64 (ring number + 64 LED levels)
function OscgardArc:send_ring_maps()
	if not self.client then return end

	for ring = 1, self.num_encoders do
		local msg = { ring - 1 } -- 0-indexed ring number
		for x = 1, LEDS_PER_RING do
			local index = ring_to_index(ring, x)
			msg[#msg + 1] = self.buffer:get(index)
		end
		osc.send(self.client, self.prefix .. "/ring/map", msg)
	end
end

-- Set overall device intensity (norns API: intensity(i))
-- @param i: intensity level (0-15)
function OscgardArc:intensity(i)
	-- TouchOSC doesn't support hardware intensity
	-- This method exists for API compatibility with norns
end

------------------------------------------
-- Cleanup and lifecycle
------------------------------------------

-- Cleanup method for arc device (called on device removal)
function OscgardArc:cleanup()
	self.buffer:clear()
	self:force_refresh()
end

------------------------------------------
-- Module state and exports
------------------------------------------

-- Helper to create vport with arc-like interface (matches norns arc API)
local function create_arc_vport()
	return {
		name = "none",
		device = nil,
		delta = nil, -- arc encoder callback function(n, delta)
		key = nil, -- arc key callback function(n, z)

		-- Norns arc API methods
		led = function(self, ring, x, val)
			if self.device then self.device:led(ring, x, val) end
		end,
		all = function(self, val)
			if self.device then self.device:all(val) end
		end,
		segment = function(self, ring, from_angle, to_angle, level)
			if self.device then self.device:segment(ring, from_angle, to_angle, level) end
		end,
		refresh = function(self)
			if self.device then self.device:refresh() end
		end,
		intensity = function(self, i)
			if self.device then self.device:intensity(i) end
		end,

		-- Serialosc arc protocol methods (for compatibility)
		ring_map = function(self, ring, levels)
			if self.device then self.device:ring_map(ring, levels) end
		end,
		ring_range = function(self, ring, x1, x2, val)
			if self.device then self.device:ring_range(ring, x1, x2, val) end
		end,

		encoders = 4
	}
end

local module = vport_module.new("arc", create_arc_vport)

-- Create a new arc device and attach to vport
-- Called by mod.lua when a client connects
-- @param slot: vport slot number (1-4)
-- @param client: {ip, port} tuple
-- @param cols: number of encoders (default 4)
-- @param rows: unused (kept for uniform interface with grid)
-- @param serial: optional serial number
function module.create_vport(slot, client, cols, rows, serial)
	-- generate unique id
	local id = 200 + slot

	-- default encoder count
	cols = (cols * rows) or 4

	-- create device
	local device = OscgardArc.new(id, client, cols, serial)
	device.port = slot

	-- store in vport
	local vport = module.vports[slot]
	vport.device = device
	vport.name = device.name

	-- Set up delta callback
	device.delta = function(n, d)
		if vport.delta then
			vport.delta(n, d)
		end
	end

	-- Set up key callback
	device.key = function(n, z)
		if vport.key then
			vport.key(n, z)
		end
	end

	print("oscgard: arc registered on slot " ..
		slot .. " (id=" .. id .. ", client=" .. client[1] .. ":" .. client[2] .. ")")

	-- call add callback if set
	if module.add then
		module.add(vport)
	end

	return device
end

-- Handle arc-specific OSC messages
-- Called by mod.lua for messages that match arc patterns
-- Returns true if message was handled
function module.handle_osc(path, args, device, prefix)
	-- <prefix>/enc/delta ii n d (0-indexed encoder, signed delta)
	if path == prefix .. "/enc/delta" then
		if device and device.delta and args[1] and args[2] then
			local n = math.floor(args[1]) + 1 -- Convert 0-indexed to 1-indexed
			local d = math.floor(args[2]) -- Signed delta value
			device.delta(n, d)
		end
		return true
	end

	-- <prefix>/enc/key ii n s (0-indexed encoder, state 0/1)
	if path == prefix .. "/enc/key" then
		if device and device.key and args[1] and args[2] then
			local n = math.floor(args[1]) + 1 -- Convert 0-indexed to 1-indexed
			local z = math.floor(args[2]) -- Key state (0=up, 1=down)
			device.key(n, z)
		end
		return true
	end

	return false
end

return module
