//! Mizu Standalone Wallpaper Module
//!
//! A native Wayland wallpaper setter and switcher overlay with zero external
//! image or UI dependencies. Uses pure Zig decoders (JPEG, PNG, QOI, BMP),
//! high-quality bilinear/box downsampling, persistent thumbnail caching,
//! and zwlr_layer_shell_v1 for background and fullscreen overlay presentation.

const std = @import("std");

// Zig 0.17 removed @cImport; reuse the translate-c bindings from src/c.zig.
const c = @import("src/c.zig").c;

extern fn memfd_create(name: [*:0]const u8, flags: c_uint) c_int;
const MFD_CLOEXEC: c_uint = 0x0001;

fn getEnvHome() []const u8 {
    const ptr = c.getenv("HOME");
    if (ptr != null) {
        return std.mem.span(ptr);
    }
    return "/tmp";
}

// ============================================================================
// Wayland Layer Shell Protocol Definitions (ZWLR Layer Shell V1)
// ============================================================================

extern const wl_output_interface: c.struct_wl_interface;
extern const wl_surface_interface: c.struct_wl_interface;

const layer_shell_types = [_]?*const c.struct_wl_interface{
    null,
    null,
    null,
    null,
    &zwlr_layer_surface_v1_interface,
    &wl_surface_interface,
    &wl_output_interface,
    null,
    null,
    null,
};

const zwlr_layer_shell_v1_requests = [_]c.struct_wl_message{
    .{ .name = "get_layer_surface", .signature = "no?ous", .types = @ptrCast(@constCast(&layer_shell_types[4])) },
    .{ .name = "destroy", .signature = "3", .types = @ptrCast(@constCast(&layer_shell_types[0])) },
};

pub export const zwlr_layer_shell_v1_interface: c.struct_wl_interface = .{
    .name = "zwlr_layer_shell_v1",
    .version = 4,
    .method_count = 2,
    .methods = &zwlr_layer_shell_v1_requests,
    .event_count = 0,
    .events = null,
};

const zwlr_layer_surface_v1_requests = [_]c.struct_wl_message{
    .{ .name = "set_size", .signature = "uu", .types = @ptrCast(@constCast(&layer_shell_types[0])) },
    .{ .name = "set_anchor", .signature = "u", .types = @ptrCast(@constCast(&layer_shell_types[0])) },
    .{ .name = "set_exclusive_zone", .signature = "i", .types = @ptrCast(@constCast(&layer_shell_types[0])) },
    .{ .name = "set_margin", .signature = "iiii", .types = @ptrCast(@constCast(&layer_shell_types[0])) },
    .{ .name = "set_keyboard_interactivity", .signature = "u", .types = @ptrCast(@constCast(&layer_shell_types[0])) },
    .{ .name = "get_popup", .signature = "o", .types = @ptrCast(@constCast(&layer_shell_types[0])) },
    .{ .name = "ack_configure", .signature = "u", .types = @ptrCast(@constCast(&layer_shell_types[0])) },
    .{ .name = "destroy", .signature = "", .types = @ptrCast(@constCast(&layer_shell_types[0])) },
    .{ .name = "set_layer", .signature = "2u", .types = @ptrCast(@constCast(&layer_shell_types[0])) },
};

const zwlr_layer_surface_v1_events = [_]c.struct_wl_message{
    .{ .name = "configure", .signature = "uuu", .types = @ptrCast(@constCast(&layer_shell_types[0])) },
    .{ .name = "closed", .signature = "", .types = @ptrCast(@constCast(&layer_shell_types[0])) },
};

pub export const zwlr_layer_surface_v1_interface: c.struct_wl_interface = .{
    .name = "zwlr_layer_surface_v1",
    .version = 4,
    .method_count = 9,
    .methods = &zwlr_layer_surface_v1_requests,
    .event_count = 2,
    .events = &zwlr_layer_surface_v1_events,
};

pub const ZwlrLayerSurfaceV1Listener = extern struct {
    configure: *const fn (?*anyopaque, ?*c.struct_wl_proxy, u32, u32, u32) callconv(.c) void,
    closed: *const fn (?*anyopaque, ?*c.struct_wl_proxy) callconv(.c) void,
};

pub const LAYER_BACKGROUND: u32 = 0;
pub const LAYER_BOTTOM: u32 = 1;
pub const LAYER_TOP: u32 = 2;
pub const LAYER_OVERLAY: u32 = 3;

pub const ANCHOR_TOP: u32 = 1;
pub const ANCHOR_BOTTOM: u32 = 2;
pub const ANCHOR_LEFT: u32 = 4;
pub const ANCHOR_RIGHT: u32 = 8;
pub const ANCHOR_FILL: u32 = ANCHOR_TOP | ANCHOR_BOTTOM | ANCHOR_LEFT | ANCHOR_RIGHT;

pub const KEYBOARD_NONE: u32 = 0;
pub const KEYBOARD_EXCLUSIVE: u32 = 1;
pub const KEYBOARD_ON_DEMAND: u32 = 2;

fn layerShellGetLayerSurface(
    shell: *c.struct_wl_proxy,
    surface: *c.struct_wl_surface,
    output: ?*c.struct_wl_output,
    layer: u32,
    namespace: [*:0]const u8,
) *c.struct_wl_proxy {
    const id = c.wl_proxy_marshal_flags(
        shell,
        0,
        &zwlr_layer_surface_v1_interface,
        c.wl_proxy_get_version(shell),
        0,
        @as(?*anyopaque, null),
        surface,
        output,
        layer,
        namespace,
    );
    return id.?;
}

fn layerSurfaceSetSize(layer_surface: *c.struct_wl_proxy, width: u32, height: u32) void {
    _ = c.wl_proxy_marshal_flags(
        layer_surface,
        0,
        null,
        c.wl_proxy_get_version(layer_surface),
        0,
        width,
        height,
    );
}

fn layerSurfaceSetAnchor(layer_surface: *c.struct_wl_proxy, anchor: u32) void {
    _ = c.wl_proxy_marshal_flags(
        layer_surface,
        1,
        null,
        c.wl_proxy_get_version(layer_surface),
        0,
        anchor,
    );
}

fn layerSurfaceSetExclusiveZone(layer_surface: *c.struct_wl_proxy, zone: i32) void {
    _ = c.wl_proxy_marshal_flags(
        layer_surface,
        2,
        null,
        c.wl_proxy_get_version(layer_surface),
        0,
        zone,
    );
}

fn layerSurfaceSetKeyboardInteractivity(layer_surface: *c.struct_wl_proxy, interactivity: u32) void {
    _ = c.wl_proxy_marshal_flags(
        layer_surface,
        4,
        null,
        c.wl_proxy_get_version(layer_surface),
        0,
        interactivity,
    );
}

fn layerSurfaceAckConfigure(layer_surface: *c.struct_wl_proxy, serial: u32) void {
    _ = c.wl_proxy_marshal_flags(
        layer_surface,
        6,
        null,
        c.wl_proxy_get_version(layer_surface),
        0,
        serial,
    );
}

fn layerSurfaceDestroy(layer_surface: *c.struct_wl_proxy) void {
    _ = c.wl_proxy_marshal_flags(
        layer_surface,
        7,
        null,
        c.wl_proxy_get_version(layer_surface),
        c.WL_MARSHAL_FLAG_DESTROY,
    );
}

fn layerSurfaceAddListener(
    layer_surface: *c.struct_wl_proxy,
    listener: *const ZwlrLayerSurfaceV1Listener,
    data: ?*anyopaque,
) void {
    _ = c.wl_proxy_add_listener(layer_surface, @ptrCast(@constCast(listener)), data);
}

// ============================================================================
// Core Image Type and Dynamic Buffer
// ============================================================================

pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []u32, // ARGB (0xAARRGGBB)

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Image {
        const pixels = try allocator.alloc(u32, width * height);
        return Image{ .width = width, .height = height, .pixels = pixels };
    }

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.pixels = &[_]u32{};
    }
};

pub const ByteBuffer = struct {
    items: []u8 = &[_]u8{},
    capacity: usize = 0,

    pub fn deinit(self: *ByteBuffer, allocator: std.mem.Allocator) void {
        if (self.capacity > 0) allocator.free(self.items.ptr[0..self.capacity]);
        self.* = .{};
    }

    pub fn append(self: *ByteBuffer, allocator: std.mem.Allocator, byte: u8) !void {
        try self.ensureUnusedCapacity(allocator, 1);
        const len = self.items.len;
        const ptr: [*]u8 = @ptrCast(self.items.ptr);
        ptr[len] = byte;
        self.items = ptr[0 .. len + 1];
    }

    pub fn appendSlice(self: *ByteBuffer, allocator: std.mem.Allocator, slice: []const u8) !void {
        try self.ensureUnusedCapacity(allocator, slice.len);
        const len = self.items.len;
        const ptr: [*]u8 = @ptrCast(self.items.ptr);
        @memcpy(ptr[len .. len + slice.len], slice);
        self.items = ptr[0 .. len + slice.len];
    }

    pub fn ensureUnusedCapacity(self: *ByteBuffer, allocator: std.mem.Allocator, extra: usize) !void {
        const needed = self.items.len + extra;
        if (needed <= self.capacity) return;
        var new_cap = if (self.capacity == 0) 1024 else self.capacity * 2;
        while (new_cap < needed) new_cap *= 2;
        const new_mem = try allocator.alloc(u8, new_cap);
        if (self.items.len > 0) {
            @memcpy(new_mem[0..self.items.len], self.items);
        }
        if (self.capacity > 0) allocator.free(self.items.ptr[0..self.capacity]);
        self.items = new_mem[0..self.items.len];
        self.capacity = new_cap;
    }
};

// ============================================================================
// Pure Zig PNG Decoder & Inflate Engine (RFC 1950 / RFC 1951)
// ============================================================================

