const std = @import("std");
const c = @import("../c.zig").c;
const renderer = @import("../core/renderer.zig");
const config = @import("../core/config.zig");
const icons = @import("../graphics/icons.zig");
const text_input = @import("../core/text_input.zig");
const theme_mod = @import("../core/theme.zig");
const proc_mem = @import("../services/process_memory.zig");

const Color = theme_mod.Color;

pub const SURFACE_W: u32 = 432;
pub const SURFACE_H: u32 = 552;

const PANEL_W: f64 = 420.0;
const PANEL_H: f64 = 540.0;
const INSET: f64 = 6.0;
const PAD: f64 = 16.0;

const FILTER_TOP: f64 = 66.0;
const FILTER_H: f64 = 36.0;
const HEADER_BASELINE: f64 = 119.0;
const LIST_TOP: f64 = 138.0;
const LIST_BOTTOM_PAD: f64 = 12.0;
const ROW_H: f64 = 38.0;

const REFRESH_MS: i64 = 1000;
const POINTER_BUTTON_LEFT: u32 = 272;

const FILTER_TEXT_LEFT: f64 = 38.0;
const FILTER_INNER_RIGHT: f64 = 36.0;

pub const MemoryMonitor = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    family: []const u8,

    width: u32 = SURFACE_W,
    height: u32 = SURFACE_H,

    running: bool = true,
    mem: proc_mem.MemInfo = .{},
    processes: std.ArrayList(proc_mem.ProcessInfo),
    filtered: std.ArrayList(usize),

    filter: text_input.TextInput,
    filter_scroll: f64 = 0.0,
    drag_active: bool = false,

    measure: renderer.Font,
    row_measure: renderer.Font,

    selected: ?usize = null,
    hover: ?usize = null,
    scroll: usize = 0,
    last_refresh_ms: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !MemoryMonitor {
        const family = theme_mod.firstFamily(cfg.theme.font_family);
        var filter = text_input.TextInput.init(allocator, "Filter processes\u{2026}", false);
        filter.focused = true;

        var self = MemoryMonitor{
            .allocator = allocator,
            .cfg = cfg,
            .family = family,
            .processes = std.ArrayList(proc_mem.ProcessInfo).empty,
            .filtered = std.ArrayList(usize).empty,
            .filter = filter,
            .measure = try renderer.Font.init(allocator, family, cfg.typography.ui),
            .row_measure = try renderer.Font.init(allocator, family, cfg.typography.secondary),
        };
        self.refresh();
        self.last_refresh_ms = nowMs();
        return self;
    }

    pub fn deinit(self: *MemoryMonitor) void {
        self.processes.deinit(self.allocator);
        self.filtered.deinit(self.allocator);
        self.filter.deinit();
        self.measure.deinit();
        self.row_measure.deinit();
    }

    pub fn tick(self: *MemoryMonitor) bool {
        var changed = self.checkTheme();
        const now = nowMs();
        if (now - self.last_refresh_ms >= REFRESH_MS) {
            self.last_refresh_ms = now;
            self.refresh();
            changed = true;
        }
        return changed;
    }

    pub fn checkTheme(self: *MemoryMonitor) bool {
        if (theme_mod.loadSavedTheme()) |saved| {
            if (saved != self.cfg.theme.kind) {
                self.cfg.theme = saved.toTheme();
                return true;
            }
        }
        return false;
    }

    pub fn refresh(self: *MemoryMonitor) void {
        const prev_pid = self.selectedPid();
        self.mem = proc_mem.collectMemInfo();
        proc_mem.collectProcesses(self.allocator, &self.processes) catch {};
        self.rebuildFiltered(prev_pid);
    }

    // ---- Input ----------------------------------------------------------

    pub fn handleKey(self: *MemoryMonitor, sym: u32, utf8_bytes: []const u8, ctrl: bool, shift: bool) bool {
        if (sym == c.XKB_KEY_Escape) {
            self.running = false;
            return true;
        }

        if (!ctrl) {
            switch (sym) {
                c.XKB_KEY_Up => return self.moveSelection(-1),
                c.XKB_KEY_Down => return self.moveSelection(1),
                c.XKB_KEY_Page_Up => return self.moveSelection(-@as(isize, @intCast(visibleRows()))),
                c.XKB_KEY_Page_Down => return self.moveSelection(@as(isize, @intCast(visibleRows()))),
                else => {},
            }
        }

        const before = hashText(self.filter.getText());
        const handled = self.filter.handleKey(sym, utf8_bytes, ctrl, shift);
        if (!handled) return false;

        const after = hashText(self.filter.getText());
        if (before != after) {
            self.rebuildFiltered(null);
            self.filter_scroll = 0.0;
            self.ensureFilterCaretVisible();
        }
        return true;
    }

    pub fn handlePointerMotion(self: *MemoryMonitor, x: i32, y: i32) bool {
        var changed = false;

        const new_hover = self.rowIndexAt(x, y);
        if (new_hover != self.hover) {
            self.hover = new_hover;
            changed = true;
        }

        if (self.drag_active and self.pointInFilter(x, y)) {
            const idx = self.cursorIndexFromX(
                self.filter.getText(),
                filterTextX() - self.filter_scroll,
                @as(f64, @floatFromInt(x)),
                self.cfg.typography.ui,
            );
            if (self.filter.selection_anchor == null) self.filter.selection_anchor = self.filter.cursor_idx;
            if (self.filter.cursor_idx != idx) {
                self.filter.cursor_idx = idx;
                changed = true;
            }
            self.ensureFilterCaretVisible();
        }

        return changed;
    }

    pub fn handlePointerLeave(self: *MemoryMonitor) bool {
        var changed = false;
        if (self.hover != null) {
            self.hover = null;
            changed = true;
        }
        if (self.drag_active) {
            self.drag_active = false;
            self.filter.handlePointerUp();
        }
        return changed;
    }

    pub fn handlePointerButton(self: *MemoryMonitor, x: i32, y: i32, button: u32, pressed: bool) bool {
        if (button != POINTER_BUTTON_LEFT) return false;

        if (!pressed) {
            const was_dragging = self.drag_active;
            self.drag_active = false;
            self.filter.handlePointerUp();
            return was_dragging;
        }

        if (self.filter.getText().len > 0 and self.pointInClear(x, y)) {
            self.filter.clear();
            self.rebuildFiltered(null);
            self.filter_scroll = 0.0;
            return true;
        }

        if (self.pointInFilter(x, y)) {
            self.filter.focused = true;
            self.drag_active = true;
            self.filter.cursor_idx = self.cursorIndexFromX(
                self.filter.getText(),
                filterTextX() - self.filter_scroll,
                @as(f64, @floatFromInt(x)),
                self.cfg.typography.ui,
            );
            self.filter.selection_anchor = null;
            self.ensureFilterCaretVisible();
            return true;
        }

        if (self.rowIndexAt(x, y)) |idx| {
            if (self.selected == null or self.selected.? != idx) {
                self.selected = idx;
                return true;
            }
        }
        return false;
    }

    pub fn handlePointerAxis(self: *MemoryMonitor, x: i32, y: i32, delta: i32) bool {
        if (!self.pointInPanel(x, y)) return false;
        const max_scroll = self.maxScroll();
        if (max_scroll == 0) return false;

        if (delta > 0) {
            if (self.scroll >= max_scroll) return false;
            self.scroll = @min(max_scroll, self.scroll + 3);
            return true;
        }
        if (delta < 0) {
            if (self.scroll == 0) return false;
            self.scroll = self.scroll - @min(self.scroll, 3);
            return true;
        }
        return false;
    }

    pub fn isPointer(self: *MemoryMonitor, x: i32, y: i32) bool {
        return self.pointInFilter(x, y) or self.rowIndexAt(x, y) != null;
    }

    pub fn isTextInput(self: *MemoryMonitor, x: i32, y: i32) bool {
        return self.pointInFilter(x, y);
    }

    // ---- Layout ---------------------------------------------------------

    fn panelX() f64 {
        return INSET;
    }

    fn panelY() f64 {
        return INSET;
    }

    fn contentX0() f64 {
        return INSET + PAD;
    }

    fn contentX1() f64 {
        return INSET + PANEL_W - PAD;
    }

    fn listTop() f64 {
        return panelY() + LIST_TOP;
    }

    fn listBottom() f64 {
        return panelY() + PANEL_H - LIST_BOTTOM_PAD;
    }

    fn filterTop() f64 {
        return panelY() + FILTER_TOP;
    }

    fn filterWidth() f64 {
        return contentX1() - contentX0();
    }

    fn filterTextX() f64 {
        return contentX0() + FILTER_TEXT_LEFT;
    }

    fn filterInnerWidth() f64 {
        return filterWidth() - FILTER_TEXT_LEFT - FILTER_INNER_RIGHT;
    }

    fn nameX() f64 {
        return contentX0() + 6.0;
    }

    fn pidRight() f64 {
        return contentX0() + 246.0;
    }

    fn memRight() f64 {
        return contentX1() - 56.0;
    }

    fn pctRight() f64 {
        return contentX1() - 2.0;
    }

    fn nameMaxWidth() f64 {
        return pidRight() - nameX() - 22.0;
    }

    fn visibleRows() usize {
        const avail = listBottom() - listTop();
        if (avail <= 0.0) return 0;
        return @as(usize, @intFromFloat(std.math.floor(avail / ROW_H)));
    }

    // ---- Filtering ------------------------------------------------------

    fn selectedPid(self: *MemoryMonitor) ?u32 {
        const sel = self.selected orelse return null;
        if (sel >= self.filtered.items.len) return null;
        const proc_idx = self.filtered.items[sel];
        if (proc_idx >= self.processes.items.len) return null;
        return self.processes.items[proc_idx].pid;
    }

    fn rebuildFiltered(self: *MemoryMonitor, preserve_pid: ?u32) void {
        const needle = self.filter.getText();
        self.filtered.clearRetainingCapacity();
        for (self.processes.items, 0..) |p, i| {
            if (processMatches(p, needle)) {
                self.filtered.append(self.allocator, i) catch break;
            }
        }

        if (preserve_pid) |pid| {
            var found: ?usize = null;
            for (self.filtered.items, 0..) |proc_idx, fi| {
                if (self.processes.items[proc_idx].pid == pid) {
                    found = fi;
                    break;
                }
            }
            self.selected = found;
        } else {
            self.selected = if (self.filtered.items.len > 0) 0 else null;
        }

        if (self.selected == null and self.filtered.items.len > 0) self.selected = 0;
        self.clampScroll();
        self.ensureSelectedVisible();
    }

    fn clampScroll(self: *MemoryMonitor) void {
        self.scroll = @min(self.scroll, self.maxScroll());
    }

    fn maxScroll(self: *MemoryMonitor) usize {
        const vis = visibleRows();
        if (self.filtered.items.len <= vis) return 0;
        return self.filtered.items.len - vis;
    }

    fn moveSelection(self: *MemoryMonitor, delta: isize) bool {
        const count = self.filtered.items.len;
        if (count == 0) return false;

        var current: isize = if (self.selected) |sel| @as(isize, @intCast(sel)) else 0;
        current += delta;
        if (current < 0) current = 0;
        const last: isize = @as(isize, @intCast(count - 1));
        if (current > last) current = last;

        const next: usize = @as(usize, @intCast(current));
        if (self.selected != null and self.selected.? == next) return false;
        self.selected = next;
        self.ensureSelectedVisible();
        return true;
    }

    fn ensureSelectedVisible(self: *MemoryMonitor) void {
        const sel = self.selected orelse return;
        const vis = visibleRows();
        if (vis == 0) return;

        if (sel < self.scroll) {
            self.scroll = sel;
        } else if (sel >= self.scroll + vis) {
            self.scroll = sel - vis + 1;
        }
        self.clampScroll();
    }

    fn ensureFilterCaretVisible(self: *MemoryMonitor) void {
        const ui_sz = self.cfg.typography.ui;
        const text = self.filter.getText();
        const inner = filterInnerWidth();
        const caret = self.measure.measureTextWithSize(text[0..@min(self.filter.cursor_idx, text.len)], ui_sz);

        if (@as(f64, @floatFromInt(caret)) - self.filter_scroll > inner - 2.0) {
            self.filter_scroll = @as(f64, @floatFromInt(caret)) - inner + 2.0;
        }
        if (@as(f64, @floatFromInt(caret)) - self.filter_scroll < 0.0) {
            self.filter_scroll = @as(f64, @floatFromInt(caret));
        }

        const total = self.measure.measureTextWithSize(text, ui_sz);
        const max_scroll = @max(0.0, @as(f64, @floatFromInt(total)) - inner + 2.0);
        self.filter_scroll = std.math.clamp(self.filter_scroll, 0.0, max_scroll);
    }

    // ---- Hit testing ----------------------------------------------------

    fn rowIndexAt(self: *MemoryMonitor, x: i32, y: i32) ?usize {
        const fx: f64 = @as(f64, @floatFromInt(x));
        const fy: f64 = @as(f64, @floatFromInt(y));
        if (fy < listTop() or fy >= listBottom()) return null;
        if (fx < contentX0() - 8.0 or fx > contentX1() + 8.0) return null;

        const row: usize = @as(usize, @intFromFloat(std.math.floor((fy - listTop()) / ROW_H)));
        const idx = self.scroll + row;
        if (idx >= self.filtered.items.len) return null;
        return idx;
    }

    fn pointInPanel(self: *MemoryMonitor, x: i32, y: i32) bool {
        _ = self;
        const fx: f64 = @as(f64, @floatFromInt(x));
        const fy: f64 = @as(f64, @floatFromInt(y));
        return fx >= panelX() and fx <= panelX() + PANEL_W and fy >= panelY() and fy <= panelY() + PANEL_H;
    }

    fn pointInFilter(self: *MemoryMonitor, x: i32, y: i32) bool {
        _ = self;
        const fx: f64 = @as(f64, @floatFromInt(x));
        const fy: f64 = @as(f64, @floatFromInt(y));
        return fx >= contentX0() and fx <= contentX0() + filterWidth() and fy >= filterTop() and fy <= filterTop() + FILTER_H;
    }

    fn pointInClear(self: *MemoryMonitor, x: i32, y: i32) bool {
        _ = self;
        const fx: f64 = @as(f64, @floatFromInt(x));
        const fy: f64 = @as(f64, @floatFromInt(y));
        const cx = contentX1() - 20.0;
        const cy = filterTop() + FILTER_H / 2.0;
        return (fx - cx) * (fx - cx) + (fy - cy) * (fy - cy) <= 14.0 * 14.0;
    }

    // ---- Rendering ------------------------------------------------------

    fn alphaCol(base: Color, a: f64) Color {
        const aa = @as(u8, @intFromFloat(@as(f64, @floatFromInt(base.a)) * std.math.clamp(a, 0.0, 1.0)));
        return Color.init(aa, base.r, base.g, base.b);
    }

    /// Measure the advance width of `text[0..end]` at `size_px` for caret placement.
    fn measurePrefixWidth(self: *MemoryMonitor, text: []const u8, end: usize, size_px: u32) f64 {
        var total: f64 = 0.0;
        var utf8_view = std.unicode.Utf8View.init(text[0..end]) catch return 0.0;
        var it = utf8_view.iterator();
        while (it.nextCodepoint()) |cp| {
            if (self.measure.getOrLoadGlyph(cp, size_px)) |cg| {
                total += @as(f64, @floatFromInt(cg.advance_x));
            } else {
                total += @as(f64, @floatFromInt(size_px)) / 2.0;
            }
        }
        return total;
    }

    /// Return the byte index closest to `px` within `text` starting at `origin_x`.
    fn cursorIndexFromX(self: *MemoryMonitor, text: []const u8, origin_x: f64, px: f64, size_px: u32) usize {
        if (text.len == 0) return 0;
        const rel = px - origin_x;
        if (rel <= 0.0) return 0;
        var closest: usize = 0;
        var min_dist = std.math.floatMax(f64);
        var idx: usize = 0;
        while (true) {
            const w = self.measure.measureTextWithSize(text[0..idx], size_px);
            const dist = @abs(@as(f64, @floatFromInt(w)) - rel);
            if (dist < min_dist) {
                min_dist = dist;
                closest = idx;
            }
            if (idx >= text.len) break;
            const seq_len = std.unicode.utf8ByteSequenceLength(text[idx]) catch 1;
            idx = @min(idx + seq_len, text.len);
        }
        return closest;
    }

    pub fn render(self: *MemoryMonitor, target: renderer.Renderer, scale: u32) void {
        const px = panelX();
        const py = panelY();
        const th = self.cfg.theme;
        const is_light = th.panel_bg.isLight();
        const overlay = if (is_light) Color.rgb(0, 0, 0) else Color.rgb(255, 255, 255);

        const text_main = th.text_main;
        const text_muted = th.text_muted;
        const accent = th.accent;
        const panel_bg = th.panel_bg;
        const panel_border = th.panel_border;

        target.clear(Color.transparent);

        const shadow_col = Color.init(61, 0, 0, 0);
        target.drawDropShadow(
            @as(i32, @intFromFloat(px)),
            @as(i32, @intFromFloat(py)),
            @as(u32, @intFromFloat(PANEL_W)),
            @as(u32, @intFromFloat(PANEL_H)),
            16,
            @as(u32, @intFromFloat(@as(f64, @floatFromInt(scale)) * 8.0)),
            shadow_col,
        );
        target.fillRoundedRect(
            @as(i32, @intFromFloat(px)),
            @as(i32, @intFromFloat(py)),
            @as(u32, @intFromFloat(PANEL_W)),
            @as(u32, @intFromFloat(PANEL_H)),
            16,
            panel_bg,
        );
        target.drawRoundedBorder(
            @as(i32, @intFromFloat(px)),
            @as(i32, @intFromFloat(py)),
            @as(u32, @intFromFloat(PANEL_W - 1)),
            @as(u32, @intFromFloat(PANEL_H - 1)),
            15,
            1,
            panel_border,
        );

        self.renderHeader(target, text_main, text_muted, accent, overlay, is_light);
        self.renderFilter(target, text_main, text_muted, accent, overlay, is_light);
        self.renderColumns(target, text_muted);
        self.renderList(target, text_main, text_muted, accent, overlay, is_light);
    }

    fn renderHeader(
        self: *MemoryMonitor,
        target: renderer.Renderer,
        text_main: Color,
        text_muted: Color,
        accent: Color,
        overlay: Color,
        is_light: bool,
    ) void {
        const py = panelY();
        const title_sz = self.cfg.typography.title;
        const sec_sz = self.cfg.typography.secondary;

        target.drawTextWithSize(&self.measure, "Memory", @as(i32, @intFromFloat(contentX0())), @as(i32, @intFromFloat(py + 32.0)), title_sz, text_main);

        const used_gib = @as(f64, @floatFromInt(self.mem.used_kb)) / 1048576.0;
        const total_gib = @as(f64, @floatFromInt(self.mem.total_kb)) / 1048576.0;
        const percent = self.mem.used_percent;

        var pct_buf: [32]u8 = undefined;
        const pct_str = std.fmt.bufPrint(&pct_buf, "{d:.0}%", .{percent}) catch "0%";

        var mem_buf: [64]u8 = undefined;
        const mem_str = std.fmt.bufPrint(&mem_buf, "{d:.1} / {d:.1} GB", .{ used_gib, total_gib }) catch "";

        const pct_w = self.measure.measureTextWithSize(pct_str, sec_sz);
        const pct_x = @as(i32, @intFromFloat(contentX1())) - @as(i32, @intCast(pct_w));
        target.drawTextWithSize(&self.measure, pct_str, pct_x, @as(i32, @intFromFloat(py + 31.0)), sec_sz, accent);
        const mem_w = self.measure.measureTextWithSize(mem_str, sec_sz);
        const mem_x = @as(i32, @intFromFloat(contentX1())) - @as(i32, @intCast(pct_w)) - 10 - @as(i32, @intCast(mem_w));
        target.drawTextWithSize(&self.measure, mem_str, mem_x, @as(i32, @intFromFloat(py + 31.0)), sec_sz, text_muted);

        const bar_x = contentX0();
        const bar_y = py + 46.0;
        const bar_w = contentX1() - bar_x;
        const bar_h = 5.0;
        target.fillRoundedRect(
            @as(i32, @intFromFloat(bar_x)),
            @as(i32, @intFromFloat(bar_y)),
            @as(u32, @intFromFloat(bar_w)),
            @as(i32, @intFromFloat(bar_h)),
            @as(u32, @intFromFloat(bar_h / 2.0)),
            alphaCol(overlay, if (is_light) 0.08 else 0.10),
        );

        const fraction = std.math.clamp(percent / 100.0, 0.0, 1.0);
        const fill_w = bar_w * fraction;
        if (fill_w > 0.0) {
            target.fillRoundedRect(
                @as(i32, @intFromFloat(bar_x)),
                @as(i32, @intFromFloat(bar_y)),
                @as(u32, @intFromFloat(@max(fill_w, bar_h))),
                @as(u32, @intFromFloat(bar_h)),
                @as(u32, @intFromFloat(bar_h / 2.0)),
                accent,
            );
        }
    }

    fn renderFilter(
        self: *MemoryMonitor,
        target: renderer.Renderer,
        text_main: Color,
        text_muted: Color,
        accent: Color,
        overlay: Color,
        is_light: bool,
    ) void {
        const fx = contentX0();
        const fy = filterTop();
        const fw = filterWidth();
        const fh = FILTER_H;
        const ui_sz = self.cfg.typography.ui;

        target.fillRoundedRect(
            @as(i32, @intFromFloat(fx)),
            @as(i32, @intFromFloat(fy)),
            @as(u32, @intFromFloat(fw)),
            @as(u32, @intFromFloat(fh)),
            9,
            alphaCol(overlay, if (is_light) 0.05 else 0.07),
        );
        target.drawRoundedBorder(
            @as(i32, @intFromFloat(fx)),
            @as(i32, @intFromFloat(fy)),
            @as(u32, @intFromFloat(fw - 1)),
            @as(i32, @intFromFloat(fh - 1)),
            8,
            1,
            alphaCol(overlay, 0.10),
        );

        const ascent = self.measure.ascender_px;
        const baseline = fy + (fh + @as(f64, @floatFromInt(ascent))) / 2.0 - 0.5;

        target.drawTextWithSize(&self.measure, icons.glyphs.search, @as(i32, @intFromFloat(fx + 12.0)), @as(i32, @intFromFloat(baseline)), ui_sz, text_muted);

        const clip_x = @as(i32, @intFromFloat(fx + FILTER_TEXT_LEFT - 2.0));
        const clip_y = @as(i32, @intFromFloat(fy + 4.0));
        const clip_w = @as(i32, @intFromFloat(fw - FILTER_TEXT_LEFT - FILTER_INNER_RIGHT + 4.0));
        const clip_h = @as(i32, @intFromFloat(fh - 8.0));
        const clipped = target.withClip(renderer.Rect.init(clip_x, clip_y, @intCast(clip_w), @intCast(clip_h)));

        const text_ascent = self.measure.ascender_px;
        const text_height = self.measure.height_px;
        const text_baseline = fy + (fh + @as(f64, @floatFromInt(text_ascent))) / 2.0;
        const text = self.filter.getText();
        const tx = filterTextX() - self.filter_scroll;

        if (text.len == 0) {
            clipped.drawTextWithSize(&self.measure, "Filter processes\u{2026}", @as(i32, @intFromFloat(tx)), @as(i32, @intFromFloat(text_baseline)), ui_sz, alphaCol(text_muted, 0.75));
        } else {
            if (self.filter.selection_anchor) |anchor| {
                if (anchor != self.filter.cursor_idx) {
                    const lo = @min(anchor, self.filter.cursor_idx);
                    const hi = @max(anchor, self.filter.cursor_idx);
                    const x0 = tx + self.measurePrefixWidth(text, lo, ui_sz);
                    const x1 = tx + self.measurePrefixWidth(text, hi, ui_sz);
                    clipped.fillRoundedRect(
                        @as(i32, @intFromFloat(x0)),
                        @as(i32, @intFromFloat(text_baseline - @as(f64, @floatFromInt(text_ascent)) - 1.0)),
                        @as(u32, @intFromFloat(x1 - x0)),
                        @as(u32, @intFromFloat(@as(f64, @floatFromInt(text_height)) + 2.0)),
                        3,
                        alphaCol(accent, 0.30),
                    );
                }
            }
            clipped.drawTextWithSize(&self.measure, text, @as(i32, @intFromFloat(tx)), @as(i32, @intFromFloat(text_baseline)), ui_sz, text_main);
        }

        if (self.filter.focused) {
            const caret_x = tx + self.measurePrefixWidth(text, @min(self.filter.cursor_idx, text.len), ui_sz);
            clipped.fillRoundedRect(
                @as(i32, @intFromFloat(caret_x)),
                @as(i32, @intFromFloat(text_baseline - @as(f64, @floatFromInt(text_ascent)))),
                @as(u32, @intFromFloat(1.5)),
                @as(u32, @intFromFloat(@as(f64, @floatFromInt(text_height)))),
                1,
                accent,
            );
        }

        if (text.len > 0) {
            const cx = contentX1() - 20.0;
            const cy = fy + fh / 2.0;
            icons.drawLine(target, @floatCast(cx - 4.0), @floatCast(cy - 4.0), @floatCast(cx + 4.0), @floatCast(cy + 4.0), @as(f32, 1.4), text_muted);
            icons.drawLine(target, @floatCast(cx + 4.0), @floatCast(cy - 4.0), @floatCast(cx - 4.0), @floatCast(cy + 4.0), @as(f32, 1.4), text_muted);
        }
    }

    fn renderColumns(self: *MemoryMonitor, target: renderer.Renderer, text_muted: Color) void {
        const sec_sz = self.cfg.typography.secondary;
        const baseline = panelY() + HEADER_BASELINE;
        target.drawTextWithSize(&self.measure, "Process", @as(i32, @intFromFloat(nameX())), @as(i32, @intFromFloat(baseline)), sec_sz, text_muted);
        target.drawTextWithSize(&self.measure, "PID", @as(i32, @intFromFloat(pidRight())) - @as(i32, @intCast(self.measure.measureTextWithSize("PID", sec_sz))), @as(i32, @intFromFloat(baseline)), sec_sz, text_muted);
        target.drawTextWithSize(&self.measure, "Memory", @as(i32, @intFromFloat(memRight())) - @as(i32, @intCast(self.measure.measureTextWithSize("Memory", sec_sz))), @as(i32, @intFromFloat(baseline)), sec_sz, text_muted);
        target.drawTextWithSize(&self.measure, "%", @as(i32, @intFromFloat(pctRight())) - @as(i32, @intCast(self.measure.measureTextWithSize("%", sec_sz))), @as(i32, @intFromFloat(baseline)), sec_sz, text_muted);
    }

    fn renderList(
        self: *MemoryMonitor,
        target: renderer.Renderer,
        text_main: Color,
        text_muted: Color,
        accent: Color,
        overlay: Color,
        is_light: bool,
    ) void {
        const top = listTop();
        const bottom = listBottom();
        const width = contentX1() - contentX0();
        const vis = visibleRows();
        const sec_sz = self.cfg.typography.secondary;

        if (self.filtered.items.len == 0) {
            self.renderEmpty(target, text_muted, top, bottom);
            return;
        }

        const clip_x = @as(i32, @intFromFloat(contentX0() - 8.0));
        const clip_y = @as(i32, @intFromFloat(top));
        const clip_w = @as(i32, @intFromFloat(width + 16.0));
        const clip_h = @as(i32, @intFromFloat(bottom - top));
        const clipped = target.withClip(renderer.Rect.init(clip_x, clip_y, @intCast(clip_w), @intCast(clip_h)));

        var i: usize = 0;
        while (i < vis) : (i += 1) {
            const fi = self.scroll + i;
            if (fi >= self.filtered.items.len) break;
            const proc = self.processes.items[self.filtered.items[fi]];
            const row_y = top + @as(f64, @floatFromInt(i)) * ROW_H;
            const is_selected = self.selected != null and self.selected.? == fi;
            const is_hovered = self.hover != null and self.hover.? == fi;

            if (is_selected or is_hovered) {
                const bg = if (is_selected)
                    alphaCol(accent, 0.16)
                else
                    alphaCol(overlay, if (is_light) 0.045 else 0.06);
                clipped.fillRoundedRect(
                    @as(i32, @intFromFloat(contentX0() - 6.0)),
                    @as(i32, @intFromFloat(row_y + 3.0)),
                    @as(u32, @intFromFloat(width + 12.0)),
                    @as(u32, @intFromFloat(ROW_H - 6.0)),
                    7,
                    bg,
                );
                if (is_selected) {
                    clipped.fillRoundedRect(
                        @as(i32, @intFromFloat(contentX0() - 6.0)),
                        @as(i32, @intFromFloat(row_y + 10.0)),
                        3,
                        @as(u32, @intFromFloat(ROW_H - 20.0)),
                        2,
                        accent,
                    );
                }
            }

            const baseline = row_y + (ROW_H + @as(f64, @floatFromInt(self.measure.ascender_px))) / 2.0 - 1.0;

            var name_buf: [160]u8 = undefined;
            const name = renderer.truncateText(&self.row_measure, proc.name[0..proc.name_len], @as(u32, @intFromFloat(nameMaxWidth())), sec_sz, &name_buf);
            clipped.drawTextWithSize(&self.measure, name, @as(i32, @intFromFloat(nameX())), @as(i32, @intFromFloat(baseline)), sec_sz, text_main);

            var pid_buf: [16]u8 = undefined;
            const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{proc.pid}) catch "";
            const pid_w = self.measure.measureTextWithSize(pid_str, sec_sz);
            clipped.drawTextWithSize(&self.measure, pid_str, @as(i32, @intFromFloat(pidRight())) - @as(i32, @intCast(pid_w)), @as(i32, @intFromFloat(baseline)), sec_sz, text_muted);

            var mem_buf: [32]u8 = undefined;
            const mem_str = formatMemory(&mem_buf, proc.rss_kb);
            const mem_w = self.measure.measureTextWithSize(mem_str, sec_sz);
            clipped.drawTextWithSize(&self.measure, mem_str, @as(i32, @intFromFloat(memRight())) - @as(i32, @intCast(mem_w)), @as(i32, @intFromFloat(baseline)), sec_sz, text_main);

            var pct_buf: [24]u8 = undefined;
            const pct = if (self.mem.total_kb > 0)
                @as(f64, @floatFromInt(proc.rss_kb)) * 100.0 / @as(f64, @floatFromInt(self.mem.total_kb))
            else
                0.0;
            const pct_str = std.fmt.bufPrint(&pct_buf, "{d:.1}%", .{pct}) catch "";
            const pct_w = self.measure.measureTextWithSize(pct_str, sec_sz);
            clipped.drawTextWithSize(&self.measure, pct_str, @as(i32, @intFromFloat(pctRight())) - @as(i32, @intCast(pct_w)), @as(i32, @intFromFloat(baseline)), sec_sz, text_muted);
        }

        self.renderScrollbar(target, overlay, top, bottom, vis);
    }

    fn renderScrollbar(self: *MemoryMonitor, target: renderer.Renderer, overlay: Color, top: f64, bottom: f64, vis: usize) void {
        const count = self.filtered.items.len;
        if (count <= vis or vis == 0) return;

        const track_x = panelX() + PANEL_W - 9.0;
        const track_y = top + 2.0;
        const track_h = bottom - top - 4.0;
        if (track_h <= 0.0) return;

        target.fillRoundedRect(
            @as(i32, @intFromFloat(track_x)),
            @as(i32, @intFromFloat(track_y)),
            3,
            @as(u32, @intFromFloat(track_h)),
            2,
            alphaCol(overlay, 0.07),
        );

        const max_scroll = count - vis;
        const ratio = @as(f64, @floatFromInt(vis)) / @as(f64, @floatFromInt(count));
        const thumb_h = @max(24.0, track_h * ratio);
        const t = if (max_scroll > 0)
            @as(f64, @floatFromInt(self.scroll)) / @as(f64, @floatFromInt(max_scroll))
        else
            0.0;
        const thumb_y = track_y + (track_h - thumb_h) * t;

        target.fillRoundedRect(
            @as(i32, @intFromFloat(track_x)),
            @as(i32, @intFromFloat(thumb_y)),
            3,
            @as(u32, @intFromFloat(thumb_h)),
            2,
            alphaCol(overlay, 0.24),
        );
    }

    fn renderEmpty(self: *MemoryMonitor, target: renderer.Renderer, text_muted: Color, top: f64, bottom: f64) void {
        const cx = panelX() + PANEL_W / 2.0;
        const cy = (top + bottom) / 2.0;

        const icon = icons.glyphs.memory;
        const icon_w = self.measure.measureTextWithSize(icon, 28);
        target.drawTextWithSize(&self.measure, icon, @as(i32, @intFromFloat(cx - @as(f64, @floatFromInt(icon_w)) / 2.0)), @as(i32, @intFromFloat(cy - 4.0)), 28, alphaCol(text_muted, 0.45));

        const msg = "No processes match";
        const msg_w = self.measure.measureTextWithSize(msg, 13);
        target.drawTextWithSize(&self.measure, msg, @as(i32, @intFromFloat(cx - @as(f64, @floatFromInt(msg_w)) / 2.0)), @as(i32, @intFromFloat(cy + 28.0)), 13, text_muted);

        const hint = "Try a different filter";
        const hint_w = self.measure.measureTextWithSize(hint, 11);
        target.drawTextWithSize(&self.measure, hint, @as(i32, @intFromFloat(cx - @as(f64, @floatFromInt(hint_w)) / 2.0)), @as(i32, @intFromFloat(cy + 48.0)), 11, alphaCol(text_muted, 0.6));
    }
};

