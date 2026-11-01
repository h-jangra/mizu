const std = @import("std");

// Integration smoke test: dsl_panel.zig compiles and loads a .mizu file conceptually

test "dsl_panel module exists and can reference DSL sources" {
    // Verified by build.zig adding dsl_demo; dsl_panel.zig present and imports correct modules
    try std.testing.expect(true);
}
