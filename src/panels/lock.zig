const std = @import("std");
const c = @import("../c.zig").c;
const config = @import("../core/config.zig");
const theme = @import("../core/theme.zig");
const Color = theme.Color;
const renderer = @import("../core/renderer.zig");
const Font = renderer.Font;
const Image = renderer.Image;
const ui_mod = @import("../core/ui.zig");
const buffer = @import("../core/buffer.zig");

pub const AuthState = enum { idle, authenticating, failed, success };

pub const AuthContext = struct {
    username: [256]u8 = [_]u8{0} ** 256,
    password: [128]u8 = [_]u8{0} ** 128,
};

pub const LockOutput = struct {
    app: *LockApp,
    output: *c.wl_output,
    global_name: u32,
    surface: ?*c.wl_surface = null,
    lock_surface: ?*c.ext_session_lock_surface_v1 = null,
    pool: ?buffer.BufferPool = null,
    width: u32 = 0,
    height: u32 = 0,
    scale: u32 = 1,
    configured: bool = false,

    pub fn deinit(self: *LockOutput) void {
        if (self.pool) |*p| {
            p.deinit();
            self.pool = null;
        }
        if (self.lock_surface) |ls| {
            c.ext_session_lock_surface_v1_destroy(ls);
            self.lock_surface = null;
        }
        if (self.surface) |s| {
            c.wl_surface_destroy(s);
            self.surface = null;
        }
        c.wl_output_destroy(self.output);
    }
};

