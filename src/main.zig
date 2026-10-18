const std = @import("std");
const c = @import("c.zig").c;
const config = @import("config.zig");
const theme = @import("theme.zig");
const mango_ipc = @import("mango_ipc.zig");
const bar_module = @import("bar.zig");
const launcher_module = @import("launcher.zig");
const quicksettings_module = @import("quicksettings.zig");
const calendar_module = @import("calendar.zig");
const clipboard_module = @import("clipboard.zig");
const osd_module = @import("osd.zig");
const wayland = @import("wayland.zig");
pub const desktop_entry = @import("desktop_entry.zig");

test {
    _ = @import("desktop_entry.zig");
    _ = @import("quicksettings.zig");
    _ = @import("osd.zig");
    _ = @import("bar.zig");
    _ = @import("calendar.zig");
    _ = @import("clipboard.zig");
    _ = @import("text_input.zig");
}

pub const VERSION = "0.1.0";

var quit_requested: bool = false;

fn sigHandler(sig: c_int) callconv(.c) void {
    _ = sig;
    quit_requested = true;
}

const Command = enum {
    bar,
    launcher,
    quicksettings,
    calendar,
    clipboard,
    notify,
    theme,
    help,
    version,
};

fn parseCommand(arg: []const u8) ?Command {
    if (std.mem.eql(u8, arg, "bar")) {
        return .bar;
    } else if (std.mem.eql(u8, arg, "launcher") or std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--launcher")) {
        return .launcher;
    } else if (std.mem.eql(u8, arg, "quicksettings") or std.mem.eql(u8, arg, "qs") or std.mem.eql(u8, arg, "panel") or std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quicksettings")) {
        return .quicksettings;
    } else if (std.mem.eql(u8, arg, "calendar") or std.mem.eql(u8, arg, "cal") or std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--calendar")) {
        return .calendar;
    } else if (std.mem.eql(u8, arg, "clipboard") or std.mem.eql(u8, arg, "clip") or std.mem.eql(u8, arg, "--clipboard")) {
        return .clipboard;
    } else if (std.mem.eql(u8, arg, "notify")) {
        return .notify;
    } else if (std.mem.eql(u8, arg, "theme") or std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--theme")) {
        return .theme;
    } else if (std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
        return .help;
    } else if (std.mem.eql(u8, arg, "version") or std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
        return .version;
    }
    return null;
}

fn printUsage() void {
    const help_text =
        \\Usage: mizu <command> [options]
        \\
        \\A lightweight, from-scratch Wayland desktop shell for Void Linux and MangoWC.
        \\
        \\Commands:
        \\  bar             Start the top desktop bar
        \\  launcher        Open the application launcher overlay (aliases: -l, --launcher)
        \\  quicksettings   Open the quick settings control panel (aliases: qs, panel, -q)
        \\  calendar        Open interactive month/year calendar (aliases: cal, -c)
        \\  clipboard       Open clipboard history search & manager (aliases: clip)
        \\  notify          Show a desktop notification popup (mizu notify <title> [body])
        \\  theme           Switch or inspect themes (mizu theme [next|prev|set <name>|list])
        \\  help            Display this help message
        \\  version         Display version information
        \\
        \\Options:
        \\  -h, --help      Display this help message
        \\  -v, --version   Display version information
        \\
        \\Run 'mizu bar' to launch the desktop status bar, 'mizu launcher' for the app drawer, or 'mizu clip' for clipboard history.
        \\
    ;
    std.debug.print("{s}", .{help_text});
}

fn printVersion() void {
    std.debug.print("mizu {s}\n", .{VERSION});
}

