const std = @import("std");
const renderer = @import("renderer.zig");
const theme = @import("theme.zig");

pub const Color = theme.Color;
pub const Image = renderer.Image;
pub const Font = renderer.Font;
pub const Rect = renderer.Rect;
pub const InkExtents = renderer.InkExtents;

/// A Raylib-inspired immediate-mode drawing context over the native renderer.
///
/// Coordinates are in pixels. `(0, 0)` is the top-left corner.
/// `x`/`y` are `i32`, `w`/`h` are `u32`.
///
/// Text `y` is the **baseline** (top of the glyph body, not including descenders),
/// matching the underlying FreeType renderer. Use `textTop` for top-aligned text.
pub const DrawCtx = struct {
    renderer: renderer.Renderer,

    pub fn init(pixels: [*]u32, width: u32, height: u32, stride: u32) !DrawCtx {
        return .{
            .renderer = try renderer.Renderer.init(pixels, width, height, stride),
        };
    }

    /// Access the underlying renderer for advanced operations not wrapped here.
    pub fn r(self: DrawCtx) renderer.Renderer {
        return self.renderer;
    }

    /// Set a clipping rectangle. Subsequent drawing is clipped to the intersection
    /// with the previous clip.
    pub fn clip(self: DrawCtx, x: i32, y: i32, w: u32, h: u32) void {
        self.renderer.active_clip = self.renderer.active_clip.intersect(
            renderer.Rect.init(x, y, w, h),
        );
    }

    /// Reset clipping to the full surface.
    pub fn clipReset(self: DrawCtx) void {
        self.renderer.active_clip = renderer.Rect.init(
            0, 0, self.renderer.width, self.renderer.height,
        );
    }

    // ---- Primitives ----

    pub fn clear(self: DrawCtx, color: Color) void {
        self.renderer.clear(color);
    }

    pub fn rect(self: DrawCtx, x: i32, y: i32, w: u32, h: u32, color: Color) void {
        self.renderer.fillRect(x, y, w, h, color);
    }

    pub fn roundedRect(self: DrawCtx, x: i32, y: i32, w: u32, h: u32, radius: u32, color: Color) void {
        self.renderer.fillRoundedRect(x, y, w, h, radius, color);
    }

    pub fn squircle(self: DrawCtx, x: i32, y: i32, w: u32, h: u32, radius: u32, color: Color) void {
        self.renderer.fillSquircle(x, y, w, h, radius, color);
    }

    pub fn circle(self: DrawCtx, cx: i32, cy: i32, r: u32, color: Color) void {
        self.renderer.fillCircle(@as(f64, @floatFromInt(cx)), @as(f64, @floatFromInt(cy)), @as(f64, @floatFromInt(r)), color);
    }

    pub fn line(self: DrawCtx, x1: i32, y1: i32, x2: i32, y2: i32, color: Color) void {
        const dx = @as(f32, @floatFromInt(x2)) - @as(f32, @floatFromInt(x1));
        const dy = @as(f32, @floatFromInt(y2)) - @as(f32, @floatFromInt(y1));
        const len = std.math.sqrt(dx * dx + dy * dy);
        if (len == 0.0) return;
        const steps = @as(i32, @intFromFloat(@ceil(len)));
        var i: i32 = 0;
        while (i <= steps) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
            const px = @as(i32, @intFromFloat(@as(f32, @floatFromInt(x1)) + dx * t));
            const py = @as(i32, @intFromFloat(@as(f32, @floatFromInt(y1)) + dy * t));
            self.renderer.setPixel(px, py, color);
        }
    }

    pub fn border(self: DrawCtx, x: i32, y: i32, w: u32, h: u32, color: Color) void {
        self.renderer.drawRoundedBorder(x, y, w, h, 0, 1, color);
    }

    pub fn roundedBorder(self: DrawCtx, x: i32, y: i32, w: u32, h: u32, radius: u32, color: Color) void {
        self.renderer.drawRoundedBorder(x, y, w, h, radius, 1, color);
    }

    pub fn shadow(self: DrawCtx, x: i32, y: i32, w: u32, h: u32, radius: u32, blur: u32, color: Color) void {
        self.renderer.drawDropShadow(x, y, w, h, radius, blur, 2, color);
    }

    // ---- Text ----

    /// Draw text at `(x, baseline_y)`. `baseline_y` is the typographic baseline
    /// (where the bottom of most capital letters sit).
    pub fn text(self: DrawCtx, font: *Font, txt: []const u8, x: i32, baseline_y: i32, size_px: u32, color: Color) void {
        self.renderer.drawTextWithSize(font, txt, x, baseline_y, size_px, color);
    }

    /// Draw text centered horizontally at `center_x`, baseline-aligned at `baseline_y`.
    pub fn textCentered(self: DrawCtx, font: *Font, txt: []const u8, center_x: i32, baseline_y: i32, size_px: u32, color: Color) void {
        self.renderer.drawTextCentered(font, txt, center_x, baseline_y, size_px, color);
    }

    /// Draw text vertically centered within a rect, top-aligned at `y`.
    /// `top_y` is the top edge of the text block; the baseline is computed from it.
    pub fn textTop(self: DrawCtx, font: *Font, txt: []const u8, x: i32, top_y: i32, size_px: u32, color: Color) void {
        const baseline = top_y + font.ascender_px;
        self.renderer.drawTextWithSize(font, txt, x, baseline, size_px, color);
    }

    /// Measure text width in pixels at the given size.
    pub fn measureText(self: DrawCtx, font: *Font, txt: []const u8, size_px: u32) u32 {
        _ = self;
        return font.measureTextWithSize(txt, size_px);
    }

    /// Measure visual ink bounds (left offset and width) for precise centering.
    pub fn measureInk(self: DrawCtx, font: *Font, txt: []const u8, size_px: u32) InkExtents {
        _ = self;
        return font.measureInk(txt, size_px);
    }

    // ---- Images ----

    pub fn image(self: DrawCtx, img: *Image, x: i32, y: i32, w: u32, h: u32) void {
        self.renderer.drawImage(img, @as(f64, @floatFromInt(x)), @as(f64, @floatFromInt(y)), @as(f64, @floatFromInt(w)), @as(f64, @floatFromInt(h)));
    }
};
