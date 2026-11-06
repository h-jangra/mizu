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
    obj.addIncludePath(.{ .cwd_relative = "/usr/include/webp" });
}

fn configureMizuModule(
    b: *std.Build,
    mod: *std.Build.Module,
    c_module: *std.Build.Module,
) void {
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
    mod.linkSystemLibrary("webp", .{ .use_pkg_config = .no });

    addMizuIncludePaths(b, mod);

    const c_sources = [_][]const u8{
        "src/protocols/wayland/generated/xdg-shell-protocol.c",
        "src/protocols/wayland/generated/wlr-layer-shell-unstable-v1-protocol.c",
        "src/protocols/wayland/generated/ext-session-lock-v1-protocol.c",
        "src/protocols/wayland/generated/viewporter-protocol.c",
        "src/protocols/wayland/generated/idle-inhibit-unstable-v1-protocol.c",
        "src/protocols/wayland/generated/wlr-screencopy-unstable-v1-protocol.c",
        "src/c/notify_dbus.c",
        "src/c/tray_dbus.c",
        "src/c/mizu_dbus_monitor.c",
        "src/c/clay_impl.c",
        "src/core/nanosvg.c",
        "src/core/nanosvg_rasterizer.c",
        "src/c/webp_export.c",
        "src/c/mizu_share.c",
        "src/c/qrcode.c",
    };

    for (c_sources) |source| {
        mod.addCSourceFile(.{
            .file = b.path(source),
            .flags = if (std.mem.eql(u8, source, "src/c/clay_impl.c"))
                &.{ "-O2", "-std=c99" }
            else if (std.mem.startsWith(u8, source, "src/core/nanosvg"))
                &.{"-O2"}
            else
                &.{},
        });
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const c_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/c/c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    addMizuIncludePaths(b, c_translate);
    const c_module = c_translate.createModule();

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

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run Mizu");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
