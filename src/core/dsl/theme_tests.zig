const std = @import("std");
const theme_resolver = @import("theme_resolver.zig");

test "valid theme variable resolves" {
    var r = theme_resolver.ThemeResolver.init(std.testing.allocator, "nord");
    const val = r.resolve("theme.accent");
    try std.testing.expect(val != null);
    try std.testing.expect(val.?.a == 255);
}

test "missing theme variable returns null with diagnostic" {
    var r = theme_resolver.ThemeResolver.init(std.testing.allocator, "nord");
    const bad = r.resolve("theme.invalid");
    try std.testing.expect(bad == null);
}

test "different theme produces different accent" {
    var r1 = theme_resolver.ThemeResolver.init(std.testing.allocator, "nord");
    var r2 = theme_resolver.ThemeResolver.init(std.testing.allocator, "dracula");
    const c1 = r1.resolve("theme.accent");
    const c2 = r2.resolve("theme.accent");
    try std.testing.expect(c1 != null and c2 != null);
    // Different themes should produce different colors (verified structurally)
    try std.testing.expect(c1.?.r != c2.?.r or c1.?.g != c2.?.g);
}
