const std = @import("std");
const c = @import("../c.zig").c;
const buffer = @import("buffer.zig");
const renderer = @import("renderer.zig");
const config = @import("config.zig");
const bar_module = @import("../bar/bar.zig");
const launcher_module = @import("../panels/launcher.zig");
const quicksettings_module = @import("../panels/quicksettings.zig");
const memory_monitor_module = @import("../panels/memory_monitor.zig");
const osd_module = @import("../panels/osd.zig");
const calendar_module = @import("../panels/calendar.zig");
const clipboard_module = @import("../panels/clipboard.zig");
const mango_ipc = @import("../services/mango_ipc.zig");
pub const keymap_module = @import("../services/keymap.zig");
pub const power_module = @import("../panels/powermenu.zig");

pub const CursorShape = enum {
    default,
    pointer,
    text,
};

pub const WaylandApp = struct {
    display: ?*c.wl_display = null,
    registry: ?*c.wl_registry = null,
    compositor: ?*c.wl_compositor = null,
    shm: ?*c.wl_shm = null,
    layer_shell: ?*c.zwlr_layer_shell_v1 = null,
    seat: ?*c.wl_seat = null,
    pointer: ?*c.wl_pointer = null,
    keyboard: ?*c.wl_keyboard = null,
    output: ?*c.wl_output = null,
    viewporter: ?*c.wp_viewporter = null,
    viewport: ?*c.wp_viewport = null,
    output_scale_factor: u32 = 1,
    output_scale_frac: f32 = 1.0,

    surface: ?*c.wl_surface = null,
    layer_surface: ?*c.zwlr_layer_surface_v1 = null,
    backdrop_surface: ?*c.wl_surface = null,
    backdrop_layer_surface: ?*c.zwlr_layer_surface_v1 = null,
    backdrop_buf: ?buffer.ShmBuffer = null,
    current_pointer_surface: ?*c.wl_surface = null,

    buffer_pool: ?buffer.BufferPool = null,
    cfg: config.Config,

    xkb_ctx: ?*c.struct_xkb_context = null,
    xkb_keymap: ?*c.struct_xkb_keymap = null,
    xkb_state: ?*c.struct_xkb_state = null,

    width: u32 = 0,
    height: u32 = 32,
    configured: bool = false,
    running: bool = true,
    needs_redraw: bool = true,
    pointer_x: i32 = -1,
    pointer_y: i32 = -1,
    pointer_serial: u32 = 0,

    cursor_theme: ?*c.wl_cursor_theme = null,
    cursor_default: ?*c.wl_cursor = null,
    cursor_pointer: ?*c.wl_cursor = null,
    cursor_text: ?*c.wl_cursor = null,
    cursor_surface: ?*c.wl_surface = null,
    current_cursor_shape: ?CursorShape = null,

    bar: ?*bar_module.Bar = null,
    launcher: ?*launcher_module.Launcher = null,
    quicksettings: ?*quicksettings_module.QuickSettings = null,
    memory_monitor: ?*memory_monitor_module.MemoryMonitor = null,
    osd: ?*osd_module.Osd = null,
    calendar: ?*calendar_module.Calendar = null,
    clipboard: ?*clipboard_module.ClipboardPanel = null,
    keyoverlay: ?*keymap_module.KeyOverlay = null,
    power: ?*power_module.PowerOverlay = null,
    ipc: ?*mango_ipc.MangoIpc = null,
    has_kbd_focus: bool = false,

    repeat_timer_fd: c_int = -1,
    repeat_delay: i32 = 280,
    repeat_rate: i32 = 30,
    repeat_key: ?u32 = null,
    repeat_keycode: u32 = 0,
    repeat_sym: u32 = 0,
    repeat_utf8_buf: [32]u8 = [_]u8{0} ** 32,
    repeat_utf8_len: usize = 0,
    repeat_is_ctrl: bool = false,
    repeat_is_shift: bool = false,
    repeat_start_ms: i64 = 0,
    repeat_accelerated: bool = false,

    pub fn init(cfg: config.Config) WaylandApp {
        return .{
            .cfg = cfg,
            .height = cfg.height,
        };
    }

    pub fn connect(self: *WaylandApp) !void {
        const display = c.wl_display_connect(null);
        if (display == null) {
            return error.WaylandDisplayConnectFailed;
        }
        self.display = display;
        errdefer {
            c.wl_display_disconnect(display);
            self.display = null;
        }

        self.xkb_ctx = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
        self.repeat_timer_fd = c.timerfd_create(c.CLOCK_MONOTONIC, c.TFD_CLOEXEC | c.TFD_NONBLOCK);

        const registry = c.wl_display_get_registry(display);
        if (registry == null) return error.GetRegistryFailed;
        self.registry = registry;

        _ = c.wl_registry_add_listener(registry, &registry_listener, self);
        _ = c.wl_display_roundtrip(display);

        if (self.compositor == null) return error.NoCompositor;
        if (self.shm == null) return error.NoShm;
        if (self.layer_shell == null) return error.NoLayerShell;

        self.buffer_pool = buffer.BufferPool.init(self.shm.?);
        self.initCursor();
    }

    fn initCursor(self: *WaylandApp) void {
        if (self.shm == null or self.compositor == null) return;
        const theme_name = c.getenv("XCURSOR_THEME");
        const theme_size_str = c.getenv("XCURSOR_SIZE");
        var cursor_size: c_int = 24;
        if (theme_size_str) |s| {
            const parsed = std.fmt.parseInt(c_int, std.mem.span(s), 10) catch 24;
            if (parsed > 0) cursor_size = parsed;
        }

        const theme_ptr = c.wl_cursor_theme_load(theme_name, cursor_size, self.shm.?);
        if (theme_ptr) |t| {
            self.cursor_theme = t;
            self.cursor_default = c.wl_cursor_theme_get_cursor(t, "left_ptr") orelse c.wl_cursor_theme_get_cursor(t, "default");
            self.cursor_pointer = c.wl_cursor_theme_get_cursor(t, "pointer") orelse
                c.wl_cursor_theme_get_cursor(t, "pointing_hand") orelse
                c.wl_cursor_theme_get_cursor(t, "hand2");
            self.cursor_text = c.wl_cursor_theme_get_cursor(t, "text") orelse
                c.wl_cursor_theme_get_cursor(t, "xterm") orelse
                c.wl_cursor_theme_get_cursor(t, "ibeam");
            self.cursor_surface = c.wl_compositor_create_surface(self.compositor.?);
        }
    }

    pub fn updateCursor(self: *WaylandApp, is_pointer: bool) void {
        self.updateCursorShape(if (is_pointer) .pointer else .default);
    }

    pub fn updateCursorShape(self: *WaylandApp, shape: CursorShape) void {
        if (self.pointer == null or self.cursor_surface == null or self.cursor_theme == null) return;
        if (self.current_cursor_shape != null and self.current_cursor_shape.? == shape) return;
        self.current_cursor_shape = shape;

        const cur = switch (shape) {
            .pointer => (self.cursor_pointer orelse self.cursor_default),
            .text => (self.cursor_text orelse self.cursor_default),
            .default => self.cursor_default,
        };

        if (cur) |c_cursor| {
            if (c_cursor.*.image_count > 0) {
                const img = c_cursor.*.images[0];
                const buf = c.wl_cursor_image_get_buffer(img);
                if (buf) |b| {
                    c.wl_pointer_set_cursor(
                        self.pointer.?,
                        self.pointer_serial,
                        self.cursor_surface.?,
                        @intCast(img.*.hotspot_x),
                        @intCast(img.*.hotspot_y),
                    );
                    c.wl_surface_attach(self.cursor_surface.?, b, 0, 0);
                    c.wl_surface_damage(
                        self.cursor_surface.?,
                        0,
                        0,
                        @intCast(img.*.width),
                        @intCast(img.*.height),
                    );
                    c.wl_surface_commit(self.cursor_surface.?);
                }
            }
        }
    }

    pub fn deinit(self: *WaylandApp) void {
        if (self.cursor_surface) |cs| {
            c.wl_surface_destroy(cs);
            self.cursor_surface = null;
        }
        if (self.cursor_theme) |ct| {
            c.wl_cursor_theme_destroy(ct);
            self.cursor_theme = null;
        }
        if (self.buffer_pool) |*pool| {
            pool.deinit();
        }
        if (self.backdrop_buf) |*bb| {
            bb.deinit();
            self.backdrop_buf = null;
        }
        if (self.backdrop_layer_surface) |bls| {
            c.zwlr_layer_surface_v1_destroy(bls);
            self.backdrop_layer_surface = null;
        }
        if (self.backdrop_surface) |bs| {
            c.wl_surface_destroy(bs);
            self.backdrop_surface = null;
        }
        if (self.layer_surface) |ls| {
            c.zwlr_layer_surface_v1_destroy(ls);
            self.layer_surface = null;
        }
        if (self.surface) |s| {
            c.wl_surface_destroy(s);
            self.surface = null;
        }
        if (self.keyboard) |kbd| {
            c.wl_keyboard_destroy(kbd);
            self.keyboard = null;
        }
        if (self.pointer) |p| {
            c.wl_pointer_destroy(p);
            self.pointer = null;
        }
        if (self.seat) |st| {
            c.wl_seat_destroy(st);
            self.seat = null;
        }
        if (self.viewport) |vp| {
            c.wp_viewport_destroy(vp);
            self.viewport = null;
        }
        if (self.viewporter) |vp| {
            c.wp_viewporter_destroy(vp);
            self.viewporter = null;
        }
        if (self.layer_shell) |ls| {
            c.zwlr_layer_shell_v1_destroy(ls);
            self.layer_shell = null;
        }
        if (self.shm) |sh| {
            c.wl_shm_destroy(sh);
            self.shm = null;
        }
        if (self.compositor) |comp| {
            c.wl_compositor_destroy(comp);
            self.compositor = null;
        }
        if (self.registry) |reg| {
            c.wl_registry_destroy(reg);
            self.registry = null;
        }
        if (self.display) |disp| {
            c.wl_display_disconnect(disp);
            self.display = null;
        }
        if (self.xkb_state) |st| {
            c.xkb_state_unref(st);
            self.xkb_state = null;
        }
        if (self.xkb_keymap) |km| {
            c.xkb_keymap_unref(km);
            self.xkb_keymap = null;
        }
        if (self.xkb_ctx) |ctx| {
            c.xkb_context_unref(ctx);
            self.xkb_ctx = null;
        }
        if (self.repeat_timer_fd >= 0) {
            _ = c.close(self.repeat_timer_fd);
            self.repeat_timer_fd = -1;
        }
    }

    fn setupSurfaceScaling(self: *WaylandApp, surface: *c.wl_surface) void {
        // Set buffer scale for integer scaling
        if (self.output_scale_factor > 1) {
            c.wl_surface_set_buffer_scale(surface, @intCast(self.output_scale_factor));
        }
        if (self.viewporter != null and self.output_scale_frac > 1.0) {
            self.viewport = c.wp_viewporter_get_viewport(self.viewporter.?, surface);
            // Set destination size to logical size
            c.wp_viewport_set_destination(self.viewport.?, @intCast(self.width), @intCast(self.height));
        }
    }

    pub fn createSurface(self: *WaylandApp) !void {
        const surf = c.wl_compositor_create_surface(self.compositor.?);
        if (surf == null) return error.CreateSurfaceFailed;
        self.surface = surf;

        self.setupSurfaceScaling(surf.?);

        const layer_surf = c.zwlr_layer_shell_v1_get_layer_surface(
            self.layer_shell.?,
            surf,
            self.output,
            c.ZWLR_LAYER_SHELL_V1_LAYER_TOP,
            "mizu-bar",
        );
        if (layer_surf == null) return error.GetLayerSurfaceFailed;
        self.layer_surface = layer_surf;

        _ = c.zwlr_layer_surface_v1_add_listener(layer_surf, &layer_surface_listener, self);

        const anchor = c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;

        c.zwlr_layer_surface_v1_set_anchor(layer_surf, anchor);
        c.zwlr_layer_surface_v1_set_size(layer_surf, 0, self.height);
        c.zwlr_layer_surface_v1_set_exclusive_zone(
            layer_surf,
            @intCast(self.height + self.cfg.margin_bottom),
        );
        c.zwlr_layer_surface_v1_set_margin(
            layer_surf,
            @intCast(self.cfg.margin_top),
            @intCast(self.cfg.margin_right),
            @intCast(self.cfg.margin_bottom),
            @intCast(self.cfg.margin_left),
        );
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(
            layer_surf,
            c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE,
        );

        c.wl_surface_commit(surf);
        _ = c.wl_display_roundtrip(self.display.?);
    }

    pub fn createBackdrop(self: *WaylandApp) !void {
        if (self.layer_shell == null or self.compositor == null) return;
        const b_surf = c.wl_compositor_create_surface(self.compositor.?);
        if (b_surf == null) return error.CreateSurfaceFailed;
        self.backdrop_surface = b_surf;
        self.setupSurfaceScaling(b_surf.?);

        const b_layer_surf = c.zwlr_layer_shell_v1_get_layer_surface(
            self.layer_shell.?,
            b_surf,
            self.output,
            c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
            "mizu-backdrop",
        );
        if (b_layer_surf == null) return error.GetLayerSurfaceFailed;
        self.backdrop_layer_surface = b_layer_surf;

        _ = c.zwlr_layer_surface_v1_add_listener(b_layer_surf, &backdrop_layer_surface_listener, self);

        const anchor = c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;
        c.zwlr_layer_surface_v1_set_anchor(b_layer_surf, anchor);
        c.zwlr_layer_surface_v1_set_size(b_layer_surf, 0, 0);
        c.zwlr_layer_surface_v1_set_exclusive_zone(b_layer_surf, -1);
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(
            b_layer_surf,
            c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE,
        );

        c.wl_surface_commit(b_surf);
        _ = c.wl_display_roundtrip(self.display.?);
    }

    pub fn createLauncherSurface(self: *WaylandApp, w: u32, h: u32) !void {
        try self.createBackdrop();
        self.width = w;
        self.height = h;

        const surf = c.wl_compositor_create_surface(self.compositor.?);
        if (surf == null) return error.CreateSurfaceFailed;
        self.surface = surf;
        self.setupSurfaceScaling(surf.?);

        const layer_surf = c.zwlr_layer_shell_v1_get_layer_surface(
            self.layer_shell.?,
            surf,
            self.output,
            c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
            "mizu-launcher",
        );
        if (layer_surf == null) return error.GetLayerSurfaceFailed;
        self.layer_surface = layer_surf;

        _ = c.zwlr_layer_surface_v1_add_listener(layer_surf, &layer_surface_listener, self);

        // Center on screen: no anchors
        c.zwlr_layer_surface_v1_set_anchor(layer_surf, 0);
        c.zwlr_layer_surface_v1_set_size(layer_surf, w, h);
        c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surf, -1);
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(
            layer_surf,
            c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE,
        );

        c.wl_surface_commit(surf);
        _ = c.wl_display_roundtrip(self.display.?);
    }

    pub fn createQuickSettingsSurface(self: *WaylandApp, w: u32, h: u32) !void {
        try self.createBackdrop();
        self.width = w;
        self.height = h;

        const surf = c.wl_compositor_create_surface(self.compositor.?);
        if (surf == null) return error.CreateSurfaceFailed;
        self.surface = surf;
        self.setupSurfaceScaling(surf.?);

        const layer_surf = c.zwlr_layer_shell_v1_get_layer_surface(
            self.layer_shell.?,
            surf,
            self.output,
            c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
            "mizu-quicksettings",
        );
        if (layer_surf == null) return error.GetLayerSurfaceFailed;
        self.layer_surface = layer_surf;

        _ = c.zwlr_layer_surface_v1_add_listener(layer_surf, &layer_surface_listener, self);

        const anchor = c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;
        c.zwlr_layer_surface_v1_set_anchor(layer_surf, anchor);
        c.zwlr_layer_surface_v1_set_size(layer_surf, w, h);
        c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surf, -1);
        const margin_top: i32 = @intCast(self.cfg.height + self.cfg.margin_top + self.cfg.margin_bottom + 4);
        const margin_right: i32 = @intCast(self.cfg.margin_right + 4);
        c.zwlr_layer_surface_v1_set_margin(layer_surf, margin_top, margin_right, 0, 0);
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(
            layer_surf,
            c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE,
        );

        c.wl_surface_commit(surf);
        _ = c.wl_display_roundtrip(self.display.?);
    }

    pub fn createMemoryMonitorSurface(self: *WaylandApp, w: u32, h: u32) !void {
        try self.createBackdrop();
        self.width = w;
        self.height = h;

        const surf = c.wl_compositor_create_surface(self.compositor.?);
        if (surf == null) return error.CreateSurfaceFailed;
        self.surface = surf;
        self.setupSurfaceScaling(surf.?);

        const layer_surf = c.zwlr_layer_shell_v1_get_layer_surface(
            self.layer_shell.?,
            surf,
            self.output,
            c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
            "mizu-memory-monitor",
        );
        if (layer_surf == null) return error.GetLayerSurfaceFailed;
        self.layer_surface = layer_surf;

        _ = c.zwlr_layer_surface_v1_add_listener(layer_surf, &layer_surface_listener, self);

        const anchor = c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;
        c.zwlr_layer_surface_v1_set_anchor(layer_surf, anchor);
        c.zwlr_layer_surface_v1_set_size(layer_surf, w, h);
        c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surf, -1);
        const margin_top: i32 = @intCast(self.cfg.height + self.cfg.margin_top + self.cfg.margin_bottom + 6);
        const margin_right: i32 = @intCast(self.cfg.margin_right);
        c.zwlr_layer_surface_v1_set_margin(layer_surf, margin_top, margin_right, 0, 0);
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(
            layer_surf,
            c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE,
        );

        c.wl_surface_commit(surf);
        _ = c.wl_display_roundtrip(self.display.?);
    }

    pub fn createCalendarSurface(self: *WaylandApp, w: u32, h: u32) !void {
        try self.createBackdrop();
        self.width = w;
        self.height = h;

        const surf = c.wl_compositor_create_surface(self.compositor.?);
        if (surf == null) return error.CreateSurfaceFailed;
        self.surface = surf;
        self.setupSurfaceScaling(surf.?);

        const layer_surf = c.zwlr_layer_shell_v1_get_layer_surface(
            self.layer_shell.?,
            surf,
            self.output,
            c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
            "mizu-calendar",
        );
        if (layer_surf == null) return error.GetLayerSurfaceFailed;
        self.layer_surface = layer_surf;

        _ = c.zwlr_layer_surface_v1_add_listener(layer_surf, &layer_surface_listener, self);

        // Centered horizontally directly below the clock/time
        const anchor = c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP;
        c.zwlr_layer_surface_v1_set_anchor(layer_surf, anchor);
        c.zwlr_layer_surface_v1_set_size(layer_surf, w, h);
        c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surf, -1);
        const margin_top: i32 = @intCast(self.cfg.height + self.cfg.margin_top + self.cfg.margin_bottom + 4);
        c.zwlr_layer_surface_v1_set_margin(layer_surf, margin_top, 0, 0, 0);
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(
            layer_surf,
            c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE,
        );

        c.wl_surface_commit(surf);
        _ = c.wl_display_roundtrip(self.display.?);
    }

    pub fn createClipboardSurface(self: *WaylandApp, w: u32, h: u32) !void {
        try self.createBackdrop();
        self.width = w;
        self.height = h;

        const surf = c.wl_compositor_create_surface(self.compositor.?);
        if (surf == null) return error.CreateSurfaceFailed;
        self.surface = surf;
        self.setupSurfaceScaling(surf.?);

        const layer_surf = c.zwlr_layer_shell_v1_get_layer_surface(
            self.layer_shell.?,
            surf,
            self.output,
            c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
            "mizu-clipboard",
        );
        if (layer_surf == null) return error.GetLayerSurfaceFailed;
        self.layer_surface = layer_surf;

        _ = c.zwlr_layer_surface_v1_add_listener(layer_surf, &layer_surface_listener, self);

        c.zwlr_layer_surface_v1_set_anchor(layer_surf, 0);
        c.zwlr_layer_surface_v1_set_size(layer_surf, w, h);
        c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surf, -1);
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(
            layer_surf,
            c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE,
        );

        c.wl_surface_commit(surf);
        _ = c.wl_display_roundtrip(self.display.?);
    }

    pub fn createOsdSurface(
        self: *WaylandApp,
        w: u32,
        h: u32,
        anchor: u32,
        margin_top: i32,
        margin_right: i32,
        margin_bottom: i32,
    ) !void {
        self.width = w;
        self.height = h;

        const surf = c.wl_compositor_create_surface(self.compositor.?);
        if (surf == null) return error.CreateSurfaceFailed;
        self.surface = surf;
        self.setupSurfaceScaling(surf.?);

        const layer_surf = c.zwlr_layer_shell_v1_get_layer_surface(
            self.layer_shell.?,
            surf,
            self.output,
            c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
            "mizu-osd",
        );
        if (layer_surf == null) return error.GetLayerSurfaceFailed;
        self.layer_surface = layer_surf;

        _ = c.zwlr_layer_surface_v1_add_listener(layer_surf, &layer_surface_listener, self);

        c.zwlr_layer_surface_v1_set_anchor(layer_surf, anchor);
        c.zwlr_layer_surface_v1_set_size(layer_surf, w, h);
        c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surf, -1);
        c.zwlr_layer_surface_v1_set_margin(
            layer_surf,
            @intCast(margin_top),
            @intCast(margin_right),
            @intCast(margin_bottom),
            0,
        );
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(
            layer_surf,
            c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE,
        );

        c.wl_surface_commit(surf);
        _ = c.wl_display_roundtrip(self.display.?);
    }

    pub fn createKeyOverlaySurface(self: *WaylandApp, w: u32, h: u32) !void {
        self.width = w;
        self.height = h;

        const surf = c.wl_compositor_create_surface(self.compositor.?);
        if (surf == null) return error.CreateSurfaceFailed;
        self.surface = surf;
        self.setupSurfaceScaling(surf.?);

        const layer_surf = c.zwlr_layer_shell_v1_get_layer_surface(
            self.layer_shell.?,
            surf,
            self.output,
            c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
            "mizu-keyoverlay",
        );
        if (layer_surf == null) return error.GetLayerSurfaceFailed;
        self.layer_surface = layer_surf;

        _ = c.zwlr_layer_surface_v1_add_listener(layer_surf, &layer_surface_listener, self);

        var anchor: u32 = 0;
        var margin_top: u32 = 0;
        var margin_bottom: u32 = 0;
        var margin_left: u32 = 0;
        var margin_right: u32 = 0;
        switch (self.cfg.keymap_position) {
            .top_left => {
                anchor = c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT;
                margin_top = 48;
                margin_left = 24;
            },
            .top_center => {
                anchor = c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP;
                margin_top = 48;
            },
            .top_right => {
                anchor = c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;
                margin_top = 48;
                margin_right = 24;
            },
            .bottom_left => {
                anchor = c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT;
                margin_bottom = 48;
                margin_left = 24;
            },
            .bottom_center => {
                anchor = c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM;
                margin_bottom = 48;
            },
            .bottom_right => {
                anchor = c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;
                margin_bottom = 48;
                margin_right = 24;
            },
        }
        c.zwlr_layer_surface_v1_set_anchor(layer_surf, anchor);
        c.zwlr_layer_surface_v1_set_size(layer_surf, w, h);
        c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surf, -1);
        c.zwlr_layer_surface_v1_set_margin(layer_surf, @intCast(margin_top), @intCast(margin_right), @intCast(margin_bottom), @intCast(margin_left));
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(
            layer_surf,
            c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE,
        );

        c.wl_surface_commit(surf);
        _ = c.wl_display_roundtrip(self.display.?);
    }

    pub fn createPowerSurface(self: *WaylandApp, w: u32, h: u32) !void {
        try self.createBackdrop();
        self.width = w;
        self.height = h;

        const surf = c.wl_compositor_create_surface(self.compositor.?);
        if (surf == null) return error.CreateSurfaceFailed;
        self.surface = surf;
        self.setupSurfaceScaling(surf.?);

        const layer_surf = c.zwlr_layer_shell_v1_get_layer_surface(
            self.layer_shell.?,
            surf,
            self.output,
            c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
            "mizu-power",
        );
        if (layer_surf == null) return error.GetLayerSurfaceFailed;
        self.layer_surface = layer_surf;

        _ = c.zwlr_layer_surface_v1_add_listener(layer_surf, &layer_surface_listener, self);

        // Centered overlay
        c.zwlr_layer_surface_v1_set_anchor(layer_surf, 0);
        c.zwlr_layer_surface_v1_set_size(layer_surf, w, h);
        c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surf, -1);
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(
            layer_surf,
            c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE,
        );

        c.wl_surface_commit(surf);
        _ = c.wl_display_roundtrip(self.display.?);
    }

    fn physicalWidth(self: *WaylandApp) u32 {
        return self.width * self.output_scale_factor;
    }

    fn physicalHeight(self: *WaylandApp) u32 {
        return self.height * self.output_scale_factor;
    }

    fn updateViewport(self: *WaylandApp) void {
        if (self.viewport != null and self.surface != null) {
            c.wp_viewport_set_destination(self.viewport.?, @intCast(self.width), @intCast(self.height));
            c.wl_surface_commit(self.surface.?);
        }
    }

    pub fn redraw(self: *WaylandApp) !void {
        if (self.quicksettings) |qs| {
            const desired_h = qs.getDesiredHeight();
            if (desired_h != self.height and self.layer_surface != null and self.surface != null) {
                self.height = desired_h;
                c.zwlr_layer_surface_v1_set_size(self.layer_surface.?, self.width, desired_h);
                c.wl_surface_commit(self.surface.?);
                self.updateViewport();
            }
        }

        if (!self.configured or self.width == 0 or self.height == 0) return;

        const phys_w = self.physicalWidth();
        const phys_h = self.physicalHeight();

        var pool = &(self.buffer_pool.?);
        const buf = try pool.getNextBuffer(phys_w, phys_h);

        var target_renderer = try renderer.Renderer.init(
            buf.data.?,
            phys_w,
            phys_h,
            buf.stride,
        );
        defer target_renderer.deinit();

        if (self.power) |p| {
            try p.render(target_renderer, self.output_scale_factor);
        } else if (self.keyoverlay) |ko| {
            try ko.render(target_renderer, self.output_scale_factor);
        } else if (self.osd) |o| {
            try o.render(target_renderer, self.output_scale_factor);
        } else if (self.memory_monitor) |mm| {
            mm.render(target_renderer, self.output_scale_factor);
        } else if (self.quicksettings) |qs| {
            try qs.render(target_renderer, self.output_scale_factor);
        } else if (self.calendar) |cal| {
            try cal.render(target_renderer, self.output_scale_factor);
        } else if (self.clipboard) |clip| {
            try clip.render(target_renderer, self.output_scale_factor);
        } else if (self.launcher) |l| {
            if ((l.width != self.width or l.height != self.height) and self.layer_surface != null and self.surface != null) {
                self.width = l.width;
                self.height = l.height;
                c.zwlr_layer_surface_v1_set_size(self.layer_surface.?, l.width, l.height);
                c.wl_surface_commit(self.surface.?);
                self.updateViewport();
            }
            try l.render(target_renderer, self.output_scale_factor);
        } else if (self.bar) |b| {
            const ipc_ptr = self.ipc orelse return;
            try b.render(target_renderer, ipc_ptr, self.output_scale_factor);
        }

        if (self.surface) |surf| {
            c.wl_surface_set_buffer_scale(surf, @intCast(@max(1, self.output_scale_factor)));
        }

        c.wl_surface_attach(self.surface.?, buf.buffer.?, 0, 0);
        c.wl_surface_damage_buffer(self.surface.?, 0, 0, @intCast(phys_w), @intCast(phys_h));
        buf.busy = true;
        c.wl_surface_commit(self.surface.?);
    }

    // Registry Listener
    fn registry_global(
        data: ?*anyopaque,
        registry: ?*c.wl_registry,
        name: u32,
        interface: [*c]const u8,
        version: u32,
    ) callconv(.c) void {
        const self: *WaylandApp = @ptrCast(@alignCast(data.?));
        const iface = std.mem.span(interface);

        if (std.mem.eql(u8, iface, "wl_compositor")) {
            self.compositor = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_compositor_interface, @min(version, 4)));
        } else if (std.mem.eql(u8, iface, "wl_shm")) {
            self.shm = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_shm_interface, 1));
        } else if (std.mem.eql(u8, iface, "zwlr_layer_shell_v1")) {
            self.layer_shell = @ptrCast(c.wl_registry_bind(registry, name, &c.zwlr_layer_shell_v1_interface, @min(version, 4)));
        } else if (std.mem.eql(u8, iface, "wl_seat")) {
            self.seat = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_seat_interface, @min(version, 5)));
            _ = c.wl_seat_add_listener(self.seat.?, &seat_listener, self);
        } else if (std.mem.eql(u8, iface, "wl_output")) {
            if (self.output == null) {
                self.output = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_output_interface, @min(version, 3)));
                _ = c.wl_output_add_listener(self.output.?, &output_listener, self);
            }
        } else if (std.mem.eql(u8, iface, "wp_viewporter")) {
            if (self.viewporter == null) {
                self.viewporter = @ptrCast(c.wl_registry_bind(registry, name, &c.wp_viewporter_interface, 1));
            }
        }
    }

    fn registry_global_remove(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32) callconv(.c) void {
        _ = data;
        _ = registry;
        _ = name;
    }

    const registry_listener = c.wl_registry_listener{
        .global = registry_global,
        .global_remove = registry_global_remove,
    };

    // Seat Listener
    fn seat_capabilities(data: ?*anyopaque, seat: ?*c.wl_seat, capabilities: u32) callconv(.c) void {
        const self: *WaylandApp = @ptrCast(@alignCast(data.?));
        const has_pointer = (capabilities & c.WL_SEAT_CAPABILITY_POINTER) != 0;
        const has_keyboard = (capabilities & c.WL_SEAT_CAPABILITY_KEYBOARD) != 0;

        if (has_pointer and self.pointer == null) {
            self.pointer = c.wl_seat_get_pointer(seat);
            _ = c.wl_pointer_add_listener(self.pointer.?, &pointer_listener, self);
        } else if (!has_pointer and self.pointer != null) {
            c.wl_pointer_destroy(self.pointer.?);
            self.pointer = null;
        }

        if (has_keyboard and self.keyboard == null) {
            self.keyboard = c.wl_seat_get_keyboard(seat);
            _ = c.wl_keyboard_add_listener(self.keyboard.?, &keyboard_listener, self);
        } else if (!has_keyboard and self.keyboard != null) {
            c.wl_keyboard_destroy(self.keyboard.?);
            self.keyboard = null;
        }
    }

    fn seat_name(data: ?*anyopaque, seat: ?*c.wl_seat, name: [*c]const u8) callconv(.c) void {
        _ = data;
        _ = seat;
        _ = name;
    }

    const seat_listener = c.wl_seat_listener{
        .capabilities = seat_capabilities,
        .name = seat_name,
    };

    // Output Listener for scale factor
    fn output_scale_cb(data: ?*anyopaque, _: ?*c.wl_output, factor: i32) callconv(.c) void {
        const self: *WaylandApp = @ptrCast(@alignCast(data.?));
        if (factor > 0) {
            const u_factor = @as(u32, @intCast(factor));
            if (self.output_scale_factor != u_factor) {
                self.output_scale_factor = u_factor;
                if (self.surface) |s| {
                    c.wl_surface_set_buffer_scale(s, factor);
                }
                self.needs_redraw = true;
            }
        }
    }

    fn output_done(data: ?*anyopaque, output: ?*c.wl_output) callconv(.c) void {
        _ = data;
        _ = output;
    }

    fn output_geometry(data: ?*anyopaque, output: ?*c.wl_output, x: i32, y: i32, physical_width: i32, physical_height: i32, subpixel: i32, make: [*c]const u8, model: [*c]const u8, transform: i32) callconv(.c) void {
        _ = data;
        _ = output;
        _ = x;
        _ = y;
        _ = physical_width;
        _ = physical_height;
        _ = subpixel;
        _ = make;
        _ = model;
        _ = transform;
    }

    fn output_mode(data: ?*anyopaque, output: ?*c.wl_output, flags: u32, width: i32, height: i32, refresh: i32) callconv(.c) void {
        _ = data;
        _ = output;
        _ = flags;
        _ = width;
        _ = height;
        _ = refresh;
    }

    const output_listener = c.wl_output_listener{
        .geometry = output_geometry,
        .mode = output_mode,
        .done = output_done,
        .scale = output_scale_cb,
    };

    // Keyboard Listener
    fn kbd_keymap(data: ?*anyopaque, kbd: ?*c.wl_keyboard, format: u32, fd: i32, size: u32) callconv(.c) void {
        _ = kbd;
        const self: *WaylandApp = @ptrCast(@alignCast(data.?));
        if (format != c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) {
            _ = c.close(fd);
            return;
        }

        const map_shm = c.mmap(null, size, c.PROT_READ, c.MAP_SHARED, fd, 0);
        if (map_shm == c.MAP_FAILED) {
            _ = c.close(fd);
            return;
        }
        defer _ = c.munmap(map_shm, size);
        defer _ = c.close(fd);

        if (self.xkb_keymap) |km| c.xkb_keymap_unref(km);
        if (self.xkb_state) |st| c.xkb_state_unref(st);

        self.xkb_keymap = c.xkb_keymap_new_from_string(
            self.xkb_ctx,
            @ptrCast(map_shm),
            c.XKB_KEYMAP_FORMAT_TEXT_V1,
            c.XKB_KEYMAP_COMPILE_NO_FLAGS,
        );
        if (self.xkb_keymap) |km| {
            self.xkb_state = c.xkb_state_new(km);
        }
    }

    pub fn armRepeatTimer(self: *WaylandApp, delay_ms: i64, interval_ms: i64) void {
        if (self.repeat_timer_fd < 0) return;
        var its: c.struct_itimerspec = undefined;
        its.it_value.tv_sec = @intCast(@divTrunc(delay_ms, 1000));
        its.it_value.tv_nsec = @intCast(@mod(delay_ms, 1000) * 1_000_000);
        its.it_interval.tv_sec = @intCast(@divTrunc(interval_ms, 1000));
        its.it_interval.tv_nsec = @intCast(@mod(interval_ms, 1000) * 1_000_000);
        _ = c.timerfd_settime(self.repeat_timer_fd, 0, &its, null);
    }

    pub fn stopRepeat(self: *WaylandApp) void {
        if (self.repeat_timer_fd >= 0) {
            var its: c.struct_itimerspec = undefined;
            @memset(std.mem.asBytes(&its), 0);
            _ = c.timerfd_settime(self.repeat_timer_fd, 0, &its, null);
        }
        self.repeat_key = null;
        self.repeat_accelerated = false;
    }

    fn getMonotonicMs() i64 {
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
    }

    pub fn handleRepeatTimer(self: *WaylandApp) void {
        if (self.repeat_timer_fd < 0 or self.repeat_key == null) return;
        var expirations: u64 = 0;
        const n = c.read(self.repeat_timer_fd, &expirations, @sizeOf(u64));
        if (n <= 0 or expirations == 0) return;

        const now = getMonotonicMs();
        // After 1 second of holding the key, accelerate to fast repeat (~65 Hz = ~15ms)
        if (!self.repeat_accelerated and (now - self.repeat_start_ms >= 1000)) {
            self.repeat_accelerated = true;
            self.armRepeatTimer(15, 15);
        }

        const utf8_slice = self.repeat_utf8_buf[0..self.repeat_utf8_len];
        self.dispatchKey(self.repeat_sym, utf8_slice, self.repeat_is_ctrl, self.repeat_is_shift);
    }

    pub fn dispatchKey(self: *WaylandApp, sym: u32, utf8_slice: []const u8, is_ctrl: bool, is_shift: bool) void {
        if (self.calendar) |cal| {
            if (cal.handleKey(sym)) {
                self.needs_redraw = true;
            }
            if (!cal.running) self.running = false;
        } else if (self.clipboard) |clip| {
            if (clip.handleKey(sym, utf8_slice, is_ctrl, is_shift)) {
                self.needs_redraw = true;
            }
            if (!clip.running) self.running = false;
        } else if (self.memory_monitor) |mm| {
            if (mm.handleKey(sym, utf8_slice, is_ctrl, is_shift)) {
                self.needs_redraw = true;
            }
            if (!mm.running) self.running = false;
        } else if (self.quicksettings) |qs| {
            if (qs.wifi_input_idx != null) {
                if (qs.handleKeyFull(sym, utf8_slice, is_ctrl, is_shift)) {
                    self.needs_redraw = true;
                    return;
                }
            }

            if (sym == c.XKB_KEY_Escape) {
                if (qs.view_mode != .main) {
                    qs.view_mode = .main;
                    qs.scroll_offset = 0;
                    qs.wifi_input_idx = null;
                    self.needs_redraw = true;
                } else {
                    qs.running = false;
                    self.running = false;
                }
            } else if (qs.view_mode != .main) {
                if (sym == c.XKB_KEY_Up) {
                    if (qs.handlePointerAxis(0, 0, -1)) self.needs_redraw = true;
                } else if (sym == c.XKB_KEY_Down) {
                    if (qs.handlePointerAxis(0, 0, 1)) self.needs_redraw = true;
                }
            }
        } else if (self.power) |p| {
            if (p.handleKey(sym)) {
                self.needs_redraw = true;
            }
            if (!p.running) self.running = false;
        } else if (self.launcher) |l| {
            if (l.handleKey(sym, utf8_slice, is_ctrl, is_shift)) {
                self.needs_redraw = true;
            }
            if (!l.running) self.running = false;
        }
    }

    fn kbd_enter(data: ?*anyopaque, kbd: ?*c.wl_keyboard, serial: u32, surface: ?*c.wl_surface, keys: [*c]c.struct_wl_array) callconv(.c) void {
        _ = kbd;
        _ = serial;
        _ = keys;
        const self: *WaylandApp = @ptrCast(@alignCast(data.?));
        if (surface != null and self.surface != null and surface == self.surface) {
            self.has_kbd_focus = true;
            self.stopRepeat();
        }
    }

    fn kbd_leave(data: ?*anyopaque, kbd: ?*c.wl_keyboard, serial: u32, surface: ?*c.wl_surface) callconv(.c) void {
        _ = kbd;
        _ = serial;
        const self: *WaylandApp = @ptrCast(@alignCast(data.?));
        self.stopRepeat();
        if (self.has_kbd_focus and surface != null and self.surface != null and surface == self.surface) {
            self.has_kbd_focus = false;
            if (self.launcher != null or self.quicksettings != null or self.memory_monitor != null or self.calendar != null or self.clipboard != null or self.power != null) {
                self.running = false;
            }
        }
    }

    fn kbd_key(data: ?*anyopaque, kbd: ?*c.wl_keyboard, serial: u32, time: u32, key: u32, state: u32) callconv(.c) void {
        _ = kbd;
        _ = serial;
        _ = time;
        const self: *WaylandApp = @ptrCast(@alignCast(data.?));

        if (self.xkb_state != null) {
            const keycode = key + 8;
            if (state == c.WL_KEYBOARD_KEY_STATE_RELEASED) {
                if (self.repeat_key != null and self.repeat_key.? == key) {
                    self.stopRepeat();
                }
            } else if (state == c.WL_KEYBOARD_KEY_STATE_PRESSED) {
                const sym = c.xkb_state_key_get_one_sym(self.xkb_state, keycode);
                const is_shift = (c.xkb_state_mod_name_is_active(self.xkb_state, c.XKB_MOD_NAME_SHIFT, c.XKB_STATE_MODS_EFFECTIVE) > 0);
                const is_ctrl = (c.xkb_state_mod_name_is_active(self.xkb_state, c.XKB_MOD_NAME_CTRL, c.XKB_STATE_MODS_EFFECTIVE) > 0);

                var utf8_buf: [32]u8 = undefined;
                const len = c.xkb_state_key_get_utf8(self.xkb_state, keycode, &utf8_buf, utf8_buf.len);
                const utf8_slice = if (len > 0) utf8_buf[0..@intCast(len)] else &[_]u8{};

                // Arm repeat timer if key repeats
                const repeats = if (self.xkb_keymap) |km| c.xkb_keymap_key_repeats(km, keycode) != 0 else true;
                if (repeats and self.repeat_rate > 0) {
                    self.repeat_key = key;
                    self.repeat_keycode = keycode;
                    self.repeat_sym = sym;
                    const copy_len = @min(if (len > 0) @as(usize, @intCast(len)) else 0, 32);
                    if (copy_len > 0) {
                        @memcpy(self.repeat_utf8_buf[0..copy_len], utf8_buf[0..copy_len]);
                    }
                    self.repeat_utf8_len = copy_len;
                    self.repeat_is_ctrl = is_ctrl;
                    self.repeat_is_shift = is_shift;
                    self.repeat_start_ms = getMonotonicMs();
                    self.repeat_accelerated = false;

                    const interval_ms: i64 = @max(10, @divTrunc(@as(i64, 1000), self.repeat_rate));
                    self.armRepeatTimer(self.repeat_delay, interval_ms);
                }

                self.dispatchKey(sym, utf8_slice, is_ctrl, is_shift);
            }
        }
    }

    fn kbd_modifiers(data: ?*anyopaque, kbd: ?*c.wl_keyboard, serial: u32, mods_depressed: u32, mods_latched: u32, mods_locked: u32, group: u32) callconv(.c) void {
        _ = kbd;
        _ = serial;
        const self: *WaylandApp = @ptrCast(@alignCast(data.?));
        if (self.xkb_state) |st| {
            _ = c.xkb_state_update_mask(st, mods_depressed, mods_latched, mods_locked, 0, 0, group);
        }
    }

    fn kbd_repeat_info(data: ?*anyopaque, kbd: ?*c.wl_keyboard, rate: i32, delay: i32) callconv(.c) void {
        _ = kbd;
        const self: *WaylandApp = @ptrCast(@alignCast(data.?));
        if (rate > 0) {
            self.repeat_rate = rate;
            self.repeat_delay = delay;
        } else {
            self.repeat_rate = 0;
            self.stopRepeat();
        }
    }

    const keyboard_listener = c.wl_keyboard_listener{
        .keymap = kbd_keymap,
        .enter = kbd_enter,
        .leave = kbd_leave,
        .key = kbd_key,
        .modifiers = kbd_modifiers,
        .repeat_info = kbd_repeat_info,
    };

    fn handlePointerMotionInternal(self: *WaylandApp, px: i32, py: i32) void {
        self.pointer_x = px;
        self.pointer_y = py;

        var shape: CursorShape = .default;
        if (self.calendar) |cal| {
            if (cal.handlePointerMotion(px, py)) self.needs_redraw = true;
            shape = .pointer;
        } else if (self.clipboard) |clip| {
            if (clip.handlePointerMotion(px, py)) self.needs_redraw = true;
            if (px >= 18 and px < @as(i32, @intCast(self.width)) - 18 and py >= 50 and py < 50 + 34) {
                shape = .text;
            } else {
                shape = .pointer;
            }
        } else if (self.memory_monitor) |mm| {
            if (mm.handlePointerMotion(px, py)) self.needs_redraw = true;
            if (mm.isTextInput(px, py)) {
                shape = .text;
            } else if (mm.isPointer(px, py)) {
                shape = .pointer;
            }
        } else if (self.quicksettings) |qs| {
            if (qs.handlePointerMotion(px, py)) self.needs_redraw = true;
            if (qs.wifi_input_idx != null and py >= 40 and py <= 120 and px >= 36) {
                shape = .text;
            } else if (qs.isPointer(px, py)) {
                shape = .pointer;
            }
        } else if (self.launcher) |l| {
            if (l.handlePointerMotion(px, py)) self.needs_redraw = true;
            const in_rect = l.getInputRect();
            if (px >= in_rect.x and px < in_rect.x + @as(i32, @intCast(in_rect.w)) and
                py >= in_rect.y and py < in_rect.y + @as(i32, @intCast(in_rect.h)))
            {
                shape = .text;
            } else if (l.hover_index != null) {
                shape = .pointer;
            }
        } else if (self.power) |p| {
            if (p.handlePointerMotion(px, py)) self.needs_redraw = true;
            shape = .pointer;
        } else if (self.bar) |bar| {
            if (bar.handlePointerMotion(px, py)) {
                self.needs_redraw = true;
            }
            if (bar.isPointer(px, py)) shape = .pointer;
        }
        self.updateCursorShape(shape);
    }

    // Pointer Listener
    fn pointer_enter(data: ?*anyopaque, pointer: ?*c.wl_pointer, serial: u32, surface: ?*c.wl_surface, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
        _ = pointer;
        const self: *WaylandApp = @ptrCast(@alignCast(data.?));
        self.pointer_serial = serial;
        self.current_cursor_shape = null;
        if (surface != null) {
            self.current_pointer_surface = surface;
        }
        if (surface != null and self.backdrop_surface != null and surface.? == self.backdrop_surface.?) {
            self.pointer_x = -1;
            self.pointer_y = -1;
            self.updateCursorShape(.default);
            return;
        }
        const px = c.wl_fixed_to_int(sx);
        const py = c.wl_fixed_to_int(sy);
        self.handlePointerMotionInternal(px, py);
    }

    fn pointer_leave(data: ?*anyopaque, pointer: ?*c.wl_pointer, serial: u32, surface: ?*c.wl_surface) callconv(.c) void {
        _ = pointer;
        _ = serial;
        _ = surface;
        const self: *WaylandApp = @ptrCast(@alignCast(data.?));
        self.pointer_x = -1;
        self.pointer_y = -1;
        self.current_pointer_surface = null;
        self.current_cursor_shape = null;
        if (self.calendar) |cal| {
            if (cal.handlePointerLeave()) self.needs_redraw = true;
        } else if (self.clipboard) |clip| {
            if (clip.handlePointerLeave()) self.needs_redraw = true;
        } else if (self.memory_monitor) |mm| {
            if (mm.handlePointerLeave()) self.needs_redraw = true;
        } else if (self.quicksettings) |qs| {
            if (qs.handlePointerLeave()) self.needs_redraw = true;
        } else if (self.launcher) |l| {
            l.hover_index = null;
            self.needs_redraw = true;
        } else if (self.bar) |bar| {
            if (bar.handlePointerLeave()) {
                self.needs_redraw = true;
            }
        }
    }

    fn pointer_motion(data: ?*anyopaque, pointer: ?*c.wl_pointer, time: u32, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
        _ = pointer;
        _ = time;
        const self: *WaylandApp = @ptrCast(@alignCast(data.?));
        const px = c.wl_fixed_to_int(sx);
        const py = c.wl_fixed_to_int(sy);
        self.handlePointerMotionInternal(px, py);
    }

    fn pointer_button(data: ?*anyopaque, pointer: ?*c.wl_pointer, serial: u32, time: u32, button: u32, state: u32) callconv(.c) void {
        _ = pointer;
        _ = serial;
        _ = time;
        const self: *WaylandApp = @ptrCast(@alignCast(data.?));
        // Dismiss panels if click was outside (on backdrop)
        if (self.current_pointer_surface != null and self.backdrop_surface != null and self.current_pointer_surface.? == self.backdrop_surface.?) {
            if (state == c.WL_POINTER_BUTTON_STATE_PRESSED) {
                self.running = false;
                if (self.calendar) |cal| cal.running = false;
                if (self.clipboard) |clip| clip.running = false;
                if (self.quicksettings) |qs| qs.running = false;
                if (self.memory_monitor) |mm| mm.running = false;
                if (self.launcher) |l| l.running = false;
                if (self.osd) |o| o.running = false;
                if (self.power) |p| p.running = false;
                return;
            }
        }

        // BTN_LEFT is 0x110 (272), BTN_RIGHT is 0x111 (273)
        if (self.power) |p| {
            const is_pressed = (state == c.WL_POINTER_BUTTON_STATE_PRESSED);
            if (is_pressed) {
                if (p.handleClick(self.pointer_x, self.pointer_y)) {
                    self.needs_redraw = true;
                }
                if (!p.running) self.running = false;
            }
        } else if (self.osd) |o| {
            if (state == c.WL_POINTER_BUTTON_STATE_PRESSED) {
                o.running = false;
                self.running = false;
            }
        } else if (self.calendar) |cal| {
            const is_pressed = (state == c.WL_POINTER_BUTTON_STATE_PRESSED);
            if (cal.handlePointerButton(self.pointer_x, self.pointer_y, button, is_pressed)) {
                self.needs_redraw = true;
            }
            if (!cal.running) {
                self.running = false;
            }
        } else if (self.clipboard) |clip| {
            const is_pressed = (state == c.WL_POINTER_BUTTON_STATE_PRESSED);
            if (clip.handlePointerButton(self.pointer_x, self.pointer_y, button, is_pressed)) {
                self.needs_redraw = true;
            }
            if (!clip.running) {
                self.running = false;
            }
        } else if (self.memory_monitor) |mm| {
            const is_pressed = (state == c.WL_POINTER_BUTTON_STATE_PRESSED);
            if (mm.handlePointerButton(self.pointer_x, self.pointer_y, button, is_pressed)) {
                self.needs_redraw = true;
            }
            if (!mm.running) {
                self.running = false;
            }
        } else if (self.quicksettings) |qs| {
            const is_pressed = (state == c.WL_POINTER_BUTTON_STATE_PRESSED);
            if (qs.handlePointerButton(self.pointer_x, self.pointer_y, button, is_pressed)) {
                self.needs_redraw = true;
            }
            if (!qs.running) {
                self.running = false;
            }
        } else if (self.launcher) |l| {
            const is_pressed = (state == c.WL_POINTER_BUTTON_STATE_PRESSED);
            if (l.handlePointerButton(self.pointer_x, self.pointer_y, button, is_pressed)) {
                self.needs_redraw = true;
            }
            if (!l.running) {
                self.running = false;
            }
        } else if (state == c.WL_POINTER_BUTTON_STATE_PRESSED) {
            if (self.bar) |bar| {
                if (self.ipc) |ipc| {
                    bar.handleClick(self.pointer_x, self.pointer_y, button, ipc);
                    self.needs_redraw = true;
                }
            }
        }
    }

    fn pointer_axis(data: ?*anyopaque, pointer: ?*c.wl_pointer, time: u32, axis: u32, value: c.wl_fixed_t) callconv(.c) void {
        _ = pointer;
        _ = time;
        const self: *WaylandApp = @ptrCast(@alignCast(data.?));
        if (axis == 0 or axis == 1) { // WL_POINTER_AXIS_VERTICAL_SCROLL or HORIZONTAL_SCROLL
            var scroll_val: i32 = 0;
            if (value > 0) {
                scroll_val = @max(1, c.wl_fixed_to_int(value));
            } else if (value < 0) {
                scroll_val = @min(-1, c.wl_fixed_to_int(value));
            }
            if (scroll_val == 0 and value != 0) {
                scroll_val = if (value > 0) 1 else -1;
            }

            if (self.calendar) |cal| {
                if (cal.handlePointerAxis(self.pointer_x, self.pointer_y, scroll_val)) {
                    self.needs_redraw = true;
                }
            } else if (self.clipboard) |clip| {
                if (clip.handlePointerAxis(self.pointer_x, self.pointer_y, scroll_val)) {
                    self.needs_redraw = true;
                }
            } else if (self.launcher) |l| {
                if (l.handlePointerAxis(self.pointer_x, self.pointer_y, scroll_val)) {
                    self.needs_redraw = true;
                }
            } else if (self.memory_monitor) |mm| {
                if (mm.handlePointerAxis(self.pointer_x, self.pointer_y, scroll_val)) {
                    self.needs_redraw = true;
                }
            } else if (self.quicksettings) |qs| {
                if (qs.handlePointerAxis(self.pointer_x, self.pointer_y, scroll_val)) {
                    self.needs_redraw = true;
                }
            } else if (self.bar) |bar| {
                if (bar.handlePointerAxis(self.pointer_x, self.pointer_y, scroll_val)) {
                    self.needs_redraw = true;
                }
            }
        }
    }

    fn pointer_frame(
        data: ?*anyopaque,
        pointer: ?*c.wl_pointer,
    ) callconv(.c) void {
        _ = data;
        _ = pointer;
    }

    fn pointer_axis_source(data: ?*anyopaque, pointer: ?*c.wl_pointer, axis_source: u32) callconv(.c) void {
        _ = data;
        _ = pointer;
        _ = axis_source;
    }

    fn pointer_axis_stop(data: ?*anyopaque, pointer: ?*c.wl_pointer, time: u32, axis: u32) callconv(.c) void {
        _ = data;
        _ = pointer;
        _ = time;
        _ = axis;
    }

    fn pointer_axis_discrete(data: ?*anyopaque, pointer: ?*c.wl_pointer, axis: u32, discrete: i32) callconv(.c) void {
        _ = data;
        _ = pointer;
        _ = axis;
        _ = discrete;
    }

    fn pointer_axis_value120(data: ?*anyopaque, pointer: ?*c.wl_pointer, axis: u32, value120: i32) callconv(.c) void {
        _ = data;
        _ = pointer;
        _ = axis;
        _ = value120;
    }

    fn pointer_axis_relative_direction(data: ?*anyopaque, pointer: ?*c.wl_pointer, axis: u32, direction: u32) callconv(.c) void {
        _ = data;
        _ = pointer;
        _ = axis;
        _ = direction;
    }

    fn pointer_warp(data: ?*anyopaque, pointer: ?*c.wl_pointer, surface_x: c.wl_fixed_t, surface_y: c.wl_fixed_t) callconv(.c) void {
        _ = data;
        _ = pointer;
        _ = surface_x;
        _ = surface_y;
    }

    const pointer_listener = c.wl_pointer_listener{
        .enter = pointer_enter,
        .leave = pointer_leave,
        .motion = pointer_motion,
        .button = pointer_button,
        .axis = pointer_axis,
        .frame = pointer_frame,
        .axis_source = pointer_axis_source,
        .axis_stop = pointer_axis_stop,
        .axis_discrete = pointer_axis_discrete,
        .axis_value120 = pointer_axis_value120,
        .axis_relative_direction = pointer_axis_relative_direction,
        .warp = pointer_warp,
    };

    // Layer Surface Listener
    fn layer_surface_configure(
        data: ?*anyopaque,
        surface: ?*c.zwlr_layer_surface_v1,
        serial: u32,
        w: u32,
        h: u32,
    ) callconv(.c) void {
        const self: *WaylandApp = @ptrCast(@alignCast(data.?));
        c.zwlr_layer_surface_v1_ack_configure(surface, serial);

        if (w > 0) self.width = w;
        if (h > 0) self.height = h;
        self.configured = true;
        self.needs_redraw = true;
    }

    fn layer_surface_closed(data: ?*anyopaque, surface: ?*c.zwlr_layer_surface_v1) callconv(.c) void {
        _ = surface;
        const self: *WaylandApp = @ptrCast(@alignCast(data.?));
        self.running = false;
    }

    const layer_surface_listener = c.zwlr_layer_surface_v1_listener{
        .configure = layer_surface_configure,
        .closed = layer_surface_closed,
    };

    // Backdrop Layer Surface Listener
    fn backdrop_layer_surface_configure(
        data: ?*anyopaque,
        surface: ?*c.zwlr_layer_surface_v1,
        serial: u32,
        w: u32,
        h: u32,
    ) callconv(.c) void {
        const self: *WaylandApp = @ptrCast(@alignCast(data.?));
        c.zwlr_layer_surface_v1_ack_configure(surface, serial);
        if (w > 0 and h > 0 and self.shm != null and self.backdrop_surface != null) {
            if (self.launcher) |l| {
                l.updateDimensions(w, h);
                if (self.layer_surface != null and self.surface != null and (self.width != l.width or self.height != l.height)) {
                    self.width = l.width;
                    self.height = l.height;
                    c.zwlr_layer_surface_v1_set_size(self.layer_surface.?, l.width, l.height);
                    c.wl_surface_commit(self.surface.?);
                    self.updateViewport();
                }
            }
            const phys_w = w * self.output_scale_factor;
            const phys_h = h * self.output_scale_factor;
            if (self.backdrop_buf == null or self.backdrop_buf.?.width != phys_w or self.backdrop_buf.?.height != phys_h) {
                if (self.backdrop_buf) |*b| b.deinit();
                self.backdrop_buf = buffer.BufferPool.createSingleBuffer(self.shm.?, phys_w, phys_h) catch null;
                if (self.backdrop_buf) |*b| {
                    c.wl_surface_attach(self.backdrop_surface.?, b.buffer.?, 0, 0);
                    c.wl_surface_damage_buffer(self.backdrop_surface.?, 0, 0, @intCast(phys_w), @intCast(phys_h));
                    c.wl_surface_commit(self.backdrop_surface.?);
                }
            }
        }
    }

    fn backdrop_layer_surface_closed(data: ?*anyopaque, surface: ?*c.zwlr_layer_surface_v1) callconv(.c) void {
        _ = surface;
        const self: *WaylandApp = @ptrCast(@alignCast(data.?));
        self.running = false;
    }

    const backdrop_layer_surface_listener = c.zwlr_layer_surface_v1_listener{
        .configure = backdrop_layer_surface_configure,
        .closed = backdrop_layer_surface_closed,
    };
};
