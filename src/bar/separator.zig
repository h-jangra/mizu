const std = @import("std");
const renderer = @import("../renderer.zig");
const types = @import("types.zig");

pub fn render(ctx: *types.BarContext, target: renderer.Renderer, cur_x: i32) i32 {
    const sep = "|";
    const font_size: u32 = 10;
    target.drawTextWithSize(ctx.font, sep, cur_x + 2, ctx.baseline_y - 1, font_size, ctx.cfg.theme.separator_fg);
    const text_w = target.measureTextWithSize(ctx.font, sep, font_size);
    return cur_x + @as(i32, @intCast(text_w)) + 6;
}

pub fn renderRight(ctx: *types.BarContext, target: renderer.Renderer, right_x: i32) i32 {
    const sep = "|";
    const font_size: u32 = 10;
    const text_w = target.measureTextWithSize(ctx.font, sep, font_size);
    const rx = right_x - @as(i32, @intCast(text_w));
    target.drawTextWithSize(ctx.font, sep, rx, ctx.baseline_y - 1, font_size, ctx.cfg.theme.separator_fg);
    return rx - 4;
}
