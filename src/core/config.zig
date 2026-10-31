const std = @import("std");
const theme = @import("theme.zig");
const c = @import("../c.zig").c;

pub const CustomButton = struct {
    label: []const u8,
    command: []const u8,
};

pub const CustomPanel = struct {
    name: []const u8,
    command: []const u8,
};

pub const Typography = struct {
    ui: u32 = 15,
    secondary: u32 = 13,
    heading: u32 = 18,
    title: u32 = 20,
    bar_text: u32 = 15,
    bar_icon: u32 = 20,
    quicksettings_text: u32 = 15,
    quicksettings_icon: u32 = 23,
    submenu_text: u32 = 15,
    calendar_text: u32 = 16,
    calendar_heading: u32 = 19,
    button_text: u32 = 15,
    keymap_text: u32 = 16,
};

pub const KeymapPosition = enum {
    top_left,
    top_center,
    top_right,
    center_left,
    center,
    center_right,
    bottom_left,
    bottom_center,
    bottom_right,

    pub fn fromString(str: []const u8) ?KeymapPosition {
        const s = std.mem.trim(u8, str, " \t\r\n");
        if (std.mem.eql(u8, s, "top-left") or std.mem.eql(u8, s, "top_left") or std.mem.eql(u8, s, "top-left-center")) return .top_left;
        if (std.mem.eql(u8, s, "top-center") or std.mem.eql(u8, s, "top_center") or std.mem.eql(u8, s, "top") or std.mem.eql(u8, s, "center-top")) return .top_center;
        if (std.mem.eql(u8, s, "top-right") or std.mem.eql(u8, s, "top_right")) return .top_right;
        if (std.mem.eql(u8, s, "center-left") or std.mem.eql(u8, s, "center_left") or std.mem.eql(u8, s, "left") or std.mem.eql(u8, s, "middle-left")) return .center_left;
        if (std.mem.eql(u8, s, "center") or std.mem.eql(u8, s, "middle") or std.mem.eql(u8, s, "center-center")) return .center;
        if (std.mem.eql(u8, s, "center-right") or std.mem.eql(u8, s, "center_right") or std.mem.eql(u8, s, "right") or std.mem.eql(u8, s, "middle-right")) return .center_right;
        if (std.mem.eql(u8, s, "bottom-left") or std.mem.eql(u8, s, "bottom_left")) return .bottom_left;
        if (std.mem.eql(u8, s, "bottom-center") or std.mem.eql(u8, s, "bottom_center") or std.mem.eql(u8, s, "bottom") or std.mem.eql(u8, s, "center-bottom")) return .bottom_center;
        if (std.mem.eql(u8, s, "bottom-right") or std.mem.eql(u8, s, "bottom_right")) return .bottom_right;
        return null;
    }

    pub fn toString(self: KeymapPosition) []const u8 {
        return switch (self) {
            .top_left => "top-left",
            .top_center => "top-center",
            .top_right => "top-right",
            .center_left => "center-left",
            .center => "center",
            .center_right => "center-right",
            .bottom_left => "bottom-left",
            .bottom_center => "bottom-center",
            .bottom_right => "bottom-right",
        };
    }
};

pub fn saveKeymapPosition(pos: KeymapPosition) void {
    var dir_buf: [512]u8 = undefined;
    var file_buf: [512]u8 = undefined;
    const home_opt = c.getenv("HOME");
    if (home_opt == null) return;
    const home = std.mem.span(home_opt.?);

    const dir_path = std.fmt.bufPrintSentinel(&dir_buf, "{s}/.cache/mizu", .{home}, 0) catch return;
    _ = c.mkdir(dir_path.ptr, 0o755);

    const file_path = std.fmt.bufPrintSentinel(&file_buf, "{s}/.cache/mizu/keymap_position", .{home}, 0) catch return;
    const f = c.fopen(file_path.ptr, "wb") orelse return;
    defer _ = c.fclose(f);

    const s = pos.toString();
    _ = c.fwrite(s.ptr, 1, s.len, f);
    _ = c.fwrite("\n", 1, 1, f);
}

