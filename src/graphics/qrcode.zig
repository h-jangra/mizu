const std = @import("std");

pub const QrCode = struct {
    size: u32,
    modules: [80 * 80]bool,

    pub fn isDark(self: *const QrCode, x: u32, y: u32) bool {
        if (self.size == 0 or x >= self.size or y >= self.size) return false;
        return self.modules[y * 80 + x];
    }
};

const gf_exp = blk: {
    var exp: [512]u8 = undefined;
    var x: u16 = 1;
    var i: usize = 0;
    while (i < 255) : (i += 1) {
        exp[i] = @intCast(x);
        exp[i + 255] = @intCast(x);
        x <<= 1;
        if ((x & 0x100) != 0) x ^= 0x11D;
    }
    exp[510] = exp[255];
    exp[511] = exp[256];
    break :blk exp;
};

const gf_log = blk: {
    var log: [256]u8 = undefined;
    log[0] = 0;
    var i: usize = 0;
    while (i < 255) : (i += 1) {
        log[gf_exp[i]] = @intCast(i);
    }
    break :blk log;
};

fn gfMul(x: u8, y: u8) u8 {
    if (x == 0 or y == 0) return 0;
    return gf_exp[@as(usize, gf_log[x]) + @as(usize, gf_log[y])];
}

fn makeRsGenerator(num_ec: usize, poly_out: []u8) void {
    @memset(poly_out, 0);
    poly_out[0] = 1;
    var len: usize = 1;
    var i: usize = 0;
    while (i < num_ec) : (i += 1) {
        const root = gf_exp[i];
        var j = len;
        while (j > 0) : (j -= 1) {
            poly_out[j] = poly_out[j - 1] ^ gfMul(poly_out[j], root);
        }
        poly_out[0] = gfMul(poly_out[0], root);
        len += 1;
    }
}

fn calcReedSolomon(data: []const u8, num_ec: usize, ec_out: []u8) void {
    var gen_poly: [64]u8 = undefined;
    makeRsGenerator(num_ec, gen_poly[0 .. num_ec + 1]);
    var remainder: [64]u8 = @splat(0);
    for (data) |b| {
        const factor = b ^ remainder[num_ec - 1];
        var i = num_ec - 1;
        while (i > 0) : (i -= 1) {
            remainder[i] = remainder[i - 1] ^ gfMul(gen_poly[i], factor);
        }
        remainder[0] = gfMul(gen_poly[0], factor);
    }
    var i: usize = 0;
    while (i < num_ec) : (i += 1) {
        ec_out[i] = remainder[num_ec - 1 - i];
    }
}

const VersionInfo = struct {
    version: u32,
    size: u32,
    total_codewords: usize,
    data_codewords: usize,
    ec_codewords_per_block: usize,
    num_blocks: usize,
};

const versions = [_]VersionInfo{
    .{ .version = 1, .size = 21, .total_codewords = 26, .data_codewords = 19, .ec_codewords_per_block = 7, .num_blocks = 1 },
    .{ .version = 2, .size = 25, .total_codewords = 44, .data_codewords = 34, .ec_codewords_per_block = 10, .num_blocks = 1 },
    .{ .version = 3, .size = 29, .total_codewords = 70, .data_codewords = 55, .ec_codewords_per_block = 15, .num_blocks = 1 },
    .{ .version = 4, .size = 33, .total_codewords = 100, .data_codewords = 80, .ec_codewords_per_block = 20, .num_blocks = 1 },
    .{ .version = 5, .size = 37, .total_codewords = 134, .data_codewords = 108, .ec_codewords_per_block = 26, .num_blocks = 1 },
    .{ .version = 6, .size = 41, .total_codewords = 172, .data_codewords = 136, .ec_codewords_per_block = 18, .num_blocks = 2 },
    .{ .version = 7, .size = 45, .total_codewords = 196, .data_codewords = 156, .ec_codewords_per_block = 20, .num_blocks = 2 },
    .{ .version = 8, .size = 49, .total_codewords = 242, .data_codewords = 194, .ec_codewords_per_block = 24, .num_blocks = 2 },
    .{ .version = 9, .size = 53, .total_codewords = 292, .data_codewords = 232, .ec_codewords_per_block = 30, .num_blocks = 2 },
    .{ .version = 10, .size = 57, .total_codewords = 346, .data_codewords = 274, .ec_codewords_per_block = 18, .num_blocks = 4 },
    .{ .version = 11, .size = 61, .total_codewords = 476, .data_codewords = 321, .ec_codewords_per_block = 15, .num_blocks = 5 },
    .{ .version = 12, .size = 65, .total_codewords = 535, .data_codewords = 367, .ec_codewords_per_block = 17, .num_blocks = 5 },
    .{ .version = 13, .size = 69, .total_codewords = 610, .data_codewords = 425, .ec_codewords_per_block = 17, .num_blocks = 6 },
    .{ .version = 14, .size = 73, .total_codewords = 665, .data_codewords = 458, .ec_codewords_per_block = 19, .num_blocks = 6 },
};

