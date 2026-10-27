# User Guide

## CLI Commands & Subcommands

Mizu is controlled through a single unified CLI executable:

```text
Usage: mizu [command] [options]
```

| Command | Aliases | Description |
|---|---|---|
| *(none)* | `bar`, `daemon`, `run` | Starts desktop shell daemon (status bar + notification server + tray) |
| `launcher` | `-l`, `--launcher` | Toggle centered 5x3 application launcher overlay |
| `quicksettings` | `qs`, `panel`, `-q` | Toggle floating quick settings control drawer |
| `calendar` | `cal`, `-c` | Toggle interactive month/year calendar |
| `clipboard` | `clip` | Toggle searchable clipboard history manager |
| `system-monitor`| `sysmon`, `memmon` | Toggle real-time process memory & CPU monitor |
| `lock` | — | Lock session via `ext-session-lock-v1` and PAM |
| `power` | `session` | Open modal power actions overlay (lock, reboot, shutdown) |
| `notify` | — | Send desktop notification popup (`mizu notify <title> [body]`) |
| `theme` | — | Switch themes (`mizu theme [next\|prev\|set <name>\|list]`) |
| `keyoverlay` | `keys`, `keymap` | Toggle keyboard shortcuts cheatsheet HUD |
| `caffeine` | — | Run Wayland idle inhibitor daemon |
| `list` | — | List all built-in and configured custom panels |

---

## Status Bar Modules

The top bar layout is defined in `~/.config/mizu/config.ini` via `modules_left`, `modules_center`, and `modules_right`:

* **`workspaces`**: Roman numerals (`Ⅰ`–`Ⅸ`) with active, occupied, and urgent tags via MangoWC IPC.
* **`clock`**: Formatted date and time (`clock_format`); clicking opens Calendar.
* **`volume`**: Volume level icon and percentage; scroll wheel adjusts volume in 5% steps (`wpctl`); click toggles mute.
* **`battery`**: Continuous-curvature capsule with percentage and charging status read from `/sys/class/power_supply`.
* **`network`**: Wi-Fi SSID and 4-tier signal strength or Ethernet indicator; click opens Quick Settings Wi-Fi drawer.
* **`bluetooth`**: BlueZ adapter state and connected peripheral indicator.
* **`memory`**: RAM usage in GB/percent; clicking opens System Monitor.
* **`mpris`**: Media player track title and playback controls (Previous, Play/Pause, Next); auto-hides when idle.
* **`tray`**: StatusNotifierItem (SNI) system tray hosting applet icons.
* **`recorder`**: Screen recording status indicator and toggle button (`gpu-screen-recorder` / `wl-screenrec`).
* **`buttons`**: Custom quick-launch buttons defined in `[buttons]`.
* **`theme_switch`**: Interactive theme cycling chip; scroll or click to switch themes.
* **`separator`**: Vertical divider (`|`) for separating module groups.

---

## Overlay Panels & Widgets

* **Application Launcher (`mizu launcher`)**: 5x3 card grid with usage-ranked search (`~/.cache/mizu/app_usage`), inline math calculation (e.g. `125 * 4`), and file browsing.
* **Quick Settings (`mizu quicksettings`)**: Top-right drawer with quick toggles (Wi-Fi, Bluetooth, Audio, Power Profiles, Caffeine), volume/brightness sliders, and MPRIS controls.
* **Interactive Calendar (`mizu calendar`)**: Month/year view with custom iCalendar (`.ics`) holiday markers.
* **Clipboard History (`mizu clipboard`)**: Searchable clipboard history with image thumbnail and text preview; press Enter to paste.
* **Process Memory Monitor (`mizu system-monitor`)**: Live tree inspector grouping browser subprocesses with interactive `SIGTERM`/`SIGKILL` actions.
* **Session Lock Screen (`mizu lock`)**: Secure screen blanking via `ext-session-lock-v1` with PAM password authentication.
