const battery = @import("battery.zig");
const sys_status = @import("../../services/system_status.zig");
const ui_mod = @import("../../core/ui.zig");
const types = @import("types.zig");

const Action = types.Action;

pub fn profileSubtitle(profile: anytype) []const u8 {
    return switch (profile) {
        .power_saver => "Power Saver",
        .balanced => "Balanced",
        .performance => "Performance",
    };
}

pub fn profileIcon(profile: anytype) []const u8 {
    return switch (profile) {
        .power_saver => "saver",
        .balanced => "balanced",
        .performance => "performance",
    };
}

pub fn handleAction(panel: anytype, action: Action) bool {
    switch (action) {
        .cycle_power_profile => {
            switch (panel.sys.power_profile) {
                .power_saver => panel.sys.setPowerProfile(.balanced),
                .balanced => panel.sys.setPowerProfile(.performance),
                .performance => panel.sys.setPowerProfile(.power_saver),
            }
            return true;
        },
        .set_power_profile_saver => {
            panel.sys.setPowerProfile(.power_saver);
            return true;
        },
        .set_power_profile_balanced => {
            panel.sys.setPowerProfile(.balanced);
            return true;
        },
        .set_power_profile_performance => {
            panel.sys.setPowerProfile(.performance);
            return true;
        },
        else => return false,
    }
}

pub fn renderMainCard(panel: anytype, ui: *ui_mod.Ui, scale: u32, icon_sz: u32, ui_sz: u32, sec_sz: u32) !void {
    const icon_name = profileIcon(panel.sys.power_profile);
    try panel.renderExpandableCard(ui, 3, icon_name, icon_name, "Power Mode", profileSubtitle(panel.sys.power_profile), (panel.sys.power_profile != .balanced), icon_sz, ui_sz, sec_sz, scale);
}

pub fn renderMenu(panel: anytype, ui: *ui_mod.Ui, scale: u32, sub_sz: u32) void {
    const profiles = [_]struct {
        profile: sys_status.PowerProfile,
        title: []const u8,
        icon_name: []const u8,
    }{
        .{ .profile = .power_saver, .title = "Power Saver", .icon_name = "saver" },
        .{ .profile = .balanced, .title = "Balanced", .icon_name = "balanced" },
        .{ .profile = .performance, .title = "Performance", .icon_name = "performance" },
    };
    for (profiles, 0..) |p, idx| {
        const sel = (panel.sys.power_profile == p.profile);
        const hov = ui.hovered("qs-power-profile", @intCast(idx));
        _ = ui.open(.{
            .id = "qs-power-profile",
            .index = @intCast(idx),
            .width = .{ .grow = .{} },
            .height = .{ .fixed = ui.s(42) },
            .direction = .row,
            .padding = .{ .left = ui.su(12), .right = ui.su(12) },
            .gap = ui.su(10),
            .bg = if (sel) panel.cfg.theme.elevated else if (hov) panel.cfg.theme.card_hover_bg else panel.cfg.theme.card_bg,
            .radius = ui.f(10),
            .align_y = .center,
        });
        ui.icon(p.icon_name, 20 * scale, if (sel) panel.cfg.theme.accent else panel.cfg.theme.text_bright, 0);
        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
            .padding = .{ .left = ui.su(6) },
            .align_y = .center,
        });
        ui.text(p.title, .{ .size = sub_sz, .color = if (sel) panel.cfg.theme.accent else panel.cfg.theme.text_bright });
        ui.close();
        if (sel) {
            ui.icon("check", 16 * scale, panel.cfg.theme.accent, 0);
        }
        ui.close();
    }

    battery.renderPowerStatus(panel, ui, scale);
}

pub fn appendHitAreas(panel: anytype, ui: *ui_mod.Ui, scale: u32) !void {
    if (ui.rectOf("qs-power-profile", 0)) |rect| try types.appendHitArea(panel, rect, scale, .set_power_profile_saver);
    if (ui.rectOf("qs-power-profile", 1)) |rect| try types.appendHitArea(panel, rect, scale, .set_power_profile_balanced);
    if (ui.rectOf("qs-power-profile", 2)) |rect| try types.appendHitArea(panel, rect, scale, .set_power_profile_performance);
}
