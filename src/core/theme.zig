const std = @import("std");
const exec = @import("exec.zig");

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

    pub fn fromHex(str: []const u8) Color {
        var s = str;
        if (s.len > 0 and s[0] == '#') {
            s = s[1..];
        }

        if (s.len == 6) {
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

    pub const default_theme = ThemeKind.frosted_neumorphic;
    pub const count: u8 = 5;

    // Backward compatibility aliases
    pub const mizu = ThemeKind.frosted_neumorphic;
    pub const pastel = ThemeKind.frosted_neumorphic;
    pub const frost = ThemeKind.frosted_neumorphic;
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
        };
    }

    pub fn icon(self: ThemeKind) []const u8 {
        return switch (self) {
            .frosted_neumorphic => "󰖔",
            .nord => "󰜗",
            .catppuccin => "󰄛",
            .tokyo_night => "󰛓",
            .rose_pine => "󱎂",
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
        if (std.ascii.eqlIgnoreCase(str, "frosted") or
            std.ascii.eqlIgnoreCase(str, "neumorphic") or
            std.ascii.eqlIgnoreCase(str, "frosted_neumorphic") or
            std.ascii.eqlIgnoreCase(str, "frosted-neumorphic") or
            std.ascii.eqlIgnoreCase(str, "frosted neumorphic") or
            std.ascii.eqlIgnoreCase(str, "pastel") or
            std.ascii.eqlIgnoreCase(str, "mizu") or
            std.ascii.eqlIgnoreCase(str, "default"))
        {
            return .frosted_neumorphic;
        }
        if (std.ascii.eqlIgnoreCase(str, "nord") or
            std.ascii.eqlIgnoreCase(str, "nord frost") or
            std.ascii.eqlIgnoreCase(str, "nord_frost") or
            std.ascii.eqlIgnoreCase(str, "nord-frost") or
            std.ascii.eqlIgnoreCase(str, "frost_nord"))
        {
            return .nord;
        }
        if (std.ascii.eqlIgnoreCase(str, "catppuccin") or
            std.ascii.eqlIgnoreCase(str, "catppuccin mocha") or
            std.ascii.eqlIgnoreCase(str, "catppuccin_mocha") or
            std.ascii.eqlIgnoreCase(str, "catppuccin-mocha") or
            std.ascii.eqlIgnoreCase(str, "mocha") or
            std.ascii.eqlIgnoreCase(str, "material_you") or
            std.ascii.eqlIgnoreCase(str, "materialyou"))
        {
            return .catppuccin;
        }
        if (std.ascii.eqlIgnoreCase(str, "tokyo_night") or
            std.ascii.eqlIgnoreCase(str, "tokyo night") or
            std.ascii.eqlIgnoreCase(str, "tokyonight") or
            std.ascii.eqlIgnoreCase(str, "tokyo-night") or
            std.ascii.eqlIgnoreCase(str, "tokyo") or
            std.ascii.eqlIgnoreCase(str, "noctalia"))
        {
            return .tokyo_night;
        }
        if (std.ascii.eqlIgnoreCase(str, "rose_pine") or
            std.ascii.eqlIgnoreCase(str, "rose pine") or
            std.ascii.eqlIgnoreCase(str, "rosé pine") or
            std.ascii.eqlIgnoreCase(str, "rosepine") or
            std.ascii.eqlIgnoreCase(str, "rose-pine") or
            std.ascii.eqlIgnoreCase(str, "rose") or
            std.ascii.eqlIgnoreCase(str, "gruvbox") or
            std.ascii.eqlIgnoreCase(str, "gruvbox material") or
            std.ascii.eqlIgnoreCase(str, "gruvbox_material") or
            std.ascii.eqlIgnoreCase(str, "gruvbox-material") or
            std.ascii.eqlIgnoreCase(str, "gruvbox_dark"))
        {
            return .rose_pine;
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
    th.card_bg = Color.init(225, 255, 255, 255);
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

// Backward compatibility aliases
pub const mizuTheme = nordTheme;
pub const noctaliaTheme = tokyoNightTheme;
pub const materialYouTheme = catppuccinTheme;

pub fn generateMizuCss(th: Theme) void {
    const c = @import("../c.zig").c;
    var dir_buf: [512]u8 = undefined;
    var file_buf: [512]u8 = undefined;
    const home_opt = c.getenv("HOME");
    if (home_opt == null) return;
    const home = std.mem.span(home_opt.?);

    const dir_path = std.fmt.bufPrintZ(&dir_buf, "{s}/.config/mizu", .{home}) catch return;
    _ = c.mkdir(dir_path.ptr, 0o755);

    const file_path = std.fmt.bufPrintZ(&file_buf, "{s}/.config/mizu/mizu.css", .{home}) catch return;
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
        \\/* ===================================================================
        \\ * Mizu Dynamic Theme Stylesheet
        \\ * Location: ~/.config/mizu/mizu.css
        \\ * Generated dynamically for: GTK 3, GTK 4, Thunar, MangoWC, Firefox
        \\ * Theme Preset: {s}
        \\ * =================================================================== */
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

pub fn saveCurrentTheme(kind: ThemeKind) void {
    const c = @import("../c.zig").c;
    var dir_buf: [512]u8 = undefined;
    var file_buf: [512]u8 = undefined;
    const home_opt = c.getenv("HOME");
    if (home_opt == null) return;
    const home = std.mem.span(home_opt.?);

    const dir_path = std.fmt.bufPrintZ(&dir_buf, "{s}/.cache/mizu", .{home}) catch return;
    _ = c.mkdir(dir_path.ptr, 0o755);

    const file_path = std.fmt.bufPrintZ(&file_buf, "{s}/.cache/mizu/current_theme", .{home}) catch return;
    const f = c.fopen(file_path.ptr, "wb") orelse return;
    defer _ = c.fclose(f);

    const name_str = kind.name();
    _ = c.fwrite(name_str.ptr, 1, name_str.len, f);
    _ = c.fwrite("\n", 1, 1, f);

    // Export mizu.css dynamically to ~/.config/mizu/mizu.css
    generateMizuCss(kind.toTheme());

    // Notify any running mizu instances by signaling SIGUSR1
    exec.spawnShell("pkill -USR1 mizu 2>/dev/null || true");
}

pub fn loadSavedTheme() ?ThemeKind {
    const c = @import("../c.zig").c;
    var file_buf: [512]u8 = undefined;
    const home_opt = c.getenv("HOME");
    if (home_opt == null) return null;
    const home = std.mem.span(home_opt.?);

    const file_path = std.fmt.bufPrintZ(&file_buf, "{s}/.cache/mizu/current_theme", .{home}) catch return null;
    const f = c.fopen(file_path.ptr, "rb") orelse {
        // If no saved theme, generate default theme CSS if missing
        const def_th = ThemeKind.default_theme.toTheme();
        var css_path_buf: [512]u8 = undefined;
        if (std.fmt.bufPrintZ(&css_path_buf, "{s}/.config/mizu/mizu.css", .{home})) |css_path| {
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
        if (std.fmt.bufPrintZ(&css_path_buf, "{s}/.config/mizu/mizu.css", .{home})) |css_path| {
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
    try std.testing.expectEqual(ThemeKind.frosted_neumorphic, ThemeKind.rose_pine.next());
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

    const frosted = ThemeKind.frosted_neumorphic.toTheme();
    try std.testing.expectEqual(ThemeKind.frosted_neumorphic, frosted.kind);
    try std.testing.expectEqual(Color.hex(0x4361EE).toArgb(), frosted.accent.toArgb());

    const nord = ThemeKind.nord.toTheme();
    try std.testing.expectEqual(ThemeKind.nord, nord.kind);
    try std.testing.expectEqual(Color.fromHex("#2E3440").toArgb(), nord.base.toArgb());
    try std.testing.expectEqual(Color.fromHex("#88C0D0").toArgb(), nord.accent.toArgb());
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
    const c = @import("../c.zig").c;
    const test_th = ThemeKind.frosted_neumorphic.toTheme();
    generateMizuCss(test_th);

    const home_opt = c.getenv("HOME");
    if (home_opt) |home_ptr| {
        const home = std.mem.span(home_ptr);
        var css_path_buf: [512]u8 = undefined;
        if (std.fmt.bufPrintZ(&css_path_buf, "{s}/.config/mizu/mizu.css", .{home})) |css_path| {
            const f = c.fopen(css_path.ptr, "rb");
            try std.testing.expect(f != null);
            if (f) |handle| _ = c.fclose(handle);
        } else |_| {}
    }
}
