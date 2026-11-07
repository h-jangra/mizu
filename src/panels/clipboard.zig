const std = @import("std");
const c = @import("c");
const renderer = @import("../core/renderer.zig");
const theme = @import("../core/theme.zig");
const Color = theme.Color;
const config = @import("../core/config.zig");
const sys_status = @import("../services/system_status.zig");
const text_input = @import("../core/text_input.zig");
const icons = @import("../graphics/icons.zig");
const ui_mod = @import("../core/ui.zig");

pub const QrCodeResult = struct {
    size: u32,
    code: c.QRCode,
    modules: [4096]u8,

    pub fn isDark(self: *const QrCodeResult, x: u32, y: u32) bool {
        if (self.size == 0 or x >= self.size or y >= self.size) return false;
        var mutable_code = self.code;
        mutable_code.modules = @constCast(&self.modules);
        return c.qrcode_getModule(&mutable_code, @intCast(x), @intCast(y));
    }
};

pub fn generateQr(text: []const u8) ?QrCodeResult {
    if (text.len == 0 or text.len > 4296) return null;
    var res: QrCodeResult = undefined;
    var ver: u8 = 1;
    while (ver <= 40) : (ver += 1) {
        const buf_size = c.qrcode_getBufferSize(ver);
        if (buf_size > res.modules.len) break;
        const ret = c.qrcode_initBytes(&res.code, &res.modules, ver, c.ECC_LOW, @constCast(text.ptr), @intCast(text.len));
        if (ret == 0) {
            res.size = res.code.size;
            return res;
        }
    }
    return null;
}

pub const ClipType = enum {
    text,
    image,
};

pub const ClipItem = struct {
    id: u64,
    clip_type: ClipType = .text,
    preview: [160]u8 = @splat(0),
    preview_len: usize = 0,
    first_line: [160]u8 = @splat(0),
    first_line_len: usize = 0,
    first_line_loaded: bool = false,
    pinned: bool = false,

    // Image-specific fields
    image_width: u32 = 0,
    image_height: u32 = 0,
    image_format: []const u8 = "",
    image_data: []u8 = &.{},

    pub fn deinit(self: *ClipItem, allocator: std.mem.Allocator) void {
        if (self.image_data.len > 0) {
            allocator.free(self.image_data);
            self.image_data = &.{};
        }
    }
};

/// Extract first preview line in-memory.
pub fn loadItemFirstLine(item: *ClipItem) void {
    if (item.first_line_loaded) return;
    item.first_line_loaded = true;

    const prev = item.preview[0..item.preview_len];
    var line_start: usize = 0;
    while (line_start < prev.len and (prev[line_start] == '\r' or prev[line_start] == '\n' or prev[line_start] == ' ' or prev[line_start] == '\t')) {
        line_start += 1;
    }
    var line_end = line_start;
    while (line_end < prev.len and prev[line_end] != '\r' and prev[line_end] != '\n') {
        line_end += 1;
    }
    const trimmed = std.mem.trim(u8, prev[line_start..line_end], " \t\r\n");
    const copy_len = @min(trimmed.len, item.first_line.len);
    if (copy_len > 0) {
        @memcpy(item.first_line[0..copy_len], trimmed[0..copy_len]);
        item.first_line_len = copy_len;
    } else {
        const raw_copy = @min(prev.len, item.first_line.len);
        @memcpy(item.first_line[0..raw_copy], prev[0..raw_copy]);
        item.first_line_len = raw_copy;
    }
}

pub const DecodedCache = struct {
    pub const Entry = struct {
        id: u64 = 0,
        len: usize = 0,
        buf: [8192]u8 = @splat(0),
        access_seq: u64 = 0,
    };

    entries: [64]Entry = @splat(Entry{}),
    seq_counter: u64 = 1,

    pub fn get(self: *DecodedCache, id: u64) ?[]const u8 {
        if (id == 0) return null;
        for (&self.entries) |*entry| {
            if (entry.id == id and entry.len > 0) {
                self.seq_counter +%= 1;
                entry.access_seq = self.seq_counter;
                return entry.buf[0..entry.len];
            }
        }
        return null;
    }

    pub fn put(self: *DecodedCache, id: u64, content: []const u8) void {
        if (id == 0) return;
        self.seq_counter +%= 1;
        // Check if already in cache
        for (&self.entries) |*entry| {
            if (entry.id == id) {
                const copy_len = @min(content.len, entry.buf.len);
                if (copy_len > 0) {
                    @memcpy(entry.buf[0..copy_len], content[0..copy_len]);
                }
                entry.len = copy_len;
                entry.access_seq = self.seq_counter;
                return;
            }
        }

        // Find oldest or empty slot
        var target_idx: usize = 0;
        var oldest_seq: u64 = std.math.maxInt(u64);
        for (self.entries, 0..) |entry, i| {
            if (entry.len == 0 or entry.id == 0) {
                target_idx = i;
                break;
            }
            if (entry.access_seq < oldest_seq) {
                oldest_seq = entry.access_seq;
                target_idx = i;
            }
        }

        const target = &self.entries[target_idx];
        target.id = id;
        const copy_len = @min(content.len, target.buf.len);
        if (copy_len > 0) {
            @memcpy(target.buf[0..copy_len], content[0..copy_len]);
        }
        target.len = copy_len;
        target.access_seq = self.seq_counter;
    }

    pub fn remove(self: *DecodedCache, id: u64) void {
        for (&self.entries) |*entry| {
            if (entry.id == id) {
                entry.id = 0;
                entry.len = 0;
                entry.access_seq = 0;
                return;
            }
        }
    }

    pub fn clear(self: *DecodedCache) void {
        for (&self.entries) |*entry| {
            entry.id = 0;
            entry.len = 0;
            entry.access_seq = 0;
        }
    }
};

/// Cache for decoded images with LRU eviction
pub const ImageCache = struct {
    pub const Entry = struct {
        id: u64 = 0,
        image: ?*renderer.Image = null,
        access_seq: u64 = 0,
    };

    entries: [16]Entry = @splat(Entry{}),
    seq_counter: u64 = 1,
    allocator: std.mem.Allocator = undefined,
    total_bytes: usize = 0,

    const max_bytes: usize = 32 * 1024 * 1024;

    pub fn init(allocator: std.mem.Allocator) ImageCache {
        return .{
            .entries = @splat(Entry{}),
            .seq_counter = 1,
            .allocator = allocator,
            .total_bytes = 0,
        };
    }

    fn freeEntry(self: *ImageCache, entry: *Entry) void {
        if (entry.image) |img| {
            self.total_bytes -|= img.pixels.len * @sizeOf(u32);
            img.deinit();
            entry.image = null;
        }
        entry.id = 0;
        entry.access_seq = 0;
    }

    fn imageBytes(img: *const renderer.Image) usize {
        return img.pixels.len * @sizeOf(u32);
    }

    fn evictUntilFits(self: *ImageCache, pending_bytes: usize, skip: usize) void {
        while (self.total_bytes + pending_bytes > max_bytes) {
            var oldest_idx: ?usize = null;
            var oldest_seq: u64 = std.math.maxInt(u64);
            for (self.entries, 0..) |entry, i| {
                if (i == skip or entry.image == null) continue;
                if (entry.access_seq < oldest_seq) {
                    oldest_seq = entry.access_seq;
                    oldest_idx = i;
                }
            }
            const idx = oldest_idx orelse break;
            self.freeEntry(&self.entries[idx]);
        }
    }

    pub fn deinit(self: *ImageCache) void {
        for (&self.entries) |*entry| {
            self.freeEntry(entry);
        }
    }

    pub fn get(self: *ImageCache, id: u64) ?*renderer.Image {
        if (id == 0) return null;
        for (&self.entries) |*entry| {
            if (entry.id == id and entry.image != null) {
                self.seq_counter +%= 1;
                entry.access_seq = self.seq_counter;
                return entry.image.?;
            }
        }
        return null;
    }

    pub fn put(self: *ImageCache, id: u64, image: *renderer.Image) void {
        if (id == 0) {
            image.deinit();
            return;
        }
        if (imageBytes(image) > max_bytes) {
            image.deinit();
            return;
        }
        self.seq_counter +%= 1;
        // Check if already in cache
        for (&self.entries, 0..) |*entry, entry_idx| {
            if (entry.id == id) {
                self.freeEntry(entry);
                entry.id = id;
                entry.image = image;
                entry.access_seq = self.seq_counter;
                self.total_bytes += imageBytes(image);
                self.evictUntilFits(0, entry_idx);
                return;
            }
        }

        // Find oldest or empty slot
        var target_idx: usize = 0;
        var oldest_seq: u64 = std.math.maxInt(u64);
        for (self.entries, 0..) |entry, i| {
            if (entry.image == null) {
                target_idx = i;
                break;
            }
            if (entry.access_seq < oldest_seq) {
                oldest_seq = entry.access_seq;
                target_idx = i;
            }
        }

        const target = &self.entries[target_idx];
        self.freeEntry(target);
        self.evictUntilFits(imageBytes(image), target_idx);
        target.id = id;
        target.image = image;
        target.access_seq = self.seq_counter;
        self.total_bytes += imageBytes(image);
    }

    pub fn remove(self: *ImageCache, id: u64) void {
        for (&self.entries) |*entry| {
            if (entry.id == id) {
                self.freeEntry(entry);
                return;
            }
        }
    }

    pub fn clear(self: *ImageCache) void {
        for (&self.entries) |*entry| {
            self.freeEntry(entry);
        }
        self.total_bytes = 0;
    }
};

/// Downscale oversized image to thumbnail (caller owns return).
fn makeThumbnail(allocator: std.mem.Allocator, src: *renderer.Image, max_dim: u32) !*renderer.Image {
    const sw = src.width;
    const sh = src.height;
    if (sw == 0 or sh == 0) return error.InvalidImage;
    const max_side = @max(sw, sh);
    if (max_side <= max_dim) return error.NotNeeded;

    const ratio = @as(f32, @floatFromInt(max_dim)) / @as(f32, @floatFromInt(max_side));
    var dw: u32 = @intFromFloat(@as(f32, @floatFromInt(sw)) * ratio);
    var dh: u32 = @intFromFloat(@as(f32, @floatFromInt(sh)) * ratio);
    if (dw == 0) dw = 1;
    if (dh == 0) dh = 1;

    const pixels = try allocator.alloc(u32, @as(usize, dw) * @as(usize, dh));
    errdefer allocator.free(pixels);
    const dws: usize = dw;
    const dhs: usize = dh;
    for (0..dhs) |y| {
        const sy: usize = @min(@as(usize, sh - 1), y * @as(usize, sh) / dhs);
        for (0..dws) |x| {
            const sx: usize = @min(@as(usize, sw - 1), x * @as(usize, sw) / dws);
            pixels[y * dws + x] = src.pixels[sy * @as(usize, sw) + sx];
        }
    }

    const img = try allocator.create(renderer.Image);
    img.* = .{
        .width = dw,
        .height = dh,
        .pixels = pixels,
        .allocator = allocator,
    };
    return img;
}

pub const Mutex = struct {
    inner: c.pthread_mutex_t = undefined,

    pub fn init() Mutex {
        var m: Mutex = undefined;
        _ = c.pthread_mutex_init(&m.inner, null);
        return m;
    }

    pub fn deinit(self: *Mutex) void {
        _ = c.pthread_mutex_destroy(&self.inner);
    }

    pub fn lock(self: *Mutex) void {
        _ = c.pthread_mutex_lock(&self.inner);
    }

    pub fn unlock(self: *Mutex) void {
        _ = c.pthread_mutex_unlock(&self.inner);
    }
};

pub const Condition = struct {
    inner: c.pthread_cond_t = undefined,

    pub fn init() Condition {
        var cond: Condition = undefined;
        _ = c.pthread_cond_init(&cond.inner, null);
        return cond;
    }

    pub fn deinit(self: *Condition) void {
        _ = c.pthread_cond_destroy(&self.inner);
    }

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        _ = c.pthread_cond_wait(&self.inner, &mutex.inner);
    }

    pub fn signal(self: *Condition) void {
        _ = c.pthread_cond_signal(&self.inner);
    }

    pub fn broadcast(self: *Condition) void {
        _ = c.pthread_cond_broadcast(&self.inner);
    }
};

/// Ref-counted context shared between UI thread and detached background workers.
pub const SharedWorkerContext = struct {
    ref_count: std.atomic.Value(u32),
    allocator: std.mem.Allocator,
    wake_fd: c_int,
    stop: std.atomic.Value(bool),

    history_lock: Mutex,
    history_done: bool = false,
    history_items: [500]ClipItem = @splat(ClipItem{ .id = 0 }),
    history_count: usize = 0,

    decode_lock: Mutex,
    decode_cond: Condition,
    decode_req_id: ?u64 = null,
    decode_res_id: u64 = 0,
    // Staging buffer for clipboard decode payload.
    decode_res_buf: []u8 = &.{},
    decode_res_len: usize = 0,
    decode_res_ready: bool = false,

    pub fn create(allocator: std.mem.Allocator) !*SharedWorkerContext {
        const wake_fd = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
        if (wake_fd < 0) return error.EventFdFailed;

        const ctx = try allocator.create(SharedWorkerContext);
        ctx.* = .{
            .ref_count = std.atomic.Value(u32).init(1),
            .allocator = allocator,
            .wake_fd = wake_fd,
            .stop = std.atomic.Value(bool).init(false),
            .history_lock = Mutex.init(),
            .history_done = false,
            .history_items = @splat(ClipItem{ .id = 0 }),
            .history_count = 0,
            .decode_lock = Mutex.init(),
            .decode_cond = Condition.init(),
            .decode_req_id = null,
            .decode_res_id = 0,
            .decode_res_buf = &.{},
            .decode_res_len = 0,
            .decode_res_ready = false,
        };
        return ctx;
    }

    pub fn acquire(self: *SharedWorkerContext) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *SharedWorkerContext) void {
        if (self.ref_count.fetchSub(1, .release) == 1) {
            _ = self.ref_count.load(.acquire);
            if (self.wake_fd >= 0) {
                _ = c.close(self.wake_fd);
            }
            if (self.decode_res_buf.len > 0) self.allocator.free(self.decode_res_buf);
            self.history_lock.deinit();
            self.decode_lock.deinit();
            self.decode_cond.deinit();
            self.allocator.destroy(self);
        }
    }

    pub fn notifyWake(self: *SharedWorkerContext) void {
        if (self.wake_fd >= 0) {
            const val: u64 = 1;
            _ = c.write(self.wake_fd, &val, @sizeOf(u64));
        }
    }
};

// Process-level session cache for instant warm reopen
var session_cached_items: [500]ClipItem = @splat(ClipItem{ .id = 0 });
var session_cached_count: usize = 0;
var session_has_cache: bool = false;

// Process-level registry of pinned item previews (survives reopen)
var session_pinned_previews: [50][160]u8 = @splat(@splat(0));
var session_pinned_preview_lens: [50]usize = @splat(0);
var session_pinned_count: usize = 0;

pub const VisualLine = struct {
    start: usize,
    end: usize,
    logical_line: usize,
    is_first: bool,
};

