const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const theme = @import("../../core/theme.zig");
const config = @import("../../core/config.zig");
const renderer = @import("../../core/renderer.zig");
const async = @import("../../core/async.zig");
const animation = @import("../../core/animation.zig");
const sys_status = @import("../../services/system_status.zig");
const notification_module = @import("../notifications.zig");
const recorder = @import("../../bar/recorder.zig");
const ui_mod = @import("../../core/ui.zig");
const keymap_module = @import("../../services/keymap.zig");

const types = @import("types.zig");
const wifi = @import("wifi.zig");
const bluetooth = @import("bluetooth.zig");
const recording = @import("recording.zig");
const powermode = @import("powermode.zig");
const sliders = @import("sliders.zig");
const battery = @import("battery.zig");

const Action = types.Action;
const QsLayout = types.QsLayout;
const ViewMode = types.ViewMode;
const SessionConfirmAction = types.SessionConfirmAction;
const AudioTab = types.AudioTab;
const AudioDeviceItem = types.AudioDeviceItem;
const AudioSinkItem = types.AudioSinkItem;
const HitArea = types.HitArea;
const SliderType = types.SliderType;
const display_scales = types.display_scales;
const display_refresh_rates = types.display_refresh_rates;
const display_resolutions = types.display_resolutions;

pub const WifiItem = wifi.WifiItem;
pub const BluetoothItem = bluetooth.BluetoothItem;

