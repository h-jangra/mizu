const std = @import("std");
const c = @import("c");
const theme = @import("../core/theme.zig");
const config = @import("../core/config.zig");
const renderer = @import("../core/renderer.zig");
const ui_mod = @import("../core/ui.zig");
const mango_ipc = @import("../services/mango_ipc.zig");
const sys_status = @import("../services/system_status.zig");
const exec = @import("../core/exec.zig");
const tray_menu_mod = @import("../panels/tray_menu.zig");

pub const types = @import("context.zig");
pub const ClickAction = types.ClickAction;
pub const ClickableArea = types.ClickableArea;
pub const ScrollAction = types.ScrollAction;
pub const BarContext = types.BarContext;

// Bar Modules
pub const launcher = @import("launcher_pill.zig");
pub const workspaces = @import("workspaces.zig");
pub const custom_buttons = @import("custom_buttons.zig");
pub const keymaps = @import("keymaps.zig");
pub const mpris = @import("mpris.zig");
pub const clock = @import("clock.zig");
pub const recorder = @import("recorder.zig");
pub const tray = @import("tray.zig");
pub const battery = @import("battery.zig");
pub const memory = @import("memory.zig");
pub const network = @import("network.zig");
pub const volume = @import("volume.zig");
pub const quicksettings = @import("quicksettings_pill.zig");
pub const theme_switch = @import("theme_switch.zig");
pub const separator = @import("separator.zig");

