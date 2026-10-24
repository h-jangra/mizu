# Mizu (水)

Mizu is a fast, lightweight, from-scratch Wayland desktop shell designed for Void Linux and MangoWC, written in Zig using native Wayland protocols.

It provides a cohesive desktop shell experience without GTK, Qt, Electron, raylib, X11, or any general-purpose heavyweight UI toolkit.

---

## Documentation

Full detailed documentation is available in the [`docs/`](docs/README.md) directory:
- [**Panels & Drawers Guide**](docs/panels.md): Built-in panels, creating custom panels via `[panels]`, native layer-shell development, and instance toggling.
- [**Custom Buttons Guide**](docs/custom_buttons.md): Adding custom buttons to the top bar (`[buttons]`), positioning, icons, and wiring to commands.
- [**IPC & CLI Commands Guide**](docs/ipc_and_commands.md): Unified CLI commands, panel toggling, CLI options, and window manager integration.
- [**Configuration Reference**](docs/configuration.md): Complete reference for `~/.config/mizu/config.ini`.

---

## Features

### Stage 1: Top Bar (Modular Architecture & Squircle UI)
- **Modular Bar Architecture (`src/bar/*`)**: Each bar component is an independent, reusable module:
  - `src/bar/types.zig`: `BarContext`, `ClickAction`, `ClickableArea`
  - `src/bar/workspaces.zig`: Roman numerals (`Ⅰ`, `Ⅱ`, `Ⅲ`, `Ⅳ`, `Ⅴ`, `Ⅵ`, `Ⅶ`, `Ⅷ`, `Ⅸ`) with active, urgent, and occupied states
  - `src/bar/custom_buttons.zig`: User-configured quick launch buttons from `config.ini`
  - `src/bar/mpris.zig`: Center media pill with play/pause and track title
  - `src/bar/clock.zig`: Clock chip with configurable time/date format
  - `src/bar/battery.zig`: Continuous-curvature squircle battery capsule with charging indicator
  - `src/bar/memory.zig`: RAM usage chip with vector memory SVG icon
  - `src/bar/volume.zig`: Audio volume chip with dynamic vector SVG speaker icon and scroll adjustment
  - `src/bar/backlight.zig`: Screen brightness chip with vector SVG icon and scroll adjustment
  - `src/bar/theme_switch.zig`: Interactive theme switcher module with live cycling
  - `src/bar/separator.zig`: Vertical dividers with opacity blending
  - `src/bar/bar.zig`: Modular coordinator orchestrating layout, tick, and input handling
- **Continuous-Curvature Squircle Rendering**: Built-in superellipse squircle geometry ($n \approx 4$, G2-continuous curvature) for all pills, chips, capsules, and containers using symmetric cubic Bézier curves, providing smooth corners without sharp arc transitions.
- **Dynamic Theme Switcher**:
  - Live on-bar module displaying active theme icon + name (`󰔎 Nord`, `󰔎 Catppuccin`, `󰔎 Tokyo Night`, `󰔎 Gruvbox`, `󰔎 Rosé Pine`).
  - Left-click or scroll up cycles to the next theme; Right-click or scroll down cycles to the previous theme.
  - Instantly updates bar styling and persists choice to `~/.cache/mizu/current_theme`.
  - CLI theme control via `mizu theme [next|prev|set <name>|list]`.

### Stage 2: Application Launcher
- **Centered Layer-Shell Overlay Surface**: Appears centered (`anchor = 0`, `layer = overlay`) with exclusive keyboard focus (`keyboard_interactivity = exclusive`).
- **Application Grid Layout with Icons**: Displays applications in an elegant 5x3 card grid (15 apps per page) with 48x48 icons and centered labels.
- **Icon Resolution & Caching**: Fast standard XDG icon lookup across `/usr/share/icons/hicolor/`, `/usr/share/pixmaps/`, and custom desktop icon paths. Decoded image buffers and SVG icon rasters are cached to avoid repeated disk I/O.
- **Material You Adaptive Fallback Badges**: Applications without bitmap icons display a sleek Material You adaptive icon tile with pastel tonal background (hashed from app name) and crisp centered initial letter.
- **2D Keyboard & Mouse Grid Navigation**:
  - `Left` / `Right`: Navigate horizontally
  - `Up` / `Down`: Navigate vertically by rows
  - `Page Up` / `Page Down`: Jump full pages
  - `Return` / `KP_Enter`: Launch selected app (or execute custom command) and close
  - `Escape`: Instantly close launcher
  - Mouse motion & click: Hover cards and click to launch
