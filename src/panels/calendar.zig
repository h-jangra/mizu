const std = @import("std");
const c = @import("c");
const renderer = @import("../core/renderer.zig");
const theme = @import("../core/theme.zig");
const config = @import("../core/config.zig");
const animation = @import("../core/animation.zig");
const icons = @import("../graphics/icons.zig");
const sys_status = @import("../services/system_status.zig");
const holidays = @import("../services/holidays.zig");
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

/// Custom draw render for the clock card - draws the time twice with a small
/// x-offset to approximate a heavier font weight (no bold font is shipped).
pub const ClockDraw = struct {
    panel: *Calendar,
    scale: u32,
    text: [16]u8,
    text_len: usize,
    color: theme.Color,
    size_px: u32,

    fn draw(target: renderer.Renderer, rect: renderer.Rect, data: *const anyopaque) void {
        const cd: *const ClockDraw = @ptrCast(@alignCast(data));
        const font = &cd.panel.font;
        const fy: f64 = @floatFromInt(rect.y);
        const fh: f64 = @floatFromInt(rect.h);
        const fx: f64 = @floatFromInt(rect.x);
        const fw: f64 = @floatFromInt(rect.w);
        const text = cd.text[0..cd.text_len];
        const tw: f64 = @floatFromInt(font.measureTextWithSize(text, cd.size_px));
        // Heavy weight: a 3x3 grid of overlapping copies (offsets up to 2
        // logical px in both axes) thickens the glyphs uniformly, not just
        // to one side like the previous 4-pass draw.
        const o: i32 = @intCast(4 * @max(1, cd.scale));
        const half: i32 = @intCast(@max(1, @divTrunc(o, 4)));
        // Compensate for the extra drawn extent so the text stays centered.
        const mo: f64 = @floatFromInt(o);
        const tx: i32 = @intFromFloat(fx + (fw - (tw + mo)) / 2.0);
        // Vertical centering accounts for the descender and the upward
        // stretch of the copies, so the ink (not the em box) is centered.
        const asc: f64 = @floatFromInt(font.ascentForSize(cd.size_px));
        const desc: f64 = @floatFromInt(font.descentForSize(cd.size_px));
        const baseline: i32 = @intFromFloat(fy + (fh + asc - desc + mo) / 2.0 + desc);
        var dy: i32 = 0;
        while (dy <= o) : (dy += half) {
            var dx: i32 = 0;
            while (dx <= o) : (dx += half) {
                target.drawTextWithSize(font, text, tx + dx, baseline - dy, cd.size_px, cd.color);
            }
        }
    }
};

