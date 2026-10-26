const std = @import("std");
const types = @import("context.zig");
const ui_mod = @import("../core/ui.zig");

pub fn render(ctx: *types.BarContext, ui: *ui_mod.Ui) !void {
    var buf: [24]u8 = undefined;
    const value = try std.fmt.bufPrint(&buf, "{d:.1} GB", .{ctx.sys.mem_used_gib});
    const icon_size = ctx.iconFontSize();
    const id = "bar-memory";
    const hovered = ui.hovered(id, 0);
    const border_col = if (hovered)
        ctx.cfg.theme.accent
    else if (ctx.cfg.theme.pill_border.a > 0)
        ctx.cfg.theme.pill_border
    else
        null;

    _ = ui.open(.{
        .id = id,
        .width = .fit,
        .height = .{ .grow = .{} },
        .padding = .{
            .left = ui.su(8),
            .right = ui.su(8),
        },
        .gap = ui.su(8),
        .bg = if (hovered) ctx.cfg.theme.pill_hover else ctx.cfg.theme.cpu_mem_bg,
        .radius = ui.f(ctx.cfg.pill_radius),
        .border = if (border_col != null) ui.su(1) else 0,
        .border_color = border_col,
        .align_y = .center,
    });
    ui.icon("memory", icon_size, ctx.cfg.theme.cpu_mem_fg, 0);
    ui.text(value, .{
        .size = ctx.textFontSize(),
        .color = ctx.cfg.theme.text_main,
    });
    ui.close();

    try ctx.linkClick(ui, id, 0, .{
        .dual_command = .{
            .left = "mizu memory-monitor",
            .right = "mizu quicksettings",
        },
    }, null);
}
