const std = @import("std");
const c = @import("../c.zig").c;
const config = @import("../core/config.zig");
const icons = @import("../graphics/icons.zig");
const renderer = @import("../core/renderer.zig");
const theme = @import("../core/theme.zig");

pub const Mods = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
};

pub const KeyItem = struct {
    code: u16,
    mods: Mods,
    timestamp_ms: i64,
};

pub const SegmentKind = enum { icon, text };

pub const Segment = struct {
    kind: SegmentKind,
    text: []const u8 = "",
    icon: []const u8 = "",
};

pub const max_segments = 6;

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
        const font_size = cfg.typography.keymap_text;
        const font = try renderer.Font.init(allocator, cfg.theme.font_family, font_size);
        var input_fds = std.ArrayList(c_int).empty;

        const dir = c.opendir("/dev/input");
        if (dir != null) {
            defer _ = c.closedir(dir);
            while (c.readdir(dir)) |entry| {
                const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
                if (!std.mem.startsWith(u8, name, "event")) continue;

                var dev_path_buf: [64]u8 = undefined;
                const dev_path = std.fmt.bufPrintZ(&dev_path_buf, "/dev/input/{s}", .{name}) catch continue;

                const fd = c.open(dev_path.ptr, c.O_RDONLY | c.O_NONBLOCK);
                if (fd >= 0) {
                    var ev_bits: [16]u8 = [_]u8{0} ** 16;
                    var key_bits: [96]u8 = [_]u8{0} ** 96;

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

        const width: u32 = 460;
        const height: u32 = @max(44, font_size + 26);

        return .{
            .allocator = allocator,
            .cfg = cfg,
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
        if (theme.loadSavedTheme()) |saved| {
            if (saved != self.cfg.theme.kind) {
                self.cfg.theme = saved.toTheme();
                return true;
            }
        }
        return false;
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

            // Track modifier state. Modifier keys themselves are not added to
            // the history; they are rendered as keycaps alongside the key they
            // modify.
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
            }

            if (val != 1) continue;

            // Ignore keys we cannot describe (unknown keycodes, pure modifier
            // variants, etc.) instead of leaving an empty keycap behind.
            if (keyText(code, self.mods.shift).len == 0 and keyIcon(code) == null) continue;

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

    /// Build the visual segments (modifier keycaps + main key) for one item.
    /// Shift is folded into character keys ("!" instead of shift + "!") and
    /// only shown as a separate keycap for non-character keys ("Shift + Tab").
    pub fn buildSegments(item: KeyItem, out: *[max_segments]Segment) usize {
        var n: usize = 0;

        if (item.mods.super) {
            out[n] = .{ .kind = .text, .text = "Super" };
            n += 1;
        }
        if (item.mods.ctrl) {
            out[n] = .{ .kind = .icon, .icon = "ctrl" };
            n += 1;
        }
        if (item.mods.alt) {
            out[n] = .{ .kind = .icon, .icon = "alt" };
            n += 1;
        }
        if (item.mods.shift and !isCharacterKey(item.code)) {
            out[n] = .{ .kind = .icon, .icon = "shift" };
            n += 1;
        }

        if (keyIcon(item.code)) |name| {
            out[n] = .{ .kind = .icon, .icon = name };
            n += 1;
        } else {
            const text = keyText(item.code, item.mods.shift);
            if (text.len > 0) {
                out[n] = .{ .kind = .text, .text = text };
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
        const font_px: i32 = @intCast(font_size);
        const icon_size: u32 = if (font_size > 2 * scale) font_size - 2 * scale else @max(10, font_size);
        const cap_pad_x: i32 = 7 * s;
        const cap_h: i32 = font_px + 10 * s;
        const seg_gap: i32 = 5 * s;
        const item_gap: i32 = 12 * s;
        const box_pad: i32 = 12 * s;
        const phys_w: i32 = @intCast(target.width);
        const phys_h: i32 = @intCast(target.height);

        var segs: [4][max_segments]Segment = undefined;
        var seg_counts: [4]usize = [_]usize{0} ** 4;
        var width_sets: [4][max_segments]i32 = [_][max_segments]i32{[_]i32{0} ** max_segments} ** 4;
        var item_widths: [4]i32 = [_]i32{0} ** 4;

        const count = @min(self.history.items.len, 4);
        var total_content: i32 = 0;
        for (0..count) |i| {
            const item = self.history.items[i];
            seg_counts[i] = buildSegments(item, &segs[i]);
            var item_w: i32 = 0;
            for (0..seg_counts[i]) |j| {
                const seg = segs[i][j];
                const content_w: i32 = switch (seg.kind) {
                    .icon => @intCast(icon_size),
                    .text => @as(i32, @intCast(target.measureTextWithSize(&self.font, seg.text, font_size))),
                };
                const w = content_w + cap_pad_x * 2;
                width_sets[i][j] = w;
                item_w += w;
                if (j + 1 < seg_counts[i]) item_w += seg_gap;
            }
            item_widths[i] = item_w;
            total_content += item_w;
            if (i + 1 < count) total_content += item_gap;
        }

        // Drop the oldest entries if a large configured font would overflow the
        // overlay surface, so keycaps never spill past the allocated width.
        var first: usize = 0;
        while (first + 1 < count and total_content + box_pad * 2 > phys_w) {
            total_content -= item_widths[first] + item_gap;
            first += 1;
        }

        const box_w = total_content + box_pad * 2;
        const box_h = phys_h - 8 * s;
        const box_x = @divTrunc(phys_w - box_w, 2);
        const box_y: i32 = 4 * s;

        target.fillGlassSquircle(box_x, box_y, @intCast(@max(1, box_w)), @intCast(@max(1, box_h)), 12 * scale, self.cfg.theme.panel_bg);
        target.drawSquircleBorder(box_x, box_y, @intCast(@max(1, box_w)), @intCast(@max(1, box_h)), 12 * scale, @max(1, scale), self.cfg.theme.panel_border);

        const cap_y = box_y + @divTrunc(box_h - cap_h, 2);
        const baseline = cap_y + @divTrunc(cap_h + self.font.ascender_px * s, 2) - 1;

        var cur_x = box_x + box_pad;
        for (first..count) |i| {
            for (0..seg_counts[i]) |j| {
                const seg = segs[i][j];
                const w = width_sets[i][j];
                target.fillSquircle(cur_x, cap_y, @intCast(@max(1, w)), @intCast(@max(1, cap_h)), 6 * scale, self.cfg.theme.elevated);
                target.drawSquircleBorder(cur_x, cap_y, @intCast(@max(1, w)), @intCast(@max(1, cap_h)), 6 * scale, @max(1, scale), self.cfg.theme.border_focused);

                switch (seg.kind) {
                    .icon => {
                        const cx = cur_x + @divTrunc(w, 2);
                        const cy = cap_y + @divTrunc(cap_h, 2);
                        icons.drawSvgIcon(target, self.allocator, seg.icon, icon_size, scale, cx, cy, self.cfg.theme.text_bright);
                    },
                    .text => {
                        const text_w = target.measureTextWithSize(&self.font, seg.text, font_size);
                        const tx = cur_x + @divTrunc(w - @as(i32, @intCast(text_w)), 2);
                        target.drawTextWithSize(&self.font, seg.text, tx, baseline, font_size, self.cfg.theme.text_bright);
                    },
                }

                cur_x += w;
                if (j + 1 < seg_counts[i]) cur_x += seg_gap;
            }
            cur_x += item_gap;
        }
    }
};

fn isCharacterKey(code: u16) bool {
    return switch (code) {
        2...13, 16...27, 30...53 => true,
        else => false,
    };
}

pub fn keyIcon(code: u16) ?[]const u8 {
    return switch (code) {
        1 => "escape",
        14 => "backspace",
        28 => "enter",
        29 => "ctrl",
        42 => "shift",
        54 => "shift",
        56 => "alt",
        58 => "caps-lock",
        96 => "enter",
        97 => "ctrl",
        100 => "alt",
        103 => "up",
        105 => "left",
        106 => "right",
        108 => "down",
        125 => "super",
        126 => "super",
        else => null,
    };
}

pub fn keyText(code: u16, shift: bool) []const u8 {
    return switch (code) {
        1 => "Esc",
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
        14 => "Backspace",
        15 => "Tab",
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
        28 => "Enter",
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
        57 => "Space",
        58 => "Caps",
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
        87 => "F11",
        88 => "F12",
        96 => "Enter",
        98 => "/",
        99 => "PrtSc",
        102 => "Home",
        103 => "Up",
        104 => "PgUp",
        105 => "Left",
        106 => "Right",
        107 => "End",
        108 => "Down",
        109 => "PgDn",
        110 => "Ins",
        111 => "Del",
        119 => "Pause",
        else => "",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

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
    try std.testing.expectEqual(SegmentKind.icon, segs[0].kind);
    try std.testing.expectEqualStrings("shift", segs[0].icon);
    try std.testing.expectEqualStrings("Tab", segs[1].text);
}

test "ctrl and alt use svg keycap assets" {
    var segs: [max_segments]Segment = undefined;
    const ctrl_c = KeyItem{ .code = 46, .mods = .{ .ctrl = true }, .timestamp_ms = 0 };
    const n = KeyOverlay.buildSegments(ctrl_c, &segs);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("ctrl", segs[0].icon);
    try std.testing.expectEqualStrings("c", segs[1].text);
}

test "special keys resolve to svg icons" {
    try std.testing.expectEqualStrings("enter", keyIcon(28).?);
    try std.testing.expectEqualStrings("backspace", keyIcon(14).?);
    try std.testing.expectEqualStrings("escape", keyIcon(1).?);
}
