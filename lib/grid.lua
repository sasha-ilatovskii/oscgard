-- oscgard/lib/grid.lua
-- Drop-in replacement for norns grid module
--
-- Usage in scripts:
--   local grid = include("oscgard/lib/grid")
--   -- or with fallback to hardware:
--   local grid = util.file_exists(_path.code.."oscgard") and include("oscgard/lib/grid") or grid
--
-- Then use exactly like norns grid API:
--   g = grid.connect()
--   g:led(x, y, val)
--   g:refresh()
--   g.key = function(x, y, z) ... end

-- Get oscgard mod instance
local oscgard = include('oscgard/lib/mod')

------------------------------------------
-- grid module (mirrors norns grid API)
------------------------------------------

local grid = {}

-- vports array (mirrors norns grid.vports)
-- Delegates to oscgard.grid.vports
grid.vports = oscgard.grid.vports

------------------------------------------
-- Static callbacks (user-definable)
------------------------------------------

-- Called when any grid device is added
-- @param dev: a Grid table
grid.add = nil

-- Called when any grid device is removed
-- @param dev: a Grid table
grid.remove = nil

-- Wire up oscgard callbacks to grid callbacks
oscgard.grid.add = function(dev)
	if grid.add then
		grid.add(dev)
	end
end

oscgard.grid.remove = function(dev)
	if grid.remove then
		grid.remove(dev)
	end
end

------------------------------------------
-- Connection
------------------------------------------

--- Create device, returns object with handler and send.
-- @param n: (integer) vport index (1-4), defaults to 1
-- @return vport object with led, all, refresh, etc methods
function grid.connect(n)
	n = n or 1
	if n < 1 or n > 4 then
		print("oscgard grid.connect: invalid port " .. n)
		return nil
	end
	return oscgard.grid.vports[n]
end

------------------------------------------
-- Module-level device control
-- (These operate on vport 1 by default, matching norns behavior)
------------------------------------------

--- Set grid rotation.
-- @param val: (integer) rotation 0,90,180,270 as [0, 3]
function grid.rotation(val)
	local vport = oscgard.grid.vports[1]
	if vport and vport.device then
		vport.device:rotation(val)
	end
end

--- Enable/disable grid tilt.
-- @param id: (integer) sensor (1-indexed)
-- @param val: (integer) off/on [0, 1]
function grid.tilt_enable(id, val)
	local vport = oscgard.grid.vports[1]
	if vport then
		vport:tilt_enable(id, val)
	end
end

--- Set state of single LED on grid device (vport 1).
-- @param x: (integer) column index (1-based!)
-- @param y: (integer) row index (1-based!)
-- @param val: (integer) LED brightness in [0, 15]
function grid.led(x, y, val)
	local vport = oscgard.grid.vports[1]
	if vport and vport.device then
		vport.device:led(x, y, val)
	end
end

--- Set state of all LEDs on grid device (vport 1).
-- @param val: (integer) LED brightness in [0, 15]
function grid.all(val)
	local vport = oscgard.grid.vports[1]
	if vport and vport.device then
		vport.device:all(val)
	end
end

--- Update any dirty quads on grid device (vport 1).
function grid.refresh()
	local vport = oscgard.grid.vports[1]
	if vport and vport.device then
		vport.device:refresh()
	end
end

--- Set LED intensity on grid device (vport 1).
-- @param i: (integer) intensity [0, 15]
function grid.intensity(i)
	local vport = oscgard.grid.vports[1]
	if vport and vport.device then
		vport.device:intensity(i)
	end
end

--- Clear handlers (called on script cleanup).
function grid.cleanup()
	-- Clear callbacks on all vports
	for i = 1, 4 do
		if oscgard.grid.vports[i] then
			oscgard.grid.vports[i].key = nil
			oscgard.grid.vports[i].tilt = nil
		end
	end
	-- Clear static callbacks
	grid.add = nil
	grid.remove = nil
end

return grid