pub const Bar = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    font: renderer.Font,
    sys_status: sys_status.SysStatus,
    clickable_areas: std.ArrayList(ClickableArea),
    pending_clicks: std.ArrayList(types.PendingClick),
    hover_x: i32 = -1,
    hover_y: i32 = -1,
    current_theme_kind: theme.ThemeKind = .nord,
    last_visual_hash: u64 = 0,
    open_menu_request: ?tray_menu_mod.TrayMenuRequest = null,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !Bar {
        const font = try renderer.Font.init(allocator, cfg.theme.font_family, cfg.typography.bar_text);
        const sys = sys_status.SysStatus.init(allocator);

        return .{
            .allocator = allocator,
            .cfg = cfg,
            .font = font,
            .sys_status = sys,
            .clickable_areas = std.ArrayList(ClickableArea).empty,
            .pending_clicks = std.ArrayList(types.PendingClick).empty,
            .current_theme_kind = cfg.theme.kind,
        };
    }

    pub fn deinit(self: *Bar) void {
        self.clickable_areas.deinit(self.allocator);
        self.pending_clicks.deinit(self.allocator);
        self.font.deinit();
        self.sys_status.deinit();
    }

    /// Refresh system state and report whether anything visible changed.
    /// The event loop uses this to avoid redrawing the bar while idle.
    pub fn tick(self: *Bar) bool {
        self.sys_status.tick();
        const hash = self.visualHash();
        if (hash == self.last_visual_hash) return false;
        self.last_visual_hash = hash;
        return true;
    }

    /// Reload the theme after SIGUSR1. Returns true when the theme changed.
    pub fn reloadTheme(self: *Bar) bool {
        const saved = theme.loadSavedTheme() orelse return false;
        if (saved == self.current_theme_kind) return false;
        self.current_theme_kind = saved;
        self.cfg.theme = theme.loadTheme(saved.id());
        self.last_visual_hash = 0;
        return true;
    }

    fn visualHash(self: *const Bar) u64 {
        var hasher = std.hash.Wyhash.init(0);
        const sys = &self.sys_status;

        var clock_buf: [64]u8 = undefined;
        const clock_label = clock.formatNow(self.cfg.clock_format, &clock_buf);
        hasher.update(clock_label);

        const mem_tenths: i64 = @intFromFloat(@round(@as(f64, sys.mem_used_gib) * 10.0));
        const bat_minutes: i64 = if (sys.bat_seconds_remaining) |seconds| @divTrunc(seconds, 60) else -1;
        const recorder_active = recorder.isRecordingActive();

        const values = [_]struct { key: u8, value: i64 }{
            .{ .key = 1, .value = @as(i64, @backingInt(self.current_theme_kind)) },
            .{ .key = 2, .value = mem_tenths },
            .{ .key = 3, .value = sys.volume_percent },
            .{ .key = 4, .value = @intFromBool(sys.volume_muted) },
            .{ .key = 5, .value = @as(i64, @backingInt(sys.mpris_state)) },
            .{ .key = 6, .value = @intFromBool(sys.has_battery) },
            .{ .key = 7, .value = sys.bat_capacity },
            .{ .key = 8, .value = @as(i64, @backingInt(sys.bat_status)) },
            .{ .key = 9, .value = bat_minutes },
            .{ .key = 10, .value = @intFromBool(sys.wifi_enabled) },
            .{ .key = 11, .value = @intFromBool(sys.bluetooth_enabled) },
            .{ .key = 12, .value = @intFromBool(sys.bluetooth_connected) },
            .{ .key = 13, .value = @intFromBool(recorder_active) },
        };
        for (values) |entry| {
            var key = [_]u8{entry.key};
            hasher.update(&key);
            hasher.update(std.mem.asBytes(&entry.value));
        }

        hasher.update(sys.mpris_track[0..sys.mpris_track_len]);
        hasher.update(sys.wifi_ssid[0..sys.wifi_ssid_len]);
        hasher.update(sys.bluetooth_device[0..sys.bluetooth_device_len]);

        return hasher.final();
    }

    pub fn handlePointerMotion(self: *Bar, x: i32, y: i32) bool {
        const old_hover = self.getHoveredAreaIndex();
        self.hover_x = x;
        self.hover_y = y;
        const new_hover = self.getHoveredAreaIndex();
        return old_hover != new_hover;
    }

    pub fn handlePointerLeave(self: *Bar) bool {
        const old_hover = self.getHoveredAreaIndex();
        self.hover_x = -1;
        self.hover_y = -1;
        return old_hover != null;
    }

    pub fn getHoveredAreaIndex(self: *const Bar) ?usize {
        if (self.hover_x < 0 or self.hover_y < 0) return null;
        for (self.clickable_areas.items, 0..) |area, idx| {
            if (self.hover_x >= area.x and self.hover_x < area.x + @as(i32, @intCast(area.w)) and
                self.hover_y >= area.y and self.hover_y < area.y + @as(i32, @intCast(area.h)))
            {
                return idx;
            }
        }
        return null;
    }

    pub fn handlePointerAxis(self: *Bar, x: i32, y: i32, scroll_delta: i32) bool {
        for (self.clickable_areas.items) |area| {
            if (x >= area.x and x < area.x + @as(i32, @intCast(area.w)) and
                y >= area.y and y < area.y + @as(i32, @intCast(area.h)))
            {
                if (area.scroll) |s| {
                    switch (s) {
                        .volume => {
                            self.sys_status.stepVolume(if (scroll_delta < 0) 1 else -1);
                            return true;
                        },
                        .backlight => {
                            if (scroll_delta < 0) {
                                sys_status.spawnCmd("brightnessctl set +1%");
                            } else {
                                sys_status.spawnCmd("brightnessctl set 1%-");
                            }
                            self.sys_status.updateBacklight();
                            return true;
                        },
                        .cycle_theme => {
                            self.cycleTheme(scroll_delta < 0);
                            return true;
                        },
                        .command => |cmd| {
                            if (scroll_delta < 0) {
                                exec.spawnShell(cmd.up);
                            } else {
                                exec.spawnShell(cmd.down);
                            }
                            return true;
                        },
                    }
                }
            }
        }
        return false;
    }

    pub fn isPointer(self: *Bar, x: i32, y: i32) bool {
        for (self.clickable_areas.items) |area| {
            if (x >= area.x and x < area.x + @as(i32, @intCast(area.w)) and
                y >= area.y and y < area.y + @as(i32, @intCast(area.h)))
            {
                return true;
            }
        }
        return false;
    }

    pub fn handleClick(self: *Bar, x: i32, y: i32, button: u32, ipc: *mango_ipc.MangoIpc) void {
        for (self.clickable_areas.items) |area| {
            if (x >= area.x and x < area.x + @as(i32, @intCast(area.w)) and
                y >= area.y and y < area.y + @as(i32, @intCast(area.h)))
            {
                switch (area.action) {
                    .workspace => |ws_idx| {
                        if (button == 272) {
                            if (ipc.isWorkspaceActive(ws_idx)) {
                                ipc.switchPreviousWorkspace();
                            } else {
                                ipc.switchWorkspace(ws_idx);
                            }
                        } else if (button == 273) {
                            if (ipc.isWorkspaceActive(ws_idx)) {
                                ipc.switchLayout();
                            } else {
                                ipc.toggleWorkspace(ws_idx);
                            }
                        }
                    },
                    .command => |cmd| {
                        if (button == 272) {
                            exec.spawnShell(cmd);
                        }
                    },
                    .dual_command => |dual| {
                        if (button == 272) {
                            if (std.mem.indexOf(u8, dual.left, "wpctl set-mute") != null) {
                                self.sys_status.toggleVolumeMute();
                            } else {
                                exec.spawnShell(dual.left);
                            }
                        } else if (button == 273) {
                            if (std.mem.indexOf(u8, dual.right, "wpctl set-mute") != null) {
                                self.sys_status.toggleVolumeMute();
                            } else {
                                exec.spawnShell(dual.right);
                            }
                        }
                    },
                    .cycle_theme => {
                        if (button == 272) {
                            self.cycleTheme(true);
                        } else if (button == 273) {
                            self.cycleTheme(false);
                        }
                    },
                    .tray_item => |item| {
                        const s_ptr = @as([*:0]const u8, @ptrCast(&item.service));
                        const p_ptr = @as([*:0]const u8, @ptrCast(&item.path));
                        const m_ptr = @as([*:0]const u8, @ptrCast(&item.menu_path));
                        if (button == 272) {
                            tray.activateItem(s_ptr, p_ptr, x, y);
                        } else if (button == 273) {
                            var actions: [tray_menu_mod.MAX_TRAY_MENU_ACTIONS]c.MizuTrayMenuAction = undefined;
                            const count = tray.getMenuActions(s_ptr, m_ptr, &actions);
                            if (count > 0) {
                                self.open_menu_request = tray_menu_mod.TrayMenuRequest{
                                    .service = item.service,
                                    .path = item.path,
                                    .menu_path = item.menu_path,
                                    .id = item.id,
                                    .title = item.title,
                                    .icon_name = item.icon_name,
                                    .actions = actions,
                                    .action_count = count,
                                    .item_x = area.x,
                                    .item_y = area.y,
                                    .item_w = area.w,
                                    .item_h = area.h,
                                };
                            } else {
                                tray.contextMenuItem(s_ptr, p_ptr, x, y);
                            }
                        } else if (button == 274) {
                            tray.secondaryActivateItem(s_ptr, p_ptr, x, y);
                        }
                    },
                    .tray_menu_action => {},
                    .tray_menu_close => {},
                }
                break;
            }
        }
    }

    pub fn cycleTheme(self: *Bar, forward: bool) void {
        self.current_theme_kind = if (forward)
            self.current_theme_kind.next()
        else
            self.current_theme_kind.prev();

        const new_th = theme.selectTheme(self.current_theme_kind.id());
        self.cfg.theme = new_th;
        theme.saveCurrentTheme(self.current_theme_kind);
    }

    fn renderLeftModule(self: *Bar, mod: config.ModuleKind, ctx: *types.BarContext, ui: *ui_mod.Ui) !void {
        _ = self;
        switch (mod) {
            .launcher => try launcher.render(ctx, ui),
            .buttons => {
                if (ctx.cfg.buttons.items.len > 0) try custom_buttons.render(ctx, ui);
            },
            .workspaces => {
                var has_workspaces = false;
                for (ctx.ipc.tags) |tag| {
                    if (tag.is_active or tag.is_urgent or tag.client_count > 0) {
                        has_workspaces = true;
                        break;
                    }
                }
                if (has_workspaces) try workspaces.render(ctx, ui);
            },
            .keymaps => try keymaps.render(ctx, ui),
            .separator => try separator.render(ctx, ui),
            else => {},
        }
    }

    fn renderRightModule(self: *Bar, mod: config.ModuleKind, ctx: *types.BarContext, ui: *ui_mod.Ui) !void {
        _ = self;
        switch (mod) {
            .theme_switch => try theme_switch.render(ctx, ui),
            .volume => try volume.render(ctx, ui),
            .quicksettings => try quicksettings.render(ctx, ui),
            .recorder => try recorder.render(ctx, ui),
            .tray => try tray.render(ctx, ui),
            .network => try network.render(ctx, ui),
            .memory => try memory.render(ctx, ui),
            .battery => {
                if (ctx.sys.has_battery) try battery.render(ctx, ui);
            },
            .keymaps => try keymaps.render(ctx, ui),
            .separator => try separator.render(ctx, ui),
            else => {},
        }
    }

    pub fn render(
        self: *Bar,
        target_renderer: renderer.Renderer,
        ipc: *const mango_ipc.MangoIpc,
        scale: u32,
    ) !void {
        self.clickable_areas.clearRetainingCapacity();
        self.pending_clicks.clearRetainingCapacity();

        const w = target_renderer.width;
        const h = target_renderer.height;

        target_renderer.clear(theme.Color.transparent);

        const chip_y: i32 = @intCast(4 * @as(u32, scale));
        const chip_h: u32 = if (h > 8 * scale) h - 8 * scale else h;
        const scaled_ascender = self.font.ascender_px * @as(i32, @intCast(scale));
        const baseline_y = chip_y + @divTrunc(@as(i32, @intCast(chip_h)) + scaled_ascender, 2) - 1;

        var ctx = BarContext{
            .allocator = self.allocator,
            .cfg = &self.cfg,
            .font = &self.font,
            .sys = &self.sys_status,
            .ipc = ipc,
            .clickable_areas = &self.clickable_areas,
            .pending_clicks = &self.pending_clicks,
            .hover_x = self.hover_x,
            .hover_y = self.hover_y,
            .chip_y = chip_y,
            .chip_h = chip_h,
            .baseline_y = baseline_y,
            .current_theme_kind = self.current_theme_kind,
            .scale = scale,
        };

        var ui = try ui_mod.Ui.begin(
            self.allocator,
            &self.font,
            w,
            h,
            scale,
            self.hover_x,
            self.hover_y,
            false,
            1.0 / 60.0,
        );
        defer ui.deinit();

        const border_w: u16 = if (self.cfg.border_width > 0)
            @intCast(self.cfg.border_width * scale)
        else
            @intCast(@max(1, scale));
        ui.root(.{
            .direction = .row,
            .align_y = .center,
            .padding = .{
                .left = ui.su(4),
                .right = ui.su(6),
                .top = ui.su(4),
                .bottom = ui.su(4),
            },
            .gap = ui.su(4),
            .bg = self.cfg.theme.bar_bg,
            .radius = ui.f(self.cfg.bar_radius),
            .border = border_w,
            .border_color = self.cfg.theme.bar_border,
        });

        // Left half: modules followed by an elastic gap and (optionally) MPRIS.
        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
            .direction = .row,
            .align_x = .left,
            .align_y = .center,
            .gap = ui.su(4),
        });
        if (self.cfg.modules_left.items.len > 0) {
            for (self.cfg.modules_left.items) |mod| {
                try self.renderLeftModule(mod, &ctx, &ui);
            }
        } else {
            try self.renderLeftModule(.launcher, &ctx, &ui);
            try self.renderLeftModule(.keymaps, &ctx, &ui);
            try self.renderLeftModule(.buttons, &ctx, &ui);
            try self.renderLeftModule(.workspaces, &ctx, &ui);
        }
        ui.spacerSized(.{ .grow = .{} }, .{ .fixed = 0 });
        try mpris.render(&ctx, &ui);
        ui.close();

        // Exact horizontal centre: the two half containers grow equally.
        _ = ui.open(.{
            .width = .fit,
            .height = .{ .grow = .{} },
            .align_x = .center,
            .align_y = .center,
        });
        try clock.render(&ctx, &ui);
        ui.close();

        // Right half, rendered in reverse so the first configured module ends
        // up furthest to the right (matching the previous right-to-left API).
        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
            .direction = .row,
            .align_x = .right,
            .align_y = .center,
            .gap = ui.su(4),
        });
        if (self.cfg.modules_right.items.len > 0) {
            var i = self.cfg.modules_right.items.len;
            while (i > 0) {
                i -= 1;
                try self.renderRightModule(self.cfg.modules_right.items[i], &ctx, &ui);
            }
        } else {
            try self.renderRightModule(.theme_switch, &ctx, &ui);
            try self.renderRightModule(.recorder, &ctx, &ui);
            try self.renderRightModule(.memory, &ctx, &ui);
            try self.renderRightModule(.quicksettings, &ctx, &ui);
            try self.renderRightModule(.tray, &ctx, &ui);
        }
        ui.close();

        ui.close(); // root

        const commands = ui.endLayout();

        const iscale: i32 = @intCast(scale);
        for (self.pending_clicks.items) |pending| {
            const rect = ui.rectOf(pending.name, pending.index) orelse continue;
            const lx = @divTrunc(rect.x, iscale);
            const ly = @divTrunc(rect.y, iscale);
            const lw: u32 = @intCast(@divTrunc(@as(i32, @intCast(rect.w)) + iscale - 1, iscale));
            const lh: u32 = @intCast(@divTrunc(@as(i32, @intCast(rect.h)) + iscale - 1, iscale));
            if (lw == 0 or lh == 0) continue;
            try self.clickable_areas.append(self.allocator, .{
                .x = lx,
                .y = ly,
                .w = lw,
                .h = lh,
                .action = pending.action,
                .scroll = pending.scroll,
            });
        }

        ui.render(target_renderer, commands);
    }
};

test {
    std.testing.refAllDecls(@This());
}

test "Bar tray menu right-click and action dispatch" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var bar = try Bar.init(allocator, cfg);
    defer bar.deinit();

    try std.testing.expect(bar.open_menu_request == null);

    var act: types.TrayItemAction = undefined;
    act.index = 0;
    @memset(&act.service, 0);
    @memset(&act.path, 0);
    @memset(&act.menu_path, 0);
    @memset(&act.id, 0);
    @memset(&act.title, 0);
    @memset(&act.icon_name, 0);
    @memcpy(act.service[0..4], "test");

    try bar.clickable_areas.append(allocator, .{
        .x = 100,
        .y = 5,
        .w = 28,
        .h = 28,
        .action = .{ .tray_item = act },
    });

    var ipc: mango_ipc.MangoIpc = undefined;
    bar.handleClick(110, 10, 273, &ipc);
    // Since mock D-Bus returns fallback actions when service is unattached, open_menu_request is queued
    if (bar.open_menu_request) |req| {
        try std.testing.expect(req.action_count > 0);
        try std.testing.expectEqual(@as(i32, 100), req.item_x);
    }
}