pub const QuickSettings = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    font: renderer.Font,
    sys: sys_status.SysStatus,

    width: u32 = 550,
    height: u32 = 370,
    running: bool = true,

    view_mode: ViewMode = .main,
    scroll_offset: usize = 0,
    hover_idx: ?usize = null,
    sliders: sliders.State = .{},
    caffeine_enabled: bool = false,
    dnd_enabled: bool = false,
    eye_comfort_enabled: bool = false,
    display_scale_pct: u32 = 100,
    display_refresh_rate: u32 = 144,
    display_resolution_idx: usize = 0,
    confirming_session: ?SessionConfirmAction = null,

    hit_areas: std.ArrayList(HitArea),
    wifi: wifi.State,
    bluetooth: bluetooth.State,
    recording: recording.State,
    sink_items: std.ArrayList(AudioDeviceItem) = std.ArrayList(AudioDeviceItem).empty,
    source_items: std.ArrayList(AudioDeviceItem) = std.ArrayList(AudioDeviceItem).empty,
    audio_tab: AudioTab = .output,
    default_sink_name: [64]u8 = @splat(0),
    default_sink_name_len: usize = 0,
    default_source_name: [64]u8 = @splat(0),
    default_source_name_len: usize = 0,

    audio_scan_worker: AudioScanWorker = .{},
    pointer_x: i32 = -1,
    pointer_y: i32 = -1,
    is_scanning: bool = false,
    scan_angle: f32 = 0.0,
    scan_ticks: u32 = 0,
    wake_fd: c_int = -1,
    panel_anim: animation.AnimationGroup = .{},
    panel_alpha: f32 = 1.0,
    panel_slide_y: i32 = 0,
    audio_scan_status: async.OpStatus = .idle,
    notif_store: ?notification_module.NotificationStore = null,
    mpris_cover_img: ?*renderer.Image = null,
    mpris_cover_path: [256]u8 = @splat(0),
    mpris_cover_len: usize = 0,
    display_queried: bool = false,
    audio_scanned: bool = false,

    pub fn getDesiredHeight(self: *const QuickSettings) u32 {
        return switch (self.view_mode) {
            .main => blk: {
                var h: u32 = 370;
                if (self.sys.mpris_state != .stopped and self.sys.mpris_track_len > 0) {
                    h += 78;
                }
                break :blk h;
            },
            .display_menu => 540,
            .wifi_menu, .bluetooth_menu => 520,
            .audio_menu => 500,
            .notifications_menu => 460,
            .recording_menu => 350,
            .power_menu => 320,
            .keymap_menu => 360,
        };
    }

    fn maxVisibleRows(self: *const QuickSettings) usize {
        return switch (self.view_mode) {
            .wifi_menu, .bluetooth_menu => 7,
            .audio_menu, .notifications_menu, .display_menu => 6,
            .recording_menu, .power_menu, .keymap_menu => 3,
            .main => 0,
        };
    }

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !QuickSettings {
        const font = try renderer.Font.init(allocator, cfg.theme.font_family, cfg.typography.quicksettings_text);
        const sys = sys_status.SysStatus.init(allocator);

        const wake_fd = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);

        var self_val = QuickSettings{
            .allocator = allocator,
            .cfg = cfg,
            .font = font,
            .sys = sys,
            .width = 550,
            .height = 370,
            .hit_areas = std.ArrayList(HitArea).empty,
            .wifi = wifi.State.init(allocator),
            .bluetooth = bluetooth.State.init(),
            .recording = recording.State.init(),
            .sink_items = std.ArrayList(AudioDeviceItem).empty,
            .source_items = std.ArrayList(AudioDeviceItem).empty,
            .notif_store = notification_module.NotificationStore.init(allocator),
            .caffeine_enabled = isCaffeineActive(),
            .dnd_enabled = loadDnd(),
            .eye_comfort_enabled = loadEyeComfort() or isEyeComfortActive(),
            .wake_fd = wake_fd,
            .audio_scan_status = .idle,
        };

        if (self_val.eye_comfort_enabled and !isEyeComfortActive()) {
            setEyeComfort(true);
        }

        // Register wake_fd with D-Bus monitor for MPRIS, NM, and BlueZ events.
        if (wake_fd >= 0) {
            _ = sys_status.dbus_monitor.mizu_dbus_monitor_init(wake_fd);
            sys_status.dbus_monitor.mizu_dbus_monitor_set_wake_fd(wake_fd);
        }

        self_val.audio_scan_worker.wake_fd = wake_fd;
        self_val.panel_alpha = 1.0;
        self_val.panel_slide_y = 0;
        self_val.sys.updateAll();
        return self_val;
    }

    pub fn deinit(self: *QuickSettings) void {
        sys_status.dbus_monitor.mizu_dbus_monitor_stop_bt_discovery();
        sys_status.dbus_monitor.mizu_dbus_monitor_set_wake_fd(-1);
        if (self.mpris_cover_img) |img| {
            img.destroy();
            self.mpris_cover_img = null;
        }
        if (self.notif_store) |*ns| ns.deinit();
        self.wifi.deinit(self.allocator);
        self.bluetooth.deinit(self.allocator);
        self.sink_items.deinit(self.allocator);
        self.source_items.deinit(self.allocator);
        self.hit_areas.deinit(self.allocator);
        self.font.deinit();
        self.sys.deinit();
        if (self.wake_fd >= 0) {
            _ = c.close(self.wake_fd);
            self.wake_fd = -1;
        }
    }

    pub fn tick(self: *QuickSettings) bool {
        var needs_redraw = false;
        const old_h = self.height;
        self.height = self.getDesiredHeight();
        if (self.height != old_h) needs_redraw = true;

        const caffeine_active = isCaffeineActive();
        if (caffeine_active != self.caffeine_enabled) {
            self.caffeine_enabled = caffeine_active;
            needs_redraw = true;
        }

        const dnd_active = loadDnd();
        if (dnd_active != self.dnd_enabled) {
            self.dnd_enabled = dnd_active;
            needs_redraw = true;
        }

        const eye_active = loadEyeComfort() or isEyeComfortActive();
        if (eye_active != self.eye_comfort_enabled) {
            self.eye_comfort_enabled = eye_active;
            needs_redraw = true;
        }

        if (wifi.tickInput(self)) needs_redraw = true;
        if (self.drainAll()) needs_redraw = true;
        self.sys.tick();

        if (!self.audio_scanned) {
            self.audio_scanned = true;
            self.triggerAudioScan();
        }

        const net_dirty = sys_status.dbus_monitor.mizu_dbus_monitor_check_network_dirty();
        const bt_dirty = sys_status.dbus_monitor.mizu_dbus_monitor_check_bluetooth_dirty();
        if (net_dirty) {
            self.sys.updateRfkill();
            self.sys.pullAsyncData();
            needs_redraw = true;
        }
        if (bt_dirty) {
            self.sys.updateRfkill();
            self.sys.pullAsyncData();
            needs_redraw = true;
        }

        const now = sys_status.monotonicMs();
        wifi.autoScan(self, now, net_dirty);
        bluetooth.autoScan(self, now, bt_dirty);

        if (theme.loadSavedTheme()) |saved| {
            if (saved != self.cfg.theme.kind) {
                self.cfg.theme = saved.toTheme();
                needs_redraw = true;
            }
        }

        const any_worker_active = wifi.anyWorkerActive(self) or
            bluetooth.anyWorkerActive(self) or
            self.audio_scan_worker.running.load(.acquire);

        if (any_worker_active) {
            self.is_scanning = true;
        }

        if (self.is_scanning) {
            needs_redraw = true;
            self.scan_angle += 0.22;
            if (self.scan_angle > 6.2831853) {
                self.scan_angle -= 6.2831853;
            }
            if (self.scan_ticks > 0) {
                self.scan_ticks -= 1;
            } else if (!any_worker_active) {
                self.is_scanning = false;
                self.scan_angle = 0.0;
            }
        }

        return needs_redraw;
    }

    pub fn handlePointerMotion(self: *QuickSettings, x: i32, y: i32) bool {
        self.pointer_x = x;
        self.pointer_y = y;

        if (self.sliders.active) |st| {
            sliders.updateFromPointer(self, st, x);
            return true;
        }

        const old_hover = self.hover_idx;
        self.hover_idx = null;
        for (self.hit_areas.items, 0..) |area, idx| {
            if (x >= area.x and x < area.x + @as(i32, @intCast(area.w)) and
                y >= area.y and y < area.y + @as(i32, @intCast(area.h)))
            {
                self.hover_idx = idx;
                break;
            }
        }
        return old_hover != self.hover_idx;
    }

    pub fn handlePointerLeave(self: *QuickSettings) bool {
        self.pointer_x = -1;
        self.pointer_y = -1;
        const had_hover = (self.hover_idx != null or self.sliders.active != null);
        self.hover_idx = null;
        self.sliders.active = null;
        return had_hover;
    }

    pub fn isPointer(self: *QuickSettings, px: i32, py: i32) bool {
        for (self.hit_areas.items) |area| {
            if (px >= area.x and px < area.x + @as(i32, @intCast(area.w)) and
                py >= area.y and py < area.y + @as(i32, @intCast(area.h)))
            {
                return true;
            }
        }
        return false;
    }

    pub fn handlePointerAxis(self: *QuickSettings, x: i32, y: i32, scroll_delta: i32) bool {
        if (self.view_mode == .main) return sliders.handleAxis(self, x, y, scroll_delta);

        const total = switch (self.view_mode) {
            .wifi_menu => self.wifi.items.items.len,
            .bluetooth_menu => self.bluetooth.items.items.len,
            .audio_menu => if (self.audio_tab == .output) self.sink_items.items.len else self.source_items.items.len,
            .notifications_menu => if (self.notif_store) |ns| ns.items.items.len else 0,
            .recording_menu => 3,
            .display_menu => 0,
            .power_menu => 3,
            .keymap_menu => 0,
            .main => 0,
        };
        const max_visible = self.maxVisibleRows();
        const max_scroll = if (total > max_visible) total - max_visible else 0;
        if (max_scroll == 0) return false;

        if (scroll_delta > 0) {
            if (self.scroll_offset < max_scroll) {
                self.scroll_offset += 1;
                return true;
            }
        } else if (scroll_delta < 0) {
            if (self.scroll_offset > 0) {
                self.scroll_offset -= 1;
                return true;
            }
        }
        return false;
    }

    pub fn handlePointerButton(self: *QuickSettings, x: i32, y: i32, button: u32, is_pressed: bool) bool {
        // BTN_LEFT is 272 (0x110), BTN_RIGHT is 273 (0x111)
        if (button != 272 and button != 273) return false;

        if (!is_pressed) {
            return sliders.release(self);
        }

        // Button pressed: check hit areas
        for (self.hit_areas.items) |area| {
            if (x >= area.x and x < area.x + @as(i32, @intCast(area.w)) and
                y >= area.y and y < area.y + @as(i32, @intCast(area.h)))
            {
                if (sliders.handleAction(self, area.action, x)) return true;
                if (wifi.handleInputClick(self, area.action, x, y, area)) return true;
                if (wifi.handleAction(self, area.action)) return true;
                if (bluetooth.handleAction(self, area.action)) return true;
                if (recording.handleAction(self, area.action)) return true;
                if (powermode.handleAction(self, area.action)) return true;
                if (battery.handleAction(self, area.action)) return true;

                switch (area.action) {
                    .toggle_audio_mute => {
                        self.sys.toggleVolumeMute();
                        return true;
                    },
                    .toggle_caffeine => {
                        setCaffeine(!self.caffeine_enabled);
                        self.caffeine_enabled = isCaffeineActive();
                        return true;
                    },
                    .open_audio_menu => {
                        if (button == 273) {
                            self.sys.toggleVolumeMute();
                            return true;
                        }
                        self.view_mode = .audio_menu;
                        self.scroll_offset = 0;
                        self.triggerAudioScan();
                        return true;
                    },
                    .back_to_main => {
                        if (self.view_mode == .bluetooth_menu) {
                            sys_status.dbus_monitor.mizu_dbus_monitor_stop_bt_discovery();
                        }
                        self.view_mode = .main;
                        self.scroll_offset = 0;
                        return true;
                    },
                    .refresh_sub_menu => {
                        switch (self.view_mode) {
                            .wifi_menu => wifi.refresh(self),
                            .bluetooth_menu => bluetooth.refresh(self),
                            .recording_menu => recording.refresh(self),
                            .notifications_menu => {
                                if (self.notif_store) |*ns| ns.loadHistory();
                            },
                            .display_menu, .power_menu, .keymap_menu, .main, .audio_menu => {},
                        }
                        return true;
                    },
                    .select_audio_sink => |idx| {
                        if (idx < self.sink_items.items.len) {
                            const item = self.sink_items.items[idx];
                            var cmd_buf: [64]u8 = undefined;
                            const cmd = std.fmt.bufPrint(&cmd_buf, "wpctl set-default {d}", .{item.id}) catch return true;
                            sys_status.spawnCmd(cmd);
                            if (self.sys.earbud_safety_enabled and sys_status.SysStatus.isHeadphoneOrEarbud(item.name[0..item.name_len])) {
                                if (self.sys.volume_percent > 20) {
                                    sys_status.spawnCmd("wpctl set-volume -l 2.0 @DEFAULT_AUDIO_SINK@ 20% 2>/dev/null || pactl set-sink-volume @DEFAULT_SINK@ 20% 2>/dev/null || true");
                                    self.sys.volume_percent = 20;
                                    self.sys.volume_muted = false;
                                }
                            }
                            self.sys.updateVolume();
                            self.triggerAudioScan();
                        }
                        return true;
                    },
                    .toggle_earbud_safety => {
                        self.sys.setEarbudSafety(!self.sys.earbud_safety_enabled);
                        return true;
                    },
                    .select_audio_source => |idx| {
                        if (idx < self.source_items.items.len) {
                            const item = self.source_items.items[idx];
                            var cmd_buf: [64]u8 = undefined;
                            const cmd = std.fmt.bufPrint(&cmd_buf, "wpctl set-default {d}", .{item.id}) catch return true;
                            sys_status.spawnCmd(cmd);
                            self.triggerAudioScan();
                        }
                        return true;
                    },
                    .set_audio_tab_output => {
                        self.audio_tab = .output;
                        self.scroll_offset = 0;
                        return true;
                    },
                    .set_audio_tab_input => {
                        self.audio_tab = .input;
                        self.scroll_offset = 0;
                        return true;
                    },
                    .media_prev => {
                        sys_status.spawnCmd("playerctl previous");
                        return true;
                    },
                    .media_play_pause => {
                        sys_status.spawnCmd("playerctl play-pause");
                        return true;
                    },
                    .media_next => {
                        sys_status.spawnCmd("playerctl next");
                        return true;
                    },
                    .open_notifications_menu => {
                        self.view_mode = .notifications_menu;
                        self.scroll_offset = 0;
                        if (self.notif_store) |*ns| ns.loadHistory();
                        return true;
                    },
                    .clear_notifications => {
                        if (self.notif_store) |*ns| ns.clear();
                        return true;
                    },
                    .dismiss_notification => |idx| {
                        if (self.notif_store) |*ns| ns.remove(idx);
                        return true;
                    },
                    .request_logout => {
                        self.confirming_session = .logout;
                        return true;
                    },
                    .request_reboot => {
                        self.confirming_session = .reboot;
                        return true;
                    },
                    .request_shutdown => {
                        self.confirming_session = .shutdown;
                        return true;
                    },
                    .cancel_session_action => {
                        self.confirming_session = null;
                        return true;
                    },
                    .confirm_session_action => {
                        if (self.confirming_session) |act| {
                            act.execute();
                            self.running = false;
                        }
                        return true;
                    },
                    .sleep_mode => {
                        sys_status.spawnCmd("systemctl suspend 2>/dev/null || loginctl suspend 2>/dev/null || true");
                        self.running = false;
                        return true;
                    },
                    .reboot => {
                        sys_status.spawnCmd("systemctl reboot 2>/dev/null || loginctl reboot 2>/dev/null || reboot 2>/dev/null || true");
                        self.running = false;
                        return true;
                    },
                    .shutdown => {
                        sys_status.spawnCmd("systemctl poweroff 2>/dev/null || loginctl poweroff 2>/dev/null || poweroff 2>/dev/null || true");
                        self.running = false;
                        return true;
                    },
                    .close => {
                        self.running = false;
                        return true;
                    },
                    .toggle_dnd => {
                        self.toggleDnd();
                        return true;
                    },
                    .toggle_eye_comfort => {
                        self.toggleEyeComfort();
                        return true;
                    },
                    .open_display_menu => {
                        if (!self.display_queried) {
                            self.display_queried = true;
                            self.queryDisplaySettings();
                        }
                        self.view_mode = .display_menu;
                        self.scroll_offset = 0;
                        return true;
                    },
                    .open_clipboard => {
                        sys_status.spawnCmd("mizu clipboard 2>/dev/null || mizu clip 2>/dev/null || true");
                        self.running = false;
                        return true;
                    },
                    .cycle_theme => {
                        const next_th = self.cfg.theme.kind.next();
                        self.cfg.theme = next_th.toTheme();
                        theme.saveCurrentTheme(next_th);
                        return true;
                    },
                    .open_keymap_menu => {
                        self.view_mode = .keymap_menu;
                        self.scroll_offset = 0;
                        return true;
                    },
                    .toggle_keymap => {
                        sys_status.spawnCmd("mizu keyoverlay 2>/dev/null || true");
                        return true;
                    },
                    .set_keymap_size => |sz| {
                        self.cfg.typography.keymap_text = sz;
                        config.saveKeymapSize(sz);
                        sys_status.spawnCmd("pkill -USR1 -f 'mizu keyoverlay' 2>/dev/null || pkill -USR1 mizu 2>/dev/null || true");
                        return true;
                    },
                    .set_keymap_pos => |pos| {
                        self.cfg.keymap_position = pos;
                        config.saveKeymapPosition(pos);
                        sys_status.spawnCmd("pkill -USR1 -f 'mizu keyoverlay' 2>/dev/null || pkill -USR1 mizu 2>/dev/null || true");
                        return true;
                    },
                    .set_display_scale => |s_val| {
                        self.display_scale_pct = s_val;
                        applyDisplayScale(s_val);
                        saveDisplayScale(s_val);
                        return true;
                    },
                    .set_display_refresh => |r_val| {
                        self.display_refresh_rate = r_val;
                        applyDisplayRefresh(r_val);
                        saveDisplayRefresh(r_val);
                        return true;
                    },
                    .set_display_resolution => |res_idx| {
                        if (res_idx < display_resolutions.len) {
                            self.display_resolution_idx = res_idx;
                            applyDisplayResolution(display_resolutions[res_idx]);
                            saveDisplayResolution(display_resolutions[res_idx]);
                        }
                        return true;
                    },
                    else => {},
                }
            }
        }

        return false;
    }

    /// Enumerate PipeWire audio sinks and sources off the UI thread.
    pub const AudioScanWorker = struct {
        running: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        status: std.atomic.Value(async.OpStatus) = .init(.idle),
        lock: sys_status.SpinLock = .{},
        wake_fd: c_int = -1,
        sink_items: [64]AudioDeviceItem = @splat(AudioDeviceItem{}),
        sink_count: usize = 0,
        source_items: [64]AudioDeviceItem = @splat(AudioDeviceItem{}),
        source_count: usize = 0,
        default_sink_name: [64]u8 = @splat(0),
        default_sink_name_len: usize = 0,
        default_source_name: [64]u8 = @splat(0),
        default_source_name_len: usize = 0,
        error_msg: [128]u8 = @splat(0),
        error_len: usize = 0,

        pub fn run(worker: *AudioScanWorker) void {
            worker.status.store(.loading, .release);
            worker.running.store(true, .release);

            var local_sinks: [64]AudioDeviceItem = @splat(AudioDeviceItem{});
            var local_sink_count: usize = 0;
            var local_sources: [64]AudioDeviceItem = @splat(AudioDeviceItem{});
            var local_source_count: usize = 0;
            var local_default_sink: [64]u8 = @splat(0);
            var local_default_sink_len: usize = 0;
            var local_default_source: [64]u8 = @splat(0);
            var local_default_source_len: usize = 0;

            const pipe = c.popen("wpctl status 2>/dev/null", "r");
            if (pipe) |p| {
                defer _ = c.pclose(p);
                var buf: [16384]u8 = undefined;
                var total_read: usize = 0;
                while (total_read < buf.len - 1) {
                    const n = c.fread(buf[total_read..].ptr, 1, buf.len - 1 - total_read, p);
                    if (n == 0) break;
                    total_read += n;
                }
                buf[total_read] = 0;

                var in_audio = false;
                var in_sinks = false;
                var in_sources = false;
                var line_it = std.mem.splitScalar(u8, buf[0..total_read], '\n');
                while (line_it.next()) |raw_line| {
                    const line = std.mem.trim(u8, raw_line, " \t\r");
                    if (std.mem.eql(u8, line, "Audio")) {
                        in_audio = true;
                        continue;
                    }
                    if (in_audio) {
                        if (std.mem.indexOf(u8, line, "Video") != null or std.mem.indexOf(u8, line, "Settings") != null) {
                            break;
                        }
                        if (std.mem.indexOf(u8, line, "Sinks:") != null) {
                            in_sinks = true;
                            in_sources = false;
                            continue;
                        }
                        if (std.mem.indexOf(u8, line, "Sources:") != null) {
                            in_sources = true;
                            in_sinks = false;
                            continue;
                        }
                        if (in_sinks or in_sources) {
                            if (std.mem.indexOf(u8, line, "Filters:") != null or
                                std.mem.indexOf(u8, line, "Streams:") != null)
                            {
                                in_sinks = false;
                                in_sources = false;
                                continue;
                            }

                            const dot_idx = std.mem.indexOf(u8, line, ".") orelse continue;
                            var num_start = dot_idx;
                            while (num_start > 0 and line[num_start - 1] >= '0' and line[num_start - 1] <= '9') {
                                num_start -= 1;
                            }
                            if (num_start == dot_idx) continue;
                            const id = std.fmt.parseInt(u32, line[num_start..dot_idx], 10) catch continue;

                            const is_default = (std.mem.indexOf(u8, line[0..num_start], "*") != null);

                            const after_dot = std.mem.trim(u8, line[dot_idx + 1 ..], " \t");
                            var name = after_dot;
                            var vol_pct: u32 = 100;

                            if (std.mem.indexOf(u8, after_dot, "[vol:")) |vol_idx| {
                                name = std.mem.trim(u8, after_dot[0..vol_idx], " \t");
                                const after_vol = std.mem.trim(u8, after_dot[vol_idx + 5 ..], " \t");
                                if (std.mem.indexOf(u8, after_vol, "]")) |close_idx| {
                                    const vol_val_str = std.mem.trim(u8, after_vol[0..close_idx], " \t");
                                    const float_vol = std.fmt.parseFloat(f32, vol_val_str) catch 1.0;
                                    vol_pct = @intFromFloat(@min(100.0, @max(0.0, float_vol * 100.0)));
                                }
                            } else if (std.mem.indexOf(u8, after_dot, "[")) |bracket_idx| {
                                name = std.mem.trim(u8, after_dot[0..bracket_idx], " \t");
                            }

                            var item = AudioDeviceItem{
                                .id = id,
                                .name = @splat(0),
                                .name_len = @min(name.len, 96),
                                .volume_pct = vol_pct,
                                .is_default = is_default,
                            };
                            @memcpy(item.name[0..item.name_len], name[0..item.name_len]);

                            if (in_sinks) {
                                if (is_default) {
                                    local_default_sink_len = @min(name.len, local_default_sink.len);
                                    @memcpy(local_default_sink[0..local_default_sink_len], name[0..local_default_sink_len]);
                                }
                                if (local_sink_count < local_sinks.len) {
                                    local_sinks[local_sink_count] = item;
                                    local_sink_count += 1;
                                }
                            } else if (in_sources) {
                                if (is_default) {
                                    local_default_source_len = @min(name.len, local_default_source.len);
                                    @memcpy(local_default_source[0..local_default_source_len], name[0..local_default_source_len]);
                                }
                                if (local_source_count < local_sources.len) {
                                    local_sources[local_source_count] = item;
                                    local_source_count += 1;
                                }
                            }
                        }
                    }
                }
            }

            // Sort: default first, then by name.
            std.mem.sort(AudioDeviceItem, local_sinks[0..local_sink_count], {}, struct {
                fn lessThan(_: void, a: AudioDeviceItem, b: AudioDeviceItem) bool {
                    if (a.is_default != b.is_default) return a.is_default;
                    return std.mem.order(u8, a.name[0..a.name_len], b.name[0..b.name_len]) == .lt;
                }
            }.lessThan);
            std.mem.sort(AudioDeviceItem, local_sources[0..local_source_count], {}, struct {
                fn lessThan(_: void, a: AudioDeviceItem, b: AudioDeviceItem) bool {
                    if (a.is_default != b.is_default) return a.is_default;
                    return std.mem.order(u8, a.name[0..a.name_len], b.name[0..b.name_len]) == .lt;
                }
            }.lessThan);

            {
                worker.lock.lock();
                defer worker.lock.unlock();
                @memcpy(worker.sink_items[0..local_sink_count], local_sinks[0..local_sink_count]);
                worker.sink_count = local_sink_count;
                @memcpy(worker.source_items[0..local_source_count], local_sources[0..local_source_count]);
                worker.source_count = local_source_count;
                @memcpy(worker.default_sink_name[0..local_default_sink_len], local_default_sink[0..local_default_sink_len]);
                worker.default_sink_name_len = local_default_sink_len;
                @memcpy(worker.default_source_name[0..local_default_source_len], local_default_source[0..local_default_source_len]);
                worker.default_source_name_len = local_default_source_len;
            }

            worker.status.store(.success, .release);
            worker.done.store(true, .release);
            worker.running.store(false, .release);
            if (worker.wake_fd >= 0) {
                const val: u64 = 1;
                _ = c.write(worker.wake_fd, &val, @sizeOf(u64));
            }
        }
    };

    pub fn triggerWifiScan(self: *QuickSettings) void {
        wifi.triggerScan(self);
    }

    pub fn triggerBtScan(self: *QuickSettings) void {
        bluetooth.triggerScan(self);
    }

    pub fn triggerAudioScan(self: *QuickSettings) void {
        if (self.audio_scan_worker.running.load(.acquire)) return;
        self.audio_scan_status = .loading;
        self.audio_scan_worker.done.store(false, .release);
        self.audio_scan_worker.running.store(true, .release);
        self.audio_scan_worker.wake_fd = self.wake_fd;
        if (self.wake_fd >= 0) {
            _ = async.spawnTask(AudioScanWorker, &self.audio_scan_worker, self.wake_fd) catch {
                self.audio_scan_worker.running.store(false, .release);
                self.audio_scan_status = .failed;
            };
        } else {
            self.audio_scan_worker.running.store(false, .release);
            self.audio_scan_status = .idle;
        }
    }

    /// Drain completed async workers into UI state.
    pub fn drainAsyncResults(self: *QuickSettings) bool {
        var changed = false;

        if (wifi.drain(self)) changed = true;
        if (bluetooth.drain(self)) changed = true;

        if (self.audio_scan_worker.done.load(.acquire)) {
            self.audio_scan_worker.lock.lock();
            defer self.audio_scan_worker.lock.unlock();
            self.sink_items.clearRetainingCapacity();
            for (self.audio_scan_worker.sink_items[0..self.audio_scan_worker.sink_count]) |it| {
                self.sink_items.append(self.allocator, it) catch break;
            }
            self.source_items.clearRetainingCapacity();
            for (self.audio_scan_worker.source_items[0..self.audio_scan_worker.source_count]) |it| {
                self.source_items.append(self.allocator, it) catch break;
            }
            self.default_sink_name_len = self.audio_scan_worker.default_sink_name_len;
            @memcpy(self.default_sink_name[0..self.default_sink_name_len], self.audio_scan_worker.default_sink_name[0..self.default_sink_name_len]);
            self.default_source_name_len = self.audio_scan_worker.default_source_name_len;
            @memcpy(self.default_source_name[0..self.default_source_name_len], self.audio_scan_worker.default_source_name[0..self.default_source_name_len]);
            self.audio_scan_worker.done.store(false, .release);
            self.audio_scan_status = self.audio_scan_worker.status.load(.acquire);
            changed = true;
        }

        return changed;
    }

    /// Drain async workers and apply state changes. Returns true if redraw needed.
    pub fn drainAll(self: *QuickSettings) bool {
        var changed = false;
        if (self.drainAsyncResults()) changed = true;
        if (self.checkWifiStatus()) changed = true;
        if (self.checkBtConnectStatus()) changed = true;

        const prev_mpris_state = self.sys.mpris_state;
        const prev_mpris_len = self.sys.mpris_track_len;
        const prev_art_len = self.sys.mpris_art_url_len;
        self.sys.pullAsyncData();
        if (self.sys.mpris_state != prev_mpris_state or
            self.sys.mpris_track_len != prev_mpris_len or
            self.sys.mpris_art_url_len != prev_art_len)
        {
            changed = true;
        }

        const any_worker_active = wifi.anyWorkerActive(self) or
            bluetooth.anyWorkerActive(self) or
            self.audio_scan_worker.running.load(.acquire);
        if (!any_worker_active and self.is_scanning and self.scan_ticks == 0) {
            self.is_scanning = false;
            self.scan_angle = 0.0;
            changed = true;
        }

        return changed;
    }

    pub fn updateCoverArt(self: *QuickSettings) void {
        const art_url = self.sys.mpris_art_url[0..self.sys.mpris_art_url_len];
        if (art_url.len == 0) {
            if (self.mpris_cover_img) |img| {
                img.destroy();
                self.mpris_cover_img = null;
                self.mpris_cover_len = 0;
            }
            return;
        }

        const path = if (std.mem.startsWith(u8, art_url, "file://"))
            art_url[7..]
        else
            art_url;

        if (self.mpris_cover_img != null and std.mem.eql(u8, path, self.mpris_cover_path[0..self.mpris_cover_len])) {
            return;
        }

        if (self.mpris_cover_img) |img| {
            img.destroy();
            self.mpris_cover_img = null;
            self.mpris_cover_len = 0;
        }

        const clen = @min(path.len, self.mpris_cover_path.len);
        @memcpy(self.mpris_cover_path[0..clen], path[0..clen]);
        self.mpris_cover_len = clen;

        if (std.mem.endsWith(u8, path, ".png")) {
            self.mpris_cover_img = renderer.Image.loadPng(self.allocator, path) catch null;
        } else if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) {
            self.mpris_cover_img = renderer.Image.loadJpeg(self.allocator, path) catch null;
        }
    }

    /// Connect to a Wi-Fi network asynchronously off the UI thread.
    pub fn connectWifiNetwork(self: *QuickSettings, ssid: []const u8, pwd: []const u8) void {
        wifi.connectNetwork(self, ssid, pwd);
    }

    pub fn checkWifiStatus(self: *QuickSettings) bool {
        return wifi.checkStatus(self);
    }

    /// Returns true when the Bluetooth connect/disconnect worker completed.
    pub fn checkBtConnectStatus(self: *QuickSettings) bool {
        return bluetooth.checkStatus(self);
    }

    pub fn submitWifiPassword(self: *QuickSettings) void {
        wifi.submitPassword(self);
    }

    pub fn handleKey(self: *QuickSettings, sym: u32, utf8_bytes: []const u8) bool {
        return self.handleKeyFull(sym, utf8_bytes, false, false);
    }

    pub fn handleKeyFull(self: *QuickSettings, sym: u32, utf8_bytes: []const u8, ctrl: bool, shift: bool) bool {
        if (sym == c.XKB_KEY_Escape) {
            if (self.confirming_session != null) {
                self.confirming_session = null;
                return true;
            }
        }

        return wifi.handleKey(self, sym, utf8_bytes, ctrl, shift);
    }

    pub fn scanWifi(self: *QuickSettings) void {
        wifi.scan(self);
    }

    pub fn scanBluetooth(self: *QuickSettings) void {
        bluetooth.scan(self);
    }

    pub fn scanAudioSinks(self: *QuickSettings) void {
        self.scanAudioDevices();
    }

    pub fn scanAudioDevices(self: *QuickSettings) void {
        self.sink_items.clearRetainingCapacity();
        self.source_items.clearRetainingCapacity();
        self.default_sink_name_len = 0;
        self.default_source_name_len = 0;

        const pipe = c.popen("wpctl status 2>/dev/null", "r") orelse return;
        defer _ = c.pclose(pipe);

        var buf: [16384]u8 = undefined;
        var total_read: usize = 0;
        while (total_read < buf.len - 1) {
            const n = c.fread(buf[total_read..].ptr, 1, buf.len - 1 - total_read, pipe);
            if (n == 0) break;
            total_read += n;
        }
        buf[total_read] = 0;

        var in_audio = false;
        var in_sinks = false;
        var in_sources = false;
        var line_it = std.mem.splitScalar(u8, buf[0..total_read], '\n');
        while (line_it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (std.mem.eql(u8, line, "Audio")) {
                in_audio = true;
                continue;
            }
            if (in_audio) {
                if (std.mem.indexOf(u8, line, "Video") != null or std.mem.indexOf(u8, line, "Settings") != null) {
                    break;
                }
                if (std.mem.indexOf(u8, line, "Sinks:") != null) {
                    in_sinks = true;
                    in_sources = false;
                    continue;
                }
                if (std.mem.indexOf(u8, line, "Sources:") != null) {
                    in_sources = true;
                    in_sinks = false;
                    continue;
                }
                if (in_sinks or in_sources) {
                    if (std.mem.indexOf(u8, line, "Filters:") != null or
                        std.mem.indexOf(u8, line, "Streams:") != null)
                    {
                        in_sinks = false;
                        in_sources = false;
                        continue;
                    }

                    const dot_idx = std.mem.indexOf(u8, line, ".") orelse continue;
                    var num_start = dot_idx;
                    while (num_start > 0 and line[num_start - 1] >= '0' and line[num_start - 1] <= '9') {
                        num_start -= 1;
                    }
                    if (num_start == dot_idx) continue;
                    const id = std.fmt.parseInt(u32, line[num_start..dot_idx], 10) catch continue;

                    const is_default = (std.mem.indexOf(u8, line[0..num_start], "*") != null);

                    const after_dot = std.mem.trim(u8, line[dot_idx + 1 ..], " \t");
                    var name = after_dot;
                    var vol_pct: u32 = 100;

                    if (std.mem.indexOf(u8, after_dot, "[vol:")) |vol_idx| {
                        name = std.mem.trim(u8, after_dot[0..vol_idx], " \t");
                        const after_vol = std.mem.trim(u8, after_dot[vol_idx + 5 ..], " \t");
                        if (std.mem.indexOf(u8, after_vol, "]")) |close_idx| {
                            const vol_val_str = std.mem.trim(u8, after_vol[0..close_idx], " \t");
                            const float_vol = std.fmt.parseFloat(f32, vol_val_str) catch 1.0;
                            vol_pct = @intFromFloat(@min(100.0, @max(0.0, float_vol * 100.0)));
                        }
                    } else if (std.mem.indexOf(u8, after_dot, "[")) |bracket_idx| {
                        name = std.mem.trim(u8, after_dot[0..bracket_idx], " \t");
                    }

                    var item = AudioDeviceItem{
                        .id = id,
                        .name = @splat(0),
                        .name_len = @min(name.len, 96),
                        .volume_pct = vol_pct,
                        .is_default = is_default,
                    };
                    @memcpy(item.name[0..item.name_len], name[0..item.name_len]);

                    if (in_sinks) {
                        if (is_default) {
                            self.default_sink_name_len = @min(name.len, self.default_sink_name.len);
                            @memcpy(self.default_sink_name[0..self.default_sink_name_len], name[0..self.default_sink_name_len]);
                        }
                        self.sink_items.append(self.allocator, item) catch break;
                    } else if (in_sources) {
                        if (is_default) {
                            self.default_source_name_len = @min(name.len, self.default_source_name.len);
                            @memcpy(self.default_source_name[0..self.default_source_name_len], name[0..self.default_source_name_len]);
                        }
                        self.source_items.append(self.allocator, item) catch break;
                    }
                }
            }
        }

        // Sort: default first, then by name
        std.mem.sort(AudioDeviceItem, self.sink_items.items, {}, struct {
            fn lessThan(_: void, a: AudioDeviceItem, b: AudioDeviceItem) bool {
                if (a.is_default != b.is_default) return a.is_default;
                return std.mem.order(u8, a.name[0..a.name_len], b.name[0..b.name_len]) == .lt;
            }
        }.lessThan);

        std.mem.sort(AudioDeviceItem, self.source_items.items, {}, struct {
            fn lessThan(_: void, a: AudioDeviceItem, b: AudioDeviceItem) bool {
                if (a.is_default != b.is_default) return a.is_default;
                return std.mem.order(u8, a.name[0..a.name_len], b.name[0..b.name_len]) == .lt;
            }
        }.lessThan);
    }

    pub fn calculateSliderPercent(px: i32, start_x: i32, width: u32) u32 {
        return sliders.calculatePercent(px, start_x, width);
    }

    pub fn calculateSliderValue(px: i32, start_x: i32, width: u32, max_val: u32) u32 {
        return sliders.calculateValue(px, start_x, width, max_val);
    }

    pub fn render(self: *QuickSettings, target: anytype, scale: u32) !void {
        _ = self.checkWifiStatus();
        self.hit_areas.clearRetainingCapacity();

        const w = target.width;
        const h = target.height;
        const radius: u32 = self.cfg.theme.radius_panel * scale;

        target.clear(theme.Color.transparent);
        target.drawDropShadow(0, 0, w, h, radius, 8 * scale, self.cfg.theme.shadow_dark);

        const ui_sz = self.cfg.typography.ui * scale;
        const sec_sz = self.cfg.typography.secondary * scale;
        const icon_sz = self.cfg.typography.quicksettings_icon * scale;

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

        if (self.view_mode == .main) {
            const top_pad: u16 = @intCast(QsLayout.pad * scale);
            ui.root(.{
                .direction = .column,
                .padding = .{
                    .left = ui.su(QsLayout.pad),
                    .right = ui.su(QsLayout.pad),
                    .top = top_pad,
                    .bottom = ui.su(0),
                },
                .gap = ui.su(QsLayout.section_gap),
                .bg = self.cfg.theme.panel_bg,
                .radius = ui.f(self.cfg.theme.radius_panel),
                .align_y = .top,
            });

            try self.renderMainBody(&ui, target, scale, ui_sz, sec_sz, icon_sz);
            ui.close();
        } else {
            ui.root(.{
                .direction = .column,
                .padding = .all(ui.su(QsLayout.pad)),
                .gap = ui.su(QsLayout.section_gap),
                .bg = self.cfg.theme.panel_bg,
                .radius = ui.f(self.cfg.theme.radius_panel),
                .align_y = .top,
            });

            try self.renderSubMenu(&ui, target, scale, ui_sz, sec_sz, icon_sz);
            ui.close();
        }

        const commands = ui.endLayout();
        try self.appendHitAreas(&ui, scale);
        ui.render(target, commands);

        // Fade-in overlay stays a direct draw so it covers every Clay command.
        if (self.panel_alpha < 1.0) {
            const fade_a = @as(u8, @intFromFloat((1.0 - self.panel_alpha) * 255.0));
            if (fade_a > 0) {
                target.fillRoundedRect(0, 0, w, h, radius, theme.Color.init(fade_a, 0, 0, 0));
            }
        }
    }

    fn renderMainBody(
        self: *QuickSettings,
        ui: *ui_mod.Ui,
        target: renderer.Renderer,
        scale: u32,
        ui_sz: u32,
        sec_sz: u32,
        icon_sz: u32,
    ) !void {
        const pad_u = QsLayout.pad * scale;
        const content_w: u32 = if (target.width > 2 * pad_u)
            target.width - 2 * pad_u
        else
            target.width;

        battery.renderHeader(self, ui, scale);

        try sliders.renderRow(self, ui, scale);

        // Row 1: Wi-Fi and Bluetooth.
        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .fixed = ui.s(QsLayout.card_h) },
            .direction = .row,
            .gap = ui.su(QsLayout.section_gap),
        });
        try wifi.renderMainCard(self, ui, scale, icon_sz, ui_sz, sec_sz);
        try bluetooth.renderMainCard(self, ui, scale, icon_sz, ui_sz, sec_sz);
        ui.close();

        // Row 2: Screen Recording and Power Mode.
        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .fixed = ui.s(QsLayout.card_h) },
            .direction = .row,
            .gap = ui.su(QsLayout.section_gap),
        });
        try recording.renderMainCard(self, ui, scale, icon_sz, ui_sz, sec_sz);
        try powermode.renderMainCard(self, ui, scale, icon_sz, ui_sz, sec_sz);
        ui.close();

        // Row 3: Eye comfort, DND, Caffeine, Keymap.
        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .fixed = ui.s(QsLayout.row3_h) },
            .direction = .row,
            .gap = ui.su(10),
        });
        const keymap_active = keymap_module.isKeymapsActive();
        const row3_items = [_]struct { icon: []const u8, active: bool }{
            .{ .icon = "moon", .active = self.eye_comfort_enabled },
            .{ .icon = if (self.dnd_enabled) "bell-off" else "bell", .active = self.dnd_enabled },
            .{ .icon = "caffeine", .active = self.caffeine_enabled },
            .{ .icon = "keyboard", .active = keymap_active },
        };
        for (row3_items, 0..) |it, idx| {
            const hov = ui.hovered("qs-row3-btn", @intCast(idx));
            var bg = if (it.active) self.cfg.theme.accent else self.cfg.theme.surface;
            if (hov and !it.active) bg = self.cfg.theme.card_hover_bg;
            const fg = if (it.active) self.cfg.theme.accent_fg else (if (hov) self.cfg.theme.secondary else self.cfg.theme.text_bright);

            _ = ui.open(.{
                .id = "qs-row3-btn",
                .index = @intCast(idx),
                .width = .{ .grow = .{} },
                .height = .{ .grow = .{} },
                .direction = .row,
                .bg = bg,
                .radius = ui.f(QsLayout.radius),
                .align_x = .center,
                .align_y = .center,
            });
            ui.icon(it.icon, 36 * scale, fg, 0);
            ui.close();
        }
        ui.close(); // row 3

        // MPRIS media card (if playing)
        if (self.sys.mpris_state != .stopped and self.sys.mpris_track_len > 0) {
            _ = ui.open(.{
                .width = .{ .grow = .{} },
                .height = .{ .fixed = ui.s(64) },
                .direction = .row,
                .padding = .{ .left = ui.su(14), .right = ui.su(14) },
                .gap = ui.su(12),
                .bg = self.cfg.theme.surface,
                .radius = ui.f(QsLayout.radius),
                .align_y = .center,
            });
            self.updateCoverArt();
            if (self.mpris_cover_img) |img| {
                ui.image(img, .{ .fixed = ui.s(40) }, .{ .fixed = ui.s(40) }, null, 0);
            } else {
                ui.icon("music", icon_sz, self.cfg.theme.accent, 0);
            }
            _ = ui.open(.{
                .width = .{ .grow = .{} },
                .height = .{ .grow = .{} },
                .direction = .column,
                .gap = 0,
                .align_y = .center,
                .clip_horizontal = true,
            });
            const track_str = self.sys.mpris_track[0..self.sys.mpris_track_len];
            var track_buf: [128]u8 = undefined;
            const trunc_track = types.truncateText(target, &self.font, track_str, content_w -| 180 * scale, ui_sz, &track_buf);
            ui.text(trunc_track, .{ .size = ui_sz, .color = self.cfg.theme.text_bright });
            ui.text(if (self.sys.mpris_state == .playing) "Playing" else "Paused", .{ .size = sec_sz, .color = self.cfg.theme.text_muted });
            ui.close();

            const media_actions = [_]struct { icon: []const u8, act: Action }{
                .{ .icon = "previous", .act = .media_prev },
                .{ .icon = if (self.sys.mpris_state == .playing) "pause" else "play", .act = .media_play_pause },
                .{ .icon = "next", .act = .media_next },
            };
            for (media_actions, 0..) |ma, mi| {
                const hov = ui.hovered("qs-media", @intCast(mi));
                _ = ui.open(.{
                    .id = "qs-media",
                    .index = @intCast(mi),
                    .width = .{ .fixed = ui.s(28) },
                    .height = .{ .fixed = ui.s(28) },
                    .bg = if (hov) self.cfg.theme.card_hover_bg else null,
                    .radius = ui.f(14),
                    .align_x = .center,
                    .align_y = .center,
                });
                ui.icon(ma.icon, 18 * scale, self.cfg.theme.text_bright, 0);
                ui.close();
            }
            ui.close();
        }
    }

    pub fn renderExpandableCard(
        self: *QuickSettings,
        ui: *ui_mod.Ui,
        idx: u32,
        icon_name: []const u8,
        active_icon_name: []const u8,
        title: []const u8,
        subtitle: []const u8,
        is_active: bool,
        icon_sz: u32,
        ui_sz: u32,
        sec_sz: u32,
        scale: u32,
    ) !void {
        const main_hov = ui.hovered("qs-card-main", idx);

        // Card background with hover/pressed states
        const card_bg = self.cfg.theme.surface;
        const hover_bg = self.cfg.theme.card_hover_bg;
        const bg = if (main_hov) hover_bg else card_bg;

        const fg = self.cfg.theme.text_bright;
        const sub_fg = if (is_active) self.cfg.theme.accent else self.cfg.theme.text_muted;
        const title_sz = ui_sz + 2 * scale;
        const sub_sz = sec_sz + scale;

        _ = ui.open(.{
            .id = "qs-card-main",
            .index = idx,
            .width = .{ .grow = .{} },
            .height = .{ .fixed = ui.s(QsLayout.card_h) },
            .direction = .row,
            .padding = .{ .left = ui.su(4), .right = ui.su(4), .top = ui.su(1), .bottom = ui.su(1) },
            .gap = ui.su(10),
            .bg = bg,
            .radius = ui.f(QsLayout.radius),
            .align_y = .center,
        });

        // Rounded-square accent-colored icon container
        const icon_bg = self.cfg.theme.accent;
        const icon_color = self.cfg.theme.accent_fg;

        _ = ui.open(.{
            .id = "qs-card-main-icon",
            .index = idx,
            .width = .{ .fixed = ui.s(52) },
            .height = .{ .fixed = ui.s(52) },
            .bg = icon_bg,
            .radius = ui.f(14),
            .align_x = .center,
            .align_y = .center,
        });
        ui.icon(if (is_active) active_icon_name else icon_name, icon_sz, icon_color, 0);
        ui.close();

        // Two-line text layout
        _ = ui.open(.{
            .id = "qs-card-main-text",
            .index = idx,
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
            .direction = .column,
            .gap = ui.su(2),
            .align_y = .center,
        });
        ui.text(title, .{
            .size = title_sz,
            .color = fg,
            .line_height = @intCast(title_sz + 2),
            .text_align = .left,
        });
        ui.text(subtitle, .{
            .size = sub_sz,
            .color = sub_fg,
            .line_height = @intCast(sub_sz + 1),
            .text_align = .left,
        });
        ui.close();

        ui.close();
    }

    fn renderSubMenu(
        self: *QuickSettings,
        ui: *ui_mod.Ui,
        target: renderer.Renderer,
        scale: u32,
        ui_sz: u32,
        sec_sz: u32,
        icon_sz: u32,
    ) !void {
        _ = ui_sz;
        const pad_u = QsLayout.pad * scale;
        const sub_sz = self.cfg.typography.submenu_text * scale;
        const btn_sz = self.cfg.typography.button_text * scale;
        const head_sz = self.cfg.typography.heading * scale;
        const content_w: u32 = if (target.width > 2 * pad_u) target.width - 2 * pad_u else target.width;

        const title = switch (self.view_mode) {
            .wifi_menu => "Wi-Fi",
            .bluetooth_menu => "Bluetooth",
            .audio_menu => "Sound & Devices",
            .notifications_menu => "Notifications",
            .recording_menu => "Recording Options",
            .display_menu => "Display",
            .power_menu => "Power",
            .keymap_menu => "Keymaps",
            .main => "",
        };

        const btn_size: u32 = 40 * scale;
        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .fixed = ui.s(56) },
            .direction = .row,
            .gap = ui.su(12),
            .align_y = .center,
        });

        const back_hov = ui.hovered("qs-back", 0);
        _ = ui.open(.{
            .id = "qs-back",
            .width = .{ .fixed = @floatFromInt(btn_size) },
            .height = .{ .fixed = @floatFromInt(btn_size) },
            .bg = if (back_hov) self.cfg.theme.surface else self.cfg.theme.card_bg,
            .radius = ui.f(20),
            .align_x = .center,
            .align_y = .center,
        });
        ui.icon("left", icon_sz, if (back_hov) self.cfg.theme.accent else self.cfg.theme.text_bright, 0);
        ui.close();

        ui.text(title, .{ .size = head_sz, .color = self.cfg.theme.text_bright });
        ui.spacerSized(.{ .grow = .{} }, .{ .fixed = 0 });

        if (self.view_mode == .wifi_menu or self.view_mode == .bluetooth_menu or self.view_mode == .keymap_menu) {
            const is_on = switch (self.view_mode) {
                .wifi_menu => self.sys.wifi_enabled,
                .bluetooth_menu => self.sys.bluetooth_enabled,
                .keymap_menu => keymap_module.isKeymapsActive(),
                else => false,
            };
            _ = ui.open(.{
                .id = "qs-header-toggle",
                .width = .{ .fixed = ui.s(46) },
                .height = .{ .fixed = ui.s(20) },
                .bg = if (is_on) self.cfg.theme.toggle_on else self.cfg.theme.toggle_off,
                .radius = ui.f(10),
                .padding = .all(ui.su(2)),
                .direction = .row,
                .align_y = .center,
            });
            if (is_on) ui.spacerSized(.{ .grow = .{} }, .{ .fixed = 0 });
            ui.rect(.{ .fixed = ui.s(16) }, .{ .fixed = ui.s(16) }, self.cfg.theme.slider_thumb, ui.f(8), .{});
            if (!is_on) ui.spacerSized(.{ .grow = .{} }, .{ .fixed = 0 });
            ui.close();
        }

        if (self.view_mode == .notifications_menu) {
            const hov = ui.hovered("qs-clear-notifs", 0);
            _ = ui.open(.{
                .id = "qs-clear-notifs",
                .width = .{ .fixed = @floatFromInt(btn_size) },
                .height = .{ .fixed = @floatFromInt(btn_size) },
                .bg = if (hov) self.cfg.theme.card_hover_bg else self.cfg.theme.card_bg,
                .radius = ui.f(20),
                .align_x = .center,
                .align_y = .center,
            });
            ui.icon("close", icon_sz, if (hov) self.cfg.theme.error_color else self.cfg.theme.text_bright, 0);
            ui.close();
        } else if (self.view_mode != .power_menu and self.view_mode != .recording_menu and self.view_mode != .display_menu and self.view_mode != .keymap_menu and self.view_mode != .audio_menu) {
            const hov = ui.hovered("qs-refresh", 0);
            const is_scanning_submenu = self.is_scanning and (self.view_mode == .wifi_menu or self.view_mode == .bluetooth_menu);
            _ = ui.open(.{
                .id = "qs-refresh",
                .width = .{ .fixed = @floatFromInt(btn_size) },
                .height = .{ .fixed = @floatFromInt(btn_size) },
                .bg = if (hov) self.cfg.theme.card_hover_bg else self.cfg.theme.card_bg,
                .radius = ui.f(20),
                .align_x = .center,
                .align_y = .center,
            });
            if (is_scanning_submenu) {
                ui.iconRotated("spinner", icon_sz, if (hov) self.cfg.theme.accent else self.cfg.theme.text_bright, self.scan_angle, 0);
            } else {
                ui.icon("refresh", icon_sz, if (hov) self.cfg.theme.accent else self.cfg.theme.text_bright, 0);
            }
            ui.close();
        }
        ui.close(); // header

        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
            .direction = .column,
            .gap = ui.su(QsLayout.row_gap),
            .clip_vertical = true,
        });

        const max_visible = self.maxVisibleRows();
        switch (self.view_mode) {
            .wifi_menu => try wifi.renderMenu(self, ui, target, scale, sec_sz, max_visible),
            .bluetooth_menu => try bluetooth.renderMenu(self, ui, target, scale, sec_sz, max_visible),
            .audio_menu => {
                // Earphone Safety Volume Toggle Card
                {
                    const is_enabled = self.sys.earbud_safety_enabled;
                    const hov = ui.hovered("qs-earbud-safety", 0);
                    _ = ui.open(.{
                        .id = "qs-earbud-safety",
                        .width = .{ .grow = .{} },
                        .height = .{ .fixed = ui.s(48) },
                        .direction = .row,
                        .padding = .{ .left = ui.su(12), .right = ui.su(12) },
                        .gap = ui.su(10),
                        .bg = if (is_enabled) self.cfg.theme.elevated else if (hov) self.cfg.theme.card_hover_bg else self.cfg.theme.card_bg,
                        .radius = ui.f(10),
                        .align_y = .center,
                    });

                    _ = ui.open(.{
                        .width = .{ .fixed = ui.s(26) },
                        .height = .{ .fixed = ui.s(26) },
                        .bg = if (is_enabled) self.cfg.theme.toggle_on else self.cfg.theme.btn_raised_bg,
                        .radius = ui.f(13),
                        .align_x = .center,
                        .align_y = .center,
                    });
                    ui.icon("volume-low", 15 * scale, if (is_enabled) self.cfg.theme.accent_fg else self.cfg.theme.text_bright, 0);
                    ui.close();

                    _ = ui.open(.{
                        .width = .{ .grow = .{} },
                        .height = .{ .grow = .{} },
                        .direction = .column,
                        .gap = ui.su(2),
                        .align_y = .center,
                        .clip_horizontal = true,
                    });
                    ui.text("Earphone Safety Volume", .{ .size = sub_sz, .color = self.cfg.theme.text_bright });
                    ui.text("Limit to 20% on connect", .{ .size = sec_sz, .color = if (is_enabled) self.cfg.theme.accent else self.cfg.theme.text_muted });
                    ui.close();

                    // Switch pill
                    _ = ui.open(.{
                        .width = .{ .fixed = ui.s(36) },
                        .height = .{ .fixed = ui.s(20) },
                        .bg = if (is_enabled) self.cfg.theme.accent else self.cfg.theme.slider_track,
                        .radius = ui.f(10),
                        .direction = .row,
                        .align_y = .center,
                        .padding = .{ .left = ui.su(3), .right = ui.su(3) },
                        .align_x = if (is_enabled) .right else .left,
                    });
                    _ = ui.open(.{
                        .width = .{ .fixed = ui.s(14) },
                        .height = .{ .fixed = ui.s(14) },
                        .bg = if (is_enabled) self.cfg.theme.accent_fg else self.cfg.theme.text_muted,
                        .radius = ui.f(7),
                    });
                    ui.close(); // knob
                    ui.close(); // switch

                    ui.close(); // earbud safety card
                }

                _ = ui.open(.{
                    .width = .{ .grow = .{} },
                    .height = .{ .fixed = ui.s(36) },
                    .direction = .row,
                    .padding = .all(ui.su(3)),
                    .gap = ui.su(4),
                    .bg = self.cfg.theme.surface,
                    .radius = ui.f(10),
                });
                const tab_labels = [_][]const u8{ "Output Devices", "Input Devices" };
                inline for (0..2) |tab_idx| {
                    const selected = (@as(usize, tab_idx) == @backingInt(self.audio_tab));
                    const tab_hov = ui.hovered(if (tab_idx == 0) "qs-audio-out" else "qs-audio-in", 0);
                    _ = ui.open(.{
                        .id = if (tab_idx == 0) "qs-audio-out" else "qs-audio-in",
                        .width = .{ .percent = 0.5 },
                        .height = .{ .grow = .{} },
                        .bg = if (selected) self.cfg.theme.elevated else if (tab_hov) self.cfg.theme.card_hover_bg else null,
                        .radius = ui.f(8),
                        .align_x = .center,
                        .align_y = .center,
                    });
                    ui.text(tab_labels[tab_idx], .{
                        .size = sub_sz,
                        .color = if (selected) self.cfg.theme.text_bright else self.cfg.theme.text_muted,
                    });
                    ui.close();
                }
                ui.close();

                const items = if (self.audio_tab == .output) self.sink_items.items else self.source_items.items;
                const is_output = self.audio_tab == .output;
                if (items.len == 0) {
                    types.emptyState(ui, if (is_output) "volume-muted" else "microphone", if (is_output) "No audio outputs found" else "No audio input devices found", "Click refresh to refresh", scale);
                } else {
                    const start_idx = self.scroll_offset;
                    const end_idx = @min(items.len, start_idx + max_visible);
                    for (items[start_idx..end_idx], start_idx..) |item, actual_idx| {
                        const hov = ui.hovered("qs-audio-item", @intCast(actual_idx));
                        _ = ui.open(.{
                            .id = "qs-audio-item",
                            .index = @intCast(actual_idx),
                            .width = .{ .grow = .{} },
                            .height = .fit,
                            .direction = .row,
                            .padding = .{ .left = ui.su(10), .right = ui.su(10), .top = ui.su(4), .bottom = ui.su(4) },
                            .gap = ui.su(10),
                            .bg = if (item.is_default) self.cfg.theme.elevated else if (hov) self.cfg.theme.card_hover_bg else self.cfg.theme.card_bg,
                            .radius = ui.f(10),
                            .border = ui.su(1),
                            .border_color = if (item.is_default) self.cfg.theme.accent else if (hov) self.cfg.theme.accent else self.cfg.theme.border,
                            .align_y = .center,
                        });
                        _ = ui.open(.{
                            .width = .{ .fixed = ui.s(24) },
                            .height = .{ .fixed = ui.s(24) },
                            .bg = if (item.is_default) self.cfg.theme.toggle_on else self.cfg.theme.btn_raised_bg,
                            .radius = ui.f(12),
                            .align_x = .center,
                            .align_y = .center,
                        });
                        ui.icon(if (is_output) "volume" else "microphone", 16 * scale, if (item.is_default) self.cfg.theme.accent_fg else self.cfg.theme.text_bright, 0);
                        ui.close();

                        _ = ui.open(.{
                            .width = .{ .grow = .{} },
                            .height = .{ .grow = .{} },
                            .direction = .column,
                            .gap = ui.su(2),
                            .align_y = .center,
                            .clip_horizontal = true,
                        });
                        ui.text(item.name[0..item.name_len], .{ .size = sub_sz, .color = self.cfg.theme.text_bright, .wrap = true, .width = @floatFromInt(content_w -| 90 * scale) });
                        var sub_buf: [64]u8 = undefined;
                        const sub_str = if (item.is_default)
                            std.fmt.bufPrint(&sub_buf, "Default • {d}%", .{item.volume_pct}) catch "Default"
                        else
                            std.fmt.bufPrint(&sub_buf, "Volume: {d}%", .{item.volume_pct}) catch "Audio";
                        ui.text(sub_str, .{
                            .size = sec_sz,
                            .color = if (item.is_default) self.cfg.theme.accent else self.cfg.theme.text_muted,
                        });
                        ui.close();

                        if (item.is_default) {
                            ui.icon("check", 16 * scale, self.cfg.theme.accent, 0);
                        }
                        ui.close(); // audio item
                    }
                }
            },
            .recording_menu => recording.renderMenu(self, ui, scale, sub_sz, btn_sz),
            .notifications_menu => {
                const store = &(self.notif_store orelse {
                    ui.close();
                    return;
                });
                if (store.items.items.len == 0) {
                    types.emptyState(ui, "bell-off", "No new notifications", "All caught up!", scale);
                } else {
                    const start_idx = self.scroll_offset;
                    const end_idx = @min(store.items.items.len, start_idx + max_visible);
                    for (store.items.items[start_idx..end_idx], start_idx..) |item, actual_idx| {
                        const hov = ui.hovered("qs-notif-card", @intCast(actual_idx));
                        _ = ui.open(.{
                            .id = "qs-notif-card",
                            .index = @intCast(actual_idx),
                            .width = .{ .grow = .{} },
                            .height = .{ .fixed = ui.s(56) },
                            .direction = .row,
                            .padding = .{ .left = ui.su(10), .right = ui.su(10), .top = ui.su(4), .bottom = ui.su(4) },
                            .gap = ui.su(8),
                            .bg = if (hov) self.cfg.theme.btn_raised_hover else self.cfg.theme.surface,
                            .radius = ui.f(self.cfg.theme.radius_button),
                            .border = ui.su(1),
                            .border_color = self.cfg.theme.border,
                            .align_y = .center,
                        });
                        ui.icon("bell", icon_sz, self.cfg.theme.accent, 0);
                        _ = ui.open(.{
                            .width = .{ .grow = .{} },
                            .height = .{ .grow = .{} },
                            .direction = .column,
                            .gap = 0,
                            .align_y = .center,
                            .clip_horizontal = true,
                        });
                        var time_buf: [16]u8 = undefined;
                        const time_str = item.formatRelativeTime(&time_buf);
                        var head_buf: [128]u8 = undefined;
                        const head_str = std.fmt.bufPrint(&head_buf, "{s} • {s}", .{ item.getAppName(), time_str }) catch item.getAppName();
                        ui.text(head_str, .{ .size = sec_sz, .color = self.cfg.theme.text_muted, .line_height = @intCast(sec_sz + 2) });
                        var trunc_sum: [128]u8 = undefined;
                        const sum = types.truncateText(target, &self.font, item.getSummary(), content_w -| 90 * scale, sub_sz, &trunc_sum);
                        ui.text(sum, .{ .size = sub_sz, .color = self.cfg.theme.text_bright, .line_height = @intCast(sub_sz + 3) });
                        const body = item.getBody();
                        if (body.len > 0) {
                            var trunc_bod: [128]u8 = undefined;
                            const bod = types.truncateText(target, &self.font, body, content_w -| 90 * scale, sec_sz, &trunc_bod);
                            ui.text(bod, .{ .size = sec_sz, .color = self.cfg.theme.text_muted, .line_height = @intCast(sec_sz + 2) });
                        }
                        ui.close();

                        const dismiss_hov = ui.hovered("qs-notif-dismiss", @intCast(actual_idx));
                        _ = ui.open(.{
                            .id = "qs-notif-dismiss",
                            .index = @intCast(actual_idx),
                            .width = .{ .fixed = ui.s(24) },
                            .height = .{ .fixed = ui.s(24) },
                            .bg = if (dismiss_hov) self.cfg.theme.btn_raised_hover else self.cfg.theme.btn_raised_bg,
                            .radius = ui.f(12),
                            .align_x = .center,
                            .align_y = .center,
                        });
                        ui.icon("close", 14 * scale, if (dismiss_hov) self.cfg.theme.error_color else self.cfg.theme.text_muted, 0);
                        ui.close();
                        ui.close(); // notification card
                    }
                }
            },
            .display_menu => {
                // Section 1: Display Scaling
                _ = ui.open(.{
                    .width = .{ .grow = .{} },
                    .direction = .column,
                    .gap = ui.su(8),
                });
                ui.text("Scaling", .{ .size = sub_sz, .color = self.cfg.theme.text_bright });
                _ = ui.open(.{
                    .width = .{ .grow = .{} },
                    .height = .{ .fixed = ui.s(40) },
                    .direction = .row,
                    .gap = ui.su(8),
                });
                inline for (display_scales, 0..) |s_val, s_idx| {
                    const sel = (self.display_scale_pct == s_val);
                    const hov = ui.hovered("qs-disp-scale", s_idx);
                    var s_buf: [16]u8 = undefined;
                    const s_lbl = std.fmt.bufPrint(&s_buf, "{d}%", .{s_val}) catch "100%";
                    _ = ui.open(.{
                        .id = "qs-disp-scale",
                        .index = s_idx,
                        .width = .{ .grow = .{} },
                        .height = .{ .grow = .{} },
                        .bg = if (sel) self.cfg.theme.elevated else if (hov) self.cfg.theme.card_hover_bg else self.cfg.theme.card_bg,
                        .radius = ui.f(10),
                        .border = ui.su(1),
                        .border_color = if (sel) self.cfg.theme.accent else if (hov) self.cfg.theme.accent else self.cfg.theme.border,
                        .align_x = .center,
                        .align_y = .center,
                    });
                    ui.text(s_lbl, .{
                        .size = btn_sz,
                        .color = if (sel) self.cfg.theme.accent else self.cfg.theme.text_bright,
                    });
                    ui.close();
                }
                ui.close(); // row
                ui.close(); // section 1

                // Section 2: Refresh Rate
                _ = ui.open(.{
                    .width = .{ .grow = .{} },
                    .direction = .column,
                    .gap = ui.su(8),
                });
                ui.text("Refresh Rate", .{ .size = sub_sz, .color = self.cfg.theme.text_bright });
                _ = ui.open(.{
                    .width = .{ .grow = .{} },
                    .height = .{ .fixed = ui.s(40) },
                    .direction = .row,
                    .gap = ui.su(8),
                });
                inline for (display_refresh_rates, 0..) |r_val, r_idx| {
                    const sel = (self.display_refresh_rate == r_val);
                    const hov = ui.hovered("qs-disp-refresh", r_idx);
                    var r_buf: [16]u8 = undefined;
                    const r_lbl = std.fmt.bufPrint(&r_buf, "{d} Hz", .{r_val}) catch "60 Hz";
                    _ = ui.open(.{
                        .id = "qs-disp-refresh",
                        .index = r_idx,
                        .width = .{ .grow = .{} },
                        .height = .{ .grow = .{} },
                        .bg = if (sel) self.cfg.theme.elevated else if (hov) self.cfg.theme.card_hover_bg else self.cfg.theme.card_bg,
                        .radius = ui.f(10),
                        .border = ui.su(1),
                        .border_color = if (sel) self.cfg.theme.accent else if (hov) self.cfg.theme.accent else self.cfg.theme.border,
                        .align_x = .center,
                        .align_y = .center,
                    });
                    ui.text(r_lbl, .{
                        .size = btn_sz,
                        .color = if (sel) self.cfg.theme.accent else self.cfg.theme.text_bright,
                    });
                    ui.close();
                }
                ui.close(); // row
                ui.close(); // section 2

                // Section 3: Resolution
                _ = ui.open(.{
                    .width = .{ .grow = .{} },
                    .direction = .column,
                    .gap = ui.su(8),
                });
                ui.text("Resolution", .{ .size = sub_sz, .color = self.cfg.theme.text_bright });
                _ = ui.open(.{
                    .width = .{ .grow = .{} },
                    .direction = .column,
                    .gap = ui.su(8),
                });
                const res_labels = [_][]const u8{
                    "1920x1080 (16:9 Full HD)",
                    "1680x1050 (16:10 WSXGA+)",
                    "1440x900 (16:10 WXGA+)",
                    "1280x720 (16:9 HD)",
                };
                for (res_labels, 0..) |res_lbl, res_idx| {
                    const sel = (self.display_resolution_idx == res_idx);
                    const hov = ui.hovered("qs-disp-res", @intCast(res_idx));
                    _ = ui.open(.{
                        .id = "qs-disp-res",
                        .index = @intCast(res_idx),
                        .width = .{ .grow = .{} },
                        .height = .{ .fixed = ui.s(42) },
                        .direction = .row,
                        .padding = .{ .left = ui.su(12), .right = ui.su(12) },
                        .gap = ui.su(10),
                        .bg = if (sel) self.cfg.theme.elevated else if (hov) self.cfg.theme.card_hover_bg else self.cfg.theme.card_bg,
                        .radius = ui.f(10),
                        .align_y = .center,
                    });
                    ui.icon("monitor", 18 * scale, if (sel) self.cfg.theme.accent else self.cfg.theme.text_bright, 0);
                    _ = ui.open(.{
                        .width = .{ .grow = .{} },
                        .height = .{ .grow = .{} },
                        .padding = .{ .left = ui.su(6) },
                        .align_y = .center,
                    });
                    ui.text(res_lbl, .{
                        .size = sub_sz,
                        .color = if (sel) self.cfg.theme.accent else self.cfg.theme.text_bright,
                    });
                    ui.close();
                    if (sel) {
                        ui.icon("check", 16 * scale, self.cfg.theme.accent, 0);
                    }
                    ui.close();
                }
                ui.close();
                ui.close(); // section 3

                // Section 4: Eye Comfort (Night Light)
                {
                    const hov = ui.hovered("qs-disp-eye-comfort", 0);
                    _ = ui.open(.{
                        .id = "qs-disp-eye-comfort",
                        .width = .{ .grow = .{} },
                        .height = .{ .fixed = ui.s(48) },
                        .direction = .row,
                        .padding = .{ .left = ui.su(12), .right = ui.su(12) },
                        .gap = ui.su(10),
                        .bg = if (self.eye_comfort_enabled) self.cfg.theme.elevated else if (hov) self.cfg.theme.card_hover_bg else self.cfg.theme.card_bg,
                        .radius = ui.f(10),
                        .align_y = .center,
                    });
                    ui.icon("moon", 20 * scale, if (self.eye_comfort_enabled) self.cfg.theme.accent else self.cfg.theme.text_bright, 0);
                    _ = ui.open(.{
                        .width = .{ .grow = .{} },
                        .height = .{ .grow = .{} },
                        .padding = .{ .left = ui.su(6) },
                        .align_y = .center,
                    });
                    ui.text("Eye Comfort", .{ .size = sub_sz, .color = self.cfg.theme.text_bright });
                    ui.close();

                    // Mini toggle switch
                    _ = ui.open(.{
                        .width = .{ .fixed = ui.s(42) },
                        .height = .{ .fixed = ui.s(22) },
                        .bg = if (self.eye_comfort_enabled) self.cfg.theme.toggle_on else self.cfg.theme.toggle_off,
                        .radius = ui.f(11),
                        .padding = .all(ui.su(2)),
                        .direction = .row,
                        .align_y = .center,
                    });
                    if (self.eye_comfort_enabled) ui.spacerSized(.{ .grow = .{} }, .{ .fixed = 0 });
                    ui.rect(.{ .fixed = ui.s(18) }, .{ .fixed = ui.s(18) }, self.cfg.theme.slider_thumb, ui.f(9), .{});
                    if (!self.eye_comfort_enabled) ui.spacerSized(.{ .grow = .{} }, .{ .fixed = 0 });
                    ui.close();

                    ui.close();
                }
            },
            .power_menu => powermode.renderMenu(self, ui, scale, sub_sz),
            .keymap_menu => {
                // Section 1: Key & Icon Size
                _ = ui.open(.{
                    .width = .{ .grow = .{} },
                    .direction = .column,
                    .gap = ui.su(8),
                });
                ui.text("Size", .{ .size = sub_sz, .color = self.cfg.theme.text_bright });
                _ = ui.open(.{
                    .width = .{ .grow = .{} },
                    .height = .{ .fixed = ui.s(38) },
                    .direction = .row,
                    .gap = ui.su(8),
                });
                const key_sizes = [_]struct { size: u32, label: []const u8 }{
                    .{ .size = 18, .label = "Small" },
                    .{ .size = 24, .label = "Medium" },
                    .{ .size = 32, .label = "Large" },
                    .{ .size = 40, .label = "X-Large" },
                };
                inline for (key_sizes, 0..) |ks, s_idx| {
                    const sel = (self.cfg.typography.keymap_text == ks.size);
                    const hov = ui.hovered("qs-km-size", s_idx);
                    _ = ui.open(.{
                        .id = "qs-km-size",
                        .index = s_idx,
                        .width = .{ .grow = .{} },
                        .height = .{ .grow = .{} },
                        .bg = if (sel) self.cfg.theme.elevated else if (hov) self.cfg.theme.card_hover_bg else self.cfg.theme.card_bg,
                        .radius = ui.f(10),
                        .border = ui.su(1),
                        .border_color = if (sel) self.cfg.theme.accent else if (hov) self.cfg.theme.accent else self.cfg.theme.border,
                        .align_x = .center,
                        .align_y = .center,
                    });
                    ui.text(ks.label, .{
                        .size = btn_sz,
                        .color = if (sel) self.cfg.theme.accent else self.cfg.theme.text_bright,
                    });
                    ui.close();
                }
                ui.close(); // row
                ui.close(); // section 1

                // Section 2: Placement (9 Places in 3x3 Grid)
                _ = ui.open(.{
                    .width = .{ .grow = .{} },
                    .direction = .column,
                    .gap = ui.su(8),
                });
                ui.text("Placement", .{ .size = sub_sz, .color = self.cfg.theme.text_bright });
                _ = ui.open(.{
                    .width = .{ .grow = .{} },
                    .direction = .column,
                    .gap = ui.su(6),
                });

                const pos_grid = [_][3]struct { pos: config.KeymapPosition, label: []const u8 }{
                    .{
                        .{ .pos = .top_left, .label = "Top Left" },
                        .{ .pos = .top_center, .label = "Top Center" },
                        .{ .pos = .top_right, .label = "Top Right" },
                    },
                    .{
                        .{ .pos = .center_left, .label = "Left" },
                        .{ .pos = .center, .label = "Center" },
                        .{ .pos = .center_right, .label = "Right" },
                    },
                    .{
                        .{ .pos = .bottom_left, .label = "Bottom Left" },
                        .{ .pos = .bottom_center, .label = "Bottom Center" },
                        .{ .pos = .bottom_right, .label = "Bottom Right" },
                    },
                };

                inline for (pos_grid, 0..) |row, row_idx| {
                    _ = ui.open(.{
                        .width = .{ .grow = .{} },
                        .height = .{ .fixed = ui.s(36) },
                        .direction = .row,
                        .gap = ui.su(6),
                    });
                    inline for (row, 0..) |cell, col_idx| {
                        const cell_idx = row_idx * 3 + col_idx;
                        const sel = (self.cfg.keymap_position == cell.pos);
                        const hov = ui.hovered("qs-km-pos", cell_idx);
                        _ = ui.open(.{
                            .id = "qs-km-pos",
                            .index = cell_idx,
                            .width = .{ .grow = .{} },
                            .height = .{ .grow = .{} },
                            .bg = if (sel) self.cfg.theme.elevated else if (hov) self.cfg.theme.card_hover_bg else self.cfg.theme.card_bg,
                            .radius = ui.f(8),
                            .border = if (sel) ui.su(1) else ui.su(0),
                            .border_color = if (sel) self.cfg.theme.accent else null,
                            .align_x = .center,
                            .align_y = .center,
                        });
                        ui.text(cell.label, .{
                            .size = sec_sz,
                            .color = if (sel) self.cfg.theme.accent else self.cfg.theme.text_bright,
                        });
                        ui.close();
                    }
                    ui.close();
                }
                ui.close(); // grid column
                ui.close(); // section 3
            },
            .main => {},
        }

        ui.close(); // list
    }

    fn appendHitAreas(self: *QuickSettings, ui: *ui_mod.Ui, scale: u32) !void {
        if (self.view_mode == .main) {
            // Row 1 & 2 cards
            inline for (0..4) |i| {
                // Icon area -> toggle action
                if (ui.rectOf("qs-card-main-icon", @intCast(i))) |rect| {
                    try self.appendRect(rect, scale, mainActionForCardIndex(i));
                }
                // Text/right area -> submenu/open action
                if (ui.rectOf("qs-card-main-text", @intCast(i))) |rect| {
                    try self.appendRect(rect, scale, mainChevronForCardIndex(i));
                }
            }

            // Row 3 buttons
            if (ui.rectOf("qs-row3-btn", 0)) |rect| try self.appendRect(rect, scale, .toggle_eye_comfort);
            if (ui.rectOf("qs-row3-btn", 1)) |rect| try self.appendRect(rect, scale, .toggle_dnd);
            if (ui.rectOf("qs-row3-btn", 2)) |rect| try self.appendRect(rect, scale, .toggle_caffeine);
            if (ui.rectOf("qs-row3-btn", 3)) |rect| try self.appendRect(rect, scale, .open_keymap_menu);

            // Sliders
            try sliders.appendHitAreas(self, ui, scale);

            // Quick profile actions (settings, lock, power)
            for (0..3) |i| {
                if (ui.rectOf("qs-quick-act", @intCast(i))) |rect| {
                    const act = [_]Action{ .open_display_menu, .lock, .open_session_power_menu };
                    try self.appendRect(rect, scale, act[i]);
                }
            }

            // Header lock / session buttons
            if (ui.rectOf("qs-header-btn", 0)) |rect| try self.appendRect(rect, scale, .lock);
            if (ui.rectOf("qs-header-btn", 1)) |rect| try self.appendRect(rect, scale, .open_session_power_menu);

            // Power button
            if (ui.rectOf("qs-power-btn", 0)) |rect| try self.appendRect(rect, scale, .open_session_power_menu);

            // MPRIS media
            const media = [_]Action{ .media_prev, .media_play_pause, .media_next };
            for (media, 0..) |action, idx| {
                if (ui.rectOf("qs-media", @intCast(idx))) |rect| try self.appendRect(rect, scale, action);
            }
            return;
        }

        if (ui.rectOf("qs-back", 0)) |rect| try self.appendRect(rect, scale, .back_to_main);
        if (self.view_mode == .notifications_menu) {
            if (ui.rectOf("qs-clear-notifs", 0)) |rect| try self.appendRect(rect, scale, .clear_notifications);
        } else if (self.view_mode != .power_menu and self.view_mode != .recording_menu and self.view_mode != .display_menu and self.view_mode != .keymap_menu and self.view_mode != .audio_menu) {
            if (ui.rectOf("qs-refresh", 0)) |rect| try self.appendRect(rect, scale, .refresh_sub_menu);
        }
        if (ui.rectOf("qs-header-toggle", 0)) |rect| {
            const action: Action = switch (self.view_mode) {
                .wifi_menu => .toggle_wifi,
                .bluetooth_menu => .toggle_bluetooth,
                .keymap_menu => .toggle_keymap,
                else => .toggle_wifi,
            };
            try self.appendRect(rect, scale, action);
        }

        const max_visible = self.maxVisibleRows();
        switch (self.view_mode) {
            .display_menu => {
                inline for (display_scales, 0..) |s_val, s_idx| {
                    if (ui.rectOf("qs-disp-scale", s_idx)) |rect| {
                        try self.appendRect(rect, scale, .{ .set_display_scale = s_val });
                    }
                }
                inline for (display_refresh_rates, 0..) |r_val, r_idx| {
                    if (ui.rectOf("qs-disp-refresh", r_idx)) |rect| {
                        try self.appendRect(rect, scale, .{ .set_display_refresh = r_val });
                    }
                }
                for (display_resolutions, 0..) |_, res_idx| {
                    if (ui.rectOf("qs-disp-res", @intCast(res_idx))) |rect| {
                        try self.appendRect(rect, scale, .{ .set_display_resolution = res_idx });
                    }
                }
                if (ui.rectOf("qs-disp-eye-comfort", 0)) |rect| {
                    try self.appendRect(rect, scale, .toggle_eye_comfort);
                }
            },
            .power_menu => try powermode.appendHitAreas(self, ui, scale),
            .wifi_menu => try wifi.appendHitAreas(self, ui, scale, max_visible),
            .bluetooth_menu => try bluetooth.appendHitAreas(self, ui, scale, max_visible),
            .audio_menu => {
                if (ui.rectOf("qs-earbud-safety", 0)) |rect| try self.appendRect(rect, scale, .toggle_earbud_safety);
                if (ui.rectOf("qs-audio-out", 0)) |rect| try self.appendRect(rect, scale, .set_audio_tab_output);
                if (ui.rectOf("qs-audio-in", 0)) |rect| try self.appendRect(rect, scale, .set_audio_tab_input);
                const items = if (self.audio_tab == .output) self.sink_items.items else self.source_items.items;
                const is_output = self.audio_tab == .output;
                const start_idx = self.scroll_offset;
                const end_idx = @min(items.len, start_idx + max_visible);
                var actual_idx = start_idx;
                while (actual_idx < end_idx) : (actual_idx += 1) {
                    if (ui.rectOf("qs-audio-item", @intCast(actual_idx))) |rect| {
                        try self.appendRect(rect, scale, if (is_output) .{ .select_audio_sink = actual_idx } else .{ .select_audio_source = actual_idx });
                    }
                }
            },
            .recording_menu => try recording.appendHitAreas(self, ui, scale),
            .notifications_menu => {
                const store = &(self.notif_store orelse return);
                const start_idx = self.scroll_offset;
                const end_idx = @min(store.items.items.len, start_idx + max_visible);
                var actual_idx = start_idx;
                while (actual_idx < end_idx) : (actual_idx += 1) {
                    if (ui.rectOf("qs-notif-dismiss", @intCast(actual_idx))) |rect| {
                        try self.appendRect(rect, scale, .{ .dismiss_notification = actual_idx });
                    }
                }
            },
            .keymap_menu => {
                const key_sizes = [_]u32{ 18, 24, 32, 40 };
                inline for (key_sizes, 0..) |ks, s_idx| {
                    if (ui.rectOf("qs-km-size", s_idx)) |rect| {
                        try self.appendRect(rect, scale, .{ .set_keymap_size = ks });
                    }
                }
                const positions = [_]config.KeymapPosition{
                    .top_left,    .top_center,    .top_right,
                    .center_left, .center,        .center_right,
                    .bottom_left, .bottom_center, .bottom_right,
                };
                inline for (positions, 0..) |pos, p_idx| {
                    if (ui.rectOf("qs-km-pos", p_idx)) |rect| {
                        try self.appendRect(rect, scale, .{ .set_keymap_pos = pos });
                    }
                }
            },
            .main => {},
        }
    }

    fn mainActionForCardIndex(idx: usize) Action {
        return switch (idx) {
            0 => .toggle_wifi,
            1 => .toggle_bluetooth,
            2 => .toggle_recording,
            3 => .cycle_power_profile,
            else => .toggle_wifi,
        };
    }

    fn mainChevronForCardIndex(idx: usize) Action {
        return switch (idx) {
            0 => .open_wifi_menu,
            1 => .open_bluetooth_menu,
            2 => .open_recording_menu,
            3 => .open_power_menu,
            else => .open_wifi_menu,
        };
    }

    pub fn toggleDnd(self: *QuickSettings) void {
        self.dnd_enabled = !self.dnd_enabled;
        saveDnd(self.dnd_enabled);
        sys_status.spawnCmd("dunstctl set-paused toggle 2>/dev/null || makoctl mode -t dnd 2>/dev/null || true");
    }

    pub fn toggleEyeComfort(self: *QuickSettings) void {
        self.eye_comfort_enabled = !self.eye_comfort_enabled;
        setEyeComfort(self.eye_comfort_enabled);
    }

    fn appendRect(self: *QuickSettings, rect: renderer.Rect, scale: u32, action: Action) !void {
        const iscale: i32 = @intCast(scale);
        const lw: u32 = @intCast(@divTrunc(@as(i32, @intCast(rect.w)) + iscale - 1, iscale));
        const lh: u32 = @intCast(@divTrunc(@as(i32, @intCast(rect.h)) + iscale - 1, iscale));
        if (lw == 0 or lh == 0) return;
        try self.hit_areas.append(self.allocator, .{
            .x = @divTrunc(rect.x, iscale),
            .y = @divTrunc(rect.y, iscale),
            .w = lw,
            .h = lh,
            .action = action,
        });
    }

    pub fn queryDisplaySettings(self: *QuickSettings) void {
        if (loadDisplayScale()) |saved_scale| {
            self.display_scale_pct = saved_scale;
        }
        if (loadDisplayRefresh()) |saved_hz| {
            self.display_refresh_rate = saved_hz;
        }
        if (loadDisplayResolutionIdx()) |saved_idx| {
            self.display_resolution_idx = saved_idx;
        }

        const pipe = c.popen("export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; wlr-randr 2>/dev/null", "r") orelse return;
        defer _ = c.pclose(pipe);

        var buf: [512]u8 = undefined;
        while (c.fgets(&buf, buf.len, pipe)) |line_ptr| {
            const line = std.mem.span(line_ptr);
            const trimmed = std.mem.trim(u8, line, " \t\r\n");

            // Parse Scale: e.g. "Scale: 1.250000"
            if (std.mem.indexOf(u8, trimmed, "Scale:")) |idx| {
                const after = std.mem.trim(u8, trimmed[idx + 6 ..], " \t");
                if (std.fmt.parseFloat(f32, after)) |scale_val| {
                    const pct = @as(u32, @intFromFloat(scale_val * 100.0 + 0.5));
                    var closest_scale: u32 = display_scales[0];
                    var min_diff: u32 = 9999;
                    for (display_scales) |s| {
                        const diff = if (s > pct) s - pct else pct - s;
                        if (diff < min_diff) {
                            min_diff = diff;
                            closest_scale = s;
                        }
                    }
                    self.display_scale_pct = closest_scale;
                } else |_| {}
            }

            // Parse current mode: e.g. "1920x1080 px, 144.003006 Hz (preferred, current)"
            if (std.mem.indexOf(u8, trimmed, "current") != null and std.mem.indexOf(u8, trimmed, "px,") != null) {
                if (std.mem.indexOf(u8, trimmed, " px,")) |px_idx| {
                    const res_part = std.mem.trim(u8, trimmed[0..px_idx], " \t");
                    for (display_resolutions, 0..) |res, i| {
                        if (std.mem.eql(u8, res, res_part)) {
                            self.display_resolution_idx = i;
                            break;
                        }
                    }
                }

                if (std.mem.indexOf(u8, trimmed, "px,")) |px_idx| {
                    const after_px = trimmed[px_idx + 3 ..];
                    if (std.mem.indexOf(u8, after_px, "Hz")) |hz_idx| {
                        const hz_str = std.mem.trim(u8, after_px[0..hz_idx], " \t");
                        if (std.fmt.parseFloat(f32, hz_str)) |hz_val| {
                            const rounded_hz = @as(u32, @intFromFloat(hz_val + 0.5));
                            var closest_hz: u32 = display_refresh_rates[0];
                            var min_diff: u32 = 9999;
                            for (display_refresh_rates) |r| {
                                const diff = if (r > rounded_hz) r - rounded_hz else rounded_hz - r;
                                if (diff < min_diff) {
                                    min_diff = diff;
                                    closest_hz = r;
                                }
                            }
                            self.display_refresh_rate = closest_hz;
                        } else |_| {}
                    }
                }
            }
        }
    }
};

