const std = @import("std");
const renderer = @import("../renderer.zig");
const types = @import("types.zig");
const theme = @import("../theme.zig");

pub fn render(ctx: *types.BarContext, target: renderer.Renderer, right_x: i32) !i32 {
    const is_enabled = ctx.sys.bluetooth_enabled;
    const is_connected = is_enabled and ctx.sys.bluetooth_connected;

    if (!is_connected) return right_x;

    const icon = "󰂱";
    const icon_w = target.measureText(ctx.font, icon);
    const chip_w: u32 = icon_w + 16;
    const rx = right_x - @as(i32, @intCast(chip_w));

    ctx.drawChipWithIcon(
        target,
        rx,
        ctx.chip_y,
        chip_w,
        ctx.chip_h,
        icon,
        ctx.cfg.theme.network_fg,
        "",
        ctx.cfg.theme.text_main,
        ctx.cfg.theme.network_bg,
    );

    try ctx.addClickable(rx, ctx.chip_y, chip_w, ctx.chip_h, .{
        .dual_command = .{
            .left = "mizu quicksettings",
            .right = "mizu quicksettings",
        },
    });

    return rx;
}
