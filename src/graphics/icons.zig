const std = @import("std");
const renderer = @import("../core/renderer.zig");
const theme = @import("../core/theme.zig");
const c = @import("c");

/// Nerd Font glyphs kept only as fallback symbols for assets that have no SVG
/// equivalent. These are not used as primary icons anymore.
pub const glyphs = struct {
    pub const chevron_right = "";
    pub const chevron_left = "";
    pub const chevron_up = "";
    pub const chevron_down = "";
    pub const power = "";
    pub const lock = "";
    pub const close = "󰅖";
    pub const check = "";
    pub const calendar = "󰸗";
    pub const screen = "󰄄";
    pub const memory = "󰍛";
    pub const cpu = "󰘚";
    pub const palette = "󰏘";
    pub const search = "\u{f002}";
    pub const filter = "\u{f0b0}";
    pub const bluetooth_off = "󰂲";
};

/// Vector-drawn native icons kept as crisp fallbacks when an SVG asset is
/// unavailable.
pub const IconKind = enum {
    wifi_full,
    wifi_medium,
    wifi_low,
    wifi_off,
    volume_high,
    volume_medium,
    volume_low,
    volume_muted,
    brightness,
    battery,
    bluetooth,
    bell,
    bell_dnd,
    chevron_left,
    chevron_right,
    chevron_up,
    chevron_down,
    close,
    power,
    lock,
    moon,
    record,
    trash,
    refresh,
};

pub fn drawIcon(target: renderer.Renderer, kind: IconKind, x: i32, y: i32, size: u32, color: theme.Color) void {
    switch (kind) {
        .wifi_full => drawWifi(target, x, y, size, 3, color),
        .wifi_medium => drawWifi(target, x, y, size, 2, color),
        .wifi_low => drawWifi(target, x, y, size, 1, color),
        .wifi_off => drawWifi(target, x, y, size, 0, color),
        .volume_high => drawVolume(target, x, y, size, 100, false, color),
        .volume_medium => drawVolume(target, x, y, size, 50, false, color),
        .volume_low => drawVolume(target, x, y, size, 20, false, color),
        .volume_muted => drawVolume(target, x, y, size, 0, true, color),
        .brightness => drawBrightness(target, x, y, size, color),
        .battery => drawBattery(target, x, y, size, size * 2 / 3, 100, false, color),
        .bluetooth => drawBluetooth(target, x, y, size, color),
        .bell => drawBell(target, x, y, size, false, color),
        .bell_dnd => drawBell(target, x, y, size, true, color),
        .chevron_left => drawChevron(target, x, y, size, .left, color),
        .chevron_right => drawChevron(target, x, y, size, .right, color),
        .chevron_up => drawChevron(target, x, y, size, .up, color),
        .chevron_down => drawChevron(target, x, y, size, .down, color),
        .close => drawClose(target, x, y, size, color),
        .power => drawPower(target, x, y, size, color),
        .lock => drawLock(target, x, y, size, color),
        .moon => drawMoon(target, x, y, size, color),
        .record => drawRecord(target, x, y, size, color),
        .trash => drawTrash(target, x, y, size, color),
        .refresh => {},
    }
}

// Vector icon primitives (crisp native fallbacks)
pub fn drawLine(
    target: renderer.Renderer,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    stroke_width: f32,
    color: theme.Color,
) void {
    if (color.a == 0 or stroke_width <= 0) return;
    const pad = stroke_width + 1.0;
    const min_x: i32 = @intFromFloat(@max(0.0, @min(x0, x1) - pad));
    const max_x: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(target.width)), @max(x0, x1) + pad));
    const min_y: i32 = @intFromFloat(@max(0.0, @min(y0, y1) - pad));
    const max_y: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(target.height)), @max(y0, y1) + pad));
    const dx = x1 - x0;
    const dy = y1 - y0;
    const len_sq = dx * dx + dy * dy;
    const half_w = stroke_width / 2.0;
    var cy = min_y;
    while (cy < max_y) : (cy += 1) {
        const py = @as(f32, @floatFromInt(cy)) + 0.5;
        var cx = min_x;
        while (cx < max_x) : (cx += 1) {
            const px = @as(f32, @floatFromInt(cx)) + 0.5;
            const t = if (len_sq > 0.0001)
                std.math.clamp(((px - x0) * dx + (py - y0) * dy) / len_sq, 0.0, 1.0)
            else
                0.0;
            const proj_x = x0 + t * dx;
            const proj_y = y0 + t * dy;
            const dist = std.math.hypot(px - proj_x, py - proj_y);
            if (dist <= half_w - 0.5) {
                target.setPixel(cx, cy, color);
            } else if (dist <= half_w + 0.5) {
                const cov = std.math.clamp(0.5 + half_w - dist, 0.0, 1.0);
                target.setPixelCoverage(cx, cy, color, @as(u8, @intFromFloat(cov * 255.0)));
            }
        }
    }
}

pub fn drawArc(
    target: renderer.Renderer,
    cx: f32,
    cy: f32,
    radius: f32,
    start_rad: f32,
    end_rad: f32,
    stroke_width: f32,
    color: theme.Color,
) void {
    if (color.a == 0 or stroke_width <= 0 or radius <= 0) return;
    const pad = radius + stroke_width + 1.0;
    const min_x: i32 = @intFromFloat(@max(0.0, cx - pad));
    const max_x: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(target.width)), cx + pad));
    const min_y: i32 = @intFromFloat(@max(0.0, cy - pad));
    const max_y: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(target.height)), cy + pad));
    const half_w = stroke_width / 2.0;
    const pi = std.math.pi;
    const two_pi = 2.0 * pi;
    var norm_start = start_rad;
    var norm_end = end_rad;
    while (norm_start < 0.0) : (norm_start += two_pi) {}
    while (norm_end < norm_start) : (norm_end += two_pi) {}
    var y = min_y;
    while (y < max_y) : (y += 1) {
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        const dy = py - cy;
        var x = min_x;
        while (x < max_x) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const dx = px - cx;
            const dist = std.math.hypot(dx, dy);
            const r_diff = @abs(dist - radius);
            if (r_diff > half_w + 0.5) continue;
            var angle = std.math.atan2(dy, dx);
            while (angle < 0.0) : (angle += two_pi) {}
            if (angle < norm_start and angle + two_pi <= norm_end) {
                angle += two_pi;
            }
            if (angle >= norm_start and angle <= norm_end) {
                if (r_diff <= half_w - 0.5) {
                    target.setPixel(x, y, color);
                } else {
                    const cov = std.math.clamp(0.5 + half_w - r_diff, 0.0, 1.0);
                    target.setPixelCoverage(x, y, color, @as(u8, @intFromFloat(cov * 255.0)));
                }
            }
        }
    }
}