pub const MultiLineEditor = struct {
    allocator: std.mem.Allocator,
    text: std.ArrayList(u8),
    cursor_idx: usize = 0,
    selection_anchor: ?usize = null,
    scroll_line: usize = 0,
    caret_visible: bool = true,
    visual_lines: std.ArrayList(VisualLine) = std.ArrayList(VisualLine).empty,
    last_wrap_width: u32 = 0,
    last_wrap_font_size: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) MultiLineEditor {
        return .{
            .allocator = allocator,
            .text = std.ArrayList(u8).empty,
            .cursor_idx = 0,
            .selection_anchor = null,
            .scroll_line = 0,
            .caret_visible = true,
            .visual_lines = std.ArrayList(VisualLine).empty,
        };
    }

    pub fn deinit(self: *MultiLineEditor) void {
        if (self.text.capacity > 0) {
            self.text.deinit(self.allocator);
            self.text = std.ArrayList(u8).empty;
        }
        if (self.visual_lines.capacity > 0) {
            self.visual_lines.deinit(self.allocator);
            self.visual_lines = std.ArrayList(VisualLine).empty;
        }
    }

    pub fn setText(self: *MultiLineEditor, new_text: []const u8) !void {
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(self.allocator, new_text);
        self.cursor_idx = self.text.items.len;
        self.selection_anchor = null;
        self.scroll_line = 0;
        self.caret_visible = true;
        self.visual_lines.clearRetainingCapacity();
    }

    pub fn getText(self: *const MultiLineEditor) []const u8 {
        return self.text.items;
    }

    pub const CursorPos = struct {
        line: usize,
        line_start: usize,
        line_end: usize,
        col_bytes: usize,
    };

    pub fn getCursorPos(self: *const MultiLineEditor, at_idx: usize) CursorPos {
        const clamped = @min(at_idx, self.text.items.len);
        var line: usize = 0;
        var line_start: usize = 0;
        var i: usize = 0;
        while (i < clamped) : (i += 1) {
            if (self.text.items[i] == '\n') {
                line += 1;
                line_start = i + 1;
            }
        }
        var line_end = line_start;
        while (line_end < self.text.items.len and self.text.items[line_end] != '\n' and self.text.items[line_end] != '\r') : (line_end += 1) {}
        return .{
            .line = line,
            .line_start = line_start,
            .line_end = line_end,
            .col_bytes = clamped - line_start,
        };
    }

    pub fn getTotalLines(self: *const MultiLineEditor) usize {
        if (self.visual_lines.items.len > 0) {
            return self.visual_lines.items.len;
        }
        if (self.text.items.len == 0) return 1;
        var count: usize = 1;
        for (self.text.items) |b| {
            if (b == '\n') count += 1;
        }
        return count;
    }

    pub fn getLineBounds(self: *const MultiLineEditor, target_line: usize) ?struct { start: usize, end: usize } {
        var cur_line: usize = 0;
        var line_start: usize = 0;
        var i: usize = 0;
        while (i < self.text.items.len) : (i += 1) {
            if (cur_line == target_line) {
                break;
            }
            if (self.text.items[i] == '\n') {
                cur_line += 1;
                line_start = i + 1;
            }
        }
        if (cur_line != target_line) {
            if (target_line == cur_line and line_start <= self.text.items.len) {
                return .{ .start = line_start, .end = self.text.items.len };
            }
            return null;
        }
        var line_end = line_start;
        while (line_end < self.text.items.len and self.text.items[line_end] != '\n' and self.text.items[line_end] != '\r') : (line_end += 1) {}
        return .{ .start = line_start, .end = line_end };
    }

    pub fn recomputeVisualLines(self: *MultiLineEditor, font: ?*const renderer.Font, size_px: u32, max_w: u32) void {
        self.visual_lines.clearRetainingCapacity();
        self.last_wrap_width = max_w;
        self.last_wrap_font_size = size_px;

        if (self.text.items.len == 0) {
            self.visual_lines.append(self.allocator, .{
                .start = 0,
                .end = 0,
                .logical_line = 0,
                .is_first = true,
            }) catch {};
            return;
        }

        var logical_line: usize = 0;
        var line_start: usize = 0;
        const text = self.text.items;
        const effective_max_w = @max(10, max_w);

        while (line_start < text.len) {
            var line_end = line_start;
            while (line_end < text.len and text[line_end] != '\n' and text[line_end] != '\r') {
                line_end += 1;
            }

            if (line_start == line_end) {
                self.visual_lines.append(self.allocator, .{
                    .start = line_start,
                    .end = line_end,
                    .logical_line = logical_line,
                    .is_first = true,
                }) catch {};
            } else {
                var v_start = line_start;
                var is_first = true;
                while (v_start < line_end) {
                    var v_end = v_start;
                    var last_space: ?usize = null;
                    var curr_idx = v_start;

                    while (curr_idx < line_end) {
                        const next_len = std.unicode.utf8ByteSequenceLength(text[curr_idx]) catch 1;
                        const test_end = @min(curr_idx + next_len, line_end);
                        const test_slice = text[v_start..test_end];
                        const w: u32 = if (font) |f|
                            @constCast(f).measureTextWithSize(test_slice, size_px)
                        else
                            @intCast(test_slice.len * if (size_px > 0) size_px / 2 else 8);

                        if (w > effective_max_w and curr_idx > v_start) {
                            if (last_space) |sp| {
                                if (sp > v_start and sp < curr_idx) {
                                    v_end = sp + 1; // Wrap after space
                                } else {
                                    v_end = curr_idx;
                                }
                            } else {
                                v_end = curr_idx;
                            }
                            break;
                        }
                        if (text[curr_idx] == ' ') {
                            last_space = curr_idx;
                        }
                        curr_idx = test_end;
                        v_end = curr_idx;
                    }

                    if (v_end <= v_start) {
                        const step = std.unicode.utf8ByteSequenceLength(text[v_start]) catch 1;
                        v_end = @min(v_start + step, line_end);
                    }

                    self.visual_lines.append(self.allocator, .{
                        .start = v_start,
                        .end = v_end,
                        .logical_line = logical_line,
                        .is_first = is_first,
                    }) catch {};
                    is_first = false;
                    v_start = v_end;
                }
            }

            logical_line += 1;
            if (line_end < text.len and text[line_end] == '\r') line_end += 1;
            if (line_end < text.len and text[line_end] == '\n') line_end += 1;
            line_start = line_end;
        }

        if (text.len > 0 and (text[text.len - 1] == '\n' or text[text.len - 1] == '\r')) {
            self.visual_lines.append(self.allocator, .{
                .start = text.len,
                .end = text.len,
                .logical_line = logical_line,
                .is_first = true,
            }) catch {};
        }
    }

    pub fn getVisualLineForCursor(self: *const MultiLineEditor) usize {
        if (self.visual_lines.items.len == 0) return 0;
        const cursor = self.cursor_idx;
        var i: usize = 0;
        while (i < self.visual_lines.items.len) : (i += 1) {
            const vl = self.visual_lines.items[i];
            if (cursor < vl.end) return i;
            if (cursor == vl.end) {
                if (i + 1 == self.visual_lines.items.len) return i;
                const next_vl = self.visual_lines.items[i + 1];
                if (next_vl.is_first) return i;
                return i + 1;
            }
            if (i + 1 < self.visual_lines.items.len) {
                const next_vl = self.visual_lines.items[i + 1];
                if (cursor < next_vl.start) return i;
            }
        }
        return self.visual_lines.items.len - 1;
    }

    pub fn findClosestCharOnVisualLine(self: *const MultiLineEditor, font: ?*const renderer.Font, size_px: u32, vl: VisualLine, target_x: u32) usize {
        if (vl.start >= vl.end or vl.start >= self.text.items.len) return vl.start;
        const slice = self.text.items[vl.start..vl.end];
        var best_idx = vl.start;
        var best_dist: u32 = target_x;
        var b_idx: usize = 0;

        while (b_idx <= slice.len) {
            const measured: u32 = if (font) |f|
                @constCast(f).measureTextWithSize(slice[0..b_idx], size_px)
            else
                @intCast(b_idx * if (size_px > 0) size_px / 2 else 8);

            const dist = if (measured > target_x) measured - target_x else target_x - measured;
            if (dist < best_dist) {
                best_dist = dist;
                best_idx = vl.start + b_idx;
            }
            if (b_idx == slice.len) break;
            const seq_len = std.unicode.utf8ByteSequenceLength(slice[b_idx]) catch 1;
            b_idx += seq_len;
        }
        return best_idx;
    }

    pub fn ensureCursorVisible(self: *MultiLineEditor, max_visible_lines: usize) void {
        const v_line = if (self.visual_lines.items.len > 0)
            self.getVisualLineForCursor()
        else
            self.getCursorPos(self.cursor_idx).line;

        if (v_line < self.scroll_line) {
            self.scroll_line = v_line;
        } else if (v_line >= self.scroll_line + max_visible_lines) {
            self.scroll_line = v_line - max_visible_lines + 1;
        }
    }

    pub fn moveUp(self: *MultiLineEditor) void {
        self.moveUpWithFont(null, 0);
    }

    pub fn moveUpWithFont(self: *MultiLineEditor, font: ?*const renderer.Font, size_px: u32) void {
        if (self.visual_lines.items.len > 0) {
            const cur_v = self.getVisualLineForCursor();
            if (cur_v == 0) {
                self.cursor_idx = 0;
                self.selection_anchor = null;
                self.caret_visible = true;
                self.ensureCursorVisible(20);
                return;
            }
            const cur_vl = self.visual_lines.items[cur_v];
            const prev_vl = self.visual_lines.items[cur_v - 1];

            const cur_slice = if (self.cursor_idx >= cur_vl.start) self.text.items[cur_vl.start..@min(self.cursor_idx, cur_vl.end)] else "";
            const cur_x: u32 = if (font) |f|
                @constCast(f).measureTextWithSize(cur_slice, size_px)
            else
                @intCast(cur_slice.len * if (size_px > 0) size_px / 2 else 8);

            self.cursor_idx = self.findClosestCharOnVisualLine(font, size_px, prev_vl, cur_x);
            self.selection_anchor = null;
            self.caret_visible = true;
            self.ensureCursorVisible(20);
            return;
        }

        const pos = self.getCursorPos(self.cursor_idx);
        if (pos.line == 0) {
            self.cursor_idx = 0;
            self.selection_anchor = null;
            self.caret_visible = true;
            self.ensureCursorVisible(20);
            return;
        }
        if (self.getLineBounds(pos.line - 1)) |prev_bounds| {
            const prev_len = prev_bounds.end - prev_bounds.start;
            const target_col = @min(pos.col_bytes, prev_len);
            var idx = prev_bounds.start + target_col;
            while (idx > prev_bounds.start and idx < prev_bounds.end and (self.text.items[idx] & 0xC0) == 0x80) {
                idx -= 1;
            }
            self.cursor_idx = idx;
        }
        self.selection_anchor = null;
        self.caret_visible = true;
        self.ensureCursorVisible(20);
    }

    pub fn moveDown(self: *MultiLineEditor) void {
        self.moveDownWithFont(null, 0);
    }

    pub fn moveDownWithFont(self: *MultiLineEditor, font: ?*const renderer.Font, size_px: u32) void {
        if (self.visual_lines.items.len > 0) {
            const cur_v = self.getVisualLineForCursor();
            if (cur_v + 1 >= self.visual_lines.items.len) {
                self.cursor_idx = self.text.items.len;
                self.selection_anchor = null;
                self.caret_visible = true;
                self.ensureCursorVisible(20);
                return;
            }
            const cur_vl = self.visual_lines.items[cur_v];
            const next_vl = self.visual_lines.items[cur_v + 1];

            const cur_slice = if (self.cursor_idx >= cur_vl.start) self.text.items[cur_vl.start..@min(self.cursor_idx, cur_vl.end)] else "";
            const cur_x: u32 = if (font) |f|
                @constCast(f).measureTextWithSize(cur_slice, size_px)
            else
                @intCast(cur_slice.len * if (size_px > 0) size_px / 2 else 8);

            self.cursor_idx = self.findClosestCharOnVisualLine(font, size_px, next_vl, cur_x);
            self.selection_anchor = null;
            self.caret_visible = true;
            self.ensureCursorVisible(20);
            return;
        }

        const pos = self.getCursorPos(self.cursor_idx);
        if (self.getLineBounds(pos.line + 1)) |next_bounds| {
            const next_len = next_bounds.end - next_bounds.start;
            const target_col = @min(pos.col_bytes, next_len);
            var idx = next_bounds.start + target_col;
            while (idx > next_bounds.start and idx < next_bounds.end and (self.text.items[idx] & 0xC0) == 0x80) {
                idx -= 1;
            }
            self.cursor_idx = idx;
        } else {
            self.cursor_idx = self.text.items.len;
        }
        self.selection_anchor = null;
        self.caret_visible = true;
        self.ensureCursorVisible(20);
    }

    pub fn moveHome(self: *MultiLineEditor) void {
        if (self.visual_lines.items.len > 0) {
            const v_line = self.getVisualLineForCursor();
            const vl = self.visual_lines.items[v_line];
            if (self.cursor_idx == vl.start and !vl.is_first) {
                var idx = v_line;
                while (idx > 0 and !self.visual_lines.items[idx].is_first) : (idx -= 1) {}
                self.cursor_idx = self.visual_lines.items[idx].start;
            } else {
                self.cursor_idx = vl.start;
            }
            self.selection_anchor = null;
            self.caret_visible = true;
            self.ensureCursorVisible(20);
            return;
        }
        const pos = self.getCursorPos(self.cursor_idx);
        self.cursor_idx = pos.line_start;
        self.selection_anchor = null;
        self.caret_visible = true;
        self.ensureCursorVisible(20);
    }

    pub fn moveEnd(self: *MultiLineEditor) void {
        if (self.visual_lines.items.len > 0) {
            const v_line = self.getVisualLineForCursor();
            const vl = self.visual_lines.items[v_line];
            if (self.cursor_idx == vl.end and v_line + 1 < self.visual_lines.items.len and !self.visual_lines.items[v_line + 1].is_first) {
                var idx = v_line;
                while (idx + 1 < self.visual_lines.items.len and !self.visual_lines.items[idx + 1].is_first) : (idx += 1) {}
                self.cursor_idx = self.visual_lines.items[idx].end;
            } else {
                self.cursor_idx = vl.end;
            }
            self.selection_anchor = null;
            self.caret_visible = true;
            self.ensureCursorVisible(20);
            return;
        }
        const pos = self.getCursorPos(self.cursor_idx);
        self.cursor_idx = pos.line_end;
        self.selection_anchor = null;
        self.caret_visible = true;
        self.ensureCursorVisible(20);
    }

    pub fn moveLeft(self: *MultiLineEditor) void {
        if (self.cursor_idx > 0) {
            var prev = self.cursor_idx - 1;
            while (prev > 0 and (self.text.items[prev] & 0xC0) == 0x80) {
                prev -= 1;
            }
            self.cursor_idx = prev;
        }
        self.selection_anchor = null;
        self.caret_visible = true;
        self.ensureCursorVisible(20);
    }

    pub fn moveRight(self: *MultiLineEditor) void {
        if (self.cursor_idx < self.text.items.len) {
            var next = self.cursor_idx + 1;
            while (next < self.text.items.len and (self.text.items[next] & 0xC0) == 0x80) {
                next += 1;
            }
            self.cursor_idx = next;
        }
        self.selection_anchor = null;
        self.caret_visible = true;
        self.ensureCursorVisible(20);
    }

    pub fn hasSelection(self: *const MultiLineEditor) bool {
        if (self.selection_anchor) |anchor| {
            return anchor != self.cursor_idx;
        }
        return false;
    }

    pub fn getSelectionRange(self: *const MultiLineEditor) ?struct { start: usize, end: usize } {
        if (self.selection_anchor) |anchor| {
            if (anchor == self.cursor_idx) return null;
            return .{
                .start = @min(anchor, self.cursor_idx),
                .end = @max(anchor, self.cursor_idx),
            };
        }
        return null;
    }

    pub fn removeSelection(self: *MultiLineEditor) bool {
        if (self.getSelectionRange()) |range| {
            const count = range.end - range.start;
            var i = range.start;
            while (i + count < self.text.items.len) : (i += 1) {
                self.text.items[i] = self.text.items[i + count];
            }
            self.text.shrinkRetainingCapacity(self.text.items.len - count);
            self.cursor_idx = range.start;
            self.selection_anchor = null;
            return true;
        }
        return false;
    }

    pub fn selectAll(self: *MultiLineEditor) void {
        if (self.text.items.len == 0) return;
        self.selection_anchor = 0;
        self.cursor_idx = self.text.items.len;
        self.caret_visible = true;
    }

    pub fn insertBytes(self: *MultiLineEditor, bytes: []const u8) !void {
        _ = self.removeSelection();
        self.cursor_idx = @min(self.cursor_idx, self.text.items.len);
        try self.text.insertSlice(self.allocator, self.cursor_idx, bytes);
        self.cursor_idx += bytes.len;
        self.selection_anchor = null;
        self.caret_visible = true;
        self.ensureCursorVisible(20);
    }

    pub fn deleteBackward(self: *MultiLineEditor) !void {
        if (self.removeSelection()) {
            self.caret_visible = true;
            self.ensureCursorVisible(20);
            return;
        }
        if (self.cursor_idx == 0 or self.text.items.len == 0) return;

        var prev = self.cursor_idx - 1;
        if (self.text.items[prev] == '\n' and prev > 0 and self.text.items[prev - 1] == '\r') {
            prev -= 1;
        } else {
            while (prev > 0 and (self.text.items[prev] & 0xC0) == 0x80) {
                prev -= 1;
            }
        }
        const count = self.cursor_idx - prev;
        var i = prev;
        while (i + count < self.text.items.len) : (i += 1) {
            self.text.items[i] = self.text.items[i + count];
        }
        self.text.shrinkRetainingCapacity(self.text.items.len - count);
        self.cursor_idx = prev;
        self.caret_visible = true;
        self.ensureCursorVisible(20);
    }

    pub fn deleteForward(self: *MultiLineEditor) !void {
        if (self.removeSelection()) {
            self.caret_visible = true;
            self.ensureCursorVisible(20);
            return;
        }
        if (self.cursor_idx >= self.text.items.len) return;

        var next = self.cursor_idx + 1;
        if (self.text.items[self.cursor_idx] == '\r' and next < self.text.items.len and self.text.items[next] == '\n') {
            next += 1;
        } else {
            while (next < self.text.items.len and (self.text.items[next] & 0xC0) == 0x80) {
                next += 1;
            }
        }
        const count = next - self.cursor_idx;
        var i = self.cursor_idx;
        while (i + count < self.text.items.len) : (i += 1) {
            self.text.items[i] = self.text.items[i + count];
        }
        self.text.shrinkRetainingCapacity(self.text.items.len - count);
        self.caret_visible = true;
        self.ensureCursorVisible(20);
    }

    pub fn deleteWordBackward(self: *MultiLineEditor) void {
        if (self.removeSelection()) {
            self.caret_visible = true;
            self.ensureCursorVisible(20);
            return;
        }
        if (self.cursor_idx == 0) return;
        var start = self.cursor_idx;
        while (start > 0 and self.text.items[start - 1] == ' ') start -= 1;
        while (start > 0 and self.text.items[start - 1] != ' ' and self.text.items[start - 1] != '\n' and self.text.items[start - 1] != '\r' and self.text.items[start - 1] != '\t') start -= 1;
        if (start >= self.cursor_idx) return;
        const count = self.cursor_idx - start;
        var i = start;
        while (i + count < self.text.items.len) : (i += 1) {
            self.text.items[i] = self.text.items[i + count];
        }
        self.text.shrinkRetainingCapacity(self.text.items.len - count);
        self.cursor_idx = start;
        self.caret_visible = true;
        self.ensureCursorVisible(20);
    }

    pub fn deleteToLineStart(self: *MultiLineEditor) void {
        if (self.removeSelection()) {
            self.caret_visible = true;
            self.ensureCursorVisible(20);
            return;
        }
        if (self.cursor_idx == 0) return;
        var line_start: usize = 0;
        var i: usize = 0;
        while (i < self.cursor_idx) : (i += 1) {
            if (self.text.items[i] == '\n' or self.text.items[i] == '\r') line_start = i + 1;
        }
        if (line_start >= self.cursor_idx) return;
        const count = self.cursor_idx - line_start;
        var j = line_start;
        while (j + count < self.text.items.len) : (j += 1) {
            self.text.items[j] = self.text.items[j + count];
        }
        self.text.shrinkRetainingCapacity(self.text.items.len - count);
        self.cursor_idx = line_start;
        self.caret_visible = true;
        self.ensureCursorVisible(20);
    }

    pub fn deleteToEndOfLine(self: *MultiLineEditor) void {
        if (self.removeSelection()) {
            self.caret_visible = true;
            self.ensureCursorVisible(20);
            return;
        }
        if (self.cursor_idx >= self.text.items.len) return;
        var line_end = self.cursor_idx;
        while (line_end < self.text.items.len and self.text.items[line_end] != '\n' and self.text.items[line_end] != '\r') : (line_end += 1) {}
        if (line_end <= self.cursor_idx) return;
        const count = line_end - self.cursor_idx;
        var j = self.cursor_idx;
        while (j + count < self.text.items.len) : (j += 1) {
            self.text.items[j] = self.text.items[j + count];
        }
        self.text.shrinkRetainingCapacity(self.text.items.len - count);
        self.caret_visible = true;
        self.ensureCursorVisible(20);
    }

    pub fn copyToClipboard(self: *const MultiLineEditor) void {
        const to_copy = if (self.getSelectionRange()) |range|
            self.text.items[range.start..range.end]
        else
            self.text.items;
        if (to_copy.len == 0) return;

        const pid = c.fork();
        if (pid == 0) {
            _ = c.setsid();
            const pipe = c.popen("export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; wl-copy 2>/dev/null", "w");
            if (pipe != null) {
                _ = c.fwrite(to_copy.ptr, 1, to_copy.len, pipe);
                _ = c.pclose(pipe);
            }
            c.exit(0);
        }
    }

    pub fn cutToClipboard(self: *MultiLineEditor) void {
        self.copyToClipboard();
        _ = self.removeSelection();
        self.caret_visible = true;
    }

    pub fn pasteFromClipboard(self: *MultiLineEditor) void {
        const pipe = c.popen("export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; wl-paste 2>/dev/null", "r");
        if (pipe != null) {
            defer _ = c.pclose(pipe);
            var buf: [65536]u8 = undefined;
            var total: usize = 0;
            while (total < buf.len) {
                const n = c.fread(buf[total..].ptr, 1, buf.len - total, pipe);
                if (n == 0) break;
                total += n;
            }
            if (total > 0) {
                self.insertBytes(buf[0..total]) catch {};
            }
        }
    }

    pub fn findCursorFromCoords(self: *MultiLineEditor, font: *renderer.Font, size_px: u32, text_x: i32, px: i32, target_line: usize) void {
        if (self.visual_lines.items.len > 0) {
            if (target_line >= self.visual_lines.items.len) {
                self.cursor_idx = self.text.items.len;
                self.selection_anchor = null;
                self.caret_visible = true;
                return;
            }
            const vl = self.visual_lines.items[target_line];
            const rel_x = @max(0, px - text_x);
            self.cursor_idx = self.findClosestCharOnVisualLine(font, size_px, vl, @intCast(rel_x));
            self.selection_anchor = null;
            self.caret_visible = true;
            return;
        }

        const total_lines = self.getTotalLines();
        if (target_line >= total_lines) {
            self.cursor_idx = self.text.items.len;
            self.selection_anchor = null;
            self.caret_visible = true;
            return;
        }
        const bounds = self.getLineBounds(target_line) orelse {
            self.cursor_idx = self.text.items.len;
            self.selection_anchor = null;
            self.caret_visible = true;
            return;
        };
        const rel_x = px - text_x;
        if (rel_x <= 0) {
            self.cursor_idx = bounds.start;
            self.selection_anchor = null;
            self.caret_visible = true;
            return;
        }

        const line_bytes = self.text.items[bounds.start..bounds.end];
        var best_idx = bounds.start;
        var best_dist: i32 = rel_x;
        var b_idx: usize = 0;

        while (b_idx <= line_bytes.len) {
            const measured = @as(i32, @intCast(font.measureTextWithSize(line_bytes[0..b_idx], size_px)));
            const dist = @abs(measured - rel_x);
            if (dist < best_dist) {
                best_dist = @as(i32, @intCast(dist));
                best_idx = bounds.start + b_idx;
            }
            if (b_idx == line_bytes.len) break;
            const seq_len = std.unicode.utf8ByteSequenceLength(line_bytes[b_idx]) catch 1;
            b_idx += seq_len;
        }

        self.cursor_idx = best_idx;
        self.selection_anchor = null;
        self.caret_visible = true;
    }
};

pub const ClipHitArea = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    action: ClipAction,
};

pub const ClipAction = union(enum) {
    none,
    click_card: usize,
    select_item: usize,
    copy_action: usize,
    delete_item: usize,
    clear_all,
    close,
    toggle_qr,
    toggle_share,
    stop_share,
    start_edit: usize,
    save_edit,
    cancel_edit,
    editor_click,
    pin_toggle: usize,
    confirm_cancel,
    confirm_ok,
    confirm_open,
};

const ClipInputDraw = struct {
    panel: *ClipboardPanel,
    size: u32,

    fn draw(target: renderer.Renderer, rect: renderer.Rect, data: *const anyopaque) void {
        const self: *const ClipInputDraw = @ptrCast(@alignCast(data));
        self.panel.input.render(
            target,
            &self.panel.font,
            rect.x,
            rect.y,
            rect.w,
            rect.h,
            rect.x,
            self.panel.cfg.theme.text_bright,
            self.panel.cfg.theme.text_muted,
            self.panel.cfg.theme.accent,
            self.size,
        );
    }
};

const ClipPreviewDraw = struct {
    panel: *ClipboardPanel,
    selected: ?usize,
    scale: u32,

    fn draw(target: renderer.Renderer, rect: renderer.Rect, data: *const anyopaque) void {
        const self: *const ClipPreviewDraw = @ptrCast(@alignCast(data));
        self.panel.renderPreviewColumn(
            target,
            rect.x,
            rect.y,
            rect.w,
            rect.h,
            self.selected,
            self.scale,
        ) catch {};
    }
};

