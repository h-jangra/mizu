const std = @import("std");
const c = @import("c");
const proc_file = @import("proc_file.zig");
const readProcFile = proc_file.read;
const parseKbValue = proc_file.parseKbValue;

pub const ProcessInfo = struct {
    pid: u32 = 0,
    ppid: u32 = 0,
    name: [128]u8 = @splat(0),
    name_len: usize = 0,
    exe: [128]u8 = @splat(0),
    exe_len: usize = 0,
    cmdline: [512]u8 = @splat(0),
    cmdline_len: usize = 0,
    rss_kb: u64 = 0,
};

pub const MemInfo = struct {
    total_kb: u64 = 0,
    available_kb: u64 = 0,
    used_kb: u64 = 0,
    used_percent: f32 = 0.0,
};

/// Read /proc/meminfo and compute used memory as MemTotal - MemAvailable.
pub fn collectMemInfo() MemInfo {
    var info = MemInfo{};
    var buf: [1024]u8 = undefined;
    const len = readProcFile("/proc/meminfo", &buf) orelse return info;
    const content = buf[0..len];

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal:")) {
            info.total_kb = parseKbValue(line[9..]);
        } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            info.available_kb = parseKbValue(line[13..]);
        }
        if (info.total_kb > 0 and info.available_kb > 0) break;
    }

    if (info.total_kb > 0 and info.total_kb >= info.available_kb) {
        info.used_kb = info.total_kb - info.available_kb;
        info.used_percent = @as(f32, @floatFromInt(info.used_kb)) / @as(f32, @floatFromInt(info.total_kb)) * 100.0;
    }
    return info;
}

fn sanitizeName(dst: []u8, src: []const u8) usize {
    if (src.len == 0) return 0;
    // Fast path: valid UTF-8 with printable characters.
    if (std.unicode.utf8ValidateSlice(src)) {
        var printable = true;
        var view = std.unicode.Utf8View.initUnchecked(src);
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            if (cp < 0x20 or cp == 0x7f) {
                printable = false;
                break;
            }
        }
        if (printable) {
            const n = @min(src.len, dst.len);
            @memcpy(dst[0..n], src[0..n]);
            return n;
        }
    }

    // Fallback: copy printable ASCII bytes, replacing anything else.
    var out: usize = 0;
    for (src) |b| {
        if (out >= dst.len) break;
        const ch: u8 = if (b >= 0x20 and b < 0x7f) b else '?';
        dst[out] = ch;
        out += 1;
    }
    return out;
}

