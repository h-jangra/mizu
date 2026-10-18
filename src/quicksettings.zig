const std = @import("std");
const c = @import("c.zig").c;
const theme = @import("theme.zig");
const config = @import("config.zig");
const renderer = @import("renderer.zig");
const sys_status = @import("sys_status.zig");
const text_input = @import("text_input.zig");

pub const Action = union(enum) {
    toggle_wifi,
    toggle_bluetooth,
    toggle_audio_mute,
    toggle_dnd,
    open_wifi_menu,
    open_bluetooth_menu,
    open_audio_menu,
    back_to_main,
    refresh_sub_menu,
    select_wifi: usize,
    select_bluetooth: usize,
    select_audio_sink: usize,
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
    wifi_input_click,
    wifi_connect_submit,
    wifi_cancel,
    set_power_profile_saver,
    set_power_profile_balanced,
    set_power_profile_performance,
    forget_wifi: usize,
    remove_bluetooth: usize,
};

pub const ViewMode = enum {
    main,
    wifi_menu,
    bluetooth_menu,
    audio_menu,
};

pub const WifiItem = struct {
    ssid: [64]u8 = [_]u8{0} ** 64,
    ssid_len: usize = 0,
    signal: u8 = 0,
    security: [32]u8 = [_]u8{0} ** 32,
    security_len: usize = 0,
    is_active: bool = false,
};

pub const BluetoothItem = struct {
    mac: [32]u8 = [_]u8{0} ** 32,
    mac_len: usize = 0,
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    connected: bool = false,
    icon: []const u8 = "󰂯",
};

