const std = @import("std");
const c = @import("c.zig").c;
const theme = @import("theme.zig");
const Color = theme.Color;
const renderer = @import("renderer.zig");
const Font = renderer.Font;
const Renderer = renderer.Renderer;

pub const SelectionRange = struct {
    start: usize,
    end: usize,
};

pub const TextInput = struct {
    allocator: std.mem.Allocator,
    text: std.ArrayList(u8),
    cursor_idx: usize = 0,
    selection_anchor: ?usize = null,
    placeholder: []const u8,
    is_password: bool = false,
    focused: bool = true,
    caret_visible: bool = true,
    drag_active: bool = false,

    pub fn init(allocator: std.mem.Allocator, placeholder: []const u8, is_password: bool) TextInput {
        return .{
            .allocator = allocator,
            .text = std.ArrayList(u8).empty,
            .cursor_idx = 0,
            .selection_anchor = null,
            .placeholder = placeholder,
            .is_password = is_password,
            .focused = true,
            .caret_visible = true,
            .drag_active = false,
        };
    }

    pub fn deinit(self: *TextInput) void {
        self.text.deinit(self.allocator);
    }

    pub fn clear(self: *TextInput) void {
        self.text.clearRetainingCapacity();
        self.cursor_idx = 0;
        self.selection_anchor = null;
        self.caret_visible = true;
    }

    pub fn setText(self: *TextInput, new_text: []const u8) !void {
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(self.allocator, new_text);
        self.cursor_idx = self.text.items.len;
        self.selection_anchor = null;
        self.caret_visible = true;
    }

    pub fn getText(self: *const TextInput) []const u8 {
        return self.text.items;
    }

    pub fn resetCaret(self: *TextInput) void {
        self.caret_visible = true;
    }

    pub fn toggleCaret(self: *TextInput) void {
        self.caret_visible = !self.caret_visible;
    }

    pub fn hasSelection(self: *const TextInput) bool {
        if (self.selection_anchor) |anchor| {
            return anchor != self.cursor_idx;
        }
        return false;
    }

    pub fn getSelectionRange(self: *const TextInput) ?SelectionRange {
        if (self.selection_anchor) |anchor| {
            if (anchor == self.cursor_idx) return null;
            const start = @min(anchor, self.cursor_idx);
            const end = @max(anchor, self.cursor_idx);
            return SelectionRange{ .start = start, .end = end };
        }
        return null;
    }

    pub fn getSelectedText(self: *const TextInput) ?[]const u8 {
        if (self.getSelectionRange()) |range| {
            return self.text.items[range.start..range.end];
        }
        return null;
    }

    pub fn clearSelection(self: *TextInput) void {
        self.selection_anchor = null;
    }

    pub fn selectAll(self: *TextInput) void {
        if (self.text.items.len == 0) return;
        self.selection_anchor = 0;
        self.cursor_idx = self.text.items.len;
        self.caret_visible = true;
    }

    fn removeSelection(self: *TextInput) bool {
        if (self.getSelectionRange()) |range| {
            const count = range.end - range.start;
            var i = range.start;
            while (i + count < self.text.items.len) : (i += 1) {
                self.text.items[i] = self.text.items[i + count];
            }
            self.text.shrinkRetainingCapacity(self.text.items.len - count);
            self.cursor_idx = range.start;
            self.selection_anchor = null;
            return true;
        }
        return false;
    }

    pub fn insertBytes(self: *TextInput, bytes: []const u8) !void {
        _ = self.removeSelection();

        // Ensure cursor is within bounds
        self.cursor_idx = @min(self.cursor_idx, self.text.items.len);

        try self.text.insertSlice(self.allocator, self.cursor_idx, bytes);
        self.cursor_idx += bytes.len;
        self.selection_anchor = null;
        self.caret_visible = true;
    }

    pub fn deleteBackward(self: *TextInput) !void {
        if (self.removeSelection()) {
            self.caret_visible = true;
            return;
        }

        if (self.cursor_idx == 0 or self.text.items.len == 0) return;

        // Find previous UTF-8 codepoint boundary
        var prev_idx = self.cursor_idx - 1;
        while (prev_idx > 0 and (self.text.items[prev_idx] & 0xC0) == 0x80) {
            prev_idx -= 1;
        }

        const count = self.cursor_idx - prev_idx;
        var i = prev_idx;
        while (i + count < self.text.items.len) : (i += 1) {
            self.text.items[i] = self.text.items[i + count];
        }
        self.text.shrinkRetainingCapacity(self.text.items.len - count);
        self.cursor_idx = prev_idx;
        self.caret_visible = true;
    }

    pub fn deleteForward(self: *TextInput) !void {
        if (self.removeSelection()) {
            self.caret_visible = true;
            return;
        }

        if (self.cursor_idx >= self.text.items.len) return;

        // Find next UTF-8 boundary
        var next_idx = self.cursor_idx + 1;
        while (next_idx < self.text.items.len and (self.text.items[next_idx] & 0xC0) == 0x80) {
            next_idx += 1;
        }

        const count = next_idx - self.cursor_idx;
        var i = self.cursor_idx;
        while (i + count < self.text.items.len) : (i += 1) {
            self.text.items[i] = self.text.items[i + count];
        }
        self.text.shrinkRetainingCapacity(self.text.items.len - count);
        self.caret_visible = true;
    }

    pub fn deleteWordBackward(self: *TextInput) !void {
        if (self.removeSelection()) {
            self.caret_visible = true;
            return;
        }
        if (self.cursor_idx == 0) return;

        var i = self.cursor_idx;
        // Skip trailing spaces
        while (i > 0 and self.text.items[i - 1] == ' ') {
            i -= 1;
        }
        // Skip word characters
        while (i > 0 and self.text.items[i - 1] != ' ') {
            i -= 1;
        }

        const count = self.cursor_idx - i;
        var j = i;
        while (j + count < self.text.items.len) : (j += 1) {
            self.text.items[j] = self.text.items[j + count];
        }
        self.text.shrinkRetainingCapacity(self.text.items.len - count);
        self.cursor_idx = i;
        self.caret_visible = true;
    }

    pub fn moveLeft(self: *TextInput, extend_selection: bool) void {
        self.caret_visible = true;
        if (!extend_selection and self.hasSelection()) {
            if (self.getSelectionRange()) |range| {
                self.cursor_idx = range.start;
                self.selection_anchor = null;
                return;
            }
        }

        if (self.cursor_idx > 0) {
            if (extend_selection and self.selection_anchor == null) {
                self.selection_anchor = self.cursor_idx;
            }
            var prev = self.cursor_idx - 1;
            while (prev > 0 and (self.text.items[prev] & 0xC0) == 0x80) {
                prev -= 1;
            }
            self.cursor_idx = prev;
            if (extend_selection and self.selection_anchor.? == self.cursor_idx) {
                self.selection_anchor = null;
            }
        } else if (!extend_selection) {
            self.selection_anchor = null;
        }
    }

    pub fn moveRight(self: *TextInput, extend_selection: bool) void {
        self.caret_visible = true;
        if (!extend_selection and self.hasSelection()) {
            if (self.getSelectionRange()) |range| {
                self.cursor_idx = range.end;
                self.selection_anchor = null;
                return;
            }
        }

        if (self.cursor_idx < self.text.items.len) {
            if (extend_selection and self.selection_anchor == null) {
                self.selection_anchor = self.cursor_idx;
            }
            var next = self.cursor_idx + 1;
            while (next < self.text.items.len and (self.text.items[next] & 0xC0) == 0x80) {
                next += 1;
            }
            self.cursor_idx = next;
            if (extend_selection and self.selection_anchor.? == self.cursor_idx) {
                self.selection_anchor = null;
            }
        } else if (!extend_selection) {
            self.selection_anchor = null;
        }
    }

    pub fn moveHome(self: *TextInput, extend_selection: bool) void {
        self.caret_visible = true;
        if (extend_selection and self.selection_anchor == null) {
            self.selection_anchor = self.cursor_idx;
        } else if (!extend_selection) {
            self.selection_anchor = null;
        }
        self.cursor_idx = 0;
    }

    pub fn moveEnd(self: *TextInput, extend_selection: bool) void {
        self.caret_visible = true;
        if (extend_selection and self.selection_anchor == null) {
            self.selection_anchor = self.cursor_idx;
        } else if (!extend_selection) {
            self.selection_anchor = null;
        }
        self.cursor_idx = self.text.items.len;
    }

    pub fn copyToClipboard(self: *const TextInput) void {
        const sel_text = self.getSelectedText() orelse return;
        if (sel_text.len == 0) return;

        const pid = c.fork();
        if (pid == 0) {
            _ = c.setsid();
            const pipe = c.popen("wl-copy 2>/dev/null", "w");
            if (pipe != null) {
                _ = c.fwrite(sel_text.ptr, 1, sel_text.len, pipe);
                _ = c.pclose(pipe);
            }
            c.exit(0);
        }
    }

    pub fn cutToClipboard(self: *TextInput) void {
        self.copyToClipboard();
        _ = self.removeSelection();
        self.caret_visible = true;
    }

    pub fn pasteFromClipboard(self: *TextInput) void {
        const pipe = c.popen("wl-paste -n 2>/dev/null", "r");
        if (pipe != null) {
            defer _ = c.pclose(pipe);
            var buf: [1024]u8 = undefined;
            const n = c.fread(&buf, 1, buf.len, pipe);
            if (n > 0) {
                // Filter out newlines/carriage returns for single-line inputs
                var clean_buf: [1024]u8 = undefined;
                var clean_len: usize = 0;
                for (buf[0..n]) |b| {
                    if (b != '\n' and b != '\r') {
                        clean_buf[clean_len] = b;
                        clean_len += 1;
                    }
                }
                if (clean_len > 0) {
                    self.insertBytes(clean_buf[0..clean_len]) catch {};
                }
            }
        }
    }

    pub fn findCursorFromX(self: *const TextInput, font: *Font, text_origin_x: i32, px: i32) usize {
        if (self.text.items.len == 0) return 0;
        const rel_x = px - text_origin_x;
        if (rel_x <= 0) return 0;

        if (self.is_password) {
            const bullet = "*";
            const bullet_w = font.measureText(bullet);
            if (bullet_w == 0) return 0;
            const utf8_len = std.unicode.utf8CountCodepoints(self.text.items) catch self.text.items.len;
            const char_idx = @min(utf8_len, @as(usize, @intCast(@divTrunc(rel_x + @as(i32, @intCast(bullet_w / 2)), @as(i32, @intCast(bullet_w))))));
            // Find byte index for char_idx codepoints
            var b_idx: usize = 0;
            var c_count: usize = 0;
            while (b_idx < self.text.items.len and c_count < char_idx) {
                const len = std.unicode.utf8ByteSequenceLength(self.text.items[b_idx]) catch 1;
                b_idx += len;
                c_count += 1;
            }
            return @min(b_idx, self.text.items.len);
        }

        var closest_idx: usize = 0;
        var min_dist: i32 = std.math.maxInt(i32);

        var byte_idx: usize = 0;
        while (byte_idx <= self.text.items.len) {
            const slice = self.text.items[0..byte_idx];
            const w = @as(i32, @intCast(font.measureText(slice)));
            const dist = @abs(w - rel_x);
            if (dist < min_dist) {
                min_dist = @as(i32, @intCast(dist));
                closest_idx = byte_idx;
            }
            if (w > rel_x + 50) break; // Don't check far past target
            if (byte_idx == self.text.items.len) break;
            const seq_len = std.unicode.utf8ByteSequenceLength(self.text.items[byte_idx]) catch 1;
            byte_idx += seq_len;
        }

        return closest_idx;
    }

    pub fn handlePointerDown(self: *TextInput, px: i32, py: i32, field_x: i32, field_y: i32, field_w: u32, field_h: u32, text_origin_x: i32, font: *Font) bool {
        if (px >= field_x and px < field_x + @as(i32, @intCast(field_w)) and
            py >= field_y and py < field_y + @as(i32, @intCast(field_h)))
        {
            self.focused = true;
            self.caret_visible = true;
            self.drag_active = true;
            const new_idx = self.findCursorFromX(font, text_origin_x, px);
            self.cursor_idx = new_idx;
            self.selection_anchor = null;
            return true;
        }
        return false;
    }

    pub fn handlePointerMotion(self: *TextInput, px: i32, text_origin_x: i32, font: *Font) bool {
        if (self.drag_active) {
            const new_idx = self.findCursorFromX(font, text_origin_x, px);
            if (self.selection_anchor == null) {
                self.selection_anchor = self.cursor_idx;
            }
            self.cursor_idx = new_idx;
            self.caret_visible = true;
            return true;
        }
        return false;
    }

    pub fn handlePointerUp(self: *TextInput) void {
        self.drag_active = false;
        if (self.selection_anchor) |anchor| {
            if (anchor == self.cursor_idx) {
                self.selection_anchor = null;
            }
        }
    }

    pub fn handleKey(self: *TextInput, sym: u32, utf8_bytes: []const u8, ctrl: bool, shift: bool) bool {
        self.caret_visible = true;

        if (ctrl) {
            switch (sym) {
                c.XKB_KEY_a, c.XKB_KEY_A => {
                    self.selectAll();
                    return true;
                },
                c.XKB_KEY_c, c.XKB_KEY_C => {
                    self.copyToClipboard();
                    return true;
                },
                c.XKB_KEY_x, c.XKB_KEY_X => {
                    self.cutToClipboard();
                    return true;
                },
                c.XKB_KEY_v, c.XKB_KEY_V => {
                    self.pasteFromClipboard();
                    return true;
                },
                c.XKB_KEY_w, c.XKB_KEY_W, c.XKB_KEY_BackSpace => {
                    self.deleteWordBackward() catch {};
                    return true;
                },
                c.XKB_KEY_u, c.XKB_KEY_U => {
                    // Delete from start to cursor
                    if (self.cursor_idx > 0) {
                        const count = self.cursor_idx;
                        var i: usize = 0;
                        while (i + count < self.text.items.len) : (i += 1) {
                            self.text.items[i] = self.text.items[i + count];
                        }
                        self.text.shrinkRetainingCapacity(self.text.items.len - count);
                        self.cursor_idx = 0;
                        self.selection_anchor = null;
                    }
                    return true;
                },
                c.XKB_KEY_k, c.XKB_KEY_K => {
                    // Delete from cursor to end
                    self.text.shrinkRetainingCapacity(self.cursor_idx);
                    self.selection_anchor = null;
                    return true;
                },
                else => {},
            }
        }

        switch (sym) {
            c.XKB_KEY_BackSpace => {
                self.deleteBackward() catch {};
                return true;
            },
            c.XKB_KEY_Delete => {
                self.deleteForward() catch {};
                return true;
            },
            c.XKB_KEY_Left => {
                self.moveLeft(shift);
                return true;
            },
            c.XKB_KEY_Right => {
                self.moveRight(shift);
                return true;
            },
            c.XKB_KEY_Home => {
                self.moveHome(shift);
                return true;
            },
            c.XKB_KEY_End => {
                self.moveEnd(shift);
                return true;
            },
            else => {
                if (utf8_bytes.len > 0 and utf8_bytes[0] >= 32 and utf8_bytes[0] != 127) {
                    self.insertBytes(utf8_bytes) catch {};
                    return true;
                }
            },
        }

        return false;
    }

    pub fn render(
        self: *TextInput,
        target: Renderer,
        font: *Font,
        field_x: i32,
        field_y: i32,
        field_w: u32,
        field_h: u32,
        text_origin_x: i32,
        text_color: Color,
        placeholder_color: Color,
        accent_color: Color,
    ) void {
        _ = field_x;
        _ = field_w;
        const baseline_y = field_y + @divTrunc(@as(i32, @intCast(field_h)) + font.ascender_px, 2) - 1;

        if (self.text.items.len == 0) {
            // Placeholder text
            target.drawText(font, self.placeholder, text_origin_x, baseline_y, placeholder_color);

            // Caret at origin if focused
            if (self.focused and self.caret_visible) {
                const caret_h: u32 = @as(u32, @intCast(font.height_px));
                const caret_y = baseline_y - font.ascender_px;
                target.fillRect(text_origin_x, caret_y, 2, caret_h, accent_color);
            }
            return;
        }

        // Render masked or plain text
        if (self.is_password) {
            const count = std.unicode.utf8CountCodepoints(self.text.items) catch self.text.items.len;
            var mask_buf: [256]u8 = undefined;
            const mask_len = @min(count, mask_buf.len);
            @memset(mask_buf[0..mask_len], '*');
            const mask_str = mask_buf[0..mask_len];

            // Selection highlight
            if (self.getSelectionRange()) |range| {
                const sel_start_cp = std.unicode.utf8CountCodepoints(self.text.items[0..range.start]) catch range.start;
                const sel_end_cp = std.unicode.utf8CountCodepoints(self.text.items[0..range.end]) catch range.end;

                const star_w = font.measureText("*");
                const sel_x = text_origin_x + @as(i32, @intCast(sel_start_cp * star_w));
                const sel_w = @as(u32, @intCast((sel_end_cp - sel_start_cp) * star_w));
                const sel_y = baseline_y - font.ascender_px - 2;
                const sel_h = @as(u32, @intCast(font.height_px + 4));

                target.fillRoundedRect(sel_x, sel_y, sel_w, sel_h, 4, Color.init(80, accent_color.r, accent_color.g, accent_color.b));
            }

            target.drawText(font, mask_str, text_origin_x, baseline_y, text_color);

            if (self.focused and self.caret_visible) {
                const cur_cp = std.unicode.utf8CountCodepoints(self.text.items[0..self.cursor_idx]) catch self.cursor_idx;
                const star_w = font.measureText("*");
                const caret_x = text_origin_x + @as(i32, @intCast(cur_cp * star_w));
                const caret_y = baseline_y - font.ascender_px;
                const caret_h: u32 = @as(u32, @intCast(font.height_px));
                target.fillRect(caret_x, caret_y, 2, caret_h, accent_color);
            }
        } else {
            // Selection highlight
            if (self.getSelectionRange()) |range| {
                const pre_sel_w = font.measureText(self.text.items[0..range.start]);
                const sel_w = font.measureText(self.text.items[range.start..range.end]);
                const sel_x = text_origin_x + @as(i32, @intCast(pre_sel_w));
                const sel_y = baseline_y - font.ascender_px - 2;
                const sel_h = @as(u32, @intCast(font.height_px + 4));

                target.fillRoundedRect(sel_x, sel_y, sel_w, sel_h, 4, Color.init(80, accent_color.r, accent_color.g, accent_color.b));
            }

            target.drawText(font, self.text.items, text_origin_x, baseline_y, text_color);

            if (self.focused and self.caret_visible) {
                const cur_w = font.measureText(self.text.items[0..self.cursor_idx]);
                const caret_x = text_origin_x + @as(i32, @intCast(cur_w));
                const caret_y = baseline_y - font.ascender_px;
                const caret_h: u32 = @as(u32, @intCast(font.height_px));
                target.fillRect(caret_x, caret_y, 2, caret_h, accent_color);
            }
        }
    }
};

test "TextInput basic operations" {
    const allocator = std.testing.allocator;
    var input = TextInput.init(allocator, "Search...", false);
    defer input.deinit();

    try input.insertBytes("hello");
    try std.testing.expectEqualStrings("hello", input.getText());
    try std.testing.expectEqual(@as(usize, 5), input.cursor_idx);

    input.moveLeft(false);
    try std.testing.expectEqual(@as(usize, 4), input.cursor_idx);

    try input.insertBytes("!");
    try std.testing.expectEqualStrings("hell!o", input.getText());
    try std.testing.expectEqual(@as(usize, 5), input.cursor_idx);

    try input.deleteBackward();
    try std.testing.expectEqualStrings("hello", input.getText());

    input.selectAll();
    try std.testing.expect(input.hasSelection());
    try std.testing.expectEqualStrings("hello", input.getSelectedText().?);

    try input.insertBytes("world");
    try std.testing.expectEqualStrings("world", input.getText());
    try std.testing.expect(!input.hasSelection());
}
