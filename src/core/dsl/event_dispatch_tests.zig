const std = @import("std");
const registry = @import("registry.zig");
const state = @import("state.zig");

// Simulated event routing (structural; real Wayland interaction unverified)

test "register and trigger single event" {
    const allocator = std.testing.allocator;
    var reg = registry.Registry.init(allocator);
    reg.register("click");
    try std.testing.expect(reg.trigger("click") == true);
    try std.testing.expect(reg.trigger("click") == false); // duplicate prevented
    reg.clearTriggered();
    try std.testing.expect(reg.trigger("click") == true);
}

test "event triggers state rebuild" {
    const allocator = std.testing.allocator;
    var s = state.State.init(allocator);
    defer s.deinit(allocator);
    var reg = registry.Registry.init(allocator);
    reg.register("demo_click");
    if (reg.trigger("demo_click")) {
        s.requestRebuild();
    }
    reg.clearTriggered();
    try std.testing.expect(s.rebuild_requested);
}
