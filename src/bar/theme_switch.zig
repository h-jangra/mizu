const std = @import("std");
const renderer = @import("../core/renderer.zig");
const types = @import("context.zig");
const icons = @import("../graphics/icons.zig");

pub fn render(ctx: *types.BarContext, target: renderer.Renderer, right_x: i32) !i32 {
    const icon_size = ctx.iconFontSize();
    const chip_w = @max(ctx.chip_h, icon_size + 14 * ctx.scale);
    const rx = right_x - @as(i32, @intCast(chip_w));

    const is_hov = ctx.isHovered(rx, ctx.chip_y, chip_w, ctx.chip_h);
    const bg = if (is_hov)
        ctx.cfg.theme.pill_hover
    else
        ctx.cfg.theme.theme_bg;

    target.fillRoundedRect(
        rx,
        ctx.chip_y,
        chip_w,
        ctx.chip_h,
        ctx.cfg.pill_radius,
        bg,
    );
    if (is_hov) {
        target.drawRoundedBorder(rx, ctx.chip_y, chip_w, ctx.chip_h, ctx.cfg.pill_radius, 1, ctx.cfg.theme.accent);
    } else if (ctx.cfg.theme.pill_border.a > 0) {
        target.drawRoundedBorder(rx, ctx.chip_y, chip_w, ctx.chip_h, ctx.cfg.pill_radius, 1, ctx.cfg.theme.pill_border);
    }

    const cx = rx + @as(i32, @intCast(chip_w / 2));
    const cy = ctx.chip_y + @as(i32, @intCast(ctx.chip_h / 2));
    icons.drawSvgIcon(target, ctx.allocator, "palette", icon_size, ctx.scale, cx, cy, if (is_hov) ctx.cfg.theme.accent else ctx.cfg.theme.theme_fg);

    try ctx.addInteractiveArea(
        rx,
        ctx.chip_y,
        chip_w,
        ctx.chip_h,
        .{ .cycle_theme = true },
        .cycle_theme,
    );

    return rx;
}
