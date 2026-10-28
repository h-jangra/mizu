const types = @import("context.zig");
const ui_mod = @import("../core/ui.zig");

pub fn render(ctx: *types.BarContext, ui: *ui_mod.Ui) !void {
    const icon_size = ctx.iconFontSize();
    const id = "bar-launcher";
    const is_hov = ui.hovered(id, 0);
    const bg = if (is_hov)
        ctx.cfg.theme.pill_hover
    else
        ctx.cfg.theme.launcher_bg;

    const border_col = if (is_hov)
        ctx.cfg.theme.accent
    else if (ctx.cfg.theme.pill_border.a > 0)
        ctx.cfg.theme.pill_border
    else
        null;

    _ = ui.open(.{
        .id = id,
        .width = .fit,
        .height = .{ .grow = .{} },
        .padding = .{ .left = ui.su(10), .right = ui.su(10) },
        .bg = bg,
        .radius = ui.f(ctx.cfg.pill_radius),
        .border = if (border_col != null) ui.su(1) else 0,
        .border_color = border_col,
        .align_x = .center,
        .align_y = .center,
    });
    ui.icon("mizu", icon_size, ctx.cfg.theme.launcher_fg, 0);
    ui.close();

    try ctx.linkClick(ui, id, 0, .{ .command = "mizu launcher" }, null);
}
