const std = @import("std");
const renderer = @import("../renderer.zig");
const types = @import("types.zig");

pub fn render(ctx: *types.BarContext, target: renderer.Renderer, right_x: i32) !struct { new_x: i32, area: types.ClickableArea } {
    const icon = if (ctx.sys.volume_muted) "󰖁" else if (ctx.sys.volume_percent >= 70) "󰕾" else if (ctx.sys.volume_percent >= 30) "󰖀" else "󰕿";
    var buf: [16]u8 = undefined;
    const label = if (ctx.sys.volume_muted) "Muted" else std.fmt.bufPrint(&buf, "{d}%", .{ctx.sys.volume_percent}) catch "50%";
    const icon_w = target.measureText(ctx.font, icon);
    const text_w = target.measureText(ctx.font, label);
    const w = icon_w + 6 + text_w + 16;
    const x = right_x - @as(i32, @intCast(w));
    const fg = if (ctx.sys.volume_muted) ctx.cfg.theme.text_muted else ctx.cfg.theme.audio_fg;

    ctx.drawChipWithIcon(target, x, ctx.chip_y, w, ctx.chip_h, icon, fg, label, ctx.cfg.theme.text_main, ctx.cfg.theme.audio_bg);

    const action: types.ClickAction = .{ .dual_command = .{
        .left = "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle",
        .right = "mizu quicksettings",
    } };

    try ctx.addClickable(x, ctx.chip_y, w, ctx.chip_h, action);

    return .{
        .new_x = x,
        .area = .{ .x = x, .y = ctx.chip_y, .w = w, .h = ctx.chip_h, .action = action },
    };
}
