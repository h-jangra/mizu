const std = @import("std");
const c = @import("../c.zig").c;
const renderer = @import("../core/renderer.zig");
const config = @import("../core/config.zig");
const icons = @import("../graphics/icons.zig");
const text_input = @import("../core/text_input.zig");
const theme_mod = @import("../core/theme.zig");
const proc_mem = @import("../services/process_memory.zig");
const ui_mod = @import("../core/ui.zig");
const desktop_entries = @import("../services/desktop_entries.zig");

const Color = theme_mod.Color;

pub const SURFACE_W: u32 = 432;
pub const SURFACE_H: u32 = 552;

const PANEL_W: f64 = 420.0;
const PANEL_H: f64 = 540.0;
const INSET: f64 = 6.0;
const PAD: f64 = 16.0;

const FILTER_TOP: f64 = 66.0;
const FILTER_H: f64 = 36.0;
const HEADER_BASELINE: f64 = 119.0;
const LIST_TOP: f64 = 138.0;
const LIST_BOTTOM_PAD: f64 = 12.0;
const ROW_H: f64 = 38.0;

const REFRESH_MS: i64 = 1000;
const POINTER_BUTTON_LEFT: u32 = 272;

const FILTER_TEXT_LEFT: f64 = 38.0;
const FILTER_INNER_RIGHT: f64 = 36.0;

const MemFilterDraw = struct {
    panel: *MemoryMonitor,
    scale: u32,

    fn draw(target: renderer.Renderer, rect: renderer.Rect, data: *const anyopaque) void {
        const self: *const MemFilterDraw = @ptrCast(@alignCast(data));
        self.panel.drawFilterContent(target, rect, self.scale);
    }
};

pub const ProcessGroup = struct {
    name: [128]u8 = [_]u8{0} ** 128,
    name_len: usize = 0,
    main_pid: u32 = 0,
    total_rss_kb: u64 = 0,
    procs: std.ArrayList(proc_mem.ProcessInfo),
    expanded: bool = false,

    pub fn deinit(self: *ProcessGroup, allocator: std.mem.Allocator) void {
        self.procs.deinit(allocator);
    }
};

pub const RowKind = enum {
    group,
    subprocess,
};

pub const DisplayRow = struct {
    kind: RowKind,
    group_idx: usize,
    sub_idx: usize = 0,
};