pub fn loadSavedKeymapPosition() ?KeymapPosition {
    var file_buf: [512]u8 = undefined;
    const home_opt = c.getenv("HOME");
    if (home_opt == null) return null;
    const home = std.mem.span(home_opt.?);

    const file_path = std.fmt.bufPrintSentinel(&file_buf, "{s}/.cache/mizu/keymap_position", .{home}, 0) catch return null;
    const f = c.fopen(file_path.ptr, "rb") orelse return null;
    defer _ = c.fclose(f);

    var buf: [64]u8 = undefined;
    const n = c.fread(&buf, 1, buf.len - 1, f);
    if (n == 0) return null;
    buf[n] = 0;
    return KeymapPosition.fromString(buf[0..n]);
}

pub fn saveKeymapSize(size: u32) void {
    var dir_buf: [512]u8 = undefined;
    var file_buf: [512]u8 = undefined;
    const home_opt = c.getenv("HOME");
    if (home_opt == null) return;
    const home = std.mem.span(home_opt.?);

    const dir_path = std.fmt.bufPrintSentinel(&dir_buf, "{s}/.cache/mizu", .{home}, 0) catch return;
    _ = c.mkdir(dir_path.ptr, 0o755);

    const file_path = std.fmt.bufPrintSentinel(&file_buf, "{s}/.cache/mizu/keymap_size", .{home}, 0) catch return;
    const f = c.fopen(file_path.ptr, "wb") orelse return;
    defer _ = c.fclose(f);

    var num_buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&num_buf, "{d}\n", .{size}) catch return;
    _ = c.fwrite(s.ptr, 1, s.len, f);
}

pub fn loadSavedKeymapSize() ?u32 {
    var file_buf: [512]u8 = undefined;
    const home_opt = c.getenv("HOME");
    if (home_opt == null) return null;
    const home = std.mem.span(home_opt.?);

    const file_path = std.fmt.bufPrintSentinel(&file_buf, "{s}/.cache/mizu/keymap_size", .{home}, 0) catch return null;
    const f = c.fopen(file_path.ptr, "rb") orelse return null;
    defer _ = c.fclose(f);

    var buf: [32]u8 = undefined;
    const n = c.fread(&buf, 1, buf.len - 1, f);
    if (n == 0) return null;
    buf[n] = 0;
    const s = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return std.fmt.parseInt(u32, s, 10) catch null;
}

fn parseFontSize(val: []const u8, fallback: u32) u32 {
    const size = std.fmt.parseInt(u32, val, 10) catch return fallback;
    if (size < 8 or size > 96) return fallback;
    return size;
}

pub const ModuleKind = enum {
    launcher,
    workspaces,
    buttons,
    keymaps,
    clock,
    mpris,
    recorder,
    tray,
    battery,
    memory,
    network,
    bluetooth,
    volume,
    quicksettings,
    theme_switch,
    separator,

    pub fn fromString(str: []const u8) ?ModuleKind {
        const s = std.mem.trim(u8, str, " \t\r\n");
        if (std.mem.eql(u8, s, "launcher") or std.mem.eql(u8, s, "menu") or std.mem.eql(u8, s, "app")) return .launcher;
        if (std.mem.eql(u8, s, "workspaces") or std.mem.eql(u8, s, "tags") or std.mem.eql(u8, s, "ws")) return .workspaces;
        if (std.mem.eql(u8, s, "buttons") or std.mem.eql(u8, s, "custom_buttons")) return .buttons;
        if (std.mem.eql(u8, s, "keymaps") or std.mem.eql(u8, s, "keys") or std.mem.eql(u8, s, "keymap") or std.mem.eql(u8, s, "keyviz")) return .keymaps;
        if (std.mem.eql(u8, s, "clock") or std.mem.eql(u8, s, "time") or std.mem.eql(u8, s, "date")) return .clock;
        if (std.mem.eql(u8, s, "mpris") or std.mem.eql(u8, s, "music") or std.mem.eql(u8, s, "media")) return .mpris;
        if (std.mem.eql(u8, s, "recorder") or std.mem.eql(u8, s, "record") or std.mem.eql(u8, s, "screenrec")) return .recorder;
        if (std.mem.eql(u8, s, "tray") or std.mem.eql(u8, s, "systray") or std.mem.eql(u8, s, "sni")) return .tray;
        if (std.mem.eql(u8, s, "battery") or std.mem.eql(u8, s, "bat")) return .battery;
        if (std.mem.eql(u8, s, "memory") or std.mem.eql(u8, s, "mem") or std.mem.eql(u8, s, "ram")) return .memory;
        if (std.mem.eql(u8, s, "network") or std.mem.eql(u8, s, "wifi") or std.mem.eql(u8, s, "net")) return .network;
        if (std.mem.eql(u8, s, "bluetooth") or std.mem.eql(u8, s, "bt")) return .bluetooth;
        if (std.mem.eql(u8, s, "volume") or std.mem.eql(u8, s, "audio") or std.mem.eql(u8, s, "sound")) return .volume;
        if (std.mem.eql(u8, s, "quicksettings") or std.mem.eql(u8, s, "qs") or std.mem.eql(u8, s, "aggregate")) return .quicksettings;
        if (std.mem.eql(u8, s, "theme_switch") or std.mem.eql(u8, s, "theme") or std.mem.eql(u8, s, "themes")) return .theme_switch;
        if (std.mem.eql(u8, s, "separator") or std.mem.eql(u8, s, "sep") or std.mem.eql(u8, s, "|")) return .separator;
        return null;
    }
};