pub const LockApp = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    display: ?*c.wl_display = null,
    registry: ?*c.wl_registry = null,
    compositor: ?*c.wl_compositor = null,
    shm: ?*c.wl_shm = null,
    seat: ?*c.wl_seat = null,
    keyboard: ?*c.wl_keyboard = null,
    pointer: ?*c.wl_pointer = null,
    session_lock_mgr: ?*c.ext_session_lock_manager_v1 = null,
    session_lock: ?*c.ext_session_lock_v1 = null,
    outputs: std.ArrayListUnmanaged(*LockOutput) = .empty,
    font: ?Font = null,
    clock_font: ?Font = null,
    glyph_font: ?Font = null,
    wallpaper_img: ?*Image = null,
    running: bool = true,
    is_locked: bool = false,
    is_finished: bool = false,
    has_kbd_focus: bool = false,
    caps_lock_active: bool = false,
    auth_state: AuthState = .idle,
    auth_in_flight: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    auth_finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    auth_success: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    auth_thread: ?std.Thread = null,
    auth_fn: *const fn (username: [:0]const u8, password: [:0]const u8) bool = authenticatePAM,
    password_buf: [128]u8 = [_]u8{0} ** 128,
    password_len: usize = 0,
    show_input: bool = false,
    needs_redraw: bool = true,
    timer_fd: c_int = -1,
    auth_username: [256]u8 = [_]u8{0} ** 256,
    auth_username_len: usize = 0,
    caret_blink: bool = true,
    glyph_anim_offset: f32 = 0.0,
    rng_seed: u64 = 0x853c49e6748fea9b,
    xkb_ctx: ?*c.struct_xkb_context = null,
    xkb_keymap: ?*c.struct_xkb_keymap = null,
    xkb_state: ?*c.struct_xkb_state = null,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !LockApp {
        var app = LockApp{
            .allocator = allocator,
            .cfg = cfg,
        };
        app.rng_seed = @as(u64, @intCast(@max(1, c.time(null)))) *% 0x9E3779B97F4A7C15 +% 0x517cc1b727220a95;
        app.font = Font.init(allocator, cfg.theme.font_family, 16) catch
            (Font.init(allocator, "sans-serif, monospace", 16) catch null);
        app.clock_font = Font.init(allocator, cfg.theme.font_family, 120) catch null;
        app.glyph_font = Font.init(allocator, "Symbols Nerd Font, JetBrainsMono Nerd Font, monospace", 48) catch null;
        app.xkb_ctx = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
        if (app.xkb_ctx) |ctx| {
            app.xkb_keymap = c.xkb_keymap_new_from_names(ctx, null, c.XKB_KEYMAP_COMPILE_NO_FLAGS);
            if (app.xkb_keymap) |km| {
                app.xkb_state = c.xkb_state_new(km);
            }
        }
        return app;
    }

    pub fn deinit(self: *LockApp) void {
        if (self.auth_thread) |t| {
            t.join();
            self.auth_thread = null;
        }
        self.wipePassword();

        for (self.outputs.items) |out| {
            out.deinit();
            self.allocator.destroy(out);
        }
        self.outputs.deinit(self.allocator);

        if (self.font) |*f| {
            f.deinit();
            self.font = null;
        }
        if (self.clock_font) |*f| {
            f.deinit();
            self.clock_font = null;
        }
        if (self.glyph_font) |*f| {
            f.deinit();
            self.glyph_font = null;
        }
        if (self.wallpaper_img) |img| {
            img.deinit();
            self.wallpaper_img = null;
        }
        if (self.pointer) |ptr| {
            c.wl_pointer_destroy(ptr);
            self.pointer = null;
        }
        if (self.keyboard) |kbd| {
            c.wl_keyboard_destroy(kbd);
            self.keyboard = null;
        }
        if (self.seat) |st| {
            c.wl_seat_destroy(st);
            self.seat = null;
        }
        if (self.session_lock) |sl| {
            if (self.is_locked and self.auth_state == .success) {
                c.ext_session_lock_v1_unlock_and_destroy(sl);
            } else if (!self.is_locked) {
                c.ext_session_lock_v1_destroy(sl);
            }
            self.session_lock = null;
        }
        if (self.session_lock_mgr) |mgr| {
            c.ext_session_lock_manager_v1_destroy(mgr);
            self.session_lock_mgr = null;
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
        if (self.timer_fd >= 0) {
            _ = c.close(self.timer_fd);
            self.timer_fd = -1;
        }
    }

    pub fn wipePassword(self: *LockApp) void {
        @memset(&self.password_buf, 0);
        self.password_len = 0;
        self.show_input = false;
    }

    pub fn submitAuth(self: *LockApp) void {
        if (self.auth_in_flight.load(.acquire)) return;
        if (self.auth_thread) |t| {
            t.join();
            self.auth_thread = null;
        }

        var ctx = AuthContext{};
        const user_slice = if (self.auth_username_len > 0)
            self.auth_username[0..self.auth_username_len]
        else
            "user";
        const ulen = @min(user_slice.len, ctx.username.len - 1);
        @memcpy(ctx.username[0..ulen], user_slice[0..ulen]);
        ctx.username[ulen] = 0;

        const plen = @min(self.password_len, ctx.password.len - 1);
        @memcpy(ctx.password[0..plen], self.password_buf[0..plen]);
        ctx.password[plen] = 0;

        // Wipe local password buffer immediately
        self.wipePassword();

        self.auth_state = .authenticating;
        self.needs_redraw = true;
        self.auth_finished.store(false, .release);
        self.auth_success.store(false, .release);
        self.auth_in_flight.store(true, .release);

        self.auth_thread = std.Thread.spawn(.{}, authWorker, .{ self, ctx }) catch {
            self.auth_in_flight.store(false, .release);
            self.auth_state = .failed;
            self.needs_redraw = true;
            return;
        };
    }

    pub fn checkAuthResult(self: *LockApp) void {
        if (!self.auth_finished.load(.acquire)) return;
        self.auth_finished.store(false, .release);
        self.auth_in_flight.store(false, .release);

        if (self.auth_thread) |t| {
            t.join();
            self.auth_thread = null;
        }

        if (self.auth_success.load(.acquire)) {
            self.auth_state = .success;
        } else {
            self.auth_state = .failed;
        }
        self.needs_redraw = true;
    }

    pub fn handleKey(self: *LockApp, key: u32, state: u32) void {
        if (state == c.WL_KEYBOARD_KEY_STATE_RELEASED) return;
        if (self.xkb_state == null) return;
        if (self.auth_state == .authenticating) return;

        const keycode = key + 8;
        const sym = c.xkb_state_key_get_one_sym(self.xkb_state.?, keycode);
        const is_ctrl = c.xkb_state_mod_name_is_active(self.xkb_state.?, c.XKB_MOD_NAME_CTRL, c.XKB_STATE_MODS_EFFECTIVE) > 0;
        self.caps_lock_active = c.xkb_state_mod_name_is_active(self.xkb_state.?, c.XKB_MOD_NAME_CAPS, c.XKB_STATE_MODS_EFFECTIVE) > 0;

        // Enter submits authentication
        if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_KP_Enter) {
            if (self.password_len > 0) {
                self.submitAuth();
            }
            return;
        }

        // Escape or Ctrl+U / Ctrl+C clears entered password
        if (sym == c.XKB_KEY_Escape or (is_ctrl and (sym == c.XKB_KEY_u or sym == c.XKB_KEY_c))) {
            self.wipePassword();
            self.auth_state = .idle;
            self.needs_redraw = true;
            return;
        }

        // Backspace or Ctrl+Backspace / Ctrl+W deletes characters
        if (sym == c.XKB_KEY_BackSpace or (is_ctrl and (sym == c.XKB_KEY_w or sym == c.XKB_KEY_BackSpace))) {
            if (self.auth_state == .failed) {
                self.auth_state = .idle;
            }
            if (self.password_len > 0) {
                if (is_ctrl) {
                    self.wipePassword();
                } else {
                    var end = self.password_len;
                    while (end > 0) {
                        end -= 1;
                        const byte = self.password_buf[end];
                        self.password_buf[end] = 0;
                        if ((byte & 0xC0) != 0x80) break;
                    }
                    self.password_len = end;
                    self.show_input = (self.password_len > 0);
                }
                self.needs_redraw = true;
            }
            return;
        }

        if (is_ctrl) return;

        // Printable characters
        var utf8_buf: [32]u8 = [_]u8{0} ** 32;
        const len = c.xkb_state_key_get_utf8(self.xkb_state.?, keycode, &utf8_buf, utf8_buf.len);
        if (len > 0) {
            const ulen: usize = @intCast(len);
            const slice = utf8_buf[0..ulen];
            const first = slice[0];
            if (first >= 32 and first != 127) {
                if (self.auth_state == .failed) {
                    self.auth_state = .idle;
                    self.wipePassword();
                }
                if (self.password_len + slice.len < self.password_buf.len) {
                    @memcpy(self.password_buf[self.password_len .. self.password_len + slice.len], slice);
                    self.password_len += slice.len;
                    self.show_input = true;
                    self.needs_redraw = true;
                }
            }
        }
    }

    pub fn createLockSurfaceForOutput(self: *LockApp, out: *LockOutput) void {
        if (out.lock_surface != null) return;
        const comp = self.compositor orelse return;
        const lock = self.session_lock orelse return;
        const surf = c.wl_compositor_create_surface(comp) orelse return;
        out.surface = surf;
        const ls = c.ext_session_lock_v1_get_lock_surface(lock, surf, out.output) orelse {
            c.wl_surface_destroy(surf);
            out.surface = null;
            return;
        };
        out.lock_surface = ls;
        _ = c.ext_session_lock_surface_v1_add_listener(ls, &lock_surface_listener, out);
    }

    pub fn renderOutput(self: *LockApp, out: *LockOutput) void {
        if (!out.configured or out.width == 0 or out.height == 0) return;
        const surf = out.surface orelse return;
        const scale = if (out.scale == 0) 1 else out.scale;

        const phys_w = out.width * scale;
        const phys_h = out.height * scale;

        if (out.pool == null) {
            const shm = self.shm orelse return;
            out.pool = buffer.BufferPool.init(shm);
        }
        const buf = out.pool.?.getNextBuffer(phys_w, phys_h) catch return;
        const pixels: [*]u32 = buf.data orelse return;
        const stride = phys_w * 4;

        const target = renderer.Renderer.init(pixels, phys_w, phys_h, stride) catch return;

        // Draw wallpaper (cover scaled) or fallback gradient
        if (self.wallpaper_img) |img| {
            self.drawWallpaper(target, img, phys_w, phys_h);
        } else {
            self.drawFallbackBackground(target, phys_w, phys_h);
        }

        // Dark overlay for subtle contrast while keeping wallpaper vibrant
        target.fillRect(0, 0, phys_w, phys_h, Color.init(55, 0, 0, 0));

        // Subtle animated decorative glyphs
        self.drawDecorativeGlyphs(target, phys_w, phys_h);

        // Foreground HUD (clock, date, username, visible styled password box, caps-lock warning, error)
        self.drawClayHud(target, phys_w, phys_h, scale);

        buf.busy = true;
        c.wl_surface_set_buffer_scale(surf, @intCast(scale));
        c.wl_surface_attach(surf, buf.buffer.?, 0, 0);
        c.wl_surface_damage_buffer(surf, 0, 0, @intCast(phys_w), @intCast(phys_h));
        c.wl_surface_commit(surf);
    }

    pub fn renderAllOutputs(self: *LockApp) void {
        for (self.outputs.items) |out| {
            self.renderOutput(out);
        }
    }

    fn drawWallpaper(self: *LockApp, target: renderer.Renderer, img: *Image, width: u32, height: u32) void {
        _ = self;
        if (img.width == width and img.height == height) {
            @memcpy(target.pixels[0 .. width * height], img.pixels[0 .. width * height]);
        } else {
            const scale_x = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(img.width));
            const scale_y = @as(f32, @floatFromInt(height)) / @as(f32, @floatFromInt(img.height));
            const scale = @max(scale_x, scale_y);
            const src_w = @as(u32, @intFromFloat(@as(f32, @floatFromInt(width)) / scale));
            const src_h = @as(u32, @intFromFloat(@as(f32, @floatFromInt(height)) / scale));
            const src_x = if (img.width > src_w) (img.width - src_w) / 2 else 0;
            const src_y = if (img.height > src_h) (img.height - src_h) / 2 else 0;

            var dy: u32 = 0;
            while (dy < height) : (dy += 1) {
                const sy = @min(src_y + @as(u32, @intFromFloat(@as(f32, @floatFromInt(dy)) / scale)), img.height - 1);
                var dx: u32 = 0;
                while (dx < width) : (dx += 1) {
                    const sx = @min(src_x + @as(u32, @intFromFloat(@as(f32, @floatFromInt(dx)) / scale)), img.width - 1);
                    const idx = dy * width + dx;
                    const src_idx = sy * img.width + sx;
                    target.pixels[idx] = img.pixels[src_idx];
                }
            }
        }
    }

    fn drawFallbackBackground(self: *LockApp, target: renderer.Renderer, width: u32, height: u32) void {
        const bg_base = self.cfg.theme.base;
        var y: i32 = 0;
        while (y < @as(i32, @intCast(height))) : (y += 1) {
            const t = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(height));
            const r = @as(u8, @intFromFloat(@max(0.0, @min(255.0, @as(f32, @floatFromInt(bg_base.r)) * 0.7 + t * 25.0))));
            const g = @as(u8, @intFromFloat(@max(0.0, @min(255.0, @as(f32, @floatFromInt(bg_base.g)) * 0.7 + t * 20.0))));
            const b = @as(u8, @intFromFloat(@max(0.0, @min(255.0, @as(f32, @floatFromInt(bg_base.b)) * 0.7 + t * 35.0))));
            target.fillRect(0, y, width, 1, Color.rgb(r, g, b));
        }
    }

    fn drawDecorativeGlyphs(self: *LockApp, target: renderer.Renderer, width: u32, height: u32) void {
        const glyphs = [_][]const u8{
            "", "󰝨", "", "󰴈", "󰧱", "󱎂", "", "", "", "", "", "󰢘",
        };
        const color = Color.init(45, 180, 180, 200);

        var glyph_font = self.glyph_font orelse return;
        const center_x = @as(i32, @intCast(width / 2));
        const center_y = @as(i32, @intCast(height / 2));

        const radius = @as(f32, @floatFromInt(@min(width, height))) * 0.35;
        const count = glyphs.len;
        const time_factor = self.glyph_anim_offset;

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const angle = (@as(f32, @floatFromInt(i)) * 2.0 * std.math.pi / @as(f32, @floatFromInt(count))) + time_factor * 0.15;
            const gx = center_x + @as(i32, @intFromFloat(radius * @cos(angle)));
            const gy = center_y + @as(i32, @intFromFloat(radius * @sin(angle)));

            var alpha: u8 = 40;
            const pulse = @sin(time_factor * 2.0 + @as(f32, @floatFromInt(i)) * 0.5) * 0.3 + 0.7;
            alpha = @as(u8, @intFromFloat(@as(f32, alpha) * pulse));

            const glyph_color = Color.init(alpha, color.r, color.g, color.b);
            const glyph = glyphs[i];

            const extents = (&glyph_font).measureInk(glyph, 48);
            const gx_centered = gx - @as(i32, @intCast(extents.width / 2)) - extents.left;
            const gy_centered = gy + @as(i32, @intCast(extents.width / 4));

            self.drawTextWithFont(target, &glyph_font, glyph, gx_centered, gy_centered, 48, glyph_color);
        }
    }

