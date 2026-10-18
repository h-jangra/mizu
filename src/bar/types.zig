const std = @import("std");
const renderer = @import("../renderer.zig");
const theme = @import("../theme.zig");
const config = @import("../config.zig");
const sys_status = @import("../sys_status.zig");
const mango_ipc = @import("../mango_ipc.zig");

pub const ClickAction = union(enum) {
    workspace: u32,
    command: []const u8,
    dual_command: struct {
        left: []const u8,
        right: []const u8,
    },
    cycle_theme: bool, // true for forward, false for backward
};

pub const ClickableArea = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    action: ClickAction,
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

    pub fn isHovered(self: *const BarContext, x: i32, y: i32, w: u32, h: u32) bool {
        return (self.hover_x >= x and self.hover_x < x + @as(i32, @intCast(w)) and
            self.hover_y >= y and self.hover_y < y + @as(i32, @intCast(h)));
    }

    pub fn addClickable(self: *BarContext, x: i32, y: i32, w: u32, h: u32, action: ClickAction) !void {
        try self.clickable_areas.append(self.allocator, .{
            .x = x,
            .y = y,
            .w = w,
            .h = h,
            .action = action,
        });
    }

    pub fn drawChipBase(self: *const BarContext, target: renderer.Renderer, x: i32, y: i32, w: u32, h: u32, bg: theme.Color) void {
        const is_hov = self.isHovered(x, y, w, h);
        const final_bg = if (is_hov)
            theme.Color.init(@min(255, @as(u16, bg.a) + 35), @min(255, @as(u16, bg.r) + 20), @min(255, @as(u16, bg.g) + 20), @min(255, @as(u16, bg.b) + 20))
        else
            bg;
        target.fillSquircle(x, y, w, h, self.cfg.pill_radius, final_bg);
        if (is_hov) {
            target.drawSquircleBorder(x, y, w, h, self.cfg.pill_radius, 1, self.cfg.theme.pill_hover);
        } else if (self.cfg.theme.pill_border.a > 0) {
            target.drawSquircleBorder(x, y, w, h, self.cfg.pill_radius, 1, self.cfg.theme.pill_border);
        }
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
        const text_w = target.measureText(self.font, text);
        const tx = x + @divTrunc(@as(i32, @intCast(w)) - @as(i32, @intCast(text_w)), 2);
        target.drawText(self.font, text, tx, self.baseline_y, fg);
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
        const icon_w = target.measureText(self.font, icon);
        const text_w = if (text.len > 0) target.measureText(self.font, text) else 0;
        const gap: u32 = if (text.len > 0) 6 else 0;
        const total_content = icon_w + gap + text_w;
        const start_x = x + @divTrunc(@as(i32, @intCast(w)) - @as(i32, @intCast(total_content)), 2);

        target.drawText(self.font, icon, start_x, self.baseline_y, icon_color);
        if (text.len > 0) {
            target.drawText(self.font, text, start_x + @as(i32, @intCast(icon_w + gap)), self.baseline_y, text_color);
        }
    }
};
