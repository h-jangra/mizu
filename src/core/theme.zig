const std = @import("std");
const exec = @import("exec.zig");
const c = @import("../c.zig").c;

pub const Color = struct {
    a: u8,
    r: u8,
    g: u8,
    b: u8,

    pub const transparent = Color{ .a = 0, .r = 0, .g = 0, .b = 0 };

    pub fn init(a: u8, r: u8, g: u8, b: u8) Color {
        return .{ .a = a, .r = r, .g = g, .b = b };
    }

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .a = 255, .r = r, .g = g, .b = b };
    }

    pub fn hex(val: u24) Color {
        return .{
            .a = 255,
            .r = @intCast((val >> 16) & 0xFF),
            .g = @intCast((val >> 8) & 0xFF),
            .b = @intCast(val & 0xFF),
        };
    }

    pub fn toArgb(self: Color) u32 {
        return (@as(u32, self.a) << 24) |
            (@as(u32, self.r) << 16) |
            (@as(u32, self.g) << 8) |
            @as(u32, self.b);
    }

    pub fn fromArgb(val: u32) Color {
        return .{
            .a = @intCast((val >> 24) & 0xFF),
            .r = @intCast((val >> 16) & 0xFF),
            .g = @intCast((val >> 8) & 0xFF),
            .b = @intCast(val & 0xFF),
        };
    }

    pub fn fromHex(str: []const u8) Color {
        var s = std.mem.trim(u8, str, " \t\r\n;\"'");
        if (s.len > 0 and s[0] == '#') {
            s = s[1..];
        }

        if (s.len == 3) {
            const val = std.fmt.parseInt(u12, s, 16) catch return Color.rgb(0, 0, 0);
            const r_4: u8 = @intCast((val >> 8) & 0xF);
            const g_4: u8 = @intCast((val >> 4) & 0xF);
            const b_4: u8 = @intCast(val & 0xF);
            return Color.rgb(r_4 * 17, g_4 * 17, b_4 * 17);
        } else if (s.len == 6) {
            const val = std.fmt.parseInt(u24, s, 16) catch return Color.rgb(0, 0, 0);
            return Color.rgb(
                @intCast((val >> 16) & 0xFF),
                @intCast((val >> 8) & 0xFF),
                @intCast(val & 0xFF),
            );
        } else if (s.len == 8) {
            const val = std.fmt.parseInt(u32, s, 16) catch return Color.rgb(0, 0, 0);
            return Color.init(
                @intCast((val >> 24) & 0xFF),
                @intCast((val >> 16) & 0xFF),
                @intCast((val >> 8) & 0xFF),
                @intCast(val & 0xFF),
            );
        }
        return Color.rgb(0, 0, 0);
    }

    pub fn fromStr(str: []const u8) Color {
        const s = std.mem.trim(u8, str, " \t\r\n;\"'");
        if (s.len == 0) return Color.rgb(0, 0, 0);
        if (s[0] == '#') return fromHex(s);
        if (std.mem.startsWith(u8, s, "rgb(") or std.mem.startsWith(u8, s, "rgba(")) {
            const open_p = std.mem.indexOfScalar(u8, s, '(') orelse return Color.rgb(0, 0, 0);
            const close_p = std.mem.lastIndexOfScalar(u8, s, ')') orelse s.len;
            const inside = s[open_p + 1 .. close_p];
            var it = std.mem.splitScalar(u8, inside, ',');
            const r_str = std.mem.trim(u8, it.next() orelse return Color.rgb(0, 0, 0), " \t");
            const g_str = std.mem.trim(u8, it.next() orelse return Color.rgb(0, 0, 0), " \t");
            const b_str = std.mem.trim(u8, it.next() orelse return Color.rgb(0, 0, 0), " \t");

            const r = parseComp(r_str);
            const g = parseComp(g_str);
            const b = parseComp(b_str);
            var a: u8 = 255;
            if (it.next()) |a_raw| {
                const a_str = std.mem.trim(u8, a_raw, " \t");
                if (std.mem.endsWith(u8, a_str, "%")) {
                    const pct = std.fmt.parseFloat(f32, a_str[0 .. a_str.len - 1]) catch 100.0;
                    a = @intFromFloat(std.math.clamp(pct * 2.55, 0.0, 255.0));
                } else if (std.mem.indexOfScalar(u8, a_str, '.') != null) {
                    const flt = std.fmt.parseFloat(f32, a_str) catch 1.0;
                    a = @intFromFloat(std.math.clamp(flt * 255.0, 0.0, 255.0));
                } else {
                    const int_val = std.fmt.parseInt(u32, a_str, 10) catch 255;
                    a = if (int_val <= 1) @intCast(int_val * 255) else @intCast(@min(255, int_val));
                }
            }
            return Color.init(a, r, g, b);
        }
        return fromHex(s);
    }

    fn parseComp(s_in: []const u8) u8 {
        const s = std.mem.trim(u8, s_in, " \t");
        if (std.mem.endsWith(u8, s, "%")) {
            const pct = std.fmt.parseFloat(f32, s[0 .. s.len - 1]) catch 0.0;
            return @intFromFloat(std.math.clamp(pct * 2.55, 0.0, 255.0));
        }
        const val = std.fmt.parseInt(u8, s, 10) catch {
            const flt = std.fmt.parseFloat(f32, s) catch 0.0;
            return @intFromFloat(std.math.clamp(flt, 0.0, 255.0));
        };
        return val;
    }

    pub fn luminance(self: Color) f32 {
        const r_s = @as(f32, @floatFromInt(self.r)) / 255.0;
        const g_s = @as(f32, @floatFromInt(self.g)) / 255.0;
        const b_s = @as(f32, @floatFromInt(self.b)) / 255.0;

        const r = if (r_s <= 0.04045) r_s / 12.92 else std.math.pow(f32, (r_s + 0.055) / 1.055, 2.4);
        const g = if (g_s <= 0.04045) g_s / 12.92 else std.math.pow(f32, (g_s + 0.055) / 1.055, 2.4);
        const b = if (b_s <= 0.04045) b_s / 12.92 else std.math.pow(f32, (b_s + 0.055) / 1.055, 2.4);

        return 0.2126 * r + 0.7152 * g + 0.0722 * b;
    }

    pub fn isLight(self: Color) bool {
        return self.luminance() > 0.38;
    }

    pub fn formatHexRgb(self: Color, buf: *[8]u8) []const u8 {
        return std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ self.r, self.g, self.b }) catch "#000000";
    }

    pub fn formatRgba(self: Color, buf: []u8) []const u8 {
        const alpha_f = @as(f32, @floatFromInt(self.a)) / 255.0;
        return std.fmt.bufPrint(buf, "rgba({d}, {d}, {d}, {d:.2})", .{ self.r, self.g, self.b, alpha_f }) catch "rgba(0,0,0,1)";
    }

    pub fn contrastingTextColor(self: Color) Color {
        return if (self.isLight())
            Color.rgb(0x18, 0x1A, 0x1F)
        else
            Color.rgb(0xEC, 0xEF, 0xF4);
    }
};

/// Return the first family from a comma-separated fontconfig family list.
pub fn firstFamily(family: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, family, ',')) |idx| {
        return std.mem.trim(u8, family[0..idx], " \t");
    }
    return std.mem.trim(u8, family, " \t");
}

pub const ThemeKind = enum(u8) {
    frosted_neumorphic = 0,
    nord = 1,
    catppuccin = 2,
    tokyo_night = 3,
    rose_pine = 4,
    dracula = 5,

    pub const default_theme = ThemeKind.nord;
    pub const count: u8 = 6;

    // Backward compatibility aliases
    pub const mizu = ThemeKind.frosted_neumorphic;
    pub const pastel = ThemeKind.frosted_neumorphic;
    pub const frost = ThemeKind.nord;
    pub const noctalia = ThemeKind.tokyo_night;
    pub const material_you = ThemeKind.catppuccin;
    pub const gruvbox = ThemeKind.rose_pine;

    pub fn name(self: ThemeKind) []const u8 {
        return switch (self) {
            .frosted_neumorphic => "Frosted Neumorphic",
            .nord => "Nord Frost",
            .catppuccin => "Catppuccin Mocha",
            .tokyo_night => "Tokyo Night",
            .rose_pine => "Rosé Pine",
            .dracula => "Dracula",
        };
    }

    pub fn id(self: ThemeKind) []const u8 {
        return switch (self) {
            .frosted_neumorphic => "frosted-neumorphic",
            .nord => "nord",
            .catppuccin => "catppuccin",
            .tokyo_night => "tokyo-night",
            .rose_pine => "rose-pine",
            .dracula => "dracula",
        };
    }

    pub fn icon(self: ThemeKind) []const u8 {
        return switch (self) {
            .frosted_neumorphic => "󰖔",
            .nord => "󰜗",
            .catppuccin => "󰄛",
            .tokyo_night => "󰛓",
            .rose_pine => "󱎂",
            .dracula => "󰚌",
        };
    }

    pub fn next(self: ThemeKind) ThemeKind {
        const val = @intFromEnum(self);
        const next_val = (val + 1) % count;
        return @enumFromInt(next_val);
    }

    pub fn prev(self: ThemeKind) ThemeKind {
        const val = @intFromEnum(self);
        const prev_val = if (val == 0) count - 1 else val - 1;
        return @enumFromInt(prev_val);
    }

    pub fn fromString(str: []const u8) ?ThemeKind {
        const s = std.mem.trim(u8, str, " \t\r\n;\"'");
        if (std.ascii.eqlIgnoreCase(s, "frosted") or
            std.ascii.eqlIgnoreCase(s, "neumorphic") or
            std.ascii.eqlIgnoreCase(s, "frosted_neumorphic") or
            std.ascii.eqlIgnoreCase(s, "frosted-neumorphic") or
            std.ascii.eqlIgnoreCase(s, "frosted neumorphic") or
            std.ascii.eqlIgnoreCase(s, "pastel") or
            std.ascii.eqlIgnoreCase(s, "mizu") or
            std.ascii.eqlIgnoreCase(s, "default"))
        {
            return .frosted_neumorphic;
        }
        if (std.ascii.eqlIgnoreCase(s, "nord") or
            std.ascii.eqlIgnoreCase(s, "nord frost") or
            std.ascii.eqlIgnoreCase(s, "nord_frost") or
            std.ascii.eqlIgnoreCase(s, "nord-frost") or
            std.ascii.eqlIgnoreCase(s, "frost_nord") or
            std.ascii.eqlIgnoreCase(s, "frost"))
        {
            return .nord;
        }
        if (std.ascii.eqlIgnoreCase(s, "catppuccin") or
            std.ascii.eqlIgnoreCase(s, "catppuccin mocha") or
            std.ascii.eqlIgnoreCase(s, "catppuccin_mocha") or
            std.ascii.eqlIgnoreCase(s, "catppuccin-mocha") or
            std.ascii.eqlIgnoreCase(s, "mocha") or
            std.ascii.eqlIgnoreCase(s, "material_you") or
            std.ascii.eqlIgnoreCase(s, "materialyou"))
        {
            return .catppuccin;
        }
        if (std.ascii.eqlIgnoreCase(s, "tokyo_night") or
            std.ascii.eqlIgnoreCase(s, "tokyo night") or
            std.ascii.eqlIgnoreCase(s, "tokyonight") or
            std.ascii.eqlIgnoreCase(s, "tokyo-night") or
            std.ascii.eqlIgnoreCase(s, "tokyo") or
            std.ascii.eqlIgnoreCase(s, "noctalia"))
        {
            return .tokyo_night;
        }
        if (std.ascii.eqlIgnoreCase(s, "rose_pine") or
            std.ascii.eqlIgnoreCase(s, "rose pine") or
            std.ascii.eqlIgnoreCase(s, "rosé pine") or
            std.ascii.eqlIgnoreCase(s, "rosepine") or
            std.ascii.eqlIgnoreCase(s, "rose-pine") or
            std.ascii.eqlIgnoreCase(s, "rose") or
            std.ascii.eqlIgnoreCase(s, "gruvbox") or
            std.ascii.eqlIgnoreCase(s, "gruvbox material") or
            std.ascii.eqlIgnoreCase(s, "gruvbox_material") or
            std.ascii.eqlIgnoreCase(s, "gruvbox-material") or
            std.ascii.eqlIgnoreCase(s, "gruvbox_dark"))
        {
            return .rose_pine;
        }
        if (std.ascii.eqlIgnoreCase(s, "dracula") or
            std.ascii.eqlIgnoreCase(s, "ant-dracula") or
            std.ascii.eqlIgnoreCase(s, "ant_dracula") or
            std.ascii.eqlIgnoreCase(s, "ant dracula"))
        {
            return .dracula;
        }
        return null;
    }

    pub fn toTheme(self: ThemeKind) Theme {
        return switch (self) {
            .frosted_neumorphic => frostedNeumorphicTheme(),
            .nord => nordTheme(),
            .catppuccin => catppuccinTheme(),
            .tokyo_night => tokyoNightTheme(),
            .rose_pine => rosePineTheme(),
            .dracula => draculaTheme(),
        };
    }
};