fn processMatches(proc: proc_mem.ProcessInfo, needle: []const u8) bool {
    if (needle.len == 0) return true;

    if (containsIgnoreCase(proc.name[0..proc.name_len], needle)) return true;

    var pid_buf: [16]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{proc.pid}) catch return false;
    return std.mem.indexOf(u8, pid_str, needle) != null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

fn hashText(text: []const u8) u64 {
    return std.hash.Wyhash.hash(0, text);
}

fn formatMemory(buf: []u8, kb: u64) []const u8 {
    const mb = @as(f64, @floatFromInt(kb)) / 1024.0;
    if (mb >= 1024.0) return std.fmt.bufPrint(buf, "{d:.1} GB", .{mb / 1024.0}) catch "";
    if (mb >= 100.0) return std.fmt.bufPrint(buf, "{d:.0} MB", .{mb}) catch "";
    return std.fmt.bufPrint(buf, "{d:.1} MB", .{mb}) catch "";
}

fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(@as(i64, ts.tv_nsec), 1_000_000);
}

test "memory monitor renders to argb buffer" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var mm = try MemoryMonitor.init(allocator, cfg);
    defer mm.deinit();

    const w = mm.width;
    const h = mm.height;
    const pixels = try allocator.alloc(u32, @as(usize, w) * h);
    defer allocator.free(pixels);
    @memset(pixels, 0);

    const ren = try renderer.Renderer.init(pixels.ptr, w, h, w * 4);
    mm.render(ren, 1);

    var nonzero: usize = 0;
    for (pixels) |px| {
        if (px != 0) nonzero += 1;
    }
    try std.testing.expect(nonzero > 0);
}

test "memory monitor filter typing and escape" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var mm = try MemoryMonitor.init(allocator, cfg);
    defer mm.deinit();

    try std.testing.expect(mm.handleKey(0, "x", false, false));
    try std.testing.expectEqualStrings("x", mm.filter.getText());

    try std.testing.expect(mm.handleKey(c.XKB_KEY_BackSpace, "", false, false));
    try std.testing.expectEqualStrings("", mm.filter.getText());

    try std.testing.expect(mm.handleKey(c.XKB_KEY_Escape, "", false, false));
    try std.testing.expect(!mm.running);
}

test "memory monitor filter matching" {
    var proc = proc_mem.ProcessInfo{
        .pid = 4242,
        .name = undefined,
        .name_len = 4,
        .rss_kb = 1024,
    };
    @memcpy(proc.name[0..4], "bash");
    try std.testing.expect(processMatches(proc, "BAS"));
    try std.testing.expect(!processMatches(proc, "zsh"));
}