- **Incremental In-Memory Search**: Weighted ranking matching name prefixes, words, generic names, keywords, and comments. No external subprocesses spawned while typing.
- **Zero Overhead While Closed**: Launches on-demand and terminates immediately upon launch or dismissal, using 0 MB memory when closed.

### Stage 3: Quick Settings & Panels
- **Floating Top-Right Drawer**: Anchored to `TOP | RIGHT` right below the bar with 16px corner radius, crisp borders.
- **System Header**: Displays user & host (`user@host`), system uptime (`up Xh Ym`), and quick power action buttons: Lock (`󰌾`), Suspend (`󰒲`), Shutdown (`󰐥`), and Close (`󰅖`).
- **2x2 Quick Toggles Grid**:
  - **Wi-Fi**: Live connection discovery & SSID; click toggles Wi-Fi on/off (`nmcli` / sysfs rfkill).
  - **Bluetooth**: Live status; click toggles power on/off (`bluetoothctl` / sysfs rfkill).
  - **Audio**: Live mute state; click toggles mute (`wpctl`).
  - **Do Not Disturb**: Silent mode toggle.
- **Interactive Audio Volume Slider**: Click or drag across the slider to adjust volume in real-time (`wpctl set-volume @DEFAULT_AUDIO_SINK@ X%`).
- **Interactive Screen Brightness Slider**: Automatically discovers backlight devices (`/sys/class/backlight/*`); click or drag to adjust display brightness (`brightnessctl set X%`).
- **Active MPRIS Media Player Card**: Displays currently playing song, artist, and interactive playback buttons (`󰒮` Previous, `󰐊`/`󰏤` Play-Pause, `󰒭` Next).
- **System Metrics & Battery Card**: Shows real-time CPU utilization (`󰻠 CPU`), RAM consumption (`󰍛 RAM`), and battery percentage / charging state (`󰂄 Battery`).
- **Date Strip Footer**: Formatted date display (` Day, Date Month Year`).
- **Seamless Bar Integration**: Clicking the clock, battery, or backlight chip on the bar opens Quick Settings; right-clicking volume or CPU/RAM chips also opens Quick Settings.
- **On-Demand Lifecycle**: Consumes 0 MB RAM when closed; only ~2.2 MB anonymous RAM when open; closes instantly on `Escape` or Close button.

### Stage 4: Desktop Notifications
- **Notification Surface (`mizu notify <title> [body]`)**:
  - Top-right banner alert with `󰂚` icon, bold summary, muted message, and click-to-dismiss.
- **Zero Overhead**: Automatically terminates after 3.5s; leaves 0 background daemons and uses 0 MB memory when closed.

### Stage 5: Native Wayland Lock Screen (`mizu lock`)
- **Native Wayland Session Lock Protocol (`ext-session-lock-v1`)**:
  - Full-screen hardware-level blanking and locking across all active and newly plugged outputs.
  - Desktop content is completely hidden and guarded against unauthorized access.
  - If the compositor lacks protocol support, gracefully delegates to an installed trusted locker (`hyprlock`, `swaylock`) without compromising security with an insecure pseudo-window.
- **Wallpaper Reuse & Translucent Overlay**:
  - Automatically discovers and decodes the active desktop wallpaper (`~/.cache/wm/current_wallpaper`, `swaybg -i`, or `config.ini`).
  - Zero asset duplication; decodes in-memory and caches per-output resolution with a subtle translucent dark overlay for clean typography contrast.
