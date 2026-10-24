const std = @import("std");
const renderer = @import("../core/renderer.zig");
const theme = @import("../core/theme.zig");
const types = @import("context.zig");
const icons = @import("../graphics/icons.zig");

pub fn render(ctx: *types.BarContext, target: renderer.Renderer, right_x: i32) !i32 {
    const has_bat = ctx.sys.has_battery;
    const bat_cap = @min(ctx.sys.bat_capacity, 100);
    const charging = ctx.sys.ac_online;

    // Layout
    const icon_size = ctx.iconFontSize();
    const bat_icon_w: u32 = if (has_bat) icon_size else 0;
    const gap: u32 = 10 * ctx.scale;
    const pad_x: u32 = 12 * ctx.scale;

    const inner_w = icon_size + gap + icon_size +
        (if (has_bat) gap + bat_icon_w else 0);
    const pill_w = inner_w + pad_x * 2;
    const x = right_x - @as(i32, @intCast(pill_w));

    const is_hovered = ctx.isHovered(x, ctx.chip_y, pill_w, ctx.chip_h);
    const bg_color = if (is_hovered)
        ctx.cfg.theme.pill_hover
    else
        ctx.cfg.theme.pill_bg;
    const border_color = if (is_hovered)
        ctx.cfg.theme.accent
    else
        ctx.cfg.theme.pill_border;

    target.fillRoundedRect(
        x,
        ctx.chip_y,
        pill_w,
        ctx.chip_h,
        ctx.cfg.pill_radius,
        bg_color,
    );
    target.drawRoundedBorder(
        x,
        ctx.chip_y,
        pill_w,
        ctx.chip_h,
        ctx.cfg.pill_radius,
        1,
        border_color,
    );

    var cur_x = x + @as(i32, @intCast(pad_x));

    // Network
    const wifi_enabled = ctx.sys.wifi_enabled;
    const wifi_connected = wifi_enabled and ctx.sys.wifi_ssid_len > 0;
    const wifi_name = if (!wifi_enabled) "wifi-off" else if (wifi_connected) "wifi-high" else "wifi-low";
    const net_fg = if (wifi_connected)
        ctx.cfg.theme.network_fg
    else
        ctx.cfg.theme.text_muted;

    const cy = ctx.chip_y + @as(i32, @intCast(ctx.chip_h / 2));
    const wx = cur_x + @as(i32, @intCast(icon_size / 2));
    icons.drawSvgIcon(target, ctx.allocator, wifi_name, icon_size, ctx.scale, wx, cy, net_fg);
    cur_x += @as(i32, @intCast(icon_size + gap));

    // Volume - dynamic icon based on volume level
    const vol_fg = if (ctx.sys.volume_muted)
        ctx.cfg.theme.error_color
    else
        ctx.cfg.theme.audio_fg;
    const vol_name = if (ctx.sys.volume_muted) "volume-muted" else if (ctx.sys.volume_percent >= 67) "volume-high" else if (ctx.sys.volume_percent >= 34) "volume-medium" else "volume-low";
    const vx = cur_x + @as(i32, @intCast(icon_size / 2));
    icons.drawSvgIcon(target, ctx.allocator, vol_name, icon_size, ctx.scale, vx, cy, vol_fg);
    cur_x += @as(i32, @intCast(icon_size + gap));

    // Battery: no percentage text
    if (has_bat) {
        const svg_name = if (charging) "battery-charging" else if (bat_cap <= 10) "battery-empty" else if (bat_cap >= 90) "battery-full" else if (bat_cap >= 60) "battery-high" else if (bat_cap >= 30) "battery-medium" else "battery-low";

        const bat_color = if (charging)
            theme.Color.rgb(0x81, 0xC7, 0x84)
        else if (bat_cap <= 15)
            ctx.cfg.theme.ws_urgent_bg
        else
            ctx.cfg.theme.battery_fg;

        const bx = cur_x + @as(i32, @intCast(icon_size / 2));
        const by = ctx.chip_y + @divTrunc(@as(i32, @intCast(ctx.chip_h)), 2);
        // Try SVG first, fall back to vector drawing
        const svg_icon = icons.getIcon(ctx.allocator, svg_name, icon_size, ctx.scale);
        if (svg_icon) |icon| {
            icons.drawIconRaster(target, icon, bx, by, bat_color);
        } else {
            const bat_w = icon_size;
            const bat_h = icon_size * 2 / 3;
            icons.drawBattery(target, bx - @as(i32, @intCast(bat_w / 2)), by - @as(i32, @intCast(bat_h / 2)), bat_w, bat_h, bat_cap, charging, bat_color);
        }
    }

    // Preserve existing interactions
    const action: types.ClickAction = .{
        .dual_command = .{
            .left = "mizu quicksettings",
            .right = "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle",
        },
    };

    try ctx.addInteractiveArea(
        x,
        ctx.chip_y,
        pill_w,
        ctx.chip_h,
        action,
        .volume,
    );

    return x;
}
