# Oscgard - Specification

> **Spec-Driven Development (SDD)** - This document serves as the single source of truth for the oscgard project.

## Overview

**Oscgard** is an OSC-to-grid/arc adapter for [norns](https://monome.org/docs/norns/) that intercepts monome grid/arc API calls and routes them to any OSC client implementing the monome serialosc device specification.

### Goals

1. **Use a tablet/phone as a monome grid/arc** via TouchOSC or other OSC clients
2. **100% API compatibility** with norns grid and arc APIs
3. **High performance** works over WiFi (low latency, minimal bandwidth)
4. **Extensible** - any OSC client implementing the spec can connect

### Script Integration

Scripts need patching to use oscgard:

```lua
local grid = include("oscgard/lib/grid")
local arc = include("oscgard/lib/arc")
```

Or with hardware fallback:

```lua
local grid = util.file_exists(_path.code.."oscgard") and include("oscgard/lib/grid") or grid
local arc = util.file_exists(_path.code.."oscgard") and include("oscgard/lib/arc") or arc
```

---

### Components

| Component | File | Purpose |
|-----------|------|---------|
| **Grid Module** | `lib/grid.lua` | Drop-in replacement for norns `grid` module |
| **Arc Module** | `lib/arc.lua` | Drop-in replacement for norns `arc` module |
| **Mod Core** | `lib/mod.lua` | OSC routing, slot management, device lifecycle, zeroconf discovery |
| **Mod Menu** | `lib/mod_menu.lua` | Reactive UI for device management (watchtable-driven) |
| **Grid Device** | `lib/oscgard_grid.lua` | Grid device class, vports, grid-specific OSC handling |
| **Arc Device** | `lib/oscgard_arc.lua` | Arc device class, vports, arc-specific OSC handling |
| **Buffer** | `lib/buffer.lua` | Packed bitwise LED storage with dirty tracking |
| **Vport Factory** | `lib/vport_module.lua` | Shared vport factory for grid and arc modules |

---

## Protocol Specification

Oscgard implements the [monome serialosc OSC specification](https://monome.org/docs/serialosc/osc/). Devices are discovered via zeroconf (`avahi-browse` for `_osc._udp` services) and assigned to ports through the mod menu.

### Discovery

Oscgard discovers devices by:
1. Scanning for `_osc._udp` services via `avahi-browse`
2. Sending `/sys/info` to each discovered service
3. Collecting responses (`/sys/type`, `/sys/id`, `/sys/prefix`, `/sys/size`, `/sys/rotation`, `/sys/sensors`)
4. Displaying available devices in the mod menu for assignment

### System Messages (Discovery)

| Address | Arguments | Direction | Description |
|---------|-----------|-----------|-------------|
| `/sys/info` | _(none)_ | norns → client | Request device info |
| `/sys/type` | `s` type | client → norns | Device type ("grid" or "arc") |
| `/sys/id` | `s` id | client → norns | Device serial/ID |
| `/sys/prefix` | `s` prefix | client → norns | OSC prefix (e.g. "/device-name") |
| `/sys/size` | `i` cols, `i` rows | client → norns | Device dimensions |
| `/sys/rotation` | `i` rotation | bidirectional | Grid rotation (0-3) |
| `/sys/sensors` | `i` count | client → norns | Number of tilt sensors |

### Grid Input (Client → Norns)

| Address | Arguments | Description |
|---------|-----------|-------------|
| `<prefix>/grid/key` | `i` x, `i` y, `i` state | Button press (0-indexed, state 0 or 1) |
| `<prefix>/tilt` | `i` sensor, `i` x, `i` y, `i` z | Tilt sensor data (0-indexed sensor) |

### Grid Output (Norns → Client)

| Address | Arguments | Description |
|---------|-----------|-------------|
| `<prefix>/grid/led/state` | `s` hex_string | Full LED state as hex string (1 char per LED, 0-f) |
| `<prefix>/grid/led/level/set` | `i` x, `i` y, `i` level | Set single LED (0-indexed, level 0-15) |
| `<prefix>/grid/led/level/all` | `i` level | Set all LEDs to level |
| `<prefix>/grid/led/level/map` | `i` x_off, `i` y_off, `i[64]` levels | Set 8x8 quad |
| `<prefix>/grid/led/level/row` | `i` x_off, `i` y, `i[8]` levels | Set row of 8 LEDs |
| `<prefix>/grid/led/level/col` | `i` x, `i` y_off, `i[8]` levels | Set column of 8 LEDs |
| `<prefix>/tilt/set` | `i` sensor, `i` enable | Enable/disable tilt sensor (0-indexed) |

> **Note**: Default prefix is `/<serial>`. Coordinates in serialosc messages are 0-indexed. The primary update method is `/grid/led/state` using hex strings.

### Arc Input (Client → Norns)

| Address | Arguments | Description |
|---------|-----------|-------------|
| `<prefix>/enc/delta` | `i` n, `i` delta | Encoder rotation (0-indexed, signed delta) |
| `<prefix>/enc/key` | `i` n, `i` state | Encoder press (0-indexed, state 0 or 1) |

### Arc Output (Norns → Client)

| Address | Arguments | Description |
|---------|-----------|-------------|
| `<prefix>/ring/state` | `s` ring1, `s` ring2 [, `s` ring3, `s` ring4] | Full ring state as hex strings (64 chars each) |

### Coordinate Systems

**Serialosc standard**: 0-indexed coordinates (x: 0-15, y: 0-7)
**Internal norns API**: 1-indexed coordinates (x: 1-16, y: 1-8)

Oscgard converts between these at the OSC boundary.

---

## Data Format

### Packed Bitwise Storage

LED state uses packed 32-bit words (4 bits per LED):

```
Configuration:
- BITS_PER_LED = 4 (16 brightness levels: 0-15)
- LEDS_PER_WORD = 8 (8 LEDs per 32-bit word)

For 128 LEDs (16x8 grid): 16 words = 64 bytes
For 256 LEDs (4x64 arc): 32 words = 128 bytes

Bit layout per word:
┌─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┐
│LED7 │LED6 │LED5 │LED4 │LED3 │LED2 │LED1 │LED0 │
│28-31│24-27│20-23│16-19│12-15│ 8-11│ 4-7 │ 0-3 │
└─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┘
```

### Hex String Format

The `/grid/led/state` and `/ring/state` messages use hex strings where each character represents one LED's brightness (0-f):

```
"0000000000000000f0000000000000000000..."
 ↑                ↑
 LED1 (row1,col1) LED17 (row2,col1)

128 characters for a 16x8 grid
64 characters per ring for arc
```

### Dirty Flag Tracking

4 x 32-bit integers hold 128 dirty bits (1 bit per LED). Used to skip unchanged frames during refresh.

---

## API Reference

### Grid API (norns compatible)

```lua
-- Connection
g = grid.connect()        -- Connect to first available grid
g = grid.connect(port)    -- Connect to specific port (1-4)

-- LED Control
g:led(x, y, brightness)   -- Set LED (1-indexed, brightness 0-15)
g:all(brightness)          -- Set all LEDs
g:refresh()                -- Send pending updates to device
g:intensity(level)         -- Set global intensity (not implemented)

-- Rotation
g:rotation(r)              -- Set rotation: 0=0°, 1=90°, 2=180°, 3=270°

-- Tilt
g:tilt_enable(id, val)     -- Enable/disable tilt sensor (1-indexed)

-- Properties
g.device.cols              -- Column count
g.device.rows              -- Row count
g.device.id                -- Device ID
g.device.name              -- Device name
g.device.serial            -- Serial number

-- Callbacks
g.key = function(x, y, z) end     -- Button press (1-indexed)
g.tilt = function(n, x, y, z) end -- Tilt sensor (1-indexed)

-- Global Callbacks
grid.add = function(dev) end    -- Grid connected
grid.remove = function(dev) end -- Grid disconnected
```

### Arc API (norns compatible)

```lua
-- Connection
a = arc.connect()         -- Connect to first available arc
a = arc.connect(port)     -- Connect to specific port (1-4)

-- LED Control
a:led(ring, x, val)       -- Set single LED (1-indexed, ring 1-4, x 1-64, val 0-15)
a:all(val)                 -- Set all LEDs
a:segment(ring, from, to, level) -- Anti-aliased arc segment (radians)
a:refresh()                -- Send pending updates to device

-- Serialosc Methods
a:ring_map(ring, levels)   -- Set all 64 LEDs on ring from array
a:ring_range(ring, x1, x2, val) -- Set range of LEDs on ring

-- Callbacks
a.delta = function(n, d) end  -- Encoder rotation (1-indexed)
a.key = function(n, z) end    -- Encoder press (1-indexed)

-- Global Callbacks
arc.add = function(dev) end    -- Arc connected
arc.remove = function(dev) end -- Arc disconnected
```

---

## Rotation

Physical storage dimensions are fixed (e.g. 16x8). Rotation transforms logical coordinates:

```lua
-- Rotation 0 (0°):   No change
-- Rotation 1 (90°):  (x,y) → (y, rows+1-x)
-- Rotation 2 (180°): (x,y) → (cols+1-x, rows+1-y)
-- Rotation 3 (270°): (x,y) → (cols+1-y, x)

-- Logical dimensions:
-- Rotation 0, 2: same as physical (e.g. 16x8)
-- Rotation 1, 3: swapped (e.g. 8x16)
```

The client app should handle portrait variants (cols < rows) by applying a base 90° rotation, so an 8x16 layout reports as a 16x8 grid with rotation.

---

## Performance

| Metric | Value |
|--------|-------|
| Refresh rate | Unthrottled (sends on dirty changes) |
| Grid message per refresh | 1 (`/grid/led/state` hex string) |
| Grid message size | ~140 bytes (128 hex chars + OSC overhead) |
| Arc message per refresh | 1 (`/ring/state` with N hex strings) |
| Buffer memory (128 LEDs) | 64 bytes per state (old + new = 128 bytes + dirty flags) |
| Change detection | Dirty bit checking + old/new buffer comparison |
| Client-side diffing | XOR-based word comparison, only updates changed LEDs |
| Tilt | Event-driven (forwarded from client) |

---

## Slot Management

- Up to 4 slots per device type (grid and arc), matching norns port limits
- Clients identified by IP + port
- Devices discovered via zeroconf and assigned through mod menu
- Reconnecting client on same IP:port reuses existing slot

---

## Error Handling

- **Bounds checking**: LED coordinates silently ignored if out of range
- **Brightness clamping**: Values clamped to 0-15
- **Null safety**: Callbacks checked before invocation
- **Handler chaining**: Unhandled OSC messages passed to original `_norns.osc.event`

---

## File Structure

```
oscgard/
├── lib/
│   ├── grid.lua             # Drop-in grid module replacement
│   ├── arc.lua              # Drop-in arc module replacement
│   ├── mod.lua              # Mod core: OSC routing, discovery, lifecycle
│   ├── mod_menu.lua         # Reactive mod menu UI
│   ├── oscgard_grid.lua     # Grid device class and module
│   ├── oscgard_arc.lua      # Arc device class and module
│   ├── buffer.lua           # Packed bitwise LED buffer
│   └── vport_module.lua     # Shared vport factory
├── docs/
│   ├── SPEC.md              # This specification
│   └── ARCHITECTURE.md      # Technical architecture details
└── README.md
```

---

## References

- [Monome Grid Documentation](https://monome.org/docs/grid/)
- [Norns Grid API Reference](https://monome.org/docs/norns/reference/grid)
- [Norns Arc API Reference](https://monome.org/docs/norns/api/modules/arc.html)
- [SerialOSC Protocol](https://monome.org/docs/serialosc/osc/)