pub fn main(init: std.process.Init.Minimal) u8 {
    // Setup signal handlers
    _ = c.signal(c.SIGINT, sigHandler);
    _ = c.signal(c.SIGTERM, sigHandler);
    _ = c.signal(c.SIGCHLD, c.SIG_IGN);

    var arg_it = init.args.iterate();
    _ = arg_it.next(); // skip binary name

    const maybe_cmd_str = arg_it.next();
    if (maybe_cmd_str == null) {
        printUsage();
        return 0;
    }

    const cmd_str = maybe_cmd_str.?;
    const cmd = parseCommand(cmd_str) orelse {
        std.debug.print("mizu: unrecognized command '{s}'\n\n", .{cmd_str});
        printUsage();
        return 1;
    };

    switch (cmd) {
        .help => {
            printUsage();
            return 0;
        },
        .version => {
            printVersion();
            return 0;
        },
        .bar => {
            const allocator = std.heap.c_allocator;
            var cfg = loadConfig(allocator);
            defer cfg.deinit(allocator);

            runBar(allocator, cfg) catch |err| {
                std.debug.print("mizu bar error: {any}\n", .{err});
                return 1;
            };
            return 0;
        },
        .launcher => {
            const allocator = std.heap.c_allocator;
            var cfg = loadConfig(allocator);
            defer cfg.deinit(allocator);

            runLauncher(allocator, cfg) catch |err| {
                std.debug.print("mizu launcher error: {any}\n", .{err});
                return 1;
            };
            return 0;
        },
        .quicksettings => {
            const allocator = std.heap.c_allocator;
            var cfg = loadConfig(allocator);
            defer cfg.deinit(allocator);

            runQuickSettings(allocator, cfg) catch |err| {
                std.debug.print("mizu quicksettings error: {any}\n", .{err});
                return 1;
            };
            return 0;
        },
        .calendar => {
            const allocator = std.heap.c_allocator;
            var cfg = loadConfig(allocator);
            defer cfg.deinit(allocator);

            runCalendar(allocator, cfg) catch |err| {
                std.debug.print("mizu calendar error: {any}\n", .{err});
                return 1;
            };
            return 0;
        },
        .clipboard => {
            const allocator = std.heap.c_allocator;
            var cfg = loadConfig(allocator);
            defer cfg.deinit(allocator);

            runClipboard(allocator, cfg) catch |err| {
                std.debug.print("mizu clipboard error: {any}\n", .{err});
                return 1;
            };
            return 0;
        },
        .notify => {
            const allocator = std.heap.c_allocator;
            var cfg = loadConfig(allocator);
            defer cfg.deinit(allocator);

            const title = arg_it.next() orelse "Mizu Notification";
            const body = arg_it.next() orelse "";

            var cmd_buf: [256]u8 = undefined;
            const initial_cmd = std.fmt.bufPrint(&cmd_buf, "notify:{s}:::{s}", .{ title, body }) catch "notify:Mizu:::";

            runOsd(allocator, cfg, .notification, initial_cmd) catch |err| {
                std.debug.print("mizu notify error: {any}\n", .{err});
                return 1;
            };
            return 0;
        },
        .theme => {
            const sub1 = arg_it.next();
            if (sub1 == null or std.mem.eql(u8, sub1.?, "get") or std.mem.eql(u8, sub1.?, "current")) {
                const current = theme.loadSavedTheme() orelse .nord;
                std.debug.print("Current theme: {s} {s}\n", .{ current.icon(), current.name() });
                return 0;
            } else if (std.mem.eql(u8, sub1.?, "list")) {
                std.debug.print("Available themes:\n", .{});
                var idx: u8 = 0;
                while (idx < theme.ThemeKind.count) : (idx += 1) {
                    const k: theme.ThemeKind = @enumFromInt(idx);
                    std.debug.print("  {s}  {s}\n", .{ k.icon(), k.name() });
                }
                return 0;
            } else if (std.mem.eql(u8, sub1.?, "next")) {
                const cur = theme.loadSavedTheme() orelse .nord;
                const nxt = cur.next();
                theme.saveCurrentTheme(nxt);
                std.debug.print("Switched theme to {s} {s}\n", .{ nxt.icon(), nxt.name() });
                return 0;
            } else if (std.mem.eql(u8, sub1.?, "prev")) {
                const cur = theme.loadSavedTheme() orelse .nord;
                const prv = cur.prev();
                theme.saveCurrentTheme(prv);
                std.debug.print("Switched theme to {s} {s}\n", .{ prv.icon(), prv.name() });
                return 0;
            } else if (std.mem.eql(u8, sub1.?, "set")) {
                const target_theme = arg_it.next() orelse {
                    std.debug.print("Usage: mizu theme set <theme_name>\n", .{});
                    return 1;
                };
                if (theme.ThemeKind.fromString(target_theme)) |k| {
                    theme.saveCurrentTheme(k);
                    std.debug.print("Set theme to {s} {s}\n", .{ k.icon(), k.name() });
                    return 0;
                } else {
                    std.debug.print("Unknown theme '{s}'. Run 'mizu theme list' to see available themes.\n", .{target_theme});
                    return 1;
                }
            } else {
                if (theme.ThemeKind.fromString(sub1.?)) |k| {
                    theme.saveCurrentTheme(k);
                    std.debug.print("Set theme to {s} {s}\n", .{ k.icon(), k.name() });
                    return 0;
                }
                std.debug.print("Usage: mizu theme [get | set <theme> | next | prev | list]\n", .{});
                return 1;
            }
        },
    }
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

fn runBar(allocator: std.mem.Allocator, cfg: config.Config) !void {
    var ipc = mango_ipc.MangoIpc.init();
    defer ipc.deinit();

    var app = wayland.WaylandApp.init(cfg);
    try app.connect();
    defer app.deinit();

    var bar = try bar_module.Bar.init(allocator, cfg);
    defer bar.deinit();

    app.bar = &bar;
    app.ipc = &ipc;

    // Create bar surface
    try app.createSurface();

    // 1-second timerfd for clock updates
    const timer_fd = c.timerfd_create(c.CLOCK_MONOTONIC, c.TFD_CLOEXEC | c.TFD_NONBLOCK);
    if (timer_fd < 0) {
        std.debug.print("Failed to create timerfd\n", .{});
        return error.TimerFdFailed;
    }
    defer _ = c.close(timer_fd);

    var its: c.struct_itimerspec = undefined;
    its.it_interval.tv_sec = 1;
    its.it_interval.tv_nsec = 0;
    its.it_value.tv_sec = 1;
    its.it_value.tv_nsec = 0;
    if (c.timerfd_settime(timer_fd, 0, &its, null) < 0) {
        std.debug.print("Failed to arm timerfd\n", .{});
        return error.TimerFdArmFailed;
    }

    // Signal fd for instant runtime theme updates via SIGUSR1
    var sig_mask: c.sigset_t = undefined;
    _ = c.sigemptyset(&sig_mask);
    _ = c.sigaddset(&sig_mask, c.SIGUSR1);
    _ = c.sigprocmask(c.SIG_BLOCK, &sig_mask, null);
    const sig_fd = c.signalfd(-1, &sig_mask, c.SFD_CLOEXEC | c.SFD_NONBLOCK);
    defer {
        if (sig_fd >= 0) _ = c.close(sig_fd);
    }

    std.debug.print("Mizu bar started successfully. Listening for events...\n", .{});

    const display_fd = c.wl_display_get_fd(app.display.?);

    while (app.running and !quit_requested) {
        while (c.wl_display_prepare_read(app.display.?) != 0) {
            _ = c.wl_display_dispatch_pending(app.display.?);
        }
        _ = c.wl_display_flush(app.display.?);

        var poll_fds = [_]c.struct_pollfd{
            .{ .fd = display_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (ipc.fd >= 0) ipc.fd else -1, .events = c.POLLIN, .revents = 0 },
            .{ .fd = timer_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (sig_fd >= 0) sig_fd else -1, .events = c.POLLIN, .revents = 0 },
        };

        const poll_res = c.poll(&poll_fds, 4, -1);
        if (poll_res < 0) {
            c.wl_display_cancel_read(app.display.?);
            if (quit_requested) break;
            continue;
        }

        if (poll_fds[0].revents & c.POLLIN != 0) {
            _ = c.wl_display_read_events(app.display.?);
        } else {
            c.wl_display_cancel_read(app.display.?);
        }
        _ = c.wl_display_dispatch_pending(app.display.?);

        if (ipc.fd >= 0 and (poll_fds[1].revents & c.POLLIN != 0)) {
            if (ipc.readEvents()) {
                app.needs_redraw = true;
            }
        }

        if (poll_fds[2].revents & c.POLLIN != 0) {
            var expirations: u64 = 0;
            _ = c.read(timer_fd, &expirations, @sizeOf(u64));
            bar.tick();
            app.needs_redraw = true;
        }

        if (sig_fd >= 0 and (poll_fds[3].revents & c.POLLIN != 0)) {
            var fdsi: c.struct_signalfd_siginfo = undefined;
            _ = c.read(sig_fd, &fdsi, @sizeOf(c.struct_signalfd_siginfo));
            bar.tick();
            app.needs_redraw = true;
        }

        if (app.needs_redraw) {
            app.redraw() catch |err| {
                std.debug.print("Redraw error: {any}\n", .{err});
            };
            app.needs_redraw = false;
        }
    }

    std.debug.print("Mizu shutting down cleanly.\n", .{});
}

fn runLauncher(allocator: std.mem.Allocator, cfg: config.Config) !void {
    var launcher = try launcher_module.Launcher.init(allocator, cfg);
    defer launcher.deinit();

    var app = wayland.WaylandApp.init(cfg);
    try app.connect();
    defer app.deinit();

    app.launcher = &launcher;
    try app.createLauncherSurface(launcher.width, launcher.height);

    const display_fd = c.wl_display_get_fd(app.display.?);

    while (app.running and launcher.running and !quit_requested) {
        while (c.wl_display_prepare_read(app.display.?) != 0) {
            _ = c.wl_display_dispatch_pending(app.display.?);
        }
        _ = c.wl_display_flush(app.display.?);

        var poll_fds = [_]c.struct_pollfd{
            .{ .fd = display_fd, .events = c.POLLIN, .revents = 0 },
        };

        const poll_res = c.poll(&poll_fds, 1, 400);
        if (poll_res < 0) {
            c.wl_display_cancel_read(app.display.?);
            if (quit_requested) break;
            continue;
        }

        if (poll_res == 0) {
            c.wl_display_cancel_read(app.display.?);
            launcher.tick();
            app.needs_redraw = true;
        } else if (poll_fds[0].revents & c.POLLIN != 0) {
            _ = c.wl_display_read_events(app.display.?);
        } else {
            c.wl_display_cancel_read(app.display.?);
        }
        _ = c.wl_display_dispatch_pending(app.display.?);

        if (app.needs_redraw) {
            app.redraw() catch |err| {
                std.debug.print("Launcher redraw error: {any}\n", .{err});
            };
            app.needs_redraw = false;
        }
    }
}

fn runQuickSettings(allocator: std.mem.Allocator, cfg: config.Config) !void {
    var qs = try quicksettings_module.QuickSettings.init(allocator, cfg);
    defer qs.deinit();

    var app = wayland.WaylandApp.init(cfg);
    try app.connect();
    defer app.deinit();

    app.quicksettings = &qs;
    try app.createQuickSettingsSurface(qs.width, qs.height);

    // 300ms timerfd for status updates and connect monitoring
    const timer_fd = c.timerfd_create(c.CLOCK_MONOTONIC, c.TFD_CLOEXEC | c.TFD_NONBLOCK);
    if (timer_fd >= 0) {
        var its: c.struct_itimerspec = undefined;
        its.it_interval.tv_sec = 0;
        its.it_interval.tv_nsec = 300_000_000;
        its.it_value.tv_sec = 0;
        its.it_value.tv_nsec = 300_000_000;
        _ = c.timerfd_settime(timer_fd, 0, &its, null);
    }
    defer {
        if (timer_fd >= 0) _ = c.close(timer_fd);
    }

    const display_fd = c.wl_display_get_fd(app.display.?);

    while (app.running and qs.running and !quit_requested) {
        while (c.wl_display_prepare_read(app.display.?) != 0) {
            _ = c.wl_display_dispatch_pending(app.display.?);
        }
        _ = c.wl_display_flush(app.display.?);

        var poll_fds = [_]c.struct_pollfd{
            .{ .fd = display_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (timer_fd >= 0) timer_fd else -1, .events = c.POLLIN, .revents = 0 },
        };

        const poll_res = c.poll(&poll_fds, 2, -1);
        if (poll_res < 0) {
            c.wl_display_cancel_read(app.display.?);
            if (quit_requested) break;
            continue;
        }

        if (poll_fds[0].revents & c.POLLIN != 0) {
            _ = c.wl_display_read_events(app.display.?);
        } else {
            c.wl_display_cancel_read(app.display.?);
        }
        _ = c.wl_display_dispatch_pending(app.display.?);

        if (timer_fd >= 0 and (poll_fds[1].revents & c.POLLIN != 0)) {
            var expirations: u64 = 0;
            _ = c.read(timer_fd, &expirations, @sizeOf(u64));
            qs.tick();
            app.needs_redraw = true;
        }

        if (app.needs_redraw) {
            app.redraw() catch |err| {
                std.debug.print("QuickSettings redraw error: {any}\n", .{err});
            };
            app.needs_redraw = false;
        }
    }
}

fn runCalendar(allocator: std.mem.Allocator, cfg: config.Config) !void {
    var cal = try calendar_module.Calendar.init(allocator, cfg);
    defer cal.deinit();

    var app = wayland.WaylandApp.init(cfg);
    try app.connect();
    defer app.deinit();

    app.calendar = &cal;
    try app.createCalendarSurface(cal.width, cal.height);

    const display_fd = c.wl_display_get_fd(app.display.?);

    while (app.running and cal.running and !quit_requested) {
        while (c.wl_display_prepare_read(app.display.?) != 0) {
            _ = c.wl_display_dispatch_pending(app.display.?);
        }
        _ = c.wl_display_flush(app.display.?);

        var poll_fds = [_]c.struct_pollfd{
            .{ .fd = display_fd, .events = c.POLLIN, .revents = 0 },
        };

        const poll_res = c.poll(&poll_fds, 1, -1);
        if (poll_res < 0) {
            c.wl_display_cancel_read(app.display.?);
            if (quit_requested) break;
            continue;
        }

        if (poll_fds[0].revents & c.POLLIN != 0) {
            _ = c.wl_display_read_events(app.display.?);
        } else {
            c.wl_display_cancel_read(app.display.?);
        }
        _ = c.wl_display_dispatch_pending(app.display.?);

        if (app.needs_redraw) {
            app.redraw() catch |err| {
                std.debug.print("Calendar redraw error: {any}\n", .{err});
            };
            app.needs_redraw = false;
        }
    }
}

fn runClipboard(allocator: std.mem.Allocator, cfg: config.Config) !void {
    var clip = try clipboard_module.ClipboardPanel.init(allocator, cfg);
    defer clip.deinit();

    var app = wayland.WaylandApp.init(cfg);
    try app.connect();
    defer app.deinit();

    app.clipboard = &clip;
    try app.createClipboardSurface(clip.width, clip.height);

    const display_fd = c.wl_display_get_fd(app.display.?);

    while (app.running and clip.running and !quit_requested) {
        while (c.wl_display_prepare_read(app.display.?) != 0) {
            _ = c.wl_display_dispatch_pending(app.display.?);
        }
        _ = c.wl_display_flush(app.display.?);

        var poll_fds = [_]c.struct_pollfd{
            .{ .fd = display_fd, .events = c.POLLIN, .revents = 0 },
        };

        const poll_res = c.poll(&poll_fds, 1, 400);
        if (poll_res < 0) {
            c.wl_display_cancel_read(app.display.?);
            if (quit_requested) break;
            continue;
        }

        if (poll_res == 0) {
            c.wl_display_cancel_read(app.display.?);
            clip.tick();
            app.needs_redraw = true;
        } else if (poll_fds[0].revents & c.POLLIN != 0) {
            _ = c.wl_display_read_events(app.display.?);
        } else {
            c.wl_display_cancel_read(app.display.?);
        }
        _ = c.wl_display_dispatch_pending(app.display.?);

        if (app.needs_redraw) {
            app.redraw() catch |err| {
                std.debug.print("Clipboard redraw error: {any}\n", .{err});
            };
            app.needs_redraw = false;
        }
    }
}

fn rearmTimer(timer_fd: c_int, ms: u64) void {
    var its: c.struct_itimerspec = undefined;
    its.it_interval.tv_sec = 0;
    its.it_interval.tv_nsec = 0;
    its.it_value.tv_sec = @intCast(ms / 1000);
    its.it_value.tv_nsec = @intCast((ms % 1000) * 1_000_000);
    _ = c.timerfd_settime(timer_fd, 0, &its, null);
}

fn getOsdSocketPath(buf: []u8) []const u8 {
    if (c.getenv("XDG_RUNTIME_DIR")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/mizu-osd.sock", .{std.mem.span(xdg)}) catch "/tmp/mizu-osd.sock";
    }
    return "/tmp/mizu-osd.sock";
}

fn trySendOsdIpc(sock_path: []const u8, msg: []const u8) bool {
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return false;
    defer _ = c.close(fd);

    var addr: c.struct_sockaddr_un = undefined;
    @memset(@as([*]u8, @ptrCast(&addr))[0..@sizeOf(c.struct_sockaddr_un)], 0);
    addr.sun_family = c.AF_UNIX;
    const path_len = @min(sock_path.len, addr.sun_path.len - 1);
    @memcpy(addr.sun_path[0..path_len], sock_path[0..path_len]);
    addr.sun_path[path_len] = 0;

    const addr_len = @as(c.socklen_t, @intCast(@sizeOf(c.sa_family_t) + path_len + 1));
    if (c.connect(fd, .{ .__sockaddr__ = @ptrCast(&addr) }, addr_len) < 0) {
        return false;
    }

    _ = c.write(fd, msg.ptr, msg.len);
    return true;
}

fn runOsd(allocator: std.mem.Allocator, cfg: config.Config, kind: osd_module.OsdKind, initial_cmd: []const u8) !void {
    var sock_path_buf: [256]u8 = undefined;
    const sock_path = getOsdSocketPath(&sock_path_buf);

    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "{s}\n", .{initial_cmd}) catch initial_cmd;

    // 1. Try sending to existing running OSD process
    if (trySendOsdIpc(sock_path, msg)) {
        return;
    }

    // 2. No OSD running: become the server
    const c_sock_path = try allocator.dupeZ(u8, sock_path);
    defer allocator.free(c_sock_path);
    _ = c.unlink(c_sock_path.ptr);

    const s_fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC, 0);
    if (s_fd < 0) return error.SocketCreationFailed;
    defer {
        _ = c.close(s_fd);
        _ = c.unlink(c_sock_path.ptr);
    }

    var addr: c.struct_sockaddr_un = undefined;
    @memset(@as([*]u8, @ptrCast(&addr))[0..@sizeOf(c.struct_sockaddr_un)], 0);
    addr.sun_family = c.AF_UNIX;
    const path_len = @min(sock_path.len, addr.sun_path.len - 1);
    @memcpy(addr.sun_path[0..path_len], sock_path[0..path_len]);
    addr.sun_path[path_len] = 0;

    const addr_len = @as(c.socklen_t, @intCast(@sizeOf(c.sa_family_t) + path_len + 1));
    if (c.bind(s_fd, .{ .__sockaddr__ = @ptrCast(&addr) }, addr_len) < 0) {
        return error.SocketBindFailed;
    }
    if (c.listen(s_fd, 5) < 0) {
        return error.SocketListenFailed;
    }

    var osd = try osd_module.Osd.init(allocator, cfg, kind);
    defer osd.deinit();

    osd.handleCommand(initial_cmd);

    var app = wayland.WaylandApp.init(cfg);
    try app.connect();
    defer app.deinit();

    app.osd = &osd;

    const anchor: u32 = if (kind == .notification)
        c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT
    else
        c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM;

    const margin_top: i32 = if (kind == .notification)
        @intCast(cfg.height + cfg.margin_top + cfg.margin_bottom + 8)
    else
        0;

    const margin_right: i32 = if (kind == .notification) 16 else 0;
    const margin_bottom: i32 = if (kind == .notification) 0 else 80;

    try app.createOsdSurface(osd.width, osd.height, anchor, margin_top, margin_right, margin_bottom);

    // Timeout duration: 1500ms for gauges, 3500ms for notifications
    const duration_ms: u64 = if (kind == .notification) 3500 else 1500;

    const timer_fd = c.timerfd_create(c.CLOCK_MONOTONIC, c.TFD_CLOEXEC | c.TFD_NONBLOCK);
    if (timer_fd < 0) return error.TimerFdFailed;
    defer {
        if (timer_fd >= 0) _ = c.close(timer_fd);
    }

    rearmTimer(timer_fd, duration_ms);

    const display_fd = c.wl_display_get_fd(app.display.?);

    while (app.running and osd.running and !quit_requested) {
        while (c.wl_display_prepare_read(app.display.?) != 0) {
            _ = c.wl_display_dispatch_pending(app.display.?);
        }
        _ = c.wl_display_flush(app.display.?);

        var poll_fds = [_]c.struct_pollfd{
            .{ .fd = display_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = timer_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = s_fd, .events = c.POLLIN, .revents = 0 },
        };

        const poll_res = c.poll(&poll_fds, 3, -1);
        if (poll_res < 0) {
            c.wl_display_cancel_read(app.display.?);
            if (quit_requested) break;
            continue;
        }

        if (poll_fds[0].revents & c.POLLIN != 0) {
            _ = c.wl_display_read_events(app.display.?);
        } else {
            c.wl_display_cancel_read(app.display.?);
        }
        _ = c.wl_display_dispatch_pending(app.display.?);

        // Timer expired
        if (poll_fds[1].revents & c.POLLIN != 0) {
            break;
        }

        // New client message arrived
        if (poll_fds[2].revents & c.POLLIN != 0) {
            const client_fd = c.accept(s_fd, .{ .__sockaddr__ = null }, null);
            if (client_fd >= 0) {
                var c_buf: [256]u8 = undefined;
                const bytes = c.read(client_fd, &c_buf, c_buf.len - 1);
                _ = c.close(client_fd);
                if (bytes > 0) {
                    c_buf[@intCast(bytes)] = 0;
                    const client_msg = std.mem.trim(u8, c_buf[0..@intCast(bytes)], " \t\r\n");
                    osd.handleCommand(client_msg);
                    rearmTimer(timer_fd, duration_ms);
                    app.needs_redraw = true;
                }
            }
        }

        if (app.needs_redraw) {
            app.redraw() catch |err| {
                std.debug.print("OSD redraw error: {any}\n", .{err});
            };
            app.needs_redraw = false;
        }
    }
}


