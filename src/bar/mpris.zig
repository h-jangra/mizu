const types = @import("context.zig");
const ui_mod = @import("../core/ui.zig");

pub fn render(ctx: *types.BarContext, ui: *ui_mod.Ui) !void {
    if (ctx.sys.mpris_state == .stopped or ctx.sys.mpris_track_len == 0) return;

    const playing = ctx.sys.mpris_state == .playing;
    const icon_size = ctx.iconFontSize();

    const id = "bar-mpris";
    const hovered = ui.hovered(id, 0);
    const bg = if (hovered) ctx.cfg.theme.pill_hover else ctx.cfg.theme.clock_bg;
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
            .left = ui.su(4),
            .right = ui.su(4),
        },
        .gap = ui.su(2),
        .bg = bg,
        .radius = ui.f(ctx.cfg.pill_radius),
        .border = if (border_col != null) ui.su(1) else 0,
        .border_color = border_col,
        .align_x = .center,
        .align_y = .center,
    });

    const slot_w = @as(f32, @floatFromInt(icon_size)) + ui.s(10);

    // 1. Previous button
    const prev_id = "bar-mpris-prev";
    const prev_hov = ui.hovered(prev_id, 0);
    _ = ui.open(.{
        .id = prev_id,
        .width = .{ .fixed = slot_w },
        .height = .{ .grow = .{} },
        .bg = if (prev_hov) ctx.cfg.theme.elevated else null,
        .radius = ui.f(ctx.cfg.pill_radius),
        .align_x = .center,
        .align_y = .center,
    });
    ui.icon("previous", icon_size, if (prev_hov) ctx.cfg.theme.accent else ctx.cfg.theme.clock_fg, 0);
    ui.close();

    // 2. Play/Pause button
    const play_id = "bar-mpris-play";
    const play_hov = ui.hovered(play_id, 0);
    const play_icon = if (playing) "pause" else "play";
    const play_fg = if (play_hov)
        ctx.cfg.theme.accent
    else if (playing)
        ctx.cfg.theme.accent
    else
        ctx.cfg.theme.clock_fg;

    _ = ui.open(.{
        .id = play_id,
        .width = .{ .fixed = slot_w },
        .height = .{ .grow = .{} },
        .bg = if (play_hov) ctx.cfg.theme.elevated else null,
        .radius = ui.f(ctx.cfg.pill_radius),
        .align_x = .center,
        .align_y = .center,
    });
    ui.icon(play_icon, icon_size, play_fg, 0);
    ui.close();

    // 3. Next button
    const next_id = "bar-mpris-next";
    const next_hov = ui.hovered(next_id, 0);
    _ = ui.open(.{
        .id = next_id,
        .width = .{ .fixed = slot_w },
        .height = .{ .grow = .{} },
        .bg = if (next_hov) ctx.cfg.theme.elevated else null,
        .radius = ui.f(ctx.cfg.pill_radius),
        .align_x = .center,
        .align_y = .center,
    });
    ui.icon("next", icon_size, if (next_hov) ctx.cfg.theme.accent else ctx.cfg.theme.clock_fg, 0);
    ui.close();

    ui.close();

    try ctx.linkClick(ui, prev_id, 0, .{ .command = "playerctl previous" }, null);
    try ctx.linkClick(ui, play_id, 0, .{
        .dual_command = .{
            .left = "playerctl play-pause",
            .right = "mizu quicksettings",
        },
    }, null);
    try ctx.linkClick(ui, next_id, 0, .{ .command = "playerctl next" }, null);
}
