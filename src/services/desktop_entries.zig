const std = @import("std");
const c = @import("c");

pub const DesktopApp = struct {
    id: []const u8,
    name: []const u8,
    generic_name: ?[]const u8 = null,
    comment: ?[]const u8 = null,
    exec: []const u8,
    icon: ?[]const u8 = null,
    terminal: bool = false,
    keywords: ?[]const u8 = null,
    usage: u32 = 0,

    pub fn deinit(self: *DesktopApp, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        if (self.generic_name) |g| allocator.free(g);
        if (self.comment) |com| allocator.free(com);
        allocator.free(self.exec);
        if (self.icon) |ic| allocator.free(ic);
        if (self.keywords) |kw| allocator.free(kw);
    }
};

pub fn cleanExec(allocator: std.mem.Allocator, raw_exec: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < raw_exec.len) {
        if (raw_exec[i] == '%' and i + 1 < raw_exec.len) {
            const next_char = raw_exec[i + 1];
            switch (next_char) {
                'f', 'F', 'u', 'U', 'd', 'D', 'n', 'N', 'i', 'c', 'k', 'v', 'm' => {
                    // Skip field code
                    i += 2;
                    // If preceding space and following space, collapse one space
                    if (out.items.len > 0 and out.items[out.items.len - 1] == ' ' and (i >= raw_exec.len or raw_exec[i] == ' ')) {
                        _ = out.pop();
                    }
                    continue;
                },
                '%' => {
                    try out.append(allocator, '%');
                    i += 2;
                    continue;
                },
                else => {},
            }
        }
        try out.append(allocator, raw_exec[i]);
        i += 1;
    }

    const trimmed = std.mem.trim(u8, out.items, " \t\r\n");
    return allocator.dupe(u8, trimmed);
}

pub fn parseDesktopContent(
    allocator: std.mem.Allocator,
    id: []const u8,
    content: []const u8,
) !?DesktopApp {
    var in_desktop_entry = false;
    var is_application = false;
    var no_display = false;
    var hidden = false;

    var name: ?[]const u8 = null;
    var generic_name: ?[]const u8 = null;
    var comment: ?[]const u8 = null;
    var raw_exec: ?[]const u8 = null;
    var icon: ?[]const u8 = null;
    var terminal = false;
    var keywords: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[' and line[line.len - 1] == ']') {
            const section = line[1 .. line.len - 1];
            if (std.mem.eql(u8, section, "Desktop Entry")) {
                in_desktop_entry = true;
            } else {
                in_desktop_entry = false;
            }
            continue;
        }

        if (!in_desktop_entry) continue;

        if (std.mem.indexOfScalar(u8, line, '=')) |eq_idx| {
            const key = std.mem.trim(u8, line[0..eq_idx], " \t");
            const val = std.mem.trim(u8, line[eq_idx + 1 ..], " \t");

            if (std.mem.eql(u8, key, "Type")) {
                if (std.mem.eql(u8, val, "Application")) {
                    is_application = true;
                }
            } else if (std.mem.eql(u8, key, "NoDisplay")) {
                if (std.mem.eql(u8, val, "true")) no_display = true;
            } else if (std.mem.eql(u8, key, "Hidden")) {
                if (std.mem.eql(u8, val, "true")) hidden = true;
            } else if (std.mem.eql(u8, key, "Name") and name == null) {
                name = val;
            } else if (std.mem.eql(u8, key, "GenericName") and generic_name == null) {
                generic_name = val;
            } else if (std.mem.eql(u8, key, "Comment") and comment == null) {
                comment = val;
            } else if (std.mem.eql(u8, key, "Exec") and raw_exec == null) {
                raw_exec = val;
            } else if (std.mem.eql(u8, key, "Icon") and icon == null) {
                icon = val;
            } else if (std.mem.eql(u8, key, "Terminal")) {
                if (std.mem.eql(u8, val, "true")) terminal = true;
            } else if (std.mem.eql(u8, key, "Keywords") and keywords == null) {
                keywords = val;
            }
        }
    }

    if (!is_application or no_display or hidden) return null;
    const final_name = name orelse return null;
    const final_raw_exec = raw_exec orelse return null;

    const cleaned_exec = try cleanExec(allocator, final_raw_exec);
    errdefer allocator.free(cleaned_exec);

    if (cleaned_exec.len == 0) return null;

    const dup_id = try allocator.dupe(u8, id);
    errdefer allocator.free(dup_id);

    const dup_name = try allocator.dupe(u8, final_name);
    errdefer allocator.free(dup_name);

    var dup_generic: ?[]const u8 = null;
    if (generic_name) |g| {
        dup_generic = try allocator.dupe(u8, g);
    }
    errdefer if (dup_generic) |g| allocator.free(g);

    var dup_comment: ?[]const u8 = null;
    if (comment) |com| {
        dup_comment = try allocator.dupe(u8, com);
    }
    errdefer if (dup_comment) |com| allocator.free(com);

    var dup_icon: ?[]const u8 = null;
    if (icon) |ic| {
        dup_icon = try allocator.dupe(u8, ic);
    }
    errdefer if (dup_icon) |ic| allocator.free(ic);

    var dup_keywords: ?[]const u8 = null;
    if (keywords) |kw| {
        dup_keywords = try allocator.dupe(u8, kw);
    }
    errdefer if (dup_keywords) |kw| allocator.free(kw);

    return DesktopApp{
        .id = dup_id,
        .name = dup_name,
        .generic_name = dup_generic,
        .comment = dup_comment,
        .exec = cleaned_exec,
        .icon = dup_icon,
        .terminal = terminal,
        .keywords = dup_keywords,
        .usage = 0,
    };
}

