const std = @import("std");
const c = @import("../c.zig").c;
const buffer = @import("../core/buffer.zig");
const renderer = @import("../core/renderer.zig");
const theme = @import("../core/theme.zig");
const config = @import("../core/config.zig");
const wayland_win = @import("../core/wayland_window.zig");
const image_ops = @import("../graphics/image_ops.zig");

const Color = theme.Color;
const Rect = renderer.Rect;
const Font = renderer.Font;
const ImageBuffer = image_ops.ImageBuffer;
const WindowApp = wayland_win.WindowApp;

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const Tool = enum {
    select,
    freehand,
    arrow,
    line,
    rect,
    circle,
    text,
    step_badge,
    highlight,
    blur,
    pixelate,
    crop,

    pub fn name(self: Tool) []const u8 {
        return switch (self) {
            .select => "Select / Move",
            .freehand => "Pen",
            .arrow => "Arrow",
            .line => "Line",
            .rect => "Rectangle",
            .circle => "Circle",
            .text => "Text",
            .step_badge => "Step Badge",
            .highlight => "Highlight",
            .blur => "Blur",
            .pixelate => "Pixelate",
            .crop => "Crop",
        };
    }

    pub fn shortcut(self: Tool) []const u8 {
        return switch (self) {
            .select => "V",
            .freehand => "P",
            .arrow => "A",
            .line => "L",
            .rect => "R",
            .circle => "C",
            .text => "T",
            .step_badge => "N",
            .highlight => "H",
            .blur => "B",
            .pixelate => "X",
            .crop => "K",
        };
    }

    pub fn icon(self: Tool) []const u8 {
        return switch (self) {
            .select => "󰆽",
            .freehand => "",
            .arrow => "",
            .line => "󰕞",
            .rect => "󰹟",
            .circle => "",
            .text => "󰊄",
            .step_badge => "󰲠",
            .highlight => "",
            .blur => "󰂶",
            .pixelate => "",
            .crop => "",
        };
    }
};

pub const AnnotationKind = enum {
    pen,
    arrow,
    line,
    rect,
    circle,
    text,
    step_badge,
    highlight,
    blur,
    pixelate,

    pub fn name(self: AnnotationKind) []const u8 {
        return switch (self) {
            .pen => "Pen Stroke",
            .arrow => "Arrow",
            .line => "Line",
            .rect => "Rectangle",
            .circle => "Circle",
            .text => "Text",
            .step_badge => "Step Badge",
            .highlight => "Highlight",
            .blur => "Blur Region",
            .pixelate => "Pixelate Region",
        };
    }

    pub fn icon(self: AnnotationKind) []const u8 {
        return switch (self) {
            .pen => "",
            .arrow => "",
            .line => "󰕞",
            .rect => "󰹟",
            .circle => "",
            .text => "󰊄",
            .step_badge => "󰲠",
            .highlight => "",
            .blur => "󰂶",
            .pixelate => "",
        };
    }
};

pub const ResizeHandle = enum {
    none,
    start_point,
    end_point,
    top_left,
    top_mid,
    top_right,
    mid_right,
    bottom_right,
    bottom_mid,
    bottom_left,
    mid_left,
};

pub const Palette = struct {
    pub const colors = [_]Color{
        Color.hex(0xE06C75), // Red / Coral
        Color.hex(0xD19A66), // Orange
        Color.hex(0xE5C07B), // Yellow
        Color.hex(0x98C379), // Green
        Color.hex(0x56B6C2), // Cyan
        Color.hex(0x61AFEF), // Blue
        Color.hex(0xC678DD), // Purple / Magenta
        Color.hex(0xFFFFFF), // White
        Color.hex(0xABB2BF), // Light Gray
        Color.hex(0x181825), // Dark
    };
};

pub const Adjustments = struct {
    brightness: f32 = 0.0,
    contrast: f32 = 1.0,
    saturation: f32 = 1.0,
    blur: u32 = 0,
    grayscale: bool = false,

    pub fn isDefault(self: Adjustments) bool {
        return self.brightness == 0.0 and
            self.contrast == 1.0 and
            self.saturation == 1.0 and
            self.blur == 0 and
            !self.grayscale;
    }

    pub fn reset(self: *Adjustments) void {
        self.* = Adjustments{};
    }
};

/// Distance squared from point (px, py) to segment (x0, y0)-(x1, y1)
fn distSqPointToSegment(px: f32, py: f32, x0: f32, y0: f32, x1: f32, y1: f32) f32 {
    const l2 = (x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0);
    if (l2 < 0.001) {
        return (px - x0) * (px - x0) + (py - y0) * (py - y0);
    }
    const t = std.math.clamp(((px - x0) * (x1 - x0) + (py - y0) * (y1 - y0)) / l2, 0.0, 1.0);
    const proj_x = x0 + t * (x1 - x0);
    const proj_y = y0 + t * (y1 - y0);
    return (px - proj_x) * (px - proj_x) + (py - proj_y) * (py - proj_y);
}

/// A movable, resizable, selectable vector annotation object
pub const Annotation = struct {
    id: u32,
    kind: AnnotationKind,

    // Bounding coordinates in base image pixel space
    rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    // For arrows and lines: start and end points
    start_x: i32 = 0,
    start_y: i32 = 0,
    end_x: i32 = 0,
    end_y: i32 = 0,

    // For freehand pen
    points: std.ArrayListUnmanaged(Point) = .empty,

    // For text
    text_buf: [128]u8 = [_]u8{0} ** 128,
    text_len: usize = 0,
    font_size: u32 = 18,

    // For step badge
    step_number: u32 = 1,

    // Styling
    color: Color = Color.hex(0xE06C75),
    stroke_width: u32 = 4,
    filled: bool = false,
    visible: bool = true,
    locked: bool = false,

    pub fn clone(self: *const Annotation, allocator: std.mem.Allocator) !Annotation {
        var copy = self.*;
        if (self.points.items.len > 0) {
            copy.points = try self.points.clone(allocator);
        } else {
            copy.points = .empty;
        }
        return copy;
    }

    pub fn deinit(self: *Annotation, allocator: std.mem.Allocator) void {
        self.points.deinit(allocator);
    }

    pub fn getBounds(self: *const Annotation) Rect {
        switch (self.kind) {
            .arrow, .line => {
                const min_x = @min(self.start_x, self.end_x) - @as(i32, @intCast(self.stroke_width + 6));
                const min_y = @min(self.start_y, self.end_y) - @as(i32, @intCast(self.stroke_width + 6));
                const max_x = @max(self.start_x, self.end_x) + @as(i32, @intCast(self.stroke_width + 6));
                const max_y = @max(self.start_y, self.end_y) + @as(i32, @intCast(self.stroke_width + 6));
                return Rect{
                    .x = min_x,
                    .y = min_y,
                    .w = @intCast(@max(10, max_x - min_x)),
                    .h = @intCast(@max(10, max_y - min_y)),
                };
            },
            .pen => {
                if (self.points.items.len == 0) return self.rect;
                var min_x = self.points.items[0].x;
                var min_y = self.points.items[0].y;
                var max_x = min_x;
                var max_y = min_y;
                for (self.points.items) |pt| {
                    min_x = @min(min_x, pt.x);
                    min_y = @min(min_y, pt.y);
                    max_x = @max(max_x, pt.x);
                    max_y = @max(max_y, pt.y);
                }
                const pad: i32 = @intCast(self.stroke_width + 4);
                return Rect{
                    .x = min_x - pad,
                    .y = min_y - pad,
                    .w = @intCast(@max(12, max_x - min_x + pad * 2)),
                    .h = @intCast(@max(12, max_y - min_y + pad * 2)),
                };
            },
            .step_badge => {
                const r: i32 = 16;
                return Rect{
                    .x = self.rect.x - r - 2,
                    .y = self.rect.y - r - 2,
                    .w = @intCast((r + 2) * 2),
                    .h = @intCast((r + 2) * 2),
                };
            },
            .text => {
                return self.rect;
            },
            else => {
                const rx = @min(self.rect.x, self.rect.x + @as(i32, @intCast(self.rect.w)));
                const ry = @min(self.rect.y, self.rect.y + @as(i32, @intCast(self.rect.h)));
                return Rect{
                    .x = rx,
                    .y = ry,
                    .w = self.rect.w,
                    .h = self.rect.h,
                };
            },
        }
    }

    pub fn move(self: *Annotation, dx: i32, dy: i32) void {
        switch (self.kind) {
            .arrow, .line => {
                self.start_x += dx;
                self.start_y += dy;
                self.end_x += dx;
                self.end_y += dy;
            },
            .pen => {
                for (self.points.items) |*pt| {
                    pt.x += dx;
                    pt.y += dy;
                }
                self.rect.x += dx;
                self.rect.y += dy;
            },
            else => {
                self.rect.x += dx;
                self.rect.y += dy;
            },
        }
    }

    pub fn hitTest(self: *const Annotation, px: i32, py: i32) bool {
        if (!self.visible or self.locked) return false;
        const p_xf: f32 = @floatFromInt(px);
        const p_yf: f32 = @floatFromInt(py);

        switch (self.kind) {
            .arrow, .line => {
                const x0: f32 = @floatFromInt(self.start_x);
                const y0: f32 = @floatFromInt(self.start_y);
                const x1: f32 = @floatFromInt(self.end_x);
                const y1: f32 = @floatFromInt(self.end_y);
                const thresh = @max(8.0, @as(f32, @floatFromInt(self.stroke_width)) + 4.0);
                return distSqPointToSegment(p_xf, p_yf, x0, y0, x1, y1) <= thresh * thresh;
            },
            .pen => {
                if (self.points.items.len < 2) return false;
                const thresh = @max(6.0, @as(f32, @floatFromInt(self.stroke_width)) + 3.0);
                const thresh_sq = thresh * thresh;
                var i: usize = 0;
                while (i + 1 < self.points.items.len) : (i += 1) {
                    const x0: f32 = @floatFromInt(self.points.items[i].x);
                    const y0: f32 = @floatFromInt(self.points.items[i].y);
                    const x1: f32 = @floatFromInt(self.points.items[i + 1].x);
                    const y1: f32 = @floatFromInt(self.points.items[i + 1].y);
                    if (distSqPointToSegment(p_xf, p_yf, x0, y0, x1, y1) <= thresh_sq) {
                        return true;
                    }
                }
                return false;
            },
            .step_badge => {
                const cx: f32 = @floatFromInt(self.rect.x);
                const cy: f32 = @floatFromInt(self.rect.y);
                const r: f32 = 18.0;
                const d2 = (p_xf - cx) * (p_xf - cx) + (p_yf - cy) * (p_yf - cy);
                return d2 <= r * r;
            },
            .rect, .highlight, .blur, .pixelate => {
                const b = self.getBounds();
                const inside = (px >= b.x and px <= b.x + @as(i32, @intCast(b.w)) and
                    py >= b.y and py <= b.y + @as(i32, @intCast(b.h)));
                if (self.kind != .rect or self.filled) return inside;

                // Outlined rect: check near border edges
                if (!inside) return false;
                const sw: i32 = @intCast(@max(4, self.stroke_width + 4));
                const in_core = (px >= b.x + sw and px <= b.x + @as(i32, @intCast(b.w)) - sw and
                    py >= b.y + sw and py <= b.y + @as(i32, @intCast(b.h)) - sw);
                return !in_core;
            },
            .circle => {
                const b = self.getBounds();
                const cx: f32 = @as(f32, @floatFromInt(b.x)) + @as(f32, @floatFromInt(b.w)) / 2.0;
                const cy: f32 = @as(f32, @floatFromInt(b.y)) + @as(f32, @floatFromInt(b.h)) / 2.0;
                const rx: f32 = @as(f32, @floatFromInt(b.w)) / 2.0;
                const ry: f32 = @as(f32, @floatFromInt(b.h)) / 2.0;
                if (rx < 1.0 or ry < 1.0) return false;

                const norm_x = (p_xf - cx) / rx;
                const norm_y = (p_yf - cy) / ry;
                const dist_sq = norm_x * norm_x + norm_y * norm_y;

                if (self.filled) return dist_sq <= 1.05;
                // Outlined: near boundary
                const dist = @sqrt(dist_sq);
                return @abs(dist - 1.0) <= 0.25;
            },
            .text => {
                const b = self.getBounds();
                return (px >= b.x and px <= b.x + @as(i32, @intCast(b.w)) and
                    py >= b.y and py <= b.y + @as(i32, @intCast(b.h)));
            },
        }
    }

    pub fn resize(self: *Annotation, handle: ResizeHandle, img_x: i32, img_y: i32) void {
        switch (self.kind) {
            .arrow, .line => {
                if (handle == .start_point) {
                    self.start_x = img_x;
                    self.start_y = img_y;
                } else if (handle == .end_point) {
                    self.end_x = img_x;
                    self.end_y = img_y;
                }
            },
            else => {
                const b = self.getBounds();
                var x0 = b.x;
                var y0 = b.y;
                var x1 = b.x + @as(i32, @intCast(b.w));
                var y1 = b.y + @as(i32, @intCast(b.h));

                switch (handle) {
                    .top_left => {
                        x0 = @min(img_x, x1 - 8);
                        y0 = @min(img_y, y1 - 8);
                    },
                    .top_mid => {
                        y0 = @min(img_y, y1 - 8);
                    },
                    .top_right => {
                        x1 = @max(img_x, x0 + 8);
                        y0 = @min(img_y, y1 - 8);
                    },
                    .mid_right => {
                        x1 = @max(img_x, x0 + 8);
                    },
                    .bottom_right => {
                        x1 = @max(img_x, x0 + 8);
                        y1 = @max(img_y, y0 + 8);
                    },
                    .bottom_mid => {
                        y1 = @max(img_y, y0 + 8);
                    },
                    .bottom_left => {
                        x0 = @min(img_x, x1 - 8);
                        y1 = @max(img_y, y0 + 8);
                    },
                    .mid_left => {
                        x0 = @min(img_x, x1 - 8);
                    },
                    else => {},
                }

                self.rect = Rect{
                    .x = x0,
                    .y = y0,
                    .w = @intCast(@max(8, x1 - x0)),
                    .h = @intCast(@max(8, y1 - y0)),
                };
            },
        }
    }

    /// Composite this vector annotation directly onto the target pixel buffer
    pub fn renderToImage(self: *const Annotation, img: *ImageBuffer, font: *Font) void {
        if (!self.visible) return;

        switch (self.kind) {
            .arrow => {
                img.drawArrow(self.start_x, self.start_y, self.end_x, self.end_y, self.stroke_width, self.color);
            },
            .line => {
                img.drawStrokeLine(self.start_x, self.start_y, self.end_x, self.end_y, self.stroke_width, self.color);
            },
            .rect => {
                img.drawRect(self.getBounds(), self.stroke_width, self.color, self.filled);
            },
            .circle => {
                const b = self.getBounds();
                const cx = b.x + @divTrunc(@as(i32, @intCast(b.w)), 2);
                const cy = b.y + @divTrunc(@as(i32, @intCast(b.h)), 2);
                const rad = @divTrunc(@min(b.w, b.h), 2);
                img.drawCircle(cx, cy, @intCast(rad), self.stroke_width, self.color, self.filled);
            },
            .highlight => {
                const tint = Color.init(100, self.color.r, self.color.g, self.color.b);
                img.applyHighlightRegion(self.getBounds(), tint);
            },
            .blur => {
                img.applyBlurRegion(self.getBounds(), @max(4, self.stroke_width * 2));
            },
            .pixelate => {
                img.applyPixelateRegion(self.getBounds(), @max(6, self.stroke_width * 3));
            },
            .step_badge => {
                const cx = self.rect.x;
                const cy = self.rect.y;
                const r: i32 = 16;
                // Outer filled circle
                img.fillCircle(cx, cy, r, self.color);
                // White step number text
                var num_buf: [16]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{self.step_number}) catch "1";
                img.drawText(font, num_str, cx - 4, cy + 5, 13, Color.rgb(255, 255, 255));
            },
            .text => {
                const slice = self.text_buf[0..self.text_len];
                img.drawText(font, slice, self.rect.x, self.rect.y + @as(i32, @intCast(self.font_size)), self.font_size, self.color);
            },
            .pen => {
                if (self.points.items.len < 2) return;
                var i: usize = 0;
                while (i + 1 < self.points.items.len) : (i += 1) {
                    img.drawStrokeLine(
                        self.points.items[i].x,
                        self.points.items[i].y,
                        self.points.items[i + 1].x,
                        self.points.items[i + 1].y,
                        self.stroke_width,
                        self.color,
                    );
                }
            },
        }
    }
};

