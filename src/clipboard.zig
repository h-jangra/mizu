const std = @import("std");
const c = @import("c.zig").c;
const renderer = @import("renderer.zig");
const theme = @import("theme.zig");
const Color = theme.Color;
const config = @import("config.zig");
const sys_status = @import("sys_status.zig");
const text_input = @import("text_input.zig");

pub const ClipItem = struct {
    id: u64,
    preview: [160]u8 = [_]u8{0} ** 160,
    preview_len: usize = 0,
};

pub const ClipHitArea = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    action: ClipAction,
};

pub const ClipAction = union(enum) {
    none,
    click_card: usize,
    select_item: usize,
    copy_action: usize,
    delete_item: usize,
    clear_all,
    close,
};

pub const ClipboardPanel = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    font: renderer.Font,

    // Minimal Noctalia-inspired 2-column layout dimensions
    width: u32 = 760,
    height: u32 = 480,
    running: bool = true,

    items: std.ArrayList(ClipItem),
    filtered_indices: std.ArrayList(usize),
    input: text_input.TextInput,

    selected_index: usize = 0,
    scroll_offset: usize = 0,

    pointer_x: i32 = -1,
    pointer_y: i32 = -1,

    hit_areas: std.ArrayList(ClipHitArea),

    // Decoded item cache for instantaneous zero-latency preview
    preview_cache_id: u64 = std.math.maxInt(u64),
    preview_cache_buf: [4096]u8 = [_]u8{0} ** 4096,
    preview_cache_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !ClipboardPanel {
        const font = try renderer.Font.init(allocator, cfg.theme.font_family, cfg.theme.font_size);

        var self = ClipboardPanel{
            .allocator = allocator,
            .cfg = cfg,
            .font = font,
            .items = std.ArrayList(ClipItem).empty,
            .filtered_indices = std.ArrayList(usize).empty,
            .input = text_input.TextInput.init(allocator, "Type to filter...", false),
            .hit_areas = std.ArrayList(ClipHitArea).empty,
        };

        // Focus search input by default so typing works immediately
        self.input.focused = true;

        self.loadHistory();
        self.updateFilter();
        return self;
    }

    pub fn deinit(self: *ClipboardPanel) void {
        self.hit_areas.deinit(self.allocator);
        self.filtered_indices.deinit(self.allocator);
        self.input.deinit();
        self.items.deinit(self.allocator);
        self.font.deinit();
    }

    pub fn tick(self: *ClipboardPanel) void {
        self.input.toggleCaret();
        if (theme.loadSavedTheme()) |saved| {
            if (saved != self.cfg.theme.kind) {
                self.cfg.theme = saved.toTheme();
            }
        }
    }

    pub fn loadHistory(self: *ClipboardPanel) void {
        self.items.clearRetainingCapacity();

        // Read cliphist list with full environment PATH
        const pipe = c.popen("export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; cliphist list 2>/dev/null", "r");
        if (pipe == null) return;
        defer _ = c.pclose(pipe);

        var line_buf: [2048]u8 = undefined;

        while (c.fgets(&line_buf, @intCast(line_buf.len), pipe) != null) {
            const raw_line = std.mem.span(@as([*:0]const u8, @ptrCast(&line_buf)));
            const trimmed = std.mem.trim(u8, raw_line, " \r\n");
            if (trimmed.len == 0) continue;

            // Format: <id>\t<preview>
            var tab_idx: usize = 0;
            while (tab_idx < trimmed.len and trimmed[tab_idx] != '\t') {
                tab_idx += 1;
            }
            if (tab_idx >= trimmed.len) continue;

            const id_str = std.mem.trim(u8, trimmed[0..tab_idx], " ");
            const id = std.fmt.parseInt(u64, id_str, 10) catch continue;

            const content = if (tab_idx + 1 < trimmed.len) std.mem.trim(u8, trimmed[tab_idx + 1 ..], " \t\r\n") else "";
            // Strictly skip empty or pure whitespace entries
            if (content.len == 0) continue;

            var item = ClipItem{ .id = id };
            const copy_len = @min(content.len, item.preview.len);
            @memcpy(item.preview[0..copy_len], content[0..copy_len]);
            item.preview_len = copy_len;

            self.items.append(self.allocator, item) catch break;
            if (self.items.items.len >= 120) break;
        }
    }

    pub fn updateFilter(self: *ClipboardPanel) void {
        self.filtered_indices.clearRetainingCapacity();

        const q = self.input.getText();
        for (self.items.items, 0..) |item, idx| {
            if (q.len == 0) {
                self.filtered_indices.append(self.allocator, idx) catch continue;
            } else {
                const prev = item.preview[0..item.preview_len];
                if (std.ascii.indexOfIgnoreCase(prev, q) != null) {
                    self.filtered_indices.append(self.allocator, idx) catch continue;
                }
            }
        }

        if (self.selected_index >= self.filtered_indices.items.len) {
            self.selected_index = if (self.filtered_indices.items.len > 0) self.filtered_indices.items.len - 1 else 0;
        }
        self.adjustScroll();
    }

    fn adjustScroll(self: *ClipboardPanel) void {
        const visible_rows: usize = 8;
        if (self.selected_index < self.scroll_offset) {
            self.scroll_offset = self.selected_index;
        } else if (self.selected_index >= self.scroll_offset + visible_rows) {
            self.scroll_offset = self.selected_index - visible_rows + 1;
        }
    }

    pub fn copySelection(self: *ClipboardPanel, actual_idx: usize) void {
        if (actual_idx >= self.items.items.len) return;
        const item = self.items.items[actual_idx];

        // Decode directly from cliphist to preserve complete unstripped multi-line content
        var cmd_buf: [256]u8 = undefined;
        const cmd = std.fmt.bufPrintZ(&cmd_buf, "export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin\"; cliphist decode {d} | wl-copy", .{item.id}) catch return;
        sys_status.spawnCmd(cmd);

        self.running = false;
    }

    pub fn deleteSelection(self: *ClipboardPanel, actual_idx: usize) void {
        if (actual_idx >= self.items.items.len) return;
        const item = self.items.items[actual_idx];

        var cmd_buf: [256]u8 = undefined;
        const cmd = std.fmt.bufPrintZ(&cmd_buf, "export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin\"; printf '{d}\\t' | cliphist delete", .{item.id}) catch return;
        sys_status.spawnCmd(cmd);

        if (self.preview_cache_id == item.id) {
            self.preview_cache_id = std.math.maxInt(u64);
            self.preview_cache_len = 0;
        }

        _ = self.items.orderedRemove(actual_idx);
        self.updateFilter();
    }

    pub fn clearAll(self: *ClipboardPanel) void {
        sys_status.spawnCmd("export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin\"; cliphist wipe");
        self.items.clearRetainingCapacity();
        self.preview_cache_id = std.math.maxInt(u64);
        self.preview_cache_len = 0;
        self.updateFilter();
    }

    pub fn getDecodedContent(self: *ClipboardPanel, item: ClipItem) []const u8 {
        if (self.preview_cache_id == item.id and self.preview_cache_len > 0) {
            return self.preview_cache_buf[0..self.preview_cache_len];
        }

        self.preview_cache_id = item.id;
        self.preview_cache_len = 0;

        var cmd_buf: [256]u8 = undefined;
        const cmd = std.fmt.bufPrintZ(&cmd_buf, "export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin\"; cliphist decode {d}", .{item.id}) catch return item.preview[0..item.preview_len];

        const pipe = c.popen(cmd.ptr, "r") orelse return item.preview[0..item.preview_len];
        defer _ = c.pclose(pipe);

        const n = c.fread(&self.preview_cache_buf, 1, self.preview_cache_buf.len - 1, pipe);
        if (n > 0) {
            self.preview_cache_buf[n] = 0;
            self.preview_cache_len = n;
            return self.preview_cache_buf[0..n];
        }

        return item.preview[0..item.preview_len];
    }

    pub fn isAreaHovered(self: *const ClipboardPanel, x: i32, y: i32, w: u32, h: u32) bool {
        if (self.pointer_x < 0 or self.pointer_y < 0) return false;
        return (self.pointer_x >= x and self.pointer_x < x + @as(i32, @intCast(w)) and
            self.pointer_y >= y and self.pointer_y < y + @as(i32, @intCast(h)));
    }

    pub fn handlePointerMotion(self: *ClipboardPanel, x: i32, y: i32) bool {
        self.pointer_x = x;
        self.pointer_y = y;

        if (self.input.drag_active) {
            const pad_x: i32 = 18;
            const text_ox = pad_x + 28;
            _ = self.input.handlePointerMotion(x, text_ox, &self.font);
            return true;
        }

        return true;
    }

    pub fn handlePointerLeave(self: *ClipboardPanel) bool {
        self.pointer_x = -1;
        self.pointer_y = -1;
        return true;
    }

    pub fn handlePointerButton(self: *ClipboardPanel, x: i32, y: i32, button: u32, is_pressed: bool) bool {
        if (button != 272) return false; // BTN_LEFT

        const pad_x: i32 = 18;
        const col1_w: u32 = 310;
        const search_y: i32 = 16 + 28;
        const search_h: u32 = 32;
        const text_ox = pad_x + 28;

        if (is_pressed) {
            if (self.input.handlePointerDown(x, y, pad_x, search_y, col1_w, search_h, text_ox, &self.font)) {
                return true;
            }

            for (self.hit_areas.items) |area| {
                if (x >= area.x and x < area.x + @as(i32, @intCast(area.w)) and
                    y >= area.y and y < area.y + @as(i32, @intCast(area.h)))
                {
                    switch (area.action) {
                        .none => {},
                        .click_card => |filter_idx| {
                            if (self.selected_index == filter_idx) {
                                if (filter_idx < self.filtered_indices.items.len) {
                                    const actual_idx = self.filtered_indices.items[filter_idx];
                                    self.copySelection(actual_idx);
                                }
                            } else {
                                self.selected_index = filter_idx;
                                self.adjustScroll();
                            }
                        },
                        .select_item => |actual_idx| self.copySelection(actual_idx),
                        .copy_action => |actual_idx| self.copySelection(actual_idx),
                        .delete_item => |actual_idx| self.deleteSelection(actual_idx),
                        .clear_all => self.clearAll(),
                        .close => self.running = false,
                    }
                    return true;
                }
            }
        } else {
            self.input.handlePointerUp();
            return true;
        }

        return false;
    }

    pub fn handlePointerAxis(self: *ClipboardPanel, x: i32, y: i32, delta: i32) bool {
        _ = x;
        _ = y;
        const total = self.filtered_indices.items.len;
        if (total == 0) return false;

        const visible_rows: usize = 8;
        const max_scroll = total -| visible_rows;

        if (delta > 0) {
            if (self.scroll_offset < max_scroll) {
                self.scroll_offset += 1;
                if (self.selected_index < self.scroll_offset) {
                    self.selected_index = self.scroll_offset;
                }
                return true;
            } else if (self.selected_index + 1 < total) {
                self.selected_index += 1;
                return true;
            }
        } else if (delta < 0) {
            if (self.scroll_offset > 0) {
                self.scroll_offset -= 1;
                if (self.selected_index >= self.scroll_offset + visible_rows) {
                    self.selected_index = self.scroll_offset + visible_rows - 1;
                }
                return true;
            } else if (self.selected_index > 0) {
                self.selected_index -= 1;
                return true;
            }
        }
        return false;
    }

    pub fn handleKey(self: *ClipboardPanel, sym: u32, utf8_bytes: []const u8, ctrl: bool, shift: bool) bool {
        // Navigation keys
        if (sym == c.XKB_KEY_Escape) {
            self.running = false;
            return true;
        } else if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_KP_Enter) {
            if (self.filtered_indices.items.len > 0 and self.selected_index < self.filtered_indices.items.len) {
                const actual_idx = self.filtered_indices.items[self.selected_index];
                self.copySelection(actual_idx);
            }
            return true;
        } else if (sym == c.XKB_KEY_Up) {
            if (self.selected_index > 0) {
                self.selected_index -= 1;
                self.adjustScroll();
                return true;
            }
        } else if (sym == c.XKB_KEY_Down) {
            if (self.selected_index + 1 < self.filtered_indices.items.len) {
                self.selected_index += 1;
                self.adjustScroll();
                return true;
            }
        } else if (sym == c.XKB_KEY_Left) {
            if (self.input.getText().len == 0 or ctrl) {
                if (self.selected_index > 0) {
                    self.selected_index -= 1;
                    self.adjustScroll();
                }
                return true;
            } else if (self.input.cursor_idx == 0) {
                if (self.selected_index > 0) {
                    self.selected_index -= 1;
                    self.adjustScroll();
                }
                return true;
            }
        } else if (sym == c.XKB_KEY_Right) {
            if (self.input.getText().len == 0 or ctrl) {
                if (self.selected_index + 1 < self.filtered_indices.items.len) {
                    self.selected_index += 1;
                    self.adjustScroll();
                }
                return true;
            } else if (self.input.cursor_idx >= self.input.getText().len) {
                if (self.selected_index + 1 < self.filtered_indices.items.len) {
                    self.selected_index += 1;
                    self.adjustScroll();
                }
                return true;
            }
        } else if (sym == c.XKB_KEY_Page_Up) {
            const jump: usize = @min(self.selected_index, 7);
            self.selected_index -= jump;
            self.adjustScroll();
            return true;
        } else if (sym == c.XKB_KEY_Page_Down) {
            self.selected_index = @min(self.filtered_indices.items.len -| 1, self.selected_index + 7);
            self.adjustScroll();
            return true;
        } else if (sym == c.XKB_KEY_Delete) {
            if (self.filtered_indices.items.len > 0 and self.selected_index < self.filtered_indices.items.len) {
                const actual_idx = self.filtered_indices.items[self.selected_index];
                self.deleteSelection(actual_idx);
                return true;
            }
        }

        // Text input handling
        const prev_len = self.input.getText().len;
        const handled = self.input.handleKey(sym, utf8_bytes, ctrl, shift);
        if (handled) {
            if (self.input.getText().len != prev_len) {
                self.updateFilter();
            }
            return true;
        }

        return false;
    }

    pub fn render(self: *ClipboardPanel, target: renderer.Renderer) !void {
        self.hit_areas.clearRetainingCapacity();

        // 0. Transparent base
        target.clear(theme.Color.transparent);

        const w = target.width;
        const h = target.height;
        const radius: u32 = 14;

        // Container: Clean flat surface with subtle border (Noctalia-style)
        target.fillSquircle(0, 0, w, h, radius, self.cfg.theme.panel_bg);
        target.drawSquircleBorder(0, 0, w, h, radius, 1, self.cfg.theme.panel_border);

        const pad_x: i32 = 18;
        const head_y: i32 = 16;

        // ================= COLUMN 1: List (Left, 310px) =================
        const col1_x: i32 = pad_x;
        const col1_w: u32 = 310;

        // Header: Clean title, count, and minimal clear action
        target.drawTextWithSize(&self.font, "󰅍", col1_x, head_y + 16, 14, self.cfg.theme.accent);
        target.drawTextWithSize(&self.font, "Clipboard", col1_x + 20, head_y + 16, 13, self.cfg.theme.text_bright);

        // Simple count text (restrained, no bulky pill)
        var count_buf: [32]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{self.items.items.len}) catch "";
        target.drawTextWithSize(&self.font, count_str, col1_x + 94, head_y + 16, 11, self.cfg.theme.text_muted);

        // Clear action button: minimal text button
        const clear_w: u32 = 48;
        const clear_h: u32 = 20;
        const clear_x = col1_x + @as(i32, @intCast(col1_w)) - @as(i32, @intCast(clear_w));
        const clear_hover = self.isAreaHovered(clear_x, head_y, clear_w, clear_h);
        if (clear_hover) {
            target.fillSquircle(clear_x, head_y, clear_w, clear_h, 4, self.cfg.theme.elevated);
        }
        const clr_fg = if (clear_hover) self.cfg.theme.error_color else self.cfg.theme.text_muted;
        const clr_text = "Clear";
        const clr_tw = target.measureTextWithSize(&self.font, clr_text, 11);
        const clr_tx = clear_x + @divTrunc(@as(i32, @intCast(clear_w)) - @as(i32, @intCast(clr_tw)), 2);
        target.drawTextWithSize(&self.font, clr_text, clr_tx, head_y + 15, 11, clr_fg);
        try self.hit_areas.append(self.allocator, .{
            .x = clear_x,
            .y = head_y,
            .w = clear_w,
            .h = clear_h,
            .action = .clear_all,
        });

        // Search Input Box (Flat, 32px height)
        const search_y: i32 = head_y + 28;
        const search_h: u32 = 32;
        const is_query_active = self.input.getText().len > 0 or self.input.focused;

        target.fillSquircle(col1_x, search_y, col1_w, search_h, 6, self.cfg.theme.surface);
        const search_border_col = if (is_query_active) self.cfg.theme.accent else self.cfg.theme.border;
        target.drawSquircleBorder(col1_x, search_y, col1_w, search_h, 6, 1, search_border_col);

        const icon_col = if (self.input.focused) self.cfg.theme.accent else self.cfg.theme.text_muted;
        target.drawTextWithSize(&self.font, "󰍉", col1_x + 9, search_y + 21, 12, icon_col);

        const text_ox = col1_x + 28;
        self.input.render(
            target,
            &self.font,
            col1_x,
            search_y,
            col1_w,
            search_h,
            text_ox,
            self.cfg.theme.text_bright,
            self.cfg.theme.text_muted,
            self.cfg.theme.accent,
        );

        // History items list (Clean flat cards, 8 visible rows)
        const list_start_y: i32 = search_y + 38;
        const item_h: u32 = 42;
        const item_gap: u32 = 4;
        const visible_rows: usize = 8;

        const total_filtered = self.filtered_indices.items.len;
        if (total_filtered == 0) {
            const empty_y = list_start_y + 110;
            const empty_msg = if (self.items.items.len == 0) "Clipboard is empty" else "No matching items";
            const em_w = target.measureTextWithSize(&self.font, empty_msg, 12);
            const em_x = col1_x + @divTrunc(@as(i32, @intCast(col1_w)) - @as(i32, @intCast(em_w)), 2);
            target.drawTextWithSize(&self.font, "󰅍", em_x + @divTrunc(@as(i32, @intCast(em_w)), 2) - 9, empty_y - 20, 18, self.cfg.theme.text_muted);
            target.drawTextWithSize(&self.font, empty_msg, em_x, empty_y, 12, self.cfg.theme.text_muted);
        } else {
            var r: usize = 0;
            var cur_y = list_start_y;
            while (r < visible_rows and (self.scroll_offset + r) < total_filtered) : (r += 1) {
                const filter_idx = self.scroll_offset + r;
                const actual_idx = self.filtered_indices.items[filter_idx];
                const item = self.items.items[actual_idx];

                const is_selected = (filter_idx == self.selected_index);
                const is_hovered = self.isAreaHovered(col1_x, cur_y, col1_w, item_h);

                // Card surface & subtle selection / hover styling
                if (is_selected) {
                    // Subtle accent tint background
                    const sel_bg = Color.init(42, self.cfg.theme.accent.r, self.cfg.theme.accent.g, self.cfg.theme.accent.b);
                    target.fillSquircle(col1_x, cur_y, col1_w, item_h, 6, sel_bg);
                    target.drawSquircleBorder(col1_x, cur_y, col1_w, item_h, 6, 1, Color.init(80, self.cfg.theme.accent.r, self.cfg.theme.accent.g, self.cfg.theme.accent.b));

                    // Thin vertical accent indicator on the left edge (Noctalia-style)
                    target.fillSquircle(col1_x + 2, cur_y + 8, 3, item_h - 16, 2, self.cfg.theme.accent);
                } else if (is_hovered) {
                    // Understated hover surface
                    target.fillSquircle(col1_x, cur_y, col1_w, item_h, 6, self.cfg.theme.surface);
                    target.drawSquircleBorder(col1_x, cur_y, col1_w, item_h, 6, 1, self.cfg.theme.border);
                }

                // Item first line text (clean, properly padded)
                const raw_prev = item.preview[0..item.preview_len];
                var clean_buf: [128]u8 = undefined;
                var clean_len: usize = 0;
                for (raw_prev) |b| {
                    if (clean_len >= clean_buf.len) break;
                    if (b == '\n' or b == '\r' or b == '\t') {
                        clean_buf[clean_len] = ' ';
                    } else {
                        clean_buf[clean_len] = b;
                    }
                    clean_len += 1;
                }
                const clean_slice = std.mem.trim(u8, clean_buf[0..clean_len], " ");

                const del_size: u32 = 18;
                const text_start_x = if (is_selected) col1_x + 14 else col1_x + 10;
                const max_txt_w = col1_w - @as(u32, @intCast(text_start_x - col1_x)) - del_size - 10;

                var trunc_buf: [140]u8 = undefined;
                const t_str = truncateStr(target, &self.font, clean_slice, max_txt_w, &trunc_buf);
                const txt_color = if (is_selected) self.cfg.theme.text_bright else self.cfg.theme.text_main;
                target.drawTextWithSize(&self.font, t_str, text_start_x, cur_y + 26, 11, txt_color);

                // Subtle Delete button on the right
                const del_x = col1_x + @as(i32, @intCast(col1_w)) - @as(i32, @intCast(del_size)) - 6;
                const del_y = cur_y + @divTrunc(@as(i32, @intCast(item_h)) - @as(i32, @intCast(del_size)), 2);
                const del_hover = self.isAreaHovered(del_x, del_y, del_size, del_size);
                if (del_hover) {
                    target.fillSquircle(del_x, del_y, del_size, del_size, 3, Color.init(45, self.cfg.theme.error_color.r, self.cfg.theme.error_color.g, self.cfg.theme.error_color.b));
                }
                target.drawTextWithSize(&self.font, "󰆴", del_x + 4, del_y + 13, 10, if (del_hover) self.cfg.theme.error_color else Color.init(100, self.cfg.theme.text_muted.r, self.cfg.theme.text_muted.g, self.cfg.theme.text_muted.b));

                try self.hit_areas.append(self.allocator, .{
                    .x = del_x,
                    .y = del_y,
                    .w = del_size,
                    .h = del_size,
                    .action = .{ .delete_item = actual_idx },
                });

                // Card click hit area: selects or copies
                try self.hit_areas.append(self.allocator, .{
                    .x = col1_x,
                    .y = cur_y,
                    .w = col1_w - del_size - 8,
                    .h = item_h,
                    .action = .{ .click_card = filter_idx },
                });

                cur_y += @as(i32, @intCast(item_h + item_gap));
            }
        }

        // ================= VERTICAL DIVIDER =================
        const sep_x: i32 = col1_x + @as(i32, @intCast(col1_w)) + 12;
        const sep_y: i32 = 16;
        const sep_h: u32 = if (h > 32) h - 32 else h;
        target.fillRect(sep_x, sep_y, 1, sep_h, Color.init(30, self.cfg.theme.border.r, self.cfg.theme.border.g, self.cfg.theme.border.b));

        // ================= COLUMN 2: Minimal Live Preview (Right) =================
        const col2_x: i32 = sep_x + 13;
        const col2_w: u32 = if (w > @as(u32, @intCast(col2_x + pad_x))) w - @as(u32, @intCast(col2_x + pad_x)) else 340;

        const selected_actual: ?usize = if (total_filtered > 0 and self.selected_index < total_filtered)
            self.filtered_indices.items[self.selected_index]
        else
            null;

        try self.renderPreviewColumn(target, col2_x, head_y, col2_w, sep_h, selected_actual);
    }

    fn renderPreviewColumn(
        self: *ClipboardPanel,
        target: renderer.Renderer,
        x: i32,
        y: i32,
        w: u32,
        h: u32,
        selected_actual_idx: ?usize,
    ) !void {
        _ = h;
        // Align card top with search bar (y + 28)
        const card_y = y + 28;
        const card_h: u32 = 364;

        if (selected_actual_idx == null or selected_actual_idx.? >= self.items.items.len) {
            // Flat minimal placeholder
            target.fillSquircle(x, card_y, w, card_h, 8, self.cfg.theme.surface);
            target.drawSquircleBorder(x, card_y, w, card_h, 8, 1, self.cfg.theme.border);

            const ph_icon = "󰅍";
            const ph_msg = "Select an item to preview";
            const icon_w = target.measureTextWithSize(&self.font, ph_icon, 20);
            const msg_w = target.measureTextWithSize(&self.font, ph_msg, 12);

            const center_x = x + @divTrunc(@as(i32, @intCast(w)), 2);
            const center_y = card_y + @divTrunc(@as(i32, @intCast(card_h)), 2);

            target.drawTextWithSize(&self.font, ph_icon, center_x - @divTrunc(@as(i32, @intCast(icon_w)), 2), center_y - 10, 20, self.cfg.theme.text_muted);
            target.drawTextWithSize(&self.font, ph_msg, center_x - @divTrunc(@as(i32, @intCast(msg_w)), 2), center_y + 16, 12, self.cfg.theme.text_muted);
            return;
        }

        const actual_idx = selected_actual_idx.?;
        const item = self.items.items[actual_idx];
        const content = self.getDecodedContent(item);

        // Count lines & characters
        var line_count: usize = 1;
        for (content) |b| {
            if (b == '\n') line_count += 1;
        }
        const char_count = content.len;

        // Preview Header: restrained title & metadata
        target.drawTextWithSize(&self.font, "Preview", x, y + 16, 13, self.cfg.theme.text_bright);

        var meta_buf: [64]u8 = undefined;
        const meta_str = std.fmt.bufPrint(&meta_buf, "{d} chars · {d} lines", .{ char_count, line_count }) catch "";
        const mw = target.measureTextWithSize(&self.font, meta_str, 11);
        const meta_x = x + @as(i32, @intCast(w)) - @as(i32, @intCast(mw));
        target.drawTextWithSize(&self.font, meta_str, meta_x, y + 16, 11, self.cfg.theme.text_muted);

        // Content Card (Flat surface, 8px radius)
        target.fillSquircle(x, card_y, w, card_h, 8, self.cfg.theme.surface);
        target.drawSquircleBorder(x, card_y, w, card_h, 8, 1, self.cfg.theme.border);

        // Check if content is a simple hex color
        const clean_str = std.mem.trim(u8, content, " \t\r\n");
        const is_hex = (clean_str.len == 7 or clean_str.len == 9 or clean_str.len == 4) and clean_str[0] == '#';

        if (is_hex) {
            // Clean minimal color preview
            const parsed_color = theme.Color.fromHex(clean_str);
            const swatch_size: u32 = 48;
            const swatch_x = x + 20;
            const swatch_y = card_y + 24;

            target.fillSquircle(swatch_x, swatch_y, swatch_size, swatch_size, 8, parsed_color);
            target.drawSquircleBorder(swatch_x, swatch_y, swatch_size, swatch_size, 8, 1, self.cfg.theme.border);

            const detail_x = swatch_x + @as(i32, @intCast(swatch_size)) + 16;
            target.drawTextWithSize(&self.font, clean_str, detail_x, swatch_y + 20, 15, self.cfg.theme.text_bright);

            var rgb_buf: [48]u8 = undefined;
            const rgb_str = std.fmt.bufPrint(&rgb_buf, "rgb({d}, {d}, {d})", .{ parsed_color.r, parsed_color.g, parsed_color.b }) catch "";
            target.drawTextWithSize(&self.font, rgb_str, detail_x, swatch_y + 40, 11, self.cfg.theme.text_muted);
        } else {
            // Multi-line text display with comfortable padding and clean line spacing
            const gutter_x = x + 32;
            target.fillRect(gutter_x, card_y + 10, 1, card_h - 20, Color.init(20, self.cfg.theme.border.r, self.cfg.theme.border.g, self.cfg.theme.border.b));

            const max_line_w = w - 48;
            const max_visible_lines: usize = 16;
            const line_step: i32 = 21;
            var line_idx: usize = 0;
            var line_start: usize = 0;
            var cur_line_y: i32 = card_y + 22;

            while (line_start < content.len and line_idx < max_visible_lines) {
                var line_end = line_start;
                while (line_end < content.len and content[line_end] != '\n' and content[line_end] != '\r') {
                    line_end += 1;
                }

                const raw_line = content[line_start..line_end];

                // Muted line number
                var num_buf: [16]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{line_idx + 1}) catch "";
                const nw = target.measureTextWithSize(&self.font, num_str, 10);
                const nx = gutter_x - @as(i32, @intCast(nw)) - 6;
                target.drawTextWithSize(&self.font, num_str, nx, cur_line_y, 10, self.cfg.theme.text_muted);

                // Sanitize tabs
                var clean_buf: [256]u8 = undefined;
                var clen: usize = 0;
                for (raw_line) |ch| {
                    if (clen >= clean_buf.len) break;
                    if (ch == '\t') {
                        const spaces_to_add = @min(4, clean_buf.len - clen);
                        @memset(clean_buf[clen .. clen + spaces_to_add], ' ');
                        clen += spaces_to_add;
                    } else if (ch >= 32 or ch == 0) {
                        clean_buf[clen] = ch;
                        clen += 1;
                    }
                }
                const clean_slice = clean_buf[0..clen];

                var trunc_buf: [260]u8 = undefined;
                const display_line = truncateStr(target, &self.font, clean_slice, max_line_w, &trunc_buf);
                target.drawTextWithSize(&self.font, display_line, gutter_x + 10, cur_line_y, 11, self.cfg.theme.text_bright);

                cur_line_y += line_step;
                line_idx += 1;

                if (line_end < content.len and content[line_end] == '\r') line_end += 1;
                if (line_end < content.len and content[line_end] == '\n') line_end += 1;
                line_start = line_end;
            }

            if (line_start < content.len) {
                var rem_lines: usize = 0;
                var pos = line_start;
                while (pos < content.len) : (pos += 1) {
                    if (content[pos] == '\n') rem_lines += 1;
                }
                if (rem_lines == 0) rem_lines = 1;

                var rem_buf: [64]u8 = undefined;
                const rem_str = std.fmt.bufPrint(&rem_buf, "... and {d} more lines", .{rem_lines}) catch "";
                target.drawTextWithSize(&self.font, rem_str, gutter_x + 10, cur_line_y, 10, self.cfg.theme.text_muted);
            }
        }

        // Action bar below preview (Clean, restrained flat buttons)
        const action_y = card_y + @as(i32, @intCast(card_h)) + 8;
        const btn_h: u32 = 26;

        // Copy button: flat surface, accent on hover
        const copy_w: u32 = 72;
        const copy_hover = self.isAreaHovered(x, action_y, copy_w, btn_h);
        const copy_bg = if (copy_hover) self.cfg.theme.accent else self.cfg.theme.surface;
        const copy_fg = if (copy_hover) self.cfg.theme.accent.contrastingTextColor() else self.cfg.theme.text_bright;

        target.fillSquircle(x, action_y, copy_w, btn_h, 5, copy_bg);
        target.drawSquircleBorder(x, action_y, copy_w, btn_h, 5, 1, if (copy_hover) self.cfg.theme.accent else self.cfg.theme.border);
        const copy_label = "󰆏 Copy";
        const cl_w = target.measureTextWithSize(&self.font, copy_label, 11);
        const cl_x = x + @divTrunc(@as(i32, @intCast(copy_w)) - @as(i32, @intCast(cl_w)), 2);
        target.drawTextWithSize(&self.font, copy_label, cl_x, action_y + 18, 11, copy_fg);

        try self.hit_areas.append(self.allocator, .{
            .x = x,
            .y = action_y,
            .w = copy_w,
            .h = btn_h,
            .action = .{ .copy_action = actual_idx },
        });

        // Delete button: flat surface, error color on hover
        const del_x = x + @as(i32, @intCast(copy_w)) + 6;
        const del_w: u32 = 76;
        const del_hover = self.isAreaHovered(del_x, action_y, del_w, btn_h);
        const del_bg = if (del_hover) self.cfg.theme.error_color else self.cfg.theme.surface;
        const del_fg = if (del_hover) self.cfg.theme.error_color.contrastingTextColor() else self.cfg.theme.text_muted;

        target.fillSquircle(del_x, action_y, del_w, btn_h, 5, del_bg);
        target.drawSquircleBorder(del_x, action_y, del_w, btn_h, 5, 1, if (del_hover) self.cfg.theme.error_color else self.cfg.theme.border);
        const del_label = "󰆴 Delete";
        const dl_w = target.measureTextWithSize(&self.font, del_label, 11);
        const dl_x = del_x + @divTrunc(@as(i32, @intCast(del_w)) - @as(i32, @intCast(dl_w)), 2);
        target.drawTextWithSize(&self.font, del_label, dl_x, action_y + 18, 11, del_fg);

        try self.hit_areas.append(self.allocator, .{
            .x = del_x,
            .y = action_y,
            .w = del_w,
            .h = btn_h,
            .action = .{ .delete_item = actual_idx },
        });

        // Keyboard hint (quiet, right-aligned)
        const hint_str = "[↵] Copy  [Del] Del  [Esc] Close";
        const hw = target.measureTextWithSize(&self.font, hint_str, 10);
        const hint_x = x + @as(i32, @intCast(w)) - @as(i32, @intCast(hw));
        target.drawTextWithSize(&self.font, hint_str, hint_x, action_y + 18, 10, self.cfg.theme.text_muted);
    }

    fn truncateStr(target: renderer.Renderer, font: *renderer.Font, str: []const u8, max_w: u32, buf: []u8) []const u8 {
        if (target.measureTextWithSize(font, str, 11) <= max_w) return str;
        var end = @min(str.len, buf.len - 4);
        while (end > 0) : (end -= 1) {
            @memcpy(buf[0..end], str[0..end]);
            buf[end] = '.';
            buf[end + 1] = '.';
            buf[end + 2] = '.';
            const candidate = buf[0 .. end + 3];
            if (target.measureTextWithSize(font, candidate, 11) <= max_w) {
                return candidate;
            }
        }
        return str[0..@min(str.len, buf.len)];
    }
};

