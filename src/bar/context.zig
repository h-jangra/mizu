const std = @import("std");
const renderer = @import("../core/renderer.zig");
const theme = @import("../core/theme.zig");
const config = @import("../core/config.zig");
const sys_status = @import("../services/system_status.zig");
const mango_ipc = @import("../services/mango_ipc.zig");

pub const ScrollAction = union(enum) {
    volume,
    backlight,
    cycle_theme,
    command: struct {
        up: []const u8,
        down: []const u8,
    },
};

pub const TrayItemAction = struct {
    index: u32,
    service: [128]u8,
    path: [128]u8,
};

pub const ClickAction = union(enum) {
    workspace: u32,
    command: []const u8,
    dual_command: struct {
        left: []const u8,
        right: []const u8,
    },
    cycle_theme: bool, // true for forward, false for backward
    tray_item: TrayItemAction,
};

pub const ClickableArea = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    action: ClickAction,
    scroll: ?ScrollAction = null,
};

pub const BarContext = struct {
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    font: *renderer.Font,
    sys: *sys_status.SysStatus,
    ipc: *const mango_ipc.MangoIpc,
    clickable_areas: *std.ArrayList(ClickableArea),
    hover_x: i32,
    hover_y: i32,
    chip_y: i32,
    chip_h: u32,
    baseline_y: i32,
    current_theme_kind: theme.ThemeKind,
    scale: u32 = 1,

    pub fn isHovered(self: *const BarContext, x: i32, y: i32, w: u32, h: u32) bool {
        return (self.hover_x >= x and self.hover_x < x + @as(i32, @intCast(w)) and
            self.hover_y >= y and self.hover_y < y + @as(i32, @intCast(h)));
    }

    pub fn addInteractiveArea(self: *BarContext, x: i32, y: i32, w: u32, h: u32, action: ClickAction, scroll: ?ScrollAction) !void {
        try self.clickable_areas.append(self.allocator, .{
            .x = x,
            .y = y,
            .w = w,
            .h = h,
            .action = action,
            .scroll = scroll,
        });
    }

    pub fn addClickable(self: *BarContext, x: i32, y: i32, w: u32, h: u32, action: ClickAction) !void {
        try self.addInteractiveArea(x, y, w, h, action, null);
    }

    pub fn drawChipBase(self: *const BarContext, target: renderer.Renderer, x: i32, y: i32, w: u32, h: u32, bg: theme.Color) void {
        const is_hov = self.isHovered(x, y, w, h);
        const radius = self.cfg.pill_radius;

        var final_bg = bg;
        if (is_hov) {
            final_bg = if (bg.a == 0)
                theme.Color.init(35, 255, 255, 255)
            else
                theme.Color.init(@min(255, @as(u16, bg.a) + 30), @min(255, @as(u16, bg.r) + 15), @min(255, @as(u16, bg.g) + 15), @min(255, @as(u16, bg.b) + 15));
        }

        if (final_bg.a > 0) {
            target.fillRoundedRect(x, y, w, h, radius, final_bg);
        }

        const border_col = if (is_hov)
            self.cfg.theme.accent
        else if (self.cfg.theme.pill_border.a > 0)
            self.cfg.theme.pill_border
        else
            theme.Color.init(30, 255, 255, 255);
        target.drawRoundedBorder(x, y, w, h, radius, 1, border_col);
    }

    pub fn textFontSize(self: *const BarContext) u32 {
        return self.cfg.typography.bar_text * self.scale;
    }

    pub fn iconFontSize(self: *const BarContext) u32 {
        return self.cfg.typography.bar_icon * self.scale;
    }

    pub fn iconBaseline(self: *const BarContext) i32 {
        return self.chip_y +
            @divTrunc(@as(i32, @intCast(self.chip_h)) + @as(i32, @intCast(self.iconFontSize() * 3 / 4)), 2) - 1;
    }

    pub fn drawChip(
        self: *const BarContext,
        target: renderer.Renderer,
        x: i32,
        y: i32,
        w: u32,
        h: u32,
        text: []const u8,
        bg: theme.Color,
        fg: theme.Color,
    ) void {
        self.drawChipBase(target, x, y, w, h, bg);
        const font_size = self.textFontSize();
        const text_w = target.measureTextWithSize(self.font, text, font_size);
        const tx = x + @divTrunc(@as(i32, @intCast(w)) - @as(i32, @intCast(text_w)), 2);
        target.drawTextWithSize(self.font, text, tx, self.baseline_y, font_size, fg);
    }

    pub fn drawChipWithIcon(
        self: *const BarContext,
        target: renderer.Renderer,
        x: i32,
        y: i32,
        w: u32,
        h: u32,
        icon: []const u8,
        icon_color: theme.Color,
        text: []const u8,
        text_color: theme.Color,
        bg: theme.Color,
    ) void {
        self.drawChipBase(target, x, y, w, h, bg);
        const icon_size = self.iconFontSize();
        const text_size = self.textFontSize();
        const icon_w = target.measureTextWithSize(self.font, icon, icon_size);
        const text_w = if (text.len > 0) target.measureTextWithSize(self.font, text, text_size) else 0;
        const gap: u32 = if (text.len > 0) 6 * self.scale else 0;
        const total_content = icon_w + gap + text_w;
        const start_x = x + @divTrunc(@as(i32, @intCast(w)) - @as(i32, @intCast(total_content)), 2);

        target.drawTextWithSize(self.font, icon, start_x, self.iconBaseline(), icon_size, icon_color);
        if (text.len > 0) {
            target.drawTextWithSize(self.font, text, start_x + @as(i32, @intCast(icon_w + gap)), self.baseline_y, text_size, text_color);
        }
    }
};