pub const MemoryMonitor = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    family: []const u8,

    width: u32 = SURFACE_W,
    height: u32 = SURFACE_H,

    running: bool = true,
    mem: proc_mem.MemInfo = .{},
    desktop_apps: std.ArrayList(desktop_entries.DesktopApp),
    processes: std.ArrayList(proc_mem.ProcessInfo),
    groups: std.ArrayList(ProcessGroup),
    visible_rows: std.ArrayList(DisplayRow),
    expanded_names: std.ArrayList([128]u8),
    expanded_lens: std.ArrayList(usize),

    filter: text_input.TextInput,
    filter_scroll: f64 = 0.0,
    drag_active: bool = false,

    measure: renderer.Font,
    row_measure: renderer.Font,

    selected: ?usize = null,
    hover: ?usize = null,
    scroll: usize = 0,
    last_refresh_ms: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !MemoryMonitor {
        const family = theme_mod.firstFamily(cfg.theme.font_family);
        var filter = text_input.TextInput.init(allocator, "Filter processes\u{2026}", false);
        filter.focused = true;

        const desktop_apps = desktop_entries.discoverApplications(allocator) catch std.ArrayList(desktop_entries.DesktopApp).empty;

        var self = MemoryMonitor{
            .allocator = allocator,
            .cfg = cfg,
            .family = family,
            .desktop_apps = desktop_apps,
            .processes = std.ArrayList(proc_mem.ProcessInfo).empty,
            .groups = std.ArrayList(ProcessGroup).empty,
            .visible_rows = std.ArrayList(DisplayRow).empty,
            .expanded_names = std.ArrayList([128]u8).empty,
            .expanded_lens = std.ArrayList(usize).empty,
            .filter = filter,
            .measure = try renderer.Font.init(allocator, family, cfg.typography.ui),
            .row_measure = try renderer.Font.init(allocator, family, cfg.typography.secondary),
        };
        self.refresh();
        self.last_refresh_ms = nowMs();
        return self;
    }

    pub fn deinit(self: *MemoryMonitor) void {
        for (self.desktop_apps.items) |*app| {
            app.deinit(self.allocator);
        }
        self.desktop_apps.deinit(self.allocator);
        self.processes.deinit(self.allocator);
        for (self.groups.items) |*grp| {
            grp.deinit(self.allocator);
        }
        self.groups.deinit(self.allocator);
        self.visible_rows.deinit(self.allocator);
        self.expanded_names.deinit(self.allocator);
        self.expanded_lens.deinit(self.allocator);
        self.filter.deinit();
        self.measure.deinit();
        self.row_measure.deinit();
    }

    pub fn isGroupExpanded(self: *MemoryMonitor, name: []const u8) bool {
        for (self.expanded_names.items, self.expanded_lens.items) |en, elen| {
            if (std.mem.eql(u8, en[0..elen], name)) return true;
        }
        return false;
    }

    pub fn setGroupExpanded(self: *MemoryMonitor, name: []const u8, expanded: bool) void {
        var found_idx: ?usize = null;
        for (self.expanded_names.items, self.expanded_lens.items, 0..) |en, elen, i| {
            if (std.mem.eql(u8, en[0..elen], name)) {
                found_idx = i;
                break;
            }
        }
        if (expanded) {
            if (found_idx == null and name.len <= 128) {
                var buf: [128]u8 = [_]u8{0} ** 128;
                @memcpy(buf[0..name.len], name);
                self.expanded_names.append(self.allocator, buf) catch {};
                self.expanded_lens.append(self.allocator, name.len) catch {};
            }
        } else {
            if (found_idx) |idx| {
                _ = self.expanded_names.orderedRemove(idx);
                _ = self.expanded_lens.orderedRemove(idx);
            }
        }
    }

    pub fn tick(self: *MemoryMonitor) bool {
        var changed = self.checkTheme();
        const now = nowMs();
        if (now - self.last_refresh_ms >= REFRESH_MS) {
            self.last_refresh_ms = now;
            self.refresh();
            changed = true;
        }
        return changed;
    }

    pub fn checkTheme(self: *MemoryMonitor) bool {
        if (theme_mod.loadSavedTheme()) |saved| {
            if (saved != self.cfg.theme.kind) {
                self.cfg.theme = saved.toTheme();
                return true;
            }
        }
        return false;
    }

    pub fn findAppName(self: *const MemoryMonitor, exe: []const u8, comm: []const u8) ?[]const u8 {
        for (self.desktop_apps.items) |*app| {
            var exec_part = app.exec;
            if (std.mem.indexOfScalar(u8, exec_part, ' ')) |sp| {
                exec_part = exec_part[0..sp];
            }
            const exec_bname = std.fs.path.basename(exec_part);
            if (exe.len > 0 and std.ascii.eqlIgnoreCase(exec_bname, exe)) {
                return app.name;
            }
            if (comm.len > 0 and std.ascii.eqlIgnoreCase(exec_bname, comm)) {
                return app.name;
            }

            var id_stem = app.id;
            if (std.mem.endsWith(u8, id_stem, ".desktop")) {
                id_stem = id_stem[0 .. id_stem.len - 8];
            }
            if (exe.len > 0 and std.ascii.eqlIgnoreCase(id_stem, exe)) {
                return app.name;
            }
            if (comm.len > 0 and std.ascii.eqlIgnoreCase(id_stem, comm)) {
                return app.name;
            }
        }
        return null;
    }

    pub fn isDesktopApp(self: *const MemoryMonitor, name: []const u8) bool {
        if (name.len == 0) return false;
        if (self.findAppName(name, "") != null) return true;
        const well_known = [_][]const u8{
            "firefox", "chrome", "google-chrome", "google-chrome-stable", "chromium",
            "brave", "brave-browser", "opera", "vivaldi", "edge", "microsoft-edge",
            "code", "vscode", "discord", "spotify", "slack", "obsidian", "steam",
            "foot", "footclient", "alacritty", "kitty", "ghostty", "wezterm", "gnome-terminal",
            "konsole", "xterm", "thunar", "nautilus", "dolphin", "pcmanfm",
            "mpv", "vlc", "gimp", "inkscape", "blender", "audacity", "obs",
            "mizu", "neovim", "nvim",
        };
        for (well_known) |k| {
            if (std.ascii.eqlIgnoreCase(name, k)) return true;
        }
        return false;
    }

    pub fn isCompositorOrSessionManager(proc: *const proc_mem.ProcessInfo) bool {
        const e = proc.exe[0..proc.exe_len];
        const n = proc.name[0..proc.name_len];
        const known = [_][]const u8{
            "mango", "sway", "hyprland", "wayfire", "river",
            "gnome-shell", "mutter", "kwin", "kwin_wayland",
            "weston", "labwc", "dwl", "xmonad", "i3", "bspwm",
            "runit", "systemd", "init", "ly", "gdm", "sddm", "lightdm",
        };
        for (known) |k| {
            if (std.mem.eql(u8, e, k) or std.mem.eql(u8, n, k)) return true;
        }
        return false;
    }

    pub fn isTerminalOrShell(proc: *const proc_mem.ProcessInfo) bool {
        const e = proc.exe[0..proc.exe_len];
        const n = proc.name[0..proc.name_len];
        const known = [_][]const u8{
            "foot", "footclient", "alacritty", "kitty", "wezterm-gui",
            "wezterm", "ghostty", "gnome-terminal", "gnome-terminal-server",
            "konsole", "xterm", "urxvt", "st", "terminator", "tilix",
            "bash", "zsh", "fish", "sh", "dash", "tmux",
        };
        for (known) |k| {
            if (std.mem.eql(u8, e, k) or std.mem.eql(u8, n, k)) return true;
        }
        return false;
    }

    pub fn isMultiprocessWorker(proc: *const proc_mem.ProcessInfo, parent: *const proc_mem.ProcessInfo) bool {
        _ = parent;
        const n = proc.name[0..proc.name_len];
        const cmd = proc.cmdline[0..proc.cmdline_len];
        if (std.mem.eql(u8, n, "forkserver") or
            std.mem.eql(u8, n, "Socket Process") or
            std.mem.eql(u8, n, "Privileged Cont") or
            std.mem.eql(u8, n, "RDD Process") or
            std.mem.eql(u8, n, "WebExtensions") or
            std.mem.eql(u8, n, "Utility Process") or
            std.mem.eql(u8, n, "Isolated Web Co") or
            std.mem.eql(u8, n, "Web Content") or
            std.mem.eql(u8, n, "bwrap")) return true;

        if (std.mem.indexOf(u8, cmd, "--type=zygote") != null or
            std.mem.indexOf(u8, cmd, "--type=renderer") != null or
            std.mem.indexOf(u8, cmd, "--type=gpu-process") != null or
            std.mem.indexOf(u8, cmd, "--type=utility") != null or
            std.mem.indexOf(u8, cmd, "--type=crashpad-handler") != null or
            std.mem.indexOf(u8, cmd, "-contentproc") != null) return true;

        return false;
    }

    pub fn findAppRootPid(self: *const MemoryMonitor, pid: u32, pid_map: *const std.AutoHashMap(u32, usize)) u32 {
        var curr_pid = pid;
        var best_root = pid;
        var depth: usize = 0;

        while (depth < 64) : (depth += 1) {
            const idx = pid_map.get(curr_pid) orelse break;
            const proc = &self.processes.items[idx];
            const ppid = proc.ppid;

            if (ppid <= 1 or ppid == curr_pid) {
                best_root = proc.pid;
                break;
            }

            const parent_idx = pid_map.get(ppid) orelse {
                best_root = proc.pid;
                break;
            };
            const parent = &self.processes.items[parent_idx];

            if (isCompositorOrSessionManager(parent)) {
                best_root = proc.pid;
                break;
            }

            if (self.isDesktopApp(proc.exe[0..proc.exe_len]) or self.isDesktopApp(proc.name[0..proc.name_len])) {
                if (!std.mem.eql(u8, proc.exe[0..proc.exe_len], parent.exe[0..parent.exe_len])) {
                    best_root = proc.pid;
                    break;
                }
            }

            if (std.mem.eql(u8, proc.exe[0..proc.exe_len], parent.exe[0..parent.exe_len]) or
                isMultiprocessWorker(proc, parent))
            {
                best_root = parent.pid;
                curr_pid = ppid;
                continue;
            }

            if (isTerminalOrShell(parent) and
                !self.isDesktopApp(proc.exe[0..proc.exe_len]) and
                !self.isDesktopApp(proc.name[0..proc.name_len]))
            {
                best_root = parent.pid;
                curr_pid = ppid;
                continue;
            }

            if (parent.pid == 2 or parent.ppid == 2) {
                best_root = parent.pid;
                break;
            }

            best_root = parent.pid;
            curr_pid = ppid;
        }

        return best_root;
    }

    pub fn resolveAppDisplayName(self: *const MemoryMonitor, proc: *const proc_mem.ProcessInfo, buf: []u8) []const u8 {
        const exe = proc.exe[0..proc.exe_len];
        const comm = proc.name[0..proc.name_len];

        if (self.findAppName(exe, comm)) |name| {
            return name;
        }

        if (proc.pid == 2 or proc.ppid == 2 or std.mem.startsWith(u8, comm, "kworker/") or std.mem.startsWith(u8, comm, "ksoftirqd/")) {
            return "Linux Kernel";
        }

        const known_services = [_]struct { key: []const u8, name: []const u8 }{
            .{ .key = "firefox", .name = "Firefox" },
            .{ .key = "chrome", .name = "Google Chrome" },
            .{ .key = "google-chrome", .name = "Google Chrome" },
            .{ .key = "google-chrome-stable", .name = "Google Chrome" },
            .{ .key = "chromium", .name = "Chromium" },
            .{ .key = "brave", .name = "Brave Browser" },
            .{ .key = "code", .name = "Visual Studio Code" },
            .{ .key = "discord", .name = "Discord" },
            .{ .key = "spotify", .name = "Spotify" },
            .{ .key = "foot", .name = "Foot Terminal" },
            .{ .key = "footclient", .name = "Foot Terminal" },
            .{ .key = "alacritty", .name = "Alacritty" },
            .{ .key = "kitty", .name = "Kitty" },
            .{ .key = "ghostty", .name = "Ghostty" },
            .{ .key = "wezterm", .name = "WezTerm" },
            .{ .key = "wezterm-gui", .name = "WezTerm" },
            .{ .key = "gnome-terminal", .name = "GNOME Terminal" },
            .{ .key = "pipewire", .name = "PipeWire" },
            .{ .key = "wireplumber", .name = "WirePlumber" },
            .{ .key = "dbus-daemon", .name = "D-Bus Daemon" },
            .{ .key = "NetworkManager", .name = "NetworkManager" },
            .{ .key = "systemd", .name = "systemd" },
            .{ .key = "systemd-journal", .name = "systemd-journald" },
            .{ .key = "systemd-udevd", .name = "systemd-udevd" },
            .{ .key = "udevd", .name = "udevd" },
            .{ .key = "elogind", .name = "elogind" },
            .{ .key = "bluetoothd", .name = "bluetoothd" },
            .{ .key = "polkitd", .name = "polkitd" },
            .{ .key = "wpa_supplicant", .name = "wpa_supplicant" },
            .{ .key = "runit", .name = "runit" },
            .{ .key = "runsvdir", .name = "runit service dir" },
            .{ .key = "mango", .name = "Mango Compositor" },
            .{ .key = "sway", .name = "Sway" },
            .{ .key = "hyprland", .name = "Hyprland" },
            .{ .key = "Xwayland", .name = "Xwayland" },
            .{ .key = "mizu", .name = "Mizu" },
            .{ .key = "mako", .name = "Mako" },
            .{ .key = "dunst", .name = "Dunst" },
            .{ .key = "waybar", .name = "Waybar" },
            .{ .key = "nvim", .name = "Neovim" },
            .{ .key = "bash", .name = "Bash" },
            .{ .key = "zsh", .name = "Zsh" },
            .{ .key = "fish", .name = "Fish" },
        };
        for (known_services) |svc| {
            if (std.ascii.eqlIgnoreCase(exe, svc.key) or std.ascii.eqlIgnoreCase(comm, svc.key)) {
                return svc.name;
            }
        }

        const raw = if (exe.len > 0) exe else comm;
        if (raw.len == 0) return "Process";
        const n = @min(raw.len, buf.len);
        @memcpy(buf[0..n], raw[0..n]);
        if (buf[0] >= 'a' and buf[0] <= 'z') {
            buf[0] = buf[0] - 32;
        }
        return buf[0..n];
    }

    pub fn groupProcesses(self: *MemoryMonitor) void {
        for (self.groups.items) |*grp| {
            grp.deinit(self.allocator);
        }
        self.groups.clearRetainingCapacity();

        var pid_map = std.AutoHashMap(u32, usize).init(self.allocator);
        defer pid_map.deinit();
        for (self.processes.items, 0..) |p, i| {
            pid_map.put(p.pid, i) catch {};
        }

        for (self.processes.items) |p| {
            const root_pid = self.findAppRootPid(p.pid, &pid_map);
            const root_idx = pid_map.get(root_pid) orelse continue;
            const root_proc = &self.processes.items[root_idx];

            var name_buf: [128]u8 = [_]u8{0} ** 128;
            const app_name = self.resolveAppDisplayName(root_proc, &name_buf);

            var found: ?*ProcessGroup = null;
            for (self.groups.items) |*grp| {
                if (std.mem.eql(u8, grp.name[0..grp.name_len], app_name)) {
                    found = grp;
                    break;
                }
            }

            if (found) |grp| {
                grp.total_rss_kb += p.rss_kb;
                if (p.pid < grp.main_pid) grp.main_pid = p.pid;
                grp.procs.append(self.allocator, p) catch {};
            } else {
                var new_grp = ProcessGroup{
                    .main_pid = root_pid,
                    .total_rss_kb = p.rss_kb,
                    .procs = std.ArrayList(proc_mem.ProcessInfo).empty,
                    .expanded = self.isGroupExpanded(app_name),
                };
                const nlen = @min(app_name.len, 128);
                @memcpy(new_grp.name[0..nlen], app_name[0..nlen]);
                new_grp.name_len = nlen;

                new_grp.procs.append(self.allocator, p) catch {};
                self.groups.append(self.allocator, new_grp) catch {};
            }
        }

        std.mem.sort(ProcessGroup, self.groups.items, {}, struct {
            fn lessThan(_: void, a: ProcessGroup, b: ProcessGroup) bool {
                return a.total_rss_kb > b.total_rss_kb;
            }
        }.lessThan);

        for (self.groups.items) |*grp| {
            std.mem.sort(proc_mem.ProcessInfo, grp.procs.items, {}, struct {
                fn lessThan(_: void, a: proc_mem.ProcessInfo, b: proc_mem.ProcessInfo) bool {
                    return a.rss_kb > b.rss_kb;
                }
            }.lessThan);
        }
    }

    pub fn refresh(self: *MemoryMonitor) void {
        const prev_pid = self.selectedPid();
        self.mem = proc_mem.collectMemInfo();
        proc_mem.collectProcesses(self.allocator, &self.processes) catch {};
        self.groupProcesses();
        self.rebuildFiltered(prev_pid);
    }

    // ---- Input ----------------------------------------------------------

    pub fn handleKey(self: *MemoryMonitor, sym: u32, utf8_bytes: []const u8, ctrl: bool, shift: bool) bool {
        if (sym == c.XKB_KEY_Escape) {
            self.running = false;
            return true;
        }

        if (!ctrl) {
            switch (sym) {
                c.XKB_KEY_Up => return self.moveSelection(-1),
                c.XKB_KEY_Down => return self.moveSelection(1),
                c.XKB_KEY_Page_Up => return self.moveSelection(-@as(isize, @intCast(visibleRows()))),
                c.XKB_KEY_Page_Down => return self.moveSelection(@as(isize, @intCast(visibleRows()))),
                c.XKB_KEY_Return, c.XKB_KEY_space => {
                    if (self.selected) |sel| {
                        if (sel < self.visible_rows.items.len) {
                            const row = self.visible_rows.items[sel];
                            if (row.kind == .group) {
                                const grp = &self.groups.items[row.group_idx];
                                grp.expanded = !grp.expanded;
                                self.setGroupExpanded(grp.name[0..grp.name_len], grp.expanded);
                                self.rebuildFiltered(grp.main_pid);
                                return true;
                            }
                        }
                    }
                },
                else => {},
            }
        }

        const before = hashText(self.filter.getText());
        const handled = self.filter.handleKey(sym, utf8_bytes, ctrl, shift);
        if (!handled) return false;

        const after = hashText(self.filter.getText());
        if (before != after) {
            self.rebuildFiltered(null);
            self.filter_scroll = 0.0;
            self.ensureFilterCaretVisible();
        }
        return true;
    }

    pub fn handlePointerMotion(self: *MemoryMonitor, x: i32, y: i32) bool {
        var changed = false;

        const new_hover = self.rowIndexAt(x, y);
        if (new_hover != self.hover) {
            self.hover = new_hover;
            changed = true;
        }

        if (self.drag_active and self.pointInFilter(x, y)) {
            const idx = self.cursorIndexFromX(
                self.filter.getText(),
                filterTextX() - self.filter_scroll,
                @as(f64, @floatFromInt(x)),
                self.cfg.typography.ui,
            );
            if (self.filter.selection_anchor == null) self.filter.selection_anchor = self.filter.cursor_idx;
            if (self.filter.cursor_idx != idx) {
                self.filter.cursor_idx = idx;
                changed = true;
            }
            self.ensureFilterCaretVisible();
        }

        return changed;
    }

    pub fn handlePointerLeave(self: *MemoryMonitor) bool {
        var changed = false;
        if (self.hover != null) {
            self.hover = null;
            changed = true;
        }
        if (self.drag_active) {
            self.drag_active = false;
            self.filter.handlePointerUp();
        }
        return changed;
    }

    pub fn handlePointerButton(self: *MemoryMonitor, x: i32, y: i32, button: u32, pressed: bool) bool {
        if (button != POINTER_BUTTON_LEFT) return false;

        if (!pressed) {
            const was_dragging = self.drag_active;
            self.drag_active = false;
            self.filter.handlePointerUp();
            return was_dragging;
        }

        if (self.filter.getText().len > 0 and self.pointInClear(x, y)) {
            self.filter.clear();
            self.rebuildFiltered(null);
            self.filter_scroll = 0.0;
            return true;
        }

        if (self.pointInFilter(x, y)) {
            self.filter.focused = true;
            self.drag_active = true;
            self.filter.cursor_idx = self.cursorIndexFromX(
                self.filter.getText(),
                filterTextX() - self.filter_scroll,
                @as(f64, @floatFromInt(x)),
                self.cfg.typography.ui,
            );
            self.filter.selection_anchor = null;
            self.ensureFilterCaretVisible();
            return true;
        }

        if (self.rowIndexAt(x, y)) |idx| {
            if (idx < self.visible_rows.items.len) {
                const row = self.visible_rows.items[idx];
                self.selected = idx;
                if (row.kind == .group) {
                    const grp = &self.groups.items[row.group_idx];
                    grp.expanded = !grp.expanded;
                    self.setGroupExpanded(grp.name[0..grp.name_len], grp.expanded);
                    self.rebuildFiltered(grp.main_pid);
                }
                return true;
            }
        }
        return false;
    }

    pub fn handlePointerAxis(self: *MemoryMonitor, x: i32, y: i32, delta: i32) bool {
        if (!self.pointInPanel(x, y)) return false;
        const max_scroll = self.maxScroll();
        if (max_scroll == 0) return false;

        if (delta > 0) {
            if (self.scroll >= max_scroll) return false;
            self.scroll = @min(max_scroll, self.scroll + 3);
            return true;
        }
        if (delta < 0) {
            if (self.scroll == 0) return false;
            self.scroll = self.scroll - @min(self.scroll, 3);
            return true;
        }
        return false;
    }

    pub fn isPointer(self: *MemoryMonitor, x: i32, y: i32) bool {
        return self.pointInFilter(x, y) or self.rowIndexAt(x, y) != null;
    }

    pub fn isTextInput(self: *MemoryMonitor, x: i32, y: i32) bool {
        return self.pointInFilter(x, y);
    }

    // ---- Layout ---------------------------------------------------------

    fn panelX() f64 {
        return INSET;
    }

    fn panelY() f64 {
        return INSET;
    }

    fn contentX0() f64 {
        return INSET + PAD;
    }

    fn contentX1() f64 {
        return INSET + PANEL_W - PAD;
    }

    fn listTop() f64 {
        return panelY() + LIST_TOP;
    }

    fn listBottom() f64 {
        return panelY() + PANEL_H - LIST_BOTTOM_PAD;
    }

    fn filterTop() f64 {
        return panelY() + FILTER_TOP;
    }

    fn filterWidth() f64 {
        return contentX1() - contentX0();
    }

    fn filterTextX() f64 {
        return contentX0() + FILTER_TEXT_LEFT;
    }

    fn filterInnerWidth() f64 {
        return filterWidth() - FILTER_TEXT_LEFT - FILTER_INNER_RIGHT;
    }

    fn nameX() f64 {
        return contentX0() + 6.0;
    }

    fn pidRight() f64 {
        return contentX0() + 246.0;
    }

    fn memRight() f64 {
        return contentX1() - 56.0;
    }

    fn pctRight() f64 {
        return contentX1() - 2.0;
    }

    fn nameMaxWidth() f64 {
        return pidRight() - nameX() - 22.0;
    }

    fn visibleRows() usize {
        const avail = listBottom() - listTop();
        if (avail <= 0.0) return 0;
        return @as(usize, @intFromFloat(std.math.floor(avail / ROW_H)));
    }

    // ---- Filtering ------------------------------------------------------

    fn selectedPid(self: *MemoryMonitor) ?u32 {
        const sel = self.selected orelse return null;
        if (sel >= self.visible_rows.items.len) return null;
        const row = self.visible_rows.items[sel];
        if (row.group_idx >= self.groups.items.len) return null;
        const grp = &self.groups.items[row.group_idx];
        if (row.kind == .group) return grp.main_pid;
        if (row.sub_idx >= grp.procs.items.len) return null;
        return grp.procs.items[row.sub_idx].pid;
    }

    fn rebuildFiltered(self: *MemoryMonitor, preserve_pid: ?u32) void {
        const needle = self.filter.getText();
        self.visible_rows.clearRetainingCapacity();

        for (self.groups.items, 0..) |*grp, gi| {
            const grp_name = grp.name[0..grp.name_len];
            var grp_match = (needle.len == 0) or containsIgnoreCase(grp_name, needle);
            if (!grp_match) {
                var pid_buf: [16]u8 = undefined;
                const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{grp.main_pid}) catch "";
                if (std.mem.indexOf(u8, pid_str, needle) != null) grp_match = true;
            }

            var any_sub_match = false;
            if (needle.len > 0) {
                for (grp.procs.items) |p| {
                    if (subprocessMatches(p, needle)) {
                        any_sub_match = true;
                        break;
                    }
                }
            }

            if (needle.len == 0 or grp_match or any_sub_match) {
                self.visible_rows.append(self.allocator, DisplayRow{
                    .kind = .group,
                    .group_idx = gi,
                    .sub_idx = 0,
                }) catch break;

                const should_expand = grp.expanded or (needle.len > 0 and any_sub_match);
                if (should_expand) {
                    for (grp.procs.items, 0..) |p, si| {
                        if (needle.len == 0 or grp_match or subprocessMatches(p, needle)) {
                            self.visible_rows.append(self.allocator, DisplayRow{
                                .kind = .subprocess,
                                .group_idx = gi,
                                .sub_idx = si,
                            }) catch break;
                        }
                    }
                }
            }
        }

        if (preserve_pid) |pid| {
            var found: ?usize = null;
            for (self.visible_rows.items, 0..) |row, vi| {
                const grp = &self.groups.items[row.group_idx];
                const row_pid = if (row.kind == .group) grp.main_pid else grp.procs.items[row.sub_idx].pid;
                if (row_pid == pid) {
                    found = vi;
                    break;
                }
            }
            self.selected = found;
        } else {
            self.selected = if (self.visible_rows.items.len > 0) 0 else null;
        }

        if (self.selected == null and self.visible_rows.items.len > 0) self.selected = 0;
        self.clampScroll();
        self.ensureSelectedVisible();
    }

    fn clampScroll(self: *MemoryMonitor) void {
        self.scroll = @min(self.scroll, self.maxScroll());
    }

    fn maxScroll(self: *MemoryMonitor) usize {
        const vis = visibleRows();
        if (self.visible_rows.items.len <= vis) return 0;
        return self.visible_rows.items.len - vis;
    }

    fn moveSelection(self: *MemoryMonitor, delta: isize) bool {
        const count = self.visible_rows.items.len;
        if (count == 0) return false;

        var current: isize = if (self.selected) |sel| @as(isize, @intCast(sel)) else 0;
        current += delta;
        if (current < 0) current = 0;
        const last: isize = @as(isize, @intCast(count - 1));
        if (current > last) current = last;

        const next: usize = @as(usize, @intCast(current));
        if (self.selected != null and self.selected.? == next) return false;
        self.selected = next;
        self.ensureSelectedVisible();
        return true;
    }

    fn ensureSelectedVisible(self: *MemoryMonitor) void {
        const sel = self.selected orelse return;
        const vis = visibleRows();
        if (vis == 0) return;

        if (sel < self.scroll) {
            self.scroll = sel;
        } else if (sel >= self.scroll + vis) {
            self.scroll = sel - vis + 1;
        }
        self.clampScroll();
    }

    fn ensureFilterCaretVisible(self: *MemoryMonitor) void {
        const ui_sz = self.cfg.typography.ui;
        const text = self.filter.getText();
        const inner = filterInnerWidth();
        const caret = self.measure.measureTextWithSize(text[0..@min(self.filter.cursor_idx, text.len)], ui_sz);

        if (@as(f64, @floatFromInt(caret)) - self.filter_scroll > inner - 2.0) {
            self.filter_scroll = @as(f64, @floatFromInt(caret)) - inner + 2.0;
        }
        if (@as(f64, @floatFromInt(caret)) - self.filter_scroll < 0.0) {
            self.filter_scroll = @as(f64, @floatFromInt(caret));
        }

        const total = self.measure.measureTextWithSize(text, ui_sz);
        const max_scroll = @max(0.0, @as(f64, @floatFromInt(total)) - inner + 2.0);
        self.filter_scroll = std.math.clamp(self.filter_scroll, 0.0, max_scroll);
    }

    // ---- Hit testing ----------------------------------------------------

    fn rowIndexAt(self: *MemoryMonitor, x: i32, y: i32) ?usize {
        const fx: f64 = @as(f64, @floatFromInt(x));
        const fy: f64 = @as(f64, @floatFromInt(y));
        if (fy < listTop() or fy >= listBottom()) return null;
        if (fx < contentX0() - 8.0 or fx > contentX1() + 8.0) return null;

        const row: usize = @as(usize, @intFromFloat(std.math.floor((fy - listTop()) / ROW_H)));
        const idx = self.scroll + row;
        if (idx >= self.visible_rows.items.len) return null;
        return idx;
    }

    fn pointInPanel(self: *MemoryMonitor, x: i32, y: i32) bool {
        _ = self;
        const fx: f64 = @as(f64, @floatFromInt(x));
        const fy: f64 = @as(f64, @floatFromInt(y));
        return fx >= panelX() and fx <= panelX() + PANEL_W and fy >= panelY() and fy <= panelY() + PANEL_H;
    }

    fn pointInFilter(self: *MemoryMonitor, x: i32, y: i32) bool {
        _ = self;
        const fx: f64 = @as(f64, @floatFromInt(x));
        const fy: f64 = @as(f64, @floatFromInt(y));
        return fx >= contentX0() and fx <= contentX0() + filterWidth() and fy >= filterTop() and fy <= filterTop() + FILTER_H;
    }

    fn pointInClear(self: *MemoryMonitor, x: i32, y: i32) bool {
        _ = self;
        const fx: f64 = @as(f64, @floatFromInt(x));
        const fy: f64 = @as(f64, @floatFromInt(y));
        const cx = contentX1() - 20.0;
        const cy = filterTop() + FILTER_H / 2.0;
        return (fx - cx) * (fx - cx) + (fy - cy) * (fy - cy) <= 14.0 * 14.0;
    }

    // ---- Rendering ------------------------------------------------------

    fn alphaCol(base: Color, a: f64) Color {
        const aa = @as(u8, @intFromFloat(@as(f64, @floatFromInt(base.a)) * std.math.clamp(a, 0.0, 1.0)));
        return Color.init(aa, base.r, base.g, base.b);
    }

    /// Measure the advance width of `text[0..end]` at `size_px` for caret placement.
    fn measurePrefixWidth(self: *MemoryMonitor, text: []const u8, end: usize, size_px: u32) f64 {
        var total: f64 = 0.0;
        var utf8_view = std.unicode.Utf8View.init(text[0..end]) catch return 0.0;
        var it = utf8_view.iterator();
        while (it.nextCodepoint()) |cp| {
            if (self.measure.getOrLoadGlyph(cp, size_px)) |cg| {
                total += @as(f64, @floatFromInt(cg.advance_x));
            } else {
                total += @as(f64, @floatFromInt(size_px)) / 2.0;
            }
        }
        return total;
    }

    /// Return the byte index closest to `px` within `text` starting at `origin_x`.
    fn cursorIndexFromX(self: *MemoryMonitor, text: []const u8, origin_x: f64, px: f64, size_px: u32) usize {
        if (text.len == 0) return 0;
        const rel = px - origin_x;
        if (rel <= 0.0) return 0;
        var closest: usize = 0;
        var min_dist = std.math.floatMax(f64);
        var idx: usize = 0;
        while (true) {
            const w = self.measure.measureTextWithSize(text[0..idx], size_px);
            const dist = @abs(@as(f64, @floatFromInt(w)) - rel);
            if (dist < min_dist) {
                min_dist = dist;
                closest = idx;
            }
            if (idx >= text.len) break;
            const seq_len = std.unicode.utf8ByteSequenceLength(text[idx]) catch 1;
            idx = @min(idx + seq_len, text.len);
        }
        return closest;
    }

    pub fn render(self: *MemoryMonitor, target: renderer.Renderer, scale: u32) void {
        const th = self.cfg.theme;
        const is_light = th.panel_bg.isLight();
        const overlay = if (is_light) Color.rgb(0, 0, 0) else Color.rgb(255, 255, 255);
        const text_main = th.text_main;
        const text_muted = th.text_muted;
        const accent = th.accent;

        target.clear(Color.transparent);

        const inset: u32 = @intFromFloat(INSET * @as(f64, @floatFromInt(scale)));
        const panel_w: u32 = @intFromFloat(PANEL_W * @as(f64, @floatFromInt(scale)));
        const panel_h: u32 = @intFromFloat(PANEL_H * @as(f64, @floatFromInt(scale)));
        target.drawDropShadow(
            @intCast(inset),
            @intCast(inset),
            panel_w,
            panel_h,
            @intFromFloat(16 * @as(f64, @floatFromInt(scale))),
            8 * scale,
            Color.init(61, 0, 0, 0),
        );

        var ui = ui_mod.Ui.begin(
            self.allocator,
            &self.measure,
            target.width,
            target.height,
            scale,
            -1,
            -1,
            false,
            1.0 / 60.0,
        ) catch return;
        defer ui.deinit();

        ui.root(.{
            .direction = .column,
            .padding = .all(ui.su(@intFromFloat(INSET))),
            .align_x = .left,
            .align_y = .top,
        });

        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
            .direction = .column,
            .padding = .{ .left = ui.su(PAD), .right = ui.su(PAD) },
            .bg = th.panel_bg,
            .radius = ui.f(16),
            .border = ui.su(1),
            .border_color = th.panel_border,
            .align_y = .top,
        });

        // Header: title, usage summary, and memory bar.
        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .fixed = ui.s(66) },
            .direction = .column,
            .padding = .{ .top = ui.su(14) },
            .gap = ui.su(6),
            .align_y = .top,
        });

        const used_gib = @as(f64, @floatFromInt(self.mem.used_kb)) / 1048576.0;
        const total_gib = @as(f64, @floatFromInt(self.mem.total_kb)) / 1048576.0;
        const percent = self.mem.used_percent;
        var pct_buf: [32]u8 = undefined;
        const pct_str = std.fmt.bufPrint(&pct_buf, "{d:.0}%", .{percent}) catch "0%";
        var mem_buf: [64]u8 = undefined;
        const mem_str = std.fmt.bufPrint(&mem_buf, "{d:.1} / {d:.1} GB", .{ used_gib, total_gib }) catch "";

        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .fixed = ui.s(24) },
            .direction = .row,
            .gap = ui.su(8),
            .align_y = .center,
        });
        ui.text("Memory", .{ .size = self.cfg.typography.title * scale, .color = text_main });
        ui.spacerSized(.{ .grow = .{} }, .{ .fixed = 0 });
        ui.text(mem_str, .{ .size = self.cfg.typography.secondary * scale, .color = text_muted });
        ui.text(pct_str, .{ .size = self.cfg.typography.secondary * scale, .color = accent });
        ui.close();

        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .fixed = ui.s(5) },
            .bg = alphaCol(overlay, if (is_light) 0.08 else 0.10),
            .radius = 2.5 * @as(f32, @floatFromInt(scale)),
        });
        ui.rect(
            .{ .percent = std.math.clamp(percent / 100.0, 0.0, 1.0) },
            .{ .grow = .{} },
            accent,
            2.5 * @as(f32, @floatFromInt(scale)),
            .{},
        );
        ui.close();
        ui.close(); // header

        // Filter field: the whole field is a Clay box with a custom leaf for
        // text, selection and caret rendering.
        _ = ui.open(.{
            .id = "mem-filter",
            .width = .{ .grow = .{} },
            .height = .{ .fixed = ui.s(FILTER_H) },
            .bg = alphaCol(overlay, if (is_light) 0.05 else 0.07),
            .radius = ui.f(9),
            .border = ui.su(1),
            .border_color = alphaCol(overlay, 0.10),
        });
        const filter_data = ui.allocator.create(MemFilterDraw) catch return;
        filter_data.* = .{ .panel = self, .scale = scale };
        const filter_custom = ui.allocator.create(ui_mod.Custom) catch return;
        filter_custom.* = .{ .callback = .{ .function = MemFilterDraw.draw, .data = filter_data } };
        ui.custom(.{ .grow = .{} }, .{ .grow = .{} }, filter_custom, 0);
        ui.close();
        ui.close(); // filter

        // Column headings at the same logical offsets used by pointer hit tests.
        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .fixed = ui.s(36) },
            .direction = .row,
            .align_y = .center,
        });
        _ = ui.open(.{
            .width = .{ .fixed = ui.s(246) },
            .height = .{ .grow = .{} },
            .direction = .row,
            .padding = .{ .left = ui.su(6) },
            .align_y = .center,
        });
        ui.text("Application", .{ .size = self.cfg.typography.secondary * scale, .color = text_muted });
        ui.spacerSized(.{ .grow = .{} }, .{ .fixed = 0 });
        ui.text("PID", .{ .size = self.cfg.typography.secondary * scale, .color = text_muted });
        ui.close();
        ui.text("Memory", .{
            .size = self.cfg.typography.secondary * scale,
            .color = text_muted,
            .width = ui.s(86),
            .text_align = .right,
        });
        _ = ui.open(.{
            .width = .{ .fixed = ui.s(56) },
            .height = .{ .grow = .{} },
            .padding = .{ .right = ui.su(2) },
            .align_x = .right,
            .align_y = .center,
        });
        ui.text("%", .{ .size = self.cfg.typography.secondary * scale, .color = text_muted });
        ui.close();
        ui.close(); // columns

        // Process list.
        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
            .direction = .column,
            .gap = 0,
            .clip_vertical = true,
            .align_y = .top,
        });

        if (self.visible_rows.items.len == 0) {
            _ = ui.open(.{
                .width = .{ .grow = .{} },
                .height = .{ .grow = .{} },
                .direction = .column,
                .align_x = .center,
                .align_y = .center,
                .gap = ui.su(6),
            });
            ui.text(icons.glyphs.memory, .{ .size = 28 * scale, .color = alphaCol(text_muted, 0.45) });
            ui.text("No processes match", .{ .size = 13 * scale, .color = text_muted });
            ui.text("Try a different filter", .{ .size = 11 * scale, .color = alphaCol(text_muted, 0.6) });
            ui.close();
        } else {
            const vis = visibleRows();
            var i: usize = 0;
            while (i < vis) : (i += 1) {
                const fi = self.scroll + i;
                if (fi >= self.visible_rows.items.len) break;
                const row = self.visible_rows.items[fi];
                if (row.group_idx >= self.groups.items.len) break;
                const grp = &self.groups.items[row.group_idx];
                const is_selected = self.selected != null and self.selected.? == fi;
                const is_hovered = self.hover != null and self.hover.? == fi;

                const row_bg: ?Color = if (is_selected)
                    alphaCol(accent, 0.16)
                else if (is_hovered)
                    alphaCol(overlay, if (is_light) 0.045 else 0.06)
                else
                    null;

                _ = ui.open(.{
                    .width = .{ .grow = .{} },
                    .height = .{ .fixed = ui.s(ROW_H) },
                    .direction = .row,
                    .bg = row_bg,
                    .radius = ui.f(7),
                    .align_y = .center,
                });

                if (is_selected) {
                    ui.rect(.{ .fixed = ui.s(3) }, .{ .fixed = ui.s(18) }, accent, 1.5 * @as(f32, @floatFromInt(scale)), .{});
                }

                if (row.kind == .group) {
                    _ = ui.open(.{
                        .width = .{ .fixed = ui.s(if (is_selected) 243 else 246) },
                        .height = .{ .grow = .{} },
                        .direction = .row,
                        .padding = .{ .left = ui.su(if (is_selected) 3 else 6) },
                        .gap = ui.su(4),
                        .align_y = .center,
                        .clip_horizontal = true,
                    });

                    if (grp.procs.items.len > 1) {
                        const chevron = if (grp.expanded) "▾" else "▸";
                        ui.text(chevron, .{ .size = (self.cfg.typography.secondary - 1) * scale, .color = if (grp.expanded) accent else text_muted });
                    } else {
                        ui.spacerSized(.{ .fixed = ui.s(10) }, .{ .fixed = 0 });
                    }

                    const grp_name = grp.name[0..grp.name_len];
                    var label_buf: [160]u8 = undefined;
                    const full_label = if (grp.procs.items.len > 1)
                        std.fmt.bufPrint(&label_buf, "{s} ({d})", .{ grp_name, grp.procs.items.len }) catch grp_name
                    else
                        grp_name;

                    var name_buf: [160]u8 = undefined;
                    const max_w = nameMaxWidth() - 14.0;
                    const name = renderer.truncateText(&self.row_measure, full_label, @intFromFloat(max_w * @as(f64, @floatFromInt(scale))), self.cfg.typography.secondary * scale, &name_buf);
                    ui.text(name, .{ .size = self.cfg.typography.secondary * scale, .color = th.text_bright });
                    ui.spacerSized(.{ .grow = .{} }, .{ .fixed = 0 });
                    var pid_buf: [16]u8 = undefined;
                    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{grp.main_pid}) catch "";
                    ui.text(pid_str, .{ .size = self.cfg.typography.secondary * scale, .color = text_muted });
                    ui.close();

                    var mem_row_buf: [32]u8 = undefined;
                    const mem_row_str = formatMemory(&mem_row_buf, grp.total_rss_kb);
                    ui.text(mem_row_str, .{
                        .size = self.cfg.typography.secondary * scale,
                        .color = text_main,
                        .width = ui.s(86),
                        .text_align = .right,
                    });

                    var pct_row_buf: [24]u8 = undefined;
                    const pct_row = if (self.mem.total_kb > 0)
                        @as(f64, @floatFromInt(grp.total_rss_kb)) * 100.0 / @as(f64, @floatFromInt(self.mem.total_kb))
                    else
                        0.0;
                    const pct_row_str = std.fmt.bufPrint(&pct_row_buf, "{d:.1}%", .{pct_row}) catch "";
                    _ = ui.open(.{
                        .width = .{ .fixed = ui.s(56) },
                        .height = .{ .grow = .{} },
                        .padding = .{ .right = ui.su(2) },
                        .align_x = .right,
                        .align_y = .center,
                    });
                    ui.text(pct_row_str, .{ .size = self.cfg.typography.secondary * scale, .color = accent });
                    ui.close();
                } else {
                    const proc = grp.procs.items[row.sub_idx];

                    // Subprocesses show only their command and RAM usage
                    _ = ui.open(.{
                        .width = .{ .grow = .{} },
                        .height = .{ .grow = .{} },
                        .direction = .row,
                        .padding = .{ .left = ui.su(if (is_selected) 16 else 19) },
                        .gap = ui.su(6),
                        .align_y = .center,
                        .clip_horizontal = true,
                    });

                    ui.text("↳", .{ .size = (self.cfg.typography.secondary - 2) * scale, .color = alphaCol(text_muted, 0.65) });

                    var cmd_fmt_buf: [256]u8 = undefined;
                    const clean_cmd = formatSubprocessCommand(&cmd_fmt_buf, proc.cmdline[0..proc.cmdline_len], proc.name[0..proc.name_len]);

                    var sub_buf: [256]u8 = undefined;
                    const sub_max_w: f64 = (PANEL_W - 2 * PAD) - 120.0 - 24.0;
                    const sub_name = renderer.truncateText(
                        &self.row_measure,
                        clean_cmd,
                        @intFromFloat(sub_max_w * @as(f64, @floatFromInt(scale))),
                        (self.cfg.typography.secondary - 1) * scale,
                        &sub_buf,
                    );
                    ui.text(sub_name, .{
                        .size = (self.cfg.typography.secondary - 1) * scale,
                        .color = alphaCol(text_main, 0.9),
                    });
                    ui.close();

                    _ = ui.open(.{
                        .width = .{ .fixed = ui.s(142) },
                        .height = .{ .grow = .{} },
                        .padding = .{ .right = ui.su(8) },
                        .align_x = .right,
                        .align_y = .center,
                    });
                    var mem_row_buf: [32]u8 = undefined;
                    const mem_row_str = formatMemory(&mem_row_buf, proc.rss_kb);
                    ui.text(mem_row_str, .{
                        .size = (self.cfg.typography.secondary - 1) * scale,
                        .color = alphaCol(text_main, 0.85),
                    });
                    ui.close();
                }

                ui.close(); // row
            }
        }
        ui.close(); // list
        ui.close(); // panel
        ui.close(); // root

        const commands = ui.endLayout();
        ui.render(target, commands);
        self.renderScrollbarDraw(target, overlay, scale);
    }

    fn drawFilterContent(self: *MemoryMonitor, target: renderer.Renderer, rect: renderer.Rect, scale: u32) void {
        const text_muted = self.cfg.theme.text_muted;
        const text_main = self.cfg.theme.text_main;
        const accent = self.cfg.theme.accent;
        const ui_sz = self.cfg.typography.ui * scale;
        const sc: i32 = @intCast(scale);
        const fx: f64 = @floatFromInt(rect.x);
        const fy: f64 = @floatFromInt(rect.y);
        const fw: f64 = @floatFromInt(rect.w);
        const fh: f64 = @floatFromInt(rect.h);

        icons.drawSvgIcon(
            target,
            self.allocator,
            "search",
            16 * scale,
            scale,
            @intFromFloat(fx + 14.0 * @as(f64, @floatFromInt(scale))),
            @intFromFloat(fy + fh / 2.0),
            text_muted,
        );

        const ascender: f64 = @floatFromInt(self.measure.ascender_px * sc);
        const text_height: f64 = @floatFromInt(self.measure.height_px * sc);
        const baseline = fy + (fh + ascender) / 2.0 - 0.5;
        const clip_x: i32 = @intFromFloat(fx + (FILTER_TEXT_LEFT - 2.0) * @as(f64, @floatFromInt(scale)));
        const clip_y: i32 = @intFromFloat(fy + 4.0 * @as(f64, @floatFromInt(scale)));
        const clip_w: u32 = @intFromFloat((fw - FILTER_TEXT_LEFT - FILTER_INNER_RIGHT + 4.0) * @as(f64, @floatFromInt(scale)));
        const clip_h: u32 = @intFromFloat((fh - 8.0 * @as(f64, @floatFromInt(scale))));
        const clipped = target.withClip(renderer.Rect.init(clip_x, clip_y, clip_w, clip_h));

        const text = self.filter.getText();
        const tx: f64 = fx + (FILTER_TEXT_LEFT * @as(f64, @floatFromInt(scale))) - self.filter_scroll * @as(f64, @floatFromInt(scale));

        if (text.len == 0) {
            clipped.drawTextWithSize(&self.measure, "Filter processes\u{2026}", @intFromFloat(tx), @intFromFloat(baseline), ui_sz, alphaCol(text_muted, 0.75));
        } else {
            if (self.filter.selection_anchor) |anchor| {
                if (anchor != self.filter.cursor_idx) {
                    const lo = @min(anchor, self.filter.cursor_idx);
                    const hi = @max(anchor, self.filter.cursor_idx);
                    const x0 = tx + self.measurePrefixWidth(text, lo, ui_sz);
                    const x1 = tx + self.measurePrefixWidth(text, hi, ui_sz);
                    clipped.fillRoundedRect(
                        @intFromFloat(x0),
                        @intFromFloat(baseline - ascender - 1.0),
                        @intFromFloat(x1 - x0),
                        @intFromFloat(text_height + 2.0),
                        3 * scale,
                        alphaCol(accent, 0.30),
                    );
                }
            }
            clipped.drawTextWithSize(&self.measure, text, @intFromFloat(tx), @intFromFloat(baseline), ui_sz, text_main);
        }

        if (self.filter.focused) {
            const caret_x = tx + self.measurePrefixWidth(text, @min(self.filter.cursor_idx, text.len), ui_sz);
            clipped.fillRoundedRect(
                @intFromFloat(caret_x),
                @intFromFloat(baseline - ascender),
                @intFromFloat(1.5 * @as(f64, @floatFromInt(scale))),
                @intFromFloat(text_height),
                scale,
                accent,
            );
        }

        if (text.len > 0) {
            const cx: f64 = fx + fw - 20.0 * @as(f64, @floatFromInt(scale));
            const cy: f64 = fy + fh / 2.0;
            const r: f64 = 4.0 * @as(f64, @floatFromInt(scale));
            const line_w: f32 = @floatCast(1.4 * @as(f64, @floatFromInt(scale)));
            icons.drawLine(target, @floatCast(cx - r), @floatCast(cy - r), @floatCast(cx + r), @floatCast(cy + r), line_w, text_muted);
            icons.drawLine(target, @floatCast(cx + r), @floatCast(cy - r), @floatCast(cx - r), @floatCast(cy + r), line_w, text_muted);
        }
    }

    fn renderScrollbarDraw(self: *MemoryMonitor, target: renderer.Renderer, overlay: Color, scale: u32) void {
        const vis = visibleRows();
        const count = self.visible_rows.items.len;
        if (count <= vis or vis == 0) return;

        const s: f64 = @floatFromInt(scale);
        const top = listTop() * s;
        const bottom = listBottom() * s;
        const track_x = (panelX() + PANEL_W - 9.0) * s;
        const track_y = top + 2.0 * s;
        const track_h = bottom - top - 4.0 * s;
        if (track_h <= 0.0) return;

        target.fillRoundedRect(
            @intFromFloat(track_x),
            @intFromFloat(track_y),
            @intFromFloat(3.0 * s),
            @intFromFloat(track_h),
            @intFromFloat(2.0 * s),
            alphaCol(overlay, 0.07),
        );

        const max_scroll = count - vis;
        const ratio = @as(f64, @floatFromInt(vis)) / @as(f64, @floatFromInt(count));
        const thumb_h = @max(24.0 * s, track_h * ratio);
        const t = if (max_scroll > 0)
            @as(f64, @floatFromInt(self.scroll)) / @as(f64, @floatFromInt(max_scroll))
        else
            0.0;
        const thumb_y = track_y + (track_h - thumb_h) * t;

        target.fillRoundedRect(
            @intFromFloat(track_x),
            @intFromFloat(thumb_y),
            @intFromFloat(3.0 * s),
            @intFromFloat(thumb_h),
            @intFromFloat(2.0 * s),
            alphaCol(overlay, 0.24),
        );
    }


};