pub fn discoverApplications(allocator: std.mem.Allocator) !std.ArrayList(DesktopApp) {
    var apps = std.ArrayList(DesktopApp).empty;
    errdefer {
        for (apps.items) |*app| app.deinit(allocator);
        apps.deinit(allocator);
    }

    var seen_ids = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen_ids.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        seen_ids.deinit();
    }

    var dirs = std.ArrayList([]const u8).empty;
    defer {
        for (dirs.items) |d| allocator.free(d);
        dirs.deinit(allocator);
    }

    // User applications dir ($XDG_DATA_HOME or ~/.local/share)
    if (c.getenv("XDG_DATA_HOME")) |ptr| {
        const d = try std.fmt.allocPrint(allocator, "{s}/applications", .{std.mem.span(ptr)});
        try dirs.append(allocator, d);
    } else if (c.getenv("HOME")) |ptr| {
        const d = try std.fmt.allocPrint(allocator, "{s}/.local/share/applications", .{std.mem.span(ptr)});
        try dirs.append(allocator, d);
    }

    // System applications dirs ($XDG_DATA_DIRS or /usr/share)
    if (c.getenv("XDG_DATA_DIRS")) |ptr| {
        var it = std.mem.splitScalar(u8, std.mem.span(ptr), ':');
        while (it.next()) |dir_part| {
            if (dir_part.len == 0) continue;
            const d = try std.fmt.allocPrint(allocator, "{s}/applications", .{dir_part});
            try dirs.append(allocator, d);
        }
    } else {
        try dirs.append(allocator, try allocator.dupe(u8, "/usr/local/share/applications"));
        try dirs.append(allocator, try allocator.dupe(u8, "/usr/share/applications"));
    }

    for (dirs.items) |dir_path| {
        scanDirectory(allocator, dir_path, &seen_ids, &apps) catch |err| {
            std.debug.print("Could not scan directory {s}: {any}\n", .{ dir_path, err });
        };
    }

    loadAppUsageInto(allocator, apps.items);

    return apps;
}

fn scanDirectory(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    seen_ids: *std.StringHashMap(void),
    apps: *std.ArrayList(DesktopApp),
) !void {
    const c_dir_path = try allocator.dupeSentinel(u8, dir_path, 0);
    defer allocator.free(c_dir_path);

    // Use libc opendir/readdir to stay robust across POSIX environments
    const dir = @import("c").opendir(c_dir_path.ptr) orelse return;
    defer _ = @import("c").closedir(dir);

    while (true) {
        const entry = @import("c").readdir(dir) orelse break;
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));

        if (std.mem.endsWith(u8, name, ".desktop")) {
            if (seen_ids.contains(name)) continue;

            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, name });
            defer allocator.free(full_path);

            if (readDesktopFile(allocator, full_path)) |content| {
                defer allocator.free(content);
                if (parseDesktopContent(allocator, name, content)) |maybe_app| {
                    if (maybe_app) |app| {
                        const dup_key = try allocator.dupe(u8, name);
                        try seen_ids.put(dup_key, {});
                        try apps.append(allocator, app);
                    }
                } else |_| {}
            }
        }
    }
}

