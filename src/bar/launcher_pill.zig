const std = @import("std");
const renderer = @import("../renderer.zig");
const types = @import("types.zig");

pub fn render(ctx: *types.BarContext, target: renderer.Renderer, cur_x: i32) !i32 {
    const symbol = ctx.current_theme_kind.icon();
    const font_size: u32 = 16;
    const text_w = target.measureTextWithSize(ctx.font, symbol, font_size);
    const chip_w = text_w + 20;

    const is_hov = ctx.isHovered(cur_x, ctx.chip_y, chip_w, ctx.chip_h);
    const bg = if (is_hov)
        ctx.cfg.theme.pill_hover
    else
        ctx.cfg.theme.launcher_bg;

    target.fillGlassSquircle(
        cur_x,
        ctx.chip_y,
        chip_w,
        ctx.chip_h,
        ctx.cfg.pill_radius,
        bg,
    );
    if (is_hov) {
        target.drawSquircleBorder(cur_x, ctx.chip_y, chip_w, ctx.chip_h, ctx.cfg.pill_radius, 1, ctx.cfg.theme.pill_hover);
    } else if (ctx.cfg.theme.pill_border.a > 0) {
        target.drawSquircleBorder(cur_x, ctx.chip_y, chip_w, ctx.chip_h, ctx.cfg.pill_radius, 1, ctx.cfg.theme.pill_border);
    }

    const text_x = cur_x + @divTrunc(@as(i32, @intCast(chip_w)) - @as(i32, @intCast(text_w)), 2);
    const baseline = ctx.chip_y + @divTrunc(@as(i32, @intCast(ctx.chip_h)) + @as(i32, @intCast(font_size)), 2) - 1;
    target.drawTextWithSize(
        ctx.font,
        symbol,
        text_x,
        baseline,
        font_size,
        ctx.cfg.theme.launcher_fg,
    );

    try ctx.addClickable(cur_x, ctx.chip_y, chip_w, ctx.chip_h, .{ .command = "mizu launcher" });

    return cur_x + @as(i32, @intCast(chip_w + 4));
}
