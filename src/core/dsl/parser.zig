const std = @import("std");
const ast = @import("ast.zig");

pub const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    pos: usize,
    line: u32,
    col: u32,

    pub fn init(alloc: std.mem.Allocator, src: []const u8) Parser {
        return .{
            .allocator = alloc,
            .source = src,
            .pos = 0,
            .line = 1,
            .col = 1,
        };
    }

    pub fn deinit(self: *Parser) void {
        // AST nodes reference source substrings; source owned by caller
        _ = self;
    }

    pub fn parseElement(self: *Parser) ast.Element {
        // Skip import lines at top
        while (self.pos < self.source.len and self.source[self.pos] == 'i') {
            if (self.pos + 6 <= self.source.len and std.mem.eql(u8, self.source[self.pos..self.pos+6], "import")) {
                while (self.pos < self.source.len and self.source[self.pos] != '\n') self.pos += 1;
                if (self.pos < self.source.len) self.pos += 1;
            } else break;
        }
        const tag = self.readIdent() orelse "box";
        return .{ .tag = tag, .props = &[_]ast.Prop{}, .children = &[_]ast.Element{} };
    }

    fn readIdent(self: *Parser) ?[]const u8 {
        while (self.pos < self.source.len and self.source[self.pos] == ' ') self.pos += 1;
        if (self.pos >= self.source.len) return null;
        const start = self.pos;
        while (self.pos < self.source.len and self.source[self.pos] != ' ' and self.source[self.pos] != '\n' and self.source[self.pos] != '{') self.pos += 1;
        return self.source[start..self.pos];
    }
};
