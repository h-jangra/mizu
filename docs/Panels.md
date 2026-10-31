# Mizu Panels

Panels are standalone overlays (lock screen, quick settings, calendar, etc.)
that appear above the bar. Each panel is a single source file in `src/panels/`.

## Panel Lifecycle

Every panel follows this lifecycle:

1. **Init**: `Panel.init(allocator, cfg) !Panel` — Allocate resources, load fonts
2. **Render**: `Panel.render(target, scale) !void` — Draw frame via `DrawCtx`
3. **Tick**: `Panel.tick() bool` — Update state, return true if redraw needed
4. **Input**: `Panel.handleKey(...)`, `Panel.handlePointerMotion(...)`, `Panel.handlePointerButton(...)`
5. **Deinit**: `Panel.deinit()` — Free resources

Panels do **not** create their own Wayland surfaces, event loops, or buffers.
The `WaylandApp` (`src/core/wayland.zig`) owns the surface lifecycle and calls
the panel's render/input methods.

## Built-in Panels

| Panel | File | Trigger | Description |
|-------|------|---------|-------------|
| lock | `lock.zig` | `mizu lock` | Native Wayland session lock |
| launcher | `launcher.zig` | `mizu launcher` | Application launcher |
| quicksettings | `quicksettings.zig` | `mizu quicksettings` | Quick settings control panel |
| calendar | `calendar.zig` | `mizu calendar` | Interactive calendar |
| clipboard | `clipboard.zig` | `mizu clipboard` | Clipboard history manager |
| powermenu | `powermenu.zig` | `mizu power` | Session & power overlay |
| osd | `osd.zig` | `mizu notify` | On-screen display |
| memory_monitor | `memory_monitor.zig` | `mizu memory-monitor` | Process memory monitor |
| notifications | `notifications.zig` | D-Bus | Notification history |

## Adding a Custom Panel

1. Create `src/panels/my_panel.zig`:

```zig
const std = @import("std");
const draw = @import("../core/draw.zig");
const config = @import("../core/config.zig");

pub const MyPanel = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    running: bool = true,
    width: u32 = 400,
    height: u32 = 300,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !MyPanel {
        return .{ .allocator = allocator, .cfg = cfg };
    }

    pub fn deinit(self: *MyPanel) void {}

    pub fn render(self: *MyPanel, ui: *draw.DrawCtx, scale: u32) !void {
        ui.clear(self.cfg.theme.panel_bg);
        ui.roundedRect(0, 0, self.width, self.height, 16, self.cfg.theme.panel_bg);
        ui.text(font, "Hello", 20, 40, 20, self.cfg.theme.text_main);
    }

    pub fn tick(self: *MyPanel) bool {
        return false;
    }

    pub fn handleKey(self: *MyPanel, sym: u32, utf8: []const u8, ctrl: bool, shift: bool) bool {
        if (sym == c.XKB_KEY_Escape) {
            self.running = false;
            return true;
        }
        return false;
    }
};
```

2. Add a command alias in `src/main.zig`'s `parseCommand()`
3. Add a `runMyPanel()` function in `src/main.zig`
4. Add a case in `src/main.zig`'s `main` switch
5. Add surface creation in `src/core/wayland.zig` (e.g., `createMyPanelSurface`)
6. Add rendering delegation in `WaylandApp.redraw()`

## Input Handling

Panels receive input through `WaylandApp`:

- **Keyboard**: `WaylandApp.dispatchKey()` routes to the active panel's `handleKey`
- **Pointer motion**: `handlePointerMotionInternal()` routes to `handlePointerMotion`
- **Pointer buttons**: `pointer_button` routes to `handlePointerButton`
- **Pointer leave**: `pointer_leave` routes to `handlePointerLeave`

Panels return `true` from input handlers if the state changed (triggering redraw).
Panels set `running = false` to close themselves.

## Configuration

Panels read from `config.Config` (loaded from `~/.config/mizu/config.ini`).
Theme colors, typography, and panel dimensions are all configurable.

## Services

Panels consume shared services (audio, network, battery, etc.) rather than
duplicating system integration. Services live in `src/services/`.