pub const Config = struct {
    height: u32 = 30,
    margin_top: u32 = 2,
    margin_bottom: u32 = 0,
    margin_left: u32 = 10,
    margin_right: u32 = 10,
    border_width: u32 = 1,
    bar_radius: u32 = 12,
    pill_radius: u32 = 10,
    panel_radius: u32 = 16,

    padding_x: u32 = 4,
    module_gap: u32 = 2,
    pill_padding_x: u32 = 6,
    pill_padding_y: u32 = 2,

    clock_format: []const u8 = "%I:%M %P",
    clock_interval_ms: u32 = 1000,

    theme: theme.Theme = theme.nordTheme(),
    typography: Typography = .{},

    buttons: std.ArrayList(CustomButton),
    panels: std.ArrayList(CustomPanel),

    // Modular layout configuration
    modules_left: std.ArrayList(ModuleKind),
    modules_center: std.ArrayList(ModuleKind),
    modules_right: std.ArrayList(ModuleKind),

    // Screen recorder settings
    recorder_cmd: []const u8 = "gpu-screen-recorder -w screen -f 60 -fm cfr -fallback-cpu-encoding yes -o \"$HOME/Videos/recording_$(date +%Y%m%d_%H%M%S).mp4\"",
    recorder_hide_when_idle: bool = false,

    // Earphone / Earbud safety volume limiting (auto limit to 20% on connect)
    earphone_safety: bool = true,

    // Wallpaper configuration
    wallpaper: ?[]const u8 = null,

    // Terminal command override (defaults to $TERMINAL or detected system terminal)
    terminal: ?[]const u8 = null,

    // Optional local iCalendar file for holidays. Relative paths resolve
    // against the Mizu config directory (~/.config/mizu).
    calendar_file: ?[]const u8 = null,

    // On-screen keymap overlay placement.
    keymap_position: KeymapPosition = .bottom_center,

    pub fn init(allocator: std.mem.Allocator) Config {
        _ = allocator;
        const buttons = std.ArrayList(CustomButton).empty;
        const panels = std.ArrayList(CustomPanel).empty;
        const modules_left = std.ArrayList(ModuleKind).empty;
        const modules_center = std.ArrayList(ModuleKind).empty;
        const modules_right = std.ArrayList(ModuleKind).empty;

        const initial_theme = theme.loadSavedThemeStruct();

        var keymap_pos = KeymapPosition.bottom_center;
        if (loadSavedKeymapPosition()) |pos| {
            keymap_pos = pos;
        }

        var typography = Typography{
            .keymap_text = 24,
        };
        if (loadSavedKeymapSize()) |sz| {
            typography.keymap_text = sz;
        }

        return .{
            .theme = initial_theme,
            .typography = typography,
            .keymap_position = keymap_pos,
            .buttons = buttons,
            .panels = panels,
            .modules_left = modules_left,
            .modules_center = modules_center,
            .modules_right = modules_right,
            .wallpaper = null,
            .calendar_file = null,
        };
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.wallpaper) |w| {
            allocator.free(w);
            self.wallpaper = null;
        }
        if (self.terminal) |t| {
            allocator.free(t);
            self.terminal = null;
        }
        if (self.calendar_file) |path| {
            allocator.free(path);
            self.calendar_file = null;
        }

        for (self.buttons.items) |b| {
            allocator.free(b.label);
            allocator.free(b.command);
        }
        self.buttons.deinit(allocator);

        for (self.panels.items) |p| {
            allocator.free(p.name);
            allocator.free(p.command);
        }
        self.panels.deinit(allocator);

        self.modules_left.deinit(allocator);
        self.modules_center.deinit(allocator);
        self.modules_right.deinit(allocator);
    }

    pub fn findPanel(self: *const Config, name: []const u8) ?[]const u8 {
        for (self.panels.items) |p| {
            if (std.mem.eql(u8, p.name, name)) {
                return p.command;
            }
        }
        return null;
    }

    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) Config {
        var cfg = Config.init(allocator);

        const c_path = allocator.dupeSentinel(u8, path, 0) catch return cfg;
        defer allocator.free(c_path);

        const f = @import("../c.zig").c.fopen(c_path.ptr, "rb") orelse return cfg;
        defer _ = @import("../c.zig").c.fclose(f);

        _ = @import("../c.zig").c.fseek(f, 0, @import("../c.zig").c.SEEK_END);
        const fsize = @import("../c.zig").c.ftell(f);
        _ = @import("../c.zig").c.fseek(f, 0, @import("../c.zig").c.SEEK_SET);

        if (fsize <= 0 or fsize > 1024 * 1024) return cfg;
        const usize_len: usize = @intCast(fsize);

        const content = allocator.alloc(u8, usize_len) catch return cfg;
        defer allocator.free(content);

        const bytes_read = @import("../c.zig").c.fread(content.ptr, 1, usize_len, f);
        const slice = content[0..bytes_read];

        var lines = std.mem.splitScalar(u8, slice, '\n');
        var in_buttons = false;
        var in_panels = false;
        var custom_buttons_cleared = false;
        var custom_panels_cleared = false;
        var configured_font_family: ?[]const u8 = null;

        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;

            if (line[0] == '[' and line[line.len - 1] == ']') {
                const section = line[1 .. line.len - 1];
                if (std.mem.eql(u8, section, "buttons")) {
                    in_buttons = true;
                    in_panels = false;
                    if (!custom_buttons_cleared) {
                        cfg.buttons.clearRetainingCapacity();
                        custom_buttons_cleared = true;
                    }
                } else if (std.mem.eql(u8, section, "panels")) {
                    in_panels = true;
                    in_buttons = false;
                    if (!custom_panels_cleared) {
                        cfg.panels.clearRetainingCapacity();
                        custom_panels_cleared = true;
                    }
                } else {
                    in_buttons = false;
                    in_panels = false;
                }
                continue;
            }

            if (in_buttons) {
                // Format: label = command
                if (std.mem.indexOfScalar(u8, line, '=')) |eq_idx| {
                    const label = std.mem.trim(u8, line[0..eq_idx], " \t");
                    const cmd = std.mem.trim(u8, line[eq_idx + 1 ..], " \t");
                    if (label.len > 0 and cmd.len > 0) {
                        const dup_label = allocator.dupe(u8, label) catch continue;
                        const dup_cmd = allocator.dupe(u8, cmd) catch continue;
                        cfg.buttons.append(allocator, .{ .label = dup_label, .command = dup_cmd }) catch {};
                    }
                }
                continue;
            }

            if (in_panels) {
                // Format: name = command
                if (std.mem.indexOfScalar(u8, line, '=')) |eq_idx| {
                    const name = std.mem.trim(u8, line[0..eq_idx], " \t");
                    const cmd = std.mem.trim(u8, line[eq_idx + 1 ..], " \t");
                    if (name.len > 0 and cmd.len > 0) {
                        const dup_name = allocator.dupe(u8, name) catch continue;
                        const dup_cmd = allocator.dupe(u8, cmd) catch continue;
                        cfg.panels.append(allocator, .{ .name = dup_name, .command = dup_cmd }) catch {};
                    }
                }
                continue;
            }

            if (std.mem.indexOfScalar(u8, line, '=')) |eq_idx| {
                const key = std.mem.trim(u8, line[0..eq_idx], " \t");
                const val = std.mem.trim(u8, line[eq_idx + 1 ..], " \t");

                if (std.mem.eql(u8, key, "height")) {
                    cfg.height = std.fmt.parseInt(u32, val, 10) catch cfg.height;
                } else if (std.mem.eql(u8, key, "margin_top")) {
                    cfg.margin_top = std.fmt.parseInt(u32, val, 10) catch cfg.margin_top;
                } else if (std.mem.eql(u8, key, "margin_bottom")) {
                    cfg.margin_bottom = std.fmt.parseInt(u32, val, 10) catch cfg.margin_bottom;
                } else if (std.mem.eql(u8, key, "margin_left")) {
                    cfg.margin_left = std.fmt.parseInt(u32, val, 10) catch cfg.margin_left;
                } else if (std.mem.eql(u8, key, "margin_right")) {
                    cfg.margin_right = std.fmt.parseInt(u32, val, 10) catch cfg.margin_right;
                } else if (std.mem.eql(u8, key, "bar_radius")) {
                    cfg.bar_radius = std.fmt.parseInt(u32, val, 10) catch cfg.bar_radius;
                } else if (std.mem.eql(u8, key, "pill_radius")) {
                    cfg.pill_radius = std.fmt.parseInt(u32, val, 10) catch cfg.pill_radius;
                } else if (std.mem.eql(u8, key, "panel_radius")) {
                    cfg.panel_radius = std.fmt.parseInt(u32, val, 10) catch cfg.panel_radius;
                } else if (std.mem.eql(u8, key, "border_width")) {
                    cfg.border_width = std.fmt.parseInt(u32, val, 10) catch cfg.border_width;
                } else if (std.mem.eql(u8, key, "theme") or std.mem.eql(u8, key, "theme_name")) {
                    cfg.theme = theme.loadTheme(val);
                } else if (std.mem.eql(u8, key, "clock_format")) {
                    cfg.clock_format = allocator.dupe(u8, val) catch cfg.clock_format;
                } else if (std.mem.eql(u8, key, "calendar_file")) {
                    if (cfg.calendar_file) |old| allocator.free(old);
                    cfg.calendar_file = if (val.len > 0) allocator.dupe(u8, val) catch null else null;
                } else if (std.mem.eql(u8, key, "terminal")) {
                    if (cfg.terminal) |old| allocator.free(old);
                    cfg.terminal = if (val.len > 0) allocator.dupe(u8, val) catch null else null;
                } else if (std.mem.eql(u8, key, "font_family")) {
                    configured_font_family = allocator.dupe(u8, val) catch cfg.theme.font_family;
                    cfg.theme.font_family = configured_font_family.?;
                } else if (std.mem.eql(u8, key, "ui")) {
                    cfg.typography.ui = parseFontSize(val, cfg.typography.ui);
                } else if (std.mem.eql(u8, key, "secondary")) {
                    cfg.typography.secondary = parseFontSize(val, cfg.typography.secondary);
                } else if (std.mem.eql(u8, key, "heading")) {
                    cfg.typography.heading = parseFontSize(val, cfg.typography.heading);
                } else if (std.mem.eql(u8, key, "title")) {
                    cfg.typography.title = parseFontSize(val, cfg.typography.title);
                } else if (std.mem.eql(u8, key, "bar_text")) {
                    cfg.typography.bar_text = parseFontSize(val, cfg.typography.bar_text);
                } else if (std.mem.eql(u8, key, "bar_icon")) {
                    cfg.typography.bar_icon = parseFontSize(val, cfg.typography.bar_icon);
                } else if (std.mem.eql(u8, key, "quicksettings_text")) {
                    cfg.typography.quicksettings_text = parseFontSize(val, cfg.typography.quicksettings_text);
                } else if (std.mem.eql(u8, key, "quicksettings_icon")) {
                    cfg.typography.quicksettings_icon = parseFontSize(val, cfg.typography.quicksettings_icon);
                } else if (std.mem.eql(u8, key, "submenu_text")) {
                    cfg.typography.submenu_text = parseFontSize(val, cfg.typography.submenu_text);
                } else if (std.mem.eql(u8, key, "calendar_text")) {
                    cfg.typography.calendar_text = parseFontSize(val, cfg.typography.calendar_text);
                } else if (std.mem.eql(u8, key, "calendar_heading")) {
                    cfg.typography.calendar_heading = parseFontSize(val, cfg.typography.calendar_heading);
                } else if (std.mem.eql(u8, key, "button_text")) {
                    cfg.typography.button_text = parseFontSize(val, cfg.typography.button_text);
                } else if (std.mem.eql(u8, key, "keymap_font_size") or std.mem.eql(u8, key, "keymap_text")) {
                    cfg.typography.keymap_text = parseFontSize(val, cfg.typography.keymap_text);
                } else if (std.mem.eql(u8, key, "keymap_position") or std.mem.eql(u8, key, "keymap_placement") or std.mem.eql(u8, key, "keymap_pos")) {
                    if (KeymapPosition.fromString(val)) |pos| {
                        cfg.keymap_position = pos;
                    }
                } else if (std.mem.eql(u8, key, "font_size")) {
                    cfg.typography.ui = parseFontSize(val, cfg.typography.ui);
                } else if (std.mem.eql(u8, key, "bar_font_size")) {
                    cfg.typography.bar_text = parseFontSize(val, cfg.typography.bar_text);
                } else if (std.mem.eql(u8, key, "panel_font_size")) {
                    cfg.typography.ui = parseFontSize(val, cfg.typography.ui);
                } else if (std.mem.eql(u8, key, "modules_left")) {
                    cfg.modules_left.clearRetainingCapacity();
                    var it = std.mem.splitScalar(u8, val, ',');
                    while (it.next()) |part| {
                        if (ModuleKind.fromString(part)) |mod| {
                            cfg.modules_left.append(allocator, mod) catch {};
                        }
                    }
                } else if (std.mem.eql(u8, key, "modules_center")) {
                    cfg.modules_center.clearRetainingCapacity();
                    var it = std.mem.splitScalar(u8, val, ',');
                    while (it.next()) |part| {
                        if (ModuleKind.fromString(part)) |mod| {
                            cfg.modules_center.append(allocator, mod) catch {};
                        }
                    }
                } else if (std.mem.eql(u8, key, "modules_right")) {
                    cfg.modules_right.clearRetainingCapacity();
                    var it = std.mem.splitScalar(u8, val, ',');
                    while (it.next()) |part| {
                        if (ModuleKind.fromString(part)) |mod| {
                            cfg.modules_right.append(allocator, mod) catch {};
                        }
                    }
                } else if (std.mem.eql(u8, key, "recorder_cmd")) {
                    cfg.recorder_cmd = allocator.dupe(u8, val) catch cfg.recorder_cmd;
                } else if (std.mem.eql(u8, key, "recorder_hide_when_idle")) {
                    cfg.recorder_hide_when_idle = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
                } else if (std.mem.eql(u8, key, "earphone_safety") or std.mem.eql(u8, key, "earbud_safety")) {
                    cfg.earphone_safety = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
                } else if (std.mem.eql(u8, key, "bar_bg")) {
                    cfg.theme.bar_bg = theme.Color.fromHex(val);
                } else if (std.mem.eql(u8, key, "bar_border")) {
                    cfg.theme.bar_border = theme.Color.fromHex(val);
                } else if (std.mem.eql(u8, key, "pill_bg")) {
                    cfg.theme.pill_bg = theme.Color.fromHex(val);
                } else if (std.mem.eql(u8, key, "ws_active_bg")) {
                    cfg.theme.ws_active_bg = theme.Color.fromHex(val);
                } else if (std.mem.eql(u8, key, "ws_active_fg")) {
                    cfg.theme.ws_active_fg = theme.Color.fromHex(val);
                } else if (std.mem.eql(u8, key, "panel_bg")) {
                    cfg.theme.panel_bg = theme.Color.fromHex(val);
                } else if (std.mem.eql(u8, key, "panel_border")) {
                    cfg.theme.panel_border = theme.Color.fromHex(val);
                } else if (std.mem.eql(u8, key, "network_bg")) {
                    cfg.theme.network_bg = theme.Color.fromHex(val);
                } else if (std.mem.eql(u8, key, "network_fg")) {
                    cfg.theme.network_fg = theme.Color.fromHex(val);
                } else if (std.mem.eql(u8, key, "wallpaper")) {
                    if (cfg.wallpaper) |w| allocator.free(w);
                    cfg.wallpaper = allocator.dupe(u8, val) catch null;
                }
            }
        }

        // Saved runtime theme takes precedence over static config.ini setting
        if (theme.loadSavedTheme()) |saved| {
            cfg.theme = theme.loadTheme(saved.id());
        }

        if (configured_font_family) |fam| {
            cfg.theme.font_family = fam;
        }

        cfg.theme.font_size = cfg.typography.ui;
        cfg.theme.bar_font_size = cfg.typography.bar_text;
        cfg.theme.panel_font_size = cfg.typography.ui;

        return cfg;
    }
};