/// Reference-counted shared image buffer to eliminate memory duplication in undo/redo
pub const SharedImage = struct {
    img: ImageBuffer,
    ref_count: usize,
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator, img: ImageBuffer) !*SharedImage {
        const ptr = try allocator.create(SharedImage);
        ptr.* = .{
            .img = img,
            .ref_count = 1,
            .allocator = allocator,
        };
        return ptr;
    }

    pub fn retain(self: *SharedImage) *SharedImage {
        self.ref_count += 1;
        return self;
    }

    pub fn release(self: *SharedImage) void {
        if (self.ref_count <= 1) {
            self.img.deinit();
            self.allocator.destroy(self);
        } else {
            self.ref_count -= 1;
        }
    }
};

/// Undo snapshot capturing the state of all vector annotations and base canvas
pub const CanvasSnapshot = struct {
    annotations: std.ArrayListUnmanaged(Annotation),
    base_image: *SharedImage,

    pub fn clone(self: *const CanvasSnapshot, allocator: std.mem.Allocator) !CanvasSnapshot {
        var ann_copy = std.ArrayListUnmanaged(Annotation).empty;
        try ann_copy.ensureTotalCapacity(allocator, self.annotations.items.len);
        for (self.annotations.items) |*ann| {
            ann_copy.appendAssumeCapacity(try ann.clone(allocator));
        }
        return .{
            .annotations = ann_copy,
            .base_image = self.base_image.retain(),
        };
    }

    pub fn deinit(self: *CanvasSnapshot, allocator: std.mem.Allocator) void {
        for (self.annotations.items) |*ann| {
            ann.deinit(allocator);
        }
        self.annotations.deinit(allocator);
        self.base_image.release();
    }
};

pub const UndoManager = struct {
    allocator: std.mem.Allocator,
    undo_stack: std.ArrayListUnmanaged(CanvasSnapshot) = .empty,
    redo_stack: std.ArrayListUnmanaged(CanvasSnapshot) = .empty,
    max_history: usize = 30,

    pub fn init(allocator: std.mem.Allocator, max_history: usize) UndoManager {
        return .{
            .allocator = allocator,
            .max_history = max_history,
        };
    }

    pub fn deinit(self: *UndoManager) void {
        for (self.undo_stack.items) |*snap| snap.deinit(self.allocator);
        self.undo_stack.deinit(self.allocator);
        for (self.redo_stack.items) |*snap| snap.deinit(self.allocator);
        self.redo_stack.deinit(self.allocator);
    }

    pub fn pushState(self: *UndoManager, current_annotations: []const Annotation, current_base: *SharedImage) !void {
        // Clear redo stack on new action
        for (self.redo_stack.items) |*snap| snap.deinit(self.allocator);
        self.redo_stack.clearRetainingCapacity();

        var ann_copy = std.ArrayListUnmanaged(Annotation).empty;
        try ann_copy.ensureTotalCapacity(self.allocator, current_annotations.len);
        for (current_annotations) |*ann| {
            ann_copy.appendAssumeCapacity(try ann.clone(self.allocator));
        }

        const snap = CanvasSnapshot{
            .annotations = ann_copy,
            .base_image = current_base.retain(),
        };

        if (self.undo_stack.items.len >= self.max_history) {
            var old = self.undo_stack.orderedRemove(0);
            old.deinit(self.allocator);
        }
        try self.undo_stack.append(self.allocator, snap);
    }

    pub fn canUndo(self: *const UndoManager) bool {
        return self.undo_stack.items.len > 0;
    }

    pub fn canRedo(self: *const UndoManager) bool {
        return self.redo_stack.items.len > 0;
    }
};

