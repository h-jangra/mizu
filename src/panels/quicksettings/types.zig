const std = @import("std");
const config = @import("../../core/config.zig");
const renderer = @import("../../core/renderer.zig");
const theme = @import("../../core/theme.zig");
const ui_mod = @import("../../core/ui.zig");
const sys_status = @import("../../services/system_status.zig");

/// Layout tokens for Quick Settings panels (logical pixels).
pub const QsLayout = struct {
    pub const pad: u32 = 24;
    pub const section_gap: u32 = 14;
    pub const header_h: u32 = 84;
    pub const row_h: u32 = 56;
    pub const card_h: u32 = 80;
    pub const row3_h: u32 = 72;
    pub const slider_h: u32 = 72;
    pub const row_gap: u32 = 10;
    pub const radius: u32 = 16;
};

pub const display_scales = [_]u32{ 100, 125, 150, 200 };
pub const display_refresh_rates = [_]u32{ 60, 120, 144, 165 };
pub const display_resolutions = [_][]const u8{
    "1920x1080",
    "1680x1050",
    "1440x900",
    "1280x720",
};

pub const Action = union(enum) {
    toggle_wifi,
    toggle_bluetooth,
    toggle_audio_mute,
    toggle_caffeine,
    toggle_recording,
    toggle_dnd,
    toggle_eye_comfort,
    open_wifi_menu,
    open_bluetooth_menu,
    open_audio_menu,
    open_display_menu,
    open_power_menu,
    open_clipboard,
    cycle_theme,
    open_keymap_menu,
    toggle_keymap,
    set_keymap_size: u32,
    set_keymap_pos: config.KeymapPosition,
    open_session_power_menu,
    open_notifications_menu,
    open_recording_menu,
    clear_notifications,
    dismiss_notification: usize,
    back_to_main,
    refresh_sub_menu,
    select_wifi: usize,
    select_bluetooth: usize,
    select_audio_sink: usize,
    select_audio_source: usize,
    set_audio_tab_output,
    set_audio_tab_input,
    toggle_earbud_safety,
    set_recording_mode_system,
    set_recording_mode_mic,
    set_recording_mode_none,
    start_record_region,
    start_record_fullscreen,
    slider_volume,
    slider_brightness,
    media_prev,
    media_play_pause,
    media_next,
    lock,
    sleep_mode,
    reboot,
    shutdown,
    close,
    request_logout,
    request_reboot,
    request_shutdown,
    confirm_session_action,
    cancel_session_action,
    wifi_input_click,
    wifi_connect_submit,
    wifi_cancel,
    cycle_power_profile,
    set_power_profile_saver,
    set_power_profile_balanced,
    set_power_profile_performance,
    set_display_scale: u32,
    set_display_refresh: u32,
    set_display_resolution: usize,
    forget_wifi: usize,
    remove_bluetooth: usize,
    disconnect_wifi: usize,
    disconnect_bluetooth: usize,
};

pub const SessionConfirmAction = enum {
    logout,
    reboot,
    shutdown,

    pub fn label(self: SessionConfirmAction) []const u8 {
        return switch (self) {
            .logout => "Log Out",
            .reboot => "Restart",
            .shutdown => "Power Off",
        };
    }

    pub fn prompt(self: SessionConfirmAction) []const u8 {
        return switch (self) {
            .logout => "Log Out?",
            .reboot => "Restart?",
            .shutdown => "Power Off?",
        };
    }

    pub fn execute(self: SessionConfirmAction) void {
        switch (self) {
            .logout => sys_status.spawnCmd("pkill -u $USER 2>/dev/null || true"),
            .reboot => sys_status.spawnCmd("systemctl reboot 2>/dev/null || loginctl reboot 2>/dev/null || reboot 2>/dev/null || true"),
            .shutdown => sys_status.spawnCmd("systemctl poweroff 2>/dev/null || loginctl poweroff 2>/dev/null || poweroff 2>/dev/null || true"),
        }
    }
};