pub const Inflate = struct {
    src: []const u8,
    pos: usize = 0,
    bit_buf: u64 = 0,
    bits_in_buf: u8 = 0,

    fn ensureBits(self: *Inflate, n: u8) !void {
        while (self.bits_in_buf < n) {
            if (self.pos >= self.src.len) return error.UnexpectedEof;
            self.bit_buf |= @as(u64, self.src[self.pos]) << @intCast(self.bits_in_buf);
            self.pos += 1;
            self.bits_in_buf += 8;
        }
    }

    fn peekBits(self: *Inflate, n: u8) u64 {
        return self.bit_buf & ((@as(u64, 1) << @intCast(n)) - 1);
    }

    fn dropBits(self: *Inflate, n: u8) void {
        self.bit_buf >>= @intCast(n);
        self.bits_in_buf -= n;
    }

    fn readBits(self: *Inflate, n: u8) !u32 {
        if (n == 0) return 0;
        try self.ensureBits(n);
        const val = self.peekBits(n);
        self.dropBits(n);
        return @intCast(val);
    }

    fn alignToByte(self: *Inflate) void {
        const drop: u8 = self.bits_in_buf % 8;
        self.dropBits(drop);
    }

    const Huffman = struct {
        counts: [16]u16 = @splat(0),
        symbols: [320]u16 = @splat(0),
        min_code: [16]u32 = @splat(0),
        max_code: [16]i32 = @splat(-1),
        val_ptr: [16]i32 = @splat(0),

        fn build(self: *Huffman, lengths: []const u8) !void {
            @memset(&self.counts, 0);
            for (lengths) |l| {
                if (l > 15) return error.InvalidHuffmanCode;
                if (l > 0) self.counts[l] += 1;
            }

            var code: u32 = 0;
            var k: usize = 0;
            var next_code: [16]u32 = undefined;
            for (1..16) |bits| {
                code = (code + self.counts[bits - 1]) << 1;
                next_code[bits] = code;
                self.min_code[bits] = code;
                if (self.counts[bits] > 0) {
                    self.max_code[bits] = @intCast(code + self.counts[bits] - 1);
                    self.val_ptr[bits] = @intCast(k);
                    k += self.counts[bits];
                } else {
                    self.max_code[bits] = -1;
                    self.val_ptr[bits] = 0;
                }
            }

            for (lengths, 0..) |l, i| {
                if (l != 0) {
                    const code_val = next_code[l];
                    next_code[l] += 1;
                    const offset = code_val - self.min_code[l];
                    const idx: usize = @intCast(self.val_ptr[l] + @as(i32, @intCast(offset)));
                    if (idx < self.symbols.len) {
                        self.symbols[idx] = @intCast(i);
                    }
                }
            }
        }

        fn decode(self: *const Huffman, inf: *Inflate) !u16 {
            var code: u32 = 0;
            var l: u8 = 1;
            while (l <= 15) : (l += 1) {
                try inf.ensureBits(1);
                const bit = inf.peekBits(1);
                inf.dropBits(1);
                code = (code << 1) | @as(u32, @intCast(bit));
                if (self.max_code[l] >= 0 and code <= @as(u32, @intCast(self.max_code[l]))) {
                    const offset = code - self.min_code[l];
                    const idx: usize = @intCast(self.val_ptr[l] + @as(i32, @intCast(offset)));
                    return self.symbols[idx];
                }
            }
            return error.InvalidHuffmanCode;
        }
    };

    const LENGTH_BASE: [29]u16 = .{
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
        35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
    };
    const LENGTH_EXTRA: [29]u8 = .{
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
    };

    const DIST_BASE: [30]u16 = .{
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
        257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
    };
    const DIST_EXTRA: [30]u8 = .{
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
    };

    const CLEN_ORDER: [19]u8 = .{
        16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
    };

    pub fn decompressZlib(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
        if (src.len < 6) return error.InvalidZlibData;
        const cmf = src[0];
        const flg = src[1];
        if ((@as(u16, cmf) * 256 + flg) % 31 != 0) return error.InvalidZlibHeader;
        if ((cmf & 0x0f) != 8) return error.UnsupportedZlibCompression;
        if ((flg & 0x20) != 0) return error.PresetDictionaryUnsupported;

        var inf = Inflate{ .src = src, .pos = 2 };
        var out = ByteBuffer{};
        errdefer out.deinit(allocator);

        var bfinal: bool = false;
        while (!bfinal) {
            bfinal = (try inf.readBits(1)) == 1;
            const btype = try inf.readBits(2);
            switch (btype) {
                0 => { // Uncompressed
                    inf.alignToByte();
                    const len = try inf.readBits(16);
                    const nlen = try inf.readBits(16);
                    if ((len ^ 0xFFFF) != nlen) return error.InvalidBlockLength;
                    if (inf.pos + len > inf.src.len) return error.UnexpectedEof;
                    try out.appendSlice(allocator, inf.src[inf.pos .. inf.pos + len]);
                    inf.pos += len;
                },
                1 => { // Fixed Huffman
                    var lit_lens: [288]u8 = undefined;
                    for (0..144) |i| lit_lens[i] = 8;
                    for (144..256) |i| lit_lens[i] = 9;
                    for (256..280) |i| lit_lens[i] = 7;
                    for (280..288) |i| lit_lens[i] = 8;
                    var lit_tree = Huffman{};
                    try lit_tree.build(&lit_lens);

                    var dist_lens: [32]u8 = @splat(5);
                    var dist_tree = Huffman{};
                    try dist_tree.build(&dist_lens);

                    try decodeBlock(allocator, &inf, &lit_tree, &dist_tree, &out);
                },
                2 => { // Dynamic Huffman
                    const hlit = (try inf.readBits(5)) + 257;
                    const hdist = (try inf.readBits(5)) + 1;
                    const hclen = (try inf.readBits(4)) + 4;

                    var clen_lens: [19]u8 = @splat(0);
                    for (0..hclen) |i| {
                        clen_lens[CLEN_ORDER[i]] = @intCast(try inf.readBits(3));
                    }
                    var clen_tree = Huffman{};
                    try clen_tree.build(&clen_lens);

                    var lit_dist_lens: [320]u8 = @splat(0);
                    var idx: usize = 0;
                    const total_codes = hlit + hdist;
                    while (idx < total_codes) {
                        const sym = try clen_tree.decode(&inf);
                        if (sym < 16) {
                            lit_dist_lens[idx] = @intCast(sym);
                            idx += 1;
                        } else if (sym == 16) {
                            if (idx == 0) return error.InvalidDynamicCode;
                            const prev = lit_dist_lens[idx - 1];
                            const repeat = (try inf.readBits(2)) + 3;
                            for (0..repeat) |_| {
                                if (idx >= total_codes) return error.InvalidDynamicCode;
                                lit_dist_lens[idx] = prev;
                                idx += 1;
                            }
                        } else if (sym == 17) {
                            const repeat = (try inf.readBits(3)) + 3;
                            for (0..repeat) |_| {
                                if (idx >= total_codes) return error.InvalidDynamicCode;
                                lit_dist_lens[idx] = 0;
                                idx += 1;
                            }
                        } else if (sym == 18) {
                            const repeat = (try inf.readBits(7)) + 11;
                            for (0..repeat) |_| {
                                if (idx >= total_codes) return error.InvalidDynamicCode;
                                lit_dist_lens[idx] = 0;
                                idx += 1;
                            }
                        }
                    }

                    var lit_tree = Huffman{};
                    try lit_tree.build(lit_dist_lens[0..hlit]);

                    var dist_tree = Huffman{};
                    try dist_tree.build(lit_dist_lens[hlit..total_codes]);

                    try decodeBlock(allocator, &inf, &lit_tree, &dist_tree, &out);
                },
                else => return error.InvalidBlockType,
            }
        }
        const result = try allocator.alloc(u8, out.items.len);
        @memcpy(result, out.items);
        out.deinit(allocator);
        return result;
    }

    fn decodeBlock(allocator: std.mem.Allocator, inf: *Inflate, lit_tree: *const Huffman, dist_tree: *const Huffman, out: *ByteBuffer) !void {
        while (true) {
            const sym = try lit_tree.decode(inf);
            if (sym < 256) {
                try out.append(allocator, @intCast(sym));
            } else if (sym == 256) {
                break;
            } else if (sym <= 285) {
                const len_idx = sym - 257;
                const extra_len = try inf.readBits(LENGTH_EXTRA[len_idx]);
                const length: usize = LENGTH_BASE[len_idx] + extra_len;

                const dist_sym = try dist_tree.decode(inf);
                if (dist_sym >= 30) return error.InvalidDistCode;
                const extra_dist = try inf.readBits(DIST_EXTRA[dist_sym]);
                const distance: usize = DIST_BASE[dist_sym] + extra_dist;

                if (distance > out.items.len) return error.InvalidDistance;
                var src_idx = out.items.len - distance;
                for (0..length) |_| {
                    try out.append(allocator, out.items[src_idx]);
                    src_idx += 1;
                }
            } else {
                return error.InvalidLiteralCode;
            }
        }
    }
};

fn paethPredictor(a: u8, b: u8, c_val: u8) u8 {
    const p: i32 = @as(i32, a) + @as(i32, b) - @as(i32, c_val);
    const pa = @abs(p - @as(i32, a));
    const pb = @abs(p - @as(i32, b));
    const pc = @abs(p - @as(i32, c_val));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c_val;
}

pub fn decodePng(allocator: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 8) return error.InvalidPngSignature;
    const sig = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
    if (!std.mem.eql(u8, data[0..8], &sig)) return error.InvalidPngSignature;

    var pos: usize = 8;
    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;
    var compression: u8 = 0;
    var filter_method: u8 = 0;
    var interlace: u8 = 0;

    var idat_chunks = ByteBuffer{};
    defer idat_chunks.deinit(allocator);

    while (pos + 8 <= data.len) {
        const length = std.mem.readInt(u32, data[pos..][0..4], .big);
        pos += 4;
        const chunk_type = data[pos .. pos + 4];
        pos += 4;
        if (pos + length + 4 > data.len) return error.UnexpectedEof;
        const chunk_data = data[pos .. pos + length];
        pos += length + 4; // Skip CRC

        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (length < 13) return error.InvalidIhdr;
            width = std.mem.readInt(u32, chunk_data[0..4], .big);
            height = std.mem.readInt(u32, chunk_data[4..8], .big);
            bit_depth = chunk_data[8];
            color_type = chunk_data[9];
            compression = chunk_data[10];
            filter_method = chunk_data[11];
            interlace = chunk_data[12];
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            try idat_chunks.appendSlice(allocator, chunk_data);
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            break;
        }
    }

    if (width == 0 or height == 0) return error.InvalidDimensions;
    if (bit_depth != 8) return error.UnsupportedBitDepth;
    if (interlace != 0) return error.InterlacedPngUnsupported;
    if (compression != 0 or filter_method != 0) return error.UnsupportedPngMethod;

    const bpp: usize = switch (color_type) {
        0 => 1, // Grayscale
        2 => 3, // RGB
        4 => 2, // Grayscale + Alpha
        6 => 4, // RGBA
        else => return error.UnsupportedColorType,
    };

    const decompressed = try Inflate.decompressZlib(allocator, idat_chunks.items);
    defer allocator.free(decompressed);

    const stride: usize = 1 + width * bpp;
    if (decompressed.len < stride * height) return error.DecompressedDataTooShort;

    const pixels = try allocator.alloc(u32, width * height);
    errdefer allocator.free(pixels);

    const prev_row = try allocator.alloc(u8, width * bpp);
    defer allocator.free(prev_row);
    @memset(prev_row, 0);

    const curr_row = try allocator.alloc(u8, width * bpp);
    defer allocator.free(curr_row);

    var offset: usize = 0;
    for (0..height) |y| {
        const filter = decompressed[offset];
        offset += 1;
        const raw = decompressed[offset .. offset + width * bpp];
        offset += width * bpp;

        for (0..width * bpp) |i| {
            const left: u8 = if (i >= bpp) curr_row[i - bpp] else 0;
            const up: u8 = prev_row[i];
            const up_left: u8 = if (i >= bpp) prev_row[i - bpp] else 0;

            const recon: u8 = switch (filter) {
                0 => raw[i],
                1 => raw[i] +% left,
                2 => raw[i] +% up,
                3 => raw[i] +% @as(u8, @intCast((@as(u16, left) + @as(u16, up)) / 2)),
                4 => raw[i] +% paethPredictor(left, up, up_left),
                else => return error.InvalidFilterType,
            };
            curr_row[i] = recon;
        }

        for (0..width) |x| {
            const px_idx = x * bpp;
            var r: u8 = 0;
            var g: u8 = 0;
            var b: u8 = 0;
            var a: u8 = 255;
            switch (color_type) {
                0 => {
                    r = curr_row[px_idx];
                    g = r;
                    b = r;
                },
                2 => {
                    r = curr_row[px_idx + 0];
                    g = curr_row[px_idx + 1];
                    b = curr_row[px_idx + 2];
                },
                4 => {
                    r = curr_row[px_idx + 0];
                    g = r;
                    b = r;
                    a = curr_row[px_idx + 1];
                },
                6 => {
                    r = curr_row[px_idx + 0];
                    g = curr_row[px_idx + 1];
                    b = curr_row[px_idx + 2];
                    a = curr_row[px_idx + 3];
                },
                else => {},
            }
            pixels[y * width + x] = (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
        }

        @memcpy(prev_row, curr_row);
    }

    return Image{ .width = width, .height = height, .pixels = pixels };
}

// ============================================================================
// Pure Zig Baseline JPEG Decoder
// ============================================================================

