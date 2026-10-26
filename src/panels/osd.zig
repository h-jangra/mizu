const std = @import("std");
const c = @import("../c.zig").c;
const theme = @import("../core/theme.zig");
const config = @import("../core/config.zig");
const renderer = @import("../core/renderer.zig");
const icons = @import("../graphics/icons.zig");
const sys_status = @import("../services/system_status.zig");
const ui_mod = @import("../core/ui.zig");

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
        const font = try renderer.Font.init(allocator, cfg.theme.font_family, cfg.typography.ui);

        const w: u32 = switch (kind) {
            .volume, .brightness => 260,
            .media => 320,
            .notification => 400,
        };

        const h: u32 = switch (kind) {
            .volume, .brightness => 52,
            .media => 56,
            .notification => 88,
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

    pub fn tick(self: *Osd) bool {
        if (theme.loadSavedTheme()) |saved| {
            if (saved != self.cfg.theme.kind) {
                self.cfg.theme = saved.toTheme();
                return true;
            }
        }
        return false;
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

    pub fn render(self: *Osd, target: renderer.Renderer, scale: u32) !void {
        target.clear(theme.Color.transparent);

        const w = target.width;
        const h = target.height;
        const radius: u32 = 14 * scale;

        // The card itself is laid out by Clay; only the soft shadow is direct.
        target.drawDropShadow(0, 0, w, h, radius, 8 * scale, self.cfg.theme.shadow_dark);

        var ui = try ui_mod.Ui.begin(
            self.allocator,
            &self.font,
            w,
            h,
            scale,
            -1,
            -1,
            false,
            1.0 / 60.0,
        );
        defer ui.deinit();

        const shell_padding = switch (self.kind) {
            .volume, .brightness => ui_mod.Edges{ .left = ui.su(16), .right = ui.su(16) },
            .media => ui_mod.Edges{ .left = ui.su(12), .right = ui.su(12) },
            .notification => ui_mod.Edges{ .left = ui.su(20), .right = ui.su(20), .top = ui.su(12), .bottom = ui.su(12) },
        };
        const shell_gap = switch (self.kind) {
            .volume, .brightness => ui.su(14),
            .media => ui.su(10),
            .notification => ui.su(4),
        };
        const direction: ui_mod.Direction = if (self.kind == .notification) .column else .row;
        const align_y: ui_mod.AlignY = switch (self.kind) {
            .notification => .center,
            else => .center,
        };
        const align_x: ui_mod.AlignX = switch (self.kind) {
            .notification => .left,
            else => .left,
        };

        ui.root(.{
            .direction = direction,
            .padding = shell_padding,
            .gap = shell_gap,
            .bg = self.cfg.theme.panel_bg,
            .radius = ui.f(14),
            .border = ui.su(1),
            .border_color = self.cfg.theme.panel_border,
            .align_x = align_x,
            .align_y = align_y,
        });

        switch (self.kind) {
            .volume, .brightness => {
                const icon_name = if (self.kind == .volume)
                    (if (self.is_muted) "volume-muted" else if (self.percent >= 67) "volume-high" else if (self.percent >= 34) "volume-medium" else "volume-low")
                else
                    (if (self.percent < 25) "moon" else if (self.percent >= 75) "sun-filled" else "sun");
                const icon_fg = if (self.is_muted) self.cfg.theme.text_muted else self.cfg.theme.accent;

                ui.icon(icon_name, self.cfg.typography.bar_icon * scale, icon_fg, 0);

                _ = ui.open(.{
                    .width = .{ .fixed = ui.s(144) },
                    .height = .{ .fixed = ui.s(8) },
                    .bg = self.cfg.theme.slider_track,
                    .radius = ui.f(4),
                    .border = ui.su(1),
                    .border_color = self.cfg.theme.border,
                });
                const pct = @min(100, self.percent);
                if (!self.is_muted and pct > 0) {
                    ui.rect(.{ .percent = @as(f32, @floatFromInt(pct)) / 100.0 }, .{ .grow = .{} }, self.cfg.theme.accent, ui.f(4), .{});
                }
                ui.close();

                var text_buf: [32]u8 = undefined;
                const label_str = if (self.is_muted) "Muted" else std.fmt.bufPrint(&text_buf, "{d}%", .{pct}) catch "";
                ui.text(label_str, .{
                    .size = self.cfg.typography.ui * scale,
                    .color = self.cfg.theme.text_bright,
                });
                ui.spacerSized(.{ .grow = .{} }, .{ .fixed = 0 });
            },
            .media => {
                _ = ui.open(.{
                    .width = .{ .fixed = ui.s(32) },
                    .height = .{ .fixed = ui.s(32) },
                    .bg = self.cfg.theme.surface,
                    .radius = ui.f(8),
                    .border = ui.su(1),
                    .border_color = self.cfg.theme.border,
                    .align_x = .center,
                    .align_y = .center,
                });
                ui.icon("music", self.cfg.typography.bar_icon * scale, self.cfg.theme.accent, 0);
                ui.close();

                _ = ui.open(.{
                    .width = .{ .grow = .{} },
                    .height = .{ .grow = .{} },
                    .direction = .column,
                    .gap = ui.su(2),
                    .align_y = .center,
                });

                const title_str = if (self.title_len > 0) self.title[0..self.title_len] else "No Media";
                var trunc_buf: [128]u8 = undefined;
                const max_w = w -| (12 + 32 + 10 + 12) * scale;
                const trunc_title = renderer.truncateText(&self.font, title_str, max_w, self.cfg.typography.ui * scale, &trunc_buf);
                ui.text(trunc_title, .{
                    .size = self.cfg.typography.ui * scale,
                    .color = self.cfg.theme.text_bright,
                });

                const sub_str = if (self.subtitle_len > 0) self.subtitle[0..self.subtitle_len] else "";
                var trunc_sub_buf: [128]u8 = undefined;
                const trunc_sub = renderer.truncateText(&self.font, sub_str, max_w, self.cfg.typography.secondary * scale, &trunc_sub_buf);
                if (trunc_sub.len > 0) {
                    ui.text(trunc_sub, .{
                        .size = self.cfg.typography.secondary * scale,
                        .color = self.cfg.theme.text_muted,
                    });
                }
                ui.close();
            },
            .notification => {
                const title_str = if (self.title_len > 0) self.title[0..self.title_len] else "Notification";
                const sub_str = if (self.subtitle_len > 0) self.subtitle[0..self.subtitle_len] else "";
                const title_size = self.cfg.typography.title * scale;
                const body_size = self.cfg.typography.secondary * scale;
                const max_text_w = w -| 40 * scale;

                var t_buf: [128]u8 = undefined;
                const trunc_t = renderer.truncateText(&self.font, title_str, max_text_w, title_size, &t_buf);
                ui.text(trunc_t, .{
                    .size = title_size,
                    .color = self.cfg.theme.text_bright,
                });

                if (sub_str.len > 0) {
                    var s_buf: [128]u8 = undefined;
                    const trunc_s = renderer.truncateText(&self.font, sub_str, max_text_w, body_size, &s_buf);
                    ui.text(trunc_s, .{
                        .size = body_size,
                        .color = self.cfg.theme.text_muted,
                    });
                }
            },
        }

        ui.close(); // root
        const commands = ui.endLayout();
        ui.render(target, commands);
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
    try std.testing.expectEqual(@as(u32, 400), osd_notif.width);
    try std.testing.expectEqual(@as(u32, 88), osd_notif.height);

    var trunc_buf: [16]u8 = undefined;
    const trunc = renderer.truncateText(&osd_notif.font, "a notification body that is much too long", 60, 13, &trunc_buf);
    try std.testing.expect(trunc.len > 3);
    try std.testing.expect(trunc.len <= trunc_buf.len);
    try std.testing.expect(std.mem.endsWith(u8, trunc, "..."));
}
