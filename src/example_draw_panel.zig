/// Minimal example panel demonstrating the Mizu Draw API.
///
/// This is a standalone demonstration file (not part of the main build).
/// It shows: background panel, title text, two rounded cards, an icon,
/// aligned text, a divider line, and a hoverable region using hit-testing.
///
/// To run as a test: `zig test src/example_draw_panel.zig`
const std = @import("std");
const draw = @import("core/draw.zig");
const layout = @import("core/layout.zig");

test "example draw panel compiles and runs primitives" {
    const width: u32 = 400;
    const height: u32 = 300;
    const stride = width * 4;
    const pixels = try std.heap.page_allocator.alloc(u32, width * height);
    defer std.heap.page_allocator.free(pixels);
    defer std.heap.page_allocator.free(pixels);

    var ctx = try draw.DrawCtx.init(pixels.ptr, width, height, stride);

    // Background panel
    ctx.rect(0, 0, width, height, draw.Color.init(255, 25, 25, 35));

    // Title text (top-aligned)
    // Note: Font loading requires FreeType + fontconfig; here we exercise
    // the geometry/layout API without a loaded font.
    var row = layout.RowCursor.init(20, 20, 12);

    // Two rounded cards side by side
    const card1 = row.next(160, 80);
    ctx.roundedRect(card1.x, card1.y, card1.w, card1.h, 12, draw.Color.init(255, 40, 40, 45));
    ctx.border(card1.x, card1.y, card1.w, card1.h, draw.Color.init(255, 90, 90, 100));

    const card2 = row.next(160, 80);
    ctx.roundedRect(card2.x, card2.y, card2.w, card2.h, 12, draw.Color.init(255, 35, 35, 50));
    ctx.roundedBorder(card2.x, card2.y, card2.w, card2.h, 12, draw.Color.init(255, 80, 180, 255));

    // Divider line
    ctx.line(20, 140, 380, 140, draw.Color.init(255, 80, 80, 90));

    // Hoverable region via hit test
    const hover_rect = layout.Rect.init(20, 160, 100, 40);
    const hovered = layout.hitTest(hover_rect, 50, 180);
    ctx.roundedRect(hover_rect.x, hover_rect.y, hover_rect.w, hover_rect.h, 8,
        if (hovered) draw.Color.init(255, 80, 180, 255) else draw.Color.init(255, 60, 60, 70));

    // Circle
    ctx.circle(300, 180, 16, draw.Color.init(255, 255, 100, 100));

    // Shadow
    ctx.shadow(20, 220, 120, 60, 8, 4, draw.Color.init(60, 0, 0, 0));

    // Centering helper
    const centered = layout.Geometry.centerIn(layout.Rect.init(0, 0, width, height), 60, 30);
    _ = centered;

    // Alignment helpers
    const ax = layout.Geometry.alignX(layout.Rect.init(0, 0, width, height), 100, layout.Align.center);
    const ay = layout.Geometry.alignY(layout.Rect.init(0, 0, width, height), 50, layout.Align.center);
    _ = ax; _ = ay;

    // Inset helper
    const inner = layout.Geometry.inset(layout.Rect.init(10, 10, 100, 100), 4);
    try std.testing.expectEqual(@as(i32, 14), inner.x);
    try std.testing.expectEqual(@as(i32, 14), inner.y);
    try std.testing.expectEqual(@as(u32, 92), inner.w);
    try std.testing.expectEqual(@as(u32, 92), inner.h);

    try std.testing.expect(hovered);
}
