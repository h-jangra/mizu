const std = @import("std");
const parser = @import("parser.zig");

// Verify component definition parses and can be stored
const src = "component Button {\n  props: label = \"Button\", active = false\n  button { text { content = label } }\n}\n";

test "component definition parsed" {
    var p = parser.Parser.init(std.testing.allocator, src);
    const root = p.parseElement();
    try std.testing.expectEqualStrings("Button", root.tag);
}