pub const AudioSinkItem = struct {
    id: u32 = 0,
    name: [96]u8 = [_]u8{0} ** 96,
    name_len: usize = 0,
    volume_pct: u32 = 100,
    is_default: bool = false,
};

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

    width: u32 = 380,
    height: u32 = 390,
    running: bool = true,

    view_mode: ViewMode = .main,
    scroll_offset: usize = 0,
    hover_idx: ?usize = null,
    active_slider: ?SliderType = null,
    dnd_enabled: bool = false,

    hit_areas: std.ArrayList(HitArea),
    wifi_items: std.ArrayList(WifiItem),
    bt_items: std.ArrayList(BluetoothItem),
    sink_items: std.ArrayList(AudioSinkItem),

    wifi_input_idx: ?usize = null,
    wifi_input: ?text_input.TextInput = null,
    wifi_password: [128]u8 = [_]u8{0} ** 128,
    wifi_password_len: usize = 0,
    wifi_connect_state: WifiConnectState = .idle,
    wifi_error_msg: [128]u8 = [_]u8{0} ** 128,
    wifi_error_len: usize = 0,
    wifi_worker: WifiWorker = .{},
    wifi_worker_running: bool = false,
    pointer_x: i32 = -1,
    pointer_y: i32 = -1,

    pub fn getDesiredHeight(self: *const QuickSettings) u32 {
        if (self.view_mode != .main) {
            return 410;
        }
        var h: u32 = 16 + 44 + 11; // pad_top + header + separator = 71
        h += 46 + 8 + 46 + 12; // 2 rows of quick toggles = 112
        h += 26 + 8; // volume slider = 34
        if (self.sys.has_backlight) {
            h += 26 + 10; // backlight slider = 36
        }
        if (self.sys.mpris_state != .stopped and self.sys.mpris_track_len > 0) {
            h += 56 + 10; // media card = 66
        }
        h += if (self.sys.has_battery) 94 + 10 else 72 + 10; // status card
        h += 24 + 14; // footer date strip = 38
        return h;
    }

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !QuickSettings {
        const font = try renderer.Font.init(allocator, cfg.theme.font_family, cfg.theme.font_size);
        const sys = sys_status.SysStatus.init(allocator);

        var self_val = QuickSettings{
            .allocator = allocator,
            .cfg = cfg,
            .font = font,
            .sys = sys,
            .hit_areas = std.ArrayList(HitArea).empty,
            .wifi_items = std.ArrayList(WifiItem).empty,
            .bt_items = std.ArrayList(BluetoothItem).empty,
            .sink_items = std.ArrayList(AudioSinkItem).empty,
            .wifi_input = text_input.TextInput.init(allocator, "Enter Wi-Fi password...", true),
        };
        self_val.height = self_val.getDesiredHeight();
        return self_val;
    }

    pub fn deinit(self: *QuickSettings) void {
        if (self.wifi_input) |*inp| inp.deinit();
        self.wifi_items.deinit(self.allocator);
        self.bt_items.deinit(self.allocator);
        self.sink_items.deinit(self.allocator);
        self.hit_areas.deinit(self.allocator);
        self.font.deinit();
    }

    pub fn tick(self: *QuickSettings) void {
        self.height = self.getDesiredHeight();
        if (self.wifi_input) |*inp| inp.toggleCaret();
        self.checkWifiStatus();
        self.sys.tick();
        if (theme.loadSavedTheme()) |saved| {
            if (saved != self.cfg.theme.kind) {
                self.cfg.theme = saved.toTheme();
            }
        }
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
            .audio_menu => self.sink_items.items.len,
            .main => 0,
        };
        const max_scroll = if (total > 7) total - 7 else 0;
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
                        return true;
                    },
                    .toggle_bluetooth => {
                        self.sys.toggleBluetooth();
                        return true;
                    },
                    .toggle_audio_mute => {
                        self.sys.toggleVolumeMute();
                        return true;
                    },
                    .toggle_dnd => {
                        self.dnd_enabled = !self.dnd_enabled;
                        sys_status.spawnCmd("dunstctl set-paused toggle 2>/dev/null || makoctl mode -t dnd 2>/dev/null || true");
                        return true;
                    },
                    .open_wifi_menu => {
                        self.view_mode = .wifi_menu;
                        self.scroll_offset = 0;
                        self.scanWifi();
                        return true;
                    },
                    .open_bluetooth_menu => {
                        self.view_mode = .bluetooth_menu;
                        self.scroll_offset = 0;
                        self.scanBluetooth();
                        return true;
                    },
                    .open_audio_menu => {
                        self.view_mode = .audio_menu;
                        self.scroll_offset = 0;
                        self.scanAudioSinks();
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
                            self.scanWifi();
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
                            self.scanBluetooth();
                            return true;
                        }
                    },
                    .refresh_sub_menu => {
                        switch (self.view_mode) {
                            .wifi_menu => {
                                sys_status.spawnCmd("nmcli dev wifi rescan 2>/dev/null || true");
                                self.scanWifi();
                            },
                            .bluetooth_menu => {
                                self.scanBluetooth();
                            },
                            .audio_menu => {
                                self.scanAudioSinks();
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
                            if (is_open) {
                                const ssid = item.ssid[0..item.ssid_len];
                                var cmd_list = std.ArrayList(u8).empty;
                                defer cmd_list.deinit(self.allocator);
                                cmd_list.appendSlice(self.allocator, "nmcli dev wifi connect ") catch return true;
                                appendShellArg(self.allocator, &cmd_list, ssid) catch return true;
                                cmd_list.appendSlice(self.allocator, " 2>/dev/null || nmcli connection up ") catch return true;
                                appendShellArg(self.allocator, &cmd_list, ssid) catch return true;
                                cmd_list.appendSlice(self.allocator, " 2>/dev/null || true") catch return true;
                                sys_status.spawnCmd(cmd_list.items);
                                self.sys.updateAll();
                            } else {
                                if (self.wifi_input_idx == idx) {
                                    self.wifi_input_idx = null;
                                    if (self.wifi_input) |*inp| inp.clear();
                                    self.wifi_password_len = 0;
                                } else {
                                    self.wifi_input_idx = idx;
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
                            var cmd_buf: [128]u8 = undefined;
                            if (item.connected) {
                                const cmd = std.fmt.bufPrint(&cmd_buf, "bluetoothctl disconnect {s} 2>/dev/null || true", .{mac}) catch return true;
                                sys_status.spawnCmd(cmd);
                            } else {
                                const cmd = std.fmt.bufPrint(&cmd_buf, "bluetoothctl connect {s} 2>/dev/null || true", .{mac}) catch return true;
                                sys_status.spawnCmd(cmd);
                            }
                            self.scanBluetooth();
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
                            self.scanAudioSinks();
                        }
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
                    .lock => {
                        sys_status.spawnCmd("swaylock -c 000000 2>/dev/null || loginctl lock-session 2>/dev/null || true");
                        self.running = false;
                        return true;
                    },
                    .sleep_mode => {
                        sys_status.spawnCmd("loginctl lock-session 2>/dev/null || true; loginctl suspend 2>/dev/null || sudo zzz 2>/dev/null || zzz 2>/dev/null || true");
                        self.running = false;
                        return true;
                    },
                    .reboot => {
                        sys_status.spawnCmd("sudo reboot 2>/dev/null || loginctl reboot 2>/dev/null || reboot 2>/dev/null || true");
                        self.running = false;
                        return true;
                    },
                    .shutdown => {
                        sys_status.spawnCmd("sudo poweroff 2>/dev/null || loginctl poweroff 2>/dev/null || poweroff 2>/dev/null || true");
                        self.running = false;
                        return true;
                    },
                    .close => {
                        self.running = false;
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
        error_msg: [128]u8 = [_]u8{0} ** 128,
        error_len: usize = 0,
        ssid: [64]u8 = [_]u8{0} ** 64,
        ssid_len: usize = 0,
        pwd: [128]u8 = [_]u8{0} ** 128,
        pwd_len: usize = 0,

        pub fn run(self: *WifiWorker) void {
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

            self.done.store(true, .release);
        }
    };

    pub fn checkWifiStatus(self: *QuickSettings) void {
        if (!self.wifi_worker_running) return;
        if (!self.wifi_worker.done.load(.acquire)) return;

        if (self.wifi_worker.success.load(.acquire)) {
            self.wifi_connect_state = .success;
            self.wifi_input_idx = null;
            self.wifi_password_len = 0;
            self.wifi_error_len = 0;
            self.sys.updateAll();
            self.scanWifi();
        } else {
            self.wifi_connect_state = .failed;
            const elen = self.wifi_worker.error_len;
            @memcpy(self.wifi_error_msg[0..elen], self.wifi_worker.error_msg[0..elen]);
            self.wifi_error_len = elen;
        }

        self.wifi_worker_running = false;
    }

    pub fn submitWifiPassword(self: *QuickSettings) void {
        const idx = self.wifi_input_idx orelse return;
        if (idx >= self.wifi_items.items.len) {
            self.wifi_input_idx = null;
            return;
        }
        if (self.wifi_connect_state == .connecting) return;

        const item = self.wifi_items.items[idx];
        const ssid = item.ssid[0..item.ssid_len];
        const pwd = self.wifi_password[0..self.wifi_password_len];

        self.wifi_connect_state = .connecting;
        self.wifi_error_len = 0;

        self.wifi_worker = WifiWorker{};
        const slen = @min(ssid.len, self.wifi_worker.ssid.len);
        @memcpy(self.wifi_worker.ssid[0..slen], ssid[0..slen]);
        self.wifi_worker.ssid_len = slen;

        const plen = @min(pwd.len, self.wifi_worker.pwd.len);
        @memcpy(self.wifi_worker.pwd[0..plen], pwd[0..plen]);
        self.wifi_worker.pwd_len = plen;

        self.wifi_worker_running = true;

        const thread = std.Thread.spawn(.{}, WifiWorker.run, .{&self.wifi_worker}) catch {
            self.wifi_connect_state = .failed;
            const fb = "Failed to spawn connect worker.";
            @memcpy(self.wifi_error_msg[0..fb.len], fb);
            self.wifi_error_len = fb.len;
            self.wifi_worker_running = false;
            return;
        };
        thread.detach();
    }

    pub fn handleKey(self: *QuickSettings, sym: u32, utf8_bytes: []const u8) bool {
        return self.handleKeyFull(sym, utf8_bytes, false, false);
    }

    pub fn handleKeyFull(self: *QuickSettings, sym: u32, utf8_bytes: []const u8, ctrl: bool, shift: bool) bool {
        if (self.wifi_input_idx == null) return false;

        if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_KP_Enter) {
            self.submitWifiPassword();
            return true;
        } else if (sym == c.XKB_KEY_Escape) {
            self.wifi_input_idx = null;
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

            // Deduplicate: if already seen this SSID, keep active or higher signal
            var found = false;
            for (self.wifi_items.items) |*existing| {
                if (std.mem.eql(u8, existing.ssid[0..existing.ssid_len], ssid)) {
                    found = true;
                    if (is_active) {
                        existing.is_active = true;
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
                };
                @memcpy(item.ssid[0..item.ssid_len], ssid[0..item.ssid_len]);
                @memcpy(item.security[0..item.security_len], security_str[0..item.security_len]);
                self.wifi_items.append(self.allocator, item) catch break;
            }
        }

        // Sort: active first, then highest signal descending
        std.mem.sort(WifiItem, self.wifi_items.items, {}, struct {
            fn lessThan(_: void, a: WifiItem, b: WifiItem) bool {
                if (a.is_active != b.is_active) return a.is_active;
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
        self.sink_items.clearRetainingCapacity();

        const pipe = c.popen("wpctl status 2>/dev/null", "r") orelse return;
        defer _ = c.pclose(pipe);

        var buf: [8192]u8 = undefined;
        var total_read: usize = 0;
        while (total_read < buf.len - 1) {
            const n = c.fread(buf[total_read..].ptr, 1, buf.len - 1 - total_read, pipe);
            if (n == 0) break;
            total_read += n;
        }
        buf[total_read] = 0;

        var in_audio = false;
        var in_sinks = false;
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
                    continue;
                }
                if (in_sinks) {
                    if (std.mem.indexOf(u8, line, "Sources:") != null or
                        std.mem.indexOf(u8, line, "Filters:") != null or
                        std.mem.indexOf(u8, line, "Streams:") != null)
                    {
                        in_sinks = false;
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

                    var item = AudioSinkItem{
                        .id = id,
                        .name = [_]u8{0} ** 96,
                        .name_len = @min(name.len, 96),
                        .volume_pct = vol_pct,
                        .is_default = is_default,
                    };
                    @memcpy(item.name[0..item.name_len], name[0..item.name_len]);
                    self.sink_items.append(self.allocator, item) catch break;
                }
            }
        }

        // Sort: default sink first, then by name
        std.mem.sort(AudioSinkItem, self.sink_items.items, {}, struct {
            fn lessThan(_: void, a: AudioSinkItem, b: AudioSinkItem) bool {
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
                    .volume => self.sys.setVolume(pct),
                    .brightness => self.sys.setBrightness(pct),
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

    pub fn render(self: *QuickSettings, target: renderer.Renderer) !void {
        self.checkWifiStatus();
        self.hit_areas.clearRetainingCapacity();

        // Transparent background outside rounded card
        target.clear(theme.Color.transparent);

        const w = target.width;
        const h = target.height;

        // Container card: Glass container with 16px squircle radius
        target.fillGlassSquircle(0, 0, w, h, 16, self.cfg.theme.panel_bg);
        target.drawSquircleBorder(0, 0, w, h, 16, 1, self.cfg.theme.panel_border);

        if (self.view_mode != .main) {
            try self.renderSubMenu(target);
            return;
        }

        const pad_x: i32 = 16;
        var cur_y: i32 = 16;
        const content_w = w - 32;

        // ======================== 1. Header ========================
        // Left: User avatar & hostname + uptime
        const avatar_size: u32 = 34;
        target.fillRoundedRect(pad_x, cur_y, avatar_size, avatar_size, 17, self.cfg.theme.pill_bg);
        const avatar_icon = "";
        const icon_w = target.measureTextWithSize(&self.font, avatar_icon, 16);
        const icon_x = pad_x + @divTrunc(@as(i32, @intCast(avatar_size)) - @as(i32, @intCast(icon_w)), 2);
        target.drawTextWithSize(&self.font, avatar_icon, icon_x, cur_y + 24, 16, self.cfg.theme.text_bright);

        const user_host_str = if (self.sys.user_host_len > 0)
            self.sys.user_host[0..self.sys.user_host_len]
        else
            "user@mizu";
        target.drawTextWithSize(&self.font, user_host_str, pad_x + 42, cur_y + 16, 13, self.cfg.theme.text_bright);

        const uptime_str = if (self.sys.uptime_len > 0)
            self.sys.uptime_str[0..self.sys.uptime_len]
        else
            "up";
        var uptime_buf: [48]u8 = undefined;
        const full_uptime = std.fmt.bufPrint(&uptime_buf, "󱑂 {s}", .{uptime_str}) catch "󱑂";
        target.drawTextWithSize(&self.font, full_uptime, pad_x + 42, cur_y + 31, 11, self.cfg.theme.text_muted);

        // Right: Action buttons (Lock, Suspend, Power, Close)
        const btn_size: u32 = 30;
        var btn_x: i32 = @as(i32, @intCast(w)) - pad_x - @as(i32, @intCast(btn_size));

        // Close button
        try self.drawHeaderButton(target, btn_x, cur_y + 2, btn_size, "󰅖", .close, self.cfg.theme.error_color);
        btn_x -= @as(i32, @intCast(btn_size + 6));

        // Power button
        try self.drawHeaderButton(target, btn_x, cur_y + 2, btn_size, "󰐥", .shutdown, self.cfg.theme.error_color);
        btn_x -= @as(i32, @intCast(btn_size + 6));

        // Reboot button
        try self.drawHeaderButton(target, btn_x, cur_y + 2, btn_size, "󰜉", .reboot, self.cfg.theme.warning_color);
        btn_x -= @as(i32, @intCast(btn_size + 6));

        // Suspend button
        try self.drawHeaderButton(target, btn_x, cur_y + 2, btn_size, "󰒲", .sleep_mode, self.cfg.theme.secondary);
        btn_x -= @as(i32, @intCast(btn_size + 6));

        // Lock button
        try self.drawHeaderButton(target, btn_x, cur_y + 2, btn_size, "󰌾", .lock, self.cfg.theme.accent);

        cur_y += 44;

        // Separator
        target.fillRect(pad_x, cur_y, content_w, 1, self.cfg.theme.separator_fg);
        cur_y += 12;

        // ======================== 2. Quick Toggles Grid (2x2) ========================
        const col_gap: u32 = 10;
        const row_gap: u32 = 8;
        const toggle_w = (content_w - col_gap) / 2;
        const toggle_h: u32 = 46;

        const col0_x = pad_x;
        const col1_x = pad_x + @as(i32, @intCast(toggle_w + col_gap));

        // Row 1: Wi-Fi & Bluetooth
        // Wi-Fi Toggle
        const wifi_icon = if (self.sys.wifi_enabled) "󰤨" else "󰤭";
        const wifi_sub = if (self.sys.wifi_enabled)
            (if (self.sys.wifi_ssid_len > 0) self.sys.wifi_ssid[0..self.sys.wifi_ssid_len] else "Connected")
        else
            "Off";
        try self.drawToggleCard(
            target,
            col0_x,
            cur_y,
            toggle_w,
            toggle_h,
            wifi_icon,
            "Wi-Fi",
            wifi_sub,
            self.sys.wifi_enabled,
            .toggle_wifi,
            .open_wifi_menu,
        );

        // Bluetooth Toggle
        const bt_icon = if (self.sys.bluetooth_enabled) "󰂯" else "󰂲";
        const bt_sub = if (self.sys.bluetooth_enabled) "On" else "Off";
        try self.drawToggleCard(
            target,
            col1_x,
            cur_y,
            toggle_w,
            toggle_h,
            bt_icon,
            "Bluetooth",
            bt_sub,
            self.sys.bluetooth_enabled,
            .toggle_bluetooth,
            .open_bluetooth_menu,
        );

        cur_y += @as(i32, @intCast(toggle_h + row_gap));

        // Row 2: Audio & Do Not Disturb
        var vol_sub_buf: [32]u8 = undefined;
        const vol_sub = if (self.sys.volume_muted)
            "Muted"
        else
            std.fmt.bufPrint(&vol_sub_buf, "{d}%", .{self.sys.volume_percent}) catch "100%";
        const vol_icon = if (self.sys.volume_muted) "󰖁" else "󰕾";
        try self.drawToggleCard(
            target,
            col0_x,
            cur_y,
            toggle_w,
            toggle_h,
            vol_icon,
            "Audio",
            vol_sub,
            !self.sys.volume_muted,
            .open_audio_menu,
            .open_audio_menu,
        );

        // DND Toggle
        const dnd_icon = if (self.dnd_enabled) "󰂛" else "󰂚";
        const dnd_sub = if (self.dnd_enabled) "Silent" else "Off";
        try self.drawToggleCard(
            target,
            col1_x,
            cur_y,
            toggle_w,
            toggle_h,
            dnd_icon,
            "Do Not Disturb",
            dnd_sub,
            self.dnd_enabled,
            .toggle_dnd,
            null,
        );

        cur_y += @as(i32, @intCast(toggle_h + 12));

        // ======================== 3. Sliders Section ========================
        // Volume Slider
        const slider_h: u32 = 26;
        const icon_col_w: u32 = 28;
        const bar_w = content_w - icon_col_w - 6;

        // Volume Icon (clicking toggles mute)
        const is_vol_icon_hovered = self.isAreaHovered(pad_x, cur_y, icon_col_w, slider_h);
        const vol_icon_fg = if (self.sys.volume_muted)
            self.cfg.theme.error_color
        else if (is_vol_icon_hovered)
            self.cfg.theme.accent
        else
            self.cfg.theme.text_bright;
        target.drawTextWithSize(&self.font, vol_icon, pad_x + 2, cur_y + 19, 16, vol_icon_fg);
        try self.hit_areas.append(self.allocator, .{
            .x = pad_x,
            .y = cur_y,
            .w = icon_col_w,
            .h = slider_h,
            .action = .toggle_audio_mute,
        });

        // Volume Slider Bar
        try self.drawSlider(
            target,
            pad_x + @as(i32, @intCast(icon_col_w + 4)),
            cur_y,
            bar_w,
            slider_h,
            self.sys.volume_percent,
            self.cfg.theme.accent,
            .slider_volume,
        );

        cur_y += @as(i32, @intCast(slider_h + 8));

        // Brightness Slider (if hardware backlight is available)
        if (self.sys.has_backlight) {
            target.drawTextWithSize(&self.font, "󰃠", pad_x + 2, cur_y + 19, 16, self.cfg.theme.text_bright);

            try self.drawSlider(
                target,
                pad_x + @as(i32, @intCast(icon_col_w + 4)),
                cur_y,
                bar_w,
                slider_h,
                self.sys.backlight_percent,
                self.cfg.theme.battery_bg,
                .slider_brightness,
            );

            cur_y += @as(i32, @intCast(slider_h + 10));
        } else {
            cur_y += 4;
        }

        // ======================== 4. Media Player Card ========================
        if (self.sys.mpris_state != .stopped and self.sys.mpris_track_len > 0) {
            const media_h: u32 = 56;
            target.fillRoundedRect(pad_x, cur_y, content_w, media_h, 12, self.cfg.theme.surface);
            target.drawRoundedBorder(pad_x, cur_y, content_w, media_h, 12, 1, self.cfg.theme.border);

            // Music note
            target.drawTextWithSize(&self.font, "󰎆", pad_x + 12, cur_y + 34, 18, self.cfg.theme.accent);

            // Track info
            const track_str = self.sys.mpris_track[0..self.sys.mpris_track_len];
            var track_buf: [128]u8 = undefined;
            const trunc_track = truncateText(target, &self.font, track_str, content_w - 130, &track_buf);
            target.drawTextWithSize(&self.font, trunc_track, pad_x + 36, cur_y + 24, 12, self.cfg.theme.text_bright);

            const status_label = if (self.sys.mpris_state == .playing) "Playing" else "Paused";
            target.drawTextWithSize(&self.font, status_label, pad_x + 36, cur_y + 42, 11, self.cfg.theme.text_muted);

            // Controls on right: Prev, Play/Pause, Next
            const ctrl_size: u32 = 26;
            var ctrl_x: i32 = @as(i32, @intCast(w)) - pad_x - @as(i32, @intCast(ctrl_size)) - 6;

            // Next
            try self.drawControlBtn(target, ctrl_x, cur_y + 15, ctrl_size, "󰒭", .media_next);
            ctrl_x -= @as(i32, @intCast(ctrl_size + 4));

            // Play/Pause
            const pp_icon = if (self.sys.mpris_state == .playing) "󰏤" else "󰐊";
            try self.drawControlBtn(target, ctrl_x, cur_y + 15, ctrl_size, pp_icon, .media_play_pause);
            ctrl_x -= @as(i32, @intCast(ctrl_size + 4));

            // Prev
            try self.drawControlBtn(target, ctrl_x, cur_y + 15, ctrl_size, "󰒮", .media_prev);

            cur_y += @as(i32, @intCast(media_h + 10));
        }

        // ======================== 5. System Status & Power Profile Card ========================
        const status_card_h: u32 = if (self.sys.has_battery) 94 else 72;
        target.fillRoundedRect(pad_x, cur_y, content_w, status_card_h, 12, self.cfg.theme.surface);
        target.drawRoundedBorder(pad_x, cur_y, content_w, status_card_h, 12, 1, self.cfg.theme.border);

        // CPU & RAM on line 1
        var stat_line1_buf: [64]u8 = undefined;
        const stat_line1 = std.fmt.bufPrint(&stat_line1_buf, "󰻠 CPU: {d:0>2}%   󰍛 RAM: {d:.1}/{d:.1} GiB", .{
            self.sys.cpu_percent,
            self.sys.mem_used_gib,
            self.sys.mem_total_gib,
        }) catch "󰻠 CPU   󰍛 RAM";
        target.drawTextWithSize(&self.font, stat_line1, pad_x + 12, cur_y + 22, 12, self.cfg.theme.text_main);

        // Battery on line 2 (if present)
        var row3_y: i32 = cur_y + 36;
        if (self.sys.has_battery) {
            var bat_line_buf: [64]u8 = undefined;
            const bat_icon = if (self.sys.bat_status == .charging) "󰂄" else "󰂀";
            const bat_state_str = switch (self.sys.bat_status) {
                .charging => "Charging",
                .discharging => "Discharging",
                .full => "Full",
                .none => "Battery",
            };
            const bat_line = std.fmt.bufPrint(&bat_line_buf, "{s} Battery: {d}% ({s})", .{
                bat_icon,
                self.sys.bat_capacity,
                bat_state_str,
            }) catch "󰂀 Battery";
            target.drawTextWithSize(&self.font, bat_line, pad_x + 12, cur_y + 44, 12, self.cfg.theme.text_muted);
            row3_y = cur_y + 58;
        }

        // Power profile buttons (Power Saver, Balanced, Performance)
        const pill_gap: u32 = 6;
        const total_gaps: u32 = pill_gap * 2;
        const avail_pill_w: u32 = content_w - 20 - total_gaps;
        const mode_pill_w: u32 = avail_pill_w / 3;
        const mode_pill_h: u32 = 24;

        const profiles = [_]struct {
            prof: sys_status.PowerProfile,
            label: []const u8,
            act: Action,
        }{
            .{ .prof = .power_saver, .label = "󰌪 Saver", .act = .set_power_profile_saver },
            .{ .prof = .balanced, .label = "󰗑 Balanced", .act = .set_power_profile_balanced },
            .{ .prof = .performance, .label = "󰓅 Performance", .act = .set_power_profile_performance },
        };

        var pill_x = pad_x + 10;
        for (profiles) |p| {
            const is_active = (self.sys.power_profile == p.prof);
            const is_hov = self.isAreaHovered(pill_x, row3_y, mode_pill_w, mode_pill_h);

            const bg = if (is_active)
                self.cfg.theme.accent
            else if (is_hov)
                self.cfg.theme.elevated
            else
                self.cfg.theme.surface;

            const fg = if (is_active)
                self.cfg.theme.accent_fg
            else if (is_hov)
                self.cfg.theme.text_bright
            else
                self.cfg.theme.text_muted;

            target.fillSquircle(pill_x, row3_y, mode_pill_w, mode_pill_h, 6, bg);
            if (is_active) {
                target.drawSquircleBorder(pill_x, row3_y, mode_pill_w, mode_pill_h, 6, 1, self.cfg.theme.border_focused);
            } else {
                target.drawSquircleBorder(pill_x, row3_y, mode_pill_w, mode_pill_h, 6, 1, self.cfg.theme.border);
            }

            const lbl_w = target.measureTextWithSize(&self.font, p.label, 11);
            const lbl_x = pill_x + @divTrunc(@as(i32, @intCast(mode_pill_w)) - @as(i32, @intCast(lbl_w)), 2);
            target.drawTextWithSize(&self.font, p.label, lbl_x, row3_y + 16, 11, fg);

            try self.hit_areas.append(self.allocator, .{
                .x = pill_x,
                .y = row3_y,
                .w = mode_pill_w,
                .h = mode_pill_h,
                .action = p.act,
            });

            pill_x += @as(i32, @intCast(mode_pill_w + pill_gap));
        }

        cur_y += @as(i32, @intCast(status_card_h + 10));

        // ======================== 6. Footer: Date Strip ========================
        var date_buf: [64]u8 = undefined;
        const date_str = formatDate(&date_buf);
        var full_date_buf: [80]u8 = undefined;
        const full_date = std.fmt.bufPrint(&full_date_buf, " {s}", .{date_str}) catch date_str;
        const date_w = target.measureTextWithSize(&self.font, full_date, 11);
        const date_x = @divTrunc(@as(i32, @intCast(w)) - @as(i32, @intCast(date_w)), 2);
        target.drawTextWithSize(&self.font, full_date, date_x, cur_y + 14, 11, self.cfg.theme.text_muted);
    }

    fn drawHeaderButton(
        self: *QuickSettings,
        target: renderer.Renderer,
        x: i32,
        y: i32,
        size: u32,
        icon: []const u8,
        action: Action,
        hover_color: theme.Color,
    ) !void {
        const is_hovered = self.isAreaHovered(x, y, size, size);

        const bg = if (is_hovered)
            hover_color
        else
            self.cfg.theme.surface;

        const fg = if (is_hovered)
            hover_color.contrastingTextColor()
        else
            self.cfg.theme.text_bright;

        if (is_hovered) {
            target.drawSoftShadow(x, y + 1, size, size, size / 2, 4, 35);
        }
        target.fillSquircle(x, y, size, size, size / 2, bg);
        target.drawSquircleBorder(x, y, size, size, size / 2, 1, if (is_hovered) hover_color else self.cfg.theme.border);
        const icon_w = target.measureTextWithSize(&self.font, icon, 14);
        const icon_x = x + @divTrunc(@as(i32, @intCast(size)) - @as(i32, @intCast(icon_w)), 2);
        target.drawTextWithSize(&self.font, icon, icon_x, y + 20, 14, fg);

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
        target: renderer.Renderer,
        x: i32,
        y: i32,
        w: u32,
        h: u32,
        icon: []const u8,
        title: []const u8,
        subtitle: []const u8,
        is_active: bool,
        action: Action,
        chevron_action: ?Action,
    ) !void {
        const has_chevron = (chevron_action != null);
        const chevron_w: u32 = if (has_chevron) 28 else 0;
        const main_w: u32 = w - chevron_w;

        const is_main_hovered = self.isAreaHovered(x, y, main_w, h);
        const is_chev_hovered = if (has_chevron)
            self.isAreaHovered(x + @as(i32, @intCast(main_w)), y, chevron_w, h)
        else
            false;

        var bg = if (is_active)
            self.cfg.theme.accent
        else
            self.cfg.theme.surface;

        if (is_main_hovered) {
            bg = if (is_active)
                theme.Color.init(220, self.cfg.theme.accent.r, self.cfg.theme.accent.g, self.cfg.theme.accent.b)
            else
                self.cfg.theme.elevated;
        }

        const active_fg = self.cfg.theme.accent_fg;
        const fg = if (is_active) active_fg else self.cfg.theme.text_bright;
        const sub_fg = if (is_active)
            self.cfg.theme.accent_fg
        else
            self.cfg.theme.text_muted;

        if (is_active) {
            target.drawSoftShadow(x, y + 1, w, h, 12, 4, 30);
            target.fillGlassSquircle(x, y, w, h, 12, bg);
            target.drawSquircleBorder(x, y, w, h, 12, 1, self.cfg.theme.accent);
        } else {
            if (is_main_hovered) {
                target.drawSoftShadow(x, y + 1, w, h, 12, 3, 20);
            }
            target.fillSquircle(x, y, w, h, 12, bg);
            target.drawSquircleBorder(x, y, w, h, 12, 1, if (is_main_hovered) self.cfg.theme.pill_hover else self.cfg.theme.border);
        }

        // Icon circle
        const circle_size: u32 = 28;
        const circle_x = x + 8;
        const circle_y = y + @divTrunc(@as(i32, @intCast(h)) - @as(i32, @intCast(circle_size)), 2);
        const circle_bg = if (is_active)
            (if (self.cfg.theme.accent.isLight()) theme.Color.init(40, 0, 0, 0) else theme.Color.init(55, 255, 255, 255))
        else
            self.cfg.theme.elevated;
        target.fillRoundedRect(circle_x, circle_y, circle_size, circle_size, circle_size / 2, circle_bg);

        const icon_w = target.measureTextWithSize(&self.font, icon, 14);
        const icon_x = circle_x + @divTrunc(@as(i32, @intCast(circle_size)) - @as(i32, @intCast(icon_w)), 2);
        target.drawTextWithSize(&self.font, icon, icon_x, circle_y + 19, 14, fg);

        // Title and Subtitle
        const text_x = circle_x + @as(i32, @intCast(circle_size + 8));
        target.drawTextWithSize(&self.font, title, text_x, y + 20, 12, fg);

        var sub_buf: [64]u8 = undefined;
        const max_sub_w = main_w - (circle_size + 20);
        const trunc_sub = truncateText(target, &self.font, subtitle, max_sub_w, &sub_buf);
        target.drawTextWithSize(&self.font, trunc_sub, text_x, y + 36, 10, sub_fg);

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

            // Subtle divider
            target.fillRect(chev_x, y + 8, 1, h - 16, self.cfg.theme.border);

            if (is_chev_hovered) {
                target.fillRoundedRect(chev_x + 2, y + 4, chevron_w - 4, h - 8, 8, if (is_active) self.cfg.theme.elevated else self.cfg.theme.pill_hover);
            }

            const chev_icon = "󰅂";
            const chev_fg = if (is_active) active_fg else self.cfg.theme.text_muted;
            const chev_text_w = target.measureTextWithSize(&self.font, chev_icon, 13);
            const chev_text_x = chev_x + @divTrunc(@as(i32, @intCast(chevron_w)) - @as(i32, @intCast(chev_text_w)), 2);
            target.drawTextWithSize(&self.font, chev_icon, chev_text_x, y + 28, 13, chev_fg);

            try self.hit_areas.append(self.allocator, .{
                .x = chev_x,
                .y = y,
                .w = chevron_w,
                .h = h,
                .action = chevron_action.?,
            });
        }
    }

    fn renderSubMenu(self: *QuickSettings, target: renderer.Renderer) !void {
        const w = target.width;
        const pad_x: i32 = 16;
        const content_w = w - 32;

        const title = switch (self.view_mode) {
            .wifi_menu => "Wi-Fi Networks",
            .bluetooth_menu => "Bluetooth Devices",
            .audio_menu => "Audio Outputs",
            .main => "",
        };

        // Header: Back button on left
        const btn_size: u32 = 30;
        const cur_y: i32 = 16;
        try self.drawHeaderButton(target, pad_x, cur_y + 2, btn_size, "󰁍", .back_to_main, self.cfg.theme.pill_bg);

        // Header title
        target.drawTextWithSize(&self.font, title, pad_x + 38, cur_y + 22, 14, self.cfg.theme.text_bright);

        // Header: Refresh/Rescan button on right
        const refresh_x = @as(i32, @intCast(w)) - pad_x - @as(i32, @intCast(btn_size));
        try self.drawHeaderButton(target, refresh_x, cur_y + 2, btn_size, "󰑐", .refresh_sub_menu, self.cfg.theme.pill_bg);

        // Separator line
        const sep_y: i32 = cur_y + 42;
        target.fillRect(pad_x, sep_y, content_w, 1, self.cfg.theme.separator_fg);

        var list_y = sep_y + 12;
        const item_h: u32 = 48;
        const item_gap: u32 = 6;
        const max_visible: usize = 7;

        switch (self.view_mode) {
            .wifi_menu => {
                if (self.wifi_items.items.len == 0) {
                    self.drawEmptySubMenu(target, "󰤭", "No Wi-Fi networks found", "Click 󰑐 to scan");
                    return;
                }
                const start_idx = self.scroll_offset;
                const end_idx = @min(self.wifi_items.items.len, start_idx + max_visible);

                for (self.wifi_items.items[start_idx..end_idx], start_idx..) |item, actual_idx| {
                    const is_input_active = (self.wifi_input_idx != null and self.wifi_input_idx.? == actual_idx);
                    const has_error = (is_input_active and self.wifi_error_len > 0);
                    const cur_item_h: u32 = if (is_input_active) (if (has_error) 134 else 110) else item_h;
                    const is_hovered = self.isAreaHovered(pad_x, list_y, content_w, cur_item_h);

                    var bg = if (item.is_active or is_input_active)
                        self.cfg.theme.elevated
                    else
                        self.cfg.theme.surface;
                    if (is_hovered and !is_input_active) {
                        bg = self.cfg.theme.elevated;
                    }

                    target.fillRoundedRect(pad_x, list_y, content_w, cur_item_h, 10, bg);
                    target.drawRoundedBorder(pad_x, list_y, content_w, cur_item_h, 10, 1, if (is_input_active or item.is_active) self.cfg.theme.accent else self.cfg.theme.border);

                    // Signal icon
                    const sig_icon = if (item.signal >= 75)
                        "󰤨"
                    else if (item.signal >= 50)
                        "󰤥"
                    else if (item.signal >= 25)
                        "󰤢"
                    else
                        "󰤟";

                    const icon_color = if (item.is_active or is_input_active) self.cfg.theme.accent else self.cfg.theme.text_bright;
                    target.drawTextWithSize(&self.font, sig_icon, pad_x + 12, list_y + 30, 15, icon_color);

                    // SSID name
                    const ssid_name = item.ssid[0..item.ssid_len];
                    var name_buf: [64]u8 = undefined;
                    const trunc_name = truncateText(target, &self.font, ssid_name, content_w - 90, &name_buf);
                    target.drawTextWithSize(&self.font, trunc_name, pad_x + 36, list_y + 20, 12, self.cfg.theme.text_bright);

                    // Subtitle: Signal + Security
                    var sub_buf: [64]u8 = undefined;
                    const sec_str = if (item.security_len > 0) item.security[0..item.security_len] else "Open";
                    const sub_str = if (item.is_active)
                        std.fmt.bufPrint(&sub_buf, "Connected • {d}% • {s}", .{ item.signal, sec_str }) catch "Connected"
                    else
                        std.fmt.bufPrint(&sub_buf, "{d}% • {s}", .{ item.signal, sec_str }) catch sec_str;

                    const sub_color = if (item.is_active) self.cfg.theme.accent else self.cfg.theme.text_muted;
                    target.drawTextWithSize(&self.font, sub_str, pad_x + 36, list_y + 36, 10, sub_color);

                    // Trash / Forget button on the right
                    const trash_size: u32 = 24;
                    const trash_x = pad_x + @as(i32, @intCast(content_w)) - @as(i32, @intCast(trash_size)) - 6;
                    const trash_y = list_y + 12;
                    const is_trash_hov = self.isAreaHovered(trash_x, trash_y, trash_size, trash_size);

                    if (!is_input_active) {
                        if (is_trash_hov) {
                            target.fillGlassSquircle(trash_x, trash_y, trash_size, trash_size, 5, theme.Color.init(60, self.cfg.theme.error_color.r, self.cfg.theme.error_color.g, self.cfg.theme.error_color.b));
                            target.drawSquircleBorder(trash_x, trash_y, trash_size, trash_size, 5, 1, self.cfg.theme.error_color);
                        }
                        target.drawTextWithSize(&self.font, "󰆴", trash_x + 5, trash_y + 16, 12, if (is_trash_hov) self.cfg.theme.error_color else self.cfg.theme.text_muted);
                        try self.hit_areas.append(self.allocator, .{
                            .x = trash_x,
                            .y = trash_y,
                            .w = trash_size,
                            .h = trash_size,
                            .action = .{ .forget_wifi = actual_idx },
                        });
                    }

                    // Checkmark if active
                    if (item.is_active) {
                        target.drawTextWithSize(&self.font, "󰄬", trash_x - 22, list_y + 30, 15, self.cfg.theme.accent);
                    }

                    if (!is_input_active) {
                        try self.hit_areas.append(self.allocator, .{
                            .x = pad_x,
                            .y = list_y,
                            .w = content_w - trash_size - 10,
                            .h = cur_item_h,
                            .action = .{ .select_wifi = actual_idx },
                        });
                    } else {
                        // Card header hit area to collapse input on click
                        try self.hit_areas.append(self.allocator, .{
                            .x = pad_x,
                            .y = list_y,
                            .w = content_w,
                            .h = 40,
                            .action = .wifi_cancel,
                        });

                        // Password input field
                        const input_x = pad_x + 36;
                        const input_y = list_y + 44;
                        const input_w = content_w - 48;
                        const input_h: u32 = 26;

                        target.fillRoundedRect(input_x, input_y, input_w, input_h, 6, self.cfg.theme.base);
                        const input_border = if (has_error) self.cfg.theme.error_color else self.cfg.theme.accent;
                        target.drawRoundedBorder(input_x, input_y, input_w, input_h, 6, 1, input_border);

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
                            );
                        } else {
                            if (self.wifi_password_len == 0) {
                                target.drawTextWithSize(&self.font, "Enter Wi-Fi password... |", input_x + 8, input_y + 18, 11, self.cfg.theme.text_muted);
                            } else {
                                var mask_buf: [130]u8 = undefined;
                                const mask_len = @min(self.wifi_password_len, 32);
                                @memset(mask_buf[0..mask_len], '*');
                                mask_buf[mask_len] = '|';
                                target.drawTextWithSize(&self.font, mask_buf[0 .. mask_len + 1], input_x + 8, input_y + 18, 12, self.cfg.theme.text_bright);
                            }
                        }

                        try self.hit_areas.append(self.allocator, .{
                            .x = input_x,
                            .y = input_y,
                            .w = input_w,
                            .h = input_h,
                            .action = .wifi_input_click,
                        });

                        // Action buttons: Cancel and Connect
                        const btn_y = list_y + 76;
                        const cancel_w: u32 = 64;
                        const is_connecting = (self.wifi_connect_state == .connecting);
                        const connect_w: u32 = if (is_connecting) 92 else 74;
                        const btn_h: u32 = 24;

                        // Cancel button
                        const is_cancel_hovered = self.isAreaHovered(input_x, btn_y, cancel_w, btn_h);
                        const cancel_bg = if (is_cancel_hovered) self.cfg.theme.elevated else self.cfg.theme.surface;
                        target.fillRoundedRect(input_x, btn_y, cancel_w, btn_h, 6, cancel_bg);
                        target.drawRoundedBorder(input_x, btn_y, cancel_w, btn_h, 6, 1, self.cfg.theme.border);
                        const c_text_w = target.measureTextWithSize(&self.font, "Cancel", 11);
                        const c_text_x = input_x + @divTrunc(@as(i32, @intCast(cancel_w)) - @as(i32, @intCast(c_text_w)), 2);
                        target.drawTextWithSize(&self.font, "Cancel", c_text_x, btn_y + 16, 11, self.cfg.theme.text_bright);
                        try self.hit_areas.append(self.allocator, .{
                            .x = input_x,
                            .y = btn_y,
                            .w = cancel_w,
                            .h = btn_h,
                            .action = .wifi_cancel,
                        });

                        // Connect button
                        const conn_x = input_x + @as(i32, @intCast(cancel_w + 8));
                        const is_conn_hovered = self.isAreaHovered(conn_x, btn_y, connect_w, btn_h);
                        const conn_bg = if (is_connecting)
                            self.cfg.theme.elevated
                        else if (is_conn_hovered)
                            self.cfg.theme.accent
                        else
                            self.cfg.theme.surface;
                        const conn_fg = if (is_conn_hovered and !is_connecting) self.cfg.theme.accent_fg else self.cfg.theme.text_bright;
                        target.fillRoundedRect(conn_x, btn_y, connect_w, btn_h, 6, conn_bg);

                        const conn_label = if (is_connecting) "Connecting..." else "Connect";
                        const k_text_w = target.measureTextWithSize(&self.font, conn_label, 11);
                        const k_text_x = conn_x + @divTrunc(@as(i32, @intCast(connect_w)) - @as(i32, @intCast(k_text_w)), 2);
                        target.drawTextWithSize(&self.font, conn_label, k_text_x, btn_y + 16, 11, conn_fg);
                        try self.hit_areas.append(self.allocator, .{
                            .x = conn_x,
                            .y = btn_y,
                            .w = connect_w,
                            .h = btn_h,
                            .action = .wifi_connect_submit,
                        });

                        // Error message feedback
                        if (has_error) {
                            target.drawTextWithSize(&self.font, "󰅚", input_x, btn_y + 34, 11, self.cfg.theme.error_color);
                            target.drawTextWithSize(&self.font, self.wifi_error_msg[0..self.wifi_error_len], input_x + 16, btn_y + 34, 10, self.cfg.theme.error_color);
                        }
                    }

                    list_y += @as(i32, @intCast(cur_item_h + item_gap));
                }
            },
            .bluetooth_menu => {
                if (self.bt_items.items.len == 0) {
                    self.drawEmptySubMenu(target, "󰂲", "No Bluetooth devices found", "Click 󰑐 to scan");
                    return;
                }
                const start_idx = self.scroll_offset;
                const end_idx = @min(self.bt_items.items.len, start_idx + max_visible);

                for (self.bt_items.items[start_idx..end_idx], start_idx..) |item, actual_idx| {
                    const is_hovered = self.isAreaHovered(pad_x, list_y, content_w, item_h);

                    var bg = if (item.connected)
                        self.cfg.theme.elevated
                    else
                        self.cfg.theme.surface;
                    if (is_hovered) {
                        bg = self.cfg.theme.elevated;
                    }

                    target.fillRoundedRect(pad_x, list_y, content_w, item_h, 10, bg);
                    target.drawRoundedBorder(pad_x, list_y, content_w, item_h, 10, 1, if (item.connected) self.cfg.theme.accent else self.cfg.theme.border);

                    const icon_color = if (item.connected) self.cfg.theme.accent else self.cfg.theme.text_bright;
                    target.drawTextWithSize(&self.font, item.icon, pad_x + 12, list_y + 30, 15, icon_color);

                    // Device name
                    const dev_name = item.name[0..item.name_len];
                    var name_buf: [64]u8 = undefined;
                    const trunc_name = truncateText(target, &self.font, dev_name, content_w - 90, &name_buf);
                    target.drawTextWithSize(&self.font, trunc_name, pad_x + 36, list_y + 20, 12, self.cfg.theme.text_bright);

                    // Subtitle: Connected or Paired
                    const sub_str = if (item.connected) "Connected" else "Paired";
                    const sub_color = if (item.connected) self.cfg.theme.accent else self.cfg.theme.text_muted;
                    target.drawTextWithSize(&self.font, sub_str, pad_x + 36, list_y + 36, 10, sub_color);

                    // Trash / Remove button on the right
                    const trash_size: u32 = 24;
                    const trash_x = pad_x + @as(i32, @intCast(content_w)) - @as(i32, @intCast(trash_size)) - 6;
                    const trash_y = list_y + 12;
                    const is_trash_hov = self.isAreaHovered(trash_x, trash_y, trash_size, trash_size);

                    if (is_trash_hov) {
                        target.fillGlassSquircle(trash_x, trash_y, trash_size, trash_size, 5, theme.Color.init(60, self.cfg.theme.error_color.r, self.cfg.theme.error_color.g, self.cfg.theme.error_color.b));
                        target.drawSquircleBorder(trash_x, trash_y, trash_size, trash_size, 5, 1, self.cfg.theme.error_color);
                    }
                    target.drawTextWithSize(&self.font, "󰆴", trash_x + 5, trash_y + 16, 12, if (is_trash_hov) self.cfg.theme.error_color else self.cfg.theme.text_muted);
                    try self.hit_areas.append(self.allocator, .{
                        .x = trash_x,
                        .y = trash_y,
                        .w = trash_size,
                        .h = trash_size,
                        .action = .{ .remove_bluetooth = actual_idx },
                    });

                    // Checkmark if connected
                    if (item.connected) {
                        target.drawTextWithSize(&self.font, "󰄬", trash_x - 22, list_y + 30, 15, self.cfg.theme.accent);
                    }

                    try self.hit_areas.append(self.allocator, .{
                        .x = pad_x,
                        .y = list_y,
                        .w = content_w - trash_size - 10,
                        .h = item_h,
                        .action = .{ .select_bluetooth = actual_idx },
                    });

                    list_y += @as(i32, @intCast(item_h + item_gap));
                }
            },
            .audio_menu => {
                if (self.sink_items.items.len == 0) {
                    self.drawEmptySubMenu(target, "󰖁", "No audio sinks found", "Click 󰑐 to refresh");
                    return;
                }
                const start_idx = self.scroll_offset;
                const end_idx = @min(self.sink_items.items.len, start_idx + max_visible);

                for (self.sink_items.items[start_idx..end_idx], start_idx..) |item, actual_idx| {
                    const is_hovered = self.isAreaHovered(pad_x, list_y, content_w, item_h);

                    var bg = if (item.is_default)
                        self.cfg.theme.elevated
                    else
                        self.cfg.theme.surface;
                    if (is_hovered) {
                        bg = self.cfg.theme.elevated;
                    }

                    target.fillRoundedRect(pad_x, list_y, content_w, item_h, 10, bg);
                    target.drawRoundedBorder(pad_x, list_y, content_w, item_h, 10, 1, if (item.is_default) self.cfg.theme.accent else self.cfg.theme.border);

                    // Icon (headphones or speaker)
                    const sink_name = item.name[0..item.name_len];
                    var lower_buf: [128]u8 = undefined;
                    const lower_name = if (sink_name.len <= lower_buf.len)
                        std.ascii.lowerString(&lower_buf, sink_name)
                    else
                        sink_name;

                    var is_headphones = false;
                    for ([_][]const u8{ "headphone", "headset", "earphone", "buds" }) |kw| {
                        if (std.mem.indexOf(u8, lower_name, kw) != null) {
                            is_headphones = true;
                            break;
                        }
                    }
                    const sink_icon = if (is_headphones) "󰋋" else "󰕾";
                    const icon_color = if (item.is_default) self.cfg.theme.accent else self.cfg.theme.text_bright;
                    target.drawTextWithSize(&self.font, sink_icon, pad_x + 12, list_y + 30, 15, icon_color);

                    // Sink name
                    var name_buf: [96]u8 = undefined;
                    const trunc_name = truncateText(target, &self.font, sink_name, content_w - 90, &name_buf);
                    target.drawTextWithSize(&self.font, trunc_name, pad_x + 36, list_y + 20, 12, self.cfg.theme.text_bright);

                    // Subtitle: Default / Vol %
                    var sub_buf: [64]u8 = undefined;
                    const sub_str = if (item.is_default)
                        std.fmt.bufPrint(&sub_buf, "Default Output • {d}%", .{item.volume_pct}) catch "Default Output"
                    else
                        std.fmt.bufPrint(&sub_buf, "Volume: {d}%", .{item.volume_pct}) catch "Audio Output";

                    const sub_color = if (item.is_default) self.cfg.theme.accent else self.cfg.theme.text_muted;
                    target.drawTextWithSize(&self.font, sub_str, pad_x + 36, list_y + 36, 10, sub_color);

                    // Checkmark if default
                    if (item.is_default) {
                        target.drawTextWithSize(&self.font, "󰄬", pad_x + @as(i32, @intCast(content_w)) - 24, list_y + 30, 15, self.cfg.theme.accent);
                    }

                    try self.hit_areas.append(self.allocator, .{
                        .x = pad_x,
                        .y = list_y,
                        .w = content_w,
                        .h = item_h,
                        .action = .{ .select_audio_sink = actual_idx },
                    });

                    list_y += @as(i32, @intCast(item_h + item_gap));
                }
            },
            .main => {},
        }
    }

    fn drawEmptySubMenu(self: *QuickSettings, target: renderer.Renderer, icon: []const u8, message: []const u8, hint: []const u8) void {
        const w = target.width;
        const icon_w = target.measureTextWithSize(&self.font, icon, 32);
        const icon_x = @divTrunc(@as(i32, @intCast(w)) - @as(i32, @intCast(icon_w)), 2);
        target.drawTextWithSize(&self.font, icon, icon_x, 180, 32, self.cfg.theme.text_muted);

        const msg_w = target.measureTextWithSize(&self.font, message, 13);
        const msg_x = @divTrunc(@as(i32, @intCast(w)) - @as(i32, @intCast(msg_w)), 2);
        target.drawTextWithSize(&self.font, message, msg_x, 220, 13, self.cfg.theme.text_bright);

        const hint_w = target.measureTextWithSize(&self.font, hint, 11);
        const hint_x = @divTrunc(@as(i32, @intCast(w)) - @as(i32, @intCast(hint_w)), 2);
        target.drawTextWithSize(&self.font, hint, hint_x, 244, 11, self.cfg.theme.text_muted);
    }

    fn drawSlider(
        self: *QuickSettings,
        target: renderer.Renderer,
        x: i32,
        y: i32,
        w: u32,
        h: u32,
        percent: u32,
        filled_color: theme.Color,
        action: Action,
    ) !void {
        const is_hovered = self.isAreaHovered(x, y, w, h);

        // Track background
        const track_bg = if (is_hovered)
            self.cfg.theme.elevated
        else
            self.cfg.theme.surface;

        target.fillSquircle(x, y, w, h, h / 2, track_bg);
        target.drawSquircleBorder(x, y, w, h, h / 2, 1, self.cfg.theme.border);

        // Filled bar
        const clamped_pct = @min(100, percent);
        const fill_w = (@as(u64, w) * clamped_pct) / 100;
        if (fill_w > 0) {
            target.fillGlassSquircle(x, y, @intCast(fill_w), h, h / 2, filled_color);
        }

        // Percentage text centered
        var pct_buf: [16]u8 = undefined;
        const pct_str = std.fmt.bufPrint(&pct_buf, "{d}%", .{clamped_pct}) catch "";
        const text_w = target.measureTextWithSize(&self.font, pct_str, 11);
        const text_x = x + @divTrunc(@as(i32, @intCast(w)) - @as(i32, @intCast(text_w)), 2);
        const pct_fg = if (clamped_pct >= 50) filled_color.contrastingTextColor() else self.cfg.theme.text_bright;
        target.drawTextWithSize(&self.font, pct_str, text_x, y + 17, 11, pct_fg);

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
        target: renderer.Renderer,
        x: i32,
        y: i32,
        size: u32,
        icon: []const u8,
        action: Action,
    ) !void {
        const is_hovered = self.isAreaHovered(x, y, size, size);
        const bg = if (is_hovered)
            theme.Color.init(90, 255, 255, 255)
        else
            theme.Color.init(35, 255, 255, 255);

        target.fillGlassSquircle(x, y, size, size, size / 2, bg);
        target.drawSquircleBorder(x, y, size, size, size / 2, 1, if (is_hovered) self.cfg.theme.accent else theme.Color.init(30, 255, 255, 255));
        const icon_w = target.measureTextWithSize(&self.font, icon, 12);
        const icon_x = x + @divTrunc(@as(i32, @intCast(size)) - @as(i32, @intCast(icon_w)), 2);
        target.drawTextWithSize(&self.font, icon, icon_x, y + 17, 12, self.cfg.theme.text_bright);

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

    fn truncateText(target: renderer.Renderer, font: *renderer.Font, text: []const u8, max_w: u32, buf: []u8) []const u8 {
        const text_w = target.measureTextWithSize(font, text, 12);
        if (text_w <= max_w) return text;

        const ellipsis = "...";
        const ell_w = target.measureTextWithSize(font, ellipsis, 12);
        if (ell_w >= max_w) return "";

        var best_len: usize = 0;
        var utf8_view = std.unicode.Utf8View.init(text) catch return text;
        var it = utf8_view.iterator();
        while (it.nextCodepointSlice()) |slice| {
            const candidate_len = best_len + slice.len;
            if (candidate_len + ellipsis.len > buf.len) break;
            @memcpy(buf[0..candidate_len], text[0..candidate_len]);
            @memcpy(buf[candidate_len .. candidate_len + ellipsis.len], ellipsis);
            const w = target.measureTextWithSize(font, buf[0 .. candidate_len + ellipsis.len], 12);
            if (w > max_w) break;
            best_len = candidate_len;
        }

        if (best_len == 0) return "";
        @memcpy(buf[0..best_len], text[0..best_len]);
        @memcpy(buf[best_len .. best_len + ellipsis.len], ellipsis);
        return buf[0 .. best_len + ellipsis.len];
    }
};

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
    };
    defer {
        qs.wifi_items.deinit(allocator);
        qs.bt_items.deinit(allocator);
        qs.sink_items.deinit(allocator);
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

    // Scrolling down increases offset up to max_scroll (10 - 7 = 3)
    try std.testing.expect(qs.handlePointerAxis(0, 0, 1));
    try std.testing.expectEqual(@as(usize, 1), qs.scroll_offset);
    try std.testing.expect(qs.handlePointerAxis(0, 0, 1));
    try std.testing.expect(qs.handlePointerAxis(0, 0, 1));
    try std.testing.expectEqual(@as(usize, 3), qs.scroll_offset);
    // Beyond max_scroll should return false
    try std.testing.expect(!qs.handlePointerAxis(0, 0, 1));

    // Scrolling up decreases offset back to 0
    try std.testing.expect(qs.handlePointerAxis(0, 0, -1));
    try std.testing.expectEqual(@as(usize, 2), qs.scroll_offset);
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
    };
    defer {
        qs.wifi_items.deinit(allocator);
        qs.bt_items.deinit(allocator);
        qs.sink_items.deinit(allocator);
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
    };
    defer {
        qs.wifi_items.deinit(allocator);
        qs.bt_items.deinit(allocator);
        qs.sink_items.deinit(allocator);
        qs.hit_areas.deinit(allocator);
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
        qs.checkWifiStatus();
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
    };
    defer {
        qs.wifi_items.deinit(allocator);
        qs.bt_items.deinit(allocator);
        qs.sink_items.deinit(allocator);
        qs.hit_areas.deinit(allocator);
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
