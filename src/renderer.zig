const std = @import("std");
const c = @import("c.zig").c;
const theme = @import("theme.zig");
const Color = theme.Color;

pub const CachedGlyph = struct {
    width: u32,
    height: u32,
    left: i32,
    top: i32,
    advance_x: i32,
    bitmap: []u8,
};

pub const Font = struct {
    ft_lib: c.FT_Library = null,
    face: c.FT_Face = null,
    fallback_face: ?c.FT_Face = null,
    allocator: std.mem.Allocator,
    size_px: u32,
    current_size_px: u32,
    ascender_px: i32,
    descender_px: i32,
    height_px: i32,
    family_c_str: [:0]const u8,
    glyph_cache: std.AutoHashMap(u64, CachedGlyph),

    pub fn init(allocator: std.mem.Allocator, font_family: []const u8, size_px: u32) !Font {
        var ft_lib: c.FT_Library = null;
        if (c.FT_Init_FreeType(&ft_lib) != 0) {
            return error.FreeTypeInitFailed;
        }
        errdefer _ = c.FT_Done_FreeType(ft_lib);

        // Find primary font path via Fontconfig
        const font_path = try findFontPath(allocator, font_family);
        defer allocator.free(font_path);

        var face: c.FT_Face = null;
        const c_path = try allocator.dupeZ(u8, font_path);
        defer allocator.free(c_path);

        if (c.FT_New_Face(ft_lib, c_path.ptr, 0, &face) != 0) {
            return error.FontLoadFailed;
        }
        errdefer _ = c.FT_Done_Face(face);

        if (c.FT_Set_Pixel_Sizes(face, 0, size_px) != 0) {
            return error.SetFontSizeFailed;
        }

        const metrics = face.*.size.*.metrics;
        const ascender_px = @as(i32, @intCast(metrics.ascender >> 6));
        const descender_px = @as(i32, @intCast(metrics.descender >> 6));
        const height_px = @as(i32, @intCast(metrics.height >> 6));

        // Load fallback face for symbols / Nerd Font
        var fallback_face: ?c.FT_Face = null;
        const fallback_path = findFontPath(allocator, "Symbols Nerd Font, JetBrainsMono Nerd Font, monospace") catch null;
        if (fallback_path) |fb_path| {
            defer allocator.free(fb_path);
            const fb_c_path = allocator.dupeZ(u8, fb_path) catch null;
            if (fb_c_path) |fcp| {
                defer allocator.free(fcp);
                var fb_f: c.FT_Face = null;
                if (c.FT_New_Face(ft_lib, fcp.ptr, 0, &fb_f) == 0) {
                    _ = c.FT_Set_Pixel_Sizes(fb_f, 0, size_px);
                    fallback_face = fb_f;
                }
            }
        }

        var first_family = font_family;
        if (std.mem.indexOfScalar(u8, font_family, ',')) |comma| {
            first_family = std.mem.trim(u8, font_family[0..comma], " \t");
        }
        const family_c_str = try allocator.dupeZ(u8, first_family);

        return .{
            .ft_lib = ft_lib,
            .face = face,
            .fallback_face = fallback_face,
            .allocator = allocator,
            .size_px = size_px,
            .current_size_px = size_px,
            .ascender_px = ascender_px,
            .descender_px = descender_px,
            .height_px = height_px,
            .family_c_str = family_c_str,
            .glyph_cache = std.AutoHashMap(u64, CachedGlyph).init(allocator),
        };
    }

    pub fn deinit(self: *Font) void {
        var it = self.glyph_cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.bitmap);
        }
        self.glyph_cache.deinit();

        self.allocator.free(self.family_c_str);
        if (self.fallback_face) |fbf| {
            _ = c.FT_Done_Face(fbf);
            self.fallback_face = null;
        }
        if (self.face) |face| {
            _ = c.FT_Done_Face(face);
            self.face = null;
        }
        if (self.ft_lib) |lib| {
            _ = c.FT_Done_FreeType(lib);
            self.ft_lib = null;
        }
    }

    fn findFontPath(allocator: std.mem.Allocator, family: []const u8) ![]u8 {
        if (c.FcInit() == 0) return error.FcInitFailed;
        const config = c.FcInitLoadConfigAndFonts();
        const c_family = try allocator.dupeZ(u8, family);
        defer allocator.free(c_family);

        const pat = c.FcNameParse(c_family.ptr);
        if (pat == null) return error.FcPatternFailed;
        defer c.FcPatternDestroy(pat);

        _ = c.FcConfigSubstitute(config, pat, c.FcMatchPattern);
        c.FcDefaultSubstitute(pat);

        var result: c.FcResult = undefined;
        const match = c.FcFontMatch(config, pat, &result);
        if (match == null) return error.FcFontNotFound;
        defer c.FcPatternDestroy(match);

        var file_ptr: [*c]c.FcChar8 = null;
        if (c.FcPatternGetString(match, c.FC_FILE, 0, &file_ptr) != c.FcResultMatch) {
            return error.FcPathNotFound;
        }

        const path_len = std.mem.len(file_ptr);
        const res = try allocator.alloc(u8, path_len);
        @memcpy(res, file_ptr[0..path_len]);
        return res;
    }

    pub fn getOrLoadGlyph(self: *Font, cp: u32, size_px: u32) ?CachedGlyph {
        const key = (@as(u64, size_px) << 32) | @as(u64, cp);
        if (self.glyph_cache.get(key)) |g| {
            return g;
        }

        var face = self.face;
        var glyph_index = c.FT_Get_Char_Index(face, cp);
        if (glyph_index == 0 and self.fallback_face != null) {
            const fb_index = c.FT_Get_Char_Index(self.fallback_face.?, cp);
            if (fb_index != 0) {
                face = self.fallback_face.?;
                glyph_index = fb_index;
            }
        }

        if (c.FT_Set_Pixel_Sizes(face, 0, size_px) != 0) {
            return null;
        }

        if (c.FT_Load_Glyph(face, glyph_index, c.FT_LOAD_RENDER) != 0) {
            return null;
        }

        const g = face.*.glyph;
        const bmp = &g.*.bitmap;
        const w: u32 = bmp.*.width;
        const h: u32 = bmp.*.rows;
        const pitch: i32 = bmp.*.pitch;

        var buf = self.allocator.alloc(u8, w * h) catch return null;
        errdefer self.allocator.free(buf);

        if (bmp.*.pixel_mode == c.FT_PIXEL_MODE_GRAY and bmp.*.buffer != null) {
            var row: u32 = 0;
            while (row < h) : (row += 1) {
                const src_row_offset = if (pitch >= 0)
                    @as(usize, row) * @as(usize, @intCast(pitch))
                else
                    @as(usize, (h - 1 - row)) * @as(usize, @intCast(-pitch));
                const dest_row_offset = @as(usize, row) * @as(usize, w);
                @memcpy(buf[dest_row_offset .. dest_row_offset + w], bmp.*.buffer[src_row_offset .. src_row_offset + w]);
            }
        } else if (bmp.*.pixel_mode == c.FT_PIXEL_MODE_MONO and bmp.*.buffer != null) {
            var row: u32 = 0;
            while (row < h) : (row += 1) {
                var col: u32 = 0;
                while (col < w) : (col += 1) {
                    const byte_val = bmp.*.buffer[@as(usize, row) * @as(usize, @intCast(pitch)) + (col >> 3)];
                    const bit = (byte_val >> @as(u3, @intCast(7 - (col & 7)))) & 1;
                    buf[row * w + col] = if (bit != 0) 255 else 0;
                }
            }
        } else {
            @memset(buf, 0);
        }

        const cached = CachedGlyph{
            .width = w,
            .height = h,
            .left = g.*.bitmap_left,
            .top = g.*.bitmap_top,
            .advance_x = @as(i32, @intCast(g.*.advance.x >> 6)),
            .bitmap = buf,
        };

        self.glyph_cache.put(key, cached) catch {};
        return cached;
    }

    pub fn measureText(self: *Font, text: []const u8) u32 {
        return self.measureTextWithSize(text, self.size_px);
    }

    pub fn measureTextWithSize(self: *Font, text: []const u8, size_px: u32) u32 {
        var total_advance: i32 = 0;
        var utf8_view = std.unicode.Utf8View.init(text) catch return 0;
        var it = utf8_view.iterator();
        while (it.nextCodepoint()) |cp| {
            if (self.getOrLoadGlyph(cp, size_px)) |cg| {
                total_advance += cg.advance_x;
            } else {
                // Approximate fallback advance
                total_advance += @as(i32, @intCast(size_px / 2));
            }
        }
        return if (total_advance > 0) @intCast(total_advance) else 0;
    }
};

pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Image) void {
        self.allocator.free(self.pixels);
        self.allocator.destroy(self);
    }

    pub fn destroy(self: *Image) void {
        self.deinit();
    }

    pub fn loadPng(allocator: std.mem.Allocator, path: []const u8) !?*Image {
        var path_z: [512]u8 = undefined;
        if (path.len >= path_z.len) return null;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;

        const fp = c.fopen(path_z[0..path.len :0].ptr, "rb") orelse return null;
        defer _ = c.fclose(fp);

        var header: [8]u8 = undefined;
        if (c.fread(&header, 1, 8, fp) != 8) return null;
        if (c.png_sig_cmp(&header, 0, 8) != 0) return null;

        var png_ptr_opt: ?*c.png_struct = c.png_create_read_struct(c.PNG_LIBPNG_VER_STRING, null, null, null) orelse return null;
        defer c.png_destroy_read_struct(&png_ptr_opt, null, null);
        const png_ptr = png_ptr_opt.?;

        const info_ptr = c.png_create_info_struct(png_ptr) orelse return null;

        c.png_init_io(png_ptr, fp);
        c.png_set_sig_bytes(png_ptr, 8);
        c.png_read_info(png_ptr, info_ptr);

        const width = c.png_get_image_width(png_ptr, info_ptr);
        const height = c.png_get_image_height(png_ptr, info_ptr);
        if (width == 0 or height == 0) return null;

        const color_type = c.png_get_color_type(png_ptr, info_ptr);
        const bit_depth = c.png_get_bit_depth(png_ptr, info_ptr);

        if (bit_depth == 16) {
            c.png_set_strip_16(png_ptr);
        }
        if (color_type == c.PNG_COLOR_TYPE_PALETTE) {
            c.png_set_palette_to_rgb(png_ptr);
        }
        if (color_type == c.PNG_COLOR_TYPE_GRAY and bit_depth < 8) {
            c.png_set_expand_gray_1_2_4_to_8(png_ptr);
        }
        if (c.png_get_valid(png_ptr, info_ptr, c.PNG_INFO_tRNS) != 0) {
            c.png_set_tRNS_to_alpha(png_ptr);
        }
        if (color_type == c.PNG_COLOR_TYPE_RGB or color_type == c.PNG_COLOR_TYPE_GRAY or color_type == c.PNG_COLOR_TYPE_PALETTE) {
            c.png_set_filler(png_ptr, 0xFF, c.PNG_FILLER_AFTER);
        }
        if (color_type == c.PNG_COLOR_TYPE_GRAY or color_type == c.PNG_COLOR_TYPE_GRAY_ALPHA) {
            c.png_set_gray_to_rgb(png_ptr);
        }
        // Wayland ARGB8888 in little-endian byte order is [B, G, R, A]
        c.png_set_bgr(png_ptr);

        c.png_read_update_info(png_ptr, info_ptr);

        const pixel_count = @as(usize, width) * @as(usize, height);
        const pixels = try allocator.alloc(u32, pixel_count);
        errdefer allocator.free(pixels);

        var row_pointers = try allocator.alloc([*c]c.png_byte, height);
        defer allocator.free(row_pointers);

        for (0..height) |y| {
            row_pointers[y] = @ptrCast(pixels.ptr + y * width);
        }

        c.png_read_image(png_ptr, row_pointers.ptr);

        const img = try allocator.create(Image);
        img.* = Image{
            .width = width,
            .height = height,
            .pixels = pixels,
            .allocator = allocator,
        };
        return img;
    }
};