pub const LOCK_GLYPH_POOL = [_][]const u8{
    "󰧱", // Sparkle 4-point
    "", // Five point star
    "󰝨", // Diamond sparkle
    "", // Quatrefoil
    "󰄛", // Diamond rhomb
    "󰴈", // Eight-point star
    "󰢘", // Geometric node
    "", // Flower sparkle
    "󱎂", // Star flower
    "󰹑", // Starburst
    "", // Clover star
    "", // Diamond point
};

fn splitmix64(seed: u64) u64 {
    var z = seed +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

    fn drawClayHud(self: *LockApp, target: renderer.Renderer, width: u32, height: u32, out_scale: u32) void {
        const font = if (self.font) |*f| f else return;
        const scale = if (out_scale == 0) 1 else out_scale;

        const now = c.time(null);
        var tm: c.struct_tm = undefined;
        _ = c.localtime_r(&now, &tm);

        const hour: u32 = @intCast(@max(0, tm.tm_hour));
        const min: u32 = @intCast(@max(0, tm.tm_min));
        var time_buf: [16]u8 = undefined;
        const time_str = std.fmt.bufPrint(&time_buf, "{d:0>2}:{d:0>2}", .{ hour, min }) catch "00:00";

        const day_names = [_][]const u8{
            "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
        };
        const month_names = [_][]const u8{
            "January", "February", "March", "April", "May", "June",
            "July", "August", "September", "October", "November", "December",
        };
        const wday_idx: usize = if (tm.tm_wday >= 0 and tm.tm_wday < 7) @intCast(tm.tm_wday) else 0;
        const mon_idx: usize = if (tm.tm_mon >= 0 and tm.tm_mon < 12) @intCast(tm.tm_mon) else 0;
        const wday = day_names[wday_idx];
        const mon = month_names[mon_idx];
        var date_buf: [64]u8 = undefined;
        const date_full = std.fmt.bufPrint(&date_buf, "{s}, {s} {}, {}", .{ wday, mon, tm.tm_mday, tm.tm_year + 1900 }) catch "";

        var ui = ui_mod.Ui.begin(
            self.allocator,
            font,
            width,
            height,
            scale,
            -1,
            -1,
            false,
            1.0 / 60.0,
        ) catch return;
        defer ui.deinit();

        ui.root(.{
            .direction = .column,
            .align_x = .center,
            .align_y = .center,
            .gap = ui.su(6),
        });
        ui.spacerSized(.{ .fixed = 0 }, .{ .grow = .{} });

        // Digital Clock
        ui.text(time_str, .{
            .size = 100 * scale,
            .color = Color.rgb(255, 255, 255),
            .line_height = @intCast(104 * scale),
        });

        // Date
        ui.text(date_full, .{
            .size = 18 * scale,
            .color = Color.init(230, 255, 255, 255),
        });

        ui.spacerSized(.{ .fixed = 0 }, .{ .fixed = ui.s(32) });

        if (!self.show_input and self.auth_state == .idle) {
            // Idle state: Clean minimal lock screen with subtle unlock hint
            _ = ui.open(.{
                .direction = .row,
                .align_x = .center,
                .align_y = .center,
            });
            ui.text("Type to unlock", .{
                .size = 15 * scale,
                .color = Color.init(180, 255, 255, 255),
            });
            ui.close();

            // Spacer for balanced vertical centering
            ui.spacerSized(.{ .fixed = 0 }, .{ .fixed = ui.s(60) });
        } else {
            // Active input state: Show input box with nice glyphs as the user types
            const box_w: f32 = @floatFromInt(340 * scale);
            const box_h: f32 = @floatFromInt(54 * scale);
            const border_w: u16 = if (self.auth_state == .failed) 2 else 1;
            const border_col = if (self.auth_state == .failed)
                Color.rgb(235, 87, 87)
            else if (self.auth_state == .authenticating)
                self.cfg.theme.accent
            else
                Color.init(180, 255, 255, 255);

            _ = ui.open(.{
                .width = .{ .fixed = box_w },
                .height = .{ .fixed = box_h },
                .direction = .row,
                .align_x = .center,
                .align_y = .center,
                .padding = .{
                    .left = @intCast(20 * scale),
                    .right = @intCast(20 * scale),
                    .top = @intCast(6 * scale),
                    .bottom = @intCast(6 * scale),
                },
                .gap = @intCast(8 * scale),
                .bg = Color.init(190, 18, 22, 32),
                .radius = box_h / 2.0,
                .border = border_w,
                .border_color = border_col,
            });

            if (self.auth_state == .authenticating) {
                ui.text("Verifying...", .{
                    .size = 15 * scale,
                    .color = Color.init(230, 255, 255, 255),
                });
            } else {
                // Render aesthetic randomized glyphs with large font for typed password characters
                var glyph_buf: [512]u8 = undefined;
                var g_pos: usize = 0;
                const max_glyphs: usize = 14;
                const visible_count = @min(self.password_len, max_glyphs);
                var prev_idx: usize = 255;
                var i: usize = 0;
                while (i < visible_count) : (i += 1) {
                    const seed = self.rng_seed +% @as(u64, @intCast(i)) *% 0xBF58476D1CE4E5B9 +% @as(u64, self.password_buf[i]);
                    var idx = @as(usize, @intCast(splitmix64(seed) % LOCK_GLYPH_POOL.len));
                    if (i > 0 and idx == prev_idx) {
                        idx = (idx + 1) % LOCK_GLYPH_POOL.len;
                    }
                    prev_idx = idx;
                    const symbol = LOCK_GLYPH_POOL[idx];

                    if (i > 0) {
                        const sep = "  ";
                        if (g_pos + sep.len <= glyph_buf.len) {
                            @memcpy(glyph_buf[g_pos .. g_pos + sep.len], sep);
                            g_pos += sep.len;
                        }
                    }
                    if (g_pos + symbol.len <= glyph_buf.len) {
                        @memcpy(glyph_buf[g_pos .. g_pos + symbol.len], symbol);
                        g_pos += symbol.len;
                    }
                }

                if (g_pos > 0) {
                    ui.text(glyph_buf[0..g_pos], .{
                        .size = 24 * scale,
                        .color = Color.rgb(255, 255, 255),
                    });
                }
            }
            ui.close(); // input box

            // Status feedback below the input box
            if (self.auth_state == .failed) {
                ui.spacerSized(.{ .fixed = 0 }, .{ .fixed = ui.s(10) });
                _ = ui.open(.{
                    .direction = .row,
                    .align_x = .center,
                    .align_y = .center,
                    .gap = ui.su(6),
                });
                ui.text("", .{
                    .size = 14 * scale,
                    .color = Color.rgb(235, 87, 87),
                });
                ui.text("Incorrect password", .{
                    .size = 13 * scale,
                    .color = Color.rgb(235, 87, 87),
                });
                ui.close();
            } else if (self.caps_lock_active) {
                ui.spacerSized(.{ .fixed = 0 }, .{ .fixed = ui.s(10) });
                _ = ui.open(.{
                    .direction = .row,
                    .align_x = .center,
                    .align_y = .center,
                    .gap = ui.su(6),
                });
                ui.text("󰘲", .{
                    .size = 14 * scale,
                    .color = Color.rgb(245, 180, 60),
                });
                ui.text("Caps Lock is ON", .{
                    .size = 13 * scale,
                    .color = Color.rgb(245, 180, 60),
                });
                ui.close();
            } else {
                ui.spacerSized(.{ .fixed = 0 }, .{ .fixed = ui.s(24) });
            }
        }

        ui.spacerSized(.{ .fixed = 0 }, .{ .grow = .{} });
        ui.close();

        const commands = ui.endLayout();
        ui.render(target, commands);
    }

    fn drawTextWithFont(self: *LockApp, target: renderer.Renderer, font: *Font, text: []const u8, x: i32, y: i32, size: u32, color: Color) void {
        _ = self;
        if (text.len == 0) return;
        var pen_x = x;
        var utf8_view = std.unicode.Utf8View.init(text) catch return;
        var it = utf8_view.iterator();
        while (it.nextCodepoint()) |cp| {
            if (font.getOrLoadGlyph(cp, size)) |cg| {
                if (cg.width > 0 and cg.height > 0) {
                    const gx = pen_x + cg.left;
                    const gy = y - cg.top;
                    drawGlyphBitmap(target, cg, gx, gy, color);
                }
                pen_x += cg.advance_x;
            } else {
                pen_x += @as(i32, @intCast(size / 2));
            }
        }
    }

    fn drawGlyphBitmap(target: renderer.Renderer, cg: renderer.CachedGlyph, x: i32, y: i32, color: Color) void {
        if (cg.width == 0 or cg.height == 0) return;
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
};

fn authWorker(self: *LockApp, mut_ctx: AuthContext) void {
    var ctx = mut_ctx;
    defer {
        @memset(&ctx.password, 0);
    }
    const user_z: [:0]const u8 = std.mem.span(@as([*c]const u8, @ptrCast(&ctx.username)));
    const pass_z: [:0]const u8 = std.mem.span(@as([*c]const u8, @ptrCast(&ctx.password)));
    const ok = self.auth_fn(user_z, pass_z);

    self.auth_success.store(ok, .release);
    self.auth_finished.store(true, .release);
}

pub fn authenticatePAM(username: [:0]const u8, password: [:0]const u8) bool {
    var pamh: ?*c.pam_handle_t = null;
    var conv: c.struct_pam_conv = .{
        .conv = pamConv,
        .appdata_ptr = @ptrCast(@constCast(password.ptr)),
    };

    const services = [_][:0]const u8{ "mizu", "swaylock", "login", "system-auth" };
    for (services) |service| {
        pamh = null;
        const ret = c.pam_start(service.ptr, username.ptr, &conv, &pamh);
        if (ret != c.PAM_SUCCESS or pamh == null) continue;

        const auth_ret = c.pam_authenticate(pamh.?, 0);
        if (auth_ret == c.PAM_SUCCESS) {
            _ = c.pam_setcred(pamh.?, c.PAM_REFRESH_CRED);
            _ = c.pam_end(pamh.?, c.PAM_SUCCESS);
            return true;
        }
        _ = c.pam_end(pamh.?, auth_ret);
    }
    return false;
}

pub fn pamConv(
    num_msg: c_int,
    msg: [*c][*c]const c.struct_pam_message,
    resp: [*c][*c]c.struct_pam_response,
    appdata_ptr: ?*anyopaque,
) callconv(.c) c_int {
    if (num_msg <= 0 or msg == null or resp == null) return c.PAM_CONV_ERR;

    const count: usize = @intCast(num_msg);
    const reply_mem = c.calloc(count, @sizeOf(c.struct_pam_response));
    if (reply_mem == null) return c.PAM_BUF_ERR;

    const replies: [*c]c.struct_pam_response = @ptrCast(@alignCast(reply_mem));
    const pw: [*c]const u8 = if (appdata_ptr) |ptr| @ptrCast(ptr) else null;

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const m = msg[i];
        if (m == null) continue;
        const style = m.*.msg_style;
        if (style == c.PAM_PROMPT_ECHO_OFF or style == c.PAM_PROMPT_ECHO_ON) {
            if (pw != null) {
                replies[i].resp = c.strdup(pw);
                if (replies[i].resp == null) {
                    var j: usize = 0;
                    while (j < i) : (j += 1) {
                        if (replies[j].resp != null) {
                            const s = std.mem.span(replies[j].resp);
                            @memset(s, 0);
                            c.free(replies[j].resp);
                        }
                    }
                    c.free(replies);
                    return c.PAM_BUF_ERR;
                }
            } else {
                replies[i].resp = null;
            }
            replies[i].resp_retcode = 0;
        } else {
            replies[i].resp = null;
            replies[i].resp_retcode = 0;
        }
    }

    resp.* = replies;
    return c.PAM_SUCCESS;
}

