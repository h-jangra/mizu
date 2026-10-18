const std = @import("std");
const renderer = @import("../renderer.zig");
const types = @import("types.zig");
const c = @import("../c.zig").c;

pub fn renderCenter(ctx: *types.BarContext, target: renderer.Renderer, total_w: u32) !struct { x: i32, w: u32 } {
    var buf: [64]u8 = undefined;
    const label = formatClockTime(ctx.cfg.clock_format, &buf);
    const width = target.measureText(ctx.font, label) + 18;
    const x = @divTrunc(@as(i32, @intCast(total_w)) - @as(i32, @intCast(width)), 2);

    try drawClock(ctx, target, x, width, label);
    return .{ .x = x, .w = width };
}

pub fn render(ctx: *types.BarContext, target: renderer.Renderer, right_x: i32) !i32 {
    var buf: [64]u8 = undefined;
    const label = formatClockTime(ctx.cfg.clock_format, &buf);
    const width = target.measureText(ctx.font, label) + 18;
    const x = right_x - @as(i32, @intCast(width));

    try drawClock(ctx, target, x, width, label);
    return x;
}

fn drawClock(ctx: *types.BarContext, target: renderer.Renderer, x: i32, width: u32, label: []const u8) !void {
    ctx.drawChip(target, x, ctx.chip_y, width, ctx.chip_h, label, ctx.cfg.theme.clock_bg, ctx.cfg.theme.clock_fg);
    try ctx.addClickable(x, ctx.chip_y, width, ctx.chip_h, .{
        .dual_command = .{
            .left = "mizu calendar",
            .right = "mizu quicksettings",
        },
    });
}

fn formatClockTime(fmt: []const u8, buf: []u8) []const u8 {
    c.tzset();
    const now = c.time(null);
    var tm: c.struct_tm = undefined;
    _ = c.localtime_r(&now, &tm);

    var fmt_buf: [64]u8 = undefined;
    const c_fmt = if (fmt.len > 0 and fmt.len < fmt_buf.len) blk: {
        @memcpy(fmt_buf[0..fmt.len], fmt);
        fmt_buf[fmt.len] = 0;
        break :blk fmt_buf[0..fmt.len :0].ptr;
    } else "%I:%M %p";

    const len = c.strftime(buf.ptr, buf.len, c_fmt, &tm);
    return if (len > 0) buf[0..len] else "12:00 AM";
}
