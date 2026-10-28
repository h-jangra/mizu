const std = @import("std");
const c = @import("../c.zig").c;
const theme = @import("../core/theme.zig");
const config = @import("../core/config.zig");
const renderer = @import("../core/renderer.zig");
const text_input = @import("../core/text_input.zig");
const ui_mod = @import("../core/ui.zig");
const desktop_entry = @import("../services/desktop_entries.zig");
const calc = @import("launcher_calculator.zig");
const file_search = @import("launcher_file_search.zig");
const sys_status = @import("../services/system_status.zig");
const icons = @import("../graphics/icons.zig");

pub const Mode = enum {
    app,
    action,
    command,
    calc,
    files,

    pub fn icon(self: Mode) []const u8 {
        return switch (self) {
            .app => "󰍉 ",
            .action => "󰘳 ",
            .command => " ",
            .calc => "󰪚 ",
            .files => "󰉋 ",
        };
    }

    pub fn svgIcon(self: Mode) []const u8 {
        return switch (self) {
            .app => "search",
            .action => "command",
            .command => "terminal",
            .calc => "calculator",
            .files => "folder",
        };
    }

    pub fn placeholder(self: Mode) []const u8 {
        return switch (self) {
            .app => "Search applications...",
            .action => "Mizu action or command (e.g. theme, lock, power)...",
            .command => "Execute shell command...",
            .calc => "Calculate expression (e.g. 125 / 5)...",
            .files => "Search files or browse (/path)...",
        };
    }
};

pub const ActionType = enum {
    launch_app,
    shell_command,
    terminal_cmd,
    copy_clipboard,
    open_file,
    mizu_action,
};

pub const GenericItem = struct {
    icon: ?[]const u8 = null,
    title: []const u8,
    description: []const u8,
    action_data: []const u8,
    action_type: ActionType,
    badge: ?[]const u8 = null,
    is_history: bool = false,
    owns_strings: bool = true,
    app: ?*const desktop_entry.DesktopApp = null,

    pub fn deinit(self: *GenericItem, allocator: std.mem.Allocator) void {
        if (self.owns_strings) {
            allocator.free(self.title);
            allocator.free(self.description);
            allocator.free(self.action_data);
        }
    }
};

pub const MizuAction = struct {
    icon: []const u8,
    title: []const u8,
    desc: []const u8,
    cmd: []const u8,
    destructive: bool = false,
};

pub const MIZU_ACTIONS = [_]MizuAction{
    .{ .icon = "󰏘 ", .title = "Theme: Next Theme", .desc = "Cycle to next desktop color scheme", .cmd = "mizu theme next" },
    .{ .icon = "󰏘 ", .title = "Theme: Previous Theme", .desc = "Cycle to previous desktop color scheme", .cmd = "mizu theme prev" },
    .{ .icon = "󰏘 ", .title = "Theme: Frosted Neumorphic", .desc = "Clean glassy neumorphic aesthetic", .cmd = "mizu theme set frosted_neumorphic" },
    .{ .icon = "󰏘 ", .title = "Theme: Nord Frost", .desc = "Arctic north-bluish palette", .cmd = "mizu theme set nord" },
    .{ .icon = "󰏘 ", .title = "Theme: Catppuccin Mocha", .desc = "Soothing pastel theme for high-spirited minds", .cmd = "mizu theme set catppuccin_mocha" },
    .{ .icon = "󰏘 ", .title = "Theme: Tokyo Night", .desc = "Clean neon cyberpunk night in Shibuya", .cmd = "mizu theme set tokyo_night" },
    .{ .icon = "󰏘 ", .title = "Theme: Rosé Pine", .desc = "All natural pine, faux fur and delicate bougainvillea", .cmd = "mizu theme set rose_pine" },
    .{ .icon = "󰒓 ", .title = "Quick Settings", .desc = "Open quick settings control panel", .cmd = "mizu quicksettings" },
    .{ .icon = "󰍛 ", .title = "System Monitor", .desc = "Open live system & process monitor", .cmd = "mizu system-monitor" },
    .{ .icon = " ", .title = "Calendar", .desc = "Open interactive calendar popup", .cmd = "mizu calendar" },
    .{ .icon = "󰅍 ", .title = "Clipboard History", .desc = "Open clipboard history search & manager", .cmd = "mizu clipboard" },
    .{ .icon = "󰌌 ", .title = "Keybindings Overlay", .desc = "Show keyboard shortcuts cheat sheet", .cmd = "mizu keyoverlay" },
    .{ .icon = " ", .title = "Lock Screen", .desc = "Lock current session with native screen locker", .cmd = "mizu lock" },
    .{ .icon = "󰤄 ", .title = "Suspend System", .desc = "Suspend computer to sleep", .cmd = "systemctl suspend" },
    .{ .icon = "󰜉 ", .title = "Restart Computer", .desc = "Reboot computer", .cmd = "systemctl reboot", .destructive = true },
    .{ .icon = " ", .title = "Power Off", .desc = "Shut down computer", .cmd = "systemctl poweroff", .destructive = true },
    .{ .icon = "󰍃 ", .title = "Log Out", .desc = "Exit current Wayland desktop session", .cmd = "loginctl terminate-user $USER", .destructive = true },
};

pub fn isDestructiveAction(cmd: []const u8) bool {
    for (MIZU_ACTIONS) |act| {
        if (std.mem.eql(u8, act.cmd, cmd) and act.destructive) {
            return true;
        }
    }
    return false;
}

pub fn isAutoCalcExpression(input: []const u8) bool {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return false;

    // Prefixes are not auto-detected; they are handled explicitly
    if (trimmed[0] == '>' or trimmed[0] == '/' or trimmed[0] == '=' or trimmed[0] == ':') return false;

    // Must contain arithmetic operator, parentheses, or math functions
    var has_math_op = false;
    for (trimmed) |ch| {
        switch (ch) {
            '+', '*', '/', '^', '%' => {
                has_math_op = true;
                break;
            },
            '(', ')' => {
                has_math_op = true;
                break;
            },
            else => {},
        }
    }

    if (!has_math_op) {
        if (std.mem.indexOfScalar(u8, trimmed, '-')) |dash_idx| {
            if (dash_idx > 0 and dash_idx + 1 < trimmed.len) {
                has_math_op = true;
            }
        }
    }

    if (!has_math_op) {
        const math_prefixes = [_][]const u8{
            "sqrt", "sin", "cos", "tan", "asin", "acos", "atan", "log", "ln", "abs", "floor", "ceil",
        };
        for (math_prefixes) |pfx| {
            if (std.mem.startsWith(u8, trimmed, pfx)) {
                has_math_op = true;
                break;
            }
        }
    }

    if (!has_math_op) return false;

    if (calc.evaluate(trimmed)) |_| {
        return true;
    } else |_| {
        return false;
    }
}

pub const IconCache = struct {
    allocator: std.mem.Allocator,
    surfaces: std.StringHashMap(?*renderer.Image),

    pub fn init(allocator: std.mem.Allocator) IconCache {
        return .{
            .allocator = allocator,
            .surfaces = std.StringHashMap(?*renderer.Image).init(allocator),
        };
    }

    pub fn deinit(self: *IconCache) void {
        var it = self.surfaces.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*) |surf| {
                surf.deinit();
            }
            self.allocator.free(entry.key_ptr.*);
        }
        self.surfaces.deinit();
    }

    pub fn getIconSurface(self: *IconCache, icon_name: ?[]const u8) ?*renderer.Image {
        const raw_name = icon_name orelse return null;
        if (raw_name.len == 0) return null;

        // Check if already in cache (both successful and failed lookups)
        if (self.surfaces.getEntry(raw_name)) |entry| {
            return entry.value_ptr.*;
        }

        const surf = self.loadIconSurface(raw_name);
        const dup_key = self.allocator.dupe(u8, raw_name) catch return surf;
        self.surfaces.put(dup_key, surf) catch {
            self.allocator.free(dup_key);
        };
        return surf;
    }

    pub fn getCachedOnly(self: *const IconCache, icon_name: ?[]const u8) ?*renderer.Image {
        const raw_name = icon_name orelse return null;
        if (raw_name.len == 0) return null;
        if (self.surfaces.get(raw_name)) |surf| {
            return surf;
        }
        return null;
    }

    fn tryLoadFile(allocator: std.mem.Allocator, path: []const u8) ?*renderer.Image {
        return renderer.Image.loadPng(allocator, path) catch null;
    }

    fn loadIconSurface(self: *IconCache, name: []const u8) ?*renderer.Image {
        if (name.len == 0) return null;

        // 1. Direct path
        if (name[0] == '/') {
            if (tryLoadFile(self.allocator, name)) |s| return s;
            var buf: [512]u8 = undefined;
            if (!std.mem.endsWith(u8, name, ".png")) {
                const with_png = std.fmt.bufPrint(&buf, "{s}.png", .{name}) catch null;
                if (with_png) |p| {
                    if (tryLoadFile(self.allocator, p)) |s| return s;
                }
            }
            return null;
        }

        // 2. Strip extension if given
        var base_name = name;
        if (std.mem.endsWith(u8, base_name, ".png")) {
            base_name = base_name[0 .. base_name.len - 4];
        } else if (std.mem.endsWith(u8, base_name, ".svg")) {
            base_name = base_name[0 .. base_name.len - 4];
        }

        const search_dirs = [_][]const u8{
            "/usr/share/icons/hicolor/48x48/apps",
            "/usr/share/icons/hicolor/64x64/apps",
            "/usr/share/icons/hicolor/128x128/apps",
            "/usr/share/icons/hicolor/32x32/apps",
            "/usr/share/icons/hicolor/256x256/apps",
            "/usr/share/icons/hicolor/scalable/apps",
            "/usr/share/pixmaps",
        };

        var path_buf: [512]u8 = undefined;
        var lower_buf: [128]u8 = undefined;
        const lower_name = if (base_name.len <= lower_buf.len)
            std.ascii.lowerString(&lower_buf, base_name)
        else
            base_name;

        for (search_dirs) |dir| {
            if (std.fmt.bufPrint(&path_buf, "{s}/{s}.png", .{ dir, base_name })) |p| {
                if (tryLoadFile(self.allocator, p)) |s| return s;
            } else |_| {}

            if (!std.mem.eql(u8, base_name, lower_name)) {
                if (std.fmt.bufPrint(&path_buf, "{s}/{s}.png", .{ dir, lower_name })) |p| {
                    if (tryLoadFile(self.allocator, p)) |s| return s;
                } else |_| {}
            }
        }

        return null;
    }
};

fn spawnDirect(argv: []const [*:0]const u8) void {
    if (argv.len == 0) return;
    const pid = c.fork();
    if (pid == 0) {
        const grandchild = c.fork();
        if (grandchild == 0) {
            _ = c.setsid();
            const dev_null = c.open("/dev/null", c.O_RDWR);
            if (dev_null >= 0) {
                _ = c.dup2(dev_null, 0);
                _ = c.dup2(dev_null, 1);
                _ = c.dup2(dev_null, 2);
                if (dev_null > 2) _ = c.close(dev_null);
            }

            var argv_ptrs: [64]?[*:0]const u8 = undefined;
            const count = @min(argv.len, argv_ptrs.len - 1);
            for (0..count) |i| {
                argv_ptrs[i] = argv[i];
            }
            argv_ptrs[count] = null;

            _ = c.execvp(argv[0], @ptrCast(&argv_ptrs));
            c.exit(1);
        }
        c.exit(0);
    } else if (pid > 0) {
        var status: c_int = 0;
        _ = c.waitpid(pid, &status, 0);
    }
}

pub fn isCommandAvailable(cmd: []const u8) bool {
    if (cmd.len == 0) return false;
    if (cmd[0] == '/') {
        var buf: [512]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{cmd}, 0) catch return false;
        return c.access(z.ptr, c.X_OK) == 0;
    }
    const path_env = c.getenv("PATH") orelse return false;
    const path_str = std.mem.span(path_env);
    var it = std.mem.splitScalar(u8, path_str, ':');
    var buf: [512]u8 = undefined;
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full_path = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ dir, cmd }, 0) catch continue;
        if (c.access(full_path.ptr, c.X_OK) == 0) return true;
    }
    return false;
}