const ZIGZAG: [64]u8 = .{
     0,  1,  8, 16,  9,  2,  3, 10,
    17, 24, 32, 25, 18, 11,  4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13,  6,  7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

pub const JpegHuffman = struct {
    counts: [16]u8 = @splat(0),
    symbols: [256]u8 = @splat(0),
    total_symbols: usize = 0,
    min_code: [16]u32 = @splat(0),
    max_code: [16]i32 = @splat(-1),
    val_ptr: [16]i32 = @splat(0),

    pub fn build(self: *JpegHuffman, counts: []const u8, symbols: []const u8) void {
        @memcpy(self.counts[0..16], counts[0..16]);
        @memcpy(self.symbols[0..symbols.len], symbols);
        self.total_symbols = symbols.len;

        var code: u32 = 0;
        var k: usize = 0;
        for (0..16) |i| {
            self.min_code[i] = code;
            if (self.counts[i] > 0) {
                self.max_code[i] = @intCast(code + self.counts[i] - 1);
                self.val_ptr[i] = @intCast(k);
                k += self.counts[i];
            } else {
                self.max_code[i] = -1;
                self.val_ptr[i] = 0;
            }
            code = (code + self.counts[i]) << 1;
        }
    }
};

pub const JpegBitReader = struct {
    data: []const u8,
    pos: usize = 0,
    bit_buf: u64 = 0,
    bits_in_buf: u8 = 0,

    pub fn nextByte(self: *JpegBitReader) !u8 {
        if (self.pos >= self.data.len) return error.UnexpectedEof;
        const b = self.data[self.pos];
        self.pos += 1;
        if (b == 0xFF) {
            if (self.pos >= self.data.len) return error.UnexpectedEof;
            const marker = self.data[self.pos];
            if (marker == 0x00) {
                self.pos += 1;
                return 0xFF;
            } else if (marker >= 0xD0 and marker <= 0xD7) {
                self.pos += 1;
                return self.nextByte();
            } else {
                return error.JpegMarkerInEntropyData;
            }
        }
        return b;
    }

    pub fn ensureBits(self: *JpegBitReader, n: u8) !void {
        while (self.bits_in_buf < n) {
            const b = try self.nextByte();
            self.bit_buf = (self.bit_buf << 8) | @as(u64, b);
            self.bits_in_buf += 8;
        }
    }

    pub fn readBits(self: *JpegBitReader, n: u8) !u32 {
        if (n == 0) return 0;
        try self.ensureBits(n);
        const shift: u6 = @intCast(self.bits_in_buf - n);
        const val: u32 = @intCast((self.bit_buf >> shift) & ((@as(u64, 1) << @intCast(n)) - 1));
        self.bits_in_buf -= n;
        return val;
    }

    pub fn decodeSymbol(self: *JpegBitReader, table: *const JpegHuffman) !u8 {
        var code: u32 = 0;
        for (0..16) |i| {
            try self.ensureBits(1);
            const shift: u6 = @intCast(self.bits_in_buf - 1);
            const bit = (self.bit_buf >> shift) & 1;
            self.bits_in_buf -= 1;
            code = (code << 1) | @as(u32, @intCast(bit));

            if (table.max_code[i] >= 0 and code <= @as(u32, @intCast(table.max_code[i]))) {
                const offset = code - table.min_code[i];
                const idx: usize = @intCast(table.val_ptr[i] + @as(i32, @intCast(offset)));
                if (idx < table.total_symbols) {
                    return table.symbols[idx];
                }
                return error.InvalidHuffmanCode;
            }
        }
        return error.InvalidHuffmanCode;
    }

    pub fn receiveExtend(self: *JpegBitReader, length: u8) !i32 {
        if (length == 0) return 0;
        const v = try self.readBits(length);
        const threshold = @as(u32, 1) << @intCast(length - 1);
        if (v < threshold) {
            const max_val = (@as(u32, 1) << @intCast(length)) - 1;
            return @as(i32, @intCast(v)) - @as(i32, @intCast(max_val));
        }
        return @as(i32, @intCast(v));
    }
};

fn idct1D(x0: f32, x1: f32, x2: f32, x3: f32, x4: f32, x5: f32, x6: f32, x7: f32, out: *[8]f32) void {
    const s = [_]f32{ x0, x1, x2, x3, x4, x5, x6, x7 };
    const inv_sqrt2: f32 = 0.7071067811865475;
    for (0..8) |i| {
        var sum: f32 = 0;
        for (0..8) |j| {
            const c_j: f32 = if (j == 0) inv_sqrt2 else 1.0;
            const angle = (@as(f32, @floatFromInt(2 * i + 1)) * @as(f32, @floatFromInt(j)) * std.math.pi) / 16.0;
            sum += c_j * s[j] * @cos(angle);
        }
        out[i] = sum * 0.5;
    }
}

fn idctBlock(block: *const [64]f32, out: *[64]u8) void {
    var temp: [64]f32 = undefined;
    var row_in: [8]f32 = undefined;
    var row_out: [8]f32 = undefined;

    for (0..8) |r| {
        for (0..8) |c_idx| row_in[c_idx] = block[r * 8 + c_idx];
        idct1D(row_in[0], row_in[1], row_in[2], row_in[3], row_in[4], row_in[5], row_in[6], row_in[7], &row_out);
        for (0..8) |c_idx| temp[r * 8 + c_idx] = row_out[c_idx];
    }

    var col_in: [8]f32 = undefined;
    var col_out: [8]f32 = undefined;
    for (0..8) |c_idx| {
        for (0..8) |r| col_in[r] = temp[r * 8 + c_idx];
        idct1D(col_in[0], col_in[1], col_in[2], col_in[3], col_in[4], col_in[5], col_in[6], col_in[7], &col_out);
        for (0..8) |r| {
            const val = std.math.clamp(col_out[r] + 128.0, 0.0, 255.0);
            out[r * 8 + c_idx] = @intFromFloat(val);
        }
    }
}

const Component = struct {
    id: u8 = 0,
    h: u8 = 1,
    v: u8 = 1,
    q_table_id: u8 = 0,
    dc_table_id: u8 = 0,
    ac_table_id: u8 = 0,
    dc_pred: i32 = 0,
};

pub fn decodeJpeg(allocator: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 4 or data[0] != 0xFF or data[1] != 0xD8) return error.NotAJpeg;

    var pos: usize = 2;
    var q_tables: [4][64]u16 = @splat(@splat(0));
    var dc_tables: [4]JpegHuffman = undefined;
    var ac_tables: [4]JpegHuffman = undefined;
    var components: [4]Component = undefined;
    var num_components: u8 = 0;
    var width: u32 = 0;
    var height: u32 = 0;
    var restart_interval: u16 = 0;
    var sos_pos: usize = 0;

    while (pos + 4 <= data.len) {
        if (data[pos] != 0xFF) {
            pos += 1;
            continue;
        }
        while (pos < data.len and data[pos] == 0xFF) pos += 1;
        if (pos >= data.len) break;
        const marker = data[pos];
        pos += 1;

        if (marker == 0xD9) break; // EOI

        if (marker == 0xDB) { // DQT
            const len = std.mem.readInt(u16, data[pos..][0..2], .big);
            const end = pos + len;
            pos += 2;
            while (pos < end) {
                const info = data[pos];
                pos += 1;
                const table_id = info & 0x0F;
                const precision = info >> 4;
                if (table_id >= 4) return error.InvalidQTableId;
                for (0..64) |i| {
                    if (precision == 0) {
                        q_tables[table_id][i] = data[pos];
                        pos += 1;
                    } else {
                        q_tables[table_id][i] = std.mem.readInt(u16, data[pos..][0..2], .big);
                        pos += 2;
                    }
                }
            }
        } else if (marker == 0xC4) { // DHT
            const len = std.mem.readInt(u16, data[pos..][0..2], .big);
            const end = pos + len;
            pos += 2;
            while (pos < end) {
                const info = data[pos];
                pos += 1;
                const table_class = (info >> 4) & 1; // 0=DC, 1=AC
                const table_id = info & 0x0F;
                if (table_id >= 4) return error.InvalidHuffmanTableId;

                const counts = data[pos .. pos + 16];
                pos += 16;
                var sym_count: usize = 0;
                for (counts) |cnt| sym_count += cnt;
                if (pos + sym_count > data.len) return error.UnexpectedEof;
                const syms = data[pos .. pos + sym_count];
                pos += sym_count;

                if (table_class == 0) {
                    dc_tables[table_id].build(counts, syms);
                } else {
                    ac_tables[table_id].build(counts, syms);
                }
            }
        } else if (marker == 0xC0) { // SOF0 Baseline DCT
            _ = std.mem.readInt(u16, data[pos..][0..2], .big);
            pos += 2;
            const precision = data[pos];
            pos += 1;
            if (precision != 8) return error.UnsupportedJpegPrecision;
            height = std.mem.readInt(u16, data[pos..][0..2], .big);
            pos += 2;
            width = std.mem.readInt(u16, data[pos..][0..2], .big);
            pos += 2;
            num_components = data[pos];
            pos += 1;
            if (num_components != 1 and num_components != 3) return error.UnsupportedComponents;

            for (0..num_components) |i| {
                components[i].id = data[pos];
                pos += 1;
                const sampling = data[pos];
                pos += 1;
                components[i].h = sampling >> 4;
                components[i].v = sampling & 0x0F;
                components[i].q_table_id = data[pos];
                pos += 1;
            }
        } else if (marker == 0xDD) { // DRI
            _ = std.mem.readInt(u16, data[pos..][0..2], .big);
            pos += 2;
            restart_interval = std.mem.readInt(u16, data[pos..][0..2], .big);
            pos += 2;
        } else if (marker == 0xDA) { // SOS
            const len = std.mem.readInt(u16, data[pos..][0..2], .big);
            const sos_start = pos;
            pos += 2;
            const num_sos_comp = data[pos];
            pos += 1;
            for (0..num_sos_comp) |_| {
                const id = data[pos];
                pos += 1;
                const tbl = data[pos];
                pos += 1;
                for (0..num_components) |ci| {
                    if (components[ci].id == id) {
                        components[ci].dc_table_id = (tbl >> 4) & 0x0F;
                        components[ci].ac_table_id = tbl & 0x0F;
                        break;
                    }
                }
            }
            pos = sos_start + len;
            sos_pos = pos;
            break;
        } else {
            if (pos + 2 > data.len) break;
            const len = std.mem.readInt(u16, data[pos..][0..2], .big);
            pos += len;
        }
    }

    if (width == 0 or height == 0 or sos_pos == 0) return error.InvalidJpeg;

    var max_h: u8 = 1;
    var max_v: u8 = 1;
    for (0..num_components) |i| {
        max_h = @max(max_h, components[i].h);
        max_v = @max(max_v, components[i].v);
    }

    const mcu_w = @as(u32, max_h) * 8;
    const mcu_h = @as(u32, max_v) * 8;
    const mcus_x = (width + mcu_w - 1) / mcu_w;
    const mcus_y = (height + mcu_h - 1) / mcu_h;

    var reader = JpegBitReader{ .data = data[sos_pos..] };
    const pixels = try allocator.alloc(u32, width * height);
    errdefer allocator.free(pixels);

    var mcu_y_blocks: [4][64]u8 = undefined;
    var mcu_cb_block: [64]u8 = undefined;
    var mcu_cr_block: [64]u8 = undefined;

    var mcu_count: u32 = 0;

    for (0..mcus_y) |my| {
        for (0..mcus_x) |mx| {
            if (restart_interval > 0 and mcu_count > 0 and (mcu_count % restart_interval) == 0) {
                reader.bits_in_buf = 0;
                for (0..num_components) |ci| {
                    components[ci].dc_pred = 0;
                }
            }
            mcu_count += 1;

            for (0..num_components) |ci| {
                const comp = &components[ci];
                const block_count = @as(usize, comp.h) * comp.v;
                for (0..block_count) |bi| {
                    var block_coeffs: [64]f32 = @splat(0.0);

                    const dc_table = &dc_tables[comp.dc_table_id];
                    const dc_len = try reader.decodeSymbol(dc_table);
                    const dc_diff = try reader.receiveExtend(dc_len);
                    comp.dc_pred += dc_diff;
                    const q_dc = @as(f32, @floatFromInt(q_tables[comp.q_table_id][0]));
                    block_coeffs[0] = @as(f32, @floatFromInt(comp.dc_pred)) * q_dc;

                    const ac_table = &ac_tables[comp.ac_table_id];
                    var k: usize = 1;
                    while (k < 64) {
                        const sym = try reader.decodeSymbol(ac_table);
                        if (sym == 0x00) break;
                        const run = sym >> 4;
                        const ac_len = sym & 0x0F;
                        k += run;
                        if (k >= 64) break;
                        const val = try reader.receiveExtend(ac_len);
                        const q_val = @as(f32, @floatFromInt(q_tables[comp.q_table_id][k]));
                        block_coeffs[ZIGZAG[k]] = @as(f32, @floatFromInt(val)) * q_val;
                        k += 1;
                    }

                    var block_pixels: [64]u8 = undefined;
                    idctBlock(&block_coeffs, &block_pixels);

                    if (ci == 0) {
                        mcu_y_blocks[bi] = block_pixels;
                    } else if (ci == 1) {
                        mcu_cb_block = block_pixels;
                    } else if (ci == 2) {
                        mcu_cr_block = block_pixels;
                    }
                }
            }

            const base_x = mx * mcu_w;
            const base_y = my * mcu_h;

            for (0..mcu_h) |dy| {
                const py = base_y + dy;
                if (py >= height) break;

                for (0..mcu_w) |dx| {
                    const px = base_x + dx;
                    if (px >= width) break;

                    var r: u8 = 0;
                    var g: u8 = 0;
                    var b: u8 = 0;

                    if (num_components == 1) {
                        const y_val = mcu_y_blocks[0][dy * 8 + dx];
                        r = y_val;
                        g = y_val;
                        b = y_val;
                    } else {
                        var y_val: f32 = 0;
                        if (max_h == 2 and max_v == 2) {
                            const sub_x = dx / 8;
                            const sub_y = dy / 8;
                            const block_idx = sub_y * 2 + sub_x;
                            const in_block_x = dx % 8;
                            const in_block_y = dy % 8;
                            y_val = @floatFromInt(mcu_y_blocks[block_idx][in_block_y * 8 + in_block_x]);

                            const chroma_x = dx / 2;
                            const chroma_y = dy / 2;
                            const cb_val: f32 = @floatFromInt(mcu_cb_block[chroma_y * 8 + chroma_x]);
                            const cr_val: f32 = @floatFromInt(mcu_cr_block[chroma_y * 8 + chroma_x]);

                            const rf = y_val + 1.402 * (cr_val - 128.0);
                            const gf = y_val - 0.344136 * (cb_val - 128.0) - 0.714136 * (cr_val - 128.0);
                            const bf = y_val + 1.772 * (cb_val - 128.0);
                            r = @intFromFloat(std.math.clamp(rf, 0.0, 255.0));
                            g = @intFromFloat(std.math.clamp(gf, 0.0, 255.0));
                            b = @intFromFloat(std.math.clamp(bf, 0.0, 255.0));
                        } else if (max_h == 1 and max_v == 1) {
                            y_val = @floatFromInt(mcu_y_blocks[0][dy * 8 + dx]);
                            const cb_val: f32 = @floatFromInt(mcu_cb_block[dy * 8 + dx]);
                            const cr_val: f32 = @floatFromInt(mcu_cr_block[dy * 8 + dx]);

                            const rf = y_val + 1.402 * (cr_val - 128.0);
                            const gf = y_val - 0.344136 * (cb_val - 128.0) - 0.714136 * (cr_val - 128.0);
                            const bf = y_val + 1.772 * (cb_val - 128.0);
                            r = @intFromFloat(std.math.clamp(rf, 0.0, 255.0));
                            g = @intFromFloat(std.math.clamp(gf, 0.0, 255.0));
                            b = @intFromFloat(std.math.clamp(bf, 0.0, 255.0));
                        } else {
                            const y_block_x = (dx * components[0].h) / max_h;
                            const y_block_y = (dy * components[0].v) / max_v;
                            y_val = @floatFromInt(mcu_y_blocks[0][(y_block_y % 8) * 8 + (y_block_x % 8)]);

                            const cb_x = (dx * components[1].h) / max_h;
                            const cb_y = (dy * components[1].v) / max_v;
                            const cb_val: f32 = @floatFromInt(mcu_cb_block[(cb_y % 8) * 8 + (cb_x % 8)]);

                            const cr_x = (dx * components[2].h) / max_h;
                            const cr_y = (dy * components[2].v) / max_v;
                            const cr_val: f32 = @floatFromInt(mcu_cr_block[(cr_y % 8) * 8 + (cr_x % 8)]);

                            const rf = y_val + 1.402 * (cr_val - 128.0);
                            const gf = y_val - 0.344136 * (cb_val - 128.0) - 0.714136 * (cr_val - 128.0);
                            const bf = y_val + 1.772 * (cb_val - 128.0);
                            r = @intFromFloat(std.math.clamp(rf, 0.0, 255.0));
                            g = @intFromFloat(std.math.clamp(gf, 0.0, 255.0));
                            b = @intFromFloat(std.math.clamp(bf, 0.0, 255.0));
                        }
                    }

                    pixels[py * width + px] = 0xFF000000 | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
                }
            }
        }
    }

    return Image{ .width = width, .height = height, .pixels = pixels };
}

// ============================================================================
// Pure Zig QOI and BMP Fallback Decoders
// ============================================================================

pub fn decodeBmp(allocator: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 54 or data[0] != 'B' or data[1] != 'M') return error.NotABmp;
    const pixel_offset = std.mem.readInt(u32, data[10..14], .little);
    const width_i = std.mem.readInt(i32, data[18..22], .little);
    const height_i = std.mem.readInt(i32, data[22..26], .little);
    const bpp = std.mem.readInt(u16, data[28..30], .little);
    if (width_i <= 0 or height_i == 0) return error.InvalidBmpDimensions;

    const width: u32 = @intCast(width_i);
    const height: u32 = @intCast(@abs(height_i));
    const top_down = height_i < 0;

    if (bpp != 24 and bpp != 32) return error.UnsupportedBmpBpp;
    const row_stride = ((width * @as(u32, bpp) + 31) / 32) * 4;
    const pixels = try allocator.alloc(u32, width * height);
    errdefer allocator.free(pixels);

    for (0..height) |y| {
        const src_y = if (top_down) y else height - 1 - y;
        const row_start = pixel_offset + src_y * row_stride;
        if (row_start + width * (bpp / 8) > data.len) return error.UnexpectedEof;

        for (0..width) |x| {
            const px_start = row_start + x * (bpp / 8);
            const b = data[px_start + 0];
            const g = data[px_start + 1];
            const r = data[px_start + 2];
            const a: u8 = if (bpp == 32) data[px_start + 3] else 255;
            pixels[y * width + x] = (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
        }
    }

    return Image{ .width = width, .height = height, .pixels = pixels };
}

