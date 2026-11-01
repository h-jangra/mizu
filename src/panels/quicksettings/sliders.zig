const std = @import("std");
const config = @import("../../core/config.zig");
const renderer = @import("../../core/renderer.zig");
const sys_status = @import("../../services/system_status.zig");
const ui_mod = @import("../../core/ui.zig");
const types = @import("types.zig");

const Action = types.Action;
const QsLayout = types.QsLayout;
const SliderType = types.SliderType;

pub const State = struct {
    active: ?SliderType = null,
};

const QsSliderDraw = struct {
    sys: *sys_status.SysStatus,
    cfg: *const config.Config,
    font: *renderer.Font,
    active_slider: *const ?SliderType,
    kind: SliderType,
    hovered: bool,
    scale: u32 = 1,

    fn draw(target: renderer.Renderer, rect: renderer.Rect, data: *const anyopaque) void {
        const self: *const QsSliderDraw = @ptrCast(@alignCast(data));
        const scale = self.scale;
        const bar_h: u32 = @min(rect.h, 34 * scale);
        const bar_y: i32 = rect.y + @divTrunc(@as(i32, @intCast(rect.h - bar_h)), 2);

        const max_val: u32 = switch (self.kind) {
            .volume => 200,
            .brightness => 100,
        };
        const val: u32 = switch (self.kind) {
            .volume => self.sys.volume_percent,
            .brightness => self.sys.backlight_percent,
        };
        const pct: u32 = @min(100, (@as(u64, val) * 100) / max_val);
        const is_vol_muted = (self.kind == .volume and self.sys.volume_muted);
        const fill_col = if (is_vol_muted) self.cfg.theme.error_color else self.cfg.theme.accent;

        target.drawPillSlider(
            rect.x,
            bar_y,
            rect.w,
            bar_h,
            pct,
            self.cfg.theme.slider_track,
            fill_col,
            fill_col,
            self.cfg.theme.slider_thumb_shadow,
        );

        // Slider value tooltip (0-100 brightness, 0-200 audio).
        const font_sz: u32 = 11 * scale;
        var num_buf: [16]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{val}) catch "0";

        const text_w = self.font.measureTextWithSize(num_str, font_sz);
        const tip_pad_x: u32 = 5 * scale;
        const tip_w: u32 = text_w + tip_pad_x * 2;
        const tip_h: u32 = 32 * scale;

        const thumb_cx: f64 = @as(f64, @floatFromInt(rect.x)) + (@as(f64, @floatFromInt(rect.w)) * @as(f64, @floatFromInt(pct))) / 100.0;
        var tip_x: i32 = @as(i32, @intFromFloat(thumb_cx)) - @as(i32, @intCast(tip_w / 2));
        const max_tip_x = rect.x + @as(i32, @intCast(rect.w)) - @as(i32, @intCast(tip_w));
        if (max_tip_x >= rect.x) {
            tip_x = std.math.clamp(tip_x, rect.x, max_tip_x);
        }
        const tip_y: i32 = bar_y - @as(i32, @intCast(tip_h)) - @as(i32, @intCast(2 * scale));

        const is_active = self.hovered or (self.active_slider.* != null and self.active_slider.*.? == self.kind);
        if (!is_active) return;

        target.fillRoundedRect(tip_x, tip_y, tip_w, tip_h, tip_h / 2, self.cfg.theme.elevated);

        const baseline = tip_y + @as(i32, @intCast(tip_h / 2)) + @divTrunc(self.font.ascender_px * @as(i32, @intCast(font_sz)), @as(i32, @intCast(self.font.size_px * 2))) - @as(i32, @intCast(scale));
        target.drawTextCentered(self.font, num_str, tip_x + @as(i32, @intCast(tip_w / 2)), baseline, font_sz, self.cfg.theme.text_bright);
    }
};

pub fn updateFromPointer(panel: anytype, st: SliderType, px: i32) void {
    for (panel.hit_areas.items) |area| {
        const matches = switch (st) {
            .volume => area.action == .slider_volume,
            .brightness => area.action == .slider_brightness,
        };
        if (matches) {
            const max_val: u32 = switch (st) {
                .volume => 200,
                .brightness => 100,
            };
            const val = calculateValue(px, area.x, area.w, max_val);
            switch (st) {
                .volume => if (val != panel.sys.volume_percent) panel.sys.setVolume(val),
                .brightness => if (val != panel.sys.backlight_percent) panel.sys.setBrightness(val),
            }
            break;
        }
    }
}

pub fn calculatePercent(px: i32, start_x: i32, width: u32) u32 {
    return calculateValue(px, start_x, width, 100);
}

pub fn calculateValue(px: i32, start_x: i32, width: u32, max_val: u32) u32 {
    if (width == 0) return 0;
    if (px <= start_x) return 0;
    const rel_x = px - start_x;
    if (rel_x >= @as(i32, @intCast(width))) return max_val;
    const val = (@as(u64, @intCast(rel_x)) * max_val) / width;
    return @min(max_val, @as(u32, @intCast(val)));
}

pub fn handleAction(panel: anytype, action: Action, x: i32) bool {
    switch (action) {
        .slider_volume => {
            panel.sliders.active = .volume;
            updateFromPointer(panel, .volume, x);
            return true;
        },
        .slider_brightness => {
            panel.sliders.active = .brightness;
            updateFromPointer(panel, .brightness, x);
            return true;
        },
        else => return false,
    }
}

