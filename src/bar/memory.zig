const std = @import("std");
const renderer = @import("../renderer.zig");
const types = @import("types.zig");

pub fn render(ctx: *types.BarContext, target: renderer.Renderer, right_x: i32) !i32 {
    var buf: [24]u8 = undefined;
    const value = try std.fmt.bufPrint(&buf, "{d:.1} GB", .{ctx.sys.mem_used_gib});
    const icon = "󰍛";
    const icon_w = target.measureText(ctx.font, icon);
    const text_w = target.measureText(ctx.font, value);
    const width = icon_w + text_w + 22;
    const x = right_x - @as(i32, @intCast(width));
    const hovered = ctx.isHovered(x, ctx.chip_y, width, ctx.chip_h);

    target.fillSquircle(
        x,
        ctx.chip_y,
        width,
        ctx.chip_h,
        ctx.cfg.pill_radius,
        if (hovered) ctx.cfg.theme.pill_hover else ctx.cfg.theme.cpu_mem_bg,
    );

    target.drawTextWithSize(
        ctx.font,
        icon,
        x + 8,
        ctx.chip_y + @divTrunc(@as(i32, @intCast(ctx.chip_h)) + 5, 2),
        13,
        ctx.cfg.theme.cpu_mem_fg,
    );

    target.drawTextWithSize(
        ctx.font,
        value,
        x + @as(i32, @intCast(icon_w)) + 14,
        ctx.chip_y + @divTrunc(@as(i32, @intCast(ctx.chip_h)) + 5, 2),
        11,
        ctx.cfg.theme.text_main,
    );

    try ctx.addClickable(x, ctx.chip_y, width, ctx.chip_h, .{
        .dual_command = .{
            .left = "foot -e btop",
            .right = "mizu quicksettings",
        },
    });

    return x;
}