pub const Theme = struct {
    kind: ThemeKind = .frosted_neumorphic,

    // Centralized Core Tokens
    base: Color,
    surface: Color,
    elevated: Color,
    accent: Color,
    accent_fg: Color,
    secondary: Color,
    text_main: Color,
    text_muted: Color,
    text_bright: Color,
    border: Color,
    border_focused: Color,
    input_bg: Color,
    input_border: Color,
    selection_bg: Color,

    // Semantic Status Colors
    error_color: Color,
    warning_color: Color,
    success_color: Color,

    // Neumorphic & Frosted Glass Tokens
    gradient_start: Color,
    gradient_mid: Color,
    gradient_end: Color,
    glass_highlight: Color,
    glass_border: Color,
    shadow_dark: Color,
    shadow_light: Color,
    slider_track: Color,
    slider_thumb: Color,
    slider_thumb_shadow: Color,
    toggle_on: Color,
    toggle_off: Color,
    btn_raised_bg: Color,
    btn_raised_hover: Color,

    // Radii Tokens (GNOME 40+ Inspired Consistent Geometry)
    radius_bar: u32 = 12,
    radius_panel: u32 = 20,
    radius_card: u32 = 14,
    radius_pill: u32 = 12,
    radius_button: u32 = 10,
    radius_slider: u32 = 8,

    // Spacing Tokens
    spacing_xs: u32 = 4,
    spacing_sm: u32 = 8,
    spacing_md: u32 = 12,
    spacing_lg: u32 = 16,
    spacing_xl: u32 = 20,

    // Bar Tokens
    bar_bg: Color,
    bar_border: Color,
    pill_bg: Color,
    pill_hover: Color,
    pill_border: Color,

    // Workspaces
    ws_active_bg: Color,
    ws_active_fg: Color,
    ws_occupied_bg: Color,
    ws_occupied_fg: Color,
    ws_empty_bg: Color,
    ws_empty_fg: Color,
    ws_urgent_bg: Color,
    ws_urgent_fg: Color,
    ws_hover_bg: Color,

    // Bar Modules
    launcher_bg: Color,
    launcher_fg: Color,
    cpu_mem_bg: Color,
    cpu_mem_fg: Color,
    audio_bg: Color,
    audio_fg: Color,
    battery_bg: Color,
    battery_fg: Color,
    clock_bg: Color,
    clock_fg: Color,
    mpris_playing_bg: Color,
    mpris_paused_bg: Color,
    mpris_fg: Color,
    separator_fg: Color,

    // Theme Switch Pill
    theme_bg: Color,
    theme_fg: Color,

    // Network Pill
    network_bg: Color,
    network_fg: Color,

    // Card Containers (Launcher, QuickSettings, Clipboard)
    card_bg: Color,
    card_selected_bg: Color,
    card_selected_fg: Color,
    card_hover_bg: Color,

    // Panels (QuickSettings, Clipboard, Calendar)
    panel_bg: Color,
    panel_border: Color,

    font_family: []const u8 = "JetBrainsMono Nerd Font, Maple Mono NF, monospace",
    font_size: u32 = 15,
    bar_font_size: u32 = 15,
    panel_font_size: u32 = 16,

    pub fn getAnsiColor(self: *const Theme, index: usize) Color {
        return switch (index) {
            0 => self.base,
            1 => self.error_color,
            2 => self.success_color,
            3 => self.warning_color,
            4 => self.secondary,
            5 => self.gradient_start,
            6 => self.accent,
            7 => self.text_muted,
            8 => self.border,
            9 => self.error_color,
            10 => self.success_color,
            11 => self.warning_color,
            12 => self.secondary,
            13 => self.accent_fg,
            14 => self.accent,
            15 => self.text_bright,
            else => self.text_main,
        };
    }
};

fn makeTheme(
    kind: ThemeKind,
    base: Color,
    surface: Color,
    elevated: Color,
    accent: Color,
    accent_fg: Color,
    secondary: Color,
    text: Color,
    text_muted: Color,
    err: Color,
    warn: Color,
    succ: Color,
) Theme {
    const subtle_border = Color.init(45, elevated.r, elevated.g, elevated.b);
    const pill_border = Color.init(35, elevated.r, elevated.g, elevated.b);
    const input_border = Color.init(65, elevated.r, elevated.g, elevated.b);
    const sel_bg = Color.init(80, accent.r, accent.g, accent.b);
    const p_hover = Color.init(130, accent.r, accent.g, accent.b);
    const sep = Color.init(50, text_muted.r, text_muted.g, text_muted.b);

    return .{
        .kind = kind,
        .base = base,
        .surface = surface,
        .elevated = elevated,
        .accent = accent,
        .accent_fg = accent_fg,
        .secondary = secondary,
        .text_main = text,
        .text_muted = text_muted,
        .text_bright = text,
        .border = subtle_border,
        .border_focused = accent,
        .input_bg = surface,
        .input_border = input_border,
        .selection_bg = sel_bg,

        .error_color = err,
        .warning_color = warn,
        .success_color = succ,

        .gradient_start = Color.init(230, base.r, base.g, base.b),
        .gradient_mid = Color.init(230, surface.r, surface.g, surface.b),
        .gradient_end = Color.init(230, elevated.r, elevated.g, elevated.b),
        .glass_highlight = Color.init(60, 255, 255, 255),
        .glass_border = Color.init(50, elevated.r, elevated.g, elevated.b),
        .shadow_dark = Color.init(45, 0, 0, 0),
        .shadow_light = Color.init(50, 255, 255, 255),
        .slider_track = Color.init(55, elevated.r, elevated.g, elevated.b),
        .slider_thumb = Color.hex(0xFFFFFF),
        .slider_thumb_shadow = Color.init(70, 0, 0, 0),
        .toggle_on = accent,
        .toggle_off = Color.init(120, elevated.r, elevated.g, elevated.b),
        .btn_raised_bg = elevated,
        .btn_raised_hover = surface,

        .bar_bg = base,
        .bar_border = subtle_border,
        .pill_bg = surface,
        .pill_hover = p_hover,
        .pill_border = pill_border,

        .ws_active_bg = accent,
        .ws_active_fg = accent_fg,
        .ws_occupied_bg = Color.transparent,
        .ws_occupied_fg = text,
        .ws_empty_bg = Color.transparent,
        .ws_empty_fg = text_muted,
        .ws_urgent_bg = err,
        .ws_urgent_fg = accent_fg,
        .ws_hover_bg = Color.init(100, secondary.r, secondary.g, secondary.b),

        .launcher_bg = accent,
        .launcher_fg = accent_fg,
        .cpu_mem_bg = surface,
        .cpu_mem_fg = warn,
        .audio_bg = surface,
        .audio_fg = secondary,
        .battery_bg = surface,
        .battery_fg = succ,
        .clock_bg = surface,
        .clock_fg = text,
        .mpris_playing_bg = surface,
        .mpris_paused_bg = surface,
        .mpris_fg = text,
        .separator_fg = sep,

        .theme_bg = surface,
        .theme_fg = accent,

        .network_bg = surface,
        .network_fg = accent,

        .card_bg = surface,
        .card_selected_bg = accent,
        .card_selected_fg = accent_fg,
        .card_hover_bg = elevated,

        .panel_bg = base,
        .panel_border = Color.init(50, elevated.r, elevated.g, elevated.b),
    };
}

// Frosted Neumorphic theme.
pub fn frostedNeumorphicTheme() Theme {
    const base = Color.init(220, 240, 244, 252);
    const surface = Color.init(235, 255, 255, 255);
    const elevated = Color.hex(0xFFFFFF);
    const accent = Color.hex(0x4361EE); // Vibrant Blue (Wi-Fi, Bluetooth, Sliders)
    const accent_fg = Color.hex(0xFFFFFF);
    const secondary = Color.hex(0x8B5CF6);
    const text_main = Color.hex(0x1E293B); // Slate 800 - crisp high-contrast
    const text_muted = Color.hex(0x64748B); // Slate 500 - crisp subtitles
    const err = Color.hex(0xEF4444);
    const warn = Color.hex(0xF59E0B);
    const succ = Color.hex(0x10B981); // Emerald Green (Battery Bar)

    var th = makeTheme(
        .frosted_neumorphic,
        base,
        surface,
        elevated,
        accent,
        accent_fg,
        secondary,
        text_main,
        text_muted,
        err,
        warn,
        succ,
    );

    th.gradient_start = Color.init(240, 219, 234, 254); // cool blue #DBEAFE
    th.gradient_mid = Color.init(240, 237, 233, 254); // lavender #EDE9FE
    th.gradient_end = Color.init(240, 252, 231, 243); // pale pink #FCE7F3
    th.glass_highlight = Color.init(220, 255, 255, 255);
    th.glass_border = Color.init(130, 255, 255, 255);
    th.shadow_dark = Color.init(35, 80, 95, 130);
    th.shadow_light = Color.init(180, 255, 255, 255);
    th.slider_track = Color.init(35, 140, 155, 185);
    th.slider_thumb = Color.hex(0xFFFFFF);
    th.slider_thumb_shadow = Color.init(60, 50, 65, 100);
    th.toggle_on = Color.hex(0x4361EE);
    th.toggle_off = Color.init(130, 203, 213, 225);
    th.btn_raised_bg = Color.init(245, 255, 255, 255);
    th.btn_raised_hover = Color.hex(0xFFFFFF);

    th.bar_bg = Color.init(210, 243, 246, 253);
    th.bar_border = Color.init(130, 255, 255, 255);
    th.pill_bg = Color.init(180, 255, 255, 255);
    th.pill_hover = Color.init(235, 255, 255, 255);
    th.pill_border = Color.init(100, 255, 255, 255);
    th.card_bg = Color.init(225, 45, 50, 70);
    th.panel_bg = Color.init(220, 242, 245, 252);
    th.panel_border = Color.init(130, 255, 255, 255);
    return th;
}

// Nord Frost theme.
pub fn nordTheme() Theme {
    return makeTheme(
        .nord,
        Color.hex(0x2E3440), // Base
        Color.hex(0x3B4252), // Surface
        Color.hex(0x434C5E), // Elevated
        Color.hex(0x88C0D0), // Accent (Frost Cyan)
        Color.hex(0x2E3440), // Accent FG (Deep dark base for 9.4:1 contrast)
        Color.hex(0x81A1C1), // Blue / Secondary
        Color.hex(0xECEFF4), // Text (Snow Storm)
        Color.hex(0xD8DEE9), // Text Muted (Nord4)
        Color.hex(0xBF616A), // Semantic Error (Nord11)
        Color.hex(0xEBCB8B), // Semantic Warning (Nord13)
        Color.hex(0xA3BE8C), // Semantic Success (Nord14)
    );
}

// Catppuccin Mocha theme.
pub fn catppuccinTheme() Theme {
    return makeTheme(
        .catppuccin,
        Color.hex(0x1E1E2E), // Base
        Color.hex(0x313244), // Surface (Surface0)
        Color.hex(0x45475A), // Elevated (Surface1)
        Color.hex(0xCBA6F7), // Accent (Mauve)
        Color.hex(0x11111B), // Accent FG (Crust)
        Color.hex(0x89B4FA), // Blue / Secondary
        Color.hex(0xCDD6F4), // Text
        Color.hex(0xA6ADC8), // Text Muted (Subtext0)
        Color.hex(0xF38BA8), // Semantic Error (Red)
        Color.hex(0xF9E2AF), // Semantic Warning (Yellow)
        Color.hex(0xA6E3A1), // Semantic Success (Green)
    );
}

// Tokyo Night theme.
pub fn tokyoNightTheme() Theme {
    return makeTheme(
        .tokyo_night,
        Color.hex(0x1A1B26), // Base
        Color.hex(0x24283B), // Surface
        Color.hex(0x292E42), // Elevated
        Color.hex(0x7AA2F7), // Accent (Blue)
        Color.hex(0x16161E), // Accent FG (Dark)
        Color.hex(0x7DCFFF), // Cyan / Secondary
        Color.hex(0xC0CAF5), // Text
        Color.hex(0x9AA5CE), // Text Muted
        Color.hex(0xF7768E), // Semantic Error (Red)
        Color.hex(0xE0AF68), // Semantic Warning (Yellow)
        Color.hex(0x9ECE6A), // Semantic Success (Green)
    );
}

// Rosé Pine theme.
pub fn rosePineTheme() Theme {
    return makeTheme(
        .rose_pine,
        Color.hex(0x191724), // Base
        Color.hex(0x1F1D2E), // Surface
        Color.hex(0x26233A), // Elevated
        Color.hex(0xC4A7E7), // Accent (Iris)
        Color.hex(0x191724), // Accent FG
        Color.hex(0x9CCFD8), // Foam / Secondary
        Color.hex(0xE0DEF4), // Text
        Color.hex(0x908CAA), // Text Muted
        Color.hex(0xEB6F92), // Semantic Error (Love)
        Color.hex(0xF6C177), // Semantic Warning (Gold)
        Color.hex(0x9CCFD8), // Semantic Success (Foam)
    );
}

// Dracula theme (Ant Dracula).
pub fn draculaTheme() Theme {
    return makeTheme(
        .dracula,
        Color.hex(0x282A36), // Base (#282A36)
        Color.hex(0x21222C), // Surface (#21222C)
        Color.hex(0x44475A), // Elevated (#44475A)
        Color.hex(0xBD93F9), // Accent Purple (#BD93F9)
        Color.hex(0x282A36), // Accent FG (Deep dark base)
        Color.hex(0x8BE9FD), // Cyan / Secondary (#8BE9FD)
        Color.hex(0xF8F8F2), // Text (#F8F8F2)
        Color.hex(0x6272A4), // Text Muted / Comment (#6272A4)
        Color.hex(0xFF5555), // Semantic Error (Red #FF5555)
        Color.hex(0xFFB86C), // Semantic Warning (Orange #FFB86C)
        Color.hex(0x50FA7B), // Semantic Success (Green #50FA7B)
    );
}

// Backward compatibility aliases
pub const mizuTheme = nordTheme;
pub const noctaliaTheme = tokyoNightTheme;
pub const materialYouTheme = catppuccinTheme;
pub const draculaAntTheme = draculaTheme;

