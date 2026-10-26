const theme = @import("../core/theme.zig");
const types = @import("context.zig");
const ui_mod = @import("../core/ui.zig");

pub fn render(ctx: *types.BarContext, ui: *ui_mod.Ui) !void {
    const has_bat = ctx.sys.has_battery;
    const bat_cap = @min(ctx.sys.bat_capacity, 100);
    const charging = ctx.sys.ac_online;

    const icon_size = ctx.iconFontSize();
    const id = "bar-quicksettings";
    const hovered = ui.hovered(id, 0);
    const bg_color = if (hovered) ctx.cfg.theme.pill_hover else ctx.cfg.theme.pill_bg;
    const border_color = if (hovered)
        ctx.cfg.theme.accent
    else if (ctx.cfg.theme.pill_border.a > 0)
        ctx.cfg.theme.pill_border
    else
        null;

    _ = ui.open(.{
        .id = id,
        .width = .fit,
        .height = .{ .grow = .{} },
        .padding = .{ .left = ui.su(12), .right = ui.su(12) },
        .gap = ui.su(10),
        .bg = bg_color,
        .radius = ui.f(ctx.cfg.pill_radius),
        .border = if (border_color != null) ui.su(1) else 0,
        .border_color = border_color,
        .align_y = .center,
    });

    const wifi_enabled = ctx.sys.wifi_enabled;
    const wifi_connected = wifi_enabled and ctx.sys.wifi_ssid_len > 0;
    const wifi_name = if (!wifi_enabled) "wifi-off" else if (wifi_connected) "wifi-high" else "wifi-low";
    const net_fg = if (wifi_connected) ctx.cfg.theme.network_fg else ctx.cfg.theme.text_muted;
    ui.icon(wifi_name, icon_size, net_fg, 0);

    const vol_fg = if (ctx.sys.volume_muted) ctx.cfg.theme.error_color else ctx.cfg.theme.audio_fg;
    const vol_name = if (ctx.sys.volume_muted) "volume-muted" else if (ctx.sys.volume_percent >= 67) "volume-high" else if (ctx.sys.volume_percent >= 34) "volume-medium" else "volume-low";
    ui.icon(vol_name, icon_size, vol_fg, 1);

    if (has_bat) {
        const svg_name = if (charging) "battery-charging" else if (bat_cap <= 10) "battery-empty" else if (bat_cap >= 90) "battery-full" else if (bat_cap >= 60) "battery-high" else if (bat_cap >= 30) "battery-middle" else "battery-low";
        const bat_color = if (charging)
            theme.Color.rgb(0x81, 0xC7, 0x84)
        else if (bat_cap <= 15)
            ctx.cfg.theme.ws_urgent_bg
        else
            ctx.cfg.theme.battery_fg;
        ui.icon(svg_name, icon_size, bat_color, 2);
    }
    ui.close();

    const action: types.ClickAction = .{
        .dual_command = .{
            .left = "mizu quicksettings",
            .right = "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle",
        },
    };
    try ctx.linkClick(ui, id, 0, action, .volume);
}
