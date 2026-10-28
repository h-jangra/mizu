const std = @import("std");
const c = @import("../c.zig").c;
const renderer = @import("../core/renderer.zig");
const theme = @import("../core/theme.zig");
const Color = theme.Color;
const Rect = renderer.Rect;
const Font = renderer.Font;

pub const ResizeFilter = enum {
    nearest,
    bilinear,
};

pub const ImageBuffer = struct {
    width: u32,
    height: u32,
    pixels: []u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, bg_color: Color) !ImageBuffer {
        if (width == 0 or height == 0) return error.InvalidDimensions;
        const total = @as(usize, width) * @as(usize, height);
        const pixels = try allocator.alloc(u32, total);
        const fill_val = bg_color.toArgb();
        @memset(pixels, fill_val);
        return ImageBuffer{
            .width = width,
            .height = height,
            .pixels = pixels,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ImageBuffer) void {
        if (self.pixels.len > 0) {
            self.allocator.free(self.pixels);
            self.pixels = &.{};
        }
    }

    pub fn clone(self: *const ImageBuffer, allocator: std.mem.Allocator) !ImageBuffer {
        const total = @as(usize, self.width) * @as(usize, self.height);
        const pixels = try allocator.alloc(u32, total);
        @memcpy(pixels, self.pixels[0..total]);
        return ImageBuffer{
            .width = self.width,
            .height = self.height,
            .pixels = pixels,
            .allocator = allocator,
        };
    }

    pub fn fromRendererImage(allocator: std.mem.Allocator, img: *const renderer.Image) !ImageBuffer {
        const total = @as(usize, img.width) * @as(usize, img.height);
        const pixels = try allocator.alloc(u32, total);
        @memcpy(pixels, img.pixels[0..total]);
        return ImageBuffer{
            .width = img.width,
            .height = img.height,
            .pixels = pixels,
            .allocator = allocator,
        };
    }

    pub fn toRendererImage(self: *const ImageBuffer, allocator: std.mem.Allocator) !*renderer.Image {
        const total = @as(usize, self.width) * @as(usize, self.height);
        const pixels = try allocator.alloc(u32, total);
        @memcpy(pixels, self.pixels[0..total]);
        const img = try allocator.create(renderer.Image);
        img.* = .{
            .width = self.width,
            .height = self.height,
            .pixels = pixels,
            .allocator = allocator,
        };
        return img;
    }

    pub inline fn getPixel(self: *const ImageBuffer, x: i32, y: i32) ?Color {
        if (x < 0 or y < 0 or x >= @as(i32, @intCast(self.width)) or y >= @as(i32, @intCast(self.height))) {
            return null;
        }
        const idx = @as(usize, @intCast(y)) * @as(usize, self.width) + @as(usize, @intCast(x));
        const px = self.pixels[idx];
        return Color.init(
            @intCast((px >> 24) & 0xFF),
            @intCast((px >> 16) & 0xFF),
            @intCast((px >> 8) & 0xFF),
            @intCast(px & 0xFF),
        );
    }

    pub inline fn setPixel(self: *ImageBuffer, x: i32, y: i32, col: Color) void {
        if (x < 0 or y < 0 or x >= @as(i32, @intCast(self.width)) or y >= @as(i32, @intCast(self.height))) {
            return;
        }
        const idx = @as(usize, @intCast(y)) * @as(usize, self.width) + @as(usize, @intCast(x));
        self.pixels[idx] = col.toArgb();
    }

    pub inline fn blendPixel(self: *ImageBuffer, x: i32, y: i32, col: Color) void {
        if (x < 0 or y < 0 or x >= @as(i32, @intCast(self.width)) or y >= @as(i32, @intCast(self.height))) {
            return;
        }
        if (col.a == 0) return;
        const idx = @as(usize, @intCast(y)) * @as(usize, self.width) + @as(usize, @intCast(x));
        if (col.a == 255) {
            self.pixels[idx] = col.toArgb();
            return;
        }

        const dst_px = self.pixels[idx];
        const da = @as(u32, (dst_px >> 24) & 0xFF);
        const dr = @as(u32, (dst_px >> 16) & 0xFF);
        const dg = @as(u32, (dst_px >> 8) & 0xFF);
        const db = @as(u32, dst_px & 0xFF);

        const sa = @as(u32, col.a);
        const sr = @as(u32, col.r);
        const sg = @as(u32, col.g);
        const sb = @as(u32, col.b);

        const inv_sa = 255 - sa;
        const out_a = sa + ((da * inv_sa + 127) / 255);
        if (out_a == 0) {
            self.pixels[idx] = 0;
            return;
        }

        const out_r = ((sr * sa + dr * da * inv_sa / 255) + (out_a / 2)) / out_a;
        const out_g = ((sg * sa + dg * da * inv_sa / 255) + (out_a / 2)) / out_a;
        const out_b = ((sb * sa + db * da * inv_sa / 255) + (out_a / 2)) / out_a;

        self.pixels[idx] = (@as(u32, @intCast(@min(255, out_a))) << 24) |
            (@as(u32, @intCast(@min(255, out_r))) << 16) |
            (@as(u32, @intCast(@min(255, out_g))) << 8) |
            @as(u32, @intCast(@min(255, out_b)));
    }

    // ==========================================
    // Transforms: Crop, Resize, Rotate, Flip
    // ==========================================

    pub fn crop(self: *const ImageBuffer, allocator: std.mem.Allocator, rect: Rect) !ImageBuffer {
        const src_w: i32 = @intCast(self.width);
        const src_h: i32 = @intCast(self.height);

        const x0 = std.math.clamp(rect.x, 0, src_w);
        const y0 = std.math.clamp(rect.y, 0, src_h);
        const x1 = std.math.clamp(rect.x + @as(i32, @intCast(rect.w)), 0, src_w);
        const y1 = std.math.clamp(rect.y + @as(i32, @intCast(rect.h)), 0, src_h);

        if (x1 <= x0 or y1 <= y0) return error.EmptyCropRegion;
        const out_w: u32 = @intCast(x1 - x0);
        const out_h: u32 = @intCast(y1 - y0);

        var dst = try ImageBuffer.init(allocator, out_w, out_h, Color.transparent);
        errdefer dst.deinit();

        var dy: u32 = 0;
        while (dy < out_h) : (dy += 1) {
            const sy = @as(usize, @intCast(y0)) + dy;
            const src_start = sy * @as(usize, self.width) + @as(usize, @intCast(x0));
            const dst_start = @as(usize, dy) * @as(usize, out_w);
            @memcpy(dst.pixels[dst_start .. dst_start + out_w], self.pixels[src_start .. src_start + out_w]);
        }
        return dst;
    }

    pub fn resize(self: *const ImageBuffer, allocator: std.mem.Allocator, new_w: u32, new_h: u32, filter: ResizeFilter) !ImageBuffer {
        if (new_w == 0 or new_h == 0) return error.InvalidDimensions;
        var dst = try ImageBuffer.init(allocator, new_w, new_h, Color.transparent);
        errdefer dst.deinit();

        const x_scale = @as(f32, @floatFromInt(self.width)) / @as(f32, @floatFromInt(new_w));
        const y_scale = @as(f32, @floatFromInt(self.height)) / @as(f32, @floatFromInt(new_h));

        switch (filter) {
            .nearest => {
                var dy: u32 = 0;
                while (dy < new_h) : (dy += 1) {
                    const sy = @min(self.height - 1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(dy)) * y_scale)));
                    const src_row = @as(usize, sy) * @as(usize, self.width);
                    const dst_row = @as(usize, dy) * @as(usize, new_w);

                    var dx: u32 = 0;
                    while (dx < new_w) : (dx += 1) {
                        const sx = @min(self.width - 1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(dx)) * x_scale)));
                        dst.pixels[dst_row + dx] = self.pixels[src_row + sx];
                    }
                }
            },
            .bilinear => {
                var dy: u32 = 0;
                while (dy < new_h) : (dy += 1) {
                    const src_yf = @as(f32, @floatFromInt(dy)) * y_scale;
                    const y0 = @min(self.height - 1, @as(u32, @intFromFloat(src_yf)));
                    const y1 = @min(self.height - 1, y0 + 1);
                    const y_diff = src_yf - @as(f32, @floatFromInt(y0));

                    const src_row0 = @as(usize, y0) * @as(usize, self.width);
                    const src_row1 = @as(usize, y1) * @as(usize, self.width);
                    const dst_row = @as(usize, dy) * @as(usize, new_w);

                    var dx: u32 = 0;
                    while (dx < new_w) : (dx += 1) {
                        const src_xf = @as(f32, @floatFromInt(dx)) * x_scale;
                        const x0 = @min(self.width - 1, @as(u32, @intFromFloat(src_xf)));
                        const x1 = @min(self.width - 1, x0 + 1);
                        const x_diff = src_xf - @as(f32, @floatFromInt(x0));

                        const p00 = self.pixels[src_row0 + x0];
                        const p10 = self.pixels[src_row0 + x1];
                        const p01 = self.pixels[src_row1 + x0];
                        const p11 = self.pixels[src_row1 + x1];

                        const a00 = @as(f32, @floatFromInt((p00 >> 24) & 0xFF));
                        const r00 = @as(f32, @floatFromInt((p00 >> 16) & 0xFF));
                        const g00 = @as(f32, @floatFromInt((p00 >> 8) & 0xFF));
                        const b00 = @as(f32, @floatFromInt(p00 & 0xFF));

                        const a10 = @as(f32, @floatFromInt((p10 >> 24) & 0xFF));
                        const r10 = @as(f32, @floatFromInt((p10 >> 16) & 0xFF));
                        const g10 = @as(f32, @floatFromInt((p10 >> 8) & 0xFF));
                        const b10 = @as(f32, @floatFromInt(p10 & 0xFF));

                        const a01 = @as(f32, @floatFromInt((p01 >> 24) & 0xFF));
                        const r01 = @as(f32, @floatFromInt((p01 >> 16) & 0xFF));
                        const g01 = @as(f32, @floatFromInt((p01 >> 8) & 0xFF));
                        const b01 = @as(f32, @floatFromInt(p01 & 0xFF));

                        const a11 = @as(f32, @floatFromInt((p11 >> 24) & 0xFF));
                        const r11 = @as(f32, @floatFromInt((p11 >> 16) & 0xFF));
                        const g11 = @as(f32, @floatFromInt((p11 >> 8) & 0xFF));
                        const b11 = @as(f32, @floatFromInt(p11 & 0xFF));

                        const w00 = (1.0 - x_diff) * (1.0 - y_diff);
                        const w10 = x_diff * (1.0 - y_diff);
                        const w01 = (1.0 - x_diff) * y_diff;
                        const w11 = x_diff * y_diff;

                        const fa = a00 * w00 + a10 * w10 + a01 * w01 + a11 * w11;
                        const fr = r00 * w00 + r10 * w10 + r01 * w01 + r11 * w11;
                        const fg = g00 * w00 + g10 * w10 + g01 * w01 + g11 * w11;
                        const fb = b00 * w00 + b10 * w10 + b01 * w01 + b11 * w11;

                        const out_a: u32 = @intFromFloat(std.math.clamp(fa, 0.0, 255.0));
                        const out_r: u32 = @intFromFloat(std.math.clamp(fr, 0.0, 255.0));
                        const out_g: u32 = @intFromFloat(std.math.clamp(fg, 0.0, 255.0));
                        const out_b: u32 = @intFromFloat(std.math.clamp(fb, 0.0, 255.0));

                        dst.pixels[dst_row + dx] = (out_a << 24) | (out_r << 16) | (out_g << 8) | out_b;
                    }
                }
            },
        }
        return dst;
    }

    pub fn rotate90(self: *const ImageBuffer, allocator: std.mem.Allocator) !ImageBuffer {
        var dst = try ImageBuffer.init(allocator, self.height, self.width, Color.transparent);
        errdefer dst.deinit();

        var sy: u32 = 0;
        while (sy < self.height) : (sy += 1) {
            const src_row = @as(usize, sy) * @as(usize, self.width);
            var sx: u32 = 0;
            while (sx < self.width) : (sx += 1) {
                const dx = self.height - 1 - sy;
                const dy = sx;
                const dst_idx = @as(usize, dy) * @as(usize, dst.width) + @as(usize, dx);
                dst.pixels[dst_idx] = self.pixels[src_row + sx];
            }
        }
        return dst;
    }

    pub fn rotate180(self: *const ImageBuffer, allocator: std.mem.Allocator) !ImageBuffer {
        var dst = try ImageBuffer.init(allocator, self.width, self.height, Color.transparent);
        errdefer dst.deinit();

        const total = @as(usize, self.width) * @as(usize, self.height);
        var i: usize = 0;
        while (i < total) : (i += 1) {
            dst.pixels[total - 1 - i] = self.pixels[i];
        }
        return dst;
    }

    pub fn rotate270(self: *const ImageBuffer, allocator: std.mem.Allocator) !ImageBuffer {
        var dst = try ImageBuffer.init(allocator, self.height, self.width, Color.transparent);
        errdefer dst.deinit();

        var sy: u32 = 0;
        while (sy < self.height) : (sy += 1) {
            const src_row = @as(usize, sy) * @as(usize, self.width);
            var sx: u32 = 0;
            while (sx < self.width) : (sx += 1) {
                const dx = sy;
                const dy = self.width - 1 - sx;
                const dst_idx = @as(usize, dy) * @as(usize, dst.width) + @as(usize, dx);
                dst.pixels[dst_idx] = self.pixels[src_row + sx];
            }
        }
        return dst;
    }

    pub fn flipHorizontal(self: *const ImageBuffer, allocator: std.mem.Allocator) !ImageBuffer {
        var dst = try ImageBuffer.init(allocator, self.width, self.height, Color.transparent);
        errdefer dst.deinit();

        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            const row = @as(usize, y) * @as(usize, self.width);
            var x: u32 = 0;
            while (x < self.width) : (x += 1) {
                dst.pixels[row + (self.width - 1 - x)] = self.pixels[row + x];
            }
        }
        return dst;
    }

    pub fn flipVertical(self: *const ImageBuffer, allocator: std.mem.Allocator) !ImageBuffer {
        var dst = try ImageBuffer.init(allocator, self.width, self.height, Color.transparent);
        errdefer dst.deinit();

        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            const src_row = @as(usize, y) * @as(usize, self.width);
            const dst_row = @as(usize, self.height - 1 - y) * @as(usize, self.width);
            @memcpy(dst.pixels[dst_row .. dst_row + self.width], self.pixels[src_row .. src_row + self.width]);
        }
        return dst;
    }

    // ==========================================
    // Color Adjustments & Filters
    // ==========================================

    /// Brightness offset: -1.0 to 1.0 (0.0 = unchanged)
    pub fn applyBrightness(self: *ImageBuffer, amount: f32) void {
        const offset = amount * 255.0;
        for (self.pixels) |*px| {
            const a = (px.* >> 24) & 0xFF;
            const r = @as(f32, @floatFromInt((px.* >> 16) & 0xFF)) + offset;
            const g = @as(f32, @floatFromInt((px.* >> 8) & 0xFF)) + offset;
            const b = @as(f32, @floatFromInt(px.* & 0xFF)) + offset;

            const ur: u32 = @intFromFloat(std.math.clamp(r, 0.0, 255.0));
            const ug: u32 = @intFromFloat(std.math.clamp(g, 0.0, 255.0));
            const ub: u32 = @intFromFloat(std.math.clamp(b, 0.0, 255.0));
            px.* = (a << 24) | (ur << 16) | (ug << 8) | ub;
        }
    }

    /// Contrast factor: 0.0 to 3.0 (1.0 = unchanged)
    pub fn applyContrast(self: *ImageBuffer, factor: f32) void {
        for (self.pixels) |*px| {
            const a = (px.* >> 24) & 0xFF;
            const r = (@as(f32, @floatFromInt((px.* >> 16) & 0xFF)) - 128.0) * factor + 128.0;
            const g = (@as(f32, @floatFromInt((px.* >> 8) & 0xFF)) - 128.0) * factor + 128.0;
            const b = (@as(f32, @floatFromInt(px.* & 0xFF)) - 128.0) * factor + 128.0;

            const ur: u32 = @intFromFloat(std.math.clamp(r, 0.0, 255.0));
            const ug: u32 = @intFromFloat(std.math.clamp(g, 0.0, 255.0));
            const ub: u32 = @intFromFloat(std.math.clamp(b, 0.0, 255.0));
            px.* = (a << 24) | (ur << 16) | (ug << 8) | ub;
        }
    }

    /// Saturation factor: 0.0 (grayscale) to 2.0 (1.0 = unchanged)
    pub fn applySaturation(self: *ImageBuffer, factor: f32) void {
        for (self.pixels) |*px| {
            const a = (px.* >> 24) & 0xFF;
            const r = @as(f32, @floatFromInt((px.* >> 16) & 0xFF));
            const g = @as(f32, @floatFromInt((px.* >> 8) & 0xFF));
            const b = @as(f32, @floatFromInt(px.* & 0xFF));

            const lum = 0.299 * r + 0.587 * g + 0.114 * b;
            const new_r = lum + (r - lum) * factor;
            const new_g = lum + (g - lum) * factor;
            const new_b = lum + (b - lum) * factor;

            const ur: u32 = @intFromFloat(std.math.clamp(new_r, 0.0, 255.0));
            const ug: u32 = @intFromFloat(std.math.clamp(new_g, 0.0, 255.0));
            const ub: u32 = @intFromFloat(std.math.clamp(new_b, 0.0, 255.0));
            px.* = (a << 24) | (ur << 16) | (ug << 8) | ub;
        }
    }

    pub fn applyGrayscale(self: *ImageBuffer) void {
        for (self.pixels) |*px| {
            const a = (px.* >> 24) & 0xFF;
            const r = (px.* >> 16) & 0xFF;
            const g = (px.* >> 8) & 0xFF;
            const b = px.* & 0xFF;
            const gray: u32 = (r * 77 + g * 150 + b * 29) >> 8;
            px.* = (a << 24) | (gray << 16) | (gray << 8) | gray;
        }
    }

    /// Blur entire image with given pixel radius (box blur)
    pub fn applyBlur(self: *ImageBuffer, radius: u32) void {
        if (radius == 0 or self.width == 0 or self.height == 0) return;
        const rect = Rect{ .x = 0, .y = 0, .w = self.width, .h = self.height };
        self.applyBlurRegion(rect, radius);
    }

    /// Blur a specific region (in-place)
    pub fn applyBlurRegion(self: *ImageBuffer, rect: Rect, radius: u32) void {
        if (radius == 0 or self.width == 0 or self.height == 0) return;
        const w_i: i32 = @intCast(self.width);
        const h_i: i32 = @intCast(self.height);

        const x0 = std.math.clamp(rect.x, 0, w_i);
        const y0 = std.math.clamp(rect.y, 0, h_i);
        const x1 = std.math.clamp(rect.x + @as(i32, @intCast(rect.w)), 0, w_i);
        const y1 = std.math.clamp(rect.y + @as(i32, @intCast(rect.h)), 0, h_i);
        if (x1 <= x0 or y1 <= y0) return;

        const rw: usize = @intCast(x1 - x0);
        const rh: usize = @intCast(y1 - y0);
        const r_rad: i32 = @intCast(radius);

        const temp = self.allocator.alloc(u32, rw * rh) catch return;
        defer self.allocator.free(temp);

        // Horizontal pass: self.pixels -> temp
        var y: usize = 0;
        while (y < rh) : (y += 1) {
            const py = @as(usize, @intCast(y0)) + y;
            const src_row = py * @as(usize, self.width);
            const dst_row = y * rw;

            var x: usize = 0;
            while (x < rw) : (x += 1) {
                const px_cur = @as(i32, @intCast(x0)) + @as(i32, @intCast(x));
                var sum_a: u32 = 0;
                var sum_r: u32 = 0;
                var sum_g: u32 = 0;
                var sum_b: u32 = 0;
                var count: u32 = 0;

                var k = -r_rad;
                while (k <= r_rad) : (k += 1) {
                    const sample_x = std.math.clamp(px_cur + k, 0, w_i - 1);
                    const p = self.pixels[src_row + @as(usize, @intCast(sample_x))];
                    sum_a += (p >> 24) & 0xFF;
                    sum_r += (p >> 16) & 0xFF;
                    sum_g += (p >> 8) & 0xFF;
                    sum_b += p & 0xFF;
                    count += 1;
                }

                temp[dst_row + x] = ((sum_a / count) << 24) |
                    ((sum_r / count) << 16) |
                    ((sum_g / count) << 8) |
                    (sum_b / count);
            }
        }

        // Vertical pass: temp -> self.pixels
        var x: usize = 0;
        while (x < rw) : (x += 1) {
            const px_dest = @as(usize, @intCast(x0)) + x;
            var y_idx: usize = 0;
            while (y_idx < rh) : (y_idx += 1) {
                const py_dest = @as(usize, @intCast(y0)) + y_idx;
                var sum_a: u32 = 0;
                var sum_r: u32 = 0;
                var sum_g: u32 = 0;
                var sum_b: u32 = 0;
                var count: u32 = 0;

                var k = -r_rad;
                while (k <= r_rad) : (k += 1) {
                    const sample_y = std.math.clamp(@as(i32, @intCast(y_idx)) + k, 0, @as(i32, @intCast(rh)) - 1);
                    const p = temp[@as(usize, @intCast(sample_y)) * rw + x];
                    sum_a += (p >> 24) & 0xFF;
                    sum_r += (p >> 16) & 0xFF;
                    sum_g += (p >> 8) & 0xFF;
                    sum_b += p & 0xFF;
                    count += 1;
                }

                self.pixels[py_dest * @as(usize, self.width) + px_dest] =
                    ((sum_a / count) << 24) |
                    ((sum_r / count) << 16) |
                    ((sum_g / count) << 8) |
                    (sum_b / count);
            }
        }
    }

    /// Pixelate / mosaic filter on a specific region
    pub fn applyPixelateRegion(self: *ImageBuffer, rect: Rect, block_size: u32) void {
        const bs = @max(2, block_size);
        const w_i: i32 = @intCast(self.width);
        const h_i: i32 = @intCast(self.height);

        const x0 = std.math.clamp(rect.x, 0, w_i);
        const y0 = std.math.clamp(rect.y, 0, h_i);
        const x1 = std.math.clamp(rect.x + @as(i32, @intCast(rect.w)), 0, w_i);
        const y1 = std.math.clamp(rect.y + @as(i32, @intCast(rect.h)), 0, h_i);
        if (x1 <= x0 or y1 <= y0) return;

        var by = y0;
        while (by < y1) : (by += @intCast(bs)) {
            const b_end_y = @min(y1, by + @as(i32, @intCast(bs)));
            var bx = x0;
            while (bx < x1) : (bx += @intCast(bs)) {
                const b_end_x = @min(x1, bx + @as(i32, @intCast(bs)));

                var sum_a: u64 = 0;
                var sum_r: u64 = 0;
                var sum_g: u64 = 0;
                var sum_b: u64 = 0;
                var count: u64 = 0;

                var py = by;
                while (py < b_end_y) : (py += 1) {
                    const row = @as(usize, @intCast(py)) * @as(usize, self.width);
                    var px = bx;
                    while (px < b_end_x) : (px += 1) {
                        const p = self.pixels[row + @as(usize, @intCast(px))];
                        sum_a += (p >> 24) & 0xFF;
                        sum_r += (p >> 16) & 0xFF;
                        sum_g += (p >> 8) & 0xFF;
                        sum_b += p & 0xFF;
                        count += 1;
                    }
                }

                if (count == 0) continue;
                const avg_color = (@as(u32, @intCast(sum_a / count)) << 24) |
                    (@as(u32, @intCast(sum_r / count)) << 16) |
                    (@as(u32, @intCast(sum_g / count)) << 8) |
                    @as(u32, @intCast(sum_b / count));

                py = by;
                while (py < b_end_y) : (py += 1) {
                    const row = @as(usize, @intCast(py)) * @as(usize, self.width);
                    var px = bx;
                    while (px < b_end_x) : (px += 1) {
                        self.pixels[row + @as(usize, @intCast(px))] = avg_color;
                    }
                }
            }
        }
    }

    /// Highlight a region with semi-transparent color tint
    pub fn applyHighlightRegion(self: *ImageBuffer, rect: Rect, tint: Color) void {
        const w_i: i32 = @intCast(self.width);
        const h_i: i32 = @intCast(self.height);

        const x0 = std.math.clamp(rect.x, 0, w_i);
        const y0 = std.math.clamp(rect.y, 0, h_i);
        const x1 = std.math.clamp(rect.x + @as(i32, @intCast(rect.w)), 0, w_i);
        const y1 = std.math.clamp(rect.y + @as(i32, @intCast(rect.h)), 0, h_i);
        if (x1 <= x0 or y1 <= y0) return;

        var y = y0;
        while (y < y1) : (y += 1) {
            var x = x0;
            while (x < x1) : (x += 1) {
                self.blendPixel(x, y, tint);
            }
        }
    }

    /// Composite another image scaled to (dest_w, dest_h) at (dest_x, dest_y)
    pub fn compositeScaled(self: *ImageBuffer, src: *const ImageBuffer, dest_x: i32, dest_y: i32, dest_w: u32, dest_h: u32) void {
        if (dest_w == 0 or dest_h == 0 or src.width == 0 or src.height == 0) return;

        const dw_f = @as(f32, @floatFromInt(dest_w));
        const dh_f = @as(f32, @floatFromInt(dest_h));
        const sw_f = @as(f32, @floatFromInt(src.width));
        const sh_f = @as(f32, @floatFromInt(src.height));

        const min_x = @max(0, dest_x);
        const max_x = @min(@as(i32, @intCast(self.width)), dest_x + @as(i32, @intCast(dest_w)));
        const min_y = @max(0, dest_y);
        const max_y = @min(@as(i32, @intCast(self.height)), dest_y + @as(i32, @intCast(dest_h)));

        if (min_x >= max_x or min_y >= max_y) return;

        var y: i32 = min_y;
        while (y < max_y) : (y += 1) {
            const sy_f = (@as(f32, @floatFromInt(y - dest_y)) / dh_f) * sh_f;
            const sy = std.math.clamp(@as(usize, @intFromFloat(sy_f)), 0, src.height - 1);
            const src_row = sy * src.width;

            var x: i32 = min_x;
            while (x < max_x) : (x += 1) {
                const sx_f = (@as(f32, @floatFromInt(x - dest_x)) / dw_f) * sw_f;
                const sx = std.math.clamp(@as(usize, @intFromFloat(sx_f)), 0, src.width - 1);

                const src_px = src.pixels[src_row + sx];
                const col = Color.fromArgb(src_px);
                self.blendPixel(x, y, col);
            }
        }
    }

    // ==========================================
    // Drawing Primitives (Annotations)
    // ==========================================

    /// Draw filled circle at center (x, y) with radius r
    pub fn fillCircle(self: *ImageBuffer, cx: i32, cy: i32, radius: i32, col: Color) void {
        if (radius <= 0) {
            self.blendPixel(cx, cy, col);
            return;
        }
        const r_sq = radius * radius;
        var dy = -radius;
        while (dy <= radius) : (dy += 1) {
            const y = cy + dy;
            if (y < 0 or y >= @as(i32, @intCast(self.height))) continue;
            var dx = -radius;
            while (dx <= radius) : (dx += 1) {
                if (dx * dx + dy * dy <= r_sq) {
                    self.blendPixel(cx + dx, y, col);
                }
            }
        }
    }

    /// Draw stroke line with thickness using circle caps / interpolation
    pub fn drawStrokeLine(self: *ImageBuffer, x0: i32, y0: i32, x1: i32, y1: i32, stroke_width: u32, col: Color) void {
        const radius: i32 = @intCast(@max(1, stroke_width / 2));
        const dx: i32 = @intCast(@abs(x1 - x0));
        const dy: i32 = @intCast(@abs(y1 - y0));
        const steps = @max(dx, dy);

        if (steps == 0) {
            self.fillCircle(x0, y0, radius, col);
            return;
        }

        const step_f: f32 = @floatFromInt(steps);
        const x_inc = @as(f32, @floatFromInt(x1 - x0)) / step_f;
        const y_inc = @as(f32, @floatFromInt(y1 - y0)) / step_f;

        var curr_x: f32 = @floatFromInt(x0);
        var curr_y: f32 = @floatFromInt(y0);

        var i: i32 = 0;
        while (i <= steps) : (i += 1) {
            self.fillCircle(@intFromFloat(curr_x), @intFromFloat(curr_y), radius, col);
            curr_x += x_inc;
            curr_y += y_inc;
        }
    }

    /// Draw line with arrowhead pointing at (x1, y1)
    pub fn drawArrow(self: *ImageBuffer, x0: i32, y0: i32, x1: i32, y1: i32, stroke_width: u32, col: Color) void {
        self.drawStrokeLine(x0, y0, x1, y1, stroke_width, col);

        const dx = @as(f32, @floatFromInt(x1 - x0));
        const dy = @as(f32, @floatFromInt(y1 - y0));
        const len = std.math.sqrt(dx * dx + dy * dy);
        if (len < 4.0) return;

        const ux = dx / len;
        const uy = dy / len;

        // Arrow head dimensions
        const head_len = @max(16.0, @as(f32, @floatFromInt(stroke_width)) * 3.5);
        const head_width = head_len * 0.55;

        // Base of the arrowhead
        const bx = @as(f32, @floatFromInt(x1)) - ux * head_len;
        const by = @as(f32, @floatFromInt(y1)) - uy * head_len;

        // Normal perpendicular vector
        const nx = -uy;
        const ny = ux;

        const left_x: i32 = @intFromFloat(bx + nx * head_width);
        const left_y: i32 = @intFromFloat(by + ny * head_width);
        const right_x: i32 = @intFromFloat(bx - nx * head_width);
        const right_y: i32 = @intFromFloat(by - ny * head_width);

        // Draw arrowhead wings
        self.drawStrokeLine(x1, y1, left_x, left_y, stroke_width, col);
        self.drawStrokeLine(x1, y1, right_x, right_y, stroke_width, col);
        self.drawStrokeLine(left_x, left_y, right_x, right_y, stroke_width, col);
    }

    /// Draw rectangle (outline or filled)
    pub fn drawRect(self: *ImageBuffer, rect: Rect, stroke_width: u32, col: Color, filled: bool) void {
        const x = rect.x;
        const y = rect.y;
        const w: i32 = @intCast(rect.w);
        const h: i32 = @intCast(rect.h);

        if (filled) {
            var cy = y;
            while (cy < y + h) : (cy += 1) {
                var cx = x;
                while (cx < x + w) : (cx += 1) {
                    self.blendPixel(cx, cy, col);
                }
            }
        } else {
            const sw: i32 = @intCast(@max(1, stroke_width));
            // Top and Bottom
            var cy = y;
            while (cy < y + sw) : (cy += 1) {
                var cx = x;
                while (cx < x + w) : (cx += 1) self.blendPixel(cx, cy, col);
            }
            cy = y + h - sw;
            while (cy < y + h) : (cy += 1) {
                var cx = x;
                while (cx < x + w) : (cx += 1) self.blendPixel(cx, cy, col);
            }
            // Left and Right
            cy = y + sw;
            while (cy < y + h - sw) : (cy += 1) {
                var cx = x;
                while (cx < x + sw) : (cx += 1) self.blendPixel(cx, cy, col);
                cx = x + w - sw;
                while (cx < x + w) : (cx += 1) self.blendPixel(cx, cy, col);
            }
        }
    }

    /// Draw circle / ellipse (outline or filled)
    pub fn drawCircle(self: *ImageBuffer, cx: i32, cy: i32, radius: i32, stroke_width: u32, col: Color, filled: bool) void {
        if (radius <= 0) return;
        if (filled) {
            self.fillCircle(cx, cy, radius, col);
            return;
        }

        const sw: i32 = @intCast(@max(1, stroke_width));
        const r_outer = radius + @divTrunc(sw, 2);
        const r_inner = @max(0, r_outer - sw);
        const r_outer_sq = r_outer * r_outer;
        const r_inner_sq = r_inner * r_inner;

        var dy = -r_outer;
        while (dy <= r_outer) : (dy += 1) {
            const y = cy + dy;
            if (y < 0 or y >= @as(i32, @intCast(self.height))) continue;
            var dx = -r_outer;
            while (dx <= r_outer) : (dx += 1) {
                const dist_sq = dx * dx + dy * dy;
                if (dist_sq <= r_outer_sq and dist_sq >= r_inner_sq) {
                    self.blendPixel(cx + dx, y, col);
                }
            }
        }
    }

    /// Render text directly onto the pixel buffer using FreeType font
    pub fn drawText(self: *ImageBuffer, font: *Font, text: []const u8, x: i32, baseline_y: i32, size_px: u32, col: Color) void {
        var pen_x = x;
        var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
        while (it.nextCodepoint()) |cp| {
            if (font.getOrLoadGlyph(cp, size_px)) |glyph| {
                if (glyph.bitmap.len > 0 and glyph.width > 0 and glyph.height > 0) {
                    const gx = pen_x + glyph.left;
                    const gy = baseline_y - glyph.top;

                    var r_idx: u32 = 0;
                    while (r_idx < glyph.height) : (r_idx += 1) {
                        const py = gy + @as(i32, @intCast(r_idx));
                        if (py < 0 or py >= @as(i32, @intCast(self.height))) continue;

                        var c_idx: u32 = 0;
                        while (c_idx < glyph.width) : (c_idx += 1) {
                            const px = gx + @as(i32, @intCast(c_idx));
                            if (px < 0 or px >= @as(i32, @intCast(self.width))) continue;

                            const alpha = glyph.bitmap[r_idx * glyph.width + c_idx];
                            if (alpha == 0) continue;

                            const blended_alpha: u8 = @intCast((@as(u16, col.a) * @as(u16, alpha)) / 255);
                            self.blendPixel(px, py, Color.init(blended_alpha, col.r, col.g, col.b));
                        }
                    }
                }
                pen_x += glyph.advance_x;
            }
        }
    }

    // ==========================================
    // File I/O: Load, Save PNG, Save JPEG
    // ==========================================

    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !ImageBuffer {
        // Try SVG if file extension is .svg
        if (std.mem.endsWith(u8, path, ".svg")) {
            if (try loadSvg(allocator, path)) |buf| return buf;
        }

        // Try PNG / JPEG via renderer.Image
        if (try renderer.Image.loadFile(allocator, path)) |r_img| {
            defer r_img.deinit();
            return try ImageBuffer.fromRendererImage(allocator, r_img);
        }

        return error.ImageLoadFailed;
    }

    pub fn loadFromMemory(allocator: std.mem.Allocator, data: []const u8) !ImageBuffer {
        if (data.len >= 4 and (std.mem.startsWith(u8, data, "<?xml") or std.mem.startsWith(u8, data, "<svg") or std.mem.indexOf(u8, data[0..@min(data.len, 256)], "<svg") != null)) {
            if (try loadSvgFromMemory(allocator, data)) |buf| return buf;
        }

        if (try renderer.Image.loadMemory(allocator, data)) |r_img| {
            defer r_img.deinit();
            return try ImageBuffer.fromRendererImage(allocator, r_img);
        }

        return error.ImageLoadFailed;
    }

    pub fn loadSvgFromMemory(allocator: std.mem.Allocator, data: []const u8) !?ImageBuffer {
        const c_data = try allocator.dupeZ(u8, data);
        defer allocator.free(c_data);

        const svg_img = c.nsvgParse(c_data.ptr, "px", 96.0) orelse return null;
        defer c.nsvgDelete(svg_img);

        const orig_w = svg_img.*.width;
        const orig_h = svg_img.*.height;
        if (orig_w <= 0.0 or orig_h <= 0.0) return null;

        // Smart vector scale: small icons upscale to ~1200px so they are sharp;
        // huge SVGs clamp to 2048px to keep RAM minimal (< 20MB)
        const max_dim = @max(orig_w, orig_h);
        var scale: f32 = 1.0;
        if (max_dim < 1000.0 and max_dim > 0.0) {
            scale = 1200.0 / max_dim;
        } else if (max_dim > 2048.0) {
            scale = 2048.0 / max_dim;
        }

        const w: u32 = @intFromFloat(@max(1.0, orig_w * scale));
        const h: u32 = @intFromFloat(@max(1.0, orig_h * scale));

        const rast = c.nsvgCreateRasterizer() orelse return null;
        defer c.nsvgDeleteRasterizer(rast);

        var buf = try ImageBuffer.init(allocator, w, h, Color.transparent);
        errdefer buf.deinit();

        const stride: usize = @as(usize, w);
        if (c.nsvgRasterizeArgb(rast, @ptrCast(buf.pixels.ptr), @intCast(w), @intCast(h), @intCast(stride), svg_img, 0, 0, scale) != 0) {
            buf.deinit();
            return null;
        }

        return buf;
    }

    pub fn loadSvg(allocator: std.mem.Allocator, path: []const u8) !?ImageBuffer {
        const c_path = try allocator.dupeZ(u8, path);
        defer allocator.free(c_path);

        const svg_img = c.nsvgParseFromFile(c_path.ptr, "px", 96.0) orelse return null;
        defer c.nsvgDelete(svg_img);

        const orig_w = svg_img.*.width;
        const orig_h = svg_img.*.height;
        if (orig_w <= 0.0 or orig_h <= 0.0) return null;

        // Smart vector scale: small icons upscale to ~1200px so they are sharp;
        // huge SVGs clamp to 2048px to keep RAM minimal (< 20MB)
        const max_dim = @max(orig_w, orig_h);
        var scale: f32 = 1.0;
        if (max_dim < 1000.0 and max_dim > 0.0) {
            scale = 1200.0 / max_dim;
        } else if (max_dim > 2048.0) {
            scale = 2048.0 / max_dim;
        }

        const w: u32 = @intFromFloat(@max(1.0, orig_w * scale));
        const h: u32 = @intFromFloat(@max(1.0, orig_h * scale));

        const rast = c.nsvgCreateRasterizer() orelse return null;
        defer c.nsvgDeleteRasterizer(rast);

        var buf = try ImageBuffer.init(allocator, w, h, Color.transparent);
        errdefer buf.deinit();

        const stride: usize = @as(usize, w);
        if (c.nsvgRasterizeArgb(rast, @ptrCast(buf.pixels.ptr), @intCast(w), @intCast(h), @intCast(stride), svg_img, 0, 0, scale) != 0) {
            buf.deinit();
            return null;
        }

        return buf;
    }

    pub fn savePng(self: *const ImageBuffer, path: []const u8) !void {
        var path_z: [1024]u8 = undefined;
        if (path.len >= path_z.len) return error.PathTooLong;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;

        const fp = c.fopen(path_z[0..path.len :0].ptr, "wb") orelse return error.FileOpenFailed;
        defer _ = c.fclose(fp);

        var png_ptr: ?*c.png_struct = c.png_create_write_struct(c.PNG_LIBPNG_VER_STRING, null, null, null) orelse return error.PngInitFailed;
        var info_ptr: ?*c.png_info = null;
        defer c.png_destroy_write_struct(&png_ptr, &info_ptr);

        info_ptr = c.png_create_info_struct(png_ptr.?) orelse return error.PngInitFailed;

        c.png_init_io(png_ptr.?, fp);

        c.png_set_IHDR(
            png_ptr.?,
            info_ptr.?,
            self.width,
            self.height,
            8,
            c.PNG_COLOR_TYPE_RGB_ALPHA,
            c.PNG_INTERLACE_NONE,
            c.PNG_COMPRESSION_TYPE_BASE,
            c.PNG_FILTER_TYPE_BASE,
        );

        // Convert little-endian ARGB [B, G, R, A] to PNG's expected [R, G, B, A]
        c.png_set_bgr(png_ptr.?);

        c.png_write_info(png_ptr.?, info_ptr.?);

        var row_ptrs = try self.allocator.alloc([*c]c.png_byte, self.height);
        defer self.allocator.free(row_ptrs);

        for (0..self.height) |y| {
            row_ptrs[y] = @ptrCast(self.pixels.ptr + y * self.width);
        }

        c.png_write_image(png_ptr.?, row_ptrs.ptr);
        c.png_write_end(png_ptr.?, null);
    }

    pub fn saveJpeg(self: *const ImageBuffer, path: []const u8, quality: c_int) !void {
        var path_z: [1024]u8 = undefined;
        if (path.len >= path_z.len) return error.PathTooLong;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;

        const fp = c.fopen(path_z[0..path.len :0].ptr, "wb") orelse return error.FileOpenFailed;
        defer _ = c.fclose(fp);

        var cinfo: c.struct_jpeg_compress_struct = undefined;
        var jerr: c.struct_jpeg_error_mgr = undefined;
        cinfo.err = c.jpeg_std_error(&jerr);
        c.jpeg_create_compress(&cinfo);
        defer c.jpeg_destroy_compress(&cinfo);

        c.jpeg_stdio_dest(&cinfo, fp);
        cinfo.image_width = self.width;
        cinfo.image_height = self.height;
        cinfo.input_components = 3;
        cinfo.in_color_space = c.JCS_RGB;

        c.jpeg_set_defaults(&cinfo);
        c.jpeg_set_quality(&cinfo, std.math.clamp(quality, 1, 100), c.TRUE);
        c.jpeg_start_compress(&cinfo, c.TRUE);

        const row_stride = @as(usize, self.width) * 3;
        const row_buf = try self.allocator.alloc(u8, row_stride);
        defer self.allocator.free(row_buf);

        var row_ptrs = [_][*c]u8{row_buf.ptr};

        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            const src_row = y * @as(usize, self.width);
            var x: usize = 0;
            while (x < self.width) : (x += 1) {
                const px = self.pixels[src_row + x];
                row_buf[x * 3 + 0] = @intCast((px >> 16) & 0xFF); // R
                row_buf[x * 3 + 1] = @intCast((px >> 8) & 0xFF);  // G
                row_buf[x * 3 + 2] = @intCast(px & 0xFF);         // B
            }
            _ = c.jpeg_write_scanlines(&cinfo, &row_ptrs, 1);
        }

        c.jpeg_finish_compress(&cinfo);
    }

    /// Save PNG directly to an in-memory byte slice
    pub fn savePngToMemory(self: *const ImageBuffer, allocator: std.mem.Allocator) ![]u8 {
        var list = std.ArrayList(u8).empty;
        errdefer list.deinit(allocator);

        const WriteContext = struct {
            list_ptr: *std.ArrayList(u8),
            alloc: std.mem.Allocator,

            fn writeData(png_ptr_: ?*c.png_struct, data_: [*c]u8, length: c.png_size_t) callconv(.c) void {
                const io_ptr = c.png_get_io_ptr(png_ptr_.?);
                const ctx = @as(*@This(), @ptrCast(@alignCast(io_ptr)));
                ctx.list_ptr.appendSlice(ctx.alloc, data_[0..length]) catch {};
            }

            fn flushData(png_ptr_: ?*c.png_struct) callconv(.c) void {
                _ = png_ptr_;
            }
        };

        var ctx = WriteContext{ .list_ptr = &list, .alloc = allocator };

        var png_ptr: ?*c.png_struct = c.png_create_write_struct(c.PNG_LIBPNG_VER_STRING, null, null, null) orelse return error.PngInitFailed;
        var info_ptr: ?*c.png_info = null;
        defer c.png_destroy_write_struct(&png_ptr, &info_ptr);

        info_ptr = c.png_create_info_struct(png_ptr.?) orelse return error.PngInitFailed;

        c.png_set_write_fn(png_ptr.?, @ptrCast(&ctx), WriteContext.writeData, WriteContext.flushData);

        c.png_set_IHDR(
            png_ptr.?,
            info_ptr.?,
            self.width,
            self.height,
            8,
            c.PNG_COLOR_TYPE_RGB_ALPHA,
            c.PNG_INTERLACE_NONE,
            c.PNG_COMPRESSION_TYPE_BASE,
            c.PNG_FILTER_TYPE_BASE,
        );

        c.png_set_bgr(png_ptr.?);
        c.png_write_info(png_ptr.?, info_ptr.?);

        var row_ptrs = try allocator.alloc([*c]c.png_byte, self.height);
        defer allocator.free(row_ptrs);

        for (0..self.height) |y| {
            row_ptrs[y] = @ptrCast(self.pixels.ptr + y * self.width);
        }

        c.png_write_image(png_ptr.?, row_ptrs.ptr);
        c.png_write_end(png_ptr.?, null);

        return try list.toOwnedSlice(allocator);
    }

    /// Pipe PNG bytes to `wl-copy --type image/png`
    pub fn copyToClipboard(self: *const ImageBuffer, allocator: std.mem.Allocator) !void {
        const png_data = try self.savePngToMemory(allocator);
        defer allocator.free(png_data);

        // Run wl-copy with stdin pipe
        var pipe_fds: [2]c_int = undefined;
        if (c.pipe(&pipe_fds) < 0) return error.PipeFailed;

        const pid = c.fork();
        if (pid < 0) {
            _ = c.close(pipe_fds[0]);
            _ = c.close(pipe_fds[1]);
            return error.ForkFailed;
        }

        if (pid == 0) {
            // Child process
            _ = c.close(pipe_fds[1]);
            _ = c.dup2(pipe_fds[0], c.STDIN_FILENO);
            _ = c.close(pipe_fds[0]);

            var env_path_buf: [512]u8 = undefined;
            const path_env = if (c.getenv("PATH")) |p| std.mem.span(p) else "/usr/bin";
            const env_path = std.fmt.bufPrintZ(&env_path_buf, "{s}:/usr/bin:/usr/local/bin:/usr/sbin:/sbin", .{path_env}) catch "/usr/bin";
            _ = c.setenv("PATH", env_path.ptr, 1);

            const args = [_][*c]const u8{ "wl-copy", "--type", "image/png", null };
            _ = c.execvp("wl-copy", @ptrCast(&args));
            c.exit(1);
        }

        // Parent process
        _ = c.close(pipe_fds[0]);
        var written: usize = 0;
        while (written < png_data.len) {
            const n = c.write(pipe_fds[1], png_data[written..].ptr, png_data.len - written);
            if (n <= 0) break;
            written += @intCast(n);
        }
        _ = c.close(pipe_fds[1]);

        var status: c_int = 0;
        _ = c.waitpid(pid, &status, 0);
    }

    /// Read image from Wayland clipboard via `wl-paste`
    pub fn loadFromClipboard(allocator: std.mem.Allocator) !?ImageBuffer {
        // 1. Try reading raw binary image data (PNG, JPEG, WebP)
        const img_cmd = "export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; wl-paste --type image/png 2>/dev/null || wl-paste --type image/jpeg 2>/dev/null || wl-paste --type image/webp 2>/dev/null";
        if (c.popen(img_cmd, "r")) |pipe| {
            defer _ = c.pclose(pipe);
            var list: std.ArrayListUnmanaged(u8) = .empty;
            defer list.deinit(allocator);

            var buf: [16384]u8 = undefined;
            while (true) {
                const n = c.fread(&buf, 1, buf.len, pipe);
                if (n == 0) break;
                try list.appendSlice(allocator, buf[0..n]);
            }

            if (list.items.len >= 4) {
                const is_png = list.items.len >= 8 and std.mem.startsWith(u8, list.items, "\x89PNG\r\n\x1a\n");
                const is_jpeg = list.items.len >= 2 and list.items[0] == 0xFF and list.items[1] == 0xD8;
                const is_webp = list.items.len >= 12 and std.mem.startsWith(u8, list.items, "RIFF") and std.mem.eql(u8, list.items[8..12], "WEBP");
                const is_svg = std.mem.startsWith(u8, list.items, "<svg") or std.mem.startsWith(u8, list.items, "<?xml") or std.mem.indexOf(u8, list.items[0..@min(list.items.len, 256)], "<svg") != null;

                if (is_png or is_jpeg or is_webp or is_svg) {
                    if (ImageBuffer.loadFromMemory(allocator, list.items)) |img| {
                        return img;
                    } else |_| {}
                }
            }
        }

        // 2. If no raw image data, check if clipboard contains a file path or URL pointing to an image file
        const txt_cmd = "export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; wl-paste --type text/plain 2>/dev/null || wl-paste 2>/dev/null";
        if (c.popen(txt_cmd, "r")) |pipe| {
            defer _ = c.pclose(pipe);
            var list: std.ArrayListUnmanaged(u8) = .empty;
            defer list.deinit(allocator);

            var buf: [4096]u8 = undefined;
            while (true) {
                const n = c.fread(&buf, 1, buf.len, pipe);
                if (n == 0) break;
                try list.appendSlice(allocator, buf[0..n]);
            }

            if (list.items.len > 0) {
                const trimmed = std.mem.trim(u8, list.items, " \t\r\n");
                const path = if (std.mem.startsWith(u8, trimmed, "file://"))
                    trimmed[7..]
                else
                    trimmed;

                if (path.len > 0 and path[0] == '/' and path.len < 512) {
                    var path_z: [512]u8 = undefined;
                    @memcpy(path_z[0..path.len], path);
                    path_z[path.len] = 0;
                    if (c.access(&path_z, c.R_OK) == 0) {
                        if (ImageBuffer.loadFromFile(allocator, path)) |img| {
                            return img;
                        } else |_| {}
                    }
                }
            }
        }

        return null;
    }

    /// Capture screenshot region using `slurp` and `grim`
    pub fn captureScreenshotRegion(allocator: std.mem.Allocator) !?ImageBuffer {
        // Create unique temporary filename
        const tmp_path = "/tmp/mizu_screenshot_tmp.png";
        _ = c.unlink(tmp_path);

        // Run: grim -g "$(slurp)" /tmp/mizu_screenshot_tmp.png
        var cmd_buf: [512]u8 = undefined;
        const cmd = std.fmt.bufPrintZ(
            &cmd_buf,
            "export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; REGION=$(slurp -d); if [ -n \"$REGION\" ]; then grim -g \"$REGION\" {s}; fi",
            .{tmp_path},
        ) catch return null;

        const ret = c.system(cmd.ptr);
        if (ret != 0) return null;

        const img_res = loadFromFile(allocator, tmp_path) catch {
            _ = c.unlink(tmp_path);
            return null;
        };
        _ = c.unlink(tmp_path);
        return img_res;
    }
};