pub fn generateMizuCss(th: Theme) void {
    var dir_buf: [512]u8 = undefined;
    var file_buf: [512]u8 = undefined;
    const home_opt = c.getenv("HOME");
    if (home_opt == null) return;
    const home = std.mem.span(home_opt.?);

    const dir_path = std.fmt.bufPrintSentinel(&dir_buf, "{s}/.config/mizu", .{home}, 0) catch return;
    _ = c.mkdir(dir_path.ptr, 0o755);

    const file_path = std.fmt.bufPrintSentinel(&file_buf, "{s}/.config/mizu/mizu.css", .{home}, 0) catch return;
    const f = c.fopen(file_path.ptr, "wb") orelse return;
    defer _ = c.fclose(f);

    var b_base: [8]u8 = undefined;
    var b_surf: [8]u8 = undefined;
    var b_elev: [8]u8 = undefined;
    var b_acc: [8]u8 = undefined;
    var b_acc_fg: [8]u8 = undefined;
    var b_sec: [8]u8 = undefined;
    var b_text: [8]u8 = undefined;
    var b_muted: [8]u8 = undefined;
    var b_bright: [8]u8 = undefined;
    var b_border: [8]u8 = undefined;
    var b_border_foc: [8]u8 = undefined;
    var b_card: [8]u8 = undefined;
    var b_bar: [8]u8 = undefined;
    var b_panel: [8]u8 = undefined;
    var b_err: [8]u8 = undefined;
    var b_warn: [8]u8 = undefined;
    var b_succ: [8]u8 = undefined;

    const base_hex = th.base.formatHexRgb(&b_base);
    const surf_hex = th.surface.formatHexRgb(&b_surf);
    const elev_hex = th.elevated.formatHexRgb(&b_elev);
    const acc_hex = th.accent.formatHexRgb(&b_acc);
    const acc_fg_hex = th.accent_fg.formatHexRgb(&b_acc_fg);
    const sec_hex = th.secondary.formatHexRgb(&b_sec);
    const text_hex = th.text_main.formatHexRgb(&b_text);
    const muted_hex = th.text_muted.formatHexRgb(&b_muted);
    const bright_hex = th.text_bright.formatHexRgb(&b_bright);
    const border_hex = th.border.formatHexRgb(&b_border);
    const border_foc_hex = th.border_focused.formatHexRgb(&b_border_foc);
    const card_hex = th.card_bg.formatHexRgb(&b_card);
    const bar_hex = th.bar_bg.formatHexRgb(&b_bar);
    const panel_hex = th.panel_bg.formatHexRgb(&b_panel);
    const err_hex = th.error_color.formatHexRgb(&b_err);
    const warn_hex = th.warning_color.formatHexRgb(&b_warn);
    const succ_hex = th.success_color.formatHexRgb(&b_succ);

    var gtk_buf: [2048]u8 = undefined;
    if (std.fmt.bufPrint(&gtk_buf,
        \\/* Mizu Dynamic Theme Stylesheet
        \\ * Location: ~/.config/mizu/mizu.css
        \\ * Generated dynamically for: GTK 3, GTK 4, Thunar, MangoWC, Firefox
        \\ * Theme Preset: {s} */
        \\
        \\/* GTK 3 & 4 Standard Color Definitions */
        \\@define-color theme_bg_color {s};
        \\@define-color theme_fg_color {s};
        \\@define-color theme_base_color {s};
        \\@define-color theme_text_color {s};
        \\@define-color theme_selected_bg_color {s};
        \\@define-color theme_selected_fg_color {s};
        \\@define-color accent_color {s};
        \\@define-color accent_bg_color {s};
        \\@define-color accent_fg_color {s};
        \\@define-color window_bg_color {s};
        \\@define-color window_fg_color {s};
        \\@define-color view_bg_color {s};
        \\@define-color view_fg_color {s};
        \\@define-color headerbar_bg_color {s};
        \\@define-color headerbar_fg_color {s};
        \\@define-color headerbar_border_color {s};
        \\@define-color card_bg_color {s};
        \\@define-color card_fg_color {s};
        \\@define-color card_border_color {s};
        \\@define-color dialog_bg_color {s};
        \\@define-color dialog_fg_color {s};
        \\@define-color popover_bg_color {s};
        \\@define-color popover_fg_color {s};
        \\@define-color borders {s};
        \\@define-color destructive_color {s};
        \\@define-color warning_color {s};
        \\@define-color success_color {s};
        \\
    , .{
        th.kind.name(),
        surf_hex,
        text_hex,
        base_hex,
        text_hex,
        acc_hex,
        acc_fg_hex,
        acc_hex,
        acc_hex,
        acc_fg_hex,
        base_hex,
        text_hex,
        surf_hex,
        text_hex,
        elev_hex,
        bright_hex,
        border_hex,
        card_hex,
        text_hex,
        border_hex,
        surf_hex,
        text_hex,
        surf_hex,
        text_hex,
        border_hex,
        err_hex,
        warn_hex,
        succ_hex,
    })) |gtk_content| {
        _ = c.fwrite(gtk_content.ptr, 1, gtk_content.len, f);
    } else |_| {}

    var b_gstart: [32]u8 = undefined;
    var b_gmid: [32]u8 = undefined;
    var b_gend: [32]u8 = undefined;
    var b_glass_hi: [32]u8 = undefined;
    var b_glass_br: [32]u8 = undefined;
    var b_sh_dark: [32]u8 = undefined;
    var b_sh_light: [32]u8 = undefined;
    var b_strack: [32]u8 = undefined;
    var b_sthumb: [8]u8 = undefined;
    var b_togon: [8]u8 = undefined;
    var b_togoff: [32]u8 = undefined;
    var b_btnr: [32]u8 = undefined;

    const gstart_rgba = th.gradient_start.formatRgba(&b_gstart);
    const gmid_rgba = th.gradient_mid.formatRgba(&b_gmid);
    const gend_rgba = th.gradient_end.formatRgba(&b_gend);
    const glass_hi_rgba = th.glass_highlight.formatRgba(&b_glass_hi);
    const glass_br_rgba = th.glass_border.formatRgba(&b_glass_br);
    const sh_dark_rgba = th.shadow_dark.formatRgba(&b_sh_dark);
    const sh_light_rgba = th.shadow_light.formatRgba(&b_sh_light);
    const strack_rgba = th.slider_track.formatRgba(&b_strack);
    const sthumb_hex = th.slider_thumb.formatHexRgb(&b_sthumb);
    const togon_hex = th.toggle_on.formatHexRgb(&b_togon);
    const togoff_rgba = th.toggle_off.formatRgba(&b_togoff);
    const btnr_rgba = th.btn_raised_bg.formatRgba(&b_btnr);

    var vars_buf: [4096]u8 = undefined;
    if (std.fmt.bufPrint(&vars_buf,
        \\/* Modern CSS Custom Properties & Variables */
        \\:root {{
        \\  --mizu-theme-name: "{s}";
        \\  --mizu-base: {s};
        \\  --mizu-surface: {s};
        \\  --mizu-elevated: {s};
        \\  --mizu-accent: {s};
        \\  --mizu-accent-fg: {s};
        \\  --mizu-secondary: {s};
        \\  --mizu-text: {s};
        \\  --mizu-text-muted: {s};
        \\  --mizu-text-bright: {s};
        \\  --mizu-border: {s};
        \\  --mizu-border-focused: {s};
        \\  --mizu-card-bg: {s};
        \\  --mizu-bar-bg: {s};
        \\  --mizu-panel-bg: {s};
        \\  --mizu-error: {s};
        \\  --mizu-warning: {s};
        \\  --mizu-success: {s};
        \\
        \\  /* Frosted & Neumorphic Design Tokens */
        \\  --mizu-gradient-start: {s};
        \\  --mizu-gradient-mid: {s};
        \\  --mizu-gradient-end: {s};
        \\  --mizu-glass-highlight: {s};
        \\  --mizu-glass-border: {s};
        \\  --mizu-shadow-dark: {s};
        \\  --mizu-shadow-light: {s};
        \\  --mizu-slider-track: {s};
        \\  --mizu-slider-thumb: {s};
        \\  --mizu-toggle-on: {s};
        \\  --mizu-toggle-off: {s};
        \\  --mizu-btn-raised: {s};
        \\
        \\  /* Corner Radii Tokens */
        \\  --mizu-radius-bar: 14px;
        \\  --mizu-radius-panel: 24px;
        \\  --mizu-radius-card: 18px;
        \\  --mizu-radius-pill: 12px;
        \\  --mizu-radius-button: 20px;
        \\  --mizu-radius-slider: 8px;
        \\
        \\  /* Spacing Tokens */
        \\  --mizu-spacing-xs: 4px;
        \\  --mizu-spacing-sm: 8px;
        \\  --mizu-spacing-md: 12px;
        \\  --mizu-spacing-lg: 16px;
        \\  --mizu-spacing-xl: 20px;
        \\
        \\  /* Animation Durations */
        \\  --mizu-anim-fast: 120ms;
        \\  --mizu-anim-base: 200ms;
        \\  --mizu-anim-slow: 300ms;
        \\}}
        \\
    , .{
        th.kind.name(),
        base_hex,
        surf_hex,
        elev_hex,
        acc_hex,
        acc_fg_hex,
        sec_hex,
        text_hex,
        muted_hex,
        bright_hex,
        border_hex,
        border_foc_hex,
        card_hex,
        bar_hex,
        panel_hex,
        err_hex,
        warn_hex,
        succ_hex,
        gstart_rgba,
        gmid_rgba,
        gend_rgba,
        glass_hi_rgba,
        glass_br_rgba,
        sh_dark_rgba,
        sh_light_rgba,
        strack_rgba,
        sthumb_hex,
        togon_hex,
        togoff_rgba,
        btnr_rgba,
    })) |vars_content| {
        _ = c.fwrite(vars_content.ptr, 1, vars_content.len, f);
    } else |_| {}

    const static_rules =
        \\/* Universal GTK Element Rules (Thunar, File Choosers, Apps) */
        \\window, .background {
        \\  background-color: @theme_bg_color;
        \\  color: @theme_fg_color;
        \\}
        \\
        \\headerbar {
        \\  background-color: @headerbar_bg_color;
        \\  color: @headerbar_fg_color;
        \\  border-bottom: 1px solid @headerbar_border_color;
        \\}
        \\
        \\button {
        \\  background-color: @card_bg_color;
        \\  color: @theme_fg_color;
        \\  border: 1px solid @borders;
        \\  border-radius: 8px;
        \\  padding: 4px 10px;
        \\}
        \\
        \\button:hover {
        \\  background-color: @theme_selected_bg_color;
        \\  color: @theme_selected_fg_color;
        \\}
        \\
        \\entry {
        \\  background-color: @view_bg_color;
        \\  color: @theme_text_color;
        \\  border: 1px solid @borders;
        \\  border-radius: 8px;
        \\  padding: 4px 8px;
        \\}
        \\
        \\entry:focus {
        \\  border-color: @accent_color;
        \\}
        \\
        \\/* MangoBar & Firefox Integration Tokens */
        \\#mangobar, .mangobar-capsule {
        \\  background: var(--mizu-bar-bg);
        \\  border-radius: var(--mizu-radius-bar);
        \\  border: 1px solid var(--mizu-glass-border);
        \\}
        \\
        \\#nav-bar, #TabsToolbar {
        \\  background-color: var(--mizu-surface) !important;
        \\  color: var(--mizu-text) !important;
        \\}
        \\
    ;
    _ = c.fwrite(static_rules.ptr, 1, static_rules.len, f);
}

fn pathExists(path: [:0]const u8) bool {
    return c.access(path.ptr, c.F_OK) == 0;
}

pub fn resolveBuiltinThemesDir(buf: []u8) ?[]const u8 {
    if (c.getenv("MIZU_THEMES_DIR")) |raw| {
        const dir = std.mem.span(raw);
        if (dir.len > 0) {
            if (std.fmt.bufPrintSentinel(buf, "{s}", .{dir}, 0)) |s| {
                if (pathExists(s)) return s;
            } else |_| {}
        }
    }

    const static_dirs = [_][]const u8{
        "/usr/share/mizu/themes",
        "/usr/local/share/mizu/themes",
    };
    for (static_dirs) |dir| {
        if (std.fmt.bufPrintSentinel(buf, "{s}", .{dir}, 0)) |s| {
            if (pathExists(s)) return s;
        } else |_| {}
    }

    var exe_buf: [4096]u8 = undefined;
    const n = c.readlink("/proc/self/exe", &exe_buf, exe_buf.len - 1);
    if (n > 0) {
        const exe_path = exe_buf[0..@intCast(n)];
        if (std.mem.lastIndexOfScalar(u8, exe_path, '/')) |slash| {
            const exe_dir = exe_path[0..slash];
            const rel_candidates = [_][]const u8{
                "../share/mizu/themes",
                "share/mizu/themes",
                "themes",
                "../themes",
                "../../themes",
            };
            for (rel_candidates) |rel| {
                if (std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ exe_dir, rel }, 0)) |s| {
                    if (pathExists(s)) return s;
                } else |_| {}
            }
        }
    }

    if (std.fmt.bufPrintSentinel(buf, "mizu/styles/themes", .{}, 0)) |s| {
        if (pathExists(s)) return s;
    } else |_| {}

    if (std.fmt.bufPrintSentinel(buf, "themes", .{}, 0)) |s| {
        if (pathExists(s)) return s;
    } else |_| {}

    return null;
}

pub fn getUserThemesDir(buf: []u8) ?[]const u8 {
    if (c.getenv("XDG_CONFIG_HOME")) |raw| {
        const xdg = std.mem.span(raw);
        if (xdg.len > 0) {
            return std.fmt.bufPrint(buf, "{s}/mizu/themes", .{xdg}) catch null;
        }
    }
    if (c.getenv("HOME")) |raw| {
        const home = std.mem.span(raw);
        if (home.len > 0) {
            return std.fmt.bufPrint(buf, "{s}/.config/mizu/themes", .{home}) catch null;
        }
    }
    return null;
}

fn copyFile(src_path: [:0]const u8, dst_path: [:0]const u8) bool {
    const in_f = c.fopen(src_path.ptr, "rb") orelse return false;
    defer _ = c.fclose(in_f);
    const out_f = c.fopen(dst_path.ptr, "wb") orelse return false;
    defer _ = c.fclose(out_f);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, in_f);
        if (n <= 0) break;
        if (c.fwrite(&buf, 1, n, out_f) != n) return false;
    }
    return true;
}

fn copyDirRecursive(src_dir: []const u8, dst_dir: []const u8) void {
    var src_z: [512]u8 = undefined;
    var dst_z: [512]u8 = undefined;
    const src_sentinel = std.fmt.bufPrintSentinel(&src_z, "{s}", .{src_dir}, 0) catch return;
    const dst_sentinel = std.fmt.bufPrintSentinel(&dst_z, "{s}", .{dst_dir}, 0) catch return;

    _ = c.mkdir(dst_sentinel.ptr, 0o755);

    const dir = c.opendir(src_sentinel.ptr) orelse return;
    defer _ = c.closedir(dir);

    while (c.readdir(dir)) |entry| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        var sub_src_buf: [512]u8 = undefined;
        var sub_dst_buf: [512]u8 = undefined;
        const sub_src = std.fmt.bufPrintSentinel(&sub_src_buf, "{s}/{s}", .{ src_dir, name }, 0) catch continue;
        const sub_dst = std.fmt.bufPrintSentinel(&sub_dst_buf, "{s}/{s}", .{ dst_dir, name }, 0) catch continue;

        if (entry.*.d_type == c.DT_DIR) {
            copyDirRecursive(sub_src, sub_dst);
        } else if (entry.*.d_type == c.DT_LNK) {
            var target_buf: [512]u8 = undefined;
            const link_len = c.readlink(sub_src.ptr, &target_buf, target_buf.len - 1);
            if (link_len > 0) {
                target_buf[@intCast(link_len)] = 0;
                _ = c.symlink(&target_buf, sub_dst.ptr);
            }
        } else {
            _ = copyFile(sub_src, sub_dst);
        }
    }
}