const caffeine_pid_path = "/tmp/mizu-caffeine.pid";

fn readCaffeinePid() ?i32 {
    const f = c.fopen(caffeine_pid_path, "rb") orelse return null;
    defer _ = c.fclose(f);
    var buf: [32]u8 = undefined;
    const n = c.fread(&buf, 1, buf.len - 1, f);
    if (n == 0) return null;
    buf[n] = 0;
    const pid = std.fmt.parseInt(i32, std.mem.trim(u8, buf[0..n], " \t\r\n"), 10) catch return null;
    if (pid <= 0) return null;
    return pid;
}

fn isCaffeineActive() bool {
    const pid = readCaffeinePid() orelse return false;
    if (c.kill(pid, 0) == 0) return true;
    _ = c.unlink(caffeine_pid_path);
    return false;
}

fn writeCaffeinePid(pid: i32) void {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrintSentinel(&buf, "{d}\n", .{pid}, 0) catch return;
    const f = c.fopen(caffeine_pid_path, "wb") orelse return;
    defer _ = c.fclose(f);
    _ = c.fwrite(text.ptr, 1, text.len, f);
}

fn startCaffeine() bool {
    if (builtin.is_test) {
        writeCaffeinePid(999999);
        return true;
    }
    const pid = c.fork();
    if (pid < 0) return false;
    if (pid == 0) {
        _ = c.setsid();
        const devnull = c.open("/dev/null", c.O_RDWR);
        if (devnull >= 0) {
            _ = c.dup2(devnull, 0);
            _ = c.dup2(devnull, 1);
            _ = c.dup2(devnull, 2);
            _ = c.close(devnull);
        }
        _ = c.execl("/proc/self/exe", "mizu", "caffeine", @as(?*anyopaque, null));
        c.exit(1);
    }
    writeCaffeinePid(pid);
    return true;
}

