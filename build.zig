const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "mizu",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    exe.root_module.linkSystemLibrary("wayland-client", .{});
    exe.root_module.linkSystemLibrary("wayland-cursor", .{});
    exe.root_module.linkSystemLibrary("freetype", .{});
    exe.root_module.linkSystemLibrary("fontconfig", .{});
    exe.root_module.linkSystemLibrary("xkbcommon", .{});
    exe.root_module.linkSystemLibrary("png16", .{});
    exe.root_module.linkSystemLibrary("pam", .{});
    exe.root_module.linkSystemLibrary("jpeg", .{});
    exe.root_module.linkSystemLibrary("dbus-1", .{});

    exe.root_module.addIncludePath(b.path("src"));
    exe.root_module.addIncludePath(b.path("src/c"));
    exe.root_module.addIncludePath(b.path("src/core"));
    exe.root_module.addIncludePath(b.path("src/bar"));
    exe.root_module.addIncludePath(b.path("src/panels"));
    exe.root_module.addIncludePath(b.path("src/graphics"));
    exe.root_module.addIncludePath(b.path("src/services"));
    exe.root_module.addIncludePath(b.path("src/protocols/wayland/generated"));
    exe.root_module.addIncludePath(.{ .cwd_relative = "/usr/include/freetype2" });
    exe.root_module.addIncludePath(.{ .cwd_relative = "/usr/include/dbus-1.0" });
    exe.root_module.addIncludePath(.{ .cwd_relative = "/usr/lib64/dbus-1.0/include" });

    exe.root_module.addCSourceFile(.{
        .file = b.path("src/protocols/wayland/generated/xdg-shell-protocol.c"),
    });
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/protocols/wayland/generated/wlr-layer-shell-unstable-v1-protocol.c"),
    });
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/protocols/wayland/generated/ext-session-lock-v1-protocol.c"),
    });
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/protocols/wayland/generated/viewporter-protocol.c"),
    });
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/protocols/wayland/generated/idle-inhibit-unstable-v1-protocol.c"),
    });
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/c/notify_dbus.c"),
    });
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/c/tray_dbus.c"),
    });
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/c/clay_impl.c"),
        .flags = &.{ "-O2", "-std=c99" },
    });
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/core/nanosvg.c"),
        .flags = &.{"-O2"},
    });
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/core/nanosvg_rasterizer.c"),
        .flags = &.{"-O2"},
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run Mizu bar");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Standalone draw/layout tests with full C include paths
    const draw_test_mod = b.createModule(.{
        .root_source_file = b.path("src/draw_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    draw_test_mod.addIncludePath(b.path("src"));
    draw_test_mod.addIncludePath(b.path("src/c"));
    draw_test_mod.addIncludePath(b.path("src/core"));
    draw_test_mod.addIncludePath(b.path("src/bar"));
    draw_test_mod.addIncludePath(b.path("src/panels"));
    draw_test_mod.addIncludePath(b.path("src/graphics"));
    draw_test_mod.addIncludePath(b.path("src/services"));
    draw_test_mod.addIncludePath(b.path("src/protocols/wayland/generated"));
    draw_test_mod.addIncludePath(.{ .cwd_relative = "/usr/include/freetype2" });
    draw_test_mod.addIncludePath(.{ .cwd_relative = "/usr/include/dbus-1.0" });
    draw_test_mod.addIncludePath(.{ .cwd_relative = "/usr/lib64/dbus-1.0/include" });
    draw_test_mod.linkSystemLibrary("wayland-client", .{});
    draw_test_mod.linkSystemLibrary("freetype", .{});
    draw_test_mod.linkSystemLibrary("fontconfig", .{});
    draw_test_mod.linkSystemLibrary("xkbcommon", .{});
    draw_test_mod.linkSystemLibrary("png16", .{});
    draw_test_mod.linkSystemLibrary("c", .{});

    const draw_tests = b.addTest(.{
        .root_module = draw_test_mod,
    });
    const run_draw_tests = b.addRunArtifact(draw_tests);
    test_step.dependOn(&run_draw_tests.step);
}
