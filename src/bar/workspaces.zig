const renderer = @import("../core/renderer.zig");
const theme = @import("../core/theme.zig");
const types = @import("context.zig");

pub fn render(ctx: *types.BarContext, target: renderer.Renderer, start_x: i32) !i32 {
    var x = start_x;

    for (ctx.ipc.tags) |tag| {
        if (!tag.is_active and !tag.is_urgent and tag.client_count == 0) continue;

        const w: u32 = if (tag.is_active)
            28
        else if (tag.is_urgent)
            20
        else if (tag.client_count > 0)
            14
        else
            10;

        const hovered = ctx.isHovered(x, ctx.chip_y, w, ctx.chip_h);

        const pill_h: u32 = if (tag.is_active or tag.is_urgent)
            if (ctx.chip_h > 4) ctx.chip_h - 4 else ctx.chip_h
        else if (ctx.chip_h > 12) ctx.chip_h - 12 else 8;
        const pill_y: i32 = ctx.chip_y + @as(i32, @intCast((ctx.chip_h - pill_h) / 2));
        const radius: u32 = pill_h / 2;

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

        target.fillRoundedRect(x, pill_y, w, pill_h, radius, bg);

        if (hovered) {
            target.drawRoundedBorder(x, pill_y, w, pill_h, radius, 1, ctx.cfg.theme.accent);
        } else if (tag.is_active) {
            target.drawRoundedBorder(x, pill_y, w, pill_h, radius, 1, ctx.cfg.theme.border_focused);
        }

        try ctx.addClickable(x, ctx.chip_y, w, ctx.chip_h, .{ .workspace = tag.index });

        x += @as(i32, @intCast(w + 6));
    }

    return x;
}