/// The main Tensaku-inspired vector Annotator & Image Editor Application
pub const AnnotateApp = struct {
    allocator: std.mem.Allocator,
    win: *WindowApp,
    font: *Font,
    cfg: config.Config,

    base_image: *SharedImage,
    annotations: std.ArrayListUnmanaged(Annotation) = .empty,
    selected_ids: std.ArrayListUnmanaged(u32) = .empty,
    undo_mgr: UndoManager,

    next_annotation_id: u32 = 1,
    step_badge_counter: u32 = 1,

    // Active tool & properties
    active_tool: Tool = .select,
    current_color: Color = Color.hex(0xE06C75),
    stroke_width: u32 = 4,
    current_font_size: u32 = 18,
    fill_shape: bool = false,

    // Navigation (Zoom & Pan)
    zoom: f32 = 1.0,
    pan_x: f32 = 0.0,
    pan_y: f32 = 0.0,
    is_panning: bool = false,
    pan_start_x: i32 = 0,
    pan_start_y: i32 = 0,

    // Interaction states
    is_drawing: bool = false,
    is_moving: bool = false,
    is_resizing: bool = false,
    is_marquee: bool = false,
    active_handle: ResizeHandle = .none,

    drag_start_x: i32 = 0, // In image coordinates
    drag_start_y: i32 = 0,
    drag_curr_x: i32 = 0,
    drag_curr_y: i32 = 0,
    last_move_x: i32 = 0,
    last_move_y: i32 = 0,

    // Inline Text Editing
    editing_text_id: ?u32 = null,

    // Crop Tool state
    is_crop_mode: bool = false,
    is_cropping: bool = false,
    crop_x0: i32 = 0,
    crop_y0: i32 = 0,
    crop_x1: i32 = 0,
    crop_y1: i32 = 0,

    // Side Panels
    show_layers: bool = false,
    show_adjustments: bool = false,
    show_info: bool = false,

    // Adjustments
    adjustments: Adjustments = .{},
    adjust_base_image: ?ImageBuffer = null,
    active_slider: ?enum { brightness, contrast, saturation, blur } = null,

    // Metadata
    original_path: ?[]const u8 = null,
    file_size_bytes: usize = 0,

    // Toast Status
    status_msg: [128]u8 = [_]u8{0} ** 128,
    status_len: usize = 0,
    status_ticks: u32 = 0,

    // Dimensions
    toolbar_height: u32 = 48,
    statusbar_height: u32 = 28,
    layers_panel_width: u32 = 230,
    adjust_panel_width: u32 = 240,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config, image_to_load: ?ImageBuffer, file_path: ?[]const u8) !*AnnotateApp {
        var win = try WindowApp.init(allocator, .{
            .title = "Mizu Annotate & Editor",
            .app_id = "mizu-annotate",
            .width = 1240,
            .height = 760,
            .min_width = 720,
            .min_height = 460,
        });
        errdefer win.deinit();

        const font = try allocator.create(Font);
        font.* = try Font.init(allocator, cfg.theme.font_family, 13);
        errdefer {
            font.deinit();
            allocator.destroy(font);
        }

        var base = if (image_to_load) |loaded|
            loaded
        else
            try ImageBuffer.init(allocator, 800, 600, Color.rgb(255, 255, 255));
        errdefer base.deinit();

        const path_copy = if (file_path) |p| try allocator.dupe(u8, p) else null;

        var f_size: usize = 0;
        if (file_path) |p| {
            var st: c.struct_stat = undefined;
            const p_z = allocator.dupeZ(u8, p) catch null;
            if (p_z) |pz| {
                defer allocator.free(pz);
                if (c.stat(pz.ptr, &st) == 0) {
                    f_size = @intCast(st.st_size);
                }
            }
        }

        const shared_base = try SharedImage.create(allocator, base);
        errdefer shared_base.release();

        const app = try allocator.create(AnnotateApp);
        app.* = .{
            .allocator = allocator,
            .win = win,
            .font = font,
            .cfg = cfg,
            .base_image = shared_base,
            .original_path = path_copy,
            .file_size_bytes = f_size,
            .undo_mgr = UndoManager.init(allocator, 30),
        };

        app.fitToWindow();
        return app;
    }

    pub fn deinit(self: *AnnotateApp) void {
        const alloc = self.allocator;
        if (self.adjust_base_image) |*abi| abi.deinit();
        if (self.original_path) |p| alloc.free(p);
        for (self.annotations.items) |*ann| ann.deinit(alloc);
        self.annotations.deinit(alloc);
        self.selected_ids.deinit(alloc);
        self.undo_mgr.deinit();
        self.base_image.release();
        self.font.deinit();
        alloc.destroy(self.font);
        self.win.deinit();
        alloc.destroy(self);
    }

    pub fn setStatus(self: *AnnotateApp, msg: []const u8) void {
        const copy_len = @min(msg.len, self.status_msg.len - 1);
        @memcpy(self.status_msg[0..copy_len], msg[0..copy_len]);
        self.status_msg[copy_len] = 0;
        self.status_len = copy_len;
        self.status_ticks = 140;
        self.win.needs_redraw = true;
    }

    pub fn canvasRect(self: *const AnnotateApp) Rect {
        const w = self.win.width;
        const h = self.win.height;
        const right_margin: u32 = if (self.show_layers)
            self.layers_panel_width
        else if (self.show_adjustments)
            self.adjust_panel_width
        else
            0;

        const cw = if (w > right_margin + 20) w - right_margin else w;
        const ch = if (h > self.toolbar_height + self.statusbar_height)
            h - self.toolbar_height - self.statusbar_height
        else
            0;

        return Rect{
            .x = 0,
            .y = @intCast(self.toolbar_height),
            .w = cw,
            .h = ch,
        };
    }

    pub fn fitToWindow(self: *AnnotateApp) void {
        const c_rect = self.canvasRect();
        if (c_rect.w == 0 or c_rect.h == 0 or self.base_image.img.width == 0 or self.base_image.img.height == 0) return;

        const avail_w = @as(f32, @floatFromInt(c_rect.w - 48));
        const avail_h = @as(f32, @floatFromInt(c_rect.h - 48));
        const img_w = @as(f32, @floatFromInt(self.base_image.img.width));
        const img_h = @as(f32, @floatFromInt(self.base_image.img.height));

        const scale_w = avail_w / img_w;
        const scale_h = avail_h / img_h;
        self.zoom = std.math.clamp(@min(scale_w, scale_h), 0.1, 4.0);

        const displayed_w = img_w * self.zoom;
        const displayed_h = img_h * self.zoom;
        self.pan_x = @as(f32, @floatFromInt(c_rect.x)) + (@as(f32, @floatFromInt(c_rect.w)) - displayed_w) / 2.0;
        self.pan_y = @as(f32, @floatFromInt(c_rect.y)) + (@as(f32, @floatFromInt(c_rect.h)) - displayed_h) / 2.0;
        self.win.needs_redraw = true;
    }

    pub fn screenToImageX(self: *const AnnotateApp, sx: i32) i32 {
        return @intFromFloat((@as(f32, @floatFromInt(sx)) - self.pan_x) / self.zoom);
    }

    pub fn screenToImageY(self: *const AnnotateApp, sy: i32) i32 {
        return @intFromFloat((@as(f32, @floatFromInt(sy)) - self.pan_y) / self.zoom);
    }

    pub fn imageToScreenX(self: *const AnnotateApp, ix: i32) i32 {
        return @intFromFloat(self.pan_x + @as(f32, @floatFromInt(ix)) * self.zoom);
    }

    pub fn imageToScreenY(self: *const AnnotateApp, iy: i32) i32 {
        return @intFromFloat(self.pan_y + @as(f32, @floatFromInt(iy)) * self.zoom);
    }

    pub fn pushUndoState(self: *AnnotateApp) void {
        self.undo_mgr.pushState(self.annotations.items, self.base_image) catch {};
    }

    pub fn undo(self: *AnnotateApp) void {
        if (!self.undo_mgr.canUndo()) return;
        // Save current to redo stack before popping
        var curr_ann = std.ArrayListUnmanaged(Annotation).empty;
        curr_ann.ensureTotalCapacity(self.allocator, self.annotations.items.len) catch return;
        for (self.annotations.items) |*a| {
            curr_ann.appendAssumeCapacity(a.clone(self.allocator) catch return);
        }
        const curr_snap = CanvasSnapshot{
            .annotations = curr_ann,
            .base_image = self.base_image.retain(),
        };
        self.undo_mgr.redo_stack.append(self.allocator, curr_snap) catch return;

        const prev = self.undo_mgr.undo_stack.pop().?;

        // Free current
        for (self.annotations.items) |*a| a.deinit(self.allocator);
        self.annotations.deinit(self.allocator);
        self.base_image.release();

        self.annotations = prev.annotations;
        self.base_image = prev.base_image;
        self.selected_ids.clearRetainingCapacity();
        self.setStatus("Undo");
        self.win.needs_redraw = true;
    }

    pub fn redo(self: *AnnotateApp) void {
        if (!self.undo_mgr.canRedo()) return;
        // Save current to undo
        var curr_ann = std.ArrayListUnmanaged(Annotation).empty;
        curr_ann.ensureTotalCapacity(self.allocator, self.annotations.items.len) catch return;
        for (self.annotations.items) |*a| {
            curr_ann.appendAssumeCapacity(a.clone(self.allocator) catch return);
        }
        const curr_snap = CanvasSnapshot{
            .annotations = curr_ann,
            .base_image = self.base_image.retain(),
        };
        self.undo_mgr.undo_stack.append(self.allocator, curr_snap) catch return;

        const next_st = self.undo_mgr.redo_stack.pop().?;

        for (self.annotations.items) |*a| a.deinit(self.allocator);
        self.annotations.deinit(self.allocator);
        self.base_image.release();

        self.annotations = next_st.annotations;
        self.base_image = next_st.base_image;
        self.selected_ids.clearRetainingCapacity();
        self.setStatus("Redo");
        self.win.needs_redraw = true;
    }

    // ==========================================
    // Selection & Manipulation
    // ==========================================

    pub fn isSelected(self: *const AnnotateApp, id: u32) bool {
        for (self.selected_ids.items) |sid| {
            if (sid == id) return true;
        }
        return false;
    }

    pub fn selectOnly(self: *AnnotateApp, id: u32) void {
        self.selected_ids.clearRetainingCapacity();
        self.selected_ids.append(self.allocator, id) catch {};
        self.win.needs_redraw = true;
    }

    pub fn toggleSelect(self: *AnnotateApp, id: u32) void {
        for (self.selected_ids.items, 0..) |sid, idx| {
            if (sid == id) {
                _ = self.selected_ids.orderedRemove(idx);
                self.win.needs_redraw = true;
                return;
            }
        }
        self.selected_ids.append(self.allocator, id) catch {};
        self.win.needs_redraw = true;
    }

    pub fn deselectAll(self: *AnnotateApp) void {
        if (self.selected_ids.items.len > 0) {
            self.selected_ids.clearRetainingCapacity();
            self.win.needs_redraw = true;
        }
    }

    pub fn selectAll(self: *AnnotateApp) void {
        self.selected_ids.clearRetainingCapacity();
        for (self.annotations.items) |ann| {
            if (ann.visible and !ann.locked) {
                self.selected_ids.append(self.allocator, ann.id) catch {};
            }
        }
        self.win.needs_redraw = true;
    }

    pub fn setActiveTool(self: *AnnotateApp, tool: Tool) void {
        self.active_tool = tool;
        switch (tool) {
            .select => self.win.setCursorShape(.default),
            .text => self.win.setCursorShape(.text),
            .crop => {
                self.win.setCursorShape(.crosshair);
                self.startCrop();
            },
            else => self.win.setCursorShape(.crosshair),
        }
        self.win.needs_redraw = true;
    }

    pub fn decreaseFontSize(self: *AnnotateApp) void {
        if (self.current_font_size > 10) {
            self.current_font_size -= 2;
            for (self.selected_ids.items) |sid| {
                if (self.findAnnotationById(sid)) |a| {
                    if (a.kind == .text) {
                        a.font_size = self.current_font_size;
                    }
                }
            }
            var buf: [32]u8 = undefined;
            self.setStatus(std.fmt.bufPrint(&buf, "Font size: {d}px", .{self.current_font_size}) catch "Font size -");
            self.win.needs_redraw = true;
        }
    }

    pub fn increaseFontSize(self: *AnnotateApp) void {
        if (self.current_font_size < 120) {
            self.current_font_size += 2;
            for (self.selected_ids.items) |sid| {
                if (self.findAnnotationById(sid)) |a| {
                    if (a.kind == .text) {
                        a.font_size = self.current_font_size;
                    }
                }
            }
            var buf: [32]u8 = undefined;
            self.setStatus(std.fmt.bufPrint(&buf, "Font size: {d}px", .{self.current_font_size}) catch "Font size +");
            self.win.needs_redraw = true;
        }
    }

    pub fn findAnnotationById(self: *AnnotateApp, id: u32) ?*Annotation {
        for (self.annotations.items) |*ann| {
            if (ann.id == id) return ann;
        }
        return null;
    }

    pub fn deleteSelected(self: *AnnotateApp) void {
        if (self.selected_ids.items.len == 0) return;
        self.pushUndoState();

        var i: usize = self.annotations.items.len;
        var count: usize = 0;
        while (i > 0) {
            i -= 1;
            const ann = &self.annotations.items[i];
            if (self.isSelected(ann.id)) {
                var removed = self.annotations.orderedRemove(i);
                removed.deinit(self.allocator);
                count += 1;
            }
        }
        self.selected_ids.clearRetainingCapacity();

        var buf: [48]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Deleted {d} annotation(s)", .{count}) catch "Deleted";
        self.setStatus(msg);
        self.win.needs_redraw = true;
    }

    pub fn duplicateSelected(self: *AnnotateApp) void {
        if (self.selected_ids.items.len == 0) return;
        self.pushUndoState();

        var new_ids = std.ArrayListUnmanaged(u32).empty;
        defer new_ids.deinit(self.allocator);

        for (self.selected_ids.items) |sid| {
            if (self.findAnnotationById(sid)) |orig| {
                var dup = orig.clone(self.allocator) catch continue;
                dup.id = self.next_annotation_id;
                self.next_annotation_id += 1;
                dup.move(20, 20);
                self.annotations.append(self.allocator, dup) catch continue;
                new_ids.append(self.allocator, dup.id) catch {};
            }
        }

        self.selected_ids.clearRetainingCapacity();
        for (new_ids.items) |nid| {
            self.selected_ids.append(self.allocator, nid) catch {};
        }

        var buf: [48]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Duplicated {d} annotation(s)", .{new_ids.items.len}) catch "Duplicated";
        self.setStatus(msg);
        self.win.needs_redraw = true;
    }

    pub fn getCombinedSelectionBounds(self: *const AnnotateApp) ?Rect {
        if (self.selected_ids.items.len == 0) return null;
        var min_x: i32 = std.math.maxInt(i32);
        var min_y: i32 = std.math.maxInt(i32);
        var max_x: i32 = std.math.minInt(i32);
        var max_y: i32 = std.math.minInt(i32);
        var count: usize = 0;

        for (self.annotations.items) |ann| {
            if (self.isSelected(ann.id)) {
                const b = ann.getBounds();
                min_x = @min(min_x, b.x);
                min_y = @min(min_y, b.y);
                max_x = @max(max_x, b.x + @as(i32, @intCast(b.w)));
                max_y = @max(max_y, b.y + @as(i32, @intCast(b.h)));
                count += 1;
            }
        }
        if (count == 0) return null;

        return Rect{
            .x = min_x,
            .y = min_y,
            .w = @intCast(@max(8, max_x - min_x)),
            .h = @intCast(@max(8, max_y - min_y)),
        };
    }

    pub fn hitTestResizeHandle(self: *const AnnotateApp, sx: i32, sy: i32) ResizeHandle {
        if (self.selected_ids.items.len == 1) {
            const sid = self.selected_ids.items[0];
            for (self.annotations.items) |ann| {
                if (ann.id == sid) {
                    if (ann.kind == .arrow or ann.kind == .line) {
                        const s_sx = self.imageToScreenX(ann.start_x);
                        const s_sy = self.imageToScreenY(ann.start_y);
                        const e_sx = self.imageToScreenX(ann.end_x);
                        const e_sy = self.imageToScreenY(ann.end_y);
                        const d2_s = (sx - s_sx) * (sx - s_sx) + (sy - s_sy) * (sy - s_sy);
                        const d2_e = (sx - e_sx) * (sx - e_sx) + (sy - e_sy) * (sy - e_sy);
                        if (d2_s <= 100) return .start_point;
                        if (d2_e <= 100) return .end_point;
                        return .none;
                    }
                    break;
                }
            }
        }

        const maybe_bounds = self.getCombinedSelectionBounds() orelse return .none;
        const b = maybe_bounds;

        const x0 = self.imageToScreenX(b.x);
        const y0 = self.imageToScreenY(b.y);
        const x1 = self.imageToScreenX(b.x + @as(i32, @intCast(b.w)));
        const y1 = self.imageToScreenY(b.y + @as(i32, @intCast(b.h)));
        const x_mid = @divTrunc(x0 + x1, 2);
        const y_mid = @divTrunc(y0 + y1, 2);

        const handles = [_]struct { h: ResizeHandle, x: i32, y: i32 }{
            .{ .h = .top_left, .x = x0, .y = y0 },
            .{ .h = .top_mid, .x = x_mid, .y = y0 },
            .{ .h = .top_right, .x = x1, .y = y0 },
            .{ .h = .mid_right, .x = x1, .y = y_mid },
            .{ .h = .bottom_right, .x = x1, .y = y1 },
            .{ .h = .bottom_mid, .x = x_mid, .y = y1 },
            .{ .h = .bottom_left, .x = x0, .y = y1 },
            .{ .h = .mid_left, .x = x0, .y = y_mid },
        };

        for (handles) |item| {
            const dx = sx - item.x;
            const dy = sy - item.y;
            if (dx * dx + dy * dy <= 81) {
                return item.h;
            }
        }
        return .none;
    }

    pub fn bringSelectedToFront(self: *AnnotateApp) void {
        if (self.selected_ids.items.len == 0) return;
        self.pushUndoState();
        var i: usize = 0;
        while (i < self.annotations.items.len) {
            if (self.isSelected(self.annotations.items[i].id)) {
                const ann = self.annotations.orderedRemove(i);
                self.annotations.append(self.allocator, ann) catch {};
            } else {
                i += 1;
            }
        }
        self.setStatus("Brought to front");
        self.win.needs_redraw = true;
    }

    pub fn sendSelectedToBack(self: *AnnotateApp) void {
        if (self.selected_ids.items.len == 0) return;
        self.pushUndoState();
        var i: usize = self.annotations.items.len;
        while (i > 0) {
            i -= 1;
            if (self.isSelected(self.annotations.items[i].id)) {
                const ann = self.annotations.orderedRemove(i);
                self.annotations.insert(self.allocator, 0, ann) catch {};
            }
        }
        self.setStatus("Sent to back");
        self.win.needs_redraw = true;
    }

    pub fn moveSelectedUp(self: *AnnotateApp) void {
        if (self.selected_ids.items.len != 1) return;
        const sid = self.selected_ids.items[0];
        for (self.annotations.items, 0..) |ann, idx| {
            if (ann.id == sid and idx + 1 < self.annotations.items.len) {
                self.pushUndoState();
                const tmp = self.annotations.items[idx];
                self.annotations.items[idx] = self.annotations.items[idx + 1];
                self.annotations.items[idx + 1] = tmp;
                self.win.needs_redraw = true;
                return;
            }
        }
    }

    pub fn moveSelectedDown(self: *AnnotateApp) void {
        if (self.selected_ids.items.len != 1) return;
        const sid = self.selected_ids.items[0];
        for (self.annotations.items, 0..) |ann, idx| {
            if (ann.id == sid and idx > 0) {
                self.pushUndoState();
                const tmp = self.annotations.items[idx];
                self.annotations.items[idx] = self.annotations.items[idx - 1];
                self.annotations.items[idx - 1] = tmp;
                self.win.needs_redraw = true;
                return;
            }
        }
    }

    // ==========================================
    // Save, Copy, Export, Screenshot Actions
    // ==========================================

    pub fn flattenImage(self: *AnnotateApp) !ImageBuffer {
        var out_img = try self.base_image.img.clone(self.allocator);
        errdefer out_img.deinit();

        for (self.annotations.items) |*ann| {
            ann.renderToImage(&out_img, self.font);
        }
        return out_img;
    }

    pub fn save(self: *AnnotateApp) !void {
        var flat = try self.flattenImage();
        defer flat.deinit();

        var path_buf: [512]u8 = undefined;
        const save_path = if (self.original_path) |p|
            p
        else blk: {
            const home = c.getenv("HOME");
            const ts = c.time(null);
            if (home) |h| {
                const home_str = std.mem.span(h);
                var dir_buf: [384]u8 = undefined;
                const dir = std.fmt.bufPrintZ(&dir_buf, "{s}/Pictures/Screenshots", .{home_str}) catch "/tmp";
                _ = c.mkdir(dir.ptr, 0o755);
                break :blk std.fmt.bufPrint(&path_buf, "{s}/Pictures/Screenshots/mizu_{d}.png", .{ home_str, ts }) catch "/tmp/mizu_annotated.png";
            }
            break :blk std.fmt.bufPrint(&path_buf, "/tmp/mizu_annotated_{d}.png", .{ts}) catch "/tmp/mizu_annotated.png";
        };

        if (std.mem.endsWith(u8, save_path, ".jpg") or std.mem.endsWith(u8, save_path, ".jpeg")) {
            try flat.saveJpeg(save_path, 92);
        } else {
            try flat.savePng(save_path);
        }

        var feedback_buf: [128]u8 = undefined;
        const feedback = std.fmt.bufPrint(&feedback_buf, "Saved to {s}", .{save_path}) catch "Saved successfully";
        self.setStatus(feedback);
    }

    pub fn exportImage(self: *AnnotateApp, as_jpeg: bool) !void {
        var flat = try self.flattenImage();
        defer flat.deinit();

        const home = if (c.getenv("HOME")) |h| std.mem.span(h) else "/tmp";
        const ts = c.time(null);
        var path_buf: [512]u8 = undefined;

        const path = if (as_jpeg)
            try std.fmt.bufPrint(&path_buf, "{s}/Pictures/mizu_export_{d}.jpg", .{ home, ts })
        else
            try std.fmt.bufPrint(&path_buf, "{s}/Pictures/mizu_export_{d}.png", .{ home, ts });

        if (as_jpeg) {
            try flat.saveJpeg(path, 92);
        } else {
            try flat.savePng(path);
        }

        var feedback_buf: [128]u8 = undefined;
        const feedback = std.fmt.bufPrint(&feedback_buf, "Exported to {s}", .{path}) catch "Exported";
        self.setStatus(feedback);
    }

    pub fn copyClipboard(self: *AnnotateApp) !void {
        var flat = try self.flattenImage();
        defer flat.deinit();
        try flat.copyToClipboard(self.allocator);
        self.setStatus("Copied to clipboard!");
    }

    pub fn captureScreenshot(self: *AnnotateApp) !void {
        self.setStatus("Select region with mouse...");
        self.win.commitFrame();

        if (try ImageBuffer.captureScreenshotRegion(self.allocator)) |new_shot| {
            self.pushUndoState();
            self.base_image.release();
            self.base_image = try SharedImage.create(self.allocator, new_shot);
            for (self.annotations.items) |*a| a.deinit(self.allocator);
            self.annotations.clearRetainingCapacity();
            self.selected_ids.clearRetainingCapacity();
            self.fitToWindow();
            self.setStatus("Region captured!");
        } else {
            self.setStatus("Screenshot canceled");
        }
    }

    // ==========================================
    // Crop & Base Transformations
    // ==========================================

    pub fn startCrop(self: *AnnotateApp) void {
        self.is_crop_mode = true;
        self.is_cropping = false;
        self.crop_x0 = 0;
        self.crop_y0 = 0;
        self.crop_x1 = @intCast(self.base_image.img.width);
        self.crop_y1 = @intCast(self.base_image.img.height);
        self.setStatus("Drag crop area • Enter: Apply • Esc: Cancel");
        self.win.needs_redraw = true;
    }

    pub fn commitCrop(self: *AnnotateApp) !void {
        const x0 = @min(self.crop_x0, self.crop_x1);
        const y0 = @min(self.crop_y0, self.crop_y1);
        const cw: u32 = @intCast(@abs(self.crop_x1 - self.crop_x0));
        const ch: u32 = @intCast(@abs(self.crop_y1 - self.crop_y0));

        if (cw < 4 or ch < 4) {
            self.cancelCrop();
            return;
        }

        self.pushUndoState();
        const cropped = try self.base_image.img.crop(self.allocator, Rect{ .x = x0, .y = y0, .w = cw, .h = ch });
        self.base_image.release();
        self.base_image = try SharedImage.create(self.allocator, cropped);

        // Shift existing annotations to match cropped origin
        for (self.annotations.items) |*ann| {
            ann.move(-x0, -y0);
        }

        self.is_crop_mode = false;
        self.fitToWindow();

        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Cropped to {d}×{d} px", .{ cw, ch }) catch "Cropped";
        self.setStatus(msg);
    }

    pub fn cancelCrop(self: *AnnotateApp) void {
        self.is_crop_mode = false;
        self.is_cropping = false;
        self.setStatus("Crop canceled");
        self.win.needs_redraw = true;
    }

    pub fn rotate(self: *AnnotateApp, clockwise: bool) !void {
        self.pushUndoState();
        const old_width = self.base_image.img.width;
        const rotated = if (clockwise)
            try self.base_image.img.rotate90(self.allocator)
        else
            try self.base_image.img.rotate270(self.allocator);

        self.base_image.release();
        self.base_image = try SharedImage.create(self.allocator, rotated);

        // Rotate existing annotations coordinates
        if (!clockwise) { // 90° CCW / left
            for (self.annotations.items) |*ann| {
                switch (ann.kind) {
                    .arrow, .line => {
                        const nx0 = ann.start_y;
                        const ny0 = @as(i32, @intCast(old_width)) - 1 - ann.start_x;
                        const nx1 = ann.end_y;
                        const ny1 = @as(i32, @intCast(old_width)) - 1 - ann.end_x;
                        ann.start_x = nx0;
                        ann.start_y = ny0;
                        ann.end_x = nx1;
                        ann.end_y = ny1;
                    },
                    .pen => {
                        for (ann.points.items) |*pt| {
                            const nx = pt.y;
                            const ny = @as(i32, @intCast(old_width)) - 1 - pt.x;
                            pt.x = nx;
                            pt.y = ny;
                        }
                    },
                    else => {
                        const nx = ann.rect.y;
                        const ny = @as(i32, @intCast(old_width)) - 1 - ann.rect.x - @as(i32, @intCast(ann.rect.w));
                        const nw = ann.rect.h;
                        const nh = ann.rect.w;
                        ann.rect = Rect{ .x = nx, .y = ny, .w = nw, .h = nh };
                    },
                }
            }
        }
        self.fitToWindow();
        self.setStatus(if (clockwise) "Rotated 90° CW" else "Rotated 90° Left");
    }

    // ==========================================
    // Event Handling
    // ==========================================

    pub fn handlePointerMotion(self: *AnnotateApp, x: i32, y: i32) void {
        const c_rect = self.canvasRect();
        const inside_canvas = (x >= c_rect.x and y >= c_rect.y and x < c_rect.x + @as(i32, @intCast(c_rect.w)) and y < c_rect.y + @as(i32, @intCast(c_rect.h)));

        if (self.show_adjustments and self.active_slider != null) {
            self.updateSliderFromMouse(x);
            return;
        }

        if (self.is_panning) {
            self.pan_x += @floatFromInt(x - self.pan_start_x);
            self.pan_y += @floatFromInt(y - self.pan_start_y);
            self.pan_start_x = x;
            self.pan_start_y = y;
            self.win.needs_redraw = true;
            return;
        }

        if (self.is_crop_mode and self.is_cropping) {
            self.crop_x1 = self.screenToImageX(x);
            self.crop_y1 = self.screenToImageY(y);
            self.win.needs_redraw = true;
            return;
        }

        const img_x = self.screenToImageX(x);
        const img_y = self.screenToImageY(y);

        if (self.is_resizing and self.active_handle != .none) {
            if (self.selected_ids.items.len == 1) {
                if (self.findAnnotationById(self.selected_ids.items[0])) |ann| {
                    ann.resize(self.active_handle, img_x, img_y);
                    self.win.needs_redraw = true;
                    return;
                }
            }
        }

        if (self.is_moving) {
            const dx = img_x - self.last_move_x;
            const dy = img_y - self.last_move_y;
            if (dx != 0 or dy != 0) {
                for (self.selected_ids.items) |sid| {
                    if (self.findAnnotationById(sid)) |ann| {
                        ann.move(dx, dy);
                    }
                }
                self.last_move_x = img_x;
                self.last_move_y = img_y;
                self.win.needs_redraw = true;
            }
            return;
        }

        if (self.is_marquee) {
            self.drag_curr_x = img_x;
            self.drag_curr_y = img_y;
            self.win.needs_redraw = true;
            return;
        }

        if (self.is_drawing) {
            self.drag_curr_x = img_x;
            self.drag_curr_y = img_y;

            if (self.active_tool == .freehand and self.annotations.items.len > 0) {
                const last_idx = self.annotations.items.len - 1;
                self.annotations.items[last_idx].points.append(self.allocator, .{ .x = img_x, .y = img_y }) catch {};
            }
            self.win.needs_redraw = true;
            return;
        }

        // Update cursor appearance based on context
        if (self.is_crop_mode) {
            self.win.setCursorShape(.crosshair);
        } else if (inside_canvas) {
            if (self.active_tool == .select) {
                const handle = self.hitTestResizeHandle(x, y);
                switch (handle) {
                    .top_left, .bottom_right => self.win.setCursorShape(.nwse_resize),
                    .top_right, .bottom_left => self.win.setCursorShape(.nesw_resize),
                    .top_mid, .bottom_mid => self.win.setCursorShape(.ns_resize),
                    .mid_left, .mid_right => self.win.setCursorShape(.ew_resize),
                    .start_point, .end_point => self.win.setCursorShape(.pointer),
                    .none => {
                        // Check if hovering over selected annotation
                        var over_sel = false;
                        for (self.selected_ids.items) |sid| {
                            if (self.findAnnotationById(sid)) |ann| {
                                if (ann.hitTest(img_x, img_y)) {
                                    over_sel = true;
                                    break;
                                }
                            }
                        }
                        if (over_sel) {
                            self.win.setCursorShape(.grab);
                        } else {
                            self.win.setCursorShape(.default);
                        }
                    },
                }
            } else if (self.active_tool == .text) {
                self.win.setCursorShape(.text);
            } else {
                self.win.setCursorShape(.crosshair);
            }
        } else {
            self.win.setCursorShape(.default);
        }
    }

    pub fn handlePointerButton(self: *AnnotateApp, x: i32, y: i32, button: u32, pressed: bool) void {
        const c_rect = self.canvasRect();
        const inside_canvas = (x >= c_rect.x and y >= c_rect.y and x < c_rect.x + @as(i32, @intCast(c_rect.w)) and y < c_rect.y + @as(i32, @intCast(c_rect.h)));

        // Pan with Middle Click (0x112) or Left Click with Space/Pan
        if (button == 0x112) {
            if (pressed) {
                self.is_panning = true;
                self.pan_start_x = x;
                self.pan_start_y = y;
                self.win.setCursorShape(.grab);
            } else {
                self.is_panning = false;
                self.win.setCursorShape(.default);
            }
            return;
        }

        if (button == 0x110) {
            if (pressed) {
                // Info modal dismissal
                if (self.show_info) {
                    self.show_info = false;
                    self.win.needs_redraw = true;
                    return;
                }

                // Check toolbar clicks
                if (y < @as(i32, @intCast(self.toolbar_height))) {
                    self.handleToolbarClick(x, y);
                    return;
                }

                // Check status bar clicks
                if (y >= @as(i32, @intCast(self.win.height - self.statusbar_height))) {
                    self.handleStatusbarClick(x, y);
                    return;
                }

                // Check Layers panel clicks
                if (self.show_layers and x >= @as(i32, @intCast(self.win.width - self.layers_panel_width))) {
                    self.handleLayersPanelClick(x, y);
                    return;
                }

                // Check Adjustments panel clicks
                if (self.show_adjustments and x >= @as(i32, @intCast(self.win.width - self.adjust_panel_width))) {
                    self.handleAdjustPanelClick(x, y);
                    return;
                }

                // Commit active text editing if clicked away
                if (self.editing_text_id != null) {
                    self.commitTextEditing();
                }

                if (inside_canvas) {
                    const img_x = self.screenToImageX(x);
                    const img_y = self.screenToImageY(y);

                    // Crop mode dragging
                    if (self.is_crop_mode) {
                        self.is_cropping = true;
                        self.crop_x0 = img_x;
                        self.crop_y0 = img_y;
                        self.crop_x1 = img_x;
                        self.crop_y1 = img_y;
                        self.win.needs_redraw = true;
                        return;
                    }

                    // Select tool interaction
                    if (self.active_tool == .select) {
                        // Check if handle was clicked
                        const handle = self.hitTestResizeHandle(x, y);
                        if (handle != .none) {
                            self.pushUndoState();
                            self.is_resizing = true;
                            self.active_handle = handle;
                            self.win.needs_redraw = true;
                            return;
                        }

                        // Check if an annotation was clicked (reverse z-order, top to bottom)
                        var clicked_id: ?u32 = null;
                        var idx: usize = self.annotations.items.len;
                        while (idx > 0) {
                            idx -= 1;
                            const ann = &self.annotations.items[idx];
                            if (ann.hitTest(img_x, img_y)) {
                                clicked_id = ann.id;
                                break;
                            }
                        }

                        if (clicked_id) |cid| {
                            if (self.win.is_shift) {
                                self.toggleSelect(cid);
                            } else if (!self.isSelected(cid)) {
                                self.selectOnly(cid);
                            }
                            // Start moving
                            self.pushUndoState();
                            self.is_moving = true;
                            self.last_move_x = img_x;
                            self.last_move_y = img_y;
                            self.win.setCursorShape(.grab);
                            self.win.needs_redraw = true;
                        } else {
                            // Clicked on empty canvas space: clear selection and start marquee
                            if (!self.win.is_shift) {
                                self.deselectAll();
                            }
                            self.is_marquee = true;
                            self.drag_start_x = img_x;
                            self.drag_start_y = img_y;
                            self.drag_curr_x = img_x;
                            self.drag_curr_y = img_y;
                            self.win.needs_redraw = true;
                        }
                        return;
                    }

                    // Text tool: click to create inline text annotation
                    if (self.active_tool == .text) {
                        self.pushUndoState();
                        const new_id = self.next_annotation_id;
                        self.next_annotation_id += 1;

                        const new_ann = Annotation{
                            .id = new_id,
                            .kind = .text,
                            .rect = Rect{ .x = img_x, .y = img_y, .w = 120, .h = @intCast(self.current_font_size + 8) },
                            .font_size = self.current_font_size,
                            .color = self.current_color,
                        };
                        self.annotations.append(self.allocator, new_ann) catch return;
                        self.selectOnly(new_id);
                        self.editing_text_id = new_id;
                        self.win.needs_redraw = true;
                        return;
                    }

                    // Step Badge tool: click to place incrementing number badge
                    if (self.active_tool == .step_badge) {
                        self.pushUndoState();
                        const new_id = self.next_annotation_id;
                        self.next_annotation_id += 1;

                        const badge = Annotation{
                            .id = new_id,
                            .kind = .step_badge,
                            .rect = Rect{ .x = img_x, .y = img_y, .w = 32, .h = 32 },
                            .step_number = self.step_badge_counter,
                            .color = self.current_color,
                        };
                        self.step_badge_counter += 1;
                        self.annotations.append(self.allocator, badge) catch return;
                        self.selectOnly(new_id);
                        self.win.needs_redraw = true;
                        return;
                    }

                    // Drawing creation tools: start drag
                    self.pushUndoState();
                    self.is_drawing = true;
                    self.drag_start_x = img_x;
                    self.drag_start_y = img_y;
                    self.drag_curr_x = img_x;
                    self.drag_curr_y = img_y;

                    if (self.active_tool == .freehand) {
                        const new_id = self.next_annotation_id;
                        self.next_annotation_id += 1;

                        var ann = Annotation{
                            .id = new_id,
                            .kind = .pen,
                            .color = self.current_color,
                            .stroke_width = self.stroke_width,
                        };
                        ann.points.append(self.allocator, .{ .x = img_x, .y = img_y }) catch {};
                        self.annotations.append(self.allocator, ann) catch {};
                    }
                    self.win.needs_redraw = true;
                }
            } else {
                // Button released
                if (self.active_slider != null) self.active_slider = null;

                if (self.is_crop_mode and self.is_cropping) {
                    self.is_cropping = false;
                    self.win.needs_redraw = true;
                    return;
                }

                if (self.is_resizing) {
                    self.is_resizing = false;
                    self.active_handle = .none;
                    self.win.needs_redraw = true;
                    return;
                }

                if (self.is_moving) {
                    self.is_moving = false;
                    self.win.setCursorShape(.default);
                    self.win.needs_redraw = true;
                    return;
                }

                if (self.is_marquee) {
                    self.is_marquee = false;
                    // Select all annotations within marquee rectangle
                    const rx0 = @min(self.drag_start_x, self.drag_curr_x);
                    const ry0 = @min(self.drag_start_y, self.drag_curr_y);
                    const rx1 = @max(self.drag_start_x, self.drag_curr_x);
                    const ry1 = @max(self.drag_start_y, self.drag_curr_y);

                    for (self.annotations.items) |ann| {
                        if (!ann.visible or ann.locked) continue;
                        const b = ann.getBounds();
                        const ax1 = b.x + @as(i32, @intCast(b.w));
                        const ay1 = b.y + @as(i32, @intCast(b.h));
                        if (b.x < rx1 and ax1 > rx0 and b.y < ry1 and ay1 > ry0) {
                            if (!self.isSelected(ann.id)) {
                                self.selected_ids.append(self.allocator, ann.id) catch {};
                            }
                        }
                    }
                    self.win.needs_redraw = true;
                    return;
                }

                if (self.is_drawing) {
                    self.is_drawing = false;
                    const end_x = self.screenToImageX(x);
                    const end_y = self.screenToImageY(y);

                    const new_id = self.next_annotation_id;
                    self.next_annotation_id += 1;

                    switch (self.active_tool) {
                        .arrow => {
                            const ann = Annotation{
                                .id = new_id,
                                .kind = .arrow,
                                .start_x = self.drag_start_x,
                                .start_y = self.drag_start_y,
                                .end_x = end_x,
                                .end_y = end_y,
                                .stroke_width = self.stroke_width,
                                .color = self.current_color,
                            };
                            self.annotations.append(self.allocator, ann) catch {};
                            self.selectOnly(new_id);
                        },
                        .line => {
                            const ann = Annotation{
                                .id = new_id,
                                .kind = .line,
                                .start_x = self.drag_start_x,
                                .start_y = self.drag_start_y,
                                .end_x = end_x,
                                .end_y = end_y,
                                .stroke_width = self.stroke_width,
                                .color = self.current_color,
                            };
                            self.annotations.append(self.allocator, ann) catch {};
                            self.selectOnly(new_id);
                        },
                        .rect => {
                            const rx = @min(self.drag_start_x, end_x);
                            const ry = @min(self.drag_start_y, end_y);
                            const rw: u32 = @intCast(@abs(end_x - self.drag_start_x));
                            const rh: u32 = @intCast(@abs(end_y - self.drag_start_y));
                            if (rw > 2 and rh > 2) {
                                const ann = Annotation{
                                    .id = new_id,
                                    .kind = .rect,
                                    .rect = Rect{ .x = rx, .y = ry, .w = rw, .h = rh },
                                    .stroke_width = self.stroke_width,
                                    .color = self.current_color,
                                    .filled = self.fill_shape,
                                };
                                self.annotations.append(self.allocator, ann) catch {};
                                self.selectOnly(new_id);
                            }
                        },
                        .circle => {
                            const rx = @min(self.drag_start_x, end_x);
                            const ry = @min(self.drag_start_y, end_y);
                            const rw: u32 = @intCast(@abs(end_x - self.drag_start_x));
                            const rh: u32 = @intCast(@abs(end_y - self.drag_start_y));
                            if (rw > 2 and rh > 2) {
                                const ann = Annotation{
                                    .id = new_id,
                                    .kind = .circle,
                                    .rect = Rect{ .x = rx, .y = ry, .w = rw, .h = rh },
                                    .stroke_width = self.stroke_width,
                                    .color = self.current_color,
                                    .filled = self.fill_shape,
                                };
                                self.annotations.append(self.allocator, ann) catch {};
                                self.selectOnly(new_id);
                            }
                        },
                        .highlight => {
                            const rx = @min(self.drag_start_x, end_x);
                            const ry = @min(self.drag_start_y, end_y);
                            const rw: u32 = @intCast(@abs(end_x - self.drag_start_x));
                            const rh: u32 = @intCast(@abs(end_y - self.drag_start_y));
                            if (rw > 2 and rh > 2) {
                                const ann = Annotation{
                                    .id = new_id,
                                    .kind = .highlight,
                                    .rect = Rect{ .x = rx, .y = ry, .w = rw, .h = rh },
                                    .color = self.current_color,
                                };
                                self.annotations.append(self.allocator, ann) catch {};
                                self.selectOnly(new_id);
                            }
                        },
                        .blur => {
                            const rx = @min(self.drag_start_x, end_x);
                            const ry = @min(self.drag_start_y, end_y);
                            const rw: u32 = @intCast(@abs(end_x - self.drag_start_x));
                            const rh: u32 = @intCast(@abs(end_y - self.drag_start_y));
                            if (rw > 2 and rh > 2) {
                                const ann = Annotation{
                                    .id = new_id,
                                    .kind = .blur,
                                    .rect = Rect{ .x = rx, .y = ry, .w = rw, .h = rh },
                                    .stroke_width = self.stroke_width,
                                };
                                self.annotations.append(self.allocator, ann) catch {};
                                self.selectOnly(new_id);
                            }
                        },
                        .pixelate => {
                            const rx = @min(self.drag_start_x, end_x);
                            const ry = @min(self.drag_start_y, end_y);
                            const rw: u32 = @intCast(@abs(end_x - self.drag_start_x));
                            const rh: u32 = @intCast(@abs(end_y - self.drag_start_y));
                            if (rw > 2 and rh > 2) {
                                const ann = Annotation{
                                    .id = new_id,
                                    .kind = .pixelate,
                                    .rect = Rect{ .x = rx, .y = ry, .w = rw, .h = rh },
                                    .stroke_width = self.stroke_width,
                                };
                                self.annotations.append(self.allocator, ann) catch {};
                                self.selectOnly(new_id);
                            }
                        },
                        .freehand => {
                            if (self.annotations.items.len > 0) {
                                self.selectOnly(self.annotations.items[self.annotations.items.len - 1].id);
                            }
                        },
                        else => {},
                    }
                    self.win.needs_redraw = true;
                }
            }
        }
    }

    pub fn handlePointerAxis(self: *AnnotateApp, x: i32, y: i32, scroll: i32) void {
        if (scroll != 0) {
            const factor: f32 = if (scroll < 0) 1.12 else 0.88;
            const new_zoom = std.math.clamp(self.zoom * factor, 0.1, 10.0);

            // Zoom towards mouse position (x, y)
            const mouse_img_x = self.screenToImageX(x);
            const mouse_img_y = self.screenToImageY(y);

            self.zoom = new_zoom;
            self.pan_x = @as(f32, @floatFromInt(x)) - @as(f32, @floatFromInt(mouse_img_x)) * self.zoom;
            self.pan_y = @as(f32, @floatFromInt(y)) - @as(f32, @floatFromInt(mouse_img_y)) * self.zoom;

            self.win.needs_redraw = true;
        }
    }

    pub fn commitTextEditing(self: *AnnotateApp) void {
        if (self.editing_text_id) |tid| {
            if (self.findAnnotationById(tid)) |ann| {
                if (ann.text_len == 0) {
                    // Empty text: remove it
                    self.deleteSelected();
                } else {
                    // Compute text bounding width
                    const slice = ann.text_buf[0..ann.text_len];
                    const w = self.font.measureTextWithSize(slice, ann.font_size);
                    ann.rect.w = @intCast(@max(20, w + 12));
                    ann.rect.h = @intCast(@max(16, ann.font_size + 8));
                }
            }
            self.editing_text_id = null;
            self.win.needs_redraw = true;
        }
    }

    pub fn handleKey(self: *AnnotateApp, sym: u32, utf8: []const u8, is_ctrl: bool, is_shift: bool) void {
        // Typing into active inline text annotation
        if (self.editing_text_id) |tid| {
            if (self.findAnnotationById(tid)) |ann| {
                if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_KP_Enter) {
                    self.commitTextEditing();
                    return;
                } else if (sym == c.XKB_KEY_Escape) {
                    self.commitTextEditing();
                    self.deselectAll();
                    self.setActiveTool(.select);
                    return;
                } else if (sym == c.XKB_KEY_BackSpace) {
                    if (ann.text_len > 0) {
                        ann.text_len -= 1;
                        self.win.needs_redraw = true;
                    }
                    return;
                } else if (utf8.len > 0 and ann.text_len + utf8.len < ann.text_buf.len) {
                    @memcpy(ann.text_buf[ann.text_len .. ann.text_len + utf8.len], utf8);
                    ann.text_len += utf8.len;
                    self.win.needs_redraw = true;
                    return;
                }
            }
        }

        if (self.is_crop_mode) {
            if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_KP_Enter) {
                self.commitCrop() catch self.setStatus("Crop failed");
                return;
            } else if (sym == c.XKB_KEY_Escape) {
                self.cancelCrop();
                self.deselectAll();
                self.setActiveTool(.select);
                return;
            }
        }

        // Global shortcuts with Ctrl
        if (is_ctrl) {
            if (sym == c.XKB_KEY_q or sym == c.XKB_KEY_Q or sym == c.XKB_KEY_w or sym == c.XKB_KEY_W) {
                self.win.running = false;
                return;
            } else if (sym == c.XKB_KEY_s or sym == c.XKB_KEY_S) {
                self.save() catch self.setStatus("Save failed");
                return;
            } else if (sym == c.XKB_KEY_c or sym == c.XKB_KEY_C) {
                self.copyClipboard() catch self.setStatus("Copy failed");
                return;
            } else if (sym == c.XKB_KEY_e or sym == c.XKB_KEY_E) {
                self.exportImage(false) catch self.setStatus("Export failed");
                return;
            } else if (sym == c.XKB_KEY_z or sym == c.XKB_KEY_Z) {
                self.undo();
                return;
            } else if (sym == c.XKB_KEY_y or sym == c.XKB_KEY_Y) {
                self.redo();
                return;
            } else if (sym == c.XKB_KEY_d or sym == c.XKB_KEY_D) {
                self.duplicateSelected();
                return;
            } else if (sym == c.XKB_KEY_a or sym == c.XKB_KEY_A) {
                self.selectAll();
                return;
            } else if (sym == c.XKB_KEY_l or sym == c.XKB_KEY_L) {
                self.show_layers = !self.show_layers;
                self.win.needs_redraw = true;
                return;
            } else if (sym == c.XKB_KEY_bracketright) {
                if (is_shift) {
                    self.bringSelectedToFront();
                } else {
                    self.moveSelectedUp();
                }
                return;
            } else if (sym == c.XKB_KEY_bracketleft) {
                if (is_shift) {
                    self.sendSelectedToBack();
                } else {
                    self.moveSelectedDown();
                }
                return;
            }
        }

        // Delete / Backspace: delete selected annotations
        if (sym == c.XKB_KEY_Delete or sym == c.XKB_KEY_BackSpace) {
            self.deleteSelected();
            return;
        }

        // Arrow keys: nudge selected annotations
        if (self.selected_ids.items.len > 0) {
            const step: i32 = if (is_shift) 10 else 1;
            if (sym == c.XKB_KEY_Left) {
                for (self.selected_ids.items) |sid| {
                    if (self.findAnnotationById(sid)) |a| a.move(-step, 0);
                }
                self.win.needs_redraw = true;
                return;
            } else if (sym == c.XKB_KEY_Right) {
                for (self.selected_ids.items) |sid| {
                    if (self.findAnnotationById(sid)) |a| a.move(step, 0);
                }
                self.win.needs_redraw = true;
                return;
            } else if (sym == c.XKB_KEY_Up) {
                for (self.selected_ids.items) |sid| {
                    if (self.findAnnotationById(sid)) |a| a.move(0, -step);
                }
                self.win.needs_redraw = true;
                return;
            } else if (sym == c.XKB_KEY_Down) {
                for (self.selected_ids.items) |sid| {
                    if (self.findAnnotationById(sid)) |a| a.move(0, step);
                }
                self.win.needs_redraw = true;
                return;
            }
        }

        // Tool Selection Shortcuts
        switch (sym) {
            c.XKB_KEY_v, c.XKB_KEY_V, c.XKB_KEY_s, c.XKB_KEY_S => self.setActiveTool(.select),
            c.XKB_KEY_p, c.XKB_KEY_P => self.setActiveTool(.freehand),
            c.XKB_KEY_a, c.XKB_KEY_A => self.setActiveTool(.arrow),
            c.XKB_KEY_l, c.XKB_KEY_L => self.setActiveTool(.line),
            c.XKB_KEY_r, c.XKB_KEY_R => self.setActiveTool(.rect),
            c.XKB_KEY_c, c.XKB_KEY_C => self.setActiveTool(.circle),
            c.XKB_KEY_t, c.XKB_KEY_T => self.setActiveTool(.text),
            c.XKB_KEY_n, c.XKB_KEY_N, c.XKB_KEY_1 => self.setActiveTool(.step_badge),
            c.XKB_KEY_h, c.XKB_KEY_H => self.setActiveTool(.highlight),
            c.XKB_KEY_b, c.XKB_KEY_B => self.setActiveTool(.blur),
            c.XKB_KEY_x, c.XKB_KEY_X => self.setActiveTool(.pixelate),
            c.XKB_KEY_k, c.XKB_KEY_K => self.startCrop(),
            c.XKB_KEY_bracketright => self.rotate(true) catch {},
            c.XKB_KEY_bracketleft => self.rotate(false) catch {},
            c.XKB_KEY_f, c.XKB_KEY_F => self.fitToWindow(),
            c.XKB_KEY_0 => {
                self.zoom = 1.0;
                self.win.needs_redraw = true;
            },
            c.XKB_KEY_plus, c.XKB_KEY_equal => {
                self.zoom = std.math.clamp(self.zoom * 1.2, 0.1, 10.0);
                self.win.needs_redraw = true;
            },
            c.XKB_KEY_minus, c.XKB_KEY_underscore => {
                self.zoom = std.math.clamp(self.zoom * 0.8, 0.1, 10.0);
                self.win.needs_redraw = true;
            },
            c.XKB_KEY_Escape => {
                if (self.editing_text_id != null) {
                    self.commitTextEditing();
                }
                if (self.is_drawing) {
                    self.is_drawing = false;
                }
                if (self.is_crop_mode) {
                    self.cancelCrop();
                }
                if (self.show_info) {
                    self.show_info = false;
                }
                if (self.show_adjustments) {
                    self.show_adjustments = false;
                }
                self.deselectAll();
                self.setActiveTool(.select);
                self.setStatus("Selection Tool (V)");
                self.win.needs_redraw = true;
            },
            c.XKB_KEY_q, c.XKB_KEY_Q => {
                if (self.editing_text_id == null) {
                    self.win.running = false;
                }
            },
            else => {},
        }
        self.win.needs_redraw = true;
    }

    fn handleToolbarClick(self: *AnnotateApp, x: i32, y: i32) void {
        _ = y;
        var bx: i32 = 80;
        const btn_w: i32 = 28;

        // Tools: Select (󰆽), Pen (), Arrow (), Line (󰕞), Rect (󰹟), Circle (), Text (󰊄), Step (󰲠), Highlight (), Blur (󰂶), Pixelate ()
        const tools = [_]Tool{ .select, .freehand, .arrow, .line, .rect, .circle, .text, .step_badge, .highlight, .blur, .pixelate };
        for (tools) |t| {
            if (x >= bx and x < bx + btn_w) {
                self.setActiveTool(t);
                return;
            }
            bx += btn_w + 3;
        }

        bx += 14; // Separator

        // Stroke width buttons: 2, 4, 8, 16
        const widths = [_]u32{ 2, 4, 8, 16 };
        for (widths) |sw| {
            if (x >= bx and x < bx + 22) {
                self.stroke_width = sw;
                for (self.selected_ids.items) |sid| {
                    if (self.findAnnotationById(sid)) |a| a.stroke_width = sw;
                }
                var buf: [32]u8 = undefined;
                self.setStatus(std.fmt.bufPrint(&buf, "Stroke width: {d}px", .{sw}) catch "Width");
                self.win.needs_redraw = true;
                return;
            }
            bx += 24;
        }

        // Font size decrease (󰧳)
        if (x >= bx and x < bx + 26) {
            self.decreaseFontSize();
            return;
        }
        bx += 28;

        // Font size increase (󰧴)
        if (x >= bx and x < bx + 26) {
            self.increaseFontSize();
            return;
        }
        bx += 28;

        bx += 14; // Separator

        // Palette swatches
        for (Palette.colors) |col| {
            if (x >= bx and x < bx + 16) {
                self.current_color = col;
                for (self.selected_ids.items) |sid| {
                    if (self.findAnnotationById(sid)) |a| a.color = col;
                }
                self.win.needs_redraw = true;
                return;
            }
            bx += 18;
        }

        bx += 14; // Separator

        // Fill toggle ()
        if (x >= bx and x < bx + 30) {
            self.fill_shape = !self.fill_shape;
            for (self.selected_ids.items) |sid| {
                if (self.findAnnotationById(sid)) |a| a.filled = self.fill_shape;
            }
            self.setStatus(if (self.fill_shape) "Fill: Enabled" else "Fill: Disabled");
            self.win.needs_redraw = true;
            return;
        }
        bx += 34;

        // Crop tool ()
        if (x >= bx and x < bx + 30) {
            self.startCrop();
            return;
        }
        bx += 34;

        // Rotate 90* left (󰚪)
        if (x >= bx and x < bx + 30) {
            self.rotate(false) catch {};
            return;
        }
        bx += 34;

        // Layers panel toggle ()
        if (x >= bx and x < bx + 30) {
            self.show_layers = !self.show_layers;
            self.win.needs_redraw = true;
            return;
        }
        bx += 34;

        // Right side global buttons: Undo, Redo, Capture, Save, Copy
        const rx_base: i32 = @as(i32, @intCast(self.win.width)) - 180;
        if (x >= rx_base) {
            var rx = rx_base;
            // Undo ()
            if (x >= rx and x < rx + 30) {
                self.undo();
                return;
            }
            rx += 34;

            // Redo ()
            if (x >= rx and x < rx + 30) {
                self.redo();
                return;
            }
            rx += 34;

            // Capture (󰄀)
            if (x >= rx and x < rx + 30) {
                self.captureScreenshot() catch {};
                return;
            }
            rx += 34;

            // Save (󰆓)
            if (x >= rx and x < rx + 30) {
                self.save() catch {};
                return;
            }
            rx += 34;

            // Copy (󰆏)
            if (x >= rx and x < rx + 30) {
                self.copyClipboard() catch {};
                return;
            }
        }
    }

    fn handleLayersPanelClick(self: *AnnotateApp, x: i32, y: i32) void {
        const panel_x: i32 = @as(i32, @intCast(self.win.width)) - @as(i32, @intCast(self.layers_panel_width));
        if (y < @as(i32, @intCast(self.toolbar_height + 34))) {
            // Header close button
            if (x >= @as(i32, @intCast(self.win.width)) - 32) {
                self.show_layers = false;
                self.win.needs_redraw = true;
            }
            return;
        }

        const start_y: i32 = @intCast(self.toolbar_height + 40);
        const row_h: i32 = 32;
        const total = self.annotations.items.len;
        if (total == 0) return;

        const row_idx = @divTrunc(y - start_y, row_h);
        if (row_idx >= 0 and row_idx < total) {
            // Layers are displayed in reverse z-order (top of list is front-most item)
            const ann_idx = total - 1 - @as(usize, @intCast(row_idx));
            const ann = &self.annotations.items[ann_idx];

            // Check eye icon click (visibility)
            if (x >= panel_x + 130 and x < panel_x + 150) {
                self.pushUndoState();
                ann.visible = !ann.visible;
                self.win.needs_redraw = true;
                return;
            }

            // Check lock icon click
            if (x >= panel_x + 152 and x < panel_x + 172) {
                self.pushUndoState();
                ann.locked = !ann.locked;
                self.win.needs_redraw = true;
                return;
            }

            // Check delete button click
            if (x >= panel_x + 195 and x < panel_x + 220) {
                self.pushUndoState();
                var removed = self.annotations.orderedRemove(ann_idx);
                removed.deinit(self.allocator);
                self.deselectAll();
                self.win.needs_redraw = true;
                return;
            }

            // Select clicked layer
            if (self.win.is_shift) {
                self.toggleSelect(ann.id);
            } else {
                self.selectOnly(ann.id);
            }
            self.win.needs_redraw = true;
        }
    }

    fn handleAdjustPanelClick(self: *AnnotateApp, x: i32, y: i32) void {
        const panel_y: i32 = @intCast(self.toolbar_height + 16);

        if (y >= panel_y + 40 and y <= panel_y + 55) {
            self.active_slider = .brightness;
            self.updateSliderFromMouse(x);
        } else if (y >= panel_y + 80 and y <= panel_y + 95) {
            self.active_slider = .contrast;
            self.updateSliderFromMouse(x);
        } else if (y >= panel_y + 120 and y <= panel_y + 135) {
            self.active_slider = .saturation;
            self.updateSliderFromMouse(x);
        } else if (y >= panel_y + 160 and y <= panel_y + 175) {
            self.active_slider = .blur;
            self.updateSliderFromMouse(x);
        } else if (y >= panel_y + 190 and y <= panel_y + 215) {
            self.adjustments.grayscale = !self.adjustments.grayscale;
            self.win.needs_redraw = true;
        } else if (y >= panel_y + 230 and y <= panel_y + 258) {
            self.show_adjustments = false;
            self.win.needs_redraw = true;
        }
    }

    fn updateSliderFromMouse(self: *AnnotateApp, x: i32) void {
        const panel_x: i32 = @as(i32, @intCast(self.win.width)) - @as(i32, @intCast(self.adjust_panel_width));
        const sx = panel_x + 16;
        const sw: f32 = 208.0;
        const frac = std.math.clamp((@as(f32, @floatFromInt(x)) - @as(f32, @floatFromInt(sx))) / sw, 0.0, 1.0);

        if (self.active_slider) |s| {
            switch (s) {
                .brightness => self.adjustments.brightness = (frac - 0.5) * 2.0,
                .contrast => self.adjustments.contrast = frac * 2.0,
                .saturation => self.adjustments.saturation = frac * 2.0,
                .blur => self.adjustments.blur = @intFromFloat(frac * 16.0),
            }
            self.win.needs_redraw = true;
        }
    }

    fn handleStatusbarClick(self: *AnnotateApp, x: i32, y: i32) void {
        _ = y;
        if (self.is_crop_mode) {
            if (x >= 300 and x < 390) {
                self.commitCrop() catch {};
                return;
            } else if (x >= 400 and x < 470) {
                self.cancelCrop();
                return;
            }
        }

        const right_base: i32 = @as(i32, @intCast(self.win.width)) - 140;
        if (x >= right_base and x < right_base + 30) {
            self.zoom = std.math.clamp(self.zoom * 0.85, 0.1, 10.0);
            self.win.needs_redraw = true;
        } else if (x >= right_base + 32 and x < right_base + 72) {
            self.fitToWindow();
        } else if (x >= right_base + 74 and x < right_base + 104) {
            self.zoom = std.math.clamp(self.zoom * 1.15, 0.1, 10.0);
            self.win.needs_redraw = true;
        }
    }

    // ==========================================
    // Rendering
    // ==========================================

    pub fn render(self: *AnnotateApp) !void {
        var r = try self.win.getRenderer();
        const th = self.cfg.theme;

        r.clear(th.base);

        // Canvas Area
        const c_rect = self.canvasRect();
        var canvas_renderer = r.withClip(c_rect);

        // Render Base Image
        const dest_x = self.pan_x;
        const dest_y = self.pan_y;
        const dest_w = @as(f64, @floatFromInt(self.base_image.img.width)) * @as(f64, self.zoom);
        const dest_h = @as(f64, @floatFromInt(self.base_image.img.height)) * @as(f64, self.zoom);

        // Soft drop shadow behind canvas
        canvas_renderer.drawSoftShadow(
            @intFromFloat(dest_x),
            @intFromFloat(dest_y),
            @intFromFloat(dest_w),
            @intFromFloat(dest_h),
            8,
            16,
            4,
            th.shadow_dark,
        );

        const r_img = renderer.Image{
            .width = self.base_image.img.width,
            .height = self.base_image.img.height,
            .pixels = self.base_image.img.pixels,
            .allocator = self.allocator,
        };
        canvas_renderer.drawImage(&r_img, dest_x, dest_y, dest_w, dest_h);

        canvas_renderer.drawRoundedBorder(
            @intFromFloat(dest_x),
            @intFromFloat(dest_y),
            @intFromFloat(dest_w),
            @intFromFloat(dest_h),
            2,
            1,
            th.border,
        );

        // Render Vector Annotations in z-order
        for (self.annotations.items) |*ann| {
            if (!ann.visible) continue;
            self.renderAnnotationOnCanvas(canvas_renderer, ann);
        }

        // Render Active Drawing Preview
        if (self.is_drawing and self.active_tool != .freehand) {
            self.renderDrawingPreview(canvas_renderer);
        }

        // Render Crop Overlay
        if (self.is_crop_mode) {
            self.renderCropOverlay(canvas_renderer);
        }

        // Render Marquee Selection Box
        if (self.is_marquee) {
            const mx0 = self.imageToScreenX(self.drag_start_x);
            const my0 = self.imageToScreenY(self.drag_start_y);
            const mx1 = self.imageToScreenX(self.drag_curr_x);
            const my1 = self.imageToScreenY(self.drag_curr_y);
            const rx = @min(mx0, mx1);
            const ry = @min(my0, my1);
            const rw: u32 = @intCast(@abs(mx1 - mx0));
            const rh: u32 = @intCast(@abs(my1 - my0));
            canvas_renderer.fillRect(rx, ry, rw, rh, Color.init(35, 97, 175, 239));
            canvas_renderer.drawRoundedBorder(rx, ry, rw, rh, 0, 1, th.accent);
        }

        // Render Selection Bounding Box & Handles
        self.renderSelectionHandles(canvas_renderer);

        // Render Inline Text Editor
        if (self.editing_text_id) |tid| {
            if (self.findAnnotationById(tid)) |ann| {
                const sx = self.imageToScreenX(ann.rect.x);
                const sy = self.imageToScreenY(ann.rect.y);
                const slice = ann.text_buf[0..ann.text_len];
                const text_w = r.measureTextWithSize(self.font, slice, ann.font_size);

                canvas_renderer.fillRoundedRect(sx - 4, sy - 4, @intCast(@max(40, text_w + 20)), @intCast(ann.font_size + 12), 4, Color.init(200, 24, 24, 37));
                canvas_renderer.drawRoundedBorder(sx - 4, sy - 4, @intCast(@max(40, text_w + 20)), @intCast(ann.font_size + 12), 4, 1, th.accent);
                canvas_renderer.drawTextWithSize(self.font, slice, sx, sy + @as(i32, @intCast(ann.font_size)), ann.font_size, ann.color);
                // Blinking cursor
                canvas_renderer.fillRect(sx + @as(i32, @intCast(text_w)) + 2, sy + 2, 2, ann.font_size, th.accent);
            }
        }

        // Render Side Panels
        if (self.show_layers) {
            self.renderLayersPanel(r);
        } else if (self.show_adjustments) {
            self.renderAdjustPanel(r);
        }

        // Render Toolbar & Statusbar on top
        self.renderToolbar(r);
        self.renderStatusbar(r);

        if (self.status_ticks > 0) {
            self.status_ticks -= 1;
            if (self.status_ticks == 0) self.status_len = 0;
        }
    }

    fn renderAnnotationOnCanvas(self: *AnnotateApp, r: renderer.Renderer, ann: *const Annotation) void {
        const th = self.cfg.theme;
        const scaled_sw = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(ann.stroke_width)) * self.zoom)));

        switch (ann.kind) {
            .arrow => {
                const sx0 = self.imageToScreenX(ann.start_x);
                const sy0 = self.imageToScreenY(ann.start_y);
                const sx1 = self.imageToScreenX(ann.end_x);
                const sy1 = self.imageToScreenY(ann.end_y);
                r.drawArrow(sx0, sy0, sx1, sy1, scaled_sw, ann.color);
            },
            .line => {
                const sx0 = self.imageToScreenX(ann.start_x);
                const sy0 = self.imageToScreenY(ann.start_y);
                const sx1 = self.imageToScreenX(ann.end_x);
                const sy1 = self.imageToScreenY(ann.end_y);
                r.drawStrokeLine(sx0, sy0, sx1, sy1, scaled_sw, ann.color);
            },
            .rect => {
                const b = ann.getBounds();
                const sx = self.imageToScreenX(b.x);
                const sy = self.imageToScreenY(b.y);
                const sw: u32 = @intFromFloat(@as(f32, @floatFromInt(b.w)) * self.zoom);
                const sh: u32 = @intFromFloat(@as(f32, @floatFromInt(b.h)) * self.zoom);
                if (ann.filled) {
                    r.fillRoundedRect(sx, sy, sw, sh, 4, ann.color);
                } else {
                    r.drawRoundedBorder(sx, sy, sw, sh, 4, scaled_sw, ann.color);
                }
            },
            .circle => {
                const b = ann.getBounds();
                const sx = self.imageToScreenX(b.x);
                const sy = self.imageToScreenY(b.y);
                const sw: f64 = @as(f64, @floatFromInt(b.w)) * @as(f64, self.zoom);
                const sh: f64 = @as(f64, @floatFromInt(b.h)) * @as(f64, self.zoom);
                const cx = @as(f64, @floatFromInt(sx)) + sw / 2.0;
                const cy = @as(f64, @floatFromInt(sy)) + sh / 2.0;
                const rad = @min(sw, sh) / 2.0;
                if (ann.filled) {
                    r.fillCircle(cx, cy, rad, ann.color);
                } else {
                    r.drawCircleBorder(cx, cy, rad, @floatFromInt(scaled_sw), ann.color);
                }
            },
            .highlight => {
                const b = ann.getBounds();
                const sx = self.imageToScreenX(b.x);
                const sy = self.imageToScreenY(b.y);
                const sw: u32 = @intFromFloat(@as(f32, @floatFromInt(b.w)) * self.zoom);
                const sh: u32 = @intFromFloat(@as(f32, @floatFromInt(b.h)) * self.zoom);
                r.fillRect(sx, sy, sw, sh, Color.init(100, ann.color.r, ann.color.g, ann.color.b));
            },
            .blur => {
                const b = ann.getBounds();
                const sx = self.imageToScreenX(b.x);
                const sy = self.imageToScreenY(b.y);
                const sw: u32 = @intFromFloat(@as(f32, @floatFromInt(b.w)) * self.zoom);
                const sh: u32 = @intFromFloat(@as(f32, @floatFromInt(b.h)) * self.zoom);
                // Frosted blur mask representation on canvas
                r.fillRect(sx, sy, sw, sh, Color.init(170, 180, 185, 200));
                r.drawRoundedBorder(sx, sy, sw, sh, 0, 1, Color.init(120, 255, 255, 255));
                r.drawTextWithSize(self.font, "󰈈 Blur", sx + 6, sy + 16, 11, th.surface);
            },
            .pixelate => {
                const b = ann.getBounds();
                const sx = self.imageToScreenX(b.x);
                const sy = self.imageToScreenY(b.y);
                const sw: u32 = @intFromFloat(@as(f32, @floatFromInt(b.w)) * self.zoom);
                const sh: u32 = @intFromFloat(@as(f32, @floatFromInt(b.h)) * self.zoom);
                r.fillRect(sx, sy, sw, sh, Color.init(210, 40, 44, 52));
                r.drawRoundedBorder(sx, sy, sw, sh, 0, 1, th.accent);
                r.drawTextWithSize(self.font, "󰹑 Pixelate", sx + 6, sy + 16, 11, Color.rgb(255, 255, 255));
            },
            .step_badge => {
                const sx = self.imageToScreenX(ann.rect.x);
                const sy = self.imageToScreenY(ann.rect.y);
                const rad: f64 = 16.0 * @as(f64, self.zoom);
                r.fillCircle(@floatFromInt(sx), @floatFromInt(sy), rad, ann.color);
                r.drawCircleBorder(@floatFromInt(sx), @floatFromInt(sy), rad, 1.5, Color.rgb(255, 255, 255));

                var num_buf: [16]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{ann.step_number}) catch "1";
                const nw = r.measureTextWithSize(self.font, num_str, 12);
                r.drawTextWithSize(self.font, num_str, sx - @divTrunc(@as(i32, @intCast(nw)), 2), sy + 4, 12, Color.rgb(255, 255, 255));
            },
            .text => {
                if (self.editing_text_id == ann.id) return; // Drawn in inline editor
                const sx = self.imageToScreenX(ann.rect.x);
                const sy = self.imageToScreenY(ann.rect.y);
                const slice = ann.text_buf[0..ann.text_len];
                const sz: u32 = @intFromFloat(@as(f32, @floatFromInt(ann.font_size)) * self.zoom);
                r.drawTextWithSize(self.font, slice, sx, sy + @as(i32, @intCast(sz)), sz, ann.color);
            },
            .pen => {
                if (ann.points.items.len < 2) return;
                var i: usize = 0;
                while (i + 1 < ann.points.items.len) : (i += 1) {
                    const sx0 = self.imageToScreenX(ann.points.items[i].x);
                    const sy0 = self.imageToScreenY(ann.points.items[i].y);
                    const sx1 = self.imageToScreenX(ann.points.items[i + 1].x);
                    const sy1 = self.imageToScreenY(ann.points.items[i + 1].y);
                    r.drawStrokeLine(sx0, sy0, sx1, sy1, scaled_sw, ann.color);
                }
            },
        }
    }

    fn renderDrawingPreview(self: *AnnotateApp, r: renderer.Renderer) void {
        const sx0 = self.imageToScreenX(self.drag_start_x);
        const sy0 = self.imageToScreenY(self.drag_start_y);
        const sx1 = self.imageToScreenX(self.drag_curr_x);
        const sy1 = self.imageToScreenY(self.drag_curr_y);
        const scaled_sw = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(self.stroke_width)) * self.zoom)));

        switch (self.active_tool) {
            .arrow => r.drawArrow(sx0, sy0, sx1, sy1, scaled_sw, self.current_color),
            .line => r.drawStrokeLine(sx0, sy0, sx1, sy1, scaled_sw, self.current_color),
            .rect => {
                const rx = @min(sx0, sx1);
                const ry = @min(sy0, sy1);
                const rw: u32 = @intCast(@abs(sx1 - sx0));
                const rh: u32 = @intCast(@abs(sy1 - sy0));
                if (self.fill_shape) {
                    r.fillRoundedRect(rx, ry, rw, rh, 4, self.current_color);
                } else {
                    r.drawRoundedBorder(rx, ry, rw, rh, 4, scaled_sw, self.current_color);
                }
            },
            .circle => {
                const rx = @min(sx0, sx1);
                const ry = @min(sy0, sy1);
                const rw: f64 = @floatFromInt(@as(u32, @intCast(@abs(sx1 - sx0))));
                const rh: f64 = @floatFromInt(@as(u32, @intCast(@abs(sy1 - sy0))));
                const cx = @as(f64, @floatFromInt(rx)) + rw / 2.0;
                const cy = @as(f64, @floatFromInt(ry)) + rh / 2.0;
                const rad = @min(rw, rh) / 2.0;
                if (self.fill_shape) {
                    r.fillCircle(cx, cy, rad, self.current_color);
                } else {
                    r.drawCircleBorder(cx, cy, rad, @floatFromInt(scaled_sw), self.current_color);
                }
            },
            .highlight => {
                const rx = @min(sx0, sx1);
                const ry = @min(sy0, sy1);
                const rw: u32 = @intCast(@abs(sx1 - sx0));
                const rh: u32 = @intCast(@abs(sy1 - sy0));
                r.fillRect(rx, ry, rw, rh, Color.init(100, self.current_color.r, self.current_color.g, self.current_color.b));
            },
            .blur, .pixelate => {
                const rx = @min(sx0, sx1);
                const ry = @min(sy0, sy1);
                const rw: u32 = @intCast(@abs(sx1 - sx0));
                const rh: u32 = @intCast(@abs(sy1 - sy0));
                r.drawRoundedBorder(rx, ry, rw, rh, 0, 1, self.cfg.theme.accent);
            },
            else => {},
        }
    }

    fn renderSelectionHandles(self: *AnnotateApp, r: renderer.Renderer) void {
        const th = self.cfg.theme;

        // If exactly 1 arrow or line is selected, draw start and end circle handles
        if (self.selected_ids.items.len == 1) {
            const sid = self.selected_ids.items[0];
            for (self.annotations.items) |ann| {
                if (ann.id == sid and (ann.kind == .arrow or ann.kind == .line)) {
                    const s_sx = self.imageToScreenX(ann.start_x);
                    const s_sy = self.imageToScreenY(ann.start_y);
                    const e_sx = self.imageToScreenX(ann.end_x);
                    const e_sy = self.imageToScreenY(ann.end_y);

                    // Start handle: White circle with accent border
                    r.fillCircle(@floatFromInt(s_sx), @floatFromInt(s_sy), 6, Color.rgb(255, 255, 255));
                    r.drawCircleBorder(@floatFromInt(s_sx), @floatFromInt(s_sy), 6, 2, th.accent);

                    // End handle
                    r.fillCircle(@floatFromInt(e_sx), @floatFromInt(e_sy), 6, Color.rgb(255, 255, 255));
                    r.drawCircleBorder(@floatFromInt(e_sx), @floatFromInt(e_sy), 6, 2, th.accent);
                    return;
                }
            }
        }

        const maybe_bounds = self.getCombinedSelectionBounds() orelse return;
        const b = maybe_bounds;

        const x0 = self.imageToScreenX(b.x);
        const y0 = self.imageToScreenY(b.y);
        const x1 = self.imageToScreenX(b.x + @as(i32, @intCast(b.w)));
        const y1 = self.imageToScreenY(b.y + @as(i32, @intCast(b.h)));
        const w: u32 = @intCast(@max(4, x1 - x0));
        const h: u32 = @intCast(@max(4, y1 - y0));

        // Outer bounding box outline with accent glow
        r.drawRoundedBorder(x0 - 2, y0 - 2, w + 4, h + 4, 2, 1, th.accent);

        // 8 Tensaku-style handles: White rounded squares with accent border
        const x_mid = @divTrunc(x0 + x1, 2);
        const y_mid = @divTrunc(y0 + y1, 2);

        const handle_coords = [_]struct { x: i32, y: i32 }{
            .{ .x = x0, .y = y0 },
            .{ .x = x_mid, .y = y0 },
            .{ .x = x1, .y = y0 },
            .{ .x = x1, .y = y_mid },
            .{ .x = x1, .y = y1 },
            .{ .x = x_mid, .y = y1 },
            .{ .x = x0, .y = y1 },
            .{ .x = x0, .y = y_mid },
        };

        for (handle_coords) |pt| {
            r.fillRoundedRect(pt.x - 4, pt.y - 4, 8, 8, 2, Color.rgb(255, 255, 255));
            r.drawRoundedBorder(pt.x - 4, pt.y - 4, 8, 8, 2, 1, th.accent);
        }
    }

    fn renderCropOverlay(self: *AnnotateApp, r: renderer.Renderer) void {
        const th = self.cfg.theme;
        const ix0 = @min(self.crop_x0, self.crop_x1);
        const iy0 = @min(self.crop_y0, self.crop_y1);
        const ix1 = @max(self.crop_x0, self.crop_x1);
        const iy1 = @max(self.crop_y0, self.crop_y1);

        const sx0 = self.imageToScreenX(ix0);
        const sy0 = self.imageToScreenY(iy0);
        const sx1 = self.imageToScreenX(ix1);
        const sy1 = self.imageToScreenY(iy1);

        const dim_col = Color.init(150, 0, 0, 0);

        r.fillRect(0, 0, self.win.width, @intCast(@max(0, sy0)), dim_col);
        r.fillRect(0, sy1, self.win.width, @intCast(@max(0, @as(i32, @intCast(self.win.height)) - sy1)), dim_col);
        r.fillRect(0, sy0, @intCast(@max(0, sx0)), @intCast(@max(0, sy1 - sy0)), dim_col);
        r.fillRect(sx1, sy0, @intCast(@max(0, @as(i32, @intCast(self.win.width)) - sx1)), @intCast(@max(0, sy1 - sy0)), dim_col);

        const cw: u32 = @intCast(@max(0, sx1 - sx0));
        const ch: u32 = @intCast(@max(0, sy1 - sy0));
        if (cw > 0 and ch > 0) {
            r.drawRoundedBorder(sx0, sy0, cw, ch, 0, 2, th.accent);

            var dim_buf: [48]u8 = undefined;
            const crop_w_px = @as(u32, @intCast(@abs(ix1 - ix0)));
            const crop_h_px = @as(u32, @intCast(@abs(iy1 - iy0)));
            const dim_txt = std.fmt.bufPrint(&dim_buf, "{d}×{d} px", .{ crop_w_px, crop_h_px }) catch "";
            r.fillRoundedRect(sx0 + 6, sy0 + 6, 88, 20, 4, Color.init(190, 0, 0, 0));
            r.drawTextWithSize(self.font, dim_txt, sx0 + 10, sy0 + 19, 10, Color.rgb(255, 255, 255));
        }
    }

    fn renderToolbar(self: *AnnotateApp, r: renderer.Renderer) void {
        const th = self.cfg.theme;
        const w = self.win.width;
        const h = self.toolbar_height;

        r.fillRect(0, 0, w, h, th.surface);
        r.fillRect(0, @intCast(h - 1), w, 1, th.glass_border);

        // Logo
        r.drawTextWithSize(self.font, "󰆉 Mizu", 14, 29, 14, th.accent);

        const btn_y: i32 = 8;
        const btn_h: i32 = 32;
        var bx: i32 = 80;
        const btn_w: i32 = 28;

        // Tool buttons with Nerd Font icons
        const tools = [_]Tool{ .select, .freehand, .arrow, .line, .rect, .circle, .text, .step_badge, .highlight, .blur, .pixelate };
        for (tools) |t| {
            const active = (self.active_tool == t);
            const bg = if (active) th.accent else th.btn_raised_bg;
            const fg = if (active) th.accent_fg else th.text_main;

            r.fillRoundedRect(bx, btn_y, @intCast(btn_w), @intCast(btn_h), 6, bg);
            r.drawRoundedBorder(bx, btn_y, @intCast(btn_w), @intCast(btn_h), 6, 1, if (active) th.accent else th.glass_border);

            r.drawIconCentered(self.font, t.icon(), bx + @divTrunc(btn_w, 2), btn_y + 21, 14, fg);
            bx += btn_w + 3;
        }

        // Separator
        bx += 6;
        r.fillRect(bx, 13, 1, 22, th.glass_border);
        bx += 8;

        // Stroke widths: 2, 4, 8, 16
        const widths = [_]u32{ 2, 4, 8, 16 };
        for (widths) |sw| {
            const active = (self.stroke_width == sw);
            r.fillRoundedRect(bx, btn_y, 22, @intCast(btn_h), 6, if (active) th.accent else th.btn_raised_bg);
            r.drawRoundedBorder(bx, btn_y, 22, @intCast(btn_h), 6, 1, if (active) th.accent else th.glass_border);

            var buf: [8]u8 = undefined;
            const label = std.fmt.bufPrint(&buf, "{d}", .{sw}) catch "4";
            const lw = r.measureTextWithSize(self.font, label, 10);
            const lx = bx + @divTrunc(22 - @as(i32, @intCast(lw)), 2);
            r.drawTextWithSize(self.font, label, lx, btn_y + 20, 10, if (active) th.accent_fg else th.text_main);
            bx += 24;
        }

        // Font size decrease (󰧳)
        {
            r.fillRoundedRect(bx, btn_y, 26, @intCast(btn_h), 6, th.btn_raised_bg);
            r.drawRoundedBorder(bx, btn_y, 26, @intCast(btn_h), 6, 1, th.glass_border);
            r.drawIconCentered(self.font, "󰧳", bx + 13, btn_y + 21, 14, th.text_main);
            bx += 28;
        }

        // Font size increase (󰧴)
        {
            r.fillRoundedRect(bx, btn_y, 26, @intCast(btn_h), 6, th.btn_raised_bg);
            r.drawRoundedBorder(bx, btn_y, 26, @intCast(btn_h), 6, 1, th.glass_border);
            r.drawIconCentered(self.font, "󰧴", bx + 13, btn_y + 21, 14, th.text_main);
            bx += 28;
        }

        // Separator
        bx += 6;
        r.fillRect(bx, 13, 1, 22, th.glass_border);
        bx += 8;

        // Color palette swatches
        for (Palette.colors) |col| {
            const active = (self.current_color.toArgb() == col.toArgb());
            r.fillCircle(@floatFromInt(bx + 8), @floatFromInt(btn_y + 16), 7, col);
            if (active) {
                r.drawCircleBorder(@floatFromInt(bx + 8), @floatFromInt(btn_y + 16), 9, 2, th.accent);
            }
            bx += 18;
        }

        // Separator
        bx += 6;
        r.fillRect(bx, 13, 1, 22, th.glass_border);
        bx += 8;

        // Fill toggle ()
        {
            r.fillRoundedRect(bx, btn_y, 30, @intCast(btn_h), 6, if (self.fill_shape) th.accent else th.btn_raised_bg);
            r.drawRoundedBorder(bx, btn_y, 30, @intCast(btn_h), 6, 1, if (self.fill_shape) th.accent else th.glass_border);
            r.drawIconCentered(self.font, "", bx + 15, btn_y + 21, 14, if (self.fill_shape) th.accent_fg else th.text_main);
            bx += 34;
        }

        // Crop Tool button ()
        {
            r.fillRoundedRect(bx, btn_y, 30, @intCast(btn_h), 6, if (self.is_crop_mode) th.accent else th.btn_raised_bg);
            r.drawRoundedBorder(bx, btn_y, 30, @intCast(btn_h), 6, 1, if (self.is_crop_mode) th.accent else th.glass_border);
            r.drawIconCentered(self.font, "", bx + 15, btn_y + 21, 14, if (self.is_crop_mode) th.accent_fg else th.text_main);
            bx += 34;
        }

        // Rotate 90* left button (󰚪)
        {
            r.fillRoundedRect(bx, btn_y, 30, @intCast(btn_h), 6, th.btn_raised_bg);
            r.drawRoundedBorder(bx, btn_y, 30, @intCast(btn_h), 6, 1, th.glass_border);
            r.drawIconCentered(self.font, "󰚪", bx + 15, btn_y + 21, 14, th.text_main);
            bx += 34;
        }

        // Layers Panel Toggle button ()
        {
            r.fillRoundedRect(bx, btn_y, 30, @intCast(btn_h), 6, if (self.show_layers) th.accent else th.btn_raised_bg);
            r.drawRoundedBorder(bx, btn_y, 30, @intCast(btn_h), 6, 1, if (self.show_layers) th.accent else th.glass_border);
            r.drawIconCentered(self.font, "", bx + 15, btn_y + 21, 14, if (self.show_layers) th.accent_fg else th.text_main);
            bx += 34;
        }

        // Right-aligned Global Actions: Undo, Redo, Screenshot, Save, Copy
        {
            var rx = @as(i32, @intCast(w)) - 180;

            // Undo ()
            r.fillRoundedRect(rx, btn_y, 30, @intCast(btn_h), 6, th.btn_raised_bg);
            r.drawRoundedBorder(rx, btn_y, 30, @intCast(btn_h), 6, 1, th.glass_border);
            r.drawIconCentered(self.font, "", rx + 15, btn_y + 21, 14, if (self.undo_mgr.canUndo()) th.text_main else th.text_muted);
            rx += 34;

            // Redo ()
            r.fillRoundedRect(rx, btn_y, 30, @intCast(btn_h), 6, th.btn_raised_bg);
            r.drawRoundedBorder(rx, btn_y, 30, @intCast(btn_h), 6, 1, th.glass_border);
            r.drawIconCentered(self.font, "", rx + 15, btn_y + 21, 14, if (self.undo_mgr.canRedo()) th.text_main else th.text_muted);
            rx += 34;

            // Capture (󰄀)
            r.fillRoundedRect(rx, btn_y, 30, @intCast(btn_h), 6, th.btn_raised_bg);
            r.drawRoundedBorder(rx, btn_y, 30, @intCast(btn_h), 6, 1, th.glass_border);
            r.drawIconCentered(self.font, "󰄀", rx + 15, btn_y + 21, 14, th.text_main);
            rx += 34;

            // Save (󰆓)
            r.fillRoundedRect(rx, btn_y, 30, @intCast(btn_h), 6, th.btn_raised_bg);
            r.drawRoundedBorder(rx, btn_y, 30, @intCast(btn_h), 6, 1, th.glass_border);
            r.drawIconCentered(self.font, "󰆓", rx + 15, btn_y + 21, 14, th.text_main);
            rx += 34;

            // Copy (󰆏)
            r.fillRoundedRect(rx, btn_y, 30, @intCast(btn_h), 6, th.accent);
            r.drawRoundedBorder(rx, btn_y, 30, @intCast(btn_h), 6, 1, th.accent);
            r.drawIconCentered(self.font, "󰆏", rx + 15, btn_y + 21, 14, th.accent_fg);
        }
    }

    fn renderLayersPanel(self: *AnnotateApp, r: renderer.Renderer) void {
        const th = self.cfg.theme;
        const panel_w = self.layers_panel_width;
        const panel_x: i32 = @as(i32, @intCast(self.win.width)) - @as(i32, @intCast(panel_w));
        const panel_y: i32 = @intCast(self.toolbar_height);
        const panel_h: u32 = if (self.win.height > self.toolbar_height + self.statusbar_height)
            self.win.height - self.toolbar_height - self.statusbar_height
        else
            0;

        r.fillRect(panel_x, panel_y, panel_w, panel_h, th.surface);
        r.fillRect(panel_x, panel_y, 1, panel_h, th.glass_border);

        // Header
        var h_buf: [48]u8 = undefined;
        const header_txt = std.fmt.bufPrint(&h_buf, "Layers ({d})", .{self.annotations.items.len}) catch "Layers";
        r.drawTextWithSize(self.font, header_txt, panel_x + 14, panel_y + 24, 13, th.accent);

        // Close button
        r.drawTextWithSize(self.font, "✕", panel_x + @as(i32, @intCast(panel_w)) - 22, panel_y + 24, 13, th.text_muted);

        r.fillRect(panel_x + 10, panel_y + 36, panel_w - 20, 1, th.glass_border);

        // Layers list (reverse order: top to bottom)
        var cur_y = panel_y + 44;
        const row_h: i32 = 32;
        const total = self.annotations.items.len;

        var i: usize = 0;
        while (i < total and cur_y + row_h < panel_y + @as(i32, @intCast(panel_h))) : (i += 1) {
            const ann_idx = total - 1 - i;
            const ann = &self.annotations.items[ann_idx];
            const sel = self.isSelected(ann.id);

            // Row background
            if (sel) {
                r.fillRoundedRect(panel_x + 6, cur_y, panel_w - 12, @intCast(row_h - 2), 4, Color.init(60, 97, 175, 239));
                r.fillRect(panel_x + 6, cur_y, 3, @intCast(row_h - 2), th.accent);
            }

            // Annotation Name / Label
            var name_buf: [64]u8 = undefined;
            const label = if (ann.kind == .text and ann.text_len > 0)
                std.fmt.bufPrint(&name_buf, "\"{s}\"", .{ann.text_buf[0..@min(ann.text_len, 14)]}) catch ann.kind.name()
            else if (ann.kind == .step_badge)
                std.fmt.bufPrint(&name_buf, "Step {d}", .{ann.step_number}) catch ann.kind.name()
            else
                ann.kind.name();

            r.drawTextWithSize(self.font, label, panel_x + 16, cur_y + 20, 11, if (sel) th.accent else th.text_main);

            // Visibility Eye Icon
            const eye_txt = if (ann.visible) "👁" else "󰈈";
            r.drawTextWithSize(self.font, eye_txt, panel_x + 132, cur_y + 20, 11, if (ann.visible) th.text_main else th.text_muted);

            // Lock Icon
            const lock_txt = if (ann.locked) "🔒" else "🔓";
            r.drawTextWithSize(self.font, lock_txt, panel_x + 154, cur_y + 20, 11, if (ann.locked) th.accent else th.text_muted);

            // Delete button
            r.drawTextWithSize(self.font, "✕", panel_x + 202, cur_y + 20, 11, th.text_muted);

            cur_y += row_h;
        }
    }

    fn renderAdjustPanel(self: *AnnotateApp, r: renderer.Renderer) void {
        const th = self.cfg.theme;
        const panel_w = self.adjust_panel_width;
        const panel_x: i32 = @as(i32, @intCast(self.win.width)) - @as(i32, @intCast(panel_w));
        const panel_y: i32 = @intCast(self.toolbar_height);
        const panel_h: u32 = if (self.win.height > self.toolbar_height + self.statusbar_height)
            self.win.height - self.toolbar_height - self.statusbar_height
        else
            0;

        r.fillRect(panel_x, panel_y, panel_w, panel_h, th.surface);
        r.fillRect(panel_x, panel_y, 1, panel_h, th.glass_border);

        var cur_y: i32 = panel_y + 20;
        r.drawTextWithSize(self.font, "Color Adjustments", panel_x + 16, cur_y + 4, 13, th.accent);
        cur_y += 30;

        // Brightness
        {
            var buf: [32]u8 = undefined;
            const pct: i32 = @intFromFloat(self.adjustments.brightness * 100.0);
            const val_txt = if (pct > 0)
                std.fmt.bufPrint(&buf, "Brightness: +{d}%", .{pct}) catch ""
            else
                std.fmt.bufPrint(&buf, "Brightness: {d}%", .{pct}) catch "";
            r.drawTextWithSize(self.font, val_txt, panel_x + 16, cur_y, 11, th.text_main);
            cur_y += 10;

            const slider_w: i32 = 208;
            r.fillRoundedRect(panel_x + 16, cur_y, @intCast(slider_w), 6, 3, th.btn_raised_bg);
            const frac = (self.adjustments.brightness / 2.0) + 0.5;
            const knob_x = panel_x + 16 + @as(i32, @intFromFloat(@as(f32, @floatFromInt(slider_w)) * frac));
            r.fillCircle(@floatFromInt(knob_x), @floatFromInt(cur_y + 3), 7, th.accent);
            cur_y += 30;
        }

        // Contrast
        {
            var buf: [32]u8 = undefined;
            const val_txt = std.fmt.bufPrint(&buf, "Contrast: {d:.2}x", .{self.adjustments.contrast}) catch "";
            r.drawTextWithSize(self.font, val_txt, panel_x + 16, cur_y, 11, th.text_main);
            cur_y += 10;

            const slider_w: i32 = 208;
            r.fillRoundedRect(panel_x + 16, cur_y, @intCast(slider_w), 6, 3, th.btn_raised_bg);
            const frac = self.adjustments.contrast / 2.0;
            const knob_x = panel_x + 16 + @as(i32, @intFromFloat(@as(f32, @floatFromInt(slider_w)) * frac));
            r.fillCircle(@floatFromInt(knob_x), @floatFromInt(cur_y + 3), 7, th.accent);
            cur_y += 30;
        }

        // Saturation
        {
            var buf: [32]u8 = undefined;
            const val_txt = std.fmt.bufPrint(&buf, "Saturation: {d:.2}x", .{self.adjustments.saturation}) catch "";
            r.drawTextWithSize(self.font, val_txt, panel_x + 16, cur_y, 11, th.text_main);
            cur_y += 10;

            const slider_w: i32 = 208;
            r.fillRoundedRect(panel_x + 16, cur_y, @intCast(slider_w), 6, 3, th.btn_raised_bg);
            const frac = self.adjustments.saturation / 2.0;
            const knob_x = panel_x + 16 + @as(i32, @intFromFloat(@as(f32, @floatFromInt(slider_w)) * frac));
            r.fillCircle(@floatFromInt(knob_x), @floatFromInt(cur_y + 3), 7, th.accent);
            cur_y += 30;
        }

        // Grayscale toggle
        {
            r.fillRoundedRect(panel_x + 16, cur_y, 208, 26, 4, if (self.adjustments.grayscale) th.accent else th.btn_raised_bg);
            r.drawRoundedBorder(panel_x + 16, cur_y, 208, 26, 4, 1, th.glass_border);
            const g_txt = if (self.adjustments.grayscale) "✓ Grayscale Enabled" else "Enable Grayscale";
            r.drawTextWithSize(self.font, g_txt, panel_x + 50, cur_y + 17, 11, if (self.adjustments.grayscale) th.accent_fg else th.text_main);
            cur_y += 38;
        }

        // Close
        r.fillRoundedRect(panel_x + 16, cur_y, 208, 28, 6, th.accent);
        r.drawTextWithSize(self.font, "Close Panel", panel_x + 76, cur_y + 18, 11, th.accent_fg);
    }

    fn renderStatusbar(self: *AnnotateApp, r: renderer.Renderer) void {
        const th = self.cfg.theme;
        const w = self.win.width;
        const h = self.statusbar_height;
        const y: i32 = @intCast(self.win.height - h);

        r.fillRect(0, y, w, h, th.surface);
        r.fillRect(0, y, w, 1, th.glass_border);

        var info_buf: [160]u8 = undefined;
        const info = if (self.is_crop_mode)
            "Mode: Crop  •  Drag area  •  Enter: Apply  •  Esc: Cancel"
        else if (self.selected_ids.items.len > 0)
            std.fmt.bufPrint(
                &info_buf,
                "Selected: {d} item(s)  |  Size: {d}×{d} px  |  Del: Delete  •  Ctrl+D: Duplicate  •  Arrows: Nudge",
                .{ self.selected_ids.items.len, self.base_image.img.width, self.base_image.img.height },
            ) catch ""
        else
            std.fmt.bufPrint(
                &info_buf,
                "Tool: {s} ({s})  |  Size: {d}×{d} px  |  V: Select • P: Pen • A: Arrow • T: Text • N: Step • Ctrl+L: Layers",
                .{ self.active_tool.name(), self.active_tool.shortcut(), self.base_image.img.width, self.base_image.img.height },
            ) catch "";

        r.drawTextWithSize(self.font, info, 14, y + 18, 11, if (self.is_crop_mode or self.selected_ids.items.len > 0) th.accent else th.text_muted);

        if (self.is_crop_mode) {
            r.fillRoundedRect(320, y + 3, 90, 22, 4, th.accent);
            r.drawTextWithSize(self.font, "Apply Crop", 334, y + 17, 11, th.accent_fg);

            r.fillRoundedRect(420, y + 3, 70, 22, 4, th.btn_raised_bg);
            r.drawRoundedBorder(420, y + 3, 70, 22, 4, 1, th.glass_border);
            r.drawTextWithSize(self.font, "Cancel", 436, y + 17, 11, th.text_main);
        }

        // Notification Message
        if (self.status_ticks > 0 and self.status_len > 0) {
            const msg = self.status_msg[0..self.status_len];
            const mw = r.measureTextWithSize(self.font, msg, 11);
            const mx = @divTrunc(@as(i32, @intCast(w)) - @as(i32, @intCast(mw)), 2);
            r.drawTextWithSize(self.font, msg, mx, y + 18, 11, th.success_color);
        }

        // Zoom Controls
        const right_base: i32 = @as(i32, @intCast(w)) - 140;
        r.fillRoundedRect(right_base, y + 4, 26, 20, 4, th.btn_raised_bg);
        r.drawTextWithSize(self.font, "-", right_base + 9, y + 17, 12, th.text_main);

        r.fillRoundedRect(right_base + 30, y + 4, 38, 20, 4, th.btn_raised_bg);
        var zoom_buf: [16]u8 = undefined;
        const zoom_txt = std.fmt.bufPrint(&zoom_buf, "{d}%", .{@as(u32, @intFromFloat(self.zoom * 100.0))}) catch "100%";
        r.drawTextWithSize(self.font, zoom_txt, right_base + 35, y + 17, 10, th.text_main);

        r.fillRoundedRect(right_base + 72, y + 4, 26, 20, 4, th.btn_raised_bg);
        r.drawTextWithSize(self.font, "+", right_base + 8, y + 17, 12, th.text_main);
    }
};