pub fn ensureUserTheme(theme_name: []const u8) void {
    var user_dir_buf: [512]u8 = undefined;
    var user_theme_buf: [512]u8 = undefined;
    const user_base = getUserThemesDir(&user_dir_buf) orelse return;
    const user_theme = std.fmt.bufPrintSentinel(&user_theme_buf, "{s}/{s}", .{ user_base, theme_name }, 0) catch return;

    // If user copy already exists, DO NOT overwrite it (preserves user customizations)
    if (pathExists(user_theme)) return;

    // Ensure parent directories exist
    var base_z: [512]u8 = undefined;
    if (std.fmt.bufPrintSentinel(&base_z, "{s}", .{user_base}, 0)) |bz| {
        var p = bz;
        if (std.mem.lastIndexOfScalar(u8, p, '/')) |slash| {
            var parent_buf: [512]u8 = undefined;
            if (std.fmt.bufPrintSentinel(&parent_buf, "{s}", .{p[0..slash]}, 0)) |pbz| {
                _ = c.mkdir(pbz.ptr, 0o755);
            } else |_| {}
        }
        _ = c.mkdir(bz.ptr, 0o755);
    } else |_| {}

    // Find built-in theme
    var builtin_base_buf: [512]u8 = undefined;
    var builtin_theme_buf: [512]u8 = undefined;
    const builtin_base = resolveBuiltinThemesDir(&builtin_base_buf) orelse return;
    const builtin_theme = std.fmt.bufPrintSentinel(&builtin_theme_buf, "{s}/{s}", .{ builtin_base, theme_name }, 0) catch return;

    if (pathExists(builtin_theme)) {
        copyDirRecursive(builtin_theme, user_theme);
    }
}

fn parseNumber(val: []const u8) ?u32 {
    var s = std.mem.trim(u8, val, " \t\r\n;\"'");
    if (std.mem.endsWith(u8, s, "px") or std.mem.endsWith(u8, s, "pt")) {
        s = s[0 .. s.len - 2];
    }
    return std.fmt.parseInt(u32, s, 10) catch null;
}

pub fn parseThemeCss(css: []const u8, base_theme: Theme) Theme {
    var th = base_theme;
    var it = std.mem.splitScalar(u8, css, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "/*") or std.mem.startsWith(u8, line, "//")) continue;

        if (std.mem.startsWith(u8, line, "@define-color")) {
            var parts = std.mem.tokenizeAny(u8, line["@define-color".len..], " \t");
            const key = parts.next() orelse continue;
            const val_raw = parts.rest();
            const val = std.mem.trim(u8, val_raw, " \t;");
            const col = Color.fromStr(val);

            if (std.mem.eql(u8, key, "theme_base_color") or std.mem.eql(u8, key, "window_bg_color")) {
                th.base = col;
                th.bar_bg = col;
                th.panel_bg = col;
            } else if (std.mem.eql(u8, key, "theme_bg_color") or std.mem.eql(u8, key, "view_bg_color")) {
                th.surface = col;
                th.input_bg = col;
                th.pill_bg = col;
            } else if (std.mem.eql(u8, key, "headerbar_bg_color")) {
                th.elevated = col;
                th.btn_raised_bg = col;
            } else if (std.mem.eql(u8, key, "accent_color") or std.mem.eql(u8, key, "accent_bg_color")) {
                th.accent = col;
                th.border_focused = col;
                th.toggle_on = col;
            } else if (std.mem.eql(u8, key, "accent_fg_color") or std.mem.eql(u8, key, "theme_selected_fg_color")) {
                th.accent_fg = col;
            } else if (std.mem.eql(u8, key, "theme_text_color") or std.mem.eql(u8, key, "theme_fg_color")) {
                th.text_main = col;
                th.text_bright = col;
            } else if (std.mem.eql(u8, key, "card_bg_color")) {
                th.card_bg = col;
            } else if (std.mem.eql(u8, key, "borders")) {
                th.border = col;
            } else if (std.mem.eql(u8, key, "destructive_color")) {
                th.error_color = col;
            } else if (std.mem.eql(u8, key, "warning_color")) {
                th.warning_color = col;
            } else if (std.mem.eql(u8, key, "success_color")) {
                th.success_color = col;
            }
            continue;
        }

        const colon_idx = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        var key = std.mem.trim(u8, line[0..colon_idx], " \t");
        const val = std.mem.trim(u8, line[colon_idx + 1 ..], " \t;");

        if (std.mem.startsWith(u8, key, "--mizu-")) {
            key = key["--mizu-".len..];
        } else if (std.mem.startsWith(u8, key, "--")) {
            key = key[2..];
        }

        if (std.mem.eql(u8, key, "base")) {
            th.base = Color.fromStr(val);
        } else if (std.mem.eql(u8, key, "surface")) {
            th.surface = Color.fromStr(val);
        } else if (std.mem.eql(u8, key, "elevated")) {
            th.elevated = Color.fromStr(val);
        } else if (std.mem.eql(u8, key, "accent")) {
            th.accent = Color.fromStr(val);
            th.border_focused = th.accent;
            th.toggle_on = th.accent;
        } else if (std.mem.eql(u8, key, "accent-fg") or std.mem.eql(u8, key, "accent_fg")) {
            th.accent_fg = Color.fromStr(val);
        } else if (std.mem.eql(u8, key, "secondary")) {
            th.secondary = Color.fromStr(val);
        } else if (std.mem.eql(u8, key, "text")) {
            th.text_main = Color.fromStr(val);
            th.text_bright = th.text_main;
        } else if (std.mem.eql(u8, key, "text-muted") or std.mem.eql(u8, key, "text_muted")) {
            th.text_muted = Color.fromStr(val);
        } else if (std.mem.eql(u8, key, "text-bright") or std.mem.eql(u8, key, "text_bright")) {
            th.text_bright = Color.fromStr(val);
        } else if (std.mem.eql(u8, key, "border")) {
            th.border = Color.fromStr(val);
        } else if (std.mem.eql(u8, key, "border-focused") or std.mem.eql(u8, key, "border_focused")) {
            th.border_focused = Color.fromStr(val);
        } else if (std.mem.eql(u8, key, "card-bg") or std.mem.eql(u8, key, "card_bg")) {
            th.card_bg = Color.fromStr(val);
        } else if (std.mem.eql(u8, key, "bar-bg") or std.mem.eql(u8, key, "bar_bg")) {
            th.bar_bg = Color.fromStr(val);
        } else if (std.mem.eql(u8, key, "panel-bg") or std.mem.eql(u8, key, "panel_bg")) {
            th.panel_bg = Color.fromStr(val);
        } else if (std.mem.eql(u8, key, "error")) {
            th.error_color = Color.fromStr(val);
        } else if (std.mem.eql(u8, key, "warning")) {
            th.warning_color = Color.fromStr(val);
        } else if (std.mem.eql(u8, key, "success")) {
            th.success_color = Color.fromStr(val);
        } else if (std.mem.eql(u8, key, "gradient-start") or std.mem.eql(u8, key, "gradient_start")) {
            th.gradient_start = Color.fromStr(val);
        } else if (std.mem.eql(u8, key, "gradient-mid") or std.mem.eql(u8, key, "gradient_mid")) {
            th.gradient_mid = Color.fromStr(val);
        } else if (std.mem.eql(u8, key, "gradient-end") or std.mem.eql(u8, key, "gradient_end")) {
            th.gradient_end = Color.fromStr(val);
        } else if (std.mem.eql(u8, key, "glass-highlight") or std.mem.eql(u8, key, "glass_highlight")) {
            th.glass_highlight = Color.fromStr(val);
        } else if (std.mem.eql(u8, key, "glass-border") or std.mem.eql(u8, key, "glass_border")) {
            th.glass_border = Color.fromStr(val);
        } else if (std.mem.eql(u8, key, "shadow-dark") or std.mem.eql(u8, key, "shadow_dark")) {
            th.shadow_dark = Color.fromStr(val);
        } else if (std.mem.eql(u8, key, "shadow-light") or std.mem.eql(u8, key, "shadow_light")) {
            th.shadow_light = Color.fromStr(val);
        } else if (std.mem.eql(u8, key, "slider-track") or std.mem.eql(u8, key, "slider_track")) {
            th.slider_track = Color.fromStr(val);
        } else if (std.mem.eql(u8, key, "slider-thumb") or std.mem.eql(u8, key, "slider_thumb")) {
            th.slider_thumb = Color.fromStr(val);
        } else if (std.mem.eql(u8, key, "toggle-on") or std.mem.eql(u8, key, "toggle_on")) {
            th.toggle_on = Color.fromStr(val);
        } else if (std.mem.eql(u8, key, "toggle-off") or std.mem.eql(u8, key, "toggle_off")) {
            th.toggle_off = Color.fromStr(val);
        } else if (std.mem.eql(u8, key, "btn-raised") or std.mem.eql(u8, key, "btn_raised")) {
            th.btn_raised_bg = Color.fromStr(val);
        } else if (std.mem.eql(u8, key, "radius-bar") or std.mem.eql(u8, key, "radius_bar")) {
            if (parseNumber(val)) |num| th.radius_bar = num;
        } else if (std.mem.eql(u8, key, "radius-panel") or std.mem.eql(u8, key, "radius_panel")) {
            if (parseNumber(val)) |num| th.radius_panel = num;
        } else if (std.mem.eql(u8, key, "radius-card") or std.mem.eql(u8, key, "radius_card")) {
            if (parseNumber(val)) |num| th.radius_card = num;
        } else if (std.mem.eql(u8, key, "radius-pill") or std.mem.eql(u8, key, "radius_pill")) {
            if (parseNumber(val)) |num| th.radius_pill = num;
        } else if (std.mem.eql(u8, key, "radius-button") or std.mem.eql(u8, key, "radius_button")) {
            if (parseNumber(val)) |num| th.radius_button = num;
        } else if (std.mem.eql(u8, key, "radius-slider") or std.mem.eql(u8, key, "radius_slider")) {
            if (parseNumber(val)) |num| th.radius_slider = num;
        } else if (std.mem.eql(u8, key, "spacing-xs") or std.mem.eql(u8, key, "spacing_xs")) {
            if (parseNumber(val)) |num| th.spacing_xs = num;
        } else if (std.mem.eql(u8, key, "spacing-sm") or std.mem.eql(u8, key, "spacing_sm")) {
            if (parseNumber(val)) |num| th.spacing_sm = num;
        } else if (std.mem.eql(u8, key, "spacing-md") or std.mem.eql(u8, key, "spacing_md")) {
            if (parseNumber(val)) |num| th.spacing_md = num;
        } else if (std.mem.eql(u8, key, "spacing-lg") or std.mem.eql(u8, key, "spacing_lg")) {
            if (parseNumber(val)) |num| th.spacing_lg = num;
        } else if (std.mem.eql(u8, key, "spacing-xl") or std.mem.eql(u8, key, "spacing_xl")) {
            if (parseNumber(val)) |num| th.spacing_xl = num;
        }
    }
    return th;
}

fn readAndParseCss(file_path: [:0]const u8, theme_name: []const u8) ?Theme {
    const f = c.fopen(file_path.ptr, "rb") orelse return null;
    defer _ = c.fclose(f);

    var buf: [65536]u8 = undefined;
    const rd = c.fread(&buf, 1, buf.len - 1, f);
    if (rd <= 0) return null;
    buf[rd] = 0;

    const base_kind = ThemeKind.fromString(theme_name) orelse ThemeKind.default_theme;
    var parsed = parseThemeCss(buf[0..rd], base_kind.toTheme());
    if (ThemeKind.fromString(theme_name)) |k| {
        parsed.kind = k;
    }
    return parsed;
}

pub fn loadTheme(name: []const u8) Theme {
    ensureUserTheme(name);

    var user_dir_buf: [512]u8 = undefined;
    var user_file_buf: [512]u8 = undefined;
    var th: ?Theme = null;

    // 1. Try user theme directory: ~/.config/mizu/themes/<name>/theme.css
    if (getUserThemesDir(&user_dir_buf)) |user_base| {
        if (std.fmt.bufPrintSentinel(&user_file_buf, "{s}/{s}/theme.css", .{ user_base, name }, 0)) |user_css_path| {
            if (readAndParseCss(user_css_path, name)) |loaded| {
                th = loaded;
            }
        } else |_| {}
    }

    // 2. If missing from user dir, try built-in theme directory
    if (th == null) {
        var builtin_dir_buf: [512]u8 = undefined;
        var builtin_file_buf: [512]u8 = undefined;
        if (resolveBuiltinThemesDir(&builtin_dir_buf)) |builtin_base| {
            if (std.fmt.bufPrintSentinel(&builtin_file_buf, "{s}/{s}/theme.css", .{ builtin_base, name }, 0)) |builtin_css_path| {
                if (readAndParseCss(builtin_css_path, name)) |loaded| {
                    th = loaded;
                }
            } else |_| {}
        }
    }

    // 3. Fallback to ThemeKind if known name
    if (th == null) {
        if (ThemeKind.fromString(name)) |k| {
            th = k.toTheme();
        }
    }

    // 4. Safe fallback to default theme
    return th orelse ThemeKind.default_theme.toTheme();
}

pub fn stripHash(color: []const u8) []const u8 {
    if (color.len > 0 and color[0] == '#') return color[1..];
    return color;
}

fn writeFileContent(path: [:0]const u8, content: []const u8) bool {
    const f = c.fopen(path.ptr, "wb") orelse return false;
    defer _ = c.fclose(f);
    return c.fwrite(content.ptr, 1, content.len, f) == content.len;
}

fn ensureDirExists(path: [:0]const u8) void {
    if (c.access(path.ptr, c.F_OK) == 0) return;
    const p: []const u8 = path;
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |slash| {
        if (slash > 0) {
            var parent_buf: [512]u8 = undefined;
            if (std.fmt.bufPrintSentinel(&parent_buf, "{s}", .{p[0..slash]}, 0)) |parent| {
                ensureDirExists(parent);
            } else |_| {}
        }
    }
    _ = c.mkdir(path.ptr, 0o755);
}