fn readDesktopFile(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const c_path = allocator.dupeSentinel(u8, path, 0) catch return null;
    defer allocator.free(c_path);

    const f = @import("c").fopen(c_path.ptr, "rb") orelse return null;
    defer _ = @import("c").fclose(f);

    _ = @import("c").fseek(f, 0, @import("c").SEEK_END);
    const fsize = @import("c").ftell(f);
    _ = @import("c").fseek(f, 0, @import("c").SEEK_SET);

    if (fsize <= 0 or fsize > 1024 * 1024) return null;
    const usize_len: usize = @intCast(fsize);

    const content = allocator.alloc(u8, usize_len) catch return null;
    const bytes_read = @import("c").fread(content.ptr, 1, usize_len, f);
    return content[0..bytes_read];
}

pub const SearchResult = struct {
    app: *const DesktopApp,
    score: u32,
};

pub fn scoreApp(app: *const DesktopApp, query: []const u8) u32 {
    if (query.len == 0) return 1;

    var max_score: u32 = 0;

    // Check name
    if (matchScore(app.name, query)) |s| {
        max_score = @max(max_score, s * 4);
    }

    // Check generic_name
    if (app.generic_name) |gn| {
        if (matchScore(gn, query)) |s| {
            max_score = @max(max_score, s * 2);
        }
    }

    // Check exec
    if (matchScore(app.exec, query)) |s| {
        max_score = @max(max_score, s * 2);
    }

    // Check keywords
    if (app.keywords) |kw| {
        if (matchScore(kw, query)) |s| {
            max_score = @max(max_score, s);
        }
    }

    // Check comment
    if (app.comment) |com| {
        if (matchScore(com, query)) |s| {
            max_score = @max(max_score, s);
        }
    }

    return max_score;
}

fn matchScore(haystack: []const u8, needle: []const u8) ?u32 {
    if (needle.len == 0) return 1;
    if (haystack.len < needle.len) return null;

    var h_buf: [256]u8 = undefined;
    var n_buf: [256]u8 = undefined;

    const h_slice = if (haystack.len <= h_buf.len)
        std.ascii.lowerString(&h_buf, haystack)
    else
        return null;

    const n_slice = if (needle.len <= n_buf.len)
        std.ascii.lowerString(&n_buf, needle)
    else
        return null;

    // Exact match
    if (std.mem.eql(u8, h_slice, n_slice)) {
        return 100;
    }

    // Starts with
    if (std.mem.startsWith(u8, h_slice, n_slice)) {
        return 80;
    }

    // Word starts with
    var words = std.mem.splitScalar(u8, h_slice, ' ');
    while (words.next()) |w| {
        if (std.mem.startsWith(u8, w, n_slice)) {
            return 60;
        }
    }

    // Contains substring
    if (std.mem.indexOf(u8, h_slice, n_slice) != null) {
        return 40;
    }

    return null;
}

pub fn searchApplicationsInto(
    allocator: std.mem.Allocator,
    apps: []const DesktopApp,
    query: []const u8,
    results: *std.ArrayList(SearchResult),
) !void {
    results.clearRetainingCapacity();

    for (apps) |*app| {
        const score = scoreApp(app, query);
        if (score > 0) {
            try results.append(allocator, .{
                .app = app,
                .score = score,
            });
        }
    }

    // Sort descending by score, tiebreak by usage descending, then name ascending
    std.mem.sort(SearchResult, results.items, {}, struct {
        fn lessThan(_: void, a: SearchResult, b: SearchResult) bool {
            if (a.score != b.score) {
                return a.score > b.score;
            }
            if (a.app.usage != b.app.usage) {
                return a.app.usage > b.app.usage;
            }
            return std.mem.order(u8, a.app.name, b.app.name) == .lt;
        }
    }.lessThan);
}

pub fn getAppUsageFilePath(buf: []u8) ?[]const u8 {
    const home = c.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.cache/mizu/app_usage", .{std.mem.span(home)}) catch null;
}