pub fn drawWifi(target: renderer.Renderer, x: i32, y: i32, size: u32, level: u8, color: theme.Color) void {
    const s = @as(f32, @floatFromInt(size));
    const cx = @as(f32, @floatFromInt(x)) + s / 2.0;
    const base_y = @as(f32, @floatFromInt(y)) + s * 0.85;
    target.fillCircle(cx, base_y - s * 0.08, s * 0.09, color);
    if (level == 0) {
        const off_col = theme.Color.init(180, color.r, color.g, color.b);
        drawLine(target, cx - s * 0.35, base_y - s * 0.75, cx + s * 0.35, base_y, 1.8, off_col);
        return;
    }
    const stroke = @max(1.5, s * 0.11);
    const start_rad = -std.math.pi * 0.75;
    const end_rad = -std.math.pi * 0.25;
    drawArc(target, cx, base_y, s * 0.28, start_rad, end_rad, stroke, color);
    if (level >= 2) drawArc(target, cx, base_y, s * 0.48, start_rad, end_rad, stroke, color);
    if (level >= 3) drawArc(target, cx, base_y, s * 0.68, start_rad, end_rad, stroke, color);
}

pub fn drawVolume(target: renderer.Renderer, x: i32, y: i32, size: u32, percent: u32, muted: bool, color: theme.Color) void {
    const s = @as(f32, @floatFromInt(size));
    const ox = @as(f32, @floatFromInt(x));
    const oy = @as(f32, @floatFromInt(y));
    const body_x = ox + s * 0.14;
    const body_y = oy + s * 0.35;
    const body_w = s * 0.20;
    const body_h = s * 0.30;
    target.fillSquircle(@intFromFloat(body_x), @intFromFloat(body_y), @intFromFloat(body_w), @intFromFloat(body_h), 2, color);
    const flare_x0 = body_x + body_w;
    const flare_y0 = body_y;
    const flare_x1 = ox + s * 0.52;
    const flare_y_top = oy + s * 0.18;
    const flare_y_bot = oy + s * 0.82;
    drawLine(target, flare_x0, flare_y0, flare_x1, flare_y_top, 2.0, color);
    drawLine(target, flare_x0, flare_y0 + body_h, flare_x1, flare_y_bot, 2.0, color);
    drawLine(target, flare_x1, flare_y_top, flare_x1, flare_y_bot, 2.0, color);
    var fill_x = flare_x0;
    while (fill_x <= flare_x1) : (fill_x += 1.0) {
        const factor = (fill_x - flare_x0) / (flare_x1 - flare_x0);
        const top = flare_y0 - factor * (flare_y0 - flare_y_top);
        const bot = (flare_y0 + body_h) + factor * (flare_y_bot - (flare_y0 + body_h));
        drawLine(target, fill_x, top, fill_x, bot, 1.2, color);
    }
    if (muted) {
        const mute_col = theme.Color.rgb(0xEF, 0x53, 0x50);
        drawLine(target, ox + s * 0.62, oy + s * 0.32, ox + s * 0.88, oy + s * 0.68, 2.0, mute_col);
        drawLine(target, ox + s * 0.88, oy + s * 0.32, ox + s * 0.62, oy + s * 0.68, 2.0, mute_col);
    } else {
        const stroke = @max(1.4, s * 0.10);
        const arc_cx = ox + s * 0.42;
        const arc_cy = oy + s * 0.50;
        const start_rad = -std.math.pi * 0.30;
        const end_rad = std.math.pi * 0.30;
        if (percent > 0) drawArc(target, arc_cx, arc_cy, s * 0.22, start_rad, end_rad, stroke, color);
        if (percent >= 35) drawArc(target, arc_cx, arc_cy, s * 0.38, start_rad, end_rad, stroke, color);
        if (percent >= 70) drawArc(target, arc_cx, arc_cy, s * 0.54, start_rad, end_rad, stroke, color);
    }
}

pub fn drawBrightness(target: renderer.Renderer, x: i32, y: i32, size: u32, color: theme.Color) void {
    const s = @as(f32, @floatFromInt(size));
    const cx = @as(f32, @floatFromInt(x)) + s / 2.0;
    const cy = @as(f32, @floatFromInt(y)) + s / 2.0;
    const r = s * 0.22;
    target.fillCircle(cx, cy, r, color);
    const stroke = @max(1.6, s * 0.10);
    const r_inner = s * 0.34;
    const r_outer = s * 0.47;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const angle = @as(f32, @floatFromInt(i)) * (std.math.pi / 4.0);
        const cos = @cos(angle);
        const sin = @sin(angle);
        drawLine(target, cx + r_inner * cos, cy + r_inner * sin, cx + r_outer * cos, cy + r_outer * sin, stroke, color);
    }
}

pub fn drawBattery(
    target: renderer.Renderer,
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    percent: u8,
    is_charging: bool,
    color: theme.Color,
) void {
    const fw = @as(f32, @floatFromInt(w));
    const fh = @as(f32, @floatFromInt(h));
    const body_w = @as(u32, @intFromFloat(fw * 0.86));
    const body_h = h;
    const body_radius: u32 = 3;
    const nipple_w = @max(2, @as(u32, @intFromFloat(fw * 0.10)));
    const nipple_h = @max(4, @as(u32, @intFromFloat(fh * 0.45)));
    const nipple_x = x + @as(i32, @intCast(body_w));
    const nipple_y = y + @as(i32, @intCast((body_h - nipple_h) / 2));
    const nipple_radius: u32 = 1;
    target.drawRoundedBorder(x, y, body_w, body_h, body_radius, 1, color);
    target.fillRoundedRect(nipple_x, nipple_y, nipple_w, nipple_h, nipple_radius, color);
    const pad: u32 = 2;
    if (body_w > pad * 2 + 1 and body_h > pad * 2) {
        const max_fill_w = body_w - pad * 2;
        const inner_h = body_h - pad * 2;
        const clamped_pct: u32 = @min(100, percent);
        const fill_w = (max_fill_w * clamped_pct) / 100;
        const fill_color = if (is_charging)
            theme.Color.rgb(0x4C, 0xAF, 0x50)
        else if (clamped_pct <= 20)
            theme.Color.rgb(0xEF, 0x44, 0x44)
        else if (clamped_pct <= 35)
            theme.Color.rgb(0xF5, 0x9E, 0x0B)
        else
            color;
        if (fill_w > 0) {
            const inner_r: u32 = if (fill_w >= 4) 2 else 1;
            target.fillRoundedRect(
                x + @as(i32, @intCast(pad)),
                y + @as(i32, @intCast(pad)),
                fill_w,
                inner_h,
                inner_r,
                fill_color,
            );
        }
    }
    if (is_charging) {
        const cx = @as(f32, @floatFromInt(x)) + @as(f32, @floatFromInt(body_w)) / 2.0;
        const cy = @as(f32, @floatFromInt(y)) + fh / 2.0;
        const bolt_fg = theme.Color.rgb(255, 255, 255);
        const bolt_shadow = theme.Color.init(160, 0, 0, 0);
        drawLine(target, cx + 1.2, cy - fh * 0.38 + 0.5, cx - 1.2, cy + 0.2 + 0.5, 1.4, bolt_shadow);
        drawLine(target, cx - 1.2, cy + 0.2 + 0.5, cx + 1.6, cy - 0.2 + 0.5, 1.4, bolt_shadow);
        drawLine(target, cx + 1.6, cy - 0.2 + 0.5, cx - 1.0, cy + fh * 0.38 + 0.5, 1.4, bolt_shadow);
        drawLine(target, cx + 1.2, cy - fh * 0.38, cx - 1.2, cy + 0.2, 1.4, bolt_fg);
        drawLine(target, cx - 1.2, cy + 0.2, cx + 1.6, cy - 0.2, 1.4, bolt_fg);
        drawLine(target, cx + 1.6, cy - 0.2, cx - 1.0, cy + fh * 0.38, 1.4, bolt_fg);
    }
}

