const std = @import("std");
const c = @import("../c.zig").c;
const renderer = @import("../core/renderer.zig");
const theme = @import("../core/theme.zig");
const config = @import("../core/config.zig");
const animation = @import("../core/animation.zig");
const icons = @import("../graphics/icons.zig");
const sys_status = @import("../services/system_status.zig");
const ui_mod = @import("../core/ui.zig");

/// Shared layout tokens used by Calendar and Quick Settings panels.
/// All values are logical pixels; callers multiply by `scale`.
pub const Layout = struct {
    pub const pad: u32 = 16;
    pub const section_gap: u32 = 12;
    pub const row_h: u32 = 44;
    pub const row_gap: u32 = 8;
    pub const icon_sz: u32 = 20;
    pub const row_icon_sz: u32 = 24;
    pub const ctrl_h: u32 = 36;
    pub const radius: u32 = 10;
    pub const border_w: u32 = 1;
};

pub const CalendarAction = union(enum) {
    none,
    prev_month,
    next_month,
    prev_year,
    next_year,
    jump_today,
    toggle_dnd,
    close,
    select_date: struct {
        year: u32,
        month: u32,
        day: u32,
    },
};

pub const CalendarHitArea = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    action: CalendarAction,
};

const PendingHit = struct {
    name: []const u8,
    index: u32,
    action: CalendarAction,
};