pub fn resolveTerminal(cfg: *const config.Config) []const u8 {
    if (cfg.terminal) |t| {
        const trimmed = std.mem.trim(u8, t, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }
    if (c.getenv("TERMINAL")) |t_env| {
        const t_span = std.mem.span(t_env);
        const trimmed = std.mem.trim(u8, t_span, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }
    const candidates = [_][]const u8{
        "foot",
        "alacritty",
        "kitty",
        "ghostty",
        "wezterm",
        "gnome-terminal",
        "konsole",
        "xfce4-terminal",
        "xterm",
    };
    for (candidates) |cand| {
        if (isCommandAvailable(cand)) return cand;
    }
    return "foot";
}

fn parseAndSpawnApp(allocator: std.mem.Allocator, exec: []const u8, in_terminal: bool, term: []const u8) void {
    const trimmed = std.mem.trim(u8, exec, " \t\r\n");
    if (trimmed.len == 0) return;

    var tokens = std.ArrayList([*:0]u8).empty;
    defer {
        for (tokens.items) |t| allocator.free(std.mem.span(t));
        tokens.deinit(allocator);
    }

    if (in_terminal) {
        const term_str = allocator.dupeSentinel(u8, term, 0) catch return;
        tokens.append(allocator, term_str) catch return;
        const e_flag = allocator.dupeSentinel(u8, "-e", 0) catch return;
        tokens.append(allocator, e_flag) catch return;
    }

    var i: usize = 0;
    while (i < trimmed.len) {
        while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t')) : (i += 1) {}
        if (i >= trimmed.len) break;

        var token_buf = std.ArrayList(u8).empty;
        defer token_buf.deinit(allocator);

        var quote_char: ?u8 = null;
        while (i < trimmed.len) {
            const ch = trimmed[i];
            if (quote_char) |q| {
                if (ch == q) {
                    quote_char = null;
                } else {
                    token_buf.append(allocator, ch) catch break;
                }
            } else {
                if (ch == '\'' or ch == '"') {
                    quote_char = ch;
                } else if (ch == ' ' or ch == '\t') {
                    break;
                } else {
                    token_buf.append(allocator, ch) catch break;
                }
            }
            i += 1;
        }

        if (token_buf.items.len > 0) {
            const tok_z = allocator.dupeSentinel(u8, token_buf.items, 0) catch break;
            tokens.append(allocator, tok_z) catch {
                allocator.free(tok_z);
                break;
            };
        }
    }

    if (tokens.items.len == 0) return;

    var argv: [64][*:0]const u8 = undefined;
    const count = @min(tokens.items.len, argv.len);
    for (0..count) |idx| {
        argv[idx] = tokens.items[idx];
    }

    spawnDirect(argv[0..count]);
}

fn openFileDirect(allocator: std.mem.Allocator, path: []const u8) void {
    const path_z = allocator.dupeSentinel(u8, path, 0) catch return;
    defer allocator.free(path_z);

    const xdg_open_z = "xdg-open";
    const argv = [_][*:0]const u8{
        xdg_open_z,
        path_z.ptr,
    };
    spawnDirect(&argv);
}

fn spawnShellCommand(allocator: std.mem.Allocator, cmd: []const u8, in_terminal: bool, term: []const u8) void {
    const trimmed = std.mem.trim(u8, cmd, " \t\r\n");
    if (trimmed.len == 0) return;

    if (in_terminal) {
        var term_buf: [1024]u8 = undefined;
        const full_cmd = std.fmt.bufPrint(&term_buf, "{s}; echo; printf 'Press Enter to exit... '; read _", .{trimmed}) catch return;
        const full_cmd_z = allocator.dupeSentinel(u8, full_cmd, 0) catch return;
        defer allocator.free(full_cmd_z);
        const term_z = allocator.dupeSentinel(u8, term, 0) catch return;
        defer allocator.free(term_z);

        const argv = [_][*:0]const u8{
            term_z.ptr,
            "-e",
            "sh",
            "-c",
            full_cmd_z.ptr,
        };
        spawnDirect(&argv);
    } else {
        sys_status.spawnCmd(trimmed);
    }
}

fn copyToClipboard(text: []const u8) void {
    if (text.len == 0) return;
    const pid = c.fork();
    if (pid == 0) {
        const grandchild = c.fork();
        if (grandchild == 0) {
            _ = c.setsid();
            var pfd: [2]c_int = undefined;
            if (c.pipe(&pfd) == 0) {
                const pipe_pid = c.fork();
                if (pipe_pid == 0) {
                    _ = c.close(pfd[1]);
                    _ = c.dup2(pfd[0], 0);
                    _ = c.close(pfd[0]);
                    const dev_null = c.open("/dev/null", c.O_WRONLY);
                    if (dev_null >= 0) {
                        _ = c.dup2(dev_null, 1);
                        _ = c.dup2(dev_null, 2);
                        if (dev_null > 2) _ = c.close(dev_null);
                    }
                    _ = c.execlp("wl-copy", "wl-copy", @as(?*anyopaque, null));
                    c.exit(1);
                } else if (pipe_pid > 0) {
                    _ = c.close(pfd[0]);
                    _ = c.write(pfd[1], text.ptr, text.len);
                    _ = c.close(pfd[1]);
                    var status: c_int = 0;
                    _ = c.waitpid(pipe_pid, &status, 0);
                }
            }
            c.exit(0);
        }
        c.exit(0);
    } else if (pid > 0) {
        var status: c_int = 0;
        _ = c.waitpid(pid, &status, 0);
    }
}

/// Map built-in glyph symbols to SVG asset names.
fn builtinSvgIcon(icon: []const u8) ?[]const u8 {
    const glyph = std.mem.trim(u8, icon, " ");
    if (std.mem.eql(u8, glyph, "\u{f03d8}")) return "palette";
    if (std.mem.eql(u8, glyph, "\u{f0493}")) return "monitor";
    if (std.mem.eql(u8, glyph, "\u{f07f}")) return "calendar";
    if (std.mem.eql(u8, glyph, "\u{f014d}")) return "clipboard";
    if (std.mem.eql(u8, glyph, "\u{f030c}")) return "keyboard";
    if (std.mem.eql(u8, glyph, "\u{f023}")) return "lock";
    if (std.mem.eql(u8, glyph, "\u{f0904}")) return "moon";
    if (std.mem.eql(u8, glyph, "\u{f0709}")) return "restart";
    if (std.mem.eql(u8, glyph, "\u{f011}")) return "power";
    if (std.mem.eql(u8, glyph, "\u{f0343}")) return "logout";
    if (std.mem.eql(u8, glyph, "\u{f120}")) return "terminal";
    if (std.mem.eql(u8, glyph, "\u{f018d}")) return "terminal";
    if (std.mem.eql(u8, glyph, "\u{f0a9a}")) return "calculator";
    if (std.mem.eql(u8, glyph, "\u{f01da}")) return "refresh";
    return null;
}

fn getHistoryFilePath(buf: []u8) ?[]const u8 {
    const home = c.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.cache/mizu/command_history", .{std.mem.span(home)}) catch null;
}

fn loadCommandHistory(allocator: std.mem.Allocator) std.ArrayList([]const u8) {
    var history = std.ArrayList([]const u8).empty;
    var path_buf: [512]u8 = undefined;
    const path = getHistoryFilePath(&path_buf) orelse return history;

    var path_z_buf: [512]u8 = undefined;
    const path_z = std.fmt.bufPrintSentinel(&path_z_buf, "{s}", .{path}, 0) catch return history;

    const file = c.fopen(path_z.ptr, "r") orelse return history;
    defer _ = c.fclose(file);

    var line_buf: [1024]u8 = undefined;
    while (c.fgets(&line_buf, @intCast(line_buf.len), file)) |line_ptr| {
        const raw_line = std.mem.span(line_ptr);
        const trimmed = std.mem.trim(u8, raw_line, " \t\r\n");
        if (trimmed.len == 0) continue;

        var dup = false;
        for (history.items) |existing| {
            if (std.mem.eql(u8, existing, trimmed)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;

        const cmd_copy = allocator.dupe(u8, trimmed) catch continue;
        history.append(allocator, cmd_copy) catch {
            allocator.free(cmd_copy);
            break;
        };
        if (history.items.len >= 100) break;
    }

    return history;
}

fn saveCommandHistoryToFile(history: []const []const u8) void {
    const home = c.getenv("HOME") orelse return;
    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintSentinel(&dir_buf, "{s}/.cache/mizu", .{std.mem.span(home)}, 0) catch return;
    _ = c.mkdir(dir_path.ptr, 0o755);

    var path_buf: [512]u8 = undefined;
    const path_z = std.fmt.bufPrintSentinel(&path_buf, "{s}/.cache/mizu/command_history", .{std.mem.span(home)}, 0) catch return;

    const file = c.fopen(path_z.ptr, "w") orelse return;
    defer _ = c.fclose(file);

    for (history) |cmd| {
        _ = c.fputs(cmd.ptr, file);
        _ = c.fputc('\n', file);
    }
}

fn getCalcHistoryFilePath(buf: []u8) ?[]const u8 {
    const home = c.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.cache/mizu/calc_history", .{std.mem.span(home)}) catch null;
}

fn loadCalcHistory(allocator: std.mem.Allocator) std.ArrayList([]const u8) {
    var history = std.ArrayList([]const u8).empty;
    var path_buf: [512]u8 = undefined;
    const path = getCalcHistoryFilePath(&path_buf) orelse return history;

    var path_z_buf: [512]u8 = undefined;
    const path_z = std.fmt.bufPrintSentinel(&path_z_buf, "{s}", .{path}, 0) catch return history;

    const file = c.fopen(path_z.ptr, "r") orelse return history;
    defer _ = c.fclose(file);

    var line_buf: [1024]u8 = undefined;
    while (c.fgets(&line_buf, @intCast(line_buf.len), file)) |line_ptr| {
        const raw_line = std.mem.span(line_ptr);
        const trimmed = std.mem.trim(u8, raw_line, " \t\r\n");
        if (trimmed.len == 0) continue;

        var dup = false;
        for (history.items) |existing| {
            if (std.mem.eql(u8, existing, trimmed)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;

        const copy = allocator.dupe(u8, trimmed) catch continue;
        history.append(allocator, copy) catch {
            allocator.free(copy);
            break;
        };
        if (history.items.len >= 100) break;
    }

    return history;
}

fn saveCalcHistoryToFile(history: []const []const u8) void {
    const home = c.getenv("HOME") orelse return;
    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintSentinel(&dir_buf, "{s}/.cache/mizu", .{std.mem.span(home)}, 0) catch return;
    _ = c.mkdir(dir_path.ptr, 0o755);

    var path_buf: [512]u8 = undefined;
    const path_z = std.fmt.bufPrintSentinel(&path_buf, "{s}/.cache/mizu/calc_history", .{std.mem.span(home)}, 0) catch return;

    const file = c.fopen(path_z.ptr, "w") orelse return;
    defer _ = c.fclose(file);

    for (history) |entry| {
        _ = c.fputs(entry.ptr, file);
        _ = c.fputc('\n', file);
    }
}

pub const MODE_SERIES = [_]Mode{ .app, .command, .action, .files, .calc };

const InputDraw = struct {
    input: *text_input.TextInput,
    font: *renderer.Font,
    text_color: theme.Color,
    placeholder_color: theme.Color,
    accent_color: theme.Color,
    size: u32,

    fn draw(target: renderer.Renderer, rect: renderer.Rect, data: *const anyopaque) void {
        const self: *const InputDraw = @ptrCast(@alignCast(data));
        self.input.render(
            target,
            self.font,
            rect.x,
            rect.y,
            rect.w,
            rect.h,
            rect.x,
            self.text_color,
            self.placeholder_color,
            self.accent_color,
            self.size,
        );
    }
};

var initial_buf: [1]u8 = undefined;

fn initialFor(title: []const u8) []const u8 {
    var view = std.unicode.Utf8View.init(title) catch return "?";
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp > 32) {
            initial_buf[0] = std.ascii.toUpper(@as(u8, @truncate(cp)));
            return initial_buf[0..1];
        }
    }
    return "?";
}

pub const Launcher = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    font: renderer.Font,
    icon_cache: IconCache,
    mode: Mode = .app,
    apps: std.ArrayList(desktop_entry.DesktopApp),
    results: std.ArrayList(desktop_entry.SearchResult),
    items: std.ArrayList(GenericItem),
    cmd_history: std.ArrayList([]const u8),
    calc_history: std.ArrayList([]const u8),
    input: text_input.TextInput,
    selected_index: usize = 0,
    hover_index: ?usize = null,
    hover_trash: bool = false,
    confirm_index: ?usize = null,

    width: u32 = 680,
    height: u32 = 520,

    grid_cols: usize = 5,
    grid_rows: usize = 4,
    list_rows: usize = 7,

    running: bool = true,

    pub const OUTER_PAD: i32 = 20;
    pub const INPUT_H: u32 = 48;
    pub const INPUT_GAP: i32 = 12;
    pub const ROW_H: u32 = 52;
    pub const ROW_GAP: i32 = 6;
    pub const CORNER_RADIUS: u32 = 16;
    pub const GRID_COLS: usize = 5;
    pub const GRID_ROW_H: u32 = 96;
    pub const GRID_GAP: i32 = 10;
    pub const GRID_ICON_SIZE: u32 = 48;

    pub const CardRect = struct { x: i32, y: i32, w: u32, h: u32 };

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !Launcher {
        const font = try renderer.Font.init(allocator, cfg.theme.font_family, cfg.typography.ui);
        const icon_cache = IconCache.init(allocator);

        // Discover and cache all desktop apps once
        const apps = try desktop_entry.discoverApplications(allocator);

        var self = Launcher{
            .allocator = allocator,
            .cfg = cfg,
            .font = font,
            .icon_cache = icon_cache,
            .apps = apps,
            .results = std.ArrayList(desktop_entry.SearchResult).empty,
            .items = std.ArrayList(GenericItem).empty,
            .cmd_history = loadCommandHistory(allocator),
            .calc_history = loadCalcHistory(allocator),
            .input = text_input.TextInput.init(allocator, Mode.app.placeholder(), false),
        };

        self.updateDimensions(0, 0);
        try self.updateResults();

        return self;
    }

    pub fn deinit(self: *Launcher) void {
        self.clearItems();
        self.items.deinit(self.allocator);
        for (self.calc_history.items) |item| {
            self.allocator.free(item);
        }
        self.calc_history.deinit(self.allocator);
        for (self.cmd_history.items) |cmd| {
            self.allocator.free(cmd);
        }
        self.cmd_history.deinit(self.allocator);
        self.results.deinit(self.allocator);
        self.input.deinit();
        for (self.apps.items) |*app| {
            app.deinit(self.allocator);
        }
        self.apps.deinit(self.allocator);
        self.icon_cache.deinit();
        self.font.deinit();
    }

    pub fn getTrashRect(self: *const Launcher, row: usize) CardRect {
        const card = self.getListCardRect(row);
        const sz: u32 = 28;
        const x = card.x + @as(i32, @intCast(card.w)) - 10 - @as(i32, @intCast(sz));
        const y = card.y + @as(i32, @intCast((card.h - sz) / 2));
        return .{ .x = x, .y = y, .w = sz, .h = sz };
    }

    pub fn isTrashAt(self: *const Launcher, row: usize, x: i32, y: i32) bool {
        const r = self.getTrashRect(row);
        return (x >= r.x and x < r.x + @as(i32, @intCast(r.w)) and
            y >= r.y and y < r.y + @as(i32, @intCast(r.h)));
    }

    pub fn addCalcHistory(self: *Launcher, expr: []const u8, result: []const u8) !void {
        const trimmed_expr = std.mem.trim(u8, expr, " \t\r\n");
        const trimmed_res = std.mem.trim(u8, result, " \t\r\n");
        if (trimmed_expr.len == 0 or trimmed_res.len == 0) return;

        var full_buf: [256]u8 = undefined;
        const entry_str = try std.fmt.bufPrint(&full_buf, "{s} = {s}", .{ trimmed_expr, trimmed_res });

        var idx: ?usize = null;
        for (self.calc_history.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, entry_str) or std.mem.startsWith(u8, existing, trimmed_expr)) {
                idx = i;
                break;
            }
        }
        if (idx) |i| {
            const removed = self.calc_history.orderedRemove(i);
            self.allocator.free(removed);
        }

        const copy = try self.allocator.dupe(u8, entry_str);
        try self.calc_history.insert(self.allocator, 0, copy);

        while (self.calc_history.items.len > 100) {
            const popped = self.calc_history.pop();
            if (popped) |p| {
                self.allocator.free(p);
            }
        }

        saveCalcHistoryToFile(self.calc_history.items);
    }

    pub fn removeCalcHistory(self: *Launcher, entry: []const u8) !void {
        const trimmed = std.mem.trim(u8, entry, " \t\r\n");
        var idx: ?usize = null;
        for (self.calc_history.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, trimmed) or
                std.mem.indexOf(u8, existing, trimmed) != null or
                std.mem.indexOf(u8, trimmed, existing) != null)
            {
                idx = i;
                break;
            }
        }
        if (idx) |i| {
            const removed = self.calc_history.orderedRemove(i);
            self.allocator.free(removed);
            saveCalcHistoryToFile(self.calc_history.items);
        }
    }

    pub fn removeCommandHistory(self: *Launcher, cmd: []const u8) !void {
        const trimmed = std.mem.trim(u8, cmd, " \t\r\n");
        var idx: ?usize = null;
        for (self.cmd_history.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, trimmed)) {
                idx = i;
                break;
            }
        }
        if (idx) |i| {
            const removed = self.cmd_history.orderedRemove(i);
            self.allocator.free(removed);
            saveCommandHistoryToFile(self.cmd_history.items);
        }
    }

    pub fn removeFromHistory(self: *Launcher, item_idx: usize) !void {
        if (item_idx >= self.items.items.len) return;
        const item = self.items.items[item_idx];
        if (!item.is_history) return;

        const effective = self.effectiveMode();
        if (effective == .command) {
            try self.removeCommandHistory(item.action_data);
        } else if (effective == .calc) {
            try self.removeCalcHistory(item.title);
        }

        try self.updateResults();
        if (self.selected_index >= self.items.items.len and self.selected_index > 0) {
            self.selected_index = self.items.items.len - 1;
        }
        self.hover_trash = false;
    }

    pub fn isGridView(self: *const Launcher) bool {
        return self.effectiveMode() == .app;
    }

    pub fn getItemsPerPage(self: *const Launcher) usize {
        if (self.isGridView()) {
            return self.grid_cols * self.grid_rows;
        } else {
            return self.list_rows;
        }
    }

    pub fn updateDimensions(self: *Launcher, output_w: u32, output_h: u32) void {
        if (output_w > 0 and output_h > 0) {
            const max_w = @min(@as(u32, 760), if (output_w > 40) output_w - 40 else output_w);
            const max_h = @min((output_h * 75) / 100, output_h);
            self.width = @min(@as(u32, 680), max_w);
            self.height = @min(@as(u32, 520), max_h);
        } else {
            self.width = 680;
            self.height = 520;
        }

        const top_used: u32 = @as(u32, @intCast(OUTER_PAD)) + INPUT_H + @as(u32, @intCast(INPUT_GAP));
        const bottom_used: u32 = 20;
        const avail_h = if (self.height > top_used + bottom_used) self.height - top_used - bottom_used else ROW_H;
        const row_step: u32 = ROW_H + @as(u32, @intCast(ROW_GAP));
        self.list_rows = @max(1, (avail_h + @as(u32, @intCast(ROW_GAP))) / row_step);

        const grid_step: u32 = GRID_ROW_H + @as(u32, @intCast(GRID_GAP));
        self.grid_rows = @max(1, (avail_h + @as(u32, @intCast(GRID_GAP))) / grid_step);

        const avail_w = if (self.width > @as(u32, @intCast(OUTER_PAD * 2))) self.width - @as(u32, @intCast(OUTER_PAD * 2)) else self.width;
        if (avail_w >= 580) {
            self.grid_cols = 5;
        } else if (avail_w >= 440) {
            self.grid_cols = 4;
        } else {
            self.grid_cols = 3;
        }
    }

    fn clearItems(self: *Launcher) void {
        for (self.items.items) |*item| {
            item.deinit(self.allocator);
        }
        self.items.clearRetainingCapacity();
    }

    pub fn tick(self: *Launcher) void {
        self.input.toggleCaret();
        if (theme.loadSavedTheme()) |saved| {
            if (saved != self.cfg.theme.kind) {
                self.cfg.theme = saved.toTheme();
            }
        }
    }

    pub fn setMode(self: *Launcher, new_mode: Mode) void {
        if (self.mode == new_mode) return;
        self.mode = new_mode;
        self.input.placeholder = new_mode.placeholder();
        self.input.clear();
        self.selected_index = 0;
        self.hover_index = null;
        self.confirm_index = null;
    }

    pub fn addHistory(self: *Launcher, cmd: []const u8) !void {
        const trimmed = std.mem.trim(u8, cmd, " \t\r\n");
        if (trimmed.len == 0) return;

        var idx: ?usize = null;
        for (self.cmd_history.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, trimmed)) {
                idx = i;
                break;
            }
        }
        if (idx) |i| {
            const removed = self.cmd_history.orderedRemove(i);
            self.allocator.free(removed);
        }

        const cmd_copy = try self.allocator.dupe(u8, trimmed);
        try self.cmd_history.insert(self.allocator, 0, cmd_copy);

        while (self.cmd_history.items.len > 100) {
            const popped = self.cmd_history.pop();
            if (popped) |p| {
                self.allocator.free(p);
            }
        }

        saveCommandHistoryToFile(self.cmd_history.items);
    }

    pub fn cycleMode(self: *Launcher, reverse: bool) !void {
        const cur_mode = self.effectiveMode();
        var cur_idx: usize = 0;
        for (MODE_SERIES, 0..) |m, i| {
            if (m == cur_mode) {
                cur_idx = i;
                break;
            }
        }

        const next_idx = if (reverse)
            if (cur_idx == 0) MODE_SERIES.len - 1 else cur_idx - 1
        else
            (cur_idx + 1) % MODE_SERIES.len;

        const next_mode = MODE_SERIES[next_idx];

        const cur_text = self.input.getText();
        const trimmed = std.mem.trim(u8, cur_text, " \t\r\n");
        var clean_query = trimmed;
        if (clean_query.len > 0) {
            if (clean_query[0] == '>' or clean_query[0] == ':' or clean_query[0] == '/' or clean_query[0] == '=') {
                clean_query = std.mem.trim(u8, clean_query[1..], " \t\r\n");
            }
        }

        self.mode = next_mode;
        self.input.placeholder = next_mode.placeholder();
        self.input.clear();
        if (clean_query.len > 0) {
            try self.input.insertBytes(clean_query);
        }
        self.selected_index = 0;
        self.hover_index = null;
        self.confirm_index = null;
        try self.updateResults();
    }

    pub fn effectiveMode(self: *const Launcher) Mode {
        if (self.mode != .app) return self.mode;
        const trimmed = std.mem.trim(u8, self.input.getText(), " \t\r\n");
        if (trimmed.len > 0) {
            if (trimmed[0] == '>') return .command;
            if (trimmed[0] == ':') return .action;
            if (trimmed[0] == '=') return .calc;
            if (trimmed[0] == '/') return .files;
            if (isAutoCalcExpression(trimmed)) return .calc;
        }
        return .app;
    }

    pub fn preloadVisibleIcons(self: *Launcher) void {
        const page_offset = self.getPageOffset();
        const page_size = self.getItemsPerPage();
        var i: usize = 0;
        while (i < page_size) : (i += 1) {
            const idx = page_offset + i;
            if (idx >= self.items.items.len) break;
            const item = &self.items.items[idx];
            if (item.action_type == .launch_app and item.icon != null) {
                _ = self.icon_cache.getIconSurface(item.icon);
            }
        }
    }

    fn stripLeadingPrefix(input: []const u8, prefix: u8) []const u8 {
        var s = input;
        if (s.len > 0 and s[0] == prefix) {
            s = s[1..];
        }
        while (s.len > 0 and (s[0] == ' ' or s[0] == '\t')) : (s = s[1..]) {}
        return s;
    }

    pub fn updateResults(self: *Launcher) !void {
        self.clearItems();
        self.confirm_index = null;
        const raw_query = self.input.getText();
        const trimmed = std.mem.trim(u8, raw_query, " \t\r\n");

        if (self.mode == .app) {
            if (trimmed.len > 0) {
                if (trimmed[0] == '>') {
                    const stripped = stripLeadingPrefix(trimmed, '>');
                    try self.updateCommandResults(stripped);
                } else if (trimmed[0] == ':') {
                    const stripped = stripLeadingPrefix(trimmed, ':');
                    try self.updateActionResults(stripped);
                } else if (trimmed[0] == '=') {
                    const stripped = stripLeadingPrefix(trimmed, '=');
                    try self.updateCalcResults(stripped);
                } else if (trimmed[0] == '/') {
                    const stripped = stripLeadingPrefix(trimmed, '/');
                    try self.updateFileResults(stripped);
                } else if (isAutoCalcExpression(trimmed)) {
                    try self.updateCalcResults(trimmed);
                } else {
                    try self.updateAppResults(trimmed);
                }
            } else {
                try self.updateAppResults("");
            }
        } else if (self.mode == .command) {
            const stripped = stripLeadingPrefix(trimmed, '>');
            try self.updateCommandResults(stripped);
        } else if (self.mode == .action) {
            const stripped = stripLeadingPrefix(trimmed, ':');
            try self.updateActionResults(stripped);
        } else if (self.mode == .calc) {
            const stripped = stripLeadingPrefix(trimmed, '=');
            try self.updateCalcResults(stripped);
        } else if (self.mode == .files) {
            const stripped = stripLeadingPrefix(trimmed, '/');
            try self.updateFileResults(stripped);
        }

        if (self.items.items.len == 0) {
            self.selected_index = 0;
        } else if (self.selected_index >= self.items.items.len) {
            self.selected_index = self.items.items.len - 1;
        }
        self.hover_index = null;

        self.preloadVisibleIcons();
    }

    fn updateAppResults(self: *Launcher, query: []const u8) !void {
        try desktop_entry.searchApplicationsInto(
            self.allocator,
            self.apps.items,
            query,
            &self.results,
        );

        for (self.results.items) |res| {
            const app = res.app;
            try self.items.append(self.allocator, .{
                .icon = app.icon,
                .title = app.name,
                .description = "",
                .action_data = app.exec,
                .action_type = .launch_app,
                .badge = "App",
                .owns_strings = false,
                .app = app,
            });
        }
    }

    fn updateCommandResults(self: *Launcher, raw_cmd: []const u8) !void {
        const cmd = std.mem.trim(u8, raw_cmd, " \t\r\n");
        if (cmd.len == 0) {
            if (self.cmd_history.items.len == 0) {
                try self.items.append(self.allocator, .{
                    .icon = " ",
                    .title = "Execute Shell Command",
                    .description = "Type any shell command and press Enter to execute",
                    .action_data = "",
                    .action_type = .shell_command,
                    .badge = "Command",
                    .owns_strings = false,
                });
            } else {
                for (self.cmd_history.items) |hist_cmd| {
                    const title = try self.allocator.dupe(u8, hist_cmd);
                    const desc = try self.allocator.dupe(u8, "Recent command");
                    const act = try self.allocator.dupe(u8, hist_cmd);
                    try self.items.append(self.allocator, .{
                        .icon = " ",
                        .title = title,
                        .description = desc,
                        .action_data = act,
                        .action_type = .shell_command,
                        .badge = "History",
                        .is_history = true,
                        .owns_strings = true,
                    });
                }
            }
            return;
        }

        const bg_title = try std.fmt.allocPrint(self.allocator, "Run: {s}", .{cmd});
        const bg_desc = try std.fmt.allocPrint(self.allocator, "Execute in background (/bin/sh -c \"{s}\")", .{cmd});
        const bg_act = try self.allocator.dupe(u8, cmd);
        try self.items.append(self.allocator, .{
            .icon = " ",
            .title = bg_title,
            .description = bg_desc,
            .action_data = bg_act,
            .action_type = .shell_command,
            .badge = "Run",
            .owns_strings = true,
        });

        const term_title = try std.fmt.allocPrint(self.allocator, "Terminal: {s}", .{cmd});
        const term_desc = try std.fmt.allocPrint(self.allocator, "Execute interactively inside terminal", .{});
        const term_act = try self.allocator.dupe(u8, cmd);
        try self.items.append(self.allocator, .{
            .icon = "󰆍 ",
            .title = term_title,
            .description = term_desc,
            .action_data = term_act,
            .action_type = .terminal_cmd,
            .badge = "Terminal",
            .owns_strings = true,
        });

        for (self.cmd_history.items) |hist_cmd| {
            if (std.mem.indexOf(u8, hist_cmd, cmd) != null and !std.mem.eql(u8, hist_cmd, cmd)) {
                const title = try self.allocator.dupe(u8, hist_cmd);
                const desc = try self.allocator.dupe(u8, "Recent command");
                const act = try self.allocator.dupe(u8, hist_cmd);
                try self.items.append(self.allocator, .{
                    .icon = " ",
                    .title = title,
                    .description = desc,
                    .action_data = act,
                    .action_type = .shell_command,
                    .badge = "History",
                    .is_history = true,
                    .owns_strings = true,
                });
            }
        }
    }

    fn updateActionResults(self: *Launcher, raw_query: []const u8) !void {
        const query = std.mem.trim(u8, raw_query, " \t\r\n");

        for (MIZU_ACTIONS) |a| {
            if (query.len == 0 or file_search.matchPattern(query, a.title) or file_search.matchPattern(query, a.desc) or file_search.matchPattern(query, a.cmd)) {
                try self.items.append(self.allocator, .{
                    .icon = a.icon,
                    .title = a.title,
                    .description = a.desc,
                    .action_data = a.cmd,
                    .action_type = .mizu_action,
                    .badge = if (a.destructive) "Danger" else "Action",
                    .owns_strings = false,
                });
            }
        }

        for (self.cfg.panels.items) |p| {
            if (query.len == 0 or file_search.matchPattern(query, p.name) or file_search.matchPattern(query, p.command)) {
                try self.items.append(self.allocator, .{
                    .icon = "󰒓 ",
                    .title = p.name,
                    .description = p.command,
                    .action_data = p.command,
                    .action_type = .mizu_action,
                    .badge = "Panel",
                    .owns_strings = false,
                });
            }
        }
    }

    fn updateCalcResults(self: *Launcher, raw_expr: []const u8) !void {
        const expr = std.mem.trim(u8, raw_expr, " \t\r\n");
        if (expr.len == 0) {
            if (self.calc_history.items.len == 0) {
                try self.items.append(self.allocator, .{
                    .icon = "󰪚 ",
                    .title = "Calculator",
                    .description = "Enter math expression (e.g. 125 / 5, 2^10, sqrt(144), sin(pi/2))",
                    .action_data = "",
                    .action_type = .copy_clipboard,
                    .badge = "Calc",
                    .is_history = false,
                    .owns_strings = false,
                });
            } else {
                for (self.calc_history.items) |h_entry| {
                    var res_part = h_entry;
                    if (std.mem.lastIndexOf(u8, h_entry, " = ")) |eq_idx| {
                        res_part = h_entry[eq_idx + 3 ..];
                    }
                    const title = try self.allocator.dupe(u8, h_entry);
                    const desc = try std.fmt.allocPrint(self.allocator, "Press Enter to copy \"{s}\" to clipboard", .{res_part});
                    const act = try self.allocator.dupe(u8, res_part);
                    try self.items.append(self.allocator, .{
                        .icon = "󰪚 ",
                        .title = title,
                        .description = desc,
                        .action_data = act,
                        .action_type = .copy_clipboard,
                        .badge = "History",
                        .is_history = true,
                        .owns_strings = true,
                    });
                }
            }
            return;
        }

        if (calc.evaluate(expr)) |val| {
            var buf: [64]u8 = undefined;
            const res_str = calc.formatResult(&buf, val);

            const title = try std.fmt.allocPrint(self.allocator, "= {s}", .{res_str});
            const desc = try std.fmt.allocPrint(self.allocator, "Press Enter to copy \"{s}\" to clipboard", .{res_str});
            const act = try self.allocator.dupe(u8, res_str);

            try self.items.append(self.allocator, .{
                .icon = "󰪚 ",
                .title = title,
                .description = desc,
                .action_data = act,
                .action_type = .copy_clipboard,
                .badge = "Calc",
                .is_history = false,
                .owns_strings = true,
            });

            for (self.calc_history.items) |h_entry| {
                if (std.mem.indexOf(u8, h_entry, expr) != null) {
                    var res_part = h_entry;
                    if (std.mem.lastIndexOf(u8, h_entry, " = ")) |eq_idx| {
                        res_part = h_entry[eq_idx + 3 ..];
                    }
                    const h_title = try self.allocator.dupe(u8, h_entry);
                    const h_desc = try std.fmt.allocPrint(self.allocator, "Press Enter to copy \"{s}\" to clipboard", .{res_part});
                    const h_act = try self.allocator.dupe(u8, res_part);
                    try self.items.append(self.allocator, .{
                        .icon = "󰪚 ",
                        .title = h_title,
                        .description = h_desc,
                        .action_data = h_act,
                        .action_type = .copy_clipboard,
                        .badge = "History",
                        .is_history = true,
                        .owns_strings = true,
                    });
                }
            }
        } else |err| {
            const err_msg = switch (err) {
                error.DivisionByZero => "Error: Division by zero",
                error.DomainError => "Error: Value out of domain",
                error.MismatchedParentheses => "Error: Mismatched parentheses",
                error.ExpressionTooLong => "Error: Expression too long (>256 chars)",
                error.RecursionLimitExceeded => "Error: Recursion limit exceeded (>32 depth)",
                error.TooManyTokens => "Error: Too many tokens (>128 tokens)",
                else => "Waiting for complete expression...",
            };

            try self.items.append(self.allocator, .{
                .icon = "󰪚 ",
                .title = "= ...",
                .description = err_msg,
                .action_data = "",
                .action_type = .copy_clipboard,
                .badge = "Calc",
                .is_history = false,
                .owns_strings = false,
            });

            for (self.calc_history.items) |h_entry| {
                if (std.mem.indexOf(u8, h_entry, expr) != null) {
                    var res_part = h_entry;
                    if (std.mem.lastIndexOf(u8, h_entry, " = ")) |eq_idx| {
                        res_part = h_entry[eq_idx + 3 ..];
                    }
                    const h_title = try self.allocator.dupe(u8, h_entry);
                    const h_desc = try std.fmt.allocPrint(self.allocator, "Press Enter to copy \"{s}\" to clipboard", .{res_part});
                    const h_act = try self.allocator.dupe(u8, res_part);
                    try self.items.append(self.allocator, .{
                        .icon = "󰪚 ",
                        .title = h_title,
                        .description = h_desc,
                        .action_data = h_act,
                        .action_type = .copy_clipboard,
                        .badge = "History",
                        .is_history = true,
                        .owns_strings = true,
                    });
                }
            }
        }
    }

    fn updateFileResults(self: *Launcher, raw_query: []const u8) !void {
        const query = std.mem.trim(u8, raw_query, " \t\r\n");
        var file_entries = try file_search.searchFiles(self.allocator, query);
        defer {
            for (file_entries.items) |*entry| entry.deinit(self.allocator);
            file_entries.deinit(self.allocator);
        }

        for (file_entries.items) |entry| {
            const title = try self.allocator.dupe(u8, entry.name);
            const desc = try self.allocator.dupe(u8, entry.path);
            const act = try self.allocator.dupe(u8, entry.path);

            try self.items.append(self.allocator, .{
                .icon = entry.icon,
                .title = title,
                .description = desc,
                .action_data = act,
                .action_type = .open_file,
                .badge = if (entry.is_dir) "Folder" else "File",
                .owns_strings = true,
            });
        }
    }

    pub fn appendChar(self: *Launcher, ch: u8) !void {
        const slice = [_]u8{ch};
        try self.appendBytes(&slice);
    }

    pub fn appendBytes(self: *Launcher, bytes: []const u8) !void {
        if (self.mode == .app and self.input.getText().len == 0 and bytes.len > 0) {
            const first_char = bytes[0];
            const target_mode: ?Mode = switch (first_char) {
                '>' => .command,
                ':' => .action,
                '=' => .calc,
                '/' => .files,
                else => null,
            };
            if (target_mode) |m| {
                self.setMode(m);
                var rest = bytes[1..];
                while (rest.len > 0 and rest[0] == ' ') : (rest = rest[1..]) {}
                if (rest.len > 0) {
                    try self.input.insertBytes(rest);
                }
                try self.updateResults();
                return;
            }
        }

        try self.input.insertBytes(bytes);
        try self.updateResults();
    }

    pub fn backspace(self: *Launcher) !void {
        if (self.input.getText().len == 0) {
            if (self.mode != .app) {
                self.setMode(.app);
                try self.updateResults();
                return;
            }
        }
        try self.input.deleteBackward();
        try self.updateResults();
    }

    pub fn moveSelection(self: *Launcher, delta: i32) void {
        const total = self.items.items.len;
        if (total == 0) return;

        const old_page = self.getPageOffset();
        if (delta > 0) {
            const u_delta: usize = @intCast(delta);
            self.selected_index = (self.selected_index + u_delta) % total;
        } else if (delta < 0) {
            const u_delta: usize = @intCast(-delta);
            if (self.selected_index >= u_delta) {
                self.selected_index -= u_delta;
            } else {
                const rem = u_delta % total;
                self.selected_index = (self.selected_index + total - rem) % total;
            }
        }

        if (self.getPageOffset() != old_page) {
            self.preloadVisibleIcons();
        }
    }

    pub fn moveSelectionGrid(self: *Launcher, dir_row: i32, dir_col: i32) void {
        const total = self.items.items.len;
        if (total == 0) return;

        const old_page = self.getPageOffset();
        const cols = @max(1, self.grid_cols);

        if (total <= cols) {
            const delta = if (dir_col != 0) dir_col else dir_row;
            if (delta > 0) {
                self.selected_index = (self.selected_index + 1) % total;
            } else if (delta < 0) {
                self.selected_index = if (self.selected_index == 0) total - 1 else self.selected_index - 1;
            }
        } else {
            if (dir_col > 0) {
                self.selected_index = (self.selected_index + 1) % total;
            } else if (dir_col < 0) {
                self.selected_index = if (self.selected_index == 0) total - 1 else self.selected_index - 1;
            } else if (dir_row > 0) {
                if (self.selected_index + cols < total) {
                    self.selected_index += cols;
                } else {
                    const cur_row = self.selected_index / cols;
                    const max_row = (total - 1) / cols;
                    if (cur_row < max_row) {
                        self.selected_index = total - 1;
                    } else {
                        const col = self.selected_index % cols;
                        self.selected_index = col;
                    }
                }
            } else if (dir_row < 0) {
                if (self.selected_index >= cols) {
                    self.selected_index -= cols;
                } else {
                    const col = self.selected_index % cols;
                    const max_row = (total - 1) / cols;
                    const target_idx = max_row * cols + col;
                    self.selected_index = if (target_idx < total) target_idx else total - 1;
                }
            }
        }

        if (self.getPageOffset() != old_page) {
            self.preloadVisibleIcons();
        }
    }

    pub fn moveSelectionPage(self: *Launcher, delta_pages: i32) void {
        const total = self.items.items.len;
        if (total == 0) return;

        const old_page = self.getPageOffset();
        const page_size = self.getItemsPerPage();
        const delta = delta_pages * @as(i32, @intCast(page_size));
        const cur = @as(i32, @intCast(self.selected_index));
        const new_val = cur + delta;

        if (new_val < 0) {
            self.selected_index = 0;
        } else if (new_val >= @as(i32, @intCast(total))) {
            self.selected_index = total - 1;
        } else {
            self.selected_index = @intCast(new_val);
        }

        if (self.getPageOffset() != old_page) {
            self.preloadVisibleIcons();
        }
    }

    pub fn handlePointerAxis(self: *Launcher, x: i32, y: i32, delta: i32) bool {
        _ = x;
        _ = y;
        const total = self.items.items.len;
        if (total == 0) return false;

        if (self.isGridView()) {
            if (delta > 0) {
                self.moveSelectionGrid(1, 0);
                return true;
            } else if (delta < 0) {
                self.moveSelectionGrid(-1, 0);
                return true;
            }
        } else {
            if (delta > 0) {
                self.moveSelection(1);
                return true;
            } else if (delta < 0) {
                self.moveSelection(-1);
                return true;
            }
        }
        return false;
    }

    pub fn recordAppUsage(self: *Launcher, app_id: []const u8) void {
        desktop_entry.recordAppUsage(self.apps.items, app_id);
    }

    pub fn launchApp(self: *Launcher, app: *const desktop_entry.DesktopApp) void {
        self.recordAppUsage(app.id);
        const term = resolveTerminal(&self.cfg);
        parseAndSpawnApp(self.allocator, app.exec, app.terminal, term);
    }

    pub fn executeMizuAction(self: *Launcher, cmd: []const u8) void {
        if (cmd.len == 0) return;

        if (std.mem.startsWith(u8, cmd, "mizu theme set ")) {
            const tname = cmd["mizu theme set ".len..];
            if (theme.ThemeKind.fromString(tname)) |k| {
                theme.saveCurrentTheme(k);
                self.cfg.theme = k.toTheme();
            }
        } else if (std.mem.eql(u8, cmd, "mizu theme next")) {
            const cur = theme.loadSavedTheme() orelse .nord;
            const nxt = cur.next();
            theme.saveCurrentTheme(nxt);
            self.cfg.theme = nxt.toTheme();
        } else if (std.mem.eql(u8, cmd, "mizu theme prev")) {
            const cur = theme.loadSavedTheme() orelse .nord;
            const prv = cur.prev();
            theme.saveCurrentTheme(prv);
            self.cfg.theme = prv.toTheme();
        }

        sys_status.spawnCmd(cmd);
    }

    pub fn launchSelected(self: *Launcher) void {
        if (self.items.items.len == 0 or self.selected_index >= self.items.items.len) {
            // Never execute arbitrary input from application search
            return;
        }

        const item = self.items.items[self.selected_index];

        // Potentially destructive actions require confirmation
        if (item.action_type == .mizu_action and isDestructiveAction(item.action_data)) {
            if (self.confirm_index == null or self.confirm_index.? != self.selected_index) {
                self.confirm_index = self.selected_index;
                return;
            }
        }

        const term = resolveTerminal(&self.cfg);
        switch (item.action_type) {
            .launch_app => {
                if (item.app) |app| {
                    self.launchApp(app);
                } else {
                    self.recordAppUsage(item.action_data);
                    parseAndSpawnApp(self.allocator, item.action_data, false, term);
                }
            },
            .shell_command => {
                if (item.action_data.len > 0) {
                    self.addHistory(item.action_data) catch {};
                    spawnShellCommand(self.allocator, item.action_data, false, term);
                } else {
                    return;
                }
            },
            .terminal_cmd => {
                if (item.action_data.len > 0) {
                    self.addHistory(item.action_data) catch {};
                    spawnShellCommand(self.allocator, item.action_data, true, term);
                } else {
                    return;
                }
            },
            .copy_clipboard => {
                if (item.action_data.len > 0) {
                    const raw_q = self.input.getText();
                    const trimmed_q = std.mem.trim(u8, raw_q, " \t\r\n");
                    var expr_str = trimmed_q;
                    if (expr_str.len > 0 and expr_str[0] == '=') {
                        expr_str = std.mem.trim(u8, expr_str[1..], " \t\r\n");
                    }
                    if (expr_str.len > 0) {
                        self.addCalcHistory(expr_str, item.action_data) catch {};
                    } else if (item.is_history) {
                        if (std.mem.lastIndexOf(u8, item.title, " = ")) |eq_idx| {
                            self.addCalcHistory(item.title[0..eq_idx], item.action_data) catch {};
                        }
                    }
                    copyToClipboard(item.action_data);
                } else {
                    return;
                }
            },
            .open_file => {
                if (item.action_data.len > 0) {
                    openFileDirect(self.allocator, item.action_data);
                } else {
                    return;
                }
            },
            .mizu_action => {
                if (item.action_data.len > 0) {
                    self.executeMizuAction(item.action_data);
                } else {
                    return;
                }
            },
        }

        self.running = false;
    }

    pub fn getInputRect(self: *const Launcher) struct { x: i32, y: i32, w: u32, h: u32 } {
        const input_x: i32 = OUTER_PAD;
        const input_y: i32 = OUTER_PAD;
        const total_pad = @as(u32, @intCast(OUTER_PAD * 2));
        const input_w: u32 = if (self.width > total_pad) self.width - total_pad else self.width;
        return .{ .x = input_x, .y = input_y, .w = input_w, .h = INPUT_H };
    }

    pub fn getListCardRect(self: *const Launcher, row: usize) CardRect {
        const start_x: i32 = OUTER_PAD;
        const start_y: i32 = OUTER_PAD + @as(i32, @intCast(INPUT_H)) + INPUT_GAP;
        const total_pad = @as(u32, @intCast(OUTER_PAD * 2));
        const card_w: u32 = if (self.width > total_pad) self.width - total_pad else self.width;
        const step: i32 = @as(i32, @intCast(ROW_H + @as(u32, @intCast(ROW_GAP))));
        const y = start_y + @as(i32, @intCast(row)) * step;
        return .{ .x = start_x, .y = y, .w = card_w, .h = ROW_H };
    }

    pub fn getGridCardRect(self: *const Launcher, cell_idx: usize) CardRect {
        const start_x: i32 = OUTER_PAD;
        const start_y: i32 = OUTER_PAD + @as(i32, @intCast(INPUT_H)) + INPUT_GAP;
        const total_pad = @as(u32, @intCast(OUTER_PAD * 2));
        const avail_w: u32 = if (self.width > total_pad) self.width - total_pad else self.width;

        const cols = @max(1, self.grid_cols);
        const total_gap_w = @as(u32, @intCast((cols - 1) * @as(usize, @intCast(GRID_GAP))));
        const cell_w = if (avail_w > total_gap_w) (avail_w - total_gap_w) / @as(u32, @intCast(cols)) else 100;

        const col = cell_idx % cols;
        const row = cell_idx / cols;

        const col_step: i32 = @as(i32, @intCast(cell_w)) + GRID_GAP;
        const row_step: i32 = @as(i32, @intCast(GRID_ROW_H)) + GRID_GAP;

        const x = start_x + @as(i32, @intCast(col)) * col_step;
        const y = start_y + @as(i32, @intCast(row)) * row_step;

        return .{ .x = x, .y = y, .w = cell_w, .h = GRID_ROW_H };
    }

    pub fn getCardRect(self: *const Launcher, page_idx: usize) CardRect {
        if (self.isGridView()) {
            return self.getGridCardRect(page_idx);
        } else {
            return self.getListCardRect(page_idx);
        }
    }

    pub fn getPageOffset(self: *const Launcher) usize {
        const total = self.items.items.len;
        if (total == 0) return 0;
        const page_size = self.getItemsPerPage();
        if (page_size == 0) return 0;
        return (self.selected_index / page_size) * page_size;
    }

    fn getTextOriginX(self: *Launcher) i32 {
        const in_rect = self.getInputRect();
        const cur_mode = self.effectiveMode();
        const icon_str = cur_mode.icon();
        const icon_w = self.font.measureText(icon_str);
        return in_rect.x + 16 + @as(i32, @intCast(icon_w)) + 8;
    }

    pub fn getItemAt(self: *const Launcher, x: i32, y: i32) ?usize {
        const total = self.items.items.len;
        if (total == 0) return null;

        const page_offset = self.getPageOffset();
        const page_size = self.getItemsPerPage();
        var i: usize = 0;
        while (i < page_size) : (i += 1) {
            const item_idx = page_offset + i;
            if (item_idx >= total) break;

            const rect = self.getCardRect(i);
            if (x >= rect.x and x < rect.x + @as(i32, @intCast(rect.w)) and
                y >= rect.y and y < rect.y + @as(i32, @intCast(rect.h)))
            {
                return item_idx;
            }
        }
        return null;
    }

    pub fn handlePointerMotion(self: *Launcher, x: i32, y: i32) bool {
        const text_ox = self.getTextOriginX();
        if (self.input.drag_active) {
            _ = self.input.handlePointerMotion(x, text_ox, &self.font);
            return true;
        }

        const old_hover = self.hover_index;
        const old_trash = self.hover_trash;
        self.hover_index = self.getItemAt(x, y);

        self.hover_trash = false;
        if (self.hover_index) |idx| {
            if (!self.isGridView()) {
                const page_offset = self.getPageOffset();
                if (idx >= page_offset and idx < page_offset + self.list_rows and idx < self.items.items.len) {
                    const r = idx - page_offset;
                    const item = self.items.items[idx];
                    if (item.is_history and self.isTrashAt(r, x, y)) {
                        self.hover_trash = true;
                    }
                }
            }
        }
        return old_hover != self.hover_index or old_trash != self.hover_trash;
    }

    pub fn handlePointerButton(self: *Launcher, x: i32, y: i32, button: u32, is_pressed: bool) bool {
        const in_rect = self.getInputRect();

        if (button == 272) { // BTN_LEFT
            if (is_pressed) {
                const text_ox = self.getTextOriginX();
                if (self.input.handlePointerDown(x, y, in_rect.x, in_rect.y, in_rect.w, in_rect.h, text_ox, &self.font)) {
                    return true;
                }
                return self.handleClick(x, y);
            } else {
                self.input.handlePointerUp();
                return true;
            }
        }
        return false;
    }

    pub fn handleClick(self: *Launcher, x: i32, y: i32) bool {
        const in_rect = self.getInputRect();

        if (x >= in_rect.x and x < in_rect.x + @as(i32, @intCast(in_rect.w)) and
            y >= in_rect.y and y < in_rect.y + @as(i32, @intCast(in_rect.h)))
        {
            return true;
        }

        if (self.getItemAt(x, y)) |item_idx| {
            if (!self.isGridView()) {
                const page_offset = self.getPageOffset();
                if (item_idx >= page_offset and item_idx < page_offset + self.list_rows and item_idx < self.items.items.len) {
                    const r = item_idx - page_offset;
                    const item = self.items.items[item_idx];
                    if (item.is_history and self.isTrashAt(r, x, y)) {
                        self.removeFromHistory(item_idx) catch {};
                        return true;
                    }
                }
            }
            self.selected_index = item_idx;
            self.launchSelected();
            return false;
        }

        self.running = false;
        return false;
    }

    pub fn handleKey(self: *Launcher, sym: u32, utf8_bytes: []const u8, ctrl: bool, shift: bool) bool {
        // 1. Escape key predictable sequence
        if (sym == c.XKB_KEY_Escape) {
            if (self.confirm_index != null) {
                self.confirm_index = null;
                return true;
            }
            if (self.input.getText().len > 0) {
                self.input.clear();
                if (self.mode != .app) self.setMode(.app);
                self.updateResults() catch {};
                return true;
            } else if (self.mode != .app) {
                self.setMode(.app);
                self.updateResults() catch {};
                return true;
            } else {
                self.running = false;
                return true;
            }
        } else if (sym == c.XKB_KEY_Delete) {
            if (self.selected_index < self.items.items.len) {
                const item = self.items.items[self.selected_index];
                if (item.is_history) {
                    self.removeFromHistory(self.selected_index) catch {};
                    return true;
                }
            }
        } else if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_KP_Enter) {
            self.launchSelected();
            return true;
        } else if (sym == c.XKB_KEY_Up) {
            self.confirm_index = null;
            if (self.isGridView()) {
                self.moveSelectionGrid(-1, 0);
            } else {
                self.moveSelection(-1);
            }
            return true;
        } else if (sym == c.XKB_KEY_Down) {
            self.confirm_index = null;
            if (self.isGridView()) {
                self.moveSelectionGrid(1, 0);
            } else {
                self.moveSelection(1);
            }
            return true;
        } else if (sym == c.XKB_KEY_Left and self.isGridView() and self.input.getText().len == 0 and !ctrl) {
            self.confirm_index = null;
            self.moveSelectionGrid(0, -1);
            return true;
        } else if (sym == c.XKB_KEY_Right and self.isGridView() and self.input.getText().len == 0 and !ctrl) {
            self.confirm_index = null;
            self.moveSelectionGrid(0, 1);
            return true;
        } else if (sym == c.XKB_KEY_Page_Up) {
            self.confirm_index = null;
            self.moveSelectionPage(-1);
            return true;
        } else if (sym == c.XKB_KEY_Page_Down) {
            self.confirm_index = null;
            self.moveSelectionPage(1);
            return true;
        } else if (sym == c.XKB_KEY_Tab) {
            self.confirm_index = null;
            self.cycleMode(shift) catch {};
            return true;
        } else if (sym == c.XKB_KEY_ISO_Left_Tab) {
            self.confirm_index = null;
            self.cycleMode(true) catch {};
            return true;
        }

        // 2. Backspace on empty query restores application search
        if (sym == c.XKB_KEY_BackSpace and self.input.getText().len == 0) {
            if (self.mode != .app) {
                self.setMode(.app);
                self.updateResults() catch {};
                return true;
            }
        }

        // 3. Mode prefix recognition when input is empty
        if (self.input.getText().len == 0 and utf8_bytes.len == 1 and !ctrl) {
            const ch = utf8_bytes[0];
            const target_mode: ?Mode = switch (ch) {
                '>' => .command,
                ':' => .action,
                '=' => .calc,
                '/' => .files,
                else => null,
            };
            if (target_mode) |m| {
                self.setMode(m);
                self.updateResults() catch {};
                return true;
            }
        }

        // 4. Ignore leading space immediately following a mode switch
        if (self.mode != .app and self.input.getText().len == 0 and sym == c.XKB_KEY_space) {
            return true;
        }

        // 5. Standard Text input handling
        var prev_buf: [256]u8 = undefined;
        const cur_text = self.input.getText();
        const prev_len = @min(cur_text.len, prev_buf.len);
        @memcpy(prev_buf[0..prev_len], cur_text[0..prev_len]);
        const prev_slice = prev_buf[0..prev_len];

        const handled = self.input.handleKey(sym, utf8_bytes, ctrl, shift);
        if (handled) {
            const new_text = self.input.getText();
            if (cur_text.len > prev_buf.len or !std.mem.eql(u8, new_text, prev_slice)) {
                self.confirm_index = null;
                self.updateResults() catch {};
            }
            return true;
        }

        return false;
    }

    fn getAppToneColor(t: theme.Theme, name: []const u8) theme.Color {
        var h: u32 = 5381;
        for (name) |byte| {
            h = ((h << 5) +% h) +% byte;
        }
        const tones = [_]theme.Color{
            t.surface,
            t.elevated,
            t.secondary,
            theme.Color.init(180, t.accent.r, t.accent.g, t.accent.b),
            theme.Color.rgb(0x3B, 0x52, 0x49),
            theme.Color.rgb(0x56, 0x43, 0x36),
            theme.Color.rgb(0x36, 0x48, 0x5C),
        };
        return tones[h % tones.len];
    }

    fn truncateText(target: renderer.Renderer, font: *renderer.Font, text: []const u8, max_w: u32, size: u32, buf: []u8) []const u8 {
        const text_w = target.measureTextWithSize(font, text, size);
        if (text_w <= max_w) return text;

        const ellipsis = "...";
        const ell_w = target.measureTextWithSize(font, ellipsis, size);
        if (ell_w >= max_w) return "";

        var best_len: usize = 0;
        var utf8_view = std.unicode.Utf8View.init(text) catch return text;
        var it = utf8_view.iterator();
        while (it.nextCodepointSlice()) |slice| {
            const candidate_len = best_len + slice.len;
            if (candidate_len + ellipsis.len > buf.len) break;
            @memcpy(buf[0..candidate_len], text[0..candidate_len]);
            @memcpy(buf[candidate_len .. candidate_len + ellipsis.len], ellipsis);
            const w = target.measureTextWithSize(font, buf[0 .. candidate_len + ellipsis.len], size);
            if (w > max_w) break;
            best_len = candidate_len;
        }

        if (best_len == 0) return "";
        @memcpy(buf[0..best_len], text[0..best_len]);
        @memcpy(buf[best_len .. best_len + ellipsis.len], ellipsis);
        return buf[0 .. best_len + ellipsis.len];
    }

    pub fn render(self: *Launcher, target: renderer.Renderer, scale: u32) !void {
        target.clear(theme.Color.transparent);

        const w = target.width;
        const h = target.height;
        const panel_font_size = self.cfg.typography.ui * scale;
        const icon_font_size = self.cfg.typography.bar_icon * scale;
        const cur_mode = self.effectiveMode();

        target.drawDropShadow(0, 0, w, h, self.cfg.theme.radius_panel, 10, self.cfg.theme.shadow_dark);

        var ui = try ui_mod.Ui.begin(
            self.allocator,
            &self.font,
            w,
            h,
            scale,
            -1,
            -1,
            false,
            1.0 / 60.0,
        );
        defer ui.deinit();

        ui.root(.{
            .direction = .column,
            .padding = .{
                .left = ui.su(@intCast(Launcher.OUTER_PAD)),
                .right = ui.su(@intCast(Launcher.OUTER_PAD)),
                .top = ui.su(@intCast(Launcher.OUTER_PAD)),
                .bottom = ui.su(@intCast(Launcher.OUTER_PAD)),
            },
            .gap = ui.su(@intCast(Launcher.INPUT_GAP)),
            .bg = self.cfg.theme.panel_bg,
            .radius = ui.f(self.cfg.theme.radius_panel),
            .border = ui.su(1),
            .border_color = self.cfg.theme.panel_border,
        });

        // Search field.
        const search_border = if (self.input.focused or self.input.getText().len > 0)
            self.cfg.theme.accent
        else
            self.cfg.theme.pill_border;
        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .fixed = ui.s(Launcher.INPUT_H) },
            .direction = .row,
            .padding = .{ .left = ui.su(16), .right = ui.su(16) },
            .gap = ui.su(8),
            .bg = self.cfg.theme.pill_bg,
            .radius = ui.f(self.cfg.theme.radius_pill),
            .border = ui.su(1),
            .border_color = search_border,
            .align_y = .center,
        });
        _ = ui.open(.{
            .width = .{ .fixed = @floatFromInt(icon_font_size) },
            .height = .{ .fixed = @floatFromInt(icon_font_size) },
            .align_x = .center,
            .align_y = .center,
        });
        ui.icon(cur_mode.svgIcon(), icon_font_size, self.cfg.theme.accent, 0);
        ui.close();

        const draw_data = try ui.allocator.create(InputDraw);
        draw_data.* = .{
            .input = &self.input,
            .font = &self.font,
            .text_color = self.cfg.theme.text_bright,
            .placeholder_color = self.cfg.theme.text_muted,
            .accent_color = self.cfg.theme.accent,
            .size = panel_font_size,
        };
        const draw_custom = try ui.allocator.create(ui_mod.Custom);
        draw_custom.* = .{ .callback = .{ .function = InputDraw.draw, .data = draw_data } };
        ui.custom(.{ .grow = .{} }, .{ .grow = .{} }, draw_custom, 0);
        ui.close(); // custom
        ui.close(); // search

        // Results.
        const total = self.items.items.len;
        if (total == 0) {
            _ = ui.open(.{
                .width = .{ .grow = .{} },
                .height = .{ .grow = .{} },
                .direction = .column,
                .align_x = .center,
                .align_y = .center,
                .gap = 4,
            });
            const no_match_str = if (cur_mode == .app)
                "No applications found"
            else
                "No matching items found";
            ui.text("󰋽", .{
                .size = self.cfg.typography.title * scale,
                .color = self.cfg.theme.text_muted,
            });
            ui.text(no_match_str, .{
                .size = panel_font_size,
                .color = self.cfg.theme.text_muted,
            });
            ui.close();
        } else if (self.isGridView()) {
            const page_offset = self.getPageOffset();
            const grid_icon_s: u32 = GRID_ICON_SIZE * scale;

            const avail_w = if (self.width > @as(u32, @intCast(OUTER_PAD * 2))) self.width - @as(u32, @intCast(OUTER_PAD * 2)) else self.width;
            const cols = @max(1, self.grid_cols);
            const total_gap_w = @as(u32, @intCast((cols - 1) * @as(usize, @intCast(GRID_GAP))));
            const cell_w = if (avail_w > total_gap_w) (avail_w - total_gap_w) / @as(u32, @intCast(cols)) else 100;
            const max_text_w = if (cell_w > 12) (cell_w - 12) * scale else cell_w * scale;

            var row_idx: usize = 0;
            while (row_idx < self.grid_rows) : (row_idx += 1) {
                _ = ui.open(.{
                    .width = .{ .grow = .{} },
                    .height = .{ .fixed = ui.s(GRID_ROW_H) },
                    .direction = .row,
                    .gap = ui.su(@intCast(GRID_GAP)),
                    .align_y = .center,
                });

                var col_idx: usize = 0;
                while (col_idx < cols) : (col_idx += 1) {
                    const cell_idx = row_idx * cols + col_idx;
                    const item_idx = page_offset + cell_idx;

                    if (item_idx < total) {
                        const item = self.items.items[item_idx];
                        const is_selected = (item_idx == self.selected_index);
                        const is_hovered = (self.hover_index != null and item_idx == self.hover_index.?);

                        _ = ui.open(.{
                            .width = .{ .fixed = ui.s(cell_w) },
                            .height = .{ .fixed = ui.s(GRID_ROW_H) },
                            .direction = .column,
                            .padding = .{ .left = ui.su(6), .right = ui.su(6), .top = ui.su(8), .bottom = ui.su(8) },
                            .gap = ui.su(6),
                            .bg = if (is_selected)
                                self.cfg.theme.card_selected_bg
                            else if (is_hovered)
                                self.cfg.theme.card_hover_bg
                            else
                                null,
                            .radius = ui.f(self.cfg.theme.radius_button),
                            .border = if (is_selected or is_hovered) ui.su(1) else 0,
                            .border_color = if (is_selected) self.cfg.theme.accent else if (is_hovered) self.cfg.theme.border else null,
                            .align_x = .center,
                            .align_y = .center,
                        });

                        if (item.action_type == .launch_app and item.icon != null) {
                            if (self.icon_cache.getCachedOnly(item.icon)) |surf| {
                                ui.image(surf, .{ .fixed = @floatFromInt(grid_icon_s) }, .{ .fixed = @floatFromInt(grid_icon_s) }, null, 0);
                            } else {
                                _ = ui.open(.{
                                    .width = .{ .fixed = @floatFromInt(grid_icon_s) },
                                    .height = .{ .fixed = @floatFromInt(grid_icon_s) },
                                    .bg = getAppToneColor(self.cfg.theme, item.title),
                                    .radius = ui.f(10),
                                    .border = ui.su(1),
                                    .border_color = self.cfg.theme.border,
                                    .align_x = .center,
                                    .align_y = .center,
                                });
                                ui.text(initialFor(item.title), .{
                                    .size = self.cfg.typography.title * scale,
                                    .color = self.cfg.theme.text_bright,
                                });
                                ui.close();
                            }
                        } else {
                            _ = ui.open(.{
                                .width = .{ .fixed = @floatFromInt(grid_icon_s) },
                                .height = .{ .fixed = @floatFromInt(grid_icon_s) },
                                .bg = self.cfg.theme.elevated,
                                .radius = ui.f(10),
                                .border = ui.su(1),
                                .border_color = self.cfg.theme.border,
                                .align_x = .center,
                                .align_y = .center,
                            });
                            const icon_str = item.icon orelse "•";
                            if (builtinSvgIcon(icon_str)) |svg_name| {
                                ui.icon(svg_name, 24 * scale, self.cfg.theme.accent, 0);
                            } else {
                                ui.text(icon_str, .{
                                    .size = 24 * scale,
                                    .color = self.cfg.theme.accent,
                                });
                            }
                            ui.close();
                        }

                        var title_trunc: [128]u8 = undefined;
                        const title_label = truncateText(target, &self.font, item.title, max_text_w, panel_font_size, &title_trunc);
                        ui.text(title_label, .{
                            .size = panel_font_size,
                            .color = if (is_selected) self.cfg.theme.card_selected_fg else self.cfg.theme.text_bright,
                            .text_align = .center,
                        });

                        ui.close(); // cell card
                    } else {
                        _ = ui.open(.{
                            .width = .{ .fixed = ui.s(cell_w) },
                            .height = .{ .fixed = ui.s(GRID_ROW_H) },
                        });
                        ui.close();
                    }
                }

                ui.close(); // grid row
            }
        } else {
            const page_offset = self.getPageOffset();
            const badge_font_size = self.cfg.typography.secondary * scale;
            const desc_font_size = self.cfg.typography.secondary * scale;

            var r: usize = 0;
            while (r < self.list_rows) : (r += 1) {
                const item_idx = page_offset + r;
                if (item_idx >= total) break;

                const item = self.items.items[item_idx];
                const rect = self.getListCardRect(r);
                const is_selected = (item_idx == self.selected_index);
                const is_hovered = (self.hover_index != null and item_idx == self.hover_index.?);
                const is_confirming = (self.confirm_index != null and self.confirm_index.? == item_idx);
                const badge_str = if (is_confirming) "CONFIRM ENTER" else item.badge;

                var badge_w: u32 = 0;
                if (badge_str) |b_str| {
                    badge_w = target.measureTextWithSize(&self.font, b_str, badge_font_size) + 16 * scale + 14 * scale;
                }
                const max_text_w = if (rect.w > 54 * scale + badge_w + 16 * scale)
                    rect.w - 54 * scale - badge_w - 16 * scale
                else
                    rect.w;

                _ = ui.open(.{
                    .width = .{ .grow = .{} },
                    .height = .{ .fixed = ui.s(Launcher.ROW_H) },
                    .direction = .row,
                    .padding = .{ .left = ui.su(10), .right = ui.su(12) },
                    .gap = ui.su(10),
                    .bg = if (is_selected)
                        self.cfg.theme.card_selected_bg
                    else if (is_hovered)
                        self.cfg.theme.card_hover_bg
                    else
                        null,
                    .radius = ui.f(self.cfg.theme.radius_button),
                    .border = if (is_selected or is_hovered) ui.su(1) else 0,
                    .border_color = if (is_selected) self.cfg.theme.accent else if (is_hovered) self.cfg.theme.border else null,
                    .align_y = .center,
                });

                const icon_s: u32 = 32 * scale;
                if (item.action_type == .launch_app and item.icon != null) {
                    if (self.icon_cache.getCachedOnly(item.icon)) |surf| {
                        ui.image(surf, .{ .fixed = @floatFromInt(icon_s) }, .{ .fixed = @floatFromInt(icon_s) }, null, 0);
                    } else {
                        _ = ui.open(.{
                            .width = .{ .fixed = @floatFromInt(icon_s) },
                            .height = .{ .fixed = @floatFromInt(icon_s) },
                            .bg = getAppToneColor(self.cfg.theme, item.title),
                            .radius = ui.f(8),
                            .border = ui.su(1),
                            .border_color = self.cfg.theme.border,
                            .align_x = .center,
                            .align_y = .center,
                        });
                        ui.text(initialFor(item.title), .{
                            .size = self.cfg.typography.ui * scale,
                            .color = self.cfg.theme.text_bright,
                        });
                        ui.close();
                    }
                } else {
                    _ = ui.open(.{
                        .width = .{ .fixed = @floatFromInt(icon_s) },
                        .height = .{ .fixed = @floatFromInt(icon_s) },
                        .bg = self.cfg.theme.elevated,
                        .radius = ui.f(8),
                        .border = ui.su(1),
                        .border_color = self.cfg.theme.border,
                        .align_x = .center,
                        .align_y = .center,
                    });
                    const icon_str = item.icon orelse "•";
                    if (builtinSvgIcon(icon_str)) |svg_name| {
                        ui.icon(svg_name, icon_font_size, self.cfg.theme.accent, 0);
                    } else {
                        ui.text(icon_str, .{
                            .size = icon_font_size,
                            .color = self.cfg.theme.accent,
                        });
                    }
                    ui.close();
                }

                _ = ui.open(.{
                    .width = .{ .grow = .{} },
                    .height = .{ .grow = .{} },
                    .direction = .column,
                    .gap = ui.su(2),
                    .align_y = .center,
                });

                var title_trunc: [128]u8 = undefined;
                const title_label = truncateText(target, &self.font, item.title, max_text_w, panel_font_size, &title_trunc);
                ui.text(title_label, .{
                    .size = panel_font_size,
                    .color = if (is_selected) self.cfg.theme.card_selected_fg else self.cfg.theme.text_bright,
                });

                if (item.action_type != .launch_app and item.description.len > 0) {
                    var desc_trunc: [160]u8 = undefined;
                    const desc_label = truncateText(target, &self.font, item.description, max_text_w, desc_font_size, &desc_trunc);
                    if (desc_label.len > 0) {
                        ui.text(desc_label, .{
                            .size = desc_font_size,
                            .color = if (is_selected) self.cfg.theme.card_selected_fg else self.cfg.theme.text_muted,
                        });
                    }
                }
                ui.close();

                if (item.is_history and is_hovered) {
                    const is_trash_hov = self.hover_trash and (self.hover_index != null and self.hover_index.? == item_idx);
                    _ = ui.open(.{
                        .width = .{ .fixed = @floatFromInt(28 * scale) },
                        .height = .{ .fixed = @floatFromInt(28 * scale) },
                        .bg = if (is_trash_hov) theme.Color.init(50, self.cfg.theme.error_color.r, self.cfg.theme.error_color.g, self.cfg.theme.error_color.b) else self.cfg.theme.surface,
                        .radius = ui.f(6),
                        .border = ui.su(1),
                        .border_color = if (is_trash_hov) self.cfg.theme.error_color else self.cfg.theme.border,
                        .align_x = .center,
                        .align_y = .center,
                    });
                    ui.icon("trash", 14 * scale, if (is_trash_hov) self.cfg.theme.error_color else self.cfg.theme.text_muted, 0);
                    ui.close();
                } else if (badge_str) |b_str| {
                    _ = ui.open(.{
                        .width = .fit,
                        .height = .{ .fixed = ui.s(22) },
                        .padding = .{ .left = ui.su(8), .right = ui.su(8) },
                        .bg = if (is_confirming)
                            self.cfg.theme.accent
                        else if (is_selected)
                            self.cfg.theme.elevated
                        else
                            self.cfg.theme.surface,
                        .radius = ui.f(5),
                        .border = ui.su(1),
                        .border_color = self.cfg.theme.border,
                        .align_x = .center,
                        .align_y = .center,
                    });
                    ui.text(b_str, .{
                        .size = badge_font_size,
                        .color = if (is_confirming)
                            self.cfg.theme.card_selected_fg
                        else if (is_selected)
                            self.cfg.theme.accent
                        else
                            self.cfg.theme.text_muted,
                    });
                    ui.close();
                }

                ui.close(); // row
            }
        }

        ui.close(); // root
        const commands = ui.endLayout();
        ui.render(target, commands);
    }

};