pub fn generateThemeCss(th: *const Theme, buf: []u8) []const u8 {
    var b_base: [8]u8 = undefined;
    var b_surf: [8]u8 = undefined;
    var b_elev: [8]u8 = undefined;
    var b_acc: [8]u8 = undefined;
    var b_acc_fg: [8]u8 = undefined;
    var b_sec: [8]u8 = undefined;
    var b_text: [8]u8 = undefined;
    var b_muted: [8]u8 = undefined;
    var b_bright: [8]u8 = undefined;
    var b_border: [8]u8 = undefined;
    var b_err: [8]u8 = undefined;
    var b_warn: [8]u8 = undefined;
    var b_succ: [8]u8 = undefined;

    const base_hex = th.base.formatHexRgb(&b_base);
    const surf_hex = th.surface.formatHexRgb(&b_surf);
    const elev_hex = th.elevated.formatHexRgb(&b_elev);
    const acc_hex = th.accent.formatHexRgb(&b_acc);
    const acc_fg_hex = th.accent_fg.formatHexRgb(&b_acc_fg);
    const sec_hex = th.secondary.formatHexRgb(&b_sec);
    const text_hex = th.text_main.formatHexRgb(&b_text);
    const muted_hex = th.text_muted.formatHexRgb(&b_muted);
    const bright_hex = th.text_bright.formatHexRgb(&b_bright);
    const border_hex = th.border.formatHexRgb(&b_border);
    const err_hex = th.error_color.formatHexRgb(&b_err);
    const warn_hex = th.warning_color.formatHexRgb(&b_warn);
    const succ_hex = th.success_color.formatHexRgb(&b_succ);

    const s1 = std.fmt.bufPrint(buf,
        \\:root {{
        \\  --mizu-theme-name: "{s}";
        \\  --mizu-base: {s};
        \\  --mizu-surface: {s};
        \\  --mizu-elevated: {s};
        \\  --mizu-accent: {s};
        \\  --mizu-accent-fg: {s};
        \\  --mizu-secondary: {s};
        \\  --mizu-text: {s};
        \\  --mizu-text-muted: {s};
        \\  --mizu-text-bright: {s};
        \\  --mizu-border: {s};
        \\  --mizu-border-focused: {s};
        \\  --mizu-card-bg: {s};
        \\  --mizu-bar-bg: {s};
        \\  --mizu-panel-bg: {s};
        \\  --mizu-error: {s};
        \\  --mizu-warning: {s};
        \\  --mizu-success: {s};
        \\
        \\  /* Corner Radii */
        \\  --mizu-radius-bar: 12px;
        \\  --mizu-radius-panel: 20px;
        \\  --mizu-radius-card: 14px;
        \\  --mizu-radius-pill: 12px;
        \\  --mizu-radius-button: 10px;
        \\  --mizu-radius-slider: 8px;
        \\
        \\  /* Spacing */
        \\  --mizu-spacing-xs: 4px;
        \\  --mizu-spacing-sm: 8px;
        \\  --mizu-spacing-md: 12px;
        \\  --mizu-spacing-lg: 16px;
        \\  --mizu-spacing-xl: 20px;
        \\}}
        \\
    , .{
        th.kind.name(),
        th.kind.name(),
        base_hex,
        surf_hex,
        elev_hex,
        acc_hex,
        acc_fg_hex,
        sec_hex,
        text_hex,
        muted_hex,
        bright_hex,
        border_hex,
        acc_hex,
        surf_hex,
        base_hex,
        base_hex,
        err_hex,
        warn_hex,
        succ_hex,
    }) catch return "";

    const s2 = std.fmt.bufPrint(buf[s1.len..],
        \\/* GTK Standard Palette */
        \\@define-color theme_bg_color {s};
        \\@define-color theme_fg_color {s};
        \\@define-color theme_base_color {s};
        \\@define-color theme_text_color {s};
        \\@define-color theme_selected_bg_color {s};
        \\@define-color theme_selected_fg_color {s};
        \\@define-color accent_color {s};
        \\@define-color accent_bg_color {s};
        \\@define-color accent_fg_color {s};
        \\@define-color window_bg_color {s};
        \\@define-color window_fg_color {s};
        \\@define-color view_bg_color {s};
        \\@define-color view_fg_color {s};
        \\@define-color headerbar_bg_color {s};
        \\@define-color headerbar_fg_color {s};
        \\@define-color headerbar_border_color {s};
        \\@define-color card_bg_color {s};
        \\@define-color card_fg_color {s};
        \\@define-color card_border_color {s};
        \\@define-color borders {s};
        \\@define-color destructive_color {s};
        \\@define-color warning_color {s};
        \\@define-color success_color {s};
        \\
    , .{
        surf_hex,   text_hex,   base_hex, text_hex,   acc_hex,  base_hex,
        acc_hex,    acc_hex,    base_hex, base_hex,   text_hex, surf_hex,
        text_hex,   elev_hex,   text_hex, border_hex, surf_hex, text_hex,
        border_hex, border_hex, err_hex,  warn_hex,   succ_hex,
    }) catch return s1;

    return buf[0 .. s1.len + s2.len];
}

pub fn generateGtkCss(th: *const Theme, buf: []u8) []const u8 {
    var b_base: [8]u8 = undefined;
    var b_surf: [8]u8 = undefined;
    var b_elev: [8]u8 = undefined;
    var b_acc: [8]u8 = undefined;
    var b_sec: [8]u8 = undefined;
    var b_text: [8]u8 = undefined;
    var b_border: [8]u8 = undefined;
    var b_err: [8]u8 = undefined;
    var b_succ: [8]u8 = undefined;

    const bg = th.base.formatHexRgb(&b_base);
    const fg = th.text_main.formatHexRgb(&b_text);
    const surface = th.surface.formatHexRgb(&b_surf);
    const sidebar = th.elevated.formatHexRgb(&b_elev);
    const border = th.border.formatHexRgb(&b_border);
    const accent = th.accent.formatHexRgb(&b_acc);
    const accent_alt = th.secondary.formatHexRgb(&b_sec);
    const urgent = th.error_color.formatHexRgb(&b_err);
    const success = th.success_color.formatHexRgb(&b_succ);

    return std.fmt.bufPrint(buf,
        \\/* Theme - {s} */
        \\
        \\@define-color theme_bg {s};
        \\@define-color theme_fg {s};
        \\@define-color theme_sidebar {s};
        \\@define-color theme_surface {s};
        \\@define-color theme_border {s};
        \\@define-color theme_accent {s};
        \\@define-color theme_accent_alt {s};
        \\@define-color theme_selected_bg {s};
        \\@define-color theme_selected_fg {s};
        \\@define-color theme_urgent {s};
        \\@define-color theme_success {s};
        \\
        \\@define-color accent {s};
        \\@define-color accent_alt {s};
        \\@define-color bg {s};
        \\@define-color fg {s};
        \\@define-color border {s};
        \\@define-color sidebar {s};
        \\@define-color surface {s};
        \\@define-color urgent {s};
        \\@define-color success {s};
        \\
        \\@define-color theme_bg_color @theme_bg;
        \\@define-color theme_fg_color @theme_fg;
        \\@define-color theme_base_color @theme_bg;
        \\@define-color theme_text_color @theme_fg;
        \\@define-color theme_selected_bg_color @theme_selected_bg;
        \\@define-color theme_selected_fg_color @theme_selected_fg;
        \\
        \\@define-color theme_unfocused_bg_color @theme_bg;
        \\@define-color theme_unfocused_fg_color @theme_fg;
        \\@define-color theme_unfocused_base_color @theme_bg;
        \\@define-color theme_unfocused_text_color @theme_fg;
        \\@define-color theme_unfocused_selected_bg_color @theme_selected_bg;
        \\@define-color theme_unfocused_selected_fg_color @theme_selected_fg;
        \\
        \\@define-color insensitive_bg_color @theme_bg;
        \\@define-color insensitive_fg_color alpha(@theme_fg, 0.45);
        \\@define-color insensitive_base_color @theme_bg;
        \\@define-color unfocused_insensitive_color alpha(@theme_fg, 0.35);
        \\
        \\@define-color borders @theme_border;
        \\@define-color unfocused_borders @theme_border;
        \\@define-color warning_color @theme_urgent;
        \\@define-color error_color @theme_urgent;
        \\@define-color success_color @theme_success;
        \\@define-color info_color @theme_accent;
        \\@define-color question_color @theme_accent;
        \\@define-color link_color @theme_accent;
        \\@define-color link_visited_color @theme_accent_alt;
        \\
        \\@define-color window_bg_color @theme_bg;
        \\@define-color window_fg_color @theme_fg;
        \\@define-color window_border_color @theme_border;
        \\@define-color view_bg_color @theme_bg;
        \\@define-color view_fg_color @theme_fg;
        \\@define-color content_view_bg @theme_bg;
        \\@define-color text_view_bg @theme_bg;
        \\
        \\@define-color headerbar_bg_color @theme_sidebar;
        \\@define-color headerbar_fg_color @theme_fg;
        \\@define-color headerbar_border_color @theme_border;
        \\@define-color headerbar_backdrop_color @theme_bg;
        \\@define-color headerbar_shade_color rgba(0, 0, 0, 0.2);
        \\
        \\@define-color toolbar_bg_color @theme_sidebar;
        \\@define-color toolbar_fg_color @theme_fg;
        \\@define-color toolbar_border_color @theme_border;
        \\@define-color toolbar_backdrop_color @theme_bg;
        \\@define-color actionbar_bg_color @theme_sidebar;
        \\@define-color actionbar_fg_color @theme_fg;
        \\@define-color actionbar_border_color @theme_border;
        \\@define-color actionbar_backdrop_color @theme_bg;
        \\@define-color searchbar_bg_color @theme_sidebar;
        \\@define-color searchbar_fg_color @theme_fg;
        \\@define-color searchbar_border_color @theme_border;
        \\@define-color statusbar_bg_color @theme_sidebar;
        \\@define-color statusbar_fg_color @theme_fg;
        \\@define-color menubar_bg_color @theme_sidebar;
        \\@define-color menubar_fg_color @theme_fg;
        \\@define-color infobar_bg_color @theme_surface;
        \\@define-color infobar_fg_color @theme_fg;
        \\
        \\@define-color sidebar_bg_color @theme_sidebar;
        \\@define-color sidebar_fg_color @theme_fg;
        \\@define-color sidebar_backdrop_color @theme_bg;
        \\@define-color sidebar_border_color @theme_border;
        \\@define-color secondary_sidebar_bg_color @theme_bg;
        \\@define-color secondary_sidebar_fg_color @theme_fg;
        \\
        \\@define-color card_bg_color @theme_surface;
        \\@define-color card_fg_color @theme_fg;
        \\@define-color card_border_color @theme_border;
        \\@define-color card_shade_color rgba(0, 0, 0, 0.15);
        \\@define-color dialog_bg_color @theme_bg;
        \\@define-color dialog_fg_color @theme_fg;
        \\@define-color popover_bg_color @theme_surface;
        \\@define-color popover_fg_color @theme_fg;
        \\@define-color popover_shade_color rgba(0, 0, 0, 0.25);
        \\@define-color overview_bg_color @theme_surface;
        \\@define-color overview_fg_color @theme_fg;
        \\
        \\@define-color tooltip_bg_color @theme_surface;
        \\@define-color tooltip_fg_color @theme_fg;
        \\@define-color tooltip_border_color @theme_border;
        \\@define-color theme_tooltip_bg_color @theme_surface;
        \\@define-color theme_tooltip_fg_color @theme_fg;
        \\@define-color progress_bg_color @theme_accent;
        \\@define-color progress_trough_color @theme_surface;
        \\@define-color shade_color rgba(0, 0, 0, 0.25);
        \\@define-color scrollbar_outline_color transparent;
        \\
        \\@define-color accent_color @theme_accent;
        \\@define-color accent_bg_color @theme_accent;
        \\@define-color accent_fg_color @theme_selected_fg;
        \\@define-color destructive_color @theme_urgent;
        \\@define-color destructive_bg_color @theme_urgent;
        \\@define-color destructive_fg_color @theme_selected_fg;
        \\@define-color theme_destructive_bg @theme_urgent;
        \\@define-color theme_destructive_hover alpha(@theme_urgent, 0.85);
        \\@define-color theme_destructive_active @theme_urgent;
        \\@define-color theme_border_dim alpha(@theme_border, 0.6);
        \\@define-color warning_bg_color @theme_urgent;
        \\@define-color warning_fg_color @theme_selected_fg;
        \\@define-color success_bg_color @theme_success;
        \\@define-color success_fg_color @theme_selected_fg;
        \\@define-color error_color @theme_urgent;
        \\@define-color error_bg_color @theme_urgent;
        \\@define-color error_fg_color @theme_selected_fg;
        \\
    , .{
        th.kind.name(),
        bg,
        fg,
        sidebar,
        surface,
        border,
        accent,
        accent_alt,
        accent,
        bg,
        urgent,
        success,
        accent,
        accent_alt,
        bg,
        fg,
        border,
        sidebar,
        surface,
        urgent,
        success,
    }) catch "";
}

pub fn generateColorsRasi(th: *const Theme, buf: []u8) []const u8 {
    var b_base: [8]u8 = undefined;
    var b_elev: [8]u8 = undefined;
    var b_surf: [8]u8 = undefined;
    var b_border: [8]u8 = undefined;
    var b_text: [8]u8 = undefined;
    var b_muted: [8]u8 = undefined;
    var b_acc: [8]u8 = undefined;
    var b_succ: [8]u8 = undefined;
    var b_err: [8]u8 = undefined;

    return std.fmt.bufPrint(buf,
        \\// Autogenerated by Mizu Theme Engine
        \\* {{
        \\    font:                        "Maple Mono NF 11";
        \\    background:                  {s}EE;
        \\    bg-alt:                      {s}FF;
        \\    background-alt:              {s}FF;
        \\    background-surface:          {s}FF;
        \\    border-color:                {s}FF;
        \\    foreground:                  {s}FF;
        \\    foreground-muted:            {s}FF;
        \\    selected:                    {s}FF;
        \\    selected-fg:                 {s}FF;
        \\    active:                      {s}FF;
        \\    urgent:                      {s}FF;
        \\    accent:                      {s}FF;
        \\}}
        \\
    , .{
        th.base.formatHexRgb(&b_base),
        th.elevated.formatHexRgb(&b_elev),
        th.elevated.formatHexRgb(&b_elev),
        th.surface.formatHexRgb(&b_surf),
        th.border.formatHexRgb(&b_border),
        th.text_main.formatHexRgb(&b_text),
        th.text_muted.formatHexRgb(&b_muted),
        th.accent.formatHexRgb(&b_acc),
        th.base.formatHexRgb(&b_base),
        th.success_color.formatHexRgb(&b_succ),
        th.error_color.formatHexRgb(&b_err),
        th.accent.formatHexRgb(&b_acc),
    }) catch "";
}