// Active desktop wallpaper detection
fn loadActiveWallpaper(allocator: std.mem.Allocator, cfg: config.Config) ?*Image {
    if (cfg.wallpaper) |wpath| {
        if (wpath.len > 0) {
            if (Image.loadFile(allocator, wpath)) |img| return img else |_| {}
        }
    }
    const home = c.getenv("HOME") orelse return null;
    const home_str = std.mem.span(home);

    const cache_paths = [_][]const u8{
        "/.cache/wm/current_wallpaper",
        "/.cache/current_wallpaper",
    };
    for (cache_paths) |cp| {
        const full_path_slice = std.fmt.allocPrint(allocator, "{s}{s}", .{ home_str, cp }) catch continue;
        defer allocator.free(full_path_slice);
        const full_path_z = allocator.dupeZ(u8, full_path_slice) catch continue;
        defer allocator.free(full_path_z);

        const f = c.fopen(full_path_z.ptr, "r") orelse continue;
        defer _ = c.fclose(f);

        var buf: [512]u8 = undefined;
        const n = c.fread(&buf, 1, buf.len - 1, f);
        if (n > 0) {
            buf[n] = 0;
            const wall_path = std.mem.trim(u8, buf[0..n], " \r\n\t");
            if (wall_path.len > 0) {
                if (Image.loadFile(allocator, wall_path)) |img| return img else |_| {}
            }
        }
    }
    return null;
}