pub const ClipboardPanel = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    font: renderer.Font,

    // 2-column layout dimensions
    width: u32 = 980,
    height: u32 = 620,
    ui_scale: u32 = 1,
    running: bool = true,

    items: std.ArrayList(ClipItem),
    filtered_indices: std.ArrayList(usize),
    input: text_input.TextInput,

    selected_index: usize = 0,
    scroll_offset: usize = 0,

    pointer_x: i32 = -1,
    pointer_y: i32 = -1,

    hit_areas: std.ArrayList(ClipHitArea),
    search_rect: renderer.Rect = .{ .x = 24, .y = 56, .w = 480, .h = 48 },
    show_qr: bool = false,
    show_share_view: bool = false,

    is_editing: bool = false,
    confirm_clear: bool = false,
    confirm_clear_rect: renderer.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    editing_original_id: u64 = 0,
    editor: MultiLineEditor = .{ .allocator = std.heap.page_allocator, .text = std.ArrayList(u8).empty },
    editor_card_rect: renderer.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    history_loading: bool = true,
    decode_cache: DecodedCache = .{},
    image_cache: ImageCache = .{},

    shared: *SharedWorkerContext,
    history_thread: ?std.Thread = null,
    worker_thread: ?std.Thread = null,

    // Incremental search optimization
    prev_query_buf: [128]u8 = @splat(0),
    prev_query_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !ClipboardPanel {
        const font = try renderer.Font.init(allocator, cfg.theme.font_family, cfg.typography.ui);

        const shared = try SharedWorkerContext.create(allocator);
        errdefer shared.release();

        var self = ClipboardPanel{
            .allocator = allocator,
            .cfg = cfg,
            .font = font,
            .items = std.ArrayList(ClipItem).empty,
            .filtered_indices = std.ArrayList(usize).empty,
            .input = text_input.TextInput.init(allocator, "Type to filter...", false),
            .hit_areas = std.ArrayList(ClipHitArea).empty,
            .shared = shared,
            .image_cache = ImageCache.init(allocator),
            .editor = MultiLineEditor.init(allocator),
        };

        self.input.focused = true;
        self.filtered_indices.ensureTotalCapacity(allocator, 500) catch {};
        self.hit_areas.ensureTotalCapacity(allocator, 64) catch {};
        self.show_share_view = false;

        c.mizu_share_set_wake_fd(shared.wake_fd);

        // Preload session cache for instant display.
        if (session_has_cache and session_cached_count > 0) {
            for (session_cached_items[0..session_cached_count]) |item| {
                self.items.append(allocator, item) catch break;
            }
            self.history_loading = false;
            self.updateFilter();
            self.requestDecodeSelected();
        }

        // Spawn background workers.
        shared.acquire();
        self.history_thread = std.Thread.spawn(.{}, historyWorker, .{shared}) catch |err| blk: {
            shared.release();
            std.debug.print("Failed to spawn clipboard historyWorker: {any}\n", .{err});
            break :blk null;
        };

        shared.acquire();
        self.worker_thread = std.Thread.spawn(.{}, decodeWorker, .{shared}) catch |err| blk: {
            shared.release();
            std.debug.print("Failed to spawn clipboard decodeWorker: {any}\n", .{err});
            break :blk null;
        };

        return self;
    }

    pub fn deinit(self: *ClipboardPanel) void {
        // Signal background workers to stop and detach them.
        self.shared.stop.store(true, .release);
        self.shared.decode_lock.lock();
        self.shared.decode_cond.signal();
        self.shared.decode_lock.unlock();

        if (self.worker_thread) |th| {
            th.detach();
            self.worker_thread = null;
        }
        if (self.history_thread) |th| {
            th.detach();
            self.history_thread = null;
        }

        // Release panel reference to shared context.
        self.shared.release();

        self.editor.deinit();
        self.image_cache.deinit();
        self.hit_areas.deinit(self.allocator);
        self.filtered_indices.deinit(self.allocator);
        self.input.deinit();
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.deinit(self.allocator);
        self.font.deinit();
    }

    pub fn getWakeFd(self: *const ClipboardPanel) c_int {
        return self.shared.wake_fd;
    }

    pub fn toggleCaret(self: *ClipboardPanel) void {
        self.input.toggleCaret();
        if (self.is_editing) {
            self.editor.caret_visible = !self.editor.caret_visible;
        }
    }

    /// Process background worker updates. Returns true if redraw needed.
    pub fn tick(self: *ClipboardPanel) bool {
        var changed = false;

        self.shared.history_lock.lock();
        if (self.shared.history_done) {
            self.shared.history_done = false;
            const count = self.shared.history_count;
            for (self.items.items) |*old_item| old_item.deinit(self.allocator);
            self.items.clearRetainingCapacity();
            self.image_cache.clear();
            for (self.shared.history_items[0..count]) |item| {
                var it = item;
                // Restore pinned state for items matching the pinned registry.
                for (0..session_pinned_count) |pi| {
                    const plen = session_pinned_preview_lens[pi];
                    if (plen > 0 and plen == it.preview_len and std.mem.eql(u8, session_pinned_previews[pi][0..plen], it.preview[0..plen])) {
                        it.pinned = true;
                    }
                }
                self.items.append(self.allocator, it) catch break;
            }
            self.history_loading = false;

            session_cached_count = @min(count, session_cached_items.len);
            @memcpy(session_cached_items[0..session_cached_count], self.items.items[0..session_cached_count]);
            session_has_cache = true;
            self.shared.history_lock.unlock();

            self.updateFilter();
            self.requestDecodeSelected();
            changed = true;
        } else {
            self.shared.history_lock.unlock();
        }

        self.shared.decode_lock.lock();
        if (self.shared.decode_res_ready) {
            self.shared.decode_res_ready = false;
            const res_id = self.shared.decode_res_id;
            const res_len_raw = self.shared.decode_res_len;
            const is_image = (res_len_raw & 0x80000000) != 0;
            const res_len = res_len_raw & 0x7FFFFFFF;
            if (res_len > 0) {
                if (is_image) {
                    const image_data = self.shared.decode_res_buf[0..res_len];
                    var img: ?*renderer.Image = null;
                    if (renderer.Image.loadPngFromMemory(self.allocator, image_data)) |png_img| {
                        img = png_img;
                    } else |_| {
                        // PNG decode failed, try JPEG
                        if (renderer.Image.loadJpegFromMemory(self.allocator, image_data)) |jpeg_img| {
                            img = jpeg_img;
                        } else |_| {
                            // Failed to decode as PNG or JPEG
                            img = null;
                        }
                    }
                    if (img) |decoded_img| {
                        const orig_w = decoded_img.width;
                        const orig_h = decoded_img.height;
                        for (self.items.items) |*it| {
                            if (it.id == res_id) {
                                it.image_width = orig_w;
                                it.image_height = orig_h;
                            }
                        }

                        // Downscale oversized images for preview cache.
                        const max_preview_dim: u32 = 1600;
                        var stored_img = decoded_img;
                        if (orig_w > max_preview_dim or orig_h > max_preview_dim) {
                            if (makeThumbnail(self.allocator, decoded_img, max_preview_dim)) |thumb| {
                                decoded_img.deinit();
                                stored_img = thumb;
                            } else |_| {}
                        }
                        self.image_cache.put(res_id, stored_img);
                    }
                } else {
                    // Text content
                    self.decode_cache.put(res_id, self.shared.decode_res_buf[0..res_len]);
                }
            }
            self.shared.decode_lock.unlock();

            // Redraw only if decoded result matches currently selected item.
            if (self.getSelectedId()) |sel_id| {
                if (sel_id == res_id) {
                    changed = true;
                }
            }
        } else {
            self.shared.decode_lock.unlock();
        }

        // 3. Theme hot reload check
        if (theme.loadSavedTheme()) |saved| {
            if (saved != self.cfg.theme.kind) {
                self.cfg.theme = saved.toTheme();
                changed = true;
            }
        }

        return changed;
    }

    pub fn getSelectedId(self: *const ClipboardPanel) ?u64 {
        if (self.filtered_indices.items.len > 0 and self.selected_index < self.filtered_indices.items.len) {
            const actual_idx = self.filtered_indices.items[self.selected_index];
            if (actual_idx < self.items.items.len) {
                return self.items.items[actual_idx].id;
            }
        }
        return null;
    }

    pub fn requestDecode(self: *ClipboardPanel, id: u64) void {
        // Direct wl-paste items (id 999999) are already loaded in preview
        if (id == 999999) return;

        // Reuse cached preview if available
        if (self.decode_cache.get(id) != null) return;

        self.shared.decode_lock.lock();
        defer self.shared.decode_lock.unlock();
        if (self.shared.stop.load(.acquire)) return;
        self.shared.decode_req_id = id;
        self.shared.decode_cond.signal();
    }

    pub fn requestDecodeSelected(self: *ClipboardPanel) void {
        if (self.getSelectedId()) |id| {
            self.requestDecode(id);
        }
    }

    fn decodeWorker(ctx: *SharedWorkerContext) void {
        defer ctx.release();

        while (true) {
            ctx.decode_lock.lock();
            while (!ctx.stop.load(.acquire) and ctx.decode_req_id == null) {
                ctx.decode_cond.wait(&ctx.decode_lock);
            }
            if (ctx.stop.load(.acquire)) {
                ctx.decode_lock.unlock();
                return;
            }
            const id = ctx.decode_req_id.?;
            ctx.decode_req_id = null;
            ctx.decode_lock.unlock();

            // Read large images into heap buffer to prevent truncation.
            const max_decoded_bytes: usize = 64 * 1024 * 1024;
            const result = ctx.allocator.alloc(u8, max_decoded_bytes) catch return;
            defer ctx.allocator.free(result);
            var result_len: usize = 0;
            var cmd_buf: [256]u8 = undefined;
            if (std.fmt.bufPrintSentinel(&cmd_buf, "export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; cliphist decode {d} 2>/dev/null", .{id}, 0)) |cmd| {
                if (c.popen(cmd.ptr, "r")) |pipe| {
                    while (result_len < result.len) {
                        const n = c.fread(result[result_len..].ptr, 1, result.len - result_len, pipe);
                        if (n == 0) break;
                        result_len += n;
                    }
                    _ = c.pclose(pipe);
                }
            } else |_| {}

            // Fallback: satty uses GTK clipboard; try wl-paste direct
            if (result_len == 0) {
                const paste_cmd = "export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; wl-paste --type image/png 2>/dev/null || wl-paste --type image/jpeg 2>/dev/null || wl-paste 2>/dev/null";
                if (c.popen(paste_cmd, "r")) |pipe| {
                    while (result_len < result.len) {
                        const n = c.fread(result[result_len..].ptr, 1, result.len - result_len, pipe);
                        if (n == 0) break;
                        result_len += n;
                    }
                    _ = c.pclose(pipe);
                }
            }

            if (ctx.stop.load(.acquire)) return;

            // Check if result is an image (starts with PNG/JPEG magic bytes)
            const is_png = result_len >= 8 and result[0] == 0x89 and result[1] == 0x50 and result[2] == 0x4E and result[3] == 0x47 and result[4] == 0x0D and result[5] == 0x0A and result[6] == 0x1A and result[7] == 0x0A;
            const is_jpeg = result_len >= 3 and result[0] == 0xFF and result[1] == 0xD8 and result[2] == 0xFF;

            ctx.decode_lock.lock();
            if (!ctx.stop.load(.acquire) and result_len > ctx.decode_res_buf.len) {
                // Grow staging buffer outside lock.
                ctx.decode_lock.unlock();
                const grown = ctx.allocator.alloc(u8, result_len) catch return;
                ctx.decode_lock.lock();
                if (ctx.stop.load(.acquire)) {
                    ctx.allocator.free(grown);
                    ctx.decode_lock.unlock();
                    return;
                }
                if (ctx.decode_res_buf.len > 0) ctx.allocator.free(ctx.decode_res_buf);
                ctx.decode_res_buf = grown;
            }
            if (!ctx.stop.load(.acquire)) {
                const copy_len = @min(result_len, ctx.decode_res_buf.len);
                if (copy_len > 0) {
                    @memcpy(ctx.decode_res_buf[0..copy_len], result[0..copy_len]);
                }
                ctx.decode_res_len = copy_len;
                ctx.decode_res_id = id;
                // Store whether it's an image in the upper bits of decode_res_len (bit 31)
                if (is_png or is_jpeg) {
                    ctx.decode_res_len |= 0x80000000;
                }
                ctx.decode_res_ready = true;
                ctx.decode_lock.unlock();
                ctx.notifyWake();
            } else {
                ctx.decode_lock.unlock();
                return;
            }
        }
    }

    fn historyWorker(ctx: *SharedWorkerContext) void {
        defer ctx.release();

        var result_items: [500]ClipItem = undefined;
        var result_count: usize = 0;

        const pipe = c.popen("export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; cliphist list 2>/dev/null", "r");
        if (pipe) |p| {
            defer _ = c.pclose(p);
            var line_buf: [2048]u8 = undefined;
            while (result_count < result_items.len and c.fgets(&line_buf, @intCast(line_buf.len), p) != null) {
                if (ctx.stop.load(.acquire)) return;

                const raw_line = std.mem.span(@as([*:0]const u8, @ptrCast(&line_buf)));
                const trimmed = std.mem.trim(u8, raw_line, " \r\n");
                if (trimmed.len == 0) continue;

                const tab_idx = std.mem.indexOfScalar(u8, trimmed, '\t') orelse continue;
                const id_str = std.mem.trim(u8, trimmed[0..tab_idx], " ");
                const id = std.fmt.parseInt(u64, id_str, 10) catch continue;
                const content = if (tab_idx + 1 < trimmed.len)
                    std.mem.trim(u8, trimmed[tab_idx + 1 ..], " \t\r\n")
                else
                    "";
                if (content.len == 0) continue;

                // Check if entry contains cliphist binary image marker OR raw PNG/JPEG bytes.
                const is_png = content.len >= 8 and content[0] == 0x89 and content[1] == 0x50 and content[2] == 0x4E and content[3] == 0x47 and content[4] == 0x0D and content[5] == 0x0A and content[6] == 0x1A and content[7] == 0x0A;
                const is_jpeg = content.len >= 2 and content[0] == 0xFF and content[1] == 0xD8;
                const is_image = std.mem.startsWith(u8, content, "[[ binary data") or std.mem.startsWith(u8, content, "[[ binary data ") or is_png or is_jpeg;

                var item = ClipItem{ .id = id, .clip_type = if (is_image) .image else .text };
                const max_p = @min(content.len, item.preview.len);
                const preview_len = trimToValidUtf8(content[0..max_p]);
                @memcpy(item.preview[0..preview_len], content[0..preview_len]);
                item.preview_len = preview_len;
                const max_f = @min(content.len, item.first_line.len);
                const first_len = trimToValidUtf8(content[0..max_f]);
                @memcpy(item.first_line[0..first_len], content[0..first_len]);
                item.first_line_len = first_len;
                item.first_line_loaded = true;
                result_items[result_count] = item;
                result_count += 1;
            }
        }

        // Always include current clipboard directly (satty/GTK may miss cliphist)
        if (result_count < result_items.len) {
            var cmd_buf: [256]u8 = undefined;
            if (std.fmt.bufPrintSentinel(&cmd_buf, "export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; wl-paste --type image/png 2>/dev/null | head -c 1024 | cat; wl-paste --type image/jpeg 2>/dev/null | head -c 1024 | cat; wl-paste 2>/dev/null | head -c 1024 | cat", .{} , 0) catch null) |_| {
                // Actually read binary image directly with wl-paste
                const paste_cmd = "export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; wl-paste --type image/png 2>/dev/null || wl-paste --type image/jpeg 2>/dev/null || wl-paste 2>/dev/null";
                if (c.popen(paste_cmd, "r")) |pipe2| {
                    defer _ = c.pclose(pipe2);
                    var buf: [4096]u8 = undefined;
                    var len: usize = 0;
                    while (len < buf.len) {
                        const n = c.fread(&buf[len], 1, buf.len - len, pipe2);
                        if (n == 0) break;
                        len += n;
                    }
                    if (len > 0) {
                        const is_png = len >= 8 and buf[0] == 0x89 and buf[1] == 0x50 and buf[2] == 0x4E and buf[3] == 0x47;
                        const is_jpeg = len >= 2 and buf[0] == 0xFF and buf[1] == 0xD8;
                        const is_image = is_png or is_jpeg;

                        // Deduplicate: avoid adding if already captured in result_items (e.g. from cliphist)
                        var already_present = false;
                        for (result_items[0..result_count]) |existing| {
                            if (is_image and existing.clip_type == .image) {
                                already_present = true;
                                break;
                            } else if (!is_image and existing.clip_type == .text) {
                                const exist_text = existing.preview[0..existing.preview_len];
                                const paste_text = buf[0..@min(len, 4096)];
                                if (exist_text.len > 0 and (std.mem.startsWith(u8, paste_text, exist_text) or std.mem.startsWith(u8, exist_text, paste_text))) {
                                    already_present = true;
                                    break;
                                }
                            }
                        }

                        if (!already_present) {
                            var item = ClipItem{ .id = 999999, .clip_type = if (is_image) .image else .text };
                            const max_p = @min(len, item.preview.len);
                            const preview_len = trimToValidUtf8(buf[0..max_p]);
                            @memcpy(item.preview[0..preview_len], buf[0..preview_len]);
                            item.preview_len = preview_len;
                            const max_f = @min(len, item.first_line.len);
                            const first_len = trimToValidUtf8(buf[0..max_f]);
                            @memcpy(item.first_line[0..first_len], buf[0..first_len]);
                            item.first_line_len = first_len;
                            item.first_line_loaded = true;
                            result_items[result_count] = item;
                            result_count += 1;
                        }
                    }
                }
            }
        }

        if (ctx.stop.load(.acquire)) return;

        ctx.history_lock.lock();
        if (!ctx.stop.load(.acquire)) {
            @memcpy(ctx.history_items[0..result_count], result_items[0..result_count]);
            ctx.history_count = result_count;
            ctx.history_done = true;
            ctx.history_lock.unlock();
            ctx.notifyWake();
        } else {
            ctx.history_lock.unlock();
        }
    }

    pub fn updateFilter(self: *ClipboardPanel) void {
        const q = self.input.getText();
        const can_incremental = q.len > self.prev_query_len and
            self.prev_query_len > 0 and
            std.mem.startsWith(u8, q, self.prev_query_buf[0..self.prev_query_len]);

        if (q.len == 0) {
            self.filtered_indices.clearRetainingCapacity();
            self.filtered_indices.ensureTotalCapacity(self.allocator, self.items.items.len) catch {};
            for (0..self.items.items.len) |idx| {
                self.filtered_indices.append(self.allocator, idx) catch continue;
            }
        } else if (can_incremental) {
            // Incremental narrowing: scan only previously matching items
            var write_idx: usize = 0;
            for (self.filtered_indices.items) |idx| {
                const item = self.items.items[idx];
                const prev = item.preview[0..item.preview_len];
                if (std.ascii.findIgnoreCase(prev, q) != null) {
                    self.filtered_indices.items[write_idx] = idx;
                    write_idx += 1;
                }
            }
            self.filtered_indices.items.len = write_idx;
        } else {
            self.filtered_indices.clearRetainingCapacity();
            self.filtered_indices.ensureTotalCapacity(self.allocator, self.items.items.len) catch {};
            for (self.items.items, 0..) |item, idx| {
                const prev = item.preview[0..item.preview_len];
                if (std.ascii.findIgnoreCase(prev, q) != null) {
                    self.filtered_indices.append(self.allocator, idx) catch continue;
                }
            }
        }

        // Cache previous query
        const copy_len = @min(q.len, self.prev_query_buf.len);
        @memcpy(self.prev_query_buf[0..copy_len], q[0..copy_len]);
        self.prev_query_len = copy_len;

        if (self.selected_index >= self.filtered_indices.items.len) {
            self.selected_index = if (self.filtered_indices.items.len > 0) self.filtered_indices.items.len - 1 else 0;
        }
        self.adjustScroll();
        self.requestDecodeSelected();
    }

    fn adjustScroll(self: *ClipboardPanel) void {
        const visible_rows: usize = 10;
        if (self.selected_index < self.scroll_offset) {
            self.scroll_offset = self.selected_index;
        } else if (self.selected_index >= self.scroll_offset + visible_rows) {
            self.scroll_offset = self.selected_index - visible_rows + 1;
        }
    }

    pub fn copySelection(self: *ClipboardPanel, actual_idx: usize) void {
        if (actual_idx >= self.items.items.len) return;
        const item = self.items.items[actual_idx];

        if (item.id != 999999) {
            // Decode from cliphist to preserve full multi-line content.
            var cmd_buf: [256]u8 = undefined;
            const cmd = std.fmt.bufPrintSentinel(&cmd_buf, "export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; cliphist decode {d} | wl-copy", .{item.id}, 0) catch return;
            sys_status.spawnCmd(cmd);
        }

        self.running = false;
    }

    pub fn deleteSelection(self: *ClipboardPanel, actual_idx: usize) void {
        if (actual_idx >= self.items.items.len) return;
        const item = self.items.items[actual_idx];

        var cmd_buf: [256]u8 = undefined;
        if (item.id != 999999) {
            const cmd = std.fmt.bufPrintSentinel(&cmd_buf, "export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; printf '{d}\\t' | cliphist delete", .{item.id}, 0) catch return;
            sys_status.spawnCmd(cmd);
        } else {
            sys_status.spawnCmd("export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; wl-copy --clear 2>/dev/null; wl-copy --primary --clear 2>/dev/null");
        }

        // If that was the last item or only 1 item remains, clear system clipboard as well
        if (self.items.items.len <= 1) {
            sys_status.spawnCmd("export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; wl-copy --clear 2>/dev/null; wl-copy --primary --clear 2>/dev/null");
            session_cached_count = 0;
            session_has_cache = false;
        } else if (session_has_cache and session_cached_count > 0) {
            var found_idx: ?usize = null;
            for (session_cached_items[0..session_cached_count], 0..) |ci, i| {
                if (ci.id == item.id) {
                    found_idx = i;
                    break;
                }
            }
            if (found_idx) |fidx| {
                var j = fidx;
                while (j + 1 < session_cached_count) : (j += 1) {
                    session_cached_items[j] = session_cached_items[j + 1];
                }
                session_cached_count -= 1;
                if (session_cached_count == 0) session_has_cache = false;
            }
        }

        self.decode_cache.remove(item.id);
        self.image_cache.remove(item.id);

        if (self.is_editing and self.editing_original_id == item.id) {
            self.cancelEdit();
        }

        var removed = self.items.orderedRemove(actual_idx);
        removed.deinit(self.allocator);
        self.updateFilter();
    }

    fn pinToggleItem(self: *ClipboardPanel, filter_idx: usize, do_reorder: bool) void {
        if (filter_idx >= self.filtered_indices.items.len) return;
        const actual_idx = self.filtered_indices.items[filter_idx];
        self.items.items[actual_idx].pinned = !self.items.items[actual_idx].pinned;
        if (do_reorder) {
            // Move pinned items to the front while preserving relative order.
            var write: usize = 0;
            var i: usize = 0;
            while (i < self.items.items.len) : (i += 1) {
                if (self.items.items[i].pinned) {
                    if (i != write) {
                        const tmp = self.items.items[i];
                        var j = i;
                        while (j > write) : (j -= 1) {
                            self.items.items[j] = self.items.items[j - 1];
                        }
                        self.items.items[write] = tmp;
                    }
                    write += 1;
                }
            }
        }
        self.updateFilter();
    }

    pub fn clearAll(self: *ClipboardPanel) void {
        self.is_editing = false;
        // Record pinned items and re-store them to cliphist so they survive reopen.
        session_pinned_count = 0;
        for (self.items.items) |item| {
            if (!item.pinned) continue;
            if (session_pinned_count >= session_pinned_previews.len) break;
            const plen = item.preview_len;
            const copy_len = @min(plen, 160);
            @memcpy(session_pinned_previews[session_pinned_count][0..copy_len], item.preview[0..copy_len]);
            session_pinned_preview_lens[session_pinned_count] = copy_len;
            session_pinned_count += 1;
        }
        _ = c.system("export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; cliphist wipe 2>/dev/null; wl-copy --clear 2>/dev/null; wl-copy --primary --clear 2>/dev/null");
        sys_status.spawnCmd("export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; cliphist wipe; wl-copy --clear 2>/dev/null; wl-copy --primary --clear 2>/dev/null");
        // Re-store pinned items after wipe
        for (self.items.items) |item| {
            if (!item.pinned) continue;
            const content = self.getDecodedContent(item);
            if (content.len > 0) {
                const ch_pipe = c.popen("export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; cliphist store 2>/dev/null", "w");
                if (ch_pipe) |pipe| {
                    _ = c.fwrite(content.ptr, 1, content.len, pipe);
                    _ = c.pclose(pipe);
                }
            }
        }
        // Remove non-pinned items only, keep pinned ones
        var to_remove = std.ArrayList(usize).empty;
        defer to_remove.deinit(self.allocator);
        to_remove.ensureTotalCapacity(self.allocator, self.items.items.len) catch {};
        for (self.items.items, 0..) |*item, idx| {
            if (!item.pinned) {
                to_remove.append(self.allocator, idx) catch {};
            }
        }
        // Deinit and remove in reverse to keep indices valid
        var ri: usize = to_remove.items.len;
        while (ri > 0) {
            ri -= 1;
            const r_idx = to_remove.items[ri];
            self.items.items[r_idx].deinit(self.allocator);
            _ = self.items.orderedRemove(r_idx);
        }
        self.decode_cache.clear();
        self.image_cache.clear();
        session_cached_count = 0;
        session_has_cache = false;
        self.shared.history_lock.lock();
        self.shared.history_count = 0;
        self.shared.history_done = false;
        self.shared.history_lock.unlock();
        self.selected_index = 0;
        self.updateFilter();
    }

    pub fn getDecodedContent(self: *ClipboardPanel, item: ClipItem) []const u8 {
        if (self.decode_cache.get(item.id)) |cached| {
            return cached;
        }
        return item.preview[0..item.preview_len];
    }

    pub fn getFullContent(self: *ClipboardPanel, item: ClipItem) []const u8 {
        if (self.decode_cache.get(item.id)) |cached| {
            return cached;
        }
        if (item.id != 999999 and item.clip_type == .text) {
            var cmd_buf: [256]u8 = undefined;
            if (std.fmt.bufPrintSentinel(&cmd_buf, "export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; cliphist decode {d} 2>/dev/null", .{item.id}, 0)) |cmd| {
                if (c.popen(cmd.ptr, "r")) |pipe| {
                    defer _ = c.pclose(pipe);
                    var buf: [65536]u8 = undefined;
                    var total: usize = 0;
                    while (total < buf.len) {
                        const n = c.fread(buf[total..].ptr, 1, buf.len - total, pipe);
                        if (n == 0) break;
                        total += n;
                    }
                    if (total > 0) {
                        self.decode_cache.put(item.id, buf[0..total]);
                        if (self.decode_cache.get(item.id)) |cached| {
                            return cached;
                        }
                    }
                }
            } else |_| {}
        }
        return item.preview[0..item.preview_len];
    }

    pub fn startEditing(self: *ClipboardPanel, actual_idx: usize) void {
        if (actual_idx >= self.items.items.len) return;
        const item = self.items.items[actual_idx];
        if (item.clip_type != .text) return;

        // Decode directly for editing so content > 8KB is not truncated by preview cache
        if (item.id != 999999) {
            var cmd_buf: [256]u8 = undefined;
            if (std.fmt.bufPrintSentinel(&cmd_buf, "export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; cliphist decode {d} 2>/dev/null", .{item.id}, 0)) |cmd| {
                if (c.popen(cmd.ptr, "r")) |pipe| {
                    defer _ = c.pclose(pipe);
                    var buf = std.ArrayList(u8).empty;
                    defer buf.deinit(self.allocator);
                    var chunk: [4096]u8 = undefined;
                    while (true) {
                        const n = c.fread(&chunk, 1, chunk.len, pipe);
                        if (n == 0) break;
                        buf.appendSlice(self.allocator, chunk[0..n]) catch break;
                    }
                    if (buf.items.len > 0) {
                        self.editor.setText(buf.items) catch return;
                        self.is_editing = true;
                        self.editing_original_id = item.id;
                        self.input.focused = false;
                        self.show_qr = false;
                        return;
                    }
                }
            } else |_| {}
        }

        const content = self.getFullContent(item);
        self.editor.setText(content) catch return;
        self.is_editing = true;
        self.editing_original_id = item.id;
        self.input.focused = false;
        self.show_qr = false;
    }

    pub fn cancelEdit(self: *ClipboardPanel) void {
        self.is_editing = false;
        self.input.focused = true;
    }

    pub fn saveEdit(self: *ClipboardPanel) void {
        if (!self.is_editing) return;
        const edited_text = self.editor.getText();

        // 1. Copy to system Wayland clipboard using wl-copy
        {
            const pipe = c.popen("export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; wl-copy 2>/dev/null", "w");
            if (pipe != null) {
                if (edited_text.len > 0) {
                    _ = c.fwrite(edited_text.ptr, 1, edited_text.len, pipe);
                }
                _ = c.pclose(pipe);
            }
        }

        // 2. Also pipe into cliphist so cliphist persists it
        {
            const ch_pipe = c.popen("export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; cliphist store 2>/dev/null", "w");
            if (ch_pipe != null) {
                if (edited_text.len > 0) {
                    _ = c.fwrite(edited_text.ptr, 1, edited_text.len, ch_pipe);
                }
                _ = c.pclose(ch_pipe);
            }
        }

        // 3. Create new ClipItem and insert at beginning of items list (old item stays!)
        var max_id: u64 = 1000;
        for (self.items.items) |item| {
            if (item.id != 999999 and item.id > max_id) {
                max_id = item.id;
            }
        }
        const new_id = max_id + 1;

        var new_item = ClipItem{
            .id = new_id,
            .clip_type = .text,
        };
        const max_p = @min(edited_text.len, new_item.preview.len);
        const preview_len = trimToValidUtf8(edited_text[0..max_p]);
        @memcpy(new_item.preview[0..preview_len], edited_text[0..preview_len]);
        new_item.preview_len = preview_len;
        loadItemFirstLine(&new_item);

        // Cache the full decoded content in decode_cache under new_id
        self.decode_cache.put(new_id, edited_text);

        // Insert new item at index 0 (top of history)
        self.items.insert(self.allocator, 0, new_item) catch {};

        // Update session cache if warm reopen cache is active
        if (session_has_cache and session_cached_count < session_cached_items.len) {
            var j = session_cached_count;
            while (j > 0) : (j -= 1) {
                session_cached_items[j] = session_cached_items[j - 1];
            }
            session_cached_items[0] = new_item;
            session_cached_count += 1;
        }

        // Update filter and select the new item
        self.updateFilter();
        self.selected_index = 0;
        self.scroll_offset = 0;

        // Exit editing mode
        self.is_editing = false;
        self.input.focused = true;
    }

    pub fn handleEditorClick(self: *ClipboardPanel, px: i32, py: i32, scale: u32) void {
        if (!self.is_editing) return;
        const iscale: i32 = @intCast(scale);
        const card_x_log = @divTrunc(self.editor_card_rect.x, iscale);
        const card_y_log = @divTrunc(self.editor_card_rect.y, iscale);
        const gutter_x_log = card_x_log + 40;
        const text_x_log = gutter_x_log + 12;
        const line_step_log: i32 = 24;
        const rel_y = py - (card_y_log + 12);
        if (rel_y < 0) return;
        const line_offset = @as(usize, @intCast(@divTrunc(rel_y, line_step_log)));
        const target_line = self.editor.scroll_line + line_offset;
        self.editor.findCursorFromCoords(&self.font, self.cfg.typography.ui * scale, text_x_log, px, target_line);
    }

    pub fn isAreaHovered(self: *const ClipboardPanel, x: i32, y: i32, w: u32, h: u32) bool {
        if (self.pointer_x < 0 or self.pointer_y < 0) return false;
        return (self.pointer_x >= x and self.pointer_x < x + @as(i32, @intCast(w)) and
            self.pointer_y >= y and self.pointer_y < y + @as(i32, @intCast(h)));
    }

    pub fn handlePointerMotion(self: *ClipboardPanel, x: i32, y: i32) bool {
        self.pointer_x = x;
        self.pointer_y = y;

        if (self.input.drag_active) {
            const text_ox = self.search_rect.x + 40;
            _ = self.input.handlePointerMotion(x, text_ox, &self.font);
            return true;
        }

        return true;
    }

    pub fn handlePointerLeave(self: *ClipboardPanel) bool {
        self.pointer_x = -1;
        self.pointer_y = -1;
        return true;
    }

    pub fn handlePointerButton(self: *ClipboardPanel, x: i32, y: i32, button: u32, is_pressed: bool) bool {
        if (button != 272) return false; // BTN_LEFT

        if (is_pressed) {
            const text_ox = self.search_rect.x + 40;
            if (self.input.handlePointerDown(x, y, self.search_rect.x, self.search_rect.y, self.search_rect.w, self.search_rect.h, text_ox, &self.font)) {
                if (self.is_editing) {
                    self.cancelEdit();
                }
                return true;
            }

            for (self.hit_areas.items) |area| {
                if (x >= area.x and x < area.x + @as(i32, @intCast(area.w)) and
                    y >= area.y and y < area.y + @as(i32, @intCast(area.h)))
                {
                    switch (area.action) {
                        .none => {},
                        .click_card => |filter_idx| {
                            if (self.is_editing) {
                                self.cancelEdit();
                            }
                            self.show_share_view = false;
                            if (self.selected_index == filter_idx) {
                                if (filter_idx < self.filtered_indices.items.len) {
                                    const actual_idx = self.filtered_indices.items[filter_idx];
                                    self.copySelection(actual_idx);
                                }
                            } else {
                                self.selected_index = filter_idx;
                                self.adjustScroll();
                                self.requestDecodeSelected();
                            }
                        },
                        .select_item => |actual_idx| self.copySelection(actual_idx),
                        .copy_action => |actual_idx| self.copySelection(actual_idx),
                        .delete_item => |actual_idx| self.deleteSelection(actual_idx),
                        .clear_all => self.clearAll(),
                        .close => self.running = false,
                        .toggle_qr => {
                            self.show_qr = !self.show_qr;
                        },
                        .toggle_share => {
                            if (c.mizu_share_is_running() == 0) {
                                _ = c.mizu_share_start();
                                self.show_share_view = true;
                            } else {
                                self.show_share_view = !self.show_share_view;
                            }
                        },
                        .stop_share => {
                            c.mizu_share_stop();
                            self.show_share_view = false;
                        },
                        .start_edit => |filter_idx| {
                            if (filter_idx < self.filtered_indices.items.len) {
                                self.selected_index = filter_idx;
                                self.adjustScroll();
                                const actual_idx = self.filtered_indices.items[filter_idx];
                                self.startEditing(actual_idx);
                            }
                        },
                        .save_edit => {
                            self.saveEdit();
                        },
                        .cancel_edit => {
                            self.cancelEdit();
                        },
                        .confirm_cancel => {
                            self.confirm_clear = false;
                        },
                        .confirm_ok => {
                            self.clearAll();
                            self.confirm_clear = false;
                        },
                        .confirm_open => {
                            self.confirm_clear = true;
                        },
                        .pin_toggle => |filter_idx| {
                            self.pinToggleItem(filter_idx, true);
                        },
                        .editor_click => {
                            self.handleEditorClick(x, y, self.ui_scale);
                        },
                    }
                    return true;
                }
            }
        } else {
            self.input.handlePointerUp();
            return true;
        }

        return false;
    }

    pub fn handlePointerAxis(self: *ClipboardPanel, x: i32, y: i32, delta: i32) bool {
        _ = y;
        const col1_w = @as(i32, @intCast(460));

        if (self.is_editing and x >= col1_w) {
            const total_lines = self.editor.getTotalLines();
            const max_visible: usize = 20;
            if (delta > 0) {
                if (self.editor.scroll_line + max_visible < total_lines) {
                    self.editor.scroll_line += 1;
                    return true;
                }
            } else if (delta < 0) {
                if (self.editor.scroll_line > 0) {
                    self.editor.scroll_line -= 1;
                    return true;
                }
            }
            return false;
        }

        const total = self.filtered_indices.items.len;
        if (total == 0) return false;

        const visible_rows: usize = 10;
        const max_scroll = total -| visible_rows;

        if (delta > 0) {
            if (self.scroll_offset < max_scroll) {
                self.scroll_offset += 1;
                if (self.selected_index < self.scroll_offset) {
                    self.selected_index = self.scroll_offset;
                }
                self.requestDecodeSelected();
                return true;
            } else if (self.selected_index + 1 < total) {
                self.selected_index += 1;
                self.requestDecodeSelected();
                return true;
            }
        } else if (delta < 0) {
            if (self.scroll_offset > 0) {
                self.scroll_offset -= 1;
                if (self.selected_index >= self.scroll_offset + visible_rows) {
                    self.selected_index = self.scroll_offset + visible_rows - 1;
                }
                self.requestDecodeSelected();
                return true;
            } else if (self.selected_index > 0) {
                self.selected_index -= 1;
                self.requestDecodeSelected();
                return true;
            }
        }
        return false;
    }

    pub fn handleKey(self: *ClipboardPanel, sym: u32, utf8_bytes: []const u8, ctrl: bool, shift: bool) bool {
        if (self.is_editing) {
            if (sym == c.XKB_KEY_Escape) {
                self.cancelEdit();
                return true;
            }
            if (ctrl and (sym == c.XKB_KEY_s or sym == c.XKB_KEY_S)) {
                self.saveEdit();
                return true;
            }
            if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_KP_Enter) {
                if (ctrl) {
                    self.saveEdit();
                    return true;
                }
                self.editor.insertBytes("\n") catch {};
                return true;
            }
            if (ctrl) {
                switch (sym) {
                    c.XKB_KEY_a, c.XKB_KEY_A => {
                        self.editor.selectAll();
                        return true;
                    },
                    c.XKB_KEY_c, c.XKB_KEY_C => {
                        self.editor.copyToClipboard();
                        return true;
                    },
                    c.XKB_KEY_x, c.XKB_KEY_X => {
                        self.editor.cutToClipboard();
                        return true;
                    },
                    c.XKB_KEY_v, c.XKB_KEY_V => {
                        self.editor.pasteFromClipboard();
                        return true;
                    },
                    c.XKB_KEY_w, c.XKB_KEY_W => {
                        self.editor.deleteWordBackward();
                        return true;
                    },
                    c.XKB_KEY_u, c.XKB_KEY_U => {
                        self.editor.deleteToLineStart();
                        return true;
                    },
                    c.XKB_KEY_k, c.XKB_KEY_K => {
                        self.editor.deleteToEndOfLine();
                        return true;
                    },
                    c.XKB_KEY_h, c.XKB_KEY_H => {
                        self.editor.deleteBackward() catch {};
                        return true;
                    },
                    c.XKB_KEY_d, c.XKB_KEY_D => {
                        self.editor.deleteForward() catch {};
                        return true;
                    },
                    c.XKB_KEY_b, c.XKB_KEY_B => {
                        self.editor.moveLeft();
                        return true;
                    },
                    c.XKB_KEY_f, c.XKB_KEY_F => {
                        self.editor.moveRight();
                        return true;
                    },
                    c.XKB_KEY_e, c.XKB_KEY_E => {
                        self.editor.moveEnd();
                        return true;
                    },
                    else => {},
                }
            }
            switch (sym) {
                c.XKB_KEY_Up => {
                    self.editor.moveUpWithFont(&self.font, self.cfg.typography.ui * self.ui_scale);
                    return true;
                },
                c.XKB_KEY_Down => {
                    self.editor.moveDownWithFont(&self.font, self.cfg.typography.ui * self.ui_scale);
                    return true;
                },
                c.XKB_KEY_Left => {
                    self.editor.moveLeft();
                    return true;
                },
                c.XKB_KEY_Right => {
                    self.editor.moveRight();
                    return true;
                },
                c.XKB_KEY_Home => {
                    self.editor.moveHome();
                    return true;
                },
                c.XKB_KEY_End => {
                    self.editor.moveEnd();
                    return true;
                },
                c.XKB_KEY_BackSpace => {
                    self.editor.deleteBackward() catch {};
                    return true;
                },
                c.XKB_KEY_Delete => {
                    self.editor.deleteForward() catch {};
                    return true;
                },
                c.XKB_KEY_Tab => {
                    self.editor.insertBytes("    ") catch {};
                    return true;
                },
                else => {
                    if (utf8_bytes.len > 0 and utf8_bytes[0] >= 32 and utf8_bytes[0] != 127) {
                        self.editor.insertBytes(utf8_bytes) catch {};
                        return true;
                    }
                },
            }
            return true;
        }

        // Navigation keys
        if (sym == c.XKB_KEY_Escape) {
            if (self.show_qr) {
                self.show_qr = false;
                return true;
            }
            if (self.show_share_view) {
                self.show_share_view = false;
                return true;
            }
            self.running = false;
            return true;
        } else if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_KP_Enter) {
            if (self.filtered_indices.items.len > 0 and self.selected_index < self.filtered_indices.items.len) {
                const actual_idx = self.filtered_indices.items[self.selected_index];
                self.copySelection(actual_idx);
            }
            return true;
        } else if (sym == c.XKB_KEY_Up) {
            if (self.selected_index > 0) {
                self.selected_index -= 1;
                self.adjustScroll();
                self.requestDecodeSelected();
                return true;
            }
        } else if (sym == c.XKB_KEY_Down) {
            if (self.selected_index + 1 < self.filtered_indices.items.len) {
                self.selected_index += 1;
                self.adjustScroll();
                self.requestDecodeSelected();
                return true;
            }
        } else if (sym == c.XKB_KEY_Left) {
            if (self.input.getText().len == 0 or ctrl) {
                if (self.selected_index > 0) {
                    self.selected_index -= 1;
                    self.adjustScroll();
                    self.requestDecodeSelected();
                }
                return true;
            } else if (self.input.cursor_idx == 0) {
                if (self.selected_index > 0) {
                    self.selected_index -= 1;
                    self.adjustScroll();
                    self.requestDecodeSelected();
                }
                return true;
            }
        } else if (sym == c.XKB_KEY_Right) {
            if (self.input.getText().len == 0 or ctrl) {
                if (self.selected_index + 1 < self.filtered_indices.items.len) {
                    self.selected_index += 1;
                    self.adjustScroll();
                    self.requestDecodeSelected();
                }
                return true;
            } else if (self.input.cursor_idx >= self.input.getText().len) {
                if (self.selected_index + 1 < self.filtered_indices.items.len) {
                    self.selected_index += 1;
                    self.adjustScroll();
                    self.requestDecodeSelected();
                }
                return true;
            }
        } else if (sym == c.XKB_KEY_Page_Up) {
            const jump: usize = @min(self.selected_index, 7);
            self.selected_index -= jump;
            self.adjustScroll();
            self.requestDecodeSelected();
            return true;
        } else if (sym == c.XKB_KEY_Page_Down) {
            self.selected_index = @min(self.filtered_indices.items.len -| 1, self.selected_index + 7);
            self.adjustScroll();
            self.requestDecodeSelected();
            return true;
        } else if (sym == c.XKB_KEY_Delete) {
            if (self.filtered_indices.items.len > 0 and self.selected_index < self.filtered_indices.items.len) {
                const actual_idx = self.filtered_indices.items[self.selected_index];
                self.deleteSelection(actual_idx);
                return true;
            }
        }

        // Text input handling
        const prev_len = self.input.getText().len;
        const handled = self.input.handleKey(sym, utf8_bytes, ctrl, shift);
        if (handled) {
            if (self.input.getText().len != prev_len) {
                self.updateFilter();
            }
            return true;
        }

        return false;
    }

    pub fn render(self: *ClipboardPanel, target: renderer.Renderer, scale: u32) !void {
        self.hit_areas.clearRetainingCapacity();
        self.ui_scale = scale;

        target.clear(theme.Color.transparent);

        const w = target.width;
        const h = target.height;
        const radius: u32 = self.cfg.panel_radius * scale;

        target.drawDropShadow(0, 0, w, h, radius, 10 * scale, self.cfg.theme.shadow_dark);

        const icon_sz = self.cfg.typography.bar_icon * scale;
        const title_sz = self.cfg.typography.title * scale;
        const button_sz = self.cfg.typography.button_text * scale;
        const ui_sz = self.cfg.typography.ui * scale;
        const sec_sz = self.cfg.typography.secondary * scale;
        const col1_w = 460 * scale;

        const total_filtered = self.filtered_indices.items.len;
        const selected_actual: ?usize = if (total_filtered > 0 and self.selected_index < total_filtered)
            self.filtered_indices.items[self.selected_index]
        else
            null;

        var ui = try ui_mod.Ui.begin(
            self.allocator,
            &self.font,
            w,
            h,
            scale,
            self.pointer_x,
            self.pointer_y,
            false,
            1.0 / 60.0,
        );
        defer ui.deinit();

        ui.root(.{
            .direction = .row,
            .padding = .{
                .left = ui.su(24),
                .right = ui.su(24),
                .top = ui.su(20),
                .bottom = ui.su(20),
            },
            .gap = ui.su(16),
            .bg = self.cfg.theme.panel_bg,
            .radius = ui.f(self.cfg.panel_radius),
            .border = ui.su(1),
            .border_color = self.cfg.theme.panel_border,
            .align_y = .top,
        });

        // Left: header, search, list.
        _ = ui.open(.{
            .width = .{ .fixed = @floatFromInt(col1_w) },
            .height = .{ .grow = .{} },
            .direction = .column,
            .gap = 0,
        });

        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .fixed = @floatFromInt(36 * scale) },
            .direction = .row,
            .gap = ui.su(6),
            .align_y = .center,
        });
        _ = ui.open(.{
            .width = .{ .fixed = @floatFromInt(icon_sz) },
            .height = .{ .fixed = @floatFromInt(icon_sz) },
            .align_x = .center,
            .align_y = .center,
        });
        ui.icon("clipboard", icon_sz, self.cfg.theme.accent, 0);
        ui.close();

        var count_buf: [32]u8 = undefined;
        const count_str = if (self.history_loading) "..." else (std.fmt.bufPrint(&count_buf, "{d}", .{self.items.items.len}) catch "");
        ui.text(count_str, .{ .size = title_sz, .color = self.cfg.theme.text_bright });

        ui.spacerSized(.{ .grow = .{} }, .{ .fixed = 0 });

        const is_sharing = c.mizu_share_is_running() != 0;
        const share_hov = ui.hovered("clip-share", 0);
        _ = ui.open(.{
            .id = "clip-share",
            .height = .{ .fixed = @floatFromInt(28 * scale) },
            .direction = .row,
            .gap = ui.su(6),
            .padding = .{ .left = ui.su(8), .right = ui.su(8) },
            .bg = if (self.show_share_view and is_sharing)
                Color.init(42, self.cfg.theme.accent.r, self.cfg.theme.accent.g, self.cfg.theme.accent.b)
            else if (share_hov)
                self.cfg.theme.elevated
            else
                null,
            .radius = ui.f(6),
            .border = if (self.show_share_view and is_sharing) ui.su(1) else 0,
            .border_color = self.cfg.theme.accent,
            .align_x = .center,
            .align_y = .center,
        });
        ui.icon("connect", 14 * scale, if (is_sharing) self.cfg.theme.accent else (if (share_hov) self.cfg.theme.text_bright else self.cfg.theme.text_muted), 0);
        ui.text("Share", .{
            .size = button_sz,
            .color = if (is_sharing) self.cfg.theme.accent else (if (share_hov) self.cfg.theme.text_bright else self.cfg.theme.text_muted),
        });
        ui.text(if (is_sharing) "On" else "Off", .{
            .size = sec_sz,
            .color = if (is_sharing) self.cfg.theme.accent else self.cfg.theme.text_muted,
        });
        ui.close();

        ui.spacerSized(.{ .grow = .{} }, .{ .fixed = 0 });

        if (self.confirm_clear) {
            const cancel_hov = ui.hovered("confirm-cancel", 0);
            _ = ui.open(.{
                .id = "confirm-cancel",
                .width = .{ .fixed = @floatFromInt(30 * scale) },
                .height = .{ .fixed = @floatFromInt(28 * scale) },
                .bg = if (cancel_hov) self.cfg.theme.elevated else null,
                .radius = ui.f(6),
                .align_x = .center,
                .align_y = .center,
            });
            ui.icon("x", 14 * scale, if (cancel_hov) self.cfg.theme.error_color else self.cfg.theme.text_muted, 0);
            ui.close();

            const ok_hov = ui.hovered("confirm-ok", 0);
            _ = ui.open(.{
                .id = "confirm-ok",
                .width = .{ .fixed = @floatFromInt(30 * scale) },
                .height = .{ .fixed = @floatFromInt(28 * scale) },
                .bg = if (ok_hov) Color.init(42, self.cfg.theme.accent.r, self.cfg.theme.accent.g, self.cfg.theme.accent.b) else null,
                .radius = ui.f(6),
                .align_x = .center,
                .align_y = .center,
            });
            ui.icon("check", 14 * scale, if (ok_hov) self.cfg.theme.accent else self.cfg.theme.text_muted, 0);
            ui.close();
        } else {
            const clear_hov = ui.hovered("clip-clear", 0);
            _ = ui.open(.{
                .id = "clip-clear",
                .width = .{ .fixed = @floatFromInt(66 * scale) },
                .height = .{ .fixed = @floatFromInt(28 * scale) },
                .bg = if (clear_hov) self.cfg.theme.elevated else null,
                .radius = ui.f(6),
                .align_x = .center,
                .align_y = .center,
            });
            ui.text("Clear", .{
                .size = button_sz,
                .color = if (clear_hov) self.cfg.theme.error_color else self.cfg.theme.text_muted,
            });
            ui.close();
        }
        ui.close(); // header

        // Search field.
        const is_query_active = self.input.getText().len > 0 or self.input.focused;
        _ = ui.open(.{
            .id = "clip-search",
            .width = .{ .grow = .{} },
            .height = .{ .fixed = @floatFromInt(48 * scale) },
            .direction = .row,
            .padding = .{ .left = ui.su(12), .right = ui.su(12) },
            .gap = ui.su(8),
            .bg = self.cfg.theme.surface,
            .radius = ui.f(self.cfg.theme.radius_pill),
            .border = ui.su(1),
            .border_color = if (is_query_active) self.cfg.theme.accent else self.cfg.theme.border,
            .align_y = .center,
        });
        _ = ui.open(.{
            .width = .{ .fixed = @floatFromInt(icon_sz) },
            .height = .{ .fixed = @floatFromInt(icon_sz) },
            .align_x = .center,
            .align_y = .center,
        });
        ui.icon("search", icon_sz, if (self.input.focused) self.cfg.theme.accent else self.cfg.theme.text_muted, 0);
        ui.close();

        const input_data = try ui.allocator.create(ClipInputDraw);
        input_data.* = .{ .panel = self, .size = ui_sz };
        const input_custom = try ui.allocator.create(ui_mod.Custom);
        input_custom.* = .{ .callback = .{ .function = ClipInputDraw.draw, .data = input_data } };
        ui.custom(.{ .grow = .{} }, .{ .grow = .{} }, input_custom, 0);
        ui.close();
        ui.close(); // search

        // History list.
        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
            .direction = .column,
            .gap = ui.su(1),
            .padding = .{ .top = ui.su(10) },
            .clip_vertical = true,
            .align_y = .top,
        });

        if (total_filtered == 0) {
            _ = ui.open(.{
                .width = .{ .grow = .{} },
                .height = .{ .grow = .{} },
                .direction = .column,
                .align_x = .center,
                .align_y = .center,
                .gap = ui.su(10),
            });
            const empty_msg = if (self.history_loading)
                "Loading clipboard history..."
            else if (self.items.items.len == 0)
                "Clipboard is empty"
            else
                "No matching items";
            ui.icon(if (self.history_loading) "refresh" else "clipboard", title_sz, self.cfg.theme.text_muted, 0);
            ui.text(empty_msg, .{ .size = ui_sz, .color = self.cfg.theme.text_muted });
            ui.close();
        } else {
            const visible_rows: usize = 10;
            var r: usize = 0;
            const count_this_page = @min(visible_rows, total_filtered - self.scroll_offset);
            while (r < visible_rows and (self.scroll_offset + r) < total_filtered) : (r += 1) {
                const filter_idx = self.scroll_offset + r;
                const actual_idx = self.filtered_indices.items[filter_idx];
                const item = self.items.items[actual_idx];
                const is_selected = (filter_idx == self.selected_index);
                const card_hov = ui.hovered("clip-card", @intCast(r));

                const row_first = (r == 0);
                const row_last = (r == count_this_page - 1);

                const row_bg: ?Color = if (is_selected)
                    Color.init(42, self.cfg.theme.accent.r, self.cfg.theme.accent.g, self.cfg.theme.accent.b)
                else if (card_hov)
                    self.cfg.theme.card_hover_bg
                else
                    self.cfg.theme.card_bg;

                _ = ui.open(.{
                    .id = "clip-card",
                    .index = @intCast(r),
                    .width = .{ .grow = .{} },
                    .height = .{ .fixed = @floatFromInt(48 * scale) },
                    .direction = .row,
                    .padding = .{ .left = ui.su(12), .right = ui.su(10) },
                    .gap = ui.su(8),
                    .bg = row_bg,
                    .radius_top = if (row_first) ui.f(10) else 0,
                    .radius_bottom = if (row_last) ui.f(10) else 0,
                    .border = if (item.pinned) ui.su(1) else 0,
                    .border_color = if (item.pinned) self.cfg.theme.accent else self.cfg.theme.border,
                    .align_y = .center,
                });

                // Pin icon (only on hover, with bg)
                const pin_hov = ui.hovered("clip-pin-btn", @intCast(r));
                if (card_hov or item.pinned) {
                    _ = ui.open(.{
                        .id = "clip-pin-btn",
                        .index = @intCast(r),
                        .width = .{ .fixed = @floatFromInt(28 * scale) },
                        .height = .{ .fixed = @floatFromInt(28 * scale) },
                        .direction = .column,
                        .bg = if (pin_hov or item.pinned) Color.init(40, self.cfg.theme.accent.r, self.cfg.theme.accent.g, self.cfg.theme.accent.b) else null,
                        .radius = ui.f(6),
                        .align_x = .center,
                        .align_y = .center,
                    });
                    ui.icon("pin", 16 * scale, if (pin_hov) self.cfg.theme.accent else (if (item.pinned) self.cfg.theme.accent else self.cfg.theme.text_muted), 0);
                    ui.close();
                }

                const first_line = if (item.first_line_len > 0) item.first_line[0..item.first_line_len] else item.preview[0..item.preview_len];
                var clean_buf: [160]u8 = undefined;
                var clean_len: usize = 0;
                for (first_line) |b| {
                    if (clean_len >= clean_buf.len) break;
                    if (b == '\n' or b == '\r') break;
                    clean_buf[clean_len] = if (b == '\t') ' ' else b;
                    clean_len += 1;
                }
                clean_len = trimToValidUtf8(clean_buf[0..clean_len]);
                const clean_slice = std.mem.trim(u8, clean_buf[0..clean_len], " ");

                var trunc_buf: [160]u8 = undefined;
                const t_str = truncateStr(target, &self.font, clean_slice, col1_w -| 96 * scale, &trunc_buf);

                // Show image info for image items, text preview for text items
                var display_str: []const u8 = t_str;
                if (item.clip_type == .image) {
                    // Show image label with dimensions instead of binary garbage
                    var img_info_buf: [128]u8 = undefined;
                    const img_str = std.fmt.bufPrint(&img_info_buf, "Image · {d}x{d} · {s}", .{ item.image_width, item.image_height, if (item.image_format.len > 0) item.image_format else "unknown" }) catch "Image";
                    display_str = img_str;
                }

                _ = ui.open(.{
                    .width = .{ .grow = .{} },
                    .height = .{ .grow = .{} },
                    .align_y = .center,
                    .clip_horizontal = true,
                });
                ui.text(display_str, .{
                    .size = self.cfg.typography.ui * scale,
                    .color = if (is_selected) self.cfg.theme.text_bright else self.cfg.theme.text_main,
                });
                ui.close();

                // Trash icon (only on hover) on right
                const del_hov = ui.hovered("clip-del", @intCast(r));
                if (card_hov or del_hov) {
                    _ = ui.open(.{
                        .id = "clip-del",
                        .index = @intCast(r),
                        .width = .{ .fixed = @floatFromInt(30 * scale) },
                        .height = .{ .fixed = @floatFromInt(30 * scale) },
                        .bg = if (del_hov) Color.init(45, self.cfg.theme.error_color.r, self.cfg.theme.error_color.g, self.cfg.theme.error_color.b) else null,
                        .radius = ui.f(6),
                        .align_x = .center,
                        .align_y = .center,
                    });
                    ui.icon("trash", 15 * scale, if (del_hov) self.cfg.theme.error_color else Color.init(90, self.cfg.theme.text_muted.r, self.cfg.theme.text_muted.g, self.cfg.theme.text_muted.b), 0);
                    ui.close();
                }

                ui.close(); // card
            }
        }
        ui.close(); // list
        ui.close(); // left column

        ui.rect(.{ .fixed = @floatFromInt(scale) }, .{ .grow = .{} }, Color.init(30, self.cfg.theme.border.r, self.cfg.theme.border.g, self.cfg.theme.border.b), 0, .{});

        // Right: live preview uses the existing renderer through a Clay custom leaf.
        const preview_data = try ui.allocator.create(ClipPreviewDraw);
        preview_data.* = .{ .panel = self, .selected = selected_actual, .scale = scale };
        const preview_custom = try ui.allocator.create(ui_mod.Custom);
        preview_custom.* = .{ .callback = .{ .function = ClipPreviewDraw.draw, .data = preview_data } };
        ui.custom(.{ .grow = .{} }, .{ .grow = .{} }, preview_custom, 0);
        ui.close(); // preview

        ui.close(); // root

        const commands = ui.endLayout();
        const iscale: i32 = @intCast(scale);
        if (ui.rectOf("clip-search", 0)) |rect| {
            self.search_rect = .{
                .x = @divTrunc(rect.x, iscale),
                .y = @divTrunc(rect.y, iscale),
                .w = @intCast(@divTrunc(@as(i32, @intCast(rect.w)) + iscale - 1, iscale)),
                .h = @intCast(@divTrunc(@as(i32, @intCast(rect.h)) + iscale - 1, iscale)),
            };
        }
        if (ui.rectOf("clip-clear", 0)) |rect| {
            try self.appendHitRect(rect, iscale, .confirm_open);
        }
        if (ui.rectOf("clip-share", 0)) |rect| {
            try self.appendHitRect(rect, iscale, .toggle_share);
        }
        if (ui.rectOf("confirm-cancel", 0)) |rect| {
            try self.appendHitRect(rect, iscale, .confirm_cancel);
        }
        if (ui.rectOf("confirm-ok", 0)) |rect| {
            try self.appendHitRect(rect, iscale, .confirm_ok);
        }
        if (total_filtered > 0) {
            const visible_rows: usize = 10;
            var r: usize = 0;
            while (r < visible_rows and (self.scroll_offset + r) < total_filtered) : (r += 1) {
                const filter_idx = self.scroll_offset + r;
                const actual_idx = self.filtered_indices.items[filter_idx];
                const item = self.items.items[actual_idx];
                // Delete is appended first so it wins the overlap test.
                if (ui.rectOf("clip-del", @intCast(r))) |rect| {
                    try self.appendHitRect(rect, iscale, .{ .delete_item = actual_idx });
                }
                if (ui.rectOf("clip-edit-btn", @intCast(r))) |rect| {
                    if (item.clip_type == .text) {
                        try self.appendHitRect(rect, iscale, .{ .start_edit = filter_idx });
                    }
                }
                if (ui.rectOf("clip-pin-btn", @intCast(r))) |rect| {
                    try self.appendHitRect(rect, iscale, .{ .pin_toggle = filter_idx });
                }
                if (ui.rectOf("clip-card", @intCast(r))) |rect| {
                    try self.appendHitRect(rect, iscale, .{ .click_card = filter_idx });
                }
            }
        }

        ui.render(target, commands);
    }

    fn appendHitRect(self: *ClipboardPanel, rect: renderer.Rect, iscale: i32, action: ClipAction) !void {
        const lw: u32 = @intCast(@divTrunc(@as(i32, @intCast(rect.w)) + iscale - 1, iscale));
        const lh: u32 = @intCast(@divTrunc(@as(i32, @intCast(rect.h)) + iscale - 1, iscale));
        if (lw == 0 or lh == 0) return;
        try self.hit_areas.append(self.allocator, .{
            .x = @divTrunc(rect.x, iscale),
            .y = @divTrunc(rect.y, iscale),
            .w = lw,
            .h = lh,
            .action = action,
        });
    }

    fn renderShareView(
        self: *ClipboardPanel,
        target: renderer.Renderer,
        x: i32,
        y: i32,
        w: u32,
        card_h: u32,
        card_y: i32,
        scale: u32,
    ) !void {
        const iscale: i32 = @intCast(scale);
        const sec_sz = self.cfg.typography.secondary * scale;
        const ui_sz = self.cfg.typography.ui * scale;

        icons.drawSvgIcon(
            target,
            self.allocator,
            "connect",
            16 * scale,
            scale,
            x + 10 * iscale,
            y + 14 * iscale,
            self.cfg.theme.accent,
        );
        target.drawTextWithSize(&self.font, "Mizu Share", x + 24 * iscale, y + 20 * iscale, ui_sz, self.cfg.theme.text_bright);

        const off_btn_w: u32 = 44 * scale;
        const off_btn_h: u32 = 24 * scale;
        const off_btn_x = x + @as(i32, @intCast(w)) - @as(i32, @intCast(off_btn_w));
        const off_btn_y = y + 4 * iscale;
        const off_hov = self.isAreaHovered(@divTrunc(off_btn_x, iscale), @divTrunc(off_btn_y, iscale), 44, 24);

        target.fillSquircle(off_btn_x, off_btn_y, off_btn_w, off_btn_h, 6 * scale, if (off_hov) self.cfg.theme.elevated else self.cfg.theme.surface);
        target.drawSquircleBorder(off_btn_x, off_btn_y, off_btn_w, off_btn_h, 6 * scale, 1, self.cfg.theme.border);
        const off_w = target.measureTextWithSize(&self.font, "Off", sec_sz);
        target.drawTextWithSize(
            &self.font,
            "Off",
            off_btn_x + @divTrunc(@as(i32, @intCast(off_btn_w)) - @as(i32, @intCast(off_w)), 2),
            off_btn_y + 17 * iscale,
            sec_sz,
            if (off_hov) self.cfg.theme.error_color else self.cfg.theme.text_muted,
        );

        try self.hit_areas.append(self.allocator, .{
            .x = @divTrunc(off_btn_x, iscale),
            .y = @divTrunc(off_btn_y, iscale),
            .w = 44,
            .h = 24,
            .action = .stop_share,
        });

        target.fillSquircle(x, card_y, w, card_h, 10 * scale, self.cfg.theme.surface);
        target.drawSquircleBorder(x, card_y, w, card_h, 10 * scale, 1, self.cfg.theme.border);

        const raw_url = c.mizu_share_get_url();
        const url = if (raw_url != null) std.mem.span(raw_url) else "";
        if (url.len > 0) {
            const qr_opt = generateQr(url);
            if (qr_opt) |qr| {
                const quiet_zone: u32 = 2;
                const total_modules = qr.size + quiet_zone * 2;

                const max_line_w = if (w > 48 * scale) w - 48 * scale else w;
                var final_lines: [4][]const u8 = undefined;
                var final_count: usize = 0;

                if (target.measureTextWithSize(&self.font, url, sec_sz) <= max_line_w) {
                    final_lines[0] = url;
                    final_count = 1;
                } else {
                    var raw_parts: [2][]const u8 = undefined;
                    var raw_part_count: usize = 1;
                    raw_parts[0] = url;
                    if (std.mem.indexOfScalar(u8, url, '?')) |q_idx| {
                        raw_parts[0] = url[0..q_idx];
                        raw_parts[1] = url[q_idx..];
                        raw_part_count = 2;
                    }

                    for (raw_parts[0..raw_part_count]) |raw_part| {
                        var cur = raw_part;
                        while (cur.len > 0 and final_count < final_lines.len) {
                            if (target.measureTextWithSize(&self.font, cur, sec_sz) <= max_line_w) {
                                final_lines[final_count] = cur;
                                final_count += 1;
                                break;
                            }
                            var split_idx = cur.len;
                            while (split_idx > 1 and target.measureTextWithSize(&self.font, cur[0..split_idx], sec_sz) > max_line_w) {
                                split_idx -= 1;
                            }
                            final_lines[final_count] = cur[0..split_idx];
                            final_count += 1;
                            cur = cur[split_idx..];
                        }
                    }
                }

                const text_h: u32 = @intCast(final_count * 18 * scale);
                const reserved_v: u32 = (40 * scale) + text_h;
                const max_box = @min(if (w > 48 * scale) w - 48 * scale else w, if (card_h > reserved_v) card_h - reserved_v else card_h);
                const mod_size = @max(1, max_box / total_modules);
                const qr_px = total_modules * mod_size;
                const qr_box_x = x + @divTrunc(@as(i32, @intCast(w)) - @as(i32, @intCast(qr_px)), 2);

                const total_content_h: i32 = @as(i32, @intCast(qr_px + (16 * scale))) + @as(i32, @intCast(text_h));
                const qr_box_y = card_y + @max(16 * iscale, @divTrunc(@as(i32, @intCast(card_h)) - total_content_h, 2));

                target.fillSquircle(qr_box_x, qr_box_y, qr_px, qr_px, 8 * scale, theme.Color.rgb(255, 255, 255));
                target.drawSquircleBorder(qr_box_x, qr_box_y, qr_px, qr_px, 8 * scale, 1, theme.Color.rgb(200, 200, 200));

                var qy: u32 = 0;
                while (qy < qr.size) : (qy += 1) {
                    var qx: u32 = 0;
                    while (qx < qr.size) : (qx += 1) {
                        if (qr.isDark(qx, qy)) {
                            const mx = qr_box_x + @as(i32, @intCast((quiet_zone + qx) * mod_size));
                            const my = qr_box_y + @as(i32, @intCast((quiet_zone + qy) * mod_size));
                            target.fillRect(mx, my, mod_size, mod_size, theme.Color.rgb(0, 0, 0));
                        }
                    }
                }

                var cur_y = qr_box_y + @as(i32, @intCast(qr_px)) + 18 * iscale;
                for (final_lines[0..final_count]) |ln| {
                    const lw = target.measureTextWithSize(&self.font, ln, sec_sz);
                    const lx = x + @divTrunc(@as(i32, @intCast(w)) - @as(i32, @intCast(lw)), 2);
                    target.drawTextWithSize(&self.font, ln, lx, cur_y, sec_sz, self.cfg.theme.accent);
                    cur_y += 18 * iscale;
                }
            }
        }
    }

    fn renderEditor(
        self: *ClipboardPanel,
        target: renderer.Renderer,
        x: i32,
        y: i32,
        w: u32,
        h: u32,
        scale: u32,
    ) !void {
        const iscale: i32 = @intCast(scale);
        const card_y = y + 36 * iscale;
        const card_h: u32 = if (h > 36 * scale) h - 36 * scale else 0;
        const sec_sz = self.cfg.typography.secondary * scale;
        const ui_sz = self.cfg.typography.ui * scale;
        const button_sz = self.cfg.typography.button_text * scale;

        self.editor_card_rect = .{
            .x = x,
            .y = card_y,
            .w = w,
            .h = card_h,
        };

        // Header
        icons.drawSvgIcon(
            target,
            self.allocator,
            "edit",
            16 * scale,
            scale,
            x + 10 * iscale,
            y + 18 * iscale,
            self.cfg.theme.accent,
        );
        target.drawTextWithSize(&self.font, "Edit Item", x + 24 * iscale, y + 23 * iscale, ui_sz, self.cfg.theme.text_bright);

        // Buttons on right of header: Cancel and Save
        const save_w: u32 = 68 * scale;
        const save_h: u32 = 26 * scale;
        const save_x = x + @as(i32, @intCast(w)) - @as(i32, @intCast(save_w));
        const save_y = y + 5 * iscale;
        const save_hov = self.isAreaHovered(@divTrunc(save_x, iscale), @divTrunc(save_y, iscale), 68, 26);

        const cancel_w: u32 = 64 * scale;
        const cancel_h: u32 = 26 * scale;
        const cancel_x = save_x - @as(i32, @intCast(cancel_w)) - 8 * iscale;
        const cancel_y = y + 5 * iscale;
        const cancel_hov = self.isAreaHovered(@divTrunc(cancel_x, iscale), @divTrunc(cancel_y, iscale), 64, 26);

        // Cancel Button
        target.fillSquircle(cancel_x, cancel_y, cancel_w, cancel_h, 6 * scale, if (cancel_hov) self.cfg.theme.elevated else self.cfg.theme.surface);
        target.drawSquircleBorder(cancel_x, cancel_y, cancel_w, cancel_h, 6 * scale, 1, self.cfg.theme.border);
        const cw = target.measureTextWithSize(&self.font, "Cancel", sec_sz);
        target.drawTextWithSize(
            &self.font,
            "Cancel",
            cancel_x + @divTrunc(@as(i32, @intCast(cancel_w)) - @as(i32, @intCast(cw)), 2),
            cancel_y + 18 * iscale,
            sec_sz,
            if (cancel_hov) self.cfg.theme.text_bright else self.cfg.theme.text_muted,
        );
        try self.hit_areas.append(self.allocator, .{
            .x = @divTrunc(cancel_x, iscale),
            .y = @divTrunc(cancel_y, iscale),
            .w = 64,
            .h = 26,
            .action = .cancel_edit,
        });

        // Save Button
        const save_bg = if (save_hov)
            self.cfg.theme.accent
        else
            Color.init(50, self.cfg.theme.accent.r, self.cfg.theme.accent.g, self.cfg.theme.accent.b);
        target.fillSquircle(save_x, save_y, save_w, save_h, 6 * scale, save_bg);
        target.drawSquircleBorder(save_x, save_y, save_w, save_h, 6 * scale, 1, self.cfg.theme.accent);

        target.drawTextWithSize(
            &self.font,
            "Save",
            save_x + 14 * iscale,
            save_y + 18 * iscale,
            button_sz,
            if (save_hov) self.cfg.theme.accent_fg else self.cfg.theme.accent,
        );
        try self.hit_areas.append(self.allocator, .{
            .x = @divTrunc(save_x, iscale),
            .y = @divTrunc(save_y, iscale),
            .w = 68,
            .h = 26,
            .action = .save_edit,
        });

        // Content Card
        target.fillSquircle(x, card_y, w, card_h, 10 * scale, self.cfg.theme.surface);
        target.drawSquircleBorder(x, card_y, w, card_h, 10 * scale, 1, self.cfg.theme.accent);

        // Entire card is clickable to set cursor position
        try self.hit_areas.append(self.allocator, .{
            .x = @divTrunc(x, iscale),
            .y = @divTrunc(card_y, iscale),
            .w = @intCast(@divTrunc(@as(i32, @intCast(w)), iscale)),
            .h = @intCast(@divTrunc(@as(i32, @intCast(card_h)), iscale)),
            .action = .editor_click,
        });

        // Gutter
        const gutter_x = x + 40 * iscale;
        target.fillRect(gutter_x, card_y + 12 * iscale, 1, if (card_h > 24 * scale) card_h - 24 * scale else 0, Color.init(30, self.cfg.theme.border.r, self.cfg.theme.border.g, self.cfg.theme.border.b));

        const max_line_w = if (w > 68 * scale) w - 68 * scale else w;
        const line_step: i32 = @as(i32, @intCast(24 * scale));
        const max_visible_lines: usize = if (card_h > 48 * scale) @intCast(@divTrunc(card_h - 48 * scale, 24 * scale)) else 10;

        self.editor.recomputeVisualLines(&self.font, ui_sz, max_line_w);
        self.editor.ensureCursorVisible(max_visible_lines);

        const total_lines = self.editor.visual_lines.items.len;
        const cursor_v_line = self.editor.getVisualLineForCursor();

        var view_line: usize = 0;
        var cur_line_y: i32 = card_y + 26 * iscale;

        while (view_line < max_visible_lines and (self.editor.scroll_line + view_line) < total_lines) : (view_line += 1) {
            const v_idx = self.editor.scroll_line + view_line;
            const vl = self.editor.visual_lines.items[v_idx];
            const is_cursor_line = (v_idx == cursor_v_line);

            // Line number on first visual line of each logical line
            if (vl.is_first) {
                var num_buf: [16]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{vl.logical_line + 1}) catch "";
                const nw = target.measureTextWithSize(&self.font, num_str, sec_sz);
                const nx = gutter_x - @as(i32, @intCast(nw)) - 8 * iscale;
                target.drawTextWithSize(&self.font, num_str, nx, cur_line_y, sec_sz, if (is_cursor_line) self.cfg.theme.accent else self.cfg.theme.text_muted);
            }

            // Line text wrapped
            if (vl.start < vl.end and vl.start < self.editor.text.items.len) {
                const raw_slice = self.editor.text.items[vl.start..vl.end];

                // Sanitize tabs and control chars
                var clean_buf: [512]u8 = undefined;
                var clen: usize = 0;
                for (raw_slice) |ch| {
                    if (clen >= clean_buf.len) break;
                    if (ch == '\t') {
                        const spaces_to_add = @min(4, clean_buf.len - clen);
                        @memset(clean_buf[clen .. clen + spaces_to_add], ' ');
                        clen += spaces_to_add;
                    } else if (ch >= 32 or ch == 0) {
                        clean_buf[clen] = ch;
                        clen += 1;
                    }
                }
                clen = trimToValidUtf8(clean_buf[0..clen]);
                target.drawTextWithSize(&self.font, clean_buf[0..clen], gutter_x + 12 * iscale, cur_line_y, ui_sz, self.cfg.theme.text_bright);
            }

            // Caret on cursor visual line
            if (is_cursor_line and self.editor.caret_visible) {
                const pre_len = if (self.editor.cursor_idx >= vl.start) @min(self.editor.cursor_idx - vl.start, vl.end - vl.start) else 0;
                const pre_slice = self.editor.text.items[vl.start .. vl.start + pre_len];
                var pre_clean: [512]u8 = undefined;
                var pre_clen: usize = 0;
                for (pre_slice) |ch| {
                    if (pre_clen >= pre_clean.len) break;
                    if (ch == '\t') {
                        const sp = @min(4, pre_clean.len - pre_clen);
                        @memset(pre_clean[pre_clen .. pre_clen + sp], ' ');
                        pre_clen += sp;
                    } else if (ch >= 32 or ch == 0) {
                        pre_clean[pre_clen] = ch;
                        pre_clen += 1;
                    }
                }
                pre_clen = trimToValidUtf8(pre_clean[0..pre_clen]);
                const pre_w = target.measureTextWithSize(&self.font, pre_clean[0..pre_clen], ui_sz);
                const caret_x = gutter_x + 12 * iscale + @as(i32, @intCast(pre_w));
                target.fillRect(caret_x, cur_line_y - 14 * iscale, 2 * scale, 18 * scale, self.cfg.theme.accent);
            }

            cur_line_y += line_step;
        }

        // Shortcut hint at bottom
        const hint = "Ctrl+S to save as new · Esc to cancel";
        const hw = target.measureTextWithSize(&self.font, hint, sec_sz);
        const hx = x + @as(i32, @intCast(w)) - @as(i32, @intCast(hw)) - 16 * iscale;
        const hy = card_y + @as(i32, @intCast(card_h)) - 14 * iscale;
        target.drawTextWithSize(&self.font, hint, hx, hy, sec_sz, self.cfg.theme.text_muted);
    }

    fn renderPreviewColumn(
        self: *ClipboardPanel,
        target: renderer.Renderer,
        x: i32,
        y: i32,
        w: u32,
        h: u32,
        selected_actual_idx: ?usize,
        scale: u32,
    ) !void {
        const iscale: i32 = @intCast(scale);
        const card_y = y + 36 * iscale;
        const card_h: u32 = if (h > 36 * scale) h - 36 * scale else 0;
        const title_sz = self.cfg.typography.title * scale;
        const sec_sz = self.cfg.typography.secondary * scale;
        const ui_sz = self.cfg.typography.ui * scale;
        const heading_sz = self.cfg.typography.heading * scale;

        if (self.is_editing) {
            try self.renderEditor(target, x, y, w, h, scale);
            return;
        }

        if (self.show_share_view and c.mizu_share_is_running() != 0) {
            try self.renderShareView(target, x, y, w, card_h, card_y, scale);
            return;
        }

        if (selected_actual_idx == null or selected_actual_idx.? >= self.items.items.len) {
            target.fillSquircle(x, card_y, w, card_h, 10 * scale, self.cfg.theme.surface);
            target.drawSquircleBorder(x, card_y, w, card_h, 10 * scale, 1, self.cfg.theme.border);

            const icon_name = if (self.history_loading) "refresh" else "clipboard";
            const ph_msg = if (self.history_loading) "Loading history..." else "Select an item to preview";
            const icon_sz = title_sz;
            const msg_w = target.measureTextWithSize(&self.font, ph_msg, ui_sz);

            const center_x = x + @divTrunc(@as(i32, @intCast(w)), 2);
            const center_y = card_y + @divTrunc(@as(i32, @intCast(card_h)), 2);

            icons.drawSvgIcon(
                target,
                self.allocator,
                icon_name,
                icon_sz,
                scale,
                center_x,
                center_y - 14 * iscale,
                self.cfg.theme.text_muted,
            );
            target.drawTextWithSize(&self.font, ph_msg, center_x - @divTrunc(@as(i32, @intCast(msg_w)), 2), center_y + 22 * iscale, ui_sz, self.cfg.theme.text_muted);
            return;
        }

        const actual_idx = selected_actual_idx.?;
        const item = self.items.items[actual_idx];
        const preview_content = self.getDecodedContent(item);
        const qr_available = item.clip_type == .text and preview_content.len > 0 and preview_content.len <= 4296;

        // QR icon button replacing "Preview" label
        const qr_btn_x = x;
        const qr_btn_y = y + 4 * iscale;
        const qr_btn_w: u32 = 28 * scale;
        const qr_btn_h: u32 = 28 * scale;
        const qr_icon_sz = 18 * scale;
        const qr_hov = self.isAreaHovered(@divTrunc(qr_btn_x, iscale), @divTrunc(qr_btn_y, iscale), 28, 28);

        if (self.show_qr or (qr_available and qr_hov)) {
            target.fillSquircle(qr_btn_x, qr_btn_y, qr_btn_w, qr_btn_h, 6 * scale, if (self.show_qr) self.cfg.theme.accent else self.cfg.theme.surface);
            target.drawSquircleBorder(qr_btn_x, qr_btn_y, qr_btn_w, qr_btn_h, 6 * scale, 1, self.cfg.theme.border);
        }

        const qr_icon_col = if (self.show_qr) self.cfg.theme.accent_fg else (if (qr_available and qr_hov) self.cfg.theme.accent else (if (qr_available) self.cfg.theme.text_main else self.cfg.theme.text_muted));
        icons.drawSvgIcon(
            target,
            self.allocator,
            "qr",
            qr_icon_sz,
            scale,
            qr_btn_x + @as(i32, @intCast(qr_btn_w / 2)),
            qr_btn_y + @as(i32, @intCast(qr_btn_h / 2)),
            qr_icon_col,
        );

        // Always register the QR button in hit areas so clicking it toggles state safely
        // instead of unhandled clicks or force closing the clipboard.
        try self.hit_areas.append(self.allocator, .{
            .x = @divTrunc(qr_btn_x, iscale),
            .y = @divTrunc(qr_btn_y, iscale),
            .w = 28,
            .h = 28,
            .action = .toggle_qr,
        });

        // Edit icon button (2nd column right of QR code) - only visible when not editing
        if (!self.is_editing) {
            const edit_btn_x = qr_btn_x + 32 * iscale;
            const edit_btn_y = qr_btn_y;
            const edit_btn_w: u32 = 28 * scale;
            const edit_btn_h: u32 = 28 * scale;
            const edit_icon_sz = 18 * scale;

            // Only show edit icon button if item is text (not image)
            if (item.clip_type == .text) {
                const edit_hov = self.isAreaHovered(@divTrunc(edit_btn_x, iscale), @divTrunc(edit_btn_y, iscale), edit_btn_w, edit_btn_h);
                if (edit_hov) {
                    target.fillSquircle(edit_btn_x, edit_btn_y, edit_btn_w, edit_btn_h, 6 * scale, self.cfg.theme.surface);
                    target.drawSquircleBorder(edit_btn_x, edit_btn_y, edit_btn_w, edit_btn_h, 6 * scale, 1, self.cfg.theme.border);
                }
                icons.drawSvgIcon(
                    target,
                    self.allocator,
                    "edit",
                    edit_icon_sz,
                    scale,
                    edit_btn_x + @as(i32, @intCast(edit_btn_w / 2)),
                    edit_btn_y + @as(i32, @intCast(edit_btn_h / 2)),
                    if (edit_hov) self.cfg.theme.accent else self.cfg.theme.text_muted,
                );
                try self.hit_areas.append(self.allocator, .{
                    .x = @divTrunc(edit_btn_x, iscale),
                    .y = @divTrunc(edit_btn_y, iscale),
                    .w = 28,
                    .h = 28,
                    .action = .{ .start_edit = self.selected_index },
                });
            }
        }

        if (self.show_qr) {
            const content = self.getDecodedContent(item);
            const can_qr = item.clip_type == .text and content.len > 0 and content.len <= 4296;
            var meta_buf: [64]u8 = undefined;
            const meta_str = if (item.clip_type == .image)
                "QR Code"
            else
                std.fmt.bufPrint(&meta_buf, "{d} chars · {d} lines", .{ content.len, std.mem.count(u8, content, "\n") + 1 }) catch "";
            const mw = target.measureTextWithSize(&self.font, meta_str, sec_sz);
            const meta_x = x + @as(i32, @intCast(w)) - @as(i32, @intCast(mw));
            target.drawTextWithSize(&self.font, meta_str, meta_x, y + 20 * iscale, sec_sz, self.cfg.theme.text_muted);

            target.fillSquircle(x, card_y, w, card_h, 10 * scale, self.cfg.theme.surface);
            target.drawSquircleBorder(x, card_y, w, card_h, 10 * scale, 1, self.cfg.theme.border);

            if (can_qr) {
                if (generateQr(content)) |qr| {
                    const quiet_zone: u32 = 2;
                    const total_modules = qr.size + quiet_zone * 2;
                    const max_box = @min(if (w > 48 * scale) w - 48 * scale else w, if (card_h > 48 * scale) card_h - 48 * scale else card_h);
                    // Pixel-perfect integer scaling: maximize module size without exceeding box
                    const mod_size = @max(1, max_box / total_modules);
                    const qr_px = total_modules * mod_size;
                    const qr_box_x = x + @divTrunc(@as(i32, @intCast(w)) - @as(i32, @intCast(qr_px)), 2);
                    const qr_box_y = card_y + @divTrunc(@as(i32, @intCast(card_h)) - @as(i32, @intCast(qr_px)), 2);

                    // Sharp high-contrast background with quiet zone
                    target.fillSquircle(qr_box_x, qr_box_y, qr_px, qr_px, 8 * scale, theme.Color.rgb(255, 255, 255));
                    target.drawSquircleBorder(qr_box_x, qr_box_y, qr_px, qr_px, 8 * scale, 1, theme.Color.rgb(200, 200, 200));

                    // Crisp pixel-perfect modules: pure black on pure white
                    var qy: u32 = 0;
                    while (qy < qr.size) : (qy += 1) {
                        var qx: u32 = 0;
                        while (qx < qr.size) : (qx += 1) {
                            if (qr.isDark(qx, qy)) {
                                const mx = qr_box_x + @as(i32, @intCast((quiet_zone + qx) * mod_size));
                                const my = qr_box_y + @as(i32, @intCast((quiet_zone + qy) * mod_size));
                                target.fillRect(mx, my, mod_size, mod_size, theme.Color.rgb(0, 0, 0));
                            }
                        }
                    }
                } else {
                    const msg = "Content cannot be converted to QR code";
                    const msg_w = target.measureTextWithSize(&self.font, msg, ui_sz);
                    const center_x = x + @divTrunc(@as(i32, @intCast(w)) - @as(i32, @intCast(msg_w)), 2);
                    const center_y = card_y + @divTrunc(@as(i32, @intCast(card_h)), 2);
                    target.drawTextWithSize(&self.font, msg, center_x, center_y, ui_sz, self.cfg.theme.text_muted);
                }
            } else {
                const msg = if (item.clip_type == .image)
                    "Cannot generate QR code for images"
                else if (content.len == 0)
                    "No content to generate QR code"
                else
                    "Clipboard content is too large (max 4,296 characters)";
                const msg_w = target.measureTextWithSize(&self.font, msg, ui_sz);
                const center_x = x + @divTrunc(@as(i32, @intCast(w)) - @as(i32, @intCast(msg_w)), 2);
                const center_y = card_y + @divTrunc(@as(i32, @intCast(card_h)), 2);
                target.drawTextWithSize(&self.font, msg, center_x, center_y, ui_sz, self.cfg.theme.text_muted);
            }
            return;
        }

        // Handle image items
        if (item.clip_type == .image) {
            // Try to get cached image
            const cached_img = self.image_cache.get(item.id);
            if (cached_img) |img| {
                var meta_buf: [64]u8 = undefined;
                const shown_w = if (item.image_width > 0) item.image_width else img.width;
                const shown_h = if (item.image_height > 0) item.image_height else img.height;
                const meta_str = std.fmt.bufPrint(&meta_buf, "{d}x{d} · {s}", .{ shown_w, shown_h, item.image_format }) catch "";
                const mw = target.measureTextWithSize(&self.font, meta_str, sec_sz);
                const meta_x = x + @as(i32, @intCast(w)) - @as(i32, @intCast(mw));
                target.drawTextWithSize(&self.font, meta_str, meta_x, y + 20 * iscale, sec_sz, self.cfg.theme.text_muted);

                // Content Card
                target.fillSquircle(x, card_y, w, card_h, 10 * scale, self.cfg.theme.surface);
                target.drawSquircleBorder(x, card_y, w, card_h, 10 * scale, 1, self.cfg.theme.border);

                // Calculate thumbnail dimensions (maintain aspect ratio, max 90% of card)
                const max_w = if (w > 40 * scale) w - 40 * scale else w;
                const max_h = if (card_h > 40 * scale) card_h - 40 * scale else card_h;
                var thumb_w: u32 = img.width;
                var thumb_h: u32 = img.height;
                const aspect = @as(f32, @floatFromInt(img.width)) / @as(f32, @floatFromInt(img.height));

                if (thumb_w > max_w) {
                    thumb_w = max_w;
                    thumb_h = @intFromFloat(@as(f32, @floatFromInt(thumb_w)) / aspect);
                }
                if (thumb_h > max_h) {
                    thumb_h = max_h;
                    thumb_w = @intFromFloat(@as(f32, @floatFromInt(thumb_h)) * aspect);
                }

                const thumb_x = x + @divTrunc(@as(i32, @intCast(w)) - @as(i32, @intCast(thumb_w)), 2);
                const thumb_y = card_y + @divTrunc(@as(i32, @intCast(card_h)) - @as(i32, @intCast(thumb_h)), 2);

                // Draw image thumbnail
                target.drawImage(img, @as(f64, @floatFromInt(thumb_x)), @as(f64, @floatFromInt(thumb_y)), @as(f64, @floatFromInt(thumb_w)), @as(f64, @floatFromInt(thumb_h)));

                return;
            } else {
                // Image not yet decoded or decode failed - show placeholder
                target.fillSquircle(x, card_y, w, card_h, 10 * scale, self.cfg.theme.surface);
                target.drawSquircleBorder(x, card_y, w, card_h, 10 * scale, 1, self.cfg.theme.border);

                const icon_name = "cat";
                const ph_msg = "Loading preview...";
                const icon_sz = title_sz;
                const msg_w = target.measureTextWithSize(&self.font, ph_msg, ui_sz);
                const center_x = x + @divTrunc(@as(i32, @intCast(w)), 2);
                const center_y = card_y + @divTrunc(@as(i32, @intCast(card_h)), 2);
                icons.drawSvgIcon(
                    target,
                    self.allocator,
                    icon_name,
                    icon_sz,
                    scale,
                    center_x,
                    center_y - 14 * iscale,
                    self.cfg.theme.text_muted,
                );
                target.drawTextWithSize(&self.font, ph_msg, center_x - @divTrunc(@as(i32, @intCast(msg_w)), 2), center_y + 22 * iscale, ui_sz, self.cfg.theme.text_muted);
                return;
            }
        }

        const content = self.getDecodedContent(item);

        // Count lines & characters
        var line_count: usize = 1;
        for (content) |b| {
            if (b == '\n') line_count += 1;
        }
        const char_count = content.len;

        var meta_buf: [64]u8 = undefined;
        const meta_str = std.fmt.bufPrint(&meta_buf, "{d} chars · {d} lines", .{ char_count, line_count }) catch "";
        const mw = target.measureTextWithSize(&self.font, meta_str, sec_sz);
        const meta_x = x + @as(i32, @intCast(w)) - @as(i32, @intCast(mw));
        target.drawTextWithSize(&self.font, meta_str, meta_x, y + 20 * iscale, sec_sz, self.cfg.theme.text_muted);

        // Content Card (Flat surface, 10px squircle radius)
        target.fillSquircle(x, card_y, w, card_h, 10 * scale, self.cfg.theme.surface);
        target.drawSquircleBorder(x, card_y, w, card_h, 10 * scale, 1, self.cfg.theme.border);

        // Check if content is a simple hex color
        const clean_str = std.mem.trim(u8, content, " \t\r\n");
        const is_hex = (clean_str.len == 7 or clean_str.len == 9 or clean_str.len == 4) and clean_str[0] == '#';

        if (is_hex) {
            const parsed_color = theme.Color.fromHex(clean_str);
            const swatch_size: u32 = 64 * scale;
            const swatch_x = x + 24 * iscale;
            const swatch_y = card_y + 28 * iscale;

            target.fillSquircle(swatch_x, swatch_y, swatch_size, swatch_size, 10 * scale, parsed_color);
            target.drawSquircleBorder(swatch_x, swatch_y, swatch_size, swatch_size, 10 * scale, 1, self.cfg.theme.border);

            const detail_x = swatch_x + @as(i32, @intCast(swatch_size)) + 20 * iscale;
            target.drawTextWithSize(&self.font, clean_str, detail_x, swatch_y + 26 * iscale, heading_sz, self.cfg.theme.text_bright);

            var rgb_buf: [48]u8 = undefined;
            const rgb_str = std.fmt.bufPrint(&rgb_buf, "rgb({d}, {d}, {d})", .{ parsed_color.r, parsed_color.g, parsed_color.b }) catch "";
            target.drawTextWithSize(&self.font, rgb_str, detail_x, swatch_y + 52 * iscale, sec_sz, self.cfg.theme.text_muted);
        } else {
            // Multi-line text display with comfortable padding and clean line spacing
            const gutter_x = x + 40 * iscale;
            target.fillRect(gutter_x, card_y + 12 * iscale, 1, if (card_h > 24 * scale) card_h - 24 * scale else 0, Color.init(20, self.cfg.theme.border.r, self.cfg.theme.border.g, self.cfg.theme.border.b));

            const max_line_w = if (w > 60 * scale) w - 60 * scale else w;
            const max_visible_lines: usize = 22;
            const line_step: i32 = @as(i32, @intCast(24 * scale));
            var line_idx: usize = 0;
            var line_start: usize = 0;
            var cur_line_y: i32 = card_y + 26 * iscale;

            while (line_start < content.len and line_idx < max_visible_lines) {
                var line_end = line_start;
                while (line_end < content.len and content[line_end] != '\n' and content[line_end] != '\r') {
                    line_end += 1;
                }

                const raw_line = content[line_start..line_end];

                // Muted line number
                var num_buf: [16]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{line_idx + 1}) catch "";
                const nw = target.measureTextWithSize(&self.font, num_str, sec_sz);
                const nx = gutter_x - @as(i32, @intCast(nw)) - 8 * iscale;
                target.drawTextWithSize(&self.font, num_str, nx, cur_line_y, sec_sz, self.cfg.theme.text_muted);

                // Sanitize tabs and control chars
                var clean_buf: [256]u8 = undefined;
                var clen: usize = 0;
                for (raw_line) |ch| {
                    if (clen >= clean_buf.len) break;
                    if (ch == '\t') {
                        const spaces_to_add = @min(4, clean_buf.len - clen);
                        @memset(clean_buf[clen .. clen + spaces_to_add], ' ');
                        clen += spaces_to_add;
                    } else if (ch >= 32 or ch == 0) {
                        clean_buf[clen] = ch;
                        clen += 1;
                    }
                }
                clen = trimToValidUtf8(clean_buf[0..clen]);
                const clean_slice = clean_buf[0..clen];

                var trunc_buf: [260]u8 = undefined;
                const display_line = truncateStrWithSize(target, &self.font, clean_slice, ui_sz, max_line_w, &trunc_buf);
                target.drawTextWithSize(&self.font, display_line, gutter_x + 12 * iscale, cur_line_y, ui_sz, self.cfg.theme.text_bright);

                cur_line_y += line_step;
                line_idx += 1;

                if (line_end < content.len and content[line_end] == '\r') line_end += 1;
                if (line_end < content.len and content[line_end] == '\n') line_end += 1;
                line_start = line_end;
            }

            if (line_start < content.len) {
                var rem_lines: usize = 0;
                var pos = line_start;
                while (pos < content.len) : (pos += 1) {
                    if (content[pos] == '\n') rem_lines += 1;
                }
                if (rem_lines == 0) rem_lines = 1;

                var rem_buf: [64]u8 = undefined;
                const rem_str = std.fmt.bufPrint(&rem_buf, "... and {d} more lines", .{rem_lines}) catch "";
                target.drawTextWithSize(&self.font, rem_str, gutter_x + 12 * iscale, cur_line_y, sec_sz, self.cfg.theme.text_muted);
            }
        }
    }

    fn trimToValidUtf8(bytes: []const u8) usize {
        var len = bytes.len;
        while (len > 0 and (bytes[len - 1] & 0xC0) == 0x80) {
            len -= 1;
        }
        if (len > 0 and (bytes[len - 1] & 0x80) != 0) {
            const lead = bytes[len - 1];
            const seq_len: usize = if ((lead & 0xE0) == 0xC0)
                2
            else if ((lead & 0xF0) == 0xE0)
                3
            else if ((lead & 0xF8) == 0xF0)
                4
            else
                1;
            if (len - 1 + seq_len > bytes.len) {
                len -= 1;
            } else {
                len = len - 1 + seq_len;
            }
        }
        return len;
    }

    pub fn truncateStrWithSize(target: renderer.Renderer, font: *renderer.Font, str: []const u8, size: u32, max_w: u32, buf: []u8) []const u8 {
        if (str.len == 0) return "";
        if (target.measureTextWithSize(font, str, size) <= max_w) return str;

        const dots = "...";
        const dots_w = target.measureTextWithSize(font, dots, size);
        if (dots_w >= max_w) {
            if (buf.len >= dots.len) {
                @memcpy(buf[0..dots.len], dots);
                return buf[0..dots.len];
            }
            return "";
        }
        const avail_w = max_w - dots_w;

        var utf8_view = std.unicode.Utf8View.init(str) catch {
            return "";
        };
        var it = utf8_view.iterator();
        var best_len: usize = 0;
        var current_w: u32 = 0;

        while (it.nextCodepoint()) |cp| {
            const cp_len = std.unicode.utf8CodepointSequenceLength(cp) catch break;
            const next_len = best_len + cp_len;
            if (next_len + dots.len > buf.len) break;

            const adv = if (font.getOrLoadGlyph(cp, size)) |cg| cg.advance_x else @as(i32, @intCast(size / 2));
            const adv_u: u32 = if (adv > 0) @intCast(adv) else 0;
            if (current_w + adv_u > avail_w) break;

            current_w += adv_u;
            best_len = next_len;
        }

        if (best_len == 0) {
            if (buf.len >= dots.len) {
                @memcpy(buf[0..dots.len], dots);
                return buf[0..dots.len];
            }
            return "";
        }

        @memcpy(buf[0..best_len], str[0..best_len]);
        @memcpy(buf[best_len .. best_len + dots.len], dots);
        return buf[0 .. best_len + dots.len];
    }

    pub fn truncateStr(target: renderer.Renderer, font: *renderer.Font, str: []const u8, max_w: u32, buf: []u8) []const u8 {
        return truncateStrWithSize(target, font, str, font.size_px, max_w, buf);
    }
};

