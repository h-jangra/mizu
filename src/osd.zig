const std = @import("std");
const c = @import("c.zig").c;
const theme = @import("theme.zig");
const config = @import("config.zig");
const renderer = @import("renderer.zig");
const sys_status = @import("sys_status.zig");

pub const OsdKind = enum {
    volume,
    brightness,
    media,
    notification,
};

pub const Osd = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    font: renderer.Font,
    kind: OsdKind,

    width: u32,
    height: u32,
    running: bool = true,

    percent: u32 = 50,
    is_muted: bool = false,

    title: [128]u8 = [_]u8{0} ** 128,
    title_len: usize = 0,

    subtitle: [128]u8 = [_]u8{0} ** 128,
    subtitle_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config, kind: OsdKind) !Osd {
        const font = try renderer.Font.init(allocator, cfg.theme.font_family, cfg.theme.font_size);

        const w: u32 = switch (kind) {
            .volume, .brightness => 260,
            .media => 320,
            .notification => 280,
        };

        const h: u32 = switch (kind) {
            .volume, .brightness => 52,
            .media => 56,
            .notification => 48,
        };

        var self = Osd{
            .allocator = allocator,
            .cfg = cfg,
            .font = font,
            .kind = kind,
            .width = w,
            .height = h,
        };

        self.updateValue();
        return self;
    }

    pub fn deinit(self: *Osd) void {
        self.font.deinit();
    }

    pub fn setTitle(self: *Osd, text: []const u8) void {
        const copy_len = @min(text.len, self.title.len);
        @memcpy(self.title[0..copy_len], text[0..copy_len]);
        self.title_len = copy_len;
    }

    pub fn setSubtitle(self: *Osd, text: []const u8) void {
        const copy_len = @min(text.len, self.subtitle.len);
        @memcpy(self.subtitle[0..copy_len], text[0..copy_len]);
        self.subtitle_len = copy_len;
    }

    pub fn updateValue(self: *Osd) void {
        switch (self.kind) {
            .volume => self.updateVolume(),
            .brightness => self.updateBrightness(),
            .media => self.updateMedia(),
            .notification => {},
        }
    }

    fn updateVolume(self: *Osd) void {
        const pipe = c.popen("wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null", "r") orelse return;
        defer _ = c.pclose(pipe);

        var buf: [64]u8 = undefined;
        const n = c.fread(&buf, 1, buf.len - 1, pipe);
        if (n == 0) return;
        buf[n] = 0;
        const s = buf[0..n];

        self.is_muted = (std.mem.indexOf(u8, s, "[MUTED]") != null);

        if (std.mem.indexOf(u8, s, "Volume:")) |idx| {
            const rem = std.mem.trim(u8, s[idx + 7 ..], " \t\r\n");
            var end_idx: usize = 0;
            while (end_idx < rem.len and (std.ascii.isDigit(rem[end_idx]) or rem[end_idx] == '.')) {
                end_idx += 1;
            }
            if (end_idx > 0) {
                const vol_float = std.fmt.parseFloat(f32, rem[0..end_idx]) catch 0.5;
                self.percent = @intFromFloat(@min(100.0, vol_float * 100.0));
            }
        }
    }

    fn updateBrightness(self: *Osd) void {
        const dir = c.opendir("/sys/class/backlight");
        if (dir == null) return;
        defer _ = c.closedir(dir);

        while (c.readdir(dir)) |entry| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

            var cur_path_buf: [128]u8 = undefined;
            const cur_path = std.fmt.bufPrintZ(&cur_path_buf, "/sys/class/backlight/{s}/brightness", .{name}) catch continue;
            const cur_f = c.fopen(cur_path.ptr, "rb") orelse continue;
            var cbuf: [64]u8 = undefined;
            const clen = c.fread(&cbuf, 1, cbuf.len - 1, cur_f);
            _ = c.fclose(cur_f);
            if (clen == 0) continue;
            cbuf[clen] = 0;
            const cur_val = std.fmt.parseInt(u32, std.mem.trim(u8, cbuf[0..clen], " \t\r\n"), 10) catch 0;

            var max_path_buf: [128]u8 = undefined;
            const max_path = std.fmt.bufPrintZ(&max_path_buf, "/sys/class/backlight/{s}/max_brightness", .{name}) catch continue;
            const max_f = c.fopen(max_path.ptr, "rb") orelse continue;
            var mbuf: [64]u8 = undefined;
            const mlen = c.fread(&mbuf, 1, mbuf.len - 1, max_f);
            _ = c.fclose(max_f);
            if (mlen == 0) continue;
            mbuf[mlen] = 0;
            const max_val = std.fmt.parseInt(u32, std.mem.trim(u8, mbuf[0..mlen], " \t\r\n"), 10) catch 0;

            if (max_val > 0) {
                self.percent = @min(100, (cur_val * 100) / max_val);
            }
            return;
        }
    }

    fn updateMedia(self: *Osd) void {
        const pipe = c.popen("playerctl metadata --format '{{status}}:::{{artist}} - {{title}}' 2>/dev/null", "r") orelse {
            self.setTitle("No Media");
            self.setSubtitle("Stopped");
            return;
        };
        defer _ = c.pclose(pipe);

        var buf: [256]u8 = undefined;
        const n = c.fread(&buf, 1, buf.len - 1, pipe);
        if (n == 0) {
            self.setTitle("No Media");
            self.setSubtitle("Stopped");
            return;
        }
        buf[n] = 0;
        const s = std.mem.trim(u8, buf[0..n], " \t\r\n");

        if (std.mem.indexOf(u8, s, ":::")) |sep| {
            const status_str = s[0..sep];
            const track_str = std.mem.trim(u8, s[sep + 3 ..], " \t-");
            self.setTitle(track_str);
            self.setSubtitle(status_str);
        } else {
            self.setTitle(s);
            self.setSubtitle("Media");
        }
    }

    pub fn handleCommand(self: *Osd, cmd: []const u8) void {
        const trimmed = std.mem.trim(u8, cmd, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "volume:")) {
            self.kind = .volume;
            const sub = trimmed[7..];
            if (std.mem.eql(u8, sub, "up")) {
                sys_status.spawnCmd("wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+");
            } else if (std.mem.eql(u8, sub, "down")) {
                sys_status.spawnCmd("wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%-");
            } else if (std.mem.eql(u8, sub, "mute")) {
                sys_status.spawnCmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle");
            } else if (std.mem.startsWith(u8, sub, "set ")) {
                var cmd_buf: [64]u8 = undefined;
                const set_cmd = std.fmt.bufPrint(&cmd_buf, "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ {s}%", .{sub[4..]}) catch "";
                if (set_cmd.len > 0) sys_status.spawnCmd(set_cmd);
            }
            // Small pause for wpctl to apply
            _ = c.usleep(20_000);
            self.updateVolume();
        } else if (std.mem.startsWith(u8, trimmed, "brightness:")) {
            self.kind = .brightness;
            const sub = trimmed[11..];
            if (std.mem.eql(u8, sub, "up")) {
                sys_status.spawnCmd("brightnessctl set 5%+");
            } else if (std.mem.eql(u8, sub, "down")) {
                sys_status.spawnCmd("brightnessctl set 5%-");
            } else if (std.mem.startsWith(u8, sub, "set ")) {
                var cmd_buf: [64]u8 = undefined;
                const set_cmd = std.fmt.bufPrint(&cmd_buf, "brightnessctl set {s}%", .{sub[4..]}) catch "";
                if (set_cmd.len > 0) sys_status.spawnCmd(set_cmd);
            }
            _ = c.usleep(20_000);
            self.updateBrightness();
        } else if (std.mem.startsWith(u8, trimmed, "media")) {
            self.kind = .media;
            self.updateMedia();
        } else if (std.mem.startsWith(u8, trimmed, "notify:")) {
            self.kind = .notification;
            const rest = trimmed[7..];
            if (std.mem.indexOf(u8, rest, ":::")) |sep| {
                self.setTitle(rest[0..sep]);
                self.setSubtitle(rest[sep + 3 ..]);
            } else {
                self.setTitle(rest);
                self.setSubtitle("");
            }
        }
    }

    pub fn render(self: *Osd, target: renderer.Renderer) !void {
        target.clear(theme.Color.transparent);

        const w = target.width;
        const h = target.height;
        const radius: u32 = 14;

        // Container card: Minimal translucent glass squircle
        target.fillGlassSquircle(0, 0, w, h, radius, self.cfg.theme.panel_bg);
        target.drawSquircleBorder(0, 0, w, h, radius, 1, self.cfg.theme.panel_border);

        switch (self.kind) {
            .volume => try self.renderGaugeOsd(target, w, h, if (self.is_muted) "󰖁" else "󰕾", self.is_muted, self.cfg.theme.accent),
            .brightness => try self.renderGaugeOsd(target, w, h, "󰃠", false, self.cfg.theme.accent),
            .media => try self.renderMediaOsd(target, w, h),
            .notification => try self.renderNotificationOsd(target, w, h),
        }
    }

    fn renderGaugeOsd(
        self: *Osd,
        target: renderer.Renderer,
        w: u32,
        h: u32,
        icon: []const u8,
        is_muted_flag: bool,
        fill_color: theme.Color,
    ) !void {
        _ = w;
        // Left Icon
        const icon_x: i32 = 16;
        const icon_baseline = @divTrunc(@as(i32, @intCast(h)) + 14, 2);
        const icon_fg = if (is_muted_flag) self.cfg.theme.text_muted else self.cfg.theme.accent;
        target.drawTextWithSize(&self.font, icon, icon_x, icon_baseline, 18, icon_fg);

        // Progress bar gauge
        const gauge_x: i32 = 46;
        const gauge_w: u32 = 144;
        const gauge_h: u32 = 8;
        const gauge_y = @divTrunc(@as(i32, @intCast(h)) - @as(i32, @intCast(gauge_h)), 2);

        // Track
        target.fillSquircle(gauge_x, gauge_y, gauge_w, gauge_h, 4, self.cfg.theme.surface);
        target.drawSquircleBorder(gauge_x, gauge_y, gauge_w, gauge_h, 4, 1, self.cfg.theme.border);

        // Fill
        const clamped_pct = @min(100, self.percent);
        const fill_w = (@as(u64, gauge_w) * clamped_pct) / 100;
        if (!is_muted_flag and fill_w > 0) {
            target.fillGlassSquircle(gauge_x, gauge_y, @intCast(fill_w), gauge_h, 4, fill_color);
        }

        // Percentage or Muted text
        var text_buf: [32]u8 = undefined;
        const label_str = if (is_muted_flag)
            "Muted"
        else
            std.fmt.bufPrint(&text_buf, "{d}%", .{clamped_pct}) catch "";

        const text_x: i32 = gauge_x + @as(i32, @intCast(gauge_w)) + 12;
        const text_baseline = @divTrunc(@as(i32, @intCast(h)) + 10, 2);
        target.drawTextWithSize(&self.font, label_str, text_x, text_baseline, 11, self.cfg.theme.text_bright);
    }

    fn renderMediaOsd(self: *Osd, target: renderer.Renderer, w: u32, h: u32) !void {
        _ = h;
        // Icon badge
        const badge_size: u32 = 32;
        const badge_x: i32 = 12;
        const badge_y: i32 = 11;
        target.fillGlassSquircle(badge_x, badge_y, badge_size, badge_size, 8, self.cfg.theme.surface);
        target.drawSquircleBorder(badge_x, badge_y, badge_size, badge_size, 8, 1, self.cfg.theme.border);
        target.drawTextWithSize(&self.font, "󰎆", badge_x + 9, badge_y + 22, 14, self.cfg.theme.accent);

        const text_x = badge_x + @as(i32, @intCast(badge_size + 10));

        // Title
        const title_str = if (self.title_len > 0) self.title[0..self.title_len] else "No Media";
        var trunc_buf: [128]u8 = undefined;
        const trunc_title = truncateText(target, &self.font, title_str, w - 60, &trunc_buf, 12);
        target.drawTextWithSize(&self.font, trunc_title, text_x, 23, 12, self.cfg.theme.text_bright);

        // Subtitle (Status / Artist)
        const sub_str = if (self.subtitle_len > 0) self.subtitle[0..self.subtitle_len] else "";
        var trunc_sub_buf: [128]u8 = undefined;
        const trunc_sub = truncateText(target, &self.font, sub_str, w - 60, &trunc_sub_buf, 10);
        target.drawTextWithSize(&self.font, trunc_sub, text_x, 41, 10, self.cfg.theme.text_muted);
    }

    fn renderNotificationOsd(self: *Osd, target: renderer.Renderer, w: u32, h: u32) !void {
        const pad_x: i32 = 16;
        const max_text_w = if (w > 32) w - 32 else w;

        const title_str = if (self.title_len > 0) self.title[0..self.title_len] else "Notification";
        const sub_str = if (self.subtitle_len > 0) self.subtitle[0..self.subtitle_len] else "";

        var t_buf: [128]u8 = undefined;
        if (sub_str.len == 0) {
            // Single-line notification: vertically centered, no extra whitespace
            const trunc_t = truncateText(target, &self.font, title_str, max_text_w, &t_buf, 12);
            const baseline = @divTrunc(@as(i32, @intCast(h)) + 9, 2);
            target.drawTextWithSize(&self.font, trunc_t, pad_x, baseline, 12, self.cfg.theme.text_bright);
        } else {
            // Two-line notification: compact layout without extra whitespace
            const trunc_t = truncateText(target, &self.font, title_str, max_text_w, &t_buf, 12);
            target.drawTextWithSize(&self.font, trunc_t, pad_x, 21, 12, self.cfg.theme.text_bright);

            var s_buf: [128]u8 = undefined;
            const trunc_s = truncateText(target, &self.font, sub_str, max_text_w, &s_buf, 10);
            target.drawTextWithSize(&self.font, trunc_s, pad_x, 37, 10, self.cfg.theme.text_muted);
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

test "Osd initialization and dimensions" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var osd_vol = try Osd.init(allocator, cfg, .volume);
    defer osd_vol.deinit();
    try std.testing.expectEqual(@as(u32, 260), osd_vol.width);
    try std.testing.expectEqual(@as(u32, 52), osd_vol.height);

    var osd_media = try Osd.init(allocator, cfg, .media);
    defer osd_media.deinit();
    try std.testing.expectEqual(@as(u32, 320), osd_media.width);
    try std.testing.expectEqual(@as(u32, 56), osd_media.height);

    var osd_notif = try Osd.init(allocator, cfg, .notification);
    defer osd_notif.deinit();
    try std.testing.expectEqual(@as(u32, 280), osd_notif.width);
    try std.testing.expectEqual(@as(u32, 48), osd_notif.height);
}
