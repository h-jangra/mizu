const std = @import("std");
const c = @import("../c.zig").c;

pub const FileEntry = struct {
    name: []const u8,
    path: []const u8,
    is_dir: bool,
    icon: []const u8,

    pub fn deinit(self: *FileEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
    }
};

pub fn getFileIcon(name: []const u8, is_dir: bool) []const u8 {
    if (is_dir) return "  ";

    const ext = std.fs.path.extension(name);
    if (ext.len > 0) {
        if (std.ascii.eqlIgnoreCase(ext, ".png") or
            std.ascii.eqlIgnoreCase(ext, ".jpg") or
            std.ascii.eqlIgnoreCase(ext, ".jpeg") or
            std.ascii.eqlIgnoreCase(ext, ".svg") or
            std.ascii.eqlIgnoreCase(ext, ".webp") or
            std.ascii.eqlIgnoreCase(ext, ".gif") or
            std.ascii.eqlIgnoreCase(ext, ".bmp"))
        {
            return " 󰈟 ";
        }
        if (std.ascii.eqlIgnoreCase(ext, ".mp4") or
            std.ascii.eqlIgnoreCase(ext, ".mkv") or
            std.ascii.eqlIgnoreCase(ext, ".webm") or
            std.ascii.eqlIgnoreCase(ext, ".avi") or
            std.ascii.eqlIgnoreCase(ext, ".mov"))
        {
            return " 󰈫 ";
        }
        if (std.ascii.eqlIgnoreCase(ext, ".mp3") or
            std.ascii.eqlIgnoreCase(ext, ".flac") or
            std.ascii.eqlIgnoreCase(ext, ".wav") or
            std.ascii.eqlIgnoreCase(ext, ".ogg") or
            std.ascii.eqlIgnoreCase(ext, ".m4a") or
            std.ascii.eqlIgnoreCase(ext, ".opus"))
        {
            return " 󰈣 ";
        }
        if (std.ascii.eqlIgnoreCase(ext, ".pdf") or
            std.ascii.eqlIgnoreCase(ext, ".epub") or
            std.ascii.eqlIgnoreCase(ext, ".doc") or
            std.ascii.eqlIgnoreCase(ext, ".docx"))
        {
            return " 󰈔 ";
        }
        if (std.ascii.eqlIgnoreCase(ext, ".zig") or
            std.ascii.eqlIgnoreCase(ext, ".c") or
            std.ascii.eqlIgnoreCase(ext, ".h") or
            std.ascii.eqlIgnoreCase(ext, ".cpp") or
            std.ascii.eqlIgnoreCase(ext, ".rs") or
            std.ascii.eqlIgnoreCase(ext, ".py") or
            std.ascii.eqlIgnoreCase(ext, ".sh") or
            std.ascii.eqlIgnoreCase(ext, ".txt") or
            std.ascii.eqlIgnoreCase(ext, ".md") or
            std.ascii.eqlIgnoreCase(ext, ".json") or
            std.ascii.eqlIgnoreCase(ext, ".toml") or
            std.ascii.eqlIgnoreCase(ext, ".ini"))
        {
            return " 󰅩 ";
        }
        if (std.ascii.eqlIgnoreCase(ext, ".zip") or
            std.ascii.eqlIgnoreCase(ext, ".tar") or
            std.ascii.eqlIgnoreCase(ext, ".gz") or
            std.ascii.eqlIgnoreCase(ext, ".xz") or
            std.ascii.eqlIgnoreCase(ext, ".7z"))
        {
            return " 󰛫 ";
        }
    }
    return " 󰈔 ";
}

pub fn matchPattern(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return true;
    if (std.mem.indexOfScalar(u8, pattern, '*') != null or std.mem.indexOfScalar(u8, pattern, '?') != null) {
        return matchGlob(pattern, text);
    }
    // Substring case-insensitive
    var pattern_lower: [128]u8 = undefined;
    var text_lower: [256]u8 = undefined;
    if (pattern.len > pattern_lower.len or text.len > text_lower.len) return false;
    const p = std.ascii.lowerString(&pattern_lower, pattern);
    const t = std.ascii.lowerString(&text_lower, text);
    return std.mem.indexOf(u8, t, p) != null;
}