pub fn formatSubprocessCommand(buf: []u8, cmd: []const u8, name: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, cmd, " \t\r\n");
    if (trimmed.len == 0) return name;

    if (trimmed[0] == '/') {
        if (std.mem.indexOfScalar(u8, trimmed, ' ')) |sp| {
            const first_word = trimmed[0..sp];
            const bname = std.fs.path.basename(first_word);
            const rest = trimmed[sp..];
            return std.fmt.bufPrint(buf, "{s}{s}", .{ bname, rest }) catch trimmed;
        } else {
            return std.fs.path.basename(trimmed);
        }
    }
    return trimmed;
}

fn subprocessMatches(proc: proc_mem.ProcessInfo, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (containsIgnoreCase(proc.name[0..proc.name_len], needle)) return true;
    if (proc.exe_len > 0 and containsIgnoreCase(proc.exe[0..proc.exe_len], needle)) return true;
    if (proc.cmdline_len > 0 and containsIgnoreCase(proc.cmdline[0..proc.cmdline_len], needle)) return true;

    var pid_buf: [16]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{proc.pid}) catch return false;
    return std.mem.indexOf(u8, pid_str, needle) != null;
}

fn processMatches(proc: proc_mem.ProcessInfo, needle: []const u8) bool {
    if (needle.len == 0) return true;

    if (containsIgnoreCase(proc.name[0..proc.name_len], needle)) return true;

    var pid_buf: [16]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{proc.pid}) catch return false;
    return std.mem.indexOf(u8, pid_str, needle) != null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

