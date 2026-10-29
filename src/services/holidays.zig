const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const exec = @import("../core/exec.zig");

pub const SOURCE_URL = "https://the-calendar.net/downloads/countries/india-holidays.ics";
const MAX_CACHE_BYTES: usize = 4 * 1024 * 1024;
const REFRESH_INTERVAL_S = 2;
// Re-download the feed at most once a week; the cached file is reused on every
// other launch so the calendar is available instantly and offline.
const FETCH_MAX_AGE_S = 7 * 24 * 60 * 60;

pub const Holiday = struct {
    year: u16 = 0,
    month: u8 = 0,
    day: u8 = 0,
    summary: [128]u8 = undefined,
    summary_len: usize = 0,
    description: [192]u8 = undefined,
    description_len: usize = 0,

    pub fn summarySlice(self: *const Holiday) []const u8 {
        return self.summary[0..self.summary_len];
    }

    pub fn descriptionSlice(self: *const Holiday) []const u8 {
        return self.description[0..self.description_len];
    }
};

pub const HolidayStore = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Holiday),
    loaded: bool = false,
    last_size: i64 = 0,
    last_check: i64 = 0,
    custom_path: [512]u8 = undefined,
    custom_path_len: usize = 0,

    pub fn initEmpty(allocator: std.mem.Allocator) HolidayStore {
        return .{
            .allocator = allocator,
            .items = std.ArrayList(Holiday).empty,
        };
    }

    pub fn init(allocator: std.mem.Allocator, calendar_file: ?[]const u8) HolidayStore {
        var self = initEmpty(allocator);
        if (builtin.is_test) return self;
        // Use explicit path or first *.ics found in config dir.
        if (calendar_file) |raw| {
            if (self.setCustomPath(raw)) {
                self.loadCache();
                return self;
            }
        } else {
            self.tryScanIcs();
            if (self.isCustom()) {
                self.loadCache();
            } else {
                self.startFetch();
            }
        }
        return self;
    }

    /// Scan config dir for any *.ics (no hardcoded filename) and use first found.
    fn tryScanIcs(self: *HolidayStore) void {
        var dir_buf: [512]u8 = undefined;
        const dir = cacheDir(&dir_buf) orelse return;
        var cmd_buf: [1024]u8 = undefined;
        const cmd = std.fmt.bufPrintSentinel(&cmd_buf, "find \"{s}\" -maxdepth 1 -type f -name '*.ics' | sort | head -n 1", .{dir}, 0) catch return;
        const f = c.popen(cmd.ptr, "r") orelse return;
        defer _ = c.pclose(f);
        var line_buf: [512]u8 = undefined;
        if (c.fgets(&line_buf, line_buf.len, f)) |line_ptr| {
            const line = std.mem.trim(u8, std.mem.span(line_ptr), " \t\r\n");
            if (line.len > 0 and std.mem.startsWith(u8, line, "/")) {
                _ = self.setCustomPath(line);
            }
        }
    }

    fn cacheDir(buf: []u8) ?[]const u8 {
        if (c.getenv("XDG_CONFIG_HOME")) |raw| {
            const base = std.mem.span(raw);
            if (base.len > 0) return std.fmt.bufPrint(buf, "{s}/mizu", .{base}) catch null;
        }
        const raw_home = c.getenv("HOME") orelse return null;
        const home = std.mem.span(raw_home);
        if (home.len == 0) return null;
        return std.fmt.bufPrint(buf, "{s}/.config/mizu", .{home}) catch null;
    }

    fn setCustomPath(self: *HolidayStore, raw: []const u8) bool {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return false;
        var buf: [512]u8 = undefined;
        const resolved = resolveCalendarPath(&buf, trimmed) orelse return false;
        const len = @min(resolved.len, self.custom_path.len);
        @memcpy(self.custom_path[0..len], resolved[0..len]);
        self.custom_path_len = len;
        return true;
    }

    fn isCustom(self: *const HolidayStore) bool {
        return self.custom_path_len > 0;
    }

    fn sourcePath(self: *const HolidayStore, buf: []u8) ?[]const u8 {
        if (self.isCustom()) return self.custom_path[0..self.custom_path_len];
        return cachePath(buf);
    }

    pub fn deinit(self: *HolidayStore) void {
        self.items.deinit(self.allocator);
    }

    pub fn hasDate(self: *const HolidayStore, year: u32, month: u32, day: u32) bool {
        return self.find(year, month, day) != null;
    }

    pub fn find(self: *const HolidayStore, year: u32, month: u32, day: u32) ?*const Holiday {
        for (self.items.items) |*item| {
            if (item.year == year and item.month == month and item.day == day) return item;
        }
        return null;
    }

    /// Reload the cached calendar if a background fetch replaced it.
    pub fn refreshIfChanged(self: *HolidayStore) bool {
        const now = c.time(null);
        if (now - self.last_check < REFRESH_INTERVAL_S) return false;
        self.last_check = now;

        const size = self.cacheSize();
        if (size <= 0 or size == self.last_size) return false;
        self.loadCache();
        return true;
    }

    fn cachePath(buf: []u8) ?[]const u8 {
        var dir_buf: [512]u8 = undefined;
        const dir = cacheDir(&dir_buf) orelse return null;
        return std.fmt.bufPrint(buf, "{s}/india-holidays.ics", .{dir}) catch null;
    }

    fn cacheAgeSeconds(self: *HolidayStore) i64 {
        var path_buf: [512]u8 = undefined;
        const path = self.sourcePath(&path_buf) orelse return -1;
        var path_z_buf: [512]u8 = undefined;
        const path_z = std.fmt.bufPrintSentinel(&path_z_buf, "{s}", .{path}, 0) catch return -1;
        var st: c.struct_stat = undefined;
        if (c.stat(path_z.ptr, &st) != 0) return -1;
        const now: i64 = @intCast(c.time(null));
        const mtime: i64 = @intCast(st.st_mtim.tv_sec);
        return now - mtime;
    }

    fn startFetch(self: *HolidayStore) void {
        if (self.isCustom()) return;
        // Reuse the cached download unless it is missing or a week old.
        const age = self.cacheAgeSeconds();
        if (age >= 0 and age < FETCH_MAX_AGE_S and self.cacheSize() > 0) return;

        var dir_buf: [512]u8 = undefined;
        const dir = cacheDir(&dir_buf) orelse return;
        var dir_z_buf: [512]u8 = undefined;
        const dir_z = std.fmt.bufPrintSentinel(&dir_z_buf, "{s}", .{dir}, 0) catch return;
        _ = c.mkdir(dir_z.ptr, 0o755);

        var path_buf: [512]u8 = undefined;
        const path = cachePath(&path_buf) orelse return;
        var tmp_buf: [640]u8 = undefined;
        const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch return;

        var cmd_buf: [1800]u8 = undefined;
        const cmd = std.fmt.bufPrint(
            &cmd_buf,
            "curl -fsSL --max-time 10 '{s}' -o '{s}' && mv '{s}' '{s}'",
            .{ SOURCE_URL, tmp, tmp, path },
        ) catch return;
        exec.spawnShell(cmd);
    }

    fn cacheSize(self: *HolidayStore) i64 {
        var path_buf: [512]u8 = undefined;
        const path = self.sourcePath(&path_buf) orelse return 0;
        var path_z_buf: [512]u8 = undefined;
        const path_z = std.fmt.bufPrintSentinel(&path_z_buf, "{s}", .{path}, 0) catch return 0;
        const f = c.fopen(path_z.ptr, "rb") orelse return 0;
        defer _ = c.fclose(f);
        _ = c.fseek(f, 0, c.SEEK_END);
        return c.ftell(f);
    }

    fn loadCache(self: *HolidayStore) void {
        var path_buf: [512]u8 = undefined;
        const path = self.sourcePath(&path_buf) orelse return;
        var path_z_buf: [512]u8 = undefined;
        const path_z = std.fmt.bufPrintSentinel(&path_z_buf, "{s}", .{path}, 0) catch return;
        const f = c.fopen(path_z.ptr, "rb") orelse return;
        defer _ = c.fclose(f);

        _ = c.fseek(f, 0, c.SEEK_END);
        const size = c.ftell(f);
        if (size <= 0 or size > MAX_CACHE_BYTES) return;
        _ = c.fseek(f, 0, c.SEEK_SET);

        const data = self.allocator.alloc(u8, @intCast(size)) catch return;
        defer self.allocator.free(data);
        const read = c.fread(data.ptr, 1, data.len, f);
        if (read == 0) return;

        self.parseIcs(data[0..read]) catch return;
        self.loaded = true;
        self.last_size = size;
    }

    pub fn parseIcs(self: *HolidayStore, data: []const u8) !void {
        self.items.clearRetainingCapacity();

        // Unfold RFC 5545 continuation lines (leading space or tab) into a
        // newline-separated property stream.
        var unfolded = std.ArrayList(u8).empty;
        defer unfolded.deinit(self.allocator);

        var pos: usize = 0;
        while (pos < data.len) {
            const start = pos;
            while (pos < data.len and data[pos] != '\n') : (pos += 1) {}
            var line = data[start..pos];
            if (pos < data.len) pos += 1;
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

            if (line.len > 0 and (line[0] == ' ' or line[0] == '\t') and unfolded.items.len > 0) {
                try unfolded.appendSlice(self.allocator, line);
            } else {
                try unfolded.append(self.allocator, '\n');
                try unfolded.appendSlice(self.allocator, line);
            }
        }

        var in_event = false;
        var event = Holiday{};
        var has_date = false;

        var lines = std.mem.splitScalar(u8, unfolded.items, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;

            if (std.mem.eql(u8, line, "BEGIN:VEVENT")) {
                in_event = true;
                event = .{};
                has_date = false;
                continue;
            }
            if (std.mem.eql(u8, line, "END:VEVENT")) {
                if (in_event and has_date and event.summary_len > 0) {
                    try self.items.append(self.allocator, event);
                }
                in_event = false;
                continue;
            }
            if (!in_event) continue;

            if (std.mem.startsWith(u8, line, "DTSTART")) {
                if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                    if (parseIcsDate(line[colon + 1 ..])) |date| {
                        event.year = date.year;
                        event.month = date.month;
                        event.day = date.day;
                        has_date = true;
                    }
                }
            } else if (std.mem.startsWith(u8, line, "SUMMARY")) {
                if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                    const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
                    event.summary_len = unescapeInto(&event.summary, value);
                }
            } else if (std.mem.startsWith(u8, line, "DESCRIPTION")) {
                if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                    const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
                    event.description_len = unescapeInto(&event.description, value);
                }
            }
        }

        std.mem.sort(Holiday, self.items.items, {}, lessThanDate);
    }
};