// ==========================================
// Undo / Redo History Stack
// ==========================================

pub const UndoStack = struct {
    allocator: std.mem.Allocator,
    undo_items: std.ArrayList(ImageBuffer),
    redo_items: std.ArrayList(ImageBuffer),
    max_states: usize,

    pub fn init(allocator: std.mem.Allocator, max_states: usize) UndoStack {
        return .{
            .allocator = allocator,
            .undo_items = std.ArrayList(ImageBuffer).empty,
            .redo_items = std.ArrayList(ImageBuffer).empty,
            .max_states = @max(2, max_states),
        };
    }

    pub fn deinit(self: *UndoStack) void {
        for (self.undo_items.items) |*item| {
            item.deinit();
        }
        self.undo_items.deinit(self.allocator);

        for (self.redo_items.items) |*item| {
            item.deinit();
        }
        self.redo_items.deinit(self.allocator);
    }

    pub fn pushState(self: *UndoStack, current: *const ImageBuffer) !void {
        // Clear redo stack on new action
        for (self.redo_items.items) |*item| {
            item.deinit();
        }
        self.redo_items.clearRetainingCapacity();

        // Enforce max states limit by dropping the oldest
        if (self.undo_items.items.len >= self.max_states) {
            var oldest = self.undo_items.orderedRemove(0);
            oldest.deinit();
        }

        const snapshot = try current.clone(self.allocator);
        try self.undo_items.append(self.allocator, snapshot);
    }

    pub fn canUndo(self: *const UndoStack) bool {
        return self.undo_items.items.len > 0;
    }

    pub fn canRedo(self: *const UndoStack) bool {
        return self.redo_items.items.len > 0;
    }

    pub fn undo(self: *UndoStack, current: *ImageBuffer) !bool {
        if (!self.canUndo()) return false;

        // Push current state to redo
        const current_copy = try current.clone(self.allocator);
        try self.redo_items.append(self.allocator, current_copy);

        // Pop last state from undo
        const previous = self.undo_items.pop().?;
        current.deinit();
        current.* = previous;
        return true;
    }

    pub fn redo(self: *UndoStack, current: *ImageBuffer) !bool {
        if (!self.canRedo()) return false;

        // Push current state to undo
        const current_copy = try current.clone(self.allocator);
        try self.undo_items.append(self.allocator, current_copy);

        // Pop last state from redo
        const next_state = self.redo_items.pop().?;
        current.deinit();
        current.* = next_state;
        return true;
    }
};

