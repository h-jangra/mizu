const std = @import("../renderer.zig");
const types = @import("types.zig");

pub fn render(ctx: *types.BarContext, target: std.Renderer, right_x: i32) !i32 {
    const enabled = ctx.sys.wifi_enabled;
    const connected = enabled and ctx.sys.wifi_ssid_len > 0;
    const icon: []const u8 = if (!enabled)
        "󰤭"
    else if (connected)
        "󰤨"
    else
        "󰤮";

    const icon_w = target.measureText(ctx.font, icon);
    const width = icon_w + 16;
    const x = right_x - @as(i32, @intCast(width));
    const hover = ctx.isHovered(x, ctx.chip_y, width, ctx.chip_h);

    const fg = if (connected)
        ctx.cfg.theme.network_fg
    else if (enabled)
        ctx.cfg.theme.text_muted
    else
        ctx.cfg.theme.ws_empty_fg;

    target.fillSquircle(
        x,
        ctx.chip_y,
        width,
        ctx.chip_h,
        ctx.chip_h / 2,
        if (hover) ctx.cfg.theme.pill_hover else ctx.cfg.theme.network_bg,
    );

    target.drawTextWithSize(
        ctx.font,
        icon,
        x + @divTrunc(@as(i32, @intCast(width)) - @as(i32, @intCast(icon_w)), 2),
        ctx.chip_y + @divTrunc(@as(i32, @intCast(ctx.chip_h)) + 5, 2),
        13,
        fg,
    );

    try ctx.addClickable(x, ctx.chip_y, width, ctx.chip_h, .{
        .dual_command = .{
            .left = "mizu quicksettings",
            .right = "mizu quicksettings",
        },
    });

    return x;
}