test "ClipboardPanel initialization, 2-column layout and filtering" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    const shared = try SharedWorkerContext.create(allocator);
    defer shared.release();

    var panel = ClipboardPanel{
        .allocator = allocator,
        .cfg = cfg,
        .font = undefined,
        .items = std.ArrayList(ClipItem).empty,
        .filtered_indices = std.ArrayList(usize).empty,
        .input = text_input.TextInput.init(allocator, "Search...", false),
        .hit_areas = std.ArrayList(ClipHitArea).empty,
        .shared = shared,
    };
    defer {
        panel.hit_areas.deinit(allocator);
        panel.filtered_indices.deinit(allocator);
        panel.input.deinit();
        panel.items.deinit(allocator);
    }

    try std.testing.expectEqual(@as(u32, 980), panel.width);
    try std.testing.expectEqual(@as(u32, 620), panel.height);

    var item1 = ClipItem{ .id = 1 };
    const t1 = "https://example.com";
    @memcpy(item1.preview[0..t1.len], t1);
    item1.preview_len = t1.len;
    try panel.items.append(allocator, item1);

    var item2 = ClipItem{ .id = 2 };
    const t2 = "Hello World";
    @memcpy(item2.preview[0..t2.len], t2);
    item2.preview_len = t2.len;
    try panel.items.append(allocator, item2);

    panel.updateFilter();
    try std.testing.expectEqual(@as(usize, 2), panel.filtered_indices.items.len);

    // Search for "hello"
    try panel.input.insertBytes("hel");
    panel.updateFilter();
    try std.testing.expectEqual(@as(usize, 1), panel.filtered_indices.items.len);
    try std.testing.expectEqual(@as(usize, 1), panel.filtered_indices.items[0]);

    // Clear filter
    panel.input.clear();
    panel.updateFilter();
    try std.testing.expectEqual(@as(usize, 2), panel.filtered_indices.items.len);

    // Test Left/Right key navigation
    panel.selected_index = 0;
    _ = panel.handleKey(c.XKB_KEY_Right, "", false, false);
    try std.testing.expectEqual(@as(usize, 1), panel.selected_index);
    _ = panel.handleKey(c.XKB_KEY_Left, "", false, false);
    try std.testing.expectEqual(@as(usize, 0), panel.selected_index);

    // Test Pointer Scroll
    _ = panel.handlePointerAxis(0, 0, 1);
    try std.testing.expectEqual(@as(usize, 1), panel.selected_index);
    _ = panel.handlePointerAxis(0, 0, -1);
    try std.testing.expectEqual(@as(usize, 0), panel.selected_index);

    // Test clicking items with scaling = 2 (items must not be intercepted by search input)
    panel.ui_scale = 2;
    panel.search_rect = .{ .x = 24, .y = 56, .w = 480, .h = 48 };
    try panel.hit_areas.append(allocator, .{
        .x = 24,
        .y = 114,
        .w = 480,
        .h = 52,
        .action = .{ .click_card = 0 },
    });
    try panel.hit_areas.append(allocator, .{
        .x = 24,
        .y = 172,
        .w = 480,
        .h = 52,
        .action = .{ .click_card = 1 },
    });

    panel.selected_index = 0;
    _ = panel.handlePointerButton(100, 180, 272, true);
    try std.testing.expectEqual(@as(usize, 1), panel.selected_index);
    _ = panel.handlePointerButton(100, 120, 272, true);
    try std.testing.expectEqual(@as(usize, 0), panel.selected_index);

    // Test QR toggle button
    try panel.hit_areas.append(allocator, .{
        .x = 520,
        .y = 20,
        .w = 28,
        .h = 28,
        .action = .toggle_qr,
    });
    try std.testing.expectEqual(false, panel.show_qr);
    _ = panel.handlePointerButton(530, 25, 272, true);
    try std.testing.expectEqual(true, panel.show_qr);
    _ = panel.handlePointerButton(530, 25, 272, true);
    try std.testing.expectEqual(false, panel.show_qr);
}

