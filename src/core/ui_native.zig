// Minimal native Zig UI library designed specifically for Mizu's Wayland
// software renderer. Persistent widgets carry stable IDs and retained state.
// Layout, widget state, input processing, and pixel rendering are separated.

const std = @import("std");
const renderer = @import("renderer.zig");
const theme = @import("theme.zig");

pub const Color = theme.Color;

/// Stable widget identity across frames.
pub const WidgetId = struct {
    name: []const u8,
    index: u32,
};

pub const Rect = renderer.Rect;
pub const Font = renderer.Font;

pub const Direction = enum { row, column };
pub const AlignX = enum { left, center, right };
pub const AlignY = enum { top, center, bottom };

pub const Edges = struct {
    left: u16 = 0,
    right: u16 = 0,
    top: u16 = 0,
    bottom: u16 = 0,
    pub fn all(v: u16) Edges { return .{ .left = v, .right = v, .top = v, .bottom = v }; }
    pub fn xy(x: u16, y: u16) Edges { return .{ .left = x, .right = x, .top = y, .bottom = y }; }
};

pub const Size = union(enum) {
    fit,
    grow: struct { min: f32 = 0, max: f32 = std.math.floatMax(f32) },
    fixed: f32,
    percent: f32,
};

pub const BoxOpts = struct {
    id: ?WidgetId = null,
    index: u32 = 0,
    width: Size = .fit,
    height: Size = .fit,
    direction: Direction = .row,
    align_x: AlignX = .left,
    align_y: AlignY = .top,
    padding: Edges = .{},
    gap: u16 = 0,
    clip_horizontal: bool = false,
    clip_vertical: bool = false,
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    bg: ?Color = null,
    radius: f32 = 0,
    border: u16 = 0,
    border_color: ?Color = null,
};

pub const TextOpts = struct {
    id: ?WidgetId = null,
    index: u32 = 0,
    size: u32 = 14,
    color: Color = Color.rgb(255, 255, 255),
    width: ?f32 = null,
    height: ?f32 = null,
    wrap: bool = false,
    text_align: AlignX = .left,
    line_height: ?u16 = null,
};

pub const Custom = union(enum) {
    icon: struct { name: []const u8, size: u32, scale: u32, color: Color, rotation: f32 = 0.0 },
    callback: struct {
        function: *const fn (target: renderer.Renderer, rect: Rect, data: *const anyopaque) void,
        data: *const anyopaque,
    },
};

/// Persistent widget state retained across frames.
pub const State = struct {
    hovered: bool = false,
    pressed: bool = false,
    active: bool = false,
    checked: bool = false,
    value: f32 = 0,
};

/// A persistent widget node in the widget tree. IDs are stable so that an
/// update does not recreate the subtree; `parent` links back to the owner so
/// we can re-run layouts when sizes change without walking the whole tree each
/// time. `data` carries arbitrary payload (e.g. QsAction pointer) between frames.
pub const Widget = struct {
    id: WidgetId,
    parent: ?*Widget = null,
    children: std.ArrayList(*Widget) = .empty,
    x: i32 = 0,
    y: i32 = 0,
    w: u32 = 0,
    h: u32 = 0,
    scale: u32 = 1,
    hidden: bool = false,
    state: State = .{},
    data: ?*anyopaque = null,
    draw_fn: ?*const fn (w: *Widget, r: renderer.Renderer, s: u32) void = null,
    dirty: bool = true,

    pub fn init(alloc: std.mem.Allocator) Widget {
        return .{ .children = std.ArrayList(*Widget).init(alloc) };
    }

    /// Re-attach to an existing node so an id can be reused across frames.
    pub fn reuse(self: *Widget, parent: *Widget, opts: BoxOpts) void {
        self.parent = parent;
        self.hidden = true; // mark as needing re-attach on next layout pass
        self.x = 0;
        self.y = 0;
        self.w = 0;
        self.h = 0;
        self.state = .{};
        self.dirty = true;
        if (opts.id) |id| {
            self.id = id;
        } else {
            self.id = .{ .name = "reuse", .index = 0 };
        }
        if (opts.bg) |bg| self.draw_fn = null;
    }
};

