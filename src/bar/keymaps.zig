const std = @import("std");
const types = @import("context.zig");
const c = @import("../c.zig").c;
const ui_mod = @import("../core/ui.zig");

pub fn isKeymapsActive() bool {
    const pid_path = "/tmp/mizu-keyoverlay.pid";
    if (c.fopen(pid_path, "rb")) |f| {
        defer _ = c.fclose(f);
        var buf: [32]u8 = undefined;
        const n = c.fread(&buf, 1, buf.len - 1, f);
        if (n > 0) {
            buf[n] = 0;
            const pid_str = std.mem.trim(u8, buf[0..n], " \t\r\n");
            const pid = std.fmt.parseInt(c_int, pid_str, 10) catch return false;
            if (pid > 0 and c.kill(pid, 0) == 0) {
                return true;
            }
        }
    }
    return false;
}

pub fn render(ctx: *types.BarContext, ui: *ui_mod.Ui) !void {
    const is_active = isKeymapsActive();
    const icon_size = ctx.iconFontSize();
    const id = "bar-keymaps";
    const hovered = ui.hovered(id, 0);

    const icon_fg = if (is_active) ctx.cfg.theme.accent else ctx.cfg.theme.text_muted;
    const bg = if (is_active or hovered) ctx.cfg.theme.pill_hover else ctx.cfg.theme.pill_bg;
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
        .padding = .{ .left = ui.su(10), .right = ui.su(10) },
        .bg = bg,
        .radius = ui.f(ctx.cfg.pill_radius),
        .border = if (border_col != null) ui.su(1) else 0,
        .border_color = border_col,
        .align_x = .center,
        .align_y = .center,
    });
    ui.icon("keyboard", icon_size, icon_fg, 0);
    ui.close();

    try ctx.linkClick(ui, id, 0, .{
        .dual_command = .{
            .left = "mizu keyoverlay 2>/dev/null || true",
            .right = "mizu keyoverlay 2>/dev/null || true",
        },
    }, null);
}
