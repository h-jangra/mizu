const std = @import("std");
const sys_status = @import("../../services/system_status.zig");
const ui_mod = @import("../../core/ui.zig");
const types = @import("types.zig");

const Action = types.Action;
const QsLayout = types.QsLayout;

pub fn handleAction(panel: anytype, action: Action) bool {
    switch (action) {
        .lock => {
            sys_status.spawnCmd("mizu lock 2>/dev/null || swaylock -c 000000 2>/dev/null || loginctl lock-session 2>/dev/null || true");
            panel.running = false;
            return true;
        },
        .open_session_power_menu => {
            sys_status.spawnCmd("mizu session 2>/dev/null || true");
            panel.running = false;
            return true;
        },
        else => return false,
    }
}

pub fn renderHeader(panel: anytype, ui: *ui_mod.Ui, scale: u32) void {
    _ = ui.open(.{
        .width = .{ .grow = .{} },
        .height = .{ .fixed = ui.s(QsLayout.header_h) },
        .direction = .row,
        .padding = .{ .left = ui.su(12), .right = ui.su(12), .top = ui.su(6), .bottom = ui.su(6) },
        .gap = ui.su(8),
        .bg = null,
        .align_y = .center,
    });

    const bat_pct = if (panel.sys.has_battery) panel.sys.bat_capacity else 100;
    const plugged = panel.sys.ac_online;
    const is_charging = panel.sys.bat_status == .charging;
    const is_full = panel.sys.bat_status == .full;
    const bat_color = if (plugged or is_full) panel.cfg.theme.success_color else if (bat_pct <= 20) panel.cfg.theme.error_color else panel.cfg.theme.text_bright;
    const bat_svg = if (!panel.sys.has_battery) "plug" else if (is_charging) "battery-charging" else if (is_full or bat_pct >= 90) "battery-full" else if (bat_pct <= 20) "battery-empty" else if (bat_pct <= 50) "battery-low" else if (bat_pct <= 80) "battery-middle" else "battery-high";

    // Battery icon
    _ = ui.open(.{ .width = .{ .fixed = ui.s(48) }, .height = .{ .fixed = ui.s(48) }, .align_x = .center, .align_y = .center });
    ui.icon(bat_svg, 40 * scale, bat_color, 0);
    ui.close();

    // Battery percentage
    var pct_buf: [16]u8 = undefined;
    const pct_str = if (panel.sys.has_battery)
        std.fmt.bufPrint(&pct_buf, "{d}%", .{bat_pct}) catch ""
    else
        "AC";
    ui.text(pct_str, .{ .size = 22 * scale, .color = panel.cfg.theme.text_bright, .line_height = @intCast(24 * scale) });

    // Battery status
    const status_str = if (!panel.sys.has_battery)
        "AC Power"
    else switch (panel.sys.bat_status) {
        .charging => "Charging",
        .discharging => "On Battery",
        .full => "Fully Charged",
        else => if (plugged) "Plugged In" else "On Battery",
    };
    ui.text(status_str, .{ .size = 13 * scale, .color = panel.cfg.theme.text_muted });

    // Spacer between battery and buttons
    ui.spacerSized(.{ .grow = .{} }, .{ .fixed = 0 });

    // Lock and power buttons
    const lock_hov = ui.hovered("qs-header-btn", 0);
    const pwr_hov = ui.hovered("qs-header-btn", 1);
    for ([_]struct { icon: []const u8, act: Action, idx: u32, hov: bool }{
        .{ .icon = "lock", .act = .lock, .idx = 0, .hov = lock_hov },
        .{ .icon = "power", .act = .open_session_power_menu, .idx = 1, .hov = pwr_hov },
    }) |btn| {
        _ = ui.open(.{
            .id = "qs-header-btn",
            .index = btn.idx,
            .width = .{ .fixed = ui.s(36) },
            .height = .{ .fixed = ui.s(36) },
            .bg = if (btn.hov) panel.cfg.theme.card_hover_bg else panel.cfg.theme.card_bg,
            .radius = ui.f(18),
            .align_x = .center,
            .align_y = .center,
        });
        ui.icon(btn.icon, 16 * scale, if (btn.hov) panel.cfg.theme.accent else panel.cfg.theme.text_bright, 0);
        ui.close();
    }
    ui.close(); // header row
}

pub fn renderPowerStatus(panel: anytype, ui: *ui_mod.Ui, scale: u32) void {
    const bb_bat_pct = if (panel.sys.has_battery) panel.sys.bat_capacity else 100;
    const bb_plugged = panel.sys.ac_online;
    const bb_is_charging = panel.sys.bat_status == .charging;
    const bb_is_full = panel.sys.bat_status == .full;
    const bb_bat_color = if (bb_plugged or bb_is_full)
        panel.cfg.theme.success_color
    else if (bb_bat_pct <= 20)
        panel.cfg.theme.error_color
    else
        panel.cfg.theme.text_bright;
    const bb_bat_svg = if (bb_plugged or bb_is_charging)
        "battery-charging"
    else if (bb_bat_pct <= 20)
        "battery-empty"
    else if (bb_bat_pct <= 50)
        "battery-low"
    else if (bb_bat_pct <= 80)
        "battery-middle"
    else if (bb_bat_pct <= 90)
        "battery-high"
    else
        "battery-full";

    var bb_bat_buf: [64]u8 = undefined;
    const bb_bat_str = blk: {
        if (panel.sys.bat_seconds_remaining) |secs| {
            const hrs = @divTrunc(secs, 3600);
            const mins = @divTrunc(@rem(secs, 3600), 60);
            if (bb_is_charging) {
                if (hrs > 0) {
                    break :blk std.fmt.bufPrint(&bb_bat_buf, "{d}h {d}m to full", .{ hrs, mins }) catch "Charging";
                } else {
                    break :blk std.fmt.bufPrint(&bb_bat_buf, "{d}m to full", .{mins}) catch "Charging";
                }
            } else {
                if (hrs > 0) {
                    break :blk std.fmt.bufPrint(&bb_bat_buf, "{d}h {d}m left", .{ hrs, mins }) catch "Discharging";
                } else {
                    break :blk std.fmt.bufPrint(&bb_bat_buf, "{d}m left", .{mins}) catch "Discharging";
                }
            }
        } else {
            if (bb_is_full) {
                break :blk "Fully Charged";
            } else if (bb_is_charging) {
                break :blk "Charging";
            } else if (bb_plugged) {
                break :blk "Plugged In";
            } else {
                break :blk "On Battery";
            }
        }
    };

    _ = ui.open(.{
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .direction = .row,
        .align_x = .center,
        .align_y = .center,
        .gap = ui.su(10),
        .padding = .{ .top = ui.su(16), .bottom = ui.su(16) },
    });

    // Battery icon
    ui.icon(bb_bat_svg, 32 * scale, bb_bat_color, 0);

    // Battery percentage
    var pct_buf: [16]u8 = undefined;
    const pct_str = std.fmt.bufPrint(&pct_buf, "{d}%", .{bb_bat_pct}) catch "100%";
    ui.text(pct_str, .{
        .size = 20 * scale,
        .color = panel.cfg.theme.text_bright,
    });

    // Dot separator
    ui.text("·", .{
        .size = 16 * scale,
        .color = panel.cfg.theme.text_muted,
    });

    // Status / duration remaining label
    ui.text(bb_bat_str, .{
        .size = 15 * scale,
        .color = panel.cfg.theme.text_muted,
    });
    ui.close();
}
