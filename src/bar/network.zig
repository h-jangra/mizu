const std = @import("std");
const renderer = @import("../core/renderer.zig");
const types = @import("context.zig");
const icons = @import("../graphics/icons.zig");

pub fn render(ctx: *types.BarContext, target: renderer.Renderer, right_x: i32) !i32 {
    const wifi_enabled = ctx.sys.wifi_enabled;
    const wifi_connected = wifi_enabled and ctx.sys.wifi_ssid_len > 0;
    const bluetooth_connected = ctx.sys.bluetooth_enabled and ctx.sys.bluetooth_connected;

    const icon_size = ctx.iconFontSize();
    const wifi_name = if (!wifi_enabled)
        "wifi-off"
    else if (wifi_connected)
        "wifi-high"
    else
        "wifi-low";
    const wifi_fg = if (wifi_connected)
        ctx.cfg.theme.network_fg
    else
        ctx.cfg.theme.text_muted;

    const bw = if (bluetooth_connected) icon_size else 0;
    const gap = if (bluetooth_connected) 8 * ctx.scale else 0;
    const left_pad: u32 = 8 * ctx.scale;
    const right_pad: u32 = 16 * ctx.scale;
    const width = left_pad + icon_size + gap + bw + right_pad;
    const x = right_x - @as(i32, @intCast(width));

    ctx.drawChipBase(
        target,
        x,
        ctx.chip_y,
        width,
        ctx.chip_h,
        ctx.cfg.theme.network_bg,
    );

    const cy = ctx.chip_y + @as(i32, @intCast(ctx.chip_h / 2));
    const wifi_cx = x + @as(i32, @intCast(left_pad)) + @as(i32, @intCast(icon_size / 2));
    icons.drawSvgIcon(target, ctx.allocator, wifi_name, icon_size, ctx.scale, wifi_cx, cy, wifi_fg);

    if (bluetooth_connected) {
        const bt_cx = x + @as(i32, @intCast(left_pad)) + @as(i32, @intCast(icon_size)) +
            @as(i32, @intCast(gap)) + @as(i32, @intCast(icon_size / 2));
        icons.drawSvgIcon(target, ctx.allocator, "bluetooth", icon_size, ctx.scale, bt_cx, cy, ctx.cfg.theme.network_fg);
    }

    try ctx.addClickable(x, ctx.chip_y, width, ctx.chip_h, .{
        .command = "mizu quicksettings",
    });

    return x;
}
