const std = @import("std");
const c = @import("c");
const config = @import("../core/config.zig");
const renderer = @import("../core/renderer.zig");
const theme = @import("../core/theme.zig");
const ui_mod = @import("../core/ui.zig");

pub const Mods = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    fun: bool = false,
};

pub const KeyItem = struct {
    code: u16,
    mods: Mods,
    timestamp_ms: i64,
};

pub const SegmentKind = enum { text };

pub const Segment = struct {
    kind: SegmentKind = .text,
    text: []const u8 = "",
};

pub const max_segments = 6;

pub fn isKeymapsActive() bool {
    const pid_path = "/tmp/mizu-keyoverlay.pid";
    if (c.fopen(pid_path, "rb")) |f| {
        defer _ = c.fclose(f);
        var buf: [32]u8 = undefined;
        const n = c.fread(&buf, 1, buf.len - 1, f);
        if (n > 0) {
            buf[n] = 0;
            const pid_str = std.mem.trim(u8, buf[0..n], " \t\r\n");
            const pid = std.fmt.parseInt(c_int, pid_str, 10) catch return false;
            if (pid > 0 and c.kill(pid, 0) == 0) {
                return true;
            }
        }
    }
    return false;
}

pub const KeyOverlay = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    font: renderer.Font,
    width: u32,
    height: u32,
    font_size: u32,
    running: bool = true,

    input_fds: std.ArrayList(c_int),

    mods: Mods = .{},

    history: std.ArrayList(KeyItem),
    last_event_time: i64 = 0,
    has_active_keys: bool = false,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !KeyOverlay {
        var effective_cfg = cfg;
        if (config.loadSavedKeymapPosition()) |pos| {
            effective_cfg.keymap_position = pos;
        }
        var font_size = effective_cfg.typography.keymap_text;
        if (config.loadSavedKeymapSize()) |sz| {
            font_size = sz;
            effective_cfg.typography.keymap_text = sz;
        }
        const font = try renderer.Font.init(allocator, effective_cfg.theme.font_family, font_size);
        var input_fds = std.ArrayList(c_int).empty;

        const dir = c.opendir("/dev/input");
        if (dir != null) {
            defer _ = c.closedir(dir);
            while (c.readdir(dir)) |entry| {
                const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
                if (!std.mem.startsWith(u8, name, "event")) continue;

                var dev_path_buf: [64]u8 = undefined;
                const dev_path = std.fmt.bufPrintSentinel(&dev_path_buf, "/dev/input/{s}", .{name}, 0) catch continue;

                const fd = c.open(dev_path.ptr, c.O_RDONLY | c.O_NONBLOCK);
                if (fd >= 0) {
                    var ev_bits: [16]u8 = @splat(0);
                    var key_bits: [96]u8 = @splat(0);

                    const EVIOCGBIT_EV: c_ulong = 0x80104520;
                    const EVIOCGBIT_KEY: c_ulong = 0x80604521;

                    _ = c.ioctl(fd, EVIOCGBIT_EV, &ev_bits);
                    _ = c.ioctl(fd, EVIOCGBIT_KEY, &key_bits);

                    const has_ev_key = (ev_bits[0] & 2) != 0;
                    const key_a: usize = 30;
                    const has_key_a = (key_bits[key_a / 8] & (@as(u8, 1) << @as(u3, @intCast(key_a % 8)))) != 0;

                    if (has_ev_key and has_key_a) {
                        try input_fds.append(allocator, fd);
                    } else {
                        _ = c.close(fd);
                    }
                }
            }
        }

        const width: u32 = 920;
        const height: u32 = @max(70, font_size + 56);

        return .{
            .allocator = allocator,
            .cfg = effective_cfg,
            .font = font,
            .width = width,
            .height = height,
            .font_size = font_size,
            .input_fds = input_fds,
            .history = std.ArrayList(KeyItem).empty,
        };
    }

    pub fn deinit(self: *KeyOverlay) void {
        for (self.input_fds.items) |fd| {
            _ = c.close(fd);
        }
        self.input_fds.deinit(self.allocator);
        self.history.deinit(self.allocator);
        self.font.deinit();
    }

    pub fn tick(self: *KeyOverlay) bool {
        var changed = false;
        if (theme.loadSavedTheme()) |saved| {
            if (saved != self.cfg.theme.kind) {
                self.cfg.theme = saved.toTheme();
                changed = true;
            }
        }
        if (config.loadSavedKeymapPosition()) |pos| {
            if (pos != self.cfg.keymap_position) {
                self.cfg.keymap_position = pos;
                changed = true;
            }
        }
        if (config.loadSavedKeymapSize()) |sz| {
            if (sz != self.font_size) {
                self.font_size = sz;
                self.cfg.typography.keymap_text = sz;
                self.height = @max(70, sz + 56);
                self.font.deinit();
                self.font = renderer.Font.init(self.allocator, self.cfg.theme.font_family, sz) catch self.font;
                changed = true;
            }
        }
        return changed;
    }

    fn getNowMs() i64 {
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1000000);
    }

    pub fn handleInput(self: *KeyOverlay, fd: c_int) bool {
        var ev: c.struct_input_event = undefined;
        var changed = false;

        while (true) {
            const bytes = c.read(fd, &ev, @sizeOf(c.struct_input_event));
            if (bytes < @sizeOf(c.struct_input_event)) break;

            if (ev.type != c.EV_KEY) continue;

            const code: u16 = ev.code;
            const val: i32 = ev.value;

            // Track modifier state.
            if (code == 42 or code == 54) {
                self.mods.shift = (val != 0);
                continue;
            } else if (code == 29 or code == 97) {
                self.mods.ctrl = (val != 0);
                continue;
            } else if (code == 56 or code == 100) {
                self.mods.alt = (val != 0);
                continue;
            } else if (code == 125 or code == 126) {
                self.mods.super = (val != 0);
                continue;
            } else if (code == 464) {
                self.mods.fun = (val != 0);
                continue;
            }

            if (val != 1) continue;

            // Ignore unknown keys.
            if (keyText(code, self.mods.shift).len == 0 and keyIcon(code, self.mods.shift) == null) continue;

            const now = getNowMs();
            if (self.history.items.len >= 4) {
                _ = self.history.orderedRemove(0);
            }
            self.history.append(self.allocator, .{
                .code = code,
                .mods = self.mods,
                .timestamp_ms = now,
            }) catch {};

            self.last_event_time = now;
            self.has_active_keys = true;
            changed = true;
        }

        return changed;
    }

    pub fn checkExpiry(self: *KeyOverlay) bool {
        if (!self.has_active_keys) return false;
        const now = getNowMs();
        if (now - self.last_event_time > 1200) {
            self.history.clearRetainingCapacity();
            self.has_active_keys = false;
            return true;
        }
        return false;
    }

    /// Build visual keycap segments (modifiers + main key) for an item.
    pub fn buildSegments(item: KeyItem, out: *[max_segments]Segment) usize {
        var n: usize = 0;

        if (item.mods.super) {
            out[n] = .{ .text = " " };
            n += 1;
        }
        if (item.mods.ctrl) {
            out[n] = .{ .text = "ctrl" };
            n += 1;
        }
        if (item.mods.alt) {
            out[n] = .{ .text = "alt" };
            n += 1;
        }
        if (item.mods.fun) {
            out[n] = .{ .text = "fn" };
            n += 1;
        }
        if (item.mods.shift and !isCharacterKey(item.code)) {
            out[n] = .{ .text = "󰘶" }; // Shift
            n += 1;
        }

        if (keyIcon(item.code, item.mods.shift)) |icon_text| {
            out[n] = .{ .text = icon_text };
            n += 1;
        } else {
            const text = keyText(item.code, item.mods.shift);
            if (text.len > 0) {
                out[n] = .{ .text = text };
                n += 1;
            }
        }

        return n;
    }

    pub fn render(self: *KeyOverlay, target: renderer.Renderer, scale: u32) !void {
        target.clear(theme.Color.transparent);
        if (!self.has_active_keys or self.history.items.len == 0) return;

        const s: i32 = @intCast(scale);
        const font_size: u32 = self.font_size * scale;

        // Logical spacing tokens (Clay will scale with ui.su)
        // Generous spacing for modern, larger keycards
        const box_pad_l: u32 = 8;
        const item_gap_l: u32 = 12;
        const seg_gap_l: u32 = 6;
        const cap_pad_x_l: u32 = 16;

        // Physical spacing tokens for exact target measurements and squircle drawing
        const box_pad: i32 = @as(i32, @intCast(box_pad_l)) * s;
        const item_gap: i32 = @as(i32, @intCast(item_gap_l)) * s;
        const seg_gap: i32 = @as(i32, @intCast(seg_gap_l)) * s;
        const cap_pad_x: i32 = @as(i32, @intCast(cap_pad_x_l)) * s;

        const phys_w: i32 = @intCast(target.width);
        const phys_h: i32 = @intCast(target.height);
        // Larger keycard height
        const cap_h: i32 = @as(i32, @intCast(font_size)) + 24 * s;

        var segs: [4][max_segments]Segment = undefined;
        var seg_counts: [4]usize = @splat(0);
        var width_sets: [4][max_segments]i32 = @splat(@splat(0));
        var item_widths: [4]i32 = @splat(0);

        const count = @min(self.history.items.len, 4);
        var total_content: i32 = 0;
        for (0..count) |i| {
            const item = self.history.items[i];
            seg_counts[i] = buildSegments(item, &segs[i]);
            var item_w: i32 = 0;
            for (0..seg_counts[i]) |j| {
                const seg = segs[i][j];
                const content_w: i32 = @as(i32, @intCast(target.measureTextWithSize(&self.font, seg.text, font_size)));
                // Square minimum width for uniform single-glyph keycaps.
                const min_w = cap_h + 4 * s;
                const w = @max(min_w, content_w + cap_pad_x * 2);
                width_sets[i][j] = w;
                item_w += w;
                if (j + 1 < seg_counts[i]) item_w += seg_gap;
            }
            item_widths[i] = item_w;
            total_content += item_w;
            if (i + 1 < count) total_content += item_gap;
        }

        // Drop oldest entries if overflowing overlay width.
        var first: usize = 0;
        while (first < count and total_content + box_pad * 2 > phys_w) {
            total_content -= item_widths[first];
            if (first + 1 < count) {
                total_content -= item_gap;
            }
            first += 1;
        }
        if (first >= count and count > 0) {
            first = count - 1;
            total_content = @min(item_widths[first], phys_w - box_pad * 2);
        }

        const box_w = @min(phys_w, total_content + box_pad * 2);
        const box_h = phys_h - 6 * s;
        const box_x = @max(0, @divTrunc(phys_w - box_w, 2));
        const box_y: i32 = 3 * s;

        // Flat container transparent — only keycards visible
        const bg_alpha: u8 = 0;
        const bg_color = theme.Color.init(bg_alpha, self.cfg.theme.panel_bg.r, self.cfg.theme.panel_bg.g, self.cfg.theme.panel_bg.b);
        const border_alpha: u8 = 0;
        const border_color = theme.Color.init(border_alpha, self.cfg.theme.panel_border.r, self.cfg.theme.panel_border.g, self.cfg.theme.panel_border.b);

        target.fillSquircle(box_x, box_y, @intCast(@max(1, box_w)), @intCast(@max(1, box_h)), 12 * scale, bg_color);
        target.drawSquircleBorder(box_x, box_y, @intCast(@max(1, box_w)), @intCast(@max(1, box_h)), 12 * scale, @max(1, scale), border_color);

        var ui = try ui_mod.Ui.begin(
            self.allocator,
            &self.font,
            target.width,
            target.height,
            scale,
            -1,
            -1,
            false,
            1.0 / 60.0,
        );
        defer ui.deinit();

        ui.root(.{
            .direction = .row,
            .align_x = .center,
            .align_y = .bottom,
        });

        _ = ui.open(.{
            .width = .{ .fixed = @floatFromInt(@max(1, box_w)) },
            .height = .{ .fixed = @floatFromInt(@max(1, box_h)) },
            .direction = .row,
            .padding = .all(ui.su(box_pad_l)),
            .gap = ui.su(item_gap_l),
            .align_x = .center,
            .align_y = .bottom,
        });

        // Flat keys: clean card background with subtle flat border
        const key_bg = theme.Color.init(220, self.cfg.theme.card_bg.r, self.cfg.theme.card_bg.g, self.cfg.theme.card_bg.b);
        const key_border = theme.Color.init(120, self.cfg.theme.border.r, self.cfg.theme.border.g, self.cfg.theme.border.b);

        for (first..count) |i| {
            _ = ui.open(.{
                .width = .fit,
                .height = .{ .fixed = @floatFromInt(@max(1, cap_h)) },
                .direction = .row,
                .gap = ui.su(seg_gap_l),
                .align_y = .center,
            });
            for (0..seg_counts[i]) |j| {
                const seg = segs[i][j];
                const w = width_sets[i][j];
                _ = ui.open(.{
                    .width = .{ .fixed = @floatFromInt(@max(1, w)) },
                    .height = .{ .fixed = @floatFromInt(@max(1, cap_h)) },
                    .bg = key_bg,
                    .radius = ui.f(8),
                    .border = ui.su(1),
                    .border_color = key_border,
                    .align_x = .center,
                    .align_y = .center,
                });
                ui.text(seg.text, .{
                    .size = font_size,
                    .color = self.cfg.theme.text_bright,
                    .line_height = @intCast(cap_h),
                });
                ui.close();
            }
            ui.close();
        }

        ui.close(); // panel
        ui.close(); // root

        const commands = ui.endLayout();
        ui.render(target, commands);
    }
};

