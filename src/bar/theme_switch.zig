const types = @import("context.zig");
const ui_mod = @import("../core/ui.zig");

pub fn render(ctx: *types.BarContext, ui: *ui_mod.Ui) !void {
    const icon_size = ctx.iconFontSize();
    const id = "bar-theme-switch";
    const hovered = ui.hovered(id, 0);
    const bg = if (hovered) ctx.cfg.theme.pill_hover else ctx.cfg.theme.theme_bg;
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
        .padding = .{ .left = ui.su(7), .right = ui.su(7) },
        .bg = bg,
        .radius = ui.f(ctx.cfg.pill_radius),
        .border = if (border_col != null) ui.su(1) else 0,
        .border_color = border_col,
        .align_x = .center,
        .align_y = .center,
    });
    ui.icon("palette", icon_size, if (hovered) ctx.cfg.theme.accent else ctx.cfg.theme.theme_fg, 0);
    ui.close();

    const action: types.ClickAction = .{ .cycle_theme = true };
    try ctx.linkClick(ui, id, 0, action, .cycle_theme);
}