// ==========================================
// Unit Tests for Image Operations
// ==========================================

test "ImageBuffer creation and get/set pixels" {
    const alloc = std.testing.allocator;
    var img = try ImageBuffer.init(alloc, 10, 10, Color.rgb(255, 0, 0));
    defer img.deinit();

    try std.testing.expectEqual(@as(u32, 10), img.width);
    try std.testing.expectEqual(@as(u32, 10), img.height);

    const p0 = img.getPixel(0, 0).?;
    try std.testing.expectEqual(@as(u8, 255), p0.r);
    try std.testing.expectEqual(@as(u8, 0), p0.g);
    try std.testing.expectEqual(@as(u8, 0), p0.b);
    try std.testing.expectEqual(@as(u8, 255), p0.a);

    img.setPixel(5, 5, Color.rgb(0, 255, 0));
    const p5 = img.getPixel(5, 5).?;
    try std.testing.expectEqual(@as(u8, 0), p5.r);
    try std.testing.expectEqual(@as(u8, 255), p5.g);
    try std.testing.expectEqual(@as(u8, 0), p5.b);
}

test "ImageBuffer crop and resize" {
    const alloc = std.testing.allocator;
    var img = try ImageBuffer.init(alloc, 20, 20, Color.rgb(10, 20, 30));
    defer img.deinit();

    var cropped = try img.crop(alloc, Rect{ .x = 5, .y = 5, .w = 10, .h = 8 });
    defer cropped.deinit();
    try std.testing.expectEqual(@as(u32, 10), cropped.width);
    try std.testing.expectEqual(@as(u32, 8), cropped.height);

    var resized = try img.resize(alloc, 40, 40, .nearest);
    defer resized.deinit();
    try std.testing.expectEqual(@as(u32, 40), resized.width);
    try std.testing.expectEqual(@as(u32, 40), resized.height);
}

