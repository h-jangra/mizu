const std = @import("std");
const renderer = @import("../core/renderer.zig");
const theme = @import("../core/theme.zig");
const types = @import("context.zig");
const ui_mod = @import("../core/ui.zig");

pub const MIZU_MAX_TRAY_ITEMS: usize = 32;

pub const MizuTrayItem = extern struct {
    service: [128]u8,
    path: [128]u8,
    id: [64]u8,
    title: [128]u8,
    icon_name: [128]u8,
    status: [32]u8,
    menu_path: [128]u8,
    is_menu: bool,
    pixmap_w: u32,
    pixmap_h: u32,
    pixmap_data: [32 * 32]u32,
};

pub extern "c" fn mizu_tray_get_items(out_items: [*c]MizuTrayItem, max_items: c_int) c_int;
pub extern "c" fn mizu_tray_item_activate(service: [*c]const u8, path: [*c]const u8, x: i32, y: i32) void;
pub extern "c" fn mizu_tray_item_context_menu(service: [*c]const u8, path: [*c]const u8, x: i32, y: i32) void;
pub extern "c" fn mizu_tray_item_secondary_activate(service: [*c]const u8, path: [*c]const u8, x: i32, y: i32) void;
pub extern "c" fn mizu_tray_item_scroll(service: [*c]const u8, path: [*c]const u8, delta: i32, horizontal: bool) void;

pub fn getIconForApp(id: []const u8, icon_name: []const u8, title: []const u8) []const u8 {
    var lower_buf: [128]u8 = undefined;
    const combined = if (icon_name.len > 0) icon_name else if (id.len > 0) id else title;
    const len = @min(combined.len, lower_buf.len);
    for (combined[0..len], 0..) |ch, i| {
        lower_buf[i] = std.ascii.toLower(ch);
    }
    const name = lower_buf[0..len];

    if (std.mem.indexOf(u8, name, "telegram") != null) return "󰕌";
    if (std.mem.indexOf(u8, name, "discord") != null or std.mem.indexOf(u8, name, "vesktop") != null) return "󰙯";
    if (std.mem.indexOf(u8, name, "steam") != null) return "󰓓";
    if (std.mem.indexOf(u8, name, "obs") != null) return "󰑋";
    if (std.mem.indexOf(u8, name, "spotify") != null) return "󰓇";
    if (std.mem.indexOf(u8, name, "easyeffects") != null) return "󰓃";
    if (std.mem.indexOf(u8, name, "bluetooth") != null) return "󰂯";
    if (std.mem.indexOf(u8, name, "network") != null or std.mem.indexOf(u8, name, "nm-applet") != null or std.mem.indexOf(u8, name, "wifi") != null) return "󰤨";
    if (std.mem.indexOf(u8, name, "volume") != null or std.mem.indexOf(u8, name, "audio") != null or std.mem.indexOf(u8, name, "pavucontrol") != null or std.mem.indexOf(u8, name, "mixer") != null) return "󰕾";
    if (std.mem.indexOf(u8, name, "flameshot") != null or std.mem.indexOf(u8, name, "screenshot") != null) return "󰹑";
    if (std.mem.indexOf(u8, name, "keepass") != null or std.mem.indexOf(u8, name, "bitwarden") != null or std.mem.indexOf(u8, name, "pass") != null) return "󰌋";
    if (std.mem.indexOf(u8, name, "nextcloud") != null or std.mem.indexOf(u8, name, "dropbox") != null or std.mem.indexOf(u8, name, "cloud") != null) return "󰇣";
    if (std.mem.indexOf(u8, name, "slack") != null) return "󰒱";
    if (std.mem.indexOf(u8, name, "element") != null or std.mem.indexOf(u8, name, "matrix") != null) return "󰘑";
    if (std.mem.indexOf(u8, name, "vlc") != null) return "󰕼";
    if (std.mem.indexOf(u8, name, "kdenlive") != null) return "󰕧";
    if (std.mem.indexOf(u8, name, "mail") != null or std.mem.indexOf(u8, name, "thunderbird") != null) return "󰇮";

    return "󰀻";
}

pub fn activateItem(service: [*c]const u8, path: [*c]const u8, x: i32, y: i32) void {
    mizu_tray_item_activate(service, path, x, y);
}

pub fn contextMenuItem(service: [*c]const u8, path: [*c]const u8, x: i32, y: i32) void {
    mizu_tray_item_context_menu(service, path, x, y);
}

pub fn secondaryActivateItem(service: [*c]const u8, path: [*c]const u8, x: i32, y: i32) void {
    mizu_tray_item_secondary_activate(service, path, x, y);
}

pub fn scrollItem(service: [*c]const u8, path: [*c]const u8, delta: i32, horizontal: bool) void {
    mizu_tray_item_scroll(service, path, delta, horizontal);
}

