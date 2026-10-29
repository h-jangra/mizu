const std = @import("std");
const renderer = @import("renderer.zig");

pub const Rect = renderer.Rect;

/// Geometry helpers for absolute positioning. No automatic layout engine.
pub const Geometry = struct {
    /// Center a child rect inside a parent rect.
    pub fn centerIn(parent: Rect, child_w: u32, child_h: u32) Rect {
        const cx = parent.x + @divTrunc(@as(i32, @intCast(parent.w)) - @as(i32, @intCast(child_w)), 2);
        const cy = parent.y + @divTrunc(@as(i32, @intCast(parent.h)) - @as(i32, @intCast(child_h)), 2);
        return Rect.init(cx, cy, child_w, child_h);
    }

    /// Align a child horizontally inside a parent: .left, .center, .right.
    pub fn alignX(parent: Rect, child_w: u32, alignment: Align) i32 {
        switch (alignment) {
            .left => return parent.x,
            .center => return parent.x + @divTrunc(@as(i32, @intCast(parent.w)) - @as(i32, @intCast(child_w)), 2),
            .right => return parent.x + @as(i32, @intCast(parent.w)) - @as(i32, @intCast(child_w)),
            .top, .bottom => return parent.x,
        }
    }

    /// Align a child vertically inside a parent: .top, .center, .bottom.
    pub fn alignY(parent: Rect, child_h: u32, alignment: Align) i32 {
        switch (alignment) {
            .top => return parent.y,
            .center => return parent.y + @divTrunc(@as(i32, @intCast(parent.h)) - @as(i32, @intCast(child_h)), 2),
            .bottom => return parent.y + @as(i32, @intCast(parent.h)) - @as(i32, @intCast(child_h)),
            .left, .right => return parent.y,
        }
    }

    /// Inset rect by padding on all sides.
    pub fn inset(r: Rect, pad: u32) Rect {
        if (pad * 2 >= r.w or pad * 2 >= r.h) return Rect.init(r.x, r.y, 0, 0);
        return Rect.init(
            r.x + @as(i32, @intCast(pad)),
            r.y + @as(i32, @intCast(pad)),
            r.w - pad * 2,
            r.h - pad * 2,
        );
    }

    /// Inset with different horizontal and vertical padding.
    pub fn insetHV(r: Rect, pad_x: u32, pad_y: u32) Rect {
        if (pad_x * 2 >= r.w or pad_y * 2 >= r.h) return Rect.init(r.x, r.y, 0, 0);
        return Rect.init(
            r.x + @as(i32, @intCast(pad_x)),
            r.y + @as(i32, @intCast(pad_y)),
            r.w - pad_x * 2,
            r.h - pad_y * 2,
        );
    }

    /// True if two rects overlap (non-zero area intersection).
    pub fn overlaps(a: Rect, b: Rect) bool {
        const inter = a.intersect(b);
        return inter.w > 0 and inter.h > 0;
    }

    /// Horizontal padding between items in a row.
    pub fn rowGap(count: usize, gap: u32) u32 {
        if (count == 0) return 0;
        return @as(u32, @intCast(count - 1)) * gap;
    }

    /// Vertical padding between items in a column.
    pub fn colGap(count: usize, gap: u32) u32 {
        if (count == 0) return 0;
        return @as(u32, @intCast(count - 1)) * gap;
    }
};

pub const Align = enum { left, center, right, top, bottom };

/// Row cursor for incremental horizontal positioning.
pub const RowCursor = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    gap: u32,

    pub fn init(x: i32, y: i32, gap: u32) RowCursor {
        return .{ .x = x, .y = y, .w = 0, .h = 0, .gap = gap };
    }

    /// Reserve a slot of `w` x `h` and return its rect, advancing x by w + gap.
    pub fn next(self: *RowCursor, w: u32, h: u32) Rect {
        const r = Rect.init(self.x, self.y, w, h);
        self.x += @as(i32, @intCast(w)) + @as(i32, @intCast(self.gap));
        self.w = @max(self.w, w);
        self.h = @max(self.h, h);
        return r;
    }

    /// Advance the cursor by an explicit amount without reserving.
    pub fn advance(self: *RowCursor, amount: i32) void {
        self.x += amount;
    }

    /// Reset to the start x with a new gap.
    pub fn reset(self: *RowCursor, x: i32, gap: u32) void {
        self.x = x;
        self.gap = gap;
    }
};