pub fn decodeQoi(allocator: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 14 or !std.mem.eql(u8, data[0..4], "qoif")) return error.NotAQoi;
    const width = std.mem.readInt(u32, data[4..8], .big);
    const height = std.mem.readInt(u32, data[8..12], .big);
    const channels = data[12];
    if (channels != 3 and channels != 4) return error.InvalidQoiChannels;

    const pixels = try allocator.alloc(u32, width * height);
    errdefer allocator.free(pixels);

    var index: [64]u32 = @splat(0xFF000000);
    var r: u8 = 0;
    var g: u8 = 0;
    var b: u8 = 0;
    var a: u8 = 255;

    var px_idx: usize = 0;
    const total_pixels = width * height;
    var pos: usize = 14;

    while (pos < data.len - 8 and px_idx < total_pixels) {
        const b1 = data[pos];
        pos += 1;

        if (b1 == 0xFE) { // QOI_OP_RGB
            r = data[pos];
            g = data[pos + 1];
            b = data[pos + 2];
            pos += 3;
        } else if (b1 == 0xFF) { // QOI_OP_RGBA
            r = data[pos];
            g = data[pos + 1];
            b = data[pos + 2];
            a = data[pos + 3];
            pos += 4;
        } else switch (@as(u2, @truncate(b1 >> 6))) {
            0 => { // QOI_OP_INDEX
                const c_val = index[b1 & 0x3F];
                a = @intCast((c_val >> 24) & 0xFF);
                r = @intCast((c_val >> 16) & 0xFF);
                g = @intCast((c_val >> 8) & 0xFF);
                b = @intCast(c_val & 0xFF);
            },
            1 => { // QOI_OP_DIFF
                r +%= (b1 >> 4) & 0x03 -% 2;
                g +%= (b1 >> 2) & 0x03 -% 2;
                b +%= b1 & 0x03 -% 2;
            },
            2 => { // QOI_OP_LUMA
                const b2 = data[pos];
                pos += 1;
                const vg = (b1 & 0x3F) -% 32;
                r +%= vg +% ((b2 >> 4) & 0x0F) -% 8;
                g +%= vg;
                b +%= vg +% (b2 & 0x0F) -% 8;
            },
            3 => { // QOI_OP_RUN
                const run = (b1 & 0x3F) + 1;
                const cur_val = (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
                for (0..run) |_| {
                    if (px_idx < total_pixels) {
                        pixels[px_idx] = cur_val;
                        px_idx += 1;
                    }
                }
                continue;
            },
        }

        const color_val = (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
        const idx = ((@as(usize, r) * 3 + @as(usize, g) * 5 + @as(usize, b) * 7 + @as(usize, a) * 11) % 64);
        index[idx] = color_val;
        pixels[px_idx] = color_val;
        px_idx += 1;
    }

    return Image{ .width = width, .height = height, .pixels = pixels };
}

// ============================================================================
// Universal Image Loader & Rescaling
// ============================================================================

pub fn loadFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var path_buf: [1024]u8 = undefined;
    if (path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const fd = c.open(@ptrCast(&path_buf), c.O_RDONLY);
    if (fd < 0) return error.FileNotFound;
    defer _ = c.close(fd);

    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0) return error.StatFailed;
    const file_size: usize = @intCast(stat.st_size);

    const data = try allocator.alloc(u8, file_size);
    errdefer allocator.free(data);

    var total: usize = 0;
    while (total < file_size) {
        const n = c.read(fd, data.ptr + total, file_size - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    return data;
}

pub fn decodeImage(allocator: std.mem.Allocator, data: []const u8) !Image {
    if (data.len >= 8 and std.mem.eql(u8, data[0..8], &[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A })) {
        return decodePng(allocator, data);
    }
    if (data.len >= 2 and data[0] == 0xFF and data[1] == 0xD8) {
        return decodeJpeg(allocator, data);
    }
    if (data.len >= 2 and data[0] == 'B' and data[1] == 'M') {
        return decodeBmp(allocator, data);
    }
    if (data.len >= 4 and std.mem.eql(u8, data[0..4], "qoif")) {
        return decodeQoi(allocator, data);
    }
    return error.UnsupportedImageFormat;
}

pub fn decodeImageFile(allocator: std.mem.Allocator, path: []const u8) !Image {
    const data = try loadFile(allocator, path);
    defer allocator.free(data);
    return decodeImage(allocator, data);
}

/// Area-averaging / box downsampler for producing razor-sharp, anti-aliased thumbnails
pub fn downsample(src: *const Image, dst_w: u32, dst_h: u32, dst_pixels: []u32) void {
    const src_w = src.width;
    const src_h = src.height;

    for (0..dst_h) |dy| {
        const y0: u32 = @intCast((dy * src_h) / dst_h);
        const y1: u32 = @intCast(@max(y0 + 1, ((dy + 1) * src_h) / dst_h));

        for (0..dst_w) |dx| {
            const x0: u32 = @intCast((dx * src_w) / dst_w);
            const x1: u32 = @intCast(@max(x0 + 1, ((dx + 1) * src_w) / dst_w));

            var sum_r: u64 = 0;
            var sum_g: u64 = 0;
            var sum_b: u64 = 0;
            var sum_a: u64 = 0;
            var count: u64 = 0;

            for (y0..y1) |sy| {
                if (sy >= src_h) break;
                const row = sy * src_w;
                for (x0..x1) |sx| {
                    if (sx >= src_w) break;
                    const p = src.pixels[row + sx];
                    sum_a += (p >> 24) & 0xFF;
                    sum_r += (p >> 16) & 0xFF;
                    sum_g += (p >> 8) & 0xFF;
                    sum_b += p & 0xFF;
                    count += 1;
                }
            }

            if (count > 0) {
                const a: u32 = @intCast(sum_a / count);
                const r: u32 = @intCast(sum_r / count);
                const g: u32 = @intCast(sum_g / count);
                const b: u32 = @intCast(sum_b / count);
                dst_pixels[dy * dst_w + dx] = (a << 24) | (r << 16) | (g << 8) | b;
            } else {
                dst_pixels[dy * dst_w + dx] = 0xFF000000;
            }
        }
    }
}

/// Aspect-fill scaling: scale image to completely cover dst_w x dst_h, centered crop
pub fn scaleAspectFill(src: *const Image, dst_w: u32, dst_h: u32, dst_pixels: []u32) void {
    if (src.width == 0 or src.height == 0 or dst_w == 0 or dst_h == 0) return;

    // Scale factor = max(dst_w / src_w, dst_h / src_h)
    const scale_x = @as(f64, @floatFromInt(dst_w)) / @as(f64, @floatFromInt(src.width));
    const scale_y = @as(f64, @floatFromInt(dst_h)) / @as(f64, @floatFromInt(src.height));
    const scale = @max(scale_x, scale_y);

    const visible_src_w = @as(f64, @floatFromInt(dst_w)) / scale;
    const visible_src_h = @as(f64, @floatFromInt(dst_h)) / scale;

    const offset_x = (@as(f64, @floatFromInt(src.width)) - visible_src_w) * 0.5;
    const offset_y = (@as(f64, @floatFromInt(src.height)) - visible_src_h) * 0.5;

    for (0..dst_h) |dy| {
        const sy = offset_y + (@as(f64, @floatFromInt(dy)) / scale);
        const iy: usize = @intCast(std.math.clamp(@as(i64, @intFromFloat(sy)), 0, @as(i64, @intCast(src.height - 1))));

        for (0..dst_w) |dx| {
            const sx = offset_x + (@as(f64, @floatFromInt(dx)) / scale);
            const ix: usize = @intCast(std.math.clamp(@as(i64, @intFromFloat(sx)), 0, @as(i64, @intCast(src.width - 1))));

            dst_pixels[dy * dst_w + dx] = src.pixels[iy * src.width + ix];
        }
    }
}

// ============================================================================
// Thumbnail Cache System
// ============================================================================

const THUMB_MAGIC: u32 = 0x4D5A5448; // "MZTH"
pub const THUMB_WIDTH: u32 = 400;
pub const THUMB_HEIGHT: u32 = 225; // ~16:9

pub const WallpaperEntry = struct {
    path: []const u8,
    filename: []const u8,
    mtime: i64,
    thumbnail: ?Image = null,
};

fn getFileMtime(path: []const u8) i64 {
    var path_buf: [1024]u8 = undefined;
    if (path.len >= path_buf.len) return 0;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    var stat: c.struct_stat = undefined;
    if (c.stat(@ptrCast(&path_buf), &stat) != 0) return 0;
    return @intCast(stat.st_mtim.tv_sec);
}

fn getCacheDir(buf: *[512]u8) []const u8 {
    const home = getEnvHome();
    const str = std.fmt.bufPrint(buf, "{s}/.cache/mizu/wallpaper_thumbs", .{home}) catch "/tmp/mizu_thumbs";
    var c_path: [512]u8 = undefined;
    @memcpy(c_path[0..str.len], str);
    c_path[str.len] = 0;
    _ = c.mkdir("/home", 0o755);
    _ = c.mkdir(@ptrCast(&c_path), 0o755);
    return str;
}

fn getCachePath(buf: *[1024]u8, filename: []const u8) []const u8 {
    var dir_buf: [512]u8 = undefined;
    const cache_dir = getCacheDir(&dir_buf);
    return std.fmt.bufPrint(buf, "{s}/{s}.thumb", .{ cache_dir, filename }) catch "";
}

pub fn loadCachedThumbnail(allocator: std.mem.Allocator, filename: []const u8, mtime: i64) ?Image {
    var path_buf: [1024]u8 = undefined;
    const cache_path = getCachePath(&path_buf, filename);
    if (cache_path.len == 0) return null;

    const data = loadFile(allocator, cache_path) catch return null;
    defer allocator.free(data);

    if (data.len < 20) return null;
    const magic = std.mem.readInt(u32, data[0..4], .little);
    if (magic != THUMB_MAGIC) return null;

    const cached_mtime = std.mem.readInt(i64, data[4..12], .little);
    if (cached_mtime != mtime) return null;

    const w = std.mem.readInt(u32, data[12..16], .little);
    const h = std.mem.readInt(u32, data[16..20], .little);
    if (w != THUMB_WIDTH or h != THUMB_HEIGHT) return null;

    const expected_bytes = 20 + @as(usize, w) * h * 4;
    if (data.len < expected_bytes) return null;

    const img = Image.init(allocator, w, h) catch return null;
    const raw_pixels: [*]const u32 = @ptrCast(@alignCast(data.ptr + 20));
    @memcpy(img.pixels, raw_pixels[0 .. w * h]);
    return img;
}

pub fn saveCachedThumbnail(filename: []const u8, mtime: i64, thumb: *const Image) void {
    var path_buf: [1024]u8 = undefined;
    const cache_path = getCachePath(&path_buf, filename);
    if (cache_path.len == 0) return;

    var c_path: [1024]u8 = undefined;
    @memcpy(c_path[0..cache_path.len], cache_path);
    c_path[cache_path.len] = 0;

    const fd = c.open(@ptrCast(&c_path), c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o644));
    if (fd < 0) return;
    defer _ = c.close(fd);

    var header: [20]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], THUMB_MAGIC, .little);
    std.mem.writeInt(i64, header[4..12], mtime, .little);
    std.mem.writeInt(u32, header[12..16], thumb.width, .little);
    std.mem.writeInt(u32, header[16..20], thumb.height, .little);

    _ = c.write(fd, &header, 20);
    const pixel_bytes: [*]const u8 = @ptrCast(thumb.pixels.ptr);
    const total_bytes = thumb.width * thumb.height * 4;
    _ = c.write(fd, pixel_bytes, total_bytes);
}

// ============================================================================
// Directory Scanner & Active State
// ============================================================================

pub fn SimpleList(comptime T: type) type {
    return struct {
        items: []T = &[_]T{},
        capacity: usize = 0,

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            if (self.capacity > 0) allocator.free(self.items.ptr[0..self.capacity]);
            self.* = .{};
        }

        pub fn append(self: *@This(), allocator: std.mem.Allocator, item: T) !void {
            if (self.items.len + 1 > self.capacity) {
                const new_cap = if (self.capacity == 0) 16 else self.capacity * 2;
                const new_mem = try allocator.alloc(T, new_cap);
                if (self.items.len > 0) {
                    @memcpy(new_mem[0..self.items.len], self.items);
                }
                if (self.capacity > 0) allocator.free(self.items.ptr[0..self.capacity]);
                self.items = new_mem[0..self.items.len];
                self.capacity = new_cap;
            }
            const ptr: [*]T = @ptrCast(self.items.ptr);
            ptr[self.items.len] = item;
            self.items = ptr[0 .. self.items.len + 1];
        }

        pub fn toOwnedSlice(self: *@This(), allocator: std.mem.Allocator) ![]T {
            const res = try allocator.alloc(T, self.items.len);
            @memcpy(res, self.items);
            self.deinit(allocator);
            return res;
        }
    };
}

