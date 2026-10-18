const renderer = @import("../renderer.zig");
const theme = @import("../theme.zig");
const types = @import("types.zig");

pub fn toRoman(val: u32, buf: []u8) []const u8 {
    _ = buf;
    return switch (val) {
        1 => "I",
        2 => "II",
        3 => "III",
        4 => "IV",
        5 => "V",
        6 => "VI",
        7 => "VII",
        8 => "VIII",
        9 => "IX",
        10 => "X",
        else => "•",
    };
}

pub fn render(ctx: *types.BarContext, target: renderer.Renderer, start_x: i32) !i32 {
    var x = start_x;

    for (ctx.ipc.tags) |tag| {
        if (!tag.is_active and !tag.is_urgent and tag.client_count == 0) continue;

        var roman_buf: [16]u8 = undefined;
        const label = toRoman(tag.index, &roman_buf);

        const text_w = target.measureText(ctx.font, label);
        const w: u32 = @max(text_w + 14, 26);
        const hovered = ctx.isHovered(x, ctx.chip_y, w, ctx.chip_h);

        const bg = if (tag.is_active)
            ctx.cfg.theme.ws_active_bg
        else if (tag.is_urgent)
            ctx.cfg.theme.ws_urgent_bg
        else if (tag.client_count > 0)
            theme.Color.init(30, 255, 255, 255)
        else if (hovered)
            ctx.cfg.theme.ws_hover_bg
        else
            theme.Color.transparent;

        const fg = if (tag.is_active)
            ctx.cfg.theme.ws_active_fg
        else if (tag.is_urgent)
            ctx.cfg.theme.ws_urgent_fg
        else if (tag.client_count > 0)
            ctx.cfg.theme.ws_occupied_fg
        else if (hovered)
            ctx.cfg.theme.text_bright
        else
            ctx.cfg.theme.ws_empty_fg;

        if (bg.a > 0) {
            if (tag.is_active) {
                target.fillGlassSquircle(x, ctx.chip_y, w, ctx.chip_h, ctx.cfg.pill_radius, bg);
            } else {
                target.fillSquircle(x, ctx.chip_y, w, ctx.chip_h, ctx.cfg.pill_radius, bg);
            }
        }

        if (hovered and !tag.is_active) {
            target.drawSquircleBorder(x, ctx.chip_y, w, ctx.chip_h, ctx.cfg.pill_radius, 1, ctx.cfg.theme.pill_hover);
        }

        target.drawText(ctx.font, label, x + @divTrunc(@as(i32, @intCast(w)) - @as(i32, @intCast(text_w)), 2), ctx.baseline_y, fg);
        try ctx.addClickable(x, ctx.chip_y, w, ctx.chip_h, .{ .workspace = tag.index });

        x += @as(i32, @intCast(w + 3));
    }

    return x;
}
