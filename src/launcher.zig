const std = @import("std");
const c = @import("c.zig").c;
const theme = @import("theme.zig");
const config = @import("config.zig");
const renderer = @import("renderer.zig");
const text_input = @import("text_input.zig");
const desktop_entry = @import("desktop_entry.zig");

pub const IconCache = struct {
    allocator: std.mem.Allocator,
    surfaces: std.StringHashMap(?*renderer.Image),

    pub fn init(allocator: std.mem.Allocator) IconCache {
        return .{
            .allocator = allocator,
            .surfaces = std.StringHashMap(?*renderer.Image).init(allocator),
        };
    }

    pub fn deinit(self: *IconCache) void {
        var it = self.surfaces.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*) |surf| {
                surf.deinit();
            }
            self.allocator.free(entry.key_ptr.*);
        }
        self.surfaces.deinit();
    }

    pub fn getIconSurface(self: *IconCache, icon_name: ?[]const u8) ?*renderer.Image {
        const raw_name = icon_name orelse return null;
        if (raw_name.len == 0) return null;

        if (self.surfaces.get(raw_name)) |surf| {
            return surf;
        }

        const surf = self.loadIconSurface(raw_name);
        const dup_key = self.allocator.dupe(u8, raw_name) catch return surf;
        self.surfaces.put(dup_key, surf) catch {
            self.allocator.free(dup_key);
        };
        return surf;
    }

    fn tryLoadFile(allocator: std.mem.Allocator, path: []const u8) ?*renderer.Image {
        return renderer.Image.loadPng(allocator, path) catch null;
    }

    fn loadIconSurface(self: *IconCache, name: []const u8) ?*renderer.Image {
        // 1. Direct path
        if (name[0] == '/') {
            if (tryLoadFile(self.allocator, name)) |s| return s;
            var buf: [512]u8 = undefined;
            if (!std.mem.endsWith(u8, name, ".png")) {
                const with_png = std.fmt.bufPrint(&buf, "{s}.png", .{name}) catch null;
                if (with_png) |p| {
                    if (tryLoadFile(self.allocator, p)) |s| return s;
                }
            }
            return null;
        }

        // 2. Strip extension if given
        var base_name = name;
        if (std.mem.endsWith(u8, base_name, ".png")) {
            base_name = base_name[0 .. base_name.len - 4];
        } else if (std.mem.endsWith(u8, base_name, ".svg")) {
            base_name = base_name[0 .. base_name.len - 4];
        }

        const search_dirs = [_][]const u8{
            "/usr/share/icons/hicolor/48x48/apps",
            "/usr/share/icons/hicolor/64x64/apps",
            "/usr/share/icons/hicolor/128x128/apps",
            "/usr/share/icons/hicolor/32x32/apps",
            "/usr/share/icons/hicolor/256x256/apps",
            "/usr/share/icons/hicolor/scalable/apps",
            "/usr/share/pixmaps",
        };

        var path_buf: [512]u8 = undefined;
        var lower_buf: [128]u8 = undefined;
        const lower_name = if (base_name.len <= lower_buf.len)
            std.ascii.lowerString(&lower_buf, base_name)
        else
            base_name;

        for (search_dirs) |dir| {
            // Try exact case
            if (std.fmt.bufPrint(&path_buf, "{s}/{s}.png", .{ dir, base_name })) |p| {
                if (tryLoadFile(self.allocator, p)) |s| return s;
            } else |_| {}

            // Try lowercase if different
            if (!std.mem.eql(u8, base_name, lower_name)) {
                if (std.fmt.bufPrint(&path_buf, "{s}/{s}.png", .{ dir, lower_name })) |p| {
                    if (tryLoadFile(self.allocator, p)) |s| return s;
                } else |_| {}
            }
        }

        return null;
    }
};

