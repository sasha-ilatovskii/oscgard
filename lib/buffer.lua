-- buffer.lua
-- Shared packed buffer module for LED state management
-- Used by both oscgard_grid and oscgard_arc for efficient LED storage
--
-- Features:
-- - Packed bitwise storage (4 bits per LED = 16 brightness levels)
-- - Dirty bit tracking for efficient updates
-- - Memory-efficient: 8 LEDs per 32-bit word

local Buffer = {}
Buffer.__index = Buffer

-- Configuration
local MAX_BITS_PER_NUMBER_IN_LUA = 32
local BITS_PER_LED = 4                                          -- 4 bits = 16 brightness levels (0-15)
local LEDS_PER_WORD = MAX_BITS_PER_NUMBER_IN_LUA / BITS_PER_LED -- 8 LEDs per word
local LED_MASK = (1 << BITS_PER_LED) - 1                        -- 0x0F

-- Precomputed hex byte lookup table (indexed by brightness 0-15)
-- Stores raw byte values for string.char() — avoids per-LED string allocation
local HEX_BYTE = {}
for i = 0, 15 do
	HEX_BYTE[i] = string.byte(string.format("%x", i))
end

------------------------------------------
-- Buffer Creation
------------------------------------------

--- Create a new buffer instance for LED state management
-- @param total_leds: total number of LEDs to store
-- @return Buffer instance with packed storage and dirty flags
function Buffer.new(total_leds)
	local self = setmetatable({}, Buffer)

	self.total_leds = total_leds
	self.num_words = math.ceil(total_leds / LEDS_PER_WORD)
	self.num_dirty_words = math.ceil(total_leds / 32)

	-- Create packed LED buffers (old and new state)
	self.old_buffer = {}
	self.new_buffer = {}
	for i = 1, self.num_words do
		self.old_buffer[i] = 0
		self.new_buffer[i] = 0
	end

	-- Create dirty flags (1 bit per LED)
	self.dirty = {}
	for i = 1, self.num_dirty_words do
		self.dirty[i] = 0
	end

	-- Pre-allocate hex byte array for to_hex_string() (avoids table alloc per call)
	self._hex_bytes = {}
	for i = 1, total_leds do
		self._hex_bytes[i] = HEX_BYTE[0]
	end

	return self
end

------------------------------------------
-- LED Operations
------------------------------------------

--- Get LED brightness at index
-- @param index: LED index (1-based)
-- @return brightness value (0-15), or 0 if out of bounds
function Buffer:get(index)
	if index < 1 or index > self.total_leds then
		return 0
	end

	local word_index = math.floor((index - 1) / LEDS_PER_WORD) + 1
	local bit_shift = ((index - 1) % LEDS_PER_WORD) * BITS_PER_LED

	if not self.new_buffer[word_index] then
		return 0
	end

	return (self.new_buffer[word_index] >> bit_shift) & LED_MASK
end

--- Set LED brightness at index
-- @param index: LED index (1-based)
-- @param brightness: brightness value (0-15)
function Buffer:set(index, brightness)
	if index < 1 or index > self.total_leds then
		return
	end

	brightness = math.max(0, math.min(15, brightness))

	-- Compute word position once (shared by change check and update)
	local word_index = math.floor((index - 1) / LEDS_PER_WORD) + 1
	local bit_shift = ((index - 1) % LEDS_PER_WORD) * BITS_PER_LED

	-- Check if value actually changed (inlined get)
	local word = self.new_buffer[word_index]
	if ((word >> bit_shift) & LED_MASK) == brightness then
		return
	end

	-- Update packed buffer
	local clear_mask = ~(LED_MASK << bit_shift)
	self.new_buffer[word_index] = (word & clear_mask) | (brightness << bit_shift)

	-- Mark as dirty (inlined set_dirty)
	local dirty_word = math.floor((index - 1) / 32) + 1
	local dirty_bit = (index - 1) % 32
	self.dirty[dirty_word] = self.dirty[dirty_word]| (1 << dirty_bit)
