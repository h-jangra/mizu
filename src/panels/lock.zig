const std = @import("std");
const c = @import("../c.zig").c;
const config = @import("../core/config.zig");
const theme = @import("../core/theme.zig");
const Color = theme.Color;
const renderer = @import("../core/renderer.zig");
const Font = renderer.Font;
const Image = renderer.Image;

pub const AuthState = enum { idle, authenticating, failed, success };

pub const LockApp = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    display: ?*c.wl_display = null,
    registry: ?*c.wl_registry = null,
    compositor: ?*c.wl_compositor = null,
    shm: ?*c.wl_shm = null,
    seat: ?*c.wl_seat = null,
    keyboard: ?*c.wl_keyboard = null,
    session_lock_mgr: ?*c.ext_session_lock_manager_v1 = null,
    session_lock: ?*c.ext_session_lock_v1 = null,
    lock_surface: ?*c.ext_session_lock_surface_v1 = null,
    surface: ?*c.wl_surface = null,
    font: ?Font = null,
    clock_font: ?Font = null,
    glyph_font: ?Font = null,
    wallpaper_img: ?*Image = null,
    wallpaper_surface: ?*c.wl_surface = null,
    wallpaper_buffer: ?*c.wl_buffer = null,
    running: bool = true,
    is_locked: bool = false,
    is_finished: bool = false,
    auth_state: AuthState = .idle,
    password_buf: [128]u8 = [_]u8{0} ** 128,
    password_len: usize = 0,
    show_input: bool = false,
    needs_redraw: bool = true,
    timer_fd: c_int = -1,
    width: u32 = 1920,
    height: u32 = 1080,
    scale: u32 = 1,
    auth_thread: ?std.Thread = null,
    auth_result: ?bool = null,
    auth_username: [256]u8 = [_]u8{0} ** 256,
    auth_username_len: usize = 0,
    caret_blink: bool = true,
    last_frame_time: u64 = 0,
    glyph_anim_offset: f32 = 0.0,
    xkb_ctx: ?*c.struct_xkb_context = null,
    xkb_keymap: ?*c.struct_xkb_keymap = null,
    xkb_state: ?*c.struct_xkb_state = null,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !LockApp {
        var app = LockApp{
            .allocator = allocator,
            .cfg = cfg,
        };
        app.font = Font.init(allocator, cfg.theme.font_family, 16) catch null;
        app.clock_font = Font.init(allocator, cfg.theme.font_family, 120) catch null;
        app.glyph_font = Font.init(allocator, "Symbols Nerd Font, JetBrainsMono Nerd Font, monospace", 48) catch null;
        app.xkb_ctx = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
        return app;
    }

    pub fn deinit(self: *LockApp) void {
        if (self.auth_thread) |t| {
            _ = t.join();
            self.auth_thread = null;
        }
        if (self.font) |*f| { f.deinit(); self.font = null; }
        if (self.clock_font) |*f| { f.deinit(); self.clock_font = null; }
        if (self.glyph_font) |*f| { f.deinit(); self.glyph_font = null; }
        if (self.wallpaper_img) |img| { img.deinit(); self.wallpaper_img = null; }
        if (self.wallpaper_buffer) |buf| { c.wl_buffer_destroy(buf); self.wallpaper_buffer = null; }
        if (self.wallpaper_surface) |surf| { c.wl_surface_destroy(surf); self.wallpaper_surface = null; }
        if (self.lock_surface) |ls| { c.ext_session_lock_surface_v1_destroy(ls); self.lock_surface = null; }
        if (self.surface) |surf| { c.wl_surface_destroy(surf); self.surface = null; }
        if (self.keyboard) |kbd| { c.wl_keyboard_destroy(kbd); self.keyboard = null; }
        if (self.seat) |st| { c.wl_seat_destroy(st); self.seat = null; }
        if (self.shm) |sh| { c.wl_shm_destroy(sh); self.shm = null; }
        if (self.session_lock) |sl| {
            if (!self.is_locked) c.ext_session_lock_v1_destroy(sl);
            self.session_lock = null;
        }
        if (self.session_lock_mgr) |mgr| { c.ext_session_lock_manager_v1_destroy(mgr); self.session_lock_mgr = null; }
        if (self.compositor) |comp| { c.wl_compositor_destroy(comp); self.compositor = null; }
        if (self.registry) |reg| { c.wl_registry_destroy(reg); self.registry = null; }
        if (self.display) |disp| { c.wl_display_disconnect(disp); self.display = null; }
        if (self.xkb_state) |st| { c.xkb_state_unref(st); self.xkb_state = null; }
        if (self.xkb_keymap) |km| { c.xkb_keymap_unref(km); self.xkb_keymap = null; }
        if (self.xkb_ctx) |ctx| { c.xkb_context_unref(ctx); self.xkb_ctx = null; }
        if (self.timer_fd >= 0) { _ = c.close(self.timer_fd); self.timer_fd = -1; }
    }

    fn wipePassword(self: *LockApp) void {
        @memset(&self.password_buf, 0);
        self.password_len = 0;
        self.show_input = false;
    }

    fn submitAuth(self: *LockApp) void {
        if (self.auth_thread) |t| {
            _ = t.join();
        }
        const password_copy = self.password_buf[0..self.password_len];
        const username = if (self.auth_username_len > 0) self.auth_username[0..self.auth_username_len] else "user";
        self.auth_state = .authenticating;
        self.auth_result = null;
        self.auth_thread = std.Thread.spawn(.{}, authWorker, .{ self, username, password_copy }) catch {
            self.auth_state = .failed;
            return;
        };
    }

    fn render(self: *LockApp, wl_surface: *c.wl_surface) void {
        const stride = self.width * 4;
        const pixel_buf = self.allocator.alloc(u32, self.width * self.height) catch return;
        defer self.allocator.free(pixel_buf);

        const target = renderer.Renderer.init(pixel_buf.ptr, self.width, self.height, stride) catch return;

        // Draw wallpaper (full screen)
        if (self.wallpaper_img) |img| {
            self.drawWallpaper(target, img);
        } else {
            // Fallback: dark gradient
            self.drawFallbackBackground(target);
        }

        // Dark overlay for readability
        target.fillRect(0, 0, self.width, self.height, Color.init(120, 0, 0, 0));

        // Decorative glyphs (subtle, animated)
        self.drawDecorativeGlyphs(target);

        // Large elegant clock (center)
        self.drawClock(target);

        // Password input indicator (only when typing)
        if (self.show_input) {
            self.drawPasswordIndicator(target);
        }

        // Failed auth feedback
        if (self.auth_state == .failed) {
            self.drawAuthFailed(target);
        }

        // Create SHM buffer and attach
        self.presentFrame(wl_surface, pixel_buf.ptr, stride);
    }

    fn drawWallpaper(self: *LockApp, target: renderer.Renderer, img: *Image) void {
        if (img.width == self.width and img.height == self.height) {
            // Direct copy
            @memcpy(target.pixels[0..self.width * self.height], img.pixels[0..self.width * self.height]);
        } else {
            // Scale to fit (cover mode)
            const scale_x = @as(f32, @floatFromInt(self.width)) / @as(f32, @floatFromInt(img.width));
            const scale_y = @as(f32, @floatFromInt(self.height)) / @as(f32, @floatFromInt(img.height));
            const scale = @max(scale_x, scale_y);
            const src_w = @as(u32, @intFromFloat(@as(f32, @floatFromInt(self.width)) / scale));
            const src_h = @as(u32, @intFromFloat(@as(f32, @floatFromInt(self.height)) / scale));
            const src_x = (img.width - src_w) / 2;
            const src_y = (img.height - src_h) / 2;

            var dy: u32 = 0;
            while (dy < self.height) : (dy += 1) {
                const sy = src_y + @as(u32, @intFromFloat(@as(f32, @floatFromInt(dy)) / scale));
                var dx: u32 = 0;
                while (dx < self.width) : (dx += 1) {
                    const sx = src_x + @as(u32, @intFromFloat(@as(f32, @floatFromInt(dx)) / scale));
                    const idx = dy * self.width + dx;
                    const src_idx = sy * img.width + sx;
                    target.pixels[idx] = img.pixels[src_idx];
                }
            }
        }
    }

    fn drawFallbackBackground(self: *LockApp, target: renderer.Renderer) void {
        // Vertical gradient dark
        var y: i32 = 0;
        while (y < @as(i32, @intCast(self.height))) : (y += 1) {
            const t = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(self.height));
            const r = @as(u8, @intFromFloat(15.0 + t * 10.0));
            const g = @as(u8, @intFromFloat(15.0 + t * 5.0));
            const b = @as(u8, @intFromFloat(25.0 + t * 15.0));
            const color = Color.init(255, r, g, b);
            target.fillRect(0, y, self.width, 1, color);
        }
    }

    fn drawDecorativeGlyphs(self: *LockApp, target: renderer.Renderer) void {
        const glyphs = [_][]const u8{
            "", "󰝨", "", "󰴈", "󰧱", "󱎂", "", "", "", "", "", "󰢘",
        };
        const color = Color.init(35, 180, 180, 200); // Very subtle

        var glyph_font = self.glyph_font orelse return;
        const center_x = @as(i32, @intCast(self.width / 2));
        const center_y = @as(i32, @intCast(self.height / 2));

        // Arrange in a subtle circle around center
        const radius = @as(f32, @floatFromInt(@min(self.width, self.height))) * 0.35;
        const count = glyphs.len;
        const time_factor = self.glyph_anim_offset;

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const angle = (@as(f32, @floatFromInt(i)) * 2.0 * std.math.pi / @as(f32, @floatFromInt(count))) + time_factor * 0.15;
            const gx = center_x + @as(i32, @intFromFloat(radius * @cos(angle)));
            const gy = center_y + @as(i32, @intFromFloat(radius * @sin(angle)));

            // Vary alpha slightly based on position
            var alpha: u8 = 35;
            const pulse = @sin(time_factor * 2.0 + @as(f32, @floatFromInt(i)) * 0.5) * 0.3 + 0.7;
            alpha = @as(u8, @intFromFloat(@as(f32, alpha) * pulse));

            const glyph_color = Color.init(alpha, color.r, color.g, color.b);
            const glyph = glyphs[i];

            // Use measureInk for proper centering
            const extents = (&glyph_font).measureInk(glyph, 48);
            const gx_centered = gx - @as(i32, @intCast(extents.width / 2)) - extents.left;
            const gy_centered = gy + @as(i32, @intCast(extents.width / 4)); // vertical center approx

            self.drawTextWithFont(target, &glyph_font, glyph, gx_centered, gy_centered, 48, glyph_color);
        }
    }

    fn drawClock(self: *LockApp, target: renderer.Renderer) void {
        var clock_font = self.clock_font orelse return;
        const now = c.time(null);
        var tm: c.struct_tm = undefined;
        _ = c.localtime_r(&now, &tm);

        const hours = tm.tm_hour;
        const mins = tm.tm_min;

        var time_buf: [16]u8 = undefined;
        const time_str = std.fmt.bufPrint(&time_buf, "{:02}:{:02}", .{ hours, mins }) catch "00:00";

        const extents = (&clock_font).measureInk(time_str, 120);
        const text_w = extents.width;
        const y = @divTrunc(@as(i32, @intCast(self.height)), 2) + @divTrunc(@as(i32, @intCast(clock_font.ascender_px)), 2) - 30;

        // Shadow
        const shadow_color = Color.init(100, 0, 0, 0);
        const clock_x = @divTrunc(@as(i32, @intCast(self.width)) - @as(i32, @intCast(text_w)), 2) - extents.left;
        self.drawTextWithFont(target, &clock_font, time_str, clock_x + 2, y + 2, 120, shadow_color);

        // Main text
        const main_color = Color.init(255, 255, 255, 255);
        self.drawTextWithFont(target, &clock_font, time_str, clock_x, y, 120, main_color);

        // Date below clock
        var date_font = self.font orelse return;
        const month_names = [_][]const u8{
            "Jan", "Feb", "Mar", "Apr", "May", "Jun",
            "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        };
        const mon_idx = @as(usize, @intCast(tm.tm_mon));
        const mon = if (tm.tm_mon >= 0 and tm.tm_mon < 12) month_names[mon_idx] else "??";
        var date_buf: [32]u8 = undefined;
        const date_full = std.fmt.bufPrint(&date_buf, "{s} {}, {}", .{ mon, tm.tm_mday, tm.tm_year + 1900 }) catch "";
        const date_w = (&date_font).measureTextWithSize(date_full, 16);
        const date_x = @divTrunc(@as(i32, @intCast(self.width)) - @as(i32, @intCast(date_w)), 2);
        const date_y = y + @as(i32, @intCast(clock_font.ascender_px)) + 10;
        self.drawTextWithFont(target, &date_font, date_full, date_x, date_y, 16, main_color);
    }

    fn drawPasswordIndicator(self: *LockApp, target: renderer.Renderer) void {
        _ = self.font;
        const center_x = @as(i32, @intCast(self.width / 2));
        const y = @divTrunc(@as(i32, @intCast(self.height)), 2) + 80;

        // Show dots for each character typed
        const dot_count = self.password_len;
        if (dot_count == 0) return;

        const dot_size = 12 * self.scale;
        const dot_gap = 8 * self.scale;
        const total_w = dot_count * dot_size + (dot_count - 1) * dot_gap;
        var dot_x = center_x - @as(i32, @intCast(total_w / 2));

        const dot_color = Color.init(200, 255, 255, 255);
        var i: usize = 0;
        while (i < dot_count) : (i += 1) {
            target.fillCircle(
                @as(f64, @floatFromInt(dot_x + @as(i32, @intCast(dot_size / 2)))),
                @as(f64, @floatFromInt(y)),
                @as(f64, @floatFromInt(dot_size / 2)),
                dot_color,
            );
            dot_x += @as(i32, @intCast(dot_size + dot_gap));
        }

        // Blinking caret
        if (self.caret_blink) {
            const caret_x = dot_x + 4;
            target.fillRect(caret_x, y - @as(i32, @intCast(dot_size / 2)), 2, dot_size, dot_color);
        }
    }

    fn drawAuthFailed(self: *LockApp, target: renderer.Renderer) void {
        var font = self.font orelse return;
        const text = "Wrong password";
        const text_w = (&font).measureTextWithSize(text, 16);
        const x = @divTrunc(@as(i32, @intCast(self.width)) - @as(i32, @intCast(text_w)), 2);
        const y = @divTrunc(@as(i32, @intCast(self.height)), 2) + 140;

        const color = Color.init(255, 255, 80, 80);
        self.drawTextWithFont(target, &font, text, x, y, 16, color);
    }

    fn drawTextWithFont(self: *LockApp, target: renderer.Renderer, font: *Font, text: []const u8, x: i32, y: i32, size: u32, color: Color) void {
        if (text.len == 0) return;
        var pen_x = x;
        var utf8_view = std.unicode.Utf8View.init(text) catch return;
        var it = utf8_view.iterator();
        while (it.nextCodepoint()) |cp| {
            if (font.getOrLoadGlyph(cp, size)) |cg| {
                if (cg.width > 0 and cg.height > 0) {
                    const gx = pen_x + cg.left;
                    const gy = y - cg.top;
                    self.drawGlyphBitmap(target, cg, gx, gy, color);
                }
                pen_x += cg.advance_x;
            } else {
                pen_x += @as(i32, @intCast(size / 2));
            }
        }
    }

    fn drawGlyphBitmap(self: *LockApp, target: renderer.Renderer, cg: renderer.CachedGlyph, x: i32, y: i32, color: Color) void {
    _ = self;
        if (cg.width == 0 or cg.height == 0) return;
        const stride = @as(usize, target.stride) / 4;
        _ = stride;
        var gy: u32 = 0;
        while (gy < cg.height) : (gy += 1) {
            const sy = @as(i32, y) + @as(i32, @intCast(gy));
            if (sy < 0 or sy >= @as(i32, @intCast(target.height))) {
                continue;
            }
            var gx: u32 = 0;
            while (gx < cg.width) : (gx += 1) {
                const sx = x + @as(i32, @intCast(gx));
                if (sx < 0 or sx >= @as(i32, @intCast(target.width))) {
                    continue;
                }
                const alpha = cg.bitmap[gy * cg.width + gx];
                if (alpha == 0) continue;
                var col = color;
                col.a = @intCast((@as(u32, alpha) * @as(u32, color.a)) / 255);
                target.setPixel(sx, sy, col);
            }
        }
    }

    fn presentFrame(self: *LockApp, wl_surface: *c.wl_surface, pixels: [*]u32, stride: u32) void {
        if (self.shm == null) return;
        const pool_size = stride * self.height;
        const fd = c.memfd_create("mizu-lock-buffer", 0);
        if (fd < 0) return;
        const pool = c.wl_shm_create_pool(self.shm.?, fd, @intCast(pool_size));
        if (pool == null) {
            _ = c.close(fd);
            return;
        }
        const data = c.mmap(null, pool_size, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
        if (data == c.MAP_FAILED) {
            c.wl_shm_pool_destroy(pool);
            _ = c.close(fd);
            return;
        }
        defer _ = c.munmap(data, pool_size);
        _ = c.memcpy(data, pixels, pool_size);

        const buffer = c.wl_shm_pool_create_buffer(pool, 0, @intCast(self.width), @intCast(self.height), @intCast(stride), c.WL_SHM_FORMAT_ARGB8888);
        c.wl_shm_pool_destroy(pool);
        _ = c.close(fd);

        if (buffer == null) return;

        c.wl_surface_attach(wl_surface, buffer, 0, 0);
        c.wl_surface_damage_buffer(wl_surface, 0, 0, @intCast(self.width), @intCast(self.height));
        c.wl_surface_commit(wl_surface);
    }
};

fn authWorker(app_ptr: *LockApp, username: []const u8, password: []const u8) void {
    const result = authenticatePAM(username, password);
    app_ptr.auth_result = result;
    if (result) {
        app_ptr.auth_state = .success;
    } else {
        app_ptr.auth_state = .failed;
    }
    app_ptr.needs_redraw = true;
}

fn authenticatePAM(username: []const u8, password: []const u8) bool {
    var pamh: ?*c.pam_handle_t = null;
    var conv: c.struct_pam_conv = .{
        .conv = pamConv,
        .appdata_ptr = @ptrCast(@constCast(&password)),
    };
    const ret = c.pam_start("login", username.ptr, &conv, &pamh);
    if (ret != c.PAM_SUCCESS) return false;
    defer _ = c.pam_end(pamh, ret);
    const auth_ret = c.pam_authenticate(pamh, 0);
    return auth_ret == c.PAM_SUCCESS;
}

fn pamConv(num_msg: c_int, msg: [*c][*c]const c.struct_pam_message, resp: [*c][*c]c.struct_pam_response, appdata_ptr: ?*anyopaque) callconv(.c) c_int {
    _ = num_msg;
    _ = msg;
    _ = resp;
    _ = appdata_ptr;
    return c.PAM_CONV_ERR;
}

// Wayland listeners
const registry_listener = c.wl_registry_listener{
    .global = registry_global,
    .global_remove = null,
};

fn registry_global(data: ?*anyopaque, reg: ?*c.wl_registry, name: u32, iface: [*c]const u8, ver: u32) callconv(.c) void {
    _ = ver;
    const self: *LockApp = @ptrCast(@alignCast(data.?));
    const s = std.mem.span(iface);
    if (std.mem.eql(u8, s, "wl_compositor")) {
        self.compositor = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_compositor_interface, 1));
    } else if (std.mem.eql(u8, s, "wl_shm")) {
        self.shm = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_shm_interface, 1));
    } else if (std.mem.eql(u8, s, "wl_seat")) {
        self.seat = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_seat_interface, 1));
    } else if (std.mem.eql(u8, s, "ext_session_lock_manager_v1")) {
        self.session_lock_mgr = @ptrCast(c.wl_registry_bind(reg, name, &c.ext_session_lock_manager_v1_interface, 1));
    }
}

