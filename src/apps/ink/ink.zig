const std = @import("std");
const c = @import("c");
const buffer = @import("../../core/buffer.zig");
const renderer = @import("../../core/renderer.zig");
const theme = @import("../../core/theme.zig");
const config = @import("../../core/config.zig");
const wayland_win = @import("../../core/wayland_window.zig");
const image_ops = @import("../../graphics/image_ops.zig");
const icons = @import("../../graphics/icons.zig");

const Color = theme.Color;
const Rect = renderer.Rect;
const Font = renderer.Font;
const quicksettings = @import("../../panels/quicksettings/panel.zig");
const ImageBuffer = image_ops.ImageBuffer;
const WindowApp = wayland_win.WindowApp;

pub const TextAlign = enum { left, center, right };

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
    eraser,

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
            .eraser => "Eraser",
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
            .eraser => "E",
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
            .eraser => "󰛔",
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
    image,

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
            .image => "Pasted Image",
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
            .image => "",
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

fn exportScaleFor(width: u32, height: u32) f32 {
    if (width == 0 or height == 0) return 1.0;
    const target_w: f32 = 1920.0;
    const target_h: f32 = 1080.0;
    const scale = @min(target_w / @as(f32, @floatFromInt(width)), target_h / @as(f32, @floatFromInt(height)));
    return @min(@max(scale, 1.0), 4.0);
}

fn scaleCoord(value: i32, scale: f32) i32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(value)) * scale));
}