- **Lightweight Zero-Continuous-Redraw Rendering**:
  - Pre-rendered background blitting in microseconds.
  - Timer-driven 1-second clock updates and double-buffered SHM pools; 0% idle CPU between updates.
- **Secure PAM Authentication**:
  - Asynchronous background worker thread authenticates via system PAM services (`mizu`, `hyprlock`, `swaylock`, `login`).
  - Zero hardcoded credentials or cleartext credential caching; password memory is securely zeroed immediately following authentication attempts.
  - Interactive feedback: masked password bullets (`● ● ●`), blinking caret, `Verifying...` indicator, and failed attempt counter.
  - `Enter` to authenticate, `Escape` to clear input without unlocking.


---

## Environment & Dependency Audit (Void Linux)

Verified on **Void Linux** (Linux kernel 6.18, x86_64):

| Component | Verified Version | Package Name (XBPS) | Purpose |
|---|---|---|---|
| **Zig** | `0.16.0` | `zig` | Application code & build toolchain |
| **Compositor** | MangoWC `0.17.5(release)` | `mangowc` | Running Wayland compositor with layer-shell |
| **Wayland Client** | `1.26.0` | `wayland`, `wayland-devel` | Core Wayland client library |
| **Wayland Protocols** | `1.49` | `wayland-protocols` | Protocol XML specifications (`xdg-shell`) |
| **Keyboard Library** | `1.13.2` | `libxkbcommon`, `libxkbcommon-devel` | Keyboard map translation and keycodes |
| **FreeType** | `2.14.3` | `freetype`, `freetype-devel` | Font rasterization & glyph rendering |
| **NanoSVG** | vendored | `src/core/nanosvg.{h,c}` | SVG icon parsing (zlib licensed, bundled source) |
| **NanoSVG Rasterizer** | vendored | `src/core/nanosvg_rasterizer.{h,c}` | SVG alpha rasterization for crisp icons (zlib licensed, bundled source) |
| **Fontconfig** | `2.17.1` | `fontconfig`, `fontconfig-devel` | Font discovery and matching |
| **Protocol Generator** | `1.26.0` | `wayland-devel` (`wayland-scanner`) | C code/header generation from protocol XML |

### Installation on Void Linux

```bash
sudo xbps-install -S wayland-devel wayland-protocols libxkbcommon-devel freetype-devel fontconfig-devel pkg-config
```

---

## CLI Commands & Subcommands

Mizu is built as a single unified executable with dedicated subcommands:

```text
Usage: mizu <command> [options]

A lightweight, from-scratch Wayland desktop shell for Void Linux and MangoWC.

Commands:
  bar             Start the top desktop bar
  lock            Lock the session with native Wayland lock screen
  launcher        Open the application launcher overlay (aliases: -l, --launcher)
  quicksettings   Open the quick settings control panel (aliases: qs, panel, -q)
  calendar        Open interactive month/year calendar (aliases: cal, -c)
  clipboard       Open clipboard history search & manager (aliases: clip)
  notify          Show a desktop notification popup (mizu notify <title> [body])
  theme           Switch or inspect themes (mizu theme [next|prev|set <name>|list])
  keyoverlay      Show on-screen key combination overlay (aliases: keymap, keys)
  list            List all available built-in and configured custom panels
  help            Display this help message
  version         Display version information

Options:
  -h, --help      Display this help message
  -v, --version   Display version information
```

### Direct Panel & Action Commands
- `mizu lock` — locks all monitors using the native Wayland session-lock protocol with PAM authentication.
- `mizu launcher` — toggles the application launcher overlay.
- `mizu quicksettings` (or `mizu qs`) — toggles the quick settings control drawer.
- `mizu calendar` (or `mizu cal`) — toggles the interactive calendar.
- `mizu clipboard` (or `mizu clip`) — toggles clipboard history search.
- `mizu keyoverlay` (or `mizu keys`) — toggles keyboard shortcut cheat sheet.
- `mizu <custom_panel>` — toggles any custom panel defined in `[panels]`.
- `mizu list` — lists all built-in and registered custom panels.
- `mizu notify <title> [body]` — posts a desktop notification.
- `mizu theme [next|prev|set <name>|list]` — manages themes.

