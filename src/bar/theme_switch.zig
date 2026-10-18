const std = @import("std");
const renderer = @import("../renderer.zig");
const types = @import("types.zig");

pub fn render(ctx: *types.BarContext, target: renderer.Renderer, right_x: i32) !struct { new_x: i32, area: types.ClickableArea } {
    const icon = ctx.current_theme_kind.icon();
    const name_str = ctx.current_theme_kind.name();

    const icon_w = target.measureText(ctx.font, icon);
    const text_w = target.measureText(ctx.font, name_str);
    const chip_w = icon_w + 6 + text_w + 16;
    const rx = right_x - @as(i32, @intCast(chip_w));

    ctx.drawChipWithIcon(
        target,
        rx,
        ctx.chip_y,
        chip_w,
        ctx.chip_h,
        icon,
        ctx.cfg.theme.theme_fg,
        name_str,
        ctx.cfg.theme.text_main,
        ctx.cfg.theme.theme_bg,
    );

    const click_action = types.ClickAction{ .cycle_theme = true };

    try ctx.addClickable(rx, ctx.chip_y, chip_w, ctx.chip_h, click_action);

    return .{
        .new_x = rx,
        .area = .{ .x = rx, .y = ctx.chip_y, .w = chip_w, .h = ctx.chip_h, .action = click_action },
    };
}