pub fn scanWallpapers(allocator: std.mem.Allocator) ![]WallpaperEntry {
    const home = getEnvHome();
    var dir_path_buf: [512]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&dir_path_buf, "{s}/Pictures/Wallpapers", .{home}) catch return error.PathTooLong;

    var c_dir: [512]u8 = undefined;
    @memcpy(c_dir[0..dir_path.len], dir_path);
    c_dir[dir_path.len] = 0;

    const dir = c.opendir(@ptrCast(&c_dir));
    if (dir == null) {
        // If directory doesn't exist, try creating it and return empty list
        _ = c.mkdir(@ptrCast(&c_dir), 0o755);
        return &[_]WallpaperEntry{};
    }
    defer _ = c.closedir(dir);

    var list = SimpleList(WallpaperEntry){};
    errdefer list.deinit(allocator);

    while (true) {
        const ent = c.readdir(dir);
        if (ent == null) break;
        const name_len = std.mem.len(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (name_len == 0) continue;
        const name = ent.*.d_name[0..name_len];
        if (std.mem.startsWith(u8, name, ".")) continue;

        // Check image extension
        const is_img = std.mem.endsWith(u8, name, ".jpg") or
            std.mem.endsWith(u8, name, ".jpeg") or
            std.mem.endsWith(u8, name, ".png") or
            std.mem.endsWith(u8, name, ".bmp") or
            std.mem.endsWith(u8, name, ".qoi");
        if (!is_img) continue;

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, name });
        const mtime = getFileMtime(full_path);
        const name_copy = try allocator.dupe(u8, name);

        try list.append(allocator, WallpaperEntry{
            .path = full_path,
            .filename = name_copy,
            .mtime = mtime,
            .thumbnail = null,
        });
    }

    // Sort alphabetically by filename
    const items = list.items;
    for (0..items.len) |i| {
        for (i + 1..items.len) |j| {
            if (std.mem.order(u8, items[i].filename, items[j].filename) == .gt) {
                const tmp = items[i];
                items[i] = items[j];
                items[j] = tmp;
            }
        }
    }

    return list.toOwnedSlice(allocator);
}

pub fn getActiveWallpaperPath(allocator: std.mem.Allocator) ?[]const u8 {
    const home = getEnvHome();
    var path_buf: [512]u8 = undefined;
    const state_path = std.fmt.bufPrint(&path_buf, "{s}/.cache/mizu/wallpaper", .{home}) catch return null;

    const data = loadFile(allocator, state_path) catch return null;
    defer allocator.free(data);

    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    if (trimmed.len == 0) return null;
    return allocator.dupe(u8, trimmed) catch null;
}

pub fn saveActiveWallpaperPath(path: []const u8) void {
    const home = getEnvHome();

    var buf1: [512]u8 = undefined;
    const p1 = std.fmt.bufPrint(&buf1, "{s}/.cache/mizu", .{home}) catch return;
    var c_p1: [512]u8 = undefined;
    @memcpy(c_p1[0..p1.len], p1);
    c_p1[p1.len] = 0;
    _ = c.mkdir(@ptrCast(&c_p1), 0o755);

    var file1: [512]u8 = undefined;
    const f1 = std.fmt.bufPrint(&file1, "{s}/.cache/mizu/wallpaper", .{home}) catch return;
    writeFileAtomic(f1, path);

    var buf2: [512]u8 = undefined;
    const p2 = std.fmt.bufPrint(&buf2, "{s}/.config/mizu", .{home}) catch return;
    var c_p2: [512]u8 = undefined;
    @memcpy(c_p2[0..p2.len], p2);
    c_p2[p2.len] = 0;
    _ = c.mkdir(@ptrCast(&c_p2), 0o755);

    var file2: [512]u8 = undefined;
    const f2 = std.fmt.bufPrint(&file2, "{s}/.config/mizu/wallpaper", .{home}) catch return;
    writeFileAtomic(f2, path);
}

fn writeFileAtomic(target_path: []const u8, content: []const u8) void {
    var c_path: [512]u8 = undefined;
    if (target_path.len >= c_path.len) return;
    @memcpy(c_path[0..target_path.len], target_path);
    c_path[target_path.len] = 0;

    const fd = c.open(@ptrCast(&c_path), c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o644));
    if (fd < 0) return;
    defer _ = c.close(fd);
    _ = c.write(fd, content.ptr, content.len);
    _ = c.write(fd, "\n", 1);
}

// ============================================================================
// Wayland Client & Shared Memory Buffer Helpers
// ============================================================================

pub const ShmBuffer = struct {
    buffer: *c.struct_wl_buffer,
    data: []u32,
    size: usize,
    width: u32,
    height: u32,

    pub fn create(shm: *c.struct_wl_shm, width: u32, height: u32) !ShmBuffer {
        const stride = width * 4;
        const size = stride * height;

        const fd = memfd_create("mizu-wallpaper-shm", MFD_CLOEXEC);
        if (fd < 0) return error.MemfdFailed;
        defer _ = c.close(fd);

        if (c.ftruncate(fd, @intCast(size)) < 0) return error.TruncateFailed;

        const mmap_ptr = c.mmap(null, size, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
        if (mmap_ptr == c.MAP_FAILED) return error.MmapFailed;

        const pool = c.wl_shm_create_pool(shm, fd, @intCast(size)) orelse return error.ShmPoolFailed;
        defer c.wl_shm_pool_destroy(pool);

        const buffer = c.wl_shm_pool_create_buffer(
            pool,
            0,
            @intCast(width),
            @intCast(height),
            @intCast(stride),
            c.WL_SHM_FORMAT_ARGB8888,
        ) orelse return error.CreateBufferFailed;

        const pixels: [*]u32 = @ptrCast(@alignCast(mmap_ptr));
        return ShmBuffer{
            .buffer = buffer,
            .data = pixels[0 .. width * height],
            .size = size,
            .width = width,
            .height = height,
        };
    }

    pub fn destroy(self: *ShmBuffer) void {
        c.wl_buffer_destroy(self.buffer);
        _ = c.munmap(self.data.ptr, self.size);
    }
};

// ============================================================================
// Wallpaper Setter Mode (Background Layer Surface)
// ============================================================================

extern fn malloc_trim(pad: usize) c_int;

fn trimMemory() void {
    _ = malloc_trim(0);
}

pub const WallpaperSetter = struct {
    allocator: std.mem.Allocator,
    display: *c.struct_wl_display,
    compositor: ?*c.struct_wl_compositor = null,
    shm: ?*c.struct_wl_shm = null,
    layer_shell: ?*c.struct_wl_proxy = null,

    surface: ?*c.struct_wl_surface = null,
    layer_surface: ?*c.struct_wl_proxy = null,
    shm_buffer: ?ShmBuffer = null,

    wallpaper_path: []const u8,
    image: ?Image = null,
    screen_width: u32 = 0,
    screen_height: u32 = 0,
    configured: bool = false,
    running: bool = true,

    pub fn init(allocator: std.mem.Allocator, wallpaper_path: []const u8) !*WallpaperSetter {
        const path_copy = try allocator.dupe(u8, wallpaper_path);
        errdefer allocator.free(path_copy);

        const self = try allocator.create(WallpaperSetter);
        self.* = .{
            .allocator = allocator,
            .display = c.wl_display_connect(null) orelse {
                allocator.free(path_copy);
                return error.WaylandConnectFailed;
            },
            .wallpaper_path = path_copy,
        };

        const registry = c.wl_display_get_registry(self.display) orelse return error.WaylandRegistryFailed;
        defer c.wl_registry_destroy(registry);

        const registry_listener = c.struct_wl_registry_listener{
            .global = registryHandleGlobal,
            .global_remove = registryHandleGlobalRemove,
        };
        _ = c.wl_registry_add_listener(registry, &registry_listener, self);

        _ = c.wl_display_roundtrip(self.display);
        if (self.compositor == null or self.shm == null or self.layer_shell == null) {
            return error.MissingRequiredProtocols;
        }

        // Create surface & layer surface
        self.surface = c.wl_compositor_create_surface(self.compositor.?) orelse return error.CreateSurfaceFailed;
        self.layer_surface = layerShellGetLayerSurface(
            self.layer_shell.?,
            self.surface.?,
            null,
            LAYER_BACKGROUND,
            "mizu-wallpaper-bg",
        );

        layerSurfaceSetSize(self.layer_surface.?, 0, 0);
        layerSurfaceSetAnchor(self.layer_surface.?, ANCHOR_FILL);
        layerSurfaceSetExclusiveZone(self.layer_surface.?, -1);
        layerSurfaceSetKeyboardInteractivity(self.layer_surface.?, KEYBOARD_NONE);

        const listener = ZwlrLayerSurfaceV1Listener{
            .configure = setterHandleConfigure,
            .closed = setterHandleClosed,
        };
        layerSurfaceAddListener(self.layer_surface.?, &listener, self);

        c.wl_surface_commit(self.surface.?);
        _ = c.wl_display_roundtrip(self.display);

        saveActiveWallpaperPath(wallpaper_path);
        return self;
    }

    pub fn render(self: *WallpaperSetter) void {
        if (!self.configured or self.screen_width == 0 or self.screen_height == 0) return;

        var img = decodeImageFile(self.allocator, self.wallpaper_path) catch |err| {
            std.debug.print("Error decoding wallpaper '{s}': {s}\n", .{ self.wallpaper_path, @errorName(err) });
            return;
        };
        defer {
            img.deinit(self.allocator);
            trimMemory();
        }

        if (self.shm_buffer) |*buf| {
            if (buf.width != self.screen_width or buf.height != self.screen_height) {
                buf.destroy();
                self.shm_buffer = null;
            }
        }

        if (self.shm_buffer == null) {
            self.shm_buffer = ShmBuffer.create(self.shm.?, self.screen_width, self.screen_height) catch return;
        }

        const buf = &self.shm_buffer.?;
        scaleAspectFill(&img, self.screen_width, self.screen_height, buf.data);

        c.wl_surface_attach(self.surface.?, buf.buffer, 0, 0);
        c.wl_surface_damage_buffer(self.surface.?, 0, 0, @intCast(self.screen_width), @intCast(self.screen_height));
        c.wl_surface_commit(self.surface.?);
        _ = c.wl_display_flush(self.display);
    }

    pub fn run(self: *WallpaperSetter, once: bool) void {
        while (self.running) {
            if (c.wl_display_dispatch(self.display) < 0) break;
            if (once and self.configured) {
                _ = c.wl_display_roundtrip(self.display);
                break;
            }
        }
    }

    pub fn deinit(self: *WallpaperSetter) void {
        if (self.shm_buffer) |*buf| buf.destroy();
        if (self.image) |*img| img.deinit(self.allocator);
        self.allocator.free(self.wallpaper_path);
        if (self.layer_surface) |ls| layerSurfaceDestroy(ls);
        if (self.surface) |s| c.wl_surface_destroy(s);
        c.wl_display_disconnect(self.display);
        self.allocator.destroy(self);
        trimMemory();
    }

    fn registryHandleGlobal(data: ?*anyopaque, registry: ?*c.struct_wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
        const self: *WallpaperSetter = @ptrCast(@alignCast(data));
        const iface = std.mem.span(interface);

        if (std.mem.eql(u8, iface, "wl_compositor")) {
            self.compositor = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_compositor_interface, @min(version, 4)));
        } else if (std.mem.eql(u8, iface, "wl_shm")) {
            self.shm = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_shm_interface, 1));
        } else if (std.mem.eql(u8, iface, "zwlr_layer_shell_v1")) {
            self.layer_shell = @ptrCast(c.wl_registry_bind(registry, name, &zwlr_layer_shell_v1_interface, @min(version, 4)));
        }
    }

    fn registryHandleGlobalRemove(data: ?*anyopaque, registry: ?*c.struct_wl_registry, name: u32) callconv(.c) void {
        _ = data;
        _ = registry;
        _ = name;
    }

    fn setterHandleConfigure(data: ?*anyopaque, layer_surface: ?*c.struct_wl_proxy, serial: u32, width: u32, height: u32) callconv(.c) void {
        const self: *WallpaperSetter = @ptrCast(@alignCast(data));
        layerSurfaceAckConfigure(layer_surface.?, serial);
        self.screen_width = width;
        self.screen_height = height;
        self.configured = true;
        self.render();
    }

    fn setterHandleClosed(data: ?*anyopaque, layer_surface: ?*c.struct_wl_proxy) callconv(.c) void {
        _ = layer_surface;
        const self: *WallpaperSetter = @ptrCast(@alignCast(data));
        self.running = false;
    }
};

// ============================================================================
// Wallpaper Switcher UI (Minimal, Modern Fullscreen Thumbnail Grid Overlay)
// ============================================================================

