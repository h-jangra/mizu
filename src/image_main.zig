const std = @import("std");
const c = @import("c.zig").c;
const config = @import("core/config.zig");
const annotate = @import("apps/annotate.zig");

fn printUsage() void {
    const usage =
        \\Mizu Image & Annotator (Unified with mizu annotate)
        \\
        \\Usage:
        \\  mizu-image [options] [image_file]
        \\  (or: mizu annotate [options] [image_file])
        \\
        \\Options:
        \\  -h, --help          Show this help message
        \\  -v, --version       Show version information
        \\
        \\Features:
        \\  - Unified image viewer, editor, and drawing annotation tool
        \\  - Tab key toggles between [Draw] and [Edit] modes
        \\  - Crop, Rotate (90°, 180°, 270°), Flip (H, V), Resize (50%, 200%)
        \\  - Color adjustments: Brightness, Contrast, Saturation, Blur, Grayscale
        \\  - Annotation tools: Pen, Arrow, Line, Rect, Circle, Text, Highlight, Blur, Pixelate
        \\  - Image metadata inspector & clipboard copy
        \\
    ;
    std.debug.print("{s}\n", .{usage});
}

fn loadConfig(allocator: std.mem.Allocator) config.Config {
    var cfg_path: ?[]const u8 = null;
    var env_buf: [512]u8 = undefined;

    if (c.getenv("XDG_CONFIG_HOME")) |xdg_ptr| {
        const xdg = std.mem.span(xdg_ptr);
        cfg_path = std.fmt.bufPrint(&env_buf, "{s}/mizu/config.ini", .{xdg}) catch null;
    } else if (c.getenv("HOME")) |home_ptr| {
        const home = std.mem.span(home_ptr);
        cfg_path = std.fmt.bufPrint(&env_buf, "{s}/.config/mizu/config.ini", .{home}) catch null;
    }

    return if (cfg_path) |p|
        config.Config.loadFromFile(allocator, p)
    else
        config.Config.init(allocator);
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const allocator = std.heap.c_allocator;

    var arg_it = init.args.iterate();
    _ = arg_it.next(); // skip binary name

    var file_to_open: ?[]const u8 = null;

    while (arg_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return 0;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            std.debug.print("mizu-image 0.1.0\n", .{});
            return 0;
        } else if (std.mem.eql(u8, arg, "-")) {
            file_to_open = "-";
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            file_to_open = arg;
        }
    }

    var cfg = loadConfig(allocator);
    defer cfg.deinit(allocator);

    const ret = annotate.run(allocator, cfg, file_to_open, false) catch |err| {
        std.debug.print("mizu-image error: {any}\n", .{err});
        return 1;
    };
    return ret;
}
