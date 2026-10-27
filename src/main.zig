const std = @import("std");
const c = @import("c.zig").c;
const config = @import("core/config.zig");
const theme = @import("core/theme.zig");
const mango_ipc = @import("services/mango_ipc.zig");
const bar_module = @import("bar/bar.zig");
const launcher_module = @import("panels/launcher.zig");
const quicksettings_module = @import("panels/quicksettings.zig");
const memory_monitor_module = @import("panels/memory_monitor.zig");
const calendar_module = @import("panels/calendar.zig");
const clipboard_module = @import("panels/clipboard.zig");
const osd_module = @import("panels/osd.zig");
const wayland = @import("core/wayland.zig");
const keymap_module = @import("services/keymap.zig");
const sys_status = @import("services/system_status.zig");
const lock_module = @import("panels/lock.zig");
const power_module = @import("panels/powermenu.zig");
const notification_module = @import("panels/notifications.zig");
const exec = @import("core/exec.zig");
const caffeine_module = @import("services/caffeine.zig");
pub const desktop_entry = @import("services/desktop_entries.zig");

test {
    _ = @import("services/desktop_entries.zig");
    _ = @import("panels/launcher.zig");
    _ = @import("panels/launcher_calculator.zig");
    _ = @import("panels/launcher_file_search.zig");
    _ = @import("panels/quicksettings.zig");
    _ = @import("panels/memory_monitor.zig");
    _ = @import("panels/osd.zig");
    _ = @import("bar/bar.zig");
    _ = @import("panels/calendar.zig");
    _ = @import("panels/clipboard.zig");
    _ = @import("core/text_input.zig");
    _ = @import("core/ui.zig");
    _ = @import("services/keymap.zig");
    _ = @import("core/config.zig");
    _ = @import("services/system_status.zig");
    _ = @import("core/theme.zig");
    _ = @import("panels/lock.zig");
    _ = @import("panels/powermenu.zig");
    _ = @import("panels/notifications.zig");
    _ = @import("services/caffeine.zig");
}

pub const VERSION = "0.1.0";

var quit_requested: bool = false;

fn sigHandler(sig: c_int) callconv(.c) void {
    _ = sig;
    quit_requested = true;
}

fn sigUsr1Handler(sig: c_int) callconv(.c) void {
    _ = sig;
}

pub const notify_dbus = struct {
    pub const MizuDbusNotification = extern struct {
        id: u32,
        app_name: [64]u8,
        app_icon: [128]u8,
        summary: [128]u8,
        body: [512]u8,
        expire_timeout_ms: i32,
        timestamp: u64,
    };

    pub const MizuNotifyCallback = ?*const fn (notif: ?*const MizuDbusNotification, userdata: ?*anyopaque) callconv(.c) void;

    pub extern "c" fn mizu_dbus_notify_init(callback: MizuNotifyCallback, userdata: ?*anyopaque) c_int;
    pub extern "c" fn mizu_dbus_notify_dispatch(timeout_ms: c_int) c_int;
    pub extern "c" fn mizu_dbus_notify_deinit() void;
    pub extern "c" fn mizu_dbus_notify_send(summary: [*c]const u8, body: [*c]const u8, app_name: [*c]const u8, timeout_ms: c_int) c_int;
};

const tray_dbus = struct {
    pub const MizuTrayItem = extern struct {
        service: [128]u8,
        path: [128]u8,
        id: [64]u8,
        title: [128]u8,
        icon_name: [128]u8,
        status: [32]u8,
        menu_path: [128]u8,
        is_menu: bool,
        pixmap_w: u32,
        pixmap_h: u32,
        pixmap_data: [32 * 32]u32,
    };
    pub const MizuTrayUpdateCallback = ?*const fn (userdata: ?*anyopaque) callconv(.c) void;

    pub extern "c" fn mizu_tray_dbus_init(callback: MizuTrayUpdateCallback, userdata: ?*anyopaque) c_int;
    pub extern "c" fn mizu_tray_dbus_dispatch(timeout_ms: c_int) c_int;
    pub extern "c" fn mizu_tray_get_items(out_items: [*c]MizuTrayItem, max_items: c_int) c_int;
    pub extern "c" fn mizu_tray_dbus_deinit() void;
};

var global_bar_app: ?*wayland.WaylandApp = null;

fn onTrayUpdate(userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    if (global_bar_app) |app| {
        app.needs_redraw = true;
    }
}

fn onDbusNotification(raw: ?*const notify_dbus.MizuDbusNotification, userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    const notif = raw orelse return;
    const allocator = std.heap.c_allocator;
    var store = notification_module.NotificationStore.init(allocator);
    defer store.deinit();

    var item = notification_module.Notification{
        .id = notif.id,
        .timestamp = notif.timestamp,
        .expire_timeout_ms = notif.expire_timeout_ms,
        .time_remaining_ms = notif.expire_timeout_ms,
    };

    const app_name_slice = std.mem.sliceTo(&notif.app_name, 0);
    @memcpy(item.app_name[0..app_name_slice.len], app_name_slice);
    item.app_name_len = app_name_slice.len;

    const summary_slice = std.mem.sliceTo(&notif.summary, 0);
    @memcpy(item.summary[0..summary_slice.len], summary_slice);
    item.summary_len = summary_slice.len;

    const body_slice = std.mem.sliceTo(&notif.body, 0);
    @memcpy(item.body[0..body_slice.len], body_slice);
    item.body_len = body_slice.len;

    store.add(item);

    // Spawn transient notification popup (direct exec, no shell parsing)
    exec.spawnNotify(summary_slice, body_slice);
}

const Command = enum {
    bar,
    launcher,
    quicksettings,
    memory_monitor,
    calendar,
    clipboard,
    notify,
    theme,
    keyoverlay,
    lock,
    power,
    session,
    caffeine,
    list,
    help,
    version,
};

