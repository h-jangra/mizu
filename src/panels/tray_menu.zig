const std = @import("std");
const renderer = @import("../core/renderer.zig");
const theme = @import("../core/theme.zig");
const config = @import("../core/config.zig");
const c = @import("c");

pub const MAX_TRAY_MENU_ACTIONS: usize = 32;

pub const TrayMenuRequest = struct {
    service: [128]u8,
    path: [128]u8,
    menu_path: [128]u8,
    id: [64]u8,
    title: [128]u8,
    icon_name: [128]u8,
    actions: [MAX_TRAY_MENU_ACTIONS]c.MizuTrayMenuAction,
    action_count: usize,
    item_x: i32,
    item_y: i32,
    item_w: u32,
    item_h: u32,
};

pub const TrayMenu = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    font: renderer.Font,
    service: [128]u8,
    menu_path: [128]u8,
    title: [128]u8,
    actions: [MAX_TRAY_MENU_ACTIONS]c.MizuTrayMenuAction,
    action_count: usize,
    width: u32,
    height: u32,
    header_h: u32,
    row_h: u32 = 30,
    hover_index: ?usize = null,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config, req: TrayMenuRequest) !TrayMenu {
        const font = try renderer.Font.init(allocator, cfg.theme.font_family, cfg.typography.bar_text);
        var tm = TrayMenu{
            .allocator = allocator,
            .cfg = cfg,
            .font = font,
            .service = req.service,
            .menu_path = req.menu_path,
            .title = req.title,
            .actions = req.actions,
            .action_count = req.action_count,
            .width = 180,
            .height = 100,
            .header_h = 0,
        };

        const title_slice = std.mem.span(@as([*:0]const u8, @ptrCast(&tm.title)));
        if (title_slice.len > 0) {
            tm.header_h = 28;
        }

        var max_w: u32 = 120;
        const font_sz = cfg.typography.bar_text;
        for (tm.actions[0..tm.action_count]) |act| {
            if (!act.visible) continue;
            const label = std.mem.span(@as([*:0]const u8, @ptrCast(&act.label)));
            const w = @as(u32, @intCast(label.len)) * (font_sz / 2 + 1);
            if (w > max_w) max_w = w;
        }

        tm.width = @max(160, @min(360, max_w + 36));
        tm.height = tm.header_h + @as(u32, @intCast(tm.action_count)) * tm.row_h + 12;
        return tm;
    }

    pub fn deinit(self: *TrayMenu) void {
        self.font.deinit();
    }

    pub fn render(self: *TrayMenu, target: renderer.Renderer, scale: u32) !void {
        const iscale: i32 = @intCast(scale);
        const phys_w = self.width * scale;
        const phys_h = self.height * scale;

        target.clear(theme.Color.transparent);

        const radius = 10 * scale;
        target.fillSquircle(0, 0, phys_w, phys_h, radius, self.cfg.theme.surface);
        target.drawSquircleBorder(0, 0, phys_w, phys_h, radius, 1, self.cfg.theme.border);

        var cur_y: i32 = 6 * iscale;
        const pad_x = 8 * iscale;
        const row_w = if (phys_w > 16 * scale) phys_w - 16 * scale else phys_w;
        const font_sz = self.cfg.typography.bar_text * scale;
        const title_sz = (self.cfg.typography.bar_text -| 1) * scale;

        const title_slice = std.mem.span(@as([*:0]const u8, @ptrCast(&self.title)));
        if (title_slice.len > 0 and self.header_h > 0) {
            target.drawTextWithSize(&self.font, title_slice, pad_x + 6 * iscale, cur_y + 17 * iscale, title_sz, self.cfg.theme.text_muted);
            cur_y += @intCast(self.header_h * scale);
            target.fillRect(pad_x, cur_y - 4 * iscale, row_w, 1, self.cfg.theme.border);
        }

        const row_h_px: u32 = self.row_h * scale;
        for (self.actions[0..self.action_count], 0..) |act, i| {
            if (!act.visible) continue;
            const is_hov = (self.hover_index != null and self.hover_index.? == i);

            if (is_hov and act.enabled) {
                target.fillSquircle(pad_x, cur_y, row_w, row_h_px, 6 * scale, self.cfg.theme.accent);
            }

            const label = std.mem.span(@as([*:0]const u8, @ptrCast(&act.label)));
            const text_col = if (is_hov and act.enabled)
                self.cfg.theme.accent_fg
            else if (act.enabled)
                self.cfg.theme.text_main
            else
                self.cfg.theme.text_muted;

            target.drawTextWithSize(&self.font, label, pad_x + 10 * iscale, cur_y + @divTrunc(@as(i32, @intCast(row_h_px)) + @as(i32, @intCast(font_sz)), 2) - 2 * iscale, font_sz, text_col);

            cur_y += @intCast(row_h_px);
        }
    }

    pub fn handlePointerMotion(self: *TrayMenu, px: i32, py: i32) bool {
        const row_idx = self.rowAt(px, py);
        if (self.hover_index != row_idx) {
            self.hover_index = row_idx;
            return true;
        }
        return false;
    }

    pub fn handleClick(self: *const TrayMenu, px: i32, py: i32) ?i32 {
        const row_idx = self.rowAt(px, py) orelse return null;
        if (row_idx < self.action_count) {
            const act = self.actions[row_idx];
            if (act.enabled and act.visible) {
                return act.id;
            }
        }
        return null;
    }

    fn rowAt(self: *const TrayMenu, px: i32, py: i32) ?usize {
        if (px < 8 or px >= @as(i32, @intCast(self.width)) - 8) return null;
        const start_y: i32 = @as(i32, @intCast(self.header_h)) + 6;
        if (py < start_y) return null;
        const rel_y = py - start_y;
        const idx: usize = @intCast(@divTrunc(rel_y, @as(i32, @intCast(self.row_h))));
        if (idx < self.action_count) {
            return idx;
        }
        return null;
    }
};

test "TrayMenu basic initialization and click detection" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var actions: [MAX_TRAY_MENU_ACTIONS]c.MizuTrayMenuAction = undefined;
    actions[0] = .{
        .id = 10,
        .label = @splat(0),
        .enabled = true,
        .visible = true,
        .is_separator = false,
    };
    @memcpy(actions[0].label[0..4], "Quit");

    actions[1] = .{
        .id = 11,
        .label = @splat(0),
        .enabled = false,
        .visible = true,
        .is_separator = false,
    };
    @memcpy(actions[1].label[0..5], "Muted");

    const req = TrayMenuRequest{
        .service = @splat(0),
        .path = @splat(0),
        .menu_path = @splat(0),
        .id = @splat(0),
        .title = @splat(0),
        .icon_name = @splat(0),
        .actions = actions,
        .action_count = 2,
        .item_x = 100,
        .item_y = 4,
        .item_w = 28,
        .item_h = 28,
    };

    var menu = try TrayMenu.init(allocator, cfg, req);
    defer menu.deinit();

    try std.testing.expect(menu.width >= 120);
    try std.testing.expect(menu.height > 60);

    // Row 0 click (y in 6..36)
    try std.testing.expectEqual(@as(?i32, 10), menu.handleClick(20, 20));

    // Row 1 click (disabled)
    try std.testing.expectEqual(@as(?i32, null), menu.handleClick(20, 50));
}
