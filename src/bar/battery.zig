const std = @import("std");
const renderer = @import("../renderer.zig");
const theme = @import("../theme.zig");
const types = @import("types.zig");

fn batteryIcon(cap: u8, charging: bool) []const u8 {
    if (charging) {
        if (cap >= 95) return "󰂄";
        if (cap >= 90) return "󰂋";
        if (cap >= 80) return "󰂊";
        if (cap >= 70) return "󰢞";
        if (cap >= 60) return "󰂉";
        if (cap >= 50) return "󰢝";
        if (cap >= 40) return "󰂈";
        if (cap >= 30) return "󰂇";
        if (cap >= 20) return "󰂆";
        return "󰢜";
    }
    if (cap >= 90) return "󰁹";
    if (cap >= 80) return "󰂂";
    if (cap >= 70) return "󰂁";
    if (cap >= 60) return "󰂀";
    if (cap >= 50) return "󰁿";
    if (cap >= 40) return "󰁾";
    if (cap >= 30) return "󰁽";
    if (cap >= 20) return "󰁼";
    if (cap >= 10) return "󰁻";
    return "󰂎";
}

pub fn render(ctx: *types.BarContext, target: renderer.Renderer, right_x: i32) !i32 {
    if (!ctx.sys.has_battery) return right_x;

    const cap = @min(ctx.sys.bat_capacity, 100);
    const charging = ctx.sys.bat_status == .charging or ctx.sys.ac_online;
    const icon = batteryIcon(cap, charging);

    var buf: [4]u8 = undefined;
    const label = try std.fmt.bufPrint(&buf, "{d}%", .{cap});
    const icon_w = target.measureText(ctx.font, icon);
    const text_w = target.measureText(ctx.font, label);
    const width = icon_w + text_w + 22;
    const x = right_x - @as(i32, @intCast(width));

    const color = if (charging)
        theme.Color.rgb(0x81, 0xC7, 0x84)
    else if (cap <= 15)
        ctx.cfg.theme.ws_urgent_bg
    else
        ctx.cfg.theme.battery_fg;

    ctx.drawChipWithIcon(
        target,
        x,
        ctx.chip_y,
        width,
        ctx.chip_h,
        icon,
        color,
        label,
        ctx.cfg.theme.text_main,
        ctx.cfg.theme.battery_bg,
    );

    try ctx.addClickable(x, ctx.chip_y, width, ctx.chip_h, .{ .command = "mizu quicksettings" });
    return x;
}
