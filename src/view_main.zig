const std = @import("std");
const c = @import("c.zig").c;
const config = @import("core/config.zig");
const image_viewer = @import("apps/image_viewer.zig");

fn printUsage() void {
    const usage =
        \\Mizu View - Minimal, Fast Wayland Image Viewer
        \\
        \\Usage:
        \\  mizu-view [options] [image_file|-]
        \\  (or: mizu view [options] [image_file|-])
        \\
        \\Options:
        \\  -h, --help          Show this help message
        \\  -v, --version       Show version information
        \\
        \\Keybindings & Interactions:
        \\  Drag (Left Mouse)   Pan / move image
        \\  Scroll Wheel        Smooth zoom centered at mouse cursor
        \\  + / =               Zoom in
        \\  -                   Zoom out
        \\  f / F               Fit image to window
        \\  1 / 0               100% Actual size (1:1 pixel scale)
        \\  Right / l / n / Spc Next image in directory
        \\  Left / h / p / Bspc Previous image in directory
        \\  r                   Rotate 90° clockwise
        \\  R                   Rotate 90° counter-clockwise
        \\  m                   Flip horizontally (mirror)
        \\  v                   Flip vertically
        \\  c / Ctrl+C          Copy image to Wayland clipboard (wl-copy)
        \\  e / a               Open current image in Mizu Annotate
        \\  i                   Toggle minimal HUD info overlay
        \\  q / Esc             Quit
        \\
        \\Pipes & Screenshots:
        \\  grim -g "$(slurp)" - | mizu view
        \\  cat photo.jpg | mizu view
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
            std.debug.print("mizu-view 0.2.0\n", .{});
            return 0;
        } else if (std.mem.eql(u8, arg, "-")) {
            file_to_open = "-";
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            file_to_open = arg;
        }
    }

    var cfg = loadConfig(allocator);
    defer cfg.deinit(allocator);

    const ret = image_viewer.run(allocator, cfg, file_to_open) catch |err| {
        std.debug.print("mizu-view error: {any}\n", .{err});
        return 1;
    };
    return ret;
}