fn setCaffeine(enabled: bool) void {
    if (enabled) {
        if (isCaffeineActive()) return;
        _ = startCaffeine();
    } else {
        if (builtin.is_test) {
            _ = c.unlink(caffeine_pid_path);
            return;
        }
        if (readCaffeinePid()) |pid| {
            _ = c.kill(pid, c.SIGTERM);
        }
        _ = c.unlink(caffeine_pid_path);
    }
}

const eye_comfort_file = "/tmp/mizu-eye-comfort";
const eye_comfort_pid = "/tmp/mizu-eye-comfort.pid";

fn ensureCacheDir() void {
    const home = c.getenv("HOME") orelse return;
    var dir_buf: [256]u8 = undefined;
    const dir = std.fmt.bufPrintSentinel(&dir_buf, "{s}/.cache/mizu", .{std.mem.span(home)}, 0) catch return;
    _ = c.mkdir(dir.ptr, 0o755);
}

pub fn saveDisplayScale(scale_pct: u32) void {
    ensureCacheDir();
    const home = c.getenv("HOME") orelse return;
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/.cache/mizu/display_scale", .{std.mem.span(home)}, 0) catch return;
    const f = c.fopen(path.ptr, "wb") orelse return;
    defer _ = c.fclose(f);
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}\n", .{scale_pct}) catch return;
    _ = c.fwrite(s.ptr, 1, s.len, f);
}