test "Clipboard first line extraction without popen" {
    var item = ClipItem{
        .id = 99999999,
        .preview_len = 11,
    };
    const t = "Hello World";
    @memcpy(item.preview[0..t.len], t);
    loadItemFirstLine(&item);
    try std.testing.expect(item.first_line_loaded);
    try std.testing.expectEqualStrings("Hello World", item.first_line[0..item.first_line_len]);
}

test "Clipboard unicode ornaments and symbols like ❫" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var font = try renderer.Font.init(allocator, cfg.theme.font_family, cfg.typography.ui);
    defer font.deinit();

    const pixels = try allocator.alloc(u32, 400 * 200);
    defer allocator.free(pixels);
    @memset(pixels, 0);
    const target = try renderer.Renderer.init(pixels.ptr, 400, 200, 400 * 4);

    const test_str = "❫ test ⏎";
    var trunc_buf: [160]u8 = undefined;
    const truncated = ClipboardPanel.truncateStr(target, &font, test_str, 200, &trunc_buf);
    try std.testing.expectEqualStrings(test_str, truncated);

    target.drawTextWithSpacing(&font, test_str, 10, 50, cfg.typography.ui, cfg.theme.text_bright, 0);
    var non_zero: usize = 0;
    for (pixels) |px| {
        if (px != 0) non_zero += 1;
    }
    try std.testing.expect(non_zero > 0);
}