test "ImageBuffer rotate and flip" {
    const alloc = std.testing.allocator;
    var img = try ImageBuffer.init(alloc, 20, 10, Color.rgb(0, 0, 0));
    defer img.deinit();

    var r90 = try img.rotate90(alloc);
    defer r90.deinit();
    try std.testing.expectEqual(@as(u32, 10), r90.width);
    try std.testing.expectEqual(@as(u32, 20), r90.height);

    var flip = try img.flipHorizontal(alloc);
    defer flip.deinit();
    try std.testing.expectEqual(@as(u32, 20), flip.width);
    try std.testing.expectEqual(@as(u32, 10), flip.height);
}

test "ImageBuffer filters and adjustments" {
    const alloc = std.testing.allocator;
    var img = try ImageBuffer.init(alloc, 16, 16, Color.rgb(100, 100, 100));
    defer img.deinit();

    img.applyBrightness(0.2);
    const pb = img.getPixel(0, 0).?;
    try std.testing.expect(pb.r > 100);

    img.applyGrayscale();
    const pg = img.getPixel(0, 0).?;
    try std.testing.expectEqual(pg.r, pg.g);
    try std.testing.expectEqual(pg.g, pg.b);

    img.applyPixelateRegion(Rect{ .x = 0, .y = 0, .w = 8, .h = 8 }, 4);
    img.applyBlurRegion(Rect{ .x = 0, .y = 0, .w = 8, .h = 8 }, 2);
}