---

## Building and Installation

### Build Targets

```bash
# Debug build (zig-out/bin/mizu)
zig build

# Smallest size build (265 KB binary)
zig build -Doptimize=ReleaseSmall

# Highest performance build (3.9 MB binary)
zig build -Doptimize=ReleaseFast
```

### Installation to User PATH

To install or symlink `mizu` into your user binaries directory (`~/.local/bin`):

```bash
mkdir -p ~/.local/bin
ln -sf $(pwd)/zig-out/bin/mizu ~/.local/bin/mizu
```

Once installed, verify that `mizu` is accessible:
```bash
mizu --version
```

### MangoWC Integration

Add the following keybinding to `~/.config/mango/config.conf` to launch Mizu with Super+Space:
```conf
bind = SUPER, Space, spawn, mizu launcher
```

To auto-start the Mizu bar when MangoWC starts, add:
```conf
exec_always = mizu bar
```

### Run Unit Tests
```bash
zig build test
```
Runs test suite covering desktop file parsing, field-code cleanup, and weighted search ranking.

---

## Configuration

Mizu searches for configuration at:
1. `$XDG_CONFIG_HOME/mizu/config.ini`
2. `~/.config/mizu/config.ini`

If no configuration file exists, built-in defaults are used.

An example configuration file is provided in `config/config.example`:

```ini
# Geometry
height = 32
margin_top = 4
margin_bottom = 0
margin_left = 8
margin_right = 8
border_width = 1
bar_radius = 8
pill_radius = 6

# Typography & Time
font_family = Maple Mono NF, monospace
clock_format = %a %b %d  %H:%M

# Logical pixel sizes; see docs/configuration.md for every key
[typography]
ui = 15
secondary = 13
bar_text = 15
bar_icon = 20

# Nord Colors
bar_bg = #2E3440
bar_border = #4C566A
pill_bg = #3B4252
ws_active_bg = #88C0D0
ws_active_fg = #2E3440

# Custom Buttons (Label = Shell Command or 'mizu <panel>')
[buttons]
󰍉 Menu = mizu launcher
󰌌 Term = foot
󰉋 Files = thunar
󰈹 Web = firefox
󰅍 Clip = mizu clipboard
󰸗 Cal = mizu calendar
󰒓 QS = mizu quicksettings
󰚝 Audio = mizu mixer

# Custom Panels (Toggle directly via 'mizu <name>')
[panels]
mixer = pavucontrol
dashboard = foot -e btop
notes = foot -e nvim ~/.notes.md
```

---

## Resource Usage Measurements

Measurements taken under active MangoWC session (`1920x1080@1`, `ReleaseFast`):

### 1. Top Bar (Stage 1)
```text
VmSize:    13,580 kB
VmRSS:      7,072 kB
PSS:        2,266 kB (~2.2 MB)
Threads:    1
Idle CPU:   0.0%
```

### 2. Application Launcher (Stage 2)
```text
Launcher Closed:
  Process: None (0 MB RAM, 0.0% CPU)

Launcher Open:
  VmSize:    14,908 kB
  VmRSS:      8,352 kB
  PSS:        2,785 kB (~2.8 MB)
  Threads:    1
  Idle CPU:   0.0% (sleeping in kernel poll() awaiting input)
```

### Measurement Commands
```bash
# Check memory & CPU of running Mizu process:
MIZU_PID=$(pidof mizu)
grep -E "VmRSS|VmSize|Threads" /proc/$MIZU_PID/status
grep -E "Pss:" /proc/$MIZU_PID/smaps_rollup
top -b -n 2 -d 1 -p $MIZU_PID
```
