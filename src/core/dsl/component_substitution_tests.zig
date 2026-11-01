const std = @import("std");
const components = @import("components.zig");
const ast = @import("ast.zig");

test "component property substitution" {
    var store = components.ComponentStore.init(std.testing.allocator);
    store.add("Button", &[_]ast.Prop{}, ast.Element{ .tag = "box", .props = &[_]ast.Prop{}, .children = &[_]ast.Element{} });
    const def = store.find("Button");
    try std.testing.expect(def != null);
    if (def) |d| try std.testing.expect(std.mem.eql(u8, d.name, "Button"));
    store.deinit();
}