test "Config custom buttons and panels lookup" {
    const allocator = std.testing.allocator;
    var cfg = Config.init(allocator);
    defer cfg.deinit(allocator);

    const b_label = try allocator.dupe(u8, "Term");
    const b_cmd = try allocator.dupe(u8, "foot");
    try cfg.buttons.append(allocator, .{ .label = b_label, .command = b_cmd });

    const p_name = try allocator.dupe(u8, "mixer");
    const p_cmd = try allocator.dupe(u8, "pavucontrol");
    try cfg.panels.append(allocator, .{ .name = p_name, .command = p_cmd });

    try std.testing.expectEqual(@as(usize, 1), cfg.buttons.items.len);
    try std.testing.expectEqualStrings("Term", cfg.buttons.items[0].label);
    try std.testing.expectEqualStrings("foot", cfg.buttons.items[0].command);

    try std.testing.expectEqual(@as(usize, 1), cfg.panels.items.len);
    try std.testing.expectEqualStrings("pavucontrol", cfg.findPanel("mixer").?);
    try std.testing.expect(cfg.findPanel("nonexistent") == null);
}

test "Config saved theme precedence" {
    const allocator = std.testing.allocator;
    theme.saveCurrentTheme(.catppuccin);
    defer theme.saveCurrentTheme(.nord);

    var cfg = Config.init(allocator);
    defer cfg.deinit(allocator);
    try std.testing.expectEqual(theme.ThemeKind.catppuccin, cfg.theme.kind);
}