pub const Calendar = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    font: renderer.Font,

    width: u32 = 340,
    height: u32 = 460,
    running: bool = true,

    view_year: u32,
    view_month: u32, // 1..12

    today_year: u32,
    today_month: u32,
    today_day: u32,

    selected_year: u32,
    selected_month: u32,
    selected_day: u32,

    dnd_enabled: bool = false,

    pointer_x: i32 = -1,
    pointer_y: i32 = -1,

    hit_areas: std.ArrayList(CalendarHitArea),

    panel_anim: animation.AnimationGroup = .{},
    panel_alpha: f32 = 1.0,
    panel_slide_y: i32 = 0,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !Calendar {
        const font = try renderer.Font.init(allocator, cfg.theme.font_family, cfg.typography.calendar_text);

        c.tzset();
        const cur_time = c.time(null);
        var tm: c.struct_tm = undefined;
        _ = c.localtime_r(&cur_time, &tm);

        const y: u32 = @intCast(tm.tm_year + 1900);
        const m: u32 = @intCast(tm.tm_mon + 1);
        const d: u32 = @intCast(tm.tm_mday);

        const is_dnd = (c.access("/tmp/mizu-dnd", c.F_OK) == 0);

        var cal: Calendar = .{
            .allocator = allocator,
            .cfg = cfg,
            .font = font,
            .width = 340,
            .height = 460,
            .view_year = y,
            .view_month = m,
            .today_year = y,
            .today_month = m,
            .today_day = d,
            .selected_year = y,
            .selected_month = m,
            .selected_day = d,
            .dnd_enabled = is_dnd,
            .hit_areas = std.ArrayList(CalendarHitArea).empty,
        };

        // Panel open animation: fade in with slight upward slide.
        cal.panel_anim.add(0.0, 1.0, 180, &animation.Easing.easeOutCubic);
        cal.panel_anim.set(1, -12.0, 0.0, 180, &animation.Easing.easeOutCubic);

        return cal;
    }

    pub fn deinit(self: *Calendar) void {
        self.hit_areas.deinit(self.allocator);
        self.font.deinit();
    }

    pub fn tick(self: *Calendar) bool {
        var changed = false;
        const is_dnd = (c.access("/tmp/mizu-dnd", c.F_OK) == 0);
        if (is_dnd != self.dnd_enabled) {
            self.dnd_enabled = is_dnd;
            changed = true;
        }

        // Update panel open/close animation.
        const anim_dt: u32 = 16;
        if (self.panel_anim.updateAll(anim_dt)) changed = true;
        self.panel_alpha = self.panel_anim.get(0);
        self.panel_slide_y = @as(i32, @intFromFloat(self.panel_anim.get(1)));

        return changed;
    }

    pub fn isLeapYear(year: u32) bool {
        return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
    }

    pub fn daysInMonth(year: u32, month: u32) u32 {
        const days = [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        if (month == 2 and isLeapYear(year)) return 29;
        if (month >= 1 and month <= 12) return days[month - 1];
        return 30;
    }

    // Returns 0 for Monday .. 6 for Sunday
    pub fn firstDayOfWeek(year: u32, month: u32) u32 {
        const t = [_]u32{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
        var y = year;
        if (month < 3) y -= 1;
        const dow = (y + y / 4 - y / 100 + y / 400 + t[month - 1] + 1) % 7;
        return (dow + 6) % 7;
    }

    pub fn weekdayOf(year: u32, month: u32, day: u32) u32 {
        if (day == 0) return firstDayOfWeek(year, month);
        return (firstDayOfWeek(year, month) + (day - 1) % 7) % 7;
    }

    pub fn monthName(month: u32) []const u8 {
        const names = [_][]const u8{
            "January", "February", "March", "April", "May", "June",
            "July", "August", "September", "October", "November", "December",
        };
        if (month >= 1 and month <= 12) return names[month - 1];
        return "Unknown";
    }

    pub fn prevMonth(self: *Calendar) void {
        if (self.view_month == 1) {
            self.view_month = 12;
            if (self.view_year > 1) self.view_year -= 1;
        } else {
            self.view_month -= 1;
        }
    }

    pub fn nextMonth(self: *Calendar) void {
        if (self.view_month == 12) {
            self.view_month = 1;
            self.view_year += 1;
        } else {
            self.view_month += 1;
        }
    }

    pub fn prevYear(self: *Calendar) void {
        if (self.view_year > 1) self.view_year -= 1;
    }

    pub fn nextYear(self: *Calendar) void {
        self.view_year += 1;
    }

    pub fn jumpToday(self: *Calendar) void {
        self.view_year = self.today_year;
        self.view_month = self.today_month;
        self.selected_year = self.today_year;
        self.selected_month = self.today_month;
        self.selected_day = self.today_day;
    }

    pub fn toggleDnd(self: *Calendar) void {
        self.dnd_enabled = !self.dnd_enabled;
        if (self.dnd_enabled) {
            if (c.fopen("/tmp/mizu-dnd", "w")) |f| {
                _ = c.fclose(f);
            }
        } else {
            _ = c.unlink("/tmp/mizu-dnd");
        }
        sys_status.spawnCmd("dunstctl set-paused toggle 2>/dev/null || makoctl mode -t dnd 2>/dev/null || true");
    }

    pub fn isAreaHovered(self: *const Calendar, x: i32, y: i32, w: u32, h: u32) bool {
        if (self.pointer_x < 0 or self.pointer_y < 0) return false;
        return (self.pointer_x >= x and self.pointer_x < x + @as(i32, @intCast(w)) and
            self.pointer_y >= y and self.pointer_y < y + @as(i32, @intCast(h)));
    }

    pub fn handlePointerMotion(self: *Calendar, x: i32, y: i32) bool {
        self.pointer_x = x;
        self.pointer_y = y;
        return true;
    }

    pub fn handlePointerLeave(self: *Calendar) bool {
        self.pointer_x = -1;
        self.pointer_y = -1;
        return true;
    }

    pub fn handlePointerButton(self: *Calendar, x: i32, y: i32, button: u32, is_pressed: bool) bool {
        if (button != 272) return false; // BTN_LEFT
        if (!is_pressed) return false;

        for (self.hit_areas.items) |area| {
            if (x >= area.x and x < area.x + @as(i32, @intCast(area.w)) and
                y >= area.y and y < area.y + @as(i32, @intCast(area.h)))
            {
                switch (area.action) {
                    .none => {},
                    .prev_month => self.prevMonth(),
                    .next_month => self.nextMonth(),
                    .prev_year => self.prevYear(),
                    .next_year => self.nextYear(),
                    .jump_today => self.jumpToday(),
                    .toggle_dnd => self.toggleDnd(),
                    .close => self.running = false,
                    .select_date => |date| {
                        self.selected_year = date.year;
                        self.selected_month = date.month;
                        self.selected_day = date.day;
                        self.view_year = date.year;
                        self.view_month = date.month;
                    },
                }
                return true;
            }
        }

        return false;
    }

    pub fn handlePointerAxis(self: *Calendar, _: i32, _: i32, delta: i32) bool {
        if (delta > 0) {
            self.nextMonth();
        } else if (delta < 0) {
            self.prevMonth();
        }
        return true;
    }

    pub fn handleKey(self: *Calendar, sym: u32) bool {
        switch (sym) {
            c.XKB_KEY_Escape, c.XKB_KEY_q => {
                self.running = false;
                return true;
            },
            c.XKB_KEY_Left, c.XKB_KEY_h => {
                if (self.selected_day > 1) {
                    self.selected_day -= 1;
                } else {
                    const prev_m = if (self.selected_month == 1) 12 else self.selected_month - 1;
                    const prev_y = if (self.selected_month == 1) self.selected_year - 1 else self.selected_year;
                    const prev_days = daysInMonth(prev_y, prev_m);
                    self.selected_day = prev_days;
                    self.selected_month = prev_m;
                    self.selected_year = prev_y;
                }
                self.view_year = self.selected_year;
                self.view_month = self.selected_month;
                return true;
            },
            c.XKB_KEY_Right, c.XKB_KEY_l => {
                const sel_days = daysInMonth(self.selected_year, self.selected_month);
                if (self.selected_day < sel_days) {
                    self.selected_day += 1;
                } else {
                    self.selected_day = 1;
                    if (self.selected_month == 12) {
                        self.selected_month = 1;
                        self.selected_year += 1;
                    } else {
                        self.selected_month += 1;
                    }
                }
                self.view_year = self.selected_year;
                self.view_month = self.selected_month;
                return true;
            },
            c.XKB_KEY_Up, c.XKB_KEY_k => {
                var d = @as(i32, @intCast(self.selected_day)) - 7;
                while (d < 1) {
                    const prev_m = if (self.selected_month == 1) 12 else self.selected_month - 1;
                    const prev_y = if (self.selected_month == 1) self.selected_year - 1 else self.selected_year;
                    const prev_days = daysInMonth(prev_y, prev_m);
                    d += @as(i32, @intCast(prev_days));
                    self.selected_month = prev_m;
                    self.selected_year = prev_y;
                }
                self.selected_day = @intCast(d);
                self.view_year = self.selected_year;
                self.view_month = self.selected_month;
                return true;
            },
            c.XKB_KEY_Down, c.XKB_KEY_j => {
                const sel_days = daysInMonth(self.selected_year, self.selected_month);
                var d = @as(i32, @intCast(self.selected_day)) + 7;
                while (d > @as(i32, @intCast(sel_days))) {
                    d -= @as(i32, @intCast(sel_days));
                    if (self.selected_month == 12) {
                        self.selected_month = 1;
                        self.selected_year += 1;
                    } else {
                        self.selected_month += 1;
                    }
                }
                self.selected_day = @intCast(d);
                self.view_year = self.selected_year;
                self.view_month = self.selected_month;
                return true;
            },
            c.XKB_KEY_Page_Up => {
                self.prevMonth();
                self.selected_month = self.view_month;
                self.selected_year = self.view_year;
                return true;
            },
            c.XKB_KEY_Page_Down => {
                self.nextMonth();
                self.selected_month = self.view_month;
                self.selected_year = self.view_year;
                return true;
            },
            c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => {
                self.view_year = self.selected_year;
                self.view_month = self.selected_month;
                return true;
            },
            c.XKB_KEY_t => {
                self.jumpToday();
                return true;
            },
            c.XKB_KEY_d => {
                self.toggleDnd();
                return true;
            },
            else => return false,
        }
    }

    /// Y position of the bottom of the header (weekday labels baseline).
    pub fn headerBottomY(self: *const Calendar) i32 {
        const scale_i = @as(i32, @intCast(self.cfg.typography.calendar_heading * 1));
        const pad_i = @as(i32, @intCast(Layout.pad));
        return pad_i + 40 + scale_i + 8; // header icon area + heading + gap to weekdays
    }

    pub fn render(self: *Calendar, target: renderer.Renderer, scale: u32) !void {
        self.hit_areas.clearRetainingCapacity();

        const w = target.width;
        const h = target.height;
        const nav_size: u16 = @intCast(28 * scale);
        const head_sz = self.cfg.typography.calendar_heading * scale;
        const sec_sz = self.cfg.typography.secondary * scale;
        const day_sz = self.cfg.typography.calendar_text * scale;
        const radius = self.cfg.theme.radius_panel * scale;

        target.clear(theme.Color.transparent);
        target.drawDropShadow(0, 0, w, h, radius, 8 * scale, self.cfg.theme.shadow_dark);

        var ui = try ui_mod.Ui.begin(
            self.allocator,
            &self.font,
            w,
            h,
            scale,
            self.pointer_x,
            self.pointer_y,
            false,
            1.0 / 60.0,
        );
        defer ui.deinit();

        var pending: [64]PendingHit = undefined;
        var pending_len: usize = 0;

        ui.root(.{
            .direction = .column,
            .padding = .all(ui.su(Layout.pad)),
            .gap = ui.su(Layout.section_gap),
            .bg = self.cfg.theme.panel_bg,
            .radius = ui.f(self.cfg.theme.radius_panel),
            .border = ui.su(Layout.border_w),
            .border_color = self.cfg.theme.panel_border,
        });

        // Header: previous, month/year title, next.
        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .fixed = @floatFromInt(nav_size) },
            .align_y = .center,
            .gap = ui.su(4),
        });
        {
            const prev_hov = ui.hovered("cal-prev", 0);
            _ = ui.open(.{
                .id = "cal-prev",
                .width = .{ .fixed = @floatFromInt(nav_size) },
                .height = .{ .fixed = @floatFromInt(nav_size) },
                .bg = if (prev_hov) self.cfg.theme.card_hover_bg else self.cfg.theme.surface,
                .radius = ui.f(6),
                .align_x = .center,
                .align_y = .center,
            });
            ui.icon("left", head_sz, if (prev_hov) self.cfg.theme.accent else self.cfg.theme.text_main, 0);
            ui.close();
            pending[pending_len] = .{ .name = "cal-prev", .index = 0, .action = .prev_month };
            pending_len += 1;

            const title_hov = ui.hovered("cal-title", 0);
            var title_buf: [48]u8 = undefined;
            const title_str = std.fmt.bufPrint(&title_buf, "{s} {d}", .{ monthName(self.view_month), self.view_year }) catch "Calendar";
            _ = ui.open(.{
                .id = "cal-title",
                .width = .{ .grow = .{} },
                .height = .{ .fixed = @floatFromInt(nav_size) },
                .align_x = .center,
                .align_y = .center,
            });
            ui.text(title_str, .{
                .size = head_sz,
                .color = if (title_hov) self.cfg.theme.accent else self.cfg.theme.text_bright,
            });
            ui.close();
            pending[pending_len] = .{ .name = "cal-title", .index = 0, .action = .jump_today };
            pending_len += 1;

            const next_hov = ui.hovered("cal-next", 0);
            _ = ui.open(.{
                .id = "cal-next",
                .width = .{ .fixed = @floatFromInt(nav_size) },
                .height = .{ .fixed = @floatFromInt(nav_size) },
                .bg = if (next_hov) self.cfg.theme.card_hover_bg else self.cfg.theme.surface,
                .radius = ui.f(6),
                .align_x = .center,
                .align_y = .center,
            });
            ui.icon("right", head_sz, if (next_hov) self.cfg.theme.accent else self.cfg.theme.text_main, 1);
            ui.close();
            pending[pending_len] = .{ .name = "cal-next", .index = 0, .action = .next_month };
            pending_len += 1;
        }
        ui.close();

        // Weekday header.
        const weekdays = [_][]const u8{ "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" };
        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .fixed = ui.s(22) },
            .direction = .row,
            .gap = 0,
        });
        for (weekdays) |day_name| {
            _ = ui.open(.{
                .width = .{ .percent = 1.0 / 7.0 },
                .height = .{ .grow = .{} },
                .align_x = .center,
                .align_y = .center,
            });
            ui.text(day_name, .{
                .size = sec_sz,
                .color = self.cfg.theme.text_muted,
            });
            ui.close();
        }
        ui.close();

        // Six-week date grid. Geometry comes entirely from Clay; hit rectangles
        // are read back after layout so calendar actions cannot drift from the
        // painted cells.
        const start_dow = firstDayOfWeek(self.view_year, self.view_month);
        const total_days = daysInMonth(self.view_year, self.view_month);
        const prev_m: u32 = if (self.view_month == 1) 12 else self.view_month - 1;
        const prev_y: u32 = if (self.view_month == 1) self.view_year - 1 else self.view_year;
        const next_m: u32 = if (self.view_month == 12) 1 else self.view_month + 1;
        const next_y: u32 = if (self.view_month == 12) self.view_year + 1 else self.view_year;
        const prev_days = daysInMonth(prev_y, prev_m);

        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
            .direction = .column,
            .gap = 0,
        });

        var cell_idx: u32 = 0;
        var row_i: u32 = 0;
        while (row_i < 6) : (row_i += 1) {
            _ = ui.open(.{
                .width = .{ .grow = .{} },
                .height = .{ .grow = .{} },
                .direction = .row,
                .gap = 0,
            });

            var col_i: u32 = 0;
            while (col_i < 7) : (col_i += 1) {
                const date = cellDate(cell_idx, start_dow, total_days, prev_y, prev_m, prev_days, self.view_year, self.view_month, next_y, next_m);
                const in_current = date.year == self.view_year and date.month == self.view_month;
                const is_today = date.year == self.today_year and date.month == self.today_month and date.day == self.today_day;
                const is_selected = date.year == self.selected_year and date.month == self.selected_month and date.day == self.selected_day;
                const is_hover = ui.hovered("cal-cell", cell_idx);

                const cell_bg = if (is_today)
                    self.cfg.theme.accent
                else if (is_hover)
                    self.cfg.theme.card_hover_bg
                else
                    null;

                _ = ui.open(.{
                    .id = "cal-cell",
                    .index = cell_idx,
                    .width = .{ .percent = 1.0 / 7.0 },
                    .height = .{ .grow = .{} },
                    .bg = cell_bg,
                    .radius = ui.f(8),
                    .border = if (is_selected) ui.su(2) else 0,
                    .border_color = if (is_selected) self.cfg.theme.accent else null,
                    .align_x = .center,
                    .align_y = .center,
                });

                var num_buf: [8]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{date.day}) catch "";
                const num_color = if (is_today)
                    self.cfg.theme.accent_fg
                else if (is_selected)
                    self.cfg.theme.accent
                else if (!in_current)
                    self.cfg.theme.text_muted
                else if (is_hover)
                    self.cfg.theme.accent
                else
                    self.cfg.theme.text_main;
                ui.text(num_str, .{
                    .size = day_sz,
                    .color = num_color,
                });
                ui.close();

                pending[pending_len] = .{
                    .name = "cal-cell",
                    .index = cell_idx,
                    .action = .{ .select_date = .{ .year = date.year, .month = date.month, .day = date.day } },
                };
                pending_len += 1;
                cell_idx += 1;
            }
            ui.close();
        }
        ui.close(); // grid
        ui.close(); // root

        const commands = ui.endLayout();
        const iscale: i32 = @intCast(scale);
        for (pending[0..pending_len]) |hit| {
            const rect = ui.rectOf(hit.name, hit.index) orelse continue;
            const lw: u32 = @intCast(@divTrunc(@as(i32, @intCast(rect.w)) + iscale - 1, iscale));
            const lh: u32 = @intCast(@divTrunc(@as(i32, @intCast(rect.h)) + iscale - 1, iscale));
            if (lw == 0 or lh == 0) continue;
            try self.hit_areas.append(self.allocator, .{
                .x = @divTrunc(rect.x, iscale),
                .y = @divTrunc(rect.y, iscale),
                .w = lw,
                .h = lh,
                .action = hit.action,
            });
        }

        ui.render(target, commands);

        if (self.panel_alpha < 1.0) {
            const fade_a = @as(u8, @intFromFloat((1.0 - self.panel_alpha) * 255.0));
            if (fade_a > 0) {
                target.fillRoundedRect(0, 0, w, h, radius, theme.Color.init(fade_a, 0, 0, 0));
            }
        }
    }

    fn truncateText(target: renderer.Renderer, font: *renderer.Font, text: []const u8, max_w: u32, buf: []u8, size: u32) []const u8 {
        const text_w = target.measureTextWithSize(font, text, size);
        if (text_w <= max_w) return text;
        const ellipsis = "...";
        const ell_w = target.measureTextWithSize(font, ellipsis, size);
        if (ell_w >= max_w) return "";
        var best_len: usize = 0;
        var utf8_view = std.unicode.Utf8View.init(text) catch return text;
        var it = utf8_view.iterator();
        while (it.nextCodepointSlice()) |slice| {
            const candidate_len = best_len + slice.len;
            if (candidate_len + ellipsis.len > buf.len) break;
            @memcpy(buf[0..candidate_len], text[0..candidate_len]);
            @memcpy(buf[candidate_len .. candidate_len + ellipsis.len], ellipsis);
            const mw = target.measureTextWithSize(font, buf[0 .. candidate_len + ellipsis.len], size);
            if (mw > max_w) break;
            best_len = candidate_len;
        }
        if (best_len == 0) return "";
        @memcpy(buf[0..best_len], text[0..best_len]);
        @memcpy(buf[best_len .. best_len + ellipsis.len], ellipsis);
        return buf[0 .. best_len + ellipsis.len];
    }
};

