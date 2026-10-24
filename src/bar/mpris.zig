const std = @import("std");
const renderer = @import("../core/renderer.zig");
const types = @import("context.zig");

fn truncateText(target: renderer.Renderer, font: *renderer.Font, text: []const u8, max_w: u32, buf: []u8) []const u8 {
    const total_w = target.measureText(font, text);
    if (total_w <= max_w) return text;

    const ellipsis = "...";
    const ellipsis_w = target.measureText(font, ellipsis);
    if (ellipsis_w >= max_w) return "";

    const available_w = max_w - ellipsis_w;
    var view = std.unicode.Utf8View.init(text) catch return "";
    var iter = view.iterator();
    var cur_len: usize = 0;
    var acc_w: u32 = 0;

    while (iter.nextCodepoint()) |cp| {
        const glyph_adv = if (font.getOrLoadGlyph(cp, font.size_px)) |cg|
            (if (cg.advance_x > 0) @as(u32, @intCast(cg.advance_x)) else 0)
        else
            font.size_px / 2;

        if (acc_w + glyph_adv > available_w) break;
        acc_w += glyph_adv;

        var cp_buf: [4]u8 = undefined;
        const cp_len = std.unicode.utf8Encode(cp, &cp_buf) catch break;
        if (cur_len + cp_len + ellipsis.len > buf.len) break;
        @memcpy(buf[cur_len .. cur_len + cp_len], cp_buf[0..cp_len]);
        cur_len += cp_len;
    }

    if (cur_len == 0) return "";
    @memcpy(buf[cur_len .. cur_len + ellipsis.len], ellipsis);
    return buf[0 .. cur_len + ellipsis.len];
}

pub fn render(ctx: *types.BarContext, target: renderer.Renderer, clock_x: i32, left_boundary_x: i32) !void {
    if (ctx.sys.mpris_state == .stopped or ctx.sys.mpris_track_len == 0) return;

    const max_w: u32 = if (clock_x > left_boundary_x + 30)
        @intCast(@min(280, clock_x - left_boundary_x - 16))
    else
        0;
    if (max_w < 40) return;

    const playing = ctx.sys.mpris_state == .playing;
    const icon = if (playing) "󰎆" else "󰏥";
    const icon_color = if (playing) ctx.cfg.theme.accent else ctx.cfg.theme.text_muted;
    const icon_size = ctx.iconFontSize();
    const icon_w = target.measureTextWithSize(ctx.font, icon, icon_size);

    var buf: [128]u8 = undefined;
    const text = truncateText(
        target,
        ctx.font,
        ctx.sys.mpris_track[0..ctx.sys.mpris_track_len],
        max_w -| (icon_w + 24),
        &buf,
    );
    const text_w = target.measureTextWithSize(ctx.font, text, ctx.textFontSize());
    const width = @min(icon_w + text_w + 22 * ctx.scale, max_w);
    const x = clock_x - @as(i32, @intCast(width)) - 8;
    const bg = if (playing) ctx.cfg.theme.mpris_playing_bg else ctx.cfg.theme.mpris_paused_bg;

    ctx.drawChipWithIcon(
        target,
        x,
        ctx.chip_y,
        width,
        ctx.chip_h,
        icon,
        icon_color,
        text,
        ctx.cfg.theme.text_main,
        bg,
    );

    try ctx.addClickable(x, ctx.chip_y, width, ctx.chip_h, .{
        .command = "playerctl play-pause",
    });
}