fn isCharacterKey(code: u16) bool {
    return switch (code) {
        2...13, 16...27, 30...53 => true,
        else => false,
    };
}

pub fn keyIcon(code: u16, shift: bool) ?[]const u8 {
    return switch (code) {
        1 => "esc",
        14 => "󰭜 ",
        15 => if (shift) "󰌥 " else "󰌒 ",
        28, 96 => "⏎",
        57 => "󱁐",
        58 => "󰌎",
        99 => " ",
        103 => "",
        105 => "",
        106 => "",
        108 => "",
        111 => "󰹿 ",
        464 => "fn",
        else => null,
    };
}

pub fn keyText(code: u16, shift: bool) []const u8 {
    return switch (code) {
        1 => "esc",
        2 => if (shift) "!" else "1",
        3 => if (shift) "@" else "2",
        4 => if (shift) "#" else "3",
        5 => if (shift) "$" else "4",
        6 => if (shift) "%" else "5",
        7 => if (shift) "^" else "6",
        8 => if (shift) "&" else "7",
        9 => if (shift) "*" else "8",
        10 => if (shift) "(" else "9",
        11 => if (shift) ")" else "0",
        12 => if (shift) "_" else "-",
        13 => if (shift) "+" else "=",
        14 => "󰭜 ",
        15 => if (shift) "󰌥 " else "󰌒 ",
        16 => if (shift) "Q" else "q",
        17 => if (shift) "W" else "w",
        18 => if (shift) "E" else "e",
        19 => if (shift) "R" else "r",
        20 => if (shift) "T" else "t",
        21 => if (shift) "Y" else "y",
        22 => if (shift) "U" else "u",
        23 => if (shift) "I" else "i",
        24 => if (shift) "O" else "o",
        25 => if (shift) "P" else "p",
        26 => if (shift) "{" else "[",
        27 => if (shift) "}" else "]",
        28 => "⏎",
        30 => if (shift) "A" else "a",
        31 => if (shift) "S" else "s",
        32 => if (shift) "D" else "d",
        33 => if (shift) "F" else "f",
        34 => if (shift) "G" else "g",
        35 => if (shift) "H" else "h",
        36 => if (shift) "J" else "j",
        37 => if (shift) "K" else "k",
        38 => if (shift) "L" else "l",
        39 => if (shift) ":" else ";",
        40 => if (shift) "\"" else "'",
        41 => if (shift) "~" else "`",
        43 => if (shift) "|" else "\\",
        44 => if (shift) "Z" else "z",
        45 => if (shift) "X" else "x",
        46 => if (shift) "C" else "c",
        47 => if (shift) "V" else "v",
        48 => if (shift) "B" else "b",
        49 => if (shift) "N" else "n",
        50 => if (shift) "M" else "m",
        51 => if (shift) "<" else ",",
        52 => if (shift) ">" else ".",
        53 => if (shift) "?" else "/",
        55 => "*",
        57 => "󱁐",
        58 => "󰌎",
        59 => "F1",
        60 => "F2",
        61 => "F3",
        62 => "F4",
        63 => "F5",
        64 => "F6",
        65 => "F7",
        66 => "F8",
        67 => "F9",
        68 => "F10",
        69 => "Num",
        70 => "Scroll",
        71 => "7",
        72 => "8",
        73 => "9",
        74 => "-",
        75 => "4",
        76 => "5",
        77 => "6",
        78 => "+",
        79 => "1",
        80 => "2",
        81 => "3",
        82 => "0",
        83 => ".",
        87 => "F11",
        88 => "F12",
        95 => ",",
        96 => "⏎",
        98 => "/",
        99 => " ",
        102 => "Home",
        103 => "",
        104 => "PgUp",
        105 => "",
        106 => "",
        107 => "End",
        108 => "",
        109 => "PgDn",
        110 => "INS",
        111 => "󰹿 ",
        113 => "Mute",
        114 => "VolDown",
        115 => "VolUp",
        119 => "Pause",
        464 => "fn",
        466 => "F1",
        467 => "F2",
        468 => "F3",
        469 => "F4",
        470 => "F5",
        471 => "F6",
        472 => "F7",
        473 => "F8",
        474 => "F9",
        475 => "F10",
        476 => "F11",
        477 => "F12",
        478 => "1",
        479 => "2",
        480 => "D",
        481 => "E",
        482 => "F",
        483 => "S",
        484 => "B",
        else => "",
    };
}

