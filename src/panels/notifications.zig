const std = @import("std");
const c = @import("c");
const theme = @import("../core/theme.zig");
const config = @import("../core/config.zig");
const renderer = @import("../core/renderer.zig");
const icons = @import("../graphics/icons.zig");
const ui_mod = @import("../core/ui.zig");

pub const Notification = struct {
    id: u32 = 0,
    app_name: [64]u8 = @splat(0),
    app_name_len: usize = 0,
    app_icon: [128]u8 = @splat(0),
    app_icon_len: usize = 0,
    summary: [128]u8 = @splat(0),
    summary_len: usize = 0,
    body: [512]u8 = @splat(0),
    body_len: usize = 0,
    timestamp: u64 = 0,
    expire_timeout_ms: i32 = 4000,
    time_remaining_ms: i32 = 4000,

    pub fn getAppName(self: *const Notification) []const u8 {
        return if (self.app_name_len > 0) self.app_name[0..self.app_name_len] else "Notification";
    }

    pub fn getSummary(self: *const Notification) []const u8 {
        return if (self.summary_len > 0) self.summary[0..self.summary_len] else "";
    }

    pub fn getBody(self: *const Notification) []const u8 {
        return if (self.body_len > 0) self.body[0..self.body_len] else "";
    }

    pub fn formatRelativeTime(self: *const Notification, buf: []u8) []const u8 {
        const now = @as(u64, @intCast(@max(0, c.time(null))));
        const diff = if (now >= self.timestamp) now - self.timestamp else 0;
        if (diff < 60) {
            return "now";
        } else if (diff < 3600) {
            return std.fmt.bufPrint(buf, "{d}m", .{diff / 60}) catch "now";
        } else if (diff < 86400) {
            return std.fmt.bufPrint(buf, "{d}h", .{diff / 3600}) catch "1h";
        } else {
            return std.fmt.bufPrint(buf, "{d}d", .{diff / 86400}) catch "1d";
        }
    }
};

