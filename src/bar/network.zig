const types = @import("context.zig");
const ui_mod = @import("../core/ui.zig");

pub fn render(ctx: *types.BarContext, ui: *ui_mod.Ui) !void {
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
    const wifi_fg = if (wifi_connected) ctx.cfg.theme.network_fg else ctx.cfg.theme.text_muted;

    const id = "bar-network";
    const hovered = ui.hovered(id, 0);
    const border_col = if (hovered)
        ctx.cfg.theme.accent
    else if (ctx.cfg.theme.pill_border.a > 0)
        ctx.cfg.theme.pill_border
    else
        null;

    _ = ui.open(.{
        .id = id,
        .width = .fit,
        .height = .{ .grow = .{} },
        .padding = .{
            .left = ui.su(8),
            .right = ui.su(16),
        },
        .gap = ui.su(8),
        .bg = if (hovered) ctx.cfg.theme.pill_hover else ctx.cfg.theme.network_bg,
        .radius = ui.f(ctx.cfg.pill_radius),
        .border = if (border_col != null) ui.su(1) else 0,
        .border_color = border_col,
        .align_y = .center,
    });
    ui.icon(wifi_name, icon_size, wifi_fg, 0);
    if (bluetooth_connected) {
        ui.icon("bluetooth", icon_size, ctx.cfg.theme.network_fg, 1);
    }
    ui.close();

    try ctx.linkClick(ui, id, 0, .{ .command = "mizu quicksettings" }, null);
}