pub fn loadDisplayScale() ?u32 {
    const home = c.getenv("HOME") orelse return null;
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/.cache/mizu/display_scale", .{std.mem.span(home)}, 0) catch return null;
    const f = c.fopen(path.ptr, "rb") orelse return null;
    defer _ = c.fclose(f);
    var buf: [16]u8 = undefined;
    const n = c.fread(&buf, 1, buf.len - 1, f);
    if (n == 0) return null;
    buf[n] = 0;
    const s = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return std.fmt.parseInt(u32, s, 10) catch null;
}

pub fn saveDisplayRefresh(hz: u32) void {
    ensureCacheDir();
    const home = c.getenv("HOME") orelse return;
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/.cache/mizu/display_refresh", .{std.mem.span(home)}, 0) catch return;
    const f = c.fopen(path.ptr, "wb") orelse return;
    defer _ = c.fclose(f);
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}\n", .{hz}) catch return;
    _ = c.fwrite(s.ptr, 1, s.len, f);
}

pub fn loadDisplayRefresh() ?u32 {
    const home = c.getenv("HOME") orelse return null;
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/.cache/mizu/display_refresh", .{std.mem.span(home)}, 0) catch return null;
    const f = c.fopen(path.ptr, "rb") orelse return null;
    defer _ = c.fclose(f);
    var buf: [16]u8 = undefined;
    const n = c.fread(&buf, 1, buf.len - 1, f);
    if (n == 0) return null;
    buf[n] = 0;
    const s = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return std.fmt.parseInt(u32, s, 10) catch null;
}

