const std = @import("std");
const c = @import("c");
const theme = @import("theme.zig");
const Color = theme.Color;

pub const InkExtents = struct {
    left: i32,
    width: u32,
};

pub const CachedGlyph = struct {
    width: u32,
    height: u32,
    left: i32,
    top: i32,
    advance_x: i32,
    bitmap: []u8,
};

pub const FallbackFace = struct {
    face: c.FT_Face,
    path: []const u8,
};

pub const Font = struct {
    ft_lib: c.FT_Library = null,
    face: c.FT_Face = null,
    fallback_face: ?c.FT_Face = null,
    fallback_faces: std.ArrayList(FallbackFace) = std.ArrayList(FallbackFace).empty,
    primary_font_path: []const u8 = "",
    missing_glyphs: std.AutoHashMap(u32, void),
    allocator: std.mem.Allocator,
    size_px: u32,
    primary_size_px: u32,
    fallback_size_px: u32,
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
        var expanded_family: ?[]u8 = null;
        defer if (expanded_family) |ef| allocator.free(ef);

        var query_family = font_family;
        if (std.mem.indexOf(u8, font_family, "Maple Mono") != null and std.mem.indexOf(u8, font_family, "NF") == null) {
            expanded_family = std.fmt.allocPrint(allocator, "Maple Mono NF, {s}", .{font_family}) catch null;
            if (expanded_family) |ef| query_family = ef;
        }

        const font_path = try findFontPath(allocator, query_family);
        defer allocator.free(font_path);

        var face: c.FT_Face = null;
        const c_path = try allocator.dupeSentinel(u8, font_path, 0);
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

        const primary_path_copy = try allocator.dupe(u8, font_path);
        errdefer allocator.free(primary_path_copy);

        // Preload common fallback faces for symbols / Nerd Fonts
        var fallback_faces = std.ArrayList(FallbackFace).empty;
        errdefer {
            for (fallback_faces.items) |fb| {
                _ = c.FT_Done_Face(fb.face);
                allocator.free(fb.path);
            }
            fallback_faces.deinit(allocator);
        }

        const fb_candidates = [_][]const u8{
            "SymbolsNF, Symbols Nerd Font, monospace",
            "JetBrainsMono Nerd Font, monospace",
            "DejaVu Sans, monospace",
        };
        for (fb_candidates) |candidate| {
            if (findFontPath(allocator, candidate)) |fb_path| {
                defer allocator.free(fb_path);
                if (!std.mem.eql(u8, fb_path, primary_path_copy)) {
                    var already_loaded = false;
                    for (fallback_faces.items) |existing| {
                        if (std.mem.eql(u8, existing.path, fb_path)) {
                            already_loaded = true;
                            break;
                        }
                    }
                    if (!already_loaded) {
                        const fb_c_path = allocator.dupeSentinel(u8, fb_path, 0) catch null;
                        if (fb_c_path) |fcp| {
                            defer allocator.free(fcp);
                            var fb_f: c.FT_Face = null;
                            if (c.FT_New_Face(ft_lib, fcp.ptr, 0, &fb_f) == 0) {
                                _ = c.FT_Set_Pixel_Sizes(fb_f, 0, size_px);
                                const saved_path = allocator.dupe(u8, fb_path) catch null;
                                if (saved_path) |sp| {
                                    fallback_faces.append(allocator, .{ .face = fb_f, .path = sp }) catch {
                                        allocator.free(sp);
                                        _ = c.FT_Done_Face(fb_f);
                                    };
                                } else {
                                    _ = c.FT_Done_Face(fb_f);
                                }
                            }
                        }
                    }
                }
            } else |_| {}
        }

        const fallback_face = if (fallback_faces.items.len > 0) fallback_faces.items[0].face else null;
        const family_c_str = try allocator.dupeSentinel(u8, theme.firstFamily(font_family), 0);

        return .{
            .ft_lib = ft_lib,
            .face = face,
            .fallback_face = fallback_face,
            .fallback_faces = fallback_faces,
            .primary_font_path = primary_path_copy,
            .missing_glyphs = std.AutoHashMap(u32, void).init(allocator),
            .allocator = allocator,
            .size_px = size_px,
            .primary_size_px = size_px,
            .fallback_size_px = size_px,
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

        for (self.fallback_faces.items) |fb| {
            _ = c.FT_Done_Face(fb.face);
            self.allocator.free(fb.path);
        }
        self.fallback_faces.deinit(self.allocator);
        self.fallback_face = null;

        if (self.primary_font_path.len > 0) {
            self.allocator.free(self.primary_font_path);
            self.primary_font_path = "";
        }

        self.missing_glyphs.deinit();

        self.allocator.free(self.family_c_str);
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
        const config = c.FcConfigGetCurrent() orelse c.FcInitLoadConfigAndFonts();
        const c_family = try allocator.dupeSentinel(u8, family, 0);
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

    fn loadFallbackForCodepoint(self: *Font, cp: u32, size_px: u32) ?struct { face: c.FT_Face, glyph_index: c.FT_UInt } {
        if (c.FcInit() == 0) return null;
        const config = c.FcConfigGetCurrent() orelse c.FcInitLoadConfigAndFonts();
        const pat = c.FcPatternCreate() orelse return null;
        defer c.FcPatternDestroy(pat);

        const cs = c.FcCharSetCreate() orelse return null;
        defer c.FcCharSetDestroy(cs);
        _ = c.FcCharSetAddChar(cs, cp);
        _ = c.FcPatternAddCharSet(pat, c.FC_CHARSET, cs);

        _ = c.FcConfigSubstitute(config, pat, c.FcMatchPattern);
        c.FcDefaultSubstitute(pat);

        var result: c.FcResult = undefined;
        const match = c.FcFontMatch(config, pat, &result);
        if (match == null) return null;
        defer c.FcPatternDestroy(match);

        var file_ptr: [*c]c.FcChar8 = null;
        if (c.FcPatternGetString(match, c.FC_FILE, 0, &file_ptr) != c.FcResultMatch or file_ptr == null) {
            return null;
        }

        const path_len = std.mem.len(file_ptr);
        const font_path = file_ptr[0..path_len];

        if (std.mem.eql(u8, self.primary_font_path, font_path)) {
            return null;
        }

        for (self.fallback_faces.items) |fb| {
            if (std.mem.eql(u8, fb.path, font_path)) {
                const idx = c.FT_Get_Char_Index(fb.face, cp);
                if (idx != 0) {
                    return .{ .face = fb.face, .glyph_index = idx };
                }
                return null;
            }
        }

        const c_path = self.allocator.dupeSentinel(u8, font_path, 0) catch return null;
        defer self.allocator.free(c_path);

        var new_face: c.FT_Face = null;
        if (c.FT_New_Face(self.ft_lib, c_path.ptr, 0, &new_face) != 0) {
            return null;
        }

        _ = c.FT_Set_Pixel_Sizes(new_face, 0, size_px);

        const saved_path = self.allocator.dupe(u8, font_path) catch {
            _ = c.FT_Done_Face(new_face);
            return null;
        };

        self.fallback_faces.append(self.allocator, .{ .face = new_face, .path = saved_path }) catch {
            self.allocator.free(saved_path);
            _ = c.FT_Done_Face(new_face);
            return null;
        };

        const g_idx = c.FT_Get_Char_Index(new_face, cp);
        if (g_idx != 0) {
            return .{ .face = new_face, .glyph_index = g_idx };
        }
        return null;
    }

    pub fn getOrLoadGlyph(self: *Font, cp: u32, size_px: u32) ?CachedGlyph {
        const key = (@as(u64, size_px) << 32) | @as(u64, cp);
        if (self.glyph_cache.get(key)) |g| {
            return g;
        }

        var face = self.face;
        var glyph_index = c.FT_Get_Char_Index(face, cp);

        if (glyph_index == 0) {
            for (self.fallback_faces.items) |fb| {
                const fb_index = c.FT_Get_Char_Index(fb.face, cp);
                if (fb_index != 0) {
                    face = fb.face;
                    glyph_index = fb_index;
                    break;
                }
            }

            if (glyph_index == 0 and !self.missing_glyphs.contains(cp)) {
                if (self.loadFallbackForCodepoint(cp, size_px)) |matched| {
                    face = matched.face;
                    glyph_index = matched.glyph_index;
                } else {
                    self.missing_glyphs.put(cp, {}) catch {};
                }
            }
        }

        if (glyph_index == 0) {
            return null;
        }

        if (face.*.size == null or @as(u32, face.*.size.*.metrics.y_ppem) != size_px) {
            if (c.FT_Set_Pixel_Sizes(face, 0, size_px) != 0) {
                return null;
            }
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

        self.glyph_cache.put(key, cached) catch {
            self.allocator.free(buf);
            return null;
        };
        return cached;
    }

    pub fn measureText(self: *Font, text: []const u8) u32 {
        return self.measureTextWithSize(text, self.size_px);
    }

    /// Approximate ascender for a given pixel size using face metrics.
    pub fn ascentForSize(self: *const Font, size_px: u32) i32 {
        if (self.size_px == 0) return 0;
        return @divTrunc(self.ascender_px * @as(i32, @intCast(size_px)), @as(i32, @intCast(self.size_px)));
    }

    pub fn descentForSize(self: *const Font, size_px: u32) i32 {
        if (self.size_px == 0) return 0;
        return @divTrunc(self.descender_px * @as(i32, @intCast(size_px)), @as(i32, @intCast(self.size_px)));
    }

    pub fn heightForSize(self: *const Font, size_px: u32) i32 {
        if (self.size_px == 0) return 0;
        return @divTrunc(self.height_px * @as(i32, @intCast(size_px)), @as(i32, @intCast(self.size_px)));
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

    /// Visual ink bounds of rendered glyphs relative to text origin.
    pub fn measureInk(self: *Font, text: []const u8, size_px: u32) InkExtents {
        var pen_x: i32 = 0;
        var min_left: i32 = std.math.maxInt(i32);
        var max_right: i32 = std.math.minInt(i32);
        var found = false;

        var utf8_view = std.unicode.Utf8View.init(text) catch return .{ .left = 0, .width = 0 };
        var it = utf8_view.iterator();
        while (it.nextCodepoint()) |cp| {
            if (self.getOrLoadGlyph(cp, size_px)) |cg| {
                if (cg.width > 0) {
                    const left = pen_x + cg.left;
                    const right = left + @as(i32, @intCast(cg.width));
                    min_left = @min(min_left, left);
                    max_right = @max(max_right, right);
                    found = true;
                }
                pen_x += cg.advance_x;
            } else {
                pen_x += @as(i32, @intCast(size_px / 2));
            }
        }

        if (!found) return .{ .left = 0, .width = 0 };
        return .{ .left = min_left, .width = @intCast(@max(0, max_right - min_left)) };
    }
};

/// Truncate text to fit max_w with an ellipsis.
pub fn truncateText(font: *Font, text: []const u8, max_w: u32, size_px: u32, buf: []u8) []const u8 {
    if (text.len == 0) return text;
    const ellipsis = "...";
    const ell_w = font.measureTextWithSize(ellipsis, size_px);
    if (ell_w >= max_w) return "";

    var view = std.unicode.Utf8View.init(text) catch return text;
    var it = view.iterator();
    var total_w: u64 = 0;
    var fit_len: usize = 0;
    var offset: usize = 0;
    var overflowed = false;

    while (it.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch return text;
        const advance: u32 = if (font.getOrLoadGlyph(cp, size_px)) |cg|
            @intCast(@max(0, cg.advance_x))
        else
            size_px / 2;
        total_w += advance;
        offset += slice.len;
        if (total_w + ell_w <= max_w) fit_len = offset;
        if (total_w > max_w) {
            overflowed = true;
            break;
        }
    }

    if (!overflowed) return text;
    if (fit_len == 0) return "";

    if (buf.len <= ellipsis.len) return "";
    const max_prefix = buf.len - ellipsis.len;
    if (fit_len > max_prefix) {
        fit_len = max_prefix;
        while (fit_len > 0 and (text[fit_len] & 0xC0) == 0x80) fit_len -= 1;
    }
    if (fit_len == 0) return "";
    @memcpy(buf[0..fit_len], text[0..fit_len]);
    @memcpy(buf[fit_len .. fit_len + ellipsis.len], ellipsis);
    return buf[0 .. fit_len + ellipsis.len];
}

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

    pub fn loadPngFromFp(allocator: std.mem.Allocator, fp: *c.FILE) !?*Image {
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

    pub fn loadPng(allocator: std.mem.Allocator, path: []const u8) !?*Image {
        var path_z: [512]u8 = undefined;
        if (path.len >= path_z.len) return null;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;

        const fp = c.fopen(path_z[0..path.len :0].ptr, "rb") orelse return null;
        defer _ = c.fclose(fp);

        return loadPngFromFp(allocator, fp);
    }

    pub fn loadJpegFromFp(allocator: std.mem.Allocator, fp: *c.FILE) !?*Image {
        var magic: [2]u8 = undefined;
        if (c.fread(&magic, 1, 2, fp) != 2) return null;
        if (magic[0] != 0xFF or magic[1] != 0xD8) return null;
        _ = c.fseek(fp, 0, c.SEEK_SET);

        var cinfo: c.struct_jpeg_decompress_struct = undefined;
        var jerr: c.struct_jpeg_error_mgr = undefined;
        cinfo.err = c.jpeg_std_error(&jerr);
        c.jpeg_create_decompress(&cinfo);
        defer c.jpeg_destroy_decompress(&cinfo);

        c.jpeg_stdio_src(&cinfo, fp);
        if (c.jpeg_read_header(&cinfo, 1) != c.JPEG_HEADER_OK) return null;
        cinfo.out_color_space = c.JCS_RGB;
        _ = c.jpeg_start_decompress(&cinfo);

        const width: u32 = cinfo.output_width;
        const height: u32 = cinfo.output_height;
        if (width == 0 or height == 0) return null;

        const pixel_count = @as(usize, width) * @as(usize, height);
        const pixels = try allocator.alloc(u32, pixel_count);
        errdefer allocator.free(pixels);

        const row_stride = @as(usize, cinfo.output_width) * @as(usize, @intCast(cinfo.output_components));
        const row_buffer = try allocator.alloc(u8, row_stride);
        defer allocator.free(row_buffer);

        var row_ptrs = [_][*c]u8{row_buffer.ptr};

        var cur_y: u32 = 0;
        while (cinfo.output_scanline < cinfo.output_height) {
            _ = c.jpeg_read_scanlines(&cinfo, &row_ptrs, 1);
            const dst_offset = @as(usize, cur_y) * @as(usize, width);
            var x: usize = 0;
            while (x < width) : (x += 1) {
                const r: u32 = row_buffer[x * 3 + 0];
                const g: u32 = row_buffer[x * 3 + 1];
                const b: u32 = row_buffer[x * 3 + 2];
                pixels[dst_offset + x] = (0xFF << 24) | (r << 16) | (g << 8) | b;
            }
            cur_y += 1;
        }
        _ = c.jpeg_finish_decompress(&cinfo);

        const img = try allocator.create(Image);
        img.* = Image{
            .width = width,
            .height = height,
            .pixels = pixels,
            .allocator = allocator,
        };
        return img;
    }

    pub fn loadJpeg(allocator: std.mem.Allocator, path: []const u8) !?*Image {
        var path_z: [512]u8 = undefined;
        if (path.len >= path_z.len) return null;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;

        const fp = c.fopen(path_z[0..path.len :0].ptr, "rb") orelse return null;
        defer _ = c.fclose(fp);

        return loadJpegFromFp(allocator, fp);
    }

    pub fn loadMemory(allocator: std.mem.Allocator, data: []const u8) !?*Image {
        if (data.len >= 8 and std.mem.startsWith(u8, data, "\x89PNG\r\n\x1a\n")) {
            return loadPngFromMemory(allocator, data);
        }
        if (data.len >= 2 and data[0] == 0xFF and data[1] == 0xD8) {
            return loadJpegFromMemory(allocator, data);
        }
        return null;
    }

    pub fn loadFile(allocator: std.mem.Allocator, path: []const u8) !?*Image {
        if (std.mem.endsWith(u8, path, ".png")) {
            return loadPng(allocator, path);
        } else if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) {
            return loadJpeg(allocator, path);
        }

        var path_z: [512]u8 = undefined;
        if (path.len >= path_z.len) return null;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;

        const fp = c.fopen(path_z[0..path.len :0].ptr, "rb") orelse return null;
        defer _ = c.fclose(fp);

        var header: [8]u8 = undefined;
        const rd = c.fread(&header, 1, 8, fp);
        _ = c.fseek(fp, 0, c.SEEK_SET);
        if (rd >= 8 and std.mem.startsWith(u8, &header, "\x89PNG\r\n\x1a\n")) {
            return loadPngFromFp(allocator, fp);
        }
        if (rd >= 2 and header[0] == 0xFF and header[1] == 0xD8) {
            return loadJpegFromFp(allocator, fp);
        }
        return null;
    }

    // Custom error handler for libpng to avoid aborting on errors
    fn pngErrorHandler(png_ptr: ?*c.png_struct, _: [*c]const u8) callconv(.c) noreturn {
        const jmp_buf = c.png_get_error_ptr(png_ptr.?) orelse unreachable;
        c.longjmp(@ptrCast(@alignCast(jmp_buf)), 1);
    }

    // Warning handler to suppress "IDAT: Extra compressed data" warning
    fn pngWarningHandler(png_ptr: ?*c.png_struct, msg: [*c]const u8) callconv(.C) void {
        _ = png_ptr;
        const msg_str = std.mem.span(msg);
        // Suppress "IDAT: Extra compressed data" warning
        if (std.mem.indexOf(u8, msg_str, "Extra compressed data") != null) {
            return;
        }
    }

    pub fn loadPngFromMemory(allocator: std.mem.Allocator, data: []const u8) !?*Image {
        if (data.len < 8) return null;
        if (c.png_sig_cmp(data.ptr, 0, 8) != 0) return null;

        var png_ptr_opt: ?*c.png_struct = c.png_create_read_struct(c.PNG_LIBPNG_VER_STRING, null, null, null) orelse return null;
        defer c.png_destroy_read_struct(&png_ptr_opt, null, null);
        const png_ptr = png_ptr_opt.?;

        // Set custom error handler to avoid aborting
        const error_ptr = try allocator.create(c.png_voidp);
        var jmp_buf: c.jmp_buf = undefined;
        error_ptr.* = @ptrCast(&jmp_buf);
        c.png_set_error_fn(png_ptr, error_ptr.*, pngErrorHandler, null);

        // Use setjmp to catch libpng errors
        const err = c.setjmp(&jmp_buf);
        if (err != 0) {
            c.png_destroy_read_struct(&png_ptr_opt, null, null);
            allocator.destroy(error_ptr);
            return null;
        }

        const info_ptr = c.png_create_info_struct(png_ptr) orelse {
            c.png_destroy_read_struct(&png_ptr_opt, null, null);
            allocator.destroy(error_ptr);
            return null;
        };

        // Use custom read function to read from memory
        const read_fn = struct {
            fn read(png_ptr_: ?*c.png_struct, data_: [*c]u8, length: c.png_size_t) callconv(.c) void {
                const io_ptr = c.png_get_io_ptr(png_ptr_.?);
                const ctx = @as(*ReadContext, @ptrCast(@alignCast(io_ptr)));
                if (ctx.offset + length > ctx.data.len) {
                    // Return error by longjmping
                    c.png_error(png_ptr_.?, "Read error");
                    return;
                }
                // Use pointer arithmetic since data_ is a raw pointer
                var i: c.png_size_t = 0;
                while (i < length) : (i += 1) {
                    data_[i] = ctx.data[ctx.offset + i];
                }
                ctx.offset += length;
            }
        }.read;

        var ctx = ReadContext{ .data = data, .offset = 0 };
        c.png_set_read_fn(png_ptr, @ptrCast(@constCast(&ctx)), read_fn);

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
        c.png_set_bgr(png_ptr);

        c.png_read_update_info(png_ptr, info_ptr);

        const pixel_count = @as(usize, width) * @as(usize, height);
        const pixels = try allocator.alloc(u32, pixel_count);
        errdefer allocator.free(pixels);

        // Allocate row_pointers before potential error point
        var row_pointers = try allocator.alloc([*c]c.png_byte, height);
        errdefer allocator.free(row_pointers);

        for (0..height) |y| {
            row_pointers[y] = @ptrCast(pixels.ptr + y * width);
        }

        // Use setjmp to catch errors during png_read_image
        const err2 = c.setjmp(&jmp_buf);
        if (err2 != 0) {
            c.png_destroy_read_struct(&png_ptr_opt, @ptrCast(@constCast(&info_ptr)), null);
            allocator.destroy(error_ptr);
            allocator.free(row_pointers);
            allocator.free(pixels);
            return null;
        }

        c.png_read_image(png_ptr, row_pointers.ptr);

        const img = try allocator.create(Image);
        img.* = Image{
            .width = width,
            .height = height,
            .pixels = pixels,
            .allocator = allocator,
        };
        allocator.destroy(error_ptr);
        allocator.free(row_pointers);
        return img;
    }

    pub fn loadJpegFromMemory(allocator: std.mem.Allocator, data: []const u8) !?*Image {
        if (data.len < 4 or data[0] != 0xFF or data[1] != 0xD8) return null;

        var cinfo: c.struct_jpeg_decompress_struct = undefined;
        var jerr: c.struct_jpeg_error_mgr = undefined;
        cinfo.err = c.jpeg_std_error(&jerr);
        c.jpeg_create_decompress(&cinfo);
        defer c.jpeg_destroy_decompress(&cinfo);

        // Use custom source manager to read from memory
        var src_mgr: c.struct_jpeg_source_mgr = undefined;
        src_mgr.init_source = initJpegSource;
        src_mgr.fill_input_buffer = fillJpegInputBuffer;
        src_mgr.skip_input_data = skipJpegInputData;
        src_mgr.resync_to_restart = c.jpeg_resync_to_restart;
        src_mgr.term_source = termJpegSource;
        src_mgr.bytes_in_buffer = @intCast(data.len);
        src_mgr.next_input_byte = @ptrCast(data.ptr);

        cinfo.src = &src_mgr;

        if (c.jpeg_read_header(&cinfo, 1) != c.JPEG_HEADER_OK) return null;
        cinfo.out_color_space = c.JCS_RGB;
        _ = c.jpeg_start_decompress(&cinfo);

        const width: u32 = cinfo.output_width;
        const height: u32 = cinfo.output_height;
        if (width == 0 or height == 0) return null;

        const pixel_count = @as(usize, width) * @as(usize, height);
        const pixels = try allocator.alloc(u32, pixel_count);
        errdefer allocator.free(pixels);

        const row_stride = @as(usize, cinfo.output_width) * @as(usize, @intCast(cinfo.output_components));
        const row_buffer = try allocator.alloc(u8, row_stride);
        defer allocator.free(row_buffer);

        var row_ptrs = [_][*c]u8{row_buffer.ptr};

        var cur_y: u32 = 0;
        while (cinfo.output_scanline < cinfo.output_height) {
            _ = c.jpeg_read_scanlines(&cinfo, &row_ptrs, 1);
            const dst_offset = @as(usize, cur_y) * @as(usize, width);
            var x: usize = 0;
            while (x < width) : (x += 1) {
                const r: u32 = row_buffer[x * 3 + 0];
                const g: u32 = row_buffer[x * 3 + 1];
                const b: u32 = row_buffer[x * 3 + 2];
                pixels[dst_offset + x] = (0xFF << 24) | (r << 16) | (g << 8) | b;
            }
            cur_y += 1;
        }
        _ = c.jpeg_finish_decompress(&cinfo);

        const img = try allocator.create(Image);
        img.* = Image{
            .width = width,
            .height = height,
            .pixels = pixels,
            .allocator = allocator,
        };
        return img;
    }

    fn initJpegSource(cinfo: [*c]c.struct_jpeg_decompress_struct) callconv(.c) void {
        _ = cinfo;
    }

    fn fillJpegInputBuffer(cinfo: [*c]c.struct_jpeg_decompress_struct) callconv(.c) c.boolean {
        _ = cinfo;
        return c.TRUE;
    }

    fn skipJpegInputData(cinfo: [*c]c.struct_jpeg_decompress_struct, num_bytes: c_long) callconv(.c) void {
        _ = cinfo;
        _ = num_bytes;
    }

    fn termJpegSource(cinfo: [*c]c.struct_jpeg_decompress_struct) callconv(.c) void {
        _ = cinfo;
    }

    const ReadContext = struct {
        data: []const u8,
        offset: usize = 0,
    };
};

pub const Rect = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,

    pub fn init(x: i32, y: i32, w: u32, h: u32) Rect {
        return .{ .x = x, .y = y, .w = w, .h = h };
    }

    pub fn intersect(self: Rect, other: Rect) Rect {
        const x0 = @max(self.x, other.x);
        const y0 = @max(self.y, other.y);
        const x1 = @min(self.x + @as(i32, @intCast(self.w)), other.x + @as(i32, @intCast(other.w)));
        const y1 = @min(self.y + @as(i32, @intCast(self.h)), other.y + @as(i32, @intCast(other.h)));
        if (x1 <= x0 or y1 <= y0) {
            return .{ .x = x0, .y = y0, .w = 0, .h = 0 };
        }
        return .{
            .x = x0,
            .y = y0,
            .w = @as(u32, @intCast(x1 - x0)),
            .h = @as(u32, @intCast(y1 - y0)),
        };
    }

    pub inline fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and py >= self.y and
            px < self.x + @as(i32, @intCast(self.w)) and
            py < self.y + @as(i32, @intCast(self.h));
    }
};

