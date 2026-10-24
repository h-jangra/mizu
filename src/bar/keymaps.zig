const std = @import("std");
const renderer = @import("../core/renderer.zig");
const types = @import("context.zig");
const icons = @import("../graphics/icons.zig");
const c = @import("../c.zig").c;

pub fn isKeymapsActive() bool {
    const pid_path = "/tmp/mizu-keyoverlay.pid";
    if (c.fopen(pid_path, "rb")) |f| {
        defer _ = c.fclose(f);
        var buf: [32]u8 = undefined;
        const n = c.fread(&buf, 1, buf.len - 1, f);
        if (n > 0) {
            buf[n] = 0;
            const pid_str = std.mem.trim(u8, buf[0..n], " \t\r\n");
            const pid = std.fmt.parseInt(c_int, pid_str, 10) catch return false;
            if (pid > 0 and c.kill(pid, 0) == 0) {
                return true;
            }
        }
    }
    return false;
}

fn renderChip(
    ctx: *types.BarContext,
    target: renderer.Renderer,
    x: i32,
    is_active: bool,
) !u32 {
    const icon_size = ctx.iconFontSize();
    const chip_w = icon_size + 22 * ctx.scale;

    const icon_fg = if (is_active) ctx.cfg.theme.accent else ctx.cfg.theme.text_muted;
    const bg = if (is_active) ctx.cfg.theme.pill_hover else ctx.cfg.theme.pill_bg;

    ctx.drawChipBase(target, x, ctx.chip_y, chip_w, ctx.chip_h, bg);
    icons.drawSvgIcon(
        target,
        ctx.allocator,
        "keyboard",
        icon_size,
        ctx.scale,
        x + @divTrunc(@as(i32, @intCast(chip_w)), 2),
        ctx.chip_y + @divTrunc(@as(i32, @intCast(ctx.chip_h)), 2),
        icon_fg,
    );

    try ctx.addClickable(x, ctx.chip_y, chip_w, ctx.chip_h, .{
        .dual_command = .{
            .left = "mizu keyoverlay 2>/dev/null || true",
            .right = "mizu keyoverlay 2>/dev/null || true",
        },
    });

    return chip_w;
}

pub fn render(ctx: *types.BarContext, target: renderer.Renderer, cur_x: i32) !i32 {
    const is_active = isKeymapsActive();
    const chip_w = try renderChip(ctx, target, cur_x, is_active);
    return cur_x + @as(i32, @intCast(chip_w + 4 * ctx.scale));
}

pub fn renderRight(ctx: *types.BarContext, target: renderer.Renderer, right_x: i32) !i32 {
    const is_active = isKeymapsActive();
    const icon_size = ctx.iconFontSize();
    const chip_w = icon_size + 22 * ctx.scale;
    const rx = right_x - @as(i32, @intCast(chip_w));

    _ = try renderChip(ctx, target, rx, is_active);
    return rx;
}
