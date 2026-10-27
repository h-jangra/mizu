# Mizu Overview

**Mizu (水)** is a lightweight, high-performance Wayland desktop shell designed for Void Linux and MangoWC, written in Zig using native Wayland protocols.

It provides a complete desktop shell suite—status bar, application launcher, quick settings drawer, notifications daemon, system tray, clipboard manager, calendar, process monitor, and session locker—as a single unified binary without GTK, Qt, Electron, or general-purpose UI toolkits.

---

## Core Principles

* **Zero Toolkit Overhead**: Direct Wayland client rendering via `wl_shm` and `wlr-layer-shell`.
* **Zero Overhead While Closed**: Overlay panels (launcher, quick settings, calendar, clipboard, power menu) instantiate on demand and free all memory when closed, consuming **0 MB RAM** while inactive.
* **Unified Layout Core**: Uses **Clay 0.14** (`src/c/clay.h`) across the status bar and all overlay surfaces for sub-millisecond box layout, text measurement, and clipping.
* **Continuous-Curvature Squircles**: Superellipse geometry ($n \approx 4$, G2 continuity) for panels, battery capsules, and accents.

---

## Architecture & Core

Mizu coordinates all components in a single process without IPC overhead:

```
Wayland Server (MangoWC)
       │
       ├─► Layer-Shell ──► Top Status Bar (src/bar/*)
       │
       └─► On-Demand ────► Overlay Panels (src/panels/*)
                           (Launcher, QuickSettings, Calendar, Lock, etc.)
```

* **Wayland Client (`src/core/wayland.zig`)**: Manages `wl_display` event loop, layer-shell surface lifecycle, and input dispatching.
* **Software Rasterizer (`src/core/renderer.zig`)**: 2D software rasterizer writing ARGB8888 pixels directly into double-buffered `wl_shm` memory pools (`src/core/buffer.zig`).
* **Declarative UI (`src/core/ui.zig`, `src/core/clay.zig`)**: Wraps Clay 0.14 to build declarative UI trees, register input hitboxes, and measure FreeType font glyphs.
* **Async Workers (`src/core/async.zig`)**: Offloads hardware scans (Wi-Fi, Bluetooth, PAM authentication) to worker threads using a non-blocking self-pipe wakeup mechanism for 0% idle CPU and stutter-free UI.
* **Theme Engine (`src/core/theme.zig`)**: Six curated palettes (Nord, Catppuccin, Tokyo Night, Gruvbox, Rosé Pine, Frosted Neumorphic) with dynamic runtime switching.