pub fn generateFootIni(th: *const Theme, buf: []u8) []const u8 {
    var b_base: [8]u8 = undefined;
    var b_text: [8]u8 = undefined;
    var b_border: [8]u8 = undefined;
    var c_bufs: [16][8]u8 = undefined;

    var c_hex: [16][]const u8 = undefined;
    for (0..16) |i| {
        c_hex[i] = stripHash(th.getAnsiColor(i).formatHexRgb(&c_bufs[i]));
    }

    return std.fmt.bufPrint(buf,
        \\# -*- conf -*-
        \\# Autogenerated by Mizu Theme Engine - {s}
        \\
        \\[colors-dark]
        \\background = {s}
        \\foreground = {s}
        \\cursor = {s} {s}
        \\selection-background = {s}
        \\selection-foreground = {s}
        \\
        \\regular0 = {s}
        \\regular1 = {s}
        \\regular2 = {s}
        \\regular3 = {s}
        \\regular4 = {s}
        \\regular5 = {s}
        \\regular6 = {s}
        \\regular7 = {s}
        \\
        \\bright0 = {s}
        \\bright1 = {s}
        \\bright2 = {s}
        \\bright3 = {s}
        \\bright4 = {s}
        \\bright5 = {s}
        \\bright6 = {s}
        \\bright7 = {s}
        \\
    , .{
        th.kind.name(),
        stripHash(th.base.formatHexRgb(&b_base)),
        stripHash(th.text_main.formatHexRgb(&b_text)),
        stripHash(th.base.formatHexRgb(&b_base)),
        stripHash(th.text_main.formatHexRgb(&b_text)),
        stripHash(th.border.formatHexRgb(&b_border)),
        stripHash(th.text_main.formatHexRgb(&b_text)),
        c_hex[0],
        c_hex[1],
        c_hex[2],
        c_hex[3],
        c_hex[4],
        c_hex[5],
        c_hex[6],
        c_hex[7],
        c_hex[8],
        c_hex[9],
        c_hex[10],
        c_hex[11],
        c_hex[12],
        c_hex[13],
        c_hex[14],
        c_hex[15],
    }) catch "";
}

pub fn generateAlacrittyToml(th: *const Theme, buf: []u8) []const u8 {
    var b_base: [8]u8 = undefined;
    var b_text: [8]u8 = undefined;
    var b_border: [8]u8 = undefined;
    var c_bufs: [16][8]u8 = undefined;

    var c_hex: [16][]const u8 = undefined;
    for (0..16) |i| {
        c_hex[i] = th.getAnsiColor(i).formatHexRgb(&c_bufs[i]);
    }

    return std.fmt.bufPrint(buf,
        \\# Autogenerated rice colors for Alacritty
        \\# Theme - {s}
        \\
        \\[colors.primary]
        \\background = "{s}"
        \\foreground = "{s}"
        \\
        \\[colors.cursor]
        \\text = "{s}"
        \\cursor = "{s}"
        \\
        \\[colors.selection]
        \\text = "{s}"
        \\background = "{s}"
        \\
        \\[colors.normal]
        \\black   = "{s}"
        \\red     = "{s}"
        \\green   = "{s}"
        \\yellow  = "{s}"
        \\blue    = "{s}"
        \\magenta = "{s}"
        \\cyan    = "{s}"
        \\white   = "{s}"
        \\
        \\[colors.bright]
        \\black   = "{s}"
        \\red     = "{s}"
        \\green   = "{s}"
        \\yellow  = "{s}"
        \\blue    = "{s}"
        \\magenta = "{s}"
        \\cyan    = "{s}"
        \\white   = "{s}"
        \\
    , .{
        th.kind.name(),
        th.base.formatHexRgb(&b_base),
        th.text_main.formatHexRgb(&b_text),
        th.base.formatHexRgb(&b_base),
        th.text_main.formatHexRgb(&b_text),
        th.text_main.formatHexRgb(&b_text),
        th.border.formatHexRgb(&b_border),
        c_hex[0],
        c_hex[1],
        c_hex[2],
        c_hex[3],
        c_hex[4],
        c_hex[5],
        c_hex[6],
        c_hex[7],
        c_hex[8],
        c_hex[9],
        c_hex[10],
        c_hex[11],
        c_hex[12],
        c_hex[13],
        c_hex[14],
        c_hex[15],
    }) catch "";
}

pub fn generateMakoConf(th: *const Theme, buf: []u8) []const u8 {
    var b_surf: [8]u8 = undefined;
    var b_text: [8]u8 = undefined;
    var b_acc: [8]u8 = undefined;
    var b_border: [8]u8 = undefined;
    var b_err: [8]u8 = undefined;

    return std.fmt.bufPrint(buf,
        \\# Theme - {s}
        \\
        \\font=Maple Mono NF 10
        \\background-color={s}F2
        \\text-color={s}
        \\width=350
        \\height=110
        \\margin=14
        \\padding=12
        \\border-size=1
        \\border-color={s}
        \\border-radius=6
        \\icons=1
        \\max-icon-size=48
        \\default-timeout=5000
        \\ignore-timeout=0
        \\group-by=summary
        \\progress-color={s}FF
        \\
        \\[urgency=low]
        \\border-color={s}
        \\default-timeout=3000
        \\
        \\[urgency=normal]
        \\border-color={s}
        \\default-timeout=5000
        \\
        \\[urgency=critical]
        \\border-color={s}
        \\text-color=#FFFFFF
        \\default-timeout=0
        \\
    , .{
        th.kind.name(),
        th.surface.formatHexRgb(&b_surf),
        th.text_main.formatHexRgb(&b_text),
        th.accent.formatHexRgb(&b_acc),
        th.accent.formatHexRgb(&b_acc),
        th.border.formatHexRgb(&b_border),
        th.accent.formatHexRgb(&b_acc),
        th.error_color.formatHexRgb(&b_err),
    }) catch "";
}

pub fn generatePaletteEnv(theme_id: []const u8, th: *const Theme, buf: []u8) []const u8 {
    var b_base: [8]u8 = undefined;
    var b_text: [8]u8 = undefined;
    var b_acc: [8]u8 = undefined;
    var b_border: [8]u8 = undefined;
    var b_elev: [8]u8 = undefined;
    var b_surf: [8]u8 = undefined;

    return std.fmt.bufPrint(buf,
        \\# Theme - {s}
        \\export WM_THEME='{s}'
        \\export WM_THEME_NAME='{s}'
        \\export WM_BG='{s}'
        \\export WM_FG='{s}'
        \\export WM_ACCENT='{s}'
        \\export WM_BORDER='{s}'
        \\export WM_CAPSULE_BG='{s}'
        \\export WM_CAPSULE_HOVER='{s}'
        \\export WM_CAPSULE_FG='{s}'
        \\
    , .{
        th.kind.name(),
        theme_id,
        th.kind.name(),
        th.base.formatHexRgb(&b_base),
        th.text_main.formatHexRgb(&b_text),
        th.accent.formatHexRgb(&b_acc),
        th.border.formatHexRgb(&b_border),
        th.elevated.formatHexRgb(&b_elev),
        th.surface.formatHexRgb(&b_surf),
        th.text_main.formatHexRgb(&b_text),
    }) catch "";
}

pub fn generateBtopTheme(th: *const Theme, buf: []u8) []const u8 {
    var b_base: [8]u8 = undefined;
    var b_text: [8]u8 = undefined;
    var b_acc: [8]u8 = undefined;
    var b_sec: [8]u8 = undefined;
    var b_surf: [8]u8 = undefined;
    var b_border: [8]u8 = undefined;
    var b_err: [8]u8 = undefined;
    var b_warn: [8]u8 = undefined;
    var b_succ: [8]u8 = undefined;

    const base = th.base.formatHexRgb(&b_base);
    const fg = th.text_main.formatHexRgb(&b_text);
    const acc = th.accent.formatHexRgb(&b_acc);
    const sec = th.secondary.formatHexRgb(&b_sec);
    const surf = th.surface.formatHexRgb(&b_surf);
    const border = th.border.formatHexRgb(&b_border);
    const err = th.error_color.formatHexRgb(&b_err);
    const warn = th.warning_color.formatHexRgb(&b_warn);
    const succ = th.success_color.formatHexRgb(&b_succ);

    const s1 = std.fmt.bufPrint(buf,
        \\# Theme - {s}
        \\theme[main_bg]="{s}"
        \\theme[main_fg]="{s}"
        \\theme[title]="{s}"
        \\theme[hi_fg]="{s}"
        \\theme[selected_bg]="{s}"
        \\theme[selected_fg]="{s}"
        \\theme[inactive_fg]="{s}"
        \\theme[proc_misc]="{s}"
        \\theme[cpu_box]="{s}"
        \\theme[mem_box]="{s}"
        \\theme[net_box]="{s}"
        \\theme[proc_box]="{s}"
        \\theme[div_line]="{s}"
        \\theme[temp_start]="{s}"
        \\theme[temp_mid]="{s}"
        \\theme[temp_end]="{s}"
        \\
    , .{
        th.kind.name(),
        base,
        fg,
        acc,
        sec,
        surf,
        fg,
        border,
        acc,
        border,
        border,
        border,
        border,
        border,
        succ,
        warn,
        err,
    }) catch return "";

    const s2 = std.fmt.bufPrint(buf[s1.len..],
        \\theme[cpu_start]="{s}"
        \\theme[cpu_mid]="{s}"
        \\theme[cpu_end]="{s}"
        \\theme[free_start]="{s}"
        \\theme[free_mid]="{s}"
        \\theme[free_end]="{s}"
        \\theme[cached_start]="{s}"
        \\theme[cached_mid]="{s}"
        \\theme[cached_end]="{s}"
        \\theme[available_start]="{s}"
        \\theme[available_mid]="{s}"
        \\theme[available_end]="{s}"
        \\theme[used_start]="{s}"
        \\theme[used_mid]="{s}"
        \\theme[used_end]="{s}"
        \\theme[download_start]="{s}"
        \\theme[download_mid]="{s}"
        \\theme[download_end]="{s}"
        \\theme[upload_start]="{s}"
        \\theme[upload_mid]="{s}"
        \\theme[upload_end]="{s}"
        \\
    , .{
        succ, warn, err, succ, warn, err,
        acc,  sec,  err, acc,  succ, warn,
        acc,  warn, err, acc,  sec,  err,
        warn, acc,  sec,
    }) catch return s1;

    return buf[0 .. s1.len + s2.len];
}

fn writeBundleToDir(dir: [:0]const u8, theme_id: []const u8, th: *const Theme) void {
    var p_buf: [512]u8 = undefined;

    if (std.fmt.bufPrintSentinel(&p_buf, "{s}/theme.css", .{dir}, 0)) |p| {
        var buf: [8192]u8 = undefined;
        _ = writeFileContent(p, generateThemeCss(th, &buf));
    } else |_| {}

    if (std.fmt.bufPrintSentinel(&p_buf, "{s}/gtk.css", .{dir}, 0)) |p| {
        var buf: [8192]u8 = undefined;
        _ = writeFileContent(p, generateGtkCss(th, &buf));
    } else |_| {}

    if (std.fmt.bufPrintSentinel(&p_buf, "{s}/colors.rasi", .{dir}, 0)) |p| {
        var buf: [2048]u8 = undefined;
        _ = writeFileContent(p, generateColorsRasi(th, &buf));
    } else |_| {}

    if (std.fmt.bufPrintSentinel(&p_buf, "{s}/foot.ini", .{dir}, 0)) |p| {
        var buf: [4096]u8 = undefined;
        _ = writeFileContent(p, generateFootIni(th, &buf));
    } else |_| {}

    if (std.fmt.bufPrintSentinel(&p_buf, "{s}/alacritty.toml", .{dir}, 0)) |p| {
        var buf: [4096]u8 = undefined;
        _ = writeFileContent(p, generateAlacrittyToml(th, &buf));
    } else |_| {}

    if (std.fmt.bufPrintSentinel(&p_buf, "{s}/mako.conf", .{dir}, 0)) |p| {
        var buf: [2048]u8 = undefined;
        _ = writeFileContent(p, generateMakoConf(th, &buf));
    } else |_| {}

    if (std.fmt.bufPrintSentinel(&p_buf, "{s}/palette.env", .{dir}, 0)) |p| {
        var buf: [2048]u8 = undefined;
        _ = writeFileContent(p, generatePaletteEnv(theme_id, th, &buf));
    } else |_| {}
}

pub fn generateThemeDirectory(theme_id: []const u8, th: *const Theme) void {
    var user_dir_buf: [512]u8 = undefined;
    var user_target_buf: [512]u8 = undefined;
    if (getUserThemesDir(&user_dir_buf)) |user_base| {
        if (std.fmt.bufPrintSentinel(&user_target_buf, "{s}/{s}", .{ user_base, theme_id }, 0)) |target| {
            ensureDirExists(target);
            writeBundleToDir(target, theme_id, th);
        } else |_| {}
    }

    var local_buf: [512]u8 = undefined;
    if (std.fmt.bufPrintSentinel(&local_buf, "themes/{s}", .{theme_id}, 0)) |local_dir| {
        if (c.access("themes", c.F_OK) == 0) {
            ensureDirExists(local_dir);
            writeBundleToDir(local_dir, theme_id, th);
        }
    } else |_| {}
}

pub fn generateAllThemes() void {
    var idx: u8 = 0;
    while (idx < ThemeKind.count) : (idx += 1) {
        const k: ThemeKind = @enumFromInt(idx);
        const th = k.toTheme();
        generateThemeDirectory(k.id(), &th);
    }
}

fn findTemplatesPlacesDir(buf: []u8) ?[]const u8 {
    const candidates = [_][]const u8{
        "themes/icons/templates/places",
        "../themes/icons/templates/places",
        "/usr/share/mizu/themes/icons/templates/places",
        "/usr/local/share/mizu/themes/icons/templates/places",
    };
    for (candidates) |cand| {
        var cand_z: [512]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&cand_z, "{s}", .{cand}, 0)) |cz| {
            if (c.access(cz.ptr, c.F_OK) == 0) {
                return std.fmt.bufPrint(buf, "{s}", .{cand}) catch null;
            }
        } else |_| {}
    }

    if (c.getenv("HOME")) |home_ptr| {
        const home = std.mem.span(home_ptr);
        const user_candidates = [_][]const u8{
            ".local/share/icons/Papirus-Custom/templates/places",
            ".icons/Papirus-Custom/templates/places",
        };
        for (user_candidates) |uc| {
            var cand_z: [512]u8 = undefined;
            if (std.fmt.bufPrintSentinel(&cand_z, "{s}/{s}", .{ home, uc }, 0)) |cz| {
                if (c.access(cz.ptr, c.F_OK) == 0) {
                    return std.fmt.bufPrint(buf, "{s}/{s}", .{ home, uc }) catch null;
                }
            } else |_| {}
        }
    }
    return null;
}