// --- Unit Tests ---

test "Launcher hybrid routing and four providers" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    const app_dummy = desktop_entry.DesktopApp{
        .id = "firefox.desktop",
        .name = "Firefox",
        .exec = "firefox",
        .icon = "firefox",
    };

    var launcher = Launcher{
        .allocator = allocator,
        .cfg = cfg,
        .font = undefined,
        .icon_cache = IconCache.init(allocator),
        .apps = std.ArrayList(desktop_entry.DesktopApp).empty,
        .results = std.ArrayList(desktop_entry.SearchResult).empty,
        .items = std.ArrayList(GenericItem).empty,
        .cmd_history = std.ArrayList([]const u8).empty,
        .calc_history = std.ArrayList([]const u8).empty,
        .hover_trash = false,
        .input = text_input.TextInput.init(allocator, Mode.app.placeholder(), false),
    };
    defer {
        launcher.clearItems();
        launcher.items.deinit(allocator);
        for (launcher.calc_history.items) |c_item| {
            allocator.free(c_item);
        }
        launcher.calc_history.deinit(allocator);
        for (launcher.cmd_history.items) |cmd| {
            allocator.free(cmd);
        }
        launcher.cmd_history.deinit(allocator);
        launcher.input.deinit();
        launcher.results.deinit(allocator);
        launcher.apps.deinit(allocator);
        launcher.icon_cache.deinit();
    }

    try launcher.apps.append(allocator, app_dummy);
    try launcher.updateResults();

    // 1. Plain text default: searches applications
    try std.testing.expectEqual(Mode.app, launcher.mode);
    try std.testing.expectEqual(Mode.app, launcher.effectiveMode());
    try std.testing.expect(launcher.items.items.len > 0);
    try std.testing.expectEqualStrings("Firefox", launcher.items.items[0].title);
    try std.testing.expectEqualStrings("", launcher.items.items[0].description);
    try std.testing.expectEqual(ActionType.launch_app, launcher.items.items[0].action_type);

    // Ordinary app names should not be classified as math or commands
    try std.testing.expect(!isAutoCalcExpression("firefox"));
    try std.testing.expect(!isAutoCalcExpression("code"));
    try std.testing.expect(!isAutoCalcExpression("gimp-2.10"));
    try std.testing.expect(!isAutoCalcExpression("7"));

    // 2. Calculator auto-detection on valid arithmetic expressions
    launcher.input.clear();
    try launcher.appendBytes("125 / 5");
    try std.testing.expectEqual(Mode.calc, launcher.effectiveMode());
    try std.testing.expectEqual(@as(usize, 1), launcher.items.items.len);
    try std.testing.expectEqualStrings("= 25", launcher.items.items[0].title);
    try std.testing.expectEqual(ActionType.copy_clipboard, launcher.items.items[0].action_type);

    launcher.input.clear();
    try launcher.appendBytes("2^10");
    try std.testing.expectEqual(Mode.calc, launcher.effectiveMode());
    try std.testing.expectEqualStrings("= 1024", launcher.items.items[0].title);

    launcher.input.clear();
    try launcher.appendBytes("sqrt(144)");
    try std.testing.expectEqual(Mode.calc, launcher.effectiveMode());
    try std.testing.expectEqualStrings("= 12", launcher.items.items[0].title);

    // 3. Explicit '=' prefix forces calculator mode and strips prefix
    launcher.input.clear();
    _ = launcher.handleKey(c.XKB_KEY_equal, "=", false, false);
    try std.testing.expectEqual(Mode.calc, launcher.mode);
    try std.testing.expectEqual(@as(usize, 0), launcher.input.getText().len);
    try launcher.appendBytes("42");
    try std.testing.expectEqualStrings("= 42", launcher.items.items[0].title);

    // Backspace on empty explicit provider query returns to application search
    launcher.input.clear();
    _ = launcher.handleKey(c.XKB_KEY_BackSpace, "", false, false);
    try std.testing.expectEqual(Mode.app, launcher.mode);

    // 4. Explicit '>' prefix forces shell command mode and strips prefix
    _ = launcher.handleKey(c.XKB_KEY_greater, ">", false, false);
    try std.testing.expectEqual(Mode.command, launcher.mode);
    try std.testing.expectEqual(@as(usize, 0), launcher.input.getText().len);

    // Shell command mode shows Run and Terminal ONLY (no hardcoded actions)
    try launcher.appendBytes("git status");
    try std.testing.expectEqual(@as(usize, 2), launcher.items.items.len);
    try std.testing.expectEqualStrings("Run: git status", launcher.items.items[0].title);
    try std.testing.expectEqual(ActionType.shell_command, launcher.items.items[0].action_type);
    try std.testing.expectEqualStrings("Terminal: git status", launcher.items.items[1].title);
    try std.testing.expectEqual(ActionType.terminal_cmd, launcher.items.items[1].action_type);

    // Shell command mode for 'theme' produces shell execution, not mizu actions
    launcher.input.clear();
    try launcher.appendBytes("theme");
    try std.testing.expectEqual(@as(usize, 2), launcher.items.items.len);
    try std.testing.expectEqual(ActionType.shell_command, launcher.items.items[0].action_type);
    try std.testing.expectEqual(ActionType.terminal_cmd, launcher.items.items[1].action_type);

    // Backspace returns to app mode
    launcher.input.clear();
    _ = launcher.handleKey(c.XKB_KEY_BackSpace, "", false, false);
    try std.testing.expectEqual(Mode.app, launcher.mode);

    // 5. Explicit ':' prefix forces Mizu action mode and displays mizu actions
    _ = launcher.handleKey(c.XKB_KEY_colon, ":", false, false);
    try std.testing.expectEqual(Mode.action, launcher.mode);
    try std.testing.expectEqual(@as(usize, 0), launcher.input.getText().len);
    try std.testing.expect(launcher.items.items.len > 10); // lists MIZU_ACTIONS

    // Filter mizu actions by keyword
    try launcher.appendBytes("theme");
    try std.testing.expect(launcher.items.items.len >= 3);
    try std.testing.expectEqual(ActionType.mizu_action, launcher.items.items[0].action_type);

    launcher.input.clear();
    _ = launcher.handleKey(c.XKB_KEY_BackSpace, "", false, false);
    try std.testing.expectEqual(Mode.app, launcher.mode);

    // 6. Explicit '/' prefix forces file search
    launcher.setMode(.app);
    _ = launcher.handleKey(c.XKB_KEY_slash, "/", false, false);
    try std.testing.expectEqual(Mode.files, launcher.mode);
    try std.testing.expectEqual(@as(usize, 0), launcher.input.getText().len);
    try std.testing.expect(launcher.items.items.len > 0);
    try std.testing.expectEqual(ActionType.open_file, launcher.items.items[0].action_type);

    // 6. Predictable Escape sequence
    launcher.setMode(.command);
    try launcher.appendBytes("htop");
    try std.testing.expect(launcher.input.getText().len > 0);
    // 1st Esc: clears query, returns to app mode
    _ = launcher.handleKey(c.XKB_KEY_Escape, "", false, false);
    try std.testing.expectEqual(@as(usize, 0), launcher.input.getText().len);
    try std.testing.expectEqual(Mode.app, launcher.mode);
    try std.testing.expect(launcher.running);
    // 2nd Esc: closes launcher
    _ = launcher.handleKey(c.XKB_KEY_Escape, "", false, false);
    try std.testing.expect(!launcher.running);

    // 7. Navigation: Up/Down, Tab/Shift-Tab, and Clamping
    launcher.running = true;
    launcher.setMode(.app);
    try launcher.updateResults();
    launcher.selected_index = 0;
    _ = launcher.handleKey(c.XKB_KEY_Down, "", false, false);
    try std.testing.expectEqual(@as(usize, 0), launcher.selected_index); // only 1 app

    // Add extra items to test navigation
    try launcher.items.append(allocator, .{
        .title = "App 2",
        .description = "Second app",
        .action_data = "app2",
        .action_type = .launch_app,
        .owns_strings = false,
    });
    launcher.selected_index = 0;
    _ = launcher.handleKey(c.XKB_KEY_Down, "", false, false);
    try std.testing.expectEqual(@as(usize, 1), launcher.selected_index);
    _ = launcher.handleKey(c.XKB_KEY_Up, "", false, false);
    try std.testing.expectEqual(@as(usize, 0), launcher.selected_index);

    // Cycle modes with Tab.
    launcher.input.clear();
    launcher.setMode(.app);
    try std.testing.expectEqual(Mode.app, launcher.mode);

    _ = launcher.handleKey(c.XKB_KEY_Tab, "", false, false);
    try std.testing.expectEqual(Mode.command, launcher.mode);

    _ = launcher.handleKey(c.XKB_KEY_Tab, "", false, false);
    try std.testing.expectEqual(Mode.action, launcher.mode);

    _ = launcher.handleKey(c.XKB_KEY_Tab, "", false, false);
    try std.testing.expectEqual(Mode.files, launcher.mode);

    _ = launcher.handleKey(c.XKB_KEY_Tab, "", false, false);
    try std.testing.expectEqual(Mode.calc, launcher.mode);

    _ = launcher.handleKey(c.XKB_KEY_Tab, "", false, false);
    try std.testing.expectEqual(Mode.app, launcher.mode);

    // Shift-Tab cycles backward
    _ = launcher.handleKey(c.XKB_KEY_Tab, "", false, true);
    try std.testing.expectEqual(Mode.calc, launcher.mode);

    _ = launcher.handleKey(c.XKB_KEY_ISO_Left_Tab, "", false, false);
    try std.testing.expectEqual(Mode.files, launcher.mode);

    // 9. Command mode history save, recall, and removal
    launcher.setMode(.command);
    try launcher.addHistory("uname -r");
    try launcher.addHistory("ip addr");
    try launcher.updateResults();
    try std.testing.expect(launcher.items.items.len >= 2);
    try std.testing.expectEqualStrings("ip addr", launcher.items.items[0].title);
    try std.testing.expectEqualStrings("uname -r", launcher.items.items[1].title);
    try std.testing.expectEqualStrings("History", launcher.items.items[0].badge.?);
    try std.testing.expect(launcher.items.items[0].is_history);

    // Remove from history via Delete key or removeFromHistory
    launcher.selected_index = 0;
    _ = launcher.handleKey(c.XKB_KEY_Delete, "", false, false);
    try std.testing.expectEqualStrings("uname -r", launcher.items.items[0].title);

    // 10. Calc mode history save, recall, and removal
    launcher.setMode(.calc);
    try launcher.addCalcHistory("125 / 5", "25");
    try launcher.addCalcHistory("2^10", "1024");
    try launcher.updateResults();
    try std.testing.expect(launcher.items.items.len >= 2);
    try std.testing.expectEqualStrings("2^10 = 1024", launcher.items.items[0].title);
    try std.testing.expectEqualStrings("1024", launcher.items.items[0].action_data);
    try std.testing.expect(launcher.items.items[0].is_history);

    // Remove top calc history item
    launcher.selected_index = 0;
    _ = launcher.handleKey(c.XKB_KEY_Delete, "", false, false);
    try std.testing.expectEqualStrings("125 / 5 = 25", launcher.items.items[0].title);

    // 11. Terminal configuration and resolution
    try std.testing.expect(resolveTerminal(&launcher.cfg).len > 0);
    launcher.cfg.terminal = "alacritty";
    try std.testing.expectEqualStrings("alacritty", resolveTerminal(&launcher.cfg));
    launcher.cfg.terminal = null;

    // 12. Safe application search: unmatched input never executes arbitrary command
    launcher.setMode(.app);
    launcher.input.clear();
    try launcher.appendBytes("nonexistent_app_xyz");
    try std.testing.expectEqual(@as(usize, 0), launcher.items.items.len);
    // Calling launchSelected on empty results must do nothing
    launcher.running = true;
    launcher.launchSelected();
    try std.testing.expect(launcher.running); // did not exit/run
}

