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
    if (cap <= 10) return "battery-empty";
    if (cap >= 90) return "battery-full";
    if (cap >= 60) return "battery-high";
    if (cap >= 30) return "battery-middle";
    return "battery-low";
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