// ==========================================
// Main Application Event Loop & Stdin Pipe Support
// ==========================================

pub fn readAllFromStdin(allocator: std.mem.Allocator) ![]u8 {
    var list = std.ArrayListUnmanaged(u8).empty;
    errdefer list.deinit(allocator);

    var buf: [65536]u8 = undefined;
    while (true) {
        const rc = c.read(0, &buf, buf.len);
        if (rc < 0) {
            const err = std.posix.errno(rc);
            if (err == .INTR) continue;
            return error.ReadFailed;
        }
        if (rc == 0) break; // EOF
        try list.appendSlice(allocator, buf[0..@intCast(rc)]);
    }
    return list.toOwnedSlice(allocator);
}

pub fn run(allocator: std.mem.Allocator, cfg: config.Config, file_to_open: ?[]const u8, screenshot_mode: bool) !u8 {
    var initial_image: ?ImageBuffer = null;
    const is_stdin = if (file_to_open) |f| std.mem.eql(u8, f, "-") else (c.isatty(0) == 0);

    if (screenshot_mode) {
        initial_image = try ImageBuffer.captureScreenshotRegion(allocator);
    } else if (is_stdin) {
        // Piped input (e.g. `grim -g "$(slurp)" - | mizu annotate` or `cat img.png | mizu annotate`).
        // Read stdin until EOF BEFORE creating the Wayland window so commands like slurp don't get obscured early!
        const stdin_bytes = readAllFromStdin(allocator) catch null;
        if (stdin_bytes) |bytes| {
            defer allocator.free(bytes);
            if (bytes.len > 0) {
                initial_image = ImageBuffer.loadFromMemory(allocator, bytes) catch null;
            }
        }
    } else if (file_to_open) |path| {
        initial_image = ImageBuffer.loadFromFile(allocator, path) catch null;
    }

    var app = try AnnotateApp.init(allocator, cfg, initial_image, if (is_stdin) null else file_to_open);
    defer app.deinit();

    const display_fd = c.wl_display_get_fd(app.win.display.?);

    var prev_px: i32 = -1;
    var prev_py: i32 = -1;
    var prev_pdown: bool = false;

    while (app.win.running) {
        while (c.wl_display_prepare_read(app.win.display.?) != 0) {
            _ = c.wl_display_dispatch_pending(app.win.display.?);
        }
        _ = c.wl_display_flush(app.win.display.?);

        var poll_fds = [_]c.struct_pollfd{
            .{ .fd = display_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (app.win.repeat_timer_fd >= 0) app.win.repeat_timer_fd else -1, .events = c.POLLIN, .revents = 0 },
        };

        const poll_res = c.poll(&poll_fds, 2, 50);
        if (poll_res < 0) {
            c.wl_display_cancel_read(app.win.display.?);
            break;
        }

        if (poll_fds[0].revents & (c.POLLHUP | c.POLLERR) != 0) {
            c.wl_display_cancel_read(app.win.display.?);
            break;
        }

        if (poll_res == 0) {
            c.wl_display_cancel_read(app.win.display.?);
        } else {
            if (poll_fds[0].revents & c.POLLIN != 0) {
                _ = c.wl_display_read_events(app.win.display.?);
            } else {
                c.wl_display_cancel_read(app.win.display.?);
            }
        }
        _ = c.wl_display_dispatch_pending(app.win.display.?);

        const cur_px = app.win.pointer_x;
        const cur_py = app.win.pointer_y;
        const cur_down = app.win.pointer_down;

        if (cur_px != prev_px or cur_py != prev_py) {
            app.handlePointerMotion(cur_px, cur_py);
            prev_px = cur_px;
            prev_py = cur_py;
        }

        if (cur_down != prev_pdown) {
            app.handlePointerButton(cur_px, cur_py, 0x110, cur_down);
            prev_pdown = cur_down;
        }

        if (app.win.repeat_sym != 0) {
            const sym = app.win.repeat_sym;
            const slice = app.win.repeat_utf8_buf[0..app.win.repeat_utf8_len];
            app.handleKey(sym, slice, app.win.is_ctrl, app.win.is_shift);
            app.win.repeat_sym = 0;
            app.win.repeat_utf8_len = 0;
        }

        if (app.win.needs_redraw and app.win.configured) {
            app.render() catch {};
            app.win.commitFrame();
        }
    }

    return 0;
}