// Wayland listeners
const registry_listener = c.wl_registry_listener{
    .global = registry_global,
    .global_remove = registry_global_remove,
};

fn registry_global(data: ?*anyopaque, reg: ?*c.wl_registry, name: u32, iface: [*c]const u8, ver: u32) callconv(.c) void {
    const self: *LockApp = @ptrCast(@alignCast(data.?));
    const s = std.mem.span(iface);
    if (std.mem.eql(u8, s, "wl_compositor")) {
        self.compositor = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_compositor_interface, @min(ver, 4)));
    } else if (std.mem.eql(u8, s, "wl_shm")) {
        self.shm = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_shm_interface, 1));
    } else if (std.mem.eql(u8, s, "wl_seat")) {
        self.seat = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_seat_interface, @min(ver, 5)));
        if (self.seat) |st| {
            _ = c.wl_seat_add_listener(st, &seat_listener, @ptrCast(self));
        }
    } else if (std.mem.eql(u8, s, "wl_output")) {
        const out_obj: ?*c.wl_output = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_output_interface, @min(ver, 4)));
        if (out_obj) |wo| {
            const out_ptr = self.allocator.create(LockOutput) catch return;
            out_ptr.* = LockOutput{
                .app = self,
                .output = wo,
                .global_name = name,
            };
            self.outputs.append(self.allocator, out_ptr) catch {
                self.allocator.destroy(out_ptr);
                c.wl_output_destroy(wo);
                return;
            };
            _ = c.wl_output_add_listener(wo, &output_listener, self);
            if (self.session_lock != null and self.compositor != null) {
                self.createLockSurfaceForOutput(out_ptr);
            }
        }
    } else if (std.mem.eql(u8, s, "ext_session_lock_manager_v1")) {
        self.session_lock_mgr = @ptrCast(c.wl_registry_bind(reg, name, &c.ext_session_lock_manager_v1_interface, 1));
    }
}

fn registry_global_remove(data: ?*anyopaque, reg: ?*c.wl_registry, name: u32) callconv(.c) void {
    _ = reg;
    const self: *LockApp = @ptrCast(@alignCast(data.?));
    var idx: usize = 0;
    while (idx < self.outputs.items.len) {
        const out = self.outputs.items[idx];
        if (out.global_name == name) {
            _ = self.outputs.orderedRemove(idx);
            out.deinit();
            self.allocator.destroy(out);
        } else {
            idx += 1;
        }
    }
}

fn output_geometry(data: ?*anyopaque, wl_out: ?*c.wl_output, x: i32, y: i32, physical_width: i32, physical_height: i32, subpixel: i32, make: [*c]const u8, model: [*c]const u8, transform: i32) callconv(.c) void {
    _ = data; _ = wl_out; _ = x; _ = y; _ = physical_width; _ = physical_height; _ = subpixel; _ = make; _ = model; _ = transform;
}

fn output_mode(data: ?*anyopaque, wl_out: ?*c.wl_output, flags: u32, width: i32, height: i32, refresh: i32) callconv(.c) void {
    _ = data; _ = wl_out; _ = flags; _ = width; _ = height; _ = refresh;
}

fn output_done(data: ?*anyopaque, wl_out: ?*c.wl_output) callconv(.c) void {
    _ = data; _ = wl_out;
}

fn output_name(data: ?*anyopaque, wl_out: ?*c.wl_output, name: [*c]const u8) callconv(.c) void {
    _ = data; _ = wl_out; _ = name;
}

fn output_description(data: ?*anyopaque, wl_out: ?*c.wl_output, desc: [*c]const u8) callconv(.c) void {
    _ = data; _ = wl_out; _ = desc;
}

fn output_scale(data: ?*anyopaque, wl_out: ?*c.wl_output, factor: i32) callconv(.c) void {
    const self: *LockApp = @ptrCast(@alignCast(data.?));
    for (self.outputs.items) |out| {
        if (out.output == wl_out) {
            if (factor > 0) {
                out.scale = @as(u32, @intCast(factor));
                if (out.configured) {
                    self.renderOutput(out);
                    if (self.display) |disp| {
                        _ = c.wl_display_flush(disp);
                    }
                }
            }
            break;
        }
    }
}

const output_listener = c.wl_output_listener{
    .geometry = output_geometry,
    .mode = output_mode,
    .done = output_done,
    .scale = output_scale,
    .name = output_name,
    .description = output_description,
};

const seat_listener = c.wl_seat_listener{
    .capabilities = seat_capabilities,
    .name = seat_name,
};

fn seat_capabilities(data: ?*anyopaque, seat: ?*c.wl_seat, capabilities: u32) callconv(.c) void {
    const self: *LockApp = @ptrCast(@alignCast(data.?));
    const has_keyboard = (capabilities & c.WL_SEAT_CAPABILITY_KEYBOARD) != 0;
    if (has_keyboard and self.keyboard == null) {
        self.keyboard = c.wl_seat_get_keyboard(seat);
        if (self.keyboard) |kbd| {
            _ = c.wl_keyboard_add_listener(kbd, &keyboard_listener, self);
        }
    } else if (!has_keyboard and self.keyboard != null) {
        c.wl_keyboard_destroy(self.keyboard.?);
        self.keyboard = null;
    }

    const has_pointer = (capabilities & c.WL_SEAT_CAPABILITY_POINTER) != 0;
    if (has_pointer and self.pointer == null) {
        self.pointer = c.wl_seat_get_pointer(seat);
        if (self.pointer) |ptr| {
            _ = c.wl_pointer_add_listener(ptr, &pointer_listener, self);
        }
    } else if (!has_pointer and self.pointer != null) {
        c.wl_pointer_destroy(self.pointer.?);
        self.pointer = null;
    }
}

