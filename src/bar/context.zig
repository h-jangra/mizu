const std = @import("std");
const renderer = @import("../core/renderer.zig");
const theme = @import("../core/theme.zig");
const config = @import("../core/config.zig");
const sys_status = @import("../services/system_status.zig");
const mango_ipc = @import("../services/mango_ipc.zig");
const ui_mod = @import("../core/ui.zig");
const c = @import("c");

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
    menu_path: [128]u8 = @splat(0),
    id: [64]u8 = @splat(0),
    title: [128]u8 = @splat(0),
    icon_name: [128]u8 = @splat(0),
};

pub const ActiveTrayMenu = struct {
    service: [128]u8,
    path: [128]u8,
    menu_path: [128]u8,
    id: [64]u8,
    title: [128]u8,
    icon_name: [128]u8,
    actions: [16]c.MizuTrayMenuAction,
    action_count: usize,
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
    tray_menu_action: struct {
        action_id: i32,
    },
    tray_menu_close,
};

pub const ClickableArea = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    action: ClickAction,
    scroll: ?ScrollAction = null,
};

pub const PendingClick = struct {
    name: []const u8,
    index: u32,
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
    pending_clicks: *std.ArrayList(PendingClick),
    hover_x: i32,
    hover_y: i32,
    chip_y: i32,
    chip_h: u32,
    baseline_y: i32,
    current_theme_kind: theme.ThemeKind,
    scale: u32 = 1,
    active_tray_menu: ?*const ActiveTrayMenu = null,

    /// Register a click target for a widget after layout.
    pub fn linkClick(
        self: *BarContext,
        ui: *ui_mod.Ui,
        name: []const u8,
        index: u32,
        action: ClickAction,
        scroll: ?ScrollAction,
    ) !void {
        try self.pending_clicks.append(self.allocator, .{
            .name = name,
            .index = index,
            .action = action,
            .scroll = scroll,
        });
        _ = ui;
    }

    pub fn textFontSize(self: *const BarContext) u32 {
        const logical_chip_h: u32 = if (self.cfg.height > 8) self.cfg.height - 8 else self.cfg.height;
        const max_text: u32 = if (logical_chip_h > 4) logical_chip_h - 4 else logical_chip_h;
        const base_text = @min(self.cfg.typography.bar_text, max_text);
        return base_text * self.scale;
    }

    pub fn iconFontSize(self: *const BarContext) u32 {
        const logical_chip_h: u32 = if (self.cfg.height > 8) self.cfg.height - 8 else self.cfg.height;
        const max_icon: u32 = if (logical_chip_h > 6) logical_chip_h - 6 else logical_chip_h;
        const base_icon = @min(self.cfg.typography.bar_icon, max_icon);
        return base_icon * self.scale;
    }
};
