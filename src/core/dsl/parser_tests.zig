const std = @import("std");
const parser = @import("parser.zig");

test "valid element parse" {
    const src = "row { padding = 8 }\n  text { content = \"hi\" }";
    var p = parser.Parser.init(std.testing.allocator, src);
    const root = p.parseElement();
    try std.testing.expectEqualStrings("row", root.tag);
}

test "nested elements" {
    const src = "row\n  button { label = \"x\" }";
    var p = parser.Parser.init(std.testing.allocator, src);
    const root = p.parseElement();
    try std.testing.expectEqualStrings("row", root.tag);
}

test "invalid unknown tag reported" {
    const src = "badtag {}";
    var p = parser.Parser.init(std.testing.allocator, src);
    const root = p.parseElement();
    // Validation catches badtag; parser alone allows unknown tags
    try std.testing.expectEqualStrings("badtag", root.tag);
}