/// Collect process information from /proc, sorted by resident memory (RSS)
/// descending. Unreadable entries and processes that exit mid-scan are skipped.
pub fn collectProcesses(allocator: std.mem.Allocator, out: *std.ArrayList(ProcessInfo)) !void {
    out.clearRetainingCapacity();

    const page_size_raw = c.sysconf(c._SC_PAGESIZE);
    const page_kb: u64 = if (page_size_raw > 0) @intCast(@divTrunc(page_size_raw, 1024)) else 4;

    const dir = c.opendir("/proc") orelse return error.NoProcessDir;
    defer _ = c.closedir(dir);

    while (c.readdir(dir)) |entry| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        if (name.len == 0) continue;

        var is_pid = true;
        for (name) |ch| {
            if (!std.ascii.isDigit(ch)) {
                is_pid = false;
                break;
            }
        }
        if (!is_pid) continue;

        const pid = std.fmt.parseInt(u32, name, 10) catch continue;

        var stat_path_buf: [128]u8 = undefined;
        const stat_path = std.fmt.bufPrintSentinel(&stat_path_buf, "/proc/{d}/stat", .{pid}, 0) catch continue;

        var stat_buf: [2048]u8 = undefined;
        const stat_len = readProcFile(stat_path.ptr, &stat_buf) orelse continue;
        const stat_content = stat_buf[0..stat_len];

        // The comm field is wrapped in parentheses and may itself contain
        // spaces or parentheses, so find the outermost pair.
        const first_paren = std.mem.indexOfScalar(u8, stat_content, '(') orelse continue;
        const last_paren = std.mem.lastIndexOfScalar(u8, stat_content, ')') orelse continue;
        if (first_paren >= last_paren) continue;
        const comm = stat_content[first_paren + 1 .. last_paren];
        if (comm.len == 0) continue;

        var ppid: u32 = 0;
        if (last_paren + 1 < stat_content.len) {
            var stat_it = std.mem.tokenizeAny(u8, stat_content[last_paren + 1 ..], " \t\r\n");
            _ = stat_it.next(); // state (e.g. 'R', 'S')
            if (stat_it.next()) |ppid_str| {
                ppid = std.fmt.parseInt(u32, ppid_str, 10) catch 0;
            }
        }

        var statm_path_buf: [128]u8 = undefined;
        const statm_path = std.fmt.bufPrintSentinel(&statm_path_buf, "/proc/{d}/statm", .{pid}, 0) catch continue;

        var statm_buf: [128]u8 = undefined;
        const statm_len = readProcFile(statm_path.ptr, &statm_buf) orelse continue;
        const statm_content = statm_buf[0..statm_len];

        var it = std.mem.tokenizeAny(u8, statm_content, " \t\r\n");
        _ = it.next() orelse continue; // total program size
        const resident_str = it.next() orelse continue;
        const resident_pages = std.fmt.parseInt(u64, resident_str, 10) catch continue;
        if (resident_pages == 0) continue;

        var info = ProcessInfo{
            .pid = pid,
            .ppid = ppid,
            .rss_kb = resident_pages * page_kb,
        };
        info.name_len = sanitizeName(&info.name, comm);

        // Read executable symlink /proc/{pid}/exe
        var exe_path_buf: [128]u8 = undefined;
        const exe_path = std.fmt.bufPrintSentinel(&exe_path_buf, "/proc/{d}/exe", .{pid}, 0) catch "";
        if (exe_path.len > 0) {
            var raw_exe_buf: [256]u8 = undefined;
            const link_len = c.readlink(exe_path.ptr, &raw_exe_buf, raw_exe_buf.len - 1);
            if (link_len > 0) {
                const full_exe = raw_exe_buf[0..@intCast(link_len)];
                const bname = std.fs.path.basename(full_exe);
                const n = @min(bname.len, info.exe.len);
                @memcpy(info.exe[0..n], bname[0..n]);
                info.exe_len = n;
            }
        }
        if (info.exe_len == 0) {
            const n = @min(info.name_len, info.exe.len);
            @memcpy(info.exe[0..n], info.name[0..n]);
            info.exe_len = n;
        }

        // Read cmdline for full subprocess command
        var cmd_path_buf: [128]u8 = undefined;
        const cmd_path = std.fmt.bufPrintSentinel(&cmd_path_buf, "/proc/{d}/cmdline", .{pid}, 0) catch "";
        if (cmd_path.len > 0) {
            var raw_cmd_buf: [512]u8 = undefined;
            const cmd_read = readProcFile(cmd_path.ptr, &raw_cmd_buf) orelse 0;
            if (cmd_read > 0) {
                var out_idx: usize = 0;
                for (raw_cmd_buf[0..cmd_read]) |b| {
                    if (out_idx >= info.cmdline.len) break;
                    info.cmdline[out_idx] = if (b == 0) ' ' else (if (b >= 0x20 and b < 0x7f) b else ' ');
                    out_idx += 1;
                }
                const trimmed = std.mem.trim(u8, info.cmdline[0..out_idx], " ");
                info.cmdline_len = trimmed.len;
            }
        }
        if (info.cmdline_len == 0) {
            const clen = @min(info.name_len, info.cmdline.len);
            @memcpy(info.cmdline[0..clen], info.name[0..clen]);
            info.cmdline_len = clen;
        }

        out.append(allocator, info) catch break;
    }

    std.mem.sort(ProcessInfo, out.items, {}, struct {
        fn lessThan(_: void, a: ProcessInfo, b: ProcessInfo) bool {
            return a.rss_kb > b.rss_kb;
        }
    }.lessThan);
}
