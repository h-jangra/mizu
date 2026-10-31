const std = @import("std");
const c = @import("c");
const config = @import("../core/config.zig");
const theme = @import("../core/theme.zig");
const Color = theme.Color;
const renderer = @import("../core/renderer.zig");
const Font = renderer.Font;
const Image = renderer.Image;
const buffer = @import("../core/buffer.zig");

pub const AuthState = enum { idle, authenticating, failed, success };

pub const AuthContext = struct {
    username: [256]u8 = @splat(0),
    password: [128]u8 = @splat(0),
};

pub const LockOutput = struct {
    app: *LockApp,
    output: *c.wl_output,
    global_name: u32,
    surface: ?*c.wl_surface = null,
    lock_surface: ?*c.ext_session_lock_surface_v1 = null,
    pool: ?buffer.DoubleBufferPool = null,
    width: u32 = 0,
    height: u32 = 0,
    scale: u32 = 1,
    configured: bool = false,
    bg_cache: ?[]u32 = null,
    bg_cache_w: u32 = 0,
    bg_cache_h: u32 = 0,

    pub fn deinit(self: *LockOutput) void {
        if (self.bg_cache) |bg| {
            self.app.allocator.free(bg);
            self.bg_cache = null;
        }
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
    password_buf: [128]u8 = @splat(0),
    password_len: usize = 0,
    show_input: bool = false,
    needs_redraw: bool = true,
    timer_fd: c_int = -1,
    auth_username: [256]u8 = @splat(0),
    auth_username_len: usize = 0,
    caret_blink: bool = true,
    last_rendered_min: i32 = -1,
    rng_seed: u64 = 0x853c49e6748fea9b,
    xkb_ctx: ?*c.struct_xkb_context = null,
    xkb_keymap: ?*c.struct_xkb_keymap = null,
    xkb_state: ?*c.struct_xkb_state = null,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !LockApp {
        var app = LockApp{ .allocator = allocator, .cfg = cfg };
        app.rng_seed = @as(u64, @intCast(@max(1, c.time(null)))) *% 0x9E3779B97F4A7C15 +% 0x517cc1b727220a95;
        app.font = Font.init(allocator, cfg.theme.font_family, 16) catch
            (Font.init(allocator, "sans-serif, monospace", 16) catch null);
        app.xkb_ctx = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
        if (app.xkb_ctx) |ctx| {
            app.xkb_keymap = c.xkb_keymap_new_from_names(ctx, null, c.XKB_KEYMAP_COMPILE_NO_FLAGS);
            if (app.xkb_keymap) |km| {
                app.xkb_state = c.xkb_state_new(km);
            }
        }
        // Minimal glyph preload — only chars we actually draw (clock digits + mask + ghost).
        if (app.font) |*f| {
            const preload = "0123456789:AMPHpm 󰊠󰮯";
            if (std.unicode.Utf8View.init(preload)) |view| {
                var it = view.iterator();
                while (it.nextCodepoint()) |cp| {
                    _ = f.getOrLoadGlyph(cp, 16);
                    _ = f.getOrLoadGlyph(cp, 20);
                }
            } else |_| {}
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
        self.auth_state = if (self.auth_success.load(.acquire)) .success else .failed;
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
        // Submit
        if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_KP_Enter) {
            if (self.password_len > 0) {
                self.submitAuth();
            }
            return;
        }
        // Clear
        if (sym == c.XKB_KEY_Escape or (is_ctrl and (sym == c.XKB_KEY_u or sym == c.XKB_KEY_c))) {
            self.wipePassword();
            self.auth_state = .idle;
            self.needs_redraw = true;
            return;
        }
        // Backspace
        if (sym == c.XKB_KEY_BackSpace or (is_ctrl and (sym == c.XKB_KEY_w or sym == c.XKB_KEY_BackSpace))) {
            if (self.auth_state == .failed) self.auth_state = .idle;
            if (self.password_len > 0) {
                if (is_ctrl) {
                    self.wipePassword();
                } else {
                    var end = self.password_len;
                    while (end > 0) {
                        end -= 1;
                        const b = self.password_buf[end];
                        self.password_buf[end] = 0;
                        if ((b & 0xC0) != 0x80) break;
                    }
                    self.password_len = end;
                    self.show_input = (self.password_len > 0);
                }
                self.needs_redraw = true;
            }
            return;
        }
        if (is_ctrl) return;
        var utf8_buf: [32]u8 = @splat(0);
        const len = c.xkb_state_key_get_utf8(self.xkb_state.?, keycode, &utf8_buf, utf8_buf.len);
        if (len > 0) {
            const ulen: usize = @intCast(len);
            const slice = utf8_buf[0..ulen];
            if (slice[0] >= 32 and slice[0] != 127) {
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

        // 2-buffer pool for minimal memory footprint.
        if (out.pool == null) {
            const shm = self.shm orelse return;
            out.pool = buffer.DoubleBufferPool.init(shm);
        }
        const buf = out.pool.?.getNextBuffer(phys_w, phys_h) catch return;
        const pixels: [*]u32 = buf.data orelse return;
        const stride = phys_w * 4;
        const target = renderer.Renderer.init(pixels, phys_w, phys_h, stride) catch return;

        // Wallpaper cache: bake once, free decoded image, keep only the screen buffer.
        if (out.bg_cache == null or out.bg_cache_w != phys_w or out.bg_cache_h != phys_h) {
            if (out.bg_cache) |bg| {
                self.allocator.free(bg);
                out.bg_cache = null;
            }
            if (self.wallpaper_img) |img| {
                const new_bg = self.allocator.alloc(u32, phys_w * phys_h) catch {
                    img.deinit();
                    self.wallpaper_img = null;
                    return;
                };
                const bg_target = renderer.Renderer.init(new_bg.ptr, phys_w, phys_h, stride) catch {
                    self.allocator.free(new_bg);
                    img.deinit();
                    self.wallpaper_img = null;
                    return;
                };
                self.drawWallpaper(bg_target, img, phys_w, phys_h);
                bg_target.fillRect(0, 0, phys_w, phys_h, Color.init(55, 0, 0, 0));
                out.bg_cache = new_bg;
                out.bg_cache_w = phys_w;
                out.bg_cache_h = phys_h;
                // Free decoded image immediately after baking.
                img.deinit();
                self.wallpaper_img = null;
            } else {
                // No wallpaper: bake dark gradient directly.
                const new_bg = self.allocator.alloc(u32, phys_w * phys_h) catch return;
                const bg_target = renderer.Renderer.init(new_bg.ptr, phys_w, phys_h, stride) catch {
                    self.allocator.free(new_bg);
                    return;
                };
                self.drawFallbackBackground(bg_target, phys_w, phys_h);
                bg_target.fillRect(0, 0, phys_w, phys_h, Color.init(55, 0, 0, 0));
                out.bg_cache = new_bg;
                out.bg_cache_w = phys_w;
                out.bg_cache_h = phys_h;
            }
        }

        if (out.bg_cache) |bg| {
            @memcpy(target.pixels[0 .. phys_w * phys_h], bg[0 .. phys_w * phys_h]);
        } else {
            // Fallback direct render (should rarely hit after first bake).
            self.drawFallbackBackground(target, phys_w, phys_h);
            target.fillRect(0, 0, phys_w, phys_h, Color.init(55, 0, 0, 0));
        }

        // Direct-render HUD: clock, user, password box, status.
        self.renderHudDirect(target, phys_w, phys_h, scale);

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
            const scale_f = @max(scale_x, scale_y);
            const src_w = @as(u32, @intFromFloat(@as(f32, @floatFromInt(width)) / scale_f));
            const src_h = @as(u32, @intFromFloat(@as(f32, @floatFromInt(height)) / scale_f));
            const src_x = if (img.width > src_w) (img.width - src_w) / 2 else 0;
            const src_y = if (img.height > src_h) (img.height - src_h) / 2 else 0;
            var dy: u32 = 0;
            while (dy < height) : (dy += 1) {
                const sy = @min(src_y + @as(u32, @intFromFloat(@as(f32, @floatFromInt(dy)) / scale_f)), img.height - 1);
                var dx: u32 = 0;
                while (dx < width) : (dx += 1) {
                    const sx = @min(src_x + @as(u32, @intFromFloat(@as(f32, @floatFromInt(dx)) / scale_f)), img.width - 1);
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

    // Minimal direct-render HUD: no Clay, no layout engine, just direct pixel drawing.
    fn renderHudDirect(self: *LockApp, target: renderer.Renderer, w: u32, h: u32, scale: u32) void {
        const font = if (self.font) |*f| f else return;
        const sc = if (scale == 0) 1 else scale;

        // Clock string
        c.tzset();
        const now = c.time(null);
        var tm: c.struct_tm = undefined;
        _ = c.localtime_r(&now, &tm);
        const is_12h = std.mem.indexOf(u8, self.cfg.clock_format, "%I") != null or std.mem.indexOf(u8, self.cfg.clock_format, "%l") != null;
        const has_ampm = std.mem.indexOf(u8, self.cfg.clock_format, "%p") != null or std.mem.indexOf(u8, self.cfg.clock_format, "%P") != null;
        const fmt: [*:0]const u8 = if (is_12h) (if (has_ampm) "%I:%M %p" else "%I:%M") else "%H:%M";
        var time_buf: [64]u8 = undefined;
        const t_len = c.strftime(&time_buf, time_buf.len, fmt, &tm);
        const time_str = if (t_len > 0) time_buf[0..t_len] else "00:00";

        const clock_size = 72 * sc;
        const time_x: i32 = 64 * @as(i32, @intCast(sc));
        const time_y: i32 = @as(i32, @intCast(h)) - 48 * @as(i32, @intCast(sc)) - @as(i32, @intCast(clock_size / 2));

        // Draw clock text using FreeType glyph rendering directly.
        self.drawTextDirect(font, target, time_str, time_x, time_y, clock_size, Color.rgb(255, 255, 255));

        // Only show input chars when typing — no box, no border, just font chars.
        if (self.auth_state == .authenticating) {
            const msg = "Verifying...";
            const msg_size = 16 * sc;
            const msg_x: i32 = @as(i32, @intCast((w - @as(u32, @intCast(msg.len)) * msg_size / 2) / 2));
            const msg_y: i32 = @as(i32, @intCast(h)) - 60 * @as(i32, @intCast(sc));
            self.drawTextDirect(font, target, msg, msg_x, msg_y, msg_size, Color.rgb(255, 255, 255));
        } else if (self.password_len > 0) {
            // Each char drawn with the font. All masked as 󰊠 except last shown as 󰮯.
            const char_size = 20 * sc;
            const char_size_i = @as(i32, @intCast(char_size));
            const char_gap = @as(i32, @intCast(4 * sc));
            const total_chars = @min(self.password_len, 8);
            const start_idx = self.password_len - total_chars;
            // Last char visible; rest masked.
            const mask_str = "󰊠";
            const last_str = "󰮯";

            // Measure approximate width to center (max 8 chars so it never overflows).
            const approx_char_w = char_size_i;
            const tc = @as(i32, @intCast(total_chars));
            const total_w_approx = tc * approx_char_w + (tc - 1) * char_gap;
            var char_x = @divTrunc(@as(i32, @intCast(w)), 2) - @divTrunc(total_w_approx, 2);
            const char_y = @as(i32, @intCast(h)) - 80 * @as(i32, @intCast(sc));

            var idx: usize = 0;
            while (idx < total_chars) : (idx += 1) {
                const i = start_idx + idx;
                const is_last = (i == self.password_len - 1);
                const str_to_draw = if (is_last) last_str else mask_str;
                self.drawTextDirect(font, target, str_to_draw, char_x, char_y, char_size, Color.rgb(255, 255, 255));
                char_x += approx_char_w + char_gap;
            }
        }

        // Minimal status text — no rectangle, just font.
        const status_y = @as(i32, @intCast(h)) - 36 * @as(i32, @intCast(sc));
        if (self.auth_state == .failed) {
            const msg = "Incorrect password";
            const msg_size = 13 * sc;
            const msg_x: i32 = @divTrunc(@as(i32, @intCast(w)), 2) - @as(i32, @intCast(msg.len)) * @as(i32, @intCast(@divTrunc(msg_size, 2)));
            self.drawTextDirect(font, target, msg, msg_x, status_y, msg_size, Color.init(230, 235, 87, 87));
        } else if (self.caps_lock_active) {
            const msg = "Caps Lock is ON";
            const msg_size = 13 * sc;
            const msg_x: i32 = @divTrunc(@as(i32, @intCast(w)), 2) - @as(i32, @intCast(msg.len)) * @as(i32, @intCast(@divTrunc(msg_size, 2)));
            self.drawTextDirect(font, target, msg, msg_x, status_y, msg_size, Color.init(230, 245, 180, 60));
        }
    }

    fn drawTextDirect(self: *LockApp, font: *Font, target: renderer.Renderer, text: []const u8, x: i32, y: i32, size: u32, color: Color) void {
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
                    for (0..cg.height) |gy_row| {
                        const py = @as(i32, @intCast(gy + @as(i32, @intCast(gy_row))));
                        if (py < 0 or py >= @as(i32, @intCast(target.height))) continue;
                        for (0..cg.width) |gx_col| {
                            const px = gx + @as(i32, @intCast(gx_col));
                            if (px < 0 or px >= @as(i32, @intCast(target.width))) continue;
                            const alpha = cg.bitmap[gy_row * cg.width + gx_col];
                            if (alpha == 0) continue;
                            const blend_a = @as(u8, @intCast((@as(u32, alpha) * @as(u32, color.a)) / 255));
                            const blend_col = Color.init(blend_a, color.r, color.g, color.b);
                            const idx = @as(u32, @intCast(py)) * target.stride / 4 + @as(u32, @intCast(px));
                            target.pixels[idx] = blend_col.toArgb();
                        }
                    }
                }
                pen_x += cg.advance_x;
            } else {
                pen_x += @as(i32, @intCast(size / 2));
            }
        }
    }

    fn drawRoundedRectDirect(self: *LockApp, target: renderer.Renderer, x: i32, y: i32, w: i32, h: i32, radius: i32, col: Color) void {
        _ = self;
        const r = @min(@as(i32, @intCast(radius)), @divTrunc(w, 2));
        const rr = @min(r, @divTrunc(h, 2));
        const urr: u32 = @intCast(@max(0, rr));
        target.fillRect(x + rr, y, @as(u32, @intCast(@max(0, w - 2 * rr))), @as(u32, @intCast(@max(0, h))), col);
        target.fillRect(x, y + rr, urr, @as(u32, @intCast(@max(0, h - 2 * rr))), col);
        target.fillRect(x + w - rr, y + rr, urr, @as(u32, @intCast(@max(0, h - 2 * rr))), col);
        target.fillRect(x, y, urr, urr, col);
        target.fillRect(x + w - rr, y, urr, urr, col);
        target.fillRect(x, y + h - rr, urr, urr, col);
        target.fillRect(x + w - rr, y + h - rr, urr, urr, col);
    }

    fn drawRoundedBorderDirect(self: *LockApp, target: renderer.Renderer, x: i32, y: i32, w: i32, h: i32, radius: i32, thickness: i32, col: Color) void {
        _ = self;
        const r2 = @min(@as(i32, @intCast(radius)), @divTrunc(w, 2));
        _ = r2;
        const uw: u32 = @intCast(@max(0, w));
        const uthick: u32 = @intCast(@max(0, thickness));
        target.fillRect(x, y, uw, uthick, col);
        target.fillRect(x, y + h - thickness, uw, uthick, col);
        target.fillRect(x, y + thickness, uthick, @intCast(@max(0, h - 2 * thickness)), col);
        target.fillRect(x + w - thickness, y + thickness, uthick, @intCast(@max(0, h - 2 * thickness)), col);
    }

    fn splitmix64(seed: u64) u64 {
        var z = seed +% 0x9E3779B97F4A7C15;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }
};

fn authWorker(self: *LockApp, mut_ctx: AuthContext) void {
    var ctx = mut_ctx;
    defer { @memset(&ctx.password, 0); }
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

fn loadActiveWallpaper(allocator: std.mem.Allocator, cfg: config.Config) ?*Image {
    if (cfg.wallpaper) |wpath| {
        if (wpath.len > 0) {
            if (Image.loadFile(allocator, wpath)) |img| return img else |_| {}
        }
    }
    const home = c.getenv("HOME") orelse return null;
    const home_str = std.mem.span(home);
    const cache_paths = [_][]const u8{
        "/.cache/mizu/wallpaper",
        "/.cache/wm/current_wallpaper",
        "/.cache/current_wallpaper",
    };
    for (cache_paths) |cp| {
        const full_path_slice = std.fmt.allocPrint(allocator, "{s}{s}", .{ home_str, cp }) catch continue;
        defer allocator.free(full_path_slice);
        const full_path_z = allocator.dupeSentinel(u8, full_path_slice, 0) catch continue;
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
        const out_obj = c.wl_registry_bind(reg, name, &c.wl_output_interface, @min(ver, 4));
        if (out_obj) |wo| {
            const out_ptr = self.allocator.create(LockOutput) catch return;
            out_ptr.* = LockOutput{ .app = self, .output = @ptrCast(@alignCast(wo)), .global_name = name };
            self.outputs.append(self.allocator, out_ptr) catch {
                self.allocator.destroy(out_ptr);
                c.wl_output_destroy(@ptrCast(@alignCast(wo)));
                return;
            };
            _ = c.wl_output_add_listener(@ptrCast(@alignCast(wo)), &output_listener, self);
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
        } else idx += 1;
    }
}

fn output_geometry(data: ?*anyopaque, wl_out: ?*c.wl_output, x: i32, y: i32, physical_width: i32, physical_height: i32, subpixel: i32, make: [*c]const u8, model: [*c]const u8, transform: i32) callconv(.c) void {
    _ = data; _ = wl_out; _ = x; _ = y; _ = physical_width; _ = physical_height; _ = subpixel; _ = make; _ = model; _ = transform;
}
fn output_mode(data: ?*anyopaque, wl_out: ?*c.wl_output, flags: u32, width: i32, height: i32, refresh: i32) callconv(.c) void {
    _ = data; _ = wl_out; _ = flags; _ = width; _ = height; _ = refresh;
}
fn output_done(data: ?*anyopaque, wl_out: ?*c.wl_output) callconv(.c) void { _ = data; _ = wl_out; }
fn output_name(data: ?*anyopaque, wl_out: ?*c.wl_output, name: [*c]const u8) callconv(.c) void { _ = data; _ = wl_out; _ = name; }
fn output_description(data: ?*anyopaque, wl_out: ?*c.wl_output, desc: [*c]const u8) callconv(.c) void { _ = data; _ = wl_out; _ = desc; }
fn output_scale(data: ?*anyopaque, wl_out: ?*c.wl_output, factor: i32) callconv(.c) void {
    const self: *LockApp = @ptrCast(@alignCast(data.?));
    for (self.outputs.items) |out| {
        if (out.output == wl_out) {
            if (factor > 0) {
                out.scale = @as(u32, @intCast(factor));
                if (out.configured) {
                    self.renderOutput(out);
                    if (self.display) |disp| _ = c.wl_display_flush(disp);
                }
            }
            break;
        }
    }
}

const output_listener = c.wl_output_listener{
    .geometry = output_geometry, .mode = output_mode, .done = output_done,
    .scale = output_scale, .name = output_name, .description = output_description,
};

const seat_listener = c.wl_seat_listener{ .capabilities = seat_capabilities, .name = seat_name };

fn seat_capabilities(data: ?*anyopaque, seat: ?*c.wl_seat, capabilities: u32) callconv(.c) void {
    const self: *LockApp = @ptrCast(@alignCast(data.?));
    const has_kbd = (capabilities & c.WL_SEAT_CAPABILITY_KEYBOARD) != 0;
    if (has_kbd and self.keyboard == null) {
        self.keyboard = c.wl_seat_get_keyboard(seat);
        if (self.keyboard) |kbd| _ = c.wl_keyboard_add_listener(kbd, &keyboard_listener, self);
    } else if (!has_kbd and self.keyboard != null) {
        c.wl_keyboard_destroy(self.keyboard.?);
        self.keyboard = null;
    }
    const has_ptr = (capabilities & c.WL_SEAT_CAPABILITY_POINTER) != 0;
    if (has_ptr and self.pointer == null) {
        self.pointer = c.wl_seat_get_pointer(seat);
        if (self.pointer) |ptr| _ = c.wl_pointer_add_listener(ptr, &pointer_listener, self);
    } else if (!has_ptr and self.pointer != null) {
        c.wl_pointer_destroy(self.pointer.?);
        self.pointer = null;
    }
}
fn seat_name(data: ?*anyopaque, seat: ?*c.wl_seat, name: [*c]const u8) callconv(.c) void { _ = data; _ = seat; _ = name; }

const session_listener = c.ext_session_lock_v1_listener{ .locked = session_locked, .finished = session_finished };
fn session_locked(data: ?*anyopaque, sl: ?*c.ext_session_lock_v1) callconv(.c) void {
    _ = sl;
    const self: *LockApp = @ptrCast(@alignCast(data.?));
    self.is_locked = true; self.needs_redraw = true;
}
fn session_finished(data: ?*anyopaque, sl: ?*c.ext_session_lock_v1) callconv(.c) void {
    _ = sl;
    const self: *LockApp = @ptrCast(@alignCast(data.?));
    self.is_finished = true; self.running = false;
}

const pointer_listener = c.wl_pointer_listener{
    .enter = pointer_enter, .leave = pointer_leave, .motion = pointer_motion,
    .button = pointer_button, .axis = pointer_axis, .frame = pointer_frame,
    .axis_source = pointer_axis_source, .axis_stop = pointer_axis_stop,
    .axis_discrete = pointer_axis_discrete,
};
fn pointer_enter(data: ?*anyopaque, pointer: ?*c.wl_pointer, serial: u32, surface: ?*c.wl_surface, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
    _ = data; _ = surface; _ = sx; _ = sy;
    if (pointer) |p| c.wl_pointer_set_cursor(p, serial, null, 0, 0);
}
fn pointer_leave(data: ?*anyopaque, pointer: ?*c.wl_pointer, serial: u32, surf: ?*c.wl_surface) callconv(.c) void { _ = data; _ = pointer; _ = serial; _ = surf; }
fn pointer_motion(data: ?*anyopaque, pointer: ?*c.wl_pointer, time: u32, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void { _ = data; _ = pointer; _ = time; _ = sx; _ = sy; }
fn pointer_button(data: ?*anyopaque, pointer: ?*c.wl_pointer, serial: u32, time: u32, button: u32, state: u32) callconv(.c) void {
    _ = pointer; _ = serial; _ = time; _ = button;
    const self: *LockApp = @ptrCast(@alignCast(data.?));
    if (state == c.WL_POINTER_BUTTON_STATE_PRESSED) self.needs_redraw = true;
}
fn pointer_axis(data: ?*anyopaque, pointer: ?*c.wl_pointer, time: u32, axis: u32, value: c.wl_fixed_t) callconv(.c) void { _ = data; _ = pointer; _ = time; _ = axis; _ = value; }
fn pointer_frame(data: ?*anyopaque, pointer: ?*c.wl_pointer) callconv(.c) void { _ = data; _ = pointer; }
fn pointer_axis_source(data: ?*anyopaque, pointer: ?*c.wl_pointer, axis_source: u32) callconv(.c) void { _ = data; _ = pointer; _ = axis_source; }
fn pointer_axis_stop(data: ?*anyopaque, pointer: ?*c.wl_pointer, time: u32, axis: u32) callconv(.c) void { _ = data; _ = pointer; _ = time; _ = axis; }
fn pointer_axis_discrete(data: ?*anyopaque, pointer: ?*c.wl_pointer, axis: u32, discrete: i32) callconv(.c) void { _ = data; _ = pointer; _ = axis; _ = discrete; }

const keyboard_listener = c.wl_keyboard_listener{
    .keymap = keyboard_keymap, .enter = keyboard_enter, .leave = keyboard_leave,
    .key = keyboard_key, .modifiers = keyboard_modifiers, .repeat_info = keyboard_repeat_info,
};
fn keyboard_repeat_info(data: ?*anyopaque, kbd: ?*c.wl_keyboard, rate: i32, delay: i32) callconv(.c) void { _ = data; _ = kbd; _ = rate; _ = delay; }
fn keyboard_keymap(data: ?*anyopaque, kbd: ?*c.wl_keyboard, format: u32, fd: c_int, size: u32) callconv(.c) void {
    _ = kbd;
    const self: *LockApp = @ptrCast(@alignCast(data.?));
    if (format != c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) { _ = c.close(fd); return; }
    const map_shm = c.mmap(null, size, c.PROT_READ, c.MAP_SHARED, fd, 0);
    if (map_shm == c.MAP_FAILED) { _ = c.close(fd); return; }
    defer _ = c.munmap(map_shm, size);
    defer _ = c.close(fd);
    if (self.xkb_ctx == null) self.xkb_ctx = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
    if (self.xkb_ctx == null) return;
    const map_str: [*c]const u8 = @ptrCast(map_shm);
    const keymap_len = if (size > 0 and map_str[size - 1] == 0) size - 1 else size;
    const keymap = c.xkb_keymap_new_from_buffer(self.xkb_ctx.?, map_str, keymap_len, c.XKB_KEYMAP_FORMAT_TEXT_V1, c.XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (keymap == null) return;
    const state = c.xkb_state_new(keymap);
    if (state == null) { c.xkb_keymap_unref(keymap); return; }
    if (self.xkb_state) |st| c.xkb_state_unref(st);
    if (self.xkb_keymap) |km| c.xkb_keymap_unref(km);
    self.xkb_keymap = keymap;
    self.xkb_state = state;
}
fn keyboard_enter(data: ?*anyopaque, kbd: ?*c.wl_keyboard, serial: u32, surf: ?*c.wl_surface, keys: [*c]c.wl_array) callconv(.c) void {
    _ = kbd; _ = serial; _ = surf; _ = keys;
    const self: *LockApp = @ptrCast(@alignCast(data.?));
    self.has_kbd_focus = true; self.needs_redraw = true;
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
    if (self.needs_redraw) {
        self.needs_redraw = false;
        self.renderAllOutputs();
        if (self.display) |disp| _ = c.wl_display_flush(disp);
    }
}
fn keyboard_modifiers(data: ?*anyopaque, kbd: ?*c.wl_keyboard, serial: u32, mods_depressed: u32, mods_latched: u32, mods_locked: u32, group: u32) callconv(.c) void {
    _ = kbd; _ = serial;
    const self: *LockApp = @ptrCast(@alignCast(data.?));
    if (self.xkb_state) |st| {
        _ = c.xkb_state_update_mask(st, mods_depressed, mods_latched, mods_locked, 0, 0, group);
        const caps = c.xkb_state_mod_name_is_active(st, c.XKB_MOD_NAME_CAPS, c.XKB_STATE_MODS_EFFECTIVE) > 0;
        if (self.caps_lock_active != caps) {
            self.caps_lock_active = caps;
            self.needs_redraw = false;
            self.renderAllOutputs();
            if (self.display) |disp| _ = c.wl_display_flush(disp);
        }
    }
}

const lock_surface_listener = c.ext_session_lock_surface_v1_listener{
    .configure = lock_surface_configure,
};
fn lock_surface_configure(data: ?*anyopaque, ls: ?*c.ext_session_lock_surface_v1, serial: u32, width: u32, height: u32) callconv(.c) void {
    const out: *LockOutput = @ptrCast(@alignCast(data.?));
    out.width = width; out.height = height;
    c.ext_session_lock_surface_v1_ack_configure(ls, serial);
    out.configured = true;
    out.app.renderOutput(out);
    if (out.app.display) |disp| _ = c.wl_display_flush(disp);
}

pub fn runLock(allocator: std.mem.Allocator, cfg: config.Config) !void {
    c.tzset();
    var app = try LockApp.init(allocator, cfg);
    defer app.deinit();
    const disp = c.wl_display_connect(null) orelse return error.ConnectFailed;
    app.display = disp;
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
    if (app.compositor == null or app.shm == null or app.session_lock_mgr == null) return error.ProtocolMissing;

    // Load wallpaper BEFORE acquiring lock so first frame is ready.
    app.wallpaper_img = loadActiveWallpaper(allocator, cfg);

    const sl = c.ext_session_lock_manager_v1_lock(app.session_lock_mgr.?) orelse return error.LockFailed;
    app.session_lock = sl;
    _ = c.ext_session_lock_v1_add_listener(sl, &session_listener, &app);
    for (app.outputs.items) |out| {
        app.createLockSurfaceForOutput(out);
    }
    _ = c.wl_display_roundtrip(disp);

    while (app.running and !app.is_locked and !app.is_finished) {
        if (c.wl_display_dispatch(disp) < 0) break;
        if (app.needs_redraw) {
            app.needs_redraw = false;
            app.renderAllOutputs();
            _ = c.wl_display_flush(disp);
        }
    }
    if (!app.is_locked) return error.SessionLockFailed;
    app.renderAllOutputs();
    _ = c.wl_display_flush(disp);

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
        if (pr < 0) { c.wl_display_cancel_read(disp); continue; }
        if ((pfd[0].revents & (c.POLLHUP | c.POLLERR)) != 0) { c.wl_display_cancel_read(disp); break; }
        if ((pfd[0].revents & c.POLLIN) != 0) { _ = c.wl_display_read_events(disp); } else { c.wl_display_cancel_read(disp); }
        _ = c.wl_display_dispatch_pending(disp);
        if (app.timer_fd >= 0 and (pfd[1].revents & c.POLLIN) != 0) {
            var val: u64 = 0;
            _ = c.read(app.timer_fd, &val, @sizeOf(u64));
            const now = c.time(null);
            var tm: c.struct_tm = undefined;
            _ = c.localtime_r(&now, &tm);
            if (tm.tm_min != app.last_rendered_min) {
                app.last_rendered_min = tm.tm_min;
                app.needs_redraw = true;
            }
        }
        app.checkAuthResult();
        if (app.auth_state == .success) break;
        if (app.needs_redraw) {
            app.needs_redraw = false;
            app.renderAllOutputs();
            _ = c.wl_display_flush(disp);
        }
    }
    if (app.is_locked and app.auth_state == .success) {
        if (app.session_lock) |lock_obj| {
            c.ext_session_lock_v1_unlock_and_destroy(lock_obj);
            app.session_lock = null;
            _ = c.wl_display_roundtrip(disp);
        }
    }
}
