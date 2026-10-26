const types = @import("context.zig");
const ui_mod = @import("../core/ui.zig");

pub fn render(ctx: *types.BarContext, ui: *ui_mod.Ui) !void {
    for (ctx.cfg.buttons.items, 0..) |btn, i| {
        if (btn.label.len == 0) continue;

        const id = "bar-custom-button";
        const hovered = ui.hovered(id, @intCast(i));
        const bg = if (hovered) ctx.cfg.theme.pill_hover else ctx.cfg.theme.pill_bg;
        const border_col = if (hovered)
            ctx.cfg.theme.accent
        else if (ctx.cfg.theme.pill_border.a > 0)
            ctx.cfg.theme.pill_border
        else
            null;

        _ = ui.open(.{
            .id = id,
            .index = @intCast(i),
            .width = .fit,
            .height = .{ .grow = .{} },
            .padding = .{ .left = ui.su(9), .right = ui.su(9) },
            .bg = bg,
            .radius = ui.f(ctx.cfg.pill_radius),
            .border = if (border_col != null) ui.su(1) else 0,
            .border_color = border_col,
            .align_y = .center,
        });
        ui.text(btn.label, .{
            .size = ctx.textFontSize(),
            .color = ctx.cfg.theme.text_bright,
        });
        ui.close();

        try ctx.linkClick(ui, id, @intCast(i), .{ .command = btn.command }, null);
    }
}