test "Annotation basic properties and cloning" {
    const alloc = std.testing.allocator;
    var ann = Annotation{
        .id = 1,
        .kind = .rect,
        .rect = Rect{ .x = 10, .y = 20, .w = 100, .h = 80 },
        .color = Color.hex(0x61AFEF),
        .stroke_width = 4,
    };
    defer ann.deinit(alloc);

    try std.testing.expect(ann.hitTest(12, 22));
    try std.testing.expect(!ann.hitTest(200, 200));

    var clone = try ann.clone(alloc);
    defer clone.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 1), clone.id);
    try std.testing.expectEqual(ann.rect.w, clone.rect.w);

    clone.move(15, 10);
    try std.testing.expectEqual(@as(i32, 25), clone.rect.x);
    try std.testing.expectEqual(@as(i32, 30), clone.rect.y);
}

test "Annotation tools and icons" {
    try std.testing.expectEqualStrings("Select / Move", Tool.select.name());
    try std.testing.expectEqualStrings("V", Tool.select.shortcut());
    try std.testing.expectEqualStrings("Step Badge", Tool.step_badge.name());
    try std.testing.expectEqualStrings("N", Tool.step_badge.shortcut());
    try std.testing.expectEqualStrings("Arrow", AnnotationKind.arrow.name());
}

