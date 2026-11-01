const std = @import("std");

pub const Token = union(enum) {
    ident: []const u8,
    str: []const u8,
    num: f32,
    eq: void,
    brace_open: void,
    brace_close: void,
    colon: void,
    newline: void,
    indent: u32,
    eof: void,
};

pub const Source = struct {
    text: []const u8,
    pos: usize,
    line: u32 = 1,
    col: u32 = 1,
};

pub fn init(text: []const u8) Source {
    return .{ .text = text, .pos = 0, .line = 1, .col = 1 };
}

pub fn error(s: *Source, msg: []const u8) void {
    std.debug.print("dsl.synt: {s}:{d}:{d}: {s}\n", .{ s.line, s.col, msg });
}
