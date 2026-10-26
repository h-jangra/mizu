# Mizu Panels

Panels are standalone overlays (lock screen, quick settings, calendar, etc.)
that appear above the bar. Each panel is a single source file in `src/panels/`.

## Panel Lifecycle

Every panel follows this lifecycle:

1. **Init**: `Panel.init(allocator, cfg) !Panel` — allocate resources and load fonts
2. **Render**: `Panel.render(target, scale)` — build a Clay layout and paint the result
3. **Tick**: `Panel.tick() bool` — update state, return `true` if a redraw is needed
4. **Input**: `Panel.handleKey(...)`, `Panel.handlePointerMotion(...)`, `Panel.handlePointerButton(...)`
5. **Deinit**: `Panel.deinit()` — free resources

Panels do **not** create their own Wayland surfaces, event loops, or buffers.
The `WaylandApp` (`src/core/wayland.zig`) owns the surface lifecycle and calls
the panel's render/input methods.

## Rendering with Clay

Every bar module and shell surface uses the same layout engine:

- `src/c/clay.h` — vendored Clay 0.14, the authoritative layout API
- `src/c/clay_impl.c` — the single C translation unit compiled by `build.zig`
- `src/core/clay.zig` — Zig interop, global Clay context/arena, text measurement
- `src/core/ui.zig` — Zig builder helpers, render-command consumer, clipping and
  overlay stacks, per-frame text arena
- `src/core/renderer.zig` — native rasterization into the `wl_shm` buffer

Clay computes element boxes, wrapping, alignment, text measurement, clipping,
and scroll containers. Mizu consumes the resulting render commands and paints
rounded rectangles, borders, text, images, SVG icons, and custom callbacks with
its own renderer. There is no GTK, Qt, Cairo, SDL, Raylib, or OpenGL layer.

Clay dimensions are **physical pixels**. Use `ui.s()` / `ui.su()` for logical
tokens so HiDPI layouts stay crisp. When storing resolved hit areas for Wayland
pointer input, divide the physical rect by `scale` first.

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
| keyoverlay | `../services/keymap.zig` | `mizu keyoverlay` | Keyboard shortcut overlay |

## Adding a Custom Panel

1. Create `src/panels/my_panel.zig`:

```zig
const std = @import("std");
const c = @import("../c.zig").c;
const config = @import("../core/config.zig");
const renderer = @import("../core/renderer.zig");
const ui_mod = @import("../core/ui.zig");

pub const MyPanel = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    font: renderer.Font,
    running: bool = true,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !MyPanel {
        const font = try renderer.Font.init(allocator, cfg.theme.font_family, cfg.typography.ui);
        return .{ .allocator = allocator, .cfg = cfg, .font = font };
    }

    pub fn deinit(self: *MyPanel) void {
        self.font.deinit();
    }

    pub fn render(self: *MyPanel, target: renderer.Renderer, scale: u32) !void {
        var ui = try ui_mod.Ui.begin(
            self.allocator,
            &self.font,
            target.width,
            target.height,
            scale,
            -1,
            -1,
            false,
            1.0 / 60.0,
        );
        defer ui.deinit();

        ui.root(.{
            .direction = .column,
            .padding = .all(ui.su(16)),
            .gap = ui.su(12),
            .bg = self.cfg.theme.panel_bg,
            .radius = ui.f(self.cfg.theme.radius_panel),
        });

        ui.text("Hello", .{
            .size = self.cfg.typography.title * scale,
            .color = self.cfg.theme.text_main,
        });

        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .fixed = ui.s(64) },
            .bg = self.cfg.theme.card_bg,
            .radius = ui.f(self.cfg.theme.radius_card),
            .border = ui.su(1),
            .border_color = self.cfg.theme.border,
        });
        ui.close();

        ui.close();
        const commands = ui.endLayout();
        ui.render(target, commands);
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
5. Add surface creation in `src/core/wayland.zig` (for example `createMyPanelSurface`)
6. Add rendering delegation in `WaylandApp.redraw()`

### Layout notes

- `ui.text` copies the string into the frame arena. Do not pass temporary stack
  buffers that die before `ui.endLayout()`.
- `ui.icon` and `ui.image` are self-closing leaves. `ui.open` must be paired with
  `ui.close`, unless `ui.endLayout()` should auto-close it.
- `ui.custom` calls a custom draw callback for complex content (text input,
  clipboard preview, pixmap previews). Wrap it in a normal Clay box when the
  element needs an ID, hover state, or `rectOf` hit rectangle.
- Use `ui.hovered(id, index)` before opening the element for styling. Clay's
  hover state comes from the previous frame.
- `MIZU_CLAY_DEBUG=1` prints every Clay render command and its bounding box.

## Input Handling

Panels receive input through `WaylandApp`:

- **Keyboard**: `WaylandApp.dispatchKey()` routes to the active panel's `handleKey`
- **Pointer motion**: `handlePointerMotionInternal()` routes to `handlePointerMotion`
- **Pointer buttons**: `pointer_button` routes to `handlePointerButton`
- **Pointer leave**: `pointer_leave` routes to `handlePointerLeave`

Panels return `true` from input handlers if the state changed (triggering a
redraw). Panels set `running = false` to close themselves.

Pointer coordinates from Wayland are logical. Clay/hit rects are physical, so
divide a resolved `renderer.Rect` by `scale` before storing or testing it.

## Configuration

Panels read from `config.Config` (loaded from `~/.config/mizu/config.ini`).
Theme colors, typography, and panel dimensions are configurable.

## Services

Panels consume shared services (audio, network, battery, etc.) rather than
duplicating system integration. Services live in `src/services/`.