pub const Renderer = struct {
    pixels: [*]u32,
    width: u32,
    height: u32,
    stride: u32,
    active_clip: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    pub fn init(pixels: [*]u32, width: u32, height: u32, stride: u32) !Renderer {
        return .{
            .pixels = pixels,
            .width = width,
            .height = height,
            .stride = stride,
            .active_clip = Rect{ .x = 0, .y = 0, .w = width, .h = height },
        };
    }

    pub fn withClip(self: Renderer, rect: Rect) Renderer {
        var r = self;
        r.active_clip = r.active_clip.intersect(rect);
        return r;
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

    pub inline fn setPixel(self: Renderer, x: i32, y: i32, color: Color) void {
        if (!self.active_clip.contains(x, y)) return;
        const idx = @as(usize, @intCast(y)) * (@as(usize, self.stride) / 4) + @as(usize, @intCast(x));
        self.pixels[idx] = blendOver(self.pixels[idx], color);
    }

    pub inline fn setPixelCoverage(self: Renderer, x: i32, y: i32, color: Color, cov: u8) void {
        if (cov == 0 or !self.active_clip.contains(x, y)) return;
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

        const clip_x0 = self.active_clip.x;
        const clip_y0 = self.active_clip.y;
        const clip_x1 = clip_x0 + @as(i32, @intCast(self.active_clip.w));
        const clip_y1 = clip_y0 + @as(i32, @intCast(self.active_clip.h));

        const x0 = @max(clip_x0, x);
        const y0 = @max(clip_y0, y);
        const x1 = @min(clip_x1, x + @as(i32, @intCast(w)));
        const y1 = @min(clip_y1, y + @as(i32, @intCast(h)));
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
        const w_i32 = @as(i32, @intCast(w));
        const h_i32 = @as(i32, @intCast(h));

        // 1. Center vertical slab (between top corners and bottom corners)
        if (h > r_u32 * 2) {
            self.fillRect(x, y + r_i32, w, h - r_u32 * 2, color);
        }

        // 2. Top and bottom slabs between the corners
        if (w > r_u32 * 2) {
            self.fillRect(x + r_i32, y, w - r_u32 * 2, r_u32, color);
            self.fillRect(x + r_i32, y + h_i32 - r_i32, w - r_u32 * 2, r_u32, color);
        }

        // 3. 4 Corner squares (r x r) with analytical antialiasing:
        const r_minus_half = r - 0.5;
        const r_plus_half = r + 0.5;
        const r_minus_half_sq = r_minus_half * r_minus_half;
        const r_plus_half_sq = r_plus_half * r_plus_half;

        // Top-Left corner: center is (x + r, y + r)
        const tl_cx = @as(f32, @floatFromInt(x + r_i32));
        const tl_cy = @as(f32, @floatFromInt(y + r_i32));
        var cy: i32 = y;
        while (cy < y + r_i32) : (cy += 1) {
            const py = @as(f32, @floatFromInt(cy)) + 0.5;
            const dy = py - tl_cy;
            const dy_sq = dy * dy;
            var cx: i32 = x;
            while (cx < x + r_i32) : (cx += 1) {
                const px = @as(f32, @floatFromInt(cx)) + 0.5;
                const dx = px - tl_cx;
                const dist_sq = dx * dx + dy_sq;
                if (dist_sq <= r_minus_half_sq) {
                    self.setPixel(cx, cy, color);
                } else if (dist_sq < r_plus_half_sq) {
                    const dist = @sqrt(dist_sq);
                    const cov = std.math.clamp(0.5 - (dist - r), 0.0, 1.0);
                    self.setPixelCoverage(cx, cy, color, @as(u8, @intFromFloat(cov * 255.0)));
                }
            }
        }

        // Top-Right corner: center is (x + w - r, y + r)
        const tr_cx = @as(f32, @floatFromInt(x + w_i32 - r_i32));
        const tr_cy = @as(f32, @floatFromInt(y + r_i32));
        cy = y;
        while (cy < y + r_i32) : (cy += 1) {
            const py = @as(f32, @floatFromInt(cy)) + 0.5;
            const dy = py - tr_cy;
            const dy_sq = dy * dy;
            var cx: i32 = x + w_i32 - r_i32;
            while (cx < x + w_i32) : (cx += 1) {
                const px = @as(f32, @floatFromInt(cx)) + 0.5;
                const dx = px - tr_cx;
                const dist_sq = dx * dx + dy_sq;
                if (dist_sq <= r_minus_half_sq) {
                    self.setPixel(cx, cy, color);
                } else if (dist_sq < r_plus_half_sq) {
                    const dist = @sqrt(dist_sq);
                    const cov = std.math.clamp(0.5 - (dist - r), 0.0, 1.0);
                    self.setPixelCoverage(cx, cy, color, @as(u8, @intFromFloat(cov * 255.0)));
                }
            }
        }

        // Bottom-Left corner: center is (x + r, y + h - r)
        const bl_cx = @as(f32, @floatFromInt(x + r_i32));
        const bl_cy = @as(f32, @floatFromInt(y + h_i32 - r_i32));
        cy = y + h_i32 - r_i32;
        while (cy < y + h_i32) : (cy += 1) {
            const py = @as(f32, @floatFromInt(cy)) + 0.5;
            const dy = py - bl_cy;
            const dy_sq = dy * dy;
            var cx: i32 = x;
            while (cx < x + r_i32) : (cx += 1) {
                const px = @as(f32, @floatFromInt(cx)) + 0.5;
                const dx = px - bl_cx;
                const dist_sq = dx * dx + dy_sq;
                if (dist_sq <= r_minus_half_sq) {
                    self.setPixel(cx, cy, color);
                } else if (dist_sq < r_plus_half_sq) {
                    const dist = @sqrt(dist_sq);
                    const cov = std.math.clamp(0.5 - (dist - r), 0.0, 1.0);
                    self.setPixelCoverage(cx, cy, color, @as(u8, @intFromFloat(cov * 255.0)));
                }
            }
        }

        // Bottom-Right corner: center is (x + w - r, y + h - r)
        const br_cx = @as(f32, @floatFromInt(x + w_i32 - r_i32));
        const br_cy = @as(f32, @floatFromInt(y + h_i32 - r_i32));
        cy = y + h_i32 - r_i32;
        while (cy < y + h_i32) : (cy += 1) {
            const py = @as(f32, @floatFromInt(cy)) + 0.5;
            const dy = py - br_cy;
            const dy_sq = dy * dy;
            var cx: i32 = x + w_i32 - r_i32;
            while (cx < x + w_i32) : (cx += 1) {
                const px = @as(f32, @floatFromInt(cx)) + 0.5;
                const dx = px - br_cx;
                const dist_sq = dx * dx + dy_sq;
                if (dist_sq <= r_minus_half_sq) {
                    self.setPixel(cx, cy, color);
                } else if (dist_sq < r_plus_half_sq) {
                    const dist = @sqrt(dist_sq);
                    const cov = std.math.clamp(0.5 - (dist - r), 0.0, 1.0);
                    self.setPixelCoverage(cx, cy, color, @as(u8, @intFromFloat(cov * 255.0)));
                }
            }
        }
    }

    /// Continuous-curvature squircle / smooth rounded rectangle
    pub fn fillSquircle(self: Renderer, x: i32, y: i32, w: u32, h: u32, radius: u32, color: Color) void {
        self.fillRoundedRect(x, y, w, h, radius, color);
    }

    /// Glassmorphic squircle with top-inner bevel highlight.
    pub fn fillGlassSquircle(self: Renderer, x: i32, y: i32, w: u32, h: u32, radius: u32, base_color: Color) void {
        self.fillSquircle(x, y, w, h, radius, base_color);
        if (h > 6 and w > 12) {
            self.drawTopBevelHighlight(x, y, w, radius);
        }
    }

    /// 1px specular highlight along top edge.
    pub fn drawTopBevelHighlight(self: Renderer, x: i32, y: i32, w: u32, radius: u32) void {
        const highlight_color = Color.init(28, 255, 255, 255);
        const r_inset = @min(radius, w / 4);
        const x_start = x + @as(i32, @intCast(r_inset));
        const span_w = if (w > r_inset * 2) w - r_inset * 2 else 0;
        if (span_w > 0) {
            self.fillRect(x_start, y + 1, span_w, 1, highlight_color);
        }
    }

    /// Soft elevated drop shadow with quadratic falloff.
    pub fn drawDropShadow(self: Renderer, x: i32, y: i32, w: u32, h: u32, radius: u32, blur: u32, shadow_color: Color) void {
        const y_off = @as(i32, @intCast(@max(1, (blur + 1) / 2)));
        self.drawSoftShadow(x, y, w, h, radius, blur, y_off, shadow_color);
    }

    pub fn drawSoftShadow(self: Renderer, x: i32, y: i32, w: u32, h: u32, radius: u32, blur: u32, y_offset: i32, shadow_color: Color) void {
        if (shadow_color.a == 0 or blur == 0 or w == 0 or h == 0) return;

        const blur_f = @as(f32, @floatFromInt(blur));
        const max_a = @as(f32, @floatFromInt(shadow_color.a));

        var step: u32 = 1;
        while (step <= blur) : (step += 1) {
            const expand = @as(i32, @intCast(step));
            const cur_x = x - expand;
            const cur_y = y - expand + y_offset;
            const cur_w = w + @as(u32, @intCast(expand * 2));
            const cur_h = h + @as(u32, @intCast(expand * 2));

            // Smooth quadratic falloff curve:
            const t = @as(f32, @floatFromInt(blur + 1 - step)) / (blur_f + 1.0);
            const factor = t * t;
            const alpha_val = @as(u32, @intFromFloat(max_a * factor * 0.40));

            if (alpha_val > 0) {
                var col = shadow_color;
                col.a = @intCast(@min(255, alpha_val));
                self.drawRoundedBorder(cur_x, cur_y, cur_w, cur_h, radius + @as(u32, @intCast(expand)), 1, col);
            }
        }
    }

    /// Linear gradient squircle blending col_start, col_mid, and col_end.
    pub fn fillPastelGradientSquircle(
        self: Renderer,
        x: i32,
        y: i32,
        w: u32,
        h: u32,
        radius: u32,
        col_start: Color,
        col_mid: Color,
        col_end: Color,
    ) void {
        if (w == 0 or h == 0) return;
        if (radius == 0) {
            var cy: i32 = @max(0, y);
            const y1 = @min(@as(i32, @intCast(self.height)), y + @as(i32, @intCast(h)));
            const x0 = @max(0, x);
            const x1 = @min(@as(i32, @intCast(self.width)), x + @as(i32, @intCast(w)));
            while (cy < y1) : (cy += 1) {
                const v = (@as(f32, @floatFromInt(cy - y)) + 0.5) / @as(f32, @floatFromInt(h));
                var cx = x0;
                while (cx < x1) : (cx += 1) {
                    const u = (@as(f32, @floatFromInt(cx - x)) + 0.5) / @as(f32, @floatFromInt(w));
                    const col = interpolateGradient3(col_start, col_mid, col_end, (u + v) * 0.5);
                    self.setPixel(cx, cy, col);
                }
            }
            return;
        }

        const max_r = @min(w / 2, h / 2);
        const r_u32 = @min(radius, max_r);
        const r = @as(f32, @floatFromInt(r_u32));
        const r_i32 = @as(i32, @intCast(r_u32));

        const x0 = @max(0, x);
        const y0 = @max(0, y);
        const x1 = @min(@as(i32, @intCast(self.width)), x + @as(i32, @intCast(w)));
        const y1 = @min(@as(i32, @intCast(self.height)), y + @as(i32, @intCast(h)));
        if (x0 >= x1 or y0 >= y1) return;

        const stride_pixels = @as(usize, self.stride) / 4;
        const inv_w: f32 = 1.0 / @as(f32, @floatFromInt(w));
        const inv_h: f32 = 1.0 / @as(f32, @floatFromInt(h));
        const dt: f32 = 0.5 * inv_w;

        const mid_top = @min(y1, @max(y0, y + r_i32));
        const mid_bot = @max(y0, @min(y1, y + @as(i32, @intCast(h)) - r_i32));

        // 1. Top corner rows
        var cy: i32 = y0;
        const top_end = @min(mid_top, y1);
        while (cy < top_end) : (cy += 1) {
            const dy = @as(f32, @floatFromInt(y + r_i32)) - (@as(f32, @floatFromInt(cy)) + 0.5);
            const vy = dy / r;
            const vy_4 = (vy * vy) * (vy * vy);
            const v = (@as(f32, @floatFromInt(cy - y)) + 0.5) * inv_h;
            const t_base = v * 0.5;
            const row_start = @as(usize, @intCast(cy)) * stride_pixels;

            const mid_left = @max(x0, x + r_i32);
            const mid_right = @min(x1, x + @as(i32, @intCast(w)) - r_i32);

            // Left corner
            var cx = x0;
            const left_end = @min(mid_left, x1);
            while (cx < left_end) : (cx += 1) {
                const dx = @as(f32, @floatFromInt(x + r_i32)) - (@as(f32, @floatFromInt(cx)) + 0.5);
                const ux = dx / r;
                const ux_4 = (ux * ux) * (ux * ux);
                const val = ux_4 + vy_4;
                const t = t_base + (@as(f32, @floatFromInt(cx - x)) + 0.5) * dt;
                const col = interpolateGradient3(col_start, col_mid, col_end, t);
                if (val <= 0.85) {
                    self.pixels[row_start + @as(usize, @intCast(cx))] = col.toArgb();
                } else if (val <= 1.05) {
                    const eff_r = std.math.sqrt(std.math.sqrt(val)) * r;
                    const d = eff_r - r;
                    const cov = std.math.clamp(0.5 - d, 0.0, 1.0);
                    self.setPixelCoverage(cx, cy, col, @as(u8, @intFromFloat(cov * 255.0)));
                }
            }

            // Middle solid span
            cx = mid_left;
            var t_mid = t_base + (@as(f32, @floatFromInt(cx - x)) + 0.5) * dt;
            while (cx < mid_right) : (cx += 1) {
                const col = interpolateGradient3(col_start, col_mid, col_end, t_mid);
                self.pixels[row_start + @as(usize, @intCast(cx))] = col.toArgb();
                t_mid += dt;
            }

            // Right corner
            cx = @max(mid_right, x0);
            while (cx < x1) : (cx += 1) {
                const dx = (@as(f32, @floatFromInt(cx)) + 0.5) - @as(f32, @floatFromInt(x + @as(i32, @intCast(w)) - r_i32));
                const ux = dx / r;
                const ux_4 = (ux * ux) * (ux * ux);
                const val = ux_4 + vy_4;
                const t = t_base + (@as(f32, @floatFromInt(cx - x)) + 0.5) * dt;
                const col = interpolateGradient3(col_start, col_mid, col_end, t);
                if (val <= 0.85) {
                    self.pixels[row_start + @as(usize, @intCast(cx))] = col.toArgb();
                } else if (val <= 1.05) {
                    const eff_r = std.math.sqrt(std.math.sqrt(val)) * r;
                    const d = eff_r - r;
                    const cov = std.math.clamp(0.5 - d, 0.0, 1.0);
                    self.setPixelCoverage(cx, cy, col, @as(u8, @intFromFloat(cov * 255.0)));
                }
            }
        }

        // 2. Middle band (fast scanline fill directly to pixel memory)
        cy = mid_top;
        while (cy < mid_bot) : (cy += 1) {
            const v = (@as(f32, @floatFromInt(cy - y)) + 0.5) * inv_h;
            const t_base = v * 0.5;
            const row_start = @as(usize, @intCast(cy)) * stride_pixels;
            var cx = x0;
            var t = t_base + (@as(f32, @floatFromInt(cx - x)) + 0.5) * dt;
            while (cx < x1) : (cx += 1) {
                const col = interpolateGradient3(col_start, col_mid, col_end, t);
                self.pixels[row_start + @as(usize, @intCast(cx))] = col.toArgb();
                t += dt;
            }
        }

        // 3. Bottom corner rows
        cy = @max(mid_bot, y0);
        while (cy < y1) : (cy += 1) {
            const dy = (@as(f32, @floatFromInt(cy)) + 0.5) - @as(f32, @floatFromInt(y + @as(i32, @intCast(h)) - r_i32));
            const vy = dy / r;
            const vy_4 = (vy * vy) * (vy * vy);
            const v = (@as(f32, @floatFromInt(cy - y)) + 0.5) * inv_h;
            const t_base = v * 0.5;
            const row_start = @as(usize, @intCast(cy)) * stride_pixels;

            const mid_left = @max(x0, x + r_i32);
            const mid_right = @min(x1, x + @as(i32, @intCast(w)) - r_i32);

            // Left corner
            var cx = x0;
            const left_end = @min(mid_left, x1);
            while (cx < left_end) : (cx += 1) {
                const dx = @as(f32, @floatFromInt(x + r_i32)) - (@as(f32, @floatFromInt(cx)) + 0.5);
                const ux = dx / r;
                const ux_4 = (ux * ux) * (ux * ux);
                const val = ux_4 + vy_4;
                const t = t_base + (@as(f32, @floatFromInt(cx - x)) + 0.5) * dt;
                const col = interpolateGradient3(col_start, col_mid, col_end, t);
                if (val <= 0.85) {
                    self.pixels[row_start + @as(usize, @intCast(cx))] = col.toArgb();
                } else if (val <= 1.05) {
                    const eff_r = std.math.sqrt(std.math.sqrt(val)) * r;
                    const d = eff_r - r;
                    const cov = std.math.clamp(0.5 - d, 0.0, 1.0);
                    self.setPixelCoverage(cx, cy, col, @as(u8, @intFromFloat(cov * 255.0)));
                }
            }

            // Middle solid span
            cx = mid_left;
            var t_mid = t_base + (@as(f32, @floatFromInt(cx - x)) + 0.5) * dt;
            while (cx < mid_right) : (cx += 1) {
                const col = interpolateGradient3(col_start, col_mid, col_end, t_mid);
                self.pixels[row_start + @as(usize, @intCast(cx))] = col.toArgb();
                t_mid += dt;
            }

            // Right corner
            cx = @max(mid_right, x0);
            while (cx < x1) : (cx += 1) {
                const dx = (@as(f32, @floatFromInt(cx)) + 0.5) - @as(f32, @floatFromInt(x + @as(i32, @intCast(w)) - r_i32));
                const ux = dx / r;
                const ux_4 = (ux * ux) * (ux * ux);
                const val = ux_4 + vy_4;
                const t = t_base + (@as(f32, @floatFromInt(cx - x)) + 0.5) * dt;
                const col = interpolateGradient3(col_start, col_mid, col_end, t);
                if (val <= 0.85) {
                    self.pixels[row_start + @as(usize, @intCast(cx))] = col.toArgb();
                } else if (val <= 1.05) {
                    const eff_r = std.math.sqrt(std.math.sqrt(val)) * r;
                    const d = eff_r - r;
                    const cov = std.math.clamp(0.5 - d, 0.0, 1.0);
                    self.setPixelCoverage(cx, cy, col, @as(u8, @intFromFloat(cov * 255.0)));
                }
            }
        }
    }

    inline fn interpolateGradient3(c0: Color, c1: Color, c2: Color, t: f32) Color {
        const clamped_t = std.math.clamp(t, 0.0, 1.0);
        if (clamped_t < 0.5) {
            const factor = clamped_t * 2.0;
            const inv = 1.0 - factor;
            return Color.init(
                @intFromFloat(@as(f32, @floatFromInt(c0.a)) * inv + @as(f32, @floatFromInt(c1.a)) * factor),
                @intFromFloat(@as(f32, @floatFromInt(c0.r)) * inv + @as(f32, @floatFromInt(c1.r)) * factor),
                @intFromFloat(@as(f32, @floatFromInt(c0.g)) * inv + @as(f32, @floatFromInt(c1.g)) * factor),
                @intFromFloat(@as(f32, @floatFromInt(c0.b)) * inv + @as(f32, @floatFromInt(c1.b)) * factor),
            );
        } else {
            const factor = (clamped_t - 0.5) * 2.0;
            const inv = 1.0 - factor;
            return Color.init(
                @intFromFloat(@as(f32, @floatFromInt(c1.a)) * inv + @as(f32, @floatFromInt(c2.a)) * factor),
                @intFromFloat(@as(f32, @floatFromInt(c1.r)) * inv + @as(f32, @floatFromInt(c2.r)) * factor),
                @intFromFloat(@as(f32, @floatFromInt(c1.g)) * inv + @as(f32, @floatFromInt(c2.g)) * factor),
                @intFromFloat(@as(f32, @floatFromInt(c1.b)) * inv + @as(f32, @floatFromInt(c2.b)) * factor),
            );
        }
    }

    pub fn drawCircleBorder(self: Renderer, cx: f64, cy: f64, radius: f64, stroke_width: f64, color: Color) void {
        if (color.a == 0 or radius <= 0 or stroke_width <= 0) return;
        const r = @as(f32, @floatCast(radius));
        const sw = @as(f32, @floatCast(stroke_width));
        const r_in = @max(0.0, r - sw);
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
                const dist = @sqrt(d_sq);
                const cov_out = std.math.clamp(0.5 - (dist - r), 0.0, 1.0);
                const cov_in = if (r_in > 0.0) std.math.clamp(0.5 - (r_in - dist), 0.0, 1.0) else 1.0;
                const cov = cov_out * cov_in;
                if (cov > 0.001) {
                    self.setPixelCoverage(px, py, color, @as(u8, @intFromFloat(cov * 255.0)));
                }
            }
        }
    }

    /// Elevated card with drop shadow and border.
    pub fn drawNeumorphicCard(
        self: Renderer,
        x: i32,
        y: i32,
        w: u32,
        h: u32,
        radius: u32,
        bg_color: Color,
        border_color: Color,
        is_hovered: bool,
    ) void {
        const shadow_col = if (is_hovered) Color.init(40, 0, 0, 0) else Color.init(22, 0, 0, 0);
        self.drawSoftShadow(x, y, w, h, radius, if (is_hovered) 5 else 3, 2, shadow_col);
        self.fillRoundedRect(x, y, w, h, radius, bg_color);
        if (border_color.a > 0) {
            self.drawRoundedBorder(x, y, w, h, radius, 1, border_color);
        }
    }

    /// Circular button with shadow and optional border.
    pub fn drawNeumorphicCircleButton(
        self: Renderer,
        cx: f64,
        cy: f64,
        radius: f64,
        bg_color: Color,
        border_color: Color,
        is_hovered: bool,
        is_active: bool,
    ) void {
        _ = is_active;
        const shadow_col = if (is_hovered) Color.init(50, 0, 0, 0) else Color.init(25, 0, 0, 0);
        self.fillCircle(cx, cy + 1.2, radius + 0.8, shadow_col);
        self.fillCircle(cx, cy, radius, bg_color);
        if (border_color.a > 0) {
            self.drawCircleBorder(cx, cy, radius, 1.0, border_color);
        }
    }

    /// Pill slider with track, progress fill, and circular thumb.
    pub fn drawPillSlider(
        self: Renderer,
        x: i32,
        y: i32,
        w: u32,
        h: u32,
        percent: u32,
        track_color: Color,
        fill_color: Color,
        thumb_color: Color,
        thumb_shadow_color: Color,
        is_hovered: bool,
    ) void {
        _ = is_hovered;
        const track_h: u32 = 6;
        const track_y: i32 = y + @as(i32, @intCast((h - track_h) / 2));
        const tr_rad: u32 = track_h / 2;

        // Clean track groove
        self.fillRoundedRect(x, track_y, w, track_h, tr_rad, track_color);

        // Filled progress portion
        const clamped_pct = @min(100, percent);
        const fill_w: u32 = @intCast((@as(u64, w) * clamped_pct) / 100);
        if (fill_w >= track_h) {
            self.fillRoundedRect(x, track_y, fill_w, track_h, tr_rad, fill_color);
        } else if (fill_w > 0) {
            self.fillRoundedRect(x, track_y, fill_w, track_h, fill_w / 2, fill_color);
        }

        // Tactile circular thumb handle
        const thumb_r: f64 = 7.5;
        var thumb_cx: f64 = @as(f64, @floatFromInt(x)) + (@as(f64, @floatFromInt(w)) * @as(f64, @floatFromInt(clamped_pct))) / 100.0;
        const min_cx: f64 = @as(f64, @floatFromInt(x)) + thumb_r;
        const max_cx: f64 = @as(f64, @floatFromInt(x + @as(i32, @intCast(w)))) - thumb_r;
        if (min_cx <= max_cx) {
            thumb_cx = std.math.clamp(thumb_cx, min_cx, max_cx);
        } else {
            thumb_cx = @as(f64, @floatFromInt(x)) + @as(f64, @floatFromInt(w)) / 2.0;
        }
        const thumb_cy: f64 = @as(f64, @floatFromInt(y + @as(i32, @intCast(h / 2))));

        // Diffuse dark shadow under thumb
        self.fillCircle(thumb_cx, thumb_cy + 1.2, thumb_r + 1.0, thumb_shadow_color);
        // Pure white knob body
        self.fillCircle(thumb_cx, thumb_cy, thumb_r, thumb_color);
        // Subtle 1px border around knob
        self.drawCircleBorder(thumb_cx, thumb_cy, thumb_r, 0.75, Color.init(40, 0, 0, 0));
    }

    /// Pill toggle switch with circular thumb.
    pub fn drawToggleSwitch(
        self: Renderer,
        x: i32,
        y: i32,
        w: u32,
        h: u32,
        is_on: bool,
        on_color: Color,
        off_color: Color,
        thumb_color: Color,
    ) void {
        const rad = h / 2;
        const track_bg = if (is_on) on_color else off_color;
        self.fillSquircle(x, y, w, h, rad, track_bg);
        self.drawTopBevelHighlight(x, y, w, rad);

        const knob_r: f64 = @as(f64, @floatFromInt(h)) / 2.0 - 2.5;
        const knob_cy: f64 = @as(f64, @floatFromInt(y)) + @as(f64, @floatFromInt(h)) / 2.0;
        const knob_cx: f64 = if (is_on)
            (@as(f64, @floatFromInt(x + @as(i32, @intCast(w)))) - @as(f64, @floatFromInt(h)) / 2.0)
        else
            (@as(f64, @floatFromInt(x)) + @as(f64, @floatFromInt(h)) / 2.0);

        self.fillCircle(knob_cx, knob_cy + 1.4, knob_r + 1.0, Color.init(45, 0, 0, 0));
        self.fillCircle(knob_cx, knob_cy, knob_r, thumb_color);
    }

    /// Segmented control with pill track and selected segment pill.
    pub fn drawSegmentedControl(
        self: Renderer,
        font: *Font,
        x: i32,
        y: i32,
        w: u32,
        h: u32,
        labels: []const []const u8,
        selected_idx: usize,
        hovered_idx: ?usize,
        size_px: u32,
        track_color: Color,
        border_color: Color,
        active_bg: Color,
        active_fg: Color,
        inactive_fg: Color,
    ) void {
        if (labels.len == 0 or w == 0 or h == 0) return;
        const rad = h / 2;
        self.fillSquircle(x, y, w, h, rad, track_color);
        self.drawSquircleBorder(x, y, w, h, rad, 1, border_color);

        const seg_w: u32 = w / @as(u32, @intCast(labels.len));
        for (labels, 0..) |lbl, i| {
            const seg_x = x + @as(i32, @intCast(@as(u32, @intCast(i)) * seg_w));
            const is_sel = (i == selected_idx);
            const is_hov = (hovered_idx != null and hovered_idx.? == i);

            if (is_sel) {
                const pad: i32 = 2;
                const rw = seg_w - 4;
                const rh = h - 4;
                self.drawDropShadow(seg_x + pad, y + pad + 1, rw, rh, (rh) / 2, 2, Color.init(26, 80, 95, 120));
                self.fillSquircle(seg_x + pad, y + pad, rw, rh, (rh) / 2, active_bg);
                self.drawTopBevelHighlight(seg_x + pad, y + pad, rw, (rh) / 2);
            } else if (is_hov) {
                const pad: i32 = 2;
                const rw = seg_w - 4;
                const rh = h - 4;
                self.fillSquircle(seg_x + pad, y + pad, rw, rh, (rh) / 2, Color.init(35, 255, 255, 255));
            }

            const fg = if (is_sel) active_fg else inactive_fg;
            const text_w = self.measureTextWithSize(font, lbl, size_px);
            const tx = seg_x + @divTrunc(@as(i32, @intCast(seg_w)) - @as(i32, @intCast(text_w)), 2);
            const baseline_y = y + @as(i32, @intCast(h / 2)) + @divTrunc(font.ascender_px, 2) - 1;
            self.drawTextWithSize(font, lbl, tx, baseline_y, size_px, fg);
        }
    }

    pub fn lerp(a: f32, b: f32, t: f32) f32 {
        return a + (b - a) * t;
    }

    pub fn easeOutCubic(t: f32) f32 {
        const clamped = std.math.clamp(t, 0.0, 1.0);
        const inv = 1.0 - clamped;
        return 1.0 - inv * inv * inv;
    }

    pub fn drawRoundedBorder(self: Renderer, x: i32, y: i32, w: u32, h: u32, radius: u32, border_w: u32, color: Color) void {
        if (color.a == 0 or w == 0 or h == 0 or border_w == 0) return;

        const max_r = @min(w / 2, h / 2);
        const r_u32 = @min(radius, max_r);
        const r = @as(f32, @floatFromInt(r_u32));
        const bw = @as(f32, @floatFromInt(border_w));
        const r_inner = @max(0.0, r - bw);
        const r_i32 = @as(i32, @intCast(r_u32));
        const bw_i32 = @as(i32, @intCast(border_w));
        const w_i32 = @as(i32, @intCast(w));
        const h_i32 = @as(i32, @intCast(h));

        // Top straight edge
        if (w > r_u32 * 2) {
            self.fillRect(x + r_i32, y, w - r_u32 * 2, border_w, color);
            self.fillRect(x + r_i32, y + h_i32 - bw_i32, w - r_u32 * 2, border_w, color);
        }
        // Left and Right straight edges
        if (h > r_u32 * 2) {
            self.fillRect(x, y + r_i32, border_w, h - r_u32 * 2, color);
            self.fillRect(x + w_i32 - bw_i32, y + r_i32, border_w, h - r_u32 * 2, color);
        }

        if (r_u32 == 0) return;

        // Corners:
        const corners = [_]struct { cx: f32, cy: f32, start_x: i32, start_y: i32 }{
            // Top-Left
            .{ .cx = @as(f32, @floatFromInt(x + r_i32)), .cy = @as(f32, @floatFromInt(y + r_i32)), .start_x = x, .start_y = y },
            // Top-Right
            .{ .cx = @as(f32, @floatFromInt(x + w_i32 - r_i32)), .cy = @as(f32, @floatFromInt(y + r_i32)), .start_x = x + w_i32 - r_i32, .start_y = y },
            // Bottom-Left
            .{ .cx = @as(f32, @floatFromInt(x + r_i32)), .cy = @as(f32, @floatFromInt(y + h_i32 - r_i32)), .start_x = x, .start_y = y + h_i32 - r_i32 },
            // Bottom-Right
            .{ .cx = @as(f32, @floatFromInt(x + w_i32 - r_i32)), .cy = @as(f32, @floatFromInt(y + h_i32 - r_i32)), .start_x = x + w_i32 - r_i32, .start_y = y + h_i32 - r_i32 },
        };

        for (corners) |c_info| {
            var cy = c_info.start_y;
            const end_y = c_info.start_y + r_i32;
            const end_x = c_info.start_x + r_i32;
            while (cy < end_y) : (cy += 1) {
                const py = @as(f32, @floatFromInt(cy)) + 0.5;
                const dy = py - c_info.cy;
                const dy_sq = dy * dy;
                var cx = c_info.start_x;
                while (cx < end_x) : (cx += 1) {
                    const px = @as(f32, @floatFromInt(cx)) + 0.5;
                    const dx = px - c_info.cx;
                    const dist = @sqrt(dx * dx + dy_sq);

                    // Outer coverage
                    const d_out = dist - r;
                    const cov_out = std.math.clamp(0.5 - d_out, 0.0, 1.0);
                    // Inner coverage
                    const d_in = r_inner - dist;
                    const cov_in = if (r_inner > 0.0) std.math.clamp(0.5 - d_in, 0.0, 1.0) else 1.0;

                    const cov = cov_out * cov_in;
                    if (cov > 0.001) {
                        self.setPixelCoverage(cx, cy, color, @as(u8, @intFromFloat(cov * 255.0)));
                    }
                }
            }
        }
    }

    pub fn drawSquircleBorder(self: Renderer, x: i32, y: i32, w: u32, h: u32, radius: u32, border_w: u32, color: Color) void {
        self.drawRoundedBorder(x, y, w, h, radius, border_w, color);
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

    pub fn drawStrokeLine(self: Renderer, x0: i32, y0: i32, x1: i32, y1: i32, stroke_width: u32, col: Color) void {
        const radius: f64 = @floatFromInt(@max(1, stroke_width / 2));
        const dx: i32 = @intCast(@abs(x1 - x0));
        const dy: i32 = @intCast(@abs(y1 - y0));
        const steps = @max(dx, dy);

        if (steps == 0) {
            self.fillCircle(@floatFromInt(x0), @floatFromInt(y0), radius, col);
            return;
        }

        const step_f: f32 = @floatFromInt(steps);
        const x_inc = @as(f32, @floatFromInt(x1 - x0)) / step_f;
        const y_inc = @as(f32, @floatFromInt(y1 - y0)) / step_f;

        var curr_x: f32 = @floatFromInt(x0);
        var curr_y: f32 = @floatFromInt(y0);

        var i: i32 = 0;
        while (i <= steps) : (i += 1) {
            self.fillCircle(@floatCast(curr_x), @floatCast(curr_y), radius, col);
            curr_x += x_inc;
            curr_y += y_inc;
        }
    }

    pub fn drawArrow(self: Renderer, x0: i32, y0: i32, x1: i32, y1: i32, stroke_width: u32, col: Color) void {
        self.drawStrokeLine(x0, y0, x1, y1, stroke_width, col);

        const dx = @as(f32, @floatFromInt(x1 - x0));
        const dy = @as(f32, @floatFromInt(y1 - y0));
        const len = std.math.sqrt(dx * dx + dy * dy);
        if (len < 4.0) return;

        const ux = dx / len;
        const uy = dy / len;

        const head_len = @max(14.0, @as(f32, @floatFromInt(stroke_width)) * 3.5);
        const head_width = head_len * 0.55;

        const bx = @as(f32, @floatFromInt(x1)) - ux * head_len;
        const by = @as(f32, @floatFromInt(y1)) - uy * head_len;

        const nx = -uy;
        const ny = ux;

        const left_x: i32 = @intFromFloat(bx + nx * head_width);
        const left_y: i32 = @intFromFloat(by + ny * head_width);
        const right_x: i32 = @intFromFloat(bx - nx * head_width);
        const right_y: i32 = @intFromFloat(by - ny * head_width);

        self.drawStrokeLine(x1, y1, left_x, left_y, stroke_width, col);
        self.drawStrokeLine(x1, y1, right_x, right_y, stroke_width, col);
        self.drawStrokeLine(left_x, left_y, right_x, right_y, stroke_width, col);
    }

    pub fn drawText(self: Renderer, font: *Font, text: []const u8, x: i32, baseline_y: i32, color: Color) void {
        self.drawTextWithSize(font, text, x, baseline_y, font.size_px, color);
    }

    pub fn drawTextWithSize(self: Renderer, font: *Font, text: []const u8, x: i32, baseline_y: i32, size_px: u32, color: Color) void {
        self.drawTextWithSpacing(font, text, x, baseline_y, size_px, color, 0);
    }

    pub fn drawTextWithSpacing(self: Renderer, font: *Font, text: []const u8, x: i32, baseline_y: i32, size_px: u32, color: Color, letter_spacing: u16) void {
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

                pen_x += cg.advance_x + letter_spacing;
            } else {
                pen_x += @as(i32, @intCast(size_px / 2)) + letter_spacing;
            }
        }
    }

    pub fn drawTextCentered(self: Renderer, font: *Font, text: []const u8, center_x: i32, baseline_y: i32, size_px: u32, color: Color) void {
        const text_w = font.measureTextWithSize(text, size_px);
        const x = center_x - @divTrunc(@as(i32, @intCast(text_w)), 2);
        self.drawTextWithSize(font, text, x, baseline_y, size_px, color);
    }

    pub fn drawTextVerticallyCentered(self: Renderer, font: *Font, text: []const u8, x: i32, y: i32, h: u32, size_px: u32, color: Color) void {
        const baseline = y + @as(i32, @intCast(h / 2)) + @divTrunc(font.ascender_px, 2) - 1;
        self.drawTextWithSize(font, text, x, baseline, size_px, color);
    }

    pub fn drawTextRotated(self: Renderer, font: *Font, text: []const u8, center_x: i32, center_y: i32, angle: f32, size_px: u32, color: Color) void {
        if (text.len == 0 or color.a == 0) return;

        var utf8_view = std.unicode.Utf8View.init(text) catch return;
        var it = utf8_view.iterator();
        const cp = it.nextCodepoint() orelse return;
        const cg = font.getOrLoadGlyph(cp, size_px) orelse return;
        if (cg.width == 0 or cg.height == 0) return;

        const cos_a = @cos(angle);
        const sin_a = @sin(angle);
        const cx_box = @as(f32, @floatFromInt(cg.width)) / 2.0;
        const cy_box = @as(f32, @floatFromInt(cg.height)) / 2.0;

        const max_dim = @max(cg.width, cg.height);
        const half_r: i32 = @intCast(@as(u32, @intFromFloat(@as(f32, @floatFromInt(max_dim)) * 0.72 + 2.0)));

        var dy_i: i32 = -half_r;
        while (dy_i <= half_r) : (dy_i += 1) {
            const dy = @as(f32, @floatFromInt(dy_i));
            var dx_i: i32 = -half_r;
            while (dx_i <= half_r) : (dx_i += 1) {
                const dx = @as(f32, @floatFromInt(dx_i));

                const src_x = cx_box + (cos_a * dx + sin_a * dy);
                const src_y = cy_box + (-sin_a * dx + cos_a * dy);

                if (src_x >= 0.0 and src_x < @as(f32, @floatFromInt(cg.width)) and
                    src_y >= 0.0 and src_y < @as(f32, @floatFromInt(cg.height)))
                {
                    const sx: u32 = @intFromFloat(src_x);
                    const sy: u32 = @intFromFloat(src_y);
                    if (sx < cg.width and sy < cg.height) {
                        const alpha_mask = cg.bitmap[sy * cg.width + sx];
                        if (alpha_mask > 0) {
                            const px = center_x + dx_i;
                            const py = center_y + dy_i;
                            if (px >= 0 and px < self.width and py >= 0 and py < self.height) {
                                self.setPixelCoverage(px, py, color, alpha_mask);
                            }
                        }
                    }
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

    pub fn measureIconInk(self: Renderer, font: *Font, text: []const u8, size_px: u32) InkExtents {
        _ = self;
        return font.measureInk(text, size_px);
    }

    pub fn drawIconCentered(self: Renderer, font: *Font, text: []const u8, center_x: i32, baseline_y: i32, size_px: u32, color: Color) void {
        const ink = font.measureInk(text, size_px);
        const x = center_x - ink.left - @divTrunc(@as(i32, @intCast(ink.width)), 2);
        self.drawTextWithSize(font, text, x, baseline_y, size_px, color);
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

    /// Draw image tinted by color.
    pub fn drawImageTinted(
        self: Renderer,
        img: *const Image,
        dest_x: f64,
        dest_y: f64,
        dest_w: f64,
        dest_h: f64,
        tint: Color,
    ) void {
        if (dest_w <= 0.0 or dest_h <= 0.0 or img.width == 0 or img.height == 0) return;
        if (tint.a == 0) {
            self.drawImage(img, dest_x, dest_y, dest_w, dest_h);
            return;
        }
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
            const src_y = @min(img.height - 1, @as(u32, @intFromFloat(@max(0.0, (@as(f64, @floatFromInt(dy)) - dest_y) * scale_y))));
            const src_row = @as(usize, src_y) * @as(usize, img.width);
            const dst_row = @as(usize, @intCast(dy)) * stride_pixels;
            var dx = x0;
            while (dx < x1) : (dx += 1) {
                const src_x = @min(img.width - 1, @as(u32, @intFromFloat(@max(0.0, (@as(f64, @floatFromInt(dx)) - dest_x) * scale_x))));
                const src_pixel = img.pixels[src_row + src_x];
                if (!self.active_clip.contains(dx, dy)) continue;
                const sa = @as(u8, @truncate((src_pixel >> 24) & 0xFF));
                if (sa == 0) continue;
                const sr = @as(u8, @truncate((src_pixel >> 16) & 0xFF));
                const sg = @as(u8, @truncate((src_pixel >> 8) & 0xFF));
                const sb = @as(u8, @truncate(src_pixel & 0xFF));
                const mul = @as(u32, tint.a);
                const out = Color.init(
                    @intCast((@as(u32, sa) * mul) / 255),
                    @intCast((@as(u32, sr) * @as(u32, tint.r)) / 255),
                    @intCast((@as(u32, sg) * @as(u32, tint.g)) / 255),
                    @intCast((@as(u32, sb) * @as(u32, tint.b)) / 255),
                );
                const dst_idx = dst_row + @as(usize, @intCast(dx));
                self.pixels[dst_idx] = blendOver(self.pixels[dst_idx], out);
            }
        }
    }

    /// Draw rasterized alpha coverage icon tinted with color.
    pub fn drawIconAlpha(
        self: Renderer,
        width: u32,
        height: u32,
        stride: u32,
        alpha: []const u8,
        dest_x: i32,
        dest_y: i32,
        color: Color,
    ) void {
        if (width == 0 or height == 0 or alpha.len == 0 or color.a == 0) return;
        const src_stride = @as(usize, stride);
        const dst_stride = @as(usize, self.stride) / 4;
        const x0 = @max(0, dest_x);
        const y0 = @max(0, dest_y);
        const x1 = @min(@as(i32, @intCast(self.width)), dest_x + @as(i32, @intCast(width)));
        const y1 = @min(@as(i32, @intCast(self.height)), dest_y + @as(i32, @intCast(height)));
        if (x0 >= x1 or y0 >= y1) return;
        var dy = y0;
        while (dy < y1) : (dy += 1) {
            const src_row = @as(usize, @intCast(dy - dest_y)) * src_stride;
            const dst_row = @as(usize, @intCast(dy)) * dst_stride;
            var dx = x0;
            while (dx < x1) : (dx += 1) {
                const cov = alpha[src_row + @as(usize, @intCast(dx - dest_x))];
                if (cov == 0) continue;
                var col = color;
                col.a = @intCast((@as(u32, cov) * @as(u32, color.a)) / 255);
                const idx = dst_row + @as(usize, @intCast(dx));
                self.pixels[idx] = blendOver(self.pixels[idx], col);
            }
        }
    }

    /// Draw rasterized 32-bit ARGB icon directly blended over destination.
    pub fn drawIconArgb(
        self: Renderer,
        width: u32,
        height: u32,
        stride_pixels: u32,
        argb: []const u32,
        dest_x: i32,
        dest_y: i32,
    ) void {
        if (width == 0 or height == 0 or argb.len == 0) return;
        const src_stride = @as(usize, stride_pixels);
        const dst_stride = @as(usize, self.stride) / 4;
        const x0 = @max(0, dest_x);
        const y0 = @max(0, dest_y);
        const x1 = @min(@as(i32, @intCast(self.width)), dest_x + @as(i32, @intCast(width)));
        const y1 = @min(@as(i32, @intCast(self.height)), dest_y + @as(i32, @intCast(height)));
        if (x0 >= x1 or y0 >= y1) return;
        var dy = y0;
        while (dy < y1) : (dy += 1) {
            const src_row = @as(usize, @intCast(dy - dest_y)) * src_stride;
            const dst_row = @as(usize, @intCast(dy)) * dst_stride;
            var dx = x0;
            while (dx < x1) : (dx += 1) {
                const px = argb[src_row + @as(usize, @intCast(dx - dest_x))];
                const sa = @as(u8, @truncate((px >> 24) & 0xFF));
                if (sa == 0) continue;
                const sr = @as(u8, @truncate((px >> 16) & 0xFF));
                const sg = @as(u8, @truncate((px >> 8) & 0xFF));
                const sb = @as(u8, @truncate(px & 0xFF));
                const idx = dst_row + @as(usize, @intCast(dx));
                self.pixels[idx] = blendOver(self.pixels[idx], Color.init(sa, sr, sg, sb));
            }
        }
    }
};

test "Font fallback renders unicode ornament ❫ and symbols" {
    const allocator = std.testing.allocator;
    var font = try Font.init(allocator, "Maple Mono NF, monospace", 16);
    defer font.deinit();

    // 0x276B is ❫
    const glyph_paren = font.getOrLoadGlyph(0x276b, 16);
    try std.testing.expect(glyph_paren != null);
    try std.testing.expect(glyph_paren.?.advance_x > 0);

    // 0x23CE is ⏎
    const glyph_enter = font.getOrLoadGlyph(0x23ce, 16);
    try std.testing.expect(glyph_enter != null);
    try std.testing.expect(glyph_enter.?.advance_x > 0);
}

test "Rect intersect and contains" {
    const r1 = Rect.init(0, 0, 100, 100);
    const r2 = Rect.init(50, 50, 100, 100);
    const inter = r1.intersect(r2);
    try std.testing.expectEqual(@as(i32, 50), inter.x);
    try std.testing.expectEqual(@as(i32, 50), inter.y);
    try std.testing.expectEqual(@as(u32, 50), inter.w);
    try std.testing.expectEqual(@as(u32, 50), inter.h);
    try std.testing.expect(r1.contains(10, 10));
    try std.testing.expect(!r1.contains(150, 150));
}

test "Rect intersect no overlap" {
    const r1 = Rect.init(0, 0, 50, 50);
    const r2 = Rect.init(100, 100, 50, 50);
    const inter = r1.intersect(r2);
    try std.testing.expectEqual(@as(u32, 0), inter.w);
    try std.testing.expectEqual(@as(u32, 0), inter.h);
}


