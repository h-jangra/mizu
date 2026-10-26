const std = @import("std");
const renderer = @import("../core/renderer.zig");
const types = @import("context.zig");
const ui_mod = @import("../core/ui.zig");

fn truncateText(font: *renderer.Font, text: []const u8, size: u32, max_w: u32, buf: []u8) []const u8 {
    if (font.measureTextWithSize(text, size) <= max_w) return text;

    const ellipsis = "...";
    const ellipsis_w = font.measureTextWithSize(ellipsis, size);
    if (ellipsis_w >= max_w) return "";

    const available_w = max_w - ellipsis_w;
    var view = std.unicode.Utf8View.init(text) catch return "";
    var iter = view.iterator();
    var cur_len: usize = 0;

    while (iter.nextCodepoint()) |cp| {
        var cp_buf: [4]u8 = undefined;
        const cp_len = std.unicode.utf8Encode(cp, &cp_buf) catch break;
        if (cur_len + cp_len + ellipsis.len > buf.len) break;
        @memcpy(buf[cur_len .. cur_len + cp_len], cp_buf[0..cp_len]);
        const candidate_w = font.measureTextWithSize(buf[0 .. cur_len + cp_len], size);
        if (candidate_w > available_w) break;
        cur_len += cp_len;
    }

    if (cur_len == 0) return "";
    @memcpy(buf[cur_len .. cur_len + ellipsis.len], ellipsis);
    return buf[0 .. cur_len + ellipsis.len];
}

pub fn render(ctx: *types.BarContext, ui: *ui_mod.Ui) !void {
    if (ctx.sys.mpris_state == .stopped or ctx.sys.mpris_track_len == 0) return;

    const playing = ctx.sys.mpris_state == .playing;
    const icon = if (playing) "󰎆" else "󰏥";
    const icon_color = if (playing) ctx.cfg.theme.accent else ctx.cfg.theme.text_muted;
    const icon_size = ctx.iconFontSize();
    const text_size = ctx.textFontSize();

    var buf: [128]u8 = undefined;
    const text = truncateText(
        ctx.font,
        ctx.sys.mpris_track[0..ctx.sys.mpris_track_len],
        text_size,
        @as(u32, @intFromFloat(ui.f(260))),
        &buf,
    );
    if (text.len == 0) return;

    const id = "bar-mpris";
    const hovered = ui.hovered(id, 0);
    const bg = if (hovered)
        ctx.cfg.theme.pill_hover
    else if (playing)
        ctx.cfg.theme.mpris_playing_bg
    else
        ctx.cfg.theme.mpris_paused_bg;

    _ = ui.open(.{
        .id = id,
        .width = .fit,
        .height = .{ .grow = .{} },
        .padding = .{
            .left = ui.su(8),
            .right = ui.su(8),
        },
        .gap = ui.su(6),
        .bg = bg,
        .radius = ui.f(ctx.cfg.pill_radius),
        .align_x = .center,
        .align_y = .center,
    });
    ui.text(icon, .{ .size = icon_size, .color = icon_color });
    ui.text(text, .{ .size = text_size, .color = ctx.cfg.theme.text_main });
    ui.close();

    try ctx.linkClick(ui, id, 0, .{ .command = "playerctl play-pause" }, null);
}
