const std = @import("std");
const c = @import("../c.zig").c;
const theme = @import("../core/theme.zig");
const config = @import("../core/config.zig");
const renderer = @import("../core/renderer.zig");
const sys_status = @import("../services/system_status.zig");
const ui_mod = @import("../core/ui.zig");

pub const PowerAction = enum(usize) {
    lock = 0,
    shutdown = 1,
    reboot = 2,
    hibernate = 3,
    logout = 4,

    pub const count: usize = 5;

    pub fn label(self: PowerAction) []const u8 {
        return switch (self) {
            .lock => "Lock",
            .shutdown => "Shut down",
            .reboot => "Reboot",
            .hibernate => "Hibernate",
            .logout => "Log out",
        };
    }

    pub fn svgIcon(self: PowerAction) []const u8 {
        return switch (self) {
            .lock => "lock",
            .shutdown => "power",
            .reboot => "restart",
            .hibernate => "pause",
            .logout => "logout",
        };
    }

    pub fn command(self: PowerAction) []const u8 {
        return switch (self) {
            .lock => "mizu lock 2>/dev/null || loginctl lock-session 2>/dev/null || true",
            .shutdown => "systemctl poweroff 2>/dev/null || loginctl poweroff 2>/dev/null || poweroff 2>/dev/null || true",
            .reboot => "systemctl reboot 2>/dev/null || loginctl reboot 2>/dev/null || reboot 2>/dev/null || true",
            .hibernate => "systemctl hibernate 2>/dev/null || loginctl hibernate 2>/dev/null || true",
            .logout => "pkill -u $USER 2>/dev/null || true",
        };
    }
};

pub const HitArea = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: u32 = 0,
    h: u32 = 0,
    action: ?PowerAction = null,
    is_confirm: bool = false,
    is_cancel: bool = false,
};