fn scaleSize(value: u32, scale: f32) u32 {
    return @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(value)) * scale))));
}

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

    rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    start_x: i32 = 0,
    start_y: i32 = 0,
    end_x: i32 = 0,
    end_y: i32 = 0,
    points: std.ArrayListUnmanaged(Point) = .empty,
    text_buf: [1024]u8 = @splat(0),
    text_len: usize = 0,
    font_size: u32 = 18,
    text_align: TextAlign = .left,
    step_number: u32 = 1,
    image_data: ?ImageBuffer = null,
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
        if (self.image_data) |*img| {
            copy.image_data = try img.clone(allocator);
        }
        return copy;
    }

    pub fn deinit(self: *Annotation, allocator: std.mem.Allocator) void {
        self.points.deinit(allocator);
        if (self.image_data) |*img| {
            img.deinit();
            self.image_data = null;
        }
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
            .rect, .highlight, .blur, .pixelate, .image => {
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

    /// Composite this vector annotation directly onto the target pixel buffer.
    /// `scale` lets save/export render at a higher resolution than the base image.
    pub fn renderToImage(self: *const Annotation, img: *ImageBuffer, font: *Font, scale: f32) void {
        if (!self.visible or scale <= 0.0) return;

        const sw = scaleSize(self.stroke_width, scale);
        const b = self.getBounds();
        const br = Rect{
            .x = scaleCoord(b.x, scale),
            .y = scaleCoord(b.y, scale),
            .w = scaleSize(b.w, scale),
            .h = scaleSize(b.h, scale),
        };

        switch (self.kind) {
            .arrow => {
                img.drawArrow(
                    scaleCoord(self.start_x, scale),
                    scaleCoord(self.start_y, scale),
                    scaleCoord(self.end_x, scale),
                    scaleCoord(self.end_y, scale),
                    sw,
                    self.color,
                );
            },
            .line => {
                img.drawStrokeLine(
                    scaleCoord(self.start_x, scale),
                    scaleCoord(self.start_y, scale),
                    scaleCoord(self.end_x, scale),
                    scaleCoord(self.end_y, scale),
                    sw,
                    self.color,
                );
            },
            .rect => {
                img.drawRect(br, sw, self.color, self.filled);
            },
            .circle => {
                const cx = br.x + @divTrunc(@as(i32, @intCast(br.w)), 2);
                const cy = br.y + @divTrunc(@as(i32, @intCast(br.h)), 2);
                const rx = @max(1, @divTrunc(br.w, 2));
                const ry = @max(1, @divTrunc(br.h, 2));
                img.drawEllipse(cx, cy, rx, ry, sw, self.color, self.filled);
            },
            .highlight => {
                const tint = Color.init(100, self.color.r, self.color.g, self.color.b);
                img.applyHighlightRegion(br, tint);
            },
            .blur => {
                img.applyBlurRegion(br, scaleSize(@max(4, self.stroke_width * 2), scale));
            },
            .pixelate => {
                img.applyPixelateRegion(br, scaleSize(@max(6, self.stroke_width * 3), scale));
            },
            .image => {
                if (self.image_data) |*src| {
                    img.compositeScaled(src, br.x, br.y, br.w, br.h);
                }
            },
            .step_badge => {
                const cx = scaleCoord(self.rect.x, scale);
                const cy = scaleCoord(self.rect.y, scale);
                const r = scaleCoord(16, scale);
                // Outer filled circle
                img.fillCircle(cx, cy, r, self.color);
                // White step number text
                var num_buf: [16]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{self.step_number}) catch "1";
                img.drawText(
                    font,
                    num_str,
                    cx - scaleCoord(4, scale),
                    cy + scaleCoord(5, scale),
                    scaleSize(13, scale),
                    Color.rgb(255, 255, 255),
                );
            },
            .text => {
                const slice = self.text_buf[0..self.text_len];
                const font_size = scaleSize(self.font_size, scale);
                const line_height = font_size + scaleSize(@max(4, @divTrunc(self.font_size, 4)), scale);

                var line_it = std.mem.splitScalar(u8, slice, '\n');
                var line_idx: usize = 0;
                while (line_it.next()) |line| : (line_idx += 1) {
                    const w = font.measureTextWithSize(line, font_size);
                    var x = br.x;
                    switch (self.text_align) {
                        .center => x = br.x + @divTrunc(@as(i32, @intCast(br.w)), 2) - @divTrunc(@as(i32, @intCast(w)), 2),
                        .right => x = br.x + @as(i32, @intCast(br.w)) - @as(i32, @intCast(w)) - scaleCoord(4, scale),
                        else => x = br.x + scaleCoord(2, scale),
                    }
                    const y = br.y + @as(i32, @intCast(line_idx)) * @as(i32, @intCast(line_height)) + @as(i32, @intCast(font_size));
                    img.drawText(font, line, x, y, font_size, self.color);
                }
            },
            .pen => {
                if (self.points.items.len < 1) return;
                const radius = @divTrunc(@as(i32, @intCast(sw)), 2);
                for (self.points.items) |pt| {
                    img.fillCircle(scaleCoord(pt.x, scale), scaleCoord(pt.y, scale), radius, self.color);
                }
                if (self.points.items.len < 2) return;
                var i: usize = 0;
                while (i + 1 < self.points.items.len) : (i += 1) {
                    img.drawStrokeLine(
                        scaleCoord(self.points.items[i].x, scale),
                        scaleCoord(self.points.items[i].y, scale),
                        scaleCoord(self.points.items[i + 1].x, scale),
                        scaleCoord(self.points.items[i + 1].y, scale),
                        sw,
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

pub const TextUndoEntry = struct {
    text: []u8,
    cursor_idx: usize,
};

pub const TextEditState = struct {
    allocator: std.mem.Allocator,
    annotation_id: u32,
    text: std.ArrayListUnmanaged(u8) = .empty,
    cursor_idx: usize = 0,
    selection_anchor: ?usize = null,
    caret_visible: bool = true,
    drag_active: bool = false,
    undo_stack: std.ArrayListUnmanaged(TextUndoEntry) = .empty,
    redo_stack: std.ArrayListUnmanaged(TextUndoEntry) = .empty,

    pub fn init(allocator: std.mem.Allocator, annotation_id: u32, initial_text: []const u8) !TextEditState {
        var text = std.ArrayListUnmanaged(u8).empty;
        try text.appendSlice(allocator, initial_text);
        return TextEditState{
            .allocator = allocator,
            .annotation_id = annotation_id,
            .text = text,
            .cursor_idx = text.items.len,
            .selection_anchor = null,
            .caret_visible = true,
            .drag_active = false,
        };
    }

    pub fn deinit(self: *TextEditState) void {
        self.text.deinit(self.allocator);
        for (self.undo_stack.items) |entry| {
            self.allocator.free(entry.text);
        }
        self.undo_stack.deinit(self.allocator);
        for (self.redo_stack.items) |entry| {
            self.allocator.free(entry.text);
        }
        self.redo_stack.deinit(self.allocator);
    }

    pub fn pushUndo(self: *TextEditState) void {
        const text_dupe = self.allocator.dupe(u8, self.text.items) catch return;
        self.undo_stack.append(self.allocator, .{
            .text = text_dupe,
            .cursor_idx = self.cursor_idx,
        }) catch {
            self.allocator.free(text_dupe);
            return;
        };
        for (self.redo_stack.items) |entry| self.allocator.free(entry.text);
        self.redo_stack.clearRetainingCapacity();
    }

    pub fn undo(self: *TextEditState) void {
        if (self.undo_stack.items.len == 0) return;
        const current_dupe = self.allocator.dupe(u8, self.text.items) catch return;
        self.redo_stack.append(self.allocator, .{
            .text = current_dupe,
            .cursor_idx = self.cursor_idx,
        }) catch {
            self.allocator.free(current_dupe);
            return;
        };

        const prev = self.undo_stack.pop().?;
        self.text.clearRetainingCapacity();
        self.text.appendSlice(self.allocator, prev.text) catch {};
        self.cursor_idx = @min(prev.cursor_idx, self.text.items.len);
        self.selection_anchor = null;
        self.allocator.free(prev.text);
    }

    pub fn redo(self: *TextEditState) void {
        if (self.redo_stack.items.len == 0) return;
        const current_dupe = self.allocator.dupe(u8, self.text.items) catch return;
        self.undo_stack.append(self.allocator, .{
            .text = current_dupe,
            .cursor_idx = self.cursor_idx,
        }) catch {
            self.allocator.free(current_dupe);
            return;
        };

        const next = self.redo_stack.pop().?;
        self.text.clearRetainingCapacity();
        self.text.appendSlice(self.allocator, next.text) catch {};
        self.cursor_idx = @min(next.cursor_idx, self.text.items.len);
        self.selection_anchor = null;
        self.allocator.free(next.text);
    }

    pub fn hasSelection(self: *const TextEditState) bool {
        if (self.selection_anchor) |anchor| {
            return anchor != self.cursor_idx;
        }
        return false;
    }

    pub const Range = struct { start: usize, end: usize };

    pub fn getSelectionRange(self: *const TextEditState) ?Range {
        if (self.selection_anchor) |anchor| {
            if (anchor == self.cursor_idx) return null;
            return Range{
                .start = @min(anchor, self.cursor_idx),
                .end = @max(anchor, self.cursor_idx),
            };
        }
        return null;
    }

    pub fn getSelectedText(self: *const TextEditState) ?[]const u8 {
        if (self.getSelectionRange()) |r| {
            return self.text.items[r.start..r.end];
        }
        return null;
    }

    pub fn removeSelection(self: *TextEditState) bool {
        if (self.getSelectionRange()) |r| {
            self.pushUndo();
            const count = r.end - r.start;
            var i = r.start;
            while (i + count < self.text.items.len) : (i += 1) {
                self.text.items[i] = self.text.items[i + count];
            }
            self.text.shrinkRetainingCapacity(self.text.items.len - count);
            self.cursor_idx = r.start;
            self.selection_anchor = null;
            return true;
        }
        return false;
    }

    pub fn selectAll(self: *TextEditState) void {
        if (self.text.items.len == 0) return;
        self.selection_anchor = 0;
        self.cursor_idx = self.text.items.len;
    }

    pub fn insertBytes(self: *TextEditState, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        if (self.text.items.len + bytes.len > 1023) return;
        _ = self.removeSelection();
        self.pushUndo();
        self.cursor_idx = @min(self.cursor_idx, self.text.items.len);
        try self.text.insertSlice(self.allocator, self.cursor_idx, bytes);
        self.cursor_idx += bytes.len;
        self.selection_anchor = null;
    }

    pub fn deleteBackward(self: *TextEditState) void {
        if (self.removeSelection()) return;
        if (self.cursor_idx == 0 or self.text.items.len == 0) return;
        self.pushUndo();
        var prev_idx = self.cursor_idx - 1;
        while (prev_idx > 0 and (self.text.items[prev_idx] & 0xC0) == 0x80) {
            prev_idx -= 1;
        }
        const count = self.cursor_idx - prev_idx;
        var i = prev_idx;
        while (i + count < self.text.items.len) : (i += 1) {
            self.text.items[i] = self.text.items[i + count];
        }
        self.text.shrinkRetainingCapacity(self.text.items.len - count);
        self.cursor_idx = prev_idx;
    }

    pub fn deleteForward(self: *TextEditState) void {
        if (self.removeSelection()) return;
        if (self.cursor_idx >= self.text.items.len) return;
        self.pushUndo();
        var next_idx = self.cursor_idx + 1;
        while (next_idx < self.text.items.len and (self.text.items[next_idx] & 0xC0) == 0x80) {
            next_idx += 1;
        }
        const count = next_idx - self.cursor_idx;
        var i = self.cursor_idx;
        while (i + count < self.text.items.len) : (i += 1) {
            self.text.items[i] = self.text.items[i + count];
        }
        self.text.shrinkRetainingCapacity(self.text.items.len - count);
    }

    pub fn deleteWordBackward(self: *TextEditState) void {
        if (self.removeSelection()) return;
        if (self.cursor_idx == 0) return;
        self.pushUndo();
        var i = self.cursor_idx;
        while (i > 0 and (self.text.items[i - 1] == ' ' or self.text.items[i - 1] == '\t' or self.text.items[i - 1] == '\n')) {
            i -= 1;
        }
        while (i > 0 and self.text.items[i - 1] != ' ' and self.text.items[i - 1] != '\t' and self.text.items[i - 1] != '\n') {
            i -= 1;
        }
        const count = self.cursor_idx - i;
        var j = i;
        while (j + count < self.text.items.len) : (j += 1) {
            self.text.items[j] = self.text.items[j + count];
        }
        self.text.shrinkRetainingCapacity(self.text.items.len - count);
        self.cursor_idx = i;
    }

    pub fn deleteWordForward(self: *TextEditState) void {
        if (self.removeSelection()) return;
        if (self.cursor_idx >= self.text.items.len) return;
        self.pushUndo();
        var i = self.cursor_idx;
        while (i < self.text.items.len and (self.text.items[i] == ' ' or self.text.items[i] == '\t' or self.text.items[i] == '\n')) {
            i += 1;
        }
        while (i < self.text.items.len and self.text.items[i] != ' ' and self.text.items[i] != '\t' and self.text.items[i] != '\n') {
            i += 1;
        }
        const count = i - self.cursor_idx;
        var j = self.cursor_idx;
        while (j + count < self.text.items.len) : (j += 1) {
            self.text.items[j] = self.text.items[j + count];
        }
        self.text.shrinkRetainingCapacity(self.text.items.len - count);
    }

    pub fn moveLeft(self: *TextEditState, extend_selection: bool) void {
        if (!extend_selection and self.hasSelection()) {
            if (self.getSelectionRange()) |r| {
                self.cursor_idx = r.start;
                self.selection_anchor = null;
                return;
            }
        }
        if (self.cursor_idx > 0) {
            if (extend_selection and self.selection_anchor == null) {
                self.selection_anchor = self.cursor_idx;
            }
            var prev = self.cursor_idx - 1;
            while (prev > 0 and (self.text.items[prev] & 0xC0) == 0x80) {
                prev -= 1;
            }
            self.cursor_idx = prev;
            if (extend_selection and self.selection_anchor.? == self.cursor_idx) {
                self.selection_anchor = null;
            }
        } else if (!extend_selection) {
            self.selection_anchor = null;
        }
    }

    pub fn moveRight(self: *TextEditState, extend_selection: bool) void {
        if (!extend_selection and self.hasSelection()) {
            if (self.getSelectionRange()) |r| {
                self.cursor_idx = r.end;
                self.selection_anchor = null;
                return;
            }
        }
        if (self.cursor_idx < self.text.items.len) {
            if (extend_selection and self.selection_anchor == null) {
                self.selection_anchor = self.cursor_idx;
            }
            var next = self.cursor_idx + 1;
            while (next < self.text.items.len and (self.text.items[next] & 0xC0) == 0x80) {
                next += 1;
            }
            self.cursor_idx = next;
            if (extend_selection and self.selection_anchor.? == self.cursor_idx) {
                self.selection_anchor = null;
            }
        } else if (!extend_selection) {
            self.selection_anchor = null;
        }
    }

    pub fn moveWordLeft(self: *TextEditState, extend_selection: bool) void {
        if (extend_selection and self.selection_anchor == null) {
            self.selection_anchor = self.cursor_idx;
        } else if (!extend_selection) {
            self.selection_anchor = null;
        }
        var i = self.cursor_idx;
        while (i > 0 and (self.text.items[i - 1] == ' ' or self.text.items[i - 1] == '\t' or self.text.items[i - 1] == '\n')) {
            i -= 1;
        }
        while (i > 0 and self.text.items[i - 1] != ' ' and self.text.items[i - 1] != '\t' and self.text.items[i - 1] != '\n') {
            i -= 1;
        }
        self.cursor_idx = i;
    }

    pub fn moveWordRight(self: *TextEditState, extend_selection: bool) void {
        if (extend_selection and self.selection_anchor == null) {
            self.selection_anchor = self.cursor_idx;
        } else if (!extend_selection) {
            self.selection_anchor = null;
        }
        var i = self.cursor_idx;
        while (i < self.text.items.len and (self.text.items[i] == ' ' or self.text.items[i] == '\t' or self.text.items[i] == '\n')) {
            i += 1;
        }
        while (i < self.text.items.len and self.text.items[i] != ' ' and self.text.items[i] != '\t' and self.text.items[i] != '\n') {
            i += 1;
        }
        self.cursor_idx = i;
    }

    pub fn moveHome(self: *TextEditState, extend_selection: bool, entire: bool) void {
        if (extend_selection and self.selection_anchor == null) {
            self.selection_anchor = self.cursor_idx;
        } else if (!extend_selection) {
            self.selection_anchor = null;
        }
        if (entire or self.cursor_idx == 0) {
            self.cursor_idx = 0;
            return;
        }
        var i = self.cursor_idx;
        while (i > 0 and self.text.items[i - 1] != '\n') {
            i -= 1;
        }
        self.cursor_idx = i;
    }

    pub fn moveEnd(self: *TextEditState, extend_selection: bool, entire: bool) void {
        if (extend_selection and self.selection_anchor == null) {
            self.selection_anchor = self.cursor_idx;
        } else if (!extend_selection) {
            self.selection_anchor = null;
        }
        if (entire or self.cursor_idx >= self.text.items.len) {
            self.cursor_idx = self.text.items.len;
            return;
        }
        var i = self.cursor_idx;
        while (i < self.text.items.len and self.text.items[i] != '\n') {
            i += 1;
        }
        self.cursor_idx = i;
    }

    pub fn moveUp(self: *TextEditState, extend_selection: bool, font: *Font, font_size: u32) void {
        if (extend_selection and self.selection_anchor == null) {
            self.selection_anchor = self.cursor_idx;
        } else if (!extend_selection) {
            self.selection_anchor = null;
        }
        var cur_start: usize = self.cursor_idx;
        while (cur_start > 0 and self.text.items[cur_start - 1] != '\n') {
            cur_start -= 1;
        }
        if (cur_start == 0) {
            self.cursor_idx = 0;
            return;
        }
        const prev_end = cur_start - 1;
        var prev_start = prev_end;
        while (prev_start > 0 and self.text.items[prev_start - 1] != '\n') {
            prev_start -= 1;
        }
        const cur_slice = self.text.items[cur_start..self.cursor_idx];
        const cur_w = font.measureTextWithSize(cur_slice, font_size);
        const prev_slice = self.text.items[prev_start..prev_end];
        var closest = prev_start;
        var min_d: i32 = std.math.maxInt(i32);
        var b: usize = 0;
        while (b <= prev_slice.len) {
            const prefix = prev_slice[0..b];
            const w = @as(i32, @intCast(font.measureTextWithSize(prefix, font_size)));
            const d = @abs(w - @as(i32, @intCast(cur_w)));
            if (d < min_d) {
                min_d = @as(i32, @intCast(d));
                closest = prev_start + b;
            }
            if (b == prev_slice.len) break;
            const seq_len = std.unicode.utf8ByteSequenceLength(prev_slice[b]) catch 1;
            b += seq_len;
        }
        self.cursor_idx = closest;
    }

    pub fn moveDown(self: *TextEditState, extend_selection: bool, font: *Font, font_size: u32) void {
        if (extend_selection and self.selection_anchor == null) {
            self.selection_anchor = self.cursor_idx;
        } else if (!extend_selection) {
            self.selection_anchor = null;
        }
        var cur_start: usize = self.cursor_idx;
        while (cur_start > 0 and self.text.items[cur_start - 1] != '\n') {
            cur_start -= 1;
        }
        var cur_end = self.cursor_idx;
        while (cur_end < self.text.items.len and self.text.items[cur_end] != '\n') {
            cur_end += 1;
        }
        if (cur_end >= self.text.items.len) {
            self.cursor_idx = self.text.items.len;
            return;
        }
        const next_start = cur_end + 1;
        var next_end = next_start;
        while (next_end < self.text.items.len and self.text.items[next_end] != '\n') {
            next_end += 1;
        }
        const cur_slice = self.text.items[cur_start..self.cursor_idx];
        const cur_w = font.measureTextWithSize(cur_slice, font_size);
        const next_slice = self.text.items[next_start..next_end];
        var closest = next_start;
        var min_d: i32 = std.math.maxInt(i32);
        var b: usize = 0;
        while (b <= next_slice.len) {
            const prefix = next_slice[0..b];
            const w = @as(i32, @intCast(font.measureTextWithSize(prefix, font_size)));
            const d = @abs(w - @as(i32, @intCast(cur_w)));
            if (d < min_d) {
                min_d = @as(i32, @intCast(d));
                closest = next_start + b;
            }
            if (b == next_slice.len) break;
            const seq_len = std.unicode.utf8ByteSequenceLength(next_slice[b]) catch 1;
            b += seq_len;
        }
        self.cursor_idx = closest;
    }

    pub fn copyToClipboard(self: *const TextEditState) void {
        const text_to_copy = if (self.getSelectedText()) |s| s else self.text.items;
        if (text_to_copy.len == 0) return;
        const pid = c.fork();
        if (pid == 0) {
            _ = c.setsid();
            const pipe = c.popen("export PATH=\"$PATH:/usr/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; wl-copy 2>/dev/null", "w");
            if (pipe != null) {
                _ = c.fwrite(text_to_copy.ptr, 1, text_to_copy.len, pipe);
                _ = c.pclose(pipe);
            }
            c.exit(0);
        }
    }

    pub fn cutToClipboard(self: *TextEditState) void {
        self.copyToClipboard();
        _ = self.removeSelection();
    }

    pub fn pasteFromClipboard(self: *TextEditState) void {
        const pipe = c.popen("export PATH=\"$PATH:/usr/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; wl-paste 2>/dev/null", "r");
        if (pipe != null) {
            defer _ = c.pclose(pipe);
            var buf: [1024]u8 = undefined;
            const n = c.fread(&buf, 1, buf.len, pipe);
            if (n > 0) {
                self.insertBytes(buf[0..n]) catch {};
            }
        }
    }

    pub fn findCursorFromXY(self: *const TextEditState, font: *Font, font_size: u32, line_height: u32, rel_x: i32, rel_y: i32) usize {
        if (self.text.items.len == 0) return 0;
        const target_line: usize = if (rel_y <= 0) 0 else @intCast(@divTrunc(rel_y, @as(i32, @intCast(@max(1, line_height)))));
        var cur_line: usize = 0;
        var line_start: usize = 0;
        var i: usize = 0;
        while (i <= self.text.items.len) : (i += 1) {
            const is_end = (i == self.text.items.len);
            if (is_end or self.text.items[i] == '\n') {
                if (cur_line == target_line or is_end) {
                    const line_slice = self.text.items[line_start..i];
                    var closest_idx = line_start;
                    var min_dist: i32 = std.math.maxInt(i32);
                    var b_idx: usize = 0;
                    while (b_idx <= line_slice.len) {
                        const prefix = line_slice[0..b_idx];
                        const w = @as(i32, @intCast(font.measureTextWithSize(prefix, font_size)));
                        const dist = @abs(w - rel_x);
                        if (dist < min_dist) {
                            min_dist = @as(i32, @intCast(dist));
                            closest_idx = line_start + b_idx;
                        }
                        if (b_idx == line_slice.len) break;
                        const seq_len = std.unicode.utf8ByteSequenceLength(line_slice[b_idx]) catch 1;
                        b_idx += seq_len;
                    }
                    return closest_idx;
                }
                cur_line += 1;
                line_start = i + 1;
            }
        }
        return self.text.items.len;
    }
};

pub const InkApp = AnnotateApp;
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

    active_tool: Tool = .select,
    current_color: Color = Color.hex(0xE06C75),
    stroke_width: u32 = 4,
    current_font_size: u32 = 18,
    current_text_align: TextAlign = .left,
    fill_shape: bool = false,

    zoom: f32 = 1.0,
    pan_x: f32 = 0.0,
    pan_y: f32 = 0.0,
    is_panning: bool = false,
    pan_start_x: i32 = 0,
    pan_start_y: i32 = 0,

    is_drawing: bool = false,
    is_moving: bool = false,
    is_resizing: bool = false,
    is_marquee: bool = false,
    active_handle: ResizeHandle = .none,

    drag_start_x: i32 = 0,
    drag_start_y: i32 = 0,
    drag_curr_x: i32 = 0,
    drag_curr_y: i32 = 0,
    last_move_x: i32 = 0,
    last_move_y: i32 = 0,

    editing_text_id: ?u32 = null,
    text_editor: ?TextEditState = null,
    has_pushed_eraser_undo: bool = false,
    font_dropdown_open: bool = false,

    color_dialog_open: bool = false,
    color_dialog_buf: [16]u8 = @splat(0),
    color_dialog_len: usize = 0,
    color_dialog_cursor: usize = 0,

    editing_font_size: bool = false,
    font_size_buf: [8]u8 = @splat(0),
    font_size_len: usize = 0,

    is_crop_mode: bool = false,
    is_cropping: bool = false,
    crop_x0: i32 = 0,
    crop_y0: i32 = 0,
    crop_x1: i32 = 0,
    crop_y1: i32 = 0,

    show_layers: bool = false,
    show_adjustments: bool = false,
    show_info: bool = false,

    adjustments: Adjustments = .{},
    adjust_base_image: ?ImageBuffer = null,
    active_slider: ?enum { brightness, contrast, saturation, blur } = null,

    original_path: ?[]const u8 = null,
    file_size_bytes: usize = 0,

    status_msg: [128]u8 = @splat(0),
    status_len: usize = 0,
    status_ticks: u32 = 0,

    ui_scale: f32 = 1.0,
    ui_font_size: u32 = 13,
    toolbar_height: u32 = 44,
    statusbar_height: u32 = 28,
    layers_panel_width: u32 = 230,
    adjust_panel_width: u32 = 240,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config, image_to_load: ?ImageBuffer, file_path: ?[]const u8) !*AnnotateApp {
        const scale_opt = quicksettings.loadDisplayScale();
        var ui_scale: f32 = if (scale_opt) |s| @as(f32, @floatFromInt(s)) / 100.0 else 1.0;
        if (ui_scale < 0.5) ui_scale = 1.0;

        var win = try WindowApp.init(allocator, .{
            .title = "Mizu Ink",
            .app_id = "mizu-ink",
            .width = 1240,
            .height = 760,
            .min_width = 720,
            .min_height = 460,
        });
        win.scale_factor = ui_scale;
        errdefer win.deinit();

        const font = try allocator.create(Font);
        const ui_font_size = @max(13, @as(u32, @intFromFloat(@round(13.5 * ui_scale))));
        font.* = try Font.init(allocator, cfg.theme.font_family, ui_font_size);
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
            const p_z = allocator.dupeSentinel(u8, p, 0) catch null;
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
            .ui_scale = ui_scale,
            .ui_font_size = @max(13, @as(u32, @intFromFloat(@round(13.5 * ui_scale)))),
            .toolbar_height = 44,
            .statusbar_height = 28,
            .layers_panel_width = 230,
            .adjust_panel_width = 240,
            .undo_mgr = UndoManager.init(allocator, 30),
        };

        app.fitToWindow();
        return app;
    }

    pub fn reloadScale(self: *AnnotateApp) void {
        const scale_opt = quicksettings.loadDisplayScale();
        var ui_scale: f32 = if (scale_opt) |s| @as(f32, @floatFromInt(s)) / 100.0 else 1.0;
        if (ui_scale < 0.5) ui_scale = 1.0;
        if (ui_scale == self.ui_scale) return;
        self.ui_scale = ui_scale;
        self.win.scale_factor = ui_scale;

        const new_font = self.allocator.create(Font) catch return;
        const ui_font_size = @max(13, @as(u32, @intFromFloat(@round(13.5 * ui_scale))));
        self.ui_font_size = ui_font_size;
        new_font.* = Font.init(self.allocator, self.cfg.theme.font_family, ui_font_size) catch {
            self.allocator.destroy(new_font);
            return;
        };
        const old_font = self.font;
        self.font = new_font;
        old_font.deinit();
        self.allocator.destroy(old_font);

        self.win.needs_redraw = true;
    }

    pub fn deinit(self: *AnnotateApp) void {
        const alloc = self.allocator;
        if (self.text_editor) |*te| te.deinit();
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

    pub fn effectiveScale(self: *const AnnotateApp) f32 {
        return self.win.effectiveScale();
    }

    pub fn toPhysX(self: *const AnnotateApp, lx: i32) i32 {
        return @intFromFloat(@round(@as(f32, @floatFromInt(lx)) * self.effectiveScale()));
    }

    pub fn toPhysY(self: *const AnnotateApp, ly: i32) i32 {
        return @intFromFloat(@round(@as(f32, @floatFromInt(ly)) * self.effectiveScale()));
    }

    pub fn toPhysSize(self: *const AnnotateApp, sz: anytype) u32 {
        const f: f32 = switch (@typeInfo(@TypeOf(sz))) {
            .comptime_int, .int => @floatFromInt(sz),
            .comptime_float, .float => @floatCast(sz),
            else => @compileError("Unsupported size type"),
        };
        return @max(1, @as(u32, @intFromFloat(@round(f * self.effectiveScale()))));
    }

    pub fn toPhysRect(self: *const AnnotateApp, r: Rect) Rect {
        const px = self.toPhysX(r.x);
        const py = self.toPhysY(r.y);
        const pw = self.toPhysX(r.x + @as(i32, @intCast(r.w))) - px;
        const ph = self.toPhysY(r.y + @as(i32, @intCast(r.h))) - py;
        return Rect{
            .x = px,
            .y = py,
            .w = @intCast(@max(0, pw)),
            .h = @intCast(@max(0, ph)),
        };
    }

    pub fn imageToPhysX(self: *const AnnotateApp, ix: i32) i32 {
        return self.toPhysX(self.imageToScreenX(ix));
    }

    pub fn imageToPhysY(self: *const AnnotateApp, iy: i32) i32 {
        return self.toPhysY(self.imageToScreenY(iy));
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

    // Selection & Manipulation
    pub fn isSelected(self: *const AnnotateApp, id: u32) bool {
        for (self.selected_ids.items) |sid| {
            if (sid == id) return true;
        }
        return false;
    }

    pub fn selectOnly(self: *AnnotateApp, id: u32) void {
        self.selected_ids.clearRetainingCapacity();
        self.selected_ids.append(self.allocator, id) catch {};
        if (self.findAnnotationById(id)) |ann| {
            if (ann.kind == .text) {
                self.current_font_size = ann.font_size;
                self.current_text_align = ann.text_align;
            }
        }
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
        if (self.findAnnotationById(id)) |ann| {
            if (ann.kind == .text) {
                self.current_font_size = ann.font_size;
            }
        }
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

    pub fn updateTextAnnotationBounds(self: *AnnotateApp, ann: *Annotation) void {
        if (ann.kind != .text) return;
        const slice = if (self.text_editor) |*te|
            if (te.annotation_id == ann.id) te.text.items else ann.text_buf[0..ann.text_len]
        else
            ann.text_buf[0..ann.text_len];

        var max_w: u32 = 0;
        var line_count: u32 = 0;
        var it = std.mem.splitScalar(u8, slice, '\n');
        while (it.next()) |line| {
            line_count += 1;
            const lw = self.font.measureTextWithSize(line, ann.font_size);
            if (lw > max_w) max_w = lw;
        }
        if (line_count == 0) line_count = 1;
        const line_h = ann.font_size + @max(4, @divTrunc(ann.font_size, 4));
        ann.rect.w = @intCast(@max(24, max_w + 12));
        ann.rect.h = @intCast(@max(18, line_count * line_h + 8));
    }

    pub fn decreaseFontSize(self: *AnnotateApp) void {
        if (self.current_font_size > 8) {
            self.current_font_size -= 2;
            for (self.selected_ids.items) |sid| {
                if (self.findAnnotationById(sid)) |a| {
                    if (a.kind == .text) {
                        a.font_size = self.current_font_size;
                        self.updateTextAnnotationBounds(a);
                    }
                }
            }
            if (self.editing_text_id) |tid| {
                if (self.findAnnotationById(tid)) |a| {
                    a.font_size = self.current_font_size;
                    self.updateTextAnnotationBounds(a);
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
                        self.updateTextAnnotationBounds(a);
                    }
                }
            }
            if (self.editing_text_id) |tid| {
                if (self.findAnnotationById(tid)) |a| {
                    a.font_size = self.current_font_size;
                    self.updateTextAnnotationBounds(a);
                }
            }
            var buf: [32]u8 = undefined;
            self.setStatus(std.fmt.bufPrint(&buf, "Font size: {d}px", .{self.current_font_size}) catch "Font size +");
            self.win.needs_redraw = true;
        }
    }

    pub fn increaseStrokeWidth(self: *AnnotateApp) void {
        if (self.stroke_width < 64) {
            self.stroke_width += 1;
            for (self.selected_ids.items) |sid| {
                if (self.findAnnotationById(sid)) |a| {
                    a.stroke_width = self.stroke_width;
                }
            }
            var buf: [32]u8 = undefined;
            self.setStatus(std.fmt.bufPrint(&buf, "Thickness: {d}px", .{self.stroke_width}) catch "Thickness +");
            self.win.needs_redraw = true;
        }
    }

    pub fn decreaseStrokeWidth(self: *AnnotateApp) void {
        if (self.stroke_width > 1) {
            self.stroke_width -= 1;
            for (self.selected_ids.items) |sid| {
                if (self.findAnnotationById(sid)) |a| {
                    a.stroke_width = self.stroke_width;
                }
            }
            var buf: [32]u8 = undefined;
            self.setStatus(std.fmt.bufPrint(&buf, "Thickness: {d}px", .{self.stroke_width}) catch "Thickness -");
            self.win.needs_redraw = true;
        }
    }

    pub fn handleShiftScroll(self: *AnnotateApp, delta: f64) void {
        const is_text = (self.active_tool == .text or self.editing_text_id != null or blk: {
            for (self.selected_ids.items) |sid| {
                if (self.findAnnotationById(sid)) |a| {
                    if (a.kind == .text) break :blk true;
                }
            }
            break :blk false;
        });

        if (is_text) {
            if (delta < 0) {
                self.increaseFontSize();
            } else {
                self.decreaseFontSize();
            }
        } else {
            if (delta < 0) {
                self.increaseStrokeWidth();
            } else {
                self.decreaseStrokeWidth();
            }
        }
    }

    pub fn parseHexColor(raw: []const u8) ?Color {
        var s = std.mem.trim(u8, raw, " \t\r\n;\"'");
        if (s.len > 0 and s[0] == '#') s = s[1..];
        if (s.len != 3 and s.len != 6 and s.len != 8) return null;
        for (s) |ch| {
            if (!std.ascii.isHex(ch)) return null;
        }
        return Color.fromHex(raw);
    }

    pub fn openColorDialog(self: *AnnotateApp) void {
        self.color_dialog_open = !self.color_dialog_open;
        if (self.color_dialog_open) {
            self.font_dropdown_open = false;
            // Check if clipboard contains a valid hex color
            var loaded = false;
            const pipe = c.popen("wl-paste --no-newline 2>/dev/null", "r");
            if (pipe != null) {
                defer _ = c.pclose(pipe);
                var c_buf: [32]u8 = undefined;
                const n_read = c.fread(&c_buf, 1, c_buf.len, pipe.?);
                if (n_read >= 3 and n_read <= 9) {
                    const trimmed = std.mem.trim(u8, c_buf[0..n_read], " \t\r\n;\"'");
                    if (parseHexColor(trimmed) != null) {
                        var out_buf: [16]u8 = undefined;
                        const formatted = if (trimmed[0] == '#')
                            trimmed
                        else
                            std.fmt.bufPrint(&out_buf, "#{s}", .{trimmed}) catch "";
                        if (formatted.len >= 4 and formatted.len <= 9) {
                            @memcpy(self.color_dialog_buf[0..formatted.len], formatted);
                            self.color_dialog_len = formatted.len;
                            self.color_dialog_cursor = formatted.len;
                            loaded = true;
                        }
                    }
                }
            }

            if (!loaded) {
                var buf: [16]u8 = undefined;
                const hex = std.fmt.bufPrint(&buf, "#{X:0>2}{X:0>2}{X:0>2}", .{
                    self.current_color.r,
                    self.current_color.g,
                    self.current_color.b,
                }) catch "#FFFFFF";
                @memcpy(self.color_dialog_buf[0..hex.len], hex);
                self.color_dialog_len = hex.len;
                self.color_dialog_cursor = hex.len;
            }
        }
        self.win.needs_redraw = true;
    }

    pub fn closeColorDialog(self: *AnnotateApp) void {
        self.color_dialog_open = false;
        self.win.needs_redraw = true;
    }

    pub fn applyColorDialog(self: *AnnotateApp) void {
        const hex_slice = self.color_dialog_buf[0..self.color_dialog_len];
        const parsed = parseHexColor(hex_slice) orelse return;
        self.current_color = parsed;
        for (self.selected_ids.items) |sid| {
            if (self.findAnnotationById(sid)) |a| a.color = parsed;
        }

        // Format and copy to clipboard
        var hex_fmt_buf: [16]u8 = undefined;
        const hex_formatted = std.fmt.bufPrint(&hex_fmt_buf, "#{X:0>2}{X:0>2}{X:0>2}", .{ parsed.r, parsed.g, parsed.b }) catch "#000000";
        var copy_cmd_buf: [128]u8 = undefined;
        const copy_cmd = std.fmt.bufPrintSentinel(&copy_cmd_buf, "wl-copy '{s}' 2>/dev/null || true", .{hex_formatted}, 0) catch null;
        if (copy_cmd) |cmd| _ = c.system(cmd.ptr);

        var status_buf: [48]u8 = undefined;
        self.setStatus(std.fmt.bufPrint(&status_buf, "Color set: {s} (copied)", .{hex_formatted}) catch "Color set");
        self.color_dialog_open = false;
        self.win.needs_redraw = true;
    }

    pub fn pasteHexFromClipboard(self: *AnnotateApp) void {
        const pipe = c.popen("wl-paste --no-newline 2>/dev/null", "r");
        if (pipe == null) return;
        defer _ = c.pclose(pipe);
        var buf: [32]u8 = undefined;
        const n = c.fread(&buf, 1, buf.len, pipe.?);
        if (n == 0) return;
        const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n;\"'");
        var clean_buf: [10]u8 = undefined;
        var clean_len: usize = 0;
        for (trimmed) |ch| {
            if (clean_len >= 9) break;
            if (ch == '#' or std.ascii.isHex(ch)) {
                clean_buf[clean_len] = ch;
                clean_len += 1;
            }
        }
        if (clean_len > 0) {
            @memcpy(self.color_dialog_buf[0..clean_len], clean_buf[0..clean_len]);
            self.color_dialog_len = clean_len;
            self.color_dialog_cursor = clean_len;
            self.win.needs_redraw = true;
        }
    }

    pub fn pickColorFromScreen(self: *AnnotateApp) void {
        _ = c.system("mizu picker > /tmp/mizu_picker_hex.txt 2>/dev/null || true");
        var picked_hex_buf: [16]u8 = undefined;
        var picked_len: usize = 0;

        const c_file = c.fopen("/tmp/mizu_picker_hex.txt", "r");
        if (c_file != null) {
            defer _ = c.fclose(c_file);
            var c_buf: [32]u8 = undefined;
            const n_read = c.fread(&c_buf, 1, c_buf.len, c_file.?);
            if (n_read > 0) {
                const hex_str = std.mem.trim(u8, c_buf[0..n_read], " \t\r\n;\"'");
                if (hex_str.len >= 3 and hex_str.len <= 9) {
                    @memcpy(picked_hex_buf[0..hex_str.len], hex_str);
                    picked_len = hex_str.len;
                }
            }
        }

        if (picked_len == 0) {
            const pipe = c.popen("wl-paste --no-newline 2>/dev/null", "r");
            if (pipe != null) {
                defer _ = c.pclose(pipe);
                var p_buf: [32]u8 = undefined;
                const n_read = c.fread(&p_buf, 1, p_buf.len, pipe.?);
                if (n_read > 0) {
                    const hex_str = std.mem.trim(u8, p_buf[0..n_read], " \t\r\n;\"'");
                    if (hex_str.len >= 3 and hex_str.len <= 9) {
                        @memcpy(picked_hex_buf[0..hex_str.len], hex_str);
                        picked_len = hex_str.len;
                    }
                }
            }
        }

        if (picked_len > 0) {
            const raw_hex = picked_hex_buf[0..picked_len];
            if (parseHexColor(raw_hex)) |col| {
                self.current_color = col;
                for (self.selected_ids.items) |sid| {
                    if (self.findAnnotationById(sid)) |a| a.color = col;
                }

                // Ensure uppercase #RRGGBB is formatted and copied to clipboard
                var hex_fmt_buf: [16]u8 = undefined;
                const hex_formatted = std.fmt.bufPrint(&hex_fmt_buf, "#{X:0>2}{X:0>2}{X:0>2}", .{ col.r, col.g, col.b }) catch "#000000";
                var copy_cmd_buf: [128]u8 = undefined;
                const copy_cmd = std.fmt.bufPrintSentinel(&copy_cmd_buf, "wl-copy '{s}' 2>/dev/null || true", .{hex_formatted}, 0) catch null;
                if (copy_cmd) |cmd| _ = c.system(cmd.ptr);

                var status_buf: [48]u8 = undefined;
                self.setStatus(std.fmt.bufPrint(&status_buf, "Picked & Copied: {s}", .{hex_formatted}) catch "Color picked");
                self.win.needs_redraw = true;
            }
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

    pub fn deleteAnnotationById(self: *AnnotateApp, id: u32) void {
        var i: usize = self.annotations.items.len;
        while (i > 0) {
            i -= 1;
            if (self.annotations.items[i].id == id) {
                var removed = self.annotations.orderedRemove(i);
                removed.deinit(self.allocator);
                break;
            }
        }
        var s: usize = self.selected_ids.items.len;
        while (s > 0) {
            s -= 1;
            if (self.selected_ids.items[s] == id) {
                _ = self.selected_ids.orderedRemove(s);
            }
        }
    }

    pub fn eraseAnnotationAt(self: *AnnotateApp, img_x: i32, img_y: i32) bool {
        var i: usize = self.annotations.items.len;
        while (i > 0) {
            i -= 1;
            const ann = &self.annotations.items[i];
            if (ann.hitTest(img_x, img_y)) {
                if (!self.has_pushed_eraser_undo) {
                    self.pushUndoState();
                    self.has_pushed_eraser_undo = true;
                }
                var removed = self.annotations.orderedRemove(i);
                removed.deinit(self.allocator);
                self.deselectAll();
                self.setStatus("Erased annotation");
                self.win.needs_redraw = true;
                return true;
            }
        }
        return false;
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

    // Save, Copy, Export, Screenshot Actions
    pub fn flattenImage(self: *AnnotateApp) !ImageBuffer {
        const scale = exportScaleFor(self.base_image.img.width, self.base_image.img.height);
        var out_img = if (scale > 1.0)
            try self.base_image.img.resize(
                self.allocator,
                scaleSize(self.base_image.img.width, scale),
                scaleSize(self.base_image.img.height, scale),
                .bilinear,
            )
        else
            try self.base_image.img.clone(self.allocator);
        errdefer out_img.deinit();

        for (self.annotations.items) |*ann| {
            ann.renderToImage(&out_img, self.font, scale);
        }
        return out_img;
    }

    pub fn save(self: *AnnotateApp) !void {
        const scale = exportScaleFor(self.base_image.img.width, self.base_image.img.height);
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
                const dir = std.fmt.bufPrintSentinel(&dir_buf, "{s}/Pictures/Screenshots", .{home_str}, 0) catch "/tmp";
                _ = c.mkdir(dir.ptr, 0o755);
                break :blk std.fmt.bufPrint(&path_buf, "{s}/Pictures/Screenshots/mizu_{d}.png", .{ home_str, ts }) catch "/tmp/mizu_annotated.png";
            }
            break :blk std.fmt.bufPrint(&path_buf, "/tmp/mizu_annotated_{d}.png", .{ts}) catch "/tmp/mizu_annotated.png";
        };

        if (std.mem.endsWith(u8, save_path, ".jpg") or std.mem.endsWith(u8, save_path, ".jpeg")) {
            try flat.saveJpeg(save_path, 92);
        } else if (std.mem.endsWith(u8, save_path, ".webp")) {
            var rgba_buf = try self.allocator.alloc(u8, @as(usize, flat.width) * @as(usize, flat.height) * 4);
            defer self.allocator.free(rgba_buf);
            var idx: usize = 0;
            while (idx < flat.pixels.len) : (idx += 1) {
                const px = flat.pixels[idx];
                rgba_buf[idx * 4 + 0] = @intCast((px >> 16) & 0xFF);
                rgba_buf[idx * 4 + 1] = @intCast((px >> 8) & 0xFF);
                rgba_buf[idx * 4 + 2] = @intCast(px & 0xFF);
                rgba_buf[idx * 4 + 3] = @intCast((px >> 24) & 0xFF);
            }
            if (c.export_webp(save_path.ptr, rgba_buf.ptr, @intCast(flat.width), @intCast(flat.height)) != 0) {
                self.setStatus("WebP save failed");
                return;
            }
        } else if (std.mem.endsWith(u8, save_path, ".svg")) {
            try self.exportSVG(save_path);
            self.setStatus("Saved SVG");
            return;
        } else {
            try flat.savePng(save_path);
        }

        var feedback_buf: [128]u8 = undefined;
        const feedback = std.fmt.bufPrint(&feedback_buf, "Saved {d:.1}x to {s}", .{ scale, save_path }) catch "Saved successfully";
        self.setStatus(feedback);
    }

    pub fn exportImage(self: *AnnotateApp, as_jpeg: bool) !void {
        const scale = exportScaleFor(self.base_image.img.width, self.base_image.img.height);
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
        const feedback = std.fmt.bufPrint(&feedback_buf, "Exported {d:.1}x to {s}", .{ scale, path }) catch "Exported";
        self.setStatus(feedback);
    }

    pub fn exportWebP(self: *AnnotateApp) !void {
        var flat = try self.flattenImage();
        defer flat.deinit();
        const home = if (c.getenv("HOME")) |h| std.mem.span(h) else "/tmp";
        const ts = c.time(null);
        var path_buf: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/Pictures/mizu_export_{d}.webp", .{ home, ts });
        var rgba_buf = try self.allocator.alloc(u8, @as(usize, flat.width) * @as(usize, flat.height) * 4);
        defer self.allocator.free(rgba_buf);
        var idx: usize = 0;
        while (idx < flat.pixels.len) : (idx += 1) {
            const px = flat.pixels[idx];
            rgba_buf[idx * 4 + 0] = @intCast((px >> 16) & 0xFF); // R
            rgba_buf[idx * 4 + 1] = @intCast((px >> 8) & 0xFF); // G
            rgba_buf[idx * 4 + 2] = @intCast(px & 0xFF); // B
            rgba_buf[idx * 4 + 3] = @intCast((px >> 24) & 0xFF); // A
        }
        if (c.export_webp(path.ptr, rgba_buf.ptr, @intCast(flat.width), @intCast(flat.height)) == 0) {
            var fb: [128]u8 = undefined;
            self.setStatus(std.fmt.bufPrint(&fb, "Exported WebP to {s}", .{path}) catch "WebP exported");
        } else {
            self.setStatus("WebP export failed");
        }
    }

    pub fn exportSVG(self: *AnnotateApp, path_override: ?[]const u8) !void {
        const home = if (c.getenv("HOME")) |h| std.mem.span(h) else "/tmp";
        const ts = c.time(null);
        var path_buf: [512]u8 = undefined;
        const path = if (path_override) |po| po else try std.fmt.bufPrint(&path_buf, "{s}/Pictures/mizu_export_{d}.svg", .{ home, ts });
        var buf: [65536]u8 = undefined;
        var pos: usize = 0;
        const w = self.base_image.img.width;
        const h = self.base_image.img.height;
        const s0 = std.fmt.bufPrint(buf[pos..], "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}\" height=\"{d}\" viewBox=\"0 0 {d} {d}\" version=\"1.1\">\n", .{ w, h, w, h }) catch return error.BufOverflow;
        pos += s0.len;
        var hex_buf: [8]u8 = undefined;
        for (self.annotations.items) |*ann| {
            if (!ann.visible) continue;
            const hex_str = ann.color.formatHexRgb(&hex_buf);
            switch (ann.kind) {
                .arrow => {
                    const _part_1417 = std.fmt.bufPrint(buf[pos..], "  <line x1=\"{d}\" y1=\"{d}\" x2=\"{d}\" y2=\"{d}\" stroke=\"{s}\" stroke-width=\"{d}\" stroke-linecap=\"round\"/>\n", .{ ann.start_x, ann.start_y, ann.end_x, ann.end_y, hex_str, ann.stroke_width }) catch return error.BufOverflow;
                    pos += _part_1417.len;
                },
                .line => {
                    const _part_1420 = std.fmt.bufPrint(buf[pos..], "  <line x1=\"{d}\" y1=\"{d}\" x2=\"{d}\" y2=\"{d}\" stroke=\"{s}\" stroke-width=\"{d}\" stroke-linecap=\"round\"/>\n", .{ ann.start_x, ann.start_y, ann.end_x, ann.end_y, hex_str, ann.stroke_width }) catch return error.BufOverflow;
                    pos += _part_1420.len;
                },
                .rect => {
                    const b = ann.getBounds();
                    const fill_attr = if (ann.filled) try std.fmt.bufPrint(&[_]u8{}, "fill=\"{s}\"", .{hex_str}) else "fill=\"none\"";
                    const _part_1425 = std.fmt.bufPrint(buf[pos..], "  <rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" stroke=\"{s}\" stroke-width=\"{d}\" {s}/>\n", .{ b.x, b.y, b.w, b.h, hex_str, ann.stroke_width, fill_attr }) catch return error.BufOverflow;
                    pos += _part_1425.len;
                },
                .circle => {
                    const b = ann.getBounds();
                    const fill_attr = if (ann.filled) try std.fmt.bufPrint(&[_]u8{}, "fill=\"{s}\"", .{hex_str}) else "fill=\"none\"";
                    const _part_1430 = std.fmt.bufPrint(buf[pos..], "  <ellipse cx=\"{d}\" cy=\"{d}\" rx=\"{d}\" ry=\"{d}\" stroke=\"{s}\" stroke-width=\"{d}\" {s}/>\n", .{ b.x + @divTrunc(@as(i32, @intCast(b.w)), 2), b.y + @divTrunc(@as(i32, @intCast(b.h)), 2), @divTrunc(@as(i32, @intCast(b.w)), 2), @divTrunc(@as(i32, @intCast(b.h)), 2), hex_str, ann.stroke_width, fill_attr }) catch return error.BufOverflow;
                    pos += _part_1430.len;
                },
                .text => {
                    const slice = ann.text_buf[0..ann.text_len];
                    const align_str = switch (ann.text_align) {
                        .center => "middle",
                        .right => "end",
                        else => "start",
                    };
                    const _part_1435 = std.fmt.bufPrint(buf[pos..], "  <text x=\"{d}\" y=\"{d}\" font-size=\"{d}\" fill=\"{s}\" text-anchor=\"{s}\" font-family=\"sans-serif\">{s}</text>\n", .{ ann.rect.x + 2, ann.rect.y + @as(i32, @intCast(ann.font_size)), ann.font_size, hex_str, align_str, slice }) catch return error.BufOverflow;
                    pos += _part_1435.len;
                },
                .pen => {
                    if (ann.points.items.len < 2) continue;
                    const _part_1439 = std.fmt.bufPrint(buf[pos..], "  <polyline points=\"", .{}) catch return error.BufOverflow;
                    pos += _part_1439.len;
                    for (ann.points.items) |pt| {
                        const _part_1441 = std.fmt.bufPrint(buf[pos..], "{d},{d} ", .{ pt.x, pt.y }) catch return error.BufOverflow;
                        pos += _part_1441.len;
                    }
                    const _part_1443 = std.fmt.bufPrint(buf[pos..], "\" stroke=\"{s}\" stroke-width=\"{d}\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>\n", .{ hex_str, ann.stroke_width }) catch return error.BufOverflow;
                    pos += _part_1443.len;
                },
                .image => {
                    if (ann.image_data) |img| {
                        _ = img;
                        const _part_1448 = std.fmt.bufPrint(buf[pos..], "  <image x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" href=\"data:image/png;base64,\"/>\n", .{ ann.rect.x, ann.rect.y, ann.rect.w, ann.rect.h }) catch return error.BufOverflow;
                        pos += _part_1448.len;
                    }
                },
                else => {},
            }
        }
        const _part_1454 = std.fmt.bufPrint(buf[pos..], "</svg>\n", .{}) catch return error.BufOverflow;
        pos += _part_1454.len;
        const f = c.fopen(path.ptr, "wb");
        if (f == null) return error.FileWriteFailed;
        defer _ = c.fclose(f);
        _ = c.fwrite(buf[0..pos].ptr, 1, pos, f);
        var fb: [128]u8 = undefined;
        self.setStatus(std.fmt.bufPrint(&fb, "Exported SVG to {s}", .{path}) catch "SVG exported");
    }

    pub fn copyClipboard(self: *AnnotateApp) !void {
        var flat = try self.flattenImage();
        defer flat.deinit();
        try flat.copyToClipboard(self.allocator);
        self.setStatus("Copied to clipboard!");
    }

    pub fn pasteClipboard(self: *AnnotateApp) !void {
        // Try text clipboard first
        const txt_cmd = "export PATH=\"$PATH:/usr/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; wl-paste --type text/plain 2>/dev/null || wl-paste 2>/dev/null";
        if (c.popen(txt_cmd, "r")) |pipe_text| {
            defer _ = c.pclose(pipe_text);
            var text_buf: [1024]u8 = undefined;
            var total_len: usize = 0;
            while (true) {
                const n = c.fread(text_buf[total_len..].ptr, 1, text_buf.len - total_len, pipe_text);
                if (n == 0) break;
                total_len += @intCast(n);
            }
            if (total_len > 0) {
                const trimmed = std.mem.trim(u8, text_buf[0..total_len], " \t\r\n");
                if (trimmed.len > 0) {
                    self.pushUndoState();
                    const base_w = self.base_image.img.width;
                    const base_h = self.base_image.img.height;
                    var place_x: i32 = 0;
                    var place_y: i32 = 0;
                    const cur_x = self.win.pointer_x;
                    const cur_y = self.win.pointer_y;
                    const c_rect = self.canvasRect();
                    if (cur_x >= c_rect.x and cur_x < c_rect.x + @as(i32, @intCast(c_rect.w)) and
                        cur_y >= c_rect.y and cur_y < c_rect.y + @as(i32, @intCast(c_rect.h)))
                    {
                        const img_cx = self.screenToImageX(cur_x);
                        const img_cy = self.screenToImageY(cur_y);
                        place_x = img_cx - 60;
                        place_y = img_cy - @as(i32, @intCast(self.current_font_size));
                    } else {
                        place_x = @divTrunc(@as(i32, @intCast(base_w)), 2) - 60;
                        place_y = @divTrunc(@as(i32, @intCast(base_h)), 2);
                    }
                    const new_id = self.next_annotation_id;
                    self.next_annotation_id += 1;
                    var copy_buf: [1024]u8 = @splat(0);
                    const copy_len = @min(trimmed.len, 1023);
                    @memcpy(copy_buf[0..copy_len], trimmed[0..copy_len]);
                    const new_ann = Annotation{
                        .id = new_id,
                        .kind = .text,
                        .rect = Rect{ .x = place_x, .y = place_y, .w = 120, .h = @as(u32, @intCast(self.current_font_size + 8)) },
                        .text_buf = copy_buf,
                        .text_len = copy_len,
                        .font_size = self.current_font_size,
                        .color = self.current_color,
                        .text_align = .left,
                        .visible = true,
                        .locked = false,
                    };
                    try self.annotations.append(self.allocator, new_ann);
                    self.deselectAll();
                    try self.selected_ids.append(self.allocator, new_id);
                    self.selectOnly(new_id);
                    self.editing_text_id = new_id;
                    self.setStatus("Pasted text");
                    self.win.needs_redraw = true;
                    return;
                }
            }
        }

        // Fall back to image paste
        var pasted = (try ImageBuffer.loadFromClipboard(self.allocator)) orelse {
            self.setStatus("Clipboard has no image");
            return;
        };
        errdefer pasted.deinit();

        const base_w = self.base_image.img.width;
        const base_h = self.base_image.img.height;
        const max_w = @as(u32, @intCast(@max(50, @divTrunc(@as(i32, @intCast(base_w)) * 4, 5))));
        const max_h = @as(u32, @intCast(@max(50, @divTrunc(@as(i32, @intCast(base_h)) * 4, 5))));

        var target_w = pasted.width;
        var target_h = pasted.height;

        if (target_w > max_w or target_h > max_h) {
            const scale_w = @as(f32, @floatFromInt(max_w)) / @as(f32, @floatFromInt(target_w));
            const scale_h = @as(f32, @floatFromInt(max_h)) / @as(f32, @floatFromInt(target_h));
            const s = @min(scale_w, scale_h);
            target_w = @intFromFloat(@as(f32, @floatFromInt(target_w)) * s);
            target_h = @intFromFloat(@as(f32, @floatFromInt(target_h)) * s);
            target_w = @max(10, target_w);
            target_h = @max(10, target_h);
        }

        // Center pasted image at mouse if cursor is on canvas, otherwise canvas center
        var place_x: i32 = 0;
        var place_y: i32 = 0;
        const cur_x = self.win.pointer_x;
        const cur_y = self.win.pointer_y;
        const c_rect = self.canvasRect();

        if (cur_x >= c_rect.x and cur_x < c_rect.x + @as(i32, @intCast(c_rect.w)) and
            cur_y >= c_rect.y and cur_y < c_rect.y + @as(i32, @intCast(c_rect.h)))
        {
            const img_cx = self.screenToImageX(cur_x);
            const img_cy = self.screenToImageY(cur_y);
            place_x = img_cx - @as(i32, @intCast(target_w / 2));
            place_y = img_cy - @as(i32, @intCast(target_h / 2));
        } else {
            place_x = @divTrunc(@as(i32, @intCast(base_w)) - @as(i32, @intCast(target_w)), 2);
            place_y = @divTrunc(@as(i32, @intCast(base_h)) - @as(i32, @intCast(target_h)), 2);
        }

        self.pushUndoState();

        const new_id = self.next_annotation_id;
        self.next_annotation_id += 1;

        const new_ann = Annotation{
            .id = new_id,
            .kind = .image,
            .rect = Rect{
                .x = place_x,
                .y = place_y,
                .w = target_w,
                .h = target_h,
            },
            .image_data = pasted,
            .visible = true,
            .locked = false,
        };

        try self.annotations.append(self.allocator, new_ann);
        self.deselectAll();
        try self.selected_ids.append(self.allocator, new_id);
        self.setActiveTool(.select);
        self.setStatus("Pasted image layer");
        self.win.needs_redraw = true;
    }

    pub fn zoomAt(self: *AnnotateApp, cursor_x: f32, cursor_y: f32, factor: f32) void {
        const old_zoom = self.zoom;
        var new_zoom = old_zoom * factor;
        new_zoom = std.math.clamp(new_zoom, 0.05, 20.0);
        if (new_zoom == old_zoom) return;

        self.pan_x = cursor_x - ((cursor_x - self.pan_x) / old_zoom) * new_zoom;
        self.pan_y = cursor_y - ((cursor_y - self.pan_y) / old_zoom) * new_zoom;
        self.zoom = new_zoom;
        self.win.needs_redraw = true;
    }

    // Crop & Base Transformations
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

    // Event Handling
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
            self.win.setCursorShape(.move);
            self.win.needs_redraw = true;
            return;
        }

        if (self.win.is_ctrl and inside_canvas and !self.is_drawing and !self.is_resizing) {
            self.win.setCursorShape(.grab);
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

        if (self.text_editor) |*te| {
            if (te.drag_active) {
                if (self.findAnnotationById(te.annotation_id)) |ann| {
                    const sx = self.imageToScreenX(ann.rect.x);
                    const sy = self.imageToScreenY(ann.rect.y);
                    const rel_x = x - sx;
                    const rel_y = y - sy;
                    const font_sz = ann.font_size;
                    const line_h = font_sz + @max(4, @divTrunc(font_sz, 4));
                    const new_idx = te.findCursorFromXY(self.font, font_sz, line_h, rel_x, rel_y);
                    if (te.selection_anchor == null) {
                        te.selection_anchor = te.cursor_idx;
                    }
                    te.cursor_idx = new_idx;
                    self.win.needs_redraw = true;
                    return;
                }
            }
        }

        if (self.is_drawing) {
            self.drag_curr_x = img_x;
            self.drag_curr_y = img_y;

            if (self.active_tool == .freehand and self.annotations.items.len > 0) {
                const last_idx = self.annotations.items.len - 1;
                self.annotations.items[last_idx].points.append(self.allocator, .{ .x = img_x, .y = img_y }) catch {};
            } else if (self.active_tool == .eraser) {
                _ = self.eraseAnnotationAt(img_x, img_y);
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

    fn handleColorDialogClick(self: *AnnotateApp, x: i32, y: i32) bool {
        if (!self.color_dialog_open) return false;
        const is_narrow = (self.win.width < 960);
        const dlg_lx: i32 = if (is_narrow) 140 else @min(@as(i32, @intCast(self.win.width)) - 220, 680);
        const dlg_ly: i32 = if (is_narrow) 76 else @as(i32, @intCast(self.toolbar_height)) + 2;
        const dlg_lw: i32 = 210;
        const dlg_lh: i32 = 72;

        if (x < dlg_lx or x >= dlg_lx + dlg_lw or y < dlg_ly or y >= dlg_ly + dlg_lh) {
            // Click outside dialog closes it
            self.closeColorDialog();
            return false;
        }

        // Close button: top right
        if (x >= dlg_lx + dlg_lw - 28 and y <= dlg_ly + 28) {
            self.closeColorDialog();
            return true;
        }

        // Apply button "✓"
        if (x >= dlg_lx + 160 and y >= dlg_ly + 24) {
            self.applyColorDialog();
            return true;
        }

        // Swatch preview click: apply if valid
        if (x >= dlg_lx + 8 and x <= dlg_lx + 44 and y >= dlg_ly + 24) {
            self.applyColorDialog();
            return true;
        }

        // Input box click: position cursor at end
        if (x >= dlg_lx + 44 and x < dlg_lx + 160 and y >= dlg_ly + 24) {
            self.color_dialog_cursor = self.color_dialog_len;
            self.win.needs_redraw = true;
            return true;
        }

        return true;
    }

    pub fn handlePointerButton(self: *AnnotateApp, x: i32, y: i32, button: u32, pressed: bool) void {
        const c_rect = self.canvasRect();
        const inside_canvas = (x >= c_rect.x and y >= c_rect.y and x < c_rect.x + @as(i32, @intCast(c_rect.w)) and y < c_rect.y + @as(i32, @intCast(c_rect.h)));

        // Pan with Middle Click (0x112) or Ctrl + Left Click (0x110)
        if (button == 0x112 or (button == 0x110 and self.win.is_ctrl and inside_canvas)) {
            if (pressed) {
                self.is_panning = true;
                self.pan_start_x = x;
                self.pan_start_y = y;
                self.win.setCursorShape(.move);
            } else {
                self.is_panning = false;
                self.win.setCursorShape(if (self.win.is_ctrl) .grab else .default);
            }
            self.win.needs_redraw = true;
            return;
        }

        if (!pressed and self.is_panning) {
            self.is_panning = false;
            self.win.setCursorShape(if (self.win.is_ctrl) .grab else .default);
            self.win.needs_redraw = true;
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

                // Check color dialog clicks
                if (self.color_dialog_open) {
                    if (self.handleColorDialogClick(x, y)) {
                        return;
                    }
                }

                // Check toolbar clicks
                if (y < @as(i32, @intCast(self.toolbar_height))) {
                    self.handleToolbarClick(x, y);
                    return;
                }

                // Check font dropdown clicks
                if (self.font_dropdown_open) {
                    const dx: i32 = 282;
                    const dy: i32 = @as(i32, @intCast(self.toolbar_height)) + 2;
                    const dw: i32 = 90;
                    const dh: i32 = 195;
                    if (x >= dx and x < dx + dw and y >= dy and y < dy + dh) {
                        const row_idx = @divTrunc(y - dy - 8, 30);
                        const sizes = [_]u32{ 12, 16, 20, 24, 32, 48 };
                        if (row_idx >= 0 and @as(usize, @intCast(row_idx)) < sizes.len) {
                            self.current_font_size = sizes[@as(usize, @intCast(row_idx))];
                            for (self.selected_ids.items) |sid| {
                                if (self.findAnnotationById(sid)) |a| a.font_size = self.current_font_size;
                            }
                            self.win.needs_redraw = true;
                        }
                        self.font_dropdown_open = false;
                        self.win.needs_redraw = true;
                        return;
                    } else {
                        self.font_dropdown_open = false;
                        self.win.needs_redraw = true;
                        return;
                    }
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

                // Check if clicking inside active text editor
                if (self.text_editor) |*te| {
                    if (self.findAnnotationById(te.annotation_id)) |ann| {
                        const sx = self.imageToScreenX(ann.rect.x);
                        const sy = self.imageToScreenY(ann.rect.y);
                        const sw = @as(i32, @intCast(ann.rect.w));
                        const sh = @as(i32, @intCast(ann.rect.h));
                        if (x >= sx - 4 and x <= sx + sw + 16 and y >= sy - 4 and y <= sy + sh + 8) {
                            te.drag_active = true;
                            const rel_x = x - sx;
                            const rel_y = y - sy;
                            const font_sz = ann.font_size;
                            const line_h = font_sz + @max(4, @divTrunc(font_sz, 4));
                            const new_idx = te.findCursorFromXY(self.font, font_sz, line_h, rel_x, rel_y);
                            te.cursor_idx = new_idx;
                            te.selection_anchor = null;
                            self.win.needs_redraw = true;
                            return;
                        }
                    }
                    self.commitTextEditing();
                } else if (self.editing_text_id != null) {
                    self.commitTextEditing();
                }
                if (self.editing_font_size) {
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
                            } else if (self.findAnnotationById(cid)) |ann| {
                                if (ann.kind == .text) {
                                    self.startTextEditing(cid);
                                    return;
                                }
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

                    // Text tool: click to create inline text annotation or edit existing
                    if (self.active_tool == .text) {
                        var clicked_text: ?u32 = null;
                        var idx: usize = self.annotations.items.len;
                        while (idx > 0) {
                            idx -= 1;
                            const ann = &self.annotations.items[idx];
                            if (ann.kind == .text and ann.hitTest(img_x, img_y)) {
                                clicked_text = ann.id;
                                break;
                            }
                        }

                        if (clicked_text) |tid| {
                            self.startTextEditing(tid);
                            return;
                        }

                        self.pushUndoState();
                        const new_id = self.next_annotation_id;
                        self.next_annotation_id += 1;

                        const new_ann = Annotation{
                            .id = new_id,
                            .kind = .text,
                            .rect = Rect{ .x = img_x, .y = img_y, .w = 40, .h = @intCast(self.current_font_size + 8) },
                            .font_size = self.current_font_size,
                            .color = self.current_color,
                        };
                        self.annotations.append(self.allocator, new_ann) catch return;
                        self.startTextEditing(new_id);
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

                    // Eraser tool: vector eraser deletes touched annotations
                    if (self.active_tool == .eraser) {
                        self.is_drawing = true;
                        self.has_pushed_eraser_undo = false;
                        _ = self.eraseAnnotationAt(img_x, img_y);
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
                if (self.text_editor) |*te| {
                    te.drag_active = false;
                    if (te.selection_anchor) |anchor| {
                        if (anchor == te.cursor_idx) {
                            te.selection_anchor = null;
                        }
                    }
                }
                if (self.active_tool == .eraser) {
                    self.is_drawing = false;
                    self.has_pushed_eraser_undo = false;
                }
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

    pub fn startTextEditing(self: *AnnotateApp, id: u32) void {
        if (self.text_editor != null) {
            self.commitTextEditing();
        }
        const ann = self.findAnnotationById(id) orelse return;
        if (ann.kind != .text) return;

        self.text_editor = TextEditState.init(self.allocator, id, ann.text_buf[0..ann.text_len]) catch return;
        self.editing_text_id = id;
        self.selectOnly(id);
        self.win.needs_redraw = true;
    }

    pub fn commitTextEditing(self: *AnnotateApp) void {
        if (self.text_editor) |*te| {
            const ann_id = te.annotation_id;
            const text_items = te.text.items;
            if (self.findAnnotationById(ann_id)) |ann| {
                if (text_items.len == 0) {
                    self.deleteAnnotationById(ann_id);
                } else {
                    const copy_len = @min(text_items.len, ann.text_buf.len - 1);
                    @memcpy(ann.text_buf[0..copy_len], text_items[0..copy_len]);
                    ann.text_buf[copy_len] = 0;
                    ann.text_len = copy_len;
                    self.updateTextAnnotationBounds(ann);
                }
            }
            var mut_te = te;
            mut_te.deinit();
            self.text_editor = null;
            self.editing_text_id = null;
            self.win.needs_redraw = true;
        } else if (self.editing_text_id) |tid| {
            if (self.findAnnotationById(tid)) |ann| {
                if (ann.text_len == 0) {
                    self.deleteAnnotationById(tid);
                } else {
                    self.updateTextAnnotationBounds(ann);
                }
            }
            self.editing_text_id = null;
            self.win.needs_redraw = true;
        }

        if (self.editing_font_size) {
            if (self.font_size_len > 0) {
                var num: u32 = 0;
                for (self.font_size_buf[0..self.font_size_len]) |ch| {
                    if (ch >= 48 and ch <= 57) num = num * 10 + (ch - 48);
                }
                if (num >= 8 and num <= 120) self.current_font_size = num;
                self.editing_font_size = false;
                self.win.needs_redraw = true;
            }
        }
    }

    pub fn handleKey(self: *AnnotateApp, sym: u32, utf8: []const u8, is_ctrl: bool, is_shift: bool) void {
        // Typing into active custom hex color dialog
        if (self.color_dialog_open) {
            switch (sym) {
                c.XKB_KEY_Escape => {
                    self.closeColorDialog();
                    return;
                },
                c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => {
                    self.applyColorDialog();
                    return;
                },
                c.XKB_KEY_BackSpace => {
                    if (self.color_dialog_cursor > 0 and self.color_dialog_len > 0) {
                        var i = self.color_dialog_cursor - 1;
                        while (i + 1 < self.color_dialog_len) : (i += 1) {
                            self.color_dialog_buf[i] = self.color_dialog_buf[i + 1];
                        }
                        self.color_dialog_len -= 1;
                        self.color_dialog_cursor -= 1;
                        self.win.needs_redraw = true;
                    }
                    return;
                },
                c.XKB_KEY_Delete => {
                    if (self.color_dialog_cursor < self.color_dialog_len) {
                        var i = self.color_dialog_cursor;
                        while (i + 1 < self.color_dialog_len) : (i += 1) {
                            self.color_dialog_buf[i] = self.color_dialog_buf[i + 1];
                        }
                        self.color_dialog_len -= 1;
                        self.win.needs_redraw = true;
                    }
                    return;
                },
                c.XKB_KEY_Left => {
                    if (self.color_dialog_cursor > 0) {
                        self.color_dialog_cursor -= 1;
                        self.win.needs_redraw = true;
                    }
                    return;
                },
                c.XKB_KEY_Right => {
                    if (self.color_dialog_cursor < self.color_dialog_len) {
                        self.color_dialog_cursor += 1;
                        self.win.needs_redraw = true;
                    }
                    return;
                },
                else => {
                    if (is_ctrl and (sym == c.XKB_KEY_v or sym == c.XKB_KEY_V)) {
                        self.pasteHexFromClipboard();
                        return;
                    }
                    if (utf8.len > 0) {
                        const ch = utf8[0];
                        if ((ch == '#' or std.ascii.isHex(ch)) and self.color_dialog_len < 9) {
                            var i = self.color_dialog_len;
                            while (i > self.color_dialog_cursor) : (i -= 1) {
                                self.color_dialog_buf[i] = self.color_dialog_buf[i - 1];
                            }
                            self.color_dialog_buf[self.color_dialog_cursor] = ch;
                            self.color_dialog_len += 1;
                            self.color_dialog_cursor += 1;
                            self.win.needs_redraw = true;
                        }
                    }
                    return;
                },
            }
        }

        // Typing into active inline text editor
        if (self.text_editor) |*te| {
            if (is_ctrl) {
                switch (sym) {
                    c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => {
                        self.commitTextEditing();
                        return;
                    },
                    c.XKB_KEY_a, c.XKB_KEY_A => {
                        te.selectAll();
                        self.win.needs_redraw = true;
                        return;
                    },
                    c.XKB_KEY_c, c.XKB_KEY_C => {
                        te.copyToClipboard();
                        self.setStatus("Copied text");
                        self.win.needs_redraw = true;
                        return;
                    },
                    c.XKB_KEY_x, c.XKB_KEY_X => {
                        te.cutToClipboard();
                        if (self.findAnnotationById(te.annotation_id)) |ann| self.updateTextAnnotationBounds(ann);
                        self.setStatus("Cut text");
                        self.win.needs_redraw = true;
                        return;
                    },
                    c.XKB_KEY_v, c.XKB_KEY_V => {
                        te.pasteFromClipboard();
                        if (self.findAnnotationById(te.annotation_id)) |ann| self.updateTextAnnotationBounds(ann);
                        self.setStatus("Pasted text");
                        self.win.needs_redraw = true;
                        return;
                    },
                    c.XKB_KEY_z, c.XKB_KEY_Z => {
                        te.undo();
                        if (self.findAnnotationById(te.annotation_id)) |ann| self.updateTextAnnotationBounds(ann);
                        self.win.needs_redraw = true;
                        return;
                    },
                    c.XKB_KEY_y, c.XKB_KEY_Y => {
                        te.redo();
                        if (self.findAnnotationById(te.annotation_id)) |ann| self.updateTextAnnotationBounds(ann);
                        self.win.needs_redraw = true;
                        return;
                    },
                    c.XKB_KEY_BackSpace => {
                        te.deleteWordBackward();
                        if (self.findAnnotationById(te.annotation_id)) |ann| self.updateTextAnnotationBounds(ann);
                        self.win.needs_redraw = true;
                        return;
                    },
                    c.XKB_KEY_Delete => {
                        te.deleteWordForward();
                        if (self.findAnnotationById(te.annotation_id)) |ann| self.updateTextAnnotationBounds(ann);
                        self.win.needs_redraw = true;
                        return;
                    },
                    c.XKB_KEY_Left => {
                        te.moveWordLeft(is_shift);
                        self.win.needs_redraw = true;
                        return;
                    },
                    c.XKB_KEY_Right => {
                        te.moveWordRight(is_shift);
                        self.win.needs_redraw = true;
                        return;
                    },
                    c.XKB_KEY_Home => {
                        te.moveHome(is_shift, true);
                        self.win.needs_redraw = true;
                        return;
                    },
                    c.XKB_KEY_End => {
                        te.moveEnd(is_shift, true);
                        self.win.needs_redraw = true;
                        return;
                    },
                    else => {},
                }
            } else {
                switch (sym) {
                    c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => {
                        te.insertBytes("\n") catch {};
                        if (self.findAnnotationById(te.annotation_id)) |ann| self.updateTextAnnotationBounds(ann);
                        self.win.needs_redraw = true;
                        return;
                    },
                    c.XKB_KEY_Escape => {
                        self.commitTextEditing();
                        return;
                    },
                    c.XKB_KEY_BackSpace => {
                        te.deleteBackward();
                        if (self.findAnnotationById(te.annotation_id)) |ann| self.updateTextAnnotationBounds(ann);
                        self.win.needs_redraw = true;
                        return;
                    },
                    c.XKB_KEY_Delete => {
                        te.deleteForward();
                        if (self.findAnnotationById(te.annotation_id)) |ann| self.updateTextAnnotationBounds(ann);
                        self.win.needs_redraw = true;
                        return;
                    },
                    c.XKB_KEY_Left => {
                        te.moveLeft(is_shift);
                        self.win.needs_redraw = true;
                        return;
                    },
                    c.XKB_KEY_Right => {
                        te.moveRight(is_shift);
                        self.win.needs_redraw = true;
                        return;
                    },
                    c.XKB_KEY_Up => {
                        if (self.findAnnotationById(te.annotation_id)) |ann| {
                            te.moveUp(is_shift, self.font, ann.font_size);
                        }
                        self.win.needs_redraw = true;
                        return;
                    },
                    c.XKB_KEY_Down => {
                        if (self.findAnnotationById(te.annotation_id)) |ann| {
                            te.moveDown(is_shift, self.font, ann.font_size);
                        }
                        self.win.needs_redraw = true;
                        return;
                    },
                    c.XKB_KEY_Home => {
                        te.moveHome(is_shift, false);
                        self.win.needs_redraw = true;
                        return;
                    },
                    c.XKB_KEY_End => {
                        te.moveEnd(is_shift, false);
                        self.win.needs_redraw = true;
                        return;
                    },
                    else => {
                        if (utf8.len > 0) {
                            te.insertBytes(utf8) catch {};
                            if (self.findAnnotationById(te.annotation_id)) |ann| self.updateTextAnnotationBounds(ann);
                            self.win.needs_redraw = true;
                            return;
                        }
                    },
                }
            }
            return;
        }

        // Font size input box editing
        if (self.editing_font_size) {
            if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_KP_Enter) {
                self.commitTextEditing();
                return;
            } else if (sym == c.XKB_KEY_Escape) {
                self.editing_font_size = false;
                self.win.needs_redraw = true;
                return;
            } else if (sym == c.XKB_KEY_BackSpace) {
                if (self.font_size_len > 0) {
                    self.font_size_len -= 1;
                    self.font_size_buf[self.font_size_len] = 0;
                    self.win.needs_redraw = true;
                }
                return;
            } else if (utf8.len > 0 and self.font_size_len + utf8.len < self.font_size_buf.len) {
                @memcpy(self.font_size_buf[self.font_size_len .. self.font_size_len + utf8.len], utf8);
                self.font_size_len += utf8.len;
                self.win.needs_redraw = true;
                return;
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
            } else if (sym == c.XKB_KEY_v or sym == c.XKB_KEY_V) {
                self.pasteClipboard() catch self.setStatus("Paste failed");
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
            c.XKB_KEY_0 => self.fitToWindow(),
            c.XKB_KEY_plus, c.XKB_KEY_equal, c.XKB_KEY_KP_Add => {
                const cx = @as(f32, @floatFromInt(self.win.width)) * 0.5;
                const cy = @as(f32, @floatFromInt(self.win.height)) * 0.5;
                self.zoomAt(cx, cy, 1.2);
            },
            c.XKB_KEY_minus, c.XKB_KEY_underscore, c.XKB_KEY_KP_Subtract => {
                const cx = @as(f32, @floatFromInt(self.win.width)) * 0.5;
                const cy = @as(f32, @floatFromInt(self.win.height)) * 0.5;
                self.zoomAt(cx, cy, 0.8);
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

    pub fn cycleFontSize(self: *AnnotateApp) void {
        const sizes = [_]u32{ 12, 16, 20, 24, 32, 48 };
        var next_sz: u32 = sizes[0];
        for (sizes, 0..) |sz, i| {
            if (sz > self.current_font_size) {
                next_sz = sz;
                break;
            }
            if (i == sizes.len - 1) {
                next_sz = sizes[0];
            }
        }
        self.current_font_size = next_sz;
        var updated_text = false;
        for (self.selected_ids.items) |sid| {
            if (self.findAnnotationById(sid)) |a| {
                if (a.kind == .text) {
                    a.font_size = self.current_font_size;
                    self.updateTextAnnotationBounds(a);
                    updated_text = true;
                }
            }
        }
        var buf: [32]u8 = undefined;
        self.setStatus(std.fmt.bufPrint(&buf, "Font size: {d}px", .{self.current_font_size}) catch "Font size");
        self.win.needs_redraw = true;
    }

    fn handleToolbarClick(self: *AnnotateApp, x: i32, y: i32) void {
        const is_narrow = (self.win.width < 960);
        const on_row2 = is_narrow and (y >= 38);

        if (!on_row2) {
            var bx: i32 = 12;
            const btn_w: i32 = 28;

            if (x >= bx and x < bx + btn_w) {
                self.setActiveTool(.select);
                return;
            }
            bx += btn_w + 13;

            if (x >= bx and x < bx + btn_w) {
                self.setActiveTool(.freehand);
                return;
            }
            bx += btn_w + 13;

            if (x >= bx and x < bx + btn_w) {
                self.setActiveTool(.arrow);
                return;
            }
            bx += btn_w + 3;
            if (x >= bx and x < bx + btn_w) {
                self.setActiveTool(.line);
                return;
            }
            bx += btn_w + 13;

            if (x >= bx and x < bx + btn_w) {
                self.setActiveTool(.rect);
                return;
            }
            bx += btn_w + 3;
            if (x >= bx and x < bx + btn_w) {
                self.setActiveTool(.circle);
                return;
            }
            bx += btn_w + 3;
            if (x >= bx and x < bx + btn_w) {
                self.fill_shape = !self.fill_shape;
                for (self.selected_ids.items) |sid| {
                    if (self.findAnnotationById(sid)) |a| a.filled = self.fill_shape;
                }
                self.setStatus(if (self.fill_shape) "Fill: Enabled" else "Fill: Disabled");
                self.win.needs_redraw = true;
                return;
            }
            bx += btn_w + 13;

            if (x >= bx and x < bx + btn_w) {
                self.setActiveTool(.text);
                return;
            }
            bx += btn_w + 4;
            if (x >= bx and x < bx + 20) {
                self.decreaseFontSize();
                return;
            }
            bx += 20 + 2;
            if (x >= bx and x < bx + 36) {
                self.font_dropdown_open = !self.font_dropdown_open;
                self.win.needs_redraw = true;
                return;
            }
            bx += 36 + 2;
            if (x >= bx and x < bx + 20) {
                self.increaseFontSize();
                return;
            }
            bx += 20 + 13;

            if (x >= bx and x < bx + btn_w) {
                self.setActiveTool(.step_badge);
                return;
            }
            bx += btn_w + 13;

            if (x >= bx and x < bx + btn_w) {
                self.setActiveTool(.blur);
                return;
            }
            bx += btn_w + 3;
            if (x >= bx and x < bx + btn_w) {
                self.setActiveTool(.pixelate);
                return;
            }
            bx += btn_w + 13;

            if (x >= bx and x < bx + btn_w) {
                self.setActiveTool(.highlight);
                return;
            }
            bx += btn_w + 13;

            if (x >= bx and x < bx + btn_w) {
                self.setActiveTool(.eraser);
                return;
            }
            bx += btn_w + 13;

            if (x >= bx and x < bx + btn_w) {
                self.startCrop();
                return;
            }
            bx += btn_w + 13;

            if (!is_narrow) {
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

                if (x >= bx and x < bx + 26) {
                    self.openColorDialog();
                    return;
                }
                bx += 29;

                if (x >= bx and x < bx + 26) {
                    self.pickColorFromScreen();
                    return;
                }
                bx += 29;

                const rx_base: i32 = @as(i32, @intCast(self.win.width)) - 138;
                if (x >= rx_base) {
                    var rx = rx_base;
                    if (x >= rx and x < rx + 28) {
                        self.undo();
                        return;
                    }
                    rx += 31;
                    if (x >= rx and x < rx + 28) {
                        self.redo();
                        return;
                    }
                    rx += 33;
                    if (x >= rx and x < rx + 28) {
                        self.save() catch {};
                        return;
                    }
                    rx += 31;
                    if (x >= rx and x < rx + 32) {
                        self.copyClipboard() catch {};
                        return;
                    }
                }
            }
        } else {
            // Row 2 on narrow windows: Palette, Picker, Actions
            var bx2: i32 = 12;
            for (Palette.colors) |col| {
                if (x >= bx2 and x < bx2 + 16) {
                    self.current_color = col;
                    for (self.selected_ids.items) |sid| {
                        if (self.findAnnotationById(sid)) |a| a.color = col;
                    }
                    self.win.needs_redraw = true;
                    return;
                }
                bx2 += 18;
            }

            // Palette icon () -> open custom hex input
            if (x >= bx2 and x < bx2 + 26) {
                self.openColorDialog();
                return;
            }
            bx2 += 29;

            // Color picker (󰈊) -> pick from screen, set color & copy to clipboard
            if (x >= bx2 and x < bx2 + 26) {
                self.pickColorFromScreen();
                return;
            }
            bx2 += 29;

            const rx_base: i32 = @as(i32, @intCast(self.win.width)) - 138;
            if (x >= rx_base) {
                var rx = rx_base;
                if (x >= rx and x < rx + 28) {
                    self.undo();
                    return;
                }
                rx += 31;
                if (x >= rx and x < rx + 28) {
                    self.redo();
                    return;
                }
                rx += 33;
                if (x >= rx and x < rx + 28) {
                    self.save() catch {};
                    return;
                }
                rx += 31;
                if (x >= rx and x < rx + 32) {
                    self.copyClipboard() catch {};
                    return;
                }
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
            if (x >= 120 and x < 195) {
                self.commitCrop() catch {};
                return;
            } else if (x >= 205 and x < 270) {
                self.cancelCrop();
                return;
            }
        }

        const total_zoom_w: i32 = 110;
        const right_margin: i32 = 12;
        const zoom_x: i32 = @as(i32, @intCast(self.win.width)) - total_zoom_w - right_margin;
        const center_x = @as(f32, @floatFromInt(self.win.width)) * 0.5;
        const center_y = @as(f32, @floatFromInt(self.win.height)) * 0.5;

        if (x >= zoom_x and x < zoom_x + 26) {
            // [-] Zoom out
            self.zoomAt(center_x, center_y, 0.8);
        } else if (x >= zoom_x + 28 and x < zoom_x + 84) {
            // [%] Toggle fit to window / 100% actual size
            if (@abs(self.zoom - 1.0) < 0.05) {
                self.fitToWindow();
            } else {
                self.zoomAt(center_x, center_y, 1.0 / self.zoom);
            }
        } else if (x >= zoom_x + 86 and x < zoom_x + 112) {
            // [+] Zoom in
            self.zoomAt(center_x, center_y, 1.25);
        }
    }

    // Rendering
    pub fn render(self: *AnnotateApp) !void {
        var r = try self.win.getRenderer();
        const th = self.cfg.theme;

        r.clear(th.base);

        // Canvas Area (clipped in physical framebuffer coordinates)
        const c_rect = self.toPhysRect(self.canvasRect());
        var canvas_renderer = r.withClip(c_rect);

        // Render Base Image in Physical Coordinates
        const dest_px = self.imageToPhysX(0);
        const dest_py = self.imageToPhysY(0);
        const phys_w: f64 = @as(f64, @floatFromInt(self.base_image.img.width)) * @as(f64, self.zoom * self.effectiveScale());
        const phys_h: f64 = @as(f64, @floatFromInt(self.base_image.img.height)) * @as(f64, self.zoom * self.effectiveScale());

        // Soft drop shadow behind canvas
        canvas_renderer.drawSoftShadow(
            dest_px,
            dest_py,
            @intFromFloat(phys_w),
            @intFromFloat(phys_h),
            self.toPhysSize(8),
            self.toPhysSize(16),
            @as(i32, @intCast(self.toPhysSize(4))),
            th.shadow_dark,
        );

        const r_img = renderer.Image{
            .width = self.base_image.img.width,
            .height = self.base_image.img.height,
            .pixels = self.base_image.img.pixels,
            .allocator = self.allocator,
        };
        canvas_renderer.drawImage(&r_img, @floatFromInt(dest_px), @floatFromInt(dest_py), phys_w, phys_h);

        canvas_renderer.drawRoundedBorder(
            dest_px,
            dest_py,
            @intFromFloat(phys_w),
            @intFromFloat(phys_h),
            self.toPhysSize(2),
            self.toPhysSize(1),
            th.border,
        );

        // Render Vector Annotations in z-order
        for (self.annotations.items) |*ann| {
            if (!ann.visible) continue;
            self.renderAnnotationOnCanvas(canvas_renderer, ann);
        }

        // Render Active Drawing Preview
        if (self.is_drawing and self.active_tool != .freehand and self.active_tool != .eraser) {
            self.renderDrawingPreview(canvas_renderer);
        }

        // Render Crop Overlay
        if (self.is_crop_mode) {
            self.renderCropOverlay(canvas_renderer);
        }

        // Render Marquee Selection Box
        if (self.is_marquee) {
            const mx0 = self.imageToPhysX(self.drag_start_x);
            const my0 = self.imageToPhysY(self.drag_start_y);
            const mx1 = self.imageToPhysX(self.drag_curr_x);
            const my1 = self.imageToPhysY(self.drag_curr_y);
            const rx = @min(mx0, mx1);
            const ry = @min(my0, my1);
            const rw: u32 = @intCast(@abs(mx1 - mx0));
            const rh: u32 = @intCast(@abs(my1 - my0));
            canvas_renderer.fillRect(rx, ry, rw, rh, Color.init(35, 97, 175, 239));
            canvas_renderer.drawRoundedBorder(rx, ry, rw, rh, 0, 1, th.accent);
        }

        // Render Selection Bounding Box & Handles
        self.renderSelectionHandles(canvas_renderer);

        // Render Active Inline Text Editor
        if (self.text_editor != null and self.editing_text_id != null) {
            self.renderInlineTextEditor(canvas_renderer);
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

        // Render Font Size Dropdown
        if (self.font_dropdown_open) {
            self.renderFontDropdown(r);
        }

        // Render Custom Hex Color Dialog
        if (self.color_dialog_open) {
            self.renderColorDialog(r);
        }

        if (self.status_ticks > 0) {
            self.status_ticks -= 1;
            if (self.status_ticks == 0) self.status_len = 0;
        }
    }

    fn renderInlineTextEditor(self: *AnnotateApp, r: renderer.Renderer) void {
        const ed = self.text_editor orelse return;
        const ann = self.findAnnotationById(ed.annotation_id) orelse return;
        const th = self.cfg.theme;

        const sx = self.imageToPhysX(ann.rect.x);
        const sy = self.imageToPhysY(ann.rect.y);
        const phys_fs = @max(10, @as(u32, @intFromFloat(@as(f32, @floatFromInt(ann.font_size)) * self.zoom * self.effectiveScale())));
        const line_h = @as(i32, @intCast(phys_fs + @max(2, @divTrunc(phys_fs, 4))));

        const phys_w = @max(self.toPhysSize(60), @as(u32, @intCast(@max(40, self.imageToPhysX(ann.rect.x + @as(i32, @intCast(ann.rect.w))) - sx))));
        const phys_h = @max(self.toPhysSize(30), @as(u32, @intCast(@max(24, self.imageToPhysY(ann.rect.y + @as(i32, @intCast(ann.rect.h))) - sy))));
        const pad_x = self.toPhysSize(4);
        const pad_y = self.toPhysSize(4);
        const pad_xi: i32 = @intCast(pad_x);
        const pad_yi: i32 = @intCast(pad_y);

        // Transparent background: NO background fill while typing!
        // Subtle 1px accent border ONLY while editing
        r.drawRoundedBorder(sx - pad_xi, sy - pad_yi, phys_w + pad_x * 2, phys_h + pad_y * 2, self.toPhysSize(2), 1, th.accent);

        // Find selection range if any
        const sel_range = ed.getSelectionRange();

        // Render line by line
        const slice = ed.text.items;
        var line_it = std.mem.splitScalar(u8, slice, '\n');
        var line_idx: usize = 0;
        var byte_offset: usize = 0;

        var caret_x: i32 = sx;
        var caret_y: i32 = sy;

        while (line_it.next()) |line| : (line_idx += 1) {
            const line_start = byte_offset;
            const line_end = byte_offset + line.len;
            const line_y = sy + @as(i32, @intCast(line_idx)) * line_h;

            // Render selection background for this line if selected
            if (sel_range) |sr| {
                if (sr.start < line_end and sr.end > line_start) {
                    const sel_sub_start = @max(sr.start, line_start) - line_start;
                    const sel_sub_end = @min(sr.end, line_end) - line_start;
                    const pre_w = r.measureTextWithSize(self.font, line[0..sel_sub_start], phys_fs);
                    const sel_w = r.measureTextWithSize(self.font, line[sel_sub_start..sel_sub_end], phys_fs);
                    r.fillRect(sx + @as(i32, @intCast(pre_w)), line_y, sel_w, @intCast(line_h), Color.init(90, 97, 175, 239));
                }
            }

            // Draw line text
            r.drawTextWithSize(self.font, line, sx, line_y + @as(i32, @intCast(phys_fs)), phys_fs, ann.color);

            // Check if cursor is on this line
            if (ed.cursor_idx >= line_start and (ed.cursor_idx <= line_end or line_it.index == null)) {
                const cursor_col = ed.cursor_idx - line_start;
                const cw = r.measureTextWithSize(self.font, line[0..cursor_col], phys_fs);
                caret_x = sx + @as(i32, @intCast(cw));
                caret_y = line_y;
            }

            byte_offset = line_end + 1; // skip \n
        }

        // Draw cursor (2px wide)
        r.fillRect(caret_x, caret_y, self.toPhysSize(2), phys_fs + 2, th.accent);
    }

    fn renderAnnotationOnCanvas(self: *AnnotateApp, r: renderer.Renderer, ann: *const Annotation) void {
        const th = self.cfg.theme;
        const scaled_sw = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(ann.stroke_width)) * self.zoom * self.effectiveScale())));

        switch (ann.kind) {
            .arrow => {
                const sx0 = self.imageToPhysX(ann.start_x);
                const sy0 = self.imageToPhysY(ann.start_y);
                const sx1 = self.imageToPhysX(ann.end_x);
                const sy1 = self.imageToPhysY(ann.end_y);
                r.drawArrow(sx0, sy0, sx1, sy1, scaled_sw, ann.color);
            },
            .line => {
                const sx0 = self.imageToPhysX(ann.start_x);
                const sy0 = self.imageToPhysY(ann.start_y);
                const sx1 = self.imageToPhysX(ann.end_x);
                const sy1 = self.imageToPhysY(ann.end_y);
                r.drawStrokeLine(sx0, sy0, sx1, sy1, scaled_sw, ann.color);
            },
            .rect => {
                const b = ann.getBounds();
                const sx0 = self.imageToPhysX(b.x);
                const sy0 = self.imageToPhysY(b.y);
                const sx1 = self.imageToPhysX(b.x + @as(i32, @intCast(b.w)));
                const sy1 = self.imageToPhysY(b.y + @as(i32, @intCast(b.h)));
                const rx = @min(sx0, sx1);
                const ry = @min(sy0, sy1);
                const rw: u32 = @intCast(@abs(sx1 - sx0));
                const rh: u32 = @intCast(@abs(sy1 - sy0));
                const cr = self.toPhysSize(4);
                if (ann.filled) {
                    r.fillRoundedRect(rx, ry, rw, rh, cr, ann.color);
                } else {
                    r.drawRoundedBorder(rx, ry, rw, rh, cr, scaled_sw, ann.color);
                }
            },
            .circle => {
                const b = ann.getBounds();
                const sx0 = self.imageToPhysX(b.x);
                const sy0 = self.imageToPhysY(b.y);
                const sx1 = self.imageToPhysX(b.x + @as(i32, @intCast(b.w)));
                const sy1 = self.imageToPhysY(b.y + @as(i32, @intCast(b.h)));
                const rx = @min(sx0, sx1);
                const ry = @min(sy0, sy1);
                const rw: u32 = @intCast(@abs(sx1 - sx0));
                const rh: u32 = @intCast(@abs(sy1 - sy0));
                const cx = rx + @as(i32, @intCast(@divTrunc(rw, 2)));
                const cy = ry + @as(i32, @intCast(@divTrunc(rh, 2)));
                const rad_x = @divTrunc(rw, 2);
                const rad_y = @divTrunc(rh, 2);
                if (ann.filled) {
                    r.fillEllipse(cx, cy, rad_x, rad_y, ann.color);
                } else {
                    r.drawEllipseBorder(cx, cy, rad_x, rad_y, scaled_sw, ann.color);
                }
            },
            .highlight => {
                const b = ann.getBounds();
                const sx0 = self.imageToPhysX(b.x);
                const sy0 = self.imageToPhysY(b.y);
                const sx1 = self.imageToPhysX(b.x + @as(i32, @intCast(b.w)));
                const sy1 = self.imageToPhysY(b.y + @as(i32, @intCast(b.h)));
                const rx = @min(sx0, sx1);
                const ry = @min(sy0, sy1);
                const rw: u32 = @intCast(@abs(sx1 - sx0));
                const rh: u32 = @intCast(@abs(sy1 - sy0));
                r.fillRect(rx, ry, rw, rh, Color.init(100, ann.color.r, ann.color.g, ann.color.b));
            },
            .blur => {
                const b = ann.getBounds();
                const sx0 = self.imageToPhysX(b.x);
                const sy0 = self.imageToPhysY(b.y);
                const sx1 = self.imageToPhysX(b.x + @as(i32, @intCast(b.w)));
                const sy1 = self.imageToPhysY(b.y + @as(i32, @intCast(b.h)));
                const rx = @min(sx0, sx1);
                const ry = @min(sy0, sy1);
                const rw: u32 = @intCast(@abs(sx1 - sx0));
                const rh: u32 = @intCast(@abs(sy1 - sy0));
                r.fillRect(rx, ry, rw, rh, Color.init(170, 180, 185, 200));
                r.drawRoundedBorder(rx, ry, rw, rh, 0, 1, Color.init(120, 255, 255, 255));
                r.drawTextWithSize(self.font, "󰈈 Blur", rx + 6, ry + @as(i32, @intCast(self.toPhysSize(16))), self.toPhysSize(11), th.surface);
            },
            .pixelate => {
                const b = ann.getBounds();
                const sx0 = self.imageToPhysX(b.x);
                const sy0 = self.imageToPhysY(b.y);
                const sx1 = self.imageToPhysX(b.x + @as(i32, @intCast(b.w)));
                const sy1 = self.imageToPhysY(b.y + @as(i32, @intCast(b.h)));
                const rx = @min(sx0, sx1);
                const ry = @min(sy0, sy1);
                const rw: u32 = @intCast(@abs(sx1 - sx0));
                const rh: u32 = @intCast(@abs(sy1 - sy0));
                r.fillRect(rx, ry, rw, rh, Color.init(210, 40, 44, 52));
                r.drawRoundedBorder(rx, ry, rw, rh, 0, 1, th.accent);
                r.drawTextWithSize(self.font, "󰹑 Pixelate", rx + 6, ry + @as(i32, @intCast(self.toPhysSize(16))), self.toPhysSize(11), Color.rgb(255, 255, 255));
            },
            .image => {
                if (ann.image_data) |*img| {
                    const b = ann.getBounds();
                    const sx0 = self.imageToPhysX(b.x);
                    const sy0 = self.imageToPhysY(b.y);
                    const sx1 = self.imageToPhysX(b.x + @as(i32, @intCast(b.w)));
                    const sy1 = self.imageToPhysY(b.y + @as(i32, @intCast(b.h)));
                    const rx = @min(sx0, sx1);
                    const ry = @min(sy0, sy1);
                    const rw: f64 = @floatFromInt(@as(u32, @intCast(@abs(sx1 - sx0))));
                    const rh: f64 = @floatFromInt(@as(u32, @intCast(@abs(sy1 - sy0))));
                    if (rw > 0.0 and rh > 0.0) {
                        const r_img = renderer.Image{
                            .width = img.width,
                            .height = img.height,
                            .pixels = img.pixels,
                            .allocator = self.allocator,
                        };
                        r.drawImage(&r_img, @floatFromInt(rx), @floatFromInt(ry), rw, rh);
                    }
                }
            },
            .step_badge => {
                const sx = self.imageToPhysX(ann.rect.x);
                const sy = self.imageToPhysY(ann.rect.y);
                const rad: f64 = 16.0 * @as(f64, self.zoom * self.effectiveScale());
                r.fillCircle(@floatFromInt(sx), @floatFromInt(sy), rad, ann.color);
                r.drawCircleBorder(@floatFromInt(sx), @floatFromInt(sy), rad, @max(1.0, 1.5 * self.effectiveScale()), Color.rgb(255, 255, 255));

                var num_buf: [16]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{ann.step_number}) catch "1";
                const badge_fs = @max(9, @as(u32, @intFromFloat(12.0 * self.zoom * self.effectiveScale())));
                const nw = r.measureTextWithSize(self.font, num_str, badge_fs);
                r.drawTextWithSize(self.font, num_str, sx - @divTrunc(@as(i32, @intCast(nw)), 2), sy + @as(i32, @intCast(@divTrunc(badge_fs, 3))), badge_fs, Color.rgb(255, 255, 255));
            },
            .text => {
                if (self.editing_text_id == ann.id) return; // Drawn in inline editor
                const sx = self.imageToPhysX(ann.rect.x);
                const sy = self.imageToPhysY(ann.rect.y);
                const phys_fs = @max(10, @as(u32, @intFromFloat(@as(f32, @floatFromInt(ann.font_size)) * self.zoom * self.effectiveScale())));
                const line_h = @as(i32, @intCast(phys_fs + @max(2, @divTrunc(phys_fs, 4))));
                const full_slice = ann.text_buf[0..ann.text_len];

                // Render finalized text directly over screenshot without background or border
                var line_it = std.mem.splitScalar(u8, full_slice, '\n');
                var cur_y = sy + @as(i32, @intCast(phys_fs));
                while (line_it.next()) |line| {
                    if (line.len > 0) {
                        r.drawTextWithSize(self.font, line, sx, cur_y, phys_fs, ann.color);
                    }
                    cur_y += line_h;
                }
            },
            .pen => {
                if (ann.points.items.len < 2) return;
                var i: usize = 0;
                while (i + 1 < ann.points.items.len) : (i += 1) {
                    const sx0 = self.imageToPhysX(ann.points.items[i].x);
                    const sy0 = self.imageToPhysY(ann.points.items[i].y);
                    const sx1 = self.imageToPhysX(ann.points.items[i + 1].x);
                    const sy1 = self.imageToPhysY(ann.points.items[i + 1].y);
                    r.drawStrokeLine(sx0, sy0, sx1, sy1, scaled_sw, ann.color);
                    if (scaled_sw > 2) {
                        r.fillCircle(@floatFromInt(sx0), @floatFromInt(sy0), @as(f64, @floatFromInt(scaled_sw)) / 2.0, ann.color);
                    }
                }
                if (ann.points.items.len > 0 and scaled_sw > 2) {
                    const last_pt = ann.points.items[ann.points.items.len - 1];
                    r.fillCircle(@floatFromInt(self.imageToPhysX(last_pt.x)), @floatFromInt(self.imageToPhysY(last_pt.y)), @as(f64, @floatFromInt(scaled_sw)) / 2.0, ann.color);
                }
            },
        }
    }

    fn renderDrawingPreview(self: *AnnotateApp, r: renderer.Renderer) void {
        const sx0 = self.imageToPhysX(self.drag_start_x);
        const sy0 = self.imageToPhysY(self.drag_start_y);
        const sx1 = self.imageToPhysX(self.drag_curr_x);
        const sy1 = self.imageToPhysY(self.drag_curr_y);
        const scaled_sw = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(self.stroke_width)) * self.zoom * self.effectiveScale())));

        switch (self.active_tool) {
            .arrow => r.drawArrow(sx0, sy0, sx1, sy1, scaled_sw, self.current_color),
            .line => r.drawStrokeLine(sx0, sy0, sx1, sy1, scaled_sw, self.current_color),
            .rect => {
                const rx = @min(sx0, sx1);
                const ry = @min(sy0, sy1);
                const rw: u32 = @intCast(@abs(sx1 - sx0));
                const rh: u32 = @intCast(@abs(sy1 - sy0));
                const cr = self.toPhysSize(4);
                if (self.fill_shape) {
                    r.fillRoundedRect(rx, ry, rw, rh, cr, self.current_color);
                } else {
                    r.drawRoundedBorder(rx, ry, rw, rh, cr, scaled_sw, self.current_color);
                }
            },
            .circle => {
                const rx = @min(sx0, sx1);
                const ry = @min(sy0, sy1);
                const rw: u32 = @intCast(@abs(sx1 - sx0));
                const rh: u32 = @intCast(@abs(sy1 - sy0));
                const cx = rx + @as(i32, @intCast(@divTrunc(rw, 2)));
                const cy = ry + @as(i32, @intCast(@divTrunc(rh, 2)));
                const rad_x = @divTrunc(rw, 2);
                const rad_y = @divTrunc(rh, 2);
                if (self.fill_shape) {
                    r.fillEllipse(cx, cy, rad_x, rad_y, self.current_color);
                } else {
                    r.drawEllipseBorder(cx, cy, rad_x, rad_y, scaled_sw, self.current_color);
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
                    const s_sx = self.imageToPhysX(ann.start_x);
                    const s_sy = self.imageToPhysY(ann.start_y);
                    const e_sx = self.imageToPhysX(ann.end_x);
                    const e_sy = self.imageToPhysY(ann.end_y);

                    const handle_rad = self.toPhysSize(6);
                    r.fillCircle(@floatFromInt(s_sx), @floatFromInt(s_sy), handle_rad, Color.rgb(255, 255, 255));
                    r.drawCircleBorder(@floatFromInt(s_sx), @floatFromInt(s_sy), handle_rad, self.toPhysSize(2), th.accent);

                    r.fillCircle(@floatFromInt(e_sx), @floatFromInt(e_sy), handle_rad, Color.rgb(255, 255, 255));
                    r.drawCircleBorder(@floatFromInt(e_sx), @floatFromInt(e_sy), handle_rad, self.toPhysSize(2), th.accent);
                    return;
                }
            }
        }

        const maybe_bounds = self.getCombinedSelectionBounds() orelse return;
        const b = maybe_bounds;

        const x0 = self.imageToPhysX(b.x);
        const y0 = self.imageToPhysY(b.y);
        const x1 = self.imageToPhysX(b.x + @as(i32, @intCast(b.w)));
        const y1 = self.imageToPhysY(b.y + @as(i32, @intCast(b.h)));
        const w: u32 = @intCast(@max(4, x1 - x0));
        const h: u32 = @intCast(@max(4, y1 - y0));

        // Outer bounding box outline with accent glow
        r.drawRoundedBorder(x0 - 2, y0 - 2, w + 4, h + 4, self.toPhysSize(2), 1, th.accent);

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

        const hw = self.toPhysSize(8);
        const h_rad = self.toPhysSize(2);
        for (handle_coords) |pt| {
            r.fillRoundedRect(pt.x - @as(i32, @intCast(@divTrunc(hw, 2))), pt.y - @as(i32, @intCast(@divTrunc(hw, 2))), hw, hw, h_rad, Color.rgb(255, 255, 255));
            r.drawRoundedBorder(pt.x - @as(i32, @intCast(@divTrunc(hw, 2))), pt.y - @as(i32, @intCast(@divTrunc(hw, 2))), hw, hw, h_rad, 1, th.accent);
        }
    }

    fn renderCropOverlay(self: *AnnotateApp, r: renderer.Renderer) void {
        const th = self.cfg.theme;
        const ix0 = @min(self.crop_x0, self.crop_x1);
        const iy0 = @min(self.crop_y0, self.crop_y1);
        const ix1 = @max(self.crop_x0, self.crop_x1);
        const iy1 = @max(self.crop_y0, self.crop_y1);

        const sx0 = self.imageToPhysX(ix0);
        const sy0 = self.imageToPhysY(iy0);
        const sx1 = self.imageToPhysX(ix1);
        const sy1 = self.imageToPhysY(iy1);

        const dim_col = Color.init(150, 0, 0, 0);
        const pw = self.win.physicalWidth();
        const ph = self.win.physicalHeight();

        r.fillRect(0, 0, pw, @intCast(@max(0, sy0)), dim_col);
        r.fillRect(0, sy1, pw, @intCast(@max(0, @as(i32, @intCast(ph)) - sy1)), dim_col);
        r.fillRect(0, sy0, @intCast(@max(0, sx0)), @intCast(@max(0, sy1 - sy0)), dim_col);
        r.fillRect(sx1, sy0, @intCast(@max(0, @as(i32, @intCast(pw)) - sx1)), @intCast(@max(0, sy1 - sy0)), dim_col);

        const cw: u32 = @intCast(@max(0, sx1 - sx0));
        const ch: u32 = @intCast(@max(0, sy1 - sy0));
        if (cw > 0 and ch > 0) {
            r.drawRoundedBorder(sx0, sy0, cw, ch, 0, self.toPhysSize(2), th.accent);

            var dim_buf: [48]u8 = undefined;
            const crop_w_px = @as(u32, @intCast(@abs(ix1 - ix0)));
            const crop_h_px = @as(u32, @intCast(@abs(iy1 - iy0)));
            const dim_txt = std.fmt.bufPrint(&dim_buf, "{d}×{d} px", .{ crop_w_px, crop_h_px }) catch "";
            const bw = self.toPhysSize(88);
            const bh = self.toPhysSize(20);
            r.fillRoundedRect(sx0 + 6, sy0 + 6, bw, bh, self.toPhysSize(4), Color.init(190, 0, 0, 0));
            r.drawTextWithSize(self.font, dim_txt, sx0 + 10, sy0 + @as(i32, @intCast(self.toPhysSize(19))), self.ui_font_size, Color.rgb(255, 255, 255));
        }
    }

    fn renderToolButton(
        self: *AnnotateApp,
        r: renderer.Renderer,
        lx: i32,
        ly: i32,
        lw: u32,
        lh: u32,
        icon: []const u8,
        active: bool,
        enabled: bool,
        fg_override: ?Color,
    ) void {
        const th = self.cfg.theme;
        const px = self.toPhysX(lx);
        const py = self.toPhysY(ly);
        const pw = self.toPhysSize(lw);
        const ph = self.toPhysSize(lh);
        const rad = self.toPhysSize(6);

        const bg = if (active) th.accent else th.btn_raised_bg;
        const border_col = if (active) th.accent else th.glass_border;
        const default_fg = if (!enabled)
            th.text_muted
        else if (active)
            th.accent_fg
        else
            th.text_main;
        const fg = fg_override orelse default_fg;

        r.fillRoundedRect(px, py, pw, ph, rad, bg);
        r.drawRoundedBorder(px, py, pw, ph, rad, 1, border_col);

        if (icon.len > 0) {
            const icon_y = py + @as(i32, @intCast(@divTrunc(ph * 3, 4))) - 1;
            r.drawIconCentered(self.font, icon, px + @as(i32, @intCast(@divTrunc(pw, 2))), icon_y, self.ui_font_size, fg);
        }
    }

    fn renderToolbar(self: *AnnotateApp, r: renderer.Renderer) void {
        const th = self.cfg.theme;
        const w = self.win.width;
        const is_narrow = (w < 960);
        self.toolbar_height = if (is_narrow) 80 else 44;

        const pw = self.win.physicalWidth();
        const ph = self.toPhysSize(self.toolbar_height);

        r.fillRect(0, 0, pw, ph, th.surface);
        r.fillRect(0, @as(i32, @intCast(ph)) - 1, pw, 1, th.glass_border);

        const btn_y: i32 = 7;
        const btn_h: u32 = 30;
        const btn_w: u32 = 28;

        // Group 1: Selection / Move
        var bx: i32 = 12;
        self.renderToolButton(r, bx, btn_y, btn_w, btn_h, Tool.select.icon(), self.active_tool == .select, true, null);
        bx += @as(i32, @intCast(btn_w)) + 6;

        // Separator 1
        r.fillRect(self.toPhysX(bx), self.toPhysY(11), 1, self.toPhysSize(22), th.glass_border);
        bx += 7;

        // Group 2: Freehand drawing
        self.renderToolButton(r, bx, btn_y, btn_w, btn_h, Tool.freehand.icon(), self.active_tool == .freehand, true, null);
        bx += @as(i32, @intCast(btn_w)) + 6;

        // Separator 2
        r.fillRect(self.toPhysX(bx), self.toPhysY(11), 1, self.toPhysSize(22), th.glass_border);
        bx += 7;

        // Group 3: Arrow and line
        self.renderToolButton(r, bx, btn_y, btn_w, btn_h, Tool.arrow.icon(), self.active_tool == .arrow, true, null);
        bx += @as(i32, @intCast(btn_w)) + 3;
        self.renderToolButton(r, bx, btn_y, btn_w, btn_h, Tool.line.icon(), self.active_tool == .line, true, null);
        bx += @as(i32, @intCast(btn_w)) + 6;

        // Separator 3
        r.fillRect(self.toPhysX(bx), self.toPhysY(11), 1, self.toPhysSize(22), th.glass_border);
        bx += 7;

        // Group 4: Rectangle, Ellipse and Fill toggle
        self.renderToolButton(r, bx, btn_y, btn_w, btn_h, Tool.rect.icon(), self.active_tool == .rect, true, null);
        bx += @as(i32, @intCast(btn_w)) + 3;
        self.renderToolButton(r, bx, btn_y, btn_w, btn_h, Tool.circle.icon(), self.active_tool == .circle, true, null);
        bx += @as(i32, @intCast(btn_w)) + 3;
        self.renderToolButton(r, bx, btn_y, btn_w, btn_h, "", self.fill_shape, true, null);
        bx += @as(i32, @intCast(btn_w)) + 6;

        // Separator 4
        r.fillRect(self.toPhysX(bx), self.toPhysY(11), 1, self.toPhysSize(22), th.glass_border);
        bx += 7;

        // Group 5: Text annotation & Font size badge
        self.renderToolButton(r, bx, btn_y, btn_w, btn_h, Tool.text.icon(), self.active_tool == .text, true, null);
        bx += @as(i32, @intCast(btn_w)) + 4;

        // Font size decrease [-]
        self.renderToolButton(r, bx, btn_y, 20, btn_h, "󰧳", false, true, null);
        bx += 20 + 2;

        // Font size badge / dropdown trigger
        {
            const f_px = self.toPhysX(bx);
            const f_py = self.toPhysY(btn_y);
            const f_pw = self.toPhysSize(36);
            const f_ph = self.toPhysSize(btn_h);
            const f_bg = if (self.font_dropdown_open) th.accent else th.btn_raised_bg;
            const f_fg = if (self.font_dropdown_open) th.accent_fg else th.text_main;
            r.fillRoundedRect(f_px, f_py, f_pw, f_ph, self.toPhysSize(6), f_bg);
            r.drawRoundedBorder(f_px, f_py, f_pw, f_ph, self.toPhysSize(6), 1, if (self.font_dropdown_open) th.accent else th.glass_border);

            var sz_buf: [8]u8 = undefined;
            const sz_str = std.fmt.bufPrint(&sz_buf, "{d}", .{self.current_font_size}) catch "18";
            const sz_lw = r.measureTextWithSize(self.font, sz_str, self.ui_font_size);
            const sz_lx = f_px + @divTrunc(@as(i32, @intCast(f_pw)) - @as(i32, @intCast(sz_lw)), 2);
            r.drawTextWithSize(self.font, sz_str, sz_lx, f_py + @as(i32, @intCast(@divTrunc(f_ph * 3, 4))) - 1, self.ui_font_size, f_fg);
            bx += 36 + 2;
        }

        // Font size increase [+]
        self.renderToolButton(r, bx, btn_y, 20, btn_h, "󰧴", false, true, null);
        bx += 20 + 6;

        // Separator 5
        r.fillRect(self.toPhysX(bx), self.toPhysY(11), 1, self.toPhysSize(22), th.glass_border);
        bx += 7;

        // Group 6: Numbered badge
        self.renderToolButton(r, bx, btn_y, btn_w, btn_h, Tool.step_badge.icon(), self.active_tool == .step_badge, true, null);
        bx += @as(i32, @intCast(btn_w)) + 6;

        // Separator 6
        r.fillRect(self.toPhysX(bx), self.toPhysY(11), 1, self.toPhysSize(22), th.glass_border);
        bx += 7;

        // Group 7: Blur & Pixelate
        self.renderToolButton(r, bx, btn_y, btn_w, btn_h, Tool.blur.icon(), self.active_tool == .blur, true, null);
        bx += @as(i32, @intCast(btn_w)) + 3;
        self.renderToolButton(r, bx, btn_y, btn_w, btn_h, Tool.pixelate.icon(), self.active_tool == .pixelate, true, null);
        bx += @as(i32, @intCast(btn_w)) + 6;

        // Separator 7
        r.fillRect(self.toPhysX(bx), self.toPhysY(11), 1, self.toPhysSize(22), th.glass_border);
        bx += 7;

        // Group 8: Highlight
        self.renderToolButton(r, bx, btn_y, btn_w, btn_h, Tool.highlight.icon(), self.active_tool == .highlight, true, null);
        bx += @as(i32, @intCast(btn_w)) + 6;

        // Separator 8
        r.fillRect(self.toPhysX(bx), self.toPhysY(11), 1, self.toPhysSize(22), th.glass_border);
        bx += 7;

        // Group 9: Eraser
        self.renderToolButton(r, bx, btn_y, btn_w, btn_h, Tool.eraser.icon(), self.active_tool == .eraser, true, null);
        bx += @as(i32, @intCast(btn_w)) + 6;

        // Separator 9
        r.fillRect(self.toPhysX(bx), self.toPhysY(11), 1, self.toPhysSize(22), th.glass_border);
        bx += 7;

        // Group 10: Crop
        self.renderToolButton(r, bx, btn_y, btn_w, btn_h, "", self.is_crop_mode, true, null);
        bx += @as(i32, @intCast(btn_w)) + 6;

        // Separator 10
        r.fillRect(self.toPhysX(bx), self.toPhysY(11), 1, self.toPhysSize(22), th.glass_border);
        bx += 7;

        if (!is_narrow) {
            // Group 11: Color swatches, palette & picker
            const c_rad = self.toPhysSize(7);
            const c_border_rad = self.toPhysSize(9);
            for (Palette.colors) |col| {
                const active = (self.current_color.toArgb() == col.toArgb());
                const c_cx = self.toPhysX(bx + 8);
                const c_cy = self.toPhysY(btn_y + 15);
                r.fillCircle(@floatFromInt(c_cx), @floatFromInt(c_cy), c_rad, col);
                if (active) {
                    r.drawCircleBorder(@floatFromInt(c_cx), @floatFromInt(c_cy), c_border_rad, self.toPhysSize(2), th.accent);
                }
                bx += 18;
            }

            // Palette icon () - opens custom hex input dialog
            self.renderToolButton(r, bx, btn_y, 26, btn_h, "", self.color_dialog_open, true, if (self.color_dialog_open) th.accent_fg else th.accent);
            bx += 29;

            // Picker icon (󰈊) - picks from screen and copies to clipboard
            self.renderToolButton(r, bx, btn_y, 26, btn_h, "󰈊", false, true, th.accent);
            bx += 29;

            // Group 12: Right Actions: Undo, Redo, Save, Copy
            var rx = @as(i32, @intCast(w)) - 138;
            self.renderToolButton(r, rx, btn_y, 28, btn_h, "", false, self.undo_mgr.canUndo(), null);
            rx += 31;
            self.renderToolButton(r, rx, btn_y, 28, btn_h, "", false, self.undo_mgr.canRedo(), null);
            rx += 33;
            self.renderToolButton(r, rx, btn_y, 28, btn_h, "󰆓", false, true, null);
            rx += 31;
            self.renderToolButton(r, rx, btn_y, 32, btn_h, "󰆏", false, true, th.accent);
        } else {
            // Narrow Window: Row 2 Palette and Actions
            const btn_y2: i32 = 42;
            var bx2: i32 = 12;
            const c_rad = self.toPhysSize(7);
            const c_border_rad = self.toPhysSize(9);
            for (Palette.colors) |col| {
                const active = (self.current_color.toArgb() == col.toArgb());
                const c_cx = self.toPhysX(bx2 + 8);
                const c_cy = self.toPhysY(btn_y2 + 15);
                r.fillCircle(@floatFromInt(c_cx), @floatFromInt(c_cy), c_rad, col);
                if (active) {
                    r.drawCircleBorder(@floatFromInt(c_cx), @floatFromInt(c_cy), c_border_rad, self.toPhysSize(2), th.accent);
                }
                bx2 += 18;
            }

            self.renderToolButton(r, bx2, btn_y2, 26, btn_h, "", self.color_dialog_open, true, if (self.color_dialog_open) th.accent_fg else th.accent);
            bx2 += 29;

            self.renderToolButton(r, bx2, btn_y2, 26, btn_h, "󰈊", false, true, th.accent);
            bx2 += 29;

            var rx2 = @as(i32, @intCast(w)) - 138;
            self.renderToolButton(r, rx2, btn_y2, 28, btn_h, "", false, self.undo_mgr.canUndo(), null);
            rx2 += 31;
            self.renderToolButton(r, rx2, btn_y2, 28, btn_h, "", false, self.undo_mgr.canRedo(), null);
            rx2 += 33;
            self.renderToolButton(r, rx2, btn_y2, 28, btn_h, "󰆓", false, true, null);
            rx2 += 31;
            self.renderToolButton(r, rx2, btn_y2, 32, btn_h, "󰆏", false, true, th.accent);
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

        const px = self.toPhysX(panel_x);
        const py = self.toPhysY(panel_y);
        const pw = self.toPhysSize(panel_w);
        const ph = self.toPhysSize(panel_h);

        r.fillRect(px, py, pw, ph, th.surface);
        r.fillRect(px, py, 1, ph, th.glass_border);

        // Header
        var h_buf: [48]u8 = undefined;
        const header_txt = std.fmt.bufPrint(&h_buf, "Layers ({d})", .{self.annotations.items.len}) catch "Layers";
        r.drawTextWithSize(self.font, header_txt, px + @as(i32, @intCast(self.toPhysSize(14))), py + @as(i32, @intCast(self.toPhysSize(24))), self.ui_font_size, th.accent);

        // Close button
        r.drawTextWithSize(self.font, "✕", px + @as(i32, @intCast(pw)) - @as(i32, @intCast(self.toPhysSize(22))), py + @as(i32, @intCast(self.toPhysSize(24))), self.ui_font_size, th.text_muted);

        r.fillRect(px + @as(i32, @intCast(self.toPhysSize(10))), py + @as(i32, @intCast(self.toPhysSize(36))), pw - self.toPhysSize(20), 1, th.glass_border);

        // Layers list (reverse order: top to bottom)
        var cur_y = py + @as(i32, @intCast(self.toPhysSize(44)));
        const row_h: i32 = @intCast(self.toPhysSize(32));
        const total = self.annotations.items.len;

        var i: usize = 0;
        while (i < total and cur_y + row_h < py + @as(i32, @intCast(ph))) : (i += 1) {
            const ann_idx = total - 1 - i;
            const ann = &self.annotations.items[ann_idx];
            const sel = self.isSelected(ann.id);

            // Row background
            if (sel) {
                r.fillRoundedRect(px + @as(i32, @intCast(self.toPhysSize(6))), cur_y, pw - self.toPhysSize(12), @intCast(row_h - 2), self.toPhysSize(4), Color.init(60, 97, 175, 239));
                r.fillRect(px + @as(i32, @intCast(self.toPhysSize(6))), cur_y, self.toPhysSize(3), @intCast(row_h - 2), th.accent);
            }

            // Annotation Name / Label
            var name_buf: [64]u8 = undefined;
            const label = if (ann.kind == .text and ann.text_len > 0)
                std.fmt.bufPrint(&name_buf, "\"{s}\"", .{ann.text_buf[0..@min(ann.text_len, 14)]}) catch ann.kind.name()
            else if (ann.kind == .step_badge)
                std.fmt.bufPrint(&name_buf, "Step {d}", .{ann.step_number}) catch ann.kind.name()
            else
                ann.kind.name();

            r.drawTextWithSize(self.font, label, px + @as(i32, @intCast(self.toPhysSize(16))), cur_y + @as(i32, @intCast(self.toPhysSize(20))), self.ui_font_size, if (sel) th.accent else th.text_main);

            // Visibility Eye Icon
            const eye_txt = if (ann.visible) "👁" else "󰈈";
            r.drawTextWithSize(self.font, eye_txt, px + @as(i32, @intCast(self.toPhysSize(132))), cur_y + @as(i32, @intCast(self.toPhysSize(20))), self.ui_font_size, if (ann.visible) th.text_main else th.text_muted);

            // Lock Icon
            const lock_txt = if (ann.locked) "🔒" else "🔓";
            r.drawTextWithSize(self.font, lock_txt, px + @as(i32, @intCast(self.toPhysSize(154))), cur_y + @as(i32, @intCast(self.toPhysSize(20))), self.ui_font_size, if (ann.locked) th.accent else th.text_muted);

            // Delete button
            r.drawTextWithSize(self.font, "✕", px + @as(i32, @intCast(self.toPhysSize(202))), cur_y + @as(i32, @intCast(self.toPhysSize(20))), self.ui_font_size, th.text_muted);

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

        const px = self.toPhysX(panel_x);
        const py = self.toPhysY(panel_y);
        const pw = self.toPhysSize(panel_w);
        const ph = self.toPhysSize(panel_h);

        r.fillRect(px, py, pw, ph, th.surface);
        r.fillRect(px, py, 1, ph, th.glass_border);

        var cur_y: i32 = py + @as(i32, @intCast(self.toPhysSize(20)));
        r.drawTextWithSize(self.font, "Color Adjustments", px + @as(i32, @intCast(self.toPhysSize(16))), cur_y + @as(i32, @intCast(self.toPhysSize(4))), self.ui_font_size, th.accent);
        cur_y += @intCast(self.toPhysSize(30));

        // Brightness
        {
            var buf: [32]u8 = undefined;
            const pct: i32 = @intFromFloat(self.adjustments.brightness * 100.0);
            const val_txt = if (pct > 0)
                std.fmt.bufPrint(&buf, "Brightness: +{d}%", .{pct}) catch ""
            else
                std.fmt.bufPrint(&buf, "Brightness: {d}%", .{pct}) catch "";
            r.drawTextWithSize(self.font, val_txt, px + @as(i32, @intCast(self.toPhysSize(16))), cur_y, self.ui_font_size, th.text_main);
            cur_y += @intCast(self.toPhysSize(10));

            const slider_w: i32 = @intCast(self.toPhysSize(208));
            r.fillRoundedRect(px + @as(i32, @intCast(self.toPhysSize(16))), cur_y, @intCast(slider_w), self.toPhysSize(6), self.toPhysSize(3), th.btn_raised_bg);
            const frac = (self.adjustments.brightness / 2.0) + 0.5;
            const knob_x = px + @as(i32, @intCast(self.toPhysSize(16))) + @as(i32, @intFromFloat(@as(f32, @floatFromInt(slider_w)) * frac));
            r.fillCircle(@floatFromInt(knob_x), @floatFromInt(cur_y + @as(i32, @intCast(self.toPhysSize(3)))), self.toPhysSize(7), th.accent);
            cur_y += @intCast(self.toPhysSize(30));
        }

        // Contrast
        {
            var buf: [32]u8 = undefined;
            const val_txt = std.fmt.bufPrint(&buf, "Contrast: {d:.2}x", .{self.adjustments.contrast}) catch "";
            r.drawTextWithSize(self.font, val_txt, px + @as(i32, @intCast(self.toPhysSize(16))), cur_y, self.ui_font_size, th.text_main);
            cur_y += @intCast(self.toPhysSize(10));

            const slider_w: i32 = @intCast(self.toPhysSize(208));
            r.fillRoundedRect(px + @as(i32, @intCast(self.toPhysSize(16))), cur_y, @intCast(slider_w), self.toPhysSize(6), self.toPhysSize(3), th.btn_raised_bg);
            const frac = self.adjustments.contrast / 2.0;
            const knob_x = px + @as(i32, @intCast(self.toPhysSize(16))) + @as(i32, @intFromFloat(@as(f32, @floatFromInt(slider_w)) * frac));
            r.fillCircle(@floatFromInt(knob_x), @floatFromInt(cur_y + @as(i32, @intCast(self.toPhysSize(3)))), self.toPhysSize(7), th.accent);
            cur_y += @intCast(self.toPhysSize(30));
        }

        // Saturation
        {
            var buf: [32]u8 = undefined;
            const val_txt = std.fmt.bufPrint(&buf, "Saturation: {d:.2}x", .{self.adjustments.saturation}) catch "";
            r.drawTextWithSize(self.font, val_txt, px + @as(i32, @intCast(self.toPhysSize(16))), cur_y, self.ui_font_size, th.text_main);
            cur_y += @intCast(self.toPhysSize(10));

            const slider_w: i32 = @intCast(self.toPhysSize(208));
            r.fillRoundedRect(px + @as(i32, @intCast(self.toPhysSize(16))), cur_y, @intCast(slider_w), self.toPhysSize(6), self.toPhysSize(3), th.btn_raised_bg);
            const frac = self.adjustments.saturation / 2.0;
            const knob_x = px + @as(i32, @intCast(self.toPhysSize(16))) + @as(i32, @intFromFloat(@as(f32, @floatFromInt(slider_w)) * frac));
            r.fillCircle(@floatFromInt(knob_x), @floatFromInt(cur_y + @as(i32, @intCast(self.toPhysSize(3)))), self.toPhysSize(7), th.accent);
            cur_y += @intCast(self.toPhysSize(30));
        }

        // Grayscale toggle
        {
            const gw = self.toPhysSize(208);
            const gh = self.toPhysSize(26);
            r.fillRoundedRect(px + @as(i32, @intCast(self.toPhysSize(16))), cur_y, gw, gh, self.toPhysSize(4), if (self.adjustments.grayscale) th.accent else th.btn_raised_bg);
            r.drawRoundedBorder(px + @as(i32, @intCast(self.toPhysSize(16))), cur_y, gw, gh, self.toPhysSize(4), 1, th.glass_border);
            const g_txt = if (self.adjustments.grayscale) "✓ Grayscale Enabled" else "Enable Grayscale";
            r.drawTextWithSize(self.font, g_txt, px + @as(i32, @intCast(self.toPhysSize(50))), cur_y + @as(i32, @intCast(self.toPhysSize(17))), self.ui_font_size, if (self.adjustments.grayscale) th.accent_fg else th.text_main);
            cur_y += @intCast(self.toPhysSize(38));
        }

        // Close
        const cw = self.toPhysSize(208);
        const ch = self.toPhysSize(28);
        r.fillRoundedRect(px + @as(i32, @intCast(self.toPhysSize(16))), cur_y, cw, ch, self.toPhysSize(6), th.accent);
        r.drawTextWithSize(self.font, "Close Panel", px + @as(i32, @intCast(self.toPhysSize(76))), cur_y + @as(i32, @intCast(self.toPhysSize(18))), self.ui_font_size, th.accent_fg);
    }

    fn renderStatusbar(self: *AnnotateApp, r: renderer.Renderer) void {
        const th = self.cfg.theme;
        const ly: i32 = @as(i32, @intCast(self.win.height)) - @as(i32, @intCast(self.statusbar_height));
        const py = self.toPhysY(ly);
        const pw = self.win.physicalWidth();
        const ph = self.toPhysSize(self.statusbar_height);

        r.fillRect(0, py, pw, ph, th.surface);
        r.fillRect(0, py, pw, 1, th.glass_border);

        // Minimal left info: dimensions & active state
        var info_buf: [96]u8 = undefined;
        const info = if (self.is_crop_mode)
            "Crop Mode"
        else if (self.selected_ids.items.len > 0)
            std.fmt.bufPrint(&info_buf, "{d} selected  •  {d}×{d} px", .{ self.selected_ids.items.len, self.base_image.img.width, self.base_image.img.height }) catch ""
        else
            std.fmt.bufPrint(&info_buf, "{s}  •  {d}×{d} px", .{ self.active_tool.name(), self.base_image.img.width, self.base_image.img.height }) catch "";

        r.drawTextWithSize(self.font, info, self.toPhysX(14), py + @as(i32, @intCast(self.toPhysSize(18))), self.ui_font_size, if (self.is_crop_mode or self.selected_ids.items.len > 0) th.accent else th.text_muted);

        if (self.is_crop_mode) {
            const apply_x = self.toPhysX(120);
            const apply_y = py + @as(i32, @intCast(self.toPhysSize(3)));
            const apply_w = self.toPhysSize(75);
            const apply_h = self.toPhysSize(22);
            r.fillRoundedRect(apply_x, apply_y, apply_w, apply_h, self.toPhysSize(4), th.accent);
            r.drawTextWithSize(self.font, "Apply", apply_x + @as(i32, @intCast(self.toPhysSize(20))), apply_y + @as(i32, @intCast(self.toPhysSize(14))), self.ui_font_size, th.accent_fg);

            const cancel_x = self.toPhysX(205);
            const cancel_y = py + @as(i32, @intCast(self.toPhysSize(3)));
            const cancel_w = self.toPhysSize(65);
            const cancel_h = self.toPhysSize(22);
            r.fillRoundedRect(cancel_x, cancel_y, cancel_w, cancel_h, self.toPhysSize(4), th.btn_raised_bg);
            r.drawRoundedBorder(cancel_x, cancel_y, cancel_w, cancel_h, self.toPhysSize(4), 1, th.glass_border);
            r.drawTextWithSize(self.font, "Cancel", cancel_x + @as(i32, @intCast(self.toPhysSize(13))), cancel_y + @as(i32, @intCast(self.toPhysSize(14))), self.ui_font_size, th.text_main);
        }

        // Notification Message centered
        if (self.status_ticks > 0 and self.status_len > 0) {
            const msg = self.status_msg[0..self.status_len];
            const mw = r.measureTextWithSize(self.font, msg, self.ui_font_size);
            const mx = @divTrunc(@as(i32, @intCast(pw)) - @as(i32, @intCast(mw)), 2);
            r.drawTextWithSize(self.font, msg, mx, py + @as(i32, @intCast(self.toPhysSize(18))), self.ui_font_size, th.success_color);
        }

        // Right Corner Minimal Zoom Controls: [-] [100%] [+]
        const right_margin: i32 = 12;
        const total_zoom_w: i32 = 110;
        const zoom_x: i32 = @as(i32, @intCast(self.win.width)) - total_zoom_w - right_margin;
        const btn_y: i32 = ly + 4;
        const z_btn_h: u32 = 20;

        // Minus button (󰍴)
        self.renderToolButton(r, zoom_x, btn_y, 24, z_btn_h, "󰍴", false, true, null);

        // Zoom percentage button
        {
            const f_px = self.toPhysX(zoom_x + 28);
            const f_py = self.toPhysY(btn_y);
            const f_pw = self.toPhysSize(54);
            const f_ph = self.toPhysSize(z_btn_h);
            r.fillRoundedRect(f_px, f_py, f_pw, f_ph, self.toPhysSize(4), th.btn_raised_bg);
            r.drawRoundedBorder(f_px, f_py, f_pw, f_ph, self.toPhysSize(4), 1, th.glass_border);

            var zoom_buf: [24]u8 = undefined;
            const zoom_pct = @as(u32, @intFromFloat(self.zoom * 100.0));
            const zoom_txt = std.fmt.bufPrint(&zoom_buf, "{d}%", .{zoom_pct}) catch "100%";
            const zw = r.measureTextWithSize(self.font, zoom_txt, self.ui_font_size);
            const zx = f_px + @divTrunc(@as(i32, @intCast(f_pw)) - @as(i32, @intCast(zw)), 2);
            r.drawTextWithSize(self.font, zoom_txt, zx, f_py + @as(i32, @intCast(self.toPhysSize(14))), self.ui_font_size, th.text_main);
        }

        // Plus button (󰐕)
        self.renderToolButton(r, zoom_x + 86, btn_y, 24, z_btn_h, "󰐕", false, true, null);
    }

    fn renderFontDropdown(self: *AnnotateApp, r: renderer.Renderer) void {
        const th = self.cfg.theme;
        const x: i32 = self.toPhysX(282);
        const y: i32 = self.toPhysY(@as(i32, @intCast(self.toolbar_height)) + 2);
        const w = self.toPhysSize(90);
        const h = self.toPhysSize(195);
        const row_h: i32 = @intCast(self.toPhysSize(30));

        r.fillRoundedRect(x, y, w, h, self.toPhysSize(6), th.surface);
        r.drawRoundedBorder(x, y, w, h, self.toPhysSize(6), 1, th.glass_border);

        const sizes = [_]u32{ 12, 16, 20, 24, 32, 48 };
        var cur_y = y + @as(i32, @intCast(self.toPhysSize(8)));
        for (sizes) |sz| {
            const active = (self.current_font_size == sz);
            const bg = if (active) th.accent else th.btn_raised_bg;
            const fg = if (active) th.accent_fg else th.text_main;
            r.fillRoundedRect(x + 4, cur_y, w - 8, @intCast(row_h - 4), self.toPhysSize(4), bg);
            var label_buf: [8]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "{d}px", .{sz}) catch "";
            const lw = r.measureTextWithSize(self.font, label, self.ui_font_size);
            const lx = x + @divTrunc(@as(i32, @intCast(w)) - @as(i32, @intCast(lw)), 2);
            r.drawTextWithSize(self.font, label, lx, cur_y + @as(i32, @intCast(self.toPhysSize(19))), self.ui_font_size, fg);
            cur_y += row_h;
        }
    }

    fn renderColorDialog(self: *AnnotateApp, r: renderer.Renderer) void {
        const th = self.cfg.theme;
        const is_narrow = (self.win.width < 960);
        const dlg_lx: i32 = if (is_narrow) 140 else @min(@as(i32, @intCast(self.win.width)) - 220, 680);
        const dlg_ly: i32 = if (is_narrow) 76 else @as(i32, @intCast(self.toolbar_height)) + 2;
        const dlg_lw: u32 = 210;
        const dlg_lh: u32 = 72;

        const px = self.toPhysX(dlg_lx);
        const py = self.toPhysY(dlg_ly);
        const pw = self.toPhysSize(dlg_lw);
        const ph = self.toPhysSize(dlg_lh);

        // Soft drop shadow
        r.drawSoftShadow(px, py, pw, ph, self.toPhysSize(6), self.toPhysSize(12), @as(i32, @intCast(self.toPhysSize(3))), th.shadow_dark);

        // Dialog background & border
        r.fillRoundedRect(px, py, pw, ph, self.toPhysSize(6), th.surface);
        r.drawRoundedBorder(px, py, pw, ph, self.toPhysSize(6), 1, th.glass_border);

        // Header: "Custom Hex Color" and Close "✕"
        r.drawTextWithSize(self.font, "Custom Hex Color", px + @as(i32, @intCast(self.toPhysSize(12))), py + @as(i32, @intCast(self.toPhysSize(18))), self.ui_font_size, th.text_muted);
        r.drawTextWithSize(self.font, "✕", px + @as(i32, @intCast(pw)) - @as(i32, @intCast(self.toPhysSize(18))), py + @as(i32, @intCast(self.toPhysSize(18))), self.ui_font_size, th.text_muted);

        // Content row Y
        const row_py = py + @as(i32, @intCast(self.toPhysSize(28)));

        // 1. Swatch preview box: 28x28
        const sw_px = px + @as(i32, @intCast(self.toPhysSize(12)));
        const sw_size = self.toPhysSize(28);
        const hex_slice = self.color_dialog_buf[0..self.color_dialog_len];
        const maybe_col = parseHexColor(hex_slice);
        const preview_col = maybe_col orelse self.current_color;

        r.fillRoundedRect(sw_px, row_py, sw_size, sw_size, self.toPhysSize(4), preview_col);
        r.drawRoundedBorder(sw_px, row_py, sw_size, sw_size, self.toPhysSize(4), 1, if (maybe_col != null) th.accent else th.error_color);

        // 2. Input box: 112x28
        const in_px = sw_px + @as(i32, @intCast(sw_size)) + @as(i32, @intCast(self.toPhysSize(8)));
        const in_pw = self.toPhysSize(112);
        r.fillRoundedRect(in_px, row_py, in_pw, sw_size, self.toPhysSize(4), th.btn_raised_bg);
        r.drawRoundedBorder(in_px, row_py, in_pw, sw_size, self.toPhysSize(4), 1, th.accent);

        // Text inside input
        const txt_x = in_px + @as(i32, @intCast(self.toPhysSize(8)));
        const txt_y = row_py + @as(i32, @intCast(self.toPhysSize(19)));
        r.drawTextWithSize(self.font, hex_slice, txt_x, txt_y, self.ui_font_size, th.text_main);

        // Caret in input box
        const cursor_slice = self.color_dialog_buf[0..self.color_dialog_cursor];
        const cw = r.measureTextWithSize(self.font, cursor_slice, self.ui_font_size);
        r.fillRect(txt_x + @as(i32, @intCast(cw)), row_py + @as(i32, @intCast(self.toPhysSize(4))), self.toPhysSize(2), self.toPhysSize(20), th.accent);

        // 3. Apply button "✓": 32x28
        const btn_px = in_px + @as(i32, @intCast(in_pw)) + @as(i32, @intCast(self.toPhysSize(6)));
        const btn_pw = self.toPhysSize(32);
        r.fillRoundedRect(btn_px, row_py, btn_pw, sw_size, self.toPhysSize(4), th.accent);
        r.drawRoundedBorder(btn_px, row_py, btn_pw, sw_size, self.toPhysSize(4), 1, th.accent);
        r.drawIconCentered(self.font, "✓", btn_px + @as(i32, @intCast(@divTrunc(btn_pw, 2))), row_py + @as(i32, @intCast(self.toPhysSize(20))), self.ui_font_size, th.accent_fg);
    }
};

// Main Application Event Loop & Stdin Pipe Support
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

        if (poll_fds[1].revents & c.POLLIN != 0) {
            app.win.handleRepeatTimer();
        }

        while (app.win.popKeyEvent()) |ev| {
            app.handleKey(ev.sym, ev.utf8_buf[0..ev.utf8_len], ev.is_ctrl, ev.is_shift);
        }

        app.reloadScale();

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

        // Ctrl + Mouse wheel zooming centered at cursor, Shift + scroll for font size / stroke thickness
        if (app.win.scroll_delta_y != 0.0) {
            const scroll = app.win.scroll_delta_y;
            app.win.scroll_delta_y = 0.0;
            if (app.win.is_ctrl) {
                const cx = @as(f32, @floatFromInt(@max(0, cur_px)));
                const cy = @as(f32, @floatFromInt(@max(0, cur_py)));
                const factor: f32 = if (scroll < 0) 1.15 else (1.0 / 1.15);
                app.zoomAt(cx, cy, factor);
            } else if (app.win.is_shift) {
                app.handleShiftScroll(scroll);
            } else {
                app.pan_y -= @as(f32, @floatCast(scroll * 24.0));
                app.win.needs_redraw = true;
            }
        }

        if (app.win.scroll_delta_x != 0.0) {
            const scroll_x = app.win.scroll_delta_x;
            app.win.scroll_delta_x = 0.0;
            if (app.win.is_shift) {
                app.handleShiftScroll(scroll_x);
            } else {
                app.pan_x -= @as(f32, @floatCast(scroll_x * 24.0));
                app.win.needs_redraw = true;
            }
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

test "Pasted image annotation kind" {
    try std.testing.expectEqualStrings("Pasted Image", AnnotationKind.image.name());
    try std.testing.expectEqualStrings("", AnnotationKind.image.icon());
}

test "Export scale stays sharp without blowing up memory" {
    try std.testing.expectApproxEqAbs(@as(f32, 1920.0 / 944.0), exportScaleFor(944, 346), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), exportScaleFor(1280, 720), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), exportScaleFor(1920, 1080), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), exportScaleFor(3840, 2160), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), exportScaleFor(400, 200), 0.0001);
}

test "Scaled annotation rendering" {
    const alloc = std.testing.allocator;
    var img = try ImageBuffer.init(alloc, 40, 20, Color.rgb(0, 0, 0));
    defer img.deinit();

    var font = try Font.init(alloc, "monospace", 12);
    defer font.deinit();

    var ann = Annotation{
        .id = 1,
        .kind = .rect,
        .rect = Rect{ .x = 5, .y = 5, .w = 6, .h = 4 },
        .stroke_width = 2,
        .color = Color.rgb(255, 0, 0),
    };
    defer ann.deinit(alloc);

    ann.renderToImage(&img, &font, 2);

    const drawn = img.getPixel(10, 10).?;
    try std.testing.expect(drawn.r > 200 and drawn.g < 50);
    const untouched = img.getPixel(3, 3).?;
    try std.testing.expect(untouched.r == 0 and untouched.g == 0);
}

test "TextEditState text editing, multiline and cursor navigation" {
    const alloc = std.testing.allocator;
    var te = try TextEditState.init(alloc, 42, "Hello World");
    defer te.deinit();

    try std.testing.expectEqualStrings("Hello World", te.text.items);
    try std.testing.expectEqual(@as(usize, 11), te.cursor_idx);

    // Left navigation
    te.moveLeft(false);
    try std.testing.expectEqual(@as(usize, 10), te.cursor_idx);

    // Home navigation
    te.moveHome(false, true);
    try std.testing.expectEqual(@as(usize, 0), te.cursor_idx);

    // Word right navigation
    te.moveWordRight(false);
    try std.testing.expectEqual(@as(usize, 5), te.cursor_idx); // After "Hello"

    // Word left navigation
    te.moveWordLeft(false);
    try std.testing.expectEqual(@as(usize, 0), te.cursor_idx);

    // End navigation
    te.moveEnd(false, true);
    try std.testing.expectEqual(@as(usize, 11), te.cursor_idx);

    // Enter / newline insertion (multiline)
    try te.insertBytes("\nNew Line");
    try std.testing.expectEqualStrings("Hello World\nNew Line", te.text.items);

    // Backspace
    te.deleteBackward();
    try std.testing.expectEqualStrings("Hello World\nNew Lin", te.text.items);

    // Undo
    te.undo();
    try std.testing.expectEqualStrings("Hello World\nNew Line", te.text.items);

    // Redo
    te.redo();
    try std.testing.expectEqualStrings("Hello World\nNew Lin", te.text.items);

    // Ctrl + A (Select all)
    te.selectAll();
    try std.testing.expect(te.hasSelection());
    if (te.getSelectionRange()) |r| {
        try std.testing.expectEqual(@as(usize, 0), r.start);
        try std.testing.expectEqual(te.text.items.len, r.end);
    } else {
        return error.TestUnexpectedResult;
    }

    // Type over selection replaces all text
    try te.insertBytes("Fresh Text");
    try std.testing.expectEqualStrings("Fresh Text", te.text.items);
    try std.testing.expect(!te.hasSelection());

    // Word deletion
    te.deleteWordBackward();
    try std.testing.expectEqualStrings("Fresh ", te.text.items);
}

test "HiDPI Display Scaling coordinate transformations" {
    // Test logical to physical framebuffer conversion across standard scale factors
    const scales = [_]f32{ 1.0, 1.25, 1.5, 1.75, 2.0 };
    for (scales) |scale| {
        const lx: i32 = 120;
        const ly: i32 = 80;
        const px = @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(lx)) * scale)));
        const py = @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(ly)) * scale)));

        // Framebuffer physical dimensions must match rounded scaling exactly
        try std.testing.expectEqual(px, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(lx)) * scale))));
        try std.testing.expectEqual(py, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(ly)) * scale))));

        // Fractional scaling (1.25, 1.75) preserves consistency without coordinate drift
        const roundtrip_x = @as(f32, @floatFromInt(px)) / scale;
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(lx)), roundtrip_x, 0.5);
    }
}

