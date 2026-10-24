const std = @import("std");
const c = @import("../c.zig").c;
const theme = @import("../core/theme.zig");
const config = @import("../core/config.zig");
const renderer = @import("../core/renderer.zig");
const icons = @import("../graphics/icons.zig");
const sys_status = @import("../services/system_status.zig");

pub const PowerAction = enum(usize) {
    lock = 0,
    sleep = 1,
    reboot = 2,
    shutdown = 3,
    logout = 4,

    pub const count: usize = 5;

    pub fn label(self: PowerAction) []const u8 {
        return switch (self) {
            .lock => "Lock",
            .sleep => "Sleep",
            .reboot => "Reboot",
            .shutdown => "Power Off",
            .logout => "Logout",
        };
    }

    pub fn svgIcon(self: PowerAction) []const u8 {
        return switch (self) {
            .lock => "lock",
            .sleep => "sleep",
            .reboot => "restart",
            .shutdown => "power",
            .logout => "logout",
        };
    }

    pub fn hotkeyChar(self: PowerAction) u8 {
        return switch (self) {
            .lock => 'L',
            .sleep => 'S',
            .reboot => 'R',
            .shutdown => 'P',
            .logout => 'E',
        };
    }

    pub fn command(self: PowerAction) []const u8 {
        return switch (self) {
            .lock => "mizu lock 2>/dev/null || loginctl lock-session 2>/dev/null || true",
            .sleep => "systemctl suspend 2>/dev/null || loginctl suspend 2>/dev/null || true",
            .reboot => "systemctl reboot 2>/dev/null || loginctl reboot 2>/dev/null || reboot 2>/dev/null || true",
            .shutdown => "systemctl poweroff 2>/dev/null || loginctl poweroff 2>/dev/null || poweroff 2>/dev/null || true",
            .logout => "pkill -u $USER 2>/dev/null || true",
        };
    }
};

pub const HitArea = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    action: ?PowerAction = null,
    is_confirm: bool = false,
    is_cancel: bool = false,
};

