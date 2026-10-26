const std = @import("std");
const c = @import("../c.zig").c;
const theme = @import("../core/theme.zig");
const config = @import("../core/config.zig");
const renderer = @import("../core/renderer.zig");
const async = @import("../core/async.zig");
const animation = @import("../core/animation.zig");
const sys_status = @import("../services/system_status.zig");
const text_input = @import("../core/text_input.zig");
const notification_module = @import("notifications.zig");
const recorder = @import("../bar/recorder.zig");
const icons = @import("../graphics/icons.zig");
const ui_mod = @import("../core/ui.zig");

/// Shared layout tokens for Quick Settings panels (logical pixels, multiplied by scale).
pub const QsLayout = struct {
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

pub const Action = union(enum) {
    toggle_wifi,
    toggle_bluetooth,
    toggle_audio_mute,
    toggle_caffeine,
    toggle_recording,
    open_wifi_menu,
    open_bluetooth_menu,
    open_audio_menu,
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
};

pub const WifiItem = struct {
    ssid: [64]u8 = [_]u8{0} ** 64,
    ssid_len: usize = 0,
    signal: u8 = 0,
    security: [32]u8 = [_]u8{0} ** 32,
    security_len: usize = 0,
    is_active: bool = false,
    is_saved: bool = false,
};

pub const BluetoothItem = struct {
    mac: [32]u8 = [_]u8{0} ** 32,
    mac_len: usize = 0,
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    connected: bool = false,
    icon: []const u8 = "󰂯",
};

pub const AudioTab = enum {
    output,
    input,
};

pub const AudioDeviceItem = struct {
    id: u32 = 0,
    name: [96]u8 = [_]u8{0} ** 96,
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

pub const SliderType = enum {
    volume,
    brightness,
};

pub const WifiConnectState = enum {
    idle,
    connecting,
    failed,
    success,
};

const QsSliderDraw = struct {
    panel: *QuickSettings,
    kind: SliderType,
    hovered: bool,

    fn draw(target: renderer.Renderer, rect: renderer.Rect, data: *const anyopaque) void {
        const self: *const QsSliderDraw = @ptrCast(@alignCast(data));
        const pct: u32 = switch (self.kind) {
            .volume => if (self.panel.sys.volume_muted) 0 else self.panel.sys.volume_percent,
            .brightness => self.panel.sys.backlight_percent,
        };
        target.drawPillSlider(
            rect.x,
            rect.y,
            rect.w,
            rect.h,
            pct,
            self.panel.cfg.theme.slider_track,
            self.panel.cfg.theme.accent,
            self.panel.cfg.theme.slider_thumb,
            self.panel.cfg.theme.slider_thumb_shadow,
            self.hovered,
        );
    }
};

const QsInputDraw = struct {
    panel: *QuickSettings,
    size: u32,

    fn draw(target: renderer.Renderer, rect: renderer.Rect, data: *const anyopaque) void {
        const self: *const QsInputDraw = @ptrCast(@alignCast(data));
        if (self.panel.wifi_input) |*inp| {
            inp.render(
                target,
                &self.panel.font,
                rect.x,
                rect.y,
                rect.w,
                rect.h,
                rect.x,
                self.panel.cfg.theme.text_bright,
                self.panel.cfg.theme.text_muted,
                self.panel.cfg.theme.accent,
                self.size,
            );
        }
    }
};

pub const QuickSettings = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    font: renderer.Font,
    sys: sys_status.SysStatus,

    width: u32 = 460,
    height: u32 = 520,
    running: bool = true,

    view_mode: ViewMode = .main,
    scroll_offset: usize = 0,
    hover_idx: ?usize = null,
    active_slider: ?SliderType = null,
    caffeine_enabled: bool = false,
    confirming_session: ?SessionConfirmAction = null,

    hit_areas: std.ArrayList(HitArea),
    wifi_items: std.ArrayList(WifiItem),
    bt_items: std.ArrayList(BluetoothItem),
    sink_items: std.ArrayList(AudioDeviceItem) = std.ArrayList(AudioDeviceItem).empty,
    source_items: std.ArrayList(AudioDeviceItem) = std.ArrayList(AudioDeviceItem).empty,
    audio_tab: AudioTab = .output,
    record_audio_mode: recorder.RecordAudioMode = .system,
    default_sink_name: [64]u8 = [_]u8{0} ** 64,
    default_sink_name_len: usize = 0,
    default_source_name: [64]u8 = [_]u8{0} ** 64,
    default_source_name_len: usize = 0,

    wifi_input_idx: ?usize = null,
    wifi_input_ssid: [64]u8 = [_]u8{0} ** 64,
    wifi_input_ssid_len: usize = 0,
    wifi_input: ?text_input.TextInput = null,
    wifi_password: [128]u8 = [_]u8{0} ** 128,
    wifi_password_len: usize = 0,
    wifi_connect_state: WifiConnectState = .idle,
    connecting_ssid: [64]u8 = [_]u8{0} ** 64,
    connecting_ssid_len: usize = 0,
    wifi_error_msg: [128]u8 = [_]u8{0} ** 128,
    wifi_error_len: usize = 0,
    wifi_worker: WifiWorker = .{},
    wifi_worker_running: bool = false,
    wifi_scan_worker: WifiScanWorker = .{},
    bt_scan_worker: BtScanWorker = .{},
    bt_connect_worker: BtConnectWorker = .{},
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
    wifi_scan_status: async.OpStatus = .idle,
    bt_scan_status: async.OpStatus = .idle,
    audio_scan_status: async.OpStatus = .idle,
    bt_connect_status: async.OpStatus = .idle,
    bt_connect_mac: [32]u8 = [_]u8{0} ** 32,
    bt_connect_mac_len: usize = 0,
    notif_store: ?notification_module.NotificationStore = null,

    pub fn getDesiredHeight(self: *const QuickSettings) u32 {
        return if (self.view_mode == .main) 520 else 480;
    }

    fn maxVisibleRows(self: *const QuickSettings) usize {
        return switch (self.view_mode) {
            .wifi_menu, .bluetooth_menu => 7,
            .audio_menu, .notifications_menu => 6,
            .recording_menu => 3,
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
            .width = 560,
            .height = 350,
            .hit_areas = std.ArrayList(HitArea).empty,
            .wifi_items = std.ArrayList(WifiItem).empty,
            .bt_items = std.ArrayList(BluetoothItem).empty,
            .sink_items = std.ArrayList(AudioDeviceItem).empty,
            .source_items = std.ArrayList(AudioDeviceItem).empty,
            .record_audio_mode = recorder.getRecordAudioMode(),
            .wifi_input = text_input.TextInput.init(allocator, "Enter Wi-Fi password...", true),
            .notif_store = notification_module.NotificationStore.init(allocator),
            .caffeine_enabled = isCaffeineActive(),
            .wake_fd = wake_fd,
            .audio_scan_status = .loading,
        };

        // Enumerate audio devices off the UI thread so the panel opens
        // immediately and populates when PipeWire responds.
        self_val.audio_scan_worker.wake_fd = wake_fd;
        _ = async.spawnTask(AudioScanWorker, &self_val.audio_scan_worker, wake_fd) catch {
            self_val.audio_scan_status = async.OpStatus.failed;
        };

        // Panel open animation: fade in with a slight upward slide.
        self_val.panel_anim.add(0.0, 1.0, 180, &animation.Easing.easeOutCubic);
        self_val.panel_anim.set(1, -12.0, 0.0, 180, &animation.Easing.easeOutCubic);
        return self_val;
    }

    pub fn deinit(self: *QuickSettings) void {
        if (self.notif_store) |*ns| ns.deinit();
        if (self.wifi_input) |*inp| inp.deinit();
        self.wifi_items.deinit(self.allocator);
        self.bt_items.deinit(self.allocator);
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

        if (self.wifi_input) |*inp| {
            inp.toggleCaret();
            needs_redraw = true;
        }
        if (self.drainAll()) needs_redraw = true;
        self.sys.tick();
        if (theme.loadSavedTheme()) |saved| {
            if (saved != self.cfg.theme.kind) {
                self.cfg.theme = saved.toTheme();
                needs_redraw = true;
            }
        }

        if (self.is_scanning) {
            needs_redraw = true;
            self.scan_angle += 0.22;
            if (self.scan_angle > 6.2831853) {
                self.scan_angle -= 6.2831853;
            }
            if (self.scan_ticks > 0) {
                self.scan_ticks -= 1;
            } else if (!self.wifi_scan_worker.running.load(.acquire) and !self.bt_scan_worker.running.load(.acquire)) {
                self.is_scanning = false;
                self.scan_angle = 0.0;
            }
        }

        // Update panel open/close animation.
        const anim_dt: u32 = 16; // ~60 Hz tick granularity
        if (self.panel_anim.updateAll(anim_dt)) needs_redraw = true;
        self.panel_alpha = self.panel_anim.get(0);
        self.panel_slide_y = @as(i32, @intFromFloat(self.panel_anim.get(1)));
        return needs_redraw;
    }

    pub fn handlePointerMotion(self: *QuickSettings, x: i32, y: i32) bool {
        self.pointer_x = x;
        self.pointer_y = y;

        if (self.active_slider) |st| {
            self.updateSliderFromPointer(st, x);
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
        const had_hover = (self.hover_idx != null or self.active_slider != null);
        self.hover_idx = null;
        self.active_slider = null;
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
        if (self.view_mode == .main) {
            for (self.hit_areas.items) |area| {
                if (x >= area.x and x < area.x + @as(i32, @intCast(area.w)) and
                    y >= area.y and y < area.y + @as(i32, @intCast(area.h)))
                {
                    if (area.action == .slider_volume) {
                        const cur = self.sys.volume_percent;
                        const delta: i32 = if (scroll_delta < 0) 5 else -5;
                        const new_vol = @as(u32, @intCast(@min(100, @max(0, @as(i32, @intCast(cur)) + delta))));
                        self.sys.setVolume(new_vol);
                        return true;
                    } else if (area.action == .slider_brightness) {
                        const cur = self.sys.backlight_percent;
                        const delta: i32 = if (scroll_delta < 0) 5 else -5;
                        const new_bl = @as(u32, @intCast(@min(100, @max(0, @as(i32, @intCast(cur)) + delta))));
                        self.sys.setBrightness(new_bl);
                        return true;
                    }
                }
            }
            return false;
        }

        const total = switch (self.view_mode) {
            .wifi_menu => self.wifi_items.items.len,
            .bluetooth_menu => self.bt_items.items.len,
            .audio_menu => if (self.audio_tab == .output) self.sink_items.items.len else self.source_items.items.len,
            .notifications_menu => if (self.notif_store) |ns| ns.items.items.len else 0,
            .recording_menu => 3,
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
        // BTN_LEFT is 272 (0x110)
        if (button != 272) return false;

        if (!is_pressed) {
            // Button released
            if (self.active_slider != null) {
                self.active_slider = null;
                return true;
            }
            return false;
        }

        // Button pressed: check hit areas
        for (self.hit_areas.items) |area| {
            if (x >= area.x and x < area.x + @as(i32, @intCast(area.w)) and
                y >= area.y and y < area.y + @as(i32, @intCast(area.h)))
            {
                switch (area.action) {
                    .toggle_wifi => {
                        self.sys.toggleWifi();
                        if (self.sys.wifi_enabled) {
                            if (self.wifi_items.items.len == 0) self.scanWifi();
                            self.is_scanning = true;
                            self.scan_ticks = 45;
                            self.triggerWifiScan();
                        } else {
                            self.wifi_items.clearRetainingCapacity();
                        }
                        return true;
                    },
                    .toggle_bluetooth => {
                        self.sys.toggleBluetooth();
                        if (self.sys.bluetooth_enabled) {
                            if (self.bt_items.items.len == 0) self.scanBluetooth();
                            self.is_scanning = true;
                            self.scan_ticks = 45;
                            self.triggerBtScan();
                        } else {
                            self.bt_items.clearRetainingCapacity();
                        }
                        return true;
                    },
                    .toggle_audio_mute => {
                        self.sys.toggleVolumeMute();
                        return true;
                    },
                    .toggle_caffeine => {
                        setCaffeine(!self.caffeine_enabled);
                        self.caffeine_enabled = isCaffeineActive();
                        return true;
                    },
                    .open_wifi_menu => {
                        self.view_mode = .wifi_menu;
                        self.scroll_offset = 0;
                        if (self.wifi_items.items.len == 0) self.scanWifi();
                        self.is_scanning = true;
                        self.scan_ticks = 45;
                        self.triggerWifiScan();
                        return true;
                    },
                    .open_bluetooth_menu => {
                        self.view_mode = .bluetooth_menu;
                        self.scroll_offset = 0;
                        if (self.bt_items.items.len == 0) self.scanBluetooth();
                        self.is_scanning = true;
                        self.scan_ticks = 45;
                        self.triggerBtScan();
                        return true;
                    },
                    .open_audio_menu => {
                        self.view_mode = .audio_menu;
                        self.scroll_offset = 0;
                        self.triggerAudioScan();
                        return true;
                    },
                    .open_recording_menu => {
                        self.view_mode = .recording_menu;
                        self.scroll_offset = 0;
                        return true;
                    },
                    .toggle_recording => {
                        if (recorder.isRecordingActive()) {
                            sys_status.spawnCmd(recorder.stop_cmd);
                        } else {
                            const cmd = recorder.getRegionCommand(self.record_audio_mode);
                            sys_status.spawnCmd(cmd);
                        }
                        return true;
                    },
                    .back_to_main => {
                        self.view_mode = .main;
                        self.scroll_offset = 0;
                        return true;
                    },
                    .forget_wifi => |idx| {
                        if (idx < self.wifi_items.items.len) {
                            const item = self.wifi_items.items[idx];
                            const ssid = item.ssid[0..item.ssid_len];
                            var cmd_buf: [256]u8 = undefined;
                            const cmd = std.fmt.bufPrint(&cmd_buf, "nmcli connection delete id \"{s}\" 2>/dev/null || true", .{ssid}) catch "";
                            sys_status.spawnCmd(cmd);

                            // Instantly reflect deletion in UI state without closing panel
                            self.wifi_items.items[idx].is_saved = false;
                            if (item.signal == 0 and !item.is_active) {
                                _ = self.wifi_items.orderedRemove(idx);
                            }
                            return true;
                        }
                    },
                    .remove_bluetooth => |idx| {
                        if (idx < self.bt_items.items.len) {
                            const item = self.bt_items.items[idx];
                            const mac = item.mac[0..item.mac_len];
                            var cmd_buf: [128]u8 = undefined;
                            const cmd = std.fmt.bufPrint(&cmd_buf, "bluetoothctl remove {s} 2>/dev/null || true", .{mac}) catch "";
                            sys_status.spawnCmd(cmd);

                            // Instantly reflect device removal in UI state without closing panel
                            _ = self.bt_items.orderedRemove(idx);
                            return true;
                        }
                    },
                    .disconnect_wifi => |idx| {
                        if (idx < self.wifi_items.items.len) {
                            const item = self.wifi_items.items[idx];
                            const ssid = item.ssid[0..item.ssid_len];
                            var cmd_buf: [256]u8 = undefined;
                            const cmd = std.fmt.bufPrint(&cmd_buf, "nmcli connection down id \"{s}\" 2>/dev/null || true", .{ssid}) catch "";
                            sys_status.spawnCmd(cmd);
                            self.is_scanning = true;
                            self.scan_ticks = 10;
                            self.triggerWifiScan();
                            return true;
                        }
                    },
                    .disconnect_bluetooth => |idx| {
                        if (idx < self.bt_items.items.len) {
                            const item = self.bt_items.items[idx];
                            const mac = item.mac[0..item.mac_len];
                            if (self.bt_connect_worker.running.load(.acquire)) return true;
                            const clen = @min(mac.len, self.bt_connect_mac.len);
                            @memcpy(self.bt_connect_mac[0..clen], mac[0..clen]);
                            self.bt_connect_mac_len = clen;
                            self.bt_connect_status = .disconnecting;
                            self.bt_connect_worker.done.store(false, .release);
                            self.bt_connect_worker.running.store(false, .release);
                            self.bt_connect_worker.wake_fd = self.wake_fd;
                            @memcpy(self.bt_connect_worker.mac[0..clen], mac[0..clen]);
                            self.bt_connect_worker.mac_len = clen;
                            self.bt_connect_worker.connect = false;
                            _ = async.spawnTask(BtConnectWorker, &self.bt_connect_worker, self.wake_fd) catch {
                                self.bt_connect_status = .failed;
                            };
                        }
                        return true;
                    },
                    .refresh_sub_menu => {
                        switch (self.view_mode) {
                            .wifi_menu => {
                                self.is_scanning = true;
                                self.scan_ticks = 45;
                                self.triggerWifiScan();
                            },
                            .bluetooth_menu => {
                                self.is_scanning = true;
                                self.scan_ticks = 45;
                                self.triggerBtScan();
                            },
                            .audio_menu => {
                                self.triggerAudioScan();
                            },
                            .recording_menu => {
                                self.record_audio_mode = recorder.getRecordAudioMode();
                            },
                            .notifications_menu => {
                                if (self.notif_store) |*ns| ns.loadHistory();
                            },
                            .main => {},
                        }
                        return true;
                    },
                    .select_wifi => |idx| {
                        if (idx < self.wifi_items.items.len) {
                            const item = self.wifi_items.items[idx];
                            if (item.is_active) {
                                return true;
                            }
                            const sec_str = if (item.security_len > 0) item.security[0..item.security_len] else "";
                            const is_open = (item.security_len == 0 or std.mem.eql(u8, sec_str, "--") or (std.mem.indexOf(u8, sec_str, "WPA") == null and std.mem.indexOf(u8, sec_str, "WEP") == null and std.mem.indexOf(u8, sec_str, "802.1X") == null));
                            if (item.is_saved or is_open) {
                                const ssid = item.ssid[0..item.ssid_len];
                                const slen = @min(ssid.len, self.connecting_ssid.len);
                                @memcpy(self.connecting_ssid[0..slen], ssid[0..slen]);
                                self.connecting_ssid_len = slen;
                                self.wifi_connect_state = .connecting;
                                self.wifi_input_idx = null;
                                self.wifi_input_ssid_len = 0;
                                if (self.wifi_input) |*inp| inp.clear();
                                self.wifi_password_len = 0;

                                var cmd_list = std.ArrayList(u8).empty;
                                defer cmd_list.deinit(self.allocator);
                                cmd_list.appendSlice(self.allocator, "nmcli connection up ") catch return true;
                                appendShellArg(self.allocator, &cmd_list, ssid) catch return true;
                                cmd_list.appendSlice(self.allocator, " 2>/dev/null || nmcli dev wifi connect ") catch return true;
                                appendShellArg(self.allocator, &cmd_list, ssid) catch return true;
                                cmd_list.appendSlice(self.allocator, " 2>/dev/null || true") catch return true;
                                sys_status.spawnCmd(cmd_list.items);
                                self.is_scanning = true;
                                self.scan_ticks = 45;
                                self.triggerWifiScan();
                            } else {
                                if (self.wifi_input_ssid_len > 0 and std.mem.eql(u8, self.wifi_input_ssid[0..self.wifi_input_ssid_len], item.ssid[0..item.ssid_len])) {
                                    self.wifi_input_idx = null;
                                    self.wifi_input_ssid_len = 0;
                                    if (self.wifi_input) |*inp| inp.clear();
                                    self.wifi_password_len = 0;
                                } else {
                                    self.wifi_input_idx = idx;
                                    const slen = @min(item.ssid_len, self.wifi_input_ssid.len);
                                    @memcpy(self.wifi_input_ssid[0..slen], item.ssid[0..slen]);
                                    self.wifi_input_ssid_len = slen;
                                    if (self.wifi_input) |*inp| {
                                        inp.clear();
                                        inp.focused = true;
                                        inp.resetCaret();
                                    }
                                    self.wifi_password_len = 0;
                                }
                            }
                        }
                        return true;
                    },
                    .wifi_cancel => {
                        self.wifi_input_idx = null;
                        self.wifi_input_ssid_len = 0;
                        if (self.wifi_input) |*inp| inp.clear();
                        self.wifi_password_len = 0;
                        return true;
                    },
                    .wifi_connect_submit => {
                        self.submitWifiPassword();
                        return true;
                    },
                    .wifi_input_click => {
                        if (self.wifi_input) |*inp| {
                            inp.focused = true;
                            inp.resetCaret();
                            _ = inp.handlePointerDown(x, y, area.x, area.y, area.w, area.h, area.x + 8, &self.font);
                        }
                        return true;
                    },
                    .select_bluetooth => |idx| {
                        if (idx < self.bt_items.items.len) {
                            const item = self.bt_items.items[idx];
                            const mac = item.mac[0..item.mac_len];
                            if (self.bt_connect_worker.running.load(.acquire)) return true;
                            const clen = @min(mac.len, self.bt_connect_mac.len);
                            @memcpy(self.bt_connect_mac[0..clen], mac[0..clen]);
                            self.bt_connect_mac_len = clen;
                            self.bt_connect_status = if (item.connected) .disconnecting else .connecting;
                            self.bt_connect_worker.done.store(false, .release);
                            self.bt_connect_worker.running.store(false, .release);
                            self.bt_connect_worker.wake_fd = self.wake_fd;
                            @memcpy(self.bt_connect_worker.mac[0..clen], mac[0..clen]);
                            self.bt_connect_worker.mac_len = clen;
                            self.bt_connect_worker.connect = !item.connected;
                            _ = async.spawnTask(BtConnectWorker, &self.bt_connect_worker, self.wake_fd) catch {
                                self.bt_connect_status = .failed;
                            };
                        }
                        return true;
                    },
                    .select_audio_sink => |idx| {
                        if (idx < self.sink_items.items.len) {
                            const item = self.sink_items.items[idx];
                            var cmd_buf: [64]u8 = undefined;
                            const cmd = std.fmt.bufPrint(&cmd_buf, "wpctl set-default {d}", .{item.id}) catch return true;
                            sys_status.spawnCmd(cmd);
                            self.sys.updateVolume();
                            self.triggerAudioScan();
                        }
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
                    .set_recording_mode_system => {
                        self.record_audio_mode = .system;
                        recorder.setRecordAudioMode(.system);
                        return true;
                    },
                    .set_recording_mode_mic => {
                        self.record_audio_mode = .mic;
                        recorder.setRecordAudioMode(.mic);
                        return true;
                    },
                    .set_recording_mode_none => {
                        self.record_audio_mode = .none;
                        recorder.setRecordAudioMode(.none);
                        return true;
                    },
                    .start_record_region => {
                        const cmd = recorder.getRegionCommand(self.record_audio_mode);
                        sys_status.spawnCmd(cmd);
                        return true;
                    },
                    .start_record_fullscreen => {
                        const cmd = recorder.getFullscreenCommand(self.record_audio_mode);
                        sys_status.spawnCmd(cmd);
                        return true;
                    },
                    .slider_volume => {
                        self.active_slider = .volume;
                        self.updateSliderFromPointer(.volume, x);
                        return true;
                    },
                    .slider_brightness => {
                        self.active_slider = .brightness;
                        self.updateSliderFromPointer(.brightness, x);
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
                    .lock => {
                        sys_status.spawnCmd("mizu lock 2>/dev/null || swaylock -c 000000 2>/dev/null || loginctl lock-session 2>/dev/null || true");
                        self.running = false;
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
                    .cycle_power_profile => {
                        switch (self.sys.power_profile) {
                            .power_saver => self.sys.setPowerProfile(.balanced),
                            .balanced => self.sys.setPowerProfile(.performance),
                            .performance => self.sys.setPowerProfile(.power_saver),
                        }
                        return true;
                    },
                    .set_power_profile_saver => {
                        self.sys.setPowerProfile(.power_saver);
                        return true;
                    },
                    .set_power_profile_balanced => {
                        self.sys.setPowerProfile(.balanced);
                        return true;
                    },
                    .set_power_profile_performance => {
                        self.sys.setPowerProfile(.performance);
                        return true;
                    },
                }
            }
        }

        return false;
    }

    fn appendShellArg(allocator: std.mem.Allocator, list: *std.ArrayList(u8), arg: []const u8) !void {
        try list.append(allocator, '\'');
        for (arg) |b| {
            if (b == '\'') {
                try list.appendSlice(allocator, "'\\''");
            } else {
                try list.append(allocator, b);
            }
        }
        try list.append(allocator, '\'');
    }

    pub const WifiWorker = struct {
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        success: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        status: std.atomic.Value(async.OpStatus) = .init(.idle),
        wake_fd: c_int = -1,
        error_msg: [128]u8 = [_]u8{0} ** 128,
        error_len: usize = 0,
        ssid: [64]u8 = [_]u8{0} ** 64,
        ssid_len: usize = 0,
        pwd: [128]u8 = [_]u8{0} ** 128,
        pwd_len: usize = 0,

        pub fn run(self: *WifiWorker) void {
            self.status.store(.connecting, .release);
            var cmd_list = std.ArrayList(u8).empty;
            defer cmd_list.deinit(std.heap.c_allocator);

            const slen = @min(self.ssid_len, self.ssid.len);
            const plen = @min(self.pwd_len, self.pwd.len);

            if (plen > 0) {
                cmd_list.appendSlice(std.heap.c_allocator, "nmcli dev wifi connect ") catch return;
                appendShellArg(std.heap.c_allocator, &cmd_list, self.ssid[0..slen]) catch return;
                cmd_list.appendSlice(std.heap.c_allocator, " password ") catch return;
                appendShellArg(std.heap.c_allocator, &cmd_list, self.pwd[0..plen]) catch return;
                cmd_list.appendSlice(std.heap.c_allocator, " 2>&1") catch return;
            } else {
                cmd_list.appendSlice(std.heap.c_allocator, "nmcli dev wifi connect ") catch return;
                appendShellArg(std.heap.c_allocator, &cmd_list, self.ssid[0..slen]) catch return;
                cmd_list.appendSlice(std.heap.c_allocator, " 2>&1") catch return;
            }

            const c_cmd = std.heap.c_allocator.dupeZ(u8, cmd_list.items) catch return;
            defer std.heap.c_allocator.free(c_cmd);

            const pipe = c.popen(c_cmd.ptr, "r");
            if (pipe != null) {
                var out_buf: [256]u8 = undefined;
                const bytes_read = c.fread(&out_buf, 1, out_buf.len - 1, pipe);
                const status = c.pclose(pipe);
                const exit_code = (status >> 8) & 0xff;

                if (exit_code == 0) {
                    self.success.store(true, .release);
                } else {
                    self.success.store(false, .release);
                    var err_text: []const u8 = "Connection failed. Check password.";
                    if (bytes_read > 0) {
                        out_buf[bytes_read] = 0;
                        const trimmed = std.mem.trim(u8, out_buf[0..bytes_read], " \t\r\n");
                        if (std.mem.indexOf(u8, trimmed, "Secrets") != null or
                            std.mem.indexOf(u8, trimmed, "password") != null or
                            std.mem.indexOf(u8, trimmed, "802-11-wireless-security") != null)
                        {
                            err_text = "Wrong password. Try again.";
                        } else if (std.mem.indexOf(u8, trimmed, "No network") != null) {
                            err_text = "Network not found or out of range.";
                        } else if (std.mem.startsWith(u8, trimmed, "Error: ")) {
                            err_text = trimmed[7..@min(trimmed.len, 70)];
                        }
                    }
                    const clen = @min(err_text.len, self.error_msg.len);
                    @memcpy(self.error_msg[0..clen], err_text[0..clen]);
                    self.error_len = clen;
                }
            } else {
                self.success.store(false, .release);
                const fallback = "Failed to run NetworkManager.";
                @memcpy(self.error_msg[0..fallback.len], fallback);
                self.error_len = fallback.len;
            }

            self.status.store(if (self.success.load(.acquire)) .success else .failed, .release);
            self.done.store(true, .release);
            if (self.wake_fd >= 0) {
                const val: u64 = 1;
                _ = c.write(self.wake_fd, &val, @sizeOf(u64));
            }
        }
    };

    pub const WifiScanWorker = struct {
        running: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        status: std.atomic.Value(async.OpStatus) = .init(.idle),
        lock: sys_status.SpinLock = .{},
        wake_fd: c_int = -1,
        items: [64]WifiItem = [_]WifiItem{.{}} ** 64,
        count: usize = 0,

        pub fn run(worker: *WifiScanWorker) void {
            worker.status.store(.scanning, .release);
            var local_items: [64]WifiItem = [_]WifiItem{.{}} ** 64;
            var local_count: usize = 0;

            // 0. Query saved wifi connections
            var saved_buf: [4096]u8 = undefined;
            var saved_names: [32][64]u8 = undefined;
            var saved_lens: [32]usize = undefined;
            var saved_count: usize = 0;

            if (c.popen("nmcli -t -f name,type connection show 2>/dev/null", "r")) |pipe| {
                defer _ = c.pclose(pipe);
                const n = c.fread(&saved_buf, 1, saved_buf.len - 1, pipe);
                saved_buf[n] = 0;
                var it = std.mem.splitScalar(u8, saved_buf[0..n], '\n');
                while (it.next()) |raw_line| {
                    const line = std.mem.trim(u8, raw_line, " \t\r");
                    if (line.len == 0) continue;
                    if (std.mem.indexOf(u8, line, "wireless") != null) {
                        if (std.mem.lastIndexOfScalar(u8, line, ':')) |col_idx| {
                            const name = line[0..col_idx];
                            if (name.len > 0 and name.len <= 64 and saved_count < 32) {
                                @memcpy(saved_names[saved_count][0..name.len], name);
                                saved_lens[saved_count] = name.len;
                                saved_count += 1;
                            }
                        }
                    }
                }
            }

            if (c.popen("nmcli -t -f active,ssid,signal,security dev wifi 2>/dev/null", "r")) |pipe| {
                defer _ = c.pclose(pipe);
                var buf: [4096]u8 = undefined;
                var total_read: usize = 0;
                while (total_read < buf.len - 1) {
                    const n = c.fread(buf[total_read..].ptr, 1, buf.len - 1 - total_read, pipe);
                    if (n == 0) break;
                    total_read += n;
                }
                buf[total_read] = 0;

                var line_it = std.mem.splitScalar(u8, buf[0..total_read], '\n');
                while (line_it.next()) |raw_line| {
                    const line = std.mem.trim(u8, raw_line, " \t\r");
                    if (line.len == 0) continue;

                    var field_it = std.mem.splitScalar(u8, line, ':');
                    const active_str = field_it.next() orelse continue;
                    const ssid = field_it.next() orelse continue;
                    if (ssid.len == 0) continue;

                    const signal_str = field_it.next() orelse "0";
                    const security_str = field_it.next() orelse "";

                    const is_active = std.mem.eql(u8, active_str, "yes");
                    const signal = std.fmt.parseInt(u8, signal_str, 10) catch 0;

                    var is_saved = false;
                    for (0..saved_count) |si| {
                        if (std.mem.eql(u8, saved_names[si][0..saved_lens[si]], ssid)) {
                            is_saved = true;
                            break;
                        }
                    }

                    var found = false;
                    for (local_items[0..local_count]) |*existing| {
                        if (std.mem.eql(u8, existing.ssid[0..existing.ssid_len], ssid)) {
                            found = true;
                            if (is_active) existing.is_active = true;
                            if (is_saved) existing.is_saved = true;
                            if (signal > existing.signal) existing.signal = signal;
                            break;
                        }
                    }

                    if (!found and local_count < local_items.len) {
                        var item = WifiItem{
                            .ssid = [_]u8{0} ** 64,
                            .ssid_len = @min(ssid.len, 64),
                            .signal = signal,
                            .security = [_]u8{0} ** 32,
                            .security_len = @min(security_str.len, 32),
                            .is_active = is_active,
                            .is_saved = is_saved,
                        };
                        @memcpy(item.ssid[0..item.ssid_len], ssid[0..item.ssid_len]);
                        @memcpy(item.security[0..item.security_len], security_str[0..item.security_len]);
                        local_items[local_count] = item;
                        local_count += 1;
                    }
                }
            }

            // Sort local_items: active first, then saved, then highest signal descending
            std.mem.sort(WifiItem, local_items[0..local_count], {}, struct {
                fn lessThan(_: void, a: WifiItem, b: WifiItem) bool {
                    if (a.is_active != b.is_active) return a.is_active;
                    if (a.is_saved != b.is_saved) return a.is_saved;
                    return a.signal > b.signal;
                }
            }.lessThan);

            {
                worker.lock.lock();
                defer worker.lock.unlock();
                @memcpy(worker.items[0..local_count], local_items[0..local_count]);
                worker.count = local_count;
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

    pub const BtScanWorker = struct {
        running: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        status: std.atomic.Value(async.OpStatus) = .init(.idle),
        lock: sys_status.SpinLock = .{},
        wake_fd: c_int = -1,
        items: [64]BluetoothItem = [_]BluetoothItem{.{}} ** 64,
        count: usize = 0,

        pub fn run(worker: *BtScanWorker) void {
            worker.status.store(.scanning, .release);
            var local_items: [64]BluetoothItem = [_]BluetoothItem{.{}} ** 64;
            var local_count: usize = 0;

            var connected_macs: [16][18]u8 = undefined;
            var connected_count: usize = 0;

            if (c.popen("bluetoothctl devices Connected 2>/dev/null", "r")) |pipe| {
                defer _ = c.pclose(pipe);
                var buf: [2048]u8 = undefined;
                const n = c.fread(&buf, 1, buf.len - 1, pipe);
                buf[n] = 0;
                var line_it = std.mem.splitScalar(u8, buf[0..n], '\n');
                while (line_it.next()) |raw_line| {
                    const line = std.mem.trim(u8, raw_line, " \t\r");
                    if (std.mem.startsWith(u8, line, "Device ")) {
                        const after = line[7..];
                        if (after.len >= 17 and connected_count < 16) {
                            @memcpy(connected_macs[connected_count][0..17], after[0..17]);
                            connected_macs[connected_count][17] = 0;
                            connected_count += 1;
                        }
                    }
                }
            }

            if (c.popen("bluetoothctl devices 2>/dev/null", "r")) |pipe| {
                defer _ = c.pclose(pipe);
                var buf: [4096]u8 = undefined;
                const n = c.fread(&buf, 1, buf.len - 1, pipe);
                buf[n] = 0;
                var line_it = std.mem.splitScalar(u8, buf[0..n], '\n');
                while (line_it.next()) |raw_line| {
                    const line = std.mem.trim(u8, raw_line, " \t\r");
                    if (std.mem.startsWith(u8, line, "Device ")) {
                        const after = line[7..];
                        if (after.len > 18) {
                            const mac_str = after[0..17];
                            const name_str = std.mem.trim(u8, after[18..], " \t");

                            var is_connected = false;
                            for (connected_macs[0..connected_count]) |cmac| {
                                if (std.mem.eql(u8, cmac[0..17], mac_str)) {
                                    is_connected = true;
                                    break;
                                }
                            }

                            var lower_buf: [128]u8 = undefined;
                            const lower_name = if (name_str.len <= lower_buf.len)
                                std.ascii.lowerString(&lower_buf, name_str)
                            else
                                name_str;

                            var dev_icon: []const u8 = "󰂯";
                            if (std.mem.indexOf(u8, lower_name, "buds") != null or
                                std.mem.indexOf(u8, lower_name, "headphone") != null or
                                std.mem.indexOf(u8, lower_name, "headset") != null or
                                std.mem.indexOf(u8, lower_name, "earphone") != null or
                                std.mem.indexOf(u8, lower_name, "airpods") != null)
                            {
                                dev_icon = "󰋋";
                            } else if (std.mem.indexOf(u8, lower_name, "keyboard") != null or
                                std.mem.indexOf(u8, lower_name, "keychron") != null)
                            {
                                dev_icon = "󰌌";
                            } else if (std.mem.indexOf(u8, lower_name, "mouse") != null) {
                                dev_icon = "󰍽";
                            }

                            if (local_count < local_items.len) {
                                var item = BluetoothItem{
                                    .mac = [_]u8{0} ** 32,
                                    .mac_len = @min(mac_str.len, 32),
                                    .name = [_]u8{0} ** 64,
                                    .name_len = @min(name_str.len, 64),
                                    .connected = is_connected,
                                    .icon = dev_icon,
                                };
                                @memcpy(item.mac[0..item.mac_len], mac_str[0..item.mac_len]);
                                @memcpy(item.name[0..item.name_len], name_str[0..item.name_len]);
                                local_items[local_count] = item;
                                local_count += 1;
                            }
                        }
                    }
                }
            }

            std.mem.sort(BluetoothItem, local_items[0..local_count], {}, struct {
                fn lessThan(_: void, a: BluetoothItem, b: BluetoothItem) bool {
                    if (a.connected != b.connected) return a.connected;
                    return std.mem.order(u8, a.name[0..a.name_len], b.name[0..b.name_len]) == .lt;
                }
            }.lessThan);

            {
                worker.lock.lock();
                defer worker.lock.unlock();
                @memcpy(worker.items[0..local_count], local_items[0..local_count]);
                worker.count = local_count;
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

    /// Connect or disconnect a single Bluetooth device off the UI thread.
    pub const BtConnectWorker = struct {
        running: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        status: std.atomic.Value(async.OpStatus) = .init(.idle),
        wake_fd: c_int = -1,
        mac: [32]u8 = [_]u8{0} ** 32,
        mac_len: usize = 0,
        connect: bool = true,
        error_msg: [128]u8 = [_]u8{0} ** 128,
        error_len: usize = 0,

        pub fn run(worker: *BtConnectWorker) void {
            worker.status.store(if (worker.connect) .connecting else .disconnecting, .release);
            worker.running.store(true, .release);

            var cmd_buf: [128]u8 = undefined;
            const cmd = if (worker.connect)
                std.fmt.bufPrint(&cmd_buf, "bluetoothctl connect {s} 2>&1", .{ worker.mac[0..worker.mac_len] }) catch ""
            else
                std.fmt.bufPrint(&cmd_buf, "bluetoothctl disconnect {s} 2>&1", .{ worker.mac[0..worker.mac_len] }) catch "";

            var success = false;
            if (cmd.len > 0) {
                const pipe = c.popen(cmd.ptr, "r");
                if (pipe) |p| {
                    // Read any output to avoid blocking the pipe, then check exit status via pclose.
                    var tmp_buf: [256]u8 = undefined;
                    _ = c.fread(&tmp_buf, 1, tmp_buf.len - 1, p);
                    const status = c.pclose(p);
                    const exit_code = (status >> 8) & 0xff;
                    success = (exit_code == 0);
                }
            }

            if (success) {
                worker.status.store(.success, .release);
            } else {
                worker.status.store(.failed, .release);
                const fallback = if (worker.connect) "Failed to connect device." else "Failed to disconnect device.";
                const clen = @min(fallback.len, worker.error_msg.len);
                @memcpy(worker.error_msg[0..clen], fallback[0..clen]);
                worker.error_len = clen;
            }

            worker.done.store(true, .release);
            worker.running.store(false, .release);
            if (worker.wake_fd >= 0) {
                const val: u64 = 1;
                _ = c.write(worker.wake_fd, &val, @sizeOf(u64));
            }
        }
    };

    /// Enumerate PipeWire audio sinks and sources off the UI thread.
    pub const AudioScanWorker = struct {
        running: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        status: std.atomic.Value(async.OpStatus) = .init(.idle),
        lock: sys_status.SpinLock = .{},
        wake_fd: c_int = -1,
        sink_items: [64]AudioDeviceItem = [_]AudioDeviceItem{.{}} ** 64,
        sink_count: usize = 0,
        source_items: [64]AudioDeviceItem = [_]AudioDeviceItem{.{}} ** 64,
        source_count: usize = 0,
        default_sink_name: [64]u8 = [_]u8{0} ** 64,
        default_sink_name_len: usize = 0,
        default_source_name: [64]u8 = [_]u8{0} ** 64,
        default_source_name_len: usize = 0,
        error_msg: [128]u8 = [_]u8{0} ** 128,
        error_len: usize = 0,

        pub fn run(worker: *AudioScanWorker) void {
            worker.status.store(.loading, .release);
            worker.running.store(true, .release);

            var local_sinks: [64]AudioDeviceItem = [_]AudioDeviceItem{.{}} ** 64;
            var local_sink_count: usize = 0;
            var local_sources: [64]AudioDeviceItem = [_]AudioDeviceItem{.{}} ** 64;
            var local_source_count: usize = 0;
            var local_default_sink: [64]u8 = [_]u8{0} ** 64;
            var local_default_sink_len: usize = 0;
            var local_default_source: [64]u8 = [_]u8{0} ** 64;
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
                                .name = [_]u8{0} ** 96,
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
        if (self.wifi_scan_worker.running.load(.acquire)) return;
        self.wifi_scan_status = .scanning;
        self.wifi_scan_worker.done.store(false, .release);
        self.wifi_scan_worker.running.store(true, .release);
        self.wifi_scan_worker.wake_fd = self.wake_fd;
        _ = async.spawnTask(WifiScanWorker, &self.wifi_scan_worker, self.wake_fd) catch {
            self.wifi_scan_worker.running.store(false, .release);
            self.wifi_scan_status = .failed;
        };
        self.is_scanning = true;
        self.scan_ticks = 45;
    }

    pub fn triggerBtScan(self: *QuickSettings) void {
        if (self.bt_scan_worker.running.load(.acquire)) return;
        self.bt_scan_status = .scanning;
        self.bt_scan_worker.done.store(false, .release);
        self.bt_scan_worker.running.store(true, .release);
        self.bt_scan_worker.wake_fd = self.wake_fd;
        _ = async.spawnTask(BtScanWorker, &self.bt_scan_worker, self.wake_fd) catch {
            self.bt_scan_worker.running.store(false, .release);
            self.bt_scan_status = .failed;
        };
        self.is_scanning = true;
        self.scan_ticks = 45;
    }

    pub fn triggerAudioScan(self: *QuickSettings) void {
        if (self.audio_scan_worker.running.load(.acquire)) return;
        self.audio_scan_status = .loading;
        self.audio_scan_worker.done.store(false, .release);
        self.audio_scan_worker.running.store(true, .release);
        self.audio_scan_worker.wake_fd = self.wake_fd;
        _ = async.spawnTask(AudioScanWorker, &self.audio_scan_worker, self.wake_fd) catch {
            self.audio_scan_worker.running.store(false, .release);
            self.audio_scan_status = .failed;
        };
    }

    /// Drain all completed async workers into UI state. Called both from the
    /// timer tick (legacy path) and immediately when the wake eventfd fires.
    pub fn drainAsyncResults(self: *QuickSettings) bool {
        var changed = false;

        if (self.wifi_scan_worker.done.load(.acquire)) {
            self.wifi_scan_worker.lock.lock();
            defer self.wifi_scan_worker.lock.unlock();
            self.wifi_items.clearRetainingCapacity();
            for (self.wifi_scan_worker.items[0..self.wifi_scan_worker.count]) |it| {
                self.wifi_items.append(self.allocator, it) catch break;
            }
            self.wifi_scan_worker.done.store(false, .release);
            self.wifi_scan_status = self.wifi_scan_worker.status.load(.acquire);
            changed = true;
        }

        if (self.bt_scan_worker.done.load(.acquire)) {
            self.bt_scan_worker.lock.lock();
            defer self.bt_scan_worker.lock.unlock();
            self.bt_items.clearRetainingCapacity();
            for (self.bt_scan_worker.items[0..self.bt_scan_worker.count]) |it| {
                self.bt_items.append(self.allocator, it) catch break;
            }
            self.bt_scan_worker.done.store(false, .release);
            self.bt_scan_status = self.bt_scan_worker.status.load(.acquire);
            changed = true;
        }

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

    /// Drain every completed async worker and apply state changes.
    /// Returns true when any visible state changed and a redraw is warranted.
    pub fn drainAll(self: *QuickSettings) bool {
        var changed = false;
        if (self.drainAsyncResults()) changed = true;
        if (self.checkWifiStatus()) changed = true;
        if (self.checkBtConnectStatus()) changed = true;
        return changed;
    }

    /// Returns true when the connect worker completed and UI state changed.
    pub fn checkWifiStatus(self: *QuickSettings) bool {
        if (!self.wifi_worker_running) return false;
        if (!self.wifi_worker.done.load(.acquire)) return false;

        if (self.wifi_worker.success.load(.acquire)) {
            self.wifi_connect_state = .success;
            self.connecting_ssid_len = 0;
            self.wifi_input_idx = null;
            self.wifi_input_ssid_len = 0;
            self.wifi_password_len = 0;
            self.wifi_error_len = 0;
            self.sys.updateAll();
            self.triggerWifiScan();
        } else {
            self.wifi_connect_state = .failed;
            self.connecting_ssid_len = 0;
            const elen = self.wifi_worker.error_len;
            @memcpy(self.wifi_error_msg[0..elen], self.wifi_worker.error_msg[0..elen]);
            self.wifi_error_len = elen;
        }

        self.wifi_worker_running = false;
        return true;
    }

    /// Returns true when the Bluetooth connect/disconnect worker completed.
    pub fn checkBtConnectStatus(self: *QuickSettings) bool {
        if (!self.bt_connect_worker.running.load(.acquire)) return false;
        if (!self.bt_connect_worker.done.load(.acquire)) return false;

        const st = self.bt_connect_worker.status.load(.acquire);
        self.bt_connect_status = st;
        if (st == .success) {
            // Refresh the device list so the new connection state is reflected.
            self.triggerBtScan();
        }
        self.bt_connect_worker.running.store(false, .release);
        return true;
    }

    pub fn submitWifiPassword(self: *QuickSettings) void {
        const idx = self.wifi_input_idx orelse return;
        if (idx >= self.wifi_items.items.len) {
            self.wifi_input_idx = null;
            self.wifi_input_ssid_len = 0;
            return;
        }
        if (self.wifi_connect_state == .connecting) return;

        const item = self.wifi_items.items[idx];
        const ssid = item.ssid[0..item.ssid_len];
        const pwd = self.wifi_password[0..self.wifi_password_len];

        self.wifi_connect_state = .connecting;
        self.wifi_error_len = 0;

        const clen = @min(ssid.len, self.connecting_ssid.len);
        @memcpy(self.connecting_ssid[0..clen], ssid[0..clen]);
        self.connecting_ssid_len = clen;

        // Immediately collapse and clear password input field so it does not linger or shift to another network!
        self.wifi_input_idx = null;
        self.wifi_input_ssid_len = 0;
        if (self.wifi_input) |*inp| inp.clear();
        self.wifi_password_len = 0;

        self.wifi_worker = WifiWorker{};
        self.wifi_worker.wake_fd = self.wake_fd;
        const slen = @min(ssid.len, self.wifi_worker.ssid.len);
        @memcpy(self.wifi_worker.ssid[0..slen], ssid[0..slen]);
        self.wifi_worker.ssid_len = slen;

        const plen = @min(pwd.len, self.wifi_worker.pwd.len);
        @memcpy(self.wifi_worker.pwd[0..plen], pwd[0..plen]);
        self.wifi_worker.pwd_len = plen;

        self.wifi_worker_running = true;

        _ = async.spawnTask(WifiWorker, &self.wifi_worker, self.wake_fd) catch {
            self.wifi_connect_state = .failed;
            self.connecting_ssid_len = 0;
            const fb = "Failed to spawn connect worker.";
            @memcpy(self.wifi_error_msg[0..fb.len], fb);
            self.wifi_error_len = fb.len;
            self.wifi_worker_running = false;
            return;
        };
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

        if (self.wifi_input_idx == null) return false;

        if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_KP_Enter) {
            self.submitWifiPassword();
            return true;
        } else if (sym == c.XKB_KEY_Escape) {
            self.wifi_input_idx = null;
            self.wifi_input_ssid_len = 0;
            if (self.wifi_input) |*inp| inp.clear();
            self.wifi_password_len = 0;
            return true;
        }

        if (self.wifi_input) |*inp| {
            const handled = inp.handleKey(sym, utf8_bytes, ctrl, shift);
            if (handled) {
                const txt = inp.getText();
                const copy_len = @min(txt.len, self.wifi_password.len);
                @memcpy(self.wifi_password[0..copy_len], txt[0..copy_len]);
                self.wifi_password_len = copy_len;
                return true;
            }
        }

        if (sym == c.XKB_KEY_BackSpace) {
            if (self.wifi_password_len > 0) {
                self.wifi_password_len -= 1;
            }
            return true;
        } else if (utf8_bytes.len > 0 and utf8_bytes[0] >= 32 and utf8_bytes[0] != 127) {
            if (self.wifi_password_len + utf8_bytes.len <= self.wifi_password.len) {
                @memcpy(self.wifi_password[self.wifi_password_len .. self.wifi_password_len + utf8_bytes.len], utf8_bytes);
                self.wifi_password_len += utf8_bytes.len;
                return true;
            }
        } else if (sym >= 32 and sym <= 126) {
            if (self.wifi_password_len < self.wifi_password.len) {
                self.wifi_password[self.wifi_password_len] = @intCast(sym);
                self.wifi_password_len += 1;
                return true;
            }
        }
        return false;
    }

    pub fn scanWifi(self: *QuickSettings) void {
        self.wifi_items.clearRetainingCapacity();

        // 0. Query saved wifi connections
        var saved_connections = std.ArrayList([64]u8).empty;
        defer saved_connections.deinit(self.allocator);
        var saved_lengths = std.ArrayList(usize).empty;
        defer saved_lengths.deinit(self.allocator);

        if (c.popen("nmcli -t -f name,type connection show 2>/dev/null", "r")) |pipe| {
            defer _ = c.pclose(pipe);
            var cbuf: [4096]u8 = undefined;
            const n = c.fread(&cbuf, 1, cbuf.len - 1, pipe);
            cbuf[n] = 0;
            var it = std.mem.splitScalar(u8, cbuf[0..n], '\n');
            while (it.next()) |raw_line| {
                const line = std.mem.trim(u8, raw_line, " \t\r");
                if (line.len == 0) continue;
                if (std.mem.indexOf(u8, line, "wireless") != null) {
                    if (std.mem.lastIndexOfScalar(u8, line, ':')) |col_idx| {
                        const name = line[0..col_idx];
                        if (name.len > 0 and name.len <= 64) {
                            var entry: [64]u8 = [_]u8{0} ** 64;
                            @memcpy(entry[0..name.len], name);
                            saved_connections.append(self.allocator, entry) catch {};
                            saved_lengths.append(self.allocator, name.len) catch {};
                        }
                    }
                }
            }
        }

        const pipe = c.popen("nmcli -t -f active,ssid,signal,security dev wifi 2>/dev/null", "r") orelse return;
        defer _ = c.pclose(pipe);

        var buf: [4096]u8 = undefined;
        var total_read: usize = 0;
        while (total_read < buf.len - 1) {
            const n = c.fread(buf[total_read..].ptr, 1, buf.len - 1 - total_read, pipe);
            if (n == 0) break;
            total_read += n;
        }
        buf[total_read] = 0;

        var line_it = std.mem.splitScalar(u8, buf[0..total_read], '\n');
        while (line_it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;

            var field_it = std.mem.splitScalar(u8, line, ':');
            const active_str = field_it.next() orelse continue;
            const ssid = field_it.next() orelse continue;
            if (ssid.len == 0) continue; // skip hidden networks

            const signal_str = field_it.next() orelse "0";
            const security_str = field_it.next() orelse "";

            const is_active = std.mem.eql(u8, active_str, "yes");
            const signal = std.fmt.parseInt(u8, signal_str, 10) catch 0;

            var is_saved = false;
            for (saved_connections.items, saved_lengths.items) |sc, slen| {
                if (std.mem.eql(u8, sc[0..slen], ssid)) {
                    is_saved = true;
                    break;
                }
            }

            // Deduplicate: if already seen this SSID, keep active or higher signal
            var found = false;
            for (self.wifi_items.items) |*existing| {
                if (std.mem.eql(u8, existing.ssid[0..existing.ssid_len], ssid)) {
                    found = true;
                    if (is_active) {
                        existing.is_active = true;
                    }
                    if (is_saved) {
                        existing.is_saved = true;
                    }
                    if (signal > existing.signal) {
                        existing.signal = signal;
                    }
                    break;
                }
            }
            if (!found) {
                var item = WifiItem{
                    .ssid = [_]u8{0} ** 64,
                    .ssid_len = @min(ssid.len, 64),
                    .signal = signal,
                    .security = [_]u8{0} ** 32,
                    .security_len = @min(security_str.len, 32),
                    .is_active = is_active,
                    .is_saved = is_saved,
                };
                @memcpy(item.ssid[0..item.ssid_len], ssid[0..item.ssid_len]);
                @memcpy(item.security[0..item.security_len], security_str[0..item.security_len]);
                self.wifi_items.append(self.allocator, item) catch break;
            }
        }

        // Sort: active first, then saved, then highest signal descending
        std.mem.sort(WifiItem, self.wifi_items.items, {}, struct {
            fn lessThan(_: void, a: WifiItem, b: WifiItem) bool {
                if (a.is_active != b.is_active) return a.is_active;
                if (a.is_saved != b.is_saved) return a.is_saved;
                return a.signal > b.signal;
            }
        }.lessThan);
    }

    pub fn scanBluetooth(self: *QuickSettings) void {
        self.bt_items.clearRetainingCapacity();

        // 1. Get connected device MACs
        var connected_macs = std.ArrayList([18]u8).empty;
        defer connected_macs.deinit(self.allocator);

        if (c.popen("bluetoothctl devices Connected 2>/dev/null", "r")) |pipe| {
            defer _ = c.pclose(pipe);
            var buf: [2048]u8 = undefined;
            const n = c.fread(&buf, 1, buf.len - 1, pipe);
            buf[n] = 0;
            var line_it = std.mem.splitScalar(u8, buf[0..n], '\n');
            while (line_it.next()) |raw_line| {
                const line = std.mem.trim(u8, raw_line, " \t\r");
                if (std.mem.startsWith(u8, line, "Device ")) {
                    const after = line[7..];
                    if (after.len >= 17) {
                        var mac: [18]u8 = [_]u8{0} ** 18;
                        @memcpy(mac[0..17], after[0..17]);
                        connected_macs.append(self.allocator, mac) catch {};
                    }
                }
            }
        }

        // 2. Get all paired/known devices
        if (c.popen("bluetoothctl devices 2>/dev/null", "r")) |pipe| {
            defer _ = c.pclose(pipe);
            var buf: [4096]u8 = undefined;
            const n = c.fread(&buf, 1, buf.len - 1, pipe);
            buf[n] = 0;
            var line_it = std.mem.splitScalar(u8, buf[0..n], '\n');
            while (line_it.next()) |raw_line| {
                const line = std.mem.trim(u8, raw_line, " \t\r");
                if (std.mem.startsWith(u8, line, "Device ")) {
                    const after = line[7..];
                    if (after.len > 18) {
                        const mac_str = after[0..17];
                        const name_str = std.mem.trim(u8, after[18..], " \t");

                        var is_connected = false;
                        for (connected_macs.items) |cmac| {
                            if (std.mem.eql(u8, cmac[0..17], mac_str)) {
                                is_connected = true;
                                break;
                            }
                        }

                        // Determine icon based on name
                        var lower_buf: [128]u8 = undefined;
                        const lower_name = if (name_str.len <= lower_buf.len)
                            std.ascii.lowerString(&lower_buf, name_str)
                        else
                            name_str;

                        var dev_icon: []const u8 = "󰂯";
                        if (std.mem.indexOf(u8, lower_name, "buds") != null or
                            std.mem.indexOf(u8, lower_name, "headphone") != null or
                            std.mem.indexOf(u8, lower_name, "headset") != null or
                            std.mem.indexOf(u8, lower_name, "earphone") != null or
                            std.mem.indexOf(u8, lower_name, "airpods") != null)
                        {
                            dev_icon = "󰋋";
                        } else if (std.mem.indexOf(u8, lower_name, "keyboard") != null or
                            std.mem.indexOf(u8, lower_name, "keychron") != null)
                        {
                            dev_icon = "󰌌";
                        } else if (std.mem.indexOf(u8, lower_name, "mouse") != null) {
                            dev_icon = "󰍽";
                        }

                        var item = BluetoothItem{
                            .mac = [_]u8{0} ** 32,
                            .mac_len = @min(mac_str.len, 32),
                            .name = [_]u8{0} ** 64,
                            .name_len = @min(name_str.len, 64),
                            .connected = is_connected,
                            .icon = dev_icon,
                        };
                        @memcpy(item.mac[0..item.mac_len], mac_str[0..item.mac_len]);
                        @memcpy(item.name[0..item.name_len], name_str[0..item.name_len]);

                        self.bt_items.append(self.allocator, item) catch break;
                    }
                }
            }
        }

        // Sort: connected first, then by name
        std.mem.sort(BluetoothItem, self.bt_items.items, {}, struct {
            fn lessThan(_: void, a: BluetoothItem, b: BluetoothItem) bool {
                if (a.connected != b.connected) return a.connected;
                return std.mem.order(u8, a.name[0..a.name_len], b.name[0..b.name_len]) == .lt;
            }
        }.lessThan);
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
                        .name = [_]u8{0} ** 96,
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

    fn updateSliderFromPointer(self: *QuickSettings, st: SliderType, px: i32) void {
        for (self.hit_areas.items) |area| {
            const matches = switch (st) {
                .volume => area.action == .slider_volume,
                .brightness => area.action == .slider_brightness,
            };
            if (matches) {
                const pct = calculateSliderPercent(px, area.x, area.w);
                switch (st) {
                    .volume => if (pct != self.sys.volume_percent) self.sys.setVolume(pct),
                    .brightness => if (pct != self.sys.backlight_percent) self.sys.setBrightness(pct),
                }
                break;
            }
        }
    }

    pub fn calculateSliderPercent(px: i32, start_x: i32, width: u32) u32 {
        if (width == 0) return 0;
        if (px <= start_x) return 0;
        const rel_x = px - start_x;
        if (rel_x >= @as(i32, @intCast(width))) return 100;
        const pct = (@as(u32, @intCast(rel_x)) * 100) / width;
        return @min(100, pct);
    }

    fn formatDate(buf: []u8) []const u8 {
        var raw_time: c.time_t = 0;
        _ = c.time(&raw_time);
        const tm_info = c.localtime(&raw_time);
        if (tm_info == null) return "Today";

        const written = c.strftime(buf.ptr, buf.len, "%A, %d %B %Y", tm_info);
        if (written == 0) return "Today";
        return buf[0..written];
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
            const top_pad: u16 = @intCast(@max(0, @as(i32, @intCast(QsLayout.pad * scale)) + self.panel_slide_y));
            ui.root(.{
                .direction = .column,
                .padding = .{
                    .left = ui.su(QsLayout.pad),
                    .right = ui.su(QsLayout.pad),
                    .top = top_pad,
                    .bottom = ui.su(QsLayout.pad),
                },
                .gap = ui.su(QsLayout.section_gap),
                .bg = self.cfg.theme.panel_bg,
                .radius = ui.f(self.cfg.theme.radius_panel),
                .border = ui.su(1),
                .border_color = self.cfg.theme.panel_border,
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
                .border = ui.su(1),
                .border_color = self.cfg.theme.panel_border,
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
        const content_w: u32 = if (self.width > 2 * QsLayout.pad * scale)
            self.width - 2 * QsLayout.pad * scale
        else
            self.width;

        const is_wifi_on = self.sys.wifi_enabled;
        const wifi_sub = if (is_wifi_on)
            (if (self.sys.wifi_ssid_len > 0) self.sys.wifi_ssid[0..self.sys.wifi_ssid_len] else "Connected")
        else
            "Off";
        const is_bt_on = self.sys.bluetooth_enabled;
        const is_aud_on = !self.sys.volume_muted;
        const aud_icon_name = if (!is_aud_on)
            "volume-muted"
        else if (self.sys.volume_percent <= 33)
            "volume-low"
        else if (self.sys.volume_percent <= 66)
            "volume-medium"
        else
            "volume-high";
        var aud_sub_buf: [64]u8 = undefined;
        const aud_sub = if (self.default_sink_name_len > 0)
            self.default_sink_name[0..self.default_sink_name_len]
        else if (!is_aud_on)
            "Muted"
        else
            std.fmt.bufPrint(&aud_sub_buf, "{d}%", .{self.sys.volume_percent}) catch "Sound";
        const prof_sub = switch (self.sys.power_profile) {
            .power_saver => "Power Saver",
            .balanced => "Balanced",
            .performance => "Performance",
        };
        const is_rec_active = recorder.isRecordingActive();

        const cards = [_]struct {
            icon: []const u8,
            title: []const u8,
            subtitle: []const u8,
            active: bool,
            action: Action,
            menu: ?Action,
        }{
            .{ .icon = if (is_wifi_on) "wifi-high" else "wifi-off", .title = "Wi-Fi", .subtitle = wifi_sub, .active = is_wifi_on, .action = .toggle_wifi, .menu = .open_wifi_menu },
            .{ .icon = "bluetooth", .title = "Bluetooth", .subtitle = if (is_bt_on) "On" else "Off", .active = is_bt_on, .action = .toggle_bluetooth, .menu = .open_bluetooth_menu },
            .{ .icon = aud_icon_name, .title = "Sound", .subtitle = aud_sub, .active = is_aud_on, .action = .toggle_audio_mute, .menu = .open_audio_menu },
            .{ .icon = "powermode", .title = "Power Mode", .subtitle = prof_sub, .active = true, .action = .cycle_power_profile, .menu = null },
            .{ .icon = "caffeine", .title = "Caffeine", .subtitle = if (self.caffeine_enabled) "On" else "Off", .active = self.caffeine_enabled, .action = .toggle_caffeine, .menu = null },
            .{ .icon = "record", .title = "Record", .subtitle = self.record_audio_mode.toShortLabel(), .active = is_rec_active, .action = .toggle_recording, .menu = .open_recording_menu },
        };

        // Three rows of toggle cards, two cards per row.
        var row: usize = 0;
        while (row < 3) : (row += 1) {
            _ = ui.open(.{
                .width = .{ .grow = .{} },
                .height = .{ .fixed = ui.s(44) },
                .direction = .row,
                .gap = ui.su(10),
            });
            var col: usize = 0;
            while (col < 2) : (col += 1) {
                const idx = row * 2 + col;
                const card = cards[idx];
                const main_hov = ui.hovered("qs-main", @intCast(idx));
                const chev_hov = ui.hovered("qs-chev", @intCast(idx));
                const any_hov = main_hov or chev_hov;

                var bg = if (card.active) self.cfg.theme.accent else self.cfg.theme.card_bg;
                if (any_hov) {
                    bg = if (card.active)
                        theme.Color.init(225, self.cfg.theme.accent.r, self.cfg.theme.accent.g, self.cfg.theme.accent.b)
                    else
                        self.cfg.theme.card_hover_bg;
                }

                _ = ui.open(.{
                    .width = .{ .grow = .{} },
                    .height = .{ .grow = .{} },
                    .direction = .row,
                    .gap = 0,
                    .bg = bg,
                    .radius = ui.f(14),
                    .border = ui.su(1),
                    .border_color = if (card.active) self.cfg.theme.accent else if (any_hov) self.cfg.theme.border_focused else self.cfg.theme.border,
                });

                const fg = if (card.active) self.cfg.theme.accent_fg else self.cfg.theme.text_bright;
                const sub_fg = if (card.active)
                    theme.Color.init(220, self.cfg.theme.accent_fg.r, self.cfg.theme.accent_fg.g, self.cfg.theme.accent_fg.b)
                else
                    self.cfg.theme.text_muted;

                _ = ui.open(.{
                    .id = "qs-main",
                    .index = @intCast(idx),
                    .width = .{ .grow = .{} },
                    .height = .{ .grow = .{} },
                    .direction = .row,
                    .padding = .{ .left = ui.su(14), .right = ui.su(6) },
                    .gap = ui.su(10),
                    .align_y = .center,
                });
                _ = ui.open(.{
                    .width = .{ .fixed = @floatFromInt(icon_sz) },
                    .height = .{ .fixed = @floatFromInt(icon_sz) },
                    .align_x = .center,
                    .align_y = .center,
                });
                ui.icon(card.icon, icon_sz, fg, 0);
                ui.close();
                _ = ui.open(.{
                    .width = .{ .grow = .{} },
                    .height = .{ .grow = .{} },
                    .direction = .column,
                    .gap = 0,
                    .align_y = .center,
                    .clip_horizontal = true,
                });
                ui.text(card.title, .{ .size = ui_sz, .color = fg, .line_height = @intCast(ui_sz + 1) });
                ui.text(card.subtitle, .{ .size = sec_sz, .color = sub_fg, .line_height = @intCast(sec_sz + 1) });
                ui.close();
                ui.close();

                if (card.menu) |menu_action| {
                    _ = ui.open(.{
                        .id = "qs-chev",
                        .index = @intCast(idx),
                        .width = .{ .fixed = ui.s(42) },
                        .height = .{ .grow = .{} },
                        .bg = if (chev_hov)
                            (if (card.active) theme.Color.init(35, 255, 255, 255) else theme.Color.init(25, 255, 255, 255))
                        else
                            null,
                        .radius = ui.f(12),
                        .align_x = .center,
                        .align_y = .center,
                    });
                    ui.icon("right", icon_sz, if (card.active) self.cfg.theme.accent_fg else self.cfg.theme.text_muted, 0);
                    ui.close();
                    _ = menu_action;
                } else {
                    ui.spacerSized(.{ .fixed = ui.s(6) }, .{ .fixed = 0 });
                }

                ui.close(); // card
            }
            ui.close(); // row
        }

        // Volume / brightness slider card.
        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .fixed = ui.s(100) },
            .direction = .column,
            .padding = .{ .left = ui.su(10), .right = ui.su(10), .top = ui.su(4), .bottom = ui.su(4) },
            .gap = 0,
            .bg = self.cfg.theme.card_bg,
            .radius = ui.f(self.cfg.theme.radius_card),
            .border = ui.su(1),
            .border_color = self.cfg.theme.border,
            .align_y = .center,
        });

        const vol_icon_name = if (self.sys.volume_muted)
            "volume-muted"
        else if (self.sys.volume_percent <= 33)
            "volume-low"
        else if (self.sys.volume_percent <= 66)
            "volume-medium"
        else
            "volume-high";

        var vol_val_buf: [16]u8 = undefined;
        const vol_val_str = if (self.sys.volume_muted) "0%" else (std.fmt.bufPrint(&vol_val_buf, "{d}%", .{self.sys.volume_percent}) catch "50%");
        try self.addSliderRow(ui, target, scale, .volume, vol_icon_name, if (self.sys.volume_muted) self.cfg.theme.error_color else self.cfg.theme.text_main, vol_val_str, ui_sz, sec_sz, icon_sz);

        const bri_icon_name = if (self.sys.backlight_percent > 50) "sun-filled" else "sun";
        var bri_val_buf: [16]u8 = undefined;
        const bri_val_str = std.fmt.bufPrint(&bri_val_buf, "{d}%", .{self.sys.backlight_percent}) catch "100%";
        try self.addSliderRow(ui, target, scale, .brightness, bri_icon_name, self.cfg.theme.text_main, bri_val_str, ui_sz, sec_sz, icon_sz);
        ui.close(); // slider card

        // Battery and uptime chips.
        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .fixed = ui.s(36) },
            .direction = .row,
            .gap = ui.su(10),
        });

        const bat_pct = if (self.sys.has_battery) self.sys.bat_capacity else 100;
        const plugged = self.sys.ac_online;
        const is_charging = self.sys.bat_status == .charging;
        const is_full = self.sys.bat_status == .full;
        const bat_color = if (plugged or is_full)
            self.cfg.theme.success_color
        else if (bat_pct <= 20)
            self.cfg.theme.error_color
        else
            self.cfg.theme.text_bright;
        const svg_name = if (plugged or is_charging) "battery-charging" else if (bat_pct <= 10) "battery-empty" else if (bat_pct >= 90) "battery-full" else if (bat_pct >= 60) "battery-high" else if (bat_pct >= 30) "battery-medium" else "battery-low";

        var detail_buf: [48]u8 = undefined;
        const detail_str: []const u8 = if (plugged)
            "Plugged In"
        else if (is_charging)
            "Charging"
        else if (is_full)
            "Full"
        else if (self.sys.bat_seconds_remaining) |sec| blk: {
            if (sec <= 0) break :blk "";
            const hours = @divTrunc(sec, 3600);
            const minutes = @divTrunc(@rem(sec, 3600), 60);
            if (hours > 0 and minutes > 0) {
                break :blk std.fmt.bufPrint(&detail_buf, "{d}h {d}m left", .{ hours, minutes }) catch "";
            } else if (hours > 0) {
                break :blk std.fmt.bufPrint(&detail_buf, "{d}h left", .{hours}) catch "";
            } else if (minutes > 0) {
                break :blk std.fmt.bufPrint(&detail_buf, "{d}m left", .{minutes}) catch "";
            } else {
                break :blk "1m left";
            }
        } else "";
        var bat_line_buf: [64]u8 = undefined;
        const bat_line = if (detail_str.len > 0)
            std.fmt.bufPrint(&bat_line_buf, "{d}% ({s})", .{ bat_pct, detail_str }) catch "100%"
        else
            std.fmt.bufPrint(&bat_line_buf, "{d}%", .{bat_pct}) catch "100%";

        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
            .direction = .row,
            .padding = .{ .left = ui.su(10), .right = ui.su(10) },
            .gap = ui.su(8),
            .bg = self.cfg.theme.card_bg,
            .radius = ui.f(self.cfg.theme.radius_pill),
            .border = ui.su(1),
            .border_color = self.cfg.theme.border,
            .align_y = .center,
            .clip_horizontal = true,
        });
        ui.icon(svg_name, icon_sz, bat_color, 0);
        var trunc_bat_buf: [96]u8 = undefined;
        const trunc_bat = truncateText(target, &self.font, bat_line, content_w / 2, ui_sz, &trunc_bat_buf);
        ui.text(trunc_bat, .{ .size = ui_sz, .color = self.cfg.theme.text_bright });
        ui.close();

        var uptime_buf: [32]u8 = undefined;
        const uptime_raw = self.sys.formatUptime(&uptime_buf);
        const uptime_str = if (std.mem.startsWith(u8, uptime_raw, "Uptime · ")) uptime_raw[9..] else uptime_raw;

        _ = ui.open(.{
            .width = .fit,
            .height = .{ .grow = .{} },
            .direction = .row,
            .padding = .{ .left = ui.su(10), .right = ui.su(10) },
            .gap = ui.su(8),
            .bg = self.cfg.theme.card_bg,
            .radius = ui.f(self.cfg.theme.radius_pill),
            .border = ui.su(1),
            .border_color = self.cfg.theme.border,
            .align_y = .center,
        });
        ui.icon("uptime", icon_sz, self.cfg.theme.text_bright, 0);
        ui.text(uptime_str, .{ .size = ui_sz, .color = self.cfg.theme.text_bright });
        ui.close();
        ui.close(); // chips row

        // Session actions, centered 2x2.
        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .fixed = ui.s(60) },
            .direction = .row,
            .gap = ui.su(10),
            .align_x = .center,
            .align_y = .center,
        });
        const sessions = [_]struct { act: Action, icon: []const u8 }{
            .{ .act = .request_logout, .icon = "logout" },
            .{ .act = .lock, .icon = "lock" },
            .{ .act = .request_reboot, .icon = "restart" },
            .{ .act = .request_shutdown, .icon = "power" },
        };
        for (sessions, 0..) |session, idx| {
            const hov = ui.hovered("qs-session", @intCast(idx));
            _ = ui.open(.{
                .id = "qs-session",
                .index = @intCast(idx),
                .width = .{ .fixed = ui.s(44) },
                .height = .{ .fixed = ui.s(44) },
                .bg = if (hov) self.cfg.theme.card_hover_bg else self.cfg.theme.card_bg,
                .radius = ui.f(22),
                .border = ui.su(1),
                .border_color = if (hov) self.cfg.theme.border_focused else self.cfg.theme.border,
                .align_x = .center,
                .align_y = .center,
            });
            ui.icon(session.icon, icon_sz, if (hov) self.cfg.theme.accent else self.cfg.theme.text_main, 0);
            ui.close();
        }
        ui.close();

        // MPRIS media card.
        if (self.sys.mpris_state != .stopped and self.sys.mpris_track_len > 0) {
            _ = ui.open(.{
                .width = .{ .grow = .{} },
                .height = .{ .fixed = ui.s(48) },
                .direction = .row,
                .padding = .{ .left = ui.su(10), .right = ui.su(10) },
                .gap = ui.su(10),
                .bg = self.cfg.theme.card_bg,
                .radius = ui.f(self.cfg.theme.radius_card),
                .border = ui.su(1),
                .border_color = self.cfg.theme.border,
                .align_y = .center,
            });
            ui.icon("music", icon_sz, self.cfg.theme.accent, 0);
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
            const trunc_track = truncateText(target, &self.font, track_str, content_w - 180, ui_sz, &track_buf);
            ui.text(trunc_track, .{ .size = ui_sz, .color = self.cfg.theme.text_bright });
            ui.text(if (self.sys.mpris_state == .playing) "Playing" else "Paused", .{ .size = sec_sz, .color = self.cfg.theme.text_muted });
            ui.close();

            const media_actions = [_]struct { icon: []const u8, act: Action }{
                .{ .icon = "prev", .act = .media_prev },
                .{ .icon = if (self.sys.mpris_state == .playing) "pause" else "play", .act = .media_play_pause },
                .{ .icon = "next", .act = .media_next },
            };
            for (media_actions, 0..) |ma, mi| {
                const hov = ui.hovered("qs-media", @intCast(mi));
                _ = ui.open(.{
                    .id = "qs-media",
                    .index = @intCast(mi),
                    .width = .{ .fixed = ui.s(24) },
                    .height = .{ .fixed = ui.s(24) },
                    .bg = if (hov) self.cfg.theme.card_hover_bg else null,
                    .radius = ui.f(12),
                    .border = ui.su(1),
                    .border_color = if (hov) self.cfg.theme.accent else self.cfg.theme.border,
                    .align_x = .center,
                    .align_y = .center,
                });
                ui.icon(ma.icon, 16 * scale, self.cfg.theme.text_bright, 0);
                ui.close();
            }
            ui.close();
        }
    }

    fn addSliderRow(
        self: *QuickSettings,
        ui: *ui_mod.Ui,
        target: renderer.Renderer,
        scale: u32,
        kind: SliderType,
        icon_name: []const u8,
        icon_color: theme.Color,
        value_str: []const u8,
        ui_sz: u32,
        sec_sz: u32,
        icon_sz: u32,
    ) !void {
        _ = target;
        _ = scale;
        const id_name = if (kind == .volume) "qs-vol-slider" else "qs-bri-slider";

        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .fixed = ui.s(44) },
            .direction = .row,
            .gap = ui.su(10),
            .align_y = .center,
        });

        if (kind == .volume) {
            const mute_hov = ui.hovered("qs-mute", 0);
            _ = ui.open(.{
                .id = "qs-mute",
                .width = .{ .fixed = ui.s(30) },
                .height = .{ .fixed = ui.s(34) },
                .align_x = .center,
                .align_y = .center,
                .radius = ui.f(8),
                .bg = if (mute_hov) self.cfg.theme.card_hover_bg else null,
            });
            ui.icon(icon_name, icon_sz, icon_color, 0);
            ui.close();
        } else {
            _ = ui.open(.{
                .width = .{ .fixed = ui.s(30) },
                .height = .{ .fixed = ui.s(34) },
                .align_x = .center,
                .align_y = .center,
            });
            ui.icon(icon_name, icon_sz, icon_color, 1);
            ui.close();
        }

        const hov = ui.hovered(id_name, 0);
        _ = ui.open(.{
            .id = id_name,
            .width = .{ .grow = .{} },
            .height = .{ .fixed = ui.s(36) },
            .align_y = .center,
        });
        const data = try ui.allocator.create(QsSliderDraw);
        data.* = .{ .panel = self, .kind = kind, .hovered = hov };
        const custom = try ui.allocator.create(ui_mod.Custom);
        custom.* = .{ .callback = .{ .function = QsSliderDraw.draw, .data = data } };
        ui.custom(.{ .grow = .{} }, .{ .grow = .{} }, custom, 0);
        ui.close(); // custom
        ui.close(); // slider wrapper

        ui.text(value_str, .{
            .size = if (kind == .volume) sec_sz else ui_sz,
            .color = self.cfg.theme.text_muted,
            .width = ui.s(40),
            .text_align = .right,
        });
        ui.close(); // row
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
        const row_h_u = QsLayout.row_h * scale;
        const sub_sz = self.cfg.typography.submenu_text * scale;
        const btn_sz = self.cfg.typography.button_text * scale;
        const head_sz = self.cfg.typography.heading * scale;
        const content_w: u32 = if (self.width > 2 * pad_u) self.width - 2 * pad_u else self.width;

        const title = switch (self.view_mode) {
            .wifi_menu => "Wi-Fi",
            .bluetooth_menu => "Bluetooth",
            .audio_menu => "Sound & Devices",
            .notifications_menu => "Notifications",
            .recording_menu => "Recording Options",
            .main => "",
        };

        const btn_size: u32 = 34 * scale;
        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .fixed = ui.s(44) },
            .direction = .row,
            .gap = ui.su(8),
            .align_y = .center,
        });

        const back_hov = ui.hovered("qs-back", 0);
        _ = ui.open(.{
            .id = "qs-back",
            .width = .{ .fixed = @floatFromInt(btn_size) },
            .height = .{ .fixed = @floatFromInt(btn_size) },
            .bg = if (back_hov) self.cfg.theme.card_hover_bg else self.cfg.theme.card_bg,
            .radius = ui.f(17),
            .border = ui.su(1),
            .border_color = self.cfg.theme.glass_border,
            .align_x = .center,
            .align_y = .center,
        });
        ui.icon("left", icon_sz, if (back_hov) self.cfg.theme.accent else self.cfg.theme.text_bright, 0);
        ui.close();

        ui.text(title, .{ .size = head_sz, .color = self.cfg.theme.text_bright });
        ui.spacerSized(.{ .grow = .{} }, .{ .fixed = 0 });

        if (self.view_mode == .wifi_menu or self.view_mode == .bluetooth_menu) {
            const is_on = if (self.view_mode == .wifi_menu) self.sys.wifi_enabled else self.sys.bluetooth_enabled;
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
                .radius = ui.f(17),
                .border = ui.su(1),
                .border_color = self.cfg.theme.glass_border,
                .align_x = .center,
                .align_y = .center,
            });
            ui.icon("close", icon_sz, if (hov) self.cfg.theme.error_color else self.cfg.theme.text_bright, 0);
            ui.close();
        } else {
            const hov = ui.hovered("qs-refresh", 0);
            const is_scanning_submenu = self.is_scanning and (self.view_mode == .wifi_menu or self.view_mode == .bluetooth_menu or self.view_mode == .audio_menu or self.view_mode == .recording_menu);
            const refresh_icon = if (is_scanning_submenu) "spinner" else "refresh";
            _ = ui.open(.{
                .id = "qs-refresh",
                .width = .{ .fixed = @floatFromInt(btn_size) },
                .height = .{ .fixed = @floatFromInt(btn_size) },
                .bg = if (hov) self.cfg.theme.card_hover_bg else self.cfg.theme.card_bg,
                .radius = ui.f(17),
                .border = ui.su(1),
                .border_color = self.cfg.theme.glass_border,
                .align_x = .center,
                .align_y = .center,
            });
            ui.icon(refresh_icon, icon_sz, if (hov) self.cfg.theme.accent else self.cfg.theme.text_bright, 0);
            ui.close();
        }
        ui.close(); // header

        ui.rect(.{ .grow = .{} }, .{ .fixed = ui.s(1) }, self.cfg.theme.separator_fg, 0, .{});

        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
            .direction = .column,
            .gap = ui.su(QsLayout.row_gap),
            .clip_vertical = true,
        });

        const max_visible = self.maxVisibleRows();
        switch (self.view_mode) {
            .wifi_menu => {
                if (self.wifi_items.items.len == 0) {
                    self.emptyState(ui, "wifi-none", "No Wi-Fi networks found", "Click refresh to scan", scale);
                } else {
                    const start_idx = self.scroll_offset;
                    const end_idx = @min(self.wifi_items.items.len, start_idx + max_visible);
                    for (self.wifi_items.items[start_idx..end_idx], start_idx..) |item, actual_idx| {
                        const is_connecting_this = (self.wifi_connect_state == .connecting and self.connecting_ssid_len > 0 and
                            std.mem.eql(u8, self.connecting_ssid[0..self.connecting_ssid_len], item.ssid[0..item.ssid_len]));
                        const is_input_active = (self.wifi_input_ssid_len > 0 and
                            std.mem.eql(u8, self.wifi_input_ssid[0..self.wifi_input_ssid_len], item.ssid[0..item.ssid_len]));
                        const has_error = (is_input_active and self.wifi_error_len > 0);
                        const hov = ui.hovered("qs-wifi-card", @intCast(actual_idx));

                        if (is_input_active) {
                            _ = ui.open(.{
                                .id = "qs-wifi-card",
                                .index = @intCast(actual_idx),
                                .width = .{ .grow = .{} },
                                .height = .{ .fixed = ui.s(134) },
                                .direction = .column,
                                .padding = .all(ui.su(10)),
                                .gap = ui.su(6),
                                .bg = self.cfg.theme.elevated,
                                .radius = ui.f(self.cfg.theme.radius_button),
                                .border = ui.su(1),
                                .border_color = if (has_error) self.cfg.theme.error_color else self.cfg.theme.accent,
                            });

                            _ = ui.open(.{
                                .width = .{ .grow = .{} },
                                .height = .{ .fixed = ui.s(28) },
                                .direction = .row,
                                .gap = ui.su(8),
                                .align_y = .center,
                            });
                            ui.text(item.ssid[0..item.ssid_len], .{ .size = sub_sz, .color = self.cfg.theme.text_bright });
                            ui.spacerSized(.{ .grow = .{} }, .{ .fixed = 0 });
                            const cancel_hov = ui.hovered("qs-wifi-input-cancel", 0);
                            _ = ui.open(.{
                                .id = "qs-wifi-input-cancel",
                                .width = .{ .fixed = ui.s(26) },
                                .height = .{ .fixed = ui.s(26) },
                                .bg = if (cancel_hov) self.cfg.theme.card_hover_bg else null,
                                .radius = ui.f(6),
                                .align_x = .center,
                                .align_y = .center,
                            });
                            ui.icon("close", 14 * scale, if (cancel_hov) self.cfg.theme.error_color else self.cfg.theme.text_muted, 0);
                            ui.close();
                            ui.close();

                            _ = ui.open(.{
                                .id = "qs-wifi-input",
                                .width = .{ .grow = .{} },
                                .height = .{ .fixed = ui.s(28) },
                                .padding = .{ .left = ui.su(8), .right = ui.su(8) },
                                .bg = self.cfg.theme.base,
                                .radius = ui.f(6),
                                .border = ui.su(1),
                                .border_color = if (has_error) self.cfg.theme.error_color else self.cfg.theme.accent,
                                .align_y = .center,
                            });
                            if (self.wifi_input != null) {
                                const data = try ui.allocator.create(QsInputDraw);
                                data.* = .{ .panel = self, .size = sub_sz };
                                const custom = try ui.allocator.create(ui_mod.Custom);
                                custom.* = .{ .callback = .{ .function = QsInputDraw.draw, .data = data } };
                                ui.custom(.{ .grow = .{} }, .{ .grow = .{} }, custom, 0);
                                ui.close();
                            } else {
                                if (self.wifi_password_len == 0) {
                                    ui.text("Enter Wi-Fi password...", .{ .size = sub_sz, .color = self.cfg.theme.text_muted });
                                } else {
                                    var mask_buf: [130]u8 = undefined;
                                    const mask_len = @min(self.wifi_password_len, 32);
                                    @memset(mask_buf[0..mask_len], '*');
                                    mask_buf[mask_len] = '|';
                                    ui.text(mask_buf[0 .. mask_len + 1], .{ .size = sub_sz, .color = self.cfg.theme.text_bright });
                                }
                            }
                            ui.close();

                            _ = ui.open(.{
                                .width = .{ .grow = .{} },
                                .height = .{ .fixed = ui.s(26) },
                                .direction = .row,
                                .gap = ui.su(8),
                            });
                            const cancel_btn_hov = ui.hovered("qs-wifi-cancel", 0);
                            _ = ui.open(.{
                                .id = "qs-wifi-cancel",
                                .width = .{ .fixed = ui.s(70) },
                                .height = .{ .grow = .{} },
                                .bg = if (cancel_btn_hov) self.cfg.theme.elevated else self.cfg.theme.surface,
                                .radius = ui.f(6),
                                .border = ui.su(1),
                                .border_color = self.cfg.theme.border,
                                .align_x = .center,
                                .align_y = .center,
                            });
                            ui.text("Cancel", .{ .size = btn_sz, .color = self.cfg.theme.text_bright });
                            ui.close();

                            const is_connecting = (self.wifi_connect_state == .connecting);
                            const conn_hov = ui.hovered("qs-wifi-connect", 0);
                            _ = ui.open(.{
                                .id = "qs-wifi-connect",
                                .width = .{ .fixed = if (is_connecting) ui.s(100) else ui.s(82) },
                                .height = .{ .grow = .{} },
                                .bg = if (is_connecting) self.cfg.theme.elevated else if (conn_hov) self.cfg.theme.accent else self.cfg.theme.surface,
                                .radius = ui.f(6),
                                .border = ui.su(1),
                                .border_color = if (conn_hov and !is_connecting) self.cfg.theme.accent else self.cfg.theme.border,
                                .align_x = .center,
                                .align_y = .center,
                            });
                            ui.text(if (is_connecting) "Connecting..." else "Connect", .{
                                .size = btn_sz,
                                .color = if (conn_hov and !is_connecting) self.cfg.theme.accent_fg else self.cfg.theme.text_bright,
                            });
                            ui.close();
                            ui.close();

                            if (has_error) {
                                ui.text(self.wifi_error_msg[0..self.wifi_error_len], .{
                                    .size = sec_sz,
                                    .color = self.cfg.theme.error_color,
                                });
                            }
                            ui.close(); // input card
                        } else {
                            var bg = if (item.is_active or is_connecting_this) self.cfg.theme.elevated else self.cfg.theme.surface;
                            if (hov) bg = self.cfg.theme.btn_raised_hover;
                            _ = ui.open(.{
                                .id = "qs-wifi-card",
                                .index = @intCast(actual_idx),
                                .width = .{ .grow = .{} },
                                .height = .{ .fixed = @floatFromInt(row_h_u) },
                                .direction = .row,
                                .padding = .{ .left = ui.su(10), .right = ui.su(10) },
                                .gap = ui.su(10),
                                .bg = bg,
                                .radius = ui.f(self.cfg.theme.radius_button),
                                .border = ui.su(1),
                                .border_color = if (item.is_active or is_connecting_this) self.cfg.theme.accent else self.cfg.theme.border,
                                .align_y = .center,
                            });

                            const sig_icon_name = if (item.signal >= 75)
                                "wifi-high"
                            else if (item.signal >= 50)
                                "wifi-medium"
                            else if (item.signal >= 25)
                                "wifi-low"
                            else
                                "wifi-none";
                            _ = ui.open(.{
                                .width = .{ .fixed = ui.s(24) },
                                .height = .{ .fixed = ui.s(24) },
                                .bg = if (item.is_active) self.cfg.theme.toggle_on else self.cfg.theme.btn_raised_bg,
                                .radius = ui.f(12),
                                .border = ui.su(1),
                                .border_color = self.cfg.theme.glass_border,
                                .align_x = .center,
                                .align_y = .center,
                            });
                            ui.icon(sig_icon_name, 16 * scale, if (item.is_active) self.cfg.theme.accent_fg else self.cfg.theme.text_bright, 0);
                            ui.close();

                            _ = ui.open(.{
                                .width = .{ .grow = .{} },
                                .height = .{ .grow = .{} },
                                .direction = .column,
                                .gap = 0,
                                .align_y = .center,
                                .clip_horizontal = true,
                            });
                            var name_buf: [64]u8 = undefined;
                            const trunc_name = truncateText(target, &self.font, item.ssid[0..item.ssid_len], content_w -| 150 * scale, sub_sz, &name_buf);
                            ui.text(trunc_name, .{ .size = sub_sz, .color = self.cfg.theme.text_bright, .line_height = @intCast(sub_sz + 1) });
                            var sub_buf: [64]u8 = undefined;
                            const sec_str = if (item.security_len > 0) item.security[0..item.security_len] else "Open";
                            const sub_str = if (is_connecting_this)
                                "Connecting..."
                            else if (item.is_active)
                                std.fmt.bufPrint(&sub_buf, "Connected • {d}%", .{item.signal}) catch "Connected"
                            else
                                std.fmt.bufPrint(&sub_buf, "{d}% • {s}", .{ item.signal, sec_str }) catch sec_str;
                            ui.text(sub_str, .{
                                .size = sec_sz,
                                .color = if (is_connecting_this) self.cfg.theme.warning_color else if (item.is_active) self.cfg.theme.accent else self.cfg.theme.text_muted,
                                .line_height = @intCast(sec_sz + 1),
                            });
                            ui.close();

                            if (item.is_saved) {
                                const forget_hov = ui.hovered("qs-wifi-forget", @intCast(actual_idx));
                                _ = ui.open(.{
                                    .id = "qs-wifi-forget",
                                    .index = @intCast(actual_idx),
                                    .width = .{ .fixed = ui.s(20) },
                                    .height = .{ .fixed = ui.s(20) },
                                    .bg = if (forget_hov) self.cfg.theme.error_color else self.cfg.theme.surface,
                                    .radius = ui.f(6),
                                    .border = ui.su(1),
                                    .border_color = if (forget_hov) self.cfg.theme.error_color else self.cfg.theme.border,
                                    .align_x = .center,
                                    .align_y = .center,
                                });
                                ui.icon("trash", 14 * scale, if (forget_hov) self.cfg.theme.accent_fg else self.cfg.theme.error_color, 0);
                                ui.close();
                            }

                            if (item.is_active or item.is_saved) {
                                const action_hov = ui.hovered("qs-wifi-action", @intCast(actual_idx));
                                const action_icon = if (item.is_active) "plug-disconnected" else "plug-connected";
                                _ = ui.open(.{
                                    .id = "qs-wifi-action",
                                    .index = @intCast(actual_idx),
                                    .width = .{ .fixed = ui.s(28) },
                                    .height = .{ .fixed = ui.s(28) },
                                    .bg = if (action_hov) (if (item.is_active) self.cfg.theme.error_color else self.cfg.theme.accent) else self.cfg.theme.surface,
                                    .radius = ui.f(6),
                                    .border = ui.su(1),
                                    .border_color = if (action_hov) (if (item.is_active) self.cfg.theme.error_color else self.cfg.theme.accent) else self.cfg.theme.border,
                                    .align_x = .center,
                                    .align_y = .center,
                                });
                                ui.icon(action_icon, 16 * scale, if (item.is_active) self.cfg.theme.accent_fg else if (action_hov) self.cfg.theme.accent_fg else self.cfg.theme.text_bright, 0);
                                ui.close();
                            }

                            ui.close(); // wifi card
                        }
                    }
                }
            },
            .bluetooth_menu => {
                if (self.bt_items.items.len == 0) {
                    self.emptyState(ui, "bluetooth", "No Bluetooth devices found", "Click refresh to scan", scale);
                } else {
                    const start_idx = self.scroll_offset;
                    const end_idx = @min(self.bt_items.items.len, start_idx + max_visible);
                    for (self.bt_items.items[start_idx..end_idx], start_idx..) |item, actual_idx| {
                        const hov = ui.hovered("qs-bt-card", @intCast(actual_idx));
                        var bg = if (item.connected) self.cfg.theme.elevated else self.cfg.theme.surface;
                        if (hov) bg = self.cfg.theme.btn_raised_hover;
                        _ = ui.open(.{
                            .id = "qs-bt-card",
                            .index = @intCast(actual_idx),
                            .width = .{ .grow = .{} },
                            .height = .{ .fixed = @floatFromInt(row_h_u) },
                            .direction = .row,
                            .padding = .{ .left = ui.su(10), .right = ui.su(10) },
                            .gap = ui.su(10),
                            .bg = bg,
                            .radius = ui.f(self.cfg.theme.radius_button),
                            .border = ui.su(1),
                            .border_color = if (item.connected) self.cfg.theme.accent else self.cfg.theme.border,
                            .align_y = .center,
                        });

                        _ = ui.open(.{
                            .width = .{ .fixed = ui.s(24) },
                            .height = .{ .fixed = ui.s(24) },
                            .bg = if (item.connected) self.cfg.theme.toggle_on else self.cfg.theme.btn_raised_bg,
                            .radius = ui.f(12),
                            .border = ui.su(1),
                            .border_color = self.cfg.theme.glass_border,
                            .align_x = .center,
                            .align_y = .center,
                        });
                        ui.icon("bluetooth", 16 * scale, if (item.connected) self.cfg.theme.accent_fg else self.cfg.theme.text_bright, 0);
                        ui.close();

                        _ = ui.open(.{
                            .width = .{ .grow = .{} },
                            .height = .{ .grow = .{} },
                            .direction = .column,
                            .gap = 0,
                            .align_y = .center,
                            .clip_horizontal = true,
                        });
                        var name_buf: [64]u8 = undefined;
                        const trunc_name = truncateText(target, &self.font, item.name[0..item.name_len], content_w -| 150 * scale, sub_sz, &name_buf);
                        ui.text(trunc_name, .{ .size = sub_sz, .color = self.cfg.theme.text_bright, .line_height = @intCast(sub_sz + 1) });
                        ui.text(if (item.connected) "Connected" else "Paired", .{
                            .size = sec_sz,
                            .color = if (item.connected) self.cfg.theme.accent else self.cfg.theme.text_muted,
                            .line_height = @intCast(sec_sz + 1),
                        });
                        ui.close();

                        const forget_hov = ui.hovered("qs-bt-forget", @intCast(actual_idx));
                        _ = ui.open(.{
                            .id = "qs-bt-forget",
                            .index = @intCast(actual_idx),
                            .width = .{ .fixed = ui.s(20) },
                            .height = .{ .fixed = ui.s(20) },
                            .bg = if (forget_hov) self.cfg.theme.error_color else self.cfg.theme.surface,
                            .radius = ui.f(6),
                            .border = ui.su(1),
                            .border_color = if (forget_hov) self.cfg.theme.error_color else self.cfg.theme.border,
                            .align_x = .center,
                            .align_y = .center,
                        });
                        ui.icon("trash", 14 * scale, if (forget_hov) self.cfg.theme.accent_fg else self.cfg.theme.error_color, 0);
                        ui.close();

                        const action_hov = ui.hovered("qs-bt-action", @intCast(actual_idx));
                        _ = ui.open(.{
                            .id = "qs-bt-action",
                            .index = @intCast(actual_idx),
                            .width = .{ .fixed = ui.s(28) },
                            .height = .{ .fixed = ui.s(28) },
                            .bg = if (action_hov) (if (item.connected) self.cfg.theme.error_color else self.cfg.theme.accent) else self.cfg.theme.surface,
                            .radius = ui.f(6),
                            .border = ui.su(1),
                            .border_color = if (action_hov) (if (item.connected) self.cfg.theme.error_color else self.cfg.theme.accent) else self.cfg.theme.border,
                            .align_x = .center,
                            .align_y = .center,
                        });
                        ui.icon(if (item.connected) "plug-disconnected" else "plug-connected", 16 * scale, if (item.connected) self.cfg.theme.accent_fg else if (action_hov) self.cfg.theme.accent_fg else self.cfg.theme.text_bright, 0);
                        ui.close();

                        ui.close(); // bt card
                    }
                }
            },
            .audio_menu => {
                _ = ui.open(.{
                    .width = .{ .grow = .{} },
                    .height = .{ .fixed = ui.s(32) },
                    .direction = .row,
                    .bg = self.cfg.theme.slider_track,
                    .radius = ui.f(8),
                });
                const tab_labels = [_][]const u8{ "Output Devices", "Input Devices" };
                inline for (0..2) |tab_idx| {
                    const selected = (@as(usize, tab_idx) == @intFromEnum(self.audio_tab));
                    const tab_hov = ui.hovered(if (tab_idx == 0) "qs-audio-out" else "qs-audio-in", 0);
                    _ = ui.open(.{
                        .id = if (tab_idx == 0) "qs-audio-out" else "qs-audio-in",
                        .width = .{ .percent = 0.5 },
                        .height = .{ .grow = .{} },
                        .bg = if (selected) self.cfg.theme.btn_raised_bg else if (tab_hov) self.cfg.theme.card_hover_bg else null,
                        .radius = ui.f(8),
                        .align_x = .center,
                        .align_y = .center,
                    });
                    ui.text(tab_labels[tab_idx], .{
                        .size = sub_sz,
                        .color = if (selected) self.cfg.theme.text_main else self.cfg.theme.text_muted,
                    });
                    ui.close();
                }
                ui.close();

                const items = if (self.audio_tab == .output) self.sink_items.items else self.source_items.items;
                const is_output = self.audio_tab == .output;
                if (items.len == 0) {
                    self.emptyState(ui, if (is_output) "volume-muted" else "microphone",
                        if (is_output) "No audio outputs found" else "No audio input devices found",
                        "Click refresh to refresh", scale);
                } else {
                    const start_idx = self.scroll_offset;
                    const end_idx = @min(items.len, start_idx + max_visible);
                    for (items[start_idx..end_idx], start_idx..) |item, actual_idx| {
                        const hov = ui.hovered("qs-audio-item", @intCast(actual_idx));
                        var bg = if (item.is_default) self.cfg.theme.elevated else self.cfg.theme.surface;
                        if (hov) bg = self.cfg.theme.btn_raised_hover;
                        _ = ui.open(.{
                            .id = "qs-audio-item",
                            .index = @intCast(actual_idx),
                            .width = .{ .grow = .{} },
                            .height = .{ .fixed = @floatFromInt(row_h_u) },
                            .direction = .row,
                            .padding = .{ .left = ui.su(10), .right = ui.su(10) },
                            .gap = ui.su(10),
                            .bg = bg,
                            .radius = ui.f(self.cfg.theme.radius_button),
                            .border = ui.su(1),
                            .border_color = if (item.is_default) self.cfg.theme.accent else self.cfg.theme.border,
                            .align_y = .center,
                        });
                        _ = ui.open(.{
                            .width = .{ .fixed = ui.s(24) },
                            .height = .{ .fixed = ui.s(24) },
                            .bg = if (item.is_default) self.cfg.theme.toggle_on else self.cfg.theme.btn_raised_bg,
                            .radius = ui.f(12),
                            .border = ui.su(1),
                            .border_color = self.cfg.theme.glass_border,
                            .align_x = .center,
                            .align_y = .center,
                        });
                        ui.icon(if (is_output) "volume" else "microphone", 16 * scale, if (item.is_default) self.cfg.theme.accent_fg else self.cfg.theme.text_bright, 0);
                        ui.close();

                        _ = ui.open(.{
                            .width = .{ .grow = .{} },
                            .height = .{ .grow = .{} },
                            .direction = .column,
                            .gap = 0,
                            .align_y = .center,
                            .clip_horizontal = true,
                        });
                        var name_buf: [96]u8 = undefined;
                        const trunc_name = truncateText(target, &self.font, item.name[0..item.name_len], content_w -| 90 * scale, sub_sz, &name_buf);
                        ui.text(trunc_name, .{ .size = sub_sz, .color = self.cfg.theme.text_bright, .line_height = @intCast(sub_sz + 1) });
                        var sub_buf: [64]u8 = undefined;
                        const sub_str = if (item.is_default)
                            std.fmt.bufPrint(&sub_buf, "Default • {d}%", .{item.volume_pct}) catch "Default"
                        else
                            std.fmt.bufPrint(&sub_buf, "Volume: {d}%", .{item.volume_pct}) catch "Audio";
                        ui.text(sub_str, .{
                            .size = sec_sz,
                            .color = if (item.is_default) self.cfg.theme.accent else self.cfg.theme.text_muted,
                            .line_height = @intCast(sec_sz + 1),
                        });
                        ui.close();

                        if (item.is_default) {
                            ui.icon("check", 16 * scale, self.cfg.theme.accent, 0);
                        }
                        ui.close(); // audio item
                    }
                }
            },
            .recording_menu => {
                const active_rec = recorder.isRecordingActive();
                const options = [_]struct {
                    mode: recorder.RecordAudioMode,
                    icon_name: []const u8,
                    title: []const u8,
                    description: []const u8,
                    action: Action,
                }{
                    .{ .mode = .system, .icon_name = "volume", .title = "System sounds (default)", .description = "Record desktop and application sounds", .action = .set_recording_mode_system },
                    .{ .mode = .mic, .icon_name = "microphone", .title = "Microphone", .description = "Record voice from the default microphone", .action = .set_recording_mode_mic },
                    .{ .mode = .none, .icon_name = "volume-muted", .title = "No audio", .description = "Record video without audio", .action = .set_recording_mode_none },
                };
                for (options, 0..) |opt, idx| {
                    const selected = (self.record_audio_mode == opt.mode);
                    const hov = ui.hovered("qs-rec-mode", @intCast(idx));
                    _ = ui.open(.{
                        .id = "qs-rec-mode",
                        .index = @intCast(idx),
                        .width = .{ .grow = .{} },
                        .height = .{ .fixed = ui.s(48) },
                        .direction = .row,
                        .padding = .{ .left = ui.su(10), .right = ui.su(10) },
                        .gap = ui.su(10),
                        .bg = if (selected) self.cfg.theme.elevated else if (hov) self.cfg.theme.btn_raised_hover else self.cfg.theme.surface,
                        .radius = ui.f(self.cfg.theme.radius_button),
                        .border = ui.su(1),
                        .border_color = if (selected) self.cfg.theme.accent else self.cfg.theme.border,
                        .align_y = .center,
                    });
                    _ = ui.open(.{
                        .width = .{ .fixed = ui.s(24) },
                        .height = .{ .fixed = ui.s(24) },
                        .bg = if (selected) self.cfg.theme.toggle_on else self.cfg.theme.btn_raised_bg,
                        .radius = ui.f(12),
                        .border = ui.su(1),
                        .border_color = self.cfg.theme.glass_border,
                        .align_x = .center,
                        .align_y = .center,
                    });
                    ui.icon(opt.icon_name, 16 * scale, if (selected) self.cfg.theme.accent_fg else self.cfg.theme.text_bright, 0);
                    ui.close();
                    _ = ui.open(.{
                        .width = .{ .grow = .{} },
                        .height = .{ .grow = .{} },
                        .direction = .column,
                        .gap = 0,
                        .align_y = .center,
                        .clip_horizontal = true,
                    });
                    ui.text(opt.title, .{ .size = sub_sz, .color = self.cfg.theme.text_bright, .line_height = @intCast(sub_sz + 1) });
                    ui.text(opt.description, .{ .size = sec_sz, .color = self.cfg.theme.text_muted, .line_height = @intCast(sec_sz + 1) });
                    ui.close();
                    if (selected) ui.icon("check", 16 * scale, self.cfg.theme.accent, 0);
                    ui.close();
                }

                ui.spacerSized(.{ .fixed = 0 }, .{ .fixed = ui.s(10) });

                if (active_rec) {
                    const hov = ui.hovered("qs-rec-stop", 0);
                    _ = ui.open(.{
                        .id = "qs-rec-stop",
                        .width = .{ .grow = .{} },
                        .height = .{ .fixed = ui.s(40) },
                        .bg = if (hov) self.cfg.theme.error_color else self.cfg.theme.btn_raised_bg,
                        .radius = ui.f(10),
                        .border = ui.su(1),
                        .border_color = self.cfg.theme.error_color,
                        .align_x = .center,
                        .align_y = .center,
                    });
                    ui.text("Stop Recording", .{ .size = btn_sz, .color = if (hov) theme.Color.rgb(255, 255, 255) else self.cfg.theme.error_color });
                    ui.close();
                } else {
                    _ = ui.open(.{
                        .width = .{ .grow = .{} },
                        .height = .{ .fixed = ui.s(40) },
                        .direction = .row,
                        .gap = ui.su(12),
                    });
                    const region_hov = ui.hovered("qs-rec-region", 0);
                    _ = ui.open(.{
                        .id = "qs-rec-region",
                        .width = .{ .percent = 0.5 },
                        .height = .{ .grow = .{} },
                        .bg = if (region_hov) self.cfg.theme.btn_raised_hover else self.cfg.theme.surface,
                        .radius = ui.f(10),
                        .border = ui.su(1),
                        .border_color = self.cfg.theme.glass_border,
                        .padding = .{ .left = ui.su(10), .right = ui.su(6) },
                        .gap = ui.su(8),
                        .align_y = .center,
                    });
                    ui.icon("screen-recording", 16 * scale, self.cfg.theme.text_main, 0);
                    ui.text("Record Region", .{ .size = 13 * scale, .color = self.cfg.theme.text_main });
                    ui.close();

                    const full_hov = ui.hovered("qs-rec-full", 0);
                    _ = ui.open(.{
                        .id = "qs-rec-full",
                        .width = .{ .percent = 0.5 },
                        .height = .{ .grow = .{} },
                        .bg = if (full_hov) self.cfg.theme.btn_raised_hover else self.cfg.theme.surface,
                        .radius = ui.f(10),
                        .border = ui.su(1),
                        .border_color = self.cfg.theme.glass_border,
                        .padding = .{ .left = ui.su(10), .right = ui.su(6) },
                        .gap = ui.su(8),
                        .align_y = .center,
                    });
                    ui.icon("screen-recording", 16 * scale, self.cfg.theme.text_main, 0);
                    ui.text("Record Screen", .{ .size = 13 * scale, .color = self.cfg.theme.text_main });
                    ui.close();
                    ui.close();
                }
            },
            .notifications_menu => {
                const store = &(self.notif_store orelse {
                    ui.close();
                    return;
                });
                if (store.items.items.len == 0) {
                    self.emptyState(ui, "bell-off", "No new notifications", "All caught up!", scale);
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
                        const sum = truncateText(target, &self.font, item.getSummary(), content_w -| 90 * scale, sub_sz, &trunc_sum);
                        ui.text(sum, .{ .size = sub_sz, .color = self.cfg.theme.text_bright, .line_height = @intCast(sub_sz + 3) });
                        const body = item.getBody();
                        if (body.len > 0) {
                            var trunc_bod: [128]u8 = undefined;
                            const bod = truncateText(target, &self.font, body, content_w -| 90 * scale, sec_sz, &trunc_bod);
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
                            .border = ui.su(1),
                            .border_color = self.cfg.theme.glass_border,
                            .align_x = .center,
                            .align_y = .center,
                        });
                        ui.icon("close", 14 * scale, if (dismiss_hov) self.cfg.theme.error_color else self.cfg.theme.text_muted, 0);
                        ui.close();
                        ui.close(); // notification card
                    }
                }
            },
            .main => {},
        }

        ui.close(); // list
    }

    fn emptyState(self: *QuickSettings, ui: *ui_mod.Ui, icon_name: []const u8, message: []const u8, hint: []const u8, scale: u32) void {
        _ = self;
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

    fn appendHitAreas(self: *QuickSettings, ui: *ui_mod.Ui, scale: u32) !void {
        if (self.view_mode == .main) {
            var i: usize = 0;
            while (i < 6) : (i += 1) {
                if (ui.rectOf("qs-main", @intCast(i))) |rect| {
                    try self.appendRect(rect, scale, mainActionForIndex(i));
                }
                if (mainMenuForIndex(i)) |action| {
                    if (ui.rectOf("qs-chev", @intCast(i))) |rect| {
                        try self.appendRect(rect, scale, action);
                    }
                }
            }
            if (ui.rectOf("qs-mute", 0)) |rect| try self.appendRect(rect, scale, .toggle_audio_mute);
            if (ui.rectOf("qs-vol-slider", 0)) |rect| try self.appendRect(rect, scale, .slider_volume);
            if (ui.rectOf("qs-bri-slider", 0)) |rect| try self.appendRect(rect, scale, .slider_brightness);

            const sessions = [_]Action{ .request_logout, .lock, .request_reboot, .request_shutdown };
            for (sessions, 0..) |action, idx| {
                if (ui.rectOf("qs-session", @intCast(idx))) |rect| try self.appendRect(rect, scale, action);
            }
            const media = [_]Action{ .media_prev, .media_play_pause, .media_next };
            for (media, 0..) |action, idx| {
                if (ui.rectOf("qs-media", @intCast(idx))) |rect| try self.appendRect(rect, scale, action);
            }
            return;
        }

        if (ui.rectOf("qs-back", 0)) |rect| try self.appendRect(rect, scale, .back_to_main);
        if (self.view_mode == .notifications_menu) {
            if (ui.rectOf("qs-clear-notifs", 0)) |rect| try self.appendRect(rect, scale, .clear_notifications);
        } else {
            if (ui.rectOf("qs-refresh", 0)) |rect| try self.appendRect(rect, scale, .refresh_sub_menu);
        }
        if (ui.rectOf("qs-header-toggle", 0)) |rect| {
            try self.appendRect(rect, scale, if (self.view_mode == .wifi_menu) .toggle_wifi else .toggle_bluetooth);
        }

        const max_visible = self.maxVisibleRows();
        switch (self.view_mode) {
            .wifi_menu => {
                const start_idx = self.scroll_offset;
                const end_idx = @min(self.wifi_items.items.len, start_idx + max_visible);
                for (self.wifi_items.items[start_idx..end_idx], start_idx..) |item, actual_idx| {
                    const is_input_active = (self.wifi_input_ssid_len > 0 and
                        std.mem.eql(u8, self.wifi_input_ssid[0..self.wifi_input_ssid_len], item.ssid[0..item.ssid_len]));
                    if (is_input_active) {
                        if (ui.rectOf("qs-wifi-input", 0)) |rect| try self.appendRect(rect, scale, .wifi_input_click);
                        if (ui.rectOf("qs-wifi-input-cancel", 0)) |rect| try self.appendRect(rect, scale, .wifi_cancel);
                        if (ui.rectOf("qs-wifi-cancel", 0)) |rect| try self.appendRect(rect, scale, .wifi_cancel);
                        if (ui.rectOf("qs-wifi-connect", 0)) |rect| try self.appendRect(rect, scale, .wifi_connect_submit);
                    } else {
                        if (item.is_saved) {
                            if (ui.rectOf("qs-wifi-forget", @intCast(actual_idx))) |rect| try self.appendRect(rect, scale, .{ .forget_wifi = actual_idx });
                        }
                        if (item.is_active) {
                            if (ui.rectOf("qs-wifi-action", @intCast(actual_idx))) |rect| try self.appendRect(rect, scale, .{ .disconnect_wifi = actual_idx });
                        } else if (item.is_saved) {
                            if (ui.rectOf("qs-wifi-action", @intCast(actual_idx))) |rect| try self.appendRect(rect, scale, .{ .select_wifi = actual_idx });
                        }
                        if (ui.rectOf("qs-wifi-card", @intCast(actual_idx))) |rect| try self.appendRect(rect, scale, .{ .select_wifi = actual_idx });
                    }
                }
            },
            .bluetooth_menu => {
                const start_idx = self.scroll_offset;
                const end_idx = @min(self.bt_items.items.len, start_idx + max_visible);
                for (self.bt_items.items[start_idx..end_idx], start_idx..) |item, actual_idx| {
                    if (ui.rectOf("qs-bt-forget", @intCast(actual_idx))) |rect| try self.appendRect(rect, scale, .{ .remove_bluetooth = actual_idx });
                    if (ui.rectOf("qs-bt-action", @intCast(actual_idx))) |rect| {
                        try self.appendRect(rect, scale, if (item.connected) .{ .disconnect_bluetooth = actual_idx } else .{ .select_bluetooth = actual_idx });
                    }
                    if (ui.rectOf("qs-bt-card", @intCast(actual_idx))) |rect| try self.appendRect(rect, scale, .{ .select_bluetooth = actual_idx });
                }
            },
            .audio_menu => {
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
            .recording_menu => {
                if (ui.rectOf("qs-rec-mode", 0)) |rect| try self.appendRect(rect, scale, .set_recording_mode_system);
                if (ui.rectOf("qs-rec-mode", 1)) |rect| try self.appendRect(rect, scale, .set_recording_mode_mic);
                if (ui.rectOf("qs-rec-mode", 2)) |rect| try self.appendRect(rect, scale, .set_recording_mode_none);
                if (ui.rectOf("qs-rec-stop", 0)) |rect| try self.appendRect(rect, scale, .toggle_recording);
                if (ui.rectOf("qs-rec-region", 0)) |rect| try self.appendRect(rect, scale, .start_record_region);
                if (ui.rectOf("qs-rec-full", 0)) |rect| try self.appendRect(rect, scale, .start_record_fullscreen);
            },
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
            .main => {},
        }
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

    fn mainActionForIndex(idx: usize) Action {
        return switch (idx) {
            0 => .toggle_wifi,
            1 => .toggle_bluetooth,
            2 => .toggle_audio_mute,
            3 => .cycle_power_profile,
            4 => .toggle_caffeine,
            else => .toggle_recording,
        };
    }

    fn mainMenuForIndex(idx: usize) ?Action {
        return switch (idx) {
            0 => .open_wifi_menu,
            1 => .open_bluetooth_menu,
            2 => .open_audio_menu,
            5 => .open_recording_menu,
            else => null,
        };
    }

    fn truncateText(target: anytype, font: *renderer.Font, text: []const u8, max_w: u32, size: u32, buf: []u8) []const u8 {
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
            const w = target.measureTextWithSize(font, buf[0 .. candidate_len + ellipsis.len], size);
            if (w > max_w) break;
            best_len = candidate_len;
        }

        if (best_len == 0) return "";
        @memcpy(buf[0..best_len], text[0..best_len]);
        @memcpy(buf[best_len .. best_len + ellipsis.len], ellipsis);
        return buf[0 .. best_len + ellipsis.len];
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
    const text = std.fmt.bufPrintZ(&buf, "{d}\n", .{pid}) catch return;
    const f = c.fopen(caffeine_pid_path, "wb") orelse return;
    defer _ = c.fclose(f);
    _ = c.fwrite(text.ptr, 1, text.len, f);
}

fn startCaffeine() bool {
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
        if (readCaffeinePid()) |pid| {
            _ = c.kill(pid, c.SIGTERM);
        }
        _ = c.unlink(caffeine_pid_path);
    }
}

test "QuickSettings calculateSliderPercent" {
    try std.testing.expectEqual(@as(u32, 0), QuickSettings.calculateSliderPercent(10, 10, 100));
    try std.testing.expectEqual(@as(u32, 50), QuickSettings.calculateSliderPercent(60, 10, 100));
    try std.testing.expectEqual(@as(u32, 100), QuickSettings.calculateSliderPercent(110, 10, 100));
    try std.testing.expectEqual(@as(u32, 100), QuickSettings.calculateSliderPercent(200, 10, 100));
    try std.testing.expectEqual(@as(u32, 0), QuickSettings.calculateSliderPercent(0, 10, 100));
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
        .wifi_items = std.ArrayList(WifiItem).empty,
        .bt_items = std.ArrayList(BluetoothItem).empty,
        .sink_items = std.ArrayList(AudioSinkItem).empty,
        .source_items = std.ArrayList(AudioDeviceItem).empty,
    };
    defer {
        qs.wifi_items.deinit(allocator);
        qs.bt_items.deinit(allocator);
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
        try qs.wifi_items.append(allocator, .{
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
        .wifi_items = std.ArrayList(WifiItem).empty,
        .bt_items = std.ArrayList(BluetoothItem).empty,
        .sink_items = std.ArrayList(AudioSinkItem).empty,
        .source_items = std.ArrayList(AudioDeviceItem).empty,
    };
    defer {
        qs.wifi_items.deinit(allocator);
        qs.bt_items.deinit(allocator);
        qs.sink_items.deinit(allocator);
        qs.source_items.deinit(allocator);
        qs.hit_areas.deinit(allocator);
    }

    // When wifi_input_idx is null, keys are ignored
    try std.testing.expect(!qs.handleKey(c.XKB_KEY_a, "a"));

    // Activate wifi input
    qs.wifi_input_idx = 0;
    try std.testing.expect(qs.handleKey(c.XKB_KEY_p, "p"));
    try std.testing.expect(qs.handleKey(c.XKB_KEY_a, "a"));
    try std.testing.expect(qs.handleKey(c.XKB_KEY_s, "s"));
    try std.testing.expect(qs.handleKey(c.XKB_KEY_s, "s"));
    try std.testing.expectEqualStrings("pass", qs.wifi_password[0..qs.wifi_password_len]);

    // Backspace
    try std.testing.expect(qs.handleKey(c.XKB_KEY_BackSpace, ""));
    try std.testing.expectEqualStrings("pas", qs.wifi_password[0..qs.wifi_password_len]);

    // Escape cancels
    try std.testing.expect(qs.handleKey(c.XKB_KEY_Escape, ""));
    try std.testing.expect(qs.wifi_input_idx == null);
    try std.testing.expectEqual(@as(usize, 0), qs.wifi_password_len);
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
        .wifi_items = std.ArrayList(WifiItem).empty,
        .bt_items = std.ArrayList(BluetoothItem).empty,
        .sink_items = std.ArrayList(AudioSinkItem).empty,
        .source_items = std.ArrayList(AudioDeviceItem).empty,
    };
    defer {
        qs.wifi_items.deinit(allocator);
        qs.bt_items.deinit(allocator);
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
    try qs.wifi_items.append(allocator, item);

    // Click to select wifi (opens input)
    try qs.hit_areas.append(allocator, .{
        .x = 10,
        .y = 10,
        .w = 100,
        .h = 40,
        .action = .{ .select_wifi = 0 },
    });
    try std.testing.expect(qs.handlePointerButton(15, 15, 272, true));
    try std.testing.expectEqual(@as(?usize, 0), qs.wifi_input_idx);

    // Type password
    try std.testing.expect(qs.handleKey(c.XKB_KEY_s, "s"));
    try std.testing.expect(qs.handleKey(c.XKB_KEY_e, "e"));
    try std.testing.expect(qs.handleKey(c.XKB_KEY_c, "c"));
    try std.testing.expect(qs.handleKey(c.XKB_KEY_r, "r"));
    try std.testing.expect(qs.handleKey(c.XKB_KEY_e, "e"));
    try std.testing.expect(qs.handleKey(c.XKB_KEY_t, "t"));
    try std.testing.expectEqualStrings("secret", qs.wifi_password[0..qs.wifi_password_len]);

    // Click connect button initiates connection
    try qs.hit_areas.append(allocator, .{
        .x = 150,
        .y = 100,
        .w = 60,
        .h = 24,
        .action = .wifi_connect_submit,
    });
    try std.testing.expect(qs.handlePointerButton(160, 110, 272, true));
    try std.testing.expect(qs.wifi_connect_state == .connecting or qs.wifi_connect_state == .failed or qs.wifi_connect_state == .success);

    // Cancel resets input and password
    qs.wifi_connect_state = .idle;
    try qs.hit_areas.append(allocator, .{
        .x = 20,
        .y = 100,
        .w = 60,
        .h = 24,
        .action = .wifi_cancel,
    });
    try std.testing.expect(qs.handlePointerButton(30, 110, 272, true));
    try std.testing.expect(qs.wifi_input_idx == null);
    try std.testing.expectEqual(@as(usize, 0), qs.wifi_password_len);

    var wait_iter: usize = 0;
    while (qs.wifi_worker_running and wait_iter < 50) : (wait_iter += 1) {
        _ = c.usleep(10_000);
        _ = qs.checkWifiStatus();
    }
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
        .wifi_items = std.ArrayList(WifiItem).empty,
        .bt_items = std.ArrayList(BluetoothItem).empty,
        .sink_items = std.ArrayList(AudioSinkItem).empty,
        .source_items = std.ArrayList(AudioDeviceItem).empty,
    };
    defer {
        qs.wifi_items.deinit(allocator);
        qs.bt_items.deinit(allocator);
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
        .wifi_items = std.ArrayList(WifiItem).empty,
        .bt_items = std.ArrayList(BluetoothItem).empty,
        .sink_items = std.ArrayList(AudioSinkItem).empty,
        .source_items = std.ArrayList(AudioDeviceItem).empty,
    };
    defer {
        qs.wifi_items.deinit(allocator);
        qs.bt_items.deinit(allocator);
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
    try qs.wifi_items.append(allocator, item_saved);
    try qs.wifi_items.append(allocator, item_unsaved);
    try std.testing.expect(qs.wifi_items.items[0].is_saved);
    try std.testing.expect(!qs.wifi_items.items[1].is_saved);
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

    try std.testing.expect(init_ns < 250_000_000); // under 250ms (cold fontconfig/sys status init in debug mode)
    try std.testing.expect(tick_ns < 5_000_000); // under 5ms
    try std.testing.expect(render_ns < 30_000_000); // under 30ms (unoptimized debug software rendering)
    try std.testing.expect(deinit_ns < 5_000_000); // under 5ms (zero blocking join!)
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
        .wifi_items = std.ArrayList(WifiItem).empty,
        .bt_items = std.ArrayList(BluetoothItem).empty,
        .sink_items = std.ArrayList(AudioSinkItem).empty,
        .source_items = std.ArrayList(AudioDeviceItem).empty,
    };
    defer {
        qs.wifi_items.deinit(allocator);
        qs.bt_items.deinit(allocator);
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
        .wifi_items = std.ArrayList(WifiItem).empty,
        .bt_items = std.ArrayList(BluetoothItem).empty,
        .sink_items = std.ArrayList(AudioSinkItem).empty,
        .source_items = std.ArrayList(AudioDeviceItem).empty,
    };
    defer {
        qs.wifi_items.deinit(allocator);
        qs.bt_items.deinit(allocator);
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
    try std.testing.expectEqual(recorder.RecordAudioMode.mic, qs.record_audio_mode);
    try std.testing.expectEqual(recorder.RecordAudioMode.mic, recorder.getRecordAudioMode());

    qs.hit_areas.clearRetainingCapacity();
    try qs.hit_areas.append(allocator, .{ .x = 0, .y = 0, .w = 100, .h = 30, .action = .set_recording_mode_none });
    try std.testing.expect(qs.handlePointerButton(10, 10, 272, true));
    try std.testing.expectEqual(recorder.RecordAudioMode.none, qs.record_audio_mode);
    try std.testing.expectEqual(recorder.RecordAudioMode.none, recorder.getRecordAudioMode());

    qs.hit_areas.clearRetainingCapacity();
    try qs.hit_areas.append(allocator, .{ .x = 0, .y = 0, .w = 100, .h = 30, .action = .set_recording_mode_system });
    try std.testing.expect(qs.handlePointerButton(10, 10, 272, true));
    try std.testing.expectEqual(recorder.RecordAudioMode.system, qs.record_audio_mode);
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
        .wifi_items = std.ArrayList(WifiItem).empty,
        .bt_items = std.ArrayList(BluetoothItem).empty,
    };
    defer {
        qs.hit_areas.deinit(allocator);
        qs.wifi_items.deinit(allocator);
        qs.bt_items.deinit(allocator);
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
}