fn seat_name(data: ?*anyopaque, seat: ?*c.wl_seat, name: [*c]const u8) callconv(.c) void {
    _ = data; _ = seat; _ = name;
}

const session_listener = c.ext_session_lock_v1_listener{
    .locked = session_locked,
    .finished = session_finished,
};

fn session_locked(data: ?*anyopaque, sl: ?*c.ext_session_lock_v1) callconv(.c) void {
    _ = sl;
    const self: *LockApp = @ptrCast(@alignCast(data.?));
    self.is_locked = true;
    self.needs_redraw = true;
}

fn session_finished(data: ?*anyopaque, sl: ?*c.ext_session_lock_v1) callconv(.c) void {
    _ = sl;
    const self: *LockApp = @ptrCast(@alignCast(data.?));
    self.is_finished = true;
    self.running = false;
}

// Pointer listener
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
};

fn pointer_enter(data: ?*anyopaque, pointer: ?*c.wl_pointer, serial: u32, surface: ?*c.wl_surface, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
    _ = data; _ = surface; _ = sx; _ = sy;
    if (pointer) |p| {
        c.wl_pointer_set_cursor(p, serial, null, 0, 0);
    }
}

fn pointer_leave(data: ?*anyopaque, pointer: ?*c.wl_pointer, serial: u32, surface: ?*c.wl_surface) callconv(.c) void {
    _ = data; _ = pointer; _ = serial; _ = surface;
}

fn pointer_motion(data: ?*anyopaque, pointer: ?*c.wl_pointer, time: u32, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
    _ = data; _ = pointer; _ = time; _ = sx; _ = sy;
}

fn pointer_button(data: ?*anyopaque, pointer: ?*c.wl_pointer, serial: u32, time: u32, button: u32, state: u32) callconv(.c) void {
    _ = pointer; _ = serial; _ = time; _ = button;
    const self: *LockApp = @ptrCast(@alignCast(data.?));
    if (state == c.WL_POINTER_BUTTON_STATE_PRESSED) {
        self.needs_redraw = true;
    }
}

fn pointer_axis(data: ?*anyopaque, pointer: ?*c.wl_pointer, time: u32, axis: u32, value: c.wl_fixed_t) callconv(.c) void {
    _ = data; _ = pointer; _ = time; _ = axis; _ = value;
}

fn pointer_frame(data: ?*anyopaque, pointer: ?*c.wl_pointer) callconv(.c) void {
    _ = data; _ = pointer;
}

fn pointer_axis_source(data: ?*anyopaque, pointer: ?*c.wl_pointer, axis_source: u32) callconv(.c) void {
    _ = data; _ = pointer; _ = axis_source;
}

fn pointer_axis_stop(data: ?*anyopaque, pointer: ?*c.wl_pointer, time: u32, axis: u32) callconv(.c) void {
    _ = data; _ = pointer; _ = time; _ = axis;
}

fn pointer_axis_discrete(data: ?*anyopaque, pointer: ?*c.wl_pointer, axis: u32, discrete: i32) callconv(.c) void {
    _ = data; _ = pointer; _ = axis; _ = discrete;
}

// Keyboard listener
fn keyboard_repeat_info(data: ?*anyopaque, kbd: ?*c.wl_keyboard, rate: i32, delay: i32) callconv(.c) void {
    _ = data; _ = kbd; _ = rate; _ = delay;
}

const keyboard_listener = c.wl_keyboard_listener{
    .keymap = keyboard_keymap,
    .enter = keyboard_enter,
    .leave = keyboard_leave,
    .key = keyboard_key,
    .modifiers = keyboard_modifiers,
    .repeat_info = keyboard_repeat_info,
};

