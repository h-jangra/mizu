const std = @import("std");
const c = @import("../c.zig").c;
const theme = @import("../theme.zig");
const config = @import("../config.zig");
const renderer = @import("../renderer.zig");
const mango_ipc = @import("../mango_ipc.zig");
const sys_status = @import("../sys_status.zig");

pub const types = @import("types.zig");
pub const ClickAction = types.ClickAction;
pub const ClickableArea = types.ClickableArea;
pub const BarContext = types.BarContext;

pub const launcher = @import("launcher_pill.zig");
pub const omarchy = launcher;
pub const workspaces = @import("workspaces.zig");
pub const custom_buttons = @import("custom_buttons.zig");
pub const mpris = @import("mpris.zig");
pub const clock = @import("clock.zig");
pub const battery = @import("battery.zig");
pub const memory = @import("memory.zig");
pub const network = @import("network.zig");
pub const bluetooth = @import("bluetooth.zig");
pub const volume = @import("volume.zig");
// pub const backlight = @import("backlight.zig");
pub const theme_switch = @import("theme_switch.zig");
pub const separator = @import("separator.zig");

pub const Bar = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    font: renderer.Font,
    sys_status: sys_status.SysStatus,
    clickable_areas: std.ArrayList(ClickableArea),
    hover_x: i32 = -1,
    hover_y: i32 = -1,
    vol_area: ?ClickableArea = null,
    bl_area: ?ClickableArea = null,
    theme_area: ?ClickableArea = null,
    current_theme_kind: theme.ThemeKind = .nord,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !Bar {
        const font = try renderer.Font.init(allocator, cfg.theme.font_family, cfg.theme.font_size);
        const sys = sys_status.SysStatus.init(allocator);

        return .{
            .allocator = allocator,
            .cfg = cfg,
            .font = font,
            .sys_status = sys,
            .clickable_areas = std.ArrayList(ClickableArea).empty,
            .current_theme_kind = cfg.theme.kind,
        };
    }

    pub fn deinit(self: *Bar) void {
        self.clickable_areas.deinit(self.allocator);
        self.font.deinit();
    }

    pub fn tick(self: *Bar) void {
        self.sys_status.tick();
        if (theme.loadSavedTheme()) |saved| {
            if (saved != self.current_theme_kind) {
                self.current_theme_kind = saved;
                self.cfg.theme = saved.toTheme();
            }
        }
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
        if (self.vol_area) |area| {
            if (x >= area.x and x < area.x + @as(i32, @intCast(area.w)) and
                y >= area.y and y < area.y + @as(i32, @intCast(area.h)))
            {
                if (scroll_delta < 0) {
                    sys_status.spawnCmd("wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+");
                } else {
                    sys_status.spawnCmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-");
                }
                self.sys_status.updateVolume();
                return true;
            }
        }

        if (self.bl_area) |area| {
            if (x >= area.x and x < area.x + @as(i32, @intCast(area.w)) and
                y >= area.y and y < area.y + @as(i32, @intCast(area.h)))
            {
                if (scroll_delta < 0) {
                    sys_status.spawnCmd("brightnessctl set +5%");
                } else {
                    sys_status.spawnCmd("brightnessctl set 5%-");
                }
                self.sys_status.updateBacklight();
                return true;
            }
        }

        if (self.theme_area) |area| {
            if (x >= area.x and x < area.x + @as(i32, @intCast(area.w)) and
                y >= area.y and y < area.y + @as(i32, @intCast(area.h)))
            {
                self.cycleTheme(scroll_delta < 0);
                return true;
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
                        if (button == 272) { // BTN_LEFT: switch to workspace
                            ipc.switchWorkspace(ws_idx);
                        } else if (button == 273) { // BTN_RIGHT: toggle workspace in current view
                            ipc.toggleWorkspace(ws_idx);
                        }
                    },
                    .command => |cmd| {
                        if (button == 272) {
                            self.spawnCommand(cmd);
                        }
                    },
                    .dual_command => |dual| {
                        if (button == 272) {
                            self.spawnCommand(dual.left);
                        } else if (button == 273) {
                            self.spawnCommand(dual.right);
                        }
                    },
                    .cycle_theme => {
                        if (button == 272) {
                            self.cycleTheme(true);
                        } else if (button == 273) {
                            self.cycleTheme(false);
                        }
                    },
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

        const new_th = self.current_theme_kind.toTheme();
        self.cfg.theme = new_th;
        theme.saveCurrentTheme(self.current_theme_kind);
    }

    fn spawnCommand(self: *Bar, cmd: []const u8) void {
        const pid = c.fork();
        if (pid == 0) {
            _ = c.setsid();
            const c_cmd = self.allocator.dupeZ(u8, cmd) catch c.exit(1);
            _ = c.execl("/bin/sh", "sh", "-c", c_cmd.ptr, @as(?*anyopaque, null));
            c.exit(1);
        }
    }

    pub fn render(
        self: *Bar,
        target_renderer: renderer.Renderer,
        ipc: *const mango_ipc.MangoIpc,
    ) !void {
        self.clickable_areas.clearRetainingCapacity();

        const w = target_renderer.width;
        const h = target_renderer.height;

        // 1. Transparent base layer
        target_renderer.clear(theme.Color.transparent);

        // 2. Floating Bar Box with Squircle curvature and smooth Noctalia-style glass illumination
        const box_h = if (h > 4) h - 2 else h;
        target_renderer.fillGlassSquircle(0, 0, w, box_h, self.cfg.bar_radius, self.cfg.theme.bar_bg);
        target_renderer.drawSquircleBorder(0, 0, w, box_h, self.cfg.bar_radius, 1, self.cfg.theme.bar_border);

        const chip_h = if (box_h > 6) box_h - 6 else box_h;
        const chip_y: i32 = 3;
        const baseline_y = chip_y + @divTrunc(@as(i32, @intCast(chip_h)) + self.font.ascender_px, 2);

        var ctx = BarContext{
            .allocator = self.allocator,
            .cfg = &self.cfg,
            .font = &self.font,
            .sys = &self.sys_status,
            .ipc = ipc,
            .clickable_areas = &self.clickable_areas,
            .hover_x = self.hover_x,
            .hover_y = self.hover_y,
            .chip_y = chip_y,
            .chip_h = chip_h,
            .baseline_y = baseline_y,
            .current_theme_kind = self.current_theme_kind,
        };

        // ======================== Left Section ========================
        var cur_x: i32 = 4;

        // 1. App Launcher: Theme squircle pill with icon
        cur_x = try launcher.render(&ctx, target_renderer, cur_x);

        // 2. hyprland/workspaces: Unicode Roman numerals (only render separator if workspaces exist)
        var has_workspaces = false;
        for (ctx.ipc.tags) |tag| {
            if (tag.is_active or tag.is_urgent or tag.client_count > 0) {
                has_workspaces = true;
                break;
            }
        }
        if (has_workspaces) {
            cur_x = separator.render(&ctx, target_renderer, cur_x);
            cur_x = try workspaces.render(&ctx, target_renderer, cur_x);
        }

        // 3. Custom Quick-Launch Buttons (if defined in config)
        if (self.cfg.buttons.items.len > 0) {
            cur_x = separator.render(&ctx, target_renderer, cur_x);
            cur_x = try custom_buttons.render(&ctx, target_renderer, cur_x);
        }

        // ======================== Center Section ========================
        // 1. Clock centered in the middle of the bar (clean text only, no icon)
        const clock_info = try clock.renderCenter(&ctx, target_renderer, w);

        // 2. MPRIS (if playing/paused, placed nicely to the left of the centered clock)
        try mpris.render(&ctx, target_renderer, clock_info.x, cur_x);

        // ======================== Right Section ========================
        // Built from right edge towards left
        var right_x: i32 = @as(i32, @intCast(w)) - 6;

        // 1. Battery (if present)
        if (self.sys_status.has_battery) {
            right_x = try battery.render(&ctx, target_renderer, right_x);
            right_x -= 6;
            right_x = separator.renderRight(&ctx, target_renderer, right_x);
        }

        // 2. Memory
        right_x = try memory.render(&ctx, target_renderer, right_x);

        right_x -= 4;

        // 3. Network (Wi-Fi: compact icon, expands on hover)
        right_x = try network.render(&ctx, target_renderer, right_x);

        // 4. Bluetooth (only when connected)
        const new_bt_x = try bluetooth.render(&ctx, target_renderer, right_x - 4);
        if (new_bt_x != right_x - 4) {
            right_x = new_bt_x - 4;
        } else {
            right_x -= 4;
        }

        // 6. Volume
        const vol_res = try volume.render(&ctx, target_renderer, right_x);
        right_x = vol_res.new_x;
        self.vol_area = vol_res.area;

        right_x -= 6;
        right_x = separator.renderRight(&ctx, target_renderer, right_x);

        // 6. Theme Switcher Module
        const theme_res = try theme_switch.render(&ctx, target_renderer, right_x);
        right_x = theme_res.new_x;
        self.theme_area = theme_res.area;
    }
};
