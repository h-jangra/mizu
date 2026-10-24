const std = @import("std");
const renderer = @import("core/renderer.zig");
const layout = @import("core/layout.zig");

test "Rect intersect and contains" {
    const r1 = renderer.Rect.init(0, 0, 100, 100);
    const r2 = renderer.Rect.init(50, 50, 100, 100);
    const inter = r1.intersect(r2);
    try std.testing.expectEqual(@as(i32, 50), inter.x);
    try std.testing.expectEqual(@as(i32, 50), inter.y);
    try std.testing.expectEqual(@as(u32, 50), inter.w);
    try std.testing.expectEqual(@as(u32, 50), inter.h);
    try std.testing.expect(r1.contains(10, 10));
    try std.testing.expect(!r1.contains(150, 150));
}

test "Rect intersect no overlap" {
    const r1 = renderer.Rect.init(0, 0, 50, 50);
    const r2 = renderer.Rect.init(100, 100, 50, 50);
    const inter = r1.intersect(r2);
    try std.testing.expectEqual(@as(u32, 0), inter.w);
    try std.testing.expectEqual(@as(u32, 0), inter.h);
    try std.testing.expect(!layout.hitTest(r1, 75, 75));
    try std.testing.expect(layout.hitTest(r1, 25, 25));
}

test "Geometry centerIn" {
    const parent = renderer.Rect.init(0, 0, 200, 100);
    const child = layout.Geometry.centerIn(parent, 50, 30);
    try std.testing.expectEqual(@as(i32, 75), child.x);
    try std.testing.expectEqual(@as(i32, 35), child.y);
    try std.testing.expectEqual(@as(u32, 50), child.w);
    try std.testing.expectEqual(@as(u32, 30), child.h);
}

test "Geometry alignX" {
    const parent = renderer.Rect.init(0, 0, 200, 100);
    try std.testing.expectEqual(@as(i32, 0), layout.Geometry.alignX(parent, 50, layout.Align.left));
    try std.testing.expectEqual(@as(i32, 75), layout.Geometry.alignX(parent, 50, layout.Align.center));
    try std.testing.expectEqual(@as(i32, 150), layout.Geometry.alignX(parent, 50, layout.Align.right));
}

test "Geometry alignY" {
    const parent = renderer.Rect.init(0, 0, 200, 100);
    try std.testing.expectEqual(@as(i32, 0), layout.Geometry.alignY(parent, 50, layout.Align.top));
    try std.testing.expectEqual(@as(i32, 25), layout.Geometry.alignY(parent, 50, layout.Align.center));
    try std.testing.expectEqual(@as(i32, 50), layout.Geometry.alignY(parent, 50, layout.Align.bottom));
}

test "Geometry inset" {
    const r = renderer.Rect.init(10, 10, 100, 100);
    const inner = layout.Geometry.inset(r, 4);
    try std.testing.expectEqual(@as(i32, 14), inner.x);
    try std.testing.expectEqual(@as(i32, 14), inner.y);
    try std.testing.expectEqual(@as(u32, 92), inner.w);
    try std.testing.expectEqual(@as(u32, 92), inner.h);
}

test "RowCursor next and advance" {
    var row = layout.RowCursor.init(10, 20, 8);
    const r1 = row.next(40, 30);
    try std.testing.expectEqual(@as(i32, 10), r1.x);
    try std.testing.expectEqual(@as(i32, 20), r1.y);
    try std.testing.expectEqual(@as(u32, 40), r1.w);
    try std.testing.expectEqual(@as(u32, 30), r1.h);

    const r2 = row.next(30, 20);
    try std.testing.expectEqual(@as(i32, 58), r2.x); // 10 + 40 + 8
    try std.testing.expectEqual(@as(i32, 20), r2.y);

    row.advance(10);
    const r3 = row.next(20, 20);
    try std.testing.expectEqual(@as(i32, 106), r3.x); // 58 + 30 + 8 + 10
}

test "ColCursor next and advance" {
    var col = layout.ColCursor.init(10, 20, 8);
    const r1 = col.next(40, 30);
    try std.testing.expectEqual(@as(i32, 10), r1.x);
    try std.testing.expectEqual(@as(i32, 20), r1.y);

    const r2 = col.next(30, 20);
    try std.testing.expectEqual(@as(i32, 58), r2.y); // 20 + 30 + 8

    col.advance(10);
    const r3 = col.next(20, 20);
    try std.testing.expectEqual(@as(i32, 96), r3.y); // 58 + 20 + 8 + 10
}