pub fn saveDisplayResolution(res: []const u8) void {
    ensureCacheDir();
    const home = c.getenv("HOME") orelse return;
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/.cache/mizu/display_resolution", .{std.mem.span(home)}, 0) catch return;
    const f = c.fopen(path.ptr, "wb") orelse return;
    defer _ = c.fclose(f);
    _ = c.fwrite(res.ptr, 1, res.len, f);
    _ = c.fwrite("\n", 1, 1, f);
}

pub fn loadDisplayResolution(buf: *[64]u8) ?[]const u8 {
    const home = c.getenv("HOME") orelse return null;
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/.cache/mizu/display_resolution", .{std.mem.span(home)}, 0) catch return null;
    const f = c.fopen(path.ptr, "rb") orelse return null;
    defer _ = c.fclose(f);
    const n = c.fread(buf, 1, buf.len - 1, f);
    if (n == 0) return null;
    buf[n] = 0;
    const s = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (s.len == 0) return null;
    return s;
}

pub fn loadDisplayResolutionIdx() ?usize {
    var buf: [64]u8 = undefined;
    const res = loadDisplayResolution(&buf) orelse return null;
    for (display_resolutions, 0..) |r, i| {
        if (std.mem.eql(u8, r, res)) return i;
    }
    return null;
}

pub fn saveEyeComfort(enabled: bool) void {
    ensureCacheDir();
    const home = c.getenv("HOME") orelse return;
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/.cache/mizu/eye_comfort", .{std.mem.span(home)}, 0) catch return;
    if (enabled) {
        const f = c.fopen(path.ptr, "wb") orelse return;
        defer _ = c.fclose(f);
        _ = c.fwrite("1\n", 1, 2, f);
    } else {
        _ = c.unlink(path.ptr);
    }
}

pub fn loadEyeComfort() bool {
    const home = c.getenv("HOME") orelse return false;
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/.cache/mizu/eye_comfort", .{std.mem.span(home)}, 0) catch return false;
    return c.access(path.ptr, c.F_OK) == 0;
}

pub fn saveDnd(enabled: bool) void {
    ensureCacheDir();
    const home = c.getenv("HOME") orelse return;
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/.cache/mizu/dnd", .{std.mem.span(home)}, 0) catch return;
    if (enabled) {
        if (c.fopen(path.ptr, "wb")) |f| {
            _ = c.fwrite("1\n", 1, 2, f);
            _ = c.fclose(f);
        }
        if (c.fopen("/tmp/mizu-dnd", "w")) |tf| {
            _ = c.fclose(tf);
        }
    } else {
        _ = c.unlink(path.ptr);
        _ = c.unlink("/tmp/mizu-dnd");
    }
}

pub fn loadDnd() bool {
    const home = c.getenv("HOME");
    if (home) |h| {
        var path_buf: [256]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&path_buf, "{s}/.cache/mizu/dnd", .{std.mem.span(h)}, 0)) |path| {
            if (c.access(path.ptr, c.F_OK) == 0) return true;
        } else |_| {}
    }
    return c.access("/tmp/mizu-dnd", c.F_OK) == 0;
}

fn readEyeComfortPid() ?i32 {
    const f = c.fopen(eye_comfort_pid, "rb") orelse return null;
    defer _ = c.fclose(f);
    var buf: [32]u8 = undefined;
    const n = c.fread(&buf, 1, buf.len - 1, f);
    if (n == 0) return null;
    buf[n] = 0;
    const pid = std.fmt.parseInt(i32, std.mem.trim(u8, buf[0..n], " \t\r\n"), 10) catch return null;
    if (pid <= 0) return null;
    return pid;
}

pub fn isEyeComfortActive() bool {
    if (readEyeComfortPid()) |pid| {
        if (c.kill(pid, 0) == 0) return true;
        _ = c.unlink(eye_comfort_pid);
    }
    return c.access(eye_comfort_file, c.F_OK) == 0;
}

pub fn setEyeComfort(enabled: bool) void {
    saveEyeComfort(enabled);
    if (enabled) {
        if (c.fopen(eye_comfort_file, "w")) |f| {
            _ = c.fclose(f);
        }
        sys_status.spawnCmd("export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; (which wlsunset >/dev/null 2>&1 && (wlsunset -t 4500 -T 4501 & echo $! > " ++ eye_comfort_pid ++ ")) || (which hyprsunset >/dev/null 2>&1 && (hyprsunset --temperature 4500 & echo $! > " ++ eye_comfort_pid ++ ")) || true");
    } else {
        if (readEyeComfortPid()) |pid| {
            _ = c.kill(pid, c.SIGTERM);
        }
        _ = c.unlink(eye_comfort_file);
        _ = c.unlink(eye_comfort_pid);
        sys_status.spawnCmd("killall -9 wlsunset hyprsunset gammastep 2>/dev/null || true");
    }
}

pub fn applyDisplayScale(scale_pct: u32) void {
    var cmd_buf: [512]u8 = undefined;
    const scale_flt: f32 = @as(f32, @floatFromInt(scale_pct)) / 100.0;
    const cmd = std.fmt.bufPrintSentinel(&cmd_buf, "export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; for out in $(wlr-randr 2>/dev/null | awk '/^[a-zA-Z0-9-]+/ {{print $1}}'); do wlr-randr --output \"$out\" --scale {d:.2} 2>/dev/null || true; done", .{scale_flt}, 0) catch return;
    sys_status.spawnCmd(cmd);
}

pub fn applyDisplayRefresh(hz: u32) void {
    var cmd_buf: [512]u8 = undefined;
    const cmd = std.fmt.bufPrintSentinel(&cmd_buf, "export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; for out in $(wlr-randr 2>/dev/null | awk '/^[a-zA-Z0-9-]+/ {{print $1}}'); do mode=$(wlr-randr 2>/dev/null | awk -v h=\"{d}\" '/px,/ && $3 ~ (\"^\" h) {{print $1 \"@\" $3 \"Hz\"; exit}}'); if [ -n \"$mode\" ]; then wlr-randr --output \"$out\" --mode \"$mode\" 2>/dev/null || true; fi; done", .{hz}, 0) catch return;
    sys_status.spawnCmd(cmd);
}

pub fn applyDisplayResolution(res: []const u8) void {
    var cmd_buf: [512]u8 = undefined;
    const cmd = std.fmt.bufPrintSentinel(&cmd_buf, "export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; for out in $(wlr-randr 2>/dev/null | awk '/^[a-zA-Z0-9-]+/ {{print $1}}'); do wlr-randr --output \"$out\" --mode {s} 2>/dev/null || true; done", .{res}, 0) catch return;
    sys_status.spawnCmd(cmd);
}

pub fn restoreSessionSettings() void {
    // 1. Display scale
    if (loadDisplayScale()) |saved_scale| {
        applyDisplayScale(saved_scale);
    }

    // 2. Display refresh rate
    if (loadDisplayRefresh()) |saved_hz| {
        applyDisplayRefresh(saved_hz);
    }

    // 3. Display resolution
    var res_buf: [64]u8 = undefined;
    if (loadDisplayResolution(&res_buf)) |saved_res| {
        applyDisplayResolution(saved_res);
    }

    // 4. Eye comfort
    if (loadEyeComfort()) {
        if (!isEyeComfortActive()) {
            setEyeComfort(true);
        }
    }

    // 5. DND
    if (loadDnd()) {
        if (c.fopen("/tmp/mizu-dnd", "w")) |tf| {
            _ = c.fclose(tf);
        }
        sys_status.spawnCmd("dunstctl set-paused true 2>/dev/null || makoctl mode -a dnd 2>/dev/null || true");
    }
}

test "QuickSettings calculateSliderPercent" {
    try std.testing.expectEqual(@as(u32, 0), QuickSettings.calculateSliderPercent(10, 10, 100));
    try std.testing.expectEqual(@as(u32, 50), QuickSettings.calculateSliderPercent(60, 10, 100));
    try std.testing.expectEqual(@as(u32, 100), QuickSettings.calculateSliderPercent(110, 10, 100));
    try std.testing.expectEqual(@as(u32, 100), QuickSettings.calculateSliderPercent(200, 10, 100));
    try std.testing.expectEqual(@as(u32, 0), QuickSettings.calculateSliderPercent(0, 10, 100));
}

test "QuickSettings queryDisplaySettings and display settings state" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var qs = QuickSettings{
        .allocator = allocator,
        .cfg = cfg,
        .font = undefined,
        .sys = undefined,
        .hit_areas = std.ArrayList(HitArea).empty,
        .wifi = wifi.State.init(allocator),
        .bluetooth = bluetooth.State.init(),
        .recording = recording.State.init(),
        .sink_items = std.ArrayList(AudioDeviceItem).empty,
        .source_items = std.ArrayList(AudioDeviceItem).empty,
    };
    defer {
        qs.wifi.deinit(allocator);
        qs.bluetooth.deinit(allocator);
        qs.sink_items.deinit(allocator);
        qs.source_items.deinit(allocator);
        qs.hit_areas.deinit(allocator);
    }

    qs.queryDisplaySettings();
    var valid_scale = false;
    for (display_scales) |s| {
        if (qs.display_scale_pct == s) valid_scale = true;
    }
    try std.testing.expect(valid_scale);

    var valid_hz = false;
    for (display_refresh_rates) |r| {
        if (qs.display_refresh_rate == r) valid_hz = true;
    }
    try std.testing.expect(valid_hz);

    try std.testing.expect(qs.display_resolution_idx < display_resolutions.len);
}