test "ImageBuffer in-memory PNG roundtrip" {
    const alloc = std.testing.allocator;
    var img = try ImageBuffer.init(alloc, 16, 16, Color.rgb(200, 50, 80));
    defer img.deinit();

    const png_data = try img.savePngToMemory(alloc);
    defer alloc.free(png_data);
    try std.testing.expect(png_data.len > 8);

    // Verify PNG header signature
    try std.testing.expectEqual(@as(u8, 0x89), png_data[0]);
    try std.testing.expectEqual(@as(u8, 'P'), png_data[1]);
    try std.testing.expectEqual(@as(u8, 'N'), png_data[2]);
    try std.testing.expectEqual(@as(u8, 'G'), png_data[3]);
}

test "UndoStack operations" {
    const alloc = std.testing.allocator;
    var img = try ImageBuffer.init(alloc, 10, 10, Color.rgb(0, 0, 0));
    defer img.deinit();

    var undo_stack = UndoStack.init(alloc, 5);
    defer undo_stack.deinit();

    try undo_stack.pushState(&img);
    img.setPixel(0, 0, Color.rgb(255, 255, 255));

    try std.testing.expect(undo_stack.canUndo());
    try std.testing.expect(!undo_stack.canRedo());

    const undid = try undo_stack.undo(&img);
    try std.testing.expect(undid);
    const p = img.getPixel(0, 0).?;
    try std.testing.expectEqual(@as(u8, 0), p.r);

    try std.testing.expect(undo_stack.canRedo());
    const redid = try undo_stack.redo(&img);
    try std.testing.expect(redid);
    const p_redo = img.getPixel(0, 0).?;
    try std.testing.expectEqual(@as(u8, 255), p_redo.r);
}