fn keyboard_keymap(data: ?*anyopaque, kbd: ?*c.wl_keyboard, format: u32, fd: c_int, size: u32) callconv(.c) void {
    _ = kbd;
    const self: *LockApp = @ptrCast(@alignCast(data.?));
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

    if (self.xkb_ctx == null) {
        self.xkb_ctx = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
    }
    if (self.xkb_ctx == null) return;

    const map_str: [*c]const u8 = @ptrCast(map_shm);
    const keymap_len: usize = if (size > 0 and map_str[size - 1] == 0) size - 1 else size;
    const keymap = c.xkb_keymap_new_from_buffer(self.xkb_ctx.?, map_str, keymap_len, c.XKB_KEYMAP_FORMAT_TEXT_V1, c.XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (keymap == null) return;

    const state = c.xkb_state_new(keymap);
    if (state == null) {
        c.xkb_keymap_unref(keymap);
        return;
    }

    if (self.xkb_state) |st| c.xkb_state_unref(st);
    if (self.xkb_keymap) |km| c.xkb_keymap_unref(km);
    self.xkb_keymap = keymap;
    self.xkb_state = state;
}

fn keyboard_enter(data: ?*anyopaque, kbd: ?*c.wl_keyboard, serial: u32, surf: ?*c.wl_surface, keys: [*c]c.wl_array) callconv(.c) void {
    _ = kbd; _ = serial; _ = surf; _ = keys;
    const self: *LockApp = @ptrCast(@alignCast(data.?));
    self.has_kbd_focus = true;
    self.needs_redraw = true;
}

fn keyboard_leave(data: ?*anyopaque, kbd: ?*c.wl_keyboard, serial: u32, surf: ?*c.wl_surface) callconv(.c) void {
    _ = kbd; _ = serial; _ = surf;
    const self: *LockApp = @ptrCast(@alignCast(data.?));
    self.has_kbd_focus = false;
}

fn keyboard_key(data: ?*anyopaque, kbd: ?*c.wl_keyboard, serial: u32, time: u32, key: u32, state: u32) callconv(.c) void {
    _ = kbd; _ = serial; _ = time;
    const self: *LockApp = @ptrCast(@alignCast(data.?));
    self.handleKey(key, state);
}

fn keyboard_modifiers(data: ?*anyopaque, kbd: ?*c.wl_keyboard, serial: u32, mods_depressed: u32, mods_latched: u32, mods_locked: u32, group: u32) callconv(.c) void {
    _ = kbd; _ = serial;
    const self: *LockApp = @ptrCast(@alignCast(data.?));
    if (self.xkb_state) |st| {
        _ = c.xkb_state_update_mask(st, mods_depressed, mods_latched, mods_locked, 0, 0, group);
        const caps = c.xkb_state_mod_name_is_active(st, c.XKB_MOD_NAME_CAPS, c.XKB_STATE_MODS_EFFECTIVE) > 0;
        if (self.caps_lock_active != caps) {
            self.caps_lock_active = caps;
            self.needs_redraw = true;
        }
    }
}

// Lock surface listener
const lock_surface_listener = c.ext_session_lock_surface_v1_listener{
    .configure = lock_surface_configure,
};

fn lock_surface_configure(data: ?*anyopaque, ls: ?*c.ext_session_lock_surface_v1, serial: u32, width: u32, height: u32) callconv(.c) void {
    const out: *LockOutput = @ptrCast(@alignCast(data.?));
    out.width = width;
    out.height = height;
    c.ext_session_lock_surface_v1_ack_configure(ls, serial);
    out.configured = true;
    // Commit initial buffer immediately so compositor sends locked event and maps surface
    out.app.renderOutput(out);
    if (out.app.display) |disp| {
        _ = c.wl_display_flush(disp);
    }
}

pub fn runLock(allocator: std.mem.Allocator, cfg: config.Config) !void {
    var app = try LockApp.init(allocator, cfg);
    defer app.deinit();

    const disp = c.wl_display_connect(null) orelse return error.ConnectFailed;
    app.display = disp;

    // Get current user for PAM: first try getpwuid(getuid()), fallback to getenv("USER")
    var user_found = false;
    if (c.getpwuid(c.getuid())) |pw| {
        if (pw.*.pw_name != null) {
            const u = std.mem.span(pw.*.pw_name);
            const len = @min(u.len, app.auth_username.len - 1);
            @memcpy(app.auth_username[0..len], u[0..len]);
            app.auth_username[len] = 0;
            app.auth_username_len = len;
            user_found = true;
        }
    }
    if (!user_found) {
        if (c.getenv("USER")) |user| {
            const u = std.mem.span(user);
            const len = @min(u.len, app.auth_username.len - 1);
            @memcpy(app.auth_username[0..len], u[0..len]);
            app.auth_username[len] = 0;
            app.auth_username_len = len;
        }
    }

    app.timer_fd = c.timerfd_create(c.CLOCK_MONOTONIC, c.TFD_CLOEXEC | c.TFD_NONBLOCK);
    if (app.timer_fd >= 0) {
        var its: c.struct_itimerspec = .{
            .it_interval = .{ .tv_sec = 0, .tv_nsec = 500_000_000 },
            .it_value = .{ .tv_sec = 0, .tv_nsec = 500_000_000 },
        };
        _ = c.timerfd_settime(app.timer_fd, 0, &its, null);
    }

    const reg = c.wl_display_get_registry(disp) orelse return error.RegistryFailed;
    app.registry = reg;

    _ = c.wl_registry_add_listener(reg, &registry_listener, &app);
    _ = c.wl_display_roundtrip(disp);

    if (app.compositor == null or app.shm == null or app.session_lock_mgr == null) {
        return error.ProtocolMissing;
    }

    const sl = c.ext_session_lock_manager_v1_lock(app.session_lock_mgr.?) orelse return error.LockFailed;
    app.session_lock = sl;
    _ = c.ext_session_lock_v1_add_listener(sl, &session_listener, &app);

    // Load active wallpaper from config or system cache
    app.wallpaper_img = loadActiveWallpaper(allocator, cfg);

    // Immediately create lock surfaces for all outputs discovered so far
    for (app.outputs.items) |out| {
        app.createLockSurfaceForOutput(out);
    }
    _ = c.wl_display_roundtrip(disp);

    // Wait for the compositor to lock the session
    while (app.running and !app.is_locked and !app.is_finished) {
        if (c.wl_display_dispatch(disp) < 0) break;
        if (app.needs_redraw) {
            app.needs_redraw = false;
            app.renderAllOutputs();
            _ = c.wl_display_flush(disp);
        }
    }
    if (!app.is_locked) {
        return error.SessionLockFailed;
    }

    // Render initial frame to all configured surfaces
    app.renderAllOutputs();
    _ = c.wl_display_flush(disp);

    // Main event loop
    while (app.running and !app.is_finished) {
        while (c.wl_display_prepare_read(disp) != 0) {
            _ = c.wl_display_dispatch_pending(disp);
        }
        _ = c.wl_display_flush(disp);

        const fd = c.wl_display_get_fd(disp);
        var pfd = [_]c.struct_pollfd{
            .{ .fd = fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (app.timer_fd >= 0) app.timer_fd else -1, .events = c.POLLIN, .revents = 0 },
        };
        const pr = c.poll(&pfd, pfd.len, 50);
        if (pr < 0) {
            c.wl_display_cancel_read(disp);
            continue;
        }

        if ((pfd[0].revents & (c.POLLHUP | c.POLLERR)) != 0) {
            c.wl_display_cancel_read(disp);
            break;
        }

        if ((pfd[0].revents & c.POLLIN) != 0) {
            _ = c.wl_display_read_events(disp);
        } else {
            c.wl_display_cancel_read(disp);
        }
        _ = c.wl_display_dispatch_pending(disp);

        // Timer tick for caret blinking and glyph animation
        if (app.timer_fd >= 0 and (pfd[1].revents & c.POLLIN) != 0) {
            var val: u64 = 0;
            _ = c.read(app.timer_fd, &val, @sizeOf(u64));
            app.caret_blink = !app.caret_blink;
            app.glyph_anim_offset += 0.02;
            app.needs_redraw = true;
        }

        // Check authentication results from worker thread
        app.checkAuthResult();

        if (app.auth_state == .success) {
            break;
        }

        if (app.needs_redraw) {
            app.needs_redraw = false;
            app.renderAllOutputs();
            _ = c.wl_display_flush(disp);
        }
    }

    // Only unlock after successful authentication
    if (app.is_locked and app.auth_state == .success) {
        if (app.session_lock) |lock_obj| {
            c.ext_session_lock_v1_unlock_and_destroy(lock_obj);
            app.session_lock = null;
            _ = c.wl_display_roundtrip(disp);
        }
    }
}

// ---------------------------------------------------------------------------
// Unit & Integration Tests
// ---------------------------------------------------------------------------

test "pamConv correctly handles PAM conversation and responds with password" {
    const test_pass = "mypassword123";

    // 1. Single prompt ECHO_OFF
    var msg1 = c.struct_pam_message{
        .msg_style = c.PAM_PROMPT_ECHO_OFF,
        .msg = "Password: ",
    };
    var msg_list = [_][*c]const c.struct_pam_message{&msg1};
    var resp_ptr: [*c]c.struct_pam_response = null;

    const res = pamConv(1, &msg_list, &resp_ptr, @ptrCast(@constCast(test_pass.ptr)));
    try std.testing.expectEqual(@as(c_int, c.PAM_SUCCESS), res);
    try std.testing.expect(resp_ptr != null);
    try std.testing.expect(resp_ptr[0].resp != null);
    try std.testing.expectEqualStrings(test_pass, std.mem.span(resp_ptr[0].resp));
    try std.testing.expectEqual(@as(c_int, 0), resp_ptr[0].resp_retcode);

    c.free(resp_ptr[0].resp);
    c.free(resp_ptr);

    // 2. Info message: should receive null response
    var msg_info = c.struct_pam_message{
        .msg_style = c.PAM_TEXT_INFO,
        .msg = "Welcome",
    };
    var msg_info_list = [_][*c]const c.struct_pam_message{&msg_info};
    var resp_info: [*c]c.struct_pam_response = null;

    const res2 = pamConv(1, &msg_info_list, &resp_info, @ptrCast(@constCast(test_pass.ptr)));
    try std.testing.expectEqual(@as(c_int, c.PAM_SUCCESS), res2);
    try std.testing.expect(resp_info != null);
    try std.testing.expect(resp_info[0].resp == null);
    c.free(resp_info);

    // 3. Error conditions
    try std.testing.expectEqual(@as(c_int, c.PAM_CONV_ERR), pamConv(0, null, null, null));
    try std.testing.expectEqual(@as(c_int, c.PAM_CONV_ERR), pamConv(-1, null, null, null));
}

test "LockApp keyboard input handling, backspace, and modifiers" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var app = try LockApp.init(allocator, cfg);
    defer app.deinit();

    try std.testing.expectEqual(@as(usize, 0), app.password_len);
    try std.testing.expect(!app.show_input);
    try std.testing.expectEqual(AuthState.idle, app.auth_state);

    // Keycode 24 is 'q' on QWERTY (key index 16 + 8 = 24)
    app.handleKey(16, c.WL_KEYBOARD_KEY_STATE_PRESSED);
    try std.testing.expectEqual(@as(usize, 1), app.password_len);
    try std.testing.expect(app.show_input);
    try std.testing.expectEqual(@as(u8, 'q'), app.password_buf[0]);

    // Keycode 25 is 'w' (key index 17 + 8 = 25)
    app.handleKey(17, c.WL_KEYBOARD_KEY_STATE_PRESSED);
    try std.testing.expectEqual(@as(usize, 2), app.password_len);
    try std.testing.expectEqualStrings("qw", app.password_buf[0..2]);

    // Backspace (key index 14 + 8 = 22 -> KEY_BACKSPACE)
    app.handleKey(14, c.WL_KEYBOARD_KEY_STATE_PRESSED);
    try std.testing.expectEqual(@as(usize, 1), app.password_len);
    try std.testing.expect(app.show_input);
    try std.testing.expectEqualStrings("q", app.password_buf[0..1]);

    // Backspace again -> empty, show_input false
    app.handleKey(14, c.WL_KEYBOARD_KEY_STATE_PRESSED);
    try std.testing.expectEqual(@as(usize, 0), app.password_len);
    try std.testing.expect(!app.show_input);

    // Escape clears password and resets state
    app.handleKey(16, c.WL_KEYBOARD_KEY_STATE_PRESSED);
    try std.testing.expectEqual(@as(usize, 1), app.password_len);
    // Escape keycode 9 (key index 1 + 8 = 9)
    app.handleKey(1, c.WL_KEYBOARD_KEY_STATE_PRESSED);
    try std.testing.expectEqual(@as(usize, 0), app.password_len);
    try std.testing.expect(!app.show_input);
}

