const std = @import("std");
const renderer = @import("core/renderer.zig");
const theme = @import("core/theme.zig");
const icons = @import("graphics/icons.zig");
const types = @import("bar/context.zig");

pub const Color = theme.Color;
pub const Font = renderer.Font;
pub const Image = renderer.Image;
pub const Rect = renderer.Rect;

/// A Raylib-inspired immediate-mode drawing context over the native renderer.
///
/// All coordinates are in pixels, (0, 0) is top-left. `x`/`y` are `i32`,
/// `w`/`h` are `u32`. Text `y` is the typographic baseline.
///
/// The context wraps `renderer.Renderer` and additionally tracks:
/// - allocator: for allocating clickable areas
/// - clickable_areas: the bar's interactive region list
/// - theme: for easy color access
/// - scale_factor: HiDPI scale factor (multiply logical sizes via scale)
/// - hover_x/hover_y: current pointer position for hover tests
pub const DrawContext = struct {
    renderer: renderer.Renderer,
    allocator: std.mem.Allocator,
    clickable_areas: *std.ArrayList(types.ClickableArea),
    th: theme.Theme,
    scale_factor: u32,
    hover_x: i32,
    hover_y: i32,

    pub fn init(
        allocator: std.mem.Allocator,
        pixels: [*]u32,
        width: u32,
        height: u32,
        stride: u32,
        clickable_areas: *std.ArrayList(types.ClickableArea),
        th: theme.Theme,
        scale_factor: u32,
        hover_x: i32,
        hover_y: i32,
    ) !DrawContext {
        return .{
            .renderer = try renderer.Renderer.init(pixels, width, height, stride),
            .allocator = allocator,
            .clickable_areas = clickable_areas,
            .th = th,
            .scale_factor = scale_factor,
            .hover_x = hover_x,
            .hover_y = hover_y,
        };
    }

    /// Access the underlying renderer for advanced operations not wrapped here.
    pub fn r(self: DrawContext) renderer.Renderer {
        return self.renderer;
    }

    /// Scale a logical pixel value by the display scale factor.
    pub fn scale(self: DrawContext, px: u32) u32 {
        return px * self.scale_factor;
    }

    /// Deprecated alias for `scale`. Use `scale` instead.
    pub fn scalePx(self: DrawContext, px: u32) u32 {
        return self.scale(px);
    }

    /// Test whether (x, y) is inside the rect (w, h).
    pub fn isHovered(self: DrawContext, x: i32, y: i32, w: u32, h: u32) bool {
        return (self.hover_x >= x and self.hover_x < x + @as(i32, @intCast(w)) and
            self.hover_y >= y and self.hover_y < y + @as(i32, @intCast(h)));
    }

    // ---- Primitives ----

    pub fn clear(self: DrawContext, color: Color) void {
        self.renderer.clear(color);
    }

    pub fn rect(self: DrawContext, x: i32, y: i32, w: u32, h: u32, color: Color) void {
        self.renderer.fillRect(x, y, w, h, color);
    }

    pub fn roundedRect(self: DrawContext, x: i32, y: i32, w: u32, h: u32, radius: u32, color: Color) void {
        self.renderer.fillRoundedRect(x, y, w, h, radius, color);
    }

    pub fn squircle(self: DrawContext, x: i32, y: i32, w: u32, h: u32, radius: u32, color: Color) void {
        self.renderer.fillSquircle(x, y, w, h, radius, color);
    }

    pub fn circle(self: DrawContext, cx: i32, cy: i32, radius: u32, color: Color) void {
        self.renderer.fillCircle(@as(f64, @floatFromInt(cx)), @as(f64, @floatFromInt(cy)), @as(f64, @floatFromInt(radius)), color);
    }

    pub fn line(self: DrawContext, x1: i32, y1: i32, x2: i32, y2: i32, color: Color) void {
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

    pub fn border(self: DrawContext, x: i32, y: i32, w: u32, h: u32, color: Color) void {
        self.renderer.drawRoundedBorder(x, y, w, h, 0, 1, color);
    }

    pub fn roundedBorder(self: DrawContext, x: i32, y: i32, w: u32, h: u32, radius: u32, color: Color) void {
        self.renderer.drawRoundedBorder(x, y, w, h, radius, 1, color);
    }

    pub fn shadow(self: DrawContext, x: i32, y: i32, w: u32, h: u32, radius: u32, blur: u32, color: Color) void {
        self.renderer.drawDropShadow(x, y, w, h, radius, blur, 2, color);
    }

    // ---- Clipping ----

    pub fn clip(self: DrawContext, x: i32, y: i32, w: u32, h: u32) void {
        self.renderer.active_clip = self.renderer.active_clip.intersect(
            renderer.Rect.init(x, y, w, h),
        );
    }

    pub fn clipReset(self: DrawContext) void {
        self.renderer.active_clip = renderer.Rect.init(0, 0, self.renderer.width, self.renderer.height);
    }

    // ---- Text ----

    /// Draw text at `(x, baseline_y)`. `baseline_y` is the typographic baseline.
    pub fn text(self: DrawContext, font: *Font, txt: []const u8, x: i32, baseline_y: i32, size_px: u32, color: Color) void {
        self.renderer.drawTextWithSize(font, txt, x, baseline_y, size_px, color);
    }

    /// Draw text centered horizontally at `center_x`, baseline-aligned at `baseline_y`.
    pub fn textCentered(self: DrawContext, font: *Font, txt: []const u8, center_x: i32, baseline_y: i32, size_px: u32, color: Color) void {
        self.renderer.drawTextCentered(font, txt, center_x, baseline_y, size_px, color);
    }

    /// Measure text width in pixels at the given size.
    pub fn measureText(self: DrawContext, font: *Font, txt: []const u8, size_px: u32) u32 {
        _ = self;
        return font.measureTextWithSize(txt, size_px);
    }

    /// Measure text width in pixels at the given size.
    /// Alias for `measureText`, kept for Raylib-style naming.
    pub fn textWidth(self: DrawContext, font: *Font, txt: []const u8, size_px: u32) u32 {
        return self.measureText(font, txt, size_px);
    }

    /// Draw text vertically centered within a rect of height `height`,
    /// with top edge at `y`. Uses the font's actual ascender for baseline
    /// computation so text is visually centered.
    pub fn textCenteredY(
        self: DrawContext,
        font: *Font,
        txt: []const u8,
        x: i32,
        y: i32,
        height: u32,
        size_px: u32,
        color: Color,
    ) void {
        self.renderer.drawTextVerticallyCentered(font, txt, x, y, height, size_px, color);
    }

    // ---- SVG Icons ----

    /// Draw an SVG icon at top-left `(x, y)`, tinted with `color`.
    /// `size_px` is the physical pixel size (already scaled by the caller).
    /// Falls back silently if the SVG asset is not found.
    /// Uses top-left coordinates for consistency with rectangle drawing.
    pub fn icon(self: DrawContext, name: []const u8, x: i32, y: i32, size_px: u32, color: Color) void {
        const raster_icon = icons.getIcon(self.allocator, name, size_px, self.scale_factor) orelse return;
        icons.drawIconRasterAt(self.renderer, raster_icon, x, y, color);
    }

    /// Draw an SVG icon centered at `(cx, cy)`, tinted with `color`.
    /// `size_px` is the physical pixel size (already scaled by the caller).
    /// Falls back silently if the SVG asset is not found.
    pub fn svgIcon(self: DrawContext, name: []const u8, size_px: u32, cx: i32, cy: i32, color: Color) void {
        const raster_icon = icons.getIcon(self.allocator, name, size_px, self.scale_factor) orelse return;
        icons.drawIconRaster(self.renderer, raster_icon, cx, cy, color);
    }

    // ---- Clickable regions ----

    /// Register a clickable area. Returns the index of the added area.
    pub fn addClickable(self: DrawContext, x: i32, y: i32, w: u32, h: u32, action: types.ClickAction) !void {
        try self.clickable_areas.append(self.allocator, .{
            .x = x,
            .y = y,
            .w = w,
            .h = h,
            .action = action,
            .scroll = null,
        });
    }

    /// Register a clickable area with scroll support.
    pub fn addClickableScroll(self: DrawContext, x: i32, y: i32, w: u32, h: u32, action: types.ClickAction, scroll: types.ScrollAction) !void {
        try self.clickable_areas.append(self.allocator, .{
            .x = x,
            .y = y,
            .w = w,
            .h = h,
            .action = action,
            .scroll = scroll,
        });
    }
};
