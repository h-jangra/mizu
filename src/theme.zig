const std = @import("std");

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

    pub fn contrastingTextColor(self: Color) Color {
        return if (self.isLight())
            Color.rgb(0x18, 0x1A, 0x1F)
        else
            Color.rgb(0xEC, 0xEF, 0xF4);
    }
};

pub const ThemeKind = enum(u8) {
    nord = 0,
    catppuccin = 1,
    tokyo_night = 2,
    gruvbox = 3,
    rose_pine = 4,

    pub const default_theme = ThemeKind.nord;
    pub const count: u8 = 5;

    // Backward compatibility aliases
    pub const omarchy = ThemeKind.nord;
    pub const mizu = ThemeKind.nord;
    pub const noctalia = ThemeKind.tokyo_night;
    pub const material_you = ThemeKind.catppuccin;

    pub fn name(self: ThemeKind) []const u8 {
        return switch (self) {
            .nord => "Nord Frost",
            .catppuccin => "Catppuccin Mocha",
            .tokyo_night => "Tokyo Night",
            .gruvbox => "Gruvbox Material",
            .rose_pine => "Rosé Pine",
        };
    }

    pub fn icon(self: ThemeKind) []const u8 {
        return switch (self) {
            .nord => "❄",
            .catppuccin => "󰄛",
            .tokyo_night => "󰛓",
            .gruvbox => "󰚢",
            .rose_pine => "󰐑",
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
        if (std.ascii.eqlIgnoreCase(str, "nord") or
            std.ascii.eqlIgnoreCase(str, "nord frost") or
            std.ascii.eqlIgnoreCase(str, "nord_frost") or
            std.ascii.eqlIgnoreCase(str, "nord-frost") or
            std.ascii.eqlIgnoreCase(str, "frost") or
            std.ascii.eqlIgnoreCase(str, "mizu") or
            std.ascii.eqlIgnoreCase(str, "omarchy") or
            std.ascii.eqlIgnoreCase(str, "default"))
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
        if (std.ascii.eqlIgnoreCase(str, "gruvbox") or
            std.ascii.eqlIgnoreCase(str, "gruvbox material") or
            std.ascii.eqlIgnoreCase(str, "gruvbox_material") or
            std.ascii.eqlIgnoreCase(str, "gruvbox-material"))
        {
            return .gruvbox;
        }
        if (std.ascii.eqlIgnoreCase(str, "rose_pine") or
            std.ascii.eqlIgnoreCase(str, "rose pine") or
            std.ascii.eqlIgnoreCase(str, "rosé pine") or
            std.ascii.eqlIgnoreCase(str, "rosepine") or
            std.ascii.eqlIgnoreCase(str, "rose-pine") or
            std.ascii.eqlIgnoreCase(str, "rose"))
        {
            return .rose_pine;
        }
        return null;
    }

    pub fn toTheme(self: ThemeKind) Theme {
        return switch (self) {
            .nord => nordTheme(),
            .catppuccin => catppuccinTheme(),
            .tokyo_night => tokyoNightTheme(),
            .gruvbox => gruvboxTheme(),
            .rose_pine => rosePineTheme(),
        };
    }
};

pub const Theme = struct {
    kind: ThemeKind = .nord,

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
    omarchy_bg: Color,
    omarchy_fg: Color,
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
    font_size: u32 = 14,
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
        .omarchy_bg = accent,
        .omarchy_fg = accent_fg,
        .cpu_mem_bg = surface,
        .cpu_mem_fg = warn,
        .audio_bg = surface,
        .audio_fg = secondary,
        .battery_bg = surface,
        .battery_fg = succ,
        .clock_bg = surface,
        .clock_fg = text,
        .mpris_playing_bg = accent,
        .mpris_paused_bg = surface,
        .mpris_fg = accent_fg,
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

// 1. Nord Frost (Default)
// Base #2E3440, Surface #3B4252, Elevated #434C5E, Accent #88C0D0, Blue #81A1C1, Text #ECEFF4
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

// 2. Catppuccin Mocha
// Base #1E1E2E, Surface #313244, Accent #CBA6F7, Blue #89B4FA, Text #CDD6F4
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

// 3. Tokyo Night
// Base #1A1B26, Surface #24283B, Accent #7AA2F7, Cyan #7DCFFF, Text #C0CAF5
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

// 4. Gruvbox Material
// Base #282828, Surface #32302F, Elevated #45403D, Accent #A9B665, Orange #E78A4E, Text #D4BE98
pub fn gruvboxTheme() Theme {
    return makeTheme(
        .gruvbox,
        Color.hex(0x282828), // Base
        Color.hex(0x32302F), // Surface
        Color.hex(0x45403D), // Elevated
        Color.hex(0xA9B665), // Accent (Greenish Aqua)
        Color.hex(0x282828), // Accent FG
        Color.hex(0xE78A4E), // Orange / Secondary
        Color.hex(0xD4BE98), // Text
        Color.hex(0xA89984), // Text Muted
        Color.hex(0xEA6962), // Semantic Error (Red)
        Color.hex(0xD8A657), // Semantic Warning (Yellow)
        Color.hex(0xA9B665), // Semantic Success (Green)
    );
}

// 5. Rosé Pine
// Base #191724, Surface #1F1D2E, Elevated #26233A, Accent #C4A7E7, Foam #9CCFD8, Text #E0DEF4
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
pub const omarchyTheme = nordTheme;
pub const noctaliaTheme = tokyoNightTheme;
pub const materialYouTheme = catppuccinTheme;

pub fn saveCurrentTheme(kind: ThemeKind) void {
    const c = @import("c.zig").c;
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

    // Notify any running mizu instances by signaling SIGUSR1
    const pid = c.fork();
    if (pid == 0) {
        _ = c.setsid();
        _ = c.execl("/bin/sh", "sh", "-c", "pkill -USR1 mizu 2>/dev/null || true", @as(?*anyopaque, null));
        c.exit(0);
    }
}

pub fn loadSavedTheme() ?ThemeKind {
    const c = @import("c.zig").c;
    var file_buf: [512]u8 = undefined;
    const home_opt = c.getenv("HOME");
    if (home_opt == null) return null;
    const home = std.mem.span(home_opt.?);

    const file_path = std.fmt.bufPrintZ(&file_buf, "{s}/.cache/mizu/current_theme", .{home}) catch return null;
    const f = c.fopen(file_path.ptr, "rb") orelse return null;
    defer _ = c.fclose(f);

    var buf: [64]u8 = undefined;
    const bytes = c.fread(&buf, 1, buf.len - 1, f);
    if (bytes <= 0) return null;
    buf[bytes] = 0;
    const trimmed = std.mem.trim(u8, buf[0..bytes], " \t\r\n");
    return ThemeKind.fromString(trimmed);
}

test "ThemeKind cycle and parse" {
    try std.testing.expectEqual(ThemeKind.catppuccin, ThemeKind.nord.next());
    try std.testing.expectEqual(ThemeKind.tokyo_night, ThemeKind.catppuccin.next());
    try std.testing.expectEqual(ThemeKind.gruvbox, ThemeKind.tokyo_night.next());
    try std.testing.expectEqual(ThemeKind.rose_pine, ThemeKind.gruvbox.next());
    try std.testing.expectEqual(ThemeKind.nord, ThemeKind.rose_pine.next());

    try std.testing.expectEqual(ThemeKind.nord, ThemeKind.fromString("nord").?);
    try std.testing.expectEqual(ThemeKind.nord, ThemeKind.fromString("nord_frost").?);
    try std.testing.expectEqual(ThemeKind.nord, ThemeKind.fromString("Nord Frost").?);
    try std.testing.expectEqual(ThemeKind.catppuccin, ThemeKind.fromString("catppuccin").?);
    try std.testing.expectEqual(ThemeKind.catppuccin, ThemeKind.fromString("Catppuccin Mocha").?);
    try std.testing.expectEqual(ThemeKind.tokyo_night, ThemeKind.fromString("tokyo_night").?);
    try std.testing.expectEqual(ThemeKind.tokyo_night, ThemeKind.fromString("Tokyo Night").?);
    try std.testing.expectEqual(ThemeKind.gruvbox, ThemeKind.fromString("gruvbox").?);
    try std.testing.expectEqual(ThemeKind.gruvbox, ThemeKind.fromString("Gruvbox Material").?);
    try std.testing.expectEqual(ThemeKind.rose_pine, ThemeKind.fromString("rose_pine").?);
    try std.testing.expectEqual(ThemeKind.rose_pine, ThemeKind.fromString("Rosé Pine").?);

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