test "Clipboard DecodedCache LRU eviction and retrieval" {
    var cache: DecodedCache = .{};
    try std.testing.expect(cache.get(42) == null);

    // Insert 70 items into a 64-entry cache
    var buf: [32]u8 = undefined;
    var i: u64 = 1;
    while (i <= 70) : (i += 1) {
        const text = try std.fmt.bufPrint(&buf, "Item {d}", .{i});
        cache.put(i, text);
    }

    // Recent items must exist
    try std.testing.expect(cache.get(70) != null);
    try std.testing.expectEqualStrings("Item 70", cache.get(70).?);

    // Oldest items (1..6) should have been evicted by LRU
    try std.testing.expect(cache.get(1) == null);

    // Access item 20 to refresh its recency
    _ = cache.get(20);

    // Add another item
    cache.put(71, "Item 71");
    // Item 20 should still be retained because its access_seq was refreshed
    try std.testing.expect(cache.get(20) != null);

    // Test remove
    cache.remove(20);
    try std.testing.expect(cache.get(20) == null);

    // Test clear
    cache.clear();
    try std.testing.expect(cache.get(70) == null);
}

test "Clipboard large histories and incremental filtering" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    const shared = try SharedWorkerContext.create(allocator);
    defer shared.release();

    var panel = ClipboardPanel{
        .allocator = allocator,
        .cfg = cfg,
        .font = undefined,
        .items = std.ArrayList(ClipItem).empty,
        .filtered_indices = std.ArrayList(usize).empty,
        .input = text_input.TextInput.init(allocator, "Search...", false),
        .hit_areas = std.ArrayList(ClipHitArea).empty,
        .shared = shared,
    };
    defer {
        panel.hit_areas.deinit(allocator);
        panel.filtered_indices.deinit(allocator);
        panel.input.deinit();
        panel.items.deinit(allocator);
    }

    // Populate with 500 items
    var i: u64 = 0;
    while (i < 500) : (i += 1) {
        var item = ClipItem{ .id = i + 1 };
        var pbuf: [64]u8 = undefined;
        const ptext = if (i % 2 == 0)
            try std.fmt.bufPrint(&pbuf, "https://example.com/page/{d}", .{i})
        else
            try std.fmt.bufPrint(&pbuf, "note {d} with some random clipboard text", .{i});
        @memcpy(item.preview[0..ptext.len], ptext);
        item.preview_len = ptext.len;
        try panel.items.append(allocator, item);
    }

    // 1. Full empty filter
    panel.updateFilter();
    try std.testing.expectEqual(@as(usize, 500), panel.filtered_indices.items.len);

    // 2. Filter "http"
    try panel.input.insertBytes("http");
    panel.updateFilter();
    try std.testing.expectEqual(@as(usize, 250), panel.filtered_indices.items.len);

    // 3. Incremental filter "https"
    try panel.input.insertBytes("s");
    panel.updateFilter();
    try std.testing.expectEqual(@as(usize, 250), panel.filtered_indices.items.len);

    // 4. Narrow to page/10
    try panel.input.insertBytes("://example.com/page/10");
    panel.updateFilter();
    // Matches page/10, page/100, page/102, etc. (11 items)
    try std.testing.expect(panel.filtered_indices.items.len > 0);
}