pub const WallpaperSwitcher = struct {
    allocator: std.mem.Allocator,
    display: *c.struct_wl_display,
    compositor: ?*c.struct_wl_compositor = null,
    shm: ?*c.struct_wl_shm = null,
    seat: ?*c.struct_wl_seat = null,
    keyboard: ?*c.struct_wl_keyboard = null,
    pointer: ?*c.struct_wl_pointer = null,
    layer_shell: ?*c.struct_wl_proxy = null,

    surface: ?*c.struct_wl_surface = null,
    layer_surface: ?*c.struct_wl_proxy = null,
    shm_buffer: ?ShmBuffer = null,

    wallpapers: []WallpaperEntry,
    active_path: ?[]const u8 = null,
    selected_index: usize = 0,
    active_index: ?usize = null,

    screen_width: u32 = 0,
    screen_height: u32 = 0,
    configured: bool = false,
    running: bool = true,
    applied: bool = false,

    // Layout metrics (3 rows and 4 columns)
    cols: usize = 4,
    rows: usize = 3,
    card_w: u32 = 380,
    card_h: u32 = 214,
    gap: u32 = 24,
    grid_x: u32 = 0,
    grid_y: u32 = 0,
    scroll_row: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !*WallpaperSwitcher {
        const self = try allocator.create(WallpaperSwitcher);
        self.* = .{
            .allocator = allocator,
            .display = c.wl_display_connect(null) orelse return error.WaylandConnectFailed,
            .wallpapers = try scanWallpapers(allocator),
            .active_path = getActiveWallpaperPath(allocator),
        };

        // Determine currently active wallpaper index
        if (self.active_path) |active| {
            for (self.wallpapers, 0..) |w, i| {
                if (std.mem.eql(u8, w.path, active)) {
                    self.active_index = i;
                    self.selected_index = i;
                    break;
                }
            }
        }

        const registry = c.wl_display_get_registry(self.display) orelse return error.WaylandRegistryFailed;
        defer c.wl_registry_destroy(registry);

        const registry_listener = c.struct_wl_registry_listener{
            .global = switcherHandleGlobal,
            .global_remove = switcherHandleGlobalRemove,
        };
        _ = c.wl_registry_add_listener(registry, &registry_listener, self);

        _ = c.wl_display_roundtrip(self.display);
        if (self.compositor == null or self.shm == null or self.layer_shell == null) {
            return error.MissingRequiredProtocols;
        }

        // Preload thumbnails
        self.loadThumbnails();

        // Create overlay layer surface
        self.surface = c.wl_compositor_create_surface(self.compositor.?);
        self.layer_surface = layerShellGetLayerSurface(
            self.layer_shell.?,
            self.surface.?,
            null,
            LAYER_OVERLAY,
            "mizu-wallpaper-switcher",
        );

        layerSurfaceSetSize(self.layer_surface.?, 0, 0);
        layerSurfaceSetAnchor(self.layer_surface.?, ANCHOR_FILL);
        layerSurfaceSetExclusiveZone(self.layer_surface.?, -1);
        layerSurfaceSetKeyboardInteractivity(self.layer_surface.?, KEYBOARD_EXCLUSIVE);

        const listener = ZwlrLayerSurfaceV1Listener{
            .configure = switcherHandleConfigure,
            .closed = switcherHandleClosed,
        };
        layerSurfaceAddListener(self.layer_surface.?, &listener, self);

        c.wl_surface_commit(self.surface.?);
        _ = c.wl_display_roundtrip(self.display);

        return self;
    }

    fn loadThumbnails(self: *WallpaperSwitcher) void {
        for (self.wallpapers) |*w| {
            // Check cache
            if (loadCachedThumbnail(self.allocator, w.filename, w.mtime)) |thumb| {
                w.thumbnail = thumb;
                continue;
            }

            // Decode and downsample
            if (decodeImageFile(self.allocator, w.path)) |full_img| {
                var mut_img = full_img;
                defer mut_img.deinit(self.allocator);

                if (Image.init(self.allocator, THUMB_WIDTH, THUMB_HEIGHT)) |thumb| {
                    var mut_thumb = thumb;
                    downsample(&mut_img, THUMB_WIDTH, THUMB_HEIGHT, mut_thumb.pixels);
                    saveCachedThumbnail(w.filename, w.mtime, &mut_thumb);
                    w.thumbnail = mut_thumb;
                } else |_| {}
            } else |_| {}
        }
    }

    fn updateLayout(self: *WallpaperSwitcher) void {
        if (self.screen_width == 0 or self.screen_height == 0) return;

        self.cols = 4;
        self.rows = 3;

        if (self.screen_width >= 2560 and self.screen_height >= 1440) {
            self.card_w = 480;
            self.card_h = 270;
            self.gap = 32;
        } else if (self.screen_width >= 1920 and self.screen_height >= 1080) {
            self.card_w = 380;
            self.card_h = 214;
            self.gap = 24;
        } else if (self.screen_width >= 1440) {
            self.card_w = 300;
            self.card_h = 169;
            self.gap = 20;
        } else {
            self.card_w = 260;
            self.card_h = 146;
            self.gap = 16;
        }

        const total_grid_w = @as(u32, @intCast(self.cols)) * self.card_w + @as(u32, @intCast(self.cols - 1)) * self.gap;
        const total_grid_h = @as(u32, @intCast(self.rows)) * self.card_h + @as(u32, @intCast(self.rows - 1)) * self.gap;

        self.grid_x = if (self.screen_width > total_grid_w) (self.screen_width - total_grid_w) / 2 else 0;
        self.grid_y = if (self.screen_height > total_grid_h) (self.screen_height - total_grid_h) / 2 else 0;

        // Keep selected in scroll view
        const sel_row = self.selected_index / self.cols;
        if (sel_row < self.scroll_row) {
            self.scroll_row = sel_row;
        } else if (sel_row >= self.scroll_row + self.rows) {
            self.scroll_row = sel_row - self.rows + 1;
        }
    }

    pub fn render(self: *WallpaperSwitcher) void {
        if (!self.configured or self.screen_width == 0 or self.screen_height == 0) return;

        self.updateLayout();

        if (self.shm_buffer) |*buf| {
            if (buf.width != self.screen_width or buf.height != self.screen_height) {
                buf.destroy();
                self.shm_buffer = null;
            }
        }

        if (self.shm_buffer == null) {
            self.shm_buffer = ShmBuffer.create(self.shm.?, self.screen_width, self.screen_height) catch return;
        }

        const buf = &self.shm_buffer.?;
        const pixels = buf.data;

        // 1. Render dark frosted backdrop (92% opacity dark slate glass)
        const bg_color: u32 = 0xEB0D0F18;
        @memset(pixels, bg_color);

        if (self.wallpapers.len == 0) {
            // Draw clean subtle empty state notice if no wallpapers exist
            drawEmptyState(pixels, self.screen_width, self.screen_height);
            c.wl_surface_attach(self.surface.?, buf.buffer, 0, 0);
            c.wl_surface_damage_buffer(self.surface.?, 0, 0, @intCast(self.screen_width), @intCast(self.screen_height));
            c.wl_surface_commit(self.surface.?);
            _ = c.wl_display_flush(self.display);
            return;
        }

        // 2. Render thumbnail cards
        const start_idx = self.scroll_row * self.cols;
        const visible_count = self.rows * self.cols;
        const radius: u32 = 14;

        for (0..visible_count) |slot| {
            const idx = start_idx + slot;
            if (idx >= self.wallpapers.len) break;

            const c_col = slot % self.cols;
            const c_row = slot / self.cols;

            const cx = self.grid_x + @as(u32, @intCast(c_col)) * (self.card_w + self.gap);
            const cy = self.grid_y + @as(u32, @intCast(c_row)) * (self.card_h + self.gap);

            const is_selected = (idx == self.selected_index);
            const is_active = (self.active_index != null and idx == self.active_index.?);

            // Draw card shadow / glow if selected
            if (is_selected) {
                drawRoundedCardGlow(pixels, self.screen_width, self.screen_height, cx, cy, self.card_w, self.card_h, radius, 0xFF38BDF8);
            }

            // Draw thumbnail image with rounded corners
            const entry = &self.wallpapers[idx];
            if (entry.thumbnail) |*thumb| {
                drawRoundedThumbnail(pixels, self.screen_width, self.screen_height, cx, cy, self.card_w, self.card_h, radius, thumb);
            } else {
                drawRoundedRect(pixels, self.screen_width, self.screen_height, cx, cy, self.card_w, self.card_h, radius, 0xFF1E202E);
            }

            // Draw card border
            if (is_selected) {
                // Accent border (3px thick)
                drawRoundedBorder(pixels, self.screen_width, self.screen_height, cx, cy, self.card_w, self.card_h, radius, 3, 0xFF38BDF8);
            } else {
                // Subtle clean frame border (1px)
                drawRoundedBorder(pixels, self.screen_width, self.screen_height, cx, cy, self.card_w, self.card_h, radius, 1, 0x4DFFFFFF);
            }

            // Draw active badge (checkmark indicator) in top-right
            if (is_active) {
                drawActiveBadge(pixels, self.screen_width, self.screen_height, cx + self.card_w - 28, cy + 12);
            }
        }

        c.wl_surface_attach(self.surface.?, buf.buffer, 0, 0);
        c.wl_surface_damage_buffer(self.surface.?, 0, 0, @intCast(self.screen_width), @intCast(self.screen_height));
        c.wl_surface_commit(self.surface.?);
        _ = c.wl_display_flush(self.display);
    }

    pub fn applySelected(self: *WallpaperSwitcher) void {
        if (self.wallpapers.len == 0) return;
        const selected = &self.wallpapers[self.selected_index];
        _ = runSetter(self.allocator, selected.path);
        self.active_index = self.selected_index;
        self.applied = true;
        self.running = false;
    }

    pub fn selectDelta(self: *WallpaperSwitcher, dx: i32, dy: i32) void {
        if (self.wallpapers.len == 0) return;
        var idx: i64 = @intCast(self.selected_index);
        const total: i64 = @intCast(self.wallpapers.len);
        const cols_i: i64 = @intCast(self.cols);

        if (dx != 0) {
            idx += dx;
            if (idx < 0) idx = total - 1;
            if (idx >= total) idx = 0;
        }
        if (dy != 0) {
            idx += dy * cols_i;
            if (idx < 0) idx = @max(0, idx + total);
            if (idx >= total) idx = @min(total - 1, @mod(idx, cols_i));
        }

        self.selected_index = @intCast(std.math.clamp(idx, 0, total - 1));
        self.render();
    }

    pub fn handlePointerClick(self: *WallpaperSwitcher, x: f64, y: f64) void {
        if (self.wallpapers.len == 0) return;
        const px: u32 = @intFromFloat(x);
        const py: u32 = @intFromFloat(y);

        const start_idx = self.scroll_row * self.cols;
        const visible_count = self.rows * self.cols;

        for (0..visible_count) |slot| {
            const idx = start_idx + slot;
            if (idx >= self.wallpapers.len) break;

            const c_col = slot % self.cols;
            const c_row = slot / self.cols;

            const cx = self.grid_x + @as(u32, @intCast(c_col)) * (self.card_w + self.gap);
            const cy = self.grid_y + @as(u32, @intCast(c_row)) * (self.card_h + self.gap);

            if (px >= cx and px < cx + self.card_w and py >= cy and py < cy + self.card_h) {
                self.selected_index = idx;
                self.applySelected();
                return;
            }
        }
    }

    pub fn handlePointerMotion(self: *WallpaperSwitcher, x: f64, y: f64) void {
        if (self.wallpapers.len == 0) return;
        const px: u32 = @intFromFloat(x);
        const py: u32 = @intFromFloat(y);

        const start_idx = self.scroll_row * self.cols;
        const visible_count = self.rows * self.cols;

        for (0..visible_count) |slot| {
            const idx = start_idx + slot;
            if (idx >= self.wallpapers.len) break;

            const c_col = slot % self.cols;
            const c_row = slot / self.cols;

            const cx = self.grid_x + @as(u32, @intCast(c_col)) * (self.card_w + self.gap);
            const cy = self.grid_y + @as(u32, @intCast(c_row)) * (self.card_h + self.gap);

            if (px >= cx and px < cx + self.card_w and py >= cy and py < cy + self.card_h) {
                if (self.selected_index != idx) {
                    self.selected_index = idx;
                    self.render();
                }
                return;
            }
        }
    }

    pub fn run(self: *WallpaperSwitcher) void {
        while (self.running) {
            if (c.wl_display_dispatch(self.display) < 0) break;
        }
    }

    pub fn deinit(self: *WallpaperSwitcher) void {
        if (self.shm_buffer) |*buf| buf.destroy();
        for (self.wallpapers) |*w| {
            if (w.thumbnail) |*thumb| thumb.deinit(self.allocator);
            self.allocator.free(w.path);
            self.allocator.free(w.filename);
        }
        self.allocator.free(self.wallpapers);
        if (self.active_path) |p| self.allocator.free(p);

        if (self.keyboard) |kb| c.wl_keyboard_destroy(kb);
        if (self.pointer) |pt| c.wl_pointer_destroy(pt);
        if (self.seat) |st| c.wl_seat_destroy(st);

        if (self.layer_surface) |ls| layerSurfaceDestroy(ls);
        if (self.surface) |s| c.wl_surface_destroy(s);
        c.wl_display_disconnect(self.display);
        self.allocator.destroy(self);
    }

    fn switcherHandleGlobal(data: ?*anyopaque, registry: ?*c.struct_wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
        const self: *WallpaperSwitcher = @ptrCast(@alignCast(data));
        const iface = std.mem.span(interface);

        if (std.mem.eql(u8, iface, "wl_compositor")) {
            self.compositor = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_compositor_interface, @min(version, 4)));
        } else if (std.mem.eql(u8, iface, "wl_shm")) {
            self.shm = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_shm_interface, 1));
        } else if (std.mem.eql(u8, iface, "zwlr_layer_shell_v1")) {
            self.layer_shell = @ptrCast(c.wl_registry_bind(registry, name, &zwlr_layer_shell_v1_interface, @min(version, 4)));
        } else if (std.mem.eql(u8, iface, "wl_seat")) {
            self.seat = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_seat_interface, @min(version, 7)));
            const seat_listener = c.struct_wl_seat_listener{
                .capabilities = seatHandleCapabilities,
                .name = seatHandleName,
            };
            _ = c.wl_seat_add_listener(self.seat.?, &seat_listener, self);
        }
    }

    fn switcherHandleGlobalRemove(data: ?*anyopaque, registry: ?*c.struct_wl_registry, name: u32) callconv(.c) void {
        _ = data;
        _ = registry;
        _ = name;
    }

    fn switcherHandleConfigure(data: ?*anyopaque, layer_surface: ?*c.struct_wl_proxy, serial: u32, width: u32, height: u32) callconv(.c) void {
        const self: *WallpaperSwitcher = @ptrCast(@alignCast(data));
        layerSurfaceAckConfigure(layer_surface.?, serial);
        self.screen_width = width;
        self.screen_height = height;
        self.configured = true;
        self.render();
    }

    fn switcherHandleClosed(data: ?*anyopaque, layer_surface: ?*c.struct_wl_proxy) callconv(.c) void {
        _ = layer_surface;
        const self: *WallpaperSwitcher = @ptrCast(@alignCast(data));
        self.running = false;
    }

    fn seatHandleCapabilities(data: ?*anyopaque, seat: ?*c.struct_wl_seat, capabilities: u32) callconv(.c) void {
        const self: *WallpaperSwitcher = @ptrCast(@alignCast(data));

        if ((capabilities & c.WL_SEAT_CAPABILITY_KEYBOARD) != 0 and self.keyboard == null) {
            self.keyboard = c.wl_seat_get_keyboard(seat);
            const kb_listener = c.struct_wl_keyboard_listener{
                .keymap = kbHandleKeymap,
                .enter = kbHandleEnter,
                .leave = kbHandleLeave,
                .key = kbHandleKey,
                .modifiers = kbHandleModifiers,
                .repeat_info = kbHandleRepeatInfo,
            };
            _ = c.wl_keyboard_add_listener(self.keyboard.?, &kb_listener, self);
        }

        if ((capabilities & c.WL_SEAT_CAPABILITY_POINTER) != 0 and self.pointer == null) {
            self.pointer = c.wl_seat_get_pointer(seat);
            const ptr_listener = c.struct_wl_pointer_listener{
                .enter = ptrHandleEnter,
                .leave = ptrHandleLeave,
                .motion = ptrHandleMotion,
                .button = ptrHandleButton,
                .axis = ptrHandleAxis,
                .frame = ptrHandleFrame,
                .axis_source = ptrHandleAxisSource,
                .axis_stop = ptrHandleAxisStop,
                .axis_discrete = ptrHandleAxisDiscrete,
            };
            _ = c.wl_pointer_add_listener(self.pointer.?, &ptr_listener, self);
        }
    }

    fn seatHandleName(data: ?*anyopaque, seat: ?*c.struct_wl_seat, name: [*c]const u8) callconv(.c) void {
        _ = data;
        _ = seat;
        _ = name;
    }

    fn kbHandleKeymap(data: ?*anyopaque, kb: ?*c.struct_wl_keyboard, format: u32, fd: i32, size: u32) callconv(.c) void {
        _ = data;
        _ = kb;
        _ = format;
        _ = size;
        _ = c.close(fd);
    }

    fn kbHandleEnter(data: ?*anyopaque, kb: ?*c.struct_wl_keyboard, serial: u32, surface: ?*c.struct_wl_surface, keys: ?*c.struct_wl_array) callconv(.c) void {
        _ = data;
        _ = kb;
        _ = serial;
        _ = surface;
        _ = keys;
    }

    fn kbHandleLeave(data: ?*anyopaque, kb: ?*c.struct_wl_keyboard, serial: u32, surface: ?*c.struct_wl_surface) callconv(.c) void {
        _ = data;
        _ = kb;
        _ = serial;
        _ = surface;
    }

    fn kbHandleKey(data: ?*anyopaque, kb: ?*c.struct_wl_keyboard, serial: u32, time: u32, key: u32, state: u32) callconv(.c) void {
        _ = kb;
        _ = serial;
        _ = time;
        const self: *WallpaperSwitcher = @ptrCast(@alignCast(data));
        if (state != 1) return; // Only process key press

        switch (key) {
            c.KEY_ESC, c.KEY_Q => {
                self.running = false;
            },
            c.KEY_ENTER, c.KEY_SPACE => {
                self.applySelected();
            },
            c.KEY_LEFT, c.KEY_H => {
                self.selectDelta(-1, 0);
            },
            c.KEY_RIGHT, c.KEY_L => {
                self.selectDelta(1, 0);
            },
            c.KEY_UP, c.KEY_K => {
                self.selectDelta(0, -1);
            },
            c.KEY_DOWN, c.KEY_J => {
                self.selectDelta(0, 1);
            },
            else => {},
        }
    }

    fn kbHandleModifiers(data: ?*anyopaque, kb: ?*c.struct_wl_keyboard, serial: u32, mods_depressed: u32, mods_latched: u32, mods_locked: u32, group: u32) callconv(.c) void {
        _ = data;
        _ = kb;
        _ = serial;
        _ = mods_depressed;
        _ = mods_latched;
        _ = mods_locked;
        _ = group;
    }

    fn kbHandleRepeatInfo(data: ?*anyopaque, kb: ?*c.struct_wl_keyboard, rate: i32, delay: i32) callconv(.c) void {
        _ = data;
        _ = kb;
        _ = rate;
        _ = delay;
    }

    fn ptrHandleEnter(data: ?*anyopaque, ptr: ?*c.struct_wl_pointer, serial: u32, surface: ?*c.struct_wl_surface, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
        _ = ptr;
        _ = serial;
        _ = surface;
        const self: *WallpaperSwitcher = @ptrCast(@alignCast(data));
        const x = @as(f64, @floatFromInt(sx)) / 256.0;
        const y = @as(f64, @floatFromInt(sy)) / 256.0;
        self.handlePointerMotion(x, y);
    }

    fn ptrHandleLeave(data: ?*anyopaque, ptr: ?*c.struct_wl_pointer, serial: u32, surface: ?*c.struct_wl_surface) callconv(.c) void {
        _ = data;
        _ = ptr;
        _ = serial;
        _ = surface;
    }

    fn ptrHandleMotion(data: ?*anyopaque, ptr: ?*c.struct_wl_pointer, time: u32, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
        _ = ptr;
        _ = time;
        const self: *WallpaperSwitcher = @ptrCast(@alignCast(data));
        const x = @as(f64, @floatFromInt(sx)) / 256.0;
        const y = @as(f64, @floatFromInt(sy)) / 256.0;
        self.handlePointerMotion(x, y);
    }

    fn ptrHandleButton(data: ?*anyopaque, ptr: ?*c.struct_wl_pointer, serial: u32, time: u32, button: u32, state: u32) callconv(.c) void {
        _ = ptr;
        _ = serial;
        _ = time;
        const self: *WallpaperSwitcher = @ptrCast(@alignCast(data));
        if (button == c.BTN_LEFT and state == c.WL_POINTER_BUTTON_STATE_PRESSED) {
            self.applySelected();
        }
    }

    fn ptrHandleAxis(data: ?*anyopaque, ptr: ?*c.struct_wl_pointer, time: u32, axis: u32, value: c.wl_fixed_t) callconv(.c) void {
        _ = ptr;
        _ = time;
        const self: *WallpaperSwitcher = @ptrCast(@alignCast(data));
        const val = @as(f64, @floatFromInt(value)) / 256.0;
        if (axis == c.WL_POINTER_AXIS_VERTICAL_SCROLL) {
            if (val > 0) {
                self.selectDelta(0, 1);
            } else if (val < 0) {
                self.selectDelta(0, -1);
            }
        }
    }

    fn ptrHandleFrame(data: ?*anyopaque, ptr: ?*c.struct_wl_pointer) callconv(.c) void {
        _ = data;
        _ = ptr;
    }

    fn ptrHandleAxisSource(data: ?*anyopaque, ptr: ?*c.struct_wl_pointer, axis_source: u32) callconv(.c) void {
        _ = data;
        _ = ptr;
        _ = axis_source;
    }

    fn ptrHandleAxisStop(data: ?*anyopaque, ptr: ?*c.struct_wl_pointer, time: u32, axis: u32) callconv(.c) void {
        _ = data;
        _ = ptr;
        _ = time;
        _ = axis;
    }

    fn ptrHandleAxisDiscrete(data: ?*anyopaque, ptr: ?*c.struct_wl_pointer, axis: u32, discrete: i32) callconv(.c) void {
        _ = data;
        _ = ptr;
        _ = axis;
        _ = discrete;
    }
};

