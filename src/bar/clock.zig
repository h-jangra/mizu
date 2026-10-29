const std = @import("std");
const types = @import("context.zig");
const c = @import("c");
const ui_mod = @import("../core/ui.zig");

var tz_initialized: bool = false;

pub fn render(ctx: *types.BarContext, ui: *ui_mod.Ui) !void {
    var buf: [64]u8 = undefined;
    const label = formatClockTime(ctx.cfg.clock_format, &buf);
    const id = "bar-clock";
    const hovered = ui.hovered(id, 0);
    const bg = if (hovered) ctx.cfg.theme.pill_hover else ctx.cfg.theme.clock_bg;
    const border_col = if (hovered) ctx.cfg.theme.accent else null;

    _ = ui.open(.{
        .id = id,
        .width = .fit,
        .height = .{ .grow = .{} },
        .padding = .{ .left = ui.su(9), .right = ui.su(9) },
        .bg = bg,
        .radius = ui.f(ctx.cfg.pill_radius),
        .border = if (border_col != null) ui.su(1) else 0,
        .border_color = border_col,
        .align_y = .center,
    });
    ui.text(label, .{
        .size = ctx.textFontSize(),
        .color = ctx.cfg.theme.clock_fg,
    });
    ui.close();

    try ctx.linkClick(ui, id, 0, .{
        .dual_command = .{
            .left = "mizu calendar",
            .right = "mizu quicksettings",
        },
    }, null);
}

pub fn formatNow(fmt: []const u8, buf: []u8) []const u8 {
    return formatClockTime(fmt, buf);
}

fn formatClockTime(fmt: []const u8, buf: []u8) []const u8 {
    if (!tz_initialized) {
        c.tzset();
        tz_initialized = true;
    }
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