test "Arrow and line hit testing and bounds" {
    const alloc = std.testing.allocator;
    var arrow = Annotation{
        .id = 2,
        .kind = .arrow,
        .start_x = 50,
        .start_y = 50,
        .end_x = 150,
        .end_y = 50,
        .stroke_width = 4,
    };
    defer arrow.deinit(alloc);

    const b = arrow.getBounds();
    try std.testing.expect(b.x <= 50);
    try std.testing.expect(b.x + @as(i32, @intCast(b.w)) >= 150);

    // Hit test along the line segment
    try std.testing.expect(arrow.hitTest(100, 52));
    try std.testing.expect(arrow.hitTest(50, 50));
    try std.testing.expect(arrow.hitTest(150, 50));
    // Miss test far from segment
    try std.testing.expect(!arrow.hitTest(100, 100));

    // Move arrow
    arrow.move(10, -5);
    try std.testing.expectEqual(@as(i32, 60), arrow.start_x);
    try std.testing.expectEqual(@as(i32, 45), arrow.start_y);
    try std.testing.expectEqual(@as(i32, 160), arrow.end_x);
    try std.testing.expectEqual(@as(i32, 45), arrow.end_y);
}

test "Step badge hit testing and numbering" {
    const alloc = std.testing.allocator;
    var badge = Annotation{
        .id = 3,
        .kind = .step_badge,
        .rect = Rect{ .x = 100, .y = 100, .w = 32, .h = 32 },
        .step_number = 5,
        .color = Color.hex(0x61AFEF),
    };
    defer badge.deinit(alloc);

    try std.testing.expect(badge.hitTest(102, 104));
    try std.testing.expect(!badge.hitTest(150, 150));
    try std.testing.expectEqual(@as(u32, 5), badge.step_number);
}