// ============================================================================
// Drawing Primitives & Visual Effects
// ============================================================================

fn blendPixel(dst: *u32, src_color: u32) void {
    const sa = (src_color >> 24) & 0xFF;
    if (sa == 0) return;
    if (sa == 255) {
        dst.* = src_color;
        return;
    }

    const da = (dst.* >> 24) & 0xFF;
    const sr = (src_color >> 16) & 0xFF;
    const sg = (src_color >> 8) & 0xFF;
    const sb = src_color & 0xFF;

    const dr = (dst.* >> 16) & 0xFF;
    const dg = (dst.* >> 8) & 0xFF;
    const db = dst.* & 0xFF;

    const inv_sa = 255 - sa;
    const out_r = (sr * sa + dr * inv_sa) / 255;
    const out_g = (sg * sa + dg * inv_sa) / 255;
    const out_b = (sb * sa + db * inv_sa) / 255;
    const out_a = sa + (da * inv_sa) / 255;

    dst.* = (out_a << 24) | (out_r << 16) | (out_g << 8) | out_b;
}

fn isInsideRoundedRect(x: u32, y: u32, rx: u32, ry: u32, rw: u32, rh: u32, r: u32) bool {
    if (x < rx or x >= rx + rw or y < ry or y >= ry + rh) return false;
    const dx = x - rx;
    const dy = y - ry;

    // Corner checks
    if (dx < r and dy < r) {
        const cx = r - dx;
        const cy = r - dy;
        return (cx * cx + cy * cy) <= r * r;
    }
    if (dx >= rw - r and dy < r) {
        const cx = dx - (rw - r - 1);
        const cy = r - dy;
        return (cx * cx + cy * cy) <= r * r;
    }
    if (dx < r and dy >= rh - r) {
        const cx = r - dx;
        const cy = dy - (rh - r - 1);
        return (cx * cx + cy * cy) <= r * r;
    }
    if (dx >= rw - r and dy >= rh - r) {
        const cx = dx - (rw - r - 1);
        const cy = dy - (rh - r - 1);
        return (cx * cx + cy * cy) <= r * r;
    }
    return true;
}

fn drawRoundedRect(pixels: []u32, screen_w: u32, screen_h: u32, rx: u32, ry: u32, rw: u32, rh: u32, r: u32, color: u32) void {
    const max_y = @min(screen_h, ry + rh);
    const max_x = @min(screen_w, rx + rw);

    for (ry..max_y) |y| {
        const row = y * screen_w;
        for (rx..max_x) |x| {
            if (isInsideRoundedRect(@intCast(x), @intCast(y), rx, ry, rw, rh, r)) {
                pixels[row + x] = color;
            }
        }
    }
}

fn drawRoundedThumbnail(pixels: []u32, screen_w: u32, screen_h: u32, rx: u32, ry: u32, rw: u32, rh: u32, r: u32, thumb: *const Image) void {
    const max_y = @min(screen_h, ry + rh);
    const max_x = @min(screen_w, rx + rw);

    for (ry..max_y) |y| {
        const row = y * screen_w;
        const dy = y - ry;
        const ty = (dy * thumb.height) / rh;

        for (rx..max_x) |x| {
            if (isInsideRoundedRect(@intCast(x), @intCast(y), rx, ry, rw, rh, r)) {
                const dx = x - rx;
                const tx = (dx * thumb.width) / rw;
                const p = thumb.pixels[ty * thumb.width + tx];
                pixels[row + x] = p;
            }
        }
    }
}

fn drawRoundedBorder(pixels: []u32, screen_w: u32, screen_h: u32, rx: u32, ry: u32, rw: u32, rh: u32, r: u32, thickness: u32, color: u32) void {
    const max_y = @min(screen_h, ry + rh);
    const max_x = @min(screen_w, rx + rw);
    const inner_r = if (r > thickness) r - thickness else 0;

    for (ry..max_y) |y| {
        const row = y * screen_w;
        for (rx..max_x) |x| {
            const in_outer = isInsideRoundedRect(@intCast(x), @intCast(y), rx, ry, rw, rh, r);
            if (!in_outer) continue;

            const in_inner = isInsideRoundedRect(@intCast(x), @intCast(y), rx + thickness, ry + thickness, rw - thickness * 2, rh - thickness * 2, inner_r);
            if (!in_inner) {
                blendPixel(&pixels[row + x], color);
            }
        }
    }
}

fn drawRoundedCardGlow(pixels: []u32, screen_w: u32, screen_h: u32, rx: u32, ry: u32, rw: u32, rh: u32, r: u32, glow_color: u32) void {
    const glow_radius: u32 = 6;
    const start_x = if (rx > glow_radius) rx - glow_radius else 0;
    const start_y = if (ry > glow_radius) ry - glow_radius else 0;
    const end_x = @min(screen_w, rx + rw + glow_radius);
    const end_y = @min(screen_h, ry + rh + glow_radius);

    const base_rgb = glow_color & 0x00FFFFFF;

    for (start_y..end_y) |y| {
        const row = y * screen_w;
        for (start_x..end_x) |x| {
            if (isInsideRoundedRect(@intCast(x), @intCast(y), rx, ry, rw, rh, r)) continue;

            // Distance from card edge
            var dist_x: u32 = 0;
            if (x < rx) dist_x = rx - @as(u32, @intCast(x)) else if (x >= rx + rw) dist_x = @as(u32, @intCast(x)) - (rx + rw - 1);

            var dist_y: u32 = 0;
            if (y < ry) dist_y = ry - @as(u32, @intCast(y)) else if (y >= ry + rh) dist_y = @as(u32, @intCast(y)) - (ry + rh - 1);

            const dist = @max(dist_x, dist_y);
            if (dist <= glow_radius) {
                const alpha: u32 = (@as(u32, glow_radius - dist + 1) * 35) / glow_radius;
                blendPixel(&pixels[row + x], (alpha << 24) | base_rgb);
            }
        }
    }
}

fn drawActiveBadge(pixels: []u32, screen_w: u32, screen_h: u32, bx: u32, by: u32) void {
    const radius: u32 = 10;
    const cx = bx + radius;
    const cy = by + radius;

    for (by..by + radius * 2) |y| {
        if (y >= screen_h) break;
        const row = y * screen_w;
        for (bx..bx + radius * 2) |x| {
            if (x >= screen_w) break;
            const dx = @as(i32, @intCast(x)) - @as(i32, @intCast(cx));
            const dy = @as(i32, @intCast(y)) - @as(i32, @intCast(cy));
            if (dx * dx + dy * dy <= radius * radius) {
                pixels[row + x] = 0xFF10B981; // Emerald badge
            }
        }
    }

    // White checkmark lines inside badge
    const check_pts = [_][2]i32{
        .{ -4, 0 }, .{ -3, 1 }, .{ -2, 2 }, .{ -1, 3 }, .{ 0, 2 }, .{ 1, 0 }, .{ 2, -2 }, .{ 3, -4 },
        .{ -4, 1 }, .{ -3, 2 }, .{ -2, 3 }, .{ -1, 4 }, .{ 0, 3 }, .{ 1, 1 }, .{ 2, -1 }, .{ 3, -3 },
    };

    for (check_pts) |pt| {
        const px = @as(i32, @intCast(cx)) + pt[0];
        const py = @as(i32, @intCast(cy)) + pt[1];
        if (px >= 0 and px < screen_w and py >= 0 and py < screen_h) {
            pixels[@as(usize, @intCast(py)) * screen_w + @as(usize, @intCast(px))] = 0xFFFFFFFF;
        }
    }
}