pub const PowerOverlay = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    font: renderer.Font,
    width: u32 = 540,
    height: u32 = 230,
    selected_idx: usize = 3, // default to shutdown / power off
    confirming: bool = false,
    countdown_seconds: u32 = 10,
    elapsed_ticks: u32 = 0,
    running: bool = true,
    user_host: [64]u8 = [_]u8{0} ** 64,
    user_host_len: usize = 0,
    uptime_buf: [64]u8 = [_]u8{0} ** 64,
    uptime_len: usize = 0,
    hit_areas: std.ArrayList(HitArea),

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !PowerOverlay {
        const font = try renderer.Font.init(allocator, cfg.theme.font_family, cfg.typography.ui);
        var self = PowerOverlay{
            .allocator = allocator,
            .cfg = cfg,
            .font = font,
            .hit_areas = std.ArrayList(HitArea).empty,
        };
        self.updateSysInfo();
        return self;
    }

    pub fn deinit(self: *PowerOverlay) void {
        self.hit_areas.deinit(self.allocator);
        self.font.deinit();
    }

    fn updateSysInfo(self: *PowerOverlay) void {
        const c_user = c.getenv("USER");
        const user_str = if (c_user != null) std.mem.span(c_user.?) else "user";

        var host_buf: [32]u8 = undefined;
        if (c.gethostname(&host_buf, host_buf.len) == 0) {
            host_buf[host_buf.len - 1] = 0;
            const host_str = std.mem.sliceTo(&host_buf, 0);
            const uh = std.fmt.bufPrint(&self.user_host, "{s}@{s}", .{ user_str, host_str }) catch "";
            self.user_host_len = uh.len;
        } else {
            const uh = std.fmt.bufPrint(&self.user_host, "{s}", .{user_str}) catch "";
            self.user_host_len = uh.len;
        }

        if (c.fopen("/proc/uptime", "r")) |f| {
            defer _ = c.fclose(f);
            var buf: [64]u8 = undefined;
            const n = c.fread(&buf, 1, buf.len - 1, f);
            if (n > 0) {
                buf[n] = 0;
                const s = std.mem.trim(u8, buf[0..n], " \t\r\n");
                var space_idx: usize = 0;
                while (space_idx < s.len and s[space_idx] != ' ' and s[space_idx] != '\t') : (space_idx += 1) {}
                const sec_float = std.fmt.parseFloat(f32, s[0..space_idx]) catch 0.0;
                const total_sec: u64 = @intFromFloat(sec_float);
                const hours = total_sec / 3600;
                const mins = (total_sec % 3600) / 60;
                const ut = std.fmt.bufPrint(&self.uptime_buf, "up {d}h {d}m", .{ hours, mins }) catch "";
                self.uptime_len = ut.len;
            }
        }
    }

    pub fn tick(self: *PowerOverlay) bool {
        if (self.confirming) {
            self.elapsed_ticks += 1;
            // 20 ticks per second (50ms timer)
            if (self.elapsed_ticks >= 20) {
                self.elapsed_ticks = 0;
                if (self.countdown_seconds > 1) {
                    self.countdown_seconds -= 1;
                    return true;
                } else {
                    self.executeAction();
                    self.running = false;
                    return true;
                }
            }
        }
        return false;
    }

    pub fn handleKey(self: *PowerOverlay, sym: u32) bool {
        switch (sym) {
            c.XKB_KEY_Escape => {
                if (self.confirming) {
                    self.confirming = false;
                    self.countdown_seconds = 10;
                    self.elapsed_ticks = 0;
                    return true;
                } else {
                    self.running = false;
                    return true;
                }
            },
            c.XKB_KEY_Left, c.XKB_KEY_h, c.XKB_KEY_H => {
                if (!self.confirming) {
                    if (self.selected_idx == 0) {
                        self.selected_idx = PowerAction.count - 1;
                    } else {
                        self.selected_idx -= 1;
                    }
                    return true;
                }
            },
            c.XKB_KEY_Right, c.XKB_KEY_l, c.XKB_KEY_L => {
                if (!self.confirming) {
                    self.selected_idx = (self.selected_idx + 1) % PowerAction.count;
                    return true;
                }
            },
            c.XKB_KEY_Tab => {
                if (!self.confirming) {
                    self.selected_idx = (self.selected_idx + 1) % PowerAction.count;
                    return true;
                }
            },
            c.XKB_KEY_ISO_Left_Tab => {
                if (!self.confirming) {
                    if (self.selected_idx == 0) {
                        self.selected_idx = PowerAction.count - 1;
                    } else {
                        self.selected_idx -= 1;
                    }
                    return true;
                }
            },
            c.XKB_KEY_Return, c.XKB_KEY_KP_Enter, c.XKB_KEY_space => {
                if (self.confirming) {
                    self.executeAction();
                    self.running = false;
                    return true;
                } else {
                    self.confirming = true;
                    self.countdown_seconds = 10;
                    self.elapsed_ticks = 0;
                    return true;
                }
            },
            // Direct hotkeys
            c.XKB_KEY_1 => {
                self.selected_idx = 0;
                self.confirming = true;
                return true;
            },
            c.XKB_KEY_2 => {
                self.selected_idx = 1;
                self.confirming = true;
                return true;
            },
            c.XKB_KEY_3 => {
                self.selected_idx = 2;
                self.confirming = true;
                return true;
            },
            c.XKB_KEY_4 => {
                self.selected_idx = 3;
                self.confirming = true;
                return true;
            },
            c.XKB_KEY_5 => {
                self.selected_idx = 4;
                self.confirming = true;
                return true;
            },
            c.XKB_KEY_s, c.XKB_KEY_S => {
                self.selected_idx = @intFromEnum(PowerAction.sleep);
                self.confirming = true;
                return true;
            },
            c.XKB_KEY_r, c.XKB_KEY_R => {
                self.selected_idx = @intFromEnum(PowerAction.reboot);
                self.confirming = true;
                return true;
            },
            c.XKB_KEY_p, c.XKB_KEY_P => {
                self.selected_idx = @intFromEnum(PowerAction.shutdown);
                self.confirming = true;
                return true;
            },
            c.XKB_KEY_e, c.XKB_KEY_E => {
                self.selected_idx = @intFromEnum(PowerAction.logout);
                self.confirming = true;
                return true;
            },
            else => {},
        }
        return false;
    }

    pub fn handleClick(self: *PowerOverlay, x: i32, y: i32) bool {
        for (self.hit_areas.items) |ha| {
            if (x >= ha.x and x < ha.x + @as(i32, @intCast(ha.w)) and
                y >= ha.y and y < ha.y + @as(i32, @intCast(ha.h)))
            {
                if (ha.is_cancel) {
                    if (self.confirming) {
                        self.confirming = false;
                        self.countdown_seconds = 10;
                        return true;
                    } else {
                        self.running = false;
                        return true;
                    }
                } else if (ha.is_confirm) {
                    self.executeAction();
                    self.running = false;
                    return true;
                } else if (ha.action) |act| {
                    if (self.selected_idx == @intFromEnum(act) and !self.confirming) {
                        self.confirming = true;
                        self.countdown_seconds = 10;
                    } else {
                        self.selected_idx = @intFromEnum(act);
                        self.confirming = false;
                    }
                    return true;
                }
            }
        }
        return false;
    }

    pub fn executeAction(self: *PowerOverlay) void {
        const act: PowerAction = @enumFromInt(self.selected_idx);
        sys_status.spawnCmd(act.command());
    }

    pub fn render(self: *PowerOverlay, target: renderer.Renderer) !void {
        target.clear(theme.Color.transparent);
        self.hit_areas.clearRetainingCapacity();

        const w = target.width;
        const h = target.height;
        const radius: u32 = 18;

        // Subtle outer drop shadow for floating depth
        target.drawDropShadow(10, 10, w - 20, h - 20, radius, 8, theme.Color.init(80, 0, 0, 0));

        // Main glassmorphic container with top specular highlight
        target.fillGlassSquircle(10, 10, w - 20, h - 20, radius, self.cfg.theme.panel_bg);
        target.drawSquircleBorder(10, 10, w - 20, h - 20, radius, 1, self.cfg.theme.panel_border);

        // Header Title & System Info
        const header_y: i32 = 38;
        if (self.confirming) {
            const act: PowerAction = @enumFromInt(self.selected_idx);
            var title_buf: [64]u8 = undefined;
            const confirm_title = std.fmt.bufPrint(&title_buf, "Confirm {s}?", .{act.label()}) catch "Confirm Action";
            target.drawTextWithSize(&self.font, confirm_title, 32, header_y, self.cfg.typography.title, self.cfg.theme.text_bright);

            var sub_buf: [64]u8 = undefined;
            const sub_msg = std.fmt.bufPrint(&sub_buf, "Auto-executing in {d}s • Press Enter to confirm, Esc to cancel", .{self.countdown_seconds}) catch "";
            target.drawTextWithSize(&self.font, sub_msg, 32, header_y + 20, self.cfg.typography.secondary, self.cfg.theme.text_muted);

            try self.renderConfirmView(target, w, h);
        } else {
            target.drawTextWithSize(&self.font, "Session Management", 32, header_y, self.cfg.typography.title, self.cfg.theme.text_bright);

            var meta_buf: [128]u8 = undefined;
            const user_host_str = if (self.user_host_len > 0) self.user_host[0..self.user_host_len] else "user@desktop";
            const uptime_str = if (self.uptime_len > 0) self.uptime_buf[0..self.uptime_len] else "";
            const meta_text = std.fmt.bufPrint(&meta_buf, "{s}  •  {s}", .{ user_host_str, uptime_str }) catch user_host_str;
            target.drawTextWithSize(&self.font, meta_text, 32, header_y + 22, self.cfg.typography.secondary, self.cfg.theme.text_muted);

            try self.renderActionsGrid(target, w, h);
        }
    }

    fn renderActionsGrid(self: *PowerOverlay, target: renderer.Renderer, w: u32, h: u32) !void {
        _ = h;
        const card_w: u32 = 88;
        const card_h: u32 = 114;
        const card_gap: u32 = 12;
        const total_w = card_w * 5 + card_gap * 4;
        const start_x: i32 = @divTrunc(@as(i32, @intCast(w)) - @as(i32, @intCast(total_w)), 2);
        const start_y: i32 = 80;

        var i: usize = 0;
        while (i < PowerAction.count) : (i += 1) {
            const act: PowerAction = @enumFromInt(i);
            const cx = start_x + @as(i32, @intCast(i * (card_w + card_gap)));
            const is_sel = (i == self.selected_idx);

            try self.hit_areas.append(self.allocator, .{
                .x = cx,
                .y = start_y,
                .w = card_w,
                .h = card_h,
                .action = act,
            });

            // Card background
            const bg_col = if (is_sel) self.cfg.theme.selection_bg else self.cfg.theme.card_bg;
            target.fillGlassSquircle(cx, start_y, card_w, card_h, 12, bg_col);

            const border_col = if (is_sel) self.cfg.theme.accent else self.cfg.theme.border;
            target.drawSquircleBorder(cx, start_y, card_w, card_h, 12, if (is_sel) 2 else 1, border_col);

            // Icon
            const icon_col = if (is_sel) self.cfg.theme.accent else self.cfg.theme.text_bright;
            const icon_size = self.cfg.typography.quicksettings_icon;
            icons.drawSvgIcon(
                target,
                self.allocator,
                act.svgIcon(),
                icon_size,
                1,
                cx + @divTrunc(@as(i32, @intCast(card_w)), 2),
                start_y + 38,
                icon_col,
            );

            // Label
            const lbl = act.label();
            const lbl_w = target.measureTextWithSize(&self.font, lbl, self.cfg.typography.ui);
            const lbl_x = cx + @divTrunc(@as(i32, @intCast(card_w)) - @as(i32, @intCast(lbl_w)), 2);
            target.drawTextWithSize(&self.font, lbl, lbl_x, start_y + 76, self.cfg.typography.ui, if (is_sel) self.cfg.theme.text_bright else self.cfg.theme.text_muted);

            // Hotkey Badge
            var key_buf: [8]u8 = undefined;
            const key_str = std.fmt.bufPrint(&key_buf, "[{c}]", .{act.hotkeyChar()}) catch "[ ]";
            const key_w = target.measureTextWithSize(&self.font, key_str, self.cfg.typography.secondary);
            const key_x = cx + @divTrunc(@as(i32, @intCast(card_w)) - @as(i32, @intCast(key_w)), 2);
            target.drawTextWithSize(&self.font, key_str, key_x, start_y + 100, self.cfg.typography.secondary, if (is_sel) self.cfg.theme.accent else self.cfg.theme.border);
        }
    }

    fn renderConfirmView(self: *PowerOverlay, target: renderer.Renderer, w: u32, h: u32) !void {
        _ = h;
        const act: PowerAction = @enumFromInt(self.selected_idx);

        // Progress bar for countdown
        const pbar_x: i32 = 32;
        const pbar_y: i32 = 96;
        const pbar_w: u32 = w - 64;
        const pbar_h: u32 = 6;
        target.fillSquircle(pbar_x, pbar_y, pbar_w, pbar_h, 3, self.cfg.theme.surface);

        const progress_pct = @min(100, (self.countdown_seconds * 10));
        const fill_w = (@as(u64, pbar_w) * progress_pct) / 100;
        if (fill_w > 0) {
            target.fillSquircle(pbar_x, pbar_y, @intCast(fill_w), pbar_h, 3, self.cfg.theme.accent);
        }

        // Action Buttons: Confirm & Cancel
        const btn_w: u32 = 180;
        const btn_h: u32 = 46;
        const btn_y: i32 = 136;

        const confirm_x: i32 = @divTrunc(@as(i32, @intCast(w)), 2) - @as(i32, @intCast(btn_w)) - 12;
        const cancel_x: i32 = @divTrunc(@as(i32, @intCast(w)), 2) + 12;

        try self.hit_areas.append(self.allocator, .{
            .x = confirm_x,
            .y = btn_y,
            .w = btn_w,
            .h = btn_h,
            .is_confirm = true,
        });

        try self.hit_areas.append(self.allocator, .{
            .x = cancel_x,
            .y = btn_y,
            .w = btn_w,
            .h = btn_h,
            .is_cancel = true,
        });

        // Confirm button (accent colored)
        const confirm_bg = if (act == .shutdown or act == .reboot) self.cfg.theme.error_color else self.cfg.theme.accent;
        target.fillGlassSquircle(confirm_x, btn_y, btn_w, btn_h, 12, confirm_bg);

        var confirm_lbl_buf: [64]u8 = undefined;
        const confirm_lbl = std.fmt.bufPrint(&confirm_lbl_buf, "{s} (Enter)", .{act.label()}) catch "Confirm";
        const c_lbl_w = target.measureTextWithSize(&self.font, confirm_lbl, self.cfg.typography.button_text);
        const c_lbl_x = confirm_x + @divTrunc(@as(i32, @intCast(btn_w)) - @as(i32, @intCast(c_lbl_w)), 2);
        target.drawTextWithSize(&self.font, confirm_lbl, c_lbl_x, btn_y + 29, self.cfg.typography.button_text, confirm_bg.contrastingTextColor());

        // Cancel button (glass surface)
        target.fillGlassSquircle(cancel_x, btn_y, btn_w, btn_h, 12, self.cfg.theme.surface);
        target.drawSquircleBorder(cancel_x, btn_y, btn_w, btn_h, 12, 1, self.cfg.theme.border);

        const cancel_lbl = "Cancel (Esc)";
        const cancel_lbl_w = target.measureTextWithSize(&self.font, cancel_lbl, self.cfg.typography.button_text);
        const cancel_lbl_x = cancel_x + @divTrunc(@as(i32, @intCast(btn_w)) - @as(i32, @intCast(cancel_lbl_w)), 2);
        target.drawTextWithSize(&self.font, cancel_lbl, cancel_lbl_x, btn_y + 29, self.cfg.typography.button_text, self.cfg.theme.text_bright);
    }
};

test "PowerOverlay initialization and hotkeys" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var overlay = try PowerOverlay.init(allocator, cfg);
    defer overlay.deinit();

    try std.testing.expectEqual(@as(usize, 5), PowerAction.count);
    try std.testing.expectEqual(true, overlay.running);
    try std.testing.expectEqual(false, overlay.confirming);

    // Test hotkey P for shutdown
    _ = overlay.handleKey(c.XKB_KEY_p);
    try std.testing.expectEqual(@intFromEnum(PowerAction.shutdown), overlay.selected_idx);
    try std.testing.expectEqual(true, overlay.confirming);

    // Escape cancels confirmation
    _ = overlay.handleKey(c.XKB_KEY_Escape);
    try std.testing.expectEqual(false, overlay.confirming);
    try std.testing.expectEqual(true, overlay.running);

    // Escape again quits
    _ = overlay.handleKey(c.XKB_KEY_Escape);
    try std.testing.expectEqual(false, overlay.running);
}
