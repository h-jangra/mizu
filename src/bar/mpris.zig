const std = @import("std");
const renderer = @import("../renderer.zig");
const types = @import("types.zig");

fn truncateText(target: renderer.Renderer, font: *renderer.Font, text: []const u8, max_w: u32, buf: []u8) []const u8 {
    if (target.measureText(font, text) <= max_w) return text;

    const ellipsis = "...";
    const ellipsis_w = target.measureText(font, ellipsis);
    if (ellipsis_w > max_w) return "";

    var view = std.unicode.Utf8View.init(text) catch return "";
    var iter = view.iterator();
    var len: usize = 0;

    while (iter.nextCodepointSlice()) |slice| {
        if (len + slice.len + ellipsis.len > buf.len) break;
        @memcpy(buf[len .. len + slice.len], slice);
        len += slice.len;

        @memcpy(buf[len .. len + ellipsis.len], ellipsis);
        if (target.measureText(font, buf[0 .. len + ellipsis.len]) > max_w) {
            len -= slice.len;
            break;
        }
    }

    if (len == 0) return "";
    @memcpy(buf[len .. len + ellipsis.len], ellipsis);
    return buf[0 .. len + ellipsis.len];
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
    const icon_w = target.measureText(ctx.font, icon);

    var buf: [128]u8 = undefined;
    const text = truncateText(
        target,
        ctx.font,
        ctx.sys.mpris_track[0..ctx.sys.mpris_track_len],
        max_w -| (icon_w + 24),
        &buf,
    );
    const text_w = target.measureText(ctx.font, text);
    const width = @min(icon_w + text_w + 22, max_w);
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