test "Resize handle operations" {
    const alloc = std.testing.allocator;
    var rect_ann = Annotation{
        .id = 4,
        .kind = .rect,
        .rect = Rect{ .x = 100, .y = 100, .w = 80, .h = 60 },
        .stroke_width = 2,
    };
    defer rect_ann.deinit(alloc);

    // Resize via bottom_right handle
    rect_ann.resize(.bottom_right, 220, 190);
    const b = rect_ann.getBounds();
    try std.testing.expectEqual(@as(i32, 100), b.x);
    try std.testing.expectEqual(@as(i32, 100), b.y);
    try std.testing.expectEqual(@as(u32, 120), b.w);
    try std.testing.expectEqual(@as(u32, 90), b.h);

    // Resize via top_left handle
    rect_ann.resize(.top_left, 80, 70);
    const b2 = rect_ann.getBounds();
    try std.testing.expectEqual(@as(i32, 80), b2.x);
    try std.testing.expectEqual(@as(i32, 70), b2.y);
    try std.testing.expectEqual(@as(u32, 140), b2.w);
    try std.testing.expectEqual(@as(u32, 120), b2.h);
}

test "UndoManager push, undo and redo" {
    const alloc = std.testing.allocator;
    const base = try ImageBuffer.init(alloc, 100, 100, Color.rgb(255, 255, 255));
    const shared = try SharedImage.create(alloc, base);
    defer shared.release();

    var undo_mgr = UndoManager.init(alloc, 10);
    defer undo_mgr.deinit();

    var ann_list = std.ArrayListUnmanaged(Annotation).empty;
    defer {
        for (ann_list.items) |*a| a.deinit(alloc);
        ann_list.deinit(alloc);
    }

    try ann_list.append(alloc, Annotation{
        .id = 1,
        .kind = .rect,
        .rect = Rect{ .x = 10, .y = 10, .w = 40, .h = 40 },
    });

    try undo_mgr.pushState(ann_list.items, shared);
    try std.testing.expect(undo_mgr.canUndo());
    try std.testing.expect(!undo_mgr.canRedo());

    // Add another item
    try ann_list.append(alloc, Annotation{
        .id = 2,
        .kind = .circle,
        .rect = Rect{ .x = 50, .y = 50, .w = 30, .h = 30 },
    });
    try undo_mgr.pushState(ann_list.items, shared);
    try std.testing.expectEqual(@as(usize, 2), undo_mgr.undo_stack.items.len);
}

