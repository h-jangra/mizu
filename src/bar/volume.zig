const std = @import("std");
const renderer = @import("../core/renderer.zig");
const types = @import("context.zig");
const icons = @import("../graphics/icons.zig");

pub fn render(ctx: *types.BarContext, target: renderer.Renderer, right_x: i32) !i32 {
    const icon_size = ctx.iconFontSize();
    const icon_name = if (ctx.sys.volume_muted) "volume-muted" else if (ctx.sys.volume_percent >= 67) "volume-high" else if (ctx.sys.volume_percent >= 34) "volume-medium" else "volume-low";
    const fg = if (ctx.sys.volume_muted) ctx.cfg.theme.text_muted else ctx.cfg.theme.audio_fg;

    const w: u32 = icon_size + 16 * ctx.scale;
    const x = right_x - @as(i32, @intCast(w));
    const cx = x + @as(i32, @intCast(icon_size / 2));
    const cy = ctx.chip_y + @as(i32, @intCast(ctx.chip_h / 2));

    icons.drawSvgIcon(target, ctx.allocator, icon_name, icon_size, ctx.scale, cx, cy, fg);

    const action: types.ClickAction = .{ .dual_command = .{
        .left = "mizu quicksettings",
        .right = "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle",
    } };

    try ctx.addInteractiveArea(x, ctx.chip_y, w, ctx.chip_h, action, .volume);

    return x;
}