const session_listener = c.ext_session_lock_v1_listener{
    .locked = session_locked,
    .finished = session_finished,
};

fn session_locked(data: ?*anyopaque, sl: ?*c.ext_session_lock_v1) callconv(.c) void {
    _ = sl;
    const self: *LockApp = @ptrCast(@alignCast(data.?));
    self.is_locked = true;
}

fn session_finished(data: ?*anyopaque, sl: ?*c.ext_session_lock_v1) callconv(.c) void {
    _ = sl;
    const self: *LockApp = @ptrCast(@alignCast(data.?));
    self.is_finished = true;
    self.running = false;
}

// Keyboard listener
const keyboard_listener = c.wl_keyboard_listener{
    .keymap = keyboard_keymap,
    .enter = keyboard_enter,
    .leave = keyboard_leave,
    .key = keyboard_key,
    .modifiers = keyboard_modifiers,
    .repeat_info = null,
};

fn keyboard_keymap(data: ?*anyopaque, kbd: ?*c.wl_keyboard, format: u32, fd: c_int, size: u32) callconv(.c) void {
    _ = kbd;
    const self: *LockApp = @ptrCast(@alignCast(data.?));
    defer _ = c.close(fd);
    if (format != c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) return;
    const map_shm = c.mmap(null, size, c.PROT_READ, c.MAP_SHARED, fd, 0);
    if (map_shm == c.MAP_FAILED) return;
    defer _ = c.munmap(map_shm, size);
    const map_str: [*c]const u8 = @ptrCast(map_shm);
    const keymap = c.xkb_keymap_new_from_string(self.xkb_ctx.?, map_str, c.XKB_KEYMAP_FORMAT_TEXT_V1, c.XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (keymap == null) return;
    const state = c.xkb_state_new(keymap);
    if (self.xkb_state) |st| c.xkb_state_unref(st);
    if (self.xkb_keymap) |km| c.xkb_keymap_unref(km);
    self.xkb_keymap = keymap;
    self.xkb_state = state;
}

fn keyboard_enter(data: ?*anyopaque, kbd: ?*c.wl_keyboard, serial: u32, surf: ?*c.wl_surface, keys: [*c]c.wl_array) callconv(.c) void {
    _ = data; _ = kbd; _ = serial; _ = surf; _ = keys;
}

fn keyboard_leave(data: ?*anyopaque, kbd: ?*c.wl_keyboard, serial: u32, surf: ?*c.wl_surface) callconv(.c) void {
    _ = data; _ = kbd; _ = serial; _ = surf;
}

fn keyboard_key(data: ?*anyopaque, kbd: ?*c.wl_keyboard, serial: u32, time: u32, key: u32, state: u32) callconv(.c) void {
    _ = kbd; _ = serial; _ = time;
    const self: *LockApp = @ptrCast(@alignCast(data.?));
    if (state == c.WL_KEYBOARD_KEY_STATE_RELEASED) return;

    if (self.xkb_state == null) return;
    const keycode = key + 8;
    const sym = c.xkb_state_key_get_one_sym(self.xkb_state.?, keycode);

    if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_KP_Enter) {
        if (self.auth_state == .authenticating) return;
        self.submitAuth();
        return;
    }
    if (sym == c.XKB_KEY_Escape) {
        self.wipePassword();
        self.auth_state = .idle;
        self.needs_redraw = true;
        return;
    }
    if (sym == c.XKB_KEY_BackSpace) {
        if (self.password_len > 0) {
            self.password_len -= 1;
            self.password_buf[self.password_len] = 0;
            self.show_input = true;
            self.needs_redraw = true;
        }
        return;
    }

    // Printable character input using UTF-8
    if (self.xkb_state != null) {
        var utf8_buf: [32]u8 = [_]u8{0} ** 32;
        const len = c.xkb_state_key_get_utf8(self.xkb_state.?, keycode, &utf8_buf, utf8_buf.len);
        if (len > 0 and self.password_len + @as(usize, @intCast(len)) < self.password_buf.len) {
            const slice = utf8_buf[0..@as(usize, @intCast(len))];
            const first_char = slice[0];
            if (first_char >= 32 and first_char != 127) {
                @memcpy(self.password_buf[self.password_len..self.password_len + slice.len], slice);
                self.password_len += slice.len;
                self.show_input = true;
                self.needs_redraw = true;
            }
        }
    }
}