test "SVG and file loading, transforms and PNG saving verification" {
    const alloc = std.testing.allocator;
    var img = ImageBuffer.loadFromFile(alloc, "assets/folder.svg") catch return;
    defer img.deinit();

    try std.testing.expect(img.width > 0);
    try std.testing.expect(img.height > 0);

    // Test rotate and flip on loaded asset
    var rot = try img.rotate90(alloc);
    defer rot.deinit();
    try std.testing.expectEqual(img.height, rot.width);
    try std.testing.expectEqual(img.width, rot.height);

    // Save to temp file and reload
    const tmp_file = "/tmp/mizu_test_folder.png";
    defer _ = c.unlink(tmp_file);

    try rot.savePng(tmp_file);

    var reloaded = try ImageBuffer.loadFromFile(alloc, tmp_file);
    defer reloaded.deinit();

    try std.testing.expectEqual(rot.width, reloaded.width);
    try std.testing.expectEqual(rot.height, reloaded.height);
}

test "SVG vector rendering with colors and styles" {
    const alloc = std.testing.allocator;
    const svg_data =
        \\<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" viewBox="0 0 100 100">
        \\  <rect x="0" y="0" width="100" height="100" fill="#ff0000"/>
        \\  <circle cx="50" cy="50" r="30" style="fill:rgb(0,255,0);stroke:#0000ff;stroke-width:2"/>
        \\</svg>
    ;
    var img = (try ImageBuffer.loadSvgFromMemory(alloc, svg_data)) orelse return error.SvgFailed;
    defer img.deinit();

    try std.testing.expect(img.width > 0);
    try std.testing.expect(img.height > 0);

    // Verify top-left corner has red fill (R=255, G=0, B=0, A=255)
    const tl_pixel = img.getPixel(2, 2).?;
    try std.testing.expectEqual(@as(u8, 255), tl_pixel.r);
    try std.testing.expectEqual(@as(u8, 0), tl_pixel.g);
    try std.testing.expectEqual(@as(u8, 0), tl_pixel.b);
    try std.testing.expectEqual(@as(u8, 255), tl_pixel.a);

    // Verify center has green circle fill (R=0, G=255, B=0, A=255)
    const cx: i32 = @intCast(img.width / 2);
    const cy: i32 = @intCast(img.height / 2);
    const center_pixel = img.getPixel(cx, cy).?;
    try std.testing.expectEqual(@as(u8, 0), center_pixel.r);
    try std.testing.expectEqual(@as(u8, 255), center_pixel.g);
    try std.testing.expectEqual(@as(u8, 0), center_pixel.b);
    try std.testing.expectEqual(@as(u8, 255), center_pixel.a);
}

