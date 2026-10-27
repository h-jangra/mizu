const std = @import("std");
const theme = @import("../core/theme.zig");
const types = @import("context.zig");
const ui_mod = @import("../core/ui.zig");

fn formatBatteryLabel(buf: *[32]u8, cap: u8, charging: bool, seconds: ?i64) []const u8 {
    if (seconds) |sec| {
        if (sec > 0) {
            const hours = @divTrunc(sec, 3600);
            const minutes = @divTrunc(@rem(sec, 3600), 60);
            if (charging) {
                if (hours > 0 and minutes > 0) {
                    return std.fmt.bufPrint(buf, "{d}% · {d}h {d}m to full", .{ cap, hours, minutes }) catch "100%";
                } else if (hours > 0) {
                    return std.fmt.bufPrint(buf, "{d}% · {d}h to full", .{ cap, hours }) catch "100%";
                } else if (minutes > 0) {
                    return std.fmt.bufPrint(buf, "{d}% · {d}m to full", .{ cap, minutes }) catch "100%";
                } else {
                    return std.fmt.bufPrint(buf, "{d}% · charging", .{cap}) catch "100%";
                }
            } else {
                if (hours > 0 and minutes > 0) {
                    return std.fmt.bufPrint(buf, "{d}% · {d}h {d}m left", .{ cap, hours, minutes }) catch "100%";
                } else if (hours > 0) {
                    return std.fmt.bufPrint(buf, "{d}% · {d}h left", .{ cap, hours }) catch "100%";
                } else if (minutes > 0) {
                    return std.fmt.bufPrint(buf, "{d}% · {d}m left", .{ cap, minutes }) catch "100%";
                } else {
                    return std.fmt.bufPrint(buf, "{d}%", .{cap}) catch "100%";
                }
            }
        }
    }
    return std.fmt.bufPrint(buf, "{d}%", .{cap}) catch "100%";
}

fn batterySvgName(cap: u8, charging: bool) []const u8 {
    if (charging) return "battery-charging";
    if (cap <= 20) return "battery-empty";
    if (cap <= 50) return "battery-low";
    if (cap <= 80) return "battery-middle";
    if (cap <= 90) return "battery-high";
    return "battery-full";
}

pub fn render(ctx: *types.BarContext, ui: *ui_mod.Ui) !void {
    if (!ctx.sys.has_battery) return;

    const cap: u8 = @min(ctx.sys.bat_capacity, 100);
    const charging = ctx.sys.bat_status == .charging;
    const svg_name = batterySvgName(cap, charging);

    var label_buf: [32]u8 = undefined;
    const label = formatBatteryLabel(&label_buf, cap, charging, ctx.sys.bat_seconds_remaining);

    const icon_size = ctx.iconFontSize();
    const id = "bar-battery";
    const hovered = ui.hovered(id, 0);
    const border_col = if (hovered)
        ctx.cfg.theme.accent
    else if (ctx.cfg.theme.pill_border.a > 0)
        ctx.cfg.theme.pill_border
    else
        null;

    const color = if (ctx.sys.ac_online)
        theme.Color.rgb(0x81, 0xC7, 0x84)
    else if (cap <= 15)
        ctx.cfg.theme.ws_urgent_bg
    else
        ctx.cfg.theme.battery_fg;

    _ = ui.open(.{
        .id = id,
        .width = .fit,
        .height = .{ .grow = .{} },
        .padding = .{
            .left = ui.su(6),
            .right = ui.su(10),
        },
        .gap = ui.su(8),
        .bg = if (hovered) ctx.cfg.theme.pill_hover else ctx.cfg.theme.battery_bg,
        .radius = ui.f(ctx.cfg.pill_radius),
        .border = if (border_col != null) ui.su(1) else 0,
        .border_color = border_col,
        .align_y = .center,
    });
    ui.icon(svg_name, icon_size, color, 0);
    ui.text(label, .{
        .size = ctx.textFontSize(),
        .color = ctx.cfg.theme.text_main,
    });
    ui.close();

    try ctx.linkClick(ui, id, 0, .{ .command = "mizu quicksettings" }, null);
}

test "batterySvgName thresholds" {
    // Charging override
    try std.testing.expectEqualStrings("battery-charging", batterySvgName(0, true));
    try std.testing.expectEqualStrings("battery-charging", batterySvgName(100, true));

    // Discharging thresholds:
    // 0-20% -> battery-empty
    try std.testing.expectEqualStrings("battery-empty", batterySvgName(0, false));
    try std.testing.expectEqualStrings("battery-empty", batterySvgName(20, false));

    // 20-50% -> battery-low
    try std.testing.expectEqualStrings("battery-low", batterySvgName(21, false));
    try std.testing.expectEqualStrings("battery-low", batterySvgName(50, false));

    // 50-80% -> battery-middle
    try std.testing.expectEqualStrings("battery-middle", batterySvgName(51, false));
    try std.testing.expectEqualStrings("battery-middle", batterySvgName(80, false));

    // 80-90% -> battery-high
    try std.testing.expectEqualStrings("battery-high", batterySvgName(81, false));
    try std.testing.expectEqualStrings("battery-high", batterySvgName(90, false));

    // 90-100% -> battery-full
    try std.testing.expectEqualStrings("battery-full", batterySvgName(91, false));
    try std.testing.expectEqualStrings("battery-full", batterySvgName(100, false));
}