const PixmapDraw = struct {
    width: u32,
    height: u32,
    pixels: [32 * 32]u32,

    fn draw(target: renderer.Renderer, rect: renderer.Rect, data: *const anyopaque) void {
        const self: *const PixmapDraw = @ptrCast(@alignCast(data));
        if (self.width == 0 or self.height == 0) return;
        const icon_w = @min(rect.w, @as(u32, @intFromFloat(@as(f32, @floatFromInt(rect.w)))));
        const icon_h = @min(rect.h, @as(u32, @intFromFloat(@as(f32, @floatFromInt(rect.h)))));
        const ox = rect.x + @divTrunc(@as(i32, @intCast(rect.w)) - @as(i32, @intCast(icon_w)), 2);
        const oy = rect.y + @divTrunc(@as(i32, @intCast(rect.h)) - @as(i32, @intCast(icon_h)), 2);
        var py: u32 = 0;
        while (py < icon_h) : (py += 1) {
            const src_y = (py * self.height) / icon_h;
            var px: u32 = 0;
            while (px < icon_w) : (px += 1) {
                const src_x = (px * self.width) / icon_w;
                const argb = self.pixels[src_y * 32 + src_x];
                const a: u8 = @intCast((argb >> 24) & 0xFF);
                if (a == 0) continue;
                const r: u8 = @intCast((argb >> 16) & 0xFF);
                const g: u8 = @intCast((argb >> 8) & 0xFF);
                const b: u8 = @intCast(argb & 0xFF);
                target.setPixel(ox + @as(i32, @intCast(px)), oy + @as(i32, @intCast(py)), theme.Color.init(a, r, g, b));
            }
        }
    }
};

pub fn render(ctx: *types.BarContext, ui: *ui_mod.Ui) !void {
    var items_buf: [MIZU_MAX_TRAY_ITEMS]MizuTrayItem = undefined;
    const total_items = mizu_tray_get_items(&items_buf, @intCast(MIZU_MAX_TRAY_ITEMS));
    if (total_items <= 0) return;

    const count: usize = @min(@as(usize, @intCast(total_items)), MIZU_MAX_TRAY_ITEMS);
    if (count == 0) return;

    const container_id = "bar-tray";
    const container_hovered = ui.hovered(container_id, 0);
    const border_col = if (container_hovered)
        ctx.cfg.theme.accent
    else if (ctx.cfg.theme.pill_border.a > 0)
        ctx.cfg.theme.pill_border
    else
        null;

    _ = ui.open(.{
        .id = container_id,
        .width = .fit,
        .height = .{ .grow = .{} },
        .padding = .{ .left = ui.su(4), .right = ui.su(4) },
        .bg = ctx.cfg.theme.pill_bg,
        .radius = ui.f(ctx.cfg.pill_radius),
        .border = if (border_col != null) ui.su(1) else 0,
        .border_color = border_col,
        .align_x = .left,
        .align_y = .center,
    });

    const slot_w = ui.s(28);
    const icon_size = ctx.iconFontSize();

    for (items_buf[0..count], 0..) |*item, i| {
        const item_id = "bar-tray-item";
        const item_hovered = ui.hovered(item_id, @intCast(i));

        _ = ui.open(.{
            .id = item_id,
            .index = @intCast(i),
            .width = .{ .fixed = slot_w },
            .height = .{ .grow = .{} },
            .bg = if (item_hovered) ctx.cfg.theme.elevated else null,
            .radius = ui.f(6),
            .align_x = .center,
            .align_y = .center,
        });

        if (item.pixmap_w > 0 and item.pixmap_h > 0) {
            const draw_data = try ui.allocator.create(PixmapDraw);
            draw_data.* = .{
                .width = item.pixmap_w,
                .height = item.pixmap_h,
                .pixels = item.pixmap_data,
            };
            const custom = try ui.allocator.create(ui_mod.Custom);
            custom.* = .{ .callback = .{
                .function = PixmapDraw.draw,
                .data = draw_data,
            } };
            ui.custom(.{ .fixed = @as(f32, @floatFromInt(icon_size)) }, .{ .fixed = @as(f32, @floatFromInt(icon_size)) }, custom, 0);
            ui.close();
        } else {
            const id_slice = std.mem.span(@as([*:0]const u8, @ptrCast(&item.id)));
            const icon_slice = std.mem.span(@as([*:0]const u8, @ptrCast(&item.icon_name)));
            const title_slice = std.mem.span(@as([*:0]const u8, @ptrCast(&item.title)));
            const icon = getIconForApp(id_slice, icon_slice, title_slice);
            ui.text(icon, .{
                .size = icon_size,
                .color = if (item_hovered) ctx.cfg.theme.accent else ctx.cfg.theme.text_main,
            });
        }
        ui.close();

        var act_item: types.TrayItemAction = undefined;
        act_item.index = @intCast(i);
        @memcpy(act_item.service[0..item.service.len], item.service[0..item.service.len]);
        @memcpy(act_item.path[0..item.path.len], item.path[0..item.path.len]);
        try ctx.linkClick(ui, item_id, @intCast(i), .{ .tray_item = act_item }, null);
    }

    ui.close();
}