test "SVG with oversized attribute and auto-bounding box" {
    const alloc = std.testing.allocator;
    // Generate an SVG path with commands exceeding 2500 bytes
    var d_buf = std.ArrayList(u8).empty;
    defer d_buf.deinit(alloc);

    try d_buf.appendSlice(alloc, "M 0 0 ");
    var i: usize = 0;
    while (i < 250) : (i += 1) {
        const x = (i % 25) * 10;
        const y = (i / 25) * 10;
        var num_buf: [64]u8 = undefined;
        const seg = try std.fmt.bufPrint(&num_buf, "L {} {} ", .{ x, y });
        try d_buf.appendSlice(alloc, seg);
    }
    try d_buf.appendSlice(alloc, "Z");
    try std.testing.expect(d_buf.items.len > 2000);

    const svg_str = try std.fmt.allocPrint(alloc, "<svg><path fill=\"#112233\" d=\"{s}\"/></svg>", .{d_buf.items});
    defer alloc.free(svg_str);

    var img = (try ImageBuffer.loadSvgFromMemory(alloc, svg_str)) orelse return error.SvgFailed;
    defer img.deinit();

    try std.testing.expect(img.width > 0);
    try std.testing.expect(img.height > 0);
}

test "SVG load complex calf.svg with long paths" {
    const alloc = std.testing.allocator;
    const path = "/usr/share/icons/hicolor/scalable/apps/calf.svg";
    const f = c.fopen(path, "rb") orelse return;
    _ = c.fclose(f);

    var ts0: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts0);

    var img = (try ImageBuffer.loadSvg(alloc, path)) orelse return error.SvgFailed;
    defer img.deinit();

    var ts1: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts1);

    const elapsed_ns = (@as(i128, ts1.tv_sec) - @as(i128, ts0.tv_sec)) * 1_000_000_000 + (@as(i128, ts1.tv_nsec) - @as(i128, ts0.tv_nsec));
    const elapsed_ms = @divTrunc(elapsed_ns, 1_000_000);
    try std.testing.expect(elapsed_ms < 5000);

    try std.testing.expect(img.width > 0);
    try std.testing.expect(img.height > 0);
}

test "Load assets/mizu.svg" {
    const alloc = std.testing.allocator;
    var img = (try ImageBuffer.loadSvg(alloc, "assets/mizu.svg")) orelse return error.SvgFailed;
    defer img.deinit();
    try std.testing.expect(img.width > 0);
    try std.testing.expect(img.height > 0);
}

test "Paste non-image data does not crash or exit" {
    const alloc = std.testing.allocator;
    const non_img_text = "/home/hj/some/file/that/is/not/an/image.txt";
    const res = try renderer.Image.loadMemory(alloc, non_img_text);
    try std.testing.expect(res == null);

    const buf_res = ImageBuffer.loadFromMemory(alloc, non_img_text);
    try std.testing.expectError(error.ImageLoadFailed, buf_res);
}


