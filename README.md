# oscgard
A norns mod that creates virtual grid and arc devices over OSC
Oscgard is a norns mod that intercepts grid/arc API calls and routes them to any OSC client app implementing the serialosc device specification.

> **Note**: Scripts currently need to be patched to use oscgard. Transparent mod integration (no script patching) is planned for a future version.

## Installation

**Via maiden:**
```
;install https://github.com/sasha-ilatovskii/oscgard
```

**Via git clone:**
```sh
cd ~/dust/code && git clone https://github.com/sasha-ilatovskii/oscgard
```

Or download the zip from [releases](https://github.com/sasha-ilatovskii/oscgard/releases) and extract to `~/dust/code/`.

After installing, enable the mod in **SYSTEM > MODS** and restart norns.

---

## Features

- **SerialOSC compliant** — speaks the same protocol real monome devices use
- **Grid + Arc** — both device types fully supported
- **All editions** — Grid 64 / 128 / 256 and Arc 2 / 4 encoders
- **Full rotation** — 0, 90, 180, 270 degree support
- **Tilt sensors** — grid tilt data forwarded to scripts
- **Zeroconf discovery** — auto-finds OSC clients on your network via avahi-browse
- **Multi-device** — up to 4 virtual devices simultaneously (any mix of grids and arcs)
- **Built for WiFi** — bulk updates, 128x fewer packets than per-LED messaging
- **Extensible** — any OSC client implementing the spec can connect

### Performance

| Metric | Per-LED (others) | Bulk (oscgard) |
|--------|:-:|:-:|
| Messages per refresh | up to 128 | 1 |
| Bytes per refresh | ~2,560 | ~140 |
| Update atomicity | Sequential | Atomic |

---

## Getting Started

1. Install and enable the mod (see above)
2. Get a client app — you need an OSC app implementing the oscgard/serialosc device protocol. A ready-made **TouchOSC** template [is available](https://ilatovskii.gumroad.com/l/oscgard-companion)
3. Open the mod menu on norns: **SYSTEM > MODS > OSCGARD**
4. The mod will scan your network for OSC devices
5. Assign a discovered device to a port (choose grid or arc, pick vport 1-4)
6. Patch your script with the appropriate include line (see below)

### Script Integration

For grid:
```lua
local grid = include("oscgard/lib/grid")
```

For arc:
```lua
local arc = include("oscgard/lib/arc")
```

With hardware fallback:
```lua
local grid = util.file_exists(_path.code.."oscgard") and include("oscgard/lib/grid") or grid
local arc = util.file_exists(_path.code.."oscgard") and include("oscgard/lib/arc") or arc
```

---

## Supported Devices

### Grid

The monome grid is a matrix of backlit silicone buttons — press/release input with 16 levels of LED brightness. Oscgard virtualizes the full spec: key input, LED feedback, all three editions, hardware rotation, and tilt sensors.

| | |
|---|---|
| Editions | 64 (8x8) / 128 (16x8) / 256 (16x16) |
| Input | Buttons + Tilt sensors |
| LED feedback | 16 brightness levels (0-15) |
| Rotation | 0 / 90 / 180 / 270 |

### Arc

The monome arc is a set of high-resolution optical encoders, each ringed by 64 individually addressable LEDs. Oscgard virtualizes encoder delta input and per-LED ring feedback.

| | |
|---|---|
| Editions | 2 / 4 encoders |
| Input | Encoders + Push-buttons |
| LED feedback | 64 LEDs per ring |
| Ring modes | All / map / range / segment |

---

## API Reference

### Grid API

```lua
-- Connect
local g = grid.connect()      -- First available port
local g = grid.connect(port)  -- Specific port (1-4)

-- LED Control
g:led(x, y, brightness)       -- Set LED (brightness 0-15)
g:all(brightness)             -- Set all LEDs
g:refresh()                   -- Send updates
g:intensity(level)            -- Set global intensity 0-15

-- Rotation
g:rotation(r)                 -- 0=0, 1=90, 2=180, 3=270

-- Callback
g.key = function(x, y, z)     -- Button press (z=1) / release (z=0)
  print("key", x, y, z)
end

-- Static callbacks
grid.add = function(dev)      -- Called when any grid connects
grid.remove = function(dev)   -- Called when any grid disconnects
```

### Arc API

```lua
-- Connect
local a = arc.connect()       -- First available port
local a = arc.connect(port)   -- Specific port (1-4)

-- LED Control
a:led(ring, x, val)           -- Set LED (ring 1-4, x 1-64, val 0-15)
a:all(val)                    -- Set all LEDs on all rings
a:segment(ring, from, to, level) -- Anti-aliased arc segment (radians)
a:refresh()                   -- Send updates

-- Callbacks
a.delta = function(n, d)      -- Encoder rotation (n=encoder 1-4, d=signed delta)
  print("delta", n, d)
end

a.key = function(n, z)        -- Encoder press (z=1) / release (z=0)
  print("key", n, z)
end

-- Static callbacks
arc.add = function(dev)       -- Called when any arc connects
arc.remove = function(dev)    -- Called when any arc disconnects
```

---

## Examples

### Grid: light up on press

```lua
local grid = include("oscgard/lib/grid")
local g = grid.connect()

function init()
  g:all(0)
  g:refresh()
end

g.key = function(x, y, z)
  g:led(x, y, z * 15)
  g:refresh()
end
```

### Arc: smooth follower

```lua
local arc = include("oscgard/lib/arc")
local a = arc.connect()
local pos = 0

function init()
  a:all(0)
end

a.delta = function(n, d)
  pos = pos + d
  local angle = (pos / 64) * (2 * math.pi)
  local width = math.pi / 8
  a:segment(n, angle - width, angle + width, 15)
end
```

---

## TouchOSC Setup

[A polished TouchOSC template is available](https://ilatovskii.gumroad.com/l/oscgard-companion) with configurable grid/arc layouts, tilt sensor support, and optimized performance.

1. Import the `.tosc` project to TouchOSC (v2, not Mk1)
2. Configure connection:
   - **Protocol**: UDP
   - **Host**: Your norns IP (see SYSTEM > WIFI) or (or you can try with norns.local url, [more info](https://monome.org/docs/norns/wifi-files/#hostname))
   - **Send Port**: 10111
   - **Receive Port**: any usused and unique for every connection
3. Run the controller (Play button)
4. The device will be discovered automatically in the mod menu

---

## How It Works

The mod registers as a norns system hook, intercepting OSC traffic. When a client connects, oscgard creates a virtual device that looks exactly like real monome hardware to any norns script.

```
OSC Client (tablet/phone)
    ↕ osc messages over WiFi
OSCgard (norns mod)
    ↕ grid / arc API
Running Script (norns)
```

LED updates from scripts are packed into efficient bulk messages and sent to the client. Button presses and encoder turns from the client are transformed and delivered to the script's callbacks.

## Mod Menu

Access via **SYSTEM > MODS > OSCGARD**:

- Scan network for devices
- Add/remove virtual devices
- Choose device type (grid/arc) and vport
- View connection status and connected clients
- Disconnect clients

## Links

- [Monome Grid Docs](https://monome.org/docs/grid/)
- [Monome Arc Docs](https://monome.org/docs/arc/)
- [Norns Grid API](https://monome.org/docs/norns/reference/grid)
- [Norns Arc API](https://monome.org/docs/norns/reference/arc)
- [serialosc protocol](https://monome.org/docs/serialosc/osc)

## License

[GPL-3.0](LICENSE)