pub fn drawBluetooth(target: renderer.Renderer, x: i32, y: i32, size: u32, color: theme.Color) void {
    const s = @as(f32, @floatFromInt(size));
    const cx = @as(f32, @floatFromInt(x)) + s / 2.0;
    const top_y = @as(f32, @floatFromInt(y)) + s * 0.15;
    const bot_y = @as(f32, @floatFromInt(y)) + s * 0.85;
    const mid_y = (top_y + bot_y) / 2.0;
    const right_x = cx + s * 0.25;
    const left_x = cx - s * 0.22;
    const stroke = @max(1.6, s * 0.11);
    drawLine(target, cx, top_y, cx, bot_y, stroke, color);
    drawLine(target, left_x, mid_y + s * 0.18, right_x, top_y + s * 0.18, stroke, color);
    drawLine(target, right_x, top_y + s * 0.18, cx, mid_y, stroke, color);
    drawLine(target, cx, mid_y, right_x, bot_y - s * 0.18, stroke, color);
    drawLine(target, right_x, bot_y - s * 0.18, left_x, mid_y - s * 0.18, stroke, color);
}

pub fn drawBell(target: renderer.Renderer, x: i32, y: i32, size: u32, is_dnd: bool, color: theme.Color) void {
    const s = @as(f32, @floatFromInt(size));
    const cx = @as(f32, @floatFromInt(x)) + s / 2.0;
    const oy = @as(f32, @floatFromInt(y));
    const stroke = @max(1.5, s * 0.10);
    const dome_top = oy + s * 0.20;
    const skirt_y = oy + s * 0.72;
    const skirt_left = cx - s * 0.32;
    const skirt_right = cx + s * 0.32;
    target.fillCircle(cx, dome_top - s * 0.05, s * 0.06, color);
    drawLine(target, cx - s * 0.20, dome_top + s * 0.15, cx, dome_top, stroke, color);
    drawLine(target, cx, dome_top, cx + s * 0.20, dome_top + s * 0.15, stroke, color);
    drawLine(target, cx - s * 0.20, dome_top + s * 0.15, skirt_left, skirt_y, stroke, color);
    drawLine(target, cx + s * 0.20, dome_top + s * 0.15, skirt_right, skirt_y, stroke, color);
    drawLine(target, skirt_left - s * 0.05, skirt_y, skirt_right + s * 0.05, skirt_y, stroke, color);
    target.fillCircle(cx, skirt_y + s * 0.08, s * 0.07, color);
    if (is_dnd) {
        const slash_col = theme.Color.rgb(0xEF, 0x53, 0x50);
        drawLine(target, cx - s * 0.38, oy + s * 0.15, cx + s * 0.38, oy + s * 0.85, 2.0, slash_col);
    }
}

pub fn drawChevron(target: renderer.Renderer, x: i32, y: i32, size: u32, direction: enum { left, right, up, down }, color: theme.Color) void {
    const s = @as(f32, @floatFromInt(size));
    const cx = @as(f32, @floatFromInt(x)) + s / 2.0;
    const cy = @as(f32, @floatFromInt(y)) + s / 2.0;
    const stroke = @max(1.6, s * 0.12);
    const d = s * 0.24;
    switch (direction) {
        .left => {
            drawLine(target, cx + d * 0.7, cy - d, cx - d * 0.7, cy, stroke, color);
            drawLine(target, cx - d * 0.7, cy, cx + d * 0.7, cy + d, stroke, color);
        },
        .right => {
            drawLine(target, cx - d * 0.7, cy - d, cx + d * 0.7, cy, stroke, color);
            drawLine(target, cx + d * 0.7, cy, cx - d * 0.7, cy + d, stroke, color);
        },
        .up => {
            drawLine(target, cx - d, cy + d * 0.7, cx, cy - d * 0.7, stroke, color);
            drawLine(target, cx, cy - d * 0.7, cx + d, cy + d * 0.7, stroke, color);
        },
        .down => {
            drawLine(target, cx - d, cy - d * 0.7, cx, cy + d * 0.7, stroke, color);
            drawLine(target, cx, cy + d * 0.7, cx + d, cy - d * 0.7, stroke, color);
        },
    }
}

pub fn drawClose(target: renderer.Renderer, x: i32, y: i32, size: u32, color: theme.Color) void {
    const s = @as(f32, @floatFromInt(size));
    const cx = @as(f32, @floatFromInt(x)) + s / 2.0;
    const cy = @as(f32, @floatFromInt(y)) + s / 2.0;
    const d = s * 0.28;
    const stroke = @max(1.5, s * 0.12);
    drawLine(target, cx - d, cy - d, cx + d, cy + d, stroke, color);
    drawLine(target, cx + d, cy - d, cx - d, cy + d, stroke, color);
}

pub fn drawPower(target: renderer.Renderer, x: i32, y: i32, size: u32, color: theme.Color) void {
    const s = @as(f32, @floatFromInt(size));
    const cx = @as(f32, @floatFromInt(x)) + s / 2.0;
    const cy = @as(f32, @floatFromInt(y)) + s / 2.0;
    const r = s * 0.32;
    const stroke = @max(1.6, s * 0.11);
    drawArc(target, cx, cy, r, -std.math.pi * 0.30, std.math.pi * 1.30, stroke, color);
    drawLine(target, cx, cy - s * 0.38, cx, cy - s * 0.05, stroke, color);
}

pub fn drawLock(target: renderer.Renderer, x: i32, y: i32, size: u32, color: theme.Color) void {
    const s = @as(f32, @floatFromInt(size));
    const cx = @as(f32, @floatFromInt(x)) + s / 2.0;
    const oy = @as(f32, @floatFromInt(y));
    const stroke = @max(1.5, s * 0.11);
    const shackle_r = s * 0.18;
    const shackle_cy = oy + s * 0.38;
    drawArc(target, cx, shackle_cy, shackle_r, -std.math.pi, 0.0, stroke, color);
    drawLine(target, cx - shackle_r, shackle_cy, cx - shackle_r, oy + s * 0.48, stroke, color);
    drawLine(target, cx + shackle_r, shackle_cy, cx + shackle_r, oy + s * 0.48, stroke, color);
    const body_w = s * 0.54;
    const body_h = s * 0.40;
    const body_x = cx - body_w / 2.0;
    const body_y = oy + s * 0.46;
    target.fillSquircle(@intFromFloat(body_x), @intFromFloat(body_y), @intFromFloat(body_w), @intFromFloat(body_h), 3, color);
    const hole_col = theme.Color.rgb(0x18, 0x1A, 0x1F);
    target.fillCircle(cx, body_y + body_h * 0.45, 1.4, hole_col);
    drawLine(target, cx, body_y + body_h * 0.45, cx, body_y + body_h * 0.70, 1.2, hole_col);
}