const CellDate = struct {
    year: u32,
    month: u32,
    day: u32,
};

fn cellDate(
    idx: u32,
    start_dow: u32,
    total_days: u32,
    prev_y: u32,
    prev_m: u32,
    prev_days: u32,
    cur_y: u32,
    cur_m: u32,
    next_y: u32,
    next_m: u32,
) CellDate {
    if (idx < start_dow) {
        return .{ .year = prev_y, .month = prev_m, .day = prev_days - start_dow + 1 + idx };
    }
    if (idx >= start_dow + total_days) {
        return .{ .year = next_y, .month = next_m, .day = idx - start_dow - total_days + 1 };
    }
    return .{ .year = cur_y, .month = cur_m, .day = idx - start_dow + 1 };
}

test "Calendar date calculations" {
    try std.testing.expect(!Calendar.isLeapYear(2026));
    try std.testing.expect(Calendar.isLeapYear(2024));
    try std.testing.expectEqual(@as(u32, 28), Calendar.daysInMonth(2026, 2));
    try std.testing.expectEqual(@as(u32, 29), Calendar.daysInMonth(2024, 2));
    try std.testing.expectEqual(@as(u32, 31), Calendar.daysInMonth(2026, 10));

    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var cal = Calendar{
        .allocator = allocator,
        .cfg = cfg,
        .font = undefined,
        .view_year = 2026,
        .view_month = 10,
        .today_year = 2026,
        .today_month = 10,
        .today_day = 16,
        .selected_year = 2026,
        .selected_month = 10,
        .selected_day = 16,
        .hit_areas = std.ArrayList(CalendarHitArea).empty,
    };
    defer { cal.hit_areas.deinit(allocator); }

    cal.nextMonth();
    try std.testing.expectEqual(@as(u32, 11), cal.view_month);
    try std.testing.expectEqual(@as(u32, 2026), cal.view_year);

    cal.prevMonth();
    try std.testing.expectEqual(@as(u32, 10), cal.view_month);

    cal.nextYear();
    try std.testing.expectEqual(@as(u32, 2027), cal.view_year);

    cal.prevYear();
    try std.testing.expectEqual(@as(u32, 2026), cal.view_year);
}

test "Calendar render latency" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var cal = try Calendar.init(allocator, cfg);
    defer cal.deinit();

    const w = cal.width;
    const h = cal.height;
    const stride = w * 4;
    const pixel_buf = try allocator.alloc(u32, w * h);
    defer allocator.free(pixel_buf);

    var target = try renderer.Renderer.init(pixel_buf.ptr, w, h, stride);
    defer target.deinit();

    _ = try cal.render(target, 1);
}
