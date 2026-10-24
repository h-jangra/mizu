const std = @import("std");
const c = @import("../c.zig").c;
const renderer = @import("../core/renderer.zig");
const theme = @import("../core/theme.zig");
const config = @import("../core/config.zig");
const animation = @import("../core/animation.zig");
const icons = @import("../graphics/icons.zig");
const sys_status = @import("../services/system_status.zig");

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
                }
                return true;
            }
        }

        // Calendar cell selection via direct coordinate mapping
        const cal_x: i32 = @as(i32, @intCast(Layout.pad)) + self.panel_slide_y;
        const grid_y: i32 = self.headerBottomY() + @as(i32, @intCast(Layout.section_gap));
        const grid_w: u32 = self.width - 2 * Layout.pad;
        const cell_w: u32 = grid_w / 7;
        const cell_h: u32 = 40 * self.cfg.typography.calendar_text / 16; // scale-aware
        const grid_h: u32 = cell_h * 6;

        if (x >= cal_x and x < cal_x + @as(i32, @intCast(grid_w)) and
            y >= grid_y and y < grid_y + @as(i32, @intCast(grid_h)))
        {
            const col = @divTrunc(x - cal_x, @as(i32, @intCast(cell_w)));
            const row = @divTrunc(y - grid_y, @as(i32, @intCast(cell_h)));
            if (col >= 0 and col < 7 and row >= 0 and row < 6) {
                const cell_idx = @as(u32, @intCast(row)) * 7 + @as(u32, @intCast(col));
                const start_dow = firstDayOfWeek(self.view_year, self.view_month);
                const total_days = daysInMonth(self.view_year, self.view_month);

                if (cell_idx < start_dow) {
                    // Previous month date
                    const prev_m = if (self.view_month == 1) 12 else self.view_month - 1;
                    const prev_y = if (self.view_month == 1) self.view_year - 1 else self.view_year;
                    const prev_total_days = daysInMonth(prev_y, prev_m);
                    const p_day = prev_total_days - start_dow + 1 + cell_idx;
                    self.selected_day = p_day;
                    self.selected_month = prev_m;
                    self.selected_year = prev_y;
                } else if (cell_idx >= start_dow + total_days) {
                    // Next month date
                    const next_d = cell_idx - start_dow - total_days + 1;
                    self.selected_day = next_d;
                    if (self.view_month == 12) {
                        self.selected_month = 1;
                        self.selected_year += 1;
                    } else {
                        self.selected_month += 1;
                    }
                    self.selected_year = self.view_year;
                } else {
                    // Current month date
                    self.selected_day = (cell_idx - start_dow + 1);
                    self.selected_month = self.view_month;
                    self.selected_year = self.view_year;
                }
                self.view_year = self.selected_year;
                self.view_month = self.selected_month;
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
        const pad = @as(i32, @intCast(Layout.pad * scale));
        const pad_u = Layout.pad * scale;
        const radius = self.cfg.theme.radius_panel * scale;

        const sec_sz = self.cfg.typography.secondary * scale;
        const head_sz = self.cfg.typography.calendar_heading * scale;
        const day_sz = self.cfg.typography.calendar_text * scale;

        // 1. Panel background
        target.clear(theme.Color.transparent);
        target.drawDropShadow(0, 0, w, h, radius, 8 * scale, self.cfg.theme.shadow_dark);
        target.fillRoundedRect(0, 0, w, h, radius, self.cfg.theme.panel_bg);
        target.drawRoundedBorder(0, 0, w, h, radius, 1 * scale, self.cfg.theme.panel_border);

        // 2. Header: prev | Month Year | next
        const head_y: i32 = pad;
        const nav_size: u32 = 28 * scale;

        const prev_hov = self.isAreaHovered(pad, head_y, nav_size, nav_size);
        target.fillSquircle(pad, head_y, nav_size, nav_size, 6 * scale,
            if (prev_hov) self.cfg.theme.card_hover_bg else self.cfg.theme.surface);
        icons.drawSvgIcon(target, self.allocator, "left", head_sz, scale,
            pad + @as(i32, @intCast(nav_size / 2)),
            head_y + @as(i32, @intCast(nav_size / 2)),
            if (prev_hov) self.cfg.theme.accent else self.cfg.theme.text_main);
        try self.hit_areas.append(self.allocator, .{
            .x = pad, .y = head_y, .w = nav_size, .h = nav_size, .action = .prev_month,
        });

        const next_btn_x = pad + @as(i32, @intCast(w - 2 * pad_u - nav_size));
        const next_hov = self.isAreaHovered(next_btn_x, head_y, nav_size, nav_size);
        target.fillSquircle(next_btn_x, head_y, nav_size, nav_size, 6 * scale,
            if (next_hov) self.cfg.theme.card_hover_bg else self.cfg.theme.surface);
        icons.drawSvgIcon(target, self.allocator, "right", head_sz, scale,
            next_btn_x + @as(i32, @intCast(nav_size / 2)),
            head_y + @as(i32, @intCast(nav_size / 2)),
            if (next_hov) self.cfg.theme.accent else self.cfg.theme.text_main);
        try self.hit_areas.append(self.allocator, .{
            .x = next_btn_x, .y = head_y, .w = nav_size, .h = nav_size, .action = .next_month,
        });

        // Month & Year title (centered, clickable -> jump to today)
        var title_buf: [48]u8 = undefined;
        const title_str = std.fmt.bufPrint(&title_buf, "{s} {d}", .{ monthName(self.view_month), self.view_year }) catch "Calendar";
        const title_w = target.measureTextWithSize(&self.font, title_str, head_sz);
        const title_x = pad + @divTrunc(@as(i32, @intCast(w - 2 * pad_u)) - @as(i32, @intCast(title_w)), 2);
        const title_hov = self.isAreaHovered(title_x - 10, head_y - 4, title_w + 20, nav_size + 8);
        target.drawTextWithSize(&self.font, title_str, title_x, head_y + @as(i32, @intCast(head_sz * 3 / 4)) + 1,
            head_sz, if (title_hov) self.cfg.theme.accent else self.cfg.theme.text_bright);
        try self.hit_areas.append(self.allocator, .{
            .x = title_x - 10, .y = head_y - 4, .w = title_w + 20, .h = nav_size + 8, .action = .jump_today,
        });

        // 3. Weekday labels
        const weekdays = [_][]const u8{ "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" };
        const grid_w: u32 = w - 2 * pad_u;
        const cell_w: u32 = grid_w / 7;
        const weekday_y: i32 = head_y + @as(i32, @intCast(nav_size)) + @as(i32, @intCast(Layout.section_gap * scale));

        for (weekdays, 0..) |day_name, col| {
            const cx = pad + @as(i32, @intCast(col * cell_w));
            const dw = target.measureTextWithSize(&self.font, day_name, sec_sz);
            const dx = cx + @divTrunc(@as(i32, @intCast(cell_w)) - @as(i32, @intCast(dw)), 2);
            target.drawTextWithSize(&self.font, day_name, dx, weekday_y + @as(i32, @intCast(sec_sz * 3 / 4)),
                sec_sz, self.cfg.theme.text_muted);
        }

        // 4. Date grid
        const start_dow = firstDayOfWeek(self.view_year, self.view_month);
        const total_days = daysInMonth(self.view_year, self.view_month);
        const grid_start_y: i32 = weekday_y + @as(i32, @intCast(sec_sz)) + @as(i32, @intCast(Layout.row_gap * scale));
        const cell_h: u32 = 40 * scale;

        var cell_idx: u32 = 0;

        // Leading days from previous month
        var p_day = if (start_dow == 0) 0 else daysInMonth(if (self.view_month == 1) self.view_year - 1 else self.view_year,
            if (self.view_month == 1) 12 else self.view_month - 1) - start_dow + 1;
        while (cell_idx < start_dow) : (cell_idx += 1) {
            const col = cell_idx % 7;
            const row = cell_idx / 7;
            const cx = pad + @as(i32, @intCast(col * cell_w));
            const cy = grid_start_y + @as(i32, @intCast(row * cell_h));

            var num_buf: [8]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{p_day}) catch "";
            const nw = target.measureTextWithSize(&self.font, num_str, day_sz);
            const nx = cx + @divTrunc(@as(i32, @intCast(cell_w)) - @as(i32, @intCast(nw)), 2);
            target.drawTextWithSize(&self.font, num_str, nx, cy + @divTrunc(@as(i32, @intCast(cell_h)) + @as(i32, @intCast(day_sz * 3 / 4)), 2),
                day_sz, self.cfg.theme.text_muted);
            p_day += 1;
        }

        // Days of current month
        var cur_d: u32 = 1;
        while (cur_d <= total_days) : (cur_d += 1) {
            const col = cell_idx % 7;
            const row = cell_idx / 7;
            const cx = pad + @as(i32, @intCast(col * cell_w));
            const cy = grid_start_y + @as(i32, @intCast(row * cell_h));

            const is_today = (self.view_year == self.today_year and self.view_month == self.today_month and cur_d == self.today_day);
            const is_selected = (self.selected_year == self.view_year and self.selected_month == self.view_month and self.selected_day == cur_d);
            const is_hover = self.isAreaHovered(cx + 2, cy + 2, cell_w - 4, cell_h - 4);

            if (is_selected) {
                // Selected: accent outline ring
                target.drawRoundedBorder(cx + 2, cy + 2, cell_w - 4, cell_h - 4, 8 * scale, 2 * scale, self.cfg.theme.accent);
            } else if (is_today) {
                // Today: filled accent circle
                const dot_r: u32 = 10 * scale;
                const today_cx = @as(f64, @floatFromInt(cx + @as(i32, @intCast(cell_w / 2))));
                const today_cy = @as(f64, @floatFromInt(cy + @as(i32, @intCast(cell_h / 2))));
                target.fillCircle(today_cx, today_cy, @as(f64, @floatFromInt(dot_r)), self.cfg.theme.accent);
            } else if (is_hover) {
                target.fillRoundedRect(cx + 2, cy + 2, cell_w - 4, cell_h - 4, 6 * scale, self.cfg.theme.card_hover_bg);
            }

            // Event indicator (holiday)
            const has_event = false;
            if (has_event and !is_today and !is_selected) {
                const dot_r: u32 = 3 * scale;
                const dot_offset = @as(i32, @intCast(dot_r + 3 * scale));
                const dot_cx = @as(f64, @floatFromInt(@as(i32, @intCast(cell_w)) + cx - dot_offset));
                const dot_cy = @as(f64, @floatFromInt(@as(i32, @intCast(cell_h)) + cy - dot_offset));
                target.fillCircle(dot_cx, dot_cy, @as(f64, @floatFromInt(dot_r)), self.cfg.theme.accent);
            }

            var num_buf: [8]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{cur_d}) catch "";
            const nw = target.measureTextWithSize(&self.font, num_str, day_sz);
            const nx = cx + @divTrunc(@as(i32, @intCast(cell_w)) - @as(i32, @intCast(nw)), 2);

            const num_color = if (is_today)
                self.cfg.theme.accent_fg
            else if (is_selected)
                self.cfg.theme.accent_fg
            else if (is_hover)
                self.cfg.theme.accent
            else
                self.cfg.theme.text_main;

            target.drawTextWithSize(&self.font, num_str, nx, cy + @divTrunc(@as(i32, @intCast(cell_h)) + @as(i32, @intCast(day_sz * 3 / 4)), 2),
                day_sz, num_color);

            cell_idx += 1;
        }

        // Trailing days from next month
        var next_d: u32 = 1;
        while (cell_idx < 42) : (cell_idx += 1) {
            const col = cell_idx % 7;
            const row = cell_idx / 7;
            const cx = pad + @as(i32, @intCast(col * cell_w));
            const cy = grid_start_y + @as(i32, @intCast(row * cell_h));

            var num_buf: [8]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{next_d}) catch "";
            const nw = target.measureTextWithSize(&self.font, num_str, day_sz);
            const nx = cx + @divTrunc(@as(i32, @intCast(cell_w)) - @as(i32, @intCast(nw)), 2);
            target.drawTextWithSize(&self.font, num_str, nx, cy + @divTrunc(@as(i32, @intCast(cell_h)) + @as(i32, @intCast(day_sz * 3 / 4)), 2),
                day_sz, self.cfg.theme.text_muted);
            next_d += 1;
        }

        // 5. Fade-in overlay for open animation
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