test "Clipboard multiline and large entry decode" {
    var cache: DecodedCache = .{};

    // Create a 6KB multiline content string
    var big_content: [6144]u8 = undefined;
    var offset: usize = 0;
    var line_no: usize = 1;
    while (offset + 64 < big_content.len) : (line_no += 1) {
        var line_buf: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "Line {d}: multiline clipboard payload with tabs\t\n", .{line_no});
        @memcpy(big_content[offset .. offset + line.len], line);
        offset += line.len;
    }

    cache.put(999, big_content[0..offset]);
    const retrieved = cache.get(999);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(offset, retrieved.?.len);
    try std.testing.expectEqualStrings(big_content[0..offset], retrieved.?);
}

test "Clipboard rapid navigation and stale decode discarding" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    const shared = try SharedWorkerContext.create(allocator);
    defer shared.release();

    var panel = ClipboardPanel{
        .allocator = allocator,
        .cfg = cfg,
        .font = undefined,
        .items = std.ArrayList(ClipItem).empty,
        .filtered_indices = std.ArrayList(usize).empty,
        .input = text_input.TextInput.init(allocator, "Search...", false),
        .hit_areas = std.ArrayList(ClipHitArea).empty,
        .shared = shared,
    };
    defer {
        panel.hit_areas.deinit(allocator);
        panel.filtered_indices.deinit(allocator);
        panel.input.deinit();
        panel.items.deinit(allocator);
    }

    try panel.items.append(allocator, .{ .id = 101, .preview_len = 5 });
    try panel.items.append(allocator, .{ .id = 102, .preview_len = 5 });
    panel.updateFilter();

    // User is currently selecting item 101
    panel.selected_index = 0;
    try std.testing.expectEqual(@as(u64, 101), panel.getSelectedId().?);

    // Simulate late decode result for unselected item.
    shared.decode_lock.lock();
    const stale_data = "Decoded 102";
    if (shared.decode_res_buf.len < stale_data.len) {
        if (shared.decode_res_buf.len > 0) allocator.free(shared.decode_res_buf);
        shared.decode_res_buf = try allocator.alloc(u8, stale_data.len);
    }
    @memcpy(shared.decode_res_buf[0..stale_data.len], stale_data);
    shared.decode_res_len = stale_data.len;
    shared.decode_res_id = 102;
    shared.decode_res_ready = true;
    shared.decode_lock.unlock();

    // Cache result without triggering redraw.
    const changed = panel.tick();
    try std.testing.expectEqual(false, changed);

    // The stale decode must be safely stored in decode_cache for item 102
    try std.testing.expectEqualStrings("Decoded 102", panel.decode_cache.get(102).?);

    // Selection 102 content is already cached.
    panel.selected_index = 1;
    try std.testing.expectEqualStrings("Decoded 102", panel.getDecodedContent(panel.items.items[1]));
}

test "Clipboard thread lifecycle - closing during decoding without blocking or leak" {
    const allocator = std.testing.allocator;
    const shared = try SharedWorkerContext.create(allocator);

    // Simulate spawning worker
    shared.acquire();
    const thread = try std.Thread.spawn(.{}, struct {
        fn worker(ctx: *SharedWorkerContext) void {
            defer ctx.release();
            var count: usize = 0;
            while (!ctx.stop.load(.acquire) and count < 100) : (count += 1) {
                _ = c.usleep(1000); // 1ms
            }
        }
    }.worker, .{shared});

    // Immediate deinit / stop
    shared.stop.store(true, .release);
    thread.detach();

    // Release context from parent side
    shared.release();

    // Wait briefly for detached worker to finish and free context cleanly
    _ = c.usleep(10000); // 10ms
}

test "Clipboard repeated opening and closing with session cache" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    // Reset session cache
    session_has_cache = false;
    session_cached_count = 0;

    // First opening (cold)
    {
        var panel1 = ClipboardPanel{
            .allocator = allocator,
            .cfg = cfg,
            .font = undefined,
            .items = std.ArrayList(ClipItem).empty,
            .filtered_indices = std.ArrayList(usize).empty,
            .input = text_input.TextInput.init(allocator, "Search...", false),
            .hit_areas = std.ArrayList(ClipHitArea).empty,
            .shared = try SharedWorkerContext.create(allocator),
        };
        defer {
            panel1.shared.release();
            panel1.hit_areas.deinit(allocator);
            panel1.filtered_indices.deinit(allocator);
            panel1.input.deinit();
            panel1.items.deinit(allocator);
        }

        try std.testing.expect(panel1.history_loading);

        // Simulate history worker delivering items
        panel1.shared.history_lock.lock();
        panel1.shared.history_items[0] = .{ .id = 55, .preview_len = 4 };
        panel1.shared.history_count = 1;
        panel1.shared.history_done = true;
        panel1.shared.history_lock.unlock();

        _ = panel1.tick();
        try std.testing.expect(!panel1.history_loading);
        try std.testing.expect(session_has_cache);
        try std.testing.expectEqual(@as(usize, 1), session_cached_count);
    }

    // Second opening (warm): should immediately have cached history!
    {
        const shared2 = try SharedWorkerContext.create(allocator);
        defer shared2.release();

        var panel2 = ClipboardPanel{
            .allocator = allocator,
            .cfg = cfg,
            .font = undefined,
            .items = std.ArrayList(ClipItem).empty,
            .filtered_indices = std.ArrayList(usize).empty,
            .input = text_input.TextInput.init(allocator, "Search...", false),
            .hit_areas = std.ArrayList(ClipHitArea).empty,
            .shared = shared2,
        };
        defer {
            panel2.hit_areas.deinit(allocator);
            panel2.filtered_indices.deinit(allocator);
            panel2.input.deinit();
            panel2.items.deinit(allocator);
        }

        if (session_has_cache and session_cached_count > 0) {
            for (session_cached_items[0..session_cached_count]) |item| {
                try panel2.items.append(allocator, item);
            }
            panel2.history_loading = false;
            panel2.updateFilter();
        }

        try std.testing.expect(!panel2.history_loading);
        try std.testing.expectEqual(@as(usize, 1), panel2.items.items.len);
        try std.testing.expectEqual(@as(u64, 55), panel2.items.items[0].id);
    }
}