/// Manual column cursor for repetitive vertical layouts.
pub const ColCursor = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    gap: u32,

    pub fn init(x: i32, y: i32, gap: u32) ColCursor {
        return .{ .x = x, .y = y, .w = 0, .h = 0, .gap = gap };
    }

    /// Reserve a slot of `w` x `h` and return its rect, advancing y by h + gap.
    pub fn next(self: *ColCursor, w: u32, h: u32) Rect {
        const r = Rect.init(self.x, self.y, w, h);
        self.y += @as(i32, @intCast(h)) + @as(i32, @intCast(self.gap));
        self.w = @max(self.w, w);
        self.h = @max(self.h, h);
        return r;
    }

    /// Advance the cursor by an explicit amount without reserving.
    pub fn advance(self: *ColCursor, amount: i32) void {
        self.y += amount;
    }

    /// Reset to the start y with a new gap.
    pub fn reset(self: *ColCursor, y: i32, gap: u32) void {
        self.y = y;
        self.gap = gap;
    }
};

/// Hit-test a pointer coordinate against a rect.
pub fn hitTest(r: Rect, px: i32, py: i32) bool {
    return r.contains(px, py);
}

test "Hit test and overlap" {
    const r1 = Rect.init(0, 0, 50, 50);
    try std.testing.expect(!hitTest(r1, 75, 75));
    try std.testing.expect(hitTest(r1, 25, 25));
}

test "Geometry centerIn" {
    const parent = Rect.init(0, 0, 200, 100);
    const child = Geometry.centerIn(parent, 50, 30);
    try std.testing.expectEqual(@as(i32, 75), child.x);
    try std.testing.expectEqual(@as(i32, 35), child.y);
    try std.testing.expectEqual(@as(u32, 50), child.w);
    try std.testing.expectEqual(@as(u32, 30), child.h);
}

test "Geometry alignX" {
    const parent = Rect.init(0, 0, 200, 100);
    try std.testing.expectEqual(@as(i32, 0), Geometry.alignX(parent, 50, Align.left));
    try std.testing.expectEqual(@as(i32, 75), Geometry.alignX(parent, 50, Align.center));
    try std.testing.expectEqual(@as(i32, 150), Geometry.alignX(parent, 50, Align.right));
}

test "Geometry alignY" {
    const parent = Rect.init(0, 0, 200, 100);
    try std.testing.expectEqual(@as(i32, 0), Geometry.alignY(parent, 50, Align.top));
    try std.testing.expectEqual(@as(i32, 25), Geometry.alignY(parent, 50, Align.center));
    try std.testing.expectEqual(@as(i32, 50), Geometry.alignY(parent, 50, Align.bottom));
}

test "Geometry inset" {
    const r = Rect.init(10, 10, 100, 100);
    const inner = Geometry.inset(r, 4);
    try std.testing.expectEqual(@as(i32, 14), inner.x);
    try std.testing.expectEqual(@as(i32, 14), inner.y);
    try std.testing.expectEqual(@as(u32, 92), inner.w);
    try std.testing.expectEqual(@as(u32, 92), inner.h);
}

test "RowCursor next and advance" {
    var row = RowCursor.init(10, 20, 8);
    const r1 = row.next(40, 30);
    try std.testing.expectEqual(@as(i32, 10), r1.x);
    try std.testing.expectEqual(@as(i32, 20), r1.y);
    try std.testing.expectEqual(@as(u32, 40), r1.w);
    try std.testing.expectEqual(@as(u32, 30), r1.h);

    const r2 = row.next(30, 20);
    try std.testing.expectEqual(@as(i32, 58), r2.x);

    row.advance(10);
    const r3 = row.next(20, 20);
    try std.testing.expectEqual(@as(i32, 106), r3.x);
}

test "ColCursor next and advance" {
    var col = ColCursor.init(10, 20, 8);
    const r1 = col.next(40, 30);
    try std.testing.expectEqual(@as(i32, 10), r1.x);
    try std.testing.expectEqual(@as(i32, 20), r1.y);

    const r2 = col.next(30, 20);
    try std.testing.expectEqual(@as(i32, 58), r2.y);

    col.advance(10);
    const r3 = col.next(20, 20);
    try std.testing.expectEqual(@as(i32, 96), r3.y);
}

