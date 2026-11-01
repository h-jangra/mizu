const std = @import("std");
const state = @import("state.zig");

// Memory ownership tests for DSL state (M5)
test "state init, update with dupe, deinit" {
    const allocator = std.testing.allocator;
    var s = state.State.init(allocator);
    defer s.deinit(allocator);
    try std.testing.expectEqualStrings("World", s.label_text);
    s.updateLabel(allocator, "Updated");
    try std.testing.expectEqualStrings("Updated", s.label_text);
    try std.testing.expect(s.rebuild_requested);
}