fn parseCommand(arg: []const u8) ?Command {
    if (std.mem.eql(u8, arg, "bar")) {
        return .bar;
    } else if (std.mem.eql(u8, arg, "lock")) {
        return .lock;
    } else if (std.mem.eql(u8, arg, "power") or std.mem.eql(u8, arg, "shutdown")) {
        return .power;
    } else if (std.mem.eql(u8, arg, "session")) {
        return .session;
    } else if (std.mem.eql(u8, arg, "caffeine")) {
        return .caffeine;
    } else if (std.mem.eql(u8, arg, "launcher") or std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--launcher")) {
        return .launcher;
    } else if (std.mem.eql(u8, arg, "quicksettings") or std.mem.eql(u8, arg, "qs") or std.mem.eql(u8, arg, "panel") or std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quicksettings")) {
        return .quicksettings;
    } else if (std.mem.eql(u8, arg, "memory-monitor") or std.mem.eql(u8, arg, "mem-monitor") or std.mem.eql(u8, arg, "memmon")) {
        return .memory_monitor;
    } else if (std.mem.eql(u8, arg, "calendar") or std.mem.eql(u8, arg, "cal") or std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--calendar")) {
        return .calendar;
    } else if (std.mem.eql(u8, arg, "clipboard") or std.mem.eql(u8, arg, "clip") or std.mem.eql(u8, arg, "--clipboard")) {
        return .clipboard;
    } else if (std.mem.eql(u8, arg, "notify")) {
        return .notify;
    } else if (std.mem.eql(u8, arg, "theme") or std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--theme")) {
        return .theme;
    } else if (std.mem.eql(u8, arg, "keyoverlay") or std.mem.eql(u8, arg, "keymap") or std.mem.eql(u8, arg, "keys")) {
        return .keyoverlay;
    } else if (std.mem.eql(u8, arg, "list") or std.mem.eql(u8, arg, "panels")) {
        return .list;
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
        \\  lock            Lock the session with native Wayland lock screen
        \\  power           Open session & power confirmation overlay
        \\  session         Session management (lock, reboot, poweroff, suspend, logout)
        \\  launcher        Open the application launcher overlay (aliases: -l, --launcher)
        \\  quicksettings   Open the quick settings control panel (aliases: qs, panel, -q)
        \\  memory-monitor  Open the live process memory monitor (aliases: mem-monitor, memmon)
        \\  calendar        Open interactive month/year calendar (aliases: cal, -c)
        \\  clipboard       Open clipboard history search & manager (aliases: clip)
        \\  notify          Show a desktop notification popup (mizu notify <title> [body])
        \\  theme           Switch or inspect themes (mizu theme [next|prev|set <name>|list])
        \\  keyoverlay      Show on-screen key combination overlay (aliases: keymap, keys)
        \\  list            List all available built-in and configured custom panels
        \\  help            Display this help message
        \\  version         Display version information
        \\
        \\Options:
        \\  -h, --help      Display this help message
        \\  -v, --version   Display version information
        \\
        \\Run 'mizu bar' to launch the desktop status bar, 'mizu lock' to lock the screen, or 'mizu clip' for clipboard history.
        \\
    ;
    std.debug.print("{s}", .{help_text});
}

fn printVersion() void {
    std.debug.print("mizu {s}\n", .{VERSION});
}

fn toggleOrLockInstance(name: []const u8) bool {
    var pid_path_buf: [64]u8 = undefined;
    const pid_path = std.fmt.bufPrintZ(&pid_path_buf, "/tmp/mizu-{s}.pid", .{name}) catch return true;

    // Check if pid file exists
    if (c.fopen(pid_path.ptr, "r")) |f| {
        var buf: [32]u8 = undefined;
        const n = c.fread(&buf, 1, buf.len - 1, f);
        _ = c.fclose(f);
        if (n > 0) {
            buf[n] = 0;
            const pid_str = std.mem.trim(u8, buf[0..n], " \t\r\n");
            const existing_pid = std.fmt.parseInt(c_int, pid_str, 10) catch 0;
            if (existing_pid > 0 and existing_pid != c.getpid()) {
                if (c.kill(existing_pid, 0) == 0) {
                    _ = c.kill(existing_pid, c.SIGTERM);
                    _ = c.unlink(pid_path.ptr);
                    return false;
                }
            }
        }
    }

    if (c.fopen(pid_path.ptr, "w")) |f| {
        var buf: [32]u8 = undefined;
        const pid_str = std.fmt.bufPrint(&buf, "{d}\n", .{c.getpid()}) catch "";
        _ = c.fwrite(pid_str.ptr, 1, pid_str.len, f);
        _ = c.fclose(f);
    }
    return true;
}

fn cleanupPidFile(name: []const u8) void {
    var pid_path_buf: [64]u8 = undefined;
    if (std.fmt.bufPrintZ(&pid_path_buf, "/tmp/mizu-{s}.pid", .{name})) |pid_path| {
        _ = c.unlink(pid_path.ptr);
    } else |_| {}
}

fn isAlreadyLocked() bool {
    var pid_path_buf: [64]u8 = undefined;
    const pid_path = std.fmt.bufPrintZ(&pid_path_buf, "/tmp/mizu-lock.pid", .{}) catch return false;

    if (c.fopen(pid_path.ptr, "r")) |f| {
        var buf: [32]u8 = undefined;
        const n = c.fread(&buf, 1, buf.len - 1, f);
        _ = c.fclose(f);
        if (n > 0) {
            buf[n] = 0;
            const pid_str = std.mem.trim(u8, buf[0..n], " \t\r\n");
            const existing_pid = std.fmt.parseInt(c_int, pid_str, 10) catch 0;
            if (existing_pid > 0 and existing_pid != c.getpid()) {
                if (c.kill(existing_pid, 0) == 0) {
                    return true;
                }
            }
        }
    }

    if (c.fopen(pid_path.ptr, "w")) |f| {
        var buf: [32]u8 = undefined;
        const pid_str = std.fmt.bufPrint(&buf, "{d}\n", .{c.getpid()}) catch "";
        _ = c.fwrite(pid_str.ptr, 1, pid_str.len, f);
        _ = c.fclose(f);
    }
    return false;
}

fn runCustomPanel(allocator: std.mem.Allocator, name: []const u8, cmd: []const u8) u8 {
    if (!toggleOrLockInstance(name)) return 0;

    const pid = c.fork();
    if (pid == 0) {
        _ = c.setsid();
        const c_cmd = allocator.dupeZ(u8, cmd) catch c.exit(1);
        _ = c.execl("/bin/sh", "sh", "-c", c_cmd.ptr, @as(?*anyopaque, null));
        c.exit(1);
    } else if (pid > 0) {
        var pid_path_buf: [64]u8 = undefined;
        if (std.fmt.bufPrintZ(&pid_path_buf, "/tmp/mizu-{s}.pid", .{name})) |pid_path| {
            if (c.fopen(pid_path.ptr, "w")) |f| {
                var buf: [32]u8 = undefined;
                const pid_str = std.fmt.bufPrint(&buf, "{d}\n", .{pid}) catch "";
                _ = c.fwrite(pid_str.ptr, 1, pid_str.len, f);
                _ = c.fclose(f);
            }
        } else |_| {}
        return 0;
    } else {
        cleanupPidFile(name);
        std.debug.print("mizu: failed to launch custom panel '{s}'\n", .{name});
        return 1;
    }
}

fn handleThemeCommand(arg_it: anytype) u8 {
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
}

pub fn main(init: std.process.Init.Minimal) u8 {
    // Setup signal handlers
    _ = c.signal(c.SIGINT, sigHandler);
    _ = c.signal(c.SIGTERM, sigHandler);
    _ = c.signal(c.SIGCHLD, c.SIG_IGN);
    _ = c.signal(c.SIGUSR1, sigUsr1Handler);

    // Block SIGUSR1 early so all worker threads inherit the blocked mask.
    // The bar main thread can still consume it via signalfd, while preventing
    // any process or thread from terminating with "User defined signal 1".
    var init_sig_mask: c.sigset_t = undefined;
    _ = c.sigemptyset(&init_sig_mask);
    _ = c.sigaddset(&init_sig_mask, c.SIGUSR1);
    _ = c.sigprocmask(c.SIG_BLOCK, &init_sig_mask, null);

    var arg_it = init.args.iterate();
    _ = arg_it.next(); // skip binary name

    const maybe_cmd_str = arg_it.next();
    if (maybe_cmd_str == null) {
        printUsage();
        return 0;
    }

    const cmd_str = maybe_cmd_str.?;
    const maybe_cmd = parseCommand(cmd_str);
    if (maybe_cmd == null) {
        const allocator = std.heap.c_allocator;
        var cfg = loadConfig(allocator);
        defer cfg.deinit(allocator);

        if (cfg.findPanel(cmd_str)) |panel_cmd| {
            return runCustomPanel(allocator, cmd_str, panel_cmd);
        }

        std.debug.print("mizu: unrecognized command or panel '{s}'\n\n", .{cmd_str});
        printUsage();
        return 1;
    }
    const cmd = maybe_cmd.?;

    switch (cmd) {
        .help => {
            printUsage();
            return 0;
        },
        .caffeine => {
            return caffeine_module.run();
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
            if (!toggleOrLockInstance("launcher")) return 0;
            defer cleanupPidFile("launcher");

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
            if (!toggleOrLockInstance("quicksettings")) return 0;
            defer cleanupPidFile("quicksettings");

            const allocator = std.heap.c_allocator;
            var cfg = loadConfig(allocator);
            defer cfg.deinit(allocator);

            runQuickSettings(allocator, cfg) catch |err| {
                std.debug.print("mizu quicksettings error: {any}\n", .{err});
                return 1;
            };
            return 0;
        },
        .memory_monitor => {
            if (!toggleOrLockInstance("memory-monitor")) return 0;
            defer cleanupPidFile("memory-monitor");

            const allocator = std.heap.c_allocator;
            var cfg = loadConfig(allocator);
            defer cfg.deinit(allocator);

            runMemoryMonitor(allocator, cfg) catch |err| {
                std.debug.print("mizu memory-monitor error: {any}\n", .{err});
                return 1;
            };
            return 0;
        },
        .calendar => {
            if (!toggleOrLockInstance("calendar")) return 0;
            defer cleanupPidFile("calendar");

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
            if (!toggleOrLockInstance("clipboard")) return 0;
            defer cleanupPidFile("clipboard");

            const allocator = std.heap.c_allocator;
            var cfg = loadConfig(allocator);
            defer cfg.deinit(allocator);

            runClipboard(allocator, cfg) catch |err| {
                std.debug.print("mizu clipboard error: {any}\n", .{err});
                return 1;
            };
            return 0;
        },
        .power => {
            if (!toggleOrLockInstance("power")) return 0;
            defer cleanupPidFile("power");

            const allocator = std.heap.c_allocator;
            var cfg = loadConfig(allocator);
            defer cfg.deinit(allocator);

            runPower(allocator, cfg) catch |err| {
                std.debug.print("mizu power error: {any}\n", .{err});
                return 1;
            };
            return 0;
        },
        .session => {
            const sub = arg_it.next();
            if (sub == null) {
                // No subcommand - show session panel
                if (!toggleOrLockInstance("session")) return 0;
                defer cleanupPidFile("session");

                const allocator = std.heap.c_allocator;
                var cfg = loadConfig(allocator);
                defer cfg.deinit(allocator);

                runSession(allocator, cfg) catch |err| {
                    std.debug.print("mizu session error: {any}\n", .{err});
                    return 1;
                };
                return 0;
            }

            // Handle subcommands: mizu session <lock|reboot|poweroff|suspend|logout>
            const action = sub.?;
            if (std.mem.eql(u8, action, "lock")) {
                sys_status.spawnCmd("mizu lock 2>/dev/null || loginctl lock-session 2>/dev/null || true");
                return 0;
            } else if (std.mem.eql(u8, action, "reboot")) {
                sys_status.spawnCmd("systemctl reboot 2>/dev/null || loginctl reboot 2>/dev/null || reboot 2>/dev/null || true");
                return 0;
            } else if (std.mem.eql(u8, action, "poweroff") or std.mem.eql(u8, action, "shutdown")) {
                sys_status.spawnCmd("systemctl poweroff 2>/dev/null || loginctl poweroff 2>/dev/null || poweroff 2>/dev/null || true");
                return 0;
            } else if (std.mem.eql(u8, action, "suspend") or std.mem.eql(u8, action, "sleep")) {
                sys_status.spawnCmd("systemctl suspend 2>/dev/null || loginctl suspend 2>/dev/null || true");
                return 0;
            } else if (std.mem.eql(u8, action, "logout")) {
                sys_status.spawnCmd("pkill -u $USER 2>/dev/null || true");
                return 0;
            } else {
                std.debug.print("mizu: unknown session action '{s}'\n", .{action});
                std.debug.print("Usage: mizu session [lock|reboot|poweroff|suspend|logout]\n", .{});
                return 1;
            }
        },
        .notify => {
            const allocator = std.heap.c_allocator;
            var cfg = loadConfig(allocator);
            defer cfg.deinit(allocator);

            const title = arg_it.next() orelse "Mizu Notification";
            const body = arg_it.next() orelse "";

            // Record to persistent notification history
            var store = notification_module.NotificationStore.init(allocator);
            defer store.deinit();

            var item = notification_module.Notification{
                .id = @intCast(@max(1, c.time(null))),
                .timestamp = @intCast(@max(0, c.time(null))),
                .expire_timeout_ms = 4000,
                .time_remaining_ms = 4000,
            };
            const app_str = "Mizu";
            @memcpy(item.app_name[0..app_str.len], app_str);
            item.app_name_len = app_str.len;
            const t_len = @min(title.len, item.summary.len);
            @memcpy(item.summary[0..t_len], title[0..t_len]);
            item.summary_len = t_len;
            const b_len = @min(body.len, item.body.len);
            @memcpy(item.body[0..b_len], body[0..b_len]);
            item.body_len = b_len;
            store.add(item);

            var cmd_buf: [1024]u8 = undefined;
            const initial_cmd = std.fmt.bufPrint(&cmd_buf, "notify:{s}:::{s}", .{ title, body }) catch "notify:Mizu:::";

            runOsd(allocator, cfg, .notification, initial_cmd) catch |err| {
                std.debug.print("mizu notify error: {any}\n", .{err});
                return 1;
            };
            return 0;
        },
        .theme => {
            return handleThemeCommand(&arg_it);
        },
        .list => {
            const allocator = std.heap.c_allocator;
            var cfg = loadConfig(allocator);
            defer cfg.deinit(allocator);

            std.debug.print("Available Built-in Panels & Targets:\n", .{});
            std.debug.print("  lock           (native Wayland session lock)\n", .{});
            std.debug.print("  launcher       (aliases: -l, --launcher)\n", .{});
            std.debug.print("  quicksettings  (aliases: qs, panel, -q)\n", .{});
            std.debug.print("  memory-monitor (aliases: mem-monitor, memmon)\n", .{});
            std.debug.print("  calendar       (aliases: cal, -c)\n", .{});
            std.debug.print("  clipboard      (aliases: clip)\n", .{});
            std.debug.print("  keyoverlay     (aliases: keymap, keys)\n", .{});
            std.debug.print("  notify\n", .{});
            std.debug.print("  theme\n", .{});
            std.debug.print("  bar\n", .{});
            std.debug.print("  session        (lock, reboot, poweroff, suspend, logout)\n\n", .{});

            if (cfg.panels.items.len > 0) {
                std.debug.print("Configured Custom Panels (~/.config/mizu/config.ini [panels]):\n", .{});
                for (cfg.panels.items) |p| {
                    std.debug.print("  {s:<14} -> {s}\n", .{ p.name, p.command });
                }
            } else {
                std.debug.print("No custom panels defined. Add [panels] to ~/.config/mizu/config.ini to register custom panels.\n", .{});
            }
            return 0;
        },
        .keyoverlay => {
            if (!toggleOrLockInstance("keyoverlay")) return 0;
            defer cleanupPidFile("keyoverlay");

            const allocator = std.heap.c_allocator;
            var cfg = loadConfig(allocator);
            defer cfg.deinit(allocator);

            runKeyOverlay(allocator, cfg) catch |err| {
                std.debug.print("mizu keyoverlay error: {any}\n", .{err});
                return 1;
            };
            return 0;
        },
        .lock => {
            if (isAlreadyLocked()) {
                std.debug.print("mizu: session already locked\n", .{});
                return 0;
            }
            defer cleanupPidFile("lock");

            const allocator = std.heap.c_allocator;
            var cfg = loadConfig(allocator);
            defer cfg.deinit(allocator);

            runLock(allocator, cfg) catch |err| {
                std.debug.print("mizu lock error: {any}\n", .{err});
                return 1;
            };
            return 0;
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

fn createSigUsr1Fd() c_int {
    var sig_mask: c.sigset_t = undefined;
    _ = c.sigemptyset(&sig_mask);
    _ = c.sigaddset(&sig_mask, c.SIGUSR1);
    _ = c.sigprocmask(c.SIG_BLOCK, &sig_mask, null);
    return c.signalfd(-1, &sig_mask, c.SFD_CLOEXEC | c.SFD_NONBLOCK);
}

fn runBar(allocator: std.mem.Allocator, cfg: config.Config) !void {
    var ipc = mango_ipc.MangoIpc.init();
    defer ipc.deinit();

    var app = wayland.WaylandApp.init(cfg);
    try app.connect();
    defer app.deinit();

    // Restore persistent display and night light session settings
    quicksettings_module.restoreSessionSettings();

    var bar = try bar_module.Bar.init(allocator, cfg);
    defer bar.deinit();

    app.bar = &bar;
    app.ipc = &ipc;

    // Create bar surface
    try app.createSurface();

    // Render first frame immediately so bar appears without delay
    _ = bar.tick();
    app.needs_redraw = true;
    try app.redraw();
    _ = c.wl_display_flush(app.display.?);
    app.needs_redraw = false;

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
    const sig_fd = createSigUsr1Fd();
    defer {
        if (sig_fd >= 0) _ = c.close(sig_fd);
    }

    // Start D-Bus notification daemon service (org.freedesktop.Notifications)
    const dbus_init_res = notify_dbus.mizu_dbus_notify_init(onDbusNotification, null);
    if (dbus_init_res == 0) {
        std.debug.print("Mizu notification daemon active on org.freedesktop.Notifications\n", .{});
    }
    defer notify_dbus.mizu_dbus_notify_deinit();

    global_bar_app = &app;
    defer global_bar_app = null;

    // Start D-Bus StatusNotifierWatcher service for system tray (org.kde.StatusNotifierWatcher)
    const tray_init_res = tray_dbus.mizu_tray_dbus_init(onTrayUpdate, null);
    if (tray_init_res == 0) {
        std.debug.print("Mizu StatusNotifierWatcher active on org.kde.StatusNotifierWatcher\n", .{});
    }
    defer tray_dbus.mizu_tray_dbus_deinit();

    _ = sys_status.dbus_monitor.mizu_dbus_monitor_init(-1);
    defer sys_status.dbus_monitor.mizu_dbus_monitor_deinit();

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

        const poll_res = c.poll(&poll_fds, 4, 250);
        _ = notify_dbus.mizu_dbus_notify_dispatch(0);
        _ = tray_dbus.mizu_tray_dbus_dispatch(0);

        if (poll_res < 0) {
            c.wl_display_cancel_read(app.display.?);
            if (quit_requested) break;
            continue;
        }

        if (poll_fds[0].revents & (c.POLLHUP | c.POLLERR) != 0) {
            c.wl_display_cancel_read(app.display.?);
            break;
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
            if (bar.tick()) app.needs_redraw = true;
        }

        if (sig_fd >= 0 and (poll_fds[3].revents & c.POLLIN != 0)) {
            var fdsi: c.struct_signalfd_siginfo = undefined;
            _ = c.read(sig_fd, &fdsi, @sizeOf(c.struct_signalfd_siginfo));
            if (bar.reloadTheme()) app.needs_redraw = true;
            if (bar.tick()) app.needs_redraw = true;
        }

        if (app.needs_redraw) {
            app.redraw() catch |err| {
                std.debug.print("Redraw error: {any}\n", .{err});
            };
            _ = c.wl_display_flush(app.display.?);
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

    // Render first frame immediately so launcher is visible on screen at T=0
    launcher.tick();
    app.needs_redraw = true;
    try app.redraw();
    _ = c.wl_display_flush(app.display.?);
    app.needs_redraw = false;

    const display_fd = c.wl_display_get_fd(app.display.?);
    const sig_fd = createSigUsr1Fd();
    defer {
        if (sig_fd >= 0) _ = c.close(sig_fd);
    }

    while (app.running and launcher.running and !quit_requested) {
        while (c.wl_display_prepare_read(app.display.?) != 0) {
            _ = c.wl_display_dispatch_pending(app.display.?);
        }
        _ = c.wl_display_flush(app.display.?);

        var poll_fds = [_]c.struct_pollfd{
            .{ .fd = display_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (app.repeat_timer_fd >= 0) app.repeat_timer_fd else -1, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (sig_fd >= 0) sig_fd else -1, .events = c.POLLIN, .revents = 0 },
        };

        const timeout: c_int = 400; // Maintain smooth caret blinking in search box
        const poll_res = c.poll(&poll_fds, 3, timeout);
        if (poll_res < 0) {
            c.wl_display_cancel_read(app.display.?);
            if (quit_requested) break;
            continue;
        }

        if (poll_fds[0].revents & (c.POLLHUP | c.POLLERR) != 0) {
            c.wl_display_cancel_read(app.display.?);
            break;
        }

        if (poll_res == 0) {
            c.wl_display_cancel_read(app.display.?);
            launcher.tick();
            app.needs_redraw = true;
        } else {
            if (poll_fds[0].revents & c.POLLIN != 0) {
                _ = c.wl_display_read_events(app.display.?);
            } else {
                c.wl_display_cancel_read(app.display.?);
            }
        }
        _ = c.wl_display_dispatch_pending(app.display.?);

        if (sig_fd >= 0 and (poll_fds[2].revents & c.POLLIN != 0)) {
            var fdsi: c.struct_signalfd_siginfo = undefined;
            _ = c.read(sig_fd, &fdsi, @sizeOf(c.struct_signalfd_siginfo));
            launcher.tick();
            app.needs_redraw = true;
        }

        if (app.repeat_timer_fd >= 0 and (poll_fds[1].revents & c.POLLIN != 0)) {
            app.handleRepeatTimer();
        }

        if (app.needs_redraw) {
            app.redraw() catch |err| {
                std.debug.print("Launcher redraw error: {any}\n", .{err});
            };
            _ = c.wl_display_flush(app.display.?);
            app.needs_redraw = false;
        }
    }
}

fn runMemoryMonitor(allocator: std.mem.Allocator, cfg: config.Config) !void {
    var mm = try memory_monitor_module.MemoryMonitor.init(allocator, cfg);
    defer mm.deinit();

    var app = wayland.WaylandApp.init(cfg);
    try app.connect();
    defer app.deinit();

    app.memory_monitor = &mm;
    try app.createMemoryMonitorSurface(mm.width, mm.height);

    // Render first frame immediately so the monitor is visible without delay.
    app.needs_redraw = true;
    try app.redraw();
    _ = c.wl_display_flush(app.display.?);
    app.needs_redraw = false;

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

    const display_fd = c.wl_display_get_fd(app.display.?);
    const sig_fd = createSigUsr1Fd();
    defer {
        if (sig_fd >= 0) _ = c.close(sig_fd);
    }

    while (app.running and mm.running and !quit_requested) {
        while (c.wl_display_prepare_read(app.display.?) != 0) {
            _ = c.wl_display_dispatch_pending(app.display.?);
        }
        _ = c.wl_display_flush(app.display.?);

        var poll_fds = [_]c.struct_pollfd{
            .{ .fd = display_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = timer_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (sig_fd >= 0) sig_fd else -1, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (app.repeat_timer_fd >= 0) app.repeat_timer_fd else -1, .events = c.POLLIN, .revents = 0 },
        };

        const poll_res = c.poll(&poll_fds, 4, -1);
        if (poll_res < 0) {
            c.wl_display_cancel_read(app.display.?);
            if (quit_requested) break;
            continue;
        }

        if (poll_fds[0].revents & (c.POLLHUP | c.POLLERR) != 0) {
            c.wl_display_cancel_read(app.display.?);
            break;
        }

        if (poll_fds[0].revents & c.POLLIN != 0) {
            _ = c.wl_display_read_events(app.display.?);
        } else {
            c.wl_display_cancel_read(app.display.?);
        }
        _ = c.wl_display_dispatch_pending(app.display.?);

        if (poll_fds[1].revents & c.POLLIN != 0) {
            var expirations: u64 = 0;
            _ = c.read(timer_fd, &expirations, @sizeOf(u64));
            if (mm.tick()) app.needs_redraw = true;
        }

        if (sig_fd >= 0 and (poll_fds[2].revents & c.POLLIN != 0)) {
            var fdsi: c.struct_signalfd_siginfo = undefined;
            _ = c.read(sig_fd, &fdsi, @sizeOf(c.struct_signalfd_siginfo));
            if (mm.checkTheme()) app.needs_redraw = true;
        }

        if (app.repeat_timer_fd >= 0 and (poll_fds[3].revents & c.POLLIN != 0)) {
            app.handleRepeatTimer();
        }

        if (app.needs_redraw) {
            app.redraw() catch |err| {
                std.debug.print("MemoryMonitor redraw error: {any}\n", .{err});
            };
            _ = c.wl_display_flush(app.display.?);
            app.needs_redraw = false;
        }
    }
}

fn runQuickSettings(allocator: std.mem.Allocator, cfg: config.Config) !void {
    quicksettings_module.restoreSessionSettings();

    var qs = try quicksettings_module.QuickSettings.init(allocator, cfg);
    defer qs.deinit();
    qs.triggerWifiScan();
    qs.triggerBtScan();
    qs.triggerAudioScan();

    var app = wayland.WaylandApp.init(cfg);
    try app.connect();
    defer app.deinit();

    app.quicksettings = &qs;
    try app.createQuickSettingsSurface(qs.width, qs.height);

    // Render first frame immediately so quicksettings is visible without delay
    _ = qs.tick();
    app.needs_redraw = true;
    try app.redraw();
    _ = c.wl_display_flush(app.display.?);
    app.needs_redraw = false;

    // Dynamic timerfd: 50ms initially for first async status refresh, then 1500ms when idle, 200ms when scanning or typing
    const timer_fd = c.timerfd_create(c.CLOCK_MONOTONIC, c.TFD_CLOEXEC | c.TFD_NONBLOCK);
    if (timer_fd >= 0) {
        rearmTimer(timer_fd, 50);
    }
    defer {
        if (timer_fd >= 0) _ = c.close(timer_fd);
    }

    const display_fd = c.wl_display_get_fd(app.display.?);
    const sig_fd = createSigUsr1Fd();
    defer {
        if (sig_fd >= 0) _ = c.close(sig_fd);
    }

    while (app.running and qs.running and !quit_requested) {
        while (c.wl_display_prepare_read(app.display.?) != 0) {
            _ = c.wl_display_dispatch_pending(app.display.?);
        }
        _ = c.wl_display_flush(app.display.?);

        var poll_fds = [_]c.struct_pollfd{
            .{ .fd = display_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (timer_fd >= 0) timer_fd else -1, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (qs.wake_fd >= 0) qs.wake_fd else -1, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (app.repeat_timer_fd >= 0) app.repeat_timer_fd else -1, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (sig_fd >= 0) sig_fd else -1, .events = c.POLLIN, .revents = 0 },
        };

        const is_animating = qs.is_scanning or qs.wifi_input_idx != null or qs.wifi_worker_running or
            qs.wifi_scan_worker.running.load(.acquire) or qs.bt_scan_worker.running.load(.acquire) or
            qs.audio_scan_worker.running.load(.acquire) or qs.bt_connect_worker.running.load(.acquire);
        const timeout: c_int = if (is_animating) 33 else 1000;
        const poll_res = c.poll(&poll_fds, 5, timeout);
        if (poll_res < 0) {
            c.wl_display_cancel_read(app.display.?);
            if (quit_requested) break;
            continue;
        }

        if (poll_fds[0].revents & (c.POLLHUP | c.POLLERR) != 0) {
            c.wl_display_cancel_read(app.display.?);
            break;
        }

        if (poll_res == 0) {
            c.wl_display_cancel_read(app.display.?);
            if (qs.tick()) app.needs_redraw = true;
        } else {
            if (poll_fds[0].revents & c.POLLIN != 0) {
                _ = c.wl_display_read_events(app.display.?);
            } else {
                c.wl_display_cancel_read(app.display.?);
            }
        }
        _ = c.wl_display_dispatch_pending(app.display.?);

        // Immediate wakeup when a background async worker finishes, so scan
        // / connect results are reflected without waiting for the next timer tick.
        if (qs.wake_fd >= 0 and (poll_fds[2].revents & c.POLLIN != 0)) {
            var val: u64 = 0;
            _ = c.read(qs.wake_fd, &val, @sizeOf(u64));
            if (qs.drainAll()) app.needs_redraw = true;
            if (qs.tick()) app.needs_redraw = true;
        }

        if (timer_fd >= 0 and (poll_fds[1].revents & c.POLLIN != 0)) {
            var expirations: u64 = 0;
            _ = c.read(timer_fd, &expirations, @sizeOf(u64));
            if (qs.tick()) app.needs_redraw = true;
            const next_interval: u64 = if (is_animating) 33 else 1000;
            rearmTimer(timer_fd, next_interval);
        }

        if (sig_fd >= 0 and (poll_fds[4].revents & c.POLLIN != 0)) {
            var fdsi: c.struct_signalfd_siginfo = undefined;
            _ = c.read(sig_fd, &fdsi, @sizeOf(c.struct_signalfd_siginfo));
            if (qs.tick()) app.needs_redraw = true;
        }

        if (app.repeat_timer_fd >= 0 and (poll_fds[3].revents & c.POLLIN != 0)) {
            app.handleRepeatTimer();
        }

        if (app.needs_redraw) {
            app.redraw() catch |err| {
                std.debug.print("QuickSettings redraw error: {any}\n", .{err});
            };
            _ = c.wl_display_flush(app.display.?);
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

    // Render first frame immediately so calendar appears without delay
    app.needs_redraw = true;
    try app.redraw();
    _ = c.wl_display_flush(app.display.?);
    app.needs_redraw = false;

    const display_fd = c.wl_display_get_fd(app.display.?);
    const sig_fd = createSigUsr1Fd();
    defer {
        if (sig_fd >= 0) _ = c.close(sig_fd);
    }

    while (app.running and cal.running and !quit_requested) {
        while (c.wl_display_prepare_read(app.display.?) != 0) {
            _ = c.wl_display_dispatch_pending(app.display.?);
        }
        _ = c.wl_display_flush(app.display.?);

        var poll_fds = [_]c.struct_pollfd{
            .{ .fd = display_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (app.repeat_timer_fd >= 0) app.repeat_timer_fd else -1, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (sig_fd >= 0) sig_fd else -1, .events = c.POLLIN, .revents = 0 },
        };

        const poll_res = c.poll(&poll_fds, 3, 1000);
        if (poll_res < 0) {
            c.wl_display_cancel_read(app.display.?);
            if (quit_requested) break;
            continue;
        }

        if (poll_res == 0) {
            c.wl_display_cancel_read(app.display.?);
            if (cal.tick()) app.needs_redraw = true;
        } else {
            if (poll_fds[0].revents & (c.POLLHUP | c.POLLERR) != 0) {
                c.wl_display_cancel_read(app.display.?);
                break;
            }

            if (poll_fds[0].revents & c.POLLIN != 0) {
                _ = c.wl_display_read_events(app.display.?);
            } else {
                c.wl_display_cancel_read(app.display.?);
            }
        }
        _ = c.wl_display_dispatch_pending(app.display.?);

        if (sig_fd >= 0 and (poll_fds[2].revents & c.POLLIN != 0)) {
            var fdsi: c.struct_signalfd_siginfo = undefined;
            _ = c.read(sig_fd, &fdsi, @sizeOf(c.struct_signalfd_siginfo));
            if (cal.tick()) app.needs_redraw = true;
        }

        if (app.repeat_timer_fd >= 0 and (poll_fds[1].revents & c.POLLIN != 0)) {
            app.handleRepeatTimer();
        }

        if (app.needs_redraw) {
            app.redraw() catch |err| {
                std.debug.print("Calendar redraw error: {any}\n", .{err});
            };
            _ = c.wl_display_flush(app.display.?);
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

    // Check updates and render first frame immediately so panel is visible at T=0
    if (clip.tick()) {}
    app.needs_redraw = true;
    try app.redraw();
    _ = c.wl_display_flush(app.display.?);
    app.needs_redraw = false;

    const display_fd = c.wl_display_get_fd(app.display.?);
    const wake_fd = clip.getWakeFd();
    const sig_fd = createSigUsr1Fd();
    defer {
        if (sig_fd >= 0) _ = c.close(sig_fd);
    }

    while (app.running and clip.running and !quit_requested) {
        while (c.wl_display_prepare_read(app.display.?) != 0) {
            _ = c.wl_display_dispatch_pending(app.display.?);
        }
        _ = c.wl_display_flush(app.display.?);

        var poll_fds = [_]c.struct_pollfd{
            .{ .fd = display_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (app.repeat_timer_fd >= 0) app.repeat_timer_fd else -1, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (wake_fd >= 0) wake_fd else -1, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (sig_fd >= 0) sig_fd else -1, .events = c.POLLIN, .revents = 0 },
        };

        const timeout: c_int = if (app.has_kbd_focus) 400 else -1;
        const poll_res = c.poll(&poll_fds, 4, timeout);
        if (poll_res < 0) {
            c.wl_display_cancel_read(app.display.?);
            if (quit_requested) break;
            continue;
        }

        if (poll_fds[0].revents & (c.POLLHUP | c.POLLERR) != 0) {
            c.wl_display_cancel_read(app.display.?);
            break;
        }

        if (poll_fds[0].revents & c.POLLIN != 0) {
            _ = c.wl_display_read_events(app.display.?);
        } else {
            c.wl_display_cancel_read(app.display.?);
        }
        _ = c.wl_display_dispatch_pending(app.display.?);

        // Immediate wakeup when background worker finishes
        if (wake_fd >= 0 and (poll_fds[2].revents & c.POLLIN != 0)) {
            var val: u64 = 0;
            _ = c.read(wake_fd, &val, @sizeOf(u64));
            if (clip.tick()) {
                app.needs_redraw = true;
            }
        }

        if (sig_fd >= 0 and (poll_fds[3].revents & c.POLLIN != 0)) {
            var fdsi: c.struct_signalfd_siginfo = undefined;
            _ = c.read(sig_fd, &fdsi, @sizeOf(c.struct_signalfd_siginfo));
            if (clip.tick()) {
                app.needs_redraw = true;
            }
        }

        // Caret blink on timeout
        if (poll_res == 0) {
            clip.toggleCaret();
            app.needs_redraw = true;
        }

        if (app.repeat_timer_fd >= 0 and (poll_fds[1].revents & c.POLLIN != 0)) {
            app.handleRepeatTimer();
        }

        if (app.needs_redraw) {
            app.redraw() catch |err| {
                std.debug.print("Clipboard redraw error: {any}\n", .{err});
            };
            _ = c.wl_display_flush(app.display.?);
            app.needs_redraw = false;
        }
    }
}

fn runPower(allocator: std.mem.Allocator, cfg: config.Config) !void {
    var pwr = try power_module.PowerOverlay.init(allocator, cfg);
    defer pwr.deinit();

    var app = wayland.WaylandApp.init(cfg);
    try app.connect();
    defer app.deinit();

    app.power = &pwr;
    try app.createPowerSurface(pwr.width, pwr.height);

    // Initial frame
    app.needs_redraw = true;
    try app.redraw();
    _ = c.wl_display_flush(app.display.?);
    app.needs_redraw = false;

    const timer_fd = c.timerfd_create(c.CLOCK_MONOTONIC, c.TFD_CLOEXEC | c.TFD_NONBLOCK);
    if (timer_fd >= 0) {
        rearmTimer(timer_fd, 50);
    }
    defer {
        if (timer_fd >= 0) _ = c.close(timer_fd);
    }

    const display_fd = c.wl_display_get_fd(app.display.?);
    const sig_fd = createSigUsr1Fd();
    defer {
        if (sig_fd >= 0) _ = c.close(sig_fd);
    }

    while (app.running and pwr.running and !quit_requested) {
        while (c.wl_display_prepare_read(app.display.?) != 0) {
            _ = c.wl_display_dispatch_pending(app.display.?);
        }
        _ = c.wl_display_flush(app.display.?);

        var poll_fds = [_]c.struct_pollfd{
            .{ .fd = display_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (timer_fd >= 0) timer_fd else -1, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (app.repeat_timer_fd >= 0) app.repeat_timer_fd else -1, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (sig_fd >= 0) sig_fd else -1, .events = c.POLLIN, .revents = 0 },
        };

        const timeout: c_int = if (pwr.confirming) 50 else -1;
        const poll_res = c.poll(&poll_fds, 4, timeout);
        if (poll_res < 0) {
            c.wl_display_cancel_read(app.display.?);
            if (quit_requested) break;
            continue;
        }

        if (poll_fds[0].revents & (c.POLLHUP | c.POLLERR) != 0) {
            c.wl_display_cancel_read(app.display.?);
            break;
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
            if (pwr.tick()) app.needs_redraw = true;
            rearmTimer(timer_fd, 50);
        }

        if (sig_fd >= 0 and (poll_fds[3].revents & c.POLLIN != 0)) {
            var fdsi: c.struct_signalfd_siginfo = undefined;
            _ = c.read(sig_fd, &fdsi, @sizeOf(c.struct_signalfd_siginfo));
            if (pwr.tick()) app.needs_redraw = true;
        }

        if (app.repeat_timer_fd >= 0 and (poll_fds[2].revents & c.POLLIN != 0)) {
            app.handleRepeatTimer();
        }

        if (app.needs_redraw) {
            app.redraw() catch |err| {
                std.debug.print("Power redraw error: {any}\n", .{err});
            };
            _ = c.wl_display_flush(app.display.?);
            app.needs_redraw = false;
        }
    }
}

fn runSession(allocator: std.mem.Allocator, cfg: config.Config) !void {
    var session = try power_module.PowerOverlay.init(allocator, cfg);
    defer session.deinit();

    var app = wayland.WaylandApp.init(cfg);
    try app.connect();
    defer app.deinit();

    app.power = &session;
    try app.createPowerSurface(session.width, session.height);

    // Initial frame
    app.needs_redraw = true;
    try app.redraw();
    _ = c.wl_display_flush(app.display.?);
    app.needs_redraw = false;

    const timer_fd = c.timerfd_create(c.CLOCK_MONOTONIC, c.TFD_CLOEXEC | c.TFD_NONBLOCK);
    if (timer_fd >= 0) {
        rearmTimer(timer_fd, 50);
    }
    defer {
        if (timer_fd >= 0) _ = c.close(timer_fd);
    }

    const display_fd = c.wl_display_get_fd(app.display.?);
    const sig_fd = createSigUsr1Fd();
    defer {
        if (sig_fd >= 0) _ = c.close(sig_fd);
    }

    while (app.running and session.running and !quit_requested) {
        while (c.wl_display_prepare_read(app.display.?) != 0) {
            _ = c.wl_display_dispatch_pending(app.display.?);
        }
        _ = c.wl_display_flush(app.display.?);

        var poll_fds = [_]c.struct_pollfd{
            .{ .fd = display_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (timer_fd >= 0) timer_fd else -1, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (app.repeat_timer_fd >= 0) app.repeat_timer_fd else -1, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (sig_fd >= 0) sig_fd else -1, .events = c.POLLIN, .revents = 0 },
        };

        const timeout: c_int = if (session.confirming) 50 else -1;
        const poll_res = c.poll(&poll_fds, 4, timeout);
        if (poll_res < 0) {
            c.wl_display_cancel_read(app.display.?);
            if (quit_requested) break;
            continue;
        }

        if (poll_fds[0].revents & (c.POLLHUP | c.POLLERR) != 0) {
            c.wl_display_cancel_read(app.display.?);
            break;
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
            if (session.tick()) app.needs_redraw = true;
            rearmTimer(timer_fd, 50);
        }

        if (sig_fd >= 0 and (poll_fds[3].revents & c.POLLIN != 0)) {
            var fdsi: c.struct_signalfd_siginfo = undefined;
            _ = c.read(sig_fd, &fdsi, @sizeOf(c.struct_signalfd_siginfo));
            if (session.tick()) app.needs_redraw = true;
        }

        if (app.repeat_timer_fd >= 0 and (poll_fds[2].revents & c.POLLIN != 0)) {
            app.handleRepeatTimer();
        }

        if (app.needs_redraw) {
            app.redraw() catch |err| {
                std.debug.print("Session redraw error: {any}\n", .{err});
            };
            _ = c.wl_display_flush(app.display.?);
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

    var msg_buf: [1024]u8 = undefined;
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
    var owns_socket = true;
    defer {
        if (owns_socket) {
            _ = c.close(s_fd);
            _ = c.unlink(c_sock_path.ptr);
        }
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

    // Detach the popup server so `mizu notify` returns immediately instead of
    // blocking for the lifetime of the toast. The parent leaves the bound
    // socket to the child and skips the cleanup defers.
    const daemon_pid = c.fork();
    if (daemon_pid < 0) return error.ForkFailed;
    if (daemon_pid > 0) {
        owns_socket = false;
        _ = c.close(s_fd);
        return;
    }
    _ = c.setsid();
    const devnull = c.open("/dev/null", c.O_RDWR);
    if (devnull >= 0) {
        _ = c.dup2(devnull, 0);
        _ = c.dup2(devnull, 1);
        _ = c.dup2(devnull, 2);
        _ = c.close(devnull);
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

    // Render first frame immediately so OSD appears without delay
    app.needs_redraw = true;
    try app.redraw();
    _ = c.wl_display_flush(app.display.?);
    app.needs_redraw = false;

    // Timeout duration: 1500ms for gauges, 3500ms for notifications
    const duration_ms: u64 = if (kind == .notification) 3500 else 1500;

    const timer_fd = c.timerfd_create(c.CLOCK_MONOTONIC, c.TFD_CLOEXEC | c.TFD_NONBLOCK);
    if (timer_fd < 0) return error.TimerFdFailed;
    defer {
        if (timer_fd >= 0) _ = c.close(timer_fd);
    }

    rearmTimer(timer_fd, duration_ms);

    const display_fd = c.wl_display_get_fd(app.display.?);
    const sig_fd = createSigUsr1Fd();
    defer {
        if (sig_fd >= 0) _ = c.close(sig_fd);
    }

    while (app.running and osd.running and !quit_requested) {
        while (c.wl_display_prepare_read(app.display.?) != 0) {
            _ = c.wl_display_dispatch_pending(app.display.?);
        }
        _ = c.wl_display_flush(app.display.?);

        var poll_fds = [_]c.struct_pollfd{
            .{ .fd = display_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = timer_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = s_fd, .events = c.POLLIN, .revents = 0 },
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

        // Timer expired
        if (poll_fds[1].revents & c.POLLIN != 0) {
            break;
        }

        // New client message arrived
        if (poll_fds[2].revents & c.POLLIN != 0) {
            const client_fd = c.accept(s_fd, .{ .__sockaddr__ = null }, null);
            if (client_fd >= 0) {
                var c_buf: [1024]u8 = undefined;
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

        if (sig_fd >= 0 and (poll_fds[3].revents & c.POLLIN != 0)) {
            var fdsi: c.struct_signalfd_siginfo = undefined;
            _ = c.read(sig_fd, &fdsi, @sizeOf(c.struct_signalfd_siginfo));
            if (osd.tick()) app.needs_redraw = true;
        }

        if (app.needs_redraw) {
            app.redraw() catch |err| {
                std.debug.print("OSD redraw error: {any}\n", .{err});
            };
            _ = c.wl_display_flush(app.display.?);
            app.needs_redraw = false;
        }
    }
}

fn runKeyOverlay(allocator: std.mem.Allocator, cfg: config.Config) !void {
    var key_overlay = try keymap_module.KeyOverlay.init(allocator, cfg);
    defer key_overlay.deinit();

    var app = wayland.WaylandApp.init(cfg);
    try app.connect();
    defer app.deinit();

    app.keyoverlay = &key_overlay;
    try app.createKeyOverlaySurface(key_overlay.width, key_overlay.height);

    // Render first frame immediately so keyoverlay appears without delay
    app.needs_redraw = true;
    try app.redraw();
    _ = c.wl_display_flush(app.display.?);
    app.needs_redraw = false;

    const timer_fd = c.timerfd_create(c.CLOCK_MONOTONIC, c.TFD_CLOEXEC | c.TFD_NONBLOCK);
    if (timer_fd < 0) return error.TimerFdFailed;
    defer {
        if (timer_fd >= 0) _ = c.close(timer_fd);
    }

    var its: c.struct_itimerspec = undefined;
    its.it_interval.tv_sec = 0;
    its.it_interval.tv_nsec = 50 * 1_000_000;
    its.it_value.tv_sec = 0;
    its.it_value.tv_nsec = 50 * 1_000_000;
    _ = c.timerfd_settime(timer_fd, 0, &its, null);

    const display_fd = c.wl_display_get_fd(app.display.?);
    const sig_fd = createSigUsr1Fd();
    defer {
        if (sig_fd >= 0) _ = c.close(sig_fd);
    }

    const poll_fds = try allocator.alloc(c.struct_pollfd, 3 + key_overlay.input_fds.items.len);
    defer allocator.free(poll_fds);

    while (app.running and key_overlay.running and !quit_requested) {
        while (c.wl_display_prepare_read(app.display.?) != 0) {
            _ = c.wl_display_dispatch_pending(app.display.?);
        }
        _ = c.wl_display_flush(app.display.?);

        poll_fds[0] = .{ .fd = display_fd, .events = c.POLLIN, .revents = 0 };
        poll_fds[1] = .{ .fd = timer_fd, .events = c.POLLIN, .revents = 0 };
        poll_fds[2] = .{ .fd = if (sig_fd >= 0) sig_fd else -1, .events = c.POLLIN, .revents = 0 };
        for (key_overlay.input_fds.items, 0..) |fd, i| {
            poll_fds[3 + i] = .{ .fd = fd, .events = c.POLLIN, .revents = 0 };
        }

        const poll_res = c.poll(poll_fds.ptr, @intCast(poll_fds.len), -1);
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

        if (poll_fds[1].revents & c.POLLIN != 0) {
            var exp: u64 = 0;
            _ = c.read(timer_fd, &exp, @sizeOf(u64));
            if (key_overlay.checkExpiry()) {
                app.needs_redraw = true;
            }
        }

        if (sig_fd >= 0 and (poll_fds[2].revents & c.POLLIN != 0)) {
            var fdsi: c.struct_signalfd_siginfo = undefined;
            _ = c.read(sig_fd, &fdsi, @sizeOf(c.struct_signalfd_siginfo));
            if (key_overlay.tick()) {
                app.needs_redraw = true;
            }
        }

        for (key_overlay.input_fds.items, 0..) |fd, i| {
            if (poll_fds[3 + i].revents & c.POLLIN != 0) {
                if (key_overlay.handleInput(fd)) {
                    app.needs_redraw = true;
                }
            }
        }

        if (app.needs_redraw) {
            app.redraw() catch |err| {
                std.debug.print("KeyOverlay redraw error: {any}\n", .{err});
            };
            _ = c.wl_display_flush(app.display.?);
            app.needs_redraw = false;
        }
    }
}

fn runLock(allocator: std.mem.Allocator, cfg: config.Config) !void {
    try lock_module.runLock(allocator, cfg);
}