fn hashText(text: []const u8) u64 {
    return std.hash.Wyhash.hash(0, text);
}

fn formatMemory(buf: []u8, kb: u64) []const u8 {
    const mb = @as(f64, @floatFromInt(kb)) / 1024.0;
    if (mb >= 1024.0) return std.fmt.bufPrint(buf, "{d:.1} GB", .{mb / 1024.0}) catch "";
    if (mb >= 100.0) return std.fmt.bufPrint(buf, "{d:.0} MB", .{mb}) catch "";
    return std.fmt.bufPrint(buf, "{d:.1} MB", .{mb}) catch "";
}

fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(@as(i64, ts.tv_nsec), 1_000_000);
}

test "memory monitor renders to argb buffer" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var mm = try MemoryMonitor.init(allocator, cfg);
    defer mm.deinit();

    const w = mm.width;
    const h = mm.height;
    const pixels = try allocator.alloc(u32, @as(usize, w) * h);
    defer allocator.free(pixels);
    @memset(pixels, 0);

    const ren = try renderer.Renderer.init(pixels.ptr, w, h, w * 4);
    mm.render(ren, 1);

    var nonzero: usize = 0;
    for (pixels) |px| {
        if (px != 0) nonzero += 1;
    }
    try std.testing.expect(nonzero > 0);
}

