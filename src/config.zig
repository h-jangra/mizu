const std = @import("std");
const theme = @import("theme.zig");

pub const CustomButton = struct {
    label: []const u8,
    command: []const u8,
};

pub const Config = struct {
    height: u32 = 30,
    margin_top: u32 = 2,
    margin_bottom: u32 = 0,
    margin_left: u32 = 10,
    margin_right: u32 = 10,
    border_width: u32 = 0,
    bar_radius: u32 = 4,
    pill_radius: u32 = 2,
    panel_radius: u32 = 14,

    padding_x: u32 = 4,
    module_gap: u32 = 2,
    pill_padding_x: u32 = 6,
    pill_padding_y: u32 = 2,

    clock_format: []const u8 = "%I:%M %P",
    clock_interval_ms: u32 = 1000,

    theme: theme.Theme = theme.nordTheme(),

    buttons: std.ArrayList(CustomButton),

    pub fn init(allocator: std.mem.Allocator) Config {
        _ = allocator;
        const buttons = std.ArrayList(CustomButton).empty;

        const initial_theme = if (theme.loadSavedTheme()) |saved|
            saved.toTheme()
        else
            theme.nordTheme();

        return .{
            .theme = initial_theme,
            .buttons = buttons,
        };
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        self.buttons.deinit(allocator);
    }

    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) Config {
        var cfg = Config.init(allocator);

        const c_path = allocator.dupeZ(u8, path) catch return cfg;
        defer allocator.free(c_path);

        const f = @import("c.zig").c.fopen(c_path.ptr, "rb") orelse return cfg;
        defer _ = @import("c.zig").c.fclose(f);

        _ = @import("c.zig").c.fseek(f, 0, @import("c.zig").c.SEEK_END);
        const fsize = @import("c.zig").c.ftell(f);
        _ = @import("c.zig").c.fseek(f, 0, @import("c.zig").c.SEEK_SET);

        if (fsize <= 0 or fsize > 1024 * 1024) return cfg;
        const usize_len: usize = @intCast(fsize);

        const content = allocator.alloc(u8, usize_len) catch return cfg;
        defer allocator.free(content);

        const bytes_read = @import("c.zig").c.fread(content.ptr, 1, usize_len, f);
        const slice = content[0..bytes_read];

        var lines = std.mem.splitScalar(u8, slice, '\n');
        var in_buttons = false;
        var custom_buttons_cleared = false;

        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;

            if (line[0] == '[' and line[line.len - 1] == ']') {
                const section = line[1 .. line.len - 1];
                if (std.mem.eql(u8, section, "buttons")) {
                    in_buttons = true;
                    if (!custom_buttons_cleared) {
                        cfg.buttons.clearRetainingCapacity();
                        custom_buttons_cleared = true;
                    }
                } else {
                    in_buttons = false;
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
                    if (theme.ThemeKind.fromString(val)) |k| {
                        cfg.theme = k.toTheme();
                    }
                } else if (std.mem.eql(u8, key, "clock_format")) {
                    cfg.clock_format = allocator.dupe(u8, val) catch cfg.clock_format;
                } else if (std.mem.eql(u8, key, "font_family")) {
                    cfg.theme.font_family = allocator.dupe(u8, val) catch cfg.theme.font_family;
                } else if (std.mem.eql(u8, key, "font_size")) {
                    cfg.theme.font_size = std.fmt.parseInt(u32, val, 10) catch cfg.theme.font_size;
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
                }
            }
        }

        return cfg;
    }
};