pub const PowerOverlay = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    font: renderer.Font,
    width: u32 = 800,
    height: u32 = 260,
    selected_idx: usize = 0,
    confirming: bool = false,
    countdown_seconds: u32 = 5,
    elapsed_ticks: u32 = 0,
    running: bool = true,
    hit_areas: std.ArrayList(HitArea),

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !PowerOverlay {
        const font = try renderer.Font.init(allocator, cfg.theme.font_family, cfg.typography.ui);
        const self = PowerOverlay{
            .allocator = allocator,
            .cfg = cfg,
            .font = font,
            .hit_areas = std.ArrayList(HitArea).empty,
        };
        return self;
    }

    pub fn deinit(self: *PowerOverlay) void {
        self.hit_areas.deinit(self.allocator);
        self.font.deinit();
    }

    pub fn tick(self: *PowerOverlay) bool {
        if (self.confirming) {
            self.elapsed_ticks += 1;
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
                    self.countdown_seconds = 5;
                    self.elapsed_ticks = 0;
                    return true;
                } else {
                    self.running = false;
                    return true;
                }
            },
            c.XKB_KEY_Left => {
                if (!self.confirming) {
                    if (self.selected_idx == 0) {
                        self.selected_idx = PowerAction.count - 1;
                    } else {
                        self.selected_idx -= 1;
                    }
                    return true;
                }
            },
            c.XKB_KEY_Right, c.XKB_KEY_Tab => {
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
                    self.countdown_seconds = 5;
                    self.elapsed_ticks = 0;
                    return true;
                }
            },
            c.XKB_KEY_1, c.XKB_KEY_l, c.XKB_KEY_L => {
                self.selected_idx = @intFromEnum(PowerAction.lock);
                self.executeAction();
                self.running = false;
                return true;
            },
            c.XKB_KEY_2, c.XKB_KEY_p, c.XKB_KEY_P => {
                self.selected_idx = @intFromEnum(PowerAction.shutdown);
                self.confirming = true;
                return true;
            },
            c.XKB_KEY_3, c.XKB_KEY_r, c.XKB_KEY_R => {
                self.selected_idx = @intFromEnum(PowerAction.reboot);
                self.confirming = true;
                return true;
            },
            c.XKB_KEY_4, c.XKB_KEY_s, c.XKB_KEY_S, c.XKB_KEY_h, c.XKB_KEY_H => {
                self.selected_idx = @intFromEnum(PowerAction.hibernate);
                self.confirming = true;
                return true;
            },
            c.XKB_KEY_5, c.XKB_KEY_e, c.XKB_KEY_E => {
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
                if (ha.action) |act| {
                    if (self.confirming) {
                        if (self.selected_idx == @intFromEnum(act)) {
                            self.confirming = false;
                            self.countdown_seconds = 5;
                            return true;
                        } else {
                            self.selected_idx = @intFromEnum(act);
                            self.countdown_seconds = 5;
                            return true;
                        }
                    } else {
                        self.selected_idx = @intFromEnum(act);
                        self.confirming = true;
                        self.countdown_seconds = 5;
                        return true;
                    }
                }
            }
        }
        return false;
    }

    pub fn executeAction(self: *PowerOverlay) void {
        const act: PowerAction = @enumFromInt(self.selected_idx);
        sys_status.spawnCmd(act.command());
    }

    pub fn render(self: *PowerOverlay, target: renderer.Renderer, scale: u32) !void {
        self.hit_areas.clearRetainingCapacity();

        const w = target.width;
        const h = target.height;
        const iscale: i32 = @intCast(scale);

        var ui = try ui_mod.Ui.begin(
            self.allocator,
            &self.font,
            w,
            h,
            scale,
            -1,
            -1,
            false,
            1.0 / 60.0,
        );
        defer ui.deinit();

        ui.root(.{
            .direction = .column,
            .align_x = .center,
            .align_y = .center,
            .padding = .{ .top = ui.su(40), .bottom = ui.su(40), .left = ui.su(40), .right = ui.su(40) },
            .gap = ui.su(12),
        });

        // Cards row
        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .fit,
            .direction = .row,
            .gap = ui.su(16),
            .align_x = .center,
            .align_y = .center,
        });
        for ([_]PowerAction{ .lock, .shutdown, .reboot, .hibernate, .logout }) |act| {
            const idx = @intFromEnum(act);
            const is_sel = (idx == self.selected_idx);
            const is_confirming = self.confirming and is_sel;
            const bg_col = self.cfg.theme.surface;
            const border_col = if (is_sel) self.cfg.theme.accent else self.cfg.theme.border;

            _ = ui.open(.{
                .id = "pw-card",
                .index = @intCast(idx),
                .width = .{ .fixed = ui.s(140) },
                .height = .{ .fixed = ui.s(140) },
                .direction = .column,
                .align_x = .center,
                .align_y = .center,
                .padding = .{ .left = ui.su(16), .right = ui.su(16), .top = ui.su(16), .bottom = ui.su(16) },
                .gap = ui.su(12),
                .bg = bg_col,
                .radius = ui.f(16),
                .border = @as(u16, if (is_sel) 2 else 1),
                .border_color = border_col,
            });

            // Icon / countdown
            _ = ui.open(.{ .width = .{ .fixed = ui.s(72) }, .height = .{ .fixed = ui.s(72) }, .align_x = .center, .align_y = .center });
            if (is_confirming) {
                var count_buf: [8]u8 = undefined;
                const str = std.fmt.bufPrint(&count_buf, "{d}", .{self.countdown_seconds}) catch "";
                ui.text(str, .{
                    .size = @intCast(48 * scale),
                    .color = self.cfg.theme.accent,
                    .text_align = .center,
                });
            } else {
                ui.icon(act.svgIcon(), 72 * scale, if (is_sel) self.cfg.theme.accent else self.cfg.theme.text_main, @intCast(idx));
            }
            ui.close();

            ui.close();
        }
        ui.close(); // cards row

        const commands = ui.endLayout();
        ui.render(target, commands);

        // Hitboxes for cards
        var i: u32 = 0;
        while (i < PowerAction.count) : (i += 1) {
            if (ui.rectOf("pw-card", i)) |rect| {
                try self.appendHit(rect, iscale, .{ .action = @enumFromInt(i) });
            }
        }
    }

    fn appendHit(self: *PowerOverlay, rect: renderer.Rect, iscale: i32, hit: HitArea) !void {
        const lw: u32 = @intCast(@divTrunc(@as(i32, @intCast(rect.w)) + iscale - 1, iscale));
        const lh: u32 = @intCast(@divTrunc(@as(i32, @intCast(rect.h)) + iscale - 1, iscale));
        if (lw == 0 or lh == 0) return;
        var h = hit;
        h.x = @divTrunc(rect.x, iscale);
        h.y = @divTrunc(rect.y, iscale);
        h.w = lw;
        h.h = lh;
        try self.hit_areas.append(self.allocator, h);
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

    _ = overlay.handleKey(c.XKB_KEY_p);
    try std.testing.expectEqual(@intFromEnum(PowerAction.shutdown), overlay.selected_idx);
    try std.testing.expectEqual(true, overlay.confirming);

    _ = overlay.handleKey(c.XKB_KEY_Escape);
    try std.testing.expectEqual(false, overlay.confirming);
    try std.testing.expectEqual(true, overlay.running);

    _ = overlay.handleKey(c.XKB_KEY_Escape);
    try std.testing.expectEqual(false, overlay.running);
}