test "Launcher grid view for apps and list view for other modules" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var launcher = Launcher{
        .allocator = allocator,
        .cfg = cfg,
        .font = undefined,
        .icon_cache = IconCache.init(allocator),
        .apps = std.ArrayList(desktop_entry.DesktopApp).empty,
        .results = std.ArrayList(desktop_entry.SearchResult).empty,
        .items = std.ArrayList(GenericItem).empty,
        .cmd_history = std.ArrayList([]const u8).empty,
        .calc_history = std.ArrayList([]const u8).empty,
        .hover_trash = false,
        .input = text_input.TextInput.init(allocator, Mode.app.placeholder(), false),
    };
    defer {
        launcher.clearItems();
        launcher.items.deinit(allocator);
        launcher.calc_history.deinit(allocator);
        launcher.cmd_history.deinit(allocator);
        launcher.input.deinit();
        launcher.results.deinit(allocator);
        launcher.apps.deinit(allocator);
        launcher.icon_cache.deinit();
    }

    launcher.updateDimensions(0, 0);

    // 1. In app mode: isGridView is true
    launcher.setMode(.app);
    try std.testing.expect(launcher.isGridView());
    try std.testing.expectEqual(launcher.grid_cols * launcher.grid_rows, launcher.getItemsPerPage());

    // 2. In command mode: isGridView is false (list view)
    launcher.setMode(.command);
    try std.testing.expect(!launcher.isGridView());
    try std.testing.expectEqual(launcher.list_rows, launcher.getItemsPerPage());

    // 3. In action mode: isGridView is false (list view)
    launcher.setMode(.action);
    try std.testing.expect(!launcher.isGridView());
    try std.testing.expectEqual(launcher.list_rows, launcher.getItemsPerPage());

    // 4. In calc mode: isGridView is false (list view)
    launcher.setMode(.calc);
    try std.testing.expect(!launcher.isGridView());
    try std.testing.expectEqual(launcher.list_rows, launcher.getItemsPerPage());

    // 5. In files mode: isGridView is false (list view)
    launcher.setMode(.files);
    try std.testing.expect(!launcher.isGridView());
    try std.testing.expectEqual(launcher.list_rows, launcher.getItemsPerPage());

    // 6. Test grid cell geometry and card rects
    launcher.setMode(.app);
    const rect0 = launcher.getCardRect(0);
    const rect1 = launcher.getCardRect(1);
    const rect5 = launcher.getCardRect(5); // row 1 col 0 with 5 columns

    // rect1 must be to the right of rect0
    try std.testing.expect(rect1.x > rect0.x);
    try std.testing.expectEqual(rect0.y, rect1.y);
    try std.testing.expectEqual(rect0.w, rect1.w);
    try std.testing.expectEqual(rect0.h, rect1.h);

    // rect5 must be below rect0 in the same column
    try std.testing.expectEqual(rect0.x, rect5.x);
    try std.testing.expect(rect5.y > rect0.y);
    try std.testing.expectEqual(rect0.w, rect5.w);
    try std.testing.expectEqual(rect0.h, rect5.h);

    // 7. Test multi-row 2D grid keyboard navigation (Left, Right, Up, Down)
    // Add 12 dummy app items to form a 5-column grid across 3 rows
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        try launcher.items.append(allocator, .{
            .title = "App",
            .description = "",
            .action_data = "app",
            .action_type = .launch_app,
            .owns_strings = false,
        });
    }

    launcher.selected_index = 0;
    // Right moves to 1
    _ = launcher.handleKey(c.XKB_KEY_Right, "", false, false);
    try std.testing.expectEqual(@as(usize, 1), launcher.selected_index);
    // Left moves back to 0
    _ = launcher.handleKey(c.XKB_KEY_Left, "", false, false);
    try std.testing.expectEqual(@as(usize, 0), launcher.selected_index);
    // Down moves down a row (+5) to index 5
    _ = launcher.handleKey(c.XKB_KEY_Down, "", false, false);
    try std.testing.expectEqual(@as(usize, 5), launcher.selected_index);
    // Down moves to index 10
    _ = launcher.handleKey(c.XKB_KEY_Down, "", false, false);
    try std.testing.expectEqual(@as(usize, 10), launcher.selected_index);
    // Up moves up a row (-5) to index 5
    _ = launcher.handleKey(c.XKB_KEY_Up, "", false, false);
    try std.testing.expectEqual(@as(usize, 5), launcher.selected_index);
    // Up moves to index 0
    _ = launcher.handleKey(c.XKB_KEY_Up, "", false, false);
    try std.testing.expectEqual(@as(usize, 0), launcher.selected_index);

    // 8. Test mouse hit test in grid view
    const hit0 = launcher.getItemAt(rect0.x + 10, rect0.y + 10);
    try std.testing.expectEqual(@as(?usize, 0), hit0);
    const hit1 = launcher.getItemAt(rect1.x + 10, rect1.y + 10);
    try std.testing.expectEqual(@as(?usize, 1), hit1);
    const hit5 = launcher.getItemAt(rect5.x + 10, rect5.y + 10);
    try std.testing.expectEqual(@as(?usize, 5), hit5);
}

