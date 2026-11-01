const std = @import("std");

pub const Registry = struct {
    allocator: std.mem.Allocator,
    entries: [16]struct { name: []const u8, triggered: bool } = undefined,
    count: usize = 0,

    pub fn init(alloc: std.mem.Allocator) Registry {
        return .{ .allocator = alloc };
    }

    pub fn register(self: *Registry, name: []const u8) void {
        if (self.count < 16) {
            self.entries[self.count] = .{ .name = name, .triggered = false };
            self.count += 1;
        }
    }

    pub fn trigger(self: *Registry, name: []const u8) bool {
        for (self.entries[0..self.count]) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                if (entry.triggered) return false; // prevent duplicate callbacks
                entry.triggered = true;
                return true;
            }
        }
        return false;
    }

    pub fn findTriggered(self: *Registry, name: []const u8) bool {
        for (self.entries[0..self.count]) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.triggered;
        }
        return false;
    }

    pub fn clearTriggered(self: *Registry) void {
        for (self.entries[0..self.count]) |*entry| {
            entry.triggered = false;
        }
    }

    pub fn deinit(self: *Registry) void {
        _ = self;
    }
};
