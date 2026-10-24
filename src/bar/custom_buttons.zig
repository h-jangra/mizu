const std = @import("std");
const renderer = @import("../core/renderer.zig");
const types = @import("context.zig");

pub fn render(ctx: *types.BarContext, target: renderer.Renderer, start_x: i32) !i32 {
    var cur_x = start_x;

    for (ctx.cfg.buttons.items) |btn| {
        if (btn.label.len == 0) continue;

        const text_w = target.measureTextWithSize(ctx.font, btn.label, ctx.textFontSize());
        const chip_w = text_w + 18 * ctx.scale;

        ctx.drawChip(
            target,
            cur_x,
            ctx.chip_y,
            chip_w,
            ctx.chip_h,
            btn.label,
            ctx.cfg.theme.pill_bg,
            ctx.cfg.theme.text_bright,
        );

        try ctx.addClickable(cur_x, ctx.chip_y, chip_w, ctx.chip_h, .{ .command = btn.command });

        cur_x += @as(i32, @intCast(chip_w + 5 * ctx.scale));
    }

    return cur_x;
}