fn drawEmptyState(pixels: []u32, screen_w: u32, screen_h: u32) void {
    const box_w: u32 = 480;
    const box_h: u32 = 160;
    if (screen_w < box_w or screen_h < box_h) return;
    const bx = (screen_w - box_w) / 2;
    const by = (screen_h - box_h) / 2;
    drawRoundedRect(pixels, screen_w, screen_h, bx, by, box_w, box_h, 16, 0xE61B1E2B);
    drawRoundedBorder(pixels, screen_w, screen_h, bx, by, box_w, box_h, 16, 2, 0x4D38BDF8);
}

// ============================================================================
// CLI Entry Point & Mode Dispatch
// ============================================================================

fn printUsage() void {
    const usage =
        \\Mizu Wallpaper Module - Native Wayland Wallpaper Setter & Switcher
        \\
        \\Usage:
        \\  wallpaper                 Open interactive wallpaper switcher overlay
        \\  wallpaper --switch        Open interactive wallpaper switcher overlay
        \\  wallpaper --set <path>    Set wallpaper to specified image file
        \\  wallpaper <image-file>    Set wallpaper to specified image file
        \\  wallpaper --daemon        Run wallpaper background service for active wallpaper
        \\  wallpaper --help          Show this help message
        \\
        \\Supported Image Formats:
        \\  PNG, JPEG / JFIF, BMP, QOI (100% pure Zig, zero external dependencies)
        \\
        \\Wallpaper Directory:
        \\  ~/Pictures/Wallpapers/
        \\
        \\Interactive Switcher Controls:
        \\  Arrow Keys / H,J,K,L      Navigate wallpaper thumbnails
        \\  Enter / Space             Apply selected wallpaper immediately
        \\  Mouse Hover / Click       Select and apply clicked wallpaper
        \\  Escape / Q                Close switcher
        \\
    ;
    _ = c.write(c.STDOUT_FILENO, usage.ptr, usage.len);
}

fn getCommandLineArgs(allocator: std.mem.Allocator) ![][]const u8 {
    const fd = c.open("/proc/self/cmdline", c.O_RDONLY);
    if (fd < 0) return &[_][]const u8{};
    defer _ = c.close(fd);

    var buf: [4096]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    if (n <= 0) return &[_][]const u8{};

    var list = SimpleList([]const u8){};
    var i: usize = 0;
    while (i < @as(usize, @intCast(n))) {
        const start = i;
        while (i < @as(usize, @intCast(n)) and buf[i] != 0) : (i += 1) {}
        if (i > start) {
            try list.append(allocator, try allocator.dupe(u8, buf[start..i]));
        }
        i += 1;
    }
    return list.toOwnedSlice(allocator);
}

const PID_FILE = "/tmp/mizu-wallpaper.pid";

fn writePidFile(pid: c.pid_t) void {
    const fd = c.open(PID_FILE, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o644));
    if (fd < 0) return;
    defer _ = c.close(fd);
    var buf: [32]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d}\n", .{pid}) catch return;
    _ = c.write(fd, str.ptr, str.len);
}

fn deletePidFile() void {
    _ = c.unlink(PID_FILE);
}

fn killProcessesByName(target_name: []const u8) void {
    const dir = c.opendir("/proc");
    if (dir == null) return;
    defer _ = c.closedir(dir);

    while (true) {
        const ent = c.readdir(dir);
        if (ent == null) break;
        const name_len = std.mem.len(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (name_len == 0) continue;
        const name = ent.*.d_name[0..name_len];
        const pid = std.fmt.parseInt(c.pid_t, name, 10) catch continue;
        if (pid <= 1 or pid == c.getpid()) continue;

        var comm_path_buf: [64]u8 = undefined;
        const comm_path = std.fmt.bufPrint(&comm_path_buf, "/proc/{s}/comm", .{name}) catch continue;
        var c_comm: [64]u8 = undefined;
        @memcpy(c_comm[0..comm_path.len], comm_path);
        c_comm[comm_path.len] = 0;

        const fd = c.open(@ptrCast(&c_comm), c.O_RDONLY);
        if (fd < 0) continue;
        var name_buf: [64]u8 = undefined;
        const n = c.read(fd, &name_buf, name_buf.len);
        _ = c.close(fd);
        if (n <= 0) continue;

        const comm = std.mem.trim(u8, name_buf[0..@intCast(n)], " \t\r\n");
        if (std.mem.eql(u8, comm, target_name)) {
            _ = c.kill(pid, c.SIGTERM);
            _ = c.kill(pid, c.SIGKILL);
        }
    }
}

fn killExistingWallpaperDaemon() void {
    const fd = c.open(PID_FILE, c.O_RDONLY);
    if (fd >= 0) {
        var buf: [32]u8 = undefined;
        const n = c.read(fd, &buf, buf.len);
        _ = c.close(fd);
        if (n > 0) {
            const trimmed = std.mem.trim(u8, buf[0..@intCast(n)], " \t\r\n");
            if (std.fmt.parseInt(c.pid_t, trimmed, 10)) |old_pid| {
                if (old_pid > 1 and old_pid != c.getpid()) {
                    _ = c.kill(old_pid, c.SIGTERM);
                    var i: usize = 0;
                    while (i < 10) : (i += 1) {
                        if (c.kill(old_pid, 0) != 0) break;
                        _ = c.usleep(10000);
                    }
                    if (c.kill(old_pid, 0) == 0) {
                        _ = c.kill(old_pid, c.SIGKILL);
                    }
                }
            } else |_| {}
        }
    }
    deletePidFile();

    // Kill any swaybg process
    killProcessesByName("swaybg");
}

pub fn isDaemonRunning() bool {
    const fd = c.open(PID_FILE, c.O_RDONLY);
    if (fd < 0) return false;
    defer _ = c.close(fd);

    var buf: [32]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    if (n <= 0) return false;

    const trimmed = std.mem.trim(u8, buf[0..@intCast(n)], " \t\r\n");
    const pid = std.fmt.parseInt(c.pid_t, trimmed, 10) catch return false;
    if (pid <= 1) return false;

    return c.kill(pid, 0) == 0;
}

pub fn runSetter(allocator: std.mem.Allocator, maybe_path: ?[]const u8) u8 {
    var chosen_path: ?[]const u8 = null;
    var allocated = false;
    defer {
        if (allocated and chosen_path != null) allocator.free(chosen_path.?);
    }

    if (maybe_path) |p| {
        chosen_path = p;
    } else {
        if (getActiveWallpaperPath(allocator)) |p| {
            chosen_path = p;
            allocated = true;
        } else {
            const list = scanWallpapers(allocator) catch return 1;
            defer {
                for (list) |w| {
                    allocator.free(w.path);
                    allocator.free(w.filename);
                }
                allocator.free(list);
            }
            if (list.len == 0) {
                std.debug.print("mizu wallpaper set: no wallpapers found in ~/Pictures/Wallpapers/\n", .{});
                return 1;
            }
            chosen_path = allocator.dupe(u8, list[0].path) catch return 1;
            allocated = true;
        }
    }

    const target_path = chosen_path.?;

    var c_target: [1024]u8 = undefined;
    if (target_path.len >= c_target.len) return 1;
    @memcpy(c_target[0..target_path.len], target_path);
    c_target[target_path.len] = 0;

    if (c.access(@ptrCast(&c_target), c.R_OK) != 0) {
        std.debug.print("mizu wallpaper set: cannot access '{s}'\n", .{target_path});
        return 1;
    }

    saveActiveWallpaperPath(target_path);
    killExistingWallpaperDaemon();

    const pid = c.fork();
    if (pid < 0) {
        std.debug.print("mizu wallpaper set: fork failed\n", .{});
        return 1;
    }

    if (pid > 0) {
        writePidFile(pid);
        std.debug.print("mizu: wallpaper set to '{s}'\n", .{target_path});
        return 0;
    }

    // In child daemon:
    _ = c.setsid();

    const max_fd = c.sysconf(c._SC_OPEN_MAX);
    var fd: c_int = 3;
    while (fd < max_fd) : (fd += 1) {
        _ = c.close(fd);
    }

    const dev_null = c.open("/dev/null", c.O_RDWR);
    if (dev_null >= 0) {
        _ = c.dup2(dev_null, 0);
        _ = c.dup2(dev_null, 1);
        _ = c.dup2(dev_null, 2);
        if (dev_null > 2) _ = c.close(dev_null);
    }

    // Exec clean daemon process to discard all parent memory (switcher/CLI)
    var target_z: [1024:0]u8 = undefined;
    if (target_path.len < target_z.len) {
        @memcpy(target_z[0..target_path.len], target_path);
        target_z[target_path.len] = 0;

        const exe_args = [_:null]?[*:0]const u8{
            "mizu",
            "wallpaper",
            "daemon",
            target_z[0..target_path.len :0].ptr,
            null,
        };
        _ = c.execv("/proc/self/exe", @ptrCast(&exe_args));
    }

    // Fallback if execv fails:
    var setter = WallpaperSetter.init(allocator, target_path) catch {
        c.exit(1);
    };
    defer setter.deinit();
    setter.run(false);
    c.exit(0);
}

pub fn runDaemon(allocator: std.mem.Allocator, maybe_path: ?[]const u8) u8 {
    var chosen_path: ?[]const u8 = null;
    var allocated = false;
    defer {
        if (allocated and chosen_path != null) allocator.free(chosen_path.?);
    }

    if (maybe_path) |p| {
        chosen_path = p;
    } else {
        if (getActiveWallpaperPath(allocator)) |p| {
            chosen_path = p;
            allocated = true;
        } else {
            const wall_list = scanWallpapers(allocator) catch return 1;
            defer {
                for (wall_list) |w| {
                    allocator.free(w.path);
                    allocator.free(w.filename);
                }
                allocator.free(wall_list);
            }
            if (wall_list.len == 0) {
                std.debug.print("mizu wallpaper daemon: no wallpapers found in ~/Pictures/Wallpapers/\n", .{});
                return 1;
            }
            chosen_path = allocator.dupe(u8, wall_list[0].path) catch return 1;
            allocated = true;
        }
    }
    const active = chosen_path.?;

    killExistingWallpaperDaemon();
    writePidFile(c.getpid());
    defer deletePidFile();

    var setter = WallpaperSetter.init(allocator, active) catch |err| {
        std.debug.print("mizu wallpaper daemon error: {}\n", .{err});
        return 1;
    };
    defer setter.deinit();
    setter.run(false);
    return 0;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try getCommandLineArgs(allocator);
    defer {
        for (args) |a| allocator.free(a);
        allocator.free(args);
    }

    if (args.len > 1) {
        const arg1 = args[1];
        if (std.mem.eql(u8, arg1, "--help") or std.mem.eql(u8, arg1, "-h")) {
            printUsage();
            return;
        }

        if (std.mem.eql(u8, arg1, "--set") or std.mem.eql(u8, arg1, "set")) {
            const maybe_path = if (args.len > 2) args[2] else null;
            _ = runSetter(allocator, maybe_path);
            return;
        } else if (std.mem.eql(u8, arg1, "--daemon") or std.mem.eql(u8, arg1, "daemon")) {
            const maybe_path = if (args.len > 2) args[2] else null;
            _ = runDaemon(allocator, maybe_path);
            return;
        } else if (!std.mem.eql(u8, arg1, "--switch") and !std.mem.eql(u8, arg1, "switch")) {
            // Path provided directly
            _ = runSetter(allocator, arg1);
            return;
        }
    }

    // Default mode: Interactive Wallpaper Switcher Overlay
    var switcher = try WallpaperSwitcher.init(allocator);
    defer switcher.deinit();
    switcher.run();
}

// ============================================================================
// Unit Tests
// ============================================================================

test "pure zig png decoder decodes wallpaper" {
    const allocator = std.testing.allocator;
    var img = decodeImageFile(allocator, "/home/hj/Pictures/Wallpapers/wallhaven-7j15m3.png") catch |err| {
        std.debug.print("Skipping test if file not found: {}\n", .{err});
        return;
    };
    defer img.deinit(allocator);

    try std.testing.expect(img.width == 1920);
    try std.testing.expect(img.height == 1080);
    try std.testing.expect(img.pixels.len == 1920 * 1080);
}

test "pure zig jpeg decoder decodes wallpaper" {
    const allocator = std.testing.allocator;
    var img = decodeImageFile(allocator, "/home/hj/Pictures/Wallpapers/wallhaven-2128mx.jpg") catch |err| {
        std.debug.print("Skipping test if file not found: {}\n", .{err});
        return;
    };
    defer img.deinit(allocator);

    try std.testing.expect(img.width == 1920);
    try std.testing.expect(img.height == 1080);
    try std.testing.expect(img.pixels.len == 1920 * 1080);
}

test "downsampler creates valid thumbnail" {
    const allocator = std.testing.allocator;
    var src = try Image.init(allocator, 1920, 1080);
    defer src.deinit(allocator);
    @memset(src.pixels, 0xFF336699);

    var thumb = try Image.init(allocator, THUMB_WIDTH, THUMB_HEIGHT);
    defer thumb.deinit(allocator);

    downsample(&src, THUMB_WIDTH, THUMB_HEIGHT, thumb.pixels);
    try std.testing.expectEqual(@as(u32, 0xFF336699), thumb.pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xFF336699), thumb.pixels[THUMB_WIDTH * THUMB_HEIGHT - 1]);
}

test "scan wallpapers finds images" {
    const allocator = std.testing.allocator;
    const list = try scanWallpapers(allocator);
    defer {
        for (list) |w| {
            allocator.free(w.path);
            allocator.free(w.filename);
        }
        allocator.free(list);
    }
    try std.testing.expect(list.len > 0);

    for (list) |w| {
        if (decodeImageFile(allocator, w.path)) |img| {
            var mut = img;
            defer mut.deinit(allocator);
            std.debug.print("SUCCESS: {s} ({d}x{d})\n", .{ w.filename, img.width, img.height });
        } else |err| {
            std.debug.print("FAILURE: {s} -> {}\n", .{ w.filename, err });
        }
    }
}