fn keyboard_modifiers(data: ?*anyopaque, kbd: ?*c.wl_keyboard, serial: u32, mods_depressed: u32, mods_latched: u32, mods_locked: u32, group: u32) callconv(.c) void {
    const self: *LockApp = @ptrCast(@alignCast(data.?));
    _ = kbd;
    _ = serial;
    if (self.xkb_state) |st| {
        _ = c.xkb_state_update_mask(st, mods_depressed, mods_latched, mods_locked, 0, 0, group);
    }
}

// Lock surface listener
const lock_surface_listener = c.ext_session_lock_surface_v1_listener{
    .configure = lock_surface_configure,
};

fn lock_surface_configure(data: ?*anyopaque, ls: ?*c.ext_session_lock_surface_v1, serial: u32, width: u32, height: u32) callconv(.c) void {
    const self: *LockApp = @ptrCast(@alignCast(data.?));
    self.width = width;
    self.height = height;
    self.scale = 1; // Could detect from output
    c.ext_session_lock_surface_v1_ack_configure(ls, serial);
    self.needs_redraw = true;
}

pub fn runLock(allocator: std.mem.Allocator, cfg: config.Config) !void {
    var app = try LockApp.init(allocator, cfg);
    defer app.deinit();

    const disp = c.wl_display_connect(null) orelse return error.ConnectFailed;
    app.display = disp;

    // Get current user for PAM
    if (c.getenv("USER")) |user| {
        const u = std.mem.span(user);
        const len = @min(u.len, app.auth_username.len - 1);
        @memcpy(app.auth_username[0..len], u[0..len]);
        app.auth_username_len = len;
    }

    app.timer_fd = c.timerfd_create(c.CLOCK_MONOTONIC, c.TFD_CLOEXEC | c.TFD_NONBLOCK);
    if (app.timer_fd >= 0) {
        var its: c.struct_itimerspec = .{
            .it_interval = .{ .tv_sec = 0, .tv_nsec = 500_000_000 },
            .it_value = .{ .tv_sec = 0, .tv_nsec = 500_000_000 },
        };
        _ = c.timerfd_settime(app.timer_fd, 0, &its, null);
    }

    const reg = c.wl_display_get_registry(disp);
    if (reg == null) return error.RegistryFailed;
    app.registry = reg;

    _ = c.wl_registry_add_listener(reg, &registry_listener, &app);
    _ = c.wl_display_roundtrip(disp);

    if (app.compositor == null or app.shm == null or app.session_lock_mgr == null) {
        return error.ProtocolMissing;
    }

    const sl = c.ext_session_lock_manager_v1_lock(app.session_lock_mgr.?);
    if (sl == null) return error.LockFailed;
    app.session_lock = sl;
    _ = c.ext_session_lock_v1_add_listener(sl, &session_listener, &app);

    // Load wallpaper
    if (cfg.wallpaper) |wpath| {
        if (wpath.len > 0) {
            app.wallpaper_img = Image.loadFile(allocator, wpath) catch null;
        }
    }

    // Wait for lock to be established
    while (app.running and !app.is_locked) {
        _ = c.wl_display_dispatch(disp);
    }

    // Get the lock surface for our output
    // In a real implementation, we'd iterate outputs and create lock surfaces for each
    // For now, create one for the first output (null = all outputs)
    if (app.compositor != null) {
        app.surface = c.wl_compositor_create_surface(app.compositor.?);
        if (app.surface != null and app.session_lock != null) {
            app.lock_surface = c.ext_session_lock_v1_get_lock_surface(app.session_lock.?, app.surface.?, null);
            if (app.lock_surface != null) {
                _ = c.ext_session_lock_surface_v1_add_listener(app.lock_surface.?, &lock_surface_listener, &app);
            }
        }
    }

    // Get keyboard
    if (app.seat != null) {
        app.keyboard = c.wl_seat_get_keyboard(app.seat.?);
        if (app.keyboard != null) {
            _ = c.wl_keyboard_add_listener(app.keyboard.?, &keyboard_listener, &app);
        }
    }

    // Main loop
    while (app.running and !app.is_finished) {
        _ = c.wl_display_dispatch_pending(disp);
        _ = c.wl_display_flush(disp);

        if (app.auth_state == .success) {
            break;
        }

        const fd = c.wl_display_get_fd(disp);
        var pfd = [_]c.struct_pollfd{
            .{ .fd = fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (app.timer_fd >= 0) app.timer_fd else -1, .events = c.POLLIN, .revents = 0 },
        };
        const pr = c.poll(&pfd, pfd.len, 16);
        if (pr > 0) {
            if ((pfd[0].revents & c.POLLIN) != 0) {
                _ = c.wl_display_read_events(disp);
                _ = c.wl_display_dispatch_pending(disp);
            }
            if (app.timer_fd >= 0 and (pfd[1].revents & c.POLLIN) != 0) {
                var val: u64 = 0;
                _ = c.read(app.timer_fd, &val, @sizeOf(u64));
                app.caret_blink = !app.caret_blink;
                app.glyph_anim_offset += 0.02;
                app.needs_redraw = true;
            }
        }

        if (app.needs_redraw and app.surface != null) {
            app.needs_redraw = false;
            app.render(app.surface.?);
        }
    }
}