pub fn matchGlob(pattern: []const u8, text: []const u8) bool {
    var p_idx: usize = 0;
    var t_idx: usize = 0;
    var star_idx: ?usize = null;
    var match_idx: usize = 0;

    while (t_idx < text.len) {
        if (p_idx < pattern.len and (pattern[p_idx] == '?' or std.ascii.toLower(pattern[p_idx]) == std.ascii.toLower(text[t_idx]))) {
            p_idx += 1;
            t_idx += 1;
        } else if (p_idx < pattern.len and pattern[p_idx] == '*') {
            star_idx = p_idx;
            match_idx = t_idx;
            p_idx += 1;
        } else if (star_idx) |s| {
            p_idx = s + 1;
            match_idx += 1;
            t_idx = match_idx;
        } else {
            return false;
        }
    }

    while (p_idx < pattern.len and pattern[p_idx] == '*') {
        p_idx += 1;
    }

    return p_idx == pattern.len;
}

pub fn searchFiles(allocator: std.mem.Allocator, query: []const u8) !std.ArrayList(FileEntry) {
    var list = std.ArrayList(FileEntry).empty;
    errdefer {
        for (list.items) |*item| item.deinit(allocator);
        list.deinit(allocator);
    }

    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    const home_env = c.getenv("HOME");
    const home = if (home_env) |h| std.mem.span(h) else "/home";

    if (trimmed.len == 0) {
        // Show default common folders
        const defaults = [_]struct { name: []const u8, rel: []const u8 }{
            .{ .name = "Home", .rel = "" },
            .{ .name = "Documents", .rel = "Documents" },
            .{ .name = "Downloads", .rel = "Downloads" },
            .{ .name = "Pictures", .rel = "Pictures" },
            .{ .name = "Videos", .rel = "Videos" },
            .{ .name = "Desktop", .rel = "Desktop" },
            .{ .name = ".config", .rel = ".config" },
        };

        for (defaults) |def| {
            const path = if (def.rel.len == 0)
                try allocator.dupe(u8, home)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, def.rel });
            errdefer allocator.free(path);

            // Check if exists
            var st: c.struct_stat = undefined;
            const path_z = try allocator.dupeSentinel(u8, path, 0);
            defer allocator.free(path_z);
            if (c.stat(path_z.ptr, &st) == 0) {
                const is_dir = (st.st_mode & c.S_IFMT) == c.S_IFDIR;
                const name_dup = try allocator.dupe(u8, def.name);
                try list.append(allocator, .{
                    .name = name_dup,
                    .path = path,
                    .is_dir = is_dir,
                    .icon = getFileIcon(def.name, is_dir),
                });
            } else {
                allocator.free(path);
            }
        }
        return list;
    }

    // If query starts with / or ~: browse directory
    if (trimmed[0] == '/' or trimmed[0] == '~') {
        var resolved_buf: [512]u8 = undefined;
        const resolved: []const u8 = if (trimmed[0] == '~') blk: {
            if (trimmed.len == 1) {
                break :blk home;
            } else if (trimmed[1] == '/') {
                break :blk std.fmt.bufPrint(&resolved_buf, "{s}{s}", .{ home, trimmed[1..] }) catch home;
            } else {
                break :blk trimmed;
            }
        } else trimmed;

        // Check if resolved is a directory or path with trailing search
        var st: c.struct_stat = undefined;
        const res_z = try allocator.dupeSentinel(u8, resolved, 0);
        defer allocator.free(res_z);

        if (c.stat(res_z.ptr, &st) == 0 and (st.st_mode & c.S_IFMT) == c.S_IFDIR) {
            // Browse this directory
            browseDir(allocator, &list, resolved, "");
            return list;
        }

        // Parent directory with filter
        if (std.fs.path.dirname(resolved)) |parent| {
            const filter = std.fs.path.basename(resolved);
            browseDir(allocator, &list, parent, filter);
            return list;
        }
    }

    // Otherwise: search in Home directory with depth limit
    searchRecursive(allocator, &list, home, trimmed, 0, 3);

    return list;
}