fn recolorIconsInTarget(templates_dir: []const u8, target_base: []const u8, accent: []const u8, back_color: []const u8, glyph_color: []const u8, text_color: []const u8) void {
    const sizes = [_][]const u8{ "16x16", "22x22", "24x24", "32x32", "48x48", "64x64" };
    for (sizes) |size_name| {
        var t_size_buf: [512]u8 = undefined;
        var d_size_buf: [512]u8 = undefined;
        const t_size_z = std.fmt.bufPrintSentinel(&t_size_buf, "{s}/{s}", .{ templates_dir, size_name }, 0) catch continue;
        const d_size_z = std.fmt.bufPrintSentinel(&d_size_buf, "{s}/{s}/places", .{ target_base, size_name }, 0) catch continue;

        ensureDirExists(d_size_z);

        const dir = c.opendir(t_size_z.ptr) orelse continue;
        defer _ = c.closedir(dir);

        while (c.readdir(dir)) |entry| {
            const fname = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
            if (!std.mem.endsWith(u8, fname, ".svg")) continue;

            var in_path_buf: [512]u8 = undefined;
            var out_path_buf: [512]u8 = undefined;
            const in_path = std.fmt.bufPrintSentinel(&in_path_buf, "{s}/{s}/{s}", .{ templates_dir, size_name, fname }, 0) catch continue;
            const out_path = std.fmt.bufPrintSentinel(&out_path_buf, "{s}/{s}/places/{s}", .{ target_base, size_name, fname }, 0) catch continue;

            const in_f = c.fopen(in_path.ptr, "rb") orelse continue;
            var in_buf: [8192]u8 = undefined;
            const n_read = c.fread(&in_buf, 1, in_buf.len, in_f);
            _ = c.fclose(in_f);
            if (n_read <= 0) continue;

            const template = in_buf[0..n_read];
            var out_buf: [8192]u8 = undefined;
            var out_len: usize = 0;
            var i: usize = 0;
            while (i < template.len and out_len < out_buf.len - 32) {
                if (std.mem.startsWith(u8, template[i..], "__FRONT_COLOR__")) {
                    @memcpy(out_buf[out_len .. out_len + accent.len], accent);
                    out_len += accent.len;
                    i += "__FRONT_COLOR__".len;
                } else if (std.mem.startsWith(u8, template[i..], "__BACK_COLOR__")) {
                    @memcpy(out_buf[out_len .. out_len + back_color.len], back_color);
                    out_len += back_color.len;
                    i += "__BACK_COLOR__".len;
                } else if (std.mem.startsWith(u8, template[i..], "__GLYPH_COLOR__")) {
                    @memcpy(out_buf[out_len .. out_len + glyph_color.len], glyph_color);
                    out_len += glyph_color.len;
                    i += "__GLYPH_COLOR__".len;
                } else if (std.mem.startsWith(u8, template[i..], "__HIGHLIGHT_COLOR__")) {
                    @memcpy(out_buf[out_len .. out_len + accent.len], accent);
                    out_len += accent.len;
                    i += "__HIGHLIGHT_COLOR__".len;
                } else if (std.mem.startsWith(u8, template[i..], "__TEXT_COLOR__")) {
                    @memcpy(out_buf[out_len .. out_len + text_color.len], text_color);
                    out_len += text_color.len;
                    i += "__TEXT_COLOR__".len;
                } else {
                    out_buf[out_len] = template[i];
                    out_len += 1;
                    i += 1;
                }
            }

            _ = writeFileContent(out_path, out_buf[0..out_len]);
        }
    }

    var cmd_buf: [512]u8 = undefined;
    if (std.fmt.bufPrint(&cmd_buf, "gtk-update-icon-cache -q -f -t \"{s}\" 2>/dev/null || true", .{target_base})) |cmd| {
        exec.spawnShell(cmd);
    } else |_| {}
}

pub fn recolorSystemIcons(th: *const Theme) void {
    var t_dir_buf: [512]u8 = undefined;
    const t_dir = findTemplatesPlacesDir(&t_dir_buf) orelse return;

    var b_acc: [8]u8 = undefined;
    const accent = th.accent.formatHexRgb(&b_acc);

    const r = th.accent.r;
    const g = th.accent.g;
    const b = th.accent.b;

    const r_back: u8 = @intFromFloat(@as(f32, @floatFromInt(r)) * 0.80);
    const g_back: u8 = @intFromFloat(@as(f32, @floatFromInt(g)) * 0.80);
    const b_back: u8 = @intFromFloat(@as(f32, @floatFromInt(b)) * 0.80);
    var back_buf: [8]u8 = undefined;
    const back_color = std.fmt.bufPrint(&back_buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ r_back, g_back, b_back }) catch "#333333";

    const lum = (0.299 * @as(f32, @floatFromInt(r)) + 0.587 * @as(f32, @floatFromInt(g)) + 0.114 * @as(f32, @floatFromInt(b))) / 255.0;
    var glyph_buf: [8]u8 = undefined;
    const glyph_color = if (lum > 0.45) blk: {
        const gr: u8 = @intFromFloat(@as(f32, @floatFromInt(r)) * 0.35);
        const gg: u8 = @intFromFloat(@as(f32, @floatFromInt(g)) * 0.35);
        const gb: u8 = @intFromFloat(@as(f32, @floatFromInt(b)) * 0.35);
        break :blk std.fmt.bufPrint(&glyph_buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ gr, gg, gb }) catch "#000000";
    } else blk: {
        const rf = @as(f32, @floatFromInt(r));
        const gf = @as(f32, @floatFromInt(g));
        const bf = @as(f32, @floatFromInt(b));
        const gr: u8 = @intFromFloat(rf + (255.0 - rf) * 0.65);
        const gg: u8 = @intFromFloat(gf + (255.0 - gf) * 0.65);
        const gb: u8 = @intFromFloat(bf + (255.0 - bf) * 0.65);
        break :blk std.fmt.bufPrint(&glyph_buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ gr, gg, gb }) catch "#ffffff";
    };

    var text_buf: [8]u8 = undefined;
    const text_color = th.text_main.formatHexRgb(&text_buf);

    if (std.mem.lastIndexOf(u8, t_dir, "/templates/places")) |idx| {
        const base_dir = t_dir[0..idx];
        recolorIconsInTarget(t_dir, base_dir, accent, back_color, glyph_color, text_color);
    }

    if (c.getenv("HOME")) |home_ptr| {
        const home = std.mem.span(home_ptr);
        const user_bases = [_][]const u8{
            ".local/share/icons/Papirus-Custom",
            ".icons/Papirus-Custom",
        };
        for (user_bases) |ub| {
            var ub_buf: [512]u8 = undefined;
            if (std.fmt.bufPrintSentinel(&ub_buf, "{s}/{s}", .{ home, ub }, 0)) |ub_z| {
                if (c.access(ub_z.ptr, c.F_OK) == 0) {
                    recolorIconsInTarget(t_dir, ub_z, accent, back_color, glyph_color, text_color);
                }
            } else |_| {}
        }
    }
}

pub fn broadcastTerminalColors(th: *const Theme) void {
    var fg_buf: [8]u8 = undefined;
    var bg_buf: [8]u8 = undefined;
    const fg = th.text_main.formatHexRgb(&fg_buf);
    const bg = th.base.formatHexRgb(&bg_buf);

    var seq_buf: [64]u8 = undefined;
    const seq = std.fmt.bufPrint(&seq_buf, "\x1b]10;{s}\x07\x1b]11;{s}\x07", .{ fg, bg }) catch return;

    const dir = c.opendir("/dev/pts") orelse return;
    defer _ = c.closedir(dir);

    while (c.readdir(dir)) |entry| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        var is_pty = name.len > 0;
        for (name) |ch| {
            if (ch < '0' or ch > '9') {
                is_pty = false;
                break;
            }
        }
        if (!is_pty) continue;

        var pty_buf: [64]u8 = undefined;
        const pty_path = std.fmt.bufPrintSentinel(&pty_buf, "/dev/pts/{s}", .{name}, 0) catch continue;
        const fd = c.open(pty_path.ptr, c.O_WRONLY);
        if (fd >= 0) {
            _ = c.write(fd, seq.ptr, seq.len);
            _ = c.close(fd);
        }
    }
}

pub fn reloadSubsystems() void {
    exec.spawnShell("makoctl reload 2>/dev/null || true");
    exec.spawnShell("mmsg dispatch reload_config 2>/dev/null || true");
    exec.spawnShell("alacritty msg config -r 2>/dev/null || true");
    exec.spawnShell("thunar -q 2>/dev/null || true");
    exec.spawnShell("pkill -USR1 mizu 2>/dev/null || true");
}

fn updateGtkSettingsIni(ini_path: [:0]const u8) void {
    const f = c.fopen(ini_path.ptr, "rb");
    if (f) |handle| {
        var buf: [4096]u8 = undefined;
        const n = c.fread(&buf, 1, buf.len - 1, handle);
        _ = c.fclose(handle);
        if (n > 0) {
            buf[n] = 0;
            const content = buf[0..n];
            if (std.mem.indexOf(u8, content, "gtk-icon-theme-name") != null) {
                return;
            }
        }
    }

    const default_ini =
        \\[Settings]
        \\gtk-icon-theme-name = Papirus-Custom
        \\gtk-theme-name = Adwaita-dark
        \\gtk-application-prefer-dark-theme = 1
        \\gtk-font-name = Maple Mono 10
        \\gtk-cursor-theme-name = Adwaita
        \\gtk-cursor-theme-size = 24
        \\
    ;
    _ = writeFileContent(ini_path, default_ini);
}

pub fn applyDesktopIntegration(th: *const Theme) void {
    const home_opt = c.getenv("HOME");
    if (home_opt == null) return;
    const home = std.mem.span(home_opt.?);

    var gtk_buf: [8192]u8 = undefined;
    const gtk_css = generateGtkCss(th, &gtk_buf);

    var gtk3_dir_buf: [512]u8 = undefined;
    if (std.fmt.bufPrintSentinel(&gtk3_dir_buf, "{s}/.config/gtk-3.0", .{home}, 0)) |dir3| {
        ensureDirExists(dir3);
        var f_buf: [512]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&f_buf, "{s}/theme.css", .{dir3}, 0)) |f| {
            _ = writeFileContent(f, gtk_css);
        } else |_| {}
        if (std.fmt.bufPrintSentinel(&f_buf, "{s}/gtk.css", .{dir3}, 0)) |f| {
            _ = writeFileContent(f, gtk_css);
        } else |_| {}

        if (std.fmt.bufPrintSentinel(&f_buf, "{s}/settings.ini", .{dir3}, 0)) |f| {
            updateGtkSettingsIni(f);
        } else |_| {}
    } else |_| {}

    var gtk4_dir_buf: [512]u8 = undefined;
    if (std.fmt.bufPrintSentinel(&gtk4_dir_buf, "{s}/.config/gtk-4.0", .{home}, 0)) |dir4| {
        ensureDirExists(dir4);
        var f_buf: [512]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&f_buf, "{s}/gtk.css", .{dir4}, 0)) |f| {
            _ = writeFileContent(f, gtk_css);
        } else |_| {}
    } else |_| {}

    var app_dir_buf: [512]u8 = undefined;
    var app_file_buf: [512]u8 = undefined;

    if (std.fmt.bufPrintSentinel(&app_dir_buf, "{s}/.config/foot", .{home}, 0)) |dir| {
        if (c.access(dir.ptr, c.F_OK) == 0) {
            if (std.fmt.bufPrintSentinel(&app_file_buf, "{s}/colors.ini", .{dir}, 0)) |fp| {
                var foot_buf: [4096]u8 = undefined;
                _ = writeFileContent(fp, generateFootIni(th, &foot_buf));
            } else |_| {}
        }
    } else |_| {}

    if (std.fmt.bufPrintSentinel(&app_dir_buf, "{s}/.config/alacritty", .{home}, 0)) |dir| {
        if (c.access(dir.ptr, c.F_OK) == 0) {
            if (std.fmt.bufPrintSentinel(&app_file_buf, "{s}/colors.toml", .{dir}, 0)) |fp| {
                var alac_buf: [4096]u8 = undefined;
                _ = writeFileContent(fp, generateAlacrittyToml(th, &alac_buf));
            } else |_| {}
        }
    } else |_| {}

    if (std.fmt.bufPrintSentinel(&app_dir_buf, "{s}/.config/rofi", .{home}, 0)) |dir| {
        if (c.access(dir.ptr, c.F_OK) == 0) {
            if (std.fmt.bufPrintSentinel(&app_file_buf, "{s}/colors.rasi", .{dir}, 0)) |fp| {
                var rofi_buf: [2048]u8 = undefined;
                _ = writeFileContent(fp, generateColorsRasi(th, &rofi_buf));
            } else |_| {}
        }
    } else |_| {}

    if (std.fmt.bufPrintSentinel(&app_dir_buf, "{s}/.config/mako", .{home}, 0)) |dir| {
        if (c.access(dir.ptr, c.F_OK) == 0) {
            if (std.fmt.bufPrintSentinel(&app_file_buf, "{s}/config", .{dir}, 0)) |fp| {
                var mako_buf: [2048]u8 = undefined;
                _ = writeFileContent(fp, generateMakoConf(th, &mako_buf));
            } else |_| {}
        }
    } else |_| {}

    if (std.fmt.bufPrintSentinel(&app_dir_buf, "{s}/.config/btop/themes", .{home}, 0)) |dir| {
        ensureDirExists(dir);
        if (std.fmt.bufPrintSentinel(&app_file_buf, "{s}/wm.theme", .{dir}, 0)) |fp| {
            var btop_buf: [4096]u8 = undefined;
            _ = writeFileContent(fp, generateBtopTheme(th, &btop_buf));
        } else |_| {}
    } else |_| {}

    exec.spawnShell("gsettings set org.gnome.desktop.interface gtk-theme Adwaita-dark 2>/dev/null || true");
    exec.spawnShell("gsettings set org.gnome.desktop.interface icon-theme Papirus-Custom 2>/dev/null || true");
    exec.spawnShell("gsettings set org.gnome.desktop.interface color-scheme prefer-dark 2>/dev/null || true");

    exec.spawnShell("xfconf-query -c thunar -p /shortcuts-icon-size -s THUNAR_ICON_SIZE_16 2>/dev/null || true");
    exec.spawnShell("xfconf-query -c thunar -p /misc-symbolic-icons-in-toolbar -s true 2>/dev/null || true");

    var notif_buf: [256]u8 = undefined;
    if (std.fmt.bufPrint(&notif_buf, "notify-send -h string:x-canonical-private-synchronous:wm-theme \"Theme Applied\" \"Active desktop theme: {s}\" 2>/dev/null || true", .{th.kind.name()})) |cmd| {
        exec.spawnShell(cmd);
    } else |_| {}
}

