const std = @import("std");
const registry = @import("registry.zig");

test "event dispatch calls registered handler" {
    var reg = registry.Registry.init(std.testing.allocator);
    reg.register("demo_click");
    try std.testing.expect(reg.trigger("demo_click"));
    try std.testing.expect(reg.findTriggered("demo_click"));
    reg.deinit();
}