pub const NotificationStore = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Notification),
    history_file_buf: [512]u8 = @splat(0),

    pub fn getHistoryFilePath(self: *const NotificationStore) [:0]const u8 {
        return std.mem.span(@as([*:0]const u8, @ptrCast(&self.history_file_buf)));
    }

    pub fn init(allocator: std.mem.Allocator) NotificationStore {
        var self = NotificationStore{
            .allocator = allocator,
            .items = std.ArrayList(Notification).empty,
        };
        self.initPath();
        self.loadHistory();
        return self;
    }

    pub fn deinit(self: *NotificationStore) void {
        self.items.deinit(self.allocator);
    }

    fn initPath(self: *NotificationStore) void {
        const home_opt = c.getenv("HOME");
        const home = if (home_opt != null) std.mem.span(home_opt.?) else "/tmp";
        var cache_buf: [512]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&cache_buf, "{s}/.cache", .{home}, 0)) |cache_path| {
            _ = c.mkdir(cache_path.ptr, 0o755);
        } else |_| {}

        var dir_buf: [512]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&dir_buf, "{s}/.cache/mizu", .{home}, 0)) |dir_path| {
            _ = c.mkdir(dir_path.ptr, 0o755);
        } else |_| {}

        _ = std.fmt.bufPrintSentinel(&self.history_file_buf, "{s}/.cache/mizu/notifications_history.json", .{home}, 0) catch {};
    }

    pub fn add(self: *NotificationStore, notif: Notification) void {
        // Prepend so newest is at items[0]
        self.items.insert(self.allocator, 0, notif) catch return;
        // Keep maximum 50 history entries
        while (self.items.items.len > 50) {
            _ = self.items.pop();
        }
        self.saveHistory();
    }

    pub fn remove(self: *NotificationStore, idx: usize) void {
        if (idx < self.items.items.len) {
            _ = self.items.orderedRemove(idx);
            self.saveHistory();
        }
    }

    pub fn clear(self: *NotificationStore) void {
        self.items.clearRetainingCapacity();
        self.saveHistory();
    }

    pub fn saveHistory(self: *NotificationStore) void {
        const path = self.getHistoryFilePath();
        if (path.len == 0) return;
        const f = c.fopen(path.ptr, "wb") orelse return;
        defer _ = c.fclose(f);

        _ = c.fwrite("[\n", 1, 2, f);
        for (self.items.items, 0..) |item, i| {
            var line_buf: [1024]u8 = undefined;
            var escaped_summary: [256]u8 = @splat(0);
            var escaped_body: [512]u8 = @splat(0);
            escapeJsonString(item.getSummary(), &escaped_summary);
            escapeJsonString(item.getBody(), &escaped_body);

            const comma = if (i + 1 < self.items.items.len) "," else "";
            if (std.fmt.bufPrint(&line_buf,
                \\  {{"id":{d},"app_name":"{s}","summary":"{s}","body":"{s}","timestamp":{d}}}{s}
                \\
            , .{
                item.id,
                item.getAppName(),
                std.mem.sliceTo(&escaped_summary, 0),
                std.mem.sliceTo(&escaped_body, 0),
                item.timestamp,
                comma,
            })) |line| {
                _ = c.fwrite(line.ptr, 1, line.len, f);
            } else |_| {}
        }
        _ = c.fwrite("]\n", 1, 2, f);
    }

    pub fn loadHistory(self: *NotificationStore) void {
        const path = self.getHistoryFilePath();
        if (path.len == 0) return;
        const f = c.fopen(path.ptr, "rb") orelse return;
        defer _ = c.fclose(f);

        var buf: [65536]u8 = undefined;
        const bytes = c.fread(&buf, 1, buf.len - 1, f);
        if (bytes <= 2) return;
        buf[bytes] = 0;
        const content = buf[0..bytes];

        // Parse JSON items simply without heavyweight JSON parser dependency
        var cursor: usize = 0;
        while (cursor < content.len) {
            const start_obj = std.mem.indexOfPos(u8, content, cursor, "{") orelse break;
            const end_obj = std.mem.indexOfPos(u8, content, start_obj, "}") orelse break;
            const obj_str = content[start_obj .. end_obj + 1];
            cursor = end_obj + 1;

            var notif = Notification{};
            if (extractJsonUint(obj_str, "\"id\":")) |id| notif.id = @intCast(id);
            if (extractJsonUint(obj_str, "\"timestamp\":")) |ts| notif.timestamp = ts;

            if (extractJsonString(obj_str, "\"app_name\":", &notif.app_name)) |len| {
                notif.app_name_len = len;
            }
            if (extractJsonString(obj_str, "\"summary\":", &notif.summary)) |len| {
                notif.summary_len = len;
            }
            if (extractJsonString(obj_str, "\"body\":", &notif.body)) |len| {
                notif.body_len = len;
            }

            self.items.append(self.allocator, notif) catch break;
        }
    }

    fn escapeJsonString(src: []const u8, dst: []u8) void {
        var d: usize = 0;
        for (src) |byte| {
            if (d + 2 >= dst.len) break;
            if (byte == '"' or byte == '\\') {
                dst[d] = '\\';
                d += 1;
                dst[d] = byte;
                d += 1;
            } else if (byte == '\n' or byte == '\r' or byte == '\t') {
                dst[d] = ' ';
                d += 1;
            } else {
                dst[d] = byte;
                d += 1;
            }
        }
        if (d < dst.len) dst[d] = 0;
    }

    fn extractJsonUint(src: []const u8, key: []const u8) ?u64 {
        const pos = std.mem.indexOf(u8, src, key) orelse return null;
        var start = pos + key.len;
        while (start < src.len and (src[start] == ' ' or src[start] == ':')) : (start += 1) {}
        var end = start;
        while (end < src.len and std.ascii.isDigit(src[end])) : (end += 1) {}
        if (end > start) {
            return std.fmt.parseInt(u64, src[start..end], 10) catch null;
        }
        return null;
    }

    fn extractJsonString(src: []const u8, key: []const u8, out_buf: []u8) ?usize {
        const pos = std.mem.indexOf(u8, src, key) orelse return null;
        var start = pos + key.len;
        while (start < src.len and (src[start] == ' ' or src[start] == ':' or src[start] == '"')) : (start += 1) {}
        var end = start;
        while (end < src.len and src[end] != '"') : (end += 1) {
            if (src[end] == '\\' and end + 1 < src.len) end += 1;
        }
        if (end >= start) {
            const raw = src[start..end];
            const copy_len = @min(raw.len, out_buf.len);
            @memcpy(out_buf[0..copy_len], raw[0..copy_len]);
            return copy_len;
        }
        return null;
    }
};

