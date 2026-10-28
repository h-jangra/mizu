const std = @import("std");
const c = @import("../c.zig").c;
const buffer = @import("buffer.zig");
const renderer = @import("renderer.zig");
const theme = @import("theme.zig");

pub const CursorShape = enum {
    default,
    pointer,
    text,
    crosshair,
    grab,
    move,
    nwse_resize,
    nesw_resize,
    ns_resize,
    ew_resize,
};

pub const MouseEvent = struct {
    x: i32,
    y: i32,
    button: u32 = 0,
    pressed: bool = false,
    scroll: i32 = 0,
};

pub const KeyEvent = struct {
    sym: u32,
    utf8: []const u8,
    is_ctrl: bool,
    is_shift: bool,
    is_alt: bool,
    pressed: bool,
};

pub const WindowConfig = struct {
    title: []const u8 = "Mizu Window",
    app_id: []const u8 = "mizu-app",
    width: u32 = 960,
    height: u32 = 640,
    min_width: u32 = 400,
    min_height: u32 = 300,
    fullscreen_layer: bool = false, // When true, uses zwlr_layer_shell overlay (e.g. for screenshot overlay)
};

pub const WindowApp = struct {
    allocator: std.mem.Allocator,
    display: ?*c.wl_display = null,
    registry: ?*c.wl_registry = null,
    compositor: ?*c.wl_compositor = null,
    shm: ?*c.wl_shm = null,
    seat: ?*c.wl_seat = null,
    pointer: ?*c.wl_pointer = null,
    keyboard: ?*c.wl_keyboard = null,
    output: ?*c.wl_output = null,
    viewporter: ?*c.wp_viewporter = null,
    viewport: ?*c.wp_viewport = null,
    output_scale: u32 = 1,

    // Window protocols: XDG shell primary, Layer shell fallback/overlay
    wm_base: ?*c.xdg_wm_base = null,
    layer_shell: ?*c.zwlr_layer_shell_v1 = null,

    surface: ?*c.wl_surface = null,
    xdg_surface: ?*c.xdg_surface = null,
    xdg_toplevel: ?*c.xdg_toplevel = null,
    layer_surface: ?*c.zwlr_layer_surface_v1 = null,

    buffer_pool: ?buffer.BufferPool = null,

    // Dimensions
    width: u32 = 960,
    height: u32 = 640,
    configured: bool = false,
    running: bool = true,
    needs_redraw: bool = true,

    // Mouse state
    pointer_x: i32 = -1,
    pointer_y: i32 = -1,
    pointer_down: bool = false,
    pointer_serial: u32 = 0,

    // Keyboard state
    xkb_ctx: ?*c.struct_xkb_context = null,
    xkb_keymap: ?*c.struct_xkb_keymap = null,
    xkb_state: ?*c.struct_xkb_state = null,
    is_ctrl: bool = false,
    is_shift: bool = false,
    is_alt: bool = false,
    repeat_timer_fd: c_int = -1,
    repeat_sym: u32 = 0,
    repeat_utf8_buf: [32]u8 = [_]u8{0} ** 32,
    repeat_utf8_len: usize = 0,

    // Cursor
    cursor_theme: ?*c.wl_cursor_theme = null,
    cursor_default: ?*c.wl_cursor = null,
    cursor_pointer: ?*c.wl_cursor = null,
    cursor_text: ?*c.wl_cursor = null,
    cursor_crosshair: ?*c.wl_cursor = null,
    cursor_grab: ?*c.wl_cursor = null,
    cursor_move: ?*c.wl_cursor = null,
    cursor_nwse: ?*c.wl_cursor = null,
    cursor_nesw: ?*c.wl_cursor = null,
    cursor_ns: ?*c.wl_cursor = null,
    cursor_ew: ?*c.wl_cursor = null,
    cursor_surface: ?*c.wl_surface = null,
    current_cursor_shape: ?CursorShape = null,

    cfg: WindowConfig,

    pub fn init(allocator: std.mem.Allocator, cfg: WindowConfig) !*WindowApp {
        const app = try allocator.create(WindowApp);
        app.* = .{
            .allocator = allocator,
            .width = cfg.width,
            .height = cfg.height,
            .cfg = cfg,
        };

        try app.connect();
        return app;
    }

    pub fn deinit(self: *WindowApp) void {
        if (self.repeat_timer_fd >= 0) {
            _ = c.close(self.repeat_timer_fd);
            self.repeat_timer_fd = -1;
        }
        if (self.cursor_surface) |cs| c.wl_surface_destroy(cs);
        if (self.cursor_theme) |ct| c.wl_cursor_theme_destroy(ct);

        if (self.viewport) |vp| c.wp_viewport_destroy(vp);
        if (self.viewporter) |vp| c.wp_viewporter_destroy(vp);

        if (self.buffer_pool) |*pool| pool.deinit();

        if (self.xdg_toplevel) |t| c.xdg_toplevel_destroy(t);
        if (self.xdg_surface) |xs| c.xdg_surface_destroy(xs);
        if (self.layer_surface) |ls| c.zwlr_layer_surface_v1_destroy(ls);
        if (self.surface) |s| c.wl_surface_destroy(s);

        if (self.keyboard) |k| c.wl_keyboard_destroy(k);
        if (self.pointer) |p| c.wl_pointer_destroy(p);
        if (self.seat) |st| c.wl_seat_destroy(st);

        if (self.xkb_state) |st| c.xkb_state_unref(st);
        if (self.xkb_keymap) |km| c.xkb_keymap_unref(km);
        if (self.xkb_ctx) |ctx| c.xkb_context_unref(ctx);

        if (self.wm_base) |wb| c.xdg_wm_base_destroy(wb);
        if (self.layer_shell) |ls| c.zwlr_layer_shell_v1_destroy(ls);
        if (self.shm) |shm| c.wl_shm_destroy(shm);
        if (self.compositor) |comp| c.wl_compositor_destroy(comp);
        if (self.output) |o| c.wl_output_destroy(o);
        if (self.registry) |reg| c.wl_registry_destroy(reg);
        if (self.display) |disp| c.wl_display_disconnect(disp);

        const alloc = self.allocator;
        alloc.destroy(self);
    }

    fn connect(self: *WindowApp) !void {
        const display = c.wl_display_connect(null);
        if (display == null) return error.WaylandDisplayConnectFailed;
        self.display = display;

        self.xkb_ctx = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
        self.repeat_timer_fd = c.timerfd_create(c.CLOCK_MONOTONIC, c.TFD_CLOEXEC | c.TFD_NONBLOCK);

        const registry = c.wl_display_get_registry(display);
        if (registry == null) return error.GetRegistryFailed;
        self.registry = registry;

        _ = c.wl_registry_add_listener(registry, &registry_listener, self);
        _ = c.wl_display_roundtrip(display);

        if (self.compositor == null) return error.NoCompositor;
        if (self.shm == null) return error.NoShm;

        self.buffer_pool = buffer.BufferPool.init(self.shm.?);
        self.initCursor();
        try self.createWindowSurface();
    }

    fn initCursor(self: *WindowApp) void {
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
            self.cursor_crosshair = c.wl_cursor_theme_get_cursor(t, "crosshair") orelse
                c.wl_cursor_theme_get_cursor(t, "cross") orelse
                self.cursor_default;
            self.cursor_grab = c.wl_cursor_theme_get_cursor(t, "grab") orelse
                c.wl_cursor_theme_get_cursor(t, "openhand") orelse
                self.cursor_pointer;
            self.cursor_move = c.wl_cursor_theme_get_cursor(t, "move") orelse
                c.wl_cursor_theme_get_cursor(t, "all-scroll") orelse
                self.cursor_pointer;
            self.cursor_nwse = c.wl_cursor_theme_get_cursor(t, "nwse-resize") orelse
                c.wl_cursor_theme_get_cursor(t, "top_left_corner") orelse
                self.cursor_pointer;
            self.cursor_nesw = c.wl_cursor_theme_get_cursor(t, "nesw-resize") orelse
                c.wl_cursor_theme_get_cursor(t, "top_right_corner") orelse
                self.cursor_pointer;
            self.cursor_ns = c.wl_cursor_theme_get_cursor(t, "ns-resize") orelse
                c.wl_cursor_theme_get_cursor(t, "v_double_arrow") orelse
                self.cursor_pointer;
            self.cursor_ew = c.wl_cursor_theme_get_cursor(t, "ew-resize") orelse
                c.wl_cursor_theme_get_cursor(t, "h_double_arrow") orelse
                self.cursor_pointer;
            self.cursor_surface = c.wl_compositor_create_surface(self.compositor.?);
        }
    }

    pub fn setCursorShape(self: *WindowApp, shape: CursorShape) void {
        if (self.pointer == null or self.cursor_surface == null or self.cursor_theme == null) return;
        if (self.current_cursor_shape != null and self.current_cursor_shape.? == shape) return;
        self.current_cursor_shape = shape;

        const cur = switch (shape) {
            .pointer => (self.cursor_pointer orelse self.cursor_default),
            .text => (self.cursor_text orelse self.cursor_default),
            .crosshair => (self.cursor_crosshair orelse self.cursor_default),
            .grab => (self.cursor_grab orelse self.cursor_default),
            .move => (self.cursor_move orelse self.cursor_default),
            .nwse_resize => (self.cursor_nwse orelse self.cursor_default),
            .nesw_resize => (self.cursor_nesw orelse self.cursor_default),
            .ns_resize => (self.cursor_ns orelse self.cursor_default),
            .ew_resize => (self.cursor_ew orelse self.cursor_default),
            .default => self.cursor_default,
        };

        if (cur) |c_cursor| {
            if (c_cursor.*.image_count > 0) {
                const img = c_cursor.*.images[0];
                const buf_ptr = c.wl_cursor_image_get_buffer(img);
                if (buf_ptr) |b| {
                    c.wl_pointer_set_cursor(
                        self.pointer.?,
                        self.pointer_serial,
                        self.cursor_surface.?,
                        @intCast(img.*.hotspot_x),
                        @intCast(img.*.hotspot_y),
                    );
                    c.wl_surface_attach(self.cursor_surface.?, b, 0, 0);
                    c.wl_surface_damage_buffer(self.cursor_surface.?, 0, 0, @intCast(img.*.width), @intCast(img.*.height));
                    c.wl_surface_commit(self.cursor_surface.?);
                }
            }
        }
    }

    fn createWindowSurface(self: *WindowApp) !void {
        const surface = c.wl_compositor_create_surface(self.compositor.?);
        if (surface == null) return error.CreateSurfaceFailed;
        self.surface = surface;

        // Viewporter setup
        if (self.viewporter) |vp| {
            self.viewport = c.wp_viewporter_get_viewport(vp, surface);
        }

        // Check if fullscreen layer requested or standard window
        if (!self.cfg.fullscreen_layer and self.wm_base != null) {
            // Standard XDG toplevel window
            const xdg_surf = c.xdg_wm_base_get_xdg_surface(self.wm_base.?, surface);
            if (xdg_surf == null) return error.CreateXdgSurfaceFailed;
            self.xdg_surface = xdg_surf;
            _ = c.xdg_surface_add_listener(xdg_surf, &xdg_surface_listener, self);

            const xdg_top = c.xdg_surface_get_toplevel(xdg_surf);
            if (xdg_top == null) return error.CreateXdgToplevelFailed;
            self.xdg_toplevel = xdg_top;
            _ = c.xdg_toplevel_add_listener(xdg_top, &xdg_toplevel_listener, self);

            const title_z = try self.allocator.dupeZ(u8, self.cfg.title);
            defer self.allocator.free(title_z);
            c.xdg_toplevel_set_title(xdg_top, title_z.ptr);

            const app_id_z = try self.allocator.dupeZ(u8, self.cfg.app_id);
            defer self.allocator.free(app_id_z);
            c.xdg_toplevel_set_app_id(xdg_top, app_id_z.ptr);

            c.xdg_toplevel_set_min_size(xdg_top, @intCast(self.cfg.min_width), @intCast(self.cfg.min_height));
            c.wl_surface_commit(surface);
        } else if (self.layer_shell != null) {
            // Layer shell window / overlay
            const layer: u32 = if (self.cfg.fullscreen_layer)
                @intCast(c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY)
            else
                @intCast(c.ZWLR_LAYER_SHELL_V1_LAYER_TOP);

            const name_z = try self.allocator.dupeZ(u8, self.cfg.app_id);
            defer self.allocator.free(name_z);

            const layer_surf = c.zwlr_layer_shell_v1_get_layer_surface(
                self.layer_shell.?,
                surface,
                self.output,
                layer,
                name_z.ptr,
            );
            if (layer_surf == null) return error.CreateLayerSurfaceFailed;
            self.layer_surface = layer_surf;
            _ = c.zwlr_layer_surface_v1_add_listener(layer_surf, &layer_surface_listener, self);

            if (self.cfg.fullscreen_layer) {
                const anchor = c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
                    c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
                    c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
                    c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;
                c.zwlr_layer_surface_v1_set_anchor(layer_surf, anchor);
                c.zwlr_layer_surface_v1_set_size(layer_surf, 0, 0);
                c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surf, -1);
                c.zwlr_layer_surface_v1_set_keyboard_interactivity(layer_surf, c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE);
            } else {
                c.zwlr_layer_surface_v1_set_anchor(layer_surf, 0);
                c.zwlr_layer_surface_v1_set_size(layer_surf, self.width, self.height);
                c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surf, -1);
                c.zwlr_layer_surface_v1_set_keyboard_interactivity(layer_surf, c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_ON_DEMAND);
            }
            c.wl_surface_commit(surface);
        } else {
            return error.NoWindowShellProtocol;
        }

        _ = c.wl_display_roundtrip(self.display.?);
    }

    pub fn physicalWidth(self: *const WindowApp) u32 {
        return self.width * self.output_scale;
    }

    pub fn physicalHeight(self: *const WindowApp) u32 {
        return self.height * self.output_scale;
    }

    pub fn getRenderer(self: *WindowApp) !renderer.Renderer {
        const pw = self.physicalWidth();
        const ph = self.physicalHeight();
        const pool = &(self.buffer_pool.?);
        const buf = try pool.getNextBuffer(pw, ph);

        const target_renderer = try renderer.Renderer.init(
            buf.data.?,
            pw,
            ph,
            buf.stride,
        );
        return target_renderer;
    }

    pub fn commitFrame(self: *WindowApp) void {
        if (!self.configured or self.surface == null) return;
        const pw = self.physicalWidth();
        const ph = self.physicalHeight();
        const pool = &(self.buffer_pool.?);

        // Get the active buffer
        const buf = pool.getNextBuffer(pw, ph) catch return;

        if (self.viewport) |vp| {
            c.wp_viewport_set_destination(vp, @intCast(self.width), @intCast(self.height));
        } else {
            c.wl_surface_set_buffer_scale(self.surface.?, @intCast(self.output_scale));
        }

        c.wl_surface_attach(self.surface.?, buf.buffer.?, 0, 0);
        c.wl_surface_damage_buffer(self.surface.?, 0, 0, @intCast(pw), @intCast(ph));
        buf.busy = true;

        const cb = c.wl_surface_frame(self.surface.?);
        _ = c.wl_callback_add_listener(cb, &frame_listener, self);
        c.wl_surface_commit(self.surface.?);
        self.needs_redraw = false;
    }

    // ==========================================
    // Wayland Protocol Listeners
    // ==========================================

    fn registry_global(
        data: ?*anyopaque,
        registry: ?*c.wl_registry,
        name: u32,
        interface: [*c]const u8,
        version: u32,
    ) callconv(.c) void {
        const self: *WindowApp = @ptrCast(@alignCast(data.?));
        const iface = std.mem.span(interface);

        if (std.mem.eql(u8, iface, "wl_compositor")) {
            self.compositor = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_compositor_interface, @min(version, 4)));
        } else if (std.mem.eql(u8, iface, "wl_shm")) {
            self.shm = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_shm_interface, 1));
        } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
            self.wm_base = @ptrCast(c.wl_registry_bind(registry, name, &c.xdg_wm_base_interface, @min(version, 3)));
            _ = c.xdg_wm_base_add_listener(self.wm_base.?, &xdg_wm_base_listener, self);
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

    fn xdg_ping(data: ?*anyopaque, wm_base: ?*c.xdg_wm_base, serial: u32) callconv(.c) void {
        _ = data;
        c.xdg_wm_base_pong(wm_base, serial);
    }

    const xdg_wm_base_listener = c.xdg_wm_base_listener{
        .ping = xdg_ping,
    };

    fn xdg_surface_configure(data: ?*anyopaque, xdg_surface: ?*c.xdg_surface, serial: u32) callconv(.c) void {
        const self: *WindowApp = @ptrCast(@alignCast(data.?));
        c.xdg_surface_ack_configure(xdg_surface, serial);
        self.configured = true;
        self.needs_redraw = true;
    }

    const xdg_surface_listener = c.xdg_surface_listener{
        .configure = xdg_surface_configure,
    };

    fn xdg_toplevel_configure(
        data: ?*anyopaque,
        toplevel: ?*c.xdg_toplevel,
        width: i32,
        height: i32,
        states: [*c]c.struct_wl_array,
    ) callconv(.c) void {
        _ = toplevel;
        _ = states;
        const self: *WindowApp = @ptrCast(@alignCast(data.?));
        if (width > 0 and height > 0) {
            self.width = @intCast(width);
            self.height = @intCast(height);
        }
        self.needs_redraw = true;
    }

    fn xdg_toplevel_close(data: ?*anyopaque, toplevel: ?*c.xdg_toplevel) callconv(.c) void {
        _ = toplevel;
        const self: *WindowApp = @ptrCast(@alignCast(data.?));
        self.running = false;
    }

    const xdg_toplevel_listener = c.xdg_toplevel_listener{
        .configure = xdg_toplevel_configure,
        .close = xdg_toplevel_close,
    };

    fn layer_surface_configure(
        data: ?*anyopaque,
        surface: ?*c.zwlr_layer_surface_v1,
        serial: u32,
        width: u32,
        height: u32,
    ) callconv(.c) void {
        const self: *WindowApp = @ptrCast(@alignCast(data.?));
        c.zwlr_layer_surface_v1_ack_configure(surface, serial);
        if (width > 0 and height > 0) {
            self.width = width;
            self.height = height;
        }
        self.configured = true;
        self.needs_redraw = true;
    }

    fn layer_surface_closed(data: ?*anyopaque, surface: ?*c.zwlr_layer_surface_v1) callconv(.c) void {
        _ = surface;
        const self: *WindowApp = @ptrCast(@alignCast(data.?));
        self.running = false;
    }

    const layer_surface_listener = c.zwlr_layer_surface_v1_listener{
        .configure = layer_surface_configure,
        .closed = layer_surface_closed,
    };

    fn frame_done(data: ?*anyopaque, cb: ?*c.wl_callback, time: u32) callconv(.c) void {
        _ = time;
        if (cb) |c_cb| c.wl_callback_destroy(c_cb);
        const self: *WindowApp = @ptrCast(@alignCast(data.?));
        _ = self;
    }

    const frame_listener = c.wl_callback_listener{
        .done = frame_done,
    };

    fn seat_capabilities(data: ?*anyopaque, seat: ?*c.wl_seat, capabilities: u32) callconv(.c) void {
        const self: *WindowApp = @ptrCast(@alignCast(data.?));
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

    fn output_scale_cb(data: ?*anyopaque, output: ?*c.wl_output, factor: i32) callconv(.c) void {
        _ = output;
        const self: *WindowApp = @ptrCast(@alignCast(data.?));
        if (factor > 0) {
            self.output_scale = @intCast(factor);
            self.needs_redraw = true;
        }
    }

    const output_listener = c.wl_output_listener{
        .geometry = dummyGeometry,
        .mode = dummyMode,
        .done = dummyDone,
        .scale = output_scale_cb,
    };

    fn dummyGeometry(data: ?*anyopaque, o: ?*c.wl_output, x: i32, y: i32, pw: i32, ph: i32, sub: i32, mk: [*c]const u8, md: [*c]const u8, tr: i32) callconv(.c) void {
        _ = data; _ = o; _ = x; _ = y; _ = pw; _ = ph; _ = sub; _ = mk; _ = md; _ = tr;
    }
    fn dummyMode(data: ?*anyopaque, o: ?*c.wl_output, fl: u32, w: i32, h: i32, r: i32) callconv(.c) void {
        _ = data; _ = o; _ = fl; _ = w; _ = h; _ = r;
    }
    fn dummyDone(data: ?*anyopaque, o: ?*c.wl_output) callconv(.c) void {
        _ = data; _ = o;
    }

    // Pointer events
    fn pointer_enter(data: ?*anyopaque, pointer: ?*c.wl_pointer, serial: u32, surface: ?*c.wl_surface, surface_x: c.wl_fixed_t, surface_y: c.wl_fixed_t) callconv(.c) void {
        _ = pointer; _ = surface;
        const self: *WindowApp = @ptrCast(@alignCast(data.?));
        self.pointer_serial = serial;
        self.pointer_x = c.wl_fixed_to_int(surface_x);
        self.pointer_y = c.wl_fixed_to_int(surface_y);
        self.current_cursor_shape = null; // reset to force re-apply
    }

    fn pointer_leave(data: ?*anyopaque, pointer: ?*c.wl_pointer, serial: u32, surface: ?*c.wl_surface) callconv(.c) void {
        _ = pointer; _ = serial; _ = surface;
        const self: *WindowApp = @ptrCast(@alignCast(data.?));
        self.pointer_x = -1;
        self.pointer_y = -1;
    }

    fn pointer_motion(data: ?*anyopaque, pointer: ?*c.wl_pointer, time: u32, surface_x: c.wl_fixed_t, surface_y: c.wl_fixed_t) callconv(.c) void {
        _ = pointer; _ = time;
        const self: *WindowApp = @ptrCast(@alignCast(data.?));
        self.pointer_x = c.wl_fixed_to_int(surface_x);
        self.pointer_y = c.wl_fixed_to_int(surface_y);
    }

    fn pointer_button(data: ?*anyopaque, pointer: ?*c.wl_pointer, serial: u32, time: u32, button: u32, state: u32) callconv(.c) void {
        _ = pointer; _ = time;
        const self: *WindowApp = @ptrCast(@alignCast(data.?));
        self.pointer_serial = serial;
        self.pointer_down = (state == c.WL_POINTER_BUTTON_STATE_PRESSED);
        _ = button;
    }

    fn pointer_axis(data: ?*anyopaque, pointer: ?*c.wl_pointer, time: u32, axis: u32, value: c.wl_fixed_t) callconv(.c) void {
        _ = data; _ = pointer; _ = time; _ = axis; _ = value;
    }

    fn pointer_frame(data: ?*anyopaque, pointer: ?*c.wl_pointer) callconv(.c) void {
        _ = data; _ = pointer;
    }

    fn pointer_axis_source(data: ?*anyopaque, pointer: ?*c.wl_pointer, source: u32) callconv(.c) void {
        _ = data; _ = pointer; _ = source;
    }

    fn pointer_axis_stop(data: ?*anyopaque, pointer: ?*c.wl_pointer, time: u32, axis: u32) callconv(.c) void {
        _ = data; _ = pointer; _ = time; _ = axis;
    }

    fn pointer_axis_discrete(data: ?*anyopaque, pointer: ?*c.wl_pointer, axis: u32, discrete: i32) callconv(.c) void {
        _ = data; _ = pointer; _ = axis; _ = discrete;
    }

    fn pointer_axis_value120(data: ?*anyopaque, pointer: ?*c.wl_pointer, axis: u32, value120: i32) callconv(.c) void {
        _ = data; _ = pointer; _ = axis; _ = value120;
    }

    fn pointer_axis_relative_direction(data: ?*anyopaque, pointer: ?*c.wl_pointer, axis: u32, direction: u32) callconv(.c) void {
        _ = data; _ = pointer; _ = axis; _ = direction;
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
    };

    // Keyboard events
    fn kbd_keymap(data: ?*anyopaque, kbd: ?*c.wl_keyboard, format: u32, fd: i32, size: u32) callconv(.c) void {
        _ = kbd;
        const self: *WindowApp = @ptrCast(@alignCast(data.?));
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

    fn kbd_enter(data: ?*anyopaque, kbd: ?*c.wl_keyboard, serial: u32, surface: ?*c.wl_surface, keys: [*c]c.struct_wl_array) callconv(.c) void {
        _ = data; _ = kbd; _ = serial; _ = surface; _ = keys;
    }

    fn kbd_leave(data: ?*anyopaque, kbd: ?*c.wl_keyboard, serial: u32, surface: ?*c.wl_surface) callconv(.c) void {
        _ = data; _ = kbd; _ = serial; _ = surface;
    }

    fn kbd_key(data: ?*anyopaque, kbd: ?*c.wl_keyboard, serial: u32, time: u32, key: u32, state: u32) callconv(.c) void {
        _ = kbd; _ = serial; _ = time;
        const self: *WindowApp = @ptrCast(@alignCast(data.?));
        if (self.xkb_state == null) return;

        const keycode = key + 8;
        const sym = c.xkb_state_key_get_one_sym(self.xkb_state.?, keycode);
        const is_down = (state == c.WL_KEYBOARD_KEY_STATE_PRESSED);

        if (is_down) {
            var buf: [32]u8 = undefined;
            const len = c.xkb_state_key_get_utf8(self.xkb_state.?, keycode, &buf, buf.len);
            const utf8_len: usize = if (len > 0) @intCast(len) else 0;
            self.repeat_sym = sym;
            @memcpy(self.repeat_utf8_buf[0..utf8_len], buf[0..utf8_len]);
            self.repeat_utf8_len = utf8_len;
        } else {
            self.repeat_sym = 0;
            self.repeat_utf8_len = 0;
        }
    }

    fn kbd_modifiers(data: ?*anyopaque, kbd: ?*c.wl_keyboard, serial: u32, mods_depressed: u32, mods_latched: u32, mods_locked: u32, group: u32) callconv(.c) void {
        _ = kbd; _ = serial;
        const self: *WindowApp = @ptrCast(@alignCast(data.?));
        if (self.xkb_state == null) return;

        _ = c.xkb_state_update_mask(self.xkb_state.?, mods_depressed, mods_latched, mods_locked, 0, 0, group);

        self.is_ctrl = c.xkb_state_mod_name_is_active(self.xkb_state.?, c.XKB_MOD_NAME_CTRL, c.XKB_STATE_MODS_EFFECTIVE) > 0;
        self.is_shift = c.xkb_state_mod_name_is_active(self.xkb_state.?, c.XKB_MOD_NAME_SHIFT, c.XKB_STATE_MODS_EFFECTIVE) > 0;
        self.is_alt = c.xkb_state_mod_name_is_active(self.xkb_state.?, c.XKB_MOD_NAME_ALT, c.XKB_STATE_MODS_EFFECTIVE) > 0;
    }

    fn kbd_repeat_info(data: ?*anyopaque, kbd: ?*c.wl_keyboard, rate: i32, delay: i32) callconv(.c) void {
        _ = data; _ = kbd; _ = rate; _ = delay;
    }

    const keyboard_listener = c.wl_keyboard_listener{
        .keymap = kbd_keymap,
        .enter = kbd_enter,
        .leave = kbd_leave,
        .key = kbd_key,
        .modifiers = kbd_modifiers,
        .repeat_info = kbd_repeat_info,
    };
};