pub fn handleAxis(panel: anytype, x: i32, y: i32, scroll_delta: i32) bool {
    if (panel.view_mode != .main) return false;
    for (panel.hit_areas.items) |area| {
        if (x >= area.x and x < area.x + @as(i32, @intCast(area.w)) and
            y >= area.y and y < area.y + @as(i32, @intCast(area.h)))
        {
            if (area.action == .slider_volume) {
                const cur = panel.sys.volume_percent;
                const delta: i32 = if (scroll_delta < 0) 1 else -1;
                const new_vol = @as(u32, @intCast(@min(200, @max(0, @as(i32, @intCast(cur)) + delta))));
                panel.sys.setVolume(new_vol);
                return true;
            } else if (area.action == .slider_brightness) {
                const cur = panel.sys.backlight_percent;
                const delta: i32 = if (scroll_delta < 0) 1 else -1;
                const new_bl = @as(u32, @intCast(@min(100, @max(0, @as(i32, @intCast(cur)) + delta))));
                panel.sys.setBrightness(new_bl);
                return true;
            }
        }
    }
    return false;
}

pub fn release(panel: anytype) bool {
    if (panel.sliders.active != null) {
        panel.sliders.active = null;
        return true;
    }
    return false;
}

pub fn renderRow(panel: anytype, ui: *ui_mod.Ui, scale: u32) !void {
    const bri_icon_name = if (panel.sys.backlight_percent > 50) "sun-filled" else "sun";
    const bri_slider_hov = ui.hovered("qs-bri-slider", 0);
    const mute_hov = ui.hovered("qs-vol-icon", 0);
    const vol_slider_hov = ui.hovered("qs-vol-slider", 0);
    const aud_icon_name = if (panel.sys.volume_muted)
        "volume-muted"
    else if (panel.sys.volume_percent <= 33)
        "volume-low"
    else if (panel.sys.volume_percent <= 66)
        "volume-medium"
    else
        "volume-high";

    // Outer slider row — no card background
    _ = ui.open(.{
        .width = .{ .grow = .{} },
        .height = .{ .fixed = ui.s(QsLayout.slider_h) },
        .direction = .row,
        .gap = ui.su(10),
        .bg = null,
        .align_y = .center,
    });

    // Brightness icon (left)
    _ = ui.open(.{
        .id = "qs-bri-btn",
        .width = .{ .fixed = ui.s(46) },
        .height = .{ .fixed = ui.s(46) },
        .bg = panel.cfg.theme.card_bg,
        .radius = ui.f(23),
        .align_x = .center,
        .align_y = .center,
    });
    ui.icon(bri_icon_name, 20 * scale, panel.cfg.theme.text_bright, 1);
    ui.close();

    // Brightness slider (grows ~half width)
    _ = ui.open(.{
        .id = "qs-bri-slider",
        .width = .{ .grow = .{} },
        .height = .{ .fixed = ui.s(QsLayout.slider_h) },
        .align_y = .center,
    });
    const data_bri = try ui.allocator.create(QsSliderDraw);
    data_bri.* = .{
        .sys = &panel.sys,
        .cfg = &panel.cfg,
        .font = &panel.font,
        .active_slider = &panel.sliders.active,
        .kind = .brightness,
        .hovered = bri_slider_hov,
        .scale = scale,
    };
    const custom_bri = try ui.allocator.create(ui_mod.Custom);
    custom_bri.* = .{ .callback = .{ .function = QsSliderDraw.draw, .data = data_bri } };
    ui.custom(.{ .grow = .{} }, .{ .grow = .{} }, custom_bri, 0);
    ui.close();
    ui.close(); // bri slider wrapper

    // Mute button (centre separator)
    _ = ui.open(.{
        .id = "qs-vol-icon",
        .width = .{ .fixed = ui.s(46) },
        .height = .{ .fixed = ui.s(46) },
        .bg = if (mute_hov) panel.cfg.theme.card_hover_bg else panel.cfg.theme.card_bg,
        .radius = ui.f(23),
        .align_x = .center,
        .align_y = .center,
    });
    const mute_fg = if (panel.sys.volume_muted) panel.cfg.theme.error_color else if (mute_hov) panel.cfg.theme.accent else panel.cfg.theme.text_bright;
    ui.icon(aud_icon_name, 20 * scale, mute_fg, 0);
    ui.close();

    // Volume slider (grows ~half width)
    _ = ui.open(.{
        .id = "qs-vol-slider",
        .width = .{ .grow = .{} },
        .height = .{ .fixed = ui.s(QsLayout.slider_h) },
        .align_y = .center,
    });
    const data_vol = try ui.allocator.create(QsSliderDraw);
    data_vol.* = .{
        .sys = &panel.sys,
        .cfg = &panel.cfg,
        .font = &panel.font,
        .active_slider = &panel.sliders.active,
        .kind = .volume,
        .hovered = vol_slider_hov,
        .scale = scale,
    };
    const custom_vol = try ui.allocator.create(ui_mod.Custom);
    custom_vol.* = .{ .callback = .{ .function = QsSliderDraw.draw, .data = data_vol } };
    ui.custom(.{ .grow = .{} }, .{ .grow = .{} }, custom_vol, 0);
    ui.close();
    ui.close(); // vol slider wrapper

    ui.close(); // combined slider card
}

pub fn appendHitAreas(panel: anytype, ui: *ui_mod.Ui, scale: u32) !void {
    if (ui.rectOf("qs-bri-btn", 0)) |rect| try types.appendHitArea(panel, rect, scale, .open_display_menu);
    if (ui.rectOf("qs-bri-slider", 0)) |rect| try types.appendHitArea(panel, rect, scale, .slider_brightness);
    if (ui.rectOf("qs-vol-icon", 0)) |rect| try types.appendHitArea(panel, rect, scale, .open_audio_menu);
    if (ui.rectOf("qs-vol-slider", 0)) |rect| try types.appendHitArea(panel, rect, scale, .slider_volume);
}