const alignment_patterns = [_][]const u32{
    &[_]u32{},
    &[_]u32{ 6, 18 },
    &[_]u32{ 6, 22 },
    &[_]u32{ 6, 26 },
    &[_]u32{ 6, 30 },
    &[_]u32{ 6, 34 },
    &[_]u32{ 6, 22, 38 },
    &[_]u32{ 6, 24, 42 },
    &[_]u32{ 6, 26, 46 },
    &[_]u32{ 6, 28, 50 },
    &[_]u32{ 6, 30, 54 },
    &[_]u32{ 6, 32, 58 },
    &[_]u32{ 6, 34, 62 },
    &[_]u32{ 6, 26, 46, 66 },
};

fn isNumeric(text: []const u8) bool {
    for (text) |ch| {
        if (ch < '0' or ch > '9') return false;
    }
    return true;
}

fn isAlphanumeric(text: []const u8) bool {
    const charset = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:";
    for (text) |ch| {
        var found = false;
        for (charset) |c| {
            if (c == ch) { found = true; break; }
        }
        if (!found) return false;
    }
    return true;
}

fn calcSegmentBitLength(mode_bits: u4, num_chars: usize) usize {
    // Byte mode = 4 bits, count = 8/16 bits, data = 8 bits per char
    if (mode_bits == 0b0100) return 4 + (if (num_chars < 256) 8 else 16) + num_chars * 8;
    // Numeric: 4 + count + ceil(10/3*n)
    if (mode_bits == 0b0001) {
        const count_bits = if (num_chars < 256) 10 else 12; // simplified for v1-9
        const data_bits = (num_chars * 10 + 2) / 3;
        return 4 + count_bits + data_bits;
    }
    // Alphanumeric: 4 + count + ceil(11/2*n)
    if (mode_bits == 0b0010) {
        const count_bits = if (num_chars < 256) 9 else 11;
        const data_bits = (num_chars * 11 + 1) / 2;
        return 4 + count_bits + data_bits;
    }
    return 4 + (if (num_chars < 256) 8 else 16) + num_chars * 8;
}

fn appendBits(dest: []u8, cursor: *usize, val: u32, num_bits: u6) void {
    var i: i32 = @as(i32, @intCast(num_bits)) - 1;
    while (i >= 0) : (i -= 1) {
        const bit: u8 = @intCast((val >> @as(u5, @intCast(i))) & 1);
        const byte_idx = cursor.* / 8;
        const bit_idx: u3 = @intCast(7 - (cursor.* % 8));
        dest[byte_idx] |= (bit << bit_idx);
        cursor.* += 1;
    }
}