pub fn drawMoon(target: renderer.Renderer, x: i32, y: i32, size: u32, color: theme.Color) void {
    const s = @as(f32, @floatFromInt(size));
    const cx = @as(f32, @floatFromInt(x)) + s / 2.0;
    const cy = @as(f32, @floatFromInt(y)) + s / 2.0;
    const r = s * 0.32;
    target.fillCircle(cx, cy, r, color);
    const cut_cx = cx + r * 0.45;
    const cut_cy = cy - r * 0.20;
    const cut_r = r * 0.85;
    const min_x: i32 = @intFromFloat(@max(0.0, cx - r - 1.0));
    const max_x: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(target.width)), cx + r + 2.0));
    const min_y: i32 = @intFromFloat(@max(0.0, cy - r - 1.0));
    const max_y: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(target.height)), cy + r + 2.0));
    var py_i = min_y;
    while (py_i < max_y) : (py_i += 1) {
        const py = @as(f32, @floatFromInt(py_i)) + 0.5;
        var px_i = min_x;
        while (px_i < max_x) : (px_i += 1) {
            const px = @as(f32, @floatFromInt(px_i)) + 0.5;
            const dist_cut = std.math.hypot(px - cut_cx, py - cut_cy);
            if (dist_cut <= cut_r) {
                const idx = @as(usize, @intCast(py_i)) * (@as(usize, target.stride) / 4) + @as(usize, @intCast(px_i));
                target.pixels[idx] = 0;
            }
        }
    }
}

pub fn drawRecord(target: renderer.Renderer, x: i32, y: i32, size: u32, color: theme.Color) void {
    const s = @as(f32, @floatFromInt(size));
    const cx = @as(f32, @floatFromInt(x)) + s / 2.0;
    const cy = @as(f32, @floatFromInt(y)) + s / 2.0;
    target.fillCircle(cx, cy, s * 0.40, color);
}

pub fn drawTrash(target: renderer.Renderer, x: i32, y: i32, size: u32, color: theme.Color) void {
    const s = @as(f32, @floatFromInt(size));
    const cx = @as(f32, @floatFromInt(x)) + s / 2.0;
    const cy = @as(f32, @floatFromInt(y)) + s / 2.0;
    target.fillCircle(cx, cy, s * 0.35, color);
}

// NanoSVG icon rasterizer
/// Rasterized alpha icon tinted with foreground color at draw time.
pub const RasterIcon = struct {
    width: u32,
    height: u32,
    stride: u32,
    pixels: []u8,
    allocator: std.mem.Allocator,
    asset: []u8,
    size_px: u32,
    scale: u32,
    is_argb: bool = false,

    pub fn deinit(self: *RasterIcon) void {
        if (self.pixels.len > 0) self.allocator.free(self.pixels);
        if (self.asset.len > 0) self.allocator.free(self.asset);
        self.pixels = self.pixels[0..0];
        self.asset = self.asset[0..0];
        self.width = 0;
        self.height = 0;
        self.stride = 0;
    }
};

// Bounded cache for on-demand rasterized icons.
const icon_allocator = std.heap.c_allocator;
const max_cached_icons = 64;
const max_icon_name = 48;

var g_active_theme_name: [64]u8 = undefined;
var g_active_theme_name_len: usize = 0;
var g_active_theme_palette_set: bool = false;
var g_palette_accent: theme.Color = theme.Color.hex(0x88C0D0);
var g_palette_text: theme.Color = theme.Color.hex(0xECEFF4);
var g_palette_base: theme.Color = theme.Color.hex(0x2E3440);
var g_palette_surface: theme.Color = theme.Color.hex(0x3B4252);
var g_palette_secondary: theme.Color = theme.Color.hex(0x81A1C1);
var g_palette_error: theme.Color = theme.Color.hex(0xBF616A);
var g_palette_warning: theme.Color = theme.Color.hex(0xEBCB8B);
var g_palette_success: theme.Color = theme.Color.hex(0xA3BE8C);

pub fn setActiveTheme(name: []const u8, th: theme.Theme) void {
    const copy_len = @min(name.len, g_active_theme_name.len);
    @memcpy(g_active_theme_name[0..copy_len], name[0..copy_len]);
    g_active_theme_name_len = copy_len;
    g_active_theme_palette_set = true;
    g_palette_accent = th.accent;
    g_palette_text = th.text_main;
    g_palette_base = th.base;
    g_palette_surface = th.surface;
    g_palette_secondary = th.secondary;
    g_palette_error = th.error_color;
    g_palette_warning = th.warning_color;
    g_palette_success = th.success_color;
    clearCache();
}

pub fn clearCache() void {
    for (&g_cache) |*entry| {
        if (entry.used) {
            if (entry.icon) |*ic| ic.deinit();
            entry.used = false;
            entry.icon = null;
        }
    }
    g_cache_seq = 0;
}

const CacheEntry = struct {
    used: bool = false,
    name: [max_icon_name]u8 = @splat(0),
    name_len: u8 = 0,
    size_px: u32 = 0,
    scale: u32 = 0,
    last_used: u64 = 0,
    icon: ?RasterIcon = null,
};

var g_cache: [max_cached_icons]CacheEntry = @splat(CacheEntry{});
var g_cache_seq: u64 = 0;

fn fileExists(path: []const u8) bool {
    if (path.len == 0 or path.len >= 512) return false;
    var buf: [512]u8 = undefined;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return c.access(&buf, c.F_OK) == 0;
}

fn pathFor(buf: []u8, dir: []const u8, name: []const u8) ?[]const u8 {
    if (dir.len == 0) return null;
    if (std.mem.endsWith(u8, name, ".svg")) {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, name }) catch null;
    }
    return std.fmt.bufPrint(buf, "{s}/{s}.svg", .{ dir, name }) catch null;
}