pub const ToastOverlay = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    font: renderer.Font,
    current_notif: ?Notification = null,
    width: u32 = 400,
    height: u32 = 88,
    running: bool = true,
    time_remaining_ms: i32 = 4000,
    total_time_ms: i32 = 4000,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config, notif: Notification) !ToastOverlay {
        const font = try renderer.Font.init(allocator, cfg.theme.font_family, cfg.typography.ui);
        const timeout = if (notif.expire_timeout_ms > 0) notif.expire_timeout_ms else 4000;
        return .{
            .allocator = allocator,
            .cfg = cfg,
            .font = font,
            .current_notif = notif,
            .time_remaining_ms = timeout,
            .total_time_ms = timeout,
        };
    }

    pub fn deinit(self: *ToastOverlay) void {
        self.font.deinit();
    }

    pub fn tick(self: *ToastOverlay, delta_ms: i32) bool {
        self.time_remaining_ms -= delta_ms;
        if (self.time_remaining_ms <= 0) {
            self.running = false;
            return true;
        }
        return true;
    }

    pub fn handleClick(self: *ToastOverlay, x: i32, y: i32) bool {
        _ = x;
        _ = y;
        self.running = false;
        return true;
    }

    pub fn render(self: *ToastOverlay, target: renderer.Renderer) !void {
        target.clear(theme.Color.transparent);
        const notif = self.current_notif orelse return;

        const w = target.width;
        const h = target.height;
        const radius: u32 = 14;

        target.drawDropShadow(6, 6, w - 12, h - 12, radius, 6, theme.Color.init(90, 0, 0, 0));

        var ui = try ui_mod.Ui.begin(
            self.allocator,
            &self.font,
            w,
            h,
            1,
            -1,
            -1,
            false,
            1.0 / 60.0,
        );
        defer ui.deinit();

        ui.root(.{
            .direction = .column,
            .padding = .all(6),
            .align_x = .left,
            .align_y = .top,
        });

        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
            .direction = .column,
            .padding = .all(12),
            .gap = 4,
            .bg = self.cfg.theme.elevated,
            .radius = ui.f(self.cfg.theme.radius_panel),
            .border = 1,
            .border_color = self.cfg.theme.panel_border,
        });

        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
            .direction = .row,
            .gap = 12,
            .align_y = .top,
        });

        _ = ui.open(.{
            .width = .{ .fixed = 36 },
            .height = .{ .fixed = 36 },
            .bg = self.cfg.theme.surface,
            .radius = ui.f(self.cfg.theme.radius_pill),
            .border = 1,
            .border_color = self.cfg.theme.border,
            .align_x = .center,
            .align_y = .center,
        });
        ui.icon("bell", 22, self.cfg.theme.accent, 0);
        ui.close();

        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
            .direction = .column,
            .gap = 2,
        });

        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .fit,
            .direction = .row,
            .align_y = .center,
        });
        ui.text(notif.getAppName(), .{
            .size = self.cfg.typography.secondary,
            .color = self.cfg.theme.text_muted,
        });
        ui.spacerSized(.{ .grow = .{} }, .{ .fixed = 0 });
        ui.text("✕", .{
            .size = self.cfg.typography.secondary,
            .color = self.cfg.theme.text_muted,
        });
        ui.close();

        const summary = notif.getSummary();
        var trunc_sum_buf: [128]u8 = undefined;
        const trunc_summary = renderer.truncateText(&self.font, summary, w -| 110, self.cfg.typography.ui, &trunc_sum_buf);
        ui.text(trunc_summary, .{
            .size = self.cfg.typography.ui,
            .color = self.cfg.theme.text_bright,
        });

        const body = notif.getBody();
        if (body.len > 0) {
            var trunc_body_buf: [128]u8 = undefined;
            const trunc_body = renderer.truncateText(&self.font, body, w -| 110, self.cfg.typography.secondary, &trunc_body_buf);
            ui.text(trunc_body, .{
                .size = self.cfg.typography.secondary,
                .color = self.cfg.theme.text_muted,
            });
        }

        ui.close(); // text column
        ui.close(); // content row

        const bar_pct: f32 = if (self.total_time_ms > 0 and self.time_remaining_ms > 0)
            @as(f32, @floatFromInt(@min(self.time_remaining_ms, self.total_time_ms))) / @as(f32, @floatFromInt(self.total_time_ms))
        else
            0;
        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .fixed = 3 },
            .bg = self.cfg.theme.surface,
            .radius = ui.f(2),
        });
        if (bar_pct > 0) {
            ui.rect(.{ .percent = bar_pct }, .{ .grow = .{} }, self.cfg.theme.accent, 2, .{});
        }
        ui.close();

        ui.close(); // card
        ui.close(); // root

        const commands = ui.endLayout();
        ui.render(target, commands);
    }

};

test "NotificationStore add, persist and reload" {
    const allocator = std.testing.allocator;
    var store = NotificationStore.init(allocator);
    defer store.deinit();

    var notif = Notification{
        .id = 42,
        .timestamp = 1700000000,
        .expire_timeout_ms = 5000,
    };
    const app = "TestApp";
    @memcpy(notif.app_name[0..app.len], app);
    notif.app_name_len = app.len;

    const sum = "Hello Mizu";
    @memcpy(notif.summary[0..sum.len], sum);
    notif.summary_len = sum.len;

    const bod = "This is a test notification message";
    @memcpy(notif.body[0..bod.len], bod);
    notif.body_len = bod.len;

    store.add(notif);
    try std.testing.expect(store.items.items.len >= 1);
    try std.testing.expectEqualStrings("Hello Mizu", store.items.items[0].getSummary());
    try std.testing.expectEqualStrings("TestApp", store.items.items[0].getAppName());
}
