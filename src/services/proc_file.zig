const std = @import("std");
const c = @import("c");

/// Read a small procfs/sysfs file into `buf`, returning the byte count and
/// appending a NUL terminator. Returns null when the file cannot be read.
pub fn read(path: [*:0]const u8, buf: []u8) ?usize {
    const f = c.fopen(path, "rb") orelse return null;
    defer _ = c.fclose(f);
    const bytes_read = c.fread(buf.ptr, 1, buf.len - 1, f);
    if (bytes_read == 0) return null;
    buf[bytes_read] = 0;
    return bytes_read;
}

/// Parse the leading decimal value from a `/proc/meminfo`-style line.
pub fn parseKbValue(str: []const u8) u64 {
    const trimmed = std.mem.trim(u8, str, " \t\r\n");
    var num_len: usize = 0;
    while (num_len < trimmed.len and std.ascii.isDigit(trimmed[num_len])) {
        num_len += 1;
    }
    if (num_len == 0) return 0;
    return std.fmt.parseInt(u64, trimmed[0..num_len], 10) catch 0;
}
