const std = @import("std");
const c = @import("../c.zig").c;
const renderer = @import("../core/renderer.zig");
const theme = @import("../core/theme.zig");
const Color = theme.Color;
const config = @import("../core/config.zig");
const sys_status = @import("../services/system_status.zig");
const text_input = @import("../core/text_input.zig");
const icons = @import("../graphics/icons.zig");

pub const ClipType = enum {
    text,
    image,
};

pub const ClipItem = struct {
    id: u64,
    clip_type: ClipType = .text,
    preview: [160]u8 = [_]u8{0} ** 160,
    preview_len: usize = 0,
    first_line: [160]u8 = [_]u8{0} ** 160,
    first_line_len: usize = 0,
    first_line_loaded: bool = false,

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

/// Pure in-memory first line extractor from preview without any subprocess or popen calls.
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
        buf: [8192]u8 = [_]u8{0} ** 8192,
        access_seq: u64 = 0,
    };

    entries: [64]Entry = [_]Entry{.{}} ** 64,
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

    entries: [16]Entry = [_]Entry{.{}} ** 16,
    seq_counter: u64 = 1,
    allocator: std.mem.Allocator = undefined,
    total_bytes: usize = 0,

    const max_bytes: usize = 32 * 1024 * 1024;

    pub fn init(allocator: std.mem.Allocator) ImageCache {
        return .{
            .entries = [_]Entry{.{}} ** 16,
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

/// Nearest-neighbour downscale used for preview thumbnails of oversized
/// clipboard images. The caller owns the returned image and must free the
/// original separately.
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
/// Ensures background threads never access freed panel memory or block the UI thread on exit.
pub const SharedWorkerContext = struct {
    ref_count: std.atomic.Value(u32),
    allocator: std.mem.Allocator,
    wake_fd: c_int,
    stop: std.atomic.Value(bool),

    history_lock: Mutex,
    history_done: bool = false,
    history_items: [500]ClipItem = [_]ClipItem{.{ .id = 0 }} ** 500,
    history_count: usize = 0,

    decode_lock: Mutex,
    decode_cond: Condition,
    decode_req_id: ?u64 = null,
    decode_res_id: u64 = 0,
    // Dynamically sized so large screenshots are not truncated. Grown by the
    // decode worker and released with the shared context.
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
            .history_items = [_]ClipItem{.{ .id = 0 }} ** 500,
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
var session_cached_items: [500]ClipItem = [_]ClipItem{.{ .id = 0 }} ** 500;
var session_cached_count: usize = 0;
var session_has_cache: bool = false;

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
};

pub const ClipboardPanel = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    font: renderer.Font,

    // 2-column layout dimensions
    width: u32 = 1500,
    height: u32 = 750,
    running: bool = true,

    items: std.ArrayList(ClipItem),
    filtered_indices: std.ArrayList(usize),
    input: text_input.TextInput,

    selected_index: usize = 0,
    scroll_offset: usize = 0,

    pointer_x: i32 = -1,
    pointer_y: i32 = -1,

    hit_areas: std.ArrayList(ClipHitArea),

    history_loading: bool = true,
    decode_cache: DecodedCache = .{},
    image_cache: ImageCache = .{},

    shared: *SharedWorkerContext,
    history_thread: ?std.Thread = null,
    worker_thread: ?std.Thread = null,

    // Incremental search optimization
    prev_query_buf: [128]u8 = [_]u8{0} ** 128,
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
        };

        self.input.focused = true;
        self.filtered_indices.ensureTotalCapacity(allocator, 500) catch {};
        self.hit_areas.ensureTotalCapacity(allocator, 64) catch {};

        // If session cache is present, populate immediately for 0ms instant display
        if (session_has_cache and session_cached_count > 0) {
            for (session_cached_items[0..session_cached_count]) |item| {
                self.items.append(allocator, item) catch break;
            }
            self.history_loading = false;
            self.updateFilter();
            self.requestDecodeSelected();
        }

        // Spawn background workers immediately (no delayed polling or timer sleep)
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
        // Signal background workers to stop and detach them. Never block the UI thread with joins!
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

        // Drop panel's reference to shared context. Workers hold their own refs and cleanup on finish.
        self.shared.release();

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
    }

    /// Process updates from background workers. Returns true if UI redraw is required.
    pub fn tick(self: *ClipboardPanel) bool {
        var changed = false;

        // 1. Process history worker results
        self.shared.history_lock.lock();
        if (self.shared.history_done) {
            self.shared.history_done = false;
            const count = self.shared.history_count;
            for (self.items.items) |*old_item| old_item.deinit(self.allocator);
            self.items.clearRetainingCapacity();
            self.image_cache.clear();
            for (self.shared.history_items[0..count]) |item| {
                self.items.append(self.allocator, item) catch break;
            }
            self.history_loading = false;

            // Update process session cache for warm reopen
            session_cached_count = @min(count, session_cached_items.len);
            @memcpy(session_cached_items[0..session_cached_count], self.shared.history_items[0..session_cached_count]);
            session_has_cache = true;
            self.shared.history_lock.unlock();

            self.updateFilter();
            self.requestDecodeSelected();
            changed = true;
        } else {
            self.shared.history_lock.unlock();
        }

        // 2. Process decode worker results
        self.shared.decode_lock.lock();
        if (self.shared.decode_res_ready) {
            self.shared.decode_res_ready = false;
            const res_id = self.shared.decode_res_id;
            const res_len_raw = self.shared.decode_res_len;
            // Check if high bit is set (image flag)
            const is_image = (res_len_raw & 0x80000000) != 0;
            const res_len = res_len_raw & 0x7FFFFFFF;
            if (res_len > 0) {
                if (is_image) {
                    // Decode image from raw bytes
                    const image_data = self.shared.decode_res_buf[0..res_len];
                    var img: ?*renderer.Image = null;
                    // Try PNG first, then JPEG
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

                        // Bound preview memory while still showing large
                        // images: downscale oversized bitmaps to a thumbnail
                        // before putting them in the cache. Previously images
                        // whose decoded buffers exceeded the cache limit were
                        // discarded entirely, so large screenshots showed no
                        // preview at all.
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

            // Discard stale decode results: only trigger redraw if currently selected item is res_id
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

            // Large clipboard images (screenshots, photos) can be tens of
            // megabytes. Read into a heap buffer instead of the old 1 MiB
            // stack buffer, otherwise the payload was truncated and the image
            // silently failed to decode.
            const max_decoded_bytes: usize = 64 * 1024 * 1024;
            const result = ctx.allocator.alloc(u8, max_decoded_bytes) catch return;
            defer ctx.allocator.free(result);
            var result_len: usize = 0;
            var cmd_buf: [256]u8 = undefined;
            if (std.fmt.bufPrintZ(&cmd_buf, "export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; cliphist decode {d} 2>/dev/null", .{id})) |cmd| {
                if (c.popen(cmd.ptr, "r")) |pipe| {
                    while (result_len < result.len) {
                        const n = c.fread(result[result_len..].ptr, 1, result.len - result_len, pipe);
                        if (n == 0) break;
                        result_len += n;
                    }
                    _ = c.pclose(pipe);
                }
            } else |_| {}

            if (ctx.stop.load(.acquire)) return;

            // Check if result is an image (starts with PNG/JPEG magic bytes)
            const is_png = result_len >= 8 and result[0] == 0x89 and result[1] == 0x50 and result[2] == 0x4E and result[3] == 0x47 and result[4] == 0x0D and result[5] == 0x0A and result[6] == 0x1A and result[7] == 0x0A;
            const is_jpeg = result_len >= 3 and result[0] == 0xFF and result[1] == 0xD8 and result[2] == 0xFF;

            ctx.decode_lock.lock();
            if (!ctx.stop.load(.acquire) and result_len > ctx.decode_res_buf.len) {
                // Grow the shared staging buffer outside the lock so the UI is
                // never blocked by a (potentially large) allocation.
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

                // Check if this is an image entry (cliphist marks images with [[ binary data ... ]])
                const is_image = std.mem.startsWith(u8, content, "[[ binary data") or std.mem.startsWith(u8, content, "[[ binary data ");

                var item = ClipItem{ .id = id, .clip_type = if (is_image) .image else .text };
                const preview_len = @min(content.len, item.preview.len);
                @memcpy(item.preview[0..preview_len], content[0..preview_len]);
                item.preview_len = preview_len;
                const first_len = @min(content.len, item.first_line.len);
                @memcpy(item.first_line[0..first_len], content[0..first_len]);
                item.first_line_len = first_len;
                item.first_line_loaded = true;
                result_items[result_count] = item;
                result_count += 1;
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
                if (std.ascii.indexOfIgnoreCase(prev, q) != null) {
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
                if (std.ascii.indexOfIgnoreCase(prev, q) != null) {
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

        // Decode directly from cliphist to preserve complete unstripped multi-line content
        var cmd_buf: [256]u8 = undefined;
        const cmd = std.fmt.bufPrintZ(&cmd_buf, "export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; cliphist decode {d} | wl-copy", .{item.id}) catch return;
        sys_status.spawnCmd(cmd);

        self.running = false;
    }

    pub fn deleteSelection(self: *ClipboardPanel, actual_idx: usize) void {
        if (actual_idx >= self.items.items.len) return;
        const item = self.items.items[actual_idx];

        var cmd_buf: [256]u8 = undefined;
        const cmd = std.fmt.bufPrintZ(&cmd_buf, "export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; printf '{d}\\t' | cliphist delete", .{item.id}) catch return;
        sys_status.spawnCmd(cmd);

        self.decode_cache.remove(item.id);
        self.image_cache.remove(item.id);

        var removed = self.items.orderedRemove(actual_idx);
        removed.deinit(self.allocator);
        self.updateFilter();
    }

    pub fn clearAll(self: *ClipboardPanel) void {
        sys_status.spawnCmd("export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; cliphist wipe");
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.clearRetainingCapacity();
        self.decode_cache.clear();
        self.image_cache.clear();
        self.updateFilter();
    }

    pub fn getDecodedContent(self: *ClipboardPanel, item: ClipItem) []const u8 {
        if (self.decode_cache.get(item.id)) |cached| {
            return cached;
        }
        return item.preview[0..item.preview_len];
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
            const pad_x: i32 = 18;
            const text_ox = pad_x + 28;
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

        const pad_x: i32 = 18;
        const col1_w: u32 = 310;
        const search_y: i32 = 16 + 28;
        const search_h: u32 = 32;
        const text_ox = pad_x + 28;

        if (is_pressed) {
            if (self.input.handlePointerDown(x, y, pad_x, search_y, col1_w, search_h, text_ox, &self.font)) {
                return true;
            }

            for (self.hit_areas.items) |area| {
                if (x >= area.x and x < area.x + @as(i32, @intCast(area.w)) and
                    y >= area.y and y < area.y + @as(i32, @intCast(area.h)))
                {
                    switch (area.action) {
                        .none => {},
                        .click_card => |filter_idx| {
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
        _ = x;
        _ = y;
        const total = self.filtered_indices.items.len;
        if (total == 0) return false;

        const visible_rows: usize = 8;
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
        // Navigation keys
        if (sym == c.XKB_KEY_Escape) {
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

        // 0. Transparent base
        target.clear(theme.Color.transparent);

        const w = target.width;
        const h = target.height;
        const radius: u32 = self.cfg.panel_radius * scale;

        // Container: Clean flat surface with subtle rounded border and drop shadow
        target.drawDropShadow(0, 0, w, h, radius, 10 * scale, self.cfg.theme.shadow_dark);
        target.fillRoundedRect(0, 0, w, h, radius, self.cfg.theme.panel_bg);
        target.drawRoundedBorder(0, 0, w, h, radius, 1 * scale, self.cfg.theme.panel_border);

        const pad_x: i32 = 24 * @as(i32, @intCast(scale));
        const head_y: i32 = 20 * @as(i32, @intCast(scale));

        // ================= COLUMN 1: List (Left, 480px) =================
        const col1_x: i32 = pad_x;
        const col1_w: u32 = 480 * scale;

        // Header: Clean title, count, and minimal clear action
        const icon_sz = self.cfg.typography.bar_icon * scale;
        const sec_sz = self.cfg.typography.secondary * scale;
        const title_sz = self.cfg.typography.title * scale;
        const icon_cx = col1_x + @divTrunc(@as(i32, @intCast(icon_sz)), 2);
        const icon_cy = head_y + 20 * @as(i32, @intCast(scale)) + @divTrunc(@as(i32, @intCast(icon_sz)), 2);
        icons.drawSvgIcon(
            target,
            self.allocator,
            "clipboard",
            icon_sz,
            scale,
            icon_cx,
            icon_cy,
            self.cfg.theme.accent,
        );
        const text_x = icon_cx + @divTrunc(@as(i32, @intCast(icon_sz)), 2) + 6 * @as(i32, @intCast(scale));
        const ascender_half = @as(u32, @intCast(self.font.ascender_px)) * scale / 2;
        target.drawTextWithSize(&self.font, "Clipboard", text_x, icon_cy + @as(i32, @intCast(ascender_half)), title_sz, self.cfg.theme.text_bright);

        // Simple count text / loading indicator
        var count_buf: [32]u8 = undefined;
        const count_str = if (self.history_loading)
            "..."
        else
            (std.fmt.bufPrint(&count_buf, "{d}", .{self.items.items.len}) catch "");
        target.drawTextWithSize(&self.font, count_str, col1_x + 148 * @as(i32, @intCast(scale)), head_y + 20 * @as(i32, @intCast(scale)), sec_sz, self.cfg.theme.text_muted);

        // Clear action button: minimal text button
        const clear_w: u32 = 64 * scale;
        const clear_h: u32 = 28 * scale;
        const clear_x = col1_x + @as(i32, @intCast(col1_w)) - @as(i32, @intCast(clear_w));
        const clear_hover = self.isAreaHovered(clear_x, head_y, clear_w, clear_h);
        if (clear_hover) {
            target.fillSquircle(clear_x, head_y, clear_w, clear_h, 6 * scale, self.cfg.theme.elevated);
        }
        const clr_fg = if (clear_hover) self.cfg.theme.error_color else self.cfg.theme.text_muted;
        const clr_text = "Clear";
        const clr_tw = target.measureTextWithSize(&self.font, clr_text, self.cfg.typography.button_text * scale);
        const clr_tx = clear_x + @divTrunc(@as(i32, @intCast(clear_w)) - @as(i32, @intCast(clr_tw)), 2);
        target.drawTextWithSize(&self.font, clr_text, clr_tx, head_y + 19 * @as(i32, @intCast(scale)), self.cfg.typography.button_text * scale, clr_fg);
        try self.hit_areas.append(self.allocator, .{
            .x = clear_x,
            .y = head_y,
            .w = clear_w,
            .h = clear_h,
            .action = .clear_all,
        });

        // Search Input Box (Flat, 48px height)
        const search_y: i32 = head_y + 36;
        const search_h: u32 = 48;
        const is_query_active = self.input.getText().len > 0 or self.input.focused;

        target.fillRoundedRect(col1_x, search_y, col1_w, search_h, self.cfg.theme.radius_pill, self.cfg.theme.surface);
        const search_border_col = if (is_query_active) self.cfg.theme.accent else self.cfg.theme.border;
        target.drawRoundedBorder(col1_x, search_y, col1_w, search_h, self.cfg.theme.radius_pill, 1, search_border_col);

        const icon_col = if (self.input.focused) self.cfg.theme.accent else self.cfg.theme.text_muted;
        icons.drawSvgIcon(
            target,
            self.allocator,
            "search",
            self.cfg.typography.bar_icon * scale,
            scale,
            col1_x + 12 + @divTrunc(@as(i32, @intCast(self.cfg.typography.bar_icon * scale)), 2),
            search_y + 32,
            icon_col,
        );

        const text_ox = col1_x + 40 * @as(i32, @intCast(scale));
        self.input.render(
            target,
            &self.font,
            col1_x,
            search_y,
            col1_w,
            search_h,
            text_ox,
            self.cfg.theme.text_bright,
            self.cfg.theme.text_muted,
            self.cfg.theme.accent,
            self.cfg.typography.ui * scale,
        );

        // History items list (Clean flat cards, 10 visible rows)
        const list_start_y: i32 = search_y + 58;
        const item_h: u32 = 52;
        const item_gap: u32 = 6;
        const visible_rows: usize = 10;

        const total_filtered = self.filtered_indices.items.len;
        if (total_filtered == 0) {
            const empty_y = list_start_y + 160;
            const empty_msg = if (self.history_loading)
                "Loading clipboard history..."
            else if (self.items.items.len == 0)
                "Clipboard is empty"
            else
                "No matching items";
            const empty_icon_name = if (self.history_loading) "refresh" else "clipboard";
            const empty_icon_sz = self.cfg.typography.title * scale;
            const em_w = target.measureTextWithSize(&self.font, empty_msg, self.cfg.typography.ui);
            const em_x = col1_x + @divTrunc(@as(i32, @intCast(col1_w)) - @as(i32, @intCast(em_w)), 2);
            icons.drawSvgIcon(
                target,
                self.allocator,
                empty_icon_name,
                empty_icon_sz,
                scale,
                em_x + @divTrunc(@as(i32, @intCast(em_w)), 2),
                empty_y - 12,
                self.cfg.theme.text_muted,
            );
            target.drawTextWithSize(&self.font, empty_msg, em_x, empty_y, self.cfg.typography.ui, self.cfg.theme.text_muted);
        } else {
            var r: usize = 0;
            var cur_y = list_start_y;
            while (r < visible_rows and (self.scroll_offset + r) < total_filtered) : (r += 1) {
                const filter_idx = self.scroll_offset + r;
                const actual_idx = self.filtered_indices.items[filter_idx];
                const item = self.items.items[actual_idx];

                const is_selected = (filter_idx == self.selected_index);
                const is_hovered = self.isAreaHovered(col1_x, cur_y, col1_w, item_h);

                // Card surface & subtle selection / hover styling
                if (is_selected) {
                    const sel_bg = Color.init(42, self.cfg.theme.accent.r, self.cfg.theme.accent.g, self.cfg.theme.accent.b);
                    target.fillRoundedRect(col1_x, cur_y, col1_w, item_h, self.cfg.theme.radius_button, sel_bg);
                    target.drawRoundedBorder(col1_x, cur_y, col1_w, item_h, self.cfg.theme.radius_button, 1, Color.init(80, self.cfg.theme.accent.r, self.cfg.theme.accent.g, self.cfg.theme.accent.b));
                    target.fillRoundedRect(col1_x + 2, cur_y + 8, 4, item_h - 16, 2, self.cfg.theme.accent);
                } else if (is_hovered) {
                    target.fillRoundedRect(col1_x, cur_y, col1_w, item_h, self.cfg.theme.radius_button, self.cfg.theme.surface);
                    target.drawRoundedBorder(col1_x, cur_y, col1_w, item_h, self.cfg.theme.radius_button, 1, self.cfg.theme.border);
                }

                // First line from pre-parsed in-memory preview
                const first_line = if (item.first_line_len > 0) item.first_line[0..item.first_line_len] else item.preview[0..item.preview_len];
                var clean_buf: [160]u8 = undefined;
                var clean_len: usize = 0;
                for (first_line) |b| {
                    if (clean_len >= clean_buf.len) break;
                    if (b == '\n' or b == '\r') break;
                    if (b == '\t') {
                        clean_buf[clean_len] = ' ';
                    } else {
                        clean_buf[clean_len] = b;
                    }
                    clean_len += 1;
                }
                const clean_slice = std.mem.trim(u8, clean_buf[0..clean_len], " ");

                const del_size: u32 = 36;
                const text_start_x = if (is_selected) col1_x + 16 else col1_x + 12;
                const max_txt_w = col1_w - @as(u32, @intCast(text_start_x - col1_x)) - del_size - 14;

                var trunc_buf: [160]u8 = undefined;
                const t_str = truncateStr(target, &self.font, clean_slice, max_txt_w, &trunc_buf);
                const txt_color = if (is_selected) self.cfg.theme.text_bright else self.cfg.theme.text_main;
                const text_baseline = cur_y + @divTrunc(@as(i32, @intCast(item_h)) + self.font.ascender_px, 2) - 1;
                target.drawText(&self.font, t_str, text_start_x, text_baseline, txt_color);

                // Subtle Delete button on the right
                const del_x = col1_x + @as(i32, @intCast(col1_w)) - @as(i32, @intCast(del_size)) - 10;
                const del_y = cur_y + @divTrunc(@as(i32, @intCast(item_h)) - @as(i32, @intCast(del_size)), 2);
                const del_hover = self.isAreaHovered(del_x, del_y, del_size, del_size);
                if (del_hover) {
                    target.fillSquircle(del_x, del_y, del_size, del_size, 5, Color.init(45, self.cfg.theme.error_color.r, self.cfg.theme.error_color.g, self.cfg.theme.error_color.b));
                }
                icons.drawSvgIcon(
                    target,
                    self.allocator,
                    "trash",
                    self.cfg.typography.bar_icon * scale,
                    scale,
                    del_x + @divTrunc(@as(i32, @intCast(del_size)), 2),
                    del_y + @divTrunc(@as(i32, @intCast(del_size)), 2),
                    if (del_hover) self.cfg.theme.error_color else Color.init(100, self.cfg.theme.text_muted.r, self.cfg.theme.text_muted.g, self.cfg.theme.text_muted.b),
                );

                try self.hit_areas.append(self.allocator, .{
                    .x = del_x,
                    .y = del_y,
                    .w = del_size,
                    .h = del_size,
                    .action = .{ .delete_item = actual_idx },
                });

                // Card click hit area: selects or copies
                try self.hit_areas.append(self.allocator, .{
                    .x = col1_x,
                    .y = cur_y,
                    .w = col1_w - del_size - 12,
                    .h = item_h,
                    .action = .{ .click_card = filter_idx },
                });

                cur_y += @as(i32, @intCast(item_h + item_gap));
            }
        }

        // ================= VERTICAL DIVIDER =================
        const sep_x: i32 = col1_x + @as(i32, @intCast(col1_w)) + 16;
        const sep_y: i32 = 20;
        const sep_h: u32 = if (h > 40) h - 40 else h;
        target.fillRect(sep_x, sep_y, 1, sep_h, Color.init(30, self.cfg.theme.border.r, self.cfg.theme.border.g, self.cfg.theme.border.b));

        // ================= COLUMN 2: Minimal Live Preview (Right) =================
        const col2_x: i32 = sep_x + 18;
        const col2_w: u32 = if (w > @as(u32, @intCast(col2_x + pad_x))) w - @as(u32, @intCast(col2_x + pad_x)) else 400;

        const selected_actual: ?usize = if (total_filtered > 0 and self.selected_index < total_filtered)
            self.filtered_indices.items[self.selected_index]
        else
            null;

        try self.renderPreviewColumn(target, col2_x, head_y, col2_w, sep_h, selected_actual, scale);
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
        _ = h;
        const card_y = y + 36;
        const card_h: u32 = if (self.height > @as(u32, @intCast(card_y)) + 64) self.height - @as(u32, @intCast(card_y)) - 64 else 580;

        if (selected_actual_idx == null or selected_actual_idx.? >= self.items.items.len) {
            target.fillSquircle(x, card_y, w, card_h, 10, self.cfg.theme.surface);
            target.drawSquircleBorder(x, card_y, w, card_h, 10, 1, self.cfg.theme.border);

            const icon_name = if (self.history_loading) "refresh" else "clipboard";
            const ph_msg = if (self.history_loading) "Loading history..." else "Select an item to preview";
            const icon_sz = self.cfg.typography.title * scale;
            const msg_w = target.measureTextWithSize(&self.font, ph_msg, self.cfg.typography.ui);

            const center_x = x + @divTrunc(@as(i32, @intCast(w)), 2);
            const center_y = card_y + @divTrunc(@as(i32, @intCast(card_h)), 2);

            icons.drawSvgIcon(
                target,
                self.allocator,
                icon_name,
                icon_sz,
                scale,
                center_x,
                center_y - 14,
                self.cfg.theme.text_muted,
            );
            target.drawTextWithSize(&self.font, ph_msg, center_x - @divTrunc(@as(i32, @intCast(msg_w)), 2), center_y + 22, self.cfg.typography.ui, self.cfg.theme.text_muted);
            return;
        }

        const actual_idx = selected_actual_idx.?;
        const item = self.items.items[actual_idx];

        // Handle image items
        if (item.clip_type == .image) {
            // Try to get cached image
            const cached_img = self.image_cache.get(item.id);
            if (cached_img) |img| {
                // Preview Header
                target.drawTextWithSize(&self.font, "Preview", x, y + 20, self.cfg.typography.title, self.cfg.theme.text_bright);

                var meta_buf: [64]u8 = undefined;
                const shown_w = if (item.image_width > 0) item.image_width else img.width;
                const shown_h = if (item.image_height > 0) item.image_height else img.height;
                const meta_str = std.fmt.bufPrint(&meta_buf, "{d}x{d} · {s}", .{ shown_w, shown_h, item.image_format }) catch "";
                const mw = target.measureTextWithSize(&self.font, meta_str, self.cfg.typography.secondary);
                const meta_x = x + @as(i32, @intCast(w)) - @as(i32, @intCast(mw));
                target.drawTextWithSize(&self.font, meta_str, meta_x, y + 20, self.cfg.typography.secondary, self.cfg.theme.text_muted);

                // Content Card
                target.fillSquircle(x, card_y, w, card_h, 10, self.cfg.theme.surface);
                target.drawSquircleBorder(x, card_y, w, card_h, 10, 1, self.cfg.theme.border);

                // Calculate thumbnail dimensions (maintain aspect ratio, max 90% of card)
                const max_w = w - 40;
                const max_h = card_h - 40;
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

                // Image info below thumbnail
                var info_buf: [64]u8 = undefined;
                const info_str = std.fmt.bufPrint(&info_buf, "{d} × {d} · {s}", .{ shown_w, shown_h, item.image_format }) catch "";
                target.drawTextWithSize(&self.font, info_str, x + 20, thumb_y + @as(i32, @intCast(thumb_h)) + 16, self.cfg.typography.secondary, self.cfg.theme.text_muted);

                return;
            } else {
                // Image not yet decoded or decode failed - show placeholder
                target.fillSquircle(x, card_y, w, card_h, 10, self.cfg.theme.surface);
                target.drawSquircleBorder(x, card_y, w, card_h, 10, 1, self.cfg.theme.border);

                const icon_name = "cat";
                const ph_msg = "Loading preview...";
                const icon_sz = self.cfg.typography.title * scale;
                const msg_w = target.measureTextWithSize(&self.font, ph_msg, self.cfg.typography.ui);
                const center_x = x + @divTrunc(@as(i32, @intCast(w)), 2);
                const center_y = card_y + @divTrunc(@as(i32, @intCast(card_h)), 2);
                icons.drawSvgIcon(
                    target,
                    self.allocator,
                    icon_name,
                    icon_sz,
                    scale,
                    center_x,
                    center_y - 14,
                    self.cfg.theme.text_muted,
                );
                target.drawTextWithSize(&self.font, ph_msg, center_x - @divTrunc(@as(i32, @intCast(msg_w)), 2), center_y + 22, self.cfg.typography.ui, self.cfg.theme.text_muted);
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

        // Preview Header: restrained title & metadata
        target.drawTextWithSize(&self.font, "Preview", x, y + 20, self.cfg.typography.title, self.cfg.theme.text_bright);

        var meta_buf: [64]u8 = undefined;
        const meta_str = std.fmt.bufPrint(&meta_buf, "{d} chars · {d} lines", .{ char_count, line_count }) catch "";
        const mw = target.measureTextWithSize(&self.font, meta_str, self.cfg.typography.secondary);
        const meta_x = x + @as(i32, @intCast(w)) - @as(i32, @intCast(mw));
        target.drawTextWithSize(&self.font, meta_str, meta_x, y + 20, self.cfg.typography.secondary, self.cfg.theme.text_muted);

        // Content Card (Flat surface, 10px squircle radius)
        target.fillSquircle(x, card_y, w, card_h, 10, self.cfg.theme.surface);
        target.drawSquircleBorder(x, card_y, w, card_h, 10, 1, self.cfg.theme.border);

        // Check if content is a simple hex color
        const clean_str = std.mem.trim(u8, content, " \t\r\n");
        const is_hex = (clean_str.len == 7 or clean_str.len == 9 or clean_str.len == 4) and clean_str[0] == '#';

        if (is_hex) {
            const parsed_color = theme.Color.fromHex(clean_str);
            const swatch_size: u32 = 64;
            const swatch_x = x + 24;
            const swatch_y = card_y + 28;

            target.fillSquircle(swatch_x, swatch_y, swatch_size, swatch_size, 10, parsed_color);
            target.drawSquircleBorder(swatch_x, swatch_y, swatch_size, swatch_size, 10, 1, self.cfg.theme.border);

            const detail_x = swatch_x + @as(i32, @intCast(swatch_size)) + 20;
            target.drawTextWithSize(&self.font, clean_str, detail_x, swatch_y + 26, self.cfg.typography.heading, self.cfg.theme.text_bright);

            var rgb_buf: [48]u8 = undefined;
            const rgb_str = std.fmt.bufPrint(&rgb_buf, "rgb({d}, {d}, {d})", .{ parsed_color.r, parsed_color.g, parsed_color.b }) catch "";
            target.drawTextWithSize(&self.font, rgb_str, detail_x, swatch_y + 52, self.cfg.typography.secondary, self.cfg.theme.text_muted);
        } else {
            // Multi-line text display with comfortable padding and clean line spacing
            const gutter_x = x + 40;
            target.fillRect(gutter_x, card_y + 12, 1, card_h - 24, Color.init(20, self.cfg.theme.border.r, self.cfg.theme.border.g, self.cfg.theme.border.b));

            const max_line_w = w - 60;
            const max_visible_lines: usize = 22;
            const line_step: i32 = 25;
            var line_idx: usize = 0;
            var line_start: usize = 0;
            var cur_line_y: i32 = card_y + 26;

            while (line_start < content.len and line_idx < max_visible_lines) {
                var line_end = line_start;
                while (line_end < content.len and content[line_end] != '\n' and content[line_end] != '\r') {
                    line_end += 1;
                }

                const raw_line = content[line_start..line_end];

                // Muted line number
                var num_buf: [16]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{line_idx + 1}) catch "";
                const nw = target.measureTextWithSize(&self.font, num_str, self.cfg.typography.secondary);
                const nx = gutter_x - @as(i32, @intCast(nw)) - 8;
                target.drawTextWithSize(&self.font, num_str, nx, cur_line_y, self.cfg.typography.secondary, self.cfg.theme.text_muted);

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
                const clean_slice = clean_buf[0..clen];

                var trunc_buf: [260]u8 = undefined;
                const display_line = truncateStrWithSize(target, &self.font, clean_slice, self.cfg.typography.ui, max_line_w, &trunc_buf);
                target.drawTextWithSize(&self.font, display_line, gutter_x + 12, cur_line_y, self.cfg.typography.ui, self.cfg.theme.text_bright);

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
                target.drawTextWithSize(&self.font, rem_str, gutter_x + 12, cur_line_y, self.cfg.typography.secondary, self.cfg.theme.text_muted);
            }
        }
    }

    pub fn truncateStrWithSize(target: renderer.Renderer, font: *renderer.Font, str: []const u8, size: u32, max_w: u32, buf: []u8) []const u8 {
        if (str.len == 0) return "";
        if (target.measureTextWithSize(font, str, size) <= max_w) return str;

        const dots_w = target.measureTextWithSize(font, "...", size);
        if (dots_w >= max_w) {
            if (buf.len >= 3) {
                @memcpy(buf[0..3], "...");
                return buf[0..3];
            }
            return "";
        }
        const avail_w = max_w - dots_w;

        // Binary search for maximum prefix that fits in avail_w
        var low: usize = 0;
        var high: usize = @min(str.len, buf.len - 4);
        var best: usize = 0;

        while (low <= high) {
            const mid = low + (high - low) / 2;
            if (mid == 0) {
                low = 1;
                continue;
            }

            var char_mid = mid;
            while (char_mid > 0 and (str[char_mid] & 0xC0) == 0x80) {
                char_mid -= 1;
            }
            if (char_mid == 0) {
                low = mid + 1;
                continue;
            }

            const w = target.measureTextWithSize(font, str[0..char_mid], size);
            if (w <= avail_w) {
                best = char_mid;
                low = mid + 1;
            } else {
                if (char_mid == 0) break;
                high = char_mid - 1;
            }
        }

        if (best == 0) {
            if (buf.len >= 3) {
                @memcpy(buf[0..3], "...");
                return buf[0..3];
            }
            return "";
        }

        @memcpy(buf[0..best], str[0..best]);
        buf[best] = '.';
        buf[best + 1] = '.';
        buf[best + 2] = '.';
        return buf[0 .. best + 3];
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

    try std.testing.expectEqual(@as(u32, 1500), panel.width);
    try std.testing.expectEqual(@as(u32, 750), panel.height);

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

    // Simulate decode result for item 102 (stale result that finished late while item 101 is selected)
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

    // tick() processes decode result: should cache it, but NOT trigger redraw because selection is 101!
    const changed = panel.tick();
    try std.testing.expectEqual(false, changed);

    // The stale decode must be safely stored in decode_cache for item 102
    try std.testing.expectEqualStrings("Decoded 102", panel.decode_cache.get(102).?);

    // Now switch selection to 102: it should immediately be in cache with 0ms delay!
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
    std.debug.print("\n[BENCHMARK] Panel init latency: {d:.2} µs ({d:.3} ms)\n", .{ init_us, init_us / 1000.0 });

    // 2. Measure immediate first frame render time (using fake renderer buffer)
    const render_pixels = try allocator.alloc(u32, panel.width * panel.height);
    defer allocator.free(render_pixels);
    const rend = try renderer.Renderer.init(render_pixels.ptr, panel.width, panel.height, panel.width * 4);

    t0 = getMonotonicNs();
    try panel.render(rend, 1);
    t1 = getMonotonicNs();
    const first_render_us = @as(f64, @floatFromInt(t1 - t0)) / 1000.0;
    std.debug.print("[BENCHMARK] First frame render (loading state) latency: {d:.2} µs ({d:.3} ms)\n", .{ first_render_us, first_render_us / 1000.0 });

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
    std.debug.print("[BENCHMARK] Live history load & filter latency: {d:.2} µs ({d:.3} ms) (items: {d})\n", .{ history_us, history_us / 1000.0, panel.items.items.len });

    // 4. Measure render time with items loaded
    t0 = getMonotonicNs();
    try panel.render(rend, 1);
    t1 = getMonotonicNs();
    const populated_render_us = @as(f64, @floatFromInt(t1 - t0)) / 1000.0;
    std.debug.print("[BENCHMARK] Populated panel render latency: {d:.2} µs ({d:.3} ms)\n", .{ populated_render_us, populated_render_us / 1000.0 });

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
    const decode_us = @as(f64, @floatFromInt(t1 - t0)) / 1000.0;
    std.debug.print("[BENCHMARK] Live selected item decode latency: {d:.2} µs ({d:.3} ms)\n", .{ decode_us, decode_us / 1000.0 });

    // 6. Measure cached preview lookup latency
    if (panel.getSelectedId()) |sel_id| {
        t0 = getMonotonicNs();
        const cached = panel.decode_cache.get(sel_id);
        t1 = getMonotonicNs();
        const cache_lookup_ns = t1 - t0;
        std.debug.print("[BENCHMARK] Cached preview lookup latency: {d} ns (cached: {})\n", .{ cache_lookup_ns, cached != null });
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
    const filter_us = @as(f64, @floatFromInt(t1 - t0)) / 1000.0;
    std.debug.print("[BENCHMARK] Filter 500 items latency: {d:.2} µs ({d:.3} ms)\n", .{ filter_us, filter_us / 1000.0 });

    // 8. Measure instant closing time during in-flight operations
    var panel_closing = try ClipboardPanel.init(allocator, cfg);
    t0 = getMonotonicNs();
    panel_closing.deinit();
    t1 = getMonotonicNs();
    const deinit_us = @as(f64, @floatFromInt(t1 - t0)) / 1000.0;
    std.debug.print("[BENCHMARK] Panel deinit (closing during decode/history) latency: {d:.2} µs ({d:.3} ms)\n\n", .{ deinit_us, deinit_us / 1000.0 });

    // Allow detached background threads in this unit test to finish exiting cleanly
    _ = c.usleep(60000);
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
