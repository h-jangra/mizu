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
        if (self.view_mode != .main) {
            return 480;
        }
        if (self.sys.mpris_state != .stopped and self.sys.mpris_track_len > 0) {
            return 430;
        }
        return 520;
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
        const max_visible: usize = 8;
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
        const pad_u = QsLayout.pad * scale;
        const pad_i = @as(i32, @intCast(pad_u));
        const sec_gap_u = QsLayout.section_gap * scale;
        const row_gap_u = QsLayout.row_gap * scale;
        const ctrl_h_u = QsLayout.ctrl_h * scale;
        const radius = self.cfg.theme.radius_panel * scale;

        const ui_sz = self.cfg.typography.ui * scale;
        const sec_sz = self.cfg.typography.secondary * scale;
        const icon_sz = self.cfg.typography.quicksettings_icon * scale;

        // 1. Panel background
        target.clear(theme.Color.transparent);
        target.drawDropShadow(0, 0, w, h, radius, 8 * scale, self.cfg.theme.shadow_dark);
        target.fillRoundedRect(0, 0, w, h, radius, self.cfg.theme.panel_bg);
        target.drawRoundedBorder(0, 0, w, h, radius, 1 * scale, self.cfg.theme.panel_border);

        if (self.view_mode != .main) {
            try self.renderSubMenu(target, scale);
            return;
        }

        const content_w = if (w > 2 * pad_u) w - 2 * pad_u else w;
        var cur_y: i32 = pad_i + self.panel_slide_y;

        // ======================== Row 1: Wi-Fi & Bluetooth Cards ========================
        const card_h: u32 = 44 * scale;
        const card_gap: u32 = 10 * scale;
        const col_w = if (content_w > card_gap) (content_w - card_gap) / 2 else content_w;
        const col0_x = pad_i;
        const col1_x = pad_i + @as(i32, @intCast(col_w + card_gap));

        const is_wifi_on = self.sys.wifi_enabled;
        const wifi_icon_name = if (is_wifi_on) "wifi-high" else "wifi-off";
        const wifi_sub = if (is_wifi_on)
            (if (self.sys.wifi_ssid_len > 0) self.sys.wifi_ssid[0..self.sys.wifi_ssid_len] else "Connected")
        else
            "Off";
        try self.drawToggleCard(target, col0_x, cur_y, col_w, card_h, wifi_icon_name, "Wi-Fi", wifi_sub, is_wifi_on, .toggle_wifi, .open_wifi_menu, scale);

        const is_bt_on = self.sys.bluetooth_enabled;
        const bt_sub = if (is_bt_on) "On" else "Off";
        try self.drawToggleCard(target, col1_x, cur_y, col_w, card_h, "bluetooth", "Bluetooth", bt_sub, is_bt_on, .toggle_bluetooth, .open_bluetooth_menu, scale);

        cur_y += @as(i32, @intCast(card_h + card_gap));

        // ======================== Row 2: Audio & Power Mode Cards ========================
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
        try self.drawToggleCard(target, col0_x, cur_y, col_w, card_h, aud_icon_name, "Sound", aud_sub, is_aud_on, .toggle_audio_mute, .open_audio_menu, scale);

        const prof_sub = switch (self.sys.power_profile) {
            .power_saver => "Power Saver",
            .balanced => "Balanced",
            .performance => "Performance",
        };
        try self.drawToggleCard(target, col1_x, cur_y, col_w, card_h, "powermode", "Power Mode", prof_sub, true, .cycle_power_profile, null, scale);

        cur_y += @as(i32, @intCast(card_h + card_gap));

        // ======================== Row 3: Caffeine & Recording Cards ========================
        const caffeine_sub = if (self.caffeine_enabled) "On" else "Off";
        try self.drawToggleCard(target, col0_x, cur_y, col_w, card_h, "caffeine", "Caffeine", caffeine_sub, self.caffeine_enabled, .toggle_caffeine, null, scale);

        const is_rec_active = recorder.isRecordingActive();
        const rec_sub = self.record_audio_mode.toShortLabel();
        try self.drawToggleCard(target, col1_x, cur_y, col_w, card_h, "record", "Record", rec_sub, is_rec_active, .toggle_recording, .open_recording_menu, scale);

        cur_y += @as(i32, @intCast(card_h + sec_gap_u));

        // ======================== Volume & Brightness Sliders Card ========================
        const slider_card_h: u32 = 2 * card_h + sec_gap_u;
        target.fillRoundedRect(pad_i, cur_y, content_w, slider_card_h, self.cfg.theme.radius_card, self.cfg.theme.card_bg);
        target.drawRoundedBorder(pad_i, cur_y, content_w, slider_card_h, self.cfg.theme.radius_card, 1 * scale, self.cfg.theme.border);

        // Volume row
        const vol_y = cur_y + @as(i32, @intCast(sec_gap_u / 2));
        const slider_y = vol_y;
        const icon_x = pad_i + @as(i32, @intCast(QsLayout.icon_sz * scale / 2));
        const vol_icon_name = if (self.sys.volume_muted)
            "volume-muted"
        else if (self.sys.volume_percent <= 33)
            "volume-low"
        else if (self.sys.volume_percent <= 66)
            "volume-medium"
        else
            "volume-high";
        const vol_icon_fg = if (self.sys.volume_muted) self.cfg.theme.error_color else self.cfg.theme.text_main;
        icons.drawSvgIcon(target, self.allocator, vol_icon_name, icon_sz, scale,
            icon_x, slider_y + @as(i32, @intCast(icon_sz * 3 / 4)), vol_icon_fg);

        try self.hit_areas.append(self.allocator, .{
            .x = pad_i - 4, .y = slider_y - 4,
            .w = icon_sz + 8, .h = ctrl_h_u + 8,
            .action = .toggle_audio_mute,
        });

        var vol_val_buf: [16]u8 = undefined;
        const vol_val_str = if (self.sys.volume_muted) "0%" else (std.fmt.bufPrint(&vol_val_buf, "{d}%", .{self.sys.volume_percent}) catch "50%");
        const val_label_w: u32 = 36;
        const val_text_x = pad_i + @as(i32, @intCast(content_w)) - @as(i32, @intCast(val_label_w)) - @as(i32, @intCast(pad_u / 2));
        target.drawTextWithSize(&self.font, vol_val_str, val_text_x, slider_y + @as(i32, @intCast(ctrl_h_u / 2)) + 2, sec_sz, self.cfg.theme.text_muted);

        const slider_x = icon_x + @as(i32, @intCast(icon_sz + QsLayout.icon_sz * scale / 2));
        const slider_w = content_w - @as(u32, @intCast(slider_x - pad_i)) - val_label_w - @as(u32, @intCast(pad_u / 2));
        target.drawPillSlider(
            slider_x, slider_y, slider_w, ctrl_h_u,
            if (self.sys.volume_muted) 0 else self.sys.volume_percent,
            self.cfg.theme.slider_track, self.cfg.theme.accent,
            self.cfg.theme.slider_thumb, self.cfg.theme.slider_thumb_shadow,
            self.isAreaHovered(slider_x, slider_y, slider_w, ctrl_h_u),
        );
        try self.hit_areas.append(self.allocator, .{
            .x = slider_x, .y = slider_y, .w = slider_w, .h = ctrl_h_u,
            .action = .slider_volume,
        });

        // Brightness row
        const bri_y = vol_y + @as(i32, @intCast(card_h)) + @as(i32, @intCast(row_gap_u));
        const bri_icon_name = if (self.sys.backlight_percent > 50) "sun-filled" else "sun";
        icons.drawSvgIcon(target, self.allocator, bri_icon_name, icon_sz, scale,
            icon_x, bri_y + @as(i32, @intCast(icon_sz * 3 / 4)), self.cfg.theme.text_main);

        var bri_val_buf: [16]u8 = undefined;
        const bri_val_str = std.fmt.bufPrint(&bri_val_buf, "{d}%", .{self.sys.backlight_percent}) catch "100%";
        target.drawTextWithSize(&self.font, bri_val_str, val_text_x, bri_y + @as(i32, @intCast(ctrl_h_u / 2)) + 2, sec_sz, self.cfg.theme.text_muted);

        target.drawPillSlider(
            slider_x, bri_y, slider_w, ctrl_h_u,
            self.sys.backlight_percent,
            self.cfg.theme.slider_track, self.cfg.theme.accent,
            self.cfg.theme.slider_thumb, self.cfg.theme.slider_thumb_shadow,
            self.isAreaHovered(slider_x, bri_y, slider_w, ctrl_h_u),
        );
        try self.hit_areas.append(self.allocator, .{
            .x = slider_x, .y = bri_y, .w = slider_w, .h = ctrl_h_u,
            .action = .slider_brightness,
        });

        cur_y += @as(i32, @intCast(slider_card_h + sec_gap_u));

        // ======================== Battery & Uptime Chips Row ========================
        const chip_h: u32 = 36 * scale;
        const chip_gap: u32 = 10 * scale;
        const uptime_icon_size = 20 * scale;

        var uptime_buf: [32]u8 = undefined;
        const uptime_raw = self.sys.formatUptime(&uptime_buf);
        const uptime_str = if (std.mem.startsWith(u8, uptime_raw, "Uptime · ")) uptime_raw[9..] else uptime_raw;
        const up_text_w = target.measureTextWithSize(&self.font, uptime_str, ui_sz);
        const uptime_chip_w = uptime_icon_size + 10 * scale + up_text_w + 20 * scale;

        const battery_chip_w = content_w - uptime_chip_w - chip_gap;
        const uptime_x = pad_i + @as(i32, @intCast(battery_chip_w + chip_gap));

        // Battery chip
        target.fillRoundedRect(pad_i, cur_y, battery_chip_w, chip_h, self.cfg.theme.radius_pill, self.cfg.theme.card_bg);
        target.drawRoundedBorder(pad_i, cur_y, battery_chip_w, chip_h, self.cfg.theme.radius_pill, 1 * scale, self.cfg.theme.border);

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

        const bat_icon_size = 20 * scale;
        const svg_name = if (plugged or is_charging) "battery-charging" else if (bat_pct <= 10) "battery-empty" else if (bat_pct >= 90) "battery-full" else if (bat_pct >= 60) "battery-high" else if (bat_pct >= 30) "battery-medium" else "battery-low";

        const bat_icon_x = pad_i + 10 * @as(i32, @intCast(scale));
        const bat_icon_y = cur_y + @divTrunc(@as(i32, @intCast(chip_h - bat_icon_size)), 2);
        const svg_icon = icons.getIcon(self.allocator, svg_name, bat_icon_size, scale);
        const bat_cx = bat_icon_x + @as(i32, @intCast(bat_icon_size / 2));
        const bat_cy = bat_icon_y + @as(i32, @intCast(bat_icon_size / 2));
        if (svg_icon) |icon| {
            icons.drawIconRaster(target, icon, bat_cx, bat_cy, bat_color);
        } else {
            const bat_w = bat_icon_size;
            const bat_h = bat_icon_size * 2 / 3;
            icons.drawBattery(target, bat_cx - @as(i32, @intCast(bat_w / 2)), bat_cy - @as(i32, @intCast(bat_h / 2)), bat_w, bat_h, @intCast(bat_pct), is_charging, bat_color);
        }

        const bat_text_x = bat_icon_x + @as(i32, @intCast(bat_icon_size + 10 * scale));
        const text_reserve = @as(u32, @intCast(bat_text_x - pad_i + 6 * @as(i32, @intCast(scale))));
        const max_bat_text_w = if (battery_chip_w > text_reserve) battery_chip_w - text_reserve else 30 * scale;

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
        var trunc_bat_buf: [96]u8 = undefined;
        const trunc_bat = truncateText(target, &self.font, bat_line, max_bat_text_w, ui_sz, &trunc_bat_buf);
        const bat_baseline = cur_y + @divTrunc(@as(i32, @intCast(chip_h)) + @as(i32, @intCast(ui_sz * 3 / 4)), 2) - 1;
        target.drawTextWithSize(&self.font, trunc_bat, bat_text_x, bat_baseline, ui_sz, self.cfg.theme.text_bright);

        // Uptime chip
        target.fillRoundedRect(uptime_x, cur_y, uptime_chip_w, chip_h, self.cfg.theme.radius_pill, self.cfg.theme.card_bg);
        target.drawRoundedBorder(uptime_x, cur_y, uptime_chip_w, chip_h, self.cfg.theme.radius_pill, 1 * scale, self.cfg.theme.border);

        const uptime_icon_x = uptime_x + 10 * @as(i32, @intCast(scale));
        const uptime_icon_y = cur_y + @divTrunc(@as(i32, @intCast(chip_h - uptime_icon_size)), 2);
        const uptime_icon_cx = uptime_icon_x + @as(i32, @intCast(uptime_icon_size / 2));
        const uptime_icon_cy = uptime_icon_y + @as(i32, @intCast(uptime_icon_size / 2));
        icons.drawSvgIcon(target, self.allocator, "uptime", uptime_icon_size, scale, uptime_icon_cx, uptime_icon_cy, self.cfg.theme.text_bright);

        const uptime_text_x = uptime_icon_x + @as(i32, @intCast(uptime_icon_size + 10 * scale));
        const uptime_baseline = cur_y + @divTrunc(@as(i32, @intCast(chip_h)) + @as(i32, @intCast(ui_sz * 3 / 4)), 2) - 1;
        target.drawTextWithSize(&self.font, uptime_str, uptime_text_x, uptime_baseline, ui_sz, self.cfg.theme.text_bright);

        cur_y += @as(i32, @intCast(chip_h + sec_gap_u));

        // ======================== Session Actions (2x2 Grid) ========================
        const session_btn_w: u32 = 40 * scale;
        const session_btn_h: u32 = 40 * scale;
        const session_btn_gap: u32 = 10 * scale;
        const session_grid_w: u32 = session_btn_w * 2 + session_btn_gap;
        const session_grid_h: u32 = session_btn_h * 2 + session_btn_gap;
        const session_x = pad_i + @as(i32, @intCast((content_w - session_grid_w) / 2));
        const session_y = cur_y;

        const sessions = [_]struct {
            act: Action,
            icon: []const u8,
        }{
            .{ .act = .request_logout, .icon = "logout" },
            .{ .act = .lock, .icon = "lock" },
            .{ .act = .request_reboot, .icon = "restart" },
            .{ .act = .request_shutdown, .icon = "power" },
        };

        var si: usize = 0;
        while (si < 4) {
            const col = si % 2;
            const row = si / 2;
            const bx = session_x + @as(i32, @intCast(col * (session_btn_w + session_btn_gap)));
            const by = session_y + @as(i32, @intCast(row * (session_btn_h + session_btn_gap)));
            const is_hov = self.isAreaHovered(bx, by, session_btn_w, session_btn_h);

            const btn_bg = if (is_hov) self.cfg.theme.card_hover_bg else self.cfg.theme.card_bg;
            const btn_border = if (is_hov) self.cfg.theme.border_focused else self.cfg.theme.border;
            const btn_fg = if (is_hov) self.cfg.theme.accent else self.cfg.theme.text_main;

            const r: f64 = @as(f64, @floatFromInt(session_btn_w)) / 2.0;
            const cx: f64 = @as(f64, @floatFromInt(bx)) + r;
            const cy: f64 = @as(f64, @floatFromInt(by)) + r;

            target.drawNeumorphicCircleButton(cx, cy, r, btn_bg, btn_border, is_hov, false);
            icons.drawSvgIcon(target, self.allocator, sessions[si].icon, icon_sz, scale,
                @as(i32, @intFromFloat(cx)), @as(i32, @intFromFloat(cy)), btn_fg);

            try self.hit_areas.append(self.allocator, .{
                .x = bx, .y = by, .w = session_btn_w, .h = session_btn_h,
                .action = sessions[si].act,
            });
            si += 1;
        }

        cur_y += @as(i32, @intCast(session_grid_h + sec_gap_u));

        // ======================== MPRIS Media Card (if active) ========================
        if (self.sys.mpris_state != .stopped and self.sys.mpris_track_len > 0) {
            const media_h: u32 = 48 * scale;
            target.fillRoundedRect(pad_i, cur_y, content_w, media_h, self.cfg.theme.radius_card, self.cfg.theme.card_bg);
            target.drawRoundedBorder(pad_i, cur_y, content_w, media_h, self.cfg.theme.radius_card, 1 * scale, self.cfg.theme.border);

            icons.drawSvgIcon(target, self.allocator, "music", icon_sz, scale,
                pad_i + @as(i32, @intCast(icon_sz)), cur_y + @as(i32, @intCast(media_h / 2)),
                self.cfg.theme.accent);

            const track_str = self.sys.mpris_track[0..self.sys.mpris_track_len];
            var track_buf: [128]u8 = undefined;
            const trunc_track = truncateText(target, &self.font, track_str, content_w - 120, ui_sz, &track_buf);
            target.drawTextWithSize(&self.font, trunc_track, pad_i + @as(i32, @intCast(icon_sz * 2)),
                cur_y + @as(i32, @intCast(media_h / 3)), ui_sz, self.cfg.theme.text_bright);

            const status_label = if (self.sys.mpris_state == .playing) "Playing" else "Paused";
            target.drawTextWithSize(&self.font, status_label, pad_i + @as(i32, @intCast(icon_sz * 2)),
                cur_y + @as(i32, @intCast(media_h * 2 / 3)), sec_sz, self.cfg.theme.text_muted);

            const ctrl_size: u32 = 24 * scale;
            var ctrl_x: i32 = pad_i + @as(i32, @intCast(content_w)) - @as(i32, @intCast(ctrl_size)) - pad_i;

            try self.drawControlBtn(target, ctrl_x, cur_y + @as(i32, @intCast((media_h - ctrl_size) / 2)), ctrl_size, "next", .media_next);
            ctrl_x -= @as(i32, @intCast(ctrl_size + 8 * scale));

            const pp_icon = if (self.sys.mpris_state == .playing) "pause" else "play";
            try self.drawControlBtn(target, ctrl_x, cur_y + @as(i32, @intCast((media_h - ctrl_size) / 2)), ctrl_size, pp_icon, .media_play_pause);
            ctrl_x -= @as(i32, @intCast(ctrl_size + 8 * scale));

            try self.drawControlBtn(target, ctrl_x, cur_y + @as(i32, @intCast((media_h - ctrl_size) / 2)), ctrl_size, "prev", .media_prev);

            cur_y += @as(i32, @intCast(media_h + row_gap_u));
        }

        // Fade-in overlay: covers the whole panel while the open animation runs.
        if (self.panel_alpha < 1.0) {
            const fade_a = @as(u8, @intFromFloat((1.0 - self.panel_alpha) * 255.0));
            if (fade_a > 0) {
                target.fillRoundedRect(0, 0, w, h, radius, theme.Color.init(fade_a, 0, 0, 0));
            }
        }
    }

    fn drawHeaderButton(
        self: *QuickSettings,
        target: anytype,
        x: i32,
        y: i32,
        size: u32,
        icon_name: []const u8,
        action: Action,
        hover_color: theme.Color,
        scale: u32,
    ) !void {
        const is_hovered = self.isAreaHovered(x, y, size, size);
        const bg = if (is_hovered) self.cfg.theme.card_hover_bg else self.cfg.theme.card_bg;
        const fg = if (is_hovered) hover_color else self.cfg.theme.text_main;

        const r: f64 = @as(f64, @floatFromInt(size)) / 2.0;
        const cx = @as(f64, @floatFromInt(x)) + r;
        const cy = @as(f64, @floatFromInt(y)) + r;
        target.drawNeumorphicCircleButton(cx, cy, r, bg, self.cfg.theme.glass_border, is_hovered, false);

        const icon_font_size = self.cfg.typography.quicksettings_icon * scale;
        icons.drawSvgIcon(target, self.allocator, icon_name, icon_font_size, scale, @as(i32, @intFromFloat(cx)), @as(i32, @intFromFloat(cy)), fg);

        try self.hit_areas.append(self.allocator, .{
            .x = x,
            .y = y,
            .w = size,
            .h = size,
            .action = action,
        });
    }

    fn drawToggleCard(
        self: *QuickSettings,
        target: anytype,
        x: i32,
        y: i32,
        w: u32,
        h: u32,
        icon_name: []const u8,
        title: []const u8,
        subtitle: []const u8,
        is_active: bool,
        action: Action,
        chevron_action: ?Action,
        scale: u32,
    ) !void {
        const has_chevron = (chevron_action != null);
        const chevron_w: u32 = if (has_chevron) 44 * scale else 0;
        const main_w: u32 = w - chevron_w;

        const is_main_hovered = self.isAreaHovered(x, y, main_w, h);
        const is_chev_hovered = if (has_chevron)
            self.isAreaHovered(x + @as(i32, @intCast(main_w)), y, chevron_w, h)
        else
            false;

        const radius: u32 = 14 * scale;

        var bg = if (is_active)
            self.cfg.theme.accent
        else
            self.cfg.theme.card_bg;

        if (is_main_hovered) {
            bg = if (is_active)
                theme.Color.init(225, self.cfg.theme.accent.r, self.cfg.theme.accent.g, self.cfg.theme.accent.b)
            else
                self.cfg.theme.card_hover_bg;
        }

        const active_fg = self.cfg.theme.accent_fg;
        const fg = if (is_active) active_fg else self.cfg.theme.text_bright;
        const sub_fg = if (is_active)
            theme.Color.init(220, active_fg.r, active_fg.g, active_fg.b)
        else
            self.cfg.theme.text_muted;

        target.fillRoundedRect(x, y, w, h, radius, bg);
        const border_col = if (is_active) self.cfg.theme.accent else (if (is_main_hovered) self.cfg.theme.border_focused else self.cfg.theme.border);
        target.drawRoundedBorder(x, y, w, h, radius, 1 * scale, border_col);

        const ui_sz = self.cfg.typography.quicksettings_text * scale;
        const sec_sz = self.cfg.typography.secondary * scale;
        const icon_size = self.cfg.typography.quicksettings_icon * scale;

        // Icon (SVG asset)
        const icon_x = x + 14 * @as(i32, @intCast(scale));
        const icon_cx = icon_x + @as(i32, @intCast(icon_size / 2));
        const icon_cy = y + @as(i32, @intCast(h / 2));
        icons.drawSvgIcon(target, self.allocator, icon_name, icon_size, scale, icon_cx, icon_cy, fg);

        // Title and Subtitle
        const text_x = icon_x + @as(i32, @intCast(icon_size + 10 * scale));
        target.drawTextWithSize(&self.font, title, text_x, y + 19 * @as(i32, @intCast(scale)), ui_sz, fg);

        var sub_buf: [64]u8 = undefined;
        const padding: u32 = @as(u32, @intCast(4 * scale));
        const text_offset = @as(u32, @intCast(text_x - x));
        const max_sub_w = if (main_w > text_offset + icon_size + 10 * scale + padding) main_w - (text_offset + icon_size + 10 * scale + padding) else 0;
        const trunc_sub = truncateText(target, &self.font, subtitle, max_sub_w, sec_sz, &sub_buf);
        target.drawTextWithSize(&self.font, trunc_sub, text_x, y + 35 * @as(i32, @intCast(scale)), sec_sz, sub_fg);

        try self.hit_areas.append(self.allocator, .{
            .x = x,
            .y = y,
            .w = main_w,
            .h = h,
            .action = action,
        });

        // Dropdown Chevron on the right side
        if (has_chevron) {
            const chev_x = x + @as(i32, @intCast(main_w));
            const scale_i = @as(i32, @intCast(scale));
            const scale_u = @as(u32, @intCast(scale));

            // Subtle vertical divider line
            const div_col = if (is_active) theme.Color.init(50, 255, 255, 255) else self.cfg.theme.border;
            target.fillRect(chev_x, y + 8 * scale_i, 1 * scale_u, h - 16 * scale_u, div_col);

            if (is_chev_hovered) {
                const chev_hov_bg = if (is_active) theme.Color.init(35, 255, 255, 255) else theme.Color.init(25, 255, 255, 255);
                target.fillRect(chev_x + 1 * scale_i, y + 4 * scale_i, chevron_w - 4 * scale_u, h - 8 * scale_u, chev_hov_bg);
            }

            const chev_fg = if (is_active) active_fg else self.cfg.theme.text_muted;
            const chev_cx = chev_x + @as(i32, @intCast(chevron_w / 2));
            const chev_cy = y + @as(i32, @intCast(h / 2));
            icons.drawSvgIcon(target, self.allocator, "right", icon_size, scale, chev_cx, chev_cy, chev_fg);

            try self.hit_areas.append(self.allocator, .{
                .x = chev_x,
                .y = y,
                .w = chevron_w,
                .h = h,
                .action = chevron_action.?,
            });
        }
    }

    fn renderSubMenu(self: *QuickSettings, target: anytype, scale: u32) !void {
        const w = target.width;
        const pad_u = QsLayout.pad * scale;
        const pad_i = @as(i32, @intCast(pad_u));
        const sec_gap_u = QsLayout.section_gap * scale;
        const row_gap_u = QsLayout.row_gap * scale;
        const row_h_u = QsLayout.row_h * scale;
        const icon_sz = self.cfg.typography.quicksettings_icon * scale;
        const sub_sz = self.cfg.typography.submenu_text * scale;
        const sec_sz = self.cfg.typography.secondary * scale;
        const btn_sz = self.cfg.typography.button_text * scale;

        const content_w = if (w > 2 * pad_u) w - 2 * pad_u else w;

        const title = switch (self.view_mode) {
            .wifi_menu => "Wi-Fi",
            .bluetooth_menu => "Bluetooth",
            .audio_menu => "Sound & Devices",
            .notifications_menu => "Notifications",
            .recording_menu => "Recording Options",
            .main => "",
        };

        // Header
        const head_h: u32 = 44 * scale;
        const btn_size: u32 = 34 * scale;
        const cur_y: i32 = pad_i;

        // Back button
        try self.drawHeaderButton(target, pad_i, cur_y + @as(i32, @intCast((head_h - btn_size) / 2)), btn_size, "left", .back_to_main, self.cfg.theme.text_bright, scale);

        // Title
        target.drawTextWithSize(&self.font, title, pad_i + @as(i32, @intCast(btn_size + 12 * scale)),
            cur_y + @as(i32, @intCast(head_h / 2)) + 2, self.cfg.typography.heading * scale, self.cfg.theme.text_bright);

        // Right side: toggle (WiFi/BT) or refresh
        const right_x = @as(i32, @intCast(w)) - pad_i - @as(i32, @intCast(btn_size));
        if (self.view_mode == .notifications_menu) {
            try self.drawHeaderButton(target, right_x, cur_y + @as(i32, @intCast((head_h - btn_size) / 2)), btn_size, "close", .clear_notifications, self.cfg.theme.error_color, scale);
        } else {
            const is_scanning_submenu = self.is_scanning and (self.view_mode == .wifi_menu or self.view_mode == .bluetooth_menu or self.view_mode == .audio_menu or self.view_mode == .recording_menu);
            const refresh_icon = if (is_scanning_submenu) "spinner" else "refresh";
            try self.drawHeaderButton(target, right_x, cur_y + @as(i32, @intCast((head_h - btn_size) / 2)), btn_size, refresh_icon, .refresh_sub_menu, self.cfg.theme.text_bright, scale);
        }

        // Toggle switch in header for Wi-Fi and Bluetooth
        if (self.view_mode == .wifi_menu or self.view_mode == .bluetooth_menu) {
            const toggle_w: u32 = 46 * scale;
            const toggle_h: u32 = 20 * scale;
            const toggle_x = right_x - @as(i32, @intCast(toggle_w)) - @as(i32, @intCast(12 * scale));
            const toggle_y = cur_y + @as(i32, @intCast((head_h - toggle_h) / 2));
            const is_on = if (self.view_mode == .wifi_menu) self.sys.wifi_enabled else self.sys.bluetooth_enabled;
            const action: Action = if (self.view_mode == .wifi_menu) .toggle_wifi else .toggle_bluetooth;

            target.drawToggleSwitch(
                toggle_x, toggle_y, toggle_w, toggle_h,
                is_on,
                self.cfg.theme.toggle_on,
                self.cfg.theme.toggle_off,
                self.cfg.theme.slider_thumb,
            );
            try self.hit_areas.append(self.allocator, .{
                .x = toggle_x, .y = toggle_y, .w = toggle_w, .h = toggle_h,
                .action = action,
            });
        }

        // Separator
        const sep_y = cur_y + @as(i32, @intCast(head_h)) + @as(i32, @intCast(row_gap_u));
        target.fillRect(pad_i, sep_y, content_w, 1 * scale, self.cfg.theme.separator_fg);

        var list_y = sep_y + @as(i32, @intCast(sec_gap_u));
        const item_h = row_h_u;
        const item_gap = row_gap_u;
        const max_visible: usize = 8;

        switch (self.view_mode) {
            .wifi_menu => {
                if (self.wifi_items.items.len == 0) {
                    self.drawEmptySubMenu(target, "wifi-none", "No Wi-Fi networks found", "Click refresh to scan", scale);
                    return;
                }
                const start_idx = self.scroll_offset;
                const end_idx = @min(self.wifi_items.items.len, start_idx + max_visible);

                for (self.wifi_items.items[start_idx..end_idx], start_idx..) |item, actual_idx| {
                    const is_connecting_this = (self.wifi_connect_state == .connecting and self.connecting_ssid_len > 0 and
                        std.mem.eql(u8, self.connecting_ssid[0..self.connecting_ssid_len], item.ssid[0..item.ssid_len]));
                    const is_input_active = (self.wifi_input_ssid_len > 0 and
                        std.mem.eql(u8, self.wifi_input_ssid[0..self.wifi_input_ssid_len], item.ssid[0..item.ssid_len]));
                    const has_error = (is_input_active and self.wifi_error_len > 0);

                    var bg = if (item.is_active or is_input_active or is_connecting_this)
                        self.cfg.theme.elevated
                    else
                        self.cfg.theme.surface;
                    const is_hovered = self.isAreaHovered(pad_i, list_y, content_w, item_h);
                    if (is_hovered and !is_input_active) {
                        bg = self.cfg.theme.btn_raised_hover;
                    }

                    target.fillRoundedRect(pad_i, list_y, content_w, item_h, self.cfg.theme.radius_button, bg);
                    target.drawRoundedBorder(pad_i, list_y, content_w, item_h, self.cfg.theme.radius_button, 1 * scale,
                        if (is_connecting_this or is_input_active or item.is_active) self.cfg.theme.accent else self.cfg.theme.border);

                    // Signal icon
                    const sig_icon_name = if (item.signal >= 75)
                        "wifi-high"
                    else if (item.signal >= 50)
                        "wifi-medium"
                    else if (item.signal >= 25)
                        "wifi-low"
                    else
                        "wifi-none";

                    const icon_size: u32 = 24 * scale;
                    const icon_x = pad_i + 10 * @as(i32, @intCast(scale));
                    const icon_y = list_y + @as(i32, @intCast((item_h - icon_size) / 2));
                    const icon_cx = @as(f64, @floatFromInt(icon_x)) + @as(f64, @floatFromInt(icon_size)) / 2.0;
                    const icon_cy = @as(f64, @floatFromInt(icon_y)) + @as(f64, @floatFromInt(icon_size)) / 2.0;

                    const icon_bg = if (item.is_active) self.cfg.theme.toggle_on else self.cfg.theme.btn_raised_bg;
                    target.drawNeumorphicCircleButton(icon_cx, icon_cy, @as(f64, @floatFromInt(icon_size)) / 2.0,
                        icon_bg, self.cfg.theme.glass_border, is_hovered, item.is_active);

                    const icon_color = if (item.is_active) self.cfg.theme.accent_fg else self.cfg.theme.text_bright;
                    icons.drawSvgIcon(target, self.allocator, sig_icon_name, icon_sz, scale,
                        @as(i32, @intFromFloat(icon_cx)), @as(i32, @intFromFloat(icon_cy)), icon_color);

                    // SSID name
                    const ssid_x = icon_x + @as(i32, @intCast(icon_size + 12 * scale));
                    const ssid_name = item.ssid[0..item.ssid_len];
                    var name_buf: [64]u8 = undefined;
                    const name_reserve: u32 = if (item.is_saved) 154 else 110;
                    const trunc_name = truncateText(target, &self.font, ssid_name, content_w - name_reserve, sub_sz, &name_buf);
                    target.drawTextWithSize(&self.font, trunc_name, ssid_x, list_y + @as(i32, @intCast(14 * scale)), sub_sz, self.cfg.theme.text_bright);

                    // Subtitle
                    var sub_buf: [64]u8 = undefined;
                    const sec_str = if (item.security_len > 0) item.security[0..item.security_len] else "Open";
                    const sub_str = if (is_connecting_this)
                        "󱑂 Connecting..."
                    else if (item.is_active)
                        std.fmt.bufPrint(&sub_buf, "✓ Connected • {d}%", .{item.signal}) catch "✓ Connected"
                    else
                        std.fmt.bufPrint(&sub_buf, "{d}% • {s}", .{ item.signal, sec_str }) catch sec_str;

                    const sub_color = if (is_connecting_this)
                        self.cfg.theme.warning_color
                    else if (item.is_active)
                        self.cfg.theme.accent
                    else
                        self.cfg.theme.text_muted;
                    target.drawTextWithSize(&self.font, sub_str, ssid_x, list_y + @as(i32, @intCast(28 * scale)), sec_sz, sub_color);

                    // Actions
                    if (!is_input_active) {
                        const action_size: u32 = 28 * scale;
                        const action_x = pad_i + @as(i32, @intCast(content_w)) - @as(i32, @intCast(action_size)) - pad_i;
                        const action_y = list_y + @as(i32, @intCast((item_h - action_size) / 2));
                        const is_action_hov = self.isAreaHovered(action_x, action_y, action_size, action_size);

                        var action_icon: []const u8 = "";
                        var action_callback: Action = .toggle_wifi;

                        if (item.is_active) {
                            action_icon = "plug-disconnected";
                            action_callback = .{ .disconnect_wifi = actual_idx };
                        } else if (item.is_saved) {
                            action_icon = "plug-connected";
                            action_callback = .{ .select_wifi = actual_idx };
                        }

                        if (item.is_saved) {
                            const trash_size: u32 = 20 * scale;
                            const trash_x = action_x - @as(i32, @intCast(trash_size)) - @as(i32, @intCast(6 * scale));
                            const trash_y = list_y + @as(i32, @intCast(2 * scale));
                            const is_trash_hov = self.isAreaHovered(trash_x, trash_y, trash_size, trash_size);
                            const trash_bg = if (is_trash_hov) self.cfg.theme.error_color else self.cfg.theme.surface;
                            const trash_fg = if (is_trash_hov) self.cfg.theme.accent_fg else self.cfg.theme.error_color;
                            target.fillSquircle(trash_x, trash_y, trash_size, trash_size, 6 * scale, trash_bg);
                            target.drawSquircleBorder(trash_x, trash_y, trash_size, trash_size, 6 * scale, 1 * scale,
                                if (is_trash_hov) self.cfg.theme.error_color else self.cfg.theme.border);
                            icons.drawSvgIcon(target, self.allocator, "trash", icon_sz, scale,
                                trash_x + @as(i32, @intCast(trash_size / 2)), trash_y + @as(i32, @intCast(trash_size / 2)), trash_fg);
                            try self.hit_areas.append(self.allocator, .{
                                .x = trash_x, .y = trash_y, .w = trash_size, .h = trash_size,
                                .action = .{ .forget_wifi = actual_idx },
                            });
                        }

                        if (action_icon.len > 0) {
                            if (is_action_hov) {
                                target.fillSquircle(action_x, action_y, action_size, action_size, 6 * scale,
                                    if (item.is_active) self.cfg.theme.error_color else self.cfg.theme.accent);
                                target.drawSquircleBorder(action_x, action_y, action_size, action_size, 6 * scale, 1 * scale,
                                    if (item.is_active) self.cfg.theme.error_color else self.cfg.theme.border);
                            } else {
                                target.fillSquircle(action_x, action_y, action_size, action_size, 6 * scale, self.cfg.theme.surface);
                                target.drawSquircleBorder(action_x, action_y, action_size, action_size, 6 * scale, 1 * scale, self.cfg.theme.border);
                            }
                            const action_fg = if (item.is_active) self.cfg.theme.accent_fg else self.cfg.theme.text_bright;
                            icons.drawSvgIcon(target, self.allocator, action_icon, icon_sz, scale,
                                action_x + @as(i32, @intCast(action_size / 2)), action_y + @as(i32, @intCast(action_size / 2)), action_fg);
                            try self.hit_areas.append(self.allocator, .{
                                .x = action_x, .y = action_y, .w = action_size, .h = action_size,
                                .action = action_callback,
                            });
                        }

                        // Checkmark if active
                        const aux_x = if (item.is_saved) action_x - 60 * @as(i32, @intCast(scale)) else action_x - 24 * @as(i32, @intCast(scale));
                        if (item.is_active) {
                            icons.drawSvgIcon(target, self.allocator, "check", icon_sz, scale,
                                aux_x + @as(i32, @intCast(icon_sz / 2)), list_y + @as(i32, @intCast(20 * scale)), self.cfg.theme.accent);
                        }

                        // Lock icon
                        const is_secured = (item.security_len > 0 and !std.mem.eql(u8, item.security[0..item.security_len], "Open"));
                        if (is_secured and !item.is_active) {
                            icons.drawSvgIcon(target, self.allocator, "lock", icon_sz, scale,
                                aux_x + @as(i32, @intCast(icon_sz / 2)), list_y + @as(i32, @intCast(20 * scale)), self.cfg.theme.text_muted);
                        }

                        // Hit area for selecting wifi
                        const hit_w = if (item.is_saved or item.is_active) content_w - @as(u32, @intCast(action_size)) - 12 * scale else content_w;
                        try self.hit_areas.append(self.allocator, .{
                            .x = pad_i, .y = list_y, .w = hit_w, .h = item_h,
                            .action = .{ .select_wifi = actual_idx },
                        });
                    } else {
                        // Wi-Fi password input
                        try self.hit_areas.append(self.allocator, .{
                            .x = pad_i, .y = list_y, .w = content_w, .h = 44 * scale,
                            .action = .wifi_cancel,
                        });

                        const input_x = pad_i + 40 * @as(i32, @intCast(scale));
                        const input_y = list_y + @as(i32, @intCast(48 * scale));
                        const input_w = content_w - 56 * scale;
                        const input_h: u32 = 28 * scale;

                        target.fillSquircle(input_x, input_y, input_w, input_h, 6 * scale, self.cfg.theme.base);
                        const input_border = if (has_error) self.cfg.theme.error_color else self.cfg.theme.accent;
                        target.drawSquircleBorder(input_x, input_y, input_w, input_h, 6 * scale, 1 * scale, input_border);

                        if (self.wifi_input) |*inp| {
                            inp.render(
                                target,
                                &self.font,
                                input_x,
                                input_y,
                                input_w,
                                input_h,
                                input_x + 8,
                                self.cfg.theme.text_bright,
                                self.cfg.theme.text_muted,
                                self.cfg.theme.accent,
                                sub_sz,
                            );
                        } else {
                            if (self.wifi_password_len == 0) {
                                target.drawTextWithSize(&self.font, "Enter Wi-Fi password... |", input_x + 8, input_y + 19, sub_sz, self.cfg.theme.text_muted);
                            } else {
                                var mask_buf: [130]u8 = undefined;
                                const mask_len = @min(self.wifi_password_len, 32);
                                @memset(mask_buf[0..mask_len], '*');
                                mask_buf[mask_len] = '|';
                                target.drawTextWithSize(&self.font, mask_buf[0 .. mask_len + 1], input_x + 8, input_y + 19, sub_sz, self.cfg.theme.text_bright);
                            }
                        }

                        try self.hit_areas.append(self.allocator, .{
                            .x = input_x, .y = input_y, .w = input_w, .h = input_h,
                            .action = .wifi_input_click,
                        });

                        const btn_y = list_y + @as(i32, @intCast(84 * scale));
                        const cancel_w: u32 = 70 * scale;
                        const is_connecting = (self.wifi_connect_state == .connecting);
                        const connect_w: u32 = if (is_connecting) 100 * scale else 82 * scale;
                        const btn_h: u32 = 26 * scale;

                        const is_cancel_hovered = self.isAreaHovered(input_x, btn_y, cancel_w, btn_h);
                        const cancel_bg = if (is_cancel_hovered) self.cfg.theme.elevated else self.cfg.theme.surface;
                        target.fillSquircle(input_x, btn_y, cancel_w, btn_h, 6 * scale, cancel_bg);
                        target.drawSquircleBorder(input_x, btn_y, cancel_w, btn_h, 6 * scale, 1 * scale, self.cfg.theme.border);
                        const c_text_w = target.measureTextWithSize(&self.font, "Cancel", btn_sz);
                        const c_text_x = input_x + @divTrunc(@as(i32, @intCast(cancel_w)) - @as(i32, @intCast(c_text_w)), 2);
                        target.drawTextWithSize(&self.font, "Cancel", c_text_x, btn_y + 19, btn_sz, self.cfg.theme.text_bright);
                        try self.hit_areas.append(self.allocator, .{
                            .x = input_x, .y = btn_y, .w = cancel_w, .h = btn_h,
                            .action = .wifi_cancel,
                        });

                        const conn_x = input_x + @as(i32, @intCast(cancel_w + 8 * scale));
                        const is_conn_hovered = self.isAreaHovered(conn_x, btn_y, connect_w, btn_h);
                        const conn_bg = if (is_connecting)
                            self.cfg.theme.elevated
                        else if (is_conn_hovered)
                            self.cfg.theme.accent
                        else
                            self.cfg.theme.surface;
                        const conn_fg = if (is_conn_hovered and !is_connecting) self.cfg.theme.accent_fg else self.cfg.theme.text_bright;
                        target.fillSquircle(conn_x, btn_y, connect_w, btn_h, 6 * scale, conn_bg);
                        target.drawSquircleBorder(conn_x, btn_y, connect_w, btn_h, 6 * scale, 1 * scale,
                            if (is_conn_hovered and !is_connecting) self.cfg.theme.accent else self.cfg.theme.border);

                        const conn_label = if (is_connecting) "Connecting..." else "Connect";
                        const k_text_w = target.measureTextWithSize(&self.font, conn_label, btn_sz);
                        const k_text_x = conn_x + @divTrunc(@as(i32, @intCast(connect_w)) - @as(i32, @intCast(k_text_w)), 2);
                        target.drawTextWithSize(&self.font, conn_label, k_text_x, btn_y + 19, btn_sz, conn_fg);
                        try self.hit_areas.append(self.allocator, .{
                            .x = conn_x, .y = btn_y, .w = connect_w, .h = btn_h,
                            .action = .wifi_connect_submit,
                        });

                        if (has_error) {
                            target.drawTextWithSize(&self.font, "󰅚", input_x, btn_y + @as(i32, @intCast(38 * scale)), sec_sz, self.cfg.theme.error_color);
                            target.drawTextWithSize(&self.font, self.wifi_error_msg[0..self.wifi_error_len], input_x + 18, btn_y + @as(i32, @intCast(38 * scale)), sec_sz, self.cfg.theme.error_color);
                        }
                    }

                    list_y += @as(i32, @intCast(item_h + item_gap));
                }
            },
            .bluetooth_menu => {
                if (self.bt_items.items.len == 0) {
                    self.drawEmptySubMenu(target, "bluetooth", "No Bluetooth devices found", "Click refresh to scan", scale);
                    return;
                }
                const start_idx = self.scroll_offset;
                const end_idx = @min(self.bt_items.items.len, start_idx + max_visible);

                for (self.bt_items.items[start_idx..end_idx], start_idx..) |item, actual_idx| {
                    const is_hovered = self.isAreaHovered(pad_i, list_y, content_w, item_h);

                    var bg = if (item.connected)
                        self.cfg.theme.elevated
                    else
                        self.cfg.theme.surface;
                    if (is_hovered) {
                        bg = self.cfg.theme.btn_raised_hover;
                    }

                    target.fillRoundedRect(pad_i, list_y, content_w, item_h, self.cfg.theme.radius_button, bg);
                    target.drawRoundedBorder(pad_i, list_y, content_w, item_h, self.cfg.theme.radius_button, 1 * scale,
                        if (item.connected) self.cfg.theme.accent else self.cfg.theme.border);

                    // Device icon
                    const icon_size: u32 = 24 * scale;
                    const icon_x = pad_i + 10 * @as(i32, @intCast(scale));
                    const icon_y = list_y + @as(i32, @intCast((item_h - icon_size) / 2));
                    const icon_cx = @as(f64, @floatFromInt(icon_x)) + @as(f64, @floatFromInt(icon_size)) / 2.0;
                    const icon_cy = @as(f64, @floatFromInt(icon_y)) + @as(f64, @floatFromInt(icon_size)) / 2.0;

                    const icon_bg = if (item.connected) self.cfg.theme.toggle_on else self.cfg.theme.btn_raised_bg;
                    target.drawNeumorphicCircleButton(icon_cx, icon_cy, @as(f64, @floatFromInt(icon_size)) / 2.0,
                        icon_bg, self.cfg.theme.glass_border, is_hovered, item.connected);

                    const icon_color = if (item.connected) self.cfg.theme.accent_fg else self.cfg.theme.text_bright;
                    icons.drawSvgIcon(target, self.allocator, "bluetooth", icon_sz, scale,
                        @as(i32, @intFromFloat(icon_cx)), @as(i32, @intFromFloat(icon_cy)), icon_color);

                    // Device name
                    const dev_name = item.name[0..item.name_len];
                    var name_buf: [64]u8 = undefined;
                    const trunc_name = truncateText(target, &self.font, dev_name, content_w - 144, sub_sz, &name_buf);
                    const dev_x = icon_x + @as(i32, @intCast(icon_size + 12 * scale));
                    target.drawTextWithSize(&self.font, trunc_name, dev_x, list_y + @as(i32, @intCast(14 * scale)), sub_sz, self.cfg.theme.text_bright);

                    // Subtitle
                    const sub_str = if (item.connected) "Connected" else "Paired";
                    const sub_color = if (item.connected) self.cfg.theme.accent else self.cfg.theme.text_muted;
                    target.drawTextWithSize(&self.font, sub_str, dev_x, list_y + @as(i32, @intCast(28 * scale)), sec_sz, sub_color);

                    // Connect/Disconnect button
                    const action_size_bt: u32 = 28 * scale;
                    const action_x = pad_i + @as(i32, @intCast(content_w)) - @as(i32, @intCast(action_size_bt)) - pad_i;
                    const action_y = list_y + @as(i32, @intCast((item_h - action_size_bt) / 2));
                    const is_action_hov = self.isAreaHovered(action_x, action_y, action_size_bt, action_size_bt);

                    var action_icon: []const u8 = "";
                    var action_callback: Action = .toggle_wifi;

                    if (item.connected) {
                        action_icon = "plug-disconnected";
                        action_callback = .{ .disconnect_bluetooth = actual_idx };
                    } else {
                        action_icon = "plug-connected";
                        action_callback = .{ .select_bluetooth = actual_idx };
                    }

                    if (is_action_hov) {
                        target.fillSquircle(action_x, action_y, action_size_bt, action_size_bt, 6 * scale,
                            if (item.connected) self.cfg.theme.error_color else self.cfg.theme.accent);
                        target.drawSquircleBorder(action_x, action_y, action_size_bt, action_size_bt, 6 * scale, 1 * scale,
                            if (item.connected) self.cfg.theme.error_color else self.cfg.theme.border);
                    } else {
                        target.fillSquircle(action_x, action_y, action_size_bt, action_size_bt, 6 * scale, self.cfg.theme.surface);
                        target.drawSquircleBorder(action_x, action_y, action_size_bt, action_size_bt, 6 * scale, 1 * scale, self.cfg.theme.border);
                    }
                    const action_fg = if (item.connected) self.cfg.theme.accent_fg else self.cfg.theme.text_bright;
                    icons.drawSvgIcon(target, self.allocator, action_icon, icon_sz, scale,
                        action_x + @as(i32, @intCast(action_size_bt / 2)), action_y + @as(i32, @intCast(action_size_bt / 2)), action_fg);
                    try self.hit_areas.append(self.allocator, .{
                        .x = action_x, .y = action_y, .w = action_size_bt, .h = action_size_bt,
                        .action = action_callback,
                    });

                    // Trash icon
                    const trash_size_bt: u32 = 20 * scale;
                    const trash_x_bt = action_x - @as(i32, @intCast(trash_size_bt)) - @as(i32, @intCast(6 * scale));
                    const trash_y_bt = list_y + @as(i32, @intCast(2 * scale));
                    const is_trash_hov_bt = self.isAreaHovered(trash_x_bt, trash_y_bt, trash_size_bt, trash_size_bt);
                    const trash_bg_bt = if (is_trash_hov_bt) self.cfg.theme.error_color else self.cfg.theme.surface;
                    const trash_fg_bt = if (is_trash_hov_bt) self.cfg.theme.accent_fg else self.cfg.theme.error_color;
                    target.fillSquircle(trash_x_bt, trash_y_bt, trash_size_bt, trash_size_bt, 6 * scale, trash_bg_bt);
                    target.drawSquircleBorder(trash_x_bt, trash_y_bt, trash_size_bt, trash_size_bt, 6 * scale, 1 * scale,
                        if (is_trash_hov_bt) self.cfg.theme.error_color else self.cfg.theme.border);
                    icons.drawSvgIcon(target, self.allocator, "trash", icon_sz, scale,
                        trash_x_bt + @as(i32, @intCast(trash_size_bt / 2)), trash_y_bt + @as(i32, @intCast(trash_size_bt / 2)), trash_fg_bt);
                    try self.hit_areas.append(self.allocator, .{
                        .x = trash_x_bt, .y = trash_y_bt, .w = trash_size_bt, .h = trash_size_bt,
                        .action = .{ .remove_bluetooth = actual_idx },
                    });

                    // Checkmark if connected
                    if (item.connected) {
                        const check_x_bt = action_x - 60 * @as(i32, @intCast(scale));
                        icons.drawSvgIcon(target, self.allocator, "check", icon_sz, scale,
                            check_x_bt + @as(i32, @intCast(icon_sz / 2)), list_y + @as(i32, @intCast(20 * scale)), self.cfg.theme.accent);
                    }

                    try self.hit_areas.append(self.allocator, .{
                        .x = pad_i, .y = list_y, .w = content_w - @as(u32, @intCast(action_size_bt)) - 12 * scale, .h = item_h,
                        .action = .{ .select_bluetooth = actual_idx },
                    });

                    list_y += @as(i32, @intCast(item_h + item_gap));
                }
            },
            .audio_menu => {
                // Segmented tab switch
                const tab_h: u32 = 32 * scale;
                const tab_w = content_w;
                const tab_labels = [_][]const u8{ "󰕾 Output Devices", "󰍬 Input Devices (Mics)" };
                const sel_tab_idx: usize = if (self.audio_tab == .output) 0 else 1;
                const seg_w = tab_w / 2;

                var hov_tab_idx: ?usize = null;
                if (self.isAreaHovered(pad_i, list_y, seg_w, tab_h)) hov_tab_idx = 0;
                if (self.isAreaHovered(pad_i + @as(i32, @intCast(seg_w)), list_y, seg_w, tab_h)) hov_tab_idx = 1;

                target.drawSegmentedControl(
                    &self.font,
                    pad_i,
                    list_y,
                    tab_w,
                    tab_h,
                    &tab_labels,
                    sel_tab_idx,
                    hov_tab_idx,
                    sub_sz,
                    self.cfg.theme.slider_track,
                    self.cfg.theme.glass_border,
                    self.cfg.theme.btn_raised_bg,
                    self.cfg.theme.text_main,
                    self.cfg.theme.text_muted,
                );

                try self.hit_areas.append(self.allocator, .{
                    .x = pad_i, .y = list_y, .w = seg_w, .h = tab_h,
                    .action = .set_audio_tab_output,
                });
                try self.hit_areas.append(self.allocator, .{
                    .x = pad_i + @as(i32, @intCast(seg_w)), .y = list_y, .w = seg_w, .h = tab_h,
                    .action = .set_audio_tab_input,
                });

                list_y += @as(i32, @intCast(tab_h + row_gap_u));

                const items = if (self.audio_tab == .output) self.sink_items.items else self.source_items.items;
                const is_output = self.audio_tab == .output;

                if (items.len == 0) {
                    self.drawEmptySubMenu(target, if (is_output) "volume-muted" else "microphone",
                        if (is_output) "No audio outputs found" else "No audio input devices found",
                        if (is_output) "Click refresh to refresh" else "Connect a mic and click refresh", scale);
                    return;
                }

                const start_idx = self.scroll_offset;
                const end_idx = @min(items.len, start_idx + max_visible);

                for (items[start_idx..end_idx], start_idx..) |item, actual_idx| {
                    const is_hovered = self.isAreaHovered(pad_i, list_y, content_w, item_h);

                    var bg = if (item.is_default)
                        self.cfg.theme.elevated
                    else
                        self.cfg.theme.surface;
                    if (is_hovered) {
                        bg = self.cfg.theme.btn_raised_hover;
                    }

                    target.fillRoundedRect(pad_i, list_y, content_w, item_h, self.cfg.theme.radius_button, bg);
                    target.drawRoundedBorder(pad_i, list_y, content_w, item_h, self.cfg.theme.radius_button, 1 * scale,
                        if (item.is_default) self.cfg.theme.accent else self.cfg.theme.border);

                    // Device icon
                    const icon_size: u32 = 24 * scale;
                    const icon_x = pad_i + 10 * @as(i32, @intCast(scale));
                    const icon_y = list_y + @as(i32, @intCast((item_h - icon_size) / 2));
                    const icon_cx = @as(f64, @floatFromInt(icon_x)) + @as(f64, @floatFromInt(icon_size)) / 2.0;
                    const icon_cy = @as(f64, @floatFromInt(icon_y)) + @as(f64, @floatFromInt(icon_size)) / 2.0;

                    const icon_bg = if (item.is_default) self.cfg.theme.toggle_on else self.cfg.theme.btn_raised_bg;
                    target.drawNeumorphicCircleButton(icon_cx, icon_cy, @as(f64, @floatFromInt(icon_size)) / 2.0,
                        icon_bg, self.cfg.theme.glass_border, is_hovered, item.is_default);

                    const icon_name = if (is_output) "volume" else "microphone";
                    const icon_color = if (item.is_default) self.cfg.theme.accent_fg else self.cfg.theme.text_bright;
                    icons.drawSvgIcon(target, self.allocator, icon_name, icon_sz, scale,
                        @as(i32, @intFromFloat(icon_cx)), @as(i32, @intFromFloat(icon_cy)), icon_color);

                    // Device name
                    const dev_name = item.name[0..item.name_len];
                    var name_buf: [96]u8 = undefined;
                    const trunc_name = truncateText(target, &self.font, dev_name, content_w - 90, sub_sz, &name_buf);
                    const text_x = icon_x + @as(i32, @intCast(icon_size + 12 * scale));
                    target.drawTextWithSize(&self.font, trunc_name, text_x, list_y + @as(i32, @intCast(14 * scale)), sub_sz, self.cfg.theme.text_bright);

                    // Subtitle
                    var sub_buf: [64]u8 = undefined;
                    const sub_str = if (item.is_default)
                        std.fmt.bufPrint(&sub_buf, "Default • {d}%", .{item.volume_pct}) catch "Default"
                    else
                        std.fmt.bufPrint(&sub_buf, "Volume: {d}%", .{item.volume_pct}) catch "Audio";

                    const sub_color = if (item.is_default) self.cfg.theme.accent else self.cfg.theme.text_muted;
                    target.drawTextWithSize(&self.font, sub_str, text_x, list_y + @as(i32, @intCast(28 * scale)), sec_sz, sub_color);

                    // Checkmark if default
                    if (item.is_default) {
                        icons.drawSvgIcon(target, self.allocator, "check", icon_sz, scale,
                            pad_i + @as(i32, @intCast(content_w)) - @as(i32, @intCast(24 * scale)) + @as(i32, @intCast(icon_sz / 2)),
                            list_y + @as(i32, @intCast(20 * scale)), self.cfg.theme.accent);
                    }

                    try self.hit_areas.append(self.allocator, .{
                        .x = pad_i, .y = list_y, .w = content_w, .h = item_h,
                        .action = if (is_output) .{ .select_audio_sink = actual_idx } else .{ .select_audio_source = actual_idx },
                    });

                    list_y += @as(i32, @intCast(item_h + item_gap));
                }
            },
            .recording_menu => {
                const opt_h: u32 = 48 * scale;
                const opt_gap: u32 = 8 * scale;
                var cur_opt_y = list_y;

                const active_rec = recorder.isRecordingActive();

                const options = [_]struct {
                    mode: recorder.RecordAudioMode,
                    icon_name: []const u8,
                    title: []const u8,
                    desc: []const u8,
                    act: Action,
                }{
                    .{
                        .mode = .system,
                        .icon_name = "volume",
                        .title = "System sounds (default)",
                        .desc = "Record internal desktop and application sounds",
                        .act = .set_recording_mode_system,
                    },
                    .{
                        .mode = .mic,
                        .icon_name = "microphone",
                        .title = "Microphone",
                        .desc = "Record voice from configured default microphone",
                        .act = .set_recording_mode_mic,
                    },
                    .{
                        .mode = .none,
                        .icon_name = "volume-muted",
                        .title = "No audio",
                        .desc = "Record video only without any audio",
                        .act = .set_recording_mode_none,
                    },
                };

                for (options) |opt| {
                    const is_selected = (self.record_audio_mode == opt.mode);
                    const is_hov = self.isAreaHovered(pad_i, cur_opt_y, content_w, opt_h);
                    var bg = if (is_selected) self.cfg.theme.elevated else self.cfg.theme.surface;
                    if (is_hov) bg = self.cfg.theme.btn_raised_hover;

                    target.fillRoundedRect(pad_i, cur_opt_y, content_w, opt_h, self.cfg.theme.radius_button, bg);
                    target.drawRoundedBorder(pad_i, cur_opt_y, content_w, opt_h, self.cfg.theme.radius_button, 1 * scale,
                        if (is_selected) self.cfg.theme.accent else self.cfg.theme.border);

                    const icon_size: u32 = 24 * scale;
                    const icon_x = pad_i + 12 * @as(i32, @intCast(scale));
                    const icon_y = cur_opt_y + @as(i32, @intCast((opt_h - icon_size) / 2));
                    const icon_cx = @as(f64, @floatFromInt(icon_x)) + @as(f64, @floatFromInt(icon_size)) / 2.0;
                    const icon_cy = @as(f64, @floatFromInt(icon_y)) + @as(f64, @floatFromInt(icon_size)) / 2.0;

                    const icon_bg = if (is_selected) self.cfg.theme.toggle_on else self.cfg.theme.btn_raised_bg;
                    target.drawNeumorphicCircleButton(icon_cx, icon_cy, @as(f64, @floatFromInt(icon_size)) / 2.0,
                        icon_bg, self.cfg.theme.glass_border, is_hov, is_selected);

                    const icon_color = if (is_selected) self.cfg.theme.accent_fg else self.cfg.theme.text_bright;
                    icons.drawSvgIcon(target, self.allocator, opt.icon_name, icon_sz, scale,
                        @as(i32, @intFromFloat(icon_cx)), @as(i32, @intFromFloat(icon_cy)), icon_color);

                    const text_x = icon_x + @as(i32, @intCast(icon_size + 14 * scale));
                    target.drawTextWithSize(&self.font, opt.title, text_x, cur_opt_y + @as(i32, @intCast(16 * scale)), sub_sz, self.cfg.theme.text_bright);
                    target.drawTextWithSize(&self.font, opt.desc, text_x, cur_opt_y + @as(i32, @intCast(32 * scale)), sec_sz, self.cfg.theme.text_muted);

                    if (is_selected) {
                        icons.drawSvgIcon(target, self.allocator, "check", icon_sz, scale,
                            pad_i + @as(i32, @intCast(content_w)) - @as(i32, @intCast(28 * scale)) + @as(i32, @intCast(icon_sz / 2)),
                            cur_opt_y + @as(i32, @intCast(24 * scale)), self.cfg.theme.accent);
                    }

                    try self.hit_areas.append(self.allocator, .{
                        .x = pad_i, .y = cur_opt_y, .w = content_w, .h = opt_h,
                        .action = opt.act,
                    });

                    cur_opt_y += @as(i32, @intCast(opt_h + opt_gap));
                }

                cur_opt_y += @as(i32, @intCast(10 * scale));
                const btn_w = if (content_w > 12) (content_w - 12) / 2 else content_w;
                const btn_h: u32 = 40 * scale;

                if (active_rec) {
                    const is_stop_hov = self.isAreaHovered(pad_i, cur_opt_y, content_w, btn_h);
                    target.fillSquircle(pad_i, cur_opt_y, content_w, btn_h, 10 * scale,
                        if (is_stop_hov) self.cfg.theme.error_color else self.cfg.theme.btn_raised_bg);
                    target.drawSquircleBorder(pad_i, cur_opt_y, content_w, btn_h, 10 * scale, 1 * scale, self.cfg.theme.error_color);
                    const stop_str = "  Stop Recording";
                    const stop_w = target.measureTextWithSize(&self.font, stop_str, btn_sz);
                    const stop_x = pad_i + @divTrunc(@as(i32, @intCast(content_w)) - @as(i32, @intCast(stop_w)), 2);
                    target.drawTextWithSize(&self.font, stop_str, stop_x, cur_opt_y + @as(i32, @intCast(26 * scale)), btn_sz,
                        if (is_stop_hov) theme.Color.rgb(255, 255, 255) else self.cfg.theme.error_color);

                    try self.hit_areas.append(self.allocator, .{
                        .x = pad_i, .y = cur_opt_y, .w = content_w, .h = btn_h,
                        .action = .toggle_recording,
                    });
                } else {
                    const is_reg_hov = self.isAreaHovered(pad_i, cur_opt_y, btn_w, btn_h);
                    target.fillSquircle(pad_i, cur_opt_y, btn_w, btn_h, 10 * scale,
                        if (is_reg_hov) self.cfg.theme.btn_raised_hover else self.cfg.theme.surface);
                    target.drawSquircleBorder(pad_i, cur_opt_y, btn_w, btn_h, 10 * scale, 1 * scale, self.cfg.theme.glass_border);
                    const reg_str = "Record Region";
                    icons.drawSvgIcon(target, self.allocator, "screen-recording", icon_sz, scale,
                        pad_i + @as(i32, @intCast(icon_sz / 2)) + 10, cur_opt_y + @as(i32, @intCast(btn_h / 2)), self.cfg.theme.text_main);
                    const reg_tx = pad_i + @as(i32, @intCast(icon_sz + 14 * scale));
                    target.drawTextWithSize(&self.font, reg_str, reg_tx, cur_opt_y + @as(i32, @intCast(26 * scale)), btn_sz, self.cfg.theme.text_main);

                    try self.hit_areas.append(self.allocator, .{
                        .x = pad_i, .y = cur_opt_y, .w = btn_w, .h = btn_h,
                        .action = .start_record_region,
                    });

                    const fs_x = pad_i + @as(i32, @intCast(btn_w + 12 * scale));
                    const is_fs_hov = self.isAreaHovered(fs_x, cur_opt_y, btn_w, btn_h);
                    target.fillSquircle(fs_x, cur_opt_y, btn_w, btn_h, 10 * scale,
                        if (is_fs_hov) self.cfg.theme.btn_raised_hover else self.cfg.theme.surface);
                    target.drawSquircleBorder(fs_x, cur_opt_y, btn_w, btn_h, 10 * scale, 1 * scale, self.cfg.theme.glass_border);
                    const fs_str = "Record Screen";
                    icons.drawSvgIcon(target, self.allocator, "screen-recording", icon_sz, scale,
                        fs_x + @as(i32, @intCast(icon_sz / 2)) - 2, cur_opt_y + @as(i32, @intCast(btn_h / 2)), self.cfg.theme.text_main);
                    const fs_tx = fs_x + @as(i32, @intCast(icon_sz + 14 * scale));
                    target.drawTextWithSize(&self.font, fs_str, fs_tx, cur_opt_y + @as(i32, @intCast(26 * scale)), btn_sz, self.cfg.theme.text_main);

                    try self.hit_areas.append(self.allocator, .{
                        .x = fs_x, .y = cur_opt_y, .w = btn_w, .h = btn_h,
                        .action = .start_record_fullscreen,
                    });
                }
            },
            .notifications_menu => {
                const store = &(self.notif_store orelse return);
                if (store.items.items.len == 0) {
                    self.drawEmptySubMenu(target, "bell-off", "No new notifications", "All caught up!", scale);
                    return;
                }
                const start_idx = self.scroll_offset;
                const end_idx = @min(store.items.items.len, start_idx + max_visible);

                for (store.items.items[start_idx..end_idx], start_idx..) |item, actual_idx| {
                    const is_hovered = self.isAreaHovered(pad_i, list_y, content_w, item_h);
                    const bg = if (is_hovered) self.cfg.theme.btn_raised_hover else self.cfg.theme.surface;

                    target.fillRoundedRect(pad_i, list_y, content_w, item_h, self.cfg.theme.radius_button, bg);
                    target.drawRoundedBorder(pad_i, list_y, content_w, item_h, self.cfg.theme.radius_button, 1 * scale, self.cfg.theme.border);

                    const icon_x = pad_i + 14 * @as(i32, @intCast(scale));
                    icons.drawSvgIcon(target, self.allocator, "bell", icon_sz, scale,
                        icon_x + @as(i32, @intCast(icon_sz / 2)), list_y + @as(i32, @intCast(22 * scale)), self.cfg.theme.accent);

                    const text_x = icon_x + 28 * @as(i32, @intCast(scale));
                    var time_buf: [16]u8 = undefined;
                    const time_str = item.formatRelativeTime(&time_buf);

                    var head_buf: [128]u8 = undefined;
                    const head_str = std.fmt.bufPrint(&head_buf, "{s} • {s}", .{ item.getAppName(), time_str }) catch item.getAppName();
                    target.drawTextWithSize(&self.font, head_str, text_x, list_y + @as(i32, @intCast(14 * scale)), sec_sz, self.cfg.theme.text_muted);

                    var trunc_sum: [128]u8 = undefined;
                    const sum = truncateText(target, &self.font, item.getSummary(), content_w - 90, sub_sz, &trunc_sum);
                    target.drawTextWithSize(&self.font, sum, text_x, list_y + @as(i32, @intCast(28 * scale)), sub_sz, self.cfg.theme.text_bright);

                    const body = item.getBody();
                    if (body.len > 0) {
                        var trunc_bod: [128]u8 = undefined;
                        const bod = truncateText(target, &self.font, body, content_w - 90, sec_sz, &trunc_bod);
                        target.drawTextWithSize(&self.font, bod, text_x, list_y + @as(i32, @intCast(44 * scale)), sec_sz, self.cfg.theme.text_muted);
                    }

                    const btn_w: u32 = 24 * scale;
                    const btn_h: u32 = 24 * scale;
                    const dismiss_x = pad_i + @as(i32, @intCast(content_w)) - @as(i32, @intCast(btn_w)) - pad_i;
                    const dismiss_y = list_y + @as(i32, @intCast(@divTrunc(item_h - btn_h, 2)));

                    try self.hit_areas.append(self.allocator, .{
                        .x = dismiss_x, .y = dismiss_y, .w = btn_w, .h = btn_h,
                        .action = .{ .dismiss_notification = actual_idx },
                    });

                    const is_btn_hover = self.isAreaHovered(dismiss_x, dismiss_y, btn_w, btn_h);
                    const dismiss_r: f64 = @as(f64, @floatFromInt(btn_w)) / 2.0;
                    target.drawNeumorphicCircleButton(
                        @as(f64, @floatFromInt(dismiss_x)) + dismiss_r,
                        @as(f64, @floatFromInt(dismiss_y)) + dismiss_r,
                        dismiss_r,
                        if (is_btn_hover) self.cfg.theme.btn_raised_hover else self.cfg.theme.btn_raised_bg,
                        self.cfg.theme.glass_border,
                        is_btn_hover,
                        false,
                    );
                    target.drawTextWithSize(&self.font, "✕", dismiss_x + 7, dismiss_y + 16, sec_sz,
                        if (is_btn_hover) self.cfg.theme.error_color else self.cfg.theme.text_muted);

                    list_y += @as(i32, @intCast(item_h + item_gap));
                }
            },
            .main => {},
        }
    }
    fn drawEmptySubMenu(self: *QuickSettings, target: anytype, icon_name: []const u8, message: []const u8, hint: []const u8, scale: u32) void {
        const w = target.width;
        const pad_u = QsLayout.pad * scale;
        const icon_size = self.cfg.typography.title * scale;
        const center_x = @divTrunc(@as(i32, @intCast(w)), 2);
        const icon_y = @as(i32, @intCast(pad_u * 4));

        icons.drawSvgIcon(target, self.allocator, icon_name, icon_size, scale, center_x, icon_y, self.cfg.theme.text_muted);

        const ui_sz = self.cfg.typography.ui * scale;
        const sec_sz = self.cfg.typography.secondary * scale;
        const msg_w = target.measureTextWithSize(&self.font, message, ui_sz);
        const msg_x = @divTrunc(@as(i32, @intCast(w)) - @as(i32, @intCast(msg_w)), 2);
        const msg_y = icon_y + @as(i32, @intCast(icon_size + 20 * scale));
        target.drawTextWithSize(&self.font, message, msg_x, msg_y, ui_sz, self.cfg.theme.text_bright);

        const hint_w = target.measureTextWithSize(&self.font, hint, sec_sz);
        const hint_x = @divTrunc(@as(i32, @intCast(w)) - @as(i32, @intCast(hint_w)), 2);
        const hint_y = msg_y + @as(i32, @intCast(ui_sz + 8 * scale));
        target.drawTextWithSize(&self.font, hint, hint_x, hint_y, sec_sz, self.cfg.theme.text_muted);
    }

    fn drawSlider(
        self: *QuickSettings,
        target: anytype,
        x: i32,
        y: i32,
        w: u32,
        h: u32,
        percent: u32,
        filled_color: theme.Color,
        action: Action,
    ) !void {
        const is_hovered = self.isAreaHovered(x, y, w, h);
        target.drawPillSlider(
            x,
            y,
            w,
            h,
            percent,
            self.cfg.theme.slider_track,
            filled_color,
            self.cfg.theme.slider_thumb,
            self.cfg.theme.slider_thumb_shadow,
            is_hovered,
        );

        try self.hit_areas.append(self.allocator, .{
            .x = x,
            .y = y,
            .w = w,
            .h = h,
            .action = action,
        });
    }

    fn drawControlBtn(
        self: *QuickSettings,
        target: anytype,
        x: i32,
        y: i32,
        size: u32,
        icon_name: []const u8,
        action: Action,
    ) !void {
        const is_hovered = self.isAreaHovered(x, y, size, size);
        const bg = if (is_hovered)
            self.cfg.theme.card_hover_bg
        else
            self.cfg.theme.card_bg;

        target.fillGlassSquircle(x, y, size, size, size / 2, bg);
        target.drawSquircleBorder(x, y, size, size, size / 2, 1 * 1, if (is_hovered) self.cfg.theme.accent else self.cfg.theme.border);
        const icon_size = self.cfg.typography.quicksettings_icon * 1;
        icons.drawSvgIcon(
            target,
            self.allocator,
            icon_name,
            icon_size,
            1,
            x + @divTrunc(@as(i32, @intCast(size)), 2),
            y + @divTrunc(@as(i32, @intCast(size)), 2),
            self.cfg.theme.text_bright,
        );

        try self.hit_areas.append(self.allocator, .{
            .x = x,
            .y = y,
            .w = size,
            .h = size,
            .action = action,
        });
    }

    fn isAreaHovered(self: *const QuickSettings, x: i32, y: i32, w: u32, h: u32) bool {
        if (self.pointer_x < 0 or self.pointer_y < 0) return false;
        return (self.pointer_x >= x and self.pointer_x < x + @as(i32, @intCast(w)) and
            self.pointer_y >= y and self.pointer_y < y + @as(i32, @intCast(h)));
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
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try qs.wifi_items.append(allocator, .{
            .ssid_len = 4,
            .signal = 80,
            .is_active = (i == 0),
        });
    }

    // Scrolling down increases offset up to max_scroll (10 - 8 = 2)
    try std.testing.expect(qs.handlePointerAxis(0, 0, 1));
    try std.testing.expectEqual(@as(usize, 1), qs.scroll_offset);
    try std.testing.expect(qs.handlePointerAxis(0, 0, 1));
    try std.testing.expectEqual(@as(usize, 2), qs.scroll_offset);
    // Beyond max_scroll should return false
    try std.testing.expect(!qs.handlePointerAxis(0, 0, 1));

    // Scrolling up decreases offset back to 0
    try std.testing.expect(qs.handlePointerAxis(0, 0, -1));
    try std.testing.expectEqual(@as(usize, 1), qs.scroll_offset);
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
