const std = @import("std");
const theme = @import("theme.zig");

// SVG parsing utility for native icon coordinates
pub fn parseNextCoord(d: []const u8, idx: *usize) ?f64 {
    var i = idx.*;
    while (i < d.len and (d[i] == ' ' or d[i] == ',' or d[i] == '\t' or d[i] == '\n' or d[i] == '\r')) {
        i += 1;
    }
    if (i >= d.len) return null;

    var start = i;
    if (d[i] == '-' or d[i] == '+') {
        i += 1;
    }
    var has_digits = false;
    while (i < d.len and (d[i] >= '0' and d[i] <= '9')) {
        has_digits = true;
        i += 1;
    }
    if (i < d.len and d[i] == '.') {
        i += 1;
        while (i < d.len and (d[i] >= '0' and d[i] <= '9')) {
            has_digits = true;
            i += 1;
        }
    }
    if (!has_digits) return null;

    if (i < d.len and (d[i] == 'e' or d[i] == 'E')) {
        i += 1;
        if (i < d.len and (d[i] == '-' or d[i] == '+')) {
            i += 1;
        }
        while (i < d.len and (d[i] >= '0' and d[i] <= '9')) {
            i += 1;
        }
    }

    const float_str = d[start..i];
    idx.* = i;
    return std.fmt.parseFloat(f64, float_str) catch null;
}