pub const Renderer = struct {
    pixels: [*]u32,
    width: u32,
    height: u32,
    stride: u32,

    pub fn init(pixels: [*]u32, width: u32, height: u32, stride: u32) !Renderer {
        return .{
            .pixels = pixels,
            .width = width,
            .height = height,
            .stride = stride,
        };
    }

    pub fn deinit(self: *Renderer) void {
        _ = self;
    }

    inline fn div255(v: u32) u32 {
        return (v * 257 + 32896) >> 16;
    }

    inline fn blendOver(dst_pixel: u32, src: Color) u32 {
        if (src.a == 0) return dst_pixel;
        if (src.a == 255) {
            return (@as(u32, 255) << 24) |
                (@as(u32, src.r) << 16) |
                (@as(u32, src.g) << 8) |
                @as(u32, src.b);
        }

        const da: u32 = (dst_pixel >> 24) & 0xFF;
        const dr: u32 = (dst_pixel >> 16) & 0xFF;
        const dg: u32 = (dst_pixel >> 8) & 0xFF;
        const db: u32 = dst_pixel & 0xFF;

        const sa: u32 = src.a;
        const inv_sa: u32 = 255 - sa;

        const out_a = sa + div255(da * inv_sa);
        const out_r = div255(@as(u32, src.r) * sa + dr * inv_sa);
        const out_g = div255(@as(u32, src.g) * sa + dg * inv_sa);
        const out_b = div255(@as(u32, src.b) * sa + db * inv_sa);

        const a_val: u32 = @min(255, out_a);
        const r_val: u32 = @min(255, out_r);
        const g_val: u32 = @min(255, out_g);
        const b_val: u32 = @min(255, out_b);

        return (a_val << 24) |
            (r_val << 16) |
            (g_val << 8) |
            b_val;
    }

    inline fn blendOverCoverage(dst_pixel: u32, color: Color, cov: u8) u32 {
        if (cov == 0 or color.a == 0) return dst_pixel;
        if (cov == 255) return blendOver(dst_pixel, color);

        var c_adj = color;
        c_adj.a = @intCast(div255(@as(u32, color.a) * @as(u32, cov)));
        return blendOver(dst_pixel, c_adj);
    }

    inline fn setPixel(self: Renderer, x: i32, y: i32, color: Color) void {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return;
        const idx = @as(usize, @intCast(y)) * (@as(usize, self.stride) / 4) + @as(usize, @intCast(x));
        self.pixels[idx] = blendOver(self.pixels[idx], color);
    }

    inline fn setPixelCoverage(self: Renderer, x: i32, y: i32, color: Color, cov: u8) void {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height or cov == 0) return;
        const idx = @as(usize, @intCast(y)) * (@as(usize, self.stride) / 4) + @as(usize, @intCast(x));
        self.pixels[idx] = blendOverCoverage(self.pixels[idx], color, cov);
    }

    pub fn clear(self: Renderer, color: Color) void {
        const val = color.toArgb();
        const total = @as(usize, self.height) * (@as(usize, self.stride) / 4);
        @memset(self.pixels[0..total], val);
    }

    pub fn fillRect(self: Renderer, x: i32, y: i32, w: u32, h: u32, color: Color) void {
        if (color.a == 0 or w == 0 or h == 0) return;

        const x0 = @max(0, x);
        const y0 = @max(0, y);
        const x1 = @min(@as(i32, @intCast(self.width)), x + @as(i32, @intCast(w)));
        const y1 = @min(@as(i32, @intCast(self.height)), y + @as(i32, @intCast(h)));
        if (x0 >= x1 or y0 >= y1) return;

        const stride_pixels = @as(usize, self.stride) / 4;
        const val = color.toArgb();

        if (color.a == 255) {
            var cy = y0;
            while (cy < y1) : (cy += 1) {
                const row_start = @as(usize, @intCast(cy)) * stride_pixels + @as(usize, @intCast(x0));
                const span_len = @as(usize, @intCast(x1 - x0));
                @memset(self.pixels[row_start .. row_start + span_len], val);
            }
        } else {
            var cy = y0;
            while (cy < y1) : (cy += 1) {
                const row_start = @as(usize, @intCast(cy)) * stride_pixels;
                var cx = x0;
                while (cx < x1) : (cx += 1) {
                    const idx = row_start + @as(usize, @intCast(cx));
                    self.pixels[idx] = blendOver(self.pixels[idx], color);
                }
            }
        }
    }

    pub fn fillRoundedRect(self: Renderer, x: i32, y: i32, w: u32, h: u32, radius: u32, color: Color) void {
        self.fillSquircle(x, y, w, h, radius, color);
    }

    /// Continuous-curvature squircle (superellipse / iOS-style smooth corners) with antialiased borders
    pub fn fillSquircle(self: Renderer, x: i32, y: i32, w: u32, h: u32, radius: u32, color: Color) void {
        if (color.a == 0 or w == 0 or h == 0) return;
        if (radius == 0) {
            self.fillRect(x, y, w, h, color);
            return;
        }

        const max_r = @min(w / 2, h / 2);
        const r_u32 = @min(radius, max_r);
        if (r_u32 == 0) {
            self.fillRect(x, y, w, h, color);
            return;
        }

        const r = @as(f32, @floatFromInt(r_u32));
        const r_i32 = @as(i32, @intCast(r_u32));

        const x0 = @max(0, x);
        const y0 = @max(0, y);
        const x1 = @min(@as(i32, @intCast(self.width)), x + @as(i32, @intCast(w)));
        const y1 = @min(@as(i32, @intCast(self.height)), y + @as(i32, @intCast(h)));
        if (x0 >= x1 or y0 >= y1) return;

        const stride_pixels = @as(usize, self.stride) / 4;

        // Middle solid band
        const mid_top = @min(y1, @max(y0, y + r_i32));
        const mid_bot = @max(y0, @min(y1, y + @as(i32, @intCast(h)) - r_i32));
        if (mid_bot > mid_top) {
            self.fillRect(x, mid_top, w, @as(u32, @intCast(mid_bot - mid_top)), color);
        }

        // Top corner rows
        var cy = y0;
        const top_end = @min(mid_top, y1);
        while (cy < top_end) : (cy += 1) {
            const dy = @as(f32, @floatFromInt(y + r_i32)) - (@as(f32, @floatFromInt(cy)) + 0.5);
            const v = dy / r;
            const v_4 = (v * v) * (v * v);

            // Center solid segment
            const mid_left = @max(x0, x + r_i32);
            const mid_right = @min(x1, x + @as(i32, @intCast(w)) - r_i32);
            if (mid_right > mid_left) {
                const row_start = @as(usize, @intCast(cy)) * stride_pixels;
                var cx = mid_left;
                while (cx < mid_right) : (cx += 1) {
                    const idx = row_start + @as(usize, @intCast(cx));
                    self.pixels[idx] = blendOver(self.pixels[idx], color);
                }
            }

            // Top-left corner
            var cx = x0;
            const left_end = @min(mid_left, x1);
            while (cx < left_end) : (cx += 1) {
                const dx = @as(f32, @floatFromInt(x + r_i32)) - (@as(f32, @floatFromInt(cx)) + 0.5);
                const u = dx / r;
                const u_4 = (u * u) * (u * u);
                const val = u_4 + v_4;
                if (val <= 1.0) {
                    const eff_r = std.math.sqrt(std.math.sqrt(val)) * r;
                    const d = eff_r - r;
                    const cov = std.math.clamp(0.5 - d, 0.0, 1.0);
                    self.setPixelCoverage(cx, cy, color, @as(u8, @intFromFloat(cov * 255.0)));
                }
            }

            // Top-right corner
            cx = @max(mid_right, x0);
            while (cx < x1) : (cx += 1) {
                const dx = (@as(f32, @floatFromInt(cx)) + 0.5) - @as(f32, @floatFromInt(x + @as(i32, @intCast(w)) - r_i32));
                const u = dx / r;
                const u_4 = (u * u) * (u * u);
                const val = u_4 + v_4;
                if (val <= 1.0) {
                    const eff_r = std.math.sqrt(std.math.sqrt(val)) * r;
                    const d = eff_r - r;
                    const cov = std.math.clamp(0.5 - d, 0.0, 1.0);
                    self.setPixelCoverage(cx, cy, color, @as(u8, @intFromFloat(cov * 255.0)));
                }
            }
        }

        // Bottom corner rows
        cy = @max(mid_bot, y0);
        while (cy < y1) : (cy += 1) {
            const dy = (@as(f32, @floatFromInt(cy)) + 0.5) - @as(f32, @floatFromInt(y + @as(i32, @intCast(h)) - r_i32));
            const v = dy / r;
            const v_4 = (v * v) * (v * v);

            // Center solid segment
            const mid_left = @max(x0, x + r_i32);
            const mid_right = @min(x1, x + @as(i32, @intCast(w)) - r_i32);
            if (mid_right > mid_left) {
                const row_start = @as(usize, @intCast(cy)) * stride_pixels;
                var cx = mid_left;
                while (cx < mid_right) : (cx += 1) {
                    const idx = row_start + @as(usize, @intCast(cx));
                    self.pixels[idx] = blendOver(self.pixels[idx], color);
                }
            }

            // Bottom-left corner
            var cx = x0;
            const left_end = @min(mid_left, x1);
            while (cx < left_end) : (cx += 1) {
                const dx = @as(f32, @floatFromInt(x + r_i32)) - (@as(f32, @floatFromInt(cx)) + 0.5);
                const u = dx / r;
                const u_4 = (u * u) * (u * u);
                const val = u_4 + v_4;
                if (val <= 1.0) {
                    const eff_r = std.math.sqrt(std.math.sqrt(val)) * r;
                    const d = eff_r - r;
                    const cov = std.math.clamp(0.5 - d, 0.0, 1.0);
                    self.setPixelCoverage(cx, cy, color, @as(u8, @intFromFloat(cov * 255.0)));
                }
            }

            // Bottom-right corner
            cx = @max(mid_right, x0);
            while (cx < x1) : (cx += 1) {
                const dx = (@as(f32, @floatFromInt(cx)) + 0.5) - @as(f32, @floatFromInt(x + @as(i32, @intCast(w)) - r_i32));
                const u = dx / r;
                const u_4 = (u * u) * (u * u);
                const val = u_4 + v_4;
                if (val <= 1.0) {
                    const eff_r = std.math.sqrt(std.math.sqrt(val)) * r;
                    const d = eff_r - r;
                    const cov = std.math.clamp(0.5 - d, 0.0, 1.0);
                    self.setPixelCoverage(cx, cy, color, @as(u8, @intFromFloat(cov * 255.0)));
                }
            }
        }
    }

    /// Shadow disabled for minimal flat aesthetic
    pub fn drawSoftShadow(self: Renderer, x: i32, y: i32, w: u32, h: u32, radius: u32, blur: u32, max_alpha: u8) void {
        _ = self;
        _ = x;
        _ = y;
        _ = w;
        _ = h;
        _ = radius;
        _ = blur;
        _ = max_alpha;
    }

    /// Clean minimal squircle
    pub fn fillGlassSquircle(self: Renderer, x: i32, y: i32, w: u32, h: u32, radius: u32, base_color: Color) void {
        self.fillSquircle(x, y, w, h, radius, base_color);
    }

    pub fn drawRoundedBorder(self: Renderer, x: i32, y: i32, w: u32, h: u32, radius: u32, border_w: u32, color: Color) void {
        self.drawSquircleBorder(x, y, w, h, radius, border_w, color);
    }

    pub fn drawSquircleBorder(self: Renderer, x: i32, y: i32, w: u32, h: u32, radius: u32, border_w: u32, color: Color) void {
        if (color.a == 0 or w == 0 or h == 0 or border_w == 0) return;

        const max_r = @min(w / 2, h / 2);
        const r_u32 = @min(radius, max_r);
        const r = @as(f32, @floatFromInt(r_u32));
        const bw = @as(f32, @floatFromInt(border_w));
        const r_inner = @max(0.0, r - bw);

        const x0 = @max(0, x);
        const y0 = @max(0, y);
        const x1 = @min(@as(i32, @intCast(self.width)), x + @as(i32, @intCast(w)));
        const y1 = @min(@as(i32, @intCast(self.height)), y + @as(i32, @intCast(h)));
        if (x0 >= x1 or y0 >= y1) return;

        const r_i32 = @as(i32, @intCast(r_u32));
        const bw_i32 = @as(i32, @intCast(border_w));

        // Top straight edge
        self.fillRect(x + r_i32, y, if (w > r_u32 * 2) w - r_u32 * 2 else 0, border_w, color);
        // Bottom straight edge
        self.fillRect(x + r_i32, y + @as(i32, @intCast(h)) - bw_i32, if (w > r_u32 * 2) w - r_u32 * 2 else 0, border_w, color);
        // Left straight edge
        self.fillRect(x, y + r_i32, border_w, if (h > r_u32 * 2) h - r_u32 * 2 else 0, color);
        // Right straight edge
        self.fillRect(x + @as(i32, @intCast(w)) - bw_i32, y + r_i32, border_w, if (h > r_u32 * 2) h - r_u32 * 2 else 0, color);

        if (r_u32 == 0) return;

        // Corner boundaries
        // Top-left
        var cy = y;
        while (cy < y + r_i32) : (cy += 1) {
            const dy = @as(f32, @floatFromInt(y + r_i32)) - (@as(f32, @floatFromInt(cy)) + 0.5);
            const v = dy / r;
            const v_4 = (v * v) * (v * v);

            var cx = x;
            while (cx < x + r_i32) : (cx += 1) {
                const dx = @as(f32, @floatFromInt(x + r_i32)) - (@as(f32, @floatFromInt(cx)) + 0.5);
                const u = dx / r;
                const u_4 = (u * u) * (u * u);
                const val = u_4 + v_4;
                if (val <= 1.05) {
                    const eff_r = std.math.sqrt(std.math.sqrt(val)) * r;
                    const d_out = eff_r - r;
                    const d_in = r_inner - eff_r;
                    const cov_out = std.math.clamp(0.5 - d_out, 0.0, 1.0);
                    const cov_in = if (r_inner > 0) std.math.clamp(0.5 - d_in, 0.0, 1.0) else 1.0;
                    const cov = cov_out * (1.0 - (1.0 - cov_in));
                    self.setPixelCoverage(cx, cy, color, @as(u8, @intFromFloat(cov * 255.0)));
                }
            }
        }

        // Top-right
        cy = y;
        while (cy < y + r_i32) : (cy += 1) {
            const dy = @as(f32, @floatFromInt(y + r_i32)) - (@as(f32, @floatFromInt(cy)) + 0.5);
            const v = dy / r;
            const v_4 = (v * v) * (v * v);

            var cx = x + @as(i32, @intCast(w)) - r_i32;
            while (cx < x + @as(i32, @intCast(w))) : (cx += 1) {
                const dx = (@as(f32, @floatFromInt(cx)) + 0.5) - @as(f32, @floatFromInt(x + @as(i32, @intCast(w)) - r_i32));
                const u = dx / r;
                const u_4 = (u * u) * (u * u);
                const val = u_4 + v_4;
                if (val <= 1.05) {
                    const eff_r = std.math.sqrt(std.math.sqrt(val)) * r;
                    const d_out = eff_r - r;
                    const d_in = r_inner - eff_r;
                    const cov_out = std.math.clamp(0.5 - d_out, 0.0, 1.0);
                    const cov_in = if (r_inner > 0) std.math.clamp(0.5 - d_in, 0.0, 1.0) else 1.0;
                    const cov = cov_out * (1.0 - (1.0 - cov_in));
                    self.setPixelCoverage(cx, cy, color, @as(u8, @intFromFloat(cov * 255.0)));
                }
            }
        }

        // Bottom-left
        cy = y + @as(i32, @intCast(h)) - r_i32;
        while (cy < y + @as(i32, @intCast(h))) : (cy += 1) {
            const dy = (@as(f32, @floatFromInt(cy)) + 0.5) - @as(f32, @floatFromInt(y + @as(i32, @intCast(h)) - r_i32));
            const v = dy / r;
            const v_4 = (v * v) * (v * v);

            var cx = x;
            while (cx < x + r_i32) : (cx += 1) {
                const dx = @as(f32, @floatFromInt(x + r_i32)) - (@as(f32, @floatFromInt(cx)) + 0.5);
                const u = dx / r;
                const u_4 = (u * u) * (u * u);
                const val = u_4 + v_4;
                if (val <= 1.05) {
                    const eff_r = std.math.sqrt(std.math.sqrt(val)) * r;
                    const d_out = eff_r - r;
                    const d_in = r_inner - eff_r;
                    const cov_out = std.math.clamp(0.5 - d_out, 0.0, 1.0);
                    const cov_in = if (r_inner > 0) std.math.clamp(0.5 - d_in, 0.0, 1.0) else 1.0;
                    const cov = cov_out * (1.0 - (1.0 - cov_in));
                    self.setPixelCoverage(cx, cy, color, @as(u8, @intFromFloat(cov * 255.0)));
                }
            }
        }

        // Bottom-right
        cy = y + @as(i32, @intCast(h)) - r_i32;
        while (cy < y + @as(i32, @intCast(h))) : (cy += 1) {
            const dy = (@as(f32, @floatFromInt(cy)) + 0.5) - @as(f32, @floatFromInt(y + @as(i32, @intCast(h)) - r_i32));
            const v = dy / r;
            const v_4 = (v * v) * (v * v);

            var cx = x + @as(i32, @intCast(w)) - r_i32;
            while (cx < x + @as(i32, @intCast(w))) : (cx += 1) {
                const dx = (@as(f32, @floatFromInt(cx)) + 0.5) - @as(f32, @floatFromInt(x + @as(i32, @intCast(w)) - r_i32));
                const u = dx / r;
                const u_4 = (u * u) * (u * u);
                const val = u_4 + v_4;
                if (val <= 1.05) {
                    const eff_r = std.math.sqrt(std.math.sqrt(val)) * r;
                    const d_out = eff_r - r;
                    const d_in = r_inner - eff_r;
                    const cov_out = std.math.clamp(0.5 - d_out, 0.0, 1.0);
                    const cov_in = if (r_inner > 0) std.math.clamp(0.5 - d_in, 0.0, 1.0) else 1.0;
                    const cov = cov_out * (1.0 - (1.0 - cov_in));
                    self.setPixelCoverage(cx, cy, color, @as(u8, @intFromFloat(cov * 255.0)));
                }
            }
        }
    }

    pub fn fillCircle(self: Renderer, cx: f64, cy: f64, radius: f64, color: Color) void {
        if (color.a == 0 or radius <= 0) return;

        const r = @as(f32, @floatCast(radius));
        const cx_f = @as(f32, @floatCast(cx));
        const cy_f = @as(f32, @floatCast(cy));

        const min_x = @max(0, @as(i32, @intFromFloat(cx_f - r - 1.0)));
        const max_x = @min(@as(i32, @intCast(self.width)), @as(i32, @intFromFloat(cx_f + r + 2.0)));
        const min_y = @max(0, @as(i32, @intFromFloat(cy_f - r - 1.0)));
        const max_y = @min(@as(i32, @intCast(self.height)), @as(i32, @intFromFloat(cy_f + r + 2.0)));

        var py = min_y;
        while (py < max_y) : (py += 1) {
            const dy = (@as(f32, @floatFromInt(py)) + 0.5) - cy_f;
            const dy_sq = dy * dy;
            if (dy_sq > (r + 1.0) * (r + 1.0)) continue;

            var px = min_x;
            while (px < max_x) : (px += 1) {
                const dx = (@as(f32, @floatFromInt(px)) + 0.5) - cx_f;
                const d_sq = dx * dx + dy_sq;
                if (d_sq <= (r - 0.5) * (r - 0.5)) {
                    self.setPixel(px, py, color);
                } else if (d_sq <= (r + 0.5) * (r + 0.5)) {
                    const dist = @sqrt(d_sq);
                    const cov = std.math.clamp(0.5 - (dist - r), 0.0, 1.0);
                    self.setPixelCoverage(px, py, color, @as(u8, @intFromFloat(cov * 255.0)));
                }
            }
        }
    }

    pub fn drawText(self: Renderer, font: *Font, text: []const u8, x: i32, baseline_y: i32, color: Color) void {
        self.drawTextWithSize(font, text, x, baseline_y, font.size_px, color);
    }

    pub fn drawTextWithSize(self: Renderer, font: *Font, text: []const u8, x: i32, baseline_y: i32, size_px: u32, color: Color) void {
        if (text.len == 0 or color.a == 0) return;

        var pen_x: i32 = x;
        var utf8_view = std.unicode.Utf8View.init(text) catch return;
        var it = utf8_view.iterator();

        while (it.nextCodepoint()) |cp| {
            if (font.getOrLoadGlyph(cp, size_px)) |cg| {
                const glyph_x = pen_x + cg.left;
                const glyph_y = baseline_y - cg.top;

                var r: u32 = 0;
                while (r < cg.height) : (r += 1) {
                    const py = glyph_y + @as(i32, @intCast(r));
                    if (py < 0 or py >= self.height) continue;

                    var c_col: u32 = 0;
                    while (c_col < cg.width) : (c_col += 1) {
                        const px = glyph_x + @as(i32, @intCast(c_col));
                        if (px < 0 or px >= self.width) continue;

                        const alpha_mask = cg.bitmap[r * cg.width + c_col];
                        if (alpha_mask > 0) {
                            self.setPixelCoverage(px, py, color, alpha_mask);
                        }
                    }
                }

                pen_x += cg.advance_x;
            } else {
                pen_x += @as(i32, @intCast(size_px / 2));
            }
        }
    }

    pub fn drawTextRotated(self: Renderer, font: *Font, text: []const u8, center_x: i32, center_y: i32, angle: f32, size_px: u32, color: Color) void {
        if (text.len == 0 or color.a == 0) return;

        var utf8_view = std.unicode.Utf8View.init(text) catch return;
        var it = utf8_view.iterator();
        const cp = it.nextCodepoint() orelse return;
        const cg = font.getOrLoadGlyph(cp, size_px) orelse return;

        const cos_a = @cos(angle);
        const sin_a = @sin(angle);
        const cx_box = @as(f32, @floatFromInt(cg.width)) / 2.0;
        const cy_box = @as(f32, @floatFromInt(cg.height)) / 2.0;

        var r: u32 = 0;
        while (r < cg.height) : (r += 1) {
            const dy = (@as(f32, @floatFromInt(r)) + 0.5) - cy_box;
            var c_col: u32 = 0;
            while (c_col < cg.width) : (c_col += 1) {
                const alpha_mask = cg.bitmap[r * cg.width + c_col];
                if (alpha_mask == 0) continue;

                const dx = (@as(f32, @floatFromInt(c_col)) + 0.5) - cx_box;
                const rx = cos_a * dx - sin_a * dy;
                const ry = sin_a * dx + cos_a * dy;

                const px = center_x + @as(i32, @intFromFloat(rx));
                const py = center_y + @as(i32, @intFromFloat(ry));

                if (px >= 0 and px < self.width and py >= 0 and py < self.height) {
                    self.setPixelCoverage(px, py, color, alpha_mask);
                }
            }
        }
    }

    pub fn measureText(self: Renderer, font: *Font, text: []const u8) u32 {
        _ = self;
        return font.measureText(text);
    }

    pub fn measureTextWithSize(self: Renderer, font: *Font, text: []const u8, size_px: u32) u32 {
        _ = self;
        return font.measureTextWithSize(text, size_px);
    }

    pub fn drawImage(
        self: Renderer,
        img: *const Image,
        dest_x: f64,
        dest_y: f64,
        dest_w: f64,
        dest_h: f64,
    ) void {
        if (dest_w <= 0.0 or dest_h <= 0.0 or img.width == 0 or img.height == 0) return;

        const x0 = @max(0, @as(i32, @intFromFloat(dest_x)));
        const y0 = @max(0, @as(i32, @intFromFloat(dest_y)));
        const x1 = @min(@as(i32, @intCast(self.width)), @as(i32, @intFromFloat(dest_x + dest_w)));
        const y1 = @min(@as(i32, @intCast(self.height)), @as(i32, @intFromFloat(dest_y + dest_h)));
        if (x0 >= x1 or y0 >= y1) return;

        const scale_x = @as(f64, @floatFromInt(img.width)) / dest_w;
        const scale_y = @as(f64, @floatFromInt(img.height)) / dest_h;

        const stride_pixels = @as(usize, self.stride) / 4;

        var dy = y0;
        while (dy < y1) : (dy += 1) {
            const src_y_f = (@as(f64, @floatFromInt(dy)) - dest_y) * scale_y;
            const src_y = @min(img.height - 1, @as(u32, @intFromFloat(@max(0.0, src_y_f))));
            const src_row_offset = @as(usize, src_y) * @as(usize, img.width);
            const dst_row_offset = @as(usize, @intCast(dy)) * stride_pixels;

            var dx = x0;
            while (dx < x1) : (dx += 1) {
                const src_x_f = (@as(f64, @floatFromInt(dx)) - dest_x) * scale_x;
                const src_x = @min(img.width - 1, @as(u32, @intFromFloat(@max(0.0, src_x_f))));

                const src_pixel = img.pixels[src_row_offset + src_x];
                const sa = @as(u8, @truncate((src_pixel >> 24) & 0xFF));
                if (sa == 0) continue;

                const sr = @as(u8, @truncate((src_pixel >> 16) & 0xFF));
                const sg = @as(u8, @truncate((src_pixel >> 8) & 0xFF));
                const sb = @as(u8, @truncate(src_pixel & 0xFF));

                const dst_idx = dst_row_offset + @as(usize, @intCast(dx));
                self.pixels[dst_idx] = blendOver(self.pixels[dst_idx], Color.init(sa, sr, sg, sb));
            }
        }
    }

    pub fn drawImageSurface(
        self: Renderer,
        img_surf: *const Image,
        dest_x: f64,
        dest_y: f64,
        dest_w: f64,
        dest_h: f64,
    ) void {
        self.drawImage(img_surf, dest_x, dest_y, dest_w, dest_h);
    }

    pub fn drawSvgIcon(
        self: Renderer,
        d: []const u8,
        x: i32,
        y: i32,
        size: u32,
        color: Color,
        is_stroke: bool,
        stroke_w: f64,
    ) void {
        _ = d;
        _ = stroke_w;
        _ = is_stroke;
        // Fallback smooth circular badge
        const r = @as(f64, @floatFromInt(size)) / 2.0;
        self.fillCircle(@as(f64, @floatFromInt(x)) + r, @as(f64, @floatFromInt(y)) + r, r, color);
    }
};
