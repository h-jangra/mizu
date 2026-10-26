const types = @import("context.zig");
const ui_mod = @import("../core/ui.zig");

pub fn render(ctx: *types.BarContext, ui: *ui_mod.Ui) !void {
    const icon_size = ctx.iconFontSize();
    const icon_name = if (ctx.sys.volume_muted)
        "volume-muted"
    else if (ctx.sys.volume_percent >= 67)
        "volume-high"
    else if (ctx.sys.volume_percent >= 34)
        "volume-medium"
    else
        "volume-low";
    const fg = if (ctx.sys.volume_muted) ctx.cfg.theme.text_muted else ctx.cfg.theme.audio_fg;

    const id = "bar-volume";
    const hovered = ui.hovered(id, 0);
    const border_col = if (hovered) ctx.cfg.theme.accent else null;

    _ = ui.open(.{
        .id = id,
        .width = .{ .fixed = @as(f32, @floatFromInt(icon_size)) + ui.s(16) },
        .height = .{ .grow = .{} },
        .bg = if (hovered) ctx.cfg.theme.pill_hover else null,
        .radius = ui.f(ctx.cfg.pill_radius),
        .border = if (border_col != null) ui.su(1) else 0,
        .border_color = border_col,
        .align_x = .center,
        .align_y = .center,
    });
    ui.icon(icon_name, icon_size, fg, 0);
    ui.close();

    const action: types.ClickAction = .{ .dual_command = .{
        .left = "mizu quicksettings",
        .right = "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle",
    } };
    try ctx.linkClick(ui, id, 0, action, .volume);
}