test "Clipboard clearAll clears all items, caches and state" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    session_has_cache = true;
    session_cached_count = 5;

    var panel = ClipboardPanel{
        .allocator = allocator,
        .cfg = cfg,
        .font = undefined,
        .items = std.ArrayList(ClipItem).empty,
        .filtered_indices = std.ArrayList(usize).empty,
        .input = text_input.TextInput.init(allocator, "Search...", false),
        .hit_areas = std.ArrayList(ClipHitArea).empty,
        .shared = try SharedWorkerContext.create(allocator),
    };
    defer {
        panel.shared.release();
        panel.hit_areas.deinit(allocator);
        panel.filtered_indices.deinit(allocator);
        panel.input.deinit();
        panel.items.deinit(allocator);
    }

    try panel.items.append(allocator, .{ .id = 1 });
    try panel.items.append(allocator, .{ .id = 2 });
    panel.updateFilter();
    try std.testing.expectEqual(@as(usize, 2), panel.items.items.len);
    try std.testing.expectEqual(@as(usize, 2), panel.filtered_indices.items.len);

    panel.clearAll();

    try std.testing.expectEqual(@as(usize, 0), panel.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), panel.filtered_indices.items.len);
    try std.testing.expectEqual(@as(usize, 0), session_cached_count);
    try std.testing.expect(!session_has_cache);
}

fn getMonotonicNs() i128 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i128, ts.tv_sec) * 1_000_000_000 + @as(i128, ts.tv_nsec);
}

test "Clipboard performance latency measurements" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    // 1. Measure panel init time
    var t0 = getMonotonicNs();
    var panel = try ClipboardPanel.init(allocator, cfg);
    defer panel.deinit();
    var t1 = getMonotonicNs();
    const init_us = @as(f64, @floatFromInt(t1 - t0)) / 1000.0;
    _ = init_us;

    // 2. Measure immediate first frame render time (using fake renderer buffer)
    const render_pixels = try allocator.alloc(u32, panel.width * panel.height);
    defer allocator.free(render_pixels);
    const rend = try renderer.Renderer.init(render_pixels.ptr, panel.width, panel.height, panel.width * 4);

    t0 = getMonotonicNs();
    try panel.render(rend, 1);
    t1 = getMonotonicNs();
    const first_render_us = @as(f64, @floatFromInt(t1 - t0)) / 1000.0;
    _ = first_render_us;

    // 3. Measure time for background history delivery via eventfd
    t0 = getMonotonicNs();
    var poll_fds = [_]c.struct_pollfd{
        .{ .fd = panel.getWakeFd(), .events = c.POLLIN, .revents = 0 },
    };
    var history_loaded = false;
    var attempts: usize = 0;
    while (attempts < 50) : (attempts += 1) {
        const res = c.poll(&poll_fds, 1, 50); // wait up to 50ms
        if (res > 0 and (poll_fds[0].revents & c.POLLIN != 0)) {
            var val: u64 = 0;
            _ = c.read(panel.getWakeFd(), &val, @sizeOf(u64));
            if (panel.tick()) {
                if (!panel.history_loading) {
                    history_loaded = true;
                    break;
                }
            }
        }
    }
    t1 = getMonotonicNs();
    const history_us = @as(f64, @floatFromInt(t1 - t0)) / 1000.0;
    _ = history_us;

    // 4. Measure render time with items loaded
    t0 = getMonotonicNs();
    try panel.render(rend, 1);
    t1 = getMonotonicNs();
    const populated_render_us = @as(f64, @floatFromInt(t1 - t0)) / 1000.0;
    _ = populated_render_us;

    // 5. Measure decode delivery via eventfd
    t0 = getMonotonicNs();
    attempts = 0;
    while (attempts < 50) : (attempts += 1) {
        const res = c.poll(&poll_fds, 1, 50);
        if (res > 0 and (poll_fds[0].revents & c.POLLIN != 0)) {
            var val: u64 = 0;
            _ = c.read(panel.getWakeFd(), &val, @sizeOf(u64));
            if (panel.tick()) {
                break;
            }
        }
    }
    t1 = getMonotonicNs();
    _ = t1 - t0;

    // 6. Measure cached preview lookup latency
    if (panel.getSelectedId()) |sel_id| {
        t0 = getMonotonicNs();
        _ = panel.decode_cache.get(sel_id);
        t1 = getMonotonicNs();
    }

    // 7. Measure incremental filtering latency over 500 items
    var panel_filt = ClipboardPanel{
        .allocator = allocator,
        .cfg = cfg,
        .font = panel.font,
        .items = std.ArrayList(ClipItem).empty,
        .filtered_indices = std.ArrayList(usize).empty,
        .input = text_input.TextInput.init(allocator, "Search...", false),
        .hit_areas = std.ArrayList(ClipHitArea).empty,
        .shared = try SharedWorkerContext.create(allocator),
    };
    defer {
        panel_filt.shared.release();
        panel_filt.hit_areas.deinit(allocator);
        panel_filt.filtered_indices.deinit(allocator);
        panel_filt.input.deinit();
        panel_filt.items.deinit(allocator);
    }
    var i: u64 = 0;
    while (i < 500) : (i += 1) {
        var it = ClipItem{ .id = i + 1 };
        var pbuf: [64]u8 = undefined;
        const ptext = try std.fmt.bufPrint(&pbuf, "entry {d} https://gitlab.com/repo/project", .{i});
        @memcpy(it.preview[0..ptext.len], ptext);
        it.preview_len = ptext.len;
        try panel_filt.items.append(allocator, it);
    }
    t0 = getMonotonicNs();
    try panel_filt.input.insertBytes("gitlab");
    panel_filt.updateFilter();
    t1 = getMonotonicNs();
    _ = t1 - t0;

    // 8. Measure instant closing time during in-flight operations
    var panel_closing = try ClipboardPanel.init(allocator, cfg);
    t0 = getMonotonicNs();
    panel_closing.deinit();
    t1 = getMonotonicNs();
    _ = t1 - t0;

    // Allow detached background threads in this unit test to finish exiting cleanly
    _ = c.usleep(150000);
}

test "ImageCache enforces byte budget and evicts LRU" {
    var cache = ImageCache.init(std.testing.allocator);
    defer cache.clear();

    const px = 2 * 1024 * 1024;
    for (0..5) |i| {
        const img = try std.testing.allocator.create(renderer.Image);
        img.* = .{
            .width = 1024,
            .height = 2048,
            .pixels = try std.testing.allocator.alloc(u32, px),
            .allocator = std.testing.allocator,
        };
        cache.put(i + 1, img);
    }

    try std.testing.expect(cache.total_bytes <= ImageCache.max_bytes);
    try std.testing.expect(cache.get(1) == null);
    try std.testing.expect(cache.get(5) != null);
}

test "Mizu Share embedded server start, share view, and stop" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    const shared = try SharedWorkerContext.create(allocator);
    defer shared.release();

    var panel = ClipboardPanel{
        .allocator = allocator,
        .cfg = cfg,
        .font = undefined,
        .items = std.ArrayList(ClipItem).empty,
        .filtered_indices = std.ArrayList(usize).empty,
        .input = text_input.TextInput.init(allocator, "Search...", false),
        .hit_areas = std.ArrayList(ClipHitArea).empty,
        .shared = shared,
    };

    c.mizu_share_stop();
    try std.testing.expectEqual(@as(c_int, 0), c.mizu_share_is_running());
    try std.testing.expect(!panel.show_share_view);

    try std.testing.expectEqual(@as(c_int, 0), c.mizu_share_start());
    panel.show_share_view = true;
    try std.testing.expectEqual(@as(c_int, 1), c.mizu_share_is_running());

    const url_ptr = c.mizu_share_get_url();
    try std.testing.expect(url_ptr != null);
    const url = std.mem.span(url_ptr);
    try std.testing.expect(std.mem.startsWith(u8, url, "http://"));
    try std.testing.expect(std.mem.indexOf(u8, url, "?token=") != null);

    panel.hit_areas.deinit(allocator);
    panel.filtered_indices.deinit(allocator);
    panel.input.deinit();
    try std.testing.expectEqual(@as(c_int, 1), c.mizu_share_is_running());

    // Panel is reopened while share is still running in background
    var panel2 = ClipboardPanel{
        .allocator = allocator,
        .cfg = cfg,
        .font = undefined,
        .items = std.ArrayList(ClipItem).empty,
        .filtered_indices = std.ArrayList(usize).empty,
        .input = text_input.TextInput.init(allocator, "Search...", false),
        .hit_areas = std.ArrayList(ClipHitArea).empty,
        .shared = shared,
    };
    defer {
        panel2.hit_areas.deinit(allocator);
        panel2.filtered_indices.deinit(allocator);
        panel2.input.deinit();
    }

    try std.testing.expect(!panel2.show_share_view);
    try std.testing.expectEqual(@as(c_int, 1), c.mizu_share_is_running());

    // User clicks Share button: toggles share view on without stopping server
    if (c.mizu_share_is_running() == 0) {
        _ = c.mizu_share_start();
        panel2.show_share_view = true;
    } else {
        panel2.show_share_view = !panel2.show_share_view;
    }
    try std.testing.expect(panel2.show_share_view);
    try std.testing.expectEqual(@as(c_int, 1), c.mizu_share_is_running());

    // User clicks Off button on preview side: stops server
    c.mizu_share_stop();
    panel2.show_share_view = false;
    c.mizu_share_stop();
    try std.testing.expectEqual(@as(c_int, 0), c.mizu_share_is_running());
    const token_ptr = c.mizu_share_get_token();
    try std.testing.expect(token_ptr != null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.span(token_ptr).len);
}

test "Mizu Share HTTP endpoints and security" {
    try std.testing.expectEqual(@as(c_int, 0), c.mizu_share_start());
    defer c.mizu_share_stop();

    const url_ptr = c.mizu_share_get_url();
    try std.testing.expect(url_ptr != null);
    const url = std.mem.span(url_ptr);

    var cmd_buf: [512]u8 = undefined;
    const cmd1 = try std.fmt.bufPrintSentinel(&cmd_buf, "curl -s -o /dev/null -w '%{{http_code}}' '{s}'", .{url}, 0);
    if (c.popen(cmd1.ptr, "r")) |p| {
        defer _ = c.pclose(p);
        var res_buf: [16]u8 = undefined;
        if (c.fgets(&res_buf, @intCast(res_buf.len), p) != null) {
            const code = std.mem.trim(u8, std.mem.span(@as([*:0]const u8, @ptrCast(&res_buf))), " \r\n");
            try std.testing.expectEqualStrings("200", code);
        }
    }

    const qpos = std.mem.indexOfScalar(u8, url, '?').?;
    const base_url = url[0..qpos];
    const cmd2 = try std.fmt.bufPrintSentinel(&cmd_buf, "curl -s -o /dev/null -w '%{{http_code}}' '{s}'", .{base_url}, 0);
    if (c.popen(cmd2.ptr, "r")) |p| {
        defer _ = c.pclose(p);
        var res_buf: [16]u8 = undefined;
        if (c.fgets(&res_buf, @intCast(res_buf.len), p) != null) {
            const code = std.mem.trim(u8, std.mem.span(@as([*:0]const u8, @ptrCast(&res_buf))), " \r\n");
            try std.testing.expectEqualStrings("403", code);
        }
    }

    var text_url_buf: [512]u8 = undefined;
    const text_url = try std.fmt.bufPrintSentinel(&text_url_buf, "{s}api/text?{s}", .{ base_url, url[qpos + 1 ..] }, 0);
    const cmd3 = try std.fmt.bufPrintSentinel(&cmd_buf, "curl -s -X POST -d 'Hello from Mobile' '{s}'", .{text_url}, 0);
    if (c.popen(cmd3.ptr, "r")) |p| {
        defer _ = c.pclose(p);
        var res_buf: [64]u8 = undefined;
        if (c.fgets(&res_buf, @intCast(res_buf.len), p) != null) {
            const resp = std.mem.span(@as([*:0]const u8, @ptrCast(&res_buf)));
            try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":true") != null);
        }
    }

    var upload_url_buf: [512]u8 = undefined;
    const upload_url = try std.fmt.bufPrintSentinel(&upload_url_buf, "{s}api/upload?{s}", .{ base_url, url[qpos + 1 ..] }, 0);
    const cmd4 = try std.fmt.bufPrintSentinel(&cmd_buf, "curl -s -X POST -H 'X-Filename: mizu_test_share.txt' -d 'Testing Mizu Upload' '{s}'", .{upload_url}, 0);
    if (c.popen(cmd4.ptr, "r")) |p| {
        defer _ = c.pclose(p);
        var res_buf: [128]u8 = undefined;
        if (c.fgets(&res_buf, @intCast(res_buf.len), p) != null) {
            const resp = std.mem.span(@as([*:0]const u8, @ptrCast(&res_buf)));
            try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":true") != null);
        }
    }

    if (c.getenv("HOME")) |home_ptr| {
        const home = std.mem.span(home_ptr);
        var clean_path: [512]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&clean_path, "{s}/Downloads/MizuShare/mizu_test_share.txt", .{home}, 0)) |p| {
            _ = c.unlink(p.ptr);
        } else |_| {}
    }
}

test "MultiLineEditor text manipulation, navigation and line bounds" {
    const allocator = std.testing.allocator;
    var editor = MultiLineEditor.init(allocator);
    defer editor.deinit();

    try editor.setText("Line 1\nLine 2\nLine 3");
    try std.testing.expectEqual(@as(usize, 3), editor.getTotalLines());

    const pos = editor.getCursorPos(editor.cursor_idx);
    try std.testing.expectEqual(@as(usize, 2), pos.line);

    editor.moveUp();
    const pos_up = editor.getCursorPos(editor.cursor_idx);
    try std.testing.expectEqual(@as(usize, 1), pos_up.line);

    editor.moveHome();
    const pos_home = editor.getCursorPos(editor.cursor_idx);
    try std.testing.expectEqual(@as(usize, 0), pos_home.col_bytes);

    try editor.insertBytes("Edited ");
    try std.testing.expect(std.mem.startsWith(u8, editor.text.items[pos_home.line_start..], "Edited Line 2"));

    editor.moveDown();
    editor.moveEnd();
    try editor.insertBytes("\nLine 4");
    try std.testing.expectEqual(@as(usize, 4), editor.getTotalLines());

    // Backspace
    try editor.deleteBackward(); // deletes '4'
    try std.testing.expect(std.mem.endsWith(u8, editor.getText(), "Line "));
}

test "ClipboardPanel edit mode and save as new item keeping old item" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    const shared = try SharedWorkerContext.create(allocator);
    defer shared.release();

    var panel = ClipboardPanel{
        .allocator = allocator,
        .cfg = cfg,
        .font = undefined,
        .items = std.ArrayList(ClipItem).empty,
        .filtered_indices = std.ArrayList(usize).empty,
        .input = text_input.TextInput.init(allocator, "Search...", false),
        .hit_areas = std.ArrayList(ClipHitArea).empty,
        .shared = shared,
        .editor = MultiLineEditor.init(allocator),
    };
    defer {
        panel.editor.deinit();
        panel.hit_areas.deinit(allocator);
        panel.filtered_indices.deinit(allocator);
        panel.input.deinit();
        panel.items.deinit(allocator);
    }

    var orig_item = ClipItem{ .id = 42 };
    const orig_text = "Original Item Content";
    @memcpy(orig_item.preview[0..orig_text.len], orig_text);
    orig_item.preview_len = orig_text.len;
    loadItemFirstLine(&orig_item);
    try panel.items.append(allocator, orig_item);
    panel.decode_cache.put(42, orig_text);
    panel.updateFilter();

    try std.testing.expectEqual(@as(usize, 1), panel.items.items.len);
    try std.testing.expectEqual(@as(usize, 1), panel.filtered_indices.items.len);

    // Start editing item at actual_idx 0
    panel.startEditing(0);
    try std.testing.expect(panel.is_editing);
    try std.testing.expectEqualStrings(orig_text, panel.editor.getText());

    // Modify the content in editor
    panel.editor.moveEnd();
    try panel.editor.insertBytes(" - Updated");
    try std.testing.expectEqualStrings("Original Item Content - Updated", panel.editor.getText());

    // Save edit
    panel.saveEdit();

    // After save:
    // 1. is_editing must be false
    try std.testing.expect(!panel.is_editing);
    // 2. Both old item and new item must exist!
    try std.testing.expectEqual(@as(usize, 2), panel.items.items.len);
    // 3. New item is at index 0
    const new_item = panel.items.items[0];
    try std.testing.expect(new_item.id != 42);
    // 4. Old item is at index 1
    const kept_old_item = panel.items.items[1];
    try std.testing.expectEqual(@as(u64, 42), kept_old_item.id);
    // 5. Decoded content for new item has the updated text
    try std.testing.expectEqualStrings("Original Item Content - Updated", panel.getDecodedContent(new_item));
    // 6. Decoded content for old item is preserved
    try std.testing.expectEqualStrings(orig_text, panel.getDecodedContent(kept_old_item));
    // 7. Selection points to the newly saved item at index 0
    try std.testing.expectEqual(@as(usize, 0), panel.selected_index);
}

test "ClipboardPanel cancel editing discards changes" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    const shared = try SharedWorkerContext.create(allocator);
    defer shared.release();

    var panel = ClipboardPanel{
        .allocator = allocator,
        .cfg = cfg,
        .font = undefined,
        .items = std.ArrayList(ClipItem).empty,
        .filtered_indices = std.ArrayList(usize).empty,
        .input = text_input.TextInput.init(allocator, "Search...", false),
        .hit_areas = std.ArrayList(ClipHitArea).empty,
        .shared = shared,
        .editor = MultiLineEditor.init(allocator),
    };
    defer {
        panel.editor.deinit();
        panel.hit_areas.deinit(allocator);
        panel.filtered_indices.deinit(allocator);
        panel.input.deinit();
        panel.items.deinit(allocator);
    }

    var orig_item = ClipItem{ .id = 99 };
    const orig_text = "Do Not Change";
    @memcpy(orig_item.preview[0..orig_text.len], orig_text);
    orig_item.preview_len = orig_text.len;
    loadItemFirstLine(&orig_item);
    try panel.items.append(allocator, orig_item);
    panel.updateFilter();

    panel.startEditing(0);
    try std.testing.expect(panel.is_editing);
    try panel.editor.insertBytes("Modified ");

    panel.cancelEdit();
    try std.testing.expect(!panel.is_editing);
    try std.testing.expectEqual(@as(usize, 1), panel.items.items.len);
    try std.testing.expectEqual(@as(u64, 99), panel.items.items[0].id);
}

test "generateQr uses qrcode.h to produce valid QR matrices" {
    const qr1 = generateQr("https://example.com");
    try std.testing.expect(qr1 != null);
    const code = qr1.?;
    try std.testing.expect(code.size >= 21);
    // Position detection patterns must be dark at (0, 0), (code.size - 1, 0), (0, code.size - 1)
    try std.testing.expect(code.isDark(0, 0));
    try std.testing.expect(code.isDark(code.size - 1, 0));
    try std.testing.expect(code.isDark(0, code.size - 1));

    // Test larger content
    const large_text = "This is a longer test string to test QR code version scaling using qrcode.h header in clipboard panel";
    const qr2 = generateQr(large_text);
    try std.testing.expect(qr2 != null);
    try std.testing.expect(qr2.?.size > code.size);

    var buf_1500: [1500]u8 = @splat('A');
    const qr3 = generateQr(&buf_1500);
    try std.testing.expect(qr3 != null);

    var buf_4296: [4296]u8 = @splat('A');
    const qr4 = generateQr(&buf_4296);
    try std.testing.expect(qr4 != null);
    try std.testing.expectEqual(@as(u32, 177), qr4.?.size);

    // Over limit: 4297 characters
    var buf_4297: [4297]u8 = @splat('A');
    const qr5 = generateQr(&buf_4297);
    try std.testing.expect(qr5 == null);
}

test "MultiLineEditor text wrapping and visual navigation" {
    const allocator = std.testing.allocator;
    var editor = MultiLineEditor.init(allocator);
    defer editor.deinit();

    // With null font, each character is 8px wide. max_w = 80px allows ~10 chars per line.
    try editor.setText("The quick brown fox jumps over the lazy dog");
    editor.recomputeVisualLines(null, 16, 80);

    // Should wrap into multiple visual lines
    try std.testing.expect(editor.visual_lines.items.len > 1);
    try std.testing.expectEqual(@as(usize, 0), editor.visual_lines.items[0].logical_line);
    try std.testing.expect(editor.visual_lines.items[0].is_first);
    try std.testing.expectEqual(@as(usize, 0), editor.visual_lines.items[1].logical_line);
    try std.testing.expect(!editor.visual_lines.items[1].is_first);

    // Test visual Up and Down navigation
    editor.cursor_idx = 0;
    try std.testing.expectEqual(@as(usize, 0), editor.getVisualLineForCursor());

    editor.moveDownWithFont(null, 16);
    try std.testing.expectEqual(@as(usize, 1), editor.getVisualLineForCursor());

    editor.moveUpWithFont(null, 16);
    try std.testing.expectEqual(@as(usize, 0), editor.getVisualLineForCursor());

    // Test Home and End on wrapped lines
    editor.moveEnd(); // moves to visual line end
    try std.testing.expectEqual(editor.visual_lines.items[0].end, editor.cursor_idx);

    editor.moveHome(); // moves to visual line start
    try std.testing.expectEqual(@as(usize, 0), editor.cursor_idx);
}