test "QuickSettings persistence of display scale, refresh, resolution, eye comfort, and dnd" {
    // Test scale
    saveDisplayScale(125);
    try std.testing.expectEqual(@as(?u32, 125), loadDisplayScale());
    saveDisplayScale(100);
    try std.testing.expectEqual(@as(?u32, 100), loadDisplayScale());

    // Test refresh
    saveDisplayRefresh(144);
    try std.testing.expectEqual(@as(?u32, 144), loadDisplayRefresh());

    // Test resolution
    saveDisplayResolution("1920x1080");
    var res_buf: [64]u8 = undefined;
    const res = loadDisplayResolution(&res_buf);
    try std.testing.expect(res != null);
    try std.testing.expectEqualStrings("1920x1080", res.?);
    try std.testing.expectEqual(@as(?usize, 0), loadDisplayResolutionIdx());

    // Test eye comfort
    saveEyeComfort(true);
    try std.testing.expect(loadEyeComfort());
    saveEyeComfort(false);
    try std.testing.expect(!loadEyeComfort());

    // Test DND
    saveDnd(true);
    try std.testing.expect(loadDnd());
    saveDnd(false);
    try std.testing.expect(!loadDnd());
}

test "QuickSettings handlePointerAxis scrolling" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var qs = QuickSettings{
        .allocator = allocator,
        .cfg = cfg,
        .font = undefined,
        .sys = undefined,
        .hit_areas = std.ArrayList(HitArea).empty,
        .wifi = wifi.State.init(allocator),
        .bluetooth = bluetooth.State.init(),
        .recording = recording.State.init(),
        .sink_items = std.ArrayList(AudioSinkItem).empty,
        .source_items = std.ArrayList(AudioDeviceItem).empty,
    };
    defer {
        qs.wifi.deinit(allocator);
        qs.bluetooth.deinit(allocator);
        qs.sink_items.deinit(allocator);
        qs.source_items.deinit(allocator);
        qs.hit_areas.deinit(allocator);
    }

    // In main view with no slider hovered, scrolling should be ignored
    try std.testing.expect(!qs.handlePointerAxis(0, 0, 1));

    // Switch to wifi_menu with 10 items (more than max visible 7)
    qs.view_mode = .wifi_menu;
    qs.scroll_offset = 0;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try qs.wifi.items.append(allocator, .{
            .ssid_len = 4,
            .signal = 80,
            .is_active = (i == 0),
        });
    }

    // Scrolling down increases offset up to max_scroll (10 - 7 = 3)
    try std.testing.expect(qs.handlePointerAxis(0, 0, 1));
    try std.testing.expectEqual(@as(usize, 1), qs.scroll_offset);
    try std.testing.expect(qs.handlePointerAxis(0, 0, 1));
    try std.testing.expectEqual(@as(usize, 2), qs.scroll_offset);
    try std.testing.expect(qs.handlePointerAxis(0, 0, 1));
    try std.testing.expectEqual(@as(usize, 3), qs.scroll_offset);
    // Beyond max_scroll should return false
    try std.testing.expect(!qs.handlePointerAxis(0, 0, 1));

    // Scrolling up decreases offset back to 0
    try std.testing.expect(qs.handlePointerAxis(0, 0, -1));
    try std.testing.expectEqual(@as(usize, 2), qs.scroll_offset);
    try std.testing.expect(qs.handlePointerAxis(0, 0, -1));
    try std.testing.expectEqual(@as(usize, 1), qs.scroll_offset);
    try std.testing.expect(qs.handlePointerAxis(0, 0, -1));
    try std.testing.expectEqual(@as(usize, 0), qs.scroll_offset);
}

test "QuickSettings wifi password keyboard input" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var qs = QuickSettings{
        .allocator = allocator,
        .cfg = cfg,
        .font = undefined,
        .sys = undefined,
        .hit_areas = std.ArrayList(HitArea).empty,
        .wifi = wifi.State.init(allocator),
        .bluetooth = bluetooth.State.init(),
        .recording = recording.State.init(),
        .sink_items = std.ArrayList(AudioSinkItem).empty,
        .source_items = std.ArrayList(AudioDeviceItem).empty,
    };
    defer {
        qs.wifi.deinit(allocator);
        qs.bluetooth.deinit(allocator);
        qs.sink_items.deinit(allocator);
        qs.source_items.deinit(allocator);
        qs.hit_areas.deinit(allocator);
    }

    // When wifi_input_idx is null, keys are ignored
    try std.testing.expect(!qs.handleKey(c.XKB_KEY_a, "a"));

    // Activate wifi input
    qs.wifi.input_idx = 0;
    try std.testing.expect(qs.handleKey(c.XKB_KEY_p, "p"));
    try std.testing.expect(qs.handleKey(c.XKB_KEY_a, "a"));
    try std.testing.expect(qs.handleKey(c.XKB_KEY_s, "s"));
    try std.testing.expect(qs.handleKey(c.XKB_KEY_s, "s"));
    try std.testing.expectEqualStrings("pass", qs.wifi.password[0..qs.wifi.password_len]);

    // Backspace
    try std.testing.expect(qs.handleKey(c.XKB_KEY_BackSpace, ""));
    try std.testing.expectEqualStrings("pas", qs.wifi.password[0..qs.wifi.password_len]);

    // Escape cancels
    try std.testing.expect(qs.handleKey(c.XKB_KEY_Escape, ""));
    try std.testing.expect(qs.wifi.input_idx == null);
    try std.testing.expectEqual(@as(usize, 0), qs.wifi.password_len);
}

test "QuickSettings wifi password hit areas and connect button" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var qs = QuickSettings{
        .allocator = allocator,
        .cfg = cfg,
        .font = undefined,
        .sys = sys_status.SysStatus.init(allocator),
        .hit_areas = std.ArrayList(HitArea).empty,
        .wifi = wifi.State.init(allocator),
        .bluetooth = bluetooth.State.init(),
        .recording = recording.State.init(),
        .sink_items = std.ArrayList(AudioSinkItem).empty,
        .source_items = std.ArrayList(AudioDeviceItem).empty,
    };
    defer {
        qs.wifi.deinit(allocator);
        qs.bluetooth.deinit(allocator);
        qs.sink_items.deinit(allocator);
        qs.source_items.deinit(allocator);
        qs.hit_areas.deinit(allocator);
        qs.sys.deinit();
    }

    var item = WifiItem{
        .signal = 80,
        .is_active = false,
    };
    const test_ssid = "TestRouter";
    @memcpy(item.ssid[0..test_ssid.len], test_ssid);
    item.ssid_len = test_ssid.len;
    const test_sec = "WPA2";
    @memcpy(item.security[0..test_sec.len], test_sec);
    item.security_len = test_sec.len;
    try qs.wifi.items.append(allocator, item);

    // Click to select wifi (opens input)
    try qs.hit_areas.append(allocator, .{
        .x = 10,
        .y = 10,
        .w = 100,
        .h = 40,
        .action = .{ .select_wifi = 0 },
    });
    try std.testing.expect(qs.handlePointerButton(15, 15, 272, true));
    try std.testing.expectEqual(@as(?usize, 0), qs.wifi.input_idx);

    // Type password
    try std.testing.expect(qs.handleKey(c.XKB_KEY_s, "s"));
    try std.testing.expect(qs.handleKey(c.XKB_KEY_e, "e"));
    try std.testing.expect(qs.handleKey(c.XKB_KEY_c, "c"));
    try std.testing.expect(qs.handleKey(c.XKB_KEY_r, "r"));
    try std.testing.expect(qs.handleKey(c.XKB_KEY_e, "e"));
    try std.testing.expect(qs.handleKey(c.XKB_KEY_t, "t"));
    try std.testing.expectEqualStrings("secret", qs.wifi.password[0..qs.wifi.password_len]);

    // Click connect button initiates connection
    try qs.hit_areas.append(allocator, .{
        .x = 150,
        .y = 100,
        .w = 60,
        .h = 24,
        .action = .wifi_connect_submit,
    });
    try std.testing.expect(qs.handlePointerButton(160, 110, 272, true));
    try std.testing.expect(qs.wifi.connect_state == .connecting or qs.wifi.connect_state == .failed or qs.wifi.connect_state == .success);

    // Cancel resets input and password
    qs.wifi.connect_state = .idle;
    try qs.hit_areas.append(allocator, .{
        .x = 20,
        .y = 100,
        .w = 60,
        .h = 24,
        .action = .wifi_cancel,
    });
    try std.testing.expect(qs.handlePointerButton(30, 110, 272, true));
    try std.testing.expect(qs.wifi.input_idx == null);
    try std.testing.expectEqual(@as(usize, 0), qs.wifi.password_len);

    var wait_iter: usize = 0;
    while (qs.wifi.worker_running and wait_iter < 50) : (wait_iter += 1) {
        _ = c.usleep(10_000);
        _ = qs.checkWifiStatus();
    }
}

test "QuickSettings saved wifi connection and bluetooth offline UX transitions" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var qs = QuickSettings{
        .allocator = allocator,
        .cfg = cfg,
        .font = undefined,
        .sys = sys_status.SysStatus.init(allocator),
        .hit_areas = std.ArrayList(HitArea).empty,
        .wifi = wifi.State.init(allocator),
        .bluetooth = bluetooth.State.init(),
        .recording = recording.State.init(),
        .sink_items = std.ArrayList(AudioSinkItem).empty,
        .source_items = std.ArrayList(AudioDeviceItem).empty,
    };
    defer {
        qs.wifi.deinit(allocator);
        qs.bluetooth.deinit(allocator);
        qs.sink_items.deinit(allocator);
        qs.source_items.deinit(allocator);
        qs.hit_areas.deinit(allocator);
        qs.sys.deinit();
    }

    // Saved Wi-Fi click connects without prompt.
    var item = WifiItem{
        .signal = 92,
        .is_active = false,
        .is_saved = true,
    };
    const ssid = "HomeFiber";
    @memcpy(item.ssid[0..ssid.len], ssid);
    item.ssid_len = ssid.len;
    try qs.wifi.items.append(allocator, item);

    // Simulate Wi-Fi worker completing successfully
    qs.wifi.worker_running = true;
    qs.wifi.connect_state = .connecting;
    @memcpy(qs.wifi.connecting_ssid[0..ssid.len], ssid);
    qs.wifi.connecting_ssid_len = ssid.len;

    @memcpy(qs.wifi.worker.ssid[0..ssid.len], ssid);
    qs.wifi.worker.ssid_len = ssid.len;
    qs.wifi.worker.success.store(true, .release);
    qs.wifi.worker.done.store(true, .release);

    try std.testing.expect(qs.checkWifiStatus());
    try std.testing.expect(qs.wifi.items.items[0].is_active);
    try std.testing.expectEqualStrings("HomeFiber", qs.sys.wifi_ssid[0..qs.sys.wifi_ssid_len]);
    try std.testing.expectEqual(@as(usize, 0), qs.wifi.connecting_ssid_len);

    // 2. Bluetooth offline item connection flow
    var bt_dev = BluetoothItem{
        .connected = false,
    };
    const bt_mac = "AA:BB:CC:DD:EE:FF";
    @memcpy(bt_dev.mac[0..bt_mac.len], bt_mac);
    bt_dev.mac_len = bt_mac.len;
    const bt_name = "Wireless Earbuds";
    @memcpy(bt_dev.name[0..bt_name.len], bt_name);
    bt_dev.name_len = bt_name.len;
    try qs.bluetooth.items.append(allocator, bt_dev);

    // Simulate connecting state
    qs.bluetooth.status = .connecting;
    @memcpy(qs.bluetooth.connect_mac[0..bt_mac.len], bt_mac);
    qs.bluetooth.connect_mac_len = bt_mac.len;
    @memcpy(qs.bluetooth.connect_worker.mac[0..bt_mac.len], bt_mac);
    qs.bluetooth.connect_worker.mac_len = bt_mac.len;

    // Simulate successful Bluetooth connection
    qs.bluetooth.connect_worker.status.store(.success, .release);
    qs.bluetooth.connect_worker.connect = true;
    qs.bluetooth.connect_worker.done.store(true, .release);

    try std.testing.expect(qs.checkBtConnectStatus());
    try std.testing.expect(qs.bluetooth.items.items[0].connected);
    try std.testing.expectEqual(@as(usize, 0), qs.bluetooth.connect_mac_len);

    // Simulate failed connection on an offline device
    qs.bluetooth.items.items[0].connected = false;
    @memcpy(qs.bluetooth.connect_mac[0..bt_mac.len], bt_mac);
    qs.bluetooth.connect_mac_len = bt_mac.len;
    @memcpy(qs.bluetooth.connect_worker.mac[0..bt_mac.len], bt_mac);
    qs.bluetooth.connect_worker.mac_len = bt_mac.len;
    const test_err = "Device offline or unreachable";
    @memcpy(qs.bluetooth.connect_worker.error_msg[0..test_err.len], test_err);
    qs.bluetooth.connect_worker.error_len = test_err.len;
    qs.bluetooth.connect_worker.status.store(.failed, .release);
    qs.bluetooth.connect_worker.done.store(true, .release);

    try std.testing.expect(qs.checkBtConnectStatus());
    try std.testing.expectEqual(async.OpStatus.failed, qs.bluetooth.status);
    try std.testing.expectEqualStrings(bt_mac, qs.bluetooth.failed_mac[0..qs.bluetooth.failed_mac_len]);
    try std.testing.expectEqualStrings(test_err, qs.bluetooth.error_msg[0..qs.bluetooth.error_len]);
}

test "QuickSettings live scan functions" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var qs = QuickSettings{
        .allocator = allocator,
        .cfg = cfg,
        .font = undefined,
        .sys = sys_status.SysStatus.init(allocator),
        .hit_areas = std.ArrayList(HitArea).empty,
        .wifi = wifi.State.init(allocator),
        .bluetooth = bluetooth.State.init(),
        .recording = recording.State.init(),
        .sink_items = std.ArrayList(AudioSinkItem).empty,
        .source_items = std.ArrayList(AudioDeviceItem).empty,
    };
    defer {
        qs.wifi.deinit(allocator);
        qs.bluetooth.deinit(allocator);
        qs.sink_items.deinit(allocator);
        qs.source_items.deinit(allocator);
        qs.hit_areas.deinit(allocator);
        qs.sys.deinit();
    }

    // Call live scan methods to verify parsing against system CLI tools
    qs.scanWifi();
    qs.scanBluetooth();
    qs.scanAudioSinks();

    // Verify sink items were found on PipeWire
    try std.testing.expect(qs.sink_items.items.len > 0);
    const default_sink = qs.sink_items.items[0];
    try std.testing.expect(default_sink.id > 0);
    try std.testing.expect(default_sink.is_default);

    // Verify source items were found on PipeWire
    try std.testing.expect(qs.source_items.items.len > 0);
    const default_source = qs.source_items.items[0];
    try std.testing.expect(default_source.id > 0);
    try std.testing.expect(default_source.is_default);
}

test "QuickSettings forget_wifi and remove_bluetooth actions" {
    const action_wifi = Action{ .forget_wifi = 3 };
    switch (action_wifi) {
        .forget_wifi => |idx| try std.testing.expectEqual(@as(usize, 3), idx),
        else => try std.testing.expect(false),
    }

    const action_bt = Action{ .remove_bluetooth = 5 };
    switch (action_bt) {
        .remove_bluetooth => |idx| try std.testing.expectEqual(@as(usize, 5), idx),
        else => try std.testing.expect(false),
    }
}

