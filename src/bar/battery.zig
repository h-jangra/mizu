const std = @import("std");
const theme = @import("../core/theme.zig");
const draw = @import("../draw.zig");
const types = @import("context.zig");

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
    if (cap <= 10) return "battery-empty";
    if (cap >= 90) return "battery-full";
    if (cap >= 60) return "battery-high";
    if (cap >= 30) return "battery-medium";
    return "battery-low";
}

pub fn render(ctx: *types.BarContext, ui: *draw.DrawContext, right_x: i32) !i32 {
    if (!ctx.sys.has_battery) return right_x;

    const cap: u8 = @min(ctx.sys.bat_capacity, 100);
    const charging = ctx.sys.bat_status == .charging;
    const svg_name = batterySvgName(cap, charging);

    var label_buf: [32]u8 = undefined;
    const label = formatBatteryLabel(&label_buf, cap, charging, ctx.sys.bat_seconds_remaining);

    const icon_size = ctx.iconFontSize();
    const text_size = ctx.textFontSize();
    const text_w = ui.textWidth(ctx.font, label, text_size);
    const width = icon_size + ui.scale(8) + text_w + ui.scale(20);
    const x = right_x - @as(i32, @intCast(width));

    const color = if (ctx.sys.ac_online)
        theme.Color.rgb(0x81, 0xC7, 0x84)
    else if (cap <= 15)
        ctx.cfg.theme.ws_urgent_bg
    else
        ctx.cfg.theme.battery_fg;

    ui.roundedRect(x, ctx.chip_y, width, ctx.chip_h, ctx.cfg.pill_radius, ctx.cfg.theme.battery_bg);

    const icon_x = x + @as(i32, @intCast(ui.scale(6)));
    const icon_y = ctx.chip_y + @divTrunc(@as(i32, @intCast(ctx.chip_h)) - @as(i32, @intCast(icon_size)), 2);
    ui.icon(svg_name, icon_x, icon_y, icon_size, color);

    const text_x = icon_x + @as(i32, @intCast(icon_size)) + @as(i32, @intCast(ui.scale(8)));
    ui.textCenteredY(ctx.font, label, text_x, ctx.chip_y, ctx.chip_h, text_size, ctx.cfg.theme.text_main);

    try ui.addClickable(x, ctx.chip_y, width, ctx.chip_h, .{ .command = "mizu quicksettings" });
    return x;
}
