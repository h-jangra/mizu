const std = @import("std");
const state = @import("state.zig");

test "explicit state update triggers rebuild" {
    var s = state.State.init(std.testing.allocator);
    defer s.deinit(std.testing.allocator);
    s.updateLabel(std.testing.allocator, "Updated");
    try std.testing.expect(std.mem.eql(u8, s.label_text, "Updated"));
    try std.testing.expect(s.rebuild_requested);
}