test "memory monitor filter typing and escape" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var mm = try MemoryMonitor.init(allocator, cfg);
    defer mm.deinit();

    try std.testing.expect(mm.handleKey(0, "x", false, false));
    try std.testing.expectEqualStrings("x", mm.filter.getText());

    try std.testing.expect(mm.handleKey(c.XKB_KEY_BackSpace, "", false, false));
    try std.testing.expectEqualStrings("", mm.filter.getText());

    try std.testing.expect(mm.handleKey(c.XKB_KEY_Escape, "", false, false));
    try std.testing.expect(!mm.running);
}

test "memory monitor filter matching" {
    var proc = proc_mem.ProcessInfo{
        .pid = 4242,
        .name = undefined,
        .name_len = 4,
        .rss_kb = 1024,
    };
    @memcpy(proc.name[0..4], "bash");
    try std.testing.expect(processMatches(proc, "BAS"));
    try std.testing.expect(!processMatches(proc, "zsh"));
}

test "memory monitor process grouping and expand toggle" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var mm = try MemoryMonitor.init(allocator, cfg);
    defer mm.deinit();

    // Inject synthetic processes
    mm.processes.clearRetainingCapacity();

    var p1 = proc_mem.ProcessInfo{ .pid = 100, .name_len = 6, .rss_kb = 2048, .cmdline_len = 16 };
    @memcpy(p1.name[0..6], "chrome");
    @memcpy(p1.cmdline[0..16], "/usr/bin/chrome ");

    const cmd2 = "/usr/bin/chrome --type=gpu";
    var p2 = proc_mem.ProcessInfo{ .pid = 105, .name_len = 6, .rss_kb = 4096, .cmdline_len = cmd2.len };
    @memcpy(p2.name[0..6], "chrome");
    @memcpy(p2.cmdline[0..cmd2.len], cmd2);

    const cmd3 = "/bin/bash ";
    var p3 = proc_mem.ProcessInfo{ .pid = 200, .name_len = 4, .rss_kb = 1024, .cmdline_len = cmd3.len };
    @memcpy(p3.name[0..4], "bash");
    @memcpy(p3.cmdline[0..cmd3.len], cmd3);

    try mm.processes.append(allocator, p1);
    try mm.processes.append(allocator, p2);
    try mm.processes.append(allocator, p3);

    // Rebuild groups
    for (mm.groups.items) |*grp| {
        grp.deinit(allocator);
    }
    mm.groups.clearRetainingCapacity();

    for (mm.processes.items) |p| {
        const pname = p.name[0..p.name_len];
        var found: ?*ProcessGroup = null;
        for (mm.groups.items) |*grp| {
            if (std.mem.eql(u8, grp.name[0..grp.name_len], pname)) {
                found = grp;
                break;
            }
        }
        if (found) |grp| {
            grp.total_rss_kb += p.rss_kb;
            if (p.pid < grp.main_pid) grp.main_pid = p.pid;
            try grp.procs.append(allocator, p);
        } else {
            var new_grp = ProcessGroup{
                .name_len = p.name_len,
                .main_pid = p.pid,
                .total_rss_kb = p.rss_kb,
                .procs = std.ArrayList(proc_mem.ProcessInfo).empty,
                .expanded = false,
            };
            @memcpy(new_grp.name[0..p.name_len], pname);
            try new_grp.procs.append(allocator, p);
            try mm.groups.append(allocator, new_grp);
        }
    }

    // Sort
    std.mem.sort(ProcessGroup, mm.groups.items, {}, struct {
        fn lessThan(_: void, a: ProcessGroup, b: ProcessGroup) bool {
            return a.total_rss_kb > b.total_rss_kb;
        }
    }.lessThan);

    mm.rebuildFiltered(null);

    // Initial state: 2 groups collapsed (chrome total 6144 KB, bash total 1024 KB)
    try std.testing.expectEqual(@as(usize, 2), mm.visible_rows.items.len);
    try std.testing.expectEqualStrings("chrome", mm.groups.items[0].name[0..mm.groups.items[0].name_len]);
    try std.testing.expectEqual(@as(u64, 6144), mm.groups.items[0].total_rss_kb);
    try std.testing.expectEqual(@as(usize, 2), mm.groups.items[0].procs.items.len);

    // Expand chrome group via handleKey Space
    mm.selected = 0;
    try std.testing.expect(mm.handleKey(c.XKB_KEY_space, " ", false, false));
    try std.testing.expect(mm.groups.items[0].expanded);
    try std.testing.expect(mm.isGroupExpanded("chrome"));

    // Visible rows now include chrome group + 2 subprocesses + bash group = 4 rows
    try std.testing.expectEqual(@as(usize, 4), mm.visible_rows.items.len);
    try std.testing.expectEqual(RowKind.group, mm.visible_rows.items[0].kind);
    try std.testing.expectEqual(RowKind.subprocess, mm.visible_rows.items[1].kind);
    try std.testing.expectEqual(RowKind.subprocess, mm.visible_rows.items[2].kind);
    try std.testing.expectEqual(RowKind.group, mm.visible_rows.items[3].kind);

    // Collapse chrome group
    try std.testing.expect(mm.handleKey(c.XKB_KEY_Return, "", false, false));
    try std.testing.expect(!mm.groups.items[0].expanded);
    try std.testing.expect(!mm.isGroupExpanded("chrome"));
    try std.testing.expectEqual(@as(usize, 2), mm.visible_rows.items.len);
}