test "Launcher performance latency measurements" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var ts_start: c.struct_timespec = undefined;
    var ts_end: c.struct_timespec = undefined;

    // 1. Measure Launcher.init latency
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts_start);
    var launcher = try Launcher.init(allocator, cfg);
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts_end);
    const init_ns = (@as(i128, ts_end.tv_sec) - @as(i128, ts_start.tv_sec)) * 1_000_000_000 + (@as(i128, ts_end.tv_nsec) - @as(i128, ts_start.tv_nsec));

    // 2. Measure Launcher.render latency
    const w = launcher.width;
    const h = launcher.height;
    const stride = w * 4;
    const pixel_buf = try allocator.alloc(u32, w * h);
    defer allocator.free(pixel_buf);

    var target = try renderer.Renderer.init(pixel_buf.ptr, w, h, stride);
    defer target.deinit();

    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts_start);
    try launcher.render(target, 1);
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts_end);
    const render_ns = (@as(i128, ts_end.tv_sec) - @as(i128, ts_start.tv_sec)) * 1_000_000_000 + (@as(i128, ts_end.tv_nsec) - @as(i128, ts_start.tv_nsec));

    // 3. Measure search filtering latency
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts_start);
    try launcher.appendBytes("code");
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts_end);
    const search_ns = (@as(i128, ts_end.tv_sec) - @as(i128, ts_start.tv_sec)) * 1_000_000_000 + (@as(i128, ts_end.tv_nsec) - @as(i128, ts_start.tv_nsec));

    // 4. Measure Launcher.deinit latency
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts_start);
    launcher.deinit();
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts_end);
    const deinit_ns = (@as(i128, ts_end.tv_sec) - @as(i128, ts_start.tv_sec)) * 1_000_000_000 + (@as(i128, ts_end.tv_nsec) - @as(i128, ts_start.tv_nsec));

    std.debug.print("\n[BENCHMARK] Launcher init latency: {d:.2} µs ({d:.3} ms) (apps: {d})\n", .{
        @as(f64, @floatFromInt(init_ns)) / 1000.0,
        @as(f64, @floatFromInt(init_ns)) / 1_000_000.0,
        launcher.apps.items.len,
    });
    std.debug.print("[BENCHMARK] Launcher render latency: {d:.2} µs ({d:.3} ms)\n", .{
        @as(f64, @floatFromInt(render_ns)) / 1000.0,
        @as(f64, @floatFromInt(render_ns)) / 1_000_000.0,
    });
    std.debug.print("[BENCHMARK] Launcher search filtering latency: {d:.2} µs ({d:.3} ms)\n", .{
        @as(f64, @floatFromInt(search_ns)) / 1000.0,
        @as(f64, @floatFromInt(search_ns)) / 1_000_000.0,
    });
    std.debug.print("[BENCHMARK] Launcher deinit latency: {d:.2} µs ({d:.3} ms)\n", .{
        @as(f64, @floatFromInt(deinit_ns)) / 1000.0,
        @as(f64, @floatFromInt(deinit_ns)) / 1_000_000.0,
    });

    try std.testing.expect(init_ns < 150_000_000); // under 150ms
    try std.testing.expect(render_ns < 25_000_000); // under 25ms
    try std.testing.expect(search_ns < 5_000_000); // under 5ms
    try std.testing.expect(deinit_ns < 5_000_000); // under 5ms
}