pub const Calendar = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    font: renderer.Font,

    width: u32 = 640,
    height: u32 = 520,
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
    last_sec: u8 = 255,

    holiday_store: ?holidays.HolidayStore = null,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !Calendar {
        const font = try renderer.Font.init(allocator, cfg.theme.font_family, cfg.typography.calendar_text);

        c.tzset();
        const cur_time = c.time(null);
        var tm: c.struct_tm = undefined;
        _ = c.localtime_r(&cur_time, &tm);

        const y: u32 = @intCast(tm.tm_year + 1900);
        const m: u32 = @intCast(tm.tm_mon + 1);
        const d: u32 = @intCast(tm.tm_mday);

        const is_dnd = isDndActive();

        var cal: Calendar = .{
            .allocator = allocator,
            .cfg = cfg,
            .font = font,
            .width = 600,
            .height = 400,
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
            .holiday_store = null,
        };

        // Load any available .ics file (scans config path, no hardcoded name).
        cal.holiday_store = holidays.HolidayStore.init(allocator, cfg.calendar_file);
        cal.panel_alpha = 0.0;
        cal.panel_slide_y = 16;
        animation.quickFadeIn(&cal.panel_anim.items[0]);
        animation.quickSlideUp(&cal.panel_anim.items[1]);
        cal.panel_anim.count = 2;

        return cal;
    }

    pub fn deinit(self: *Calendar) void {
        if (self.holiday_store) |*store| {
            store.deinit();
            self.holiday_store = null;
        }
        self.hit_areas.deinit(self.allocator);
        self.font.deinit();
    }

    pub fn tick(self: *Calendar) bool {
        var changed = false;
        const is_dnd = isDndActive();
        if (is_dnd != self.dnd_enabled) {
            self.dnd_enabled = is_dnd;
            changed = true;
        }

        const cur_time = c.time(null);
        var tm: c.struct_tm = undefined;
        _ = c.localtime_r(&cur_time, &tm);
        const s: u8 = @intCast(tm.tm_sec);
        if (self.last_sec != s) {
            self.last_sec = s;
            changed = true;
        }

        if (self.holiday_store) |*store| {
            if (store.refreshIfChanged()) changed = true;
        }

        // Advance entry animations (lightweight, event-driven).
        if (self.panel_anim.anyActive()) {
            const dt_ms: u32 = 16;
            if (self.panel_anim.updateAll(dt_ms)) {
                changed = true;
                self.panel_alpha = @min(1.0, @max(0.0, self.panel_anim.get(0)));
                self.panel_slide_y = @intFromFloat(self.panel_anim.get(1));
            }
        } else if (self.panel_alpha < 1.0 or self.panel_slide_y != 0) {
            self.panel_alpha = 1.0;
            self.panel_slide_y = 0;
            changed = true;
        }

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

    // Returns 0 for Sunday .. 6 for Saturday
    pub fn firstDayOfWeek(year: u32, month: u32) u32 {
        const t = [_]u32{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
        var y = year;
        if (month < 3) y -= 1;
        const dow = (y + y / 4 - y / 100 + y / 400 + t[month - 1] + 1) % 7;
        return dow;
    }

    pub fn weekdayOf(year: u32, month: u32, day: u32) u32 {
        if (day == 0) return firstDayOfWeek(year, month);
        return (firstDayOfWeek(year, month) + (day - 1) % 7) % 7;
    }

    pub fn monthName(month: u32) []const u8 {
        const names = [_][]const u8{
            "January", "February", "March",     "April",   "May",      "June",
            "July",    "August",   "September", "October", "November", "December",
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
        const home = c.getenv("HOME");
        var path_buf: [256]u8 = undefined;
        if (self.dnd_enabled) {
            if (home) |h| {
                if (std.fmt.bufPrintSentinel(&path_buf, "{s}/.cache/mizu/dnd", .{std.mem.span(h)}, 0)) |p| {
                    if (c.fopen(p.ptr, "wb")) |f| _ = c.fclose(f);
                } else |_| {}
            }
            if (c.fopen("/tmp/mizu-dnd", "w")) |f| {
                _ = c.fclose(f);
            }
        } else {
            if (home) |h| {
                if (std.fmt.bufPrintSentinel(&path_buf, "{s}/.cache/mizu/dnd", .{std.mem.span(h)}, 0)) |p| {
                    _ = c.unlink(p.ptr);
                } else |_| {}
            }
            _ = c.unlink("/tmp/mizu-dnd");
        }
        sys_status.spawnCmd("dunstctl set-paused toggle 2>/dev/null || makoctl mode -t dnd 2>/dev/null || true");
    }

    fn isDndActive() bool {
        const home = c.getenv("HOME");
        if (home) |h| {
            var path_buf: [256]u8 = undefined;
            if (std.fmt.bufPrintSentinel(&path_buf, "{s}/.cache/mizu/dnd", .{std.mem.span(h)}, 0)) |p| {
                if (c.access(p.ptr, c.F_OK) == 0) return true;
            } else |_| {}
        }
        return (c.access("/tmp/mizu-dnd", c.F_OK) == 0);
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

    pub fn render(self: *Calendar, target: renderer.Renderer, scale: u32) !void {
        self.hit_areas.clearRetainingCapacity();

        const w = target.width;
        const h = target.height;
        const nav_size: u16 = @intCast(28 * scale);
        const head_sz = self.cfg.typography.calendar_heading * scale;
        const sec_sz = self.cfg.typography.secondary * scale;
        const day_sz = self.cfg.typography.calendar_text * scale;
        const weekday_sz = sec_sz + 2 * scale;
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

        // Column widths: computed fixed sizes so Clay never has to expand
        // percentages from content widths (percent columns of a grow row
        // get sized against the content pass and overflow).
        const pad_px: f32 = @as(f32, @floatFromInt(Layout.pad)) * @as(f32, @floatFromInt(scale));
        const col_gap_px: f32 = @as(f32, @floatFromInt(10)) * @as(f32, @floatFromInt(scale));
        const content_w: f32 = @as(f32, @floatFromInt(w)) - 2.0 * pad_px;
        const left_w: f32 = (content_w - col_gap_px) * 0.55;
        const right_w: f32 = (content_w - col_gap_px) * 0.45;
        // Day-cell width: 7 columns with 4px logical gaps.
        const cell_gap_px: f32 = @as(f32, @floatFromInt(4)) * @as(f32, @floatFromInt(scale));
        const cell_w: f32 = (left_w - 6.0 * cell_gap_px) / 7.0;
        // Equal card height: the three right-column cards each get an equal
        // third of the column height minus two column gaps (12 logical each).
        const col_v_gap: f32 = @as(f32, @floatFromInt(12)) * @as(f32, @floatFromInt(scale));
        const col_h: f32 = @as(f32, @floatFromInt(h)) - 2.0 * pad_px;
        const card_h: f32 = (col_h - 2.0 * col_v_gap) / 3.0;

        // 2-column layout: left = calendar (header + grid); right = date info + holiday
        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
            .direction = .row,
            .gap = ui.su(10),
        });
        // LEFT COLUMN - Calendar (whole bg same as the panel bg)
        _ = ui.open(.{
            .id = "cal-left",
            .index = 0,
            .width = .{ .fixed = left_w },
            .height = .{ .grow = .{} },
            .direction = .column,
            .gap = ui.su(6),
            .bg = self.cfg.theme.panel_bg,
            .radius = ui.f(self.cfg.theme.radius_panel),
        });
        // Month header: < Month >
        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .fixed = @floatFromInt(44 * scale) },
            .direction = .row,
            .align_y = .center,
            .gap = ui.su(6),
        });
        {
            const prev_mo = ui.hovered("cal-month-prev", 0);
            _ = ui.open(.{ .id = "cal-month-prev", .index = 0, .width = .{ .fixed = @floatFromInt(nav_size) }, .height = .{ .fixed = @floatFromInt(nav_size) }, .bg = if (prev_mo) self.cfg.theme.surface else null, .radius = ui.f(6), .align_x = .center, .align_y = .center });
            ui.icon("left", head_sz, if (prev_mo) self.cfg.theme.accent else self.cfg.theme.text_muted, 0);
            ui.close();
            pending[pending_len] = .{ .name = "cal-month-prev", .index = 0, .action = .prev_month };
            pending_len += 1;

            var title_buf: [48]u8 = undefined;
            const title_str = std.fmt.bufPrint(&title_buf, "{s} {d}", .{ monthName(self.view_month), self.view_year }) catch "Calendar";
            _ = ui.open(.{ .id = "cal-month-title", .index = 0, .width = .{ .grow = .{} }, .height = .{ .fixed = @floatFromInt(nav_size) }, .align_x = .center, .align_y = .center });
            ui.text(title_str, .{ .size = head_sz, .color = self.cfg.theme.text_bright });
            ui.close();
            pending[pending_len] = .{ .name = "cal-month-title", .index = 0, .action = .jump_today };
            pending_len += 1;

            const next_mo = ui.hovered("cal-month-next", 0);
            _ = ui.open(.{ .id = "cal-month-next", .index = 0, .width = .{ .fixed = @floatFromInt(nav_size) }, .height = .{ .fixed = @floatFromInt(nav_size) }, .bg = if (next_mo) self.cfg.theme.surface else null, .radius = ui.f(6), .align_x = .center, .align_y = .center });
            ui.icon("right", head_sz, if (next_mo) self.cfg.theme.accent else self.cfg.theme.text_muted, 1);
            ui.close();
            pending[pending_len] = .{ .name = "cal-month-next", .index = 0, .action = .next_month };
            pending_len += 1;
        }
        ui.close();

        // Weekday header (starts on Sunday)
        const weekdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
        _ = ui.open(.{ .width = .{ .grow = .{} }, .height = .{ .fixed = ui.s(24) }, .direction = .row, .gap = ui.su(4) });
        for (weekdays) |day_name| {
            _ = ui.open(.{ .width = .{ .fixed = cell_w }, .height = .{ .grow = .{} }, .align_x = .center, .align_y = .center });
            ui.text(day_name, .{ .size = weekday_sz, .color = self.cfg.theme.text_muted });
            ui.close();
        }
        ui.close();

        // Date grid
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
            .gap = ui.su(4),
        });

        var cell_idx: u32 = 0;
        var row_i: u32 = 0;
        while (row_i < 6) : (row_i += 1) {
            _ = ui.open(.{
                .width = .{ .grow = .{} },
                .height = .{ .grow = .{} },
                .direction = .row,
                .gap = ui.su(4),
            });

            var col_i: u32 = 0;
            while (col_i < 7) : (col_i += 1) {
                const date = cellDate(cell_idx, start_dow, total_days, prev_y, prev_m, prev_days, self.view_year, self.view_month, next_y, next_m);
                const in_current = date.year == self.view_year and date.month == self.view_month;
                const is_today = date.year == self.today_year and date.month == self.today_month and date.day == self.today_day;
                const is_selected = date.year == self.selected_year and date.month == self.selected_month and date.day == self.selected_day;
                const is_hover = ui.hovered("cal-cell", cell_idx);

                var hover_bg = self.cfg.theme.accent;
                hover_bg.a = 70;

                const cell_bg = if (is_today)
                    self.cfg.theme.accent
                else if (is_hover)
                    hover_bg
                else if (in_current)
                    self.cfg.theme.card_bg
                else
                    null;

                _ = ui.open(.{
                    .id = "cal-cell",
                    .index = cell_idx,
                    .width = .{ .fixed = cell_w },
                    .height = .{ .grow = .{} },
                    .bg = cell_bg,
                    .radius = ui.f(12),
                    .border = if (is_selected) ui.su(2) else 0,
                    .border_color = if (is_selected) self.cfg.theme.accent else null,
                    .align_x = .center,
                    .align_y = .center,
                });

                var num_buf: [8]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{date.day}) catch "";
                const holiday_opt = if (self.holiday_store) |store| store.find(date.year, date.month, date.day) else null;
                const has_hol = holiday_opt != null;
                const num_color = if (is_today)
                    self.cfg.theme.accent_fg
                else if (is_selected)
                    self.cfg.theme.accent
                else if (has_hol)
                    self.cfg.theme.accent
                else if (!in_current)
                    self.cfg.theme.text_muted
                else if (is_hover)
                    self.cfg.theme.accent
                else
                    self.cfg.theme.text_main;
                ui.text(num_str, .{
                    .size = (day_sz * 9) / 8,
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

        ui.close(); // left column

        // RIGHT COLUMN - Date info + holiday (three separate cards on the panel bg)
        _ = ui.open(.{
            .id = "cal-right",
            .index = 0,
            .width = .{ .fixed = right_w },
            .height = .{ .grow = .{} },
            .direction = .column,
            .gap = ui.su(12),
        });

        // 1. Clock card: descriptive, font shrinks until the time fits
        c.tzset();
        const cur_time = c.time(null);
        var tm: c.struct_tm = undefined;
        _ = c.localtime_r(&cur_time, &tm);
        const raw_hour_24: u32 = @intCast(tm.tm_hour);
        const min_u: u32 = @intCast(tm.tm_min);
        const sec_u: u32 = @intCast(tm.tm_sec);
        const display_hour = if (raw_hour_24 == 0) 12 else if (raw_hour_24 > 12) raw_hour_24 - 12 else raw_hour_24;

        const clock_bg = self.cfg.theme.accent;
        var clock_buf: [32]u8 = undefined;
        const clock_str = std.fmt.bufPrint(&clock_buf, "{d}:{d:0>2}:{d:0>2}", .{ display_hour, min_u, sec_u }) catch "12:00:00";

        var clock_size = sec_sz * 6;
        // Account for the extra drawn width of the heavy 9-pass text
        // (copies extend up to 2 logical px to the right) in the budget.
        const clock_weight_offset: u32 = 4 * scale;
        const clock_budget = right_w - @as(f32, @floatFromInt(2 * 16 * scale)) - @as(f32, @floatFromInt(clock_weight_offset));
        while (clock_size > sec_sz * 2 and @as(f32, @floatFromInt(self.font.measureTextWithSize(clock_str, clock_size))) > clock_budget) {
            clock_size -= 1;
        }

        _ = ui.open(.{
            .id = "cal-clk",
            .width = .{ .grow = .{} },
            .height = .{ .fixed = card_h },
            .direction = .row,
            .align_x = .center,
            .align_y = .center,
            .bg = clock_bg,
            .radius = ui.f(16),
            .border = 0,
            .padding = .xy(ui.su(16), ui.su(8)),
        });
        const clock_data = ui.allocator.create(ClockDraw) catch return;
        clock_data.* = .{
            .panel = self,
            .scale = scale,
            .text = @splat(0),
            .text_len = clock_str.len,
            .color = self.cfg.theme.accent_fg,
            .size_px = clock_size,
        };
        @memcpy(clock_data.text[0..clock_str.len], clock_str);
        const clock_custom = ui.allocator.create(ui_mod.Custom) catch return;
        clock_custom.* = .{ .callback = .{ .function = ClockDraw.draw, .data = clock_data } };
        ui.custom(.{ .grow = .{} }, .{ .grow = .{} }, clock_custom, 0);
        ui.close(); // custom clock text
        ui.close(); // clock card

        // 2. Current date card: "30 Oct" over "Friday · 10/30/2026"
        const weekday_full = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
        const short_months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
        const wday_idx: usize = @intCast(@mod(@as(i64, tm.tm_wday), 7));
        const cur_y: u32 = @intCast(tm.tm_year + 1900);
        const cur_m: u32 = @intCast(tm.tm_mon + 1);
        const cur_d: u32 = @intCast(tm.tm_mday);
        var date_buf: [16]u8 = undefined;
        const date_str = std.fmt.bufPrint(&date_buf, "{d:0>2}/{d:0>2}/{d}", .{ cur_m, cur_d, cur_y }) catch "";
        var line2_buf: [48]u8 = undefined;
        const line2_str = std.fmt.bufPrint(&line2_buf, "{s} · {s}", .{ weekday_full[wday_idx], date_str }) catch date_str;

        _ = ui.open(.{
            .id = "cal-date",
            .width = .{ .grow = .{} },
            .height = .{ .fixed = card_h },
            .direction = .column,
            .align_x = .center,
            .align_y = .center,
            .gap = ui.su(4),
            .bg = self.cfg.theme.card_bg,
            .radius = ui.f(16),
            .border = 0,
            .padding = .xy(ui.su(10), ui.su(6)),
        });
        _ = ui.open(.{
            .width = .fit,
            .height = .fit,
            .direction = .row,
            .gap = ui.su(6),
            .align_x = .center,
            .align_y = .center,
        });
        var day_buf: [8]u8 = undefined;
        const day_str = std.fmt.bufPrint(&day_buf, "{d}", .{cur_d}) catch "";
        const big_day_sz = @as(u32, @intFromFloat(card_h * 0.55));
        ui.text(day_str, .{ .size = big_day_sz, .color = self.cfg.theme.text_bright, .text_align = .center });
        ui.text(short_months[cur_m - 1], .{ .size = (sec_sz * 4) / 2, .color = self.cfg.theme.accent, .text_align = .center });
        ui.close();
        ui.text(line2_str, .{ .size = (sec_sz * 5) / 4, .color = self.cfg.theme.text_muted, .line_height = @intCast((sec_sz * 5) / 4 + 4), .wrap = true, .text_align = .center });
        ui.close();

        // 3. Holidays card (shows whole-month holidays, or the selected day's holiday)
        _ = ui.open(.{
            .id = "cal-hol",
            .width = .{ .grow = .{} },
            .height = .{ .fixed = card_h },
            .direction = .column,
            .gap = ui.su(8),
            .bg = self.cfg.theme.card_bg,
            .radius = ui.f(16),
            .border = 0,
            .padding = .xy(ui.su(16), ui.su(12)),
            .clip_vertical = true,
        });
        // Larger holiday text (list rows and detail view share it).
        const hol_sz = (sec_sz * 5) / 4;

        const sel_in_view = self.selected_year == self.view_year and self.selected_month == self.view_month;
        var sel_holiday: ?*const holidays.Holiday = null;
        if (sel_in_view) {
            if (self.holiday_store) |*store| {
                sel_holiday = store.find(self.selected_year, self.selected_month, self.selected_day);
            }
        }

        if (sel_holiday) |hol| {
            // Detail view: the selected day has a holiday.
            var hol_date_buf: [48]u8 = undefined;
            const hol_date_str = std.fmt.bufPrint(
                &hol_date_buf,
                "{d:0>2}/{d:0>2}/{d}",
                .{ self.selected_month, self.selected_day, self.selected_year },
            ) catch "";

            ui.text(hol.summarySlice(), .{
                .size = (sec_sz * 9) / 4,
                .color = self.cfg.theme.text_bright,
                .wrap = true,
                .line_height = @intCast((sec_sz * 9) / 4 + 6),
            });
            ui.text(hol_date_str, .{ .size = hol_sz, .color = self.cfg.theme.accent, .line_height = @intCast(hol_sz + 2) });
        } else {
            // List view: every holiday in the viewed month.
            var shown: usize = 0;
            if (self.holiday_store) |*store| {
                for (store.items.items) |*item| {
                    if (shown >= 6) break;
                    if (item.year != self.view_year or item.month != self.view_month) continue;

                    var hday_buf: [8]u8 = undefined;
                    const hday_str = std.fmt.bufPrint(&hday_buf, "{d}", .{item.day}) catch "";

                    var hsum_buf: [160]u8 = undefined;
                    const hsum_budget: u32 = @intFromFloat(right_w - @as(f32, @floatFromInt(2 * 16 * scale)) - @as(f32, @floatFromInt(24 * scale)) - @as(f32, @floatFromInt(10 * scale)));
                    const hsum_text = renderer.truncateText(&self.font, item.summarySlice(), hsum_budget, hol_sz, &hsum_buf);

                    _ = ui.open(.{
                        .id = "cal-holiday-row",
                        .index = @intCast(shown),
                        .width = .{ .grow = .{} },
                        .height = .{ .fixed = @floatFromInt(38 * scale) },
                        .direction = .row,
                        .gap = ui.su(10),
                        .align_y = .center,
                        .bg = if (ui.hovered("cal-holiday-row", @intCast(shown))) self.cfg.theme.card_hover_bg else null,
                        .radius = ui.f(8),
                        .padding = .xy(ui.su(6), 0),
                    });
                    _ = ui.open(.{ .width = .{ .fixed = @floatFromInt(28 * scale) }, .align_x = .left });
                    ui.text(hday_str, .{ .size = hol_sz, .color = self.cfg.theme.accent, .line_height = @intCast(hol_sz + 2) });
                    ui.close();
                    ui.text(hsum_text, .{ .size = hol_sz, .color = self.cfg.theme.text_main, .line_height = @intCast(hol_sz + 2) });
                    ui.close();

                    shown += 1;
                }
            }

            if (shown == 0) {
                ui.text("No holidays this month", .{ .size = hol_sz, .color = self.cfg.theme.text_muted, .line_height = @intCast(hol_sz + 2) });
            }
        }
        ui.close(); // holidays card
        ui.close();

        ui.close(); // right column

        ui.close(); // row
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

        // Panel entry fade handled by panel_alpha; no black overlay needed.
        // (If using overlay, ensure it doesn't block content at start.)
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
    try std.testing.expectEqual(@as(u32, 4), Calendar.firstDayOfWeek(2026, 10)); // Oct 1, 2026 is Thursday (0=Sun..4=Thu)
    try std.testing.expectEqual(@as(u32, 0), Calendar.weekdayOf(2026, 10, 4)); // Oct 4, 2026 is Sunday (0)
    try std.testing.expectEqual(@as(u32, 1), Calendar.weekdayOf(2026, 10, 5)); // Oct 5, 2026 is Monday (1)

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
    defer {
        cal.hit_areas.deinit(allocator);
    }

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
