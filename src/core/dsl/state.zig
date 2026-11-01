const std = @import("std");

pub const State = struct {
    label_buf: ?[]u8 = null,
    label_text: []const u8 = "World",
    active: bool = false,
    rebuild_requested: bool = false,

    pub fn init(allocator: std.mem.Allocator) State {
        const buf = allocator.dupe(u8, "World") catch return .{ .label_text = "World" };
        return .{ .label_buf = buf, .label_text = buf, .rebuild_requested = false };
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.label_buf) |b| {
            allocator.free(b);
        }
        self.label_buf = null;
        self.label_text = "";
    }

    pub fn requestRebuild(self: *State) void {
        self.rebuild_requested = true;
    }

    pub fn updateLabel(self: *State, allocator: std.mem.Allocator, text: []const u8) void {
        if (self.label_buf) |old| {
            allocator.free(old);
        }
        const new_buf = allocator.dupe(u8, text) catch {
            self.label_text = text;
            return;
        };
        self.label_buf = new_buf;
        self.label_text = new_buf;
        self.rebuild_requested = true;
    }
};
