const std = @import("std");

fn addMizuIncludePaths(b: *std.Build, obj: anytype) void {
    obj.addIncludePath(b.path("src"));
    obj.addIncludePath(b.path("src/c"));
    obj.addIncludePath(b.path("src/core"));
    obj.addIncludePath(b.path("src/bar"));
    obj.addIncludePath(b.path("src/panels"));
    obj.addIncludePath(b.path("src/graphics"));
    obj.addIncludePath(b.path("src/apps"));
    obj.addIncludePath(b.path("src/services"));
    obj.addIncludePath(b.path("src/protocols/wayland/generated"));
    obj.addIncludePath(.{ .cwd_relative = "/usr/include/freetype2" });
    obj.addIncludePath(.{ .cwd_relative = "/usr/include/libpng16" });
    obj.addIncludePath(.{ .cwd_relative = "/usr/include/security" });
    obj.addIncludePath(.{ .cwd_relative = "/usr/include/dbus-1.0" });
    obj.addIncludePath(.{ .cwd_relative = "/usr/lib64/dbus-1.0/include" });
}

fn configureMizuModule(b: *std.Build, mod: *std.Build.Module, c_module: *std.Build.Module) void {
    mod.addImport("c", c_module);

    mod.linkSystemLibrary("wayland-client", .{ .use_pkg_config = .no });
    mod.linkSystemLibrary("wayland-cursor", .{ .use_pkg_config = .no });
    mod.linkSystemLibrary("freetype", .{ .use_pkg_config = .no });
    mod.linkSystemLibrary("fontconfig", .{ .use_pkg_config = .no });
    mod.linkSystemLibrary("xkbcommon", .{ .use_pkg_config = .no });
    mod.linkSystemLibrary("png16", .{ .use_pkg_config = .no });
    mod.linkSystemLibrary("pam", .{ .use_pkg_config = .no });
    mod.linkSystemLibrary("jpeg", .{ .use_pkg_config = .no });
    mod.linkSystemLibrary("dbus-1", .{ .use_pkg_config = .no });

    addMizuIncludePaths(b, mod);

    mod.addCSourceFile(.{
        .file = b.path("src/protocols/wayland/generated/xdg-shell-protocol.c"),
    });
    mod.addCSourceFile(.{
        .file = b.path("src/protocols/wayland/generated/wlr-layer-shell-unstable-v1-protocol.c"),
    });
    mod.addCSourceFile(.{
        .file = b.path("src/protocols/wayland/generated/ext-session-lock-v1-protocol.c"),
    });
    mod.addCSourceFile(.{
        .file = b.path("src/protocols/wayland/generated/viewporter-protocol.c"),
    });
    mod.addCSourceFile(.{
        .file = b.path("src/protocols/wayland/generated/idle-inhibit-unstable-v1-protocol.c"),
    });
    mod.addCSourceFile(.{
        .file = b.path("src/protocols/wayland/generated/wlr-screencopy-unstable-v1-protocol.c"),
    });
    mod.addCSourceFile(.{
        .file = b.path("src/c/notify_dbus.c"),
    });
    mod.addCSourceFile(.{
        .file = b.path("src/c/tray_dbus.c"),
    });
    mod.addCSourceFile(.{
        .file = b.path("src/c/mizu_dbus_monitor.c"),
    });
    mod.addCSourceFile(.{
        .file = b.path("src/c/clay_impl.c"),
        .flags = &.{ "-O2", "-std=c99" },
    });
    mod.addCSourceFile(.{
        .file = b.path("src/core/nanosvg.c"),
        .flags = &.{"-O2"},
    });
    mod.addCSourceFile(.{
        .file = b.path("src/core/nanosvg_rasterizer.c"),
        .flags = &.{"-O2"},
    });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Zig 0.17 removed @cImport; generate the C bindings with translate-c instead.
    const c_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/c/c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addMizuIncludePaths(b, c_translate);
    const c_module = c_translate.createModule();

    // Main Mizu desktop shell executable
    const exe = b.addExecutable(.{
        .name = "mizu",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    configureMizuModule(b, exe.root_module, c_module);
    b.installArtifact(exe);

    // Standalone Mizu Ink executable
    const exe_ink = b.addExecutable(.{
        .name = "mizu-ink",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    configureMizuModule(b, exe_ink.root_module, c_module);
    b.installArtifact(exe_ink);

    // Standalone Mizu Annotate executable (alias to ink)
    const exe_annotate = b.addExecutable(.{
        .name = "mizu-annotate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    configureMizuModule(b, exe_annotate.root_module, c_module);
    b.installArtifact(exe_annotate);

    // Standalone Mizu Image executable (alias to ink)
    const exe_image = b.addExecutable(.{
        .name = "mizu-image",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    configureMizuModule(b, exe_image.root_module, c_module);
    b.installArtifact(exe_image);

    // Standalone Mizu View executable
    const exe_view = b.addExecutable(.{
        .name = "mizu-view",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    configureMizuModule(b, exe_view.root_module, c_module);
    b.installArtifact(exe_view);

    // Install built-in themes into share/mizu/themes
    b.installDirectory(.{
        .source_dir = b.path("themes"),
        .install_dir = .{ .custom = "share/mizu" },
        .install_subdir = "themes",
    });

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run Mizu bar");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