pub fn encodeText(text: []const u8) QrCode {
    if (text.len == 0) return QrCode{ .size = 0, .modules = @splat(false) };
    if (text.len > 2048) return QrCode{ .size = 0, .modules = @splat(false) };

    var chosen_v: ?VersionInfo = null;
    for (versions) |v| {
        const count_bits: usize = if (v.version >= 10) 16 else 8;
        const total_data_bits = 4 + count_bits + text.len * 8;
        const total_data_bytes = (total_data_bits + 7) / 8;
        if (total_data_bytes + 1 <= v.data_codewords) {
            chosen_v = v;
            break;
        }
    }
    const info = chosen_v orelse return QrCode{ .size = 0, .modules = @splat(false) };

    var data_bytes: [1024]u8 = @splat(0);
    var bit_cursor: usize = 0;
    appendBits(&data_bytes, &bit_cursor, 0b0100, 4);
    const count_bits: u6 = if (info.version >= 10) 16 else 8;
    appendBits(&data_bytes, &bit_cursor, @intCast(text.len), count_bits);
    for (text) |ch| appendBits(&data_bytes, &bit_cursor, ch, 8);

    const max_data_bits = info.data_codewords * 8;
    const term_bits = @min(@as(usize, 4), max_data_bits -| bit_cursor);
    appendBits(&data_bytes, &bit_cursor, 0, @intCast(term_bits));
    const rem = bit_cursor % 8;
    if (rem != 0) appendBits(&data_bytes, &bit_cursor, 0, @intCast(8 - rem));

    var pad_byte: u8 = 0xEC;
    var byte_idx = bit_cursor / 8;
    while (byte_idx < info.data_codewords) : (byte_idx += 1) {
        data_bytes[byte_idx] = pad_byte;
        pad_byte = if (pad_byte == 0xEC) 0x11 else 0xEC;
    }

    const num_blocks = info.num_blocks;
    const block_data_len = info.data_codewords / num_blocks;
    const ec_len = info.ec_codewords_per_block;
    var ec_blocks: [6][64]u8 = undefined;
    var b_idx: usize = 0;
    while (b_idx < num_blocks) : (b_idx += 1) {
        calcReedSolomon(data_bytes[b_idx * block_data_len .. (b_idx + 1) * block_data_len], ec_len, ec_blocks[b_idx][0..ec_len]);
    }

    var final_codewords: [1024]u8 = undefined;
    var fc_idx: usize = 0;
    var col: usize = 0;
    while (col < block_data_len) : (col += 1) {
        var b: usize = 0;
        while (b < num_blocks) : (b += 1) {
            final_codewords[fc_idx] = data_bytes[b * block_data_len + col];
            fc_idx += 1;
        }
    }
    col = 0;
    while (col < ec_len) : (col += 1) {
        var b: usize = 0;
        while (b < num_blocks) : (b += 1) {
            final_codewords[fc_idx] = ec_blocks[b][col];
            fc_idx += 1;
        }
    }

    var qr = QrCode{ .size = info.size, .modules = @splat(false) };
    var is_func: [80 * 80]bool = @splat(false);

    const setFunc = struct {
        fn call(q: *QrCode, fn_mat: *[80 * 80]bool, x: u32, y: u32, dark: bool) void {
            if (q.size == 0 or x >= q.size or y >= q.size) return;
            const idx = y * 80 + x;
            q.modules[idx] = dark;
            fn_mat[idx] = true;
        }
    }.call;

    const drawFinder = struct {
        fn call(q: *QrCode, fn_mat: *[80 * 80]bool, ox: i32, oy: i32) void {
            var r: i32 = -1;
            while (r <= 7) : (r += 1) {
                var c_i: i32 = -1;
                while (c_i <= 7) : (c_i += 1) {
                    const x = ox + c_i;
                    const y = oy + r;
                    if (x < 0 or y < 0 or x >= @as(i32, @intCast(q.size)) or y >= @as(i32, @intCast(q.size))) continue;
                    const is_dark = if (r >= 0 and r <= 6 and c_i >= 0 and c_i <= 6)
                        (r == 0 or r == 6 or c_i == 0 or c_i == 6 or (r >= 2 and r <= 4 and c_i >= 2 and c_i <= 4))
                    else false;
                    setFunc(q, fn_mat, @intCast(x), @intCast(y), is_dark);
                }
            }
        }
    }.call;

    drawFinder(&qr, &is_func, 0, 0);
    drawFinder(&qr, &is_func, @as(i32, @intCast(qr.size)) - 7, 0);
    drawFinder(&qr, &is_func, 0, @as(i32, @intCast(qr.size)) - 7);

    var i: u32 = 8;
    while (i < qr.size - 8) : (i += 1) {
        setFunc(&qr, &is_func, i, 6, (i % 2) == 0);
        setFunc(&qr, &is_func, 6, i, (i % 2) == 0);
    }

    if (info.version >= 2) {
        const coords = alignment_patterns[info.version - 1];
        for (coords) |ay| {
            for (coords) |ax| {
                if (is_func[ay * 80 + ax]) continue;
                var dy: i32 = -2;
                while (dy <= 2) : (dy += 1) {
                    var dx: i32 = -2;
                    while (dx <= 2) : (dx += 1) {
                        const dark = (dy == -2 or dy == 2 or dx == -2 or dx == 2 or (dx == 0 and dy == 0));
                        setFunc(&qr, &is_func, @intCast(@as(i32, @intCast(ax)) + dx), @intCast(@as(i32, @intCast(ay)) + dy), dark);
                    }
                }
            }
        }
    }

    setFunc(&qr, &is_func, 8, 4 * info.version + 9, true);

    var fi: u32 = 0;
    while (fi <= 8) : (fi += 1) {
        if (fi != 6) {
            setFunc(&qr, &is_func, fi, 8, false);
            setFunc(&qr, &is_func, 8, fi, false);
        }
    }
    fi = 0;
    while (fi < 8) : (fi += 1) {
        setFunc(&qr, &is_func, @as(u32, @intCast(qr.size)) - 1 - fi, 8, false);
        setFunc(&qr, &is_func, 8, @as(u32, @intCast(qr.size)) - 1 - fi, false);
    }

    if (info.version >= 7) {
        const s = qr.size;
        var yb: u32 = s - 11;
        while (yb < s - 8) : (yb += 1) {
            var xb: u32 = 0;
            while (xb < 6) : (xb += 1) setFunc(&qr, &is_func, xb, yb, false);
        }
        var yt: u32 = 0;
        while (yt < 6) : (yt += 1) {
            var xt: u32 = s - 11;
            while (xt < s - 8) : (xt += 1) setFunc(&qr, &is_func, xt, yt, false);
        }
    }

    var bit_idx: usize = 0;
    const total_bit_len = fc_idx * 8;
    var x_coord: i32 = @as(i32, @intCast(qr.size)) - 1;
    var upward = true;
    while (x_coord > 0) {
        if (x_coord == 6) x_coord -= 1;
        var y_step: i32 = 0;
        while (y_step < @as(i32, @intCast(qr.size))) : (y_step += 1) {
            const y_coord: u32 = if (upward)
                @intCast(@as(i32, @intCast(qr.size)) - 1 - y_step)
            else
                @intCast(y_step);
            var c_off: i32 = 0;
            while (c_off < 2) : (c_off += 1) {
                const cur_x: u32 = @intCast(x_coord - c_off);
                const cur_y = y_coord;
                if (!is_func[cur_y * 80 + cur_x]) {
                    var bit = false;
                    if (bit_idx < total_bit_len) {
                        const b_byte = final_codewords[bit_idx / 8];
                        const b_bit: u3 = @intCast(7 - (bit_idx % 8));
                        bit = ((b_byte >> b_bit) & 1) == 1;
                        bit_idx += 1;
                    }
                    const mask = ((cur_x + cur_y) % 2) == 0;
                    qr.modules[cur_y * 80 + cur_x] = bit ^ mask;
                }
            }
        }
        upward = !upward;
        x_coord -= 2;
    }

    const format_bits: u15 = 0b111011111000100;
    var fb: u5 = 0;
    while (fb < 15) : (fb += 1) {
        const shift: u4 = @intCast(fb);
        const dark = ((format_bits >> shift) & 1) == 1;
        const ufb: usize = fb;
        if (fb <= 5) {
            qr.modules[ufb * 80 + 8] = dark;
        } else if (fb == 6) {
            qr.modules[7 * 80 + 8] = dark;
        } else if (fb == 7) {
            qr.modules[8 * 80 + 8] = dark;
        } else if (fb == 8) {
            qr.modules[8 * 80 + 7] = dark;
        } else {
            qr.modules[8 * 80 + (14 - ufb)] = dark;
        }
        if (fb < 7) {
            qr.modules[(@as(usize, qr.size) - 1 - ufb) * 80 + 8] = dark;
        } else {
            qr.modules[8 * 80 + (@as(usize, qr.size) - 15 + ufb)] = dark;
        }
    }

    if (info.version >= 7) {
        const ver_bits: u6 = @intCast(info.version - 7);
        var vb: u5 = 0;
        while (vb < 6) : (vb += 1) {
            const v_dark = ((ver_bits >> @intCast(5 - vb)) & 1) == 1;
            const pos_x = 8 + @as(u32, @intCast(vb));
            const pos_y = @as(u32, @intCast(qr.size)) - 11 + @as(u32, @intCast(vb));
            if (pos_x < qr.size and pos_y < qr.size) {
                qr.modules[pos_y * 80 + pos_x] = v_dark;
                qr.modules[pos_x * 80 + pos_y] = v_dark;
            }
        }
    }

    return qr;
}

test "QR short string" {
    const qr = encodeText("https://github.com");
    std.debug.assert(qr.size >= 21);
    std.debug.assert(qr.isDark(0, 0));
}

test "QR empty" {
    const qr = encodeText("");
    std.debug.assert(qr.size == 0);
}

test "QR 50 chars" {
    const qr = encodeText("this is a test of around fifty characters long text!!!");
    std.debug.assert(qr.size > 0);
}

test "QR 100 chars" {
    const qr = encodeText("this is a longer test string that should be close to one hundred characters in total length!!");
    std.debug.assert(qr.size > 0);
}

test "QR 140 chars" {
    const qr = encodeText("this is a very long test string that should exceed around one hundred and forty characters total when combined with some extra padding!!");
    std.debug.assert(qr.size > 0);
}
