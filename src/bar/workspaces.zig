const theme = @import("../core/theme.zig");
const types = @import("context.zig");
const ui_mod = @import("../core/ui.zig");

pub fn render(ctx: *types.BarContext, ui: *ui_mod.Ui) !void {
    for (ctx.ipc.tags) |tag| {
        if (!tag.is_active and !tag.is_urgent and tag.client_count == 0) continue;

        const w: u32 = if (tag.is_active)
            28
        else if (tag.is_urgent)
            20
        else if (tag.client_count > 0)
            14
        else
            8;

        const pill_h: u32 = 8;

        const id = "bar-workspace";
        const hovered = ui.hovered(id, tag.index);

        const bg = if (tag.is_active)
            ctx.cfg.theme.ws_active_bg
        else if (tag.is_urgent)
            ctx.cfg.theme.ws_urgent_bg
        else if (hovered)
            ctx.cfg.theme.ws_hover_bg
        else if (tag.client_count > 0)
            theme.Color.init(110, 255, 255, 255)
        else
            theme.Color.init(45, 255, 255, 255);

        const border_col = if (hovered)
            ctx.cfg.theme.accent
        else if (tag.is_active)
            ctx.cfg.theme.border_focused
        else
            null;

        const scaled_w = ui.s(w);
        const scaled_h = ui.s(pill_h);

        _ = ui.open(.{
            .id = id,
            .index = tag.index,
            .width = .{ .fixed = scaled_w },
            .height = .{ .grow = .{} },
            .align_x = .center,
            .align_y = .center,
        });
        _ = ui.open(.{
            .width = .{ .fixed = scaled_w },
            .height = .{ .fixed = scaled_h },
            .bg = bg,
            .radius = scaled_h / 2.0,
            .border = if (border_col != null) ui.su(1) else 0,
            .border_color = border_col,
        });
        ui.close();
        ui.close();

        try ctx.linkClick(ui, id, tag.index, .{ .workspace = tag.index }, null);
    }
}