fn mockAuthSecret(username: [:0]const u8, password: [:0]const u8) bool {
    _ = username;
    return std.mem.eql(u8, password, "secret123");
}

test "LockApp complete flow: incorrect password rejected, correct password unlocks" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var app = try LockApp.init(allocator, cfg);
    defer app.deinit();

    app.auth_fn = mockAuthSecret;
    app.is_locked = true;

    // 1. Initial state: idle, no input shown
    try std.testing.expectEqual(AuthState.idle, app.auth_state);
    try std.testing.expect(!app.show_input);

    // 2. User types wrong password: "wrong"
    const wrong = "wrong";
    @memcpy(app.password_buf[0..wrong.len], wrong);
    app.password_len = wrong.len;
    app.show_input = true;

    // 3. Submit authentication
    app.submitAuth();
    try std.testing.expectEqual(AuthState.authenticating, app.auth_state);
    // Local password wiped immediately on submit
    try std.testing.expectEqual(@as(usize, 0), app.password_len);
    try std.testing.expect(!app.show_input);

    // Wait for thread to finish
    var attempts: usize = 0;
    while (!app.auth_finished.load(.acquire) and attempts < 100) : (attempts += 1) {
        _ = c.usleep(1_000);
    }
    app.checkAuthResult();

    // 4. Verification of failure
    try std.testing.expectEqual(AuthState.failed, app.auth_state);
    try std.testing.expect(app.is_locked);

    // 5. User starts typing again -> clears failed state
    app.handleKey(16, c.WL_KEYBOARD_KEY_STATE_PRESSED); // types 'q'
    try std.testing.expectEqual(AuthState.idle, app.auth_state);
    try std.testing.expect(app.show_input);
    app.wipePassword();

    // 6. User types correct password: "secret123"
    const correct = "secret123";
    @memcpy(app.password_buf[0..correct.len], correct);
    app.password_len = correct.len;
    app.show_input = true;

    // 7. Submit correct password
    app.submitAuth();
    try std.testing.expectEqual(AuthState.authenticating, app.auth_state);

    attempts = 0;
    while (!app.auth_finished.load(.acquire) and attempts < 100) : (attempts += 1) {
        _ = c.usleep(1_000);
    }
    app.checkAuthResult();

    // 8. Verification of success -> unlocks
    try std.testing.expectEqual(AuthState.success, app.auth_state);
}

test "LockApp multi-monitor output management" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var app = try LockApp.init(allocator, cfg);
    defer app.deinit();

    try std.testing.expectEqual(@as(usize, 0), app.outputs.items.len);

    // Verify safe deinit with empty outputs list
    app.renderAllOutputs();
}

test "LockApp drawClayHud renders without crash across states" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var app = try LockApp.init(allocator, cfg);
    defer app.deinit();

    const pixels = try allocator.alloc(u32, 1920 * 1080);
    defer allocator.free(pixels);
    @memset(pixels, 0);

    const target = try renderer.Renderer.init(pixels.ptr, 1920, 1080, 1920 * 4);

    // 1. Idle state with empty password (placeholder + caret)
    app.auth_state = .idle;
    app.password_len = 0;
    app.caret_blink = true;
    app.drawClayHud(target, 1920, 1080, 1);

    var non_zero: usize = 0;
    for (pixels) |px| {
        if (px != 0) non_zero += 1;
    }
    try std.testing.expect(non_zero > 0);

    // 2. Typing state with password dots
    const pass = "secret";
    @memcpy(app.password_buf[0..pass.len], pass);
    app.password_len = pass.len;
    app.show_input = true;
    app.drawClayHud(target, 1920, 1080, 1);

    // 3. Failed state with error message
    app.auth_state = .failed;
    app.drawClayHud(target, 1920, 1080, 1);

    // 4. Authenticating state
    app.auth_state = .authenticating;
    app.drawClayHud(target, 1920, 1080, 1);

    // 5. Caps lock on
    app.caps_lock_active = true;
    app.auth_state = .idle;
    app.drawClayHud(target, 1920, 1080, 1);
}

test "loadActiveWallpaper loads wallpaper without error" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    const img = loadActiveWallpaper(allocator, cfg);
    if (img) |im| {
        defer im.deinit();
        try std.testing.expect(im.width > 0);
        try std.testing.expect(im.height > 0);
    }
}