fn existingPath(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ?[]u8 {
    var buf: [512]u8 = undefined;
    const path = pathFor(&buf, dir, name) orelse return null;
    if (!fileExists(path)) return null;
    return allocator.dupe(u8, path) catch null;
}

fn tryDir(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ?[]u8 {
    return existingPath(allocator, dir, name);
}

fn tryDirWithAliases(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ?[]u8 {
    if (tryDir(allocator, dir, name)) |p| return p;

    // Common freedesktop and Mizu icon aliases
    if (std.mem.eql(u8, name, "trash")) {
        if (tryDir(allocator, dir, "user-trash")) |p| return p;
        if (tryDir(allocator, dir, "user-trash-full")) |p| return p;
    } else if (std.mem.eql(u8, name, "power")) {
        if (tryDir(allocator, dir, "shutdown")) |p| return p;
        if (tryDir(allocator, dir, "system-shutdown")) |p| return p;
    } else if (std.mem.eql(u8, name, "restart")) {
        if (tryDir(allocator, dir, "system-reboot")) |p| return p;
    } else if (std.mem.eql(u8, name, "home")) {
        if (tryDir(allocator, dir, "user-home")) |p| return p;
        if (tryDir(allocator, dir, "folder-home")) |p| return p;
    } else if (std.mem.eql(u8, name, "search")) {
        if (tryDir(allocator, dir, "edit-find")) |p| return p;
    } else if (std.mem.eql(u8, name, "spinner")) {
        if (tryDir(allocator, dir, "process-working")) |p| return p;
    } else if (std.mem.eql(u8, name, "folder")) {
        if (tryDir(allocator, dir, "folder-blue")) |p| return p;
    }
    return null;
}

fn exeDir(buf: []u8) ?[]const u8 {
    const n = c.readlink("/proc/self/exe", buf.ptr, buf.len - 1);
    if (n <= 0) return null;
    const len: usize = @intCast(n);
    const path = buf[0..@min(len, buf.len - 1)];
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    return path[0..slash];
}

fn tryRelative(allocator: std.mem.Allocator, base: []const u8, suffix: []const u8, name: []const u8) ?[]u8 {
    var buf: [512]u8 = undefined;
    const dir = std.fmt.bufPrint(&buf, "{s}/{s}", .{ base, suffix }) catch return null;
    return tryDirWithAliases(allocator, dir, name);
}

fn tryIconTheme(allocator: std.mem.Allocator, base_dir: []const u8, name: []const u8) ?[]u8 {
    const subdirs = [_][]const u8{
        "64x64/places",
        "64x64/apps",
        "64x64/devices",
        "64x64/mimetypes",
        "symbolic/actions",
        "symbolic/apps",
        "symbolic/status",
        "symbolic/places",
        "symbolic/devices",
    };
    for (subdirs) |sub| {
        var buf: [512]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "{s}/{s}", .{ base_dir, sub })) |dir| {
            if (tryDirWithAliases(allocator, dir, name)) |path| return path;
        } else |_| {}
    }
    return null;
}

/// Resolve an SVG asset path for `name` (caller frees).
pub fn resolveIconPath(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    if (c.getenv("MIZU_ICON_DIR")) |raw| {
        const dir = std.mem.span(raw);
        if (tryDirWithAliases(allocator, dir, name)) |path| return path;
    }

    // 1. Check themes/icons directly
    if (tryIconTheme(allocator, "themes/icons", name)) |path| return path;
    if (tryIconTheme(allocator, "../themes/icons", name)) |path| return path;

    // 2. Check active user theme icon folder: ~/.config/mizu/themes/<active_theme>/icons/
    if (g_active_theme_name_len > 0) {
        const active_theme = g_active_theme_name[0..g_active_theme_name_len];
        var user_dir_buf: [512]u8 = undefined;
        if (theme.getUserThemesDir(&user_dir_buf)) |ub| {
            var path_buf: [512]u8 = undefined;
            if (std.fmt.bufPrint(&path_buf, "{s}/{s}/icons", .{ ub, active_theme })) |theme_icons_dir| {
                if (tryDirWithAliases(allocator, theme_icons_dir, name)) |path| return path;
            } else |_| {}
        }

        // 3. Check active built-in theme icon folder: /usr/share/mizu/themes/<active_theme>/icons/
        var builtin_dir_buf: [512]u8 = undefined;
        if (theme.resolveBuiltinThemesDir(&builtin_dir_buf)) |bb| {
            var path_buf: [512]u8 = undefined;
            if (std.fmt.bufPrint(&path_buf, "{s}/{s}/icons", .{ bb, active_theme })) |theme_icons_dir| {
                if (tryDirWithAliases(allocator, theme_icons_dir, name)) |path| return path;
            } else |_| {}
        }
    }

    // 4. Fallback to standard asset search directories
    if (tryDirWithAliases(allocator, "assets", name)) |path| return path;

    var exe_buf: [4096]u8 = undefined;
    if (exeDir(&exe_buf)) |base| {
        var pbuf: [512]u8 = undefined;
        if (std.fmt.bufPrint(&pbuf, "{s}/../share/mizu/themes/icons", .{base})) |p| {
            if (tryIconTheme(allocator, p, name)) |path| return path;
        } else |_| {}
        if (tryRelative(allocator, base, "assets", name)) |path| return path;
        if (tryRelative(allocator, base, "../assets", name)) |path| return path;
        if (tryRelative(allocator, base, "../../assets", name)) |path| return path;
        if (tryRelative(allocator, base, "../../../assets", name)) |path| return path;
        if (tryRelative(allocator, base, "../share/mizu/assets", name)) |path| return path;
        if (tryRelative(allocator, base, "../../share/mizu/assets", name)) |path| return path;
    }

    if (c.getenv("XDG_DATA_HOME")) |raw| {
        const xdg = std.mem.span(raw);
        var dir_buf: [512]u8 = undefined;
        if (std.fmt.bufPrint(&dir_buf, "{s}/mizu/assets", .{xdg})) |dir| {
            if (tryDirWithAliases(allocator, dir, name)) |path| return path;
        } else |_| {}
    }
    if (c.getenv("HOME")) |raw| {
        const home = std.mem.span(raw);
        var dir_buf: [512]u8 = undefined;
        if (std.fmt.bufPrint(&dir_buf, "{s}/.local/share/icons/Papirus-Custom", .{home})) |dir| {
            if (tryIconTheme(allocator, dir, name)) |path| return path;
        } else |_| {}
        if (std.fmt.bufPrint(&dir_buf, "{s}/.icons/Papirus-Custom", .{home})) |dir| {
            if (tryIconTheme(allocator, dir, name)) |path| return path;
        } else |_| {}
        if (std.fmt.bufPrint(&dir_buf, "{s}/.local/share/mizu/assets", .{home})) |dir| {
            if (tryDirWithAliases(allocator, dir, name)) |path| return path;
        } else |_| {}
    }
    if (tryIconTheme(allocator, "/usr/share/mizu/themes/icons", name)) |path| return path;
    if (tryIconTheme(allocator, "/usr/local/share/mizu/themes/icons", name)) |path| return path;
    if (tryIconTheme(allocator, "/usr/share/icons/Papirus-Custom", name)) |path| return path;
    if (tryIconTheme(allocator, "/usr/local/share/icons/Papirus-Custom", name)) |path| return path;
    if (tryDirWithAliases(allocator, "/usr/local/share/mizu/assets", name)) |path| return path;
    if (tryDirWithAliases(allocator, "/usr/share/mizu/assets", name)) |path| return path;

    // Not found: return the default location so callers get a consistent path
    // (parsing will fail and the caller falls back gracefully).
    if (std.mem.endsWith(u8, name, ".svg")) {
        return try std.fmt.allocPrint(allocator, "assets/{s}", .{name});
    }
    return try std.fmt.allocPrint(allocator, "assets/{s}.svg", .{name});
}

fn isMultiColor(image: *c.NSVGimage) bool {
    var shape = image.shapes;
    var first_color: ?u32 = null;
    while (shape != null) : (shape = shape.*.next) {
        if ((shape.*.flags & c.NSVG_FLAGS_VISIBLE) == 0) continue;
        if (shape.*.fill.type == c.NSVG_PAINT_LINEAR_GRADIENT or shape.*.fill.type == c.NSVG_PAINT_RADIAL_GRADIENT) {
            return true;
        }
        if (shape.*.stroke.type == c.NSVG_PAINT_LINEAR_GRADIENT or shape.*.stroke.type == c.NSVG_PAINT_RADIAL_GRADIENT) {
            return true;
        }
        if (shape.*.fill.type == c.NSVG_PAINT_COLOR) {
            const col = shape.*.fill.unnamed_0.color;
            if (((col >> 24) & 0xFF) > 0) {
                if (first_color) |fc| {
                    if (fc != col) return true;
                } else {
                    first_color = col;
                }
            }
        }
        if (shape.*.stroke.type == c.NSVG_PAINT_COLOR) {
            const col = shape.*.stroke.unnamed_0.color;
            if (((col >> 24) & 0xFF) > 0 and shape.*.strokeWidth > 0.0) {
                if (first_color) |fc| {
                    if (fc != col) return true;
                } else {
                    first_color = col;
                }
            }
        }
    }
    return false;
}

pub fn recolorSvg(allocator: std.mem.Allocator, svg_bytes: []const u8) ![]u8 {
    if (!g_active_theme_palette_set) {
        return try allocator.dupe(u8, svg_bytes);
    }

    var b_acc: [8]u8 = undefined;
    var b_txt: [8]u8 = undefined;
    var b_base: [8]u8 = undefined;
    var b_surf: [8]u8 = undefined;
    var b_sec: [8]u8 = undefined;
    var b_err: [8]u8 = undefined;
    var b_warn: [8]u8 = undefined;
    var b_succ: [8]u8 = undefined;

    const acc_hex = g_palette_accent.formatHexRgb(&b_acc);
    const txt_hex = g_palette_text.formatHexRgb(&b_txt);
    const base_hex = g_palette_base.formatHexRgb(&b_base);
    const surf_hex = g_palette_surface.formatHexRgb(&b_surf);
    const sec_hex = g_palette_secondary.formatHexRgb(&b_sec);
    const err_hex = g_palette_error.formatHexRgb(&b_err);
    const warn_hex = g_palette_warning.formatHexRgb(&b_warn);
    const succ_hex = g_palette_success.formatHexRgb(&b_succ);

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < svg_bytes.len) {
        if (std.mem.startsWith(u8, svg_bytes[i..], "var(--mizu-accent)")) {
            try result.appendSlice(allocator, acc_hex);
            i += "var(--mizu-accent)".len;
        } else if (std.mem.startsWith(u8, svg_bytes[i..], "var(--mizu-text)")) {
            try result.appendSlice(allocator, txt_hex);
            i += "var(--mizu-text)".len;
        } else if (std.mem.startsWith(u8, svg_bytes[i..], "var(--mizu-base)")) {
            try result.appendSlice(allocator, base_hex);
            i += "var(--mizu-base)".len;
        } else if (std.mem.startsWith(u8, svg_bytes[i..], "var(--mizu-surface)")) {
            try result.appendSlice(allocator, surf_hex);
            i += "var(--mizu-surface)".len;
        } else if (std.mem.startsWith(u8, svg_bytes[i..], "var(--mizu-secondary)")) {
            try result.appendSlice(allocator, sec_hex);
            i += "var(--mizu-secondary)".len;
        } else if (std.mem.startsWith(u8, svg_bytes[i..], "var(--mizu-error)")) {
            try result.appendSlice(allocator, err_hex);
            i += "var(--mizu-error)".len;
        } else if (std.mem.startsWith(u8, svg_bytes[i..], "var(--mizu-warning)")) {
            try result.appendSlice(allocator, warn_hex);
            i += "var(--mizu-warning)".len;
        } else if (std.mem.startsWith(u8, svg_bytes[i..], "var(--mizu-success)")) {
            try result.appendSlice(allocator, succ_hex);
            i += "var(--mizu-success)".len;
        } else if (std.mem.startsWith(u8, svg_bytes[i..], ".ColorScheme-Text")) {
            try result.appendSlice(allocator, ".ColorScheme-Text { color:");
            try result.appendSlice(allocator, txt_hex);
            try result.appendSlice(allocator, "; }");
            const close_brace = std.mem.indexOfScalar(u8, svg_bytes[i..], '}');
            if (close_brace) |cb| {
                i += cb + 1;
            } else {
                i += ".ColorScheme-Text".len;
            }
        } else if (std.mem.startsWith(u8, svg_bytes[i..], ".ColorScheme-Highlight")) {
            try result.appendSlice(allocator, ".ColorScheme-Highlight { color:");
            try result.appendSlice(allocator, acc_hex);
            try result.appendSlice(allocator, "; }");
            const close_brace = std.mem.indexOfScalar(u8, svg_bytes[i..], '}');
            if (close_brace) |cb| {
                i += cb + 1;
            } else {
                i += ".ColorScheme-Highlight".len;
            }
        } else if (std.mem.startsWith(u8, svg_bytes[i..], ".ColorScheme-Background")) {
            try result.appendSlice(allocator, ".ColorScheme-Background { color:");
            try result.appendSlice(allocator, base_hex);
            try result.appendSlice(allocator, "; }");
            const close_brace = std.mem.indexOfScalar(u8, svg_bytes[i..], '}');
            if (close_brace) |cb| {
                i += cb + 1;
            } else {
                i += ".ColorScheme-Background".len;
            }
        } else {
            try result.append(allocator, svg_bytes[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Load and rasterize an SVG asset at the given physical size.
pub fn loadSvgIcon(allocator: std.mem.Allocator, name: []const u8, size_px: u32, scale: u32) ?RasterIcon {
    if (size_px == 0) return null;
    const path = resolveIconPath(allocator, name) catch return null;
    defer allocator.free(path);

    const c_path = allocator.alloc(u8, path.len + 1) catch return null;
    defer allocator.free(c_path);
    @memcpy(c_path[0..path.len], path);
    c_path[path.len] = 0;

    const fp = c.fopen(c_path.ptr, "rb") orelse return null;
    defer _ = c.fclose(fp);
    _ = c.fseek(fp, 0, c.SEEK_END);
    const sz = c.ftell(fp);
    _ = c.fseek(fp, 0, c.SEEK_SET);
    if (sz <= 0 or sz > 2 * 1024 * 1024) return null;

    const file_bytes = allocator.alloc(u8, @intCast(sz)) catch return null;
    defer allocator.free(file_bytes);
    const rd = c.fread(file_bytes.ptr, 1, file_bytes.len, fp);
    if (rd != file_bytes.len) return null;

    const recolored = recolorSvg(allocator, file_bytes) catch return null;
    defer allocator.free(recolored);

    const recolored_z = allocator.alloc(u8, recolored.len + 1) catch return null;
    defer allocator.free(recolored_z);
    @memcpy(recolored_z[0..recolored.len], recolored);
    recolored_z[recolored.len] = 0;

    const phys_w = size_px;
    const phys_h = size_px;

    const image = c.nsvgParse(recolored_z.ptr, "px", 96.0) orelse return null;
    defer c.nsvgDelete(image);

    if (image.*.width <= 0 or image.*.height <= 0) return null;

    const rast = c.nsvgCreateRasterizer() orelse return null;
    defer c.nsvgDeleteRasterizer(rast);

    // Center the icon within the physical cell, preserving aspect ratio.
    const scale_x = @as(f32, @floatFromInt(phys_w)) / image.*.width;
    const scale_y = @as(f32, @floatFromInt(phys_h)) / image.*.height;
    const use_scale = @min(scale_x, scale_y);
    const dx = (@as(f32, @floatFromInt(phys_w)) - image.*.width * use_scale) / 2.0;
    const dy = (@as(f32, @floatFromInt(phys_h)) - image.*.height * use_scale) / 2.0;

    const is_argb = isMultiColor(image);
    var pixels: []u8 = undefined;
    var stride: u32 = undefined;

    if (is_argb) {
        stride = phys_w; // pixels per row
        const total_bytes = @as(usize, stride) * @as(usize, phys_h) * 4;
        pixels = allocator.alloc(u8, total_bytes) catch return null;
        @memset(pixels, 0);

        if (c.nsvgRasterizeArgb(rast, @ptrCast(@alignCast(pixels.ptr)), @intCast(phys_w), @intCast(phys_h), @intCast(stride), image, dx, dy, use_scale) != 0) {
            allocator.free(pixels);
            return null;
        }
    } else {
        stride = phys_w; // bytes per row
        const total_bytes = @as(usize, stride) * @as(usize, phys_h);
        pixels = allocator.alloc(u8, total_bytes) catch return null;
        @memset(pixels, 0);

        if (c.nsvgRasterize(rast, pixels.ptr, @intCast(phys_w), @intCast(phys_h), @intCast(stride), image, dx, dy, use_scale) != 0) {
            allocator.free(pixels);
            return null;
        }
    }

    const key_asset = allocator.dupe(u8, name) catch {
        allocator.free(pixels);
        return null;
    };

    return RasterIcon{
        .width = phys_w,
        .height = phys_h,
        .stride = stride,
        .pixels = pixels,
        .allocator = allocator,
        .asset = key_asset,
        .size_px = size_px,
        .scale = scale,
        .is_argb = is_argb,
    };
}

fn findCached(name: []const u8, size_px: u32, scale: u32) ?*RasterIcon {
    for (&g_cache) |*entry| {
        if (!entry.used) continue;
        if (entry.size_px != size_px or entry.scale != scale) continue;
        const name_len: usize = entry.name_len;
        if (name_len != name.len) continue;
        if (!std.mem.eql(u8, entry.name[0..name_len], name)) continue;
        g_cache_seq +%= 1;
        entry.last_used = g_cache_seq;
        if (entry.icon) |*icon| return icon;
    }
    return null;
}

fn storeCached(name: []const u8, size_px: u32, scale: u32, icon: RasterIcon) *RasterIcon {
    var target: ?*CacheEntry = null;
    var oldest: u64 = std.math.maxInt(u64);
    for (&g_cache) |*entry| {
        if (!entry.used) {
            target = entry;
            break;
        }
        if (entry.last_used < oldest) {
            oldest = entry.last_used;
            target = entry;
        }
    }
    const entry = target orelse unreachable;

    if (entry.icon) |*old| old.deinit();
    entry.used = true;
    entry.name_len = @intCast(@min(name.len, max_icon_name));
    const name_len: usize = entry.name_len;
    @memcpy(entry.name[0..name_len], name[0..name_len]);
    entry.size_px = size_px;
    entry.scale = scale;
    g_cache_seq +%= 1;
    entry.last_used = g_cache_seq;
    entry.icon = icon;
    return &entry.icon.?;
}

/// Get a rasterized icon, loading it on demand. The returned pointer is
/// borrowed from the bounded icon cache; do not deinit it.
pub fn getIcon(allocator: std.mem.Allocator, name: []const u8, size_px: u32, scale: u32) ?*RasterIcon {
    _ = allocator;
    if (name.len > max_icon_name) return null;
    if (findCached(name, size_px, scale)) |icon| return icon;
    const icon = loadSvgIcon(icon_allocator, name, size_px, scale) orelse return null;
    return storeCached(name, size_px, scale, icon);
}

/// Draw a rasterized SVG icon centered at (cx, cy), tinted with `color`.
pub fn drawIconRaster(target: renderer.Renderer, icon: *const RasterIcon, cx: i32, cy: i32, color: theme.Color) void {
    if (icon.pixels.len == 0) return;
    const dx = cx - @as(i32, @intCast(icon.width / 2));
    const dy = cy - @as(i32, @intCast(icon.height / 2));
    if (icon.is_argb) {
        const u32_ptr: [*]const u32 = @ptrCast(@alignCast(icon.pixels.ptr));
        const num_pixels = @as(usize, icon.stride) * @as(usize, icon.height);
        target.drawIconArgb(icon.width, icon.height, icon.stride, u32_ptr[0..num_pixels], dx, dy);
    } else {
        target.drawIconAlpha(icon.width, icon.height, icon.stride, icon.pixels, dx, dy, color);
    }
}

/// Draw a rasterized SVG icon at top-left (x, y), tinted with `color`.
pub fn drawIconRasterAt(target: renderer.Renderer, icon: *const RasterIcon, x: i32, y: i32, color: theme.Color) void {
    if (icon.pixels.len == 0) return;
    if (icon.is_argb) {
        const u32_ptr: [*]const u32 = @ptrCast(@alignCast(icon.pixels.ptr));
        const num_pixels = @as(usize, icon.stride) * @as(usize, icon.height);
        target.drawIconArgb(icon.width, icon.height, icon.stride, u32_ptr[0..num_pixels], x, y);
    } else {
        target.drawIconAlpha(icon.width, icon.height, icon.stride, icon.pixels, x, y, color);
    }
}

/// Draw an SVG icon centered at (cx, cy). `size_px` is the physical pixel
/// size (callers already multiply by the display scale).
pub fn drawSvgIcon(
    target: renderer.Renderer,
    allocator: std.mem.Allocator,
    name: []const u8,
    size_px: u32,
    scale: u32,
    cx: i32,
    cy: i32,
    color: theme.Color,
) void {
    const icon = getIcon(allocator, name, size_px, scale) orelse return;
    drawIconRaster(target, icon, cx, cy, color);
}

/// Draw rasterized SVG icon centered at (cx, cy) with rotation.
pub fn drawIconRasterRotated(
    target: renderer.Renderer,
    icon: *const RasterIcon,
    cx: i32,
    cy: i32,
    angle: f32,
    color: theme.Color,
) void {
    if (icon.pixels.len == 0) return;
    const w = icon.width;
    const h = icon.height;
    const stride = icon.stride;
    const cos_a = @cos(angle);
    const sin_a = @sin(angle);
    const half_w = @as(f32, @floatFromInt(w)) / 2.0;
    const half_h = @as(f32, @floatFromInt(h)) / 2.0;

    // Compute bounding box of rotated icon
    const corners = [4][2]f32{
        .{ -half_w, -half_h },
        .{ half_w, -half_h },
        .{ half_w, half_h },
        .{ -half_w, half_h },
    };
    var min_x: f32 = corners[0][0] * cos_a - corners[0][1] * sin_a;
    var max_x: f32 = min_x;
    var min_y: f32 = corners[0][0] * sin_a + corners[0][1] * cos_a;
    var max_y: f32 = min_y;
    for (corners) |corner| {
        const rx = corner[0] * cos_a - corner[1] * sin_a;
        const ry = corner[0] * sin_a + corner[1] * cos_a;
        min_x = @min(min_x, rx);
        max_x = @max(max_x, rx);
        min_y = @min(min_y, ry);
        max_y = @max(max_y, ry);
    }
    const bb_w = @as(u32, @intFromFloat(@ceil(max_x - min_x)));
    const bb_h = @as(u32, @intFromFloat(@ceil(max_y - min_y)));
    if (bb_w == 0 or bb_h == 0) return;

    const start_x = cx - @as(i32, @intCast(bb_w / 2));
    const start_y = cy - @as(i32, @intCast(bb_h / 2));

    const inv_cos = cos_a;
    const inv_sin = -sin_a;

    var dy: u32 = 0;
    while (dy < bb_h) : (dy += 1) {
        const py = @as(f32, @floatFromInt(dy)) + 0.5 - @as(f32, @floatFromInt(bb_h)) / 2.0;
        var dx: u32 = 0;
        while (dx < bb_w) : (dx += 1) {
            const px = @as(f32, @floatFromInt(dx)) + 0.5 - @as(f32, @floatFromInt(bb_w)) / 2.0;
            // Inverse rotation
            const src_x = px * inv_cos - py * inv_sin;
            const src_y = px * inv_sin + py * inv_cos;
            // Check bounds
            if (src_x < -half_w or src_x >= half_w or src_y < -half_h or src_y >= half_h) continue;
            const sx = @as(u32, @intFromFloat(src_x + half_w));
            const sy = @as(u32, @intFromFloat(src_y + half_h));
            if (sx >= w or sy >= h) continue;

            if (icon.is_argb) {
                const u32_ptr: [*]const u32 = @ptrCast(@alignCast(icon.pixels.ptr));
                const pix = u32_ptr[sy * stride + sx];
                const sa = @as(u8, @truncate((pix >> 24) & 0xFF));
                if (sa == 0) continue;
                const sr = @as(u8, @truncate((pix >> 16) & 0xFF));
                const sg = @as(u8, @truncate((pix >> 8) & 0xFF));
                const sb = @as(u8, @truncate(pix & 0xFF));
                const dst_x = start_x + @as(i32, @intCast(dx));
                const dst_y = start_y + @as(i32, @intCast(dy));
                if (dst_x < 0 or @as(u32, @intCast(dst_x)) >= target.width or dst_y < 0 or @as(u32, @intCast(dst_y)) >= target.height) continue;
                const idx = @as(usize, @intCast(dst_y)) * (@as(usize, target.stride) / 4) + @as(usize, @intCast(dst_x));
                target.pixels[idx] = blendOver(target.pixels[idx], theme.Color.init(sa, sr, sg, sb));
                continue;
            }

            const cov = icon.pixels[sy * stride + sx];
            if (cov == 0) continue;
            var col = color;
            col.a = @intCast((@as(u32, cov) * @as(u32, color.a)) / 255);
            const dst_x = start_x + @as(i32, @intCast(dx));
            const dst_y = start_y + @as(i32, @intCast(dy));
            if (dst_x < 0 or @as(u32, @intCast(dst_x)) >= target.width or dst_y < 0 or @as(u32, @intCast(dst_y)) >= target.height) continue;
            const idx = @as(usize, @intCast(dst_y)) * (@as(usize, target.stride) / 4) + @as(usize, @intCast(dst_x));
            target.pixels[idx] = blendOver(target.pixels[idx], col);
        }
    }
}

/// blendOver helper for icon rotation (copied from renderer)
fn div255(v: u32) u32 {
    return (v * 257 + 32896) >> 16;
}

fn blendOver(dst_pixel: u32, src: theme.Color) u32 {
    if (src.a == 0) return dst_pixel;
    if (src.a == 255) {
        return (@as(u32, 255) << 24) |
            (@as(u32, src.r) << 16) |
            (@as(u32, src.g) << 8) |
            @as(u32, src.b);
    }

    const da: u32 = (dst_pixel >> 24) & 0xFF;
    const dr: u32 = (dst_pixel >> 16) & 0xFF;
    const dg: u32 = (dst_pixel >> 8) & 0xFF;
    const db: u32 = dst_pixel & 0xFF;

    const sa: u32 = src.a;
    const inv_sa: u32 = 255 - sa;

    const out_a = sa + div255(da * inv_sa);
    const out_r = div255(@as(u32, src.r) * sa + dr * inv_sa);
    const out_g = div255(@as(u32, src.g) * sa + dg * inv_sa);
    const out_b = div255(@as(u32, src.b) * sa + db * inv_sa);

    const a_val: u32 = @min(255, out_a);
    const r_val: u32 = @min(255, out_r);
    const g_val: u32 = @min(255, out_g);
    const b_val: u32 = @min(255, out_b);

    return (a_val << 24) | (r_val << 16) | (g_val << 8) | b_val;
}

// Unit tests
test "getIcon returns null for missing asset" {
    const allocator = std.testing.allocator;
    const icon = getIcon(allocator, "does-not-exist-icon", 24, 1);
    try std.testing.expect(icon == null);
}

test "SVG assets rasterize to visible alpha and are cached" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{ "wifi-high", "bell", "volume", "palette", "power", "lock", "moon" };
    for (names) |name| {
        const icon = getIcon(allocator, name, 24, 1) orelse {
            std.debug.print("failed to load SVG asset: {s}\n", .{name});
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqual(@as(u32, 24), icon.width);
        try std.testing.expectEqual(@as(u32, 24), icon.height);
        var nonzero: usize = 0;
        for (icon.pixels) |p| {
            if (p > 0) nonzero += 1;
        }
        try std.testing.expect(nonzero > 4);

        // Repeated lookups must return the same cached raster, not reload it.
        const again = getIcon(allocator, name, 24, 1) orelse return error.TestUnexpectedResult;
        try std.testing.expect(again == icon);
    }
}

test "Automatic SVG icon recoloring with theme palette" {
    const allocator = std.testing.allocator;
    const test_th = theme.draculaTheme();
    setActiveTheme("dracula", test_th);
    defer clearCache();

    const sample_svg =
        \\<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64">
        \\  <style>.ColorScheme-Highlight { color:#123456; } .ColorScheme-Text { color:#abcdef; }</style>
        \\  <path fill="var(--mizu-accent)" d="M 0 0 L 10 10"/>
        \\  <path fill="var(--mizu-text)" d="M 10 10 L 20 20"/>
        \\</svg>
    ;

    const recolored = try recolorSvg(allocator, sample_svg);
    defer allocator.free(recolored);

    // var(--mizu-accent) should be replaced with Dracula accent #bd93f9
    try std.testing.expect(std.mem.indexOf(u8, recolored, "#bd93f9") != null);
    // var(--mizu-text) should be replaced with Dracula text #f8f8f2
    try std.testing.expect(std.mem.indexOf(u8, recolored, "#f8f8f2") != null);
}

test "Load integrated theme icons" {
    const allocator = std.testing.allocator;
    const nord_th = theme.nordTheme();
    setActiveTheme("nord", nord_th);

    // Test folder icon resolution from themes/nord/icons/
    const folder_icon = getIcon(allocator, "folder", 32, 1);
    try std.testing.expect(folder_icon != null);
    if (folder_icon) |ic| {
        try std.testing.expectEqual(@as(u32, 32), ic.width);
        try std.testing.expectEqual(@as(u32, 32), ic.height);
        try std.testing.expect(ic.pixels.len > 0);
    }

    // Switch to Dracula theme
    const drac_th = theme.draculaTheme();
    setActiveTheme("dracula", drac_th);

    // Test Dracula power icon resolution from themes/dracula/icons/
    const power_icon = getIcon(allocator, "power", 32, 1);
    try std.testing.expect(power_icon != null);
    if (power_icon) |ic| {
        try std.testing.expectEqual(@as(u32, 32), ic.width);
        try std.testing.expectEqual(@as(u32, 32), ic.height);
        try std.testing.expect(ic.pixels.len > 0);
    }
}
