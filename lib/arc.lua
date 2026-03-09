-- oscgard/lib/arc.lua
-- Drop-in replacement for norns arc module

-- Usage in scripts:
--   local arc = include("oscgard/lib/arc")
--   -- or with fallback to hardware:
--   local arc = util.file_exists(_path.code.."oscgard") and include("oscgard/lib/arc") or arc

-- Then use exactly like norns arc API:
--   a = arc.connect()
--   a:led(n, x, val)
--   a:refresh()
--   a.delta = function(n, d) ... end

local oscgard = include('oscgard/lib/mod')

------------------------------------------
-- arc module (mirrors norns arc API)
------------------------------------------

local arc = {}

-- vports array (mirrors norns arc.vports)
arc.vports = oscgard.arc.vports

------------------------------------------
-- Static callbacks (user-definable)
------------------------------------------

-- Called when any arc device is added
-- @param dev: an Arc table
arc.add = nil

-- Called when any arc device is removed
-- @param dev: an Arc table
arc.remove = nil

-- Wire up oscgard callbacks to arc callbacks
oscgard.arc.add = function(dev)
	if arc.add then
		arc.add(dev)
	end
end

oscgard.arc.remove = function(dev)
	if arc.remove then
		arc.remove(dev)
	end
end

------------------------------------------
-- Connection
------------------------------------------

--- Create device, returns object with handler and send.
-- @param n: (integer) vport index (1-4), defaults to 1
-- @return vport object with led, all, refresh, etc methods

function arc.connect(n)
	n = n or 1
	if n < 1 or n > 4 then
		print("oscgard arc.connect: invalid port " .. n)
		return nil
	end
	return oscgard.arc.vports[n]
end

------------------------------------------
-- Module-level device control
-- (These operate on vport 1 by default, matching norns behavior)
------------------------------------------

--- Set arc rotation (not typically used, but for API parity)
-- @param val: (integer) rotation 0,90,180,270 as [0, 3]
function arc.rotation(val)
	local vport = oscgard.arc.vports[1]
	if vport and vport.device and vport.device.rotation then
		vport.device:rotation(val)
	end
end

return arc