test "Vector Eraser deletes touched vector annotations" {
    const alloc = std.testing.allocator;
    var ann_list = std.ArrayListUnmanaged(Annotation).empty;
    defer {
        for (ann_list.items) |*a| a.deinit(alloc);
        ann_list.deinit(alloc);
    }

    // Annotation 1: Rectangle at (10, 10, 40, 40)
    try ann_list.append(alloc, Annotation{
        .id = 101,
        .kind = .rect,
        .rect = Rect{ .x = 10, .y = 10, .w = 40, .h = 40 },
        .stroke_width = 4,
    });

    // Annotation 2: Line from (100, 100) to (200, 100)
    try ann_list.append(alloc, Annotation{
        .id = 102,
        .kind = .line,
        .start_x = 100,
        .start_y = 100,
        .end_x = 200,
        .end_y = 100,
        .stroke_width = 4,
    });

    try std.testing.expectEqual(@as(usize, 2), ann_list.items.len);

    // Hit test erasing line 102 at (150, 100)
    var erased_id: ?u32 = null;
    var i = ann_list.items.len;
    while (i > 0) {
        i -= 1;
        if (ann_list.items[i].hitTest(150, 100)) {
            erased_id = ann_list.items[i].id;
            var removed = ann_list.orderedRemove(i);
            removed.deinit(alloc);
            break;
        }
    }

    try std.testing.expectEqual(@as(?u32, 102), erased_id);
    try std.testing.expectEqual(@as(usize, 1), ann_list.items.len);
    try std.testing.expectEqual(@as(u32, 101), ann_list.items[0].id);
}

