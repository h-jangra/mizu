const std = @import("std");
const c = @import("../../c.zig").c;
const config = @import("../../core/config.zig");
const ink = @import("ink.zig");

fn printUsage() void {
    const usage =
        \\Mizu Ink - Unified Wayland Image Annotation & Editing Tool
        \\
        \\Usage:
        \\  mizu-ink [options] [image_file]
        \\  (or: mizu ink [options] [image_file])
        \\
        \\Options:
        \\  -s, --screenshot    Capture a screen region immediately and annotate it
        \\  -h, --help          Show this help message
        \\  -v, --version       Show version information
        \\
        \\Tabs:
        \\  Tab                 Switch between [Draw] and [Edit] toolbar tabs
        \\
        \\Draw Tools (in Draw tab):
        \\  V                   Select tool
        \\  Ctrl+Click & Drag   Pan / move image
        \\  P                   Pen / Freehand drawing
        \\  A                   Arrow tool
        \\  L                   Line tool
        \\  R                   Rectangle tool
        \\  C                   Circle / Ellipse tool
        \\  T                   Text tool (click canvas, type, Enter to commit)
        \\  N                   Step badge counter tool
        \\  H                   Highlight tool
        \\  B                   Blur region tool (censor passwords/tokens)
        \\  X                   Pixelate region tool (censor faces/sensitive data)
        \\
        \\Edit Tools (in Edit tab):
        \\  C                   Crop mode (drag selection, Enter to apply, Esc to cancel)
        \\  R or ]              Rotate 90° clockwise
        \\  [                   Rotate 90° counter-clockwise
        \\  A                   Toggle Adjustments sidebar (Brightness, Contrast, Saturation, Blur, Grayscale)
        \\  I                   Toggle Image Metadata & inspection modal
        \\  H                   Flip horizontally
        \\  V                   Flip vertically
        \\
        \\Global Actions & Shortcuts:
        \\  Ctrl + S            Save image (in-place or to ~/Pictures/Screenshots)
        \\  Ctrl + C            Copy image to Wayland clipboard (wl-copy)
        \\  Ctrl + V            Paste image from clipboard as layer
        \\  Ctrl + E            Export image
        \\  Ctrl + Z            Undo
        \\  Ctrl + Y            Redo
        \\  F                   Fit image to window
        \\  0                   Reset zoom to 100%
        \\  + / -               Zoom in / Zoom out (or mouse wheel scroll)
        \\  Esc                 Cancel active mode (crop/adjust/text) or quit
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

    var screenshot_mode = false;
    var file_to_open: ?[]const u8 = null;

    while (arg_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return 0;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            std.debug.print("mizu-ink 0.1.0\n", .{});
            return 0;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--screenshot")) {
            screenshot_mode = true;
        } else if (std.mem.eql(u8, arg, "-")) {
            file_to_open = "-";
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            file_to_open = arg;
        }
    }

    var cfg = loadConfig(allocator);
    defer cfg.deinit(allocator);

    const ret = ink.run(allocator, cfg, file_to_open, screenshot_mode) catch |err| {
        std.debug.print("mizu-ink error: {any}\n", .{err});
        return 1;
    };
    return ret;
}