test "memory monitor ancestry grouping for browsers, electron and terminals" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var mm = try MemoryMonitor.init(allocator, cfg);
    defer mm.deinit();

    mm.processes.clearRetainingCapacity();

    // Compositor (e.g. mango, pid=10)
    var p_comp = proc_mem.ProcessInfo{ .pid = 10, .ppid = 1, .name_len = 5, .exe_len = 5, .rss_kb = 10000 };
    @memcpy(p_comp.name[0..5], "mango");
    @memcpy(p_comp.exe[0..5], "mango");
    try mm.processes.append(allocator, p_comp);

    // Firefox main (pid=100, ppid=10)
    var p_ff = proc_mem.ProcessInfo{ .pid = 100, .ppid = 10, .name_len = 7, .exe_len = 7, .rss_kb = 50000 };
    @memcpy(p_ff.name[0..7], "firefox");
    @memcpy(p_ff.exe[0..7], "firefox");
    const cmd_ff = "/usr/lib/firefox/firefox";
    @memcpy(p_ff.cmdline[0..cmd_ff.len], cmd_ff);
    p_ff.cmdline_len = cmd_ff.len;
    try mm.processes.append(allocator, p_ff);

    // Firefox forkserver (pid=101, ppid=100)
    var p_fs = proc_mem.ProcessInfo{ .pid = 101, .ppid = 100, .name_len = 10, .exe_len = 7, .rss_kb = 10000 };
    @memcpy(p_fs.name[0..10], "forkserver");
    @memcpy(p_fs.exe[0..7], "firefox");
    const cmd_fs = "/usr/lib/firefox/firefox -contentproc forkserver";
    @memcpy(p_fs.cmdline[0..cmd_fs.len], cmd_fs);
    p_fs.cmdline_len = cmd_fs.len;
    try mm.processes.append(allocator, p_fs);

    // Firefox Web Content (pid=102, ppid=101)
    var p_wc = proc_mem.ProcessInfo{ .pid = 102, .ppid = 101, .name_len = 11, .exe_len = 7, .rss_kb = 40000 };
    @memcpy(p_wc.name[0..11], "Web Content");
    @memcpy(p_wc.exe[0..7], "firefox");
    const cmd_wc = "/usr/lib/firefox/firefox -contentproc tab";
    @memcpy(p_wc.cmdline[0..cmd_wc.len], cmd_wc);
    p_wc.cmdline_len = cmd_wc.len;
    try mm.processes.append(allocator, p_wc);

    // Foot terminal (pid=200, ppid=10)
    var p_foot = proc_mem.ProcessInfo{ .pid = 200, .ppid = 10, .name_len = 4, .exe_len = 4, .rss_kb = 8000 };
    @memcpy(p_foot.name[0..4], "foot");
    @memcpy(p_foot.exe[0..4], "foot");
    try mm.processes.append(allocator, p_foot);

    // Bash shell under Foot (pid=201, ppid=200)
    var p_bash = proc_mem.ProcessInfo{ .pid = 201, .ppid = 200, .name_len = 4, .exe_len = 4, .rss_kb = 4000 };
    @memcpy(p_bash.name[0..4], "bash");
    @memcpy(p_bash.exe[0..4], "bash");
    try mm.processes.append(allocator, p_bash);

    // CLI tool running in Foot (pid=202, ppid=201)
    var p_tool = proc_mem.ProcessInfo{ .pid = 202, .ppid = 201, .name_len = 3, .exe_len = 3, .rss_kb = 2000 };
    @memcpy(p_tool.name[0..3], "cat");
    @memcpy(p_tool.exe[0..3], "cat");
    try mm.processes.append(allocator, p_tool);

    // Standalone desktop app launched from terminal (pid=300, ppid=201)
    var p_nvim = proc_mem.ProcessInfo{ .pid = 300, .ppid = 201, .name_len = 4, .exe_len = 4, .rss_kb = 15000 };
    @memcpy(p_nvim.name[0..4], "nvim");
    @memcpy(p_nvim.exe[0..4], "nvim");
    try mm.processes.append(allocator, p_nvim);

    mm.groupProcesses();
    mm.rebuildFiltered(null);

    // Find groups
    var ff_grp: ?*ProcessGroup = null;
    var foot_grp: ?*ProcessGroup = null;
    var nvim_grp: ?*ProcessGroup = null;
    for (mm.groups.items) |*grp| {
        const gname = grp.name[0..grp.name_len];
        if (std.mem.eql(u8, gname, "Firefox")) ff_grp = grp;
        if (std.mem.indexOf(u8, gname, "Foot") != null) foot_grp = grp;
        if (std.mem.indexOf(u8, gname, "Neovim") != null or std.mem.indexOf(u8, gname, "Nvim") != null) nvim_grp = grp;
    }

    try std.testing.expect(ff_grp != null);
    try std.testing.expect(foot_grp != null);
    try std.testing.expect(nvim_grp != null);

    // Verify Firefox has all 3 processes grouped together (main, forkserver, Web Content)
    try std.testing.expectEqual(@as(usize, 3), ff_grp.?.procs.items.len);
    try std.testing.expectEqual(@as(u64, 100000), ff_grp.?.total_rss_kb);

    // Verify Foot has 3 processes (foot, bash, cat)
    try std.testing.expectEqual(@as(usize, 3), foot_grp.?.procs.items.len);
    try std.testing.expectEqual(@as(u64, 14000), foot_grp.?.total_rss_kb);

    // Verify Neovim is its own group despite being launched from Foot
    try std.testing.expectEqual(@as(usize, 1), nvim_grp.?.procs.items.len);
    try std.testing.expectEqual(@as(u64, 15000), nvim_grp.?.total_rss_kb);

    // Test clean command formatting
    var cbuf: [128]u8 = undefined;
    const clean = formatSubprocessCommand(&cbuf, "/usr/lib/firefox/firefox -contentproc tab", "firefox");
    try std.testing.expectEqualStrings("firefox -contentproc tab", clean);
}
