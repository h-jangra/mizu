const std = @import("std");
const ast = @import("ast.zig");

pub const ComponentStore = struct {
    allocator: std.mem.Allocator,
    // Simple fixed-size store for milestone
    defs: [8]struct { name: []const u8, props: []ast.Prop, body: ast.Element },
    count: usize,

    pub fn init(alloc: std.mem.Allocator) ComponentStore {
        return .{ .allocator = alloc, .count = 0, .defs = undefined };
    }

    pub fn add(self: *ComponentStore, name: []const u8, props: []ast.Prop, body: ast.Element) void {
        if (self.count < 8) {
            self.defs[self.count] = .{ .name = name, .props = props, .body = body };
            self.count += 1;
        }
    }

    pub fn find(self: *ComponentStore, name: []const u8) ?*struct { name: []const u8, props: []ast.Prop, body: ast.Element } {
        for (self.defs[0..self.count]) |*def| {
            if (std.mem.eql(u8, def.name, name)) return def;
        }
        return null;
    }
};