pub fn loadAppUsageInto(allocator: std.mem.Allocator, apps: []DesktopApp) void {
    var path_buf: [512]u8 = undefined;
    const path = getAppUsageFilePath(&path_buf) orelse return;

    var path_z_buf: [512]u8 = undefined;
    const path_z = std.fmt.bufPrintSentinel(&path_z_buf, "{s}", .{path}, 0) catch return;

    const file = c.fopen(path_z.ptr, "r") orelse return;
    defer _ = c.fclose(file);

    var usage_map = std.StringHashMap(u32).init(allocator);
    defer {
        var it = usage_map.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        usage_map.deinit();
    }

    var line_buf: [1024]u8 = undefined;
    while (c.fgets(&line_buf, @intCast(line_buf.len), file)) |line_ptr| {
        const raw_line = std.mem.span(line_ptr);
        const trimmed = std.mem.trim(u8, raw_line, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        const sep_idx = std.mem.lastIndexOfScalar(u8, trimmed, ' ') orelse
            std.mem.lastIndexOfScalar(u8, trimmed, '\t') orelse continue;

        const id_part = std.mem.trim(u8, trimmed[0..sep_idx], " \t");
        const count_part = std.mem.trim(u8, trimmed[sep_idx + 1 ..], " \t");
        if (id_part.len == 0 or count_part.len == 0) continue;

        const count = std.fmt.parseInt(u32, count_part, 10) catch continue;
        const key_copy = allocator.dupe(u8, id_part) catch continue;
        usage_map.put(key_copy, count) catch {
            allocator.free(key_copy);
        };
    }

    for (apps) |*app| {
        if (usage_map.get(app.id)) |cnt| {
            app.usage = cnt;
        } else if (usage_map.get(app.name)) |cnt| {
            app.usage = cnt;
        }
    }
}

pub fn saveAppUsageToFile(apps: []const DesktopApp) void {
    const home = c.getenv("HOME") orelse return;
    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintSentinel(&dir_buf, "{s}/.cache/mizu", .{std.mem.span(home)}, 0) catch return;
    _ = c.mkdir(dir_path.ptr, 0o755);

    var path_buf: [512]u8 = undefined;
    const path_z = std.fmt.bufPrintSentinel(&path_buf, "{s}/.cache/mizu/app_usage", .{std.mem.span(home)}, 0) catch return;

    const file = c.fopen(path_z.ptr, "w") orelse return;
    defer _ = c.fclose(file);

    var line_out: [512]u8 = undefined;
    for (apps) |app| {
        if (app.usage > 0) {
            if (std.fmt.bufPrint(&line_out, "{s} {d}\n", .{ app.id, app.usage })) |line| {
                _ = c.fwrite(line.ptr, 1, line.len, file);
            } else |_| {}
        }
    }
}

pub fn recordAppUsage(apps: []DesktopApp, app_id: []const u8) void {
    var found = false;
    for (apps) |*app| {
        if (std.mem.eql(u8, app.id, app_id) or std.mem.eql(u8, app.name, app_id)) {
            app.usage +|= 1;
            found = true;
            break;
        }
    }
    if (found) {
        saveAppUsageToFile(apps);
    }
}

pub fn searchApplications(
    allocator: std.mem.Allocator,
    apps: []const DesktopApp,
    query: []const u8,
) !std.ArrayList(SearchResult) {
    var results = std.ArrayList(SearchResult).empty;
    try searchApplicationsInto(allocator, apps, query, &results);
    return results;
}

// Unit Tests
test "cleanExec removes field codes" {
    const allocator = std.testing.allocator;

    const cleaned1 = try cleanExec(allocator, "firefox %u");
    defer allocator.free(cleaned1);
    try std.testing.expectEqualStrings("firefox", cleaned1);

    const cleaned2 = try cleanExec(allocator, "gimp-2.10 %U -v");
    defer allocator.free(cleaned2);
    try std.testing.expectEqualStrings("gimp-2.10 -v", cleaned2);

    const cleaned3 = try cleanExec(allocator, "foot");
    defer allocator.free(cleaned3);
    try std.testing.expectEqualStrings("foot", cleaned3);
}

test "parseDesktopContent valid and invalid entries" {
    const allocator = std.testing.allocator;

    const valid =
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Foot
        \\GenericName=Terminal
        \\Comment=A wayland native terminal emulator
        \\Exec=foot %f
        \\Terminal=false
        \\
    ;

    const maybe_app = try parseDesktopContent(allocator, "foot.desktop", valid);
    try std.testing.expect(maybe_app != null);
    var app = maybe_app.?;
    defer app.deinit(allocator);

    try std.testing.expectEqualStrings("Foot", app.name);
    try std.testing.expectEqualStrings("Terminal", app.generic_name.?);
    try std.testing.expectEqualStrings("foot", app.exec);
    try std.testing.expectEqual(false, app.terminal);

    // Test NoDisplay=true ignored
    const nodisplay =
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Secret
        \\Exec=secret
        \\NoDisplay=true
        \\
    ;
    const ignored1 = try parseDesktopContent(allocator, "secret.desktop", nodisplay);
    try std.testing.expect(ignored1 == null);

    // Test non-Application ignored
    const link_entry =
        \\[Desktop Entry]
        \\Type=Link
        \\Name=Google
        \\URL=https://google.com
        \\
    ;
    const ignored2 = try parseDesktopContent(allocator, "google.desktop", link_entry);
    try std.testing.expect(ignored2 == null);
}

test "search ranking and case insensitivity" {
    const app1 = DesktopApp{
        .id = "foot.desktop",
        .name = "Foot",
        .generic_name = "Terminal",
        .exec = "foot",
    };
    const app2 = DesktopApp{
        .id = "firefox.desktop",
        .name = "Firefox",
        .generic_name = "Web Browser",
        .exec = "firefox",
    };
    const app3 = DesktopApp{
        .id = "alacritty.desktop",
        .name = "Alacritty",
        .generic_name = "Terminal Emulator",
        .exec = "alacritty",
    };

    const apps = [_]DesktopApp{ app1, app2, app3 };

    // Search "term" -> Foot and Alacritty should match, Foot higher than Alacritty
    const allocator = std.testing.allocator;
    var res1 = try searchApplications(allocator, &apps, "term");
    defer res1.deinit(allocator);

    try std.testing.expect(res1.items.len >= 2);
    try std.testing.expect(res1.items[0].score > 0);

    // Search "fire" -> Firefox must be top
    var res2 = try searchApplications(allocator, &apps, "fire");
    defer res2.deinit(allocator);

    try std.testing.expect(res2.items.len == 1);
    try std.testing.expectEqualStrings("Firefox", res2.items[0].app.name);
}

test "apps sorted by usage when query is empty and ties broken by name" {
    const allocator = std.testing.allocator;

    const app_a = DesktopApp{
        .id = "alacritty.desktop",
        .name = "Alacritty",
        .exec = "alacritty",
        .usage = 5,
    };
    const app_b = DesktopApp{
        .id = "firefox.desktop",
        .name = "Firefox",
        .exec = "firefox",
        .usage = 42,
    };
    const app_c = DesktopApp{
        .id = "code.desktop",
        .name = "Code",
        .exec = "code",
        .usage = 0,
    };
    const app_d = DesktopApp{
        .id = "gimp.desktop",
        .name = "GIMP",
        .exec = "gimp",
        .usage = 0,
    };

    var apps = [_]DesktopApp{ app_a, app_b, app_c, app_d };

    var results = try searchApplications(allocator, &apps, "");
    defer results.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), results.items.len);
    // Firefox has highest usage (42) -> #1
    try std.testing.expectEqualStrings("Firefox", results.items[0].app.name);
    // Alacritty has next highest usage (5) -> #2
    try std.testing.expectEqualStrings("Alacritty", results.items[1].app.name);
    // Code and GIMP have 0 usage, so tiebreaker is alphabetical: Code (#3) then GIMP (#4)
    try std.testing.expectEqualStrings("Code", results.items[2].app.name);
    try std.testing.expectEqualStrings("GIMP", results.items[3].app.name);

    // Test recordAppUsage increments usage
    recordAppUsage(&apps, "code.desktop");
    try std.testing.expectEqual(@as(u32, 1), apps[2].usage);

    var updated_results = try searchApplications(allocator, &apps, "");
    defer updated_results.deinit(allocator);
    // Now Code has usage 1, so it comes before GIMP (usage 0)
    try std.testing.expectEqualStrings("Firefox", updated_results.items[0].app.name);
    try std.testing.expectEqualStrings("Alacritty", updated_results.items[1].app.name);
    try std.testing.expectEqualStrings("Code", updated_results.items[2].app.name);
    try std.testing.expectEqualStrings("GIMP", updated_results.items[3].app.name);
}
