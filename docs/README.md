# Mizu Documentation

Welcome to the comprehensive documentation for **Mizu (水)** — a fast, lightweight, from-scratch Wayland desktop shell designed for Void Linux and MangoWC, built with Zig and native Wayland protocols.

---

## Documentation Index

| Guide | Description |
|---|---|
| [**Panels & Drawers Guide**](Panels.md) | Built-in panels (`launcher`, `quicksettings`, `calendar`, `clipboard`, `keyoverlay`, `lock`), defining custom panels via `[panels]`, writing standalone layer-shell panels, and instance toggle behavior. |
| [**Configuration Reference**](Configuration.md) | Complete reference for `~/.config/mizu/config.ini`, including bar geometry, themes, modular layout, recorder settings, `[buttons]`, and `[panels]`. |

---

## Quick Reference: CLI Commands

Mizu provides direct CLI commands for controlling panels, session locking, and triggering desktop actions:

```bash
# Session locking
mizu lock                # Lock screen with native Wayland session-lock and PAM auth

# Toggle built-in panels
mizu launcher            # Toggle centered application launcher
mizu quicksettings       # Toggle top-right quick settings drawer (aliases: qs, panel)
mizu calendar            # Toggle interactive calendar panel (alias: cal)
mizu clipboard           # Toggle clipboard history search panel (alias: clip)
mizu keyoverlay          # Toggle keyboard shortcuts cheat sheet (aliases: keys, keymap)
mizu memory-monitor      # Toggle live process memory monitor (aliases: mem-monitor, memmon)

# Desktop notifications & themes
mizu notify "Title" "Message body text"
mizu theme next
mizu theme set nord

# Toggle or launch custom panels (configured in config.ini)
mizu mixer               # Toggle pavucontrol or audio mixer
mizu dashboard           # Toggle system dashboard

# List all available built-in and registered custom panels
mizu list
```

---

## Architecture Overview

```
                                 +-------------------+
                                 |    MangoWC / WM   |
                                 +---------+---------+
                                           |
                          +----------------+----------------+
                          |                                 |
                          v                                 v
                  Wayland Layer-Shell               Direct CLI Commands
                          |                                 |
         +----------------+----------------+                |
         |                |                |                |
         v                v                v                v
    Top Bar Surface   Overlay Panels   OSD Popups    Dynamic Toggle & PID Manager
    (src/bar/*)       (Launcher, QS,   (Notify,      (/tmp/mizu-<target>.pid)
    - Clock           Clipboard, Cal,   Gauges)
    - Workspaces      Keyoverlay,
    - Custom Buttons  Custom Panels)
    - System Status
```

All Mizu panels follow a **zero-overhead lifecycle**: they consume 0 MB RAM when closed, instantiate in milliseconds on demand, dismiss cleanly when clicked outside or on pressing `Escape`, and toggle gracefully on repeat invocation.