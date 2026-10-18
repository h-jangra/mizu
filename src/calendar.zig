const std = @import("std");
const c = @import("c.zig").c;
const renderer = @import("renderer.zig");
const theme = @import("theme.zig");
const config = @import("config.zig");

pub const CalendarAction = enum {
    none,
    prev_month,
    next_month,
    prev_year,
    next_year,
    jump_today,
    close,
};

pub const CalendarHitArea = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    action: CalendarAction,
};

pub const Calendar = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    font: renderer.Font,

    width: u32 = 290,
    height: u32 = 318,
    running: bool = true,

    view_year: u32,
    view_month: u32, // 1..12

    today_year: u32,
    today_month: u32,
    today_day: u32,

    pointer_x: i32 = -1,
    pointer_y: i32 = -1,

    hit_areas: std.ArrayList(CalendarHitArea),

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !Calendar {
        const font = try renderer.Font.init(allocator, cfg.theme.font_family, cfg.theme.font_size);

        c.tzset();
        const cur_time = c.time(null);
        var tm: c.struct_tm = undefined;
        _ = c.localtime_r(&cur_time, &tm);

        const y: u32 = @intCast(tm.tm_year + 1900);
        const m: u32 = @intCast(tm.tm_mon + 1);
        const d: u32 = @intCast(tm.tm_mday);

        return .{
            .allocator = allocator,
            .cfg = cfg,
            .font = font,
            .width = 290,
            .height = 318,
            .view_year = y,
            .view_month = m,
            .today_year = y,
            .today_month = m,
            .today_day = d,
            .hit_areas = std.ArrayList(CalendarHitArea).empty,
        };
    }

    pub fn deinit(self: *Calendar) void {
        self.hit_areas.deinit(self.allocator);
        self.font.deinit();
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
        // dow: 0=Sun, 1=Mon, ..., 6=Sat
        // Convert to Mon=0 .. Sun=6
        return (dow + 6) % 7;
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
                    .close => self.running = false,
                }
                return true;
            }
        }
        return false;
    }

    pub fn handlePointerAxis(self: *Calendar, x: i32, y: i32, delta: i32) bool {
        _ = x;
        _ = y;
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
                self.prevMonth();
                return true;
            },
            c.XKB_KEY_Right, c.XKB_KEY_l => {
                self.nextMonth();
                return true;
            },
            c.XKB_KEY_Up, c.XKB_KEY_k => {
                self.nextYear();
                return true;
            },
            c.XKB_KEY_Down, c.XKB_KEY_j => {
                self.prevYear();
                return true;
            },
            c.XKB_KEY_t => {
                self.jumpToday();
                return true;
            },
            else => return false,
        }
    }

    pub fn render(self: *Calendar, target: renderer.Renderer) !void {
        self.hit_areas.clearRetainingCapacity();

        const w = target.width;
        const h = target.height;
        const radius = self.cfg.panel_radius;

        // Background squircle panel
        target.clear(theme.Color.transparent);
        target.fillGlassSquircle(0, 0, w, h, radius, self.cfg.theme.panel_bg);
        target.drawSquircleBorder(0, 0, w, h, radius, 1, self.cfg.theme.panel_border);

        const pad_x: i32 = 14;
        const content_w: u32 = w - 28;

        // 1. Header: Navigation & Month/Year
        const nav_btn_size: u32 = 24;
        const head_y: i32 = 14;

        // Prev Year button "<<"
        const prev_y_hover = self.isAreaHovered(pad_x, head_y, nav_btn_size, nav_btn_size);
        const prev_y_bg = if (prev_y_hover) self.cfg.theme.elevated else self.cfg.theme.surface;
        target.fillGlassSquircle(pad_x, head_y, nav_btn_size, nav_btn_size, 5, prev_y_bg);
        target.drawSquircleBorder(pad_x, head_y, nav_btn_size, nav_btn_size, 5, 1, if (prev_y_hover) self.cfg.theme.accent else self.cfg.theme.border);
        const py_icon = "󰁍";
        const py_w = target.measureTextWithSize(&self.font, py_icon, 11);
        target.drawTextWithSize(&self.font, py_icon, pad_x + @divTrunc(@as(i32, @intCast(nav_btn_size)) - @as(i32, @intCast(py_w)), 2), head_y + 17, 11, if (prev_y_hover) self.cfg.theme.accent else self.cfg.theme.text_muted);
        try self.hit_areas.append(self.allocator, .{
            .x = pad_x,
            .y = head_y,
            .w = nav_btn_size,
            .h = nav_btn_size,
            .action = .prev_year,
        });

        // Prev Month button "<"
        const prev_m_x = pad_x + @as(i32, @intCast(nav_btn_size + 4));
        const prev_m_hover = self.isAreaHovered(prev_m_x, head_y, nav_btn_size, nav_btn_size);
        const prev_m_bg = if (prev_m_hover) self.cfg.theme.elevated else self.cfg.theme.surface;
        target.fillGlassSquircle(prev_m_x, head_y, nav_btn_size, nav_btn_size, 5, prev_m_bg);
        target.drawSquircleBorder(prev_m_x, head_y, nav_btn_size, nav_btn_size, 5, 1, if (prev_m_hover) self.cfg.theme.accent else self.cfg.theme.border);
        const p_icon = "󰅁";
        const p_w = target.measureTextWithSize(&self.font, p_icon, 12);
        target.drawTextWithSize(&self.font, p_icon, prev_m_x + @divTrunc(@as(i32, @intCast(nav_btn_size)) - @as(i32, @intCast(p_w)), 2), head_y + 17, 12, if (prev_m_hover) self.cfg.theme.accent else self.cfg.theme.text_bright);
        try self.hit_areas.append(self.allocator, .{
            .x = prev_m_x,
            .y = head_y,
            .w = nav_btn_size,
            .h = nav_btn_size,
            .action = .prev_month,
        });

        // Next Month button ">"
        const next_m_x = @as(i32, @intCast(w)) - pad_x - @as(i32, @intCast(nav_btn_size * 2 + 4));
        const next_m_hover = self.isAreaHovered(next_m_x, head_y, nav_btn_size, nav_btn_size);
        const next_m_bg = if (next_m_hover) self.cfg.theme.elevated else self.cfg.theme.surface;
        target.fillGlassSquircle(next_m_x, head_y, nav_btn_size, nav_btn_size, 5, next_m_bg);
        target.drawSquircleBorder(next_m_x, head_y, nav_btn_size, nav_btn_size, 5, 1, if (next_m_hover) self.cfg.theme.accent else self.cfg.theme.border);
        const n_icon = "󰅂";
        const n_w = target.measureTextWithSize(&self.font, n_icon, 12);
        target.drawTextWithSize(&self.font, n_icon, next_m_x + @divTrunc(@as(i32, @intCast(nav_btn_size)) - @as(i32, @intCast(n_w)), 2), head_y + 17, 12, if (next_m_hover) self.cfg.theme.accent else self.cfg.theme.text_bright);
        try self.hit_areas.append(self.allocator, .{
            .x = next_m_x,
            .y = head_y,
            .w = nav_btn_size,
            .h = nav_btn_size,
            .action = .next_month,
        });

        // Next Year button ">>"
        const next_y_x = @as(i32, @intCast(w)) - pad_x - @as(i32, @intCast(nav_btn_size));
        const next_y_hover = self.isAreaHovered(next_y_x, head_y, nav_btn_size, nav_btn_size);
        const next_y_bg = if (next_y_hover) self.cfg.theme.elevated else self.cfg.theme.surface;
        target.fillGlassSquircle(next_y_x, head_y, nav_btn_size, nav_btn_size, 5, next_y_bg);
        target.drawSquircleBorder(next_y_x, head_y, nav_btn_size, nav_btn_size, 5, 1, if (next_y_hover) self.cfg.theme.accent else self.cfg.theme.border);
        const ny_icon = "󰁔";
        const ny_w = target.measureTextWithSize(&self.font, ny_icon, 11);
        target.drawTextWithSize(&self.font, ny_icon, next_y_x + @divTrunc(@as(i32, @intCast(nav_btn_size)) - @as(i32, @intCast(ny_w)), 2), head_y + 17, 11, if (next_y_hover) self.cfg.theme.accent else self.cfg.theme.text_muted);
        try self.hit_areas.append(self.allocator, .{
            .x = next_y_x,
            .y = head_y,
            .w = nav_btn_size,
            .h = nav_btn_size,
            .action = .next_year,
        });

        // Center Title: "October 2026"
        var title_buf: [48]u8 = undefined;
        const title_str = std.fmt.bufPrint(&title_buf, "{s} {d}", .{ monthName(self.view_month), self.view_year }) catch "Calendar";
        const title_w = target.measureTextWithSize(&self.font, title_str, 13);
        const title_x = @divTrunc(@as(i32, @intCast(w)) - @as(i32, @intCast(title_w)), 2);
        const title_hover = self.isAreaHovered(title_x - 4, head_y, title_w + 8, nav_btn_size);
        target.drawTextWithSize(&self.font, title_str, title_x, head_y + 17, 13, if (title_hover) self.cfg.theme.accent else self.cfg.theme.text_bright);
        try self.hit_areas.append(self.allocator, .{
            .x = title_x - 4,
            .y = head_y,
            .w = title_w + 8,
            .h = nav_btn_size,
            .action = .jump_today,
        });

        // Separator
        const sep_y = head_y + 32;
        target.fillSquircle(pad_x, sep_y, content_w, 1, 1, self.cfg.theme.panel_border);

        // 2. Weekdays Header
        const weekdays = [_][]const u8{ "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" };
        const col_w: u32 = content_w / 7;
        const grid_start_y: i32 = sep_y + 8;

        for (weekdays, 0..) |day_name, col| {
            const cx = pad_x + @as(i32, @intCast(col * col_w));
            const dw = target.measureTextWithSize(&self.font, day_name, 10);
            const dx = cx + @divTrunc(@as(i32, @intCast(col_w)) - @as(i32, @intCast(dw)), 2);
            target.drawTextWithSize(&self.font, day_name, dx, grid_start_y + 13, 10, self.cfg.theme.text_muted);
        }

        // 3. Days Grid
        const start_dow = firstDayOfWeek(self.view_year, self.view_month);
        const total_days = daysInMonth(self.view_year, self.view_month);

        const prev_m = if (self.view_month == 1) 12 else self.view_month - 1;
        const prev_y = if (self.view_month == 1) self.view_year - 1 else self.view_year;
        const prev_total_days = daysInMonth(prev_y, prev_m);

        const cell_h: u32 = 28;
        const days_start_y = grid_start_y + 18;

        var cell_idx: u32 = 0;

        // Leading days from previous month
        var p_day = prev_total_days - start_dow + 1;
        while (cell_idx < start_dow) : (cell_idx += 1) {
            const col = cell_idx % 7;
            const row = cell_idx / 7;
            const cx = pad_x + @as(i32, @intCast(col * col_w));
            const cy = days_start_y + @as(i32, @intCast(row * cell_h));

            var num_buf: [8]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{p_day}) catch "";
            const nw = target.measureTextWithSize(&self.font, num_str, 11);
            const nx = cx + @divTrunc(@as(i32, @intCast(col_w)) - @as(i32, @intCast(nw)), 2);
            target.drawTextWithSize(&self.font, num_str, nx, cy + 19, 11, self.cfg.theme.text_muted);

            p_day += 1;
        }

        // Days of current month
        var cur_d: u32 = 1;
        while (cur_d <= total_days) : (cur_d += 1) {
            const col = cell_idx % 7;
            const row = cell_idx / 7;
            const cx = pad_x + @as(i32, @intCast(col * col_w));
            const cy = days_start_y + @as(i32, @intCast(row * cell_h));

            const is_today = (self.view_year == self.today_year and self.view_month == self.today_month and cur_d == self.today_day);
            const is_hover = self.isAreaHovered(cx + 2, cy + 1, col_w - 4, cell_h - 2);

            if (is_today) {
                target.drawSoftShadow(cx + 2, cy + 2, col_w - 4, cell_h - 2, 6, 3, 25);
                target.fillSquircle(cx + 2, cy + 1, col_w - 4, cell_h - 2, 6, self.cfg.theme.accent);
            } else if (is_hover) {
                target.fillSquircle(cx + 2, cy + 1, col_w - 4, cell_h - 2, 6, self.cfg.theme.elevated);
                target.drawSquircleBorder(cx + 2, cy + 1, col_w - 4, cell_h - 2, 6, 1, self.cfg.theme.border);
            }

            var num_buf: [8]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{cur_d}) catch "";
            const nw = target.measureTextWithSize(&self.font, num_str, 11);
            const nx = cx + @divTrunc(@as(i32, @intCast(col_w)) - @as(i32, @intCast(nw)), 2);

            const num_color = if (is_today)
                self.cfg.theme.accent_fg
            else if (is_hover)
                self.cfg.theme.accent
            else
                self.cfg.theme.text_main;

            target.drawTextWithSize(&self.font, num_str, nx, cy + 19, 11, num_color);

            cell_idx += 1;
        }

        // Trailing days from next month to fill grid
        var next_d: u32 = 1;
        while (cell_idx < 42) : (cell_idx += 1) {
            const col = cell_idx % 7;
            const row = cell_idx / 7;
            const cx = pad_x + @as(i32, @intCast(col * col_w));
            const cy = days_start_y + @as(i32, @intCast(row * cell_h));

            var num_buf: [8]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{next_d}) catch "";
            const nw = target.measureTextWithSize(&self.font, num_str, 11);
            const nx = cx + @divTrunc(@as(i32, @intCast(col_w)) - @as(i32, @intCast(nw)), 2);
            target.drawTextWithSize(&self.font, num_str, nx, cy + 19, 11, self.cfg.theme.text_muted);

            next_d += 1;
        }

        // 4. Footer shortcuts bar (Noctalia-inspired)
        const foot_sep_y = @as(i32, @intCast(h)) - 25;
        target.fillSquircle(pad_x, foot_sep_y, content_w, 1, 1, self.cfg.theme.border);

        const foot_y = @as(i32, @intCast(h)) - 9;
        const foot_text = "T Today  •  ←→ Month  •  Esc Close";
        const fw = target.measureTextWithSize(&self.font, foot_text, 10);
        const fx = @divTrunc(@as(i32, @intCast(w)) - @as(i32, @intCast(fw)), 2);
        target.drawTextWithSize(&self.font, foot_text, fx, foot_y, 10, self.cfg.theme.text_muted);
    }
};

test "Calendar date calculations" {
    // 2026 is not a leap year, 2024 was
    try std.testing.expect(!Calendar.isLeapYear(2026));
    try std.testing.expect(Calendar.isLeapYear(2024));
    try std.testing.expectEqual(@as(u32, 28), Calendar.daysInMonth(2026, 2));
    try std.testing.expectEqual(@as(u32, 29), Calendar.daysInMonth(2024, 2));
    try std.testing.expectEqual(@as(u32, 31), Calendar.daysInMonth(2026, 10));

    // October 1, 2026: October has 31 days
    // Test month navigation
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
        .hit_areas = std.ArrayList(CalendarHitArea).empty,
    };
    defer cal.hit_areas.deinit(allocator);

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