test "ClipboardPanel initialization, 2-column layout and filtering" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var panel = ClipboardPanel{
        .allocator = allocator,
        .cfg = cfg,
        .font = undefined,
        .items = std.ArrayList(ClipItem).empty,
        .filtered_indices = std.ArrayList(usize).empty,
        .input = text_input.TextInput.init(allocator, "Search...", false),
        .hit_areas = std.ArrayList(ClipHitArea).empty,
    };
    defer {
        panel.hit_areas.deinit(allocator);
        panel.filtered_indices.deinit(allocator);
        panel.input.deinit();
        panel.items.deinit(allocator);
    }

    try std.testing.expectEqual(@as(u32, 760), panel.width);
    try std.testing.expectEqual(@as(u32, 480), panel.height);

    var item1 = ClipItem{ .id = 1 };
    const t1 = "https://example.com";
    @memcpy(item1.preview[0..t1.len], t1);
    item1.preview_len = t1.len;
    try panel.items.append(allocator, item1);

    var item2 = ClipItem{ .id = 2 };
    const t2 = "Hello World";
    @memcpy(item2.preview[0..t2.len], t2);
    item2.preview_len = t2.len;
    try panel.items.append(allocator, item2);

    panel.updateFilter();
    try std.testing.expectEqual(@as(usize, 2), panel.filtered_indices.items.len);

    // Search for "hello"
    try panel.input.insertBytes("hel");
    panel.updateFilter();
    try std.testing.expectEqual(@as(usize, 1), panel.filtered_indices.items.len);
    try std.testing.expectEqual(@as(usize, 1), panel.filtered_indices.items[0]);

    // Clear filter
    panel.input.clear();
    panel.updateFilter();
    try std.testing.expectEqual(@as(usize, 2), panel.filtered_indices.items.len);

    // Test Left/Right key navigation
    panel.selected_index = 0;
    _ = panel.handleKey(c.XKB_KEY_Right, "", false, false);
    try std.testing.expectEqual(@as(usize, 1), panel.selected_index);
    _ = panel.handleKey(c.XKB_KEY_Left, "", false, false);
    try std.testing.expectEqual(@as(usize, 0), panel.selected_index);

    // Test Pointer Scroll
    _ = panel.handlePointerAxis(0, 0, 1);
    try std.testing.expectEqual(@as(usize, 1), panel.selected_index);
    _ = panel.handlePointerAxis(0, 0, -1);
    try std.testing.expectEqual(@as(usize, 0), panel.selected_index);
}