pub const Launcher = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    font: renderer.Font,
    icon_cache: IconCache,
    apps: std.ArrayList(desktop_entry.DesktopApp),
    results: std.ArrayList(desktop_entry.SearchResult),
    input: text_input.TextInput,
    selected_index: usize = 0,
    hover_index: ?usize = null,

    width: u32 = 640,
    height: u32 = 460,

    cols: usize = 5,
    rows: usize = 3,

    running: bool = true,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !Launcher {
        const font = try renderer.Font.init(allocator, cfg.theme.font_family, cfg.theme.font_size);
        const icon_cache = IconCache.init(allocator);

        // Discover and cache all desktop apps
        const apps = try desktop_entry.discoverApplications(allocator);

        var self = Launcher{
            .allocator = allocator,
            .cfg = cfg,
            .font = font,
            .icon_cache = icon_cache,
            .apps = apps,
            .results = std.ArrayList(desktop_entry.SearchResult).empty,
            .input = text_input.TextInput.init(allocator, "Search applications or commands...", false),
        };

        // Populate initial results (all apps)
        try self.updateResults();

        return self;
    }

    pub fn deinit(self: *Launcher) void {
        self.results.deinit(self.allocator);
        self.input.deinit();
        for (self.apps.items) |*app| {
            app.deinit(self.allocator);
        }
        self.apps.deinit(self.allocator);
        self.icon_cache.deinit();
        self.font.deinit();
    }

    pub fn tick(self: *Launcher) void {
        self.input.toggleCaret();
        if (theme.loadSavedTheme()) |saved| {
            if (saved != self.cfg.theme.kind) {
                self.cfg.theme = saved.toTheme();
            }
        }
    }

    fn updateResults(self: *Launcher) !void {
        self.results.deinit(self.allocator);
        self.results = try desktop_entry.searchApplications(
            self.allocator,
            self.apps.items,
            self.input.getText(),
        );
        self.selected_index = 0;
        self.hover_index = null;
    }

    pub fn appendChar(self: *Launcher, ch: u8) !void {
        const slice = [_]u8{ch};
        try self.input.insertBytes(&slice);
        try self.updateResults();
    }

    pub fn appendBytes(self: *Launcher, bytes: []const u8) !void {
        try self.input.insertBytes(bytes);
        try self.updateResults();
    }

    pub fn backspace(self: *Launcher) !void {
        try self.input.deleteBackward();
        try self.updateResults();
    }

    pub fn moveSelection(self: *Launcher, delta: i32) void {
        if (self.results.items.len == 0) return;

        const total = self.results.items.len;
        if (delta > 0) {
            self.selected_index = (self.selected_index + 1) % total;
        } else if (delta < 0) {
            self.selected_index = if (self.selected_index == 0) total - 1 else self.selected_index - 1;
        }
    }

    pub fn moveSelectionVertical(self: *Launcher, delta_rows: i32) void {
        if (self.results.items.len == 0) return;

        const total = self.results.items.len;
        const delta = delta_rows * @as(i32, @intCast(self.cols));
        const cur = @as(i32, @intCast(self.selected_index));
        const new_val = cur + delta;

        if (new_val < 0) {
            const rem = @as(usize, @intCast(@mod(cur, @as(i32, @intCast(self.cols)))));
            const last_row_start = (total / self.cols) * self.cols;
            const target = last_row_start + rem;
            self.selected_index = if (target < total) target else total - 1;
        } else if (new_val >= @as(i32, @intCast(total))) {
            const rem = @as(usize, @intCast(@mod(cur, @as(i32, @intCast(self.cols)))));
            self.selected_index = @min(rem, total - 1);
        } else {
            self.selected_index = @intCast(new_val);
        }
    }

    pub fn moveSelectionPage(self: *Launcher, delta_pages: i32) void {
        if (self.results.items.len == 0) return;

        const page_size = self.cols * self.rows;
        const total = self.results.items.len;
        const delta = delta_pages * @as(i32, @intCast(page_size));
        const cur = @as(i32, @intCast(self.selected_index));
        const new_val = cur + delta;

        if (new_val < 0) {
            self.selected_index = 0;
        } else if (new_val >= @as(i32, @intCast(total))) {
            self.selected_index = total - 1;
        } else {
            self.selected_index = @intCast(new_val);
        }
    }

    pub fn handlePointerAxis(self: *Launcher, x: i32, y: i32, delta: i32) bool {
        _ = x;
        _ = y;
        if (self.results.items.len == 0) return false;

        if (delta > 0) {
            self.moveSelectionPage(1);
            return true;
        } else if (delta < 0) {
            self.moveSelectionPage(-1);
            return true;
        }
        return false;
    }

    pub fn launchApp(self: *Launcher, app: *const desktop_entry.DesktopApp) void {
        const cmd = if (app.terminal)
            std.fmt.allocPrint(self.allocator, "foot -e {s}", .{app.exec}) catch app.exec
        else
            app.exec;

        self.spawnCommand(cmd);
        if (app.terminal and cmd.ptr != app.exec.ptr) {
            self.allocator.free(cmd);
        }
    }

    pub fn launchSelected(self: *Launcher) void {
        if (self.results.items.len > 0 and self.selected_index < self.results.items.len) {
            const app = self.results.items[self.selected_index].app;
            self.launchApp(app);
        } else if (self.input.getText().len > 0) {
            self.spawnCommand(self.input.getText());
        }
    }

    fn spawnCommand(self: *Launcher, cmd: []const u8) void {
        const pid = c.fork();
        if (pid == 0) {
            _ = c.setsid();
            const c_cmd = self.allocator.dupeZ(u8, cmd) catch c.exit(1);
            _ = c.execl("/bin/sh", "sh", "-c", c_cmd.ptr, @as(?*anyopaque, null));
            c.exit(1);
        }
    }

    fn getCardRect(self: *const Launcher, row: usize, col: usize) struct { x: i32, y: i32, w: u32, h: u32 } {
        _ = self;
        const start_x: i32 = 20;
        const start_y: i32 = 76;
        const card_w: u32 = 112;
        const card_h: u32 = 104;
        const gap_x: i32 = 10;
        const gap_y: i32 = 8;

        const x = start_x + @as(i32, @intCast(col)) * @as(i32, @intCast(card_w + @as(u32, @intCast(gap_x))));
        const y = start_y + @as(i32, @intCast(row)) * @as(i32, @intCast(card_h + @as(u32, @intCast(gap_y))));
        return .{ .x = x, .y = y, .w = card_w, .h = card_h };
    }

    fn getPageOffset(self: *const Launcher) usize {
        const page_size = self.cols * self.rows;
        if (self.results.items.len == 0) return 0;
        return (self.selected_index / page_size) * page_size;
    }

    fn getTextOriginX(self: *Launcher) i32 {
        const search_icon = "󰍉 ";
        const icon_w = self.font.measureText(search_icon);
        return 20 + 14 + @as(i32, @intCast(icon_w)) + 4;
    }

    pub fn handlePointerMotion(self: *Launcher, x: i32, y: i32) bool {
        const text_ox = self.getTextOriginX();
        if (self.input.drag_active) {
            _ = self.input.handlePointerMotion(x, text_ox, &self.font);
            return true;
        }

        const old_hover = self.hover_index;
        const page_offset = self.getPageOffset();

        var r: usize = 0;
        while (r < self.rows) : (r += 1) {
            var c_col: usize = 0;
            while (c_col < self.cols) : (c_col += 1) {
                const item_idx = page_offset + r * self.cols + c_col;
                if (item_idx >= self.results.items.len) break;

                const rect = self.getCardRect(r, c_col);
                if (x >= rect.x and x < rect.x + @as(i32, @intCast(rect.w)) and
                    y >= rect.y and y < rect.y + @as(i32, @intCast(rect.h)))
                {
                    self.hover_index = item_idx;
                    return old_hover != self.hover_index;
                }
            }
        }

        self.hover_index = null;
        return old_hover != null;
    }

    pub fn handlePointerButton(self: *Launcher, x: i32, y: i32, button: u32, is_pressed: bool) bool {
        const input_x: i32 = 20;
        const input_y: i32 = 16;
        const input_w: u32 = if (self.width > 40) self.width - 40 else self.width;
        const input_h: u32 = 44;

        if (button == 272) { // BTN_LEFT
            if (is_pressed) {
                const text_ox = self.getTextOriginX();
                if (self.input.handlePointerDown(x, y, input_x, input_y, input_w, input_h, text_ox, &self.font)) {
                    return true;
                }
                return self.handleClick(x, y);
            } else {
                self.input.handlePointerUp();
                return true;
            }
        }
        return false;
    }

    pub fn handleClick(self: *Launcher, x: i32, y: i32) bool {
        const input_x: i32 = 20;
        const input_y: i32 = 16;
        const input_w: u32 = if (self.width > 40) self.width - 40 else self.width;
        const input_h: u32 = 44;

        // If clicking inside the search box, keep launcher open
        if (x >= input_x and x < input_x + @as(i32, @intCast(input_w)) and
            y >= input_y and y < input_y + @as(i32, @intCast(input_h)))
        {
            return true;
        }

        const page_offset = self.getPageOffset();

        var r: usize = 0;
        while (r < self.rows) : (r += 1) {
            var c_col: usize = 0;
            while (c_col < self.cols) : (c_col += 1) {
                const item_idx = page_offset + r * self.cols + c_col;
                if (item_idx >= self.results.items.len) break;

                const rect = self.getCardRect(r, c_col);
                if (x >= rect.x and x < rect.x + @as(i32, @intCast(rect.w)) and
                    y >= rect.y and y < rect.y + @as(i32, @intCast(rect.h)))
                {
                    self.launchApp(self.results.items[item_idx].app);
                    self.running = false;
                    return false;
                }
            }
        }

        // Clicked elsewhere outside cards and search bar: close launcher
        self.running = false;
        return false;
    }

    pub fn handleKey(self: *Launcher, sym: u32, utf8_bytes: []const u8, ctrl: bool, shift: bool) bool {
        // Navigation keys take precedence
        if (sym == c.XKB_KEY_Escape) {
            self.running = false;
            return true;
        } else if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_KP_Enter) {
            self.launchSelected();
            self.running = false;
            return true;
        } else if (sym == c.XKB_KEY_Up) {
            self.moveSelectionVertical(-1);
            return true;
        } else if (sym == c.XKB_KEY_Down) {
            self.moveSelectionVertical(1);
            return true;
        } else if (sym == c.XKB_KEY_Page_Up) {
            self.moveSelectionPage(-1);
            return true;
        } else if (sym == c.XKB_KEY_Page_Down) {
            self.moveSelectionPage(1);
            return true;
        } else if (sym == c.XKB_KEY_Tab) {
            self.moveSelection(1);
            return true;
        } else if (sym == c.XKB_KEY_ISO_Left_Tab) {
            self.moveSelection(-1);
            return true;
        } else if (sym == c.XKB_KEY_Left) {
            if (self.input.getText().len == 0 or ctrl) {
                self.moveSelection(-1);
                return true;
            } else if (self.input.cursor_idx == 0) {
                self.moveSelection(-1);
                return true;
            }
        } else if (sym == c.XKB_KEY_Right) {
            if (self.input.getText().len == 0 or ctrl) {
                self.moveSelection(1);
                return true;
            } else if (self.input.cursor_idx >= self.input.getText().len) {
                self.moveSelection(1);
                return true;
            }
        }

        // Text input handling
        const prev_len = self.input.getText().len;
        const handled = self.input.handleKey(sym, utf8_bytes, ctrl, shift);
        if (handled) {
            if (self.input.getText().len != prev_len) {
                self.updateResults() catch {};
            }
            return true;
        }

        return false;
    }

    fn getAppToneColor(t: theme.Theme, name: []const u8) theme.Color {
        var h: u32 = 5381;
        for (name) |byte| {
            h = ((h << 5) +% h) +% byte;
        }
        const tones = [_]theme.Color{
            t.surface,
            t.elevated,
            t.secondary,
            theme.Color.init(180, t.accent.r, t.accent.g, t.accent.b),
            theme.Color.rgb(0x3B, 0x52, 0x49), // Sage green container
            theme.Color.rgb(0x56, 0x43, 0x36), // Warm terracotta container
            theme.Color.rgb(0x36, 0x48, 0x5C), // Slate indigo container
        };
        return tones[h % tones.len];
    }

    fn truncateText(target: renderer.Renderer, font: *renderer.Font, text: []const u8, max_w: u32, buf: []u8) []const u8 {
        const text_w = target.measureText(font, text);
        if (text_w <= max_w) return text;

        const ellipsis = "...";
        const ell_w = target.measureText(font, ellipsis);
        if (ell_w >= max_w) return "";

        var best_len: usize = 0;
        var utf8_view = std.unicode.Utf8View.init(text) catch return text;
        var it = utf8_view.iterator();
        while (it.nextCodepointSlice()) |slice| {
            const candidate_len = best_len + slice.len;
            if (candidate_len + ellipsis.len > buf.len) break;
            @memcpy(buf[0..candidate_len], text[0..candidate_len]);
            @memcpy(buf[candidate_len .. candidate_len + ellipsis.len], ellipsis);
            const w = target.measureText(font, buf[0 .. candidate_len + ellipsis.len]);
            if (w > max_w) break;
            best_len = candidate_len;
        }

        if (best_len == 0) return "";
        @memcpy(buf[0..best_len], text[0..best_len]);
        @memcpy(buf[best_len .. best_len + ellipsis.len], ellipsis);
        return buf[0 .. best_len + ellipsis.len];
    }

    pub fn render(self: *Launcher, target: renderer.Renderer) !void {
        // Clear transparent outer border
        target.clear(theme.Color.transparent);

        const w = target.width;
        const h = target.height;

        // Container card: Glass surface container with smooth 16px squircle radius
        target.fillGlassSquircle(0, 0, w, h, 16, self.cfg.theme.card_bg);
        target.drawSquircleBorder(0, 0, w, h, 16, 1, self.cfg.theme.panel_border);

        // Search Input Box (Pill)
        const input_x: i32 = 20;
        const input_y: i32 = 16;
        const input_w: u32 = w - 40;
        const input_h: u32 = 44;

        if (self.input.focused) {
            target.drawSoftShadow(input_x, input_y + 1, input_w, input_h, 14, 3, 25);
        }
        target.fillSquircle(input_x, input_y, input_w, input_h, 14, self.cfg.theme.pill_bg);
        const search_border = if (self.input.focused or self.input.getText().len > 0) self.cfg.theme.accent else self.cfg.theme.pill_border;
        target.drawSquircleBorder(input_x, input_y, input_w, input_h, 14, 1, search_border);

        const baseline_y = input_y + @divTrunc(@as(i32, @intCast(input_h)) + self.font.ascender_px, 2) - 1;

        // Search Icon
        const search_icon = "󰍉 ";
        target.drawText(&self.font, search_icon, input_x + 14, baseline_y, self.cfg.theme.accent);
        const icon_w = target.measureText(&self.font, search_icon);
        const text_x = input_x + 14 + @as(i32, @intCast(icon_w)) + 4;

        // Render full TextInput (handles text, selection highlight, caret, placeholder)
        self.input.render(
            target,
            &self.font,
            input_x,
            input_y,
            input_w,
            input_h,
            text_x,
            self.cfg.theme.text_bright,
            self.cfg.theme.text_muted,
            self.cfg.theme.accent,
        );

        // ESC badge on right of search input
        const esc_w: u32 = 36;
        const esc_h: u32 = 22;
        const esc_x = input_x + @as(i32, @intCast(input_w)) - @as(i32, @intCast(esc_w)) - 10;
        const esc_y = input_y + @divTrunc(@as(i32, @intCast(input_h)) - @as(i32, @intCast(esc_h)), 2);
        target.fillSquircle(esc_x, esc_y, esc_w, esc_h, 6, self.cfg.theme.elevated);
        target.drawSquircleBorder(esc_x, esc_y, esc_w, esc_h, 6, 1, self.cfg.theme.border);
        const esc_tw = target.measureTextWithSize(&self.font, "ESC", 10);
        const esc_tx = esc_x + @divTrunc(@as(i32, @intCast(esc_w)) - @as(i32, @intCast(esc_tw)), 2);
        target.drawTextWithSize(&self.font, "ESC", esc_tx, esc_y + 15, 10, self.cfg.theme.text_muted);

        // Empty state
        if (self.results.items.len == 0) {
            const no_match_str = if (self.input.getText().len > 0)
                "Press Enter to execute shell command"
            else
                "No applications found";
            const no_match_w = target.measureText(&self.font, no_match_str);
            const center_x = @divTrunc(@as(i32, @intCast(w)) - @as(i32, @intCast(no_match_w)), 2);
            target.drawTextWithSize(&self.font, "󰋽", center_x + @divTrunc(@as(i32, @intCast(no_match_w)), 2) - 10, 200, 24, self.cfg.theme.text_muted);
            target.drawText(&self.font, no_match_str, center_x, 230, self.cfg.theme.text_muted);
            return;
        }

        // App Grid
        const page_offset = self.getPageOffset();
        const page_size = self.cols * self.rows;

        var r: usize = 0;
        while (r < self.rows) : (r += 1) {
            var c_col: usize = 0;
            while (c_col < self.cols) : (c_col += 1) {
                const item_idx = page_offset + r * self.cols + c_col;
                if (item_idx >= self.results.items.len) break;

                const res = self.results.items[item_idx];
                const app = res.app;
                const rect = self.getCardRect(r, c_col);

                const is_selected = (item_idx == self.selected_index);
                const is_hovered = (self.hover_index != null and item_idx == self.hover_index.?);

                // Card background
                if (is_selected) {
                    target.drawSoftShadow(rect.x, rect.y + 1, rect.w, rect.h, 12, 4, 30);
                    target.fillGlassSquircle(rect.x, rect.y, rect.w, rect.h, 12, self.cfg.theme.card_selected_bg);
                    target.drawSquircleBorder(rect.x, rect.y, rect.w, rect.h, 12, 1, self.cfg.theme.accent);
                } else if (is_hovered) {
                    target.fillSquircle(rect.x, rect.y, rect.w, rect.h, 12, self.cfg.theme.card_hover_bg);
                    target.drawSquircleBorder(rect.x, rect.y, rect.w, rect.h, 12, 1, self.cfg.theme.border);
                }

                // Render App Icon
                const icon_size: u32 = 48;
                const icon_x = rect.x + @divTrunc(@as(i32, @intCast(rect.w)) - @as(i32, @intCast(icon_size)), 2);
                const icon_y = rect.y + 12;

                const icon_surf = self.icon_cache.getIconSurface(app.icon);
                if (icon_surf) |surf| {
                    target.drawImage(
                        surf,
                        @as(f64, @floatFromInt(icon_x)),
                        @as(f64, @floatFromInt(icon_y)),
                        @as(f64, @floatFromInt(icon_size)),
                        @as(f64, @floatFromInt(icon_size)),
                    );
                } else {
                    // Fallback Noctalia-style adaptive icon badge
                    const badge_color = getAppToneColor(self.cfg.theme, app.name);
                    target.fillGlassSquircle(icon_x, icon_y, icon_size, icon_size, 14, badge_color);
                    target.drawSquircleBorder(icon_x, icon_y, icon_size, icon_size, 14, 1, self.cfg.theme.border);

                    // Initial letter
                    var letter_buf: [4]u8 = undefined;
                    var letter_str: []const u8 = "?";
                    var it = (std.unicode.Utf8View.init(app.name) catch null);
                    if (it) |*utf8_view| {
                        var cp_it = utf8_view.iterator();
                        while (cp_it.nextCodepoint()) |cp| {
                            if (cp > 32) {
                                const upper = std.ascii.toUpper(@as(u8, @truncate(cp)));
                                letter_buf[0] = upper;
                                letter_str = letter_buf[0..1];
                                break;
                            }
                        }
                    }

                    const badge_font_size: u32 = 20;
                    const letter_w = target.measureTextWithSize(&self.font, letter_str, badge_font_size);
                    const letter_x = icon_x + @divTrunc(@as(i32, @intCast(icon_size)) - @as(i32, @intCast(letter_w)), 2);
                    const letter_y = icon_y + @divTrunc(@as(i32, @intCast(icon_size)) + @as(i32, @intCast(badge_font_size)), 2) - 3;
                    target.drawTextWithSize(
                        &self.font,
                        letter_str,
                        letter_x,
                        letter_y,
                        badge_font_size,
                        self.cfg.theme.text_bright,
                    );
                }

                // Render App Name (Centered, Truncated)
                var trunc_buf: [128]u8 = undefined;
                const label = truncateText(target, &self.font, app.name, rect.w - 8, &trunc_buf);
                const label_w = target.measureText(&self.font, label);
                const label_x = rect.x + @divTrunc(@as(i32, @intCast(rect.w)) - @as(i32, @intCast(label_w)), 2);
                const label_y = rect.y + 82;

                const text_color = if (is_selected)
                    self.cfg.theme.card_selected_fg
                else if (is_hovered)
                    self.cfg.theme.text_bright
                else
                    self.cfg.theme.text_main;

                target.drawText(&self.font, label, label_x, label_y, text_color);
            }
        }

        // Footer / Status Bar (Noctalia-style minimal shortcut bar)
        const footer_y: i32 = @as(i32, @intCast(h)) - 22;
        const total = self.results.items.len;
        const current_page = (self.selected_index / page_size) + 1;
        const total_pages = (total + page_size - 1) / page_size;

        // Selected app description on the left
        if (self.results.items.len > 0 and self.selected_index < self.results.items.len) {
            const sel_app = self.results.items[self.selected_index].app;
            const desc = sel_app.generic_name orelse (sel_app.comment orelse sel_app.exec);
            var desc_trunc_buf: [128]u8 = undefined;
            const desc_label = truncateText(target, &self.font, desc, 260, &desc_trunc_buf);
            target.drawTextWithSize(&self.font, desc_label, 20, footer_y, 11, self.cfg.theme.text_muted);
        }

        // Page dots indicator in center if multiple pages
        if (total_pages > 1) {
            const dot_spacing: i32 = 12;
            const dots_total_w = @as(i32, @intCast(total_pages - 1)) * dot_spacing;
            var dot_x = @divTrunc(@as(i32, @intCast(w)) - dots_total_w, 2);
            var p: usize = 1;
            while (p <= total_pages) : (p += 1) {
                const is_active_p = (p == current_page);
                const dot_color = if (is_active_p) self.cfg.theme.accent else self.cfg.theme.border;
                const dot_r: f64 = if (is_active_p) 3.5 else 2.5;
                target.fillCircle(@as(f64, @floatFromInt(dot_x)), @as(f64, @floatFromInt(footer_y - 4)), dot_r, dot_color);
                dot_x += dot_spacing;
            }
        }
    }
};