test "QuickSettings scanning animation and saved wifi item logic" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var qs = QuickSettings{
        .allocator = allocator,
        .cfg = cfg,
        .font = undefined,
        .sys = sys_status.SysStatus.init(allocator),
        .hit_areas = std.ArrayList(HitArea).empty,
        .wifi = wifi.State.init(allocator),
        .bluetooth = bluetooth.State.init(),
        .recording = recording.State.init(),
        .sink_items = std.ArrayList(AudioSinkItem).empty,
        .source_items = std.ArrayList(AudioDeviceItem).empty,
    };
    defer {
        qs.wifi.deinit(allocator);
        qs.bluetooth.deinit(allocator);
        qs.sink_items.deinit(allocator);
        qs.source_items.deinit(allocator);
        qs.hit_areas.deinit(allocator);
        qs.sys.deinit();
    }

    // Test scanning state and tick spin
    qs.is_scanning = true;
    qs.scan_ticks = 4;
    qs.scan_angle = 0.0;
    _ = qs.tick();
    try std.testing.expect(qs.scan_angle > 0.0);
    try std.testing.expectEqual(@as(u32, 3), qs.scan_ticks);

    // Test WifiItem is_saved field
    const item_saved = WifiItem{
        .signal = 90,
        .is_saved = true,
    };
    const item_unsaved = WifiItem{
        .signal = 95,
        .is_saved = false,
    };
    try qs.wifi.items.append(allocator, item_saved);
    try qs.wifi.items.append(allocator, item_unsaved);
    try std.testing.expect(qs.wifi.items.items[0].is_saved);
    try std.testing.expect(!qs.wifi.items.items[1].is_saved);

    // Test continuous spinner animation while async worker active
    qs.is_scanning = false;
    qs.scan_ticks = 0;
    qs.wifi.scan_worker.running.store(true, .release);
    _ = qs.tick();
    try std.testing.expect(qs.is_scanning);
    try std.testing.expect(qs.scan_angle > 0.0);

    // When worker completes, is_scanning stops immediately
    qs.wifi.scan_worker.running.store(false, .release);
    _ = qs.drainAll();
    _ = qs.tick();
    try std.testing.expect(!qs.is_scanning);
    try std.testing.expectEqual(@as(f32, 0.0), qs.scan_angle);

    // Test MPRIS cover art path parsing
    const test_url = "file:///tmp/test_art.png";
    @memcpy(qs.sys.mpris_art_url[0..test_url.len], test_url);
    qs.sys.mpris_art_url_len = test_url.len;
    qs.updateCoverArt();
    try std.testing.expectEqualStrings("/tmp/test_art.png", qs.mpris_cover_path[0..qs.mpris_cover_len]);
}

test "QuickSettings performance latency measurements" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var ts_start: c.struct_timespec = undefined;
    var ts_end: c.struct_timespec = undefined;

    // 1. Measure QuickSettings.init latency
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts_start);
    var qs = try QuickSettings.init(allocator, cfg);
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts_end);
    const init_ns = (@as(i128, ts_end.tv_sec) - @as(i128, ts_start.tv_sec)) * 1_000_000_000 + (@as(i128, ts_end.tv_nsec) - @as(i128, ts_start.tv_nsec));

    // 2. Measure QuickSettings.tick latency
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts_start);
    _ = qs.tick();
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts_end);
    const tick_ns = (@as(i128, ts_end.tv_sec) - @as(i128, ts_start.tv_sec)) * 1_000_000_000 + (@as(i128, ts_end.tv_nsec) - @as(i128, ts_start.tv_nsec));

    // 3. Measure QuickSettings.render latency
    const w = qs.width;
    const h = qs.height;
    const stride = w * 4;
    const pixel_buf = try allocator.alloc(u32, w * h);
    defer allocator.free(pixel_buf);

    var target = try renderer.Renderer.init(pixel_buf.ptr, w, h, stride);
    defer target.deinit();

    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts_start);
    try qs.render(target, 1);
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts_end);
    const render_ns = (@as(i128, ts_end.tv_sec) - @as(i128, ts_start.tv_sec)) * 1_000_000_000 + (@as(i128, ts_end.tv_nsec) - @as(i128, ts_start.tv_nsec));

    // 4. Measure QuickSettings.deinit latency (never blocking joins)
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts_start);
    qs.deinit();
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts_end);
    const deinit_ns = (@as(i128, ts_end.tv_sec) - @as(i128, ts_start.tv_sec)) * 1_000_000_000 + (@as(i128, ts_end.tv_nsec) - @as(i128, ts_start.tv_nsec));

    std.debug.print("\n[BENCHMARK] QuickSettings init latency: {d:.2} µs ({d:.3} ms)\n", .{
        @as(f64, @floatFromInt(init_ns)) / 1000.0,
        @as(f64, @floatFromInt(init_ns)) / 1_000_000.0,
    });
    std.debug.print("[BENCHMARK] QuickSettings tick latency: {d:.2} µs ({d:.3} ms)\n", .{
        @as(f64, @floatFromInt(tick_ns)) / 1000.0,
        @as(f64, @floatFromInt(tick_ns)) / 1_000_000.0,
    });
    std.debug.print("[BENCHMARK] QuickSettings render latency: {d:.2} µs ({d:.3} ms)\n", .{
        @as(f64, @floatFromInt(render_ns)) / 1000.0,
        @as(f64, @floatFromInt(render_ns)) / 1_000_000.0,
    });
    std.debug.print("[BENCHMARK] QuickSettings deinit latency: {d:.2} µs ({d:.3} ms)\n", .{
        @as(f64, @floatFromInt(deinit_ns)) / 1000.0,
        @as(f64, @floatFromInt(deinit_ns)) / 1_000_000.0,
    });

    try std.testing.expect(init_ns < 1_500_000_000); // under 1500ms (cold fontconfig/sys status init in debug mode)
    try std.testing.expect(tick_ns < 10_000_000); // under 10ms
    try std.testing.expect(render_ns < 250_000_000); // under 250ms (unoptimized debug software rendering)
    try std.testing.expect(deinit_ns < 10_000_000); // under 10ms (zero blocking join!)
}

test "QuickSettings audio options tabs and device selection" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var qs = QuickSettings{
        .allocator = allocator,
        .cfg = cfg,
        .font = undefined,
        .sys = sys_status.SysStatus.init(allocator),
        .hit_areas = std.ArrayList(HitArea).empty,
        .wifi = wifi.State.init(allocator),
        .bluetooth = bluetooth.State.init(),
        .recording = recording.State.init(),
        .sink_items = std.ArrayList(AudioSinkItem).empty,
        .source_items = std.ArrayList(AudioDeviceItem).empty,
    };
    defer {
        qs.wifi.deinit(allocator);
        qs.bluetooth.deinit(allocator);
        qs.sink_items.deinit(allocator);
        qs.source_items.deinit(allocator);
        qs.hit_areas.deinit(allocator);
        qs.sys.deinit();
    }

    // Tab switching
    try std.testing.expectEqual(AudioTab.output, qs.audio_tab);
    _ = qs.handlePointerButton(0, 0, 0, false); // test button handler exists

    qs.hit_areas.clearRetainingCapacity();
    try qs.hit_areas.append(allocator, .{ .x = 0, .y = 0, .w = 100, .h = 30, .action = .set_audio_tab_input });
    try std.testing.expect(qs.handlePointerButton(10, 10, 272, true));
    try std.testing.expectEqual(AudioTab.input, qs.audio_tab);

    qs.hit_areas.clearRetainingCapacity();
    try qs.hit_areas.append(allocator, .{ .x = 0, .y = 0, .w = 100, .h = 30, .action = .set_audio_tab_output });
    try std.testing.expect(qs.handlePointerButton(10, 10, 272, true));
    try std.testing.expectEqual(AudioTab.output, qs.audio_tab);

    // Audio menu open and back
    qs.hit_areas.clearRetainingCapacity();
    try qs.hit_areas.append(allocator, .{ .x = 0, .y = 0, .w = 100, .h = 30, .action = .open_audio_menu });
    try std.testing.expect(qs.handlePointerButton(10, 10, 272, true));
    try std.testing.expectEqual(ViewMode.audio_menu, qs.view_mode);

    // Toggle earbud safety
    const initial_safety = qs.sys.earbud_safety_enabled;
    qs.hit_areas.clearRetainingCapacity();
    try qs.hit_areas.append(allocator, .{ .x = 0, .y = 0, .w = 100, .h = 30, .action = .toggle_earbud_safety });
    try std.testing.expect(qs.handlePointerButton(10, 10, 272, true));
    try std.testing.expectEqual(!initial_safety, qs.sys.earbud_safety_enabled);
    try std.testing.expect(qs.handlePointerButton(10, 10, 272, true));
    try std.testing.expectEqual(initial_safety, qs.sys.earbud_safety_enabled);

    qs.hit_areas.clearRetainingCapacity();
    try qs.hit_areas.append(allocator, .{ .x = 0, .y = 0, .w = 100, .h = 30, .action = .back_to_main });
    try std.testing.expect(qs.handlePointerButton(10, 10, 272, true));
    try std.testing.expectEqual(ViewMode.main, qs.view_mode);
}

test "QuickSettings recording options configuration" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var qs = QuickSettings{
        .allocator = allocator,
        .cfg = cfg,
        .font = undefined,
        .sys = sys_status.SysStatus.init(allocator),
        .hit_areas = std.ArrayList(HitArea).empty,
        .wifi = wifi.State.init(allocator),
        .bluetooth = bluetooth.State.init(),
        .recording = recording.State.init(),
        .sink_items = std.ArrayList(AudioSinkItem).empty,
        .source_items = std.ArrayList(AudioDeviceItem).empty,
    };
    defer {
        qs.wifi.deinit(allocator);
        qs.bluetooth.deinit(allocator);
        qs.sink_items.deinit(allocator);
        qs.source_items.deinit(allocator);
        qs.hit_areas.deinit(allocator);
        qs.sys.deinit();
    }

    // Test record menu opening
    qs.hit_areas.clearRetainingCapacity();
    try qs.hit_areas.append(allocator, .{ .x = 0, .y = 0, .w = 100, .h = 30, .action = .open_recording_menu });
    try std.testing.expect(qs.handlePointerButton(10, 10, 272, true));
    try std.testing.expectEqual(ViewMode.recording_menu, qs.view_mode);

    // Test mode changes
    qs.hit_areas.clearRetainingCapacity();
    try qs.hit_areas.append(allocator, .{ .x = 0, .y = 0, .w = 100, .h = 30, .action = .set_recording_mode_mic });
    try std.testing.expect(qs.handlePointerButton(10, 10, 272, true));
    try std.testing.expectEqual(recorder.RecordAudioMode.mic, qs.recording.audio_mode);
    try std.testing.expectEqual(recorder.RecordAudioMode.mic, recorder.getRecordAudioMode());

    qs.hit_areas.clearRetainingCapacity();
    try qs.hit_areas.append(allocator, .{ .x = 0, .y = 0, .w = 100, .h = 30, .action = .set_recording_mode_none });
    try std.testing.expect(qs.handlePointerButton(10, 10, 272, true));
    try std.testing.expectEqual(recorder.RecordAudioMode.none, qs.recording.audio_mode);
    try std.testing.expectEqual(recorder.RecordAudioMode.none, recorder.getRecordAudioMode());

    qs.hit_areas.clearRetainingCapacity();
    try qs.hit_areas.append(allocator, .{ .x = 0, .y = 0, .w = 100, .h = 30, .action = .set_recording_mode_system });
    try std.testing.expect(qs.handlePointerButton(10, 10, 272, true));
    try std.testing.expectEqual(recorder.RecordAudioMode.system, qs.recording.audio_mode);
    try std.testing.expectEqual(recorder.RecordAudioMode.system, recorder.getRecordAudioMode());

    // Verify command strings contain expected flags
    const sys_cmd = recorder.getRegionCommand(.system);
    try std.testing.expect(std.mem.indexOf(u8, sys_cmd, "gpu-screen-recorder") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys_cmd, "-fm cfr") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys_cmd, "-a default_output") != null);

    const mic_cmd = recorder.getRegionCommand(.mic);
    try std.testing.expect(std.mem.indexOf(u8, mic_cmd, "-a default_input") != null);

    const none_cmd = recorder.getRegionCommand(.none);
    try std.testing.expect(std.mem.indexOf(u8, none_cmd, "-a ") == null);
}

test "QuickSettings footer battery, uptime, and session actions" {
    const allocator = std.testing.allocator;
    var status = sys_status.SysStatus.init(allocator);
    defer status.deinit();

    // 1. Test battery status formatting
    status.has_battery = true;
    status.bat_capacity = 94;

    // Discharging with estimate
    status.bat_status = .discharging;
    status.bat_seconds_remaining = 4 * 3600 + 20 * 60; // 4h 20m
    var bbuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("94% · 4h 20m remaining", status.formatBatteryStatus(&bbuf));

    // Charging with estimate
    status.bat_status = .charging;
    status.bat_seconds_remaining = 35 * 60; // 35m
    try std.testing.expectEqualStrings("Charging · 35m until full", status.formatBatteryStatus(&bbuf));

    // Fully charged
    status.bat_status = .full;
    try std.testing.expectEqualStrings("Fully charged", status.formatBatteryStatus(&bbuf));

    // Discharging without reliable estimate
    status.bat_status = .discharging;
    status.bat_seconds_remaining = null;
    try std.testing.expectEqualStrings("94%", status.formatBatteryStatus(&bbuf));

    // Charging without reliable estimate
    status.bat_status = .charging;
    status.bat_seconds_remaining = null;
    try std.testing.expectEqualStrings("Charging · 94%", status.formatBatteryStatus(&bbuf));

    // 2. Test session confirmation actions
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var qs = QuickSettings{
        .allocator = allocator,
        .cfg = cfg,
        .font = undefined,
        .sys = sys_status.SysStatus.init(allocator),
        .hit_areas = std.ArrayList(HitArea).empty,
        .wifi = wifi.State.init(allocator),
        .bluetooth = bluetooth.State.init(),
        .recording = recording.State.init(),
    };
    defer {
        qs.hit_areas.deinit(allocator);
        qs.wifi.deinit(allocator);
        qs.bluetooth.deinit(allocator);
        qs.sys.deinit();
    }

    try std.testing.expectEqual(@as(?SessionConfirmAction, null), qs.confirming_session);

    // Request restart
    try qs.hit_areas.append(allocator, .{ .x = 10, .y = 10, .w = 34, .h = 34, .action = .request_reboot });
    try std.testing.expect(qs.handlePointerButton(20, 20, 272, true));
    try std.testing.expectEqual(SessionConfirmAction.reboot, qs.confirming_session.?);

    // Cancel restart
    qs.hit_areas.clearRetainingCapacity();
    try qs.hit_areas.append(allocator, .{ .x = 10, .y = 10, .w = 40, .h = 24, .action = .cancel_session_action });
    try std.testing.expect(qs.handlePointerButton(20, 20, 272, true));
    try std.testing.expectEqual(@as(?SessionConfirmAction, null), qs.confirming_session);

    // Request power off
    qs.hit_areas.clearRetainingCapacity();
    try qs.hit_areas.append(allocator, .{ .x = 10, .y = 10, .w = 34, .h = 34, .action = .request_shutdown });
    try std.testing.expect(qs.handlePointerButton(20, 20, 272, true));
    try std.testing.expectEqual(SessionConfirmAction.shutdown, qs.confirming_session.?);

    // Cancel via Escape key
    try std.testing.expect(qs.handleKeyFull(c.XKB_KEY_Escape, "", false, false));
    try std.testing.expectEqual(@as(?SessionConfirmAction, null), qs.confirming_session);

    // Open session power menu
    qs.hit_areas.clearRetainingCapacity();
    try qs.hit_areas.append(allocator, .{ .x = 10, .y = 10, .w = 34, .h = 34, .action = .open_session_power_menu });
    try std.testing.expect(qs.handlePointerButton(20, 20, 272, true));
    try std.testing.expect(!qs.running);
}

test "QuickSettings keymap submenu navigation and settings" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    var qs = QuickSettings{
        .allocator = allocator,
        .cfg = cfg,
        .font = undefined,
        .sys = sys_status.SysStatus.init(allocator),
        .hit_areas = std.ArrayList(HitArea).empty,
        .wifi = wifi.State.init(allocator),
        .bluetooth = bluetooth.State.init(),
        .recording = recording.State.init(),
    };
    defer {
        qs.hit_areas.deinit(allocator);
        qs.wifi.deinit(allocator);
        qs.bluetooth.deinit(allocator);
        qs.sys.deinit();
    }

    // Open keymap menu
    try qs.hit_areas.append(allocator, .{ .x = 10, .y = 10, .w = 50, .h = 50, .action = .open_keymap_menu });
    try std.testing.expect(qs.handlePointerButton(20, 20, 272, true));
    try std.testing.expectEqual(ViewMode.keymap_menu, qs.view_mode);
    try std.testing.expectEqual(@as(u32, 380), qs.getDesiredHeight());

    // Change keymap size
    qs.hit_areas.clearRetainingCapacity();
    try qs.hit_areas.append(allocator, .{ .x = 10, .y = 10, .w = 50, .h = 30, .action = .{ .set_keymap_size = 32 } });
    try std.testing.expect(qs.handlePointerButton(20, 20, 272, true));
    try std.testing.expectEqual(@as(u32, 32), qs.cfg.typography.keymap_text);

    // Change keymap position
    qs.hit_areas.clearRetainingCapacity();
    try qs.hit_areas.append(allocator, .{ .x = 10, .y = 10, .w = 50, .h = 30, .action = .{ .set_keymap_pos = .top_right } });
    try std.testing.expect(qs.handlePointerButton(20, 20, 272, true));
    try std.testing.expectEqual(config.KeymapPosition.top_right, qs.cfg.keymap_position);

    // Navigate back to main
    qs.hit_areas.clearRetainingCapacity();
    try qs.hit_areas.append(allocator, .{ .x = 10, .y = 10, .w = 34, .h = 34, .action = .back_to_main });
    try std.testing.expect(qs.handlePointerButton(20, 20, 272, true));
    try std.testing.expectEqual(ViewMode.main, qs.view_mode);
}