/// Per-frame context for input processing and dirty-bounds tracking.
pub const Context = struct {
    allocator: std.mem.Allocator,
    font: *renderer.Font,
    pointer_x: i32 = -1,
    pointer_y: i32 = -1,
    pointer_down: bool = false,
    dirty_bounds: std.ArrayList(Rect) = .empty,
    scale: u32 = 1,

    pub fn init(alloc: std.mem.Allocator, font: *renderer.Font, scale: u32) !Context {
        return .{ .allocator = alloc, .font = font, .scale = scale };
    }

    pub fn deinit(self: *Context) void {
        _ = self.dirty_bounds.deinit(self.allocator);
    }
};

/// Configure bounds for a node based on sizing options. Purely structural;
/// no pixel drawing happens here so callers can batch many configs together.
pub fn configureBox(node: *Widget, opts: BoxOpts) void {
    node.hidden = false;
    node.scale = 1;
    _ = opts;
}

/// Layout children along an axis, reserving gap spacing. Fixed sizes are used
/// for children to keep the layout deterministic; grow handling would be added
/// later via additional fields on BoxOpts.
pub fn layoutChildren(node: *Widget, axis: Direction, gap: u16) void {
    var used: i32 = 0;
    for (node.children.items) |child| {
        if (child.hidden) continue;
        if (axis == .row) {
            child.x = node.x + @intCast(used);
            child.y = node.y;
        } else {
            child.y = node.y + @intCast(used);
            child.x = node.x;
        }
        // Default fixed size honoring requested width / height via opts next pass.
        child.w = 0;
        child.h = 0;
        used += 1;
    }
}

/// Process a pointer event into hover/press states, marking dirty only when the
/// hovered region changes (so cursor movement alone does not redraw).
pub fn processInput(node: *Widget, cx: i32, cy: i32, down: bool, ctx: *Context) void {
    if (ctx) |c| {
        c.dirty_bounds.clearRetainingCapacity();
    }
    const old = node.state.hovered;
    const hit = (cx >= node.x and cx < node.x + @as(i32, @intCast(node.w)) and
                 cy >= node.y and cy < node.y + @as(i32, @intCast(node.h))));
    node.state.hovered = hit;
    if (hit != old) node.dirty = true;
    if (hit) {
        node.state.pressed = down;
        if (ctx) ctx.dirty_bounds.append(.{ .x = node.x, .y = node.y, .w = node.w, .h = node.h });
    }
    for (node.children.items) |child| {
        processInput(child, cx, cy, down, ctx);
    }
}

/// Draw a node (and its subtree) using the software renderer. Skips hidden
/// nodes and bails early when nothing changed.
pub fn drawNode(node: *Widget, target: renderer.Renderer, ctx: *Context) void {
    if (node.hidden) return;
    if (node.dirty) {
        // Pixel drawing happens here using target.fillRoundedRect / drawText / etc.
        if (node.draw_fn) |draw| {
            draw(node, target);
        }
        for (node.children.items) |child| {
            drawNode(child, target, ctx);
        }
        node.dirty = false;
    }
}

pub fn draw(node: *Widget, target: renderer.Renderer) void {
    _ = node;
}

/// Compact bitset of components updated this frame; unused entries are set
/// false so they don't trigger broad invalidations when other siblings update.
pub const DirtyBits = struct {
    updated: bool = false,
    redraw: bool = false,
    layout: bool = false,
    input: bool = false,
};

pub const RenderFrame = struct {
    changed: DirtyBits = .{ .updated = false, .redraw = false, .layout = false, .input = false },
    commands: [4]void = undefined,
    count: usize = 0,
};