pub fn selectTheme(name: []const u8) Theme {
    ensureUserTheme(name);
    const th = loadTheme(name);

    var cache_dir_buf: [512]u8 = undefined;
    var file_buf: [512]u8 = undefined;

    if (c.getenv("HOME")) |home_ptr| {
        const home = std.mem.span(home_ptr);
        if (std.fmt.bufPrintSentinel(&cache_dir_buf, "{s}/.cache/mizu", .{home}, 0)) |dir_path| {
            _ = c.mkdir(dir_path.ptr, 0o755);
        } else |_| {}
        if (std.fmt.bufPrintSentinel(&file_buf, "{s}/.cache/mizu/current_theme", .{home}, 0)) |file_path| {
            if (c.fopen(file_path.ptr, "wb")) |f| {
                defer _ = c.fclose(f);
                _ = c.fwrite(name.ptr, 1, name.len, f);
                _ = c.fwrite("\n", 1, 1, f);
            }
        } else |_| {}

        var state_dir_buf: [512]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&state_dir_buf, "{s}/.local/state/wm", .{home}, 0)) |sdir| {
            ensureDirExists(sdir);
            var sf_buf: [512]u8 = undefined;
            if (std.fmt.bufPrintSentinel(&sf_buf, "{s}/current", .{sdir}, 0)) |cfp| {
                if (c.fopen(cfp.ptr, "wb")) |sf| {
                    defer _ = c.fclose(sf);
                    _ = c.fwrite(name.ptr, 1, name.len, sf);
                    _ = c.fwrite("\n", 1, 1, sf);
                }
            } else |_| {}
            if (std.fmt.bufPrintSentinel(&sf_buf, "{s}/current_mode", .{sdir}, 0)) |mfp| {
                if (c.fopen(mfp.ptr, "wb")) |sf| {
                    defer _ = c.fclose(sf);
                    _ = c.fwrite("static\n", 1, 7, sf);
                }
            } else |_| {}
        } else |_| {}
    }

    generateMizuCss(th);

    const icons = @import("../graphics/icons.zig");
    icons.setActiveTheme(name, th);

    exec.spawnShell("pkill -USR1 mizu 2>/dev/null || true");

    return th;
}

pub fn saveCurrentTheme(kind: ThemeKind) void {
    _ = selectTheme(kind.id());
}

pub fn loadSavedThemeStruct() Theme {
    var file_buf: [512]u8 = undefined;
    const home_opt = c.getenv("HOME");
    if (home_opt == null) return ThemeKind.default_theme.toTheme();
    const home = std.mem.span(home_opt.?);

    const file_path = std.fmt.bufPrintSentinel(&file_buf, "{s}/.cache/mizu/current_theme", .{home}, 0) catch return ThemeKind.default_theme.toTheme();
    const f = c.fopen(file_path.ptr, "rb") orelse {
        const def_th = ThemeKind.default_theme.toTheme();
        var css_path_buf: [512]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&css_path_buf, "{s}/.config/mizu/mizu.css", .{home}, 0)) |css_path| {
            if (c.access(css_path.ptr, 0) != 0) {
                generateMizuCss(def_th);
            }
        } else |_| {}
        return def_th;
    };
    defer _ = c.fclose(f);

    var buf: [64]u8 = undefined;
    const bytes = c.fread(&buf, 1, buf.len - 1, f);
    if (bytes <= 0) return ThemeKind.default_theme.toTheme();
    buf[bytes] = 0;
    const trimmed = std.mem.trim(u8, buf[0..bytes], " \t\r\n");
    const loaded = loadTheme(trimmed);
    const icons = @import("../graphics/icons.zig");
    icons.setActiveTheme(trimmed, loaded);
    return loaded;
}

pub fn loadSavedTheme() ?ThemeKind {
    var file_buf: [512]u8 = undefined;
    const home_opt = c.getenv("HOME");
    if (home_opt == null) return null;
    const home = std.mem.span(home_opt.?);

    const file_path = std.fmt.bufPrintSentinel(&file_buf, "{s}/.cache/mizu/current_theme", .{home}, 0) catch return null;
    const f = c.fopen(file_path.ptr, "rb") orelse {
        // If no saved theme, generate default theme CSS if missing
        const def_th = ThemeKind.default_theme.toTheme();
        var css_path_buf: [512]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&css_path_buf, "{s}/.config/mizu/mizu.css", .{home}, 0)) |css_path| {
            if (c.access(css_path.ptr, 0) != 0) {
                generateMizuCss(def_th);
            }
        } else |_| {}
        return null;
    };
    defer _ = c.fclose(f);

    var buf: [64]u8 = undefined;
    const bytes = c.fread(&buf, 1, buf.len - 1, f);
    if (bytes <= 0) return null;
    buf[bytes] = 0;
    const trimmed = std.mem.trim(u8, buf[0..bytes], " \t\r\n");
    const found_kind = ThemeKind.fromString(trimmed);
    if (found_kind) |k| {
        // Verify mizu.css exists, generate if missing
        var css_path_buf: [512]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&css_path_buf, "{s}/.config/mizu/mizu.css", .{home}, 0)) |css_path| {
            if (c.access(css_path.ptr, 0) != 0) {
                generateMizuCss(k.toTheme());
            }
        } else |_| {}
    }
    return found_kind;
}

test "ThemeKind cycle and parse" {
    try std.testing.expectEqual(ThemeKind.catppuccin, ThemeKind.nord.next());
    try std.testing.expectEqual(ThemeKind.tokyo_night, ThemeKind.catppuccin.next());
    try std.testing.expectEqual(ThemeKind.rose_pine, ThemeKind.tokyo_night.next());
    try std.testing.expectEqual(ThemeKind.dracula, ThemeKind.rose_pine.next());
    try std.testing.expectEqual(ThemeKind.frosted_neumorphic, ThemeKind.dracula.next());
    try std.testing.expectEqual(ThemeKind.nord, ThemeKind.frosted_neumorphic.next());

    try std.testing.expectEqual(ThemeKind.frosted_neumorphic, ThemeKind.fromString("frosted").?);
    try std.testing.expectEqual(ThemeKind.frosted_neumorphic, ThemeKind.fromString("neumorphic").?);
    try std.testing.expectEqual(ThemeKind.frosted_neumorphic, ThemeKind.fromString("Frosted Neumorphic").?);
    try std.testing.expectEqual(ThemeKind.frosted_neumorphic, ThemeKind.fromString("mizu").?);
    try std.testing.expectEqual(ThemeKind.frosted_neumorphic, ThemeKind.fromString("default").?);

    try std.testing.expectEqual(ThemeKind.nord, ThemeKind.fromString("nord").?);
    try std.testing.expectEqual(ThemeKind.nord, ThemeKind.fromString("nord_frost").?);
    try std.testing.expectEqual(ThemeKind.nord, ThemeKind.fromString("Nord Frost").?);
    try std.testing.expectEqual(ThemeKind.catppuccin, ThemeKind.fromString("catppuccin").?);
    try std.testing.expectEqual(ThemeKind.catppuccin, ThemeKind.fromString("Catppuccin Mocha").?);
    try std.testing.expectEqual(ThemeKind.tokyo_night, ThemeKind.fromString("tokyo_night").?);
    try std.testing.expectEqual(ThemeKind.tokyo_night, ThemeKind.fromString("Tokyo Night").?);
    try std.testing.expectEqual(ThemeKind.rose_pine, ThemeKind.fromString("rose_pine").?);
    try std.testing.expectEqual(ThemeKind.rose_pine, ThemeKind.fromString("Rosé Pine").?);
    try std.testing.expectEqual(ThemeKind.rose_pine, ThemeKind.fromString("gruvbox").?);
    try std.testing.expectEqual(ThemeKind.rose_pine, ThemeKind.fromString("Gruvbox Material").?);
    try std.testing.expectEqual(ThemeKind.dracula, ThemeKind.fromString("dracula").?);
    try std.testing.expectEqual(ThemeKind.dracula, ThemeKind.fromString("Ant Dracula").?);
    try std.testing.expectEqual(ThemeKind.dracula, ThemeKind.fromString("ant-dracula").?);

    const frosted = ThemeKind.frosted_neumorphic.toTheme();
    try std.testing.expectEqual(ThemeKind.frosted_neumorphic, frosted.kind);
    try std.testing.expectEqual(Color.hex(0x4361EE).toArgb(), frosted.accent.toArgb());

    const nord = ThemeKind.nord.toTheme();
    try std.testing.expectEqual(ThemeKind.nord, nord.kind);
    try std.testing.expectEqual(Color.fromHex("#2E3440").toArgb(), nord.base.toArgb());
    try std.testing.expectEqual(Color.fromHex("#88C0D0").toArgb(), nord.accent.toArgb());

    const drac = ThemeKind.dracula.toTheme();
    try std.testing.expectEqual(ThemeKind.dracula, drac.kind);
    try std.testing.expectEqual(Color.fromHex("#282A36").toArgb(), drac.base.toArgb());
    try std.testing.expectEqual(Color.fromHex("#BD93F9").toArgb(), drac.accent.toArgb());
}

test "CSS theme parsing and variable overrides" {
    const css =
        \\:root {
        \\  --mizu-theme-name: "Custom Cyber";
        \\  --mizu-base: #0F141C;
        \\  --mizu-surface: #1E2530;
        \\  --mizu-accent: #00FFCC;
        \\  --mizu-radius-bar: 18px;
        \\  --mizu-radius-panel: 28px;
        \\}
    ;
    const base_th = ThemeKind.nord.toTheme();
    const parsed = parseThemeCss(css, base_th);

    try std.testing.expectEqual(Color.hex(0x0F141C).toArgb(), parsed.base.toArgb());
    try std.testing.expectEqual(Color.hex(0x1E2530).toArgb(), parsed.surface.toArgb());
    try std.testing.expectEqual(Color.hex(0x00FFCC).toArgb(), parsed.accent.toArgb());
    try std.testing.expectEqual(@as(u32, 18), parsed.radius_bar);
    try std.testing.expectEqual(@as(u32, 28), parsed.radius_panel);
    // Unspecified property preserves base theme value
    try std.testing.expectEqual(base_th.elevated.toArgb(), parsed.elevated.toArgb());
}

test "loadTheme falls back safely on unknown theme" {
    const fallback_th = loadTheme("nonexistent_theme_xyz_123");
    try std.testing.expectEqual(ThemeKind.default_theme, fallback_th.kind);
}

test "Color luminance and contrasting text colors" {
    // Red (dark background) -> contrasting text should be light #ECEFF4
    const nord_red = Color.hex(0xBF616A);
    try std.testing.expect(!nord_red.isLight());
    try std.testing.expectEqual(Color.rgb(0xEC, 0xEF, 0xF4).toArgb(), nord_red.contrastingTextColor().toArgb());

    // Accent Frost Cyan (light background) -> contrasting text should be dark #181A1F
    const nord_cyan = Color.hex(0x88C0D0);
    try std.testing.expect(nord_cyan.isLight());
    try std.testing.expectEqual(Color.rgb(0x18, 0x1A, 0x1F).toArgb(), nord_cyan.contrastingTextColor().toArgb());

    // Warning Yellow (light background) -> contrasting text should be dark #181A1F
    const nord_yellow = Color.hex(0xEBCB8B);
    try std.testing.expect(nord_yellow.isLight());
    try std.testing.expectEqual(Color.rgb(0x18, 0x1A, 0x1F).toArgb(), nord_yellow.contrastingTextColor().toArgb());

    // Deep Base (dark background) -> contrasting text should be light #ECEFF4
    const nord_base = Color.hex(0x2E3440);
    try std.testing.expect(!nord_base.isLight());
    try std.testing.expectEqual(Color.rgb(0xEC, 0xEF, 0xF4).toArgb(), nord_base.contrastingTextColor().toArgb());
}

test "generateMizuCss produces valid stylesheet" {
    const test_th = ThemeKind.frosted_neumorphic.toTheme();
    generateMizuCss(test_th);

    const home_opt = c.getenv("HOME");
    if (home_opt) |home_ptr| {
        const home = std.mem.span(home_ptr);
        var css_path_buf: [512]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&css_path_buf, "{s}/.config/mizu/mizu.css", .{home}, 0)) |css_path| {
            const f = c.fopen(css_path.ptr, "rb");
            try std.testing.expect(f != null);
            if (f) |handle| _ = c.fclose(handle);
        } else |_| {}
    }
}

test "ensureUserTheme copies built-in theme and preserves customizations" {
    var user_dir_buf: [512]u8 = undefined;
    const user_base = getUserThemesDir(&user_dir_buf) orelse return;

    // Ensure dracula theme exists in user config
    ensureUserTheme("dracula");

    var check_buf: [512]u8 = undefined;
    const check_path = try std.fmt.bufPrintSentinel(&check_buf, "{s}/dracula/theme.css", .{user_base}, 0);
    try std.testing.expect(c.access(check_path.ptr, c.F_OK) == 0);

    // Verify icons were copied as well
    var icon_check_buf: [512]u8 = undefined;
    const icon_check_path = try std.fmt.bufPrintSentinel(&icon_check_buf, "{s}/dracula/icons/index.theme", .{user_base}, 0);
    try std.testing.expect(c.access(icon_check_path.ptr, c.F_OK) == 0);

    // Calling ensureUserTheme again must not overwrite customizations
    ensureUserTheme("dracula");
    try std.testing.expect(c.access(check_path.ptr, c.F_OK) == 0);
}

test "selectTheme switches theme and exports css" {
    const th = selectTheme("nord");
    try std.testing.expectEqual(Color.hex(0x88C0D0).toArgb(), th.accent.toArgb());

    // Switch to dracula
    const drac_th = selectTheme("dracula");
    try std.testing.expectEqual(Color.hex(0xBD93F9).toArgb(), drac_th.accent.toArgb());
}