test "Launcher navigation and scroll" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var app_dummy = desktop_entry.DesktopApp{
        .name = "Test App",
        .exec = "testapp",
    };

    var launcher = Launcher{
        .allocator = allocator,
        .cfg = cfg,
        .font = undefined,
        .apps = std.ArrayList(desktop_entry.DesktopApp).empty,
        .results = std.ArrayList(desktop_entry.SearchResult).empty,
        .input = text_input.TextInput.init(allocator, "Search...", false),
        .icons = std.StringHashMap(?*renderer.Image).init(allocator),
    };
    defer {
        launcher.icons.deinit();
        launcher.input.deinit();
        launcher.results.deinit(allocator);
        launcher.apps.deinit(allocator);
    }

    try launcher.results.append(allocator, .{ .app = &app_dummy, .score = 100 });
    try launcher.results.append(allocator, .{ .app = &app_dummy, .score = 90 });
    try launcher.results.append(allocator, .{ .app = &app_dummy, .score = 80 });

    // Test Left / Right keys
    launcher.selected_index = 0;
    _ = launcher.handleKey(c.XKB_KEY_Right, "", false, false);
    try std.testing.expectEqual(@as(usize, 1), launcher.selected_index);
    _ = launcher.handleKey(c.XKB_KEY_Left, "", false, false);
    try std.testing.expectEqual(@as(usize, 0), launcher.selected_index);

    // Test scroll
    _ = launcher.handlePointerAxis(0, 0, 1);
    try std.testing.expect(launcher.selected_index <= 2);
}