pub const ViewMode = enum {
    main,
    wifi_menu,
    bluetooth_menu,
    audio_menu,
    notifications_menu,
    recording_menu,
    display_menu,
    power_menu,
    keymap_menu,
};

pub const AudioTab = enum {
    output,
    input,
};

pub const SliderType = enum {
    volume,
    brightness,
};

pub const AudioDeviceItem = struct {
    id: u32 = 0,
    name: [96]u8 = @splat(0),
    name_len: usize = 0,
    volume_pct: u32 = 100,
    is_default: bool = false,
};

pub const AudioSinkItem = AudioDeviceItem;

pub const HitArea = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    action: Action,
};

pub fn appendHitArea(panel: anytype, rect: renderer.Rect, scale: u32, action: Action) !void {
    const iscale: i32 = @intCast(scale);
    const lw: u32 = @intCast(@divTrunc(@as(i32, @intCast(rect.w)) + iscale - 1, iscale));
    const lh: u32 = @intCast(@divTrunc(@as(i32, @intCast(rect.h)) + iscale - 1, iscale));
    if (lw == 0 or lh == 0) return;
    try panel.hit_areas.append(panel.allocator, .{
        .x = @divTrunc(rect.x, iscale),
        .y = @divTrunc(rect.y, iscale),
        .w = lw,
        .h = lh,
        .action = action,
    });
}

pub fn emptyState(ui: *ui_mod.Ui, icon_name: []const u8, message: []const u8, hint: []const u8, scale: u32) void {
    _ = ui.open(.{
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .direction = .column,
        .align_x = .center,
        .align_y = .center,
        .gap = ui.su(8),
    });
    ui.icon(icon_name, 40 * scale, theme.Color.rgb(150, 150, 150), 0);
    ui.text(message, .{ .size = 15 * scale, .color = theme.Color.rgb(230, 230, 230) });
    ui.text(hint, .{ .size = 12 * scale, .color = theme.Color.rgb(140, 140, 140) });
    ui.close();
}

pub fn truncateText(target: anytype, font: *renderer.Font, text: []const u8, max_w: u32, size: u32, buf: []u8) []const u8 {
    if (text.len == 0 or max_w == 0) return "";
    const text_w = target.measureTextWithSize(font, text, size);
    if (text_w <= max_w) return text;

    const ellipsis = "...";
    const ell_w = target.measureTextWithSize(font, ellipsis, size);
    if (ell_w < max_w) {
        var best_len: usize = 0;
        if (std.unicode.Utf8View.init(text)) |utf8_view| {
            var it = utf8_view.iterator();
            while (it.nextCodepointSlice()) |slice| {
                const candidate_len = best_len + slice.len;
                if (candidate_len + ellipsis.len > buf.len) break;
                @memcpy(buf[0..candidate_len], text[0..candidate_len]);
                @memcpy(buf[candidate_len .. candidate_len + ellipsis.len], ellipsis);
                const w = target.measureTextWithSize(font, buf[0 .. candidate_len + ellipsis.len], size);
                if (w > max_w) break;
                best_len = candidate_len;
            }
        } else |_| {}

        if (best_len > 0) {
            @memcpy(buf[0..best_len], text[0..best_len]);
            @memcpy(buf[best_len .. best_len + ellipsis.len], ellipsis);
            return buf[0 .. best_len + ellipsis.len];
        }
    }

    var raw_len: usize = 0;
    if (std.unicode.Utf8View.init(text)) |utf8_view| {
        var it = utf8_view.iterator();
        while (it.nextCodepointSlice()) |slice| {
            const candidate_len = raw_len + slice.len;
            if (candidate_len > buf.len) break;
            @memcpy(buf[0..candidate_len], text[0..candidate_len]);
            const w = target.measureTextWithSize(font, buf[0..candidate_len], size);
            if (w > max_w) break;
            raw_len = candidate_len;
        }
    } else |_| {}

    if (raw_len > 0) return buf[0..raw_len];
    return "";
}
