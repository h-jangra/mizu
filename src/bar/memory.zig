const std = @import("std");
const renderer = @import("../core/renderer.zig");
const types = @import("context.zig");
const icons = @import("../graphics/icons.zig");

pub fn render(ctx: *types.BarContext, target: renderer.Renderer, right_x: i32) !i32 {
    var buf: [24]u8 = undefined;
    const value = try std.fmt.bufPrint(&buf, "{d:.1} GB", .{ctx.sys.mem_used_gib});
    const icon_size = ctx.iconFontSize();
    const text_size = ctx.textFontSize();
    const text_w = target.measureTextWithSize(ctx.font, value, text_size);
    const width = icon_size + 8 * ctx.scale + text_w + 16 * ctx.scale;
    const x = right_x - @as(i32, @intCast(width));

    ctx.drawChipBase(target, x, ctx.chip_y, width, ctx.chip_h, ctx.cfg.theme.cpu_mem_bg);

    // Center both icon and text vertically in the chip
    const center_y = ctx.chip_y + @divTrunc(@as(i32, @intCast(ctx.chip_h)), 2);
    const icon_cx = x + @as(i32, @intCast(icon_size / 2)) + @as(i32, @intCast(8 * ctx.scale));
    icons.drawSvgIcon(
        target,
        ctx.allocator,
        "memory",
        icon_size,
        ctx.scale,
        icon_cx,
        center_y,
        ctx.cfg.theme.cpu_mem_fg,
    );
    const text_x = icon_cx + @as(i32, @intCast(icon_size / 2)) + @as(i32, @intCast(8 * ctx.scale));
    const text_baseline = center_y + @as(i32, @intCast(@as(u32, @intCast(ctx.font.ascender_px)) * ctx.scale / 2));
    target.drawTextWithSize(ctx.font, value, text_x, text_baseline, text_size, ctx.cfg.theme.text_main);

    try ctx.addClickable(x, ctx.chip_y, width, ctx.chip_h, .{
        .dual_command = .{
            .left = "mizu memory-monitor",
            .right = "mizu quicksettings",
        },
    });

    return x;
}