test "parseHexColor parses 3, 6, 8 hex and rejects invalid" {
    // 6-digit hex
    const red = AnnotateApp.parseHexColor("#FF0000").?;
    try std.testing.expectEqual(@as(u8, 255), red.r);
    try std.testing.expectEqual(@as(u8, 0), red.g);
    try std.testing.expectEqual(@as(u8, 0), red.b);
    try std.testing.expectEqual(@as(u8, 255), red.a);

    // 3-digit hex (#0F0 -> #00FF00)
    const green = AnnotateApp.parseHexColor("#0F0").?;
    try std.testing.expectEqual(@as(u8, 0), green.r);
    try std.testing.expectEqual(@as(u8, 255), green.g);
    try std.testing.expectEqual(@as(u8, 0), green.b);

    // Without '#' prefix
    const blue = AnnotateApp.parseHexColor("0000FF").?;
    try std.testing.expectEqual(@as(u8, 0), blue.r);
    try std.testing.expectEqual(@as(u8, 0), blue.g);
    try std.testing.expectEqual(@as(u8, 255), blue.b);

    // 8-digit hex with alpha
    const transparent_yellow = AnnotateApp.parseHexColor("#FFFF0080").?;
    try std.testing.expectEqual(@as(u8, 255), transparent_yellow.r);
    try std.testing.expectEqual(@as(u8, 255), transparent_yellow.g);
    try std.testing.expectEqual(@as(u8, 0), transparent_yellow.b);
    try std.testing.expectEqual(@as(u8, 128), transparent_yellow.a);

    // Invalid inputs
    try std.testing.expect(AnnotateApp.parseHexColor("") == null);
    try std.testing.expect(AnnotateApp.parseHexColor("#GG0000") == null);
    try std.testing.expect(AnnotateApp.parseHexColor("1234") == null);
}