end

--- Set all LEDs to same brightness
-- @param brightness: brightness value (0-15)
function Buffer:set_all(brightness)
	brightness = math.max(0, math.min(15, brightness))

	-- Precompute a word with all 8 nibbles set to the same brightness
	local word = 0
	for i = 0, LEDS_PER_WORD - 1 do
		word = word | (brightness << (i * BITS_PER_LED))
	end

	for i = 1, self.num_words do
		self.new_buffer[i] = word
	end

	self:mark_all_dirty()
end

------------------------------------------
-- Dirty Flag Operations
------------------------------------------

--- Mark LED at index as dirty
-- @param index: LED index (1-based)
function Buffer:set_dirty(index)
	if index < 1 or index > self.total_leds then
		return
	end

	local word_index = math.floor((index - 1) / 32) + 1
	local bit_index = (index - 1) % 32
	self.dirty[word_index] = self.dirty[word_index]| (1 << bit_index)
end

--- Check if any LEDs are dirty
-- @return true if any changes pending
function Buffer:has_dirty()
	for i = 1, self.num_dirty_words do
		if self.dirty[i] ~= 0 then
			return true
		end
	end
	return false
end

--- Clear all dirty flags
function Buffer:clear_dirty()
	for i = 1, self.num_dirty_words do
		self.dirty[i] = 0
	end
end

--- Mark all LEDs as dirty
function Buffer:mark_all_dirty()
	for i = 1, self.num_dirty_words do
		self.dirty[i] = 0xFFFFFFFF
	end
end

--- Check if new buffer differs from last committed state
-- @return true if any words differ between new_buffer and old_buffer
function Buffer:has_changes()
	for i = 1, self.num_words do
		if self.new_buffer[i] ~= self.old_buffer[i] then
			return true
		end
	end
	return false
end

------------------------------------------
-- State Management
------------------------------------------

--- Commit new state to old state (call after sending updates)
function Buffer:commit()
	for i = 1, self.num_words do
		self.old_buffer[i] = self.new_buffer[i]
	end
end

--- Reset buffer to all zeros
function Buffer:clear()
	for i = 1, self.num_words do
		self.new_buffer[i] = 0
	end
	self:mark_all_dirty()
end

------------------------------------------
-- Serialization
------------------------------------------

--- Convert buffer to hex string for OSC transmission
-- @return hex string (e.g., "F00A..." with total_leds characters)
function Buffer:to_hex_string()
	local bytes = self._hex_bytes
	local buf = self.new_buffer
	local led = 1

	for w = 1, self.num_words do
		local word = buf[w]
		local leds_in_word = math.min(LEDS_PER_WORD, self.total_leds - (w - 1) * LEDS_PER_WORD)
		for _ = 1, leds_in_word do
			bytes[led] = HEX_BYTE[word & LED_MASK]
			word = word >> BITS_PER_LED
			led = led + 1
		end
	end

	return string.char(table.unpack(bytes, 1, self.total_leds))
end

--- Update buffer from hex string
-- @param hex_string: hex string with brightness values (0-F per LED)
function Buffer:from_hex_string(hex_string)
	local len = math.min(#hex_string, self.total_leds)

	for i = 1, len do
		local hex_char = hex_string:sub(i, i)
		local brightness = tonumber(hex_char, 16) or 0
		self:set(i, brightness)
	end
end

------------------------------------------
-- Statistics
------------------------------------------

--- Get buffer statistics
-- @return table with memory usage info
function Buffer:stats()
	return {
		total_leds = self.total_leds,
		buffer_bytes = self.num_words * 4,                       -- 4 bytes per 32-bit word
		dirty_bytes = self.num_dirty_words * 4,
		total_bytes = (self.num_words + self.num_dirty_words) * 2 * 4, -- old + new buffers + dirty
		leds_per_word = LEDS_PER_WORD,
		bits_per_led = BITS_PER_LED
	}
end

return Buffer