test "KeymapPosition all 9 places string conversion and parsing" {
    const positions = [_]KeymapPosition{
        .top_left,
        .top_center,
        .top_right,
        .center_left,
        .center,
        .center_right,
        .bottom_left,
        .bottom_center,
        .bottom_right,
    };

    for (positions) |pos| {
        const s = pos.toString();
        const parsed = KeymapPosition.fromString(s);
        try std.testing.expect(parsed != null);
        try std.testing.expectEqual(pos, parsed.?);
    }

    try std.testing.expectEqual(KeymapPosition.center_left, KeymapPosition.fromString("left").?);
    try std.testing.expectEqual(KeymapPosition.center_right, KeymapPosition.fromString("right").?);
    try std.testing.expectEqual(KeymapPosition.center, KeymapPosition.fromString("middle").?);
}

test "save and load KeymapPosition and KeymapSize" {
    saveKeymapPosition(.center);
    try std.testing.expectEqual(KeymapPosition.center, loadSavedKeymapPosition().?);

    saveKeymapSize(24);
    try std.testing.expectEqual(@as(u32, 24), loadSavedKeymapSize().?);
}

test "Typography defaults and font size validation" {
    const defaults = Typography{};
    try std.testing.expectEqual(@as(u32, 15), defaults.ui);
    try std.testing.expectEqual(@as(u32, 13), defaults.secondary);
    try std.testing.expectEqual(@as(u32, 20), defaults.title);
    try std.testing.expectEqual(@as(u32, 23), defaults.quicksettings_icon);

    try std.testing.expectEqual(@as(u32, 15), parseFontSize("15", 13));
    try std.testing.expectEqual(@as(u32, 13), parseFontSize("7", 13));
    try std.testing.expectEqual(@as(u32, 13), parseFontSize("97", 13));
    try std.testing.expectEqual(@as(u32, 13), parseFontSize("abc", 13));
}
