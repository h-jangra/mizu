const types = @import("context.zig");
const ui_mod = @import("../core/ui.zig");

pub fn render(ctx: *types.BarContext, ui: *ui_mod.Ui) !void {
    ui.text("|", .{
        .size = 10 * ctx.scale,
        .color = ctx.cfg.theme.separator_fg,
    });
}
