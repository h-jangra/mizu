const std = @import("std");
const ui_mod = @import("ui.zig");
const theme = @import("theme.zig");

// Item descriptor for a dropdown list option.
pub const DropdownItem = struct {
    label: []const u8,
    icon: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

// Configuration options for rendering a dropdown component.
pub const DropdownOptions = struct {
    id: []const u8,
    title: ?[]const u8 = null,
    current_label: []const u8,
    leading_icon: ?[]const u8 = null,
    is_open: bool = false,
    items: []const DropdownItem,
    selected_index: ?usize = null,
    height: u32 = 42,
    item_height: u32 = 36,
    font_size: u32 = 13,
    title_font_size: u32 = 12,
    theme: theme.Theme,
    scale: u32 = 1,
};

// Render an expandable dropdown selector using Clay UI elements.
pub fn render(ui: *ui_mod.Ui, opts: DropdownOptions) !void {
    // Outer column grouping title, header trigger, and opened list
    _ = ui.open(.{
        .width = .{ .grow = .{} },
        .direction = .column,
        .gap = ui.su(6),
    });

    if (opts.title) |t| {
        ui.text(t, .{
            .size = opts.title_font_size * opts.scale,
            .color = opts.theme.text_bright,
        });
    }

    const hdr_id = try std.fmt.allocPrint(ui.allocator, "{s}-hdr", .{opts.id});
    const hdr_hov = ui.hovered(hdr_id, 0);

    // Dropdown trigger button
    _ = ui.open(.{
        .id = hdr_id,
        .width = .{ .grow = .{} },
        .height = .{ .fixed = ui.s(opts.height) },
        .direction = .row,
        .padding = .{ .left = ui.su(12), .right = ui.su(12) },
        .gap = ui.su(10),
        .bg = if (opts.is_open)
            opts.theme.elevated
        else if (hdr_hov)
            opts.theme.card_hover_bg
        else
            opts.theme.card_bg,
        .radius = ui.f(10),
        .border = ui.su(1),
        .border_color = if (opts.is_open or hdr_hov) opts.theme.border_focused else opts.theme.border,
        .align_y = .center,
    });

    if (opts.leading_icon) |ico| {
        ui.icon(ico, 18 * opts.scale, if (opts.is_open) opts.theme.accent else opts.theme.text_bright, 0);
    }

    _ = ui.open(.{
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .direction = .column,
        .align_y = .center,
        .clip_horizontal = true,
    });
    ui.text(opts.current_label, .{
        .size = opts.font_size * opts.scale,
        .color = if (opts.is_open) opts.theme.accent else opts.theme.text_bright,
    });
    ui.close();

    // Dropdown indicator arrow using down.svg, flipped 180 degrees when opened
    ui.iconRotated(
        "down",
        14 * opts.scale,
        if (opts.is_open) opts.theme.accent else opts.theme.text_muted,
        if (opts.is_open) 180.0 else 0.0,
        0,
    );

    ui.close(); // trigger button

    // Expanded options list
    if (opts.is_open and opts.items.len > 0) {
        const item_base_id = try std.fmt.allocPrint(ui.allocator, "{s}-item", .{opts.id});

        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .direction = .column,
            .gap = ui.su(3),
            .padding = .all(ui.su(4)),
            .bg = opts.theme.surface,
            .radius = ui.f(10),
            .border = ui.su(1),
            .border_color = opts.theme.border,
        });

        for (opts.items, 0..) |item, idx| {
            const is_sel = (opts.selected_index != null and opts.selected_index.? == idx);
            const is_hov = ui.hovered(item_base_id, @intCast(idx));

            _ = ui.open(.{
                .id = item_base_id,
                .index = @intCast(idx),
                .width = .{ .grow = .{} },
                .height = .{ .fixed = ui.s(opts.item_height) },
                .direction = .row,
                .padding = .{ .left = ui.su(10), .right = ui.su(10) },
                .gap = ui.su(8),
                .bg = if (is_sel)
                    opts.theme.elevated
                else if (is_hov)
                    opts.theme.card_hover_bg
                else
                    null,
                .radius = ui.f(8),
                .border = if (is_sel) ui.su(1) else 0,
                .border_color = if (is_sel) opts.theme.border_focused else null,
                .align_y = .center,
            });

            if (item.icon) |ico| {
                ui.icon(ico, 16 * opts.scale, if (is_sel) opts.theme.accent else opts.theme.text_bright, @intCast(idx));
            }

            _ = ui.open(.{
                .width = .{ .grow = .{} },
                .height = .{ .grow = .{} },
                .direction = .row,
                .align_y = .center,
                .clip_horizontal = true,
            });
            ui.text(item.label, .{
                .size = opts.font_size * opts.scale,
                .color = if (is_sel) opts.theme.accent else opts.theme.text_bright,
            });
            ui.close();

            if (is_sel) {
                ui.icon("check", 14 * opts.scale, opts.theme.accent, @intCast(idx));
            }

            ui.close(); // item row
        }

        ui.close(); // list container
    }

    ui.close(); // outer container
}

test "DropdownOptions basic config" {
    const items = [_]DropdownItem{
        .{ .label = "100%", .icon = "monitor" },
        .{ .label = "125%", .icon = "monitor" },
    };
    const opts = DropdownOptions{
        .id = "test-drop",
        .title = "Scaling",
        .current_label = "100%",
        .items = &items,
        .selected_index = 0,
        .theme = undefined,
    };
    try std.testing.expectEqualStrings("test-drop", opts.id);
    try std.testing.expectEqual(@as(usize, 2), opts.items.len);
    try std.testing.expectEqual(@as(?usize, 0), opts.selected_index);
}