test "SharedImage refcount lifecycle and zero copy undo" {
    const alloc = std.testing.allocator;
    const base = try ImageBuffer.init(alloc, 64, 64, Color.rgb(20, 20, 20));
    const shared = try SharedImage.create(alloc, base);
    try std.testing.expectEqual(@as(usize, 1), shared.ref_count);

    _ = shared.retain();
    try std.testing.expectEqual(@as(usize, 2), shared.ref_count);

    shared.release();
    try std.testing.expectEqual(@as(usize, 1), shared.ref_count);

    shared.release(); // Frees buffer and struct cleanly without leaks
}

test "Nerd Font icons match user specification" {
    try std.testing.expectEqualStrings("󰆽", Tool.select.icon());
    try std.testing.expectEqualStrings("", Tool.freehand.icon());
    try std.testing.expectEqualStrings("", Tool.arrow.icon());
    try std.testing.expectEqualStrings("󰕞", Tool.line.icon());
    try std.testing.expectEqualStrings("󰹟", Tool.rect.icon());
    try std.testing.expectEqualStrings("", Tool.circle.icon());
    try std.testing.expectEqualStrings("󰊄", Tool.text.icon());
    try std.testing.expectEqualStrings("󰲠", Tool.step_badge.icon());
    try std.testing.expectEqualStrings("", Tool.highlight.icon());
    try std.testing.expectEqualStrings("󰂶", Tool.blur.icon());
    try std.testing.expectEqualStrings("", Tool.pixelate.icon());
    try std.testing.expectEqualStrings("", Tool.crop.icon());
}

