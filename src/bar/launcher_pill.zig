const std = @import("std");
const theme = @import("../core/theme.zig");
const draw = @import("../draw.zig");
const types = @import("context.zig");

pub fn render(ctx: *types.BarContext, ui: *draw.DrawContext, cur_x: i32) !i32 {
    const icon_size = ctx.iconFontSize();
    const padding = ui.scale(10);
    const chip_w = icon_size + padding * 2;

    const is_hov = ctx.isHovered(cur_x, ctx.chip_y, chip_w, ctx.chip_h);
    const bg = if (is_hov)
        ctx.cfg.theme.pill_hover
    else
        ctx.cfg.theme.launcher_bg;

    ui.roundedRect(
        cur_x,
        ctx.chip_y,
        chip_w,
        ctx.chip_h,
        ctx.cfg.pill_radius,
        bg,
    );

    if (is_hov) {
        // ui.roundedBorder(cur_x, ctx.chip_y, chip_w, ctx.chip_h,
        //     ctx.cfg.pill_radius, 1, ctx.cfg.theme.accent);
    } else if (ctx.cfg.theme.pill_border.a > 0) {}

    const icon_x = cur_x + @divTrunc(
        @as(i32, @intCast(chip_w)) - @as(i32, @intCast(icon_size)),
        2,
    );
    const icon_y = ctx.chip_y + @divTrunc(
        @as(i32, @intCast(ctx.chip_h)) - @as(i32, @intCast(icon_size)),
        2,
    );

    ui.icon(
        "launcher",
        icon_x,
        icon_y,
        icon_size,
        ctx.cfg.theme.launcher_fg,
    );

    try ui.addClickable(
        cur_x,
        ctx.chip_y,
        chip_w,
        ctx.chip_h,
        .{ .command = "mizu launcher" },
    );

    return cur_x + @as(i32, @intCast(chip_w + ui.scale(4)));
}
