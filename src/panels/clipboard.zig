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
const qrcode = @import("../graphics/qrcode.zig");

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
        };

        self.input.focused = true;
        self.filtered_indices.ensureTotalCapacity(allocator, 500) catch {};
        self.hit_areas.ensureTotalCapacity(allocator, 64) catch {};

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

    /// Process background worker updates. Returns true if redraw needed.
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
                        // Insert at front by shifting (simplified: append, filter shows last)
                        result_items[result_count] = item;
                        result_count += 1;
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

        // Decode from cliphist to preserve full multi-line content.
        var cmd_buf: [256]u8 = undefined;
        const cmd = std.fmt.bufPrintSentinel(&cmd_buf, "export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; cliphist decode {d} | wl-copy", .{item.id}, 0) catch return;
        sys_status.spawnCmd(cmd);

        self.running = false;
    }

    pub fn deleteSelection(self: *ClipboardPanel, actual_idx: usize) void {
        if (actual_idx >= self.items.items.len) return;
        const item = self.items.items[actual_idx];

        var cmd_buf: [256]u8 = undefined;
        const cmd = std.fmt.bufPrintSentinel(&cmd_buf, "export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; printf '{d}\\t' | cliphist delete", .{item.id}, 0) catch return;
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
                        .toggle_qr => {
                            self.show_qr = !self.show_qr;
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

        const clear_hov = ui.hovered("clip-clear", 0);
        _ = ui.open(.{
            .id = "clip-clear",
            .width = .{ .fixed = @floatFromInt(64 * scale) },
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
            .gap = ui.su(6),
            .padding = .{ .top = ui.su(10) },
            .clip_vertical = true,
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
            while (r < visible_rows and (self.scroll_offset + r) < total_filtered) : (r += 1) {
                const filter_idx = self.scroll_offset + r;
                const actual_idx = self.filtered_indices.items[filter_idx];
                const item = self.items.items[actual_idx];
                const is_selected = (filter_idx == self.selected_index);
                const card_hov = ui.hovered("clip-card", @intCast(r));

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
                const t_str = truncateStr(target, &self.font, clean_slice, col1_w -| 92 * scale, &trunc_buf);

                _ = ui.open(.{
                    .id = "clip-card",
                    .index = @intCast(r),
                    .width = .{ .grow = .{} },
                    .height = .{ .fixed = @floatFromInt(52 * scale) },
                    .direction = .row,
                    .padding = .{ .left = ui.su(10), .right = ui.su(10) },
                    .gap = ui.su(6),
                    .bg = if (is_selected)
                        Color.init(42, self.cfg.theme.accent.r, self.cfg.theme.accent.g, self.cfg.theme.accent.b)
                    else if (card_hov)
                        self.cfg.theme.surface
                    else
                        null,
                    .radius = ui.f(self.cfg.theme.radius_button),
                    .border = if (is_selected or card_hov) ui.su(1) else 0,
                    .border_color = if (is_selected)
                        Color.init(80, self.cfg.theme.accent.r, self.cfg.theme.accent.g, self.cfg.theme.accent.b)
                    else
                        self.cfg.theme.border,
                    .align_y = .center,
                });

                _ = ui.open(.{
                    .width = .{ .grow = .{} },
                    .height = .{ .grow = .{} },
                    .align_y = .center,
                    .clip_horizontal = true,
                });
                ui.text(t_str, .{
                    .size = self.cfg.typography.ui * scale,
                    .color = if (is_selected) self.cfg.theme.text_bright else self.cfg.theme.text_main,
                });
                ui.close();

                const del_hov = ui.hovered("clip-del", @intCast(r));
                _ = ui.open(.{
                    .id = "clip-del",
                    .index = @intCast(r),
                    .width = .{ .fixed = @floatFromInt(36 * scale) },
                    .height = .{ .fixed = @floatFromInt(36 * scale) },
                    .bg = if (del_hov) Color.init(45, self.cfg.theme.error_color.r, self.cfg.theme.error_color.g, self.cfg.theme.error_color.b) else null,
                    .radius = ui.f(5),
                    .align_x = .center,
                    .align_y = .center,
                });
                ui.icon("trash", icon_sz, if (del_hov) self.cfg.theme.error_color else Color.init(100, self.cfg.theme.text_muted.r, self.cfg.theme.text_muted.g, self.cfg.theme.text_muted.b), 0);
                ui.close();

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
            try self.appendHitRect(rect, iscale, .clear_all);
        }
        if (total_filtered > 0) {
            const visible_rows: usize = 10;
            var r: usize = 0;
            while (r < visible_rows and (self.scroll_offset + r) < total_filtered) : (r += 1) {
                const filter_idx = self.scroll_offset + r;
                const actual_idx = self.filtered_indices.items[filter_idx];
                // Delete is appended first so it wins the overlap test.
                if (ui.rectOf("clip-del", @intCast(r))) |rect| {
                    try self.appendHitRect(rect, iscale, .{ .delete_item = actual_idx });
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
        const qr_available = preview_content.len > 0 and preview_content.len <= 2048;

        // QR icon button replacing "Preview" label
        const qr_btn_x = x;
        const qr_btn_y = y + 4 * iscale;
        const qr_btn_w: u32 = 28 * scale;
        const qr_btn_h: u32 = 28 * scale;
        const qr_icon_sz = 18 * scale;
        const qr_hov = self.isAreaHovered(@divTrunc(qr_btn_x, iscale), @divTrunc(qr_btn_y, iscale), 28, 28);

        if (qr_available and (self.show_qr or qr_hov)) {
            target.fillSquircle(qr_btn_x, qr_btn_y, qr_btn_w, qr_btn_h, 6 * scale, if (self.show_qr) self.cfg.theme.accent else self.cfg.theme.surface);
            target.drawSquircleBorder(qr_btn_x, qr_btn_y, qr_btn_w, qr_btn_h, 6 * scale, 1, self.cfg.theme.border);
        }

        const qr_icon_col = if (self.show_qr and qr_available) self.cfg.theme.accent_fg else (if (qr_available and qr_hov) self.cfg.theme.accent else self.cfg.theme.text_muted);
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

        if (qr_available) {
            try self.hit_areas.append(self.allocator, .{
                .x = @divTrunc(qr_btn_x, iscale),
                .y = @divTrunc(qr_btn_y, iscale),
                .w = 28,
                .h = 28,
                .action = .toggle_qr,
            });
        }

        if (self.show_qr) {
            const content = self.getDecodedContent(item);
            const can_qr = content.len > 0 and content.len <= 2048;
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
                const qr = qrcode.encodeText(content);
                const quiet_zone: u32 = 2;
                const total_modules = qr.size + quiet_zone * 2;
                const max_box = @min(if (w > 48 * scale) w - 48 * scale else w, if (card_h > 48 * scale) card_h - 48 * scale else card_h);
                const mod_size = @max(1, max_box / total_modules);
                const qr_px = total_modules * mod_size;
                const qr_box_x = x + @divTrunc(@as(i32, @intCast(w)) - @as(i32, @intCast(qr_px)), 2);
                const qr_box_y = card_y + @divTrunc(@as(i32, @intCast(card_h)) - @as(i32, @intCast(qr_px)), 2);

                target.fillSquircle(qr_box_x, qr_box_y, qr_px, qr_px, 8 * scale, theme.Color.rgb(255, 255, 255));
                target.drawSquircleBorder(qr_box_x, qr_box_y, qr_px, qr_px, 8 * scale, 1, theme.Color.rgb(220, 220, 220));

                var qy: u32 = 0;
                while (qy < qr.size) : (qy += 1) {
                    var qx: u32 = 0;
                    while (qx < qr.size) : (qx += 1) {
                        if (qr.isDark(qx, qy)) {
                            const mx = qr_box_x + @as(i32, @intCast((quiet_zone + qx) * mod_size));
                            const my = qr_box_y + @as(i32, @intCast((quiet_zone + qy) * mod_size));
                            target.fillRect(mx, my, mod_size, mod_size, theme.Color.rgb(18, 18, 18));
                        }
                    }
                }
            } else {
                const msg = if (content.len == 0) "No content to generate QR" else "Clipboard content is too large (max 2 KB)";
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