fn resolveCalendarPath(buf: []u8, raw: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, raw, "~/")) {
        const home = std.mem.span(c.getenv("HOME") orelse return null);
        if (home.len == 0) return null;
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ home, raw[2..] }) catch null;
    }
    if (raw[0] == '/') {
        return std.fmt.bufPrint(buf, "{s}", .{raw}) catch null;
    }
    if (c.getenv("XDG_CONFIG_HOME")) |xdg_ptr| {
        const xdg = std.mem.span(xdg_ptr);
        if (xdg.len > 0) {
            return std.fmt.bufPrint(buf, "{s}/mizu/{s}", .{ xdg, raw }) catch null;
        }
    }
    const home_ptr = c.getenv("HOME") orelse return null;
    const home = std.mem.span(home_ptr);
    if (home.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}/.config/mizu/{s}", .{ home, raw }) catch null;
}

const IcsDate = struct {
    year: u16,
    month: u8,
    day: u8,
};

fn parseIcsDate(value: []const u8) ?IcsDate {
    const trimmed = std.mem.trim(u8, value, " \t\r");
    if (trimmed.len < 8) return null;
    const year = std.fmt.parseInt(u16, trimmed[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, trimmed[4..6], 10) catch return null;
    const day = std.fmt.parseInt(u8, trimmed[6..8], 10) catch return null;
    if (year < 1900 or month < 1 or month > 12 or day < 1 or day > 31) return null;
    return .{ .year = year, .month = month, .day = day };
}

fn unescapeInto(dest: []u8, src: []const u8) usize {
    var out: usize = 0;
    var i: usize = 0;
    while (i < src.len and out < dest.len) {
        if (src[i] == '\\' and i + 1 < src.len) {
            i += 1;
            dest[out] = switch (src[i]) {
                'n', 'N' => ' ',
                't', 'T' => ' ',
                else => src[i],
            };
            out += 1;
            i += 1;
        } else if (src[i] != '\r') {
            dest[out] = src[i];
            out += 1;
            i += 1;
        } else {
            i += 1;
        }
    }
    return out;
}

fn lessThanDate(_: void, a: Holiday, b: Holiday) bool {
    if (a.year != b.year) return a.year < b.year;
    if (a.month != b.month) return a.month < b.month;
    return a.day < b.day;
}

test "HolidayStore parses India ICS dates, folding, and escapes" {
    const allocator = std.testing.allocator;
    var store = HolidayStore.initEmpty(allocator);
    defer store.deinit();

    const sample =
        "BEGIN:VCALENDAR\r\n" ++
        "BEGIN:VEVENT\r\n" ++
        "DTSTART;VALUE=DATE:20260126\r\n" ++
        "SUMMARY:Republic Day\r\n" ++
        "DESCRIPTION:Public holiday\\, nationwide\r\n" ++
        "END:VEVENT\r\n" ++
        "BEGIN:VEVENT\r\n" ++
        "DTSTART:20260815T000000Z\r\n" ++
        "SUMMARY:Independence\r\n" ++
        " Day\r\n" ++
        "END:VEVENT\r\n" ++
        "END:VCALENDAR\r\n";

    try store.parseIcs(sample);
    try std.testing.expectEqual(@as(usize, 2), store.items.items.len);
    try std.testing.expect(store.hasDate(2026, 1, 26));
    try std.testing.expect(store.hasDate(2026, 8, 15));
    try std.testing.expect(!store.hasDate(2026, 1, 27));

    const republic = store.find(2026, 1, 26).?;
    try std.testing.expectEqualStrings("Republic Day", republic.summarySlice());
    try std.testing.expectEqualStrings("Public holiday, nationwide", republic.descriptionSlice());

    const independence = store.find(2026, 8, 15).?;
    try std.testing.expectEqualStrings("Independence Day", independence.summarySlice());
}
