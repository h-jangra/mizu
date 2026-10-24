const std = @import("std");
const renderer = @import("../core/renderer.zig");
const theme = @import("../core/theme.zig");
const types = @import("context.zig");

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

pub fn render(ctx: *types.BarContext, target: renderer.Renderer, right_x: i32) !i32 {
    var items_buf: [MIZU_MAX_TRAY_ITEMS]MizuTrayItem = undefined;
    const total_items = mizu_tray_get_items(&items_buf, @intCast(MIZU_MAX_TRAY_ITEMS));
    if (total_items <= 0) return right_x;

    const count: usize = @min(@as(usize, @intCast(total_items)), MIZU_MAX_TRAY_ITEMS);
    if (count == 0) return right_x;

    const slot_w: u32 = 28;
    const pad: u32 = 4;
    const total_w: u32 = @as(u32, @intCast(count)) * slot_w + pad * 2;
    const x = right_x - @as(i32, @intCast(total_w));

    // Outer unified capsule container with soft elevated shadow
    const is_tray_hovered = ctx.isHovered(x, ctx.chip_y, total_w, ctx.chip_h);
    if (is_tray_hovered) {
        target.drawDropShadow(x, ctx.chip_y, total_w, ctx.chip_h, ctx.cfg.pill_radius, 4, theme.Color.init(115, 0, 0, 0));
    } else {
        target.drawDropShadow(x, ctx.chip_y, total_w, ctx.chip_h, ctx.cfg.pill_radius, 2, theme.Color.init(55, 0, 0, 0));
    }

    target.fillRoundedRect(x, ctx.chip_y, total_w, ctx.chip_h, ctx.cfg.pill_radius, ctx.cfg.theme.pill_bg);
    target.drawRoundedBorder(x, ctx.chip_y, total_w, ctx.chip_h, ctx.cfg.pill_radius, 1, if (is_tray_hovered) ctx.cfg.theme.accent else ctx.cfg.theme.pill_border);

    // Render individual item icons inside capsule
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const item = &items_buf[i];
        const item_x = x + @as(i32, @intCast(pad + @as(u32, @intCast(i)) * slot_w));
        const item_w = slot_w;
        const is_item_hovered = ctx.isHovered(item_x, ctx.chip_y, item_w, ctx.chip_h);

        // Hover highlight for single item
        if (is_item_hovered) {
            target.fillSquircle(item_x + 2, ctx.chip_y + 2, item_w - 4, ctx.chip_h - 4, 6, ctx.cfg.theme.elevated);
        }

        // Draw Pixmap or Nerd Font glyph
        if (item.pixmap_w > 0 and item.pixmap_h > 0) {
            const pw = item.pixmap_w;
            const ph = item.pixmap_h;
            const icon_w = @min(pw, 20);
            const icon_h = @min(ph, 20);
            const ox = item_x + @divTrunc(@as(i32, @intCast(item_w)) - @as(i32, @intCast(icon_w)), 2);
            const oy = ctx.chip_y + @divTrunc(@as(i32, @intCast(ctx.chip_h)) - @as(i32, @intCast(icon_h)), 2);

            var py: u32 = 0;
            while (py < icon_h) : (py += 1) {
                const src_y = (py * ph) / icon_h;
                var px: u32 = 0;
                while (px < icon_w) : (px += 1) {
                    const src_x = (px * pw) / icon_w;
                    const argb = item.pixmap_data[src_y * 32 + src_x];
                    const a: u8 = @intCast((argb >> 24) & 0xFF);
                    const r: u8 = @intCast((argb >> 16) & 0xFF);
                    const g: u8 = @intCast((argb >> 8) & 0xFF);
                    const b: u8 = @intCast(argb & 0xFF);
                    const col = theme.Color.init(a, r, g, b);
                    if (col.a > 0) {
                        target.setPixel(ox + @as(i32, @intCast(px)), oy + @as(i32, @intCast(py)), col);
                    }
                }
            }
        } else {
            const id_slice = std.mem.span(@as([*:0]const u8, @ptrCast(&item.id)));
            const icon_slice = std.mem.span(@as([*:0]const u8, @ptrCast(&item.icon_name)));
            const title_slice = std.mem.span(@as([*:0]const u8, @ptrCast(&item.title)));
            const icon = getIconForApp(id_slice, icon_slice, title_slice);

            const icon_size = ctx.iconFontSize();
            const icon_w = target.measureTextWithSize(ctx.font, icon, icon_size);
            const icon_x = item_x + @divTrunc(@as(i32, @intCast(item_w)) - @as(i32, @intCast(icon_w)), 2);
            const icon_y = ctx.baseline_y;
            target.drawTextWithSize(ctx.font, icon, icon_x, icon_y, icon_size, if (is_item_hovered) ctx.cfg.theme.accent else ctx.cfg.theme.text_main);
        }

        // Register interactive clickable area for this specific item
        var act_item: types.TrayItemAction = undefined;
        act_item.index = @intCast(i);
        @memcpy(act_item.service[0..item.service.len], item.service[0..item.service.len]);
        @memcpy(act_item.path[0..item.path.len], item.path[0..item.path.len]);

        try ctx.clickable_areas.append(ctx.allocator, .{
            .x = item_x,
            .y = ctx.chip_y,
            .w = item_w,
            .h = ctx.chip_h,
            .action = .{ .tray_item = act_item },
            .scroll = null,
        });
    }

    return x;
}