fn browseDir(allocator: std.mem.Allocator, list: *std.ArrayList(FileEntry), dir_path: []const u8, filter: []const u8) void {
    const dir_z = allocator.dupeSentinel(u8, dir_path, 0) catch return;
    defer allocator.free(dir_z);

    const dir = c.opendir(dir_z.ptr);
    if (dir == null) return;
    defer _ = c.closedir(dir);

    while (c.readdir(dir)) |entry| {
        const d_name = std.mem.span(@as([*c]const u8, @ptrCast(&entry.*.d_name)));
        if (std.mem.eql(u8, d_name, ".") or std.mem.eql(u8, d_name, "..")) continue;

        if (filter.len > 0 and !matchPattern(filter, d_name)) continue;

        const is_dir = entry.*.d_type == c.DT_DIR;
        const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, d_name }) catch continue;
        const name_dup = allocator.dupe(u8, d_name) catch {
            allocator.free(full_path);
            continue;
        };

        list.append(allocator, .{
            .name = name_dup,
            .path = full_path,
            .is_dir = is_dir,
            .icon = getFileIcon(d_name, is_dir),
        }) catch {
            allocator.free(name_dup);
            allocator.free(full_path);
            return;
        };

        if (list.items.len >= 50) break;
    }
}

fn searchRecursive(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(FileEntry),
    dir_path: []const u8,
    pattern: []const u8,
    depth: usize,
    max_depth: usize,
) void {
    if (depth > max_depth or list.items.len >= 50) return;

    const dir_z = allocator.dupeSentinel(u8, dir_path, 0) catch return;
    defer allocator.free(dir_z);

    const dir = c.opendir(dir_z.ptr);
    if (dir == null) return;
    defer _ = c.closedir(dir);

    while (c.readdir(dir)) |entry| {
        if (list.items.len >= 50) break;
        const d_name = std.mem.span(@as([*c]const u8, @ptrCast(&entry.*.d_name)));
        if (std.mem.eql(u8, d_name, ".") or std.mem.eql(u8, d_name, "..")) continue;

        // Skip heavy/hidden folders unless pattern starts with dot
        if (d_name[0] == '.' and pattern.len > 0 and pattern[0] != '.') continue;
        if (std.mem.eql(u8, d_name, "node_modules") or
            std.mem.eql(u8, d_name, ".git") or
            std.mem.eql(u8, d_name, ".cache") or
            std.mem.eql(u8, d_name, ".local") or
            std.mem.eql(u8, d_name, "target") or
            std.mem.eql(u8, d_name, "zig-cache") or
            std.mem.eql(u8, d_name, "zig-out"))
        {
            continue;
        }

        const is_dir = entry.*.d_type == c.DT_DIR;

        if (matchPattern(pattern, d_name)) {
            const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, d_name }) catch continue;
            const name_dup = allocator.dupe(u8, d_name) catch {
                allocator.free(full_path);
                continue;
            };

            list.append(allocator, .{
                .name = name_dup,
                .path = full_path,
                .is_dir = is_dir,
                .icon = getFileIcon(d_name, is_dir),
            }) catch {
                allocator.free(name_dup);
                allocator.free(full_path);
                return;
            };
        }

        if (is_dir and depth < max_depth) {
            const sub_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, d_name }) catch continue;
            defer allocator.free(sub_path);
            searchRecursive(allocator, list, sub_path, pattern, depth + 1, max_depth);
        }
    }
}

test "matchGlob pattern" {
    try std.testing.expect(matchGlob("recording-2026*", "recording-2026-10-18.mp4"));
    try std.testing.expect(matchGlob("*.zig", "main.zig"));
    try std.testing.expect(!matchGlob("*.zig", "main.c"));
    try std.testing.expect(matchPattern("test", "MyTestFile.txt"));
}