// Tests
test "shift is folded into character keys but kept for named keys" {
    var segs: [max_segments]Segment = undefined;

    const shift_one = KeyItem{ .code = 2, .mods = .{ .shift = true }, .timestamp_ms = 0 };
    const n1 = KeyOverlay.buildSegments(shift_one, &segs);
    try std.testing.expectEqual(@as(usize, 1), n1);
    try std.testing.expectEqual(SegmentKind.text, segs[0].kind);
    try std.testing.expectEqualStrings("!", segs[0].text);

    const shift_tab = KeyItem{ .code = 15, .mods = .{ .shift = true }, .timestamp_ms = 0 };
    const n2 = KeyOverlay.buildSegments(shift_tab, &segs);
    try std.testing.expectEqual(@as(usize, 2), n2);
    try std.testing.expectEqual(SegmentKind.text, segs[0].kind);
    try std.testing.expectEqualStrings("󰘶", segs[0].text);
    try std.testing.expectEqualStrings("󰌥 ", segs[1].text);
}

test "ctrl and alt use text keycap labels" {
    var segs: [max_segments]Segment = undefined;
    const ctrl_c = KeyItem{ .code = 46, .mods = .{ .ctrl = true }, .timestamp_ms = 0 };
    const n = KeyOverlay.buildSegments(ctrl_c, &segs);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("ctrl", segs[0].text);
    try std.testing.expectEqualStrings("c", segs[1].text);
}

test "special keys resolve to nerdfont icons" {
    try std.testing.expectEqualStrings("⏎", keyIcon(28, false).?);
    try std.testing.expectEqualStrings("󰭜 ", keyIcon(14, false).?);
    try std.testing.expectEqualStrings("esc", keyIcon(1, false).?);
    try std.testing.expectEqualStrings("󰌒 ", keyIcon(15, false).?);
    try std.testing.expectEqualStrings("󰌥 ", keyIcon(15, true).?);
    try std.testing.expectEqualStrings("󰌎", keyIcon(58, false).?);
    try std.testing.expectEqualStrings("󰹿 ", keyIcon(111, false).?);
    try std.testing.expectEqualStrings("", keyIcon(103, false).?);
    try std.testing.expectEqualStrings("", keyIcon(108, false).?);
    try std.testing.expectEqualStrings("", keyIcon(105, false).?);
    try std.testing.expectEqualStrings("", keyIcon(106, false).?);
}
