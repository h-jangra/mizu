const std = @import("std");
const c = @import("../c.zig").c;
const proc_file = @import("proc_file.zig");
const exec = @import("../core/exec.zig");
const readProcFile = proc_file.read;

pub const dbus_monitor = struct {
    pub const MizuMprisState = enum(c_int) {
        stopped = 0,
        paused = 1,
        playing = 2,
    };

    pub const MizuMprisSnapshot = extern struct {
        mpris_state: c_int,
        mpris_track: [128]u8,
        mpris_title: [128]u8,
        mpris_artist: [128]u8,
        mpris_art_url: [256]u8,
        version: u32,
    };

    pub extern "c" fn mizu_dbus_monitor_init(wake_fd: c_int) c_int;
    pub extern "c" fn mizu_dbus_monitor_set_wake_fd(wake_fd: c_int) void;
    pub extern "c" fn mizu_dbus_monitor_get_mpris(out: *MizuMprisSnapshot) bool;
    pub extern "c" fn mizu_dbus_monitor_check_network_dirty() bool;
    pub extern "c" fn mizu_dbus_monitor_check_bluetooth_dirty() bool;
    pub extern "c" fn mizu_dbus_monitor_trigger_mpris_refresh() void;
    pub extern "c" fn mizu_dbus_monitor_start_bt_discovery() void;
    pub extern "c" fn mizu_dbus_monitor_stop_bt_discovery() void;
    pub extern "c" fn mizu_dbus_monitor_bt_connect(mac: [*c]const u8, connect: bool, err_buf: [*c]u8, err_len: usize) bool;
    pub extern "c" fn mizu_dbus_monitor_bt_remove(mac: [*c]const u8) bool;
    pub extern "c" fn mizu_dbus_monitor_deinit() void;
};

pub const BatteryStatus = enum {
    none,
    charging,
    discharging,
    full,
};

pub fn batteryIcon(cap_raw: u32, charging: bool) []const u8 {
    const cap: u8 = @min(cap_raw, 100);
    if (charging) {
        if (cap >= 95) return "󰂄";
        if (cap >= 90) return "󰂋";
        if (cap >= 80) return "󰂊";
        if (cap >= 70) return "󰢞";
        if (cap >= 60) return "󰂉";
        if (cap >= 50) return "󰢝";
        if (cap >= 40) return "󰂈";
        if (cap >= 30) return "󰂇";
        if (cap >= 20) return "󰂆";
        return "󰢜";
    }
    if (cap >= 90) return "󰁹";
    if (cap >= 80) return "󰂂";
    if (cap >= 70) return "󰂁";
    if (cap >= 60) return "󰂀";
    if (cap >= 50) return "󰁿";
    if (cap >= 40) return "󰁾";
    if (cap >= 30) return "󰁽";
    if (cap >= 20) return "󰁼";
    if (cap >= 10) return "󰁻";
    return "󰂎";
}

pub const PowerProfile = enum {
    power_saver,
    balanced,
    performance,

    pub fn name(self: PowerProfile) []const u8 {
        return switch (self) {
            .power_saver => "Power Saver",
            .balanced => "Balanced",
            .performance => "Performance",
        };
    }

    pub fn icon(self: PowerProfile) []const u8 {
        return switch (self) {
            .power_saver => "󰌪",
            .balanced => "󰗑",
            .performance => "󰓅",
        };
    }
};

pub const MprisState = enum {
    stopped,
    playing,
    paused,
};

pub const spawnCmd = exec.spawnShell;

pub const SpinLock = struct {
    flag: std.atomic.Value(bool) = .init(false),

    pub fn lock(self: *SpinLock) void {
        while (self.flag.swap(true, .acquire)) {
            _ = c.usleep(100);
        }
    }

    pub fn unlock(self: *SpinLock) void {
        self.flag.store(false, .release);
    }
};

pub const AsyncSysData = struct {
    volume_percent: u32 = 50,
    volume_muted: bool = false,
    mpris_state: MprisState = .stopped,
    mpris_track: [128]u8 = [_]u8{0} ** 128,
    mpris_track_len: usize = 0,
    mpris_art_url: [256]u8 = [_]u8{0} ** 256,
    mpris_art_url_len: usize = 0,
    wifi_ssid: [64]u8 = [_]u8{0} ** 64,
    wifi_ssid_len: usize = 0,
    bluetooth_connected: bool = false,
    bluetooth_device: [64]u8 = [_]u8{0} ** 64,
    bluetooth_device_len: usize = 0,
};

pub const SharedWorkerState = struct {
    running: std.atomic.Value(bool) = .init(true),
    ref_count: std.atomic.Value(u32) = .init(2), // 1 for UI, 1 for worker
    wifi_enabled: std.atomic.Value(bool) = .init(true),
    bluetooth_enabled: std.atomic.Value(bool) = .init(false),
    earbud_safety_enabled: std.atomic.Value(bool) = .init(true),
    lock: SpinLock = .{},
    data: AsyncSysData = .{},
    thread: ?std.Thread = null,

    pub fn release(self: *SharedWorkerState) void {
        if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
            std.heap.c_allocator.destroy(self);
        }
    }
};

pub const SysStatus = struct {
    allocator: std.mem.Allocator,
    shared: ?*SharedWorkerState = null,

    // CPU tracking
    prev_idle: u64 = 0,
    prev_total: u64 = 0,
    cpu_percent: u32 = 0,

    // Memory
    mem_used_gib: f32 = 0.0,
    mem_total_gib: f32 = 0.0,

    // Battery & Power Profile
    has_battery: bool = false,
    ac_online: bool = false,
    bat_capacity: u32 = 0,
    bat_status: BatteryStatus = .none,
    bat_seconds_remaining: ?i64 = null,
    energy_rate_watts: f64 = 0.0,
    power_profile: PowerProfile = .balanced,
    profile_manually_set: bool = false,
    battery_device: [64]u8 = [_]u8{0} ** 64,
    battery_device_len: usize = 0,

    // Backlight
    has_backlight: bool = false,
    backlight_percent: u32 = 0,
    backlight_device: [64]u8 = [_]u8{0} ** 64,
    backlight_device_len: usize = 0,

    // Audio
    volume_percent: u32 = 50,
    volume_muted: bool = false,

    // MPRIS
    mpris_state: MprisState = .stopped,
    mpris_track: [128]u8 = [_]u8{0} ** 128,
    mpris_track_len: usize = 0,
    mpris_art_url: [256]u8 = [_]u8{0} ** 256,
    mpris_art_url_len: usize = 0,

    // Network & Bluetooth
    wifi_enabled: bool = false,
    wifi_ssid: [64]u8 = [_]u8{0} ** 64,
    wifi_ssid_len: usize = 0,
    bluetooth_enabled: bool = false,
    bluetooth_connected: bool = false,
    bluetooth_device: [64]u8 = [_]u8{0} ** 64,
    bluetooth_device_len: usize = 0,

    // Host & Uptime
    user_host: [64]u8 = [_]u8{0} ** 64,
    user_host_len: usize = 0,
    uptime_str: [32]u8 = [_]u8{0} ** 32,
    uptime_len: usize = 0,

    // Audio & safety
    earbud_safety_enabled: bool = true,

    // Ticks & throttling
    tick_count: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) SysStatus {
        var self = SysStatus{
            .allocator = allocator,
        };
        if (loadPowerProfileCache()) |cached| {
            self.power_profile = cached;
            self.profile_manually_set = true;
        }
        if (loadEarbudSafetyCache()) |cached| {
            self.earbud_safety_enabled = cached;
        }

        // Allocate heap-pinned worker state so it remains valid across moves
        const shared = std.heap.c_allocator.create(SharedWorkerState) catch null;
        if (shared) |s| {
            s.* = SharedWorkerState{};
            s.earbud_safety_enabled.store(self.earbud_safety_enabled, .release);
            s.thread = std.Thread.spawn(.{}, workerLoop, .{s}) catch null;
            if (s.thread == null) {
                s.ref_count.store(1, .release);
            }
            self.shared = s;
        }

        self.updateAll();
        return self;
    }

    pub fn deinit(self: *SysStatus) void {
        if (self.shared) |s| {
            s.running.store(false, .release);
            if (s.thread) |t| {
                t.detach();
                s.thread = null;
            }
            s.release();
            self.shared = null;
        }
    }

    pub fn tick(self: *SysStatus) void {
        self.tick_count +%= 1;

        // Fast metrics updated every tick (1s)
        self.updateCpu();
        self.updateMem();
        self.updateUptime();
        if (self.tick_count % 5 == 0) self.updateRfkill();
        self.pullAsyncData();

        // Battery, backlight, power profile every 2 seconds
        if (self.tick_count % 2 == 0) {
            self.updateBattery();
            self.updatePowerProfile();
            self.updateBacklight();
        }
    }

    pub fn updateAll(self: *SysStatus) void {
        self.updateUserHost();
        self.updateUptime();
        self.updateCpu();
        self.updateMem();
        self.updateBattery();
        self.updatePowerProfile();
        self.updateBacklight();
        self.updateRfkill();
        self.pullAsyncData();
    }

    pub fn pullAsyncData(self: *SysStatus) void {
        var mpris_snap: dbus_monitor.MizuMprisSnapshot = undefined;
        if (dbus_monitor.mizu_dbus_monitor_get_mpris(&mpris_snap)) {
            if (mpris_snap.version > 0) {
                self.mpris_state = switch (mpris_snap.mpris_state) {
                    1 => .paused,
                    2 => .playing,
                    else => .stopped,
                };
                const track_span = std.mem.span(@as([*:0]const u8, @ptrCast(&mpris_snap.mpris_track)));
                const tlen = @min(track_span.len, self.mpris_track.len);
                @memcpy(self.mpris_track[0..tlen], track_span[0..tlen]);
                self.mpris_track_len = tlen;

                const art_span = std.mem.span(@as([*:0]const u8, @ptrCast(&mpris_snap.mpris_art_url)));
                const alen = @min(art_span.len, self.mpris_art_url.len);
                @memcpy(self.mpris_art_url[0..alen], art_span[0..alen]);
                self.mpris_art_url_len = alen;
            }
        }

        const s = self.shared orelse return;
        s.lock.lock();
        defer s.lock.unlock();

        self.volume_percent = s.data.volume_percent;
        self.volume_muted = s.data.volume_muted;
        if (self.mpris_track_len == 0 and s.data.mpris_track_len > 0) {
            self.mpris_state = s.data.mpris_state;
            const mlen = @min(s.data.mpris_track_len, self.mpris_track.len);
            @memcpy(self.mpris_track[0..mlen], s.data.mpris_track[0..mlen]);
            self.mpris_track_len = mlen;
        }

        if (self.wifi_enabled) {
            const wlen = @min(s.data.wifi_ssid_len, self.wifi_ssid.len);
            @memcpy(self.wifi_ssid[0..wlen], s.data.wifi_ssid[0..wlen]);
            self.wifi_ssid_len = wlen;
        } else {
            self.wifi_ssid_len = 0;
        }

        if (self.bluetooth_enabled) {
            self.bluetooth_connected = s.data.bluetooth_connected;
            const blen = @min(s.data.bluetooth_device_len, self.bluetooth_device.len);
            @memcpy(self.bluetooth_device[0..blen], s.data.bluetooth_device[0..blen]);
            self.bluetooth_device_len = blen;
        } else {
            self.bluetooth_connected = false;
            self.bluetooth_device_len = 0;
        }
    }

    pub fn updateRfkill(self: *SysStatus) void {
        var wlan_on = true;
        var bt_found = false;
        var bt_blocked = false;

        const dir = c.opendir("/sys/class/rfkill");
        if (dir != null) {
            defer _ = c.closedir(dir);
            while (c.readdir(dir)) |entry| {
                const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
                if (std.mem.startsWith(u8, name, "rfkill")) {
                    var type_path_buf: [128]u8 = undefined;
                    const type_path = std.fmt.bufPrintZ(&type_path_buf, "/sys/class/rfkill/{s}/type", .{name}) catch continue;
                    var tbuf: [32]u8 = undefined;
                    if (readProcFile(type_path.ptr, &tbuf)) |tlen| {
                        const tstr = std.mem.trim(u8, tbuf[0..tlen], " \t\r\n");
                        if (std.mem.eql(u8, tstr, "wlan")) {
                            var soft_path_buf: [128]u8 = undefined;
                            const soft_path = std.fmt.bufPrintZ(&soft_path_buf, "/sys/class/rfkill/{s}/soft", .{name}) catch continue;
                            var sbuf: [16]u8 = undefined;
                            if (readProcFile(soft_path.ptr, &sbuf)) |slen| {
                                const sstr = std.mem.trim(u8, sbuf[0..slen], " \t\r\n");
                                if (std.mem.eql(u8, sstr, "1")) {
                                    wlan_on = false;
                                }
                            }
                        } else if (std.mem.eql(u8, tstr, "bluetooth")) {
                            bt_found = true;
                            var soft_path_buf: [128]u8 = undefined;
                            const soft_path = std.fmt.bufPrintZ(&soft_path_buf, "/sys/class/rfkill/{s}/soft", .{name}) catch continue;
                            var sbuf: [16]u8 = undefined;
                            if (readProcFile(soft_path.ptr, &sbuf)) |slen| {
                                const sstr = std.mem.trim(u8, sbuf[0..slen], " \t\r\n");
                                if (!std.mem.eql(u8, sstr, "0")) {
                                    bt_blocked = true;
                                }
                            }
                        }
                    }
                }
            }
        }
        self.wifi_enabled = wlan_on;
        if (bt_found) {
            self.bluetooth_enabled = !bt_blocked;
        }
        if (self.shared) |shared| {
            shared.wifi_enabled.store(self.wifi_enabled, .release);
            shared.bluetooth_enabled.store(self.bluetooth_enabled, .release);
        }
    }

    pub fn updatePowerProfile(self: *SysStatus) void {
        if (self.profile_manually_set) return;
        self.power_profile = detectPowerProfile();
    }

    pub fn setPowerProfile(self: *SysStatus, profile: PowerProfile) void {
        self.power_profile = profile;
        self.profile_manually_set = true;
        applyPowerProfile(profile);
    }

    pub fn applyPowerProfile(profile: PowerProfile) void {
        savePowerProfileCache(profile);

        switch (profile) {
            .power_saver => {
                spawnCmd("export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin\"; " ++
                    "powerprofilesctl set power-saver 2>/dev/null || " ++
                    "dbus-send --system --dest=net.hadess.PowerProfiles --type=method_call /net/hadess/PowerProfiles org.freedesktop.DBus.Properties.Set string:net.hadess.PowerProfiles string:ActiveProfile variant:string:power-saver 2>/dev/null || " ++
                    "(for p in cool quiet low-power; do echo $p > /sys/firmware/acpi/platform_profile 2>/dev/null && break; done) || " ++
                    "(for p in cool quiet low-power; do echo $p | sudo -n tee /sys/firmware/acpi/platform_profile 2>/dev/null && break; done) || true; " ++
                    "(echo powersave > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo powersave | sudo -n tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || true); " ++
                    "(echo power > /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo power | sudo -n tee /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference 2>/dev/null || true)");
            },
            .balanced => {
                spawnCmd("export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin\"; " ++
                    "powerprofilesctl set balanced 2>/dev/null || " ++
                    "dbus-send --system --dest=net.hadess.PowerProfiles --type=method_call /net/hadess/PowerProfiles org.freedesktop.DBus.Properties.Set string:net.hadess.PowerProfiles string:ActiveProfile variant:string:balanced 2>/dev/null || " ++
                    "(echo balanced > /sys/firmware/acpi/platform_profile 2>/dev/null) || " ++
                    "(echo balanced | sudo -n tee /sys/firmware/acpi/platform_profile 2>/dev/null) || true; " ++
                    "(echo schedutil > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo powersave > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true); " ++
                    "(echo balance_performance > /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || true)");
            },
            .performance => {
                spawnCmd("export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin\"; " ++
                    "powerprofilesctl set performance 2>/dev/null || " ++
                    "dbus-send --system --dest=net.hadess.PowerProfiles --type=method_call /net/hadess/PowerProfiles org.freedesktop.DBus.Properties.Set string:net.hadess.PowerProfiles string:ActiveProfile variant:string:performance 2>/dev/null || " ++
                    "(echo performance > /sys/firmware/acpi/platform_profile 2>/dev/null) || " ++
                    "(echo performance | sudo -n tee /sys/firmware/acpi/platform_profile 2>/dev/null) || true; " ++
                    "(echo performance > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo performance | sudo -n tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || true); " ++
                    "(echo performance > /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo performance | sudo -n tee /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference 2>/dev/null || true)");
            },
        }
    }

    pub fn detectPowerProfile() PowerProfile {
        var buf: [64]u8 = undefined;
        // 1. ACPI platform_profile
        if (readProcFile("/sys/firmware/acpi/platform_profile", &buf)) |l| {
            const s = std.mem.trim(u8, buf[0..l], " \t\r\n");
            if (std.mem.indexOf(u8, s, "low-power") != null or std.mem.indexOf(u8, s, "quiet") != null or std.mem.indexOf(u8, s, "cool") != null or std.mem.indexOf(u8, s, "saver") != null) {
                return .power_saver;
            } else if (std.mem.indexOf(u8, s, "perf") != null) {
                return .performance;
            } else if (std.mem.indexOf(u8, s, "bal") != null or std.mem.indexOf(u8, s, "default") != null) {
                return .balanced;
            }
        }

        // 2. CPU EPP
        if (readProcFile("/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference", &buf)) |l| {
            const s = std.mem.trim(u8, buf[0..l], " \t\r\n");
            if (std.mem.indexOf(u8, s, "power") != null) {
                return .power_saver;
            } else if (std.mem.indexOf(u8, s, "perf") != null) {
                return .performance;
            } else {
                return .balanced;
            }
        }

        // 3. CPU scaling_governor
        if (readProcFile("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor", &buf)) |l| {
            const s = std.mem.trim(u8, buf[0..l], " \t\r\n");
            if (std.mem.eql(u8, s, "powersave") or std.mem.eql(u8, s, "conservative")) {
                return .power_saver;
            } else if (std.mem.eql(u8, s, "performance")) {
                return .performance;
            } else {
                return .balanced;
            }
        }

        if (loadPowerProfileCache()) |cached| {
            return cached;
        }

        return .balanced;
    }

    pub fn savePowerProfileCache(profile: PowerProfile) void {
        const home = c.getenv("HOME") orelse return;
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}/.cache/mizu/power_profile", .{std.mem.span(home)}) catch return;
        const f = c.fopen(path.ptr, "wb") orelse return;
        defer _ = c.fclose(f);
        const s = switch (profile) {
            .power_saver => "power-saver\n",
            .balanced => "balanced\n",
            .performance => "performance\n",
        };
        _ = c.fwrite(s.ptr, 1, s.len, f);
    }

    pub fn loadPowerProfileCache() ?PowerProfile {
        const home = c.getenv("HOME") orelse return null;
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}/.cache/mizu/power_profile", .{std.mem.span(home)}) catch return null;
        const f = c.fopen(path.ptr, "rb") orelse return null;
        defer _ = c.fclose(f);
        var buf: [32]u8 = undefined;
        const n = c.fread(&buf, 1, buf.len - 1, f);
        if (n == 0) return null;
        buf[n] = 0;
        const s = std.mem.trim(u8, buf[0..n], " \t\r\n");
        if (std.mem.indexOf(u8, s, "saver") != null or std.mem.indexOf(u8, s, "power") != null or std.mem.indexOf(u8, s, "cool") != null or std.mem.indexOf(u8, s, "quiet") != null) {
            return .power_saver;
        } else if (std.mem.indexOf(u8, s, "perf") != null) {
            return .performance;
        } else if (std.mem.indexOf(u8, s, "bal") != null) {
            return .balanced;
        }
        return null;
    }

    pub fn setEarbudSafety(self: *SysStatus, enabled: bool) void {
        self.earbud_safety_enabled = enabled;
        saveEarbudSafetyCache(enabled);
        if (self.shared) |s| {
            s.earbud_safety_enabled.store(enabled, .release);
        }
    }

    pub fn saveEarbudSafetyCache(enabled: bool) void {
        const home = c.getenv("HOME") orelse return;
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}/.cache/mizu/earbud_safety", .{std.mem.span(home)}) catch return;
        const f = c.fopen(path.ptr, "wb") orelse return;
        defer _ = c.fclose(f);
        const s: []const u8 = if (enabled) "1\n" else "0\n";
        _ = c.fwrite(s.ptr, 1, s.len, f);
    }

    pub fn loadEarbudSafetyCache() ?bool {
        const home = c.getenv("HOME") orelse return null;
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}/.cache/mizu/earbud_safety", .{std.mem.span(home)}) catch return null;
        const f = c.fopen(path.ptr, "rb") orelse return null;
        defer _ = c.fclose(f);
        var buf: [16]u8 = undefined;
        const n = c.fread(&buf, 1, buf.len - 1, f);
        if (n == 0) return null;
        buf[n] = 0;
        const s = std.mem.trim(u8, buf[0..n], " \t\r\n");
        if (std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "true")) return true;
        if (std.mem.eql(u8, s, "0") or std.mem.eql(u8, s, "false")) return false;
        return null;
    }

    pub fn isHeadphoneOrEarbud(name: []const u8) bool {
        var lower_buf: [128]u8 = undefined;
        const len = @min(name.len, lower_buf.len);
        for (name[0..len], 0..) |ch, i| {
            lower_buf[i] = std.ascii.toLower(ch);
        }
        const lower = lower_buf[0..len];

        // Bluetooth sink
        if (std.mem.indexOf(u8, lower, "bluez") != null) {
            if (std.mem.indexOf(u8, lower, "speaker") != null) return false;
            return true;
        }

        // Wired / USB / other headphones or earbuds
        if (std.mem.indexOf(u8, lower, "headphone") != null) return true;
        if (std.mem.indexOf(u8, lower, "headset") != null) return true;
        if (std.mem.indexOf(u8, lower, "earbud") != null) return true;
        if (std.mem.indexOf(u8, lower, "earphone") != null) return true;
        if (std.mem.indexOf(u8, lower, "in-ear") != null) return true;
        if (std.mem.indexOf(u8, lower, "airpod") != null) return true;
        if (std.mem.indexOf(u8, lower, "buds") != null) return true;
        if (std.mem.indexOf(u8, lower, " ear") != null) return true;
        if (std.mem.indexOf(u8, lower, "ear ") != null) return true;

        return false;
    }

    fn updateUserHost(self: *SysStatus) void {
        const user = if (c.getenv("USER")) |u| std.mem.span(u) else "user";
        var host_buf: [64]u8 = undefined;
        _ = c.gethostname(&host_buf, host_buf.len);
        const host = std.mem.sliceTo(&host_buf, 0);

        var out_buf: [64]u8 = undefined;
        const res = std.fmt.bufPrint(&out_buf, "{s}@{s}", .{ user, host }) catch user;
        const copy_len = @min(res.len, self.user_host.len);
        @memcpy(self.user_host[0..copy_len], res[0..copy_len]);
        self.user_host_len = copy_len;
    }

    fn updateUptime(self: *SysStatus) void {
        var buf: [64]u8 = undefined;
        const len = readProcFile("/proc/uptime", &buf) orelse return;
        const slice = buf[0..len];
        var end_idx: usize = 0;
        while (end_idx < slice.len and slice[end_idx] != ' ' and slice[end_idx] != '.') {
            end_idx += 1;
        }
        if (end_idx == 0) return;
        const total_sec = std.fmt.parseInt(u64, slice[0..end_idx], 10) catch return;

        const hours = total_sec / 3600;
        const mins = (total_sec % 3600) / 60;

        var str_buf: [32]u8 = undefined;
        const res = if (hours > 0)
            std.fmt.bufPrint(&str_buf, "up {d}h {d}m", .{ hours, mins }) catch return
        else
            std.fmt.bufPrint(&str_buf, "up {d}m", .{mins}) catch return;

        @memcpy(self.uptime_str[0..res.len], res);
        self.uptime_len = res.len;
    }

    fn updateCpu(self: *SysStatus) void {
        var buf: [512]u8 = undefined;
        const len = readProcFile("/proc/stat", &buf) orelse return;
        const content = buf[0..len];

        // Format: cpu user nice system idle iowait irq softirq steal guest guest_nice
        if (!std.mem.startsWith(u8, content, "cpu ")) return;

        var it = std.mem.tokenizeAny(u8, content[4..], " \t\r\n");
        var fields: [10]u64 = [_]u64{0} ** 10;
        var count: usize = 0;
        while (it.next()) |token| {
            if (count >= 10) break;
            fields[count] = std.fmt.parseInt(u64, token, 10) catch 0;
            count += 1;
        }

        if (count < 4) return;

        const idle = fields[3] + fields[4]; // idle + iowait
        var total: u64 = 0;
        for (fields[0..count]) |val| {
            total += val;
        }

        if (self.prev_total > 0 and total > self.prev_total) {
            const diff_idle = idle - self.prev_idle;
            const diff_total = total - self.prev_total;
            if (diff_total > 0) {
                const usage = 100 - (diff_idle * 100 / diff_total);
                self.cpu_percent = @min(100, @as(u32, @intCast(usage)));
            }
        }

        self.prev_idle = idle;
        self.prev_total = total;
    }

    fn updateMem(self: *SysStatus) void {
        var buf: [1024]u8 = undefined;
        const len = readProcFile("/proc/meminfo", &buf) orelse return;
        const content = buf[0..len];

        var total_kb: u64 = 0;
        var avail_kb: u64 = 0;

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "MemTotal:")) {
                total_kb = proc_file.parseKbValue(line[9..]);
            } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
                avail_kb = proc_file.parseKbValue(line[13..]);
            }
            if (total_kb > 0 and avail_kb > 0) break;
        }

        if (total_kb > 0 and total_kb >= avail_kb) {
            const used_kb = total_kb - avail_kb;
            self.mem_used_gib = @as(f32, @floatFromInt(used_kb)) / (1024.0 * 1024.0);
            self.mem_total_gib = @as(f32, @floatFromInt(total_kb)) / (1024.0 * 1024.0);
        }
    }

    fn findBatteryDevice(self: *SysStatus) ?[]const u8 {
        if (self.battery_device_len > 0) {
            return self.battery_device[0..self.battery_device_len];
        }

        const common_bats = [_][]const u8{ "BAT0", "BAT1", "BAT2", "BATT" };
        var test_buf: [32]u8 = undefined;
        for (common_bats) |bat_name| {
            var path_buf: [128:0]u8 = undefined;
            if (std.fmt.bufPrintZ(&path_buf, "/sys/class/power_supply/{s}/capacity", .{bat_name})) |p| {
                if (readProcFile(p.ptr, &test_buf) != null) {
                    const copy_len = @min(bat_name.len, self.battery_device.len);
                    @memcpy(self.battery_device[0..copy_len], bat_name[0..copy_len]);
                    self.battery_device_len = copy_len;
                    return self.battery_device[0..copy_len];
                }
            } else |_| {}
        }

        const dir = c.opendir("/sys/class/power_supply");
        if (dir == null) return null;
        defer _ = c.closedir(dir);

        while (c.readdir(dir)) |entry| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

            var path_buf: [128:0]u8 = undefined;
            if (std.fmt.bufPrintZ(&path_buf, "/sys/class/power_supply/{s}/capacity", .{name})) |p| {
                if (readProcFile(p.ptr, &test_buf) != null) {
                    const copy_len = @min(name.len, self.battery_device.len);
                    @memcpy(self.battery_device[0..copy_len], name[0..copy_len]);
                    self.battery_device_len = copy_len;
                    return self.battery_device[0..copy_len];
                }
            } else |_| {}
        }

        return null;
    }

    fn updateBattery(self: *SysStatus) void {
        var buf: [64]u8 = undefined;

        self.ac_online = false;
        const ac_paths = [_][*:0]const u8{
            "/sys/class/power_supply/ACAD/online",
            "/sys/class/power_supply/AC/online",
            "/sys/class/power_supply/ADP1/online",
            "/sys/class/power_supply/ADP0/online",
        };
        for (ac_paths) |p| {
            if (readProcFile(p, &buf)) |l| {
                const s = std.mem.trim(u8, buf[0..l], " \t\r\n");
                if (std.mem.eql(u8, s, "1")) {
                    self.ac_online = true;
                    break;
                }
            }
        }

        if (!self.ac_online) {
            if (c.opendir("/sys/class/power_supply")) |dir| {
                defer _ = c.closedir(dir);
                while (c.readdir(dir)) |entry| {
                    const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
                    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                    var path_buf: [128:0]u8 = undefined;
                    if (std.fmt.bufPrintZ(&path_buf, "/sys/class/power_supply/{s}/online", .{name})) |p| {
                        if (readProcFile(p.ptr, &buf)) |l| {
                            const s = std.mem.trim(u8, buf[0..l], " \t\r\n");
                            if (std.mem.eql(u8, s, "1")) {
                                self.ac_online = true;
                                break;
                            }
                        }
                    } else |_| {}
                }
            }
        }

        // Try UPower telemetry first for battery time estimates.
        var telem: c.MizuBatteryTelemetry = undefined;
        if (c.mizu_upower_get_telemetry(&telem) == 0 and telem.has_battery != 0) {
            self.has_battery = true;
            self.bat_capacity = @min(100, @as(u32, @intFromFloat(telem.percentage + 0.5)));
            self.energy_rate_watts = telem.energy_rate;
            switch (telem.state) {
                1 => self.bat_status = .charging,
                2 => self.bat_status = .discharging,
                4 => self.bat_status = .full,
                else => {
                    if (self.ac_online) {
                        self.bat_status = if (self.bat_capacity >= 98) .full else .charging;
                    } else {
                        self.bat_status = .discharging;
                    }
                },
            }
            if (self.bat_status == .charging and telem.time_to_full > 0) {
                self.bat_seconds_remaining = telem.time_to_full;
            } else if (self.bat_status == .discharging and telem.time_to_empty > 0) {
                self.bat_seconds_remaining = telem.time_to_empty;
            } else {
                self.bat_seconds_remaining = null;
            }
            return;
        }

        // 2. Sysfs fallback if UPower is not running
        const dev = self.findBatteryDevice() orelse {
            self.has_battery = false;
            self.bat_seconds_remaining = null;
            return;
        };

        var cap_path_buf: [128:0]u8 = undefined;
        const cap_path = std.fmt.bufPrintZ(&cap_path_buf, "/sys/class/power_supply/{s}/capacity", .{dev}) catch {
            self.has_battery = false;
            self.bat_seconds_remaining = null;
            return;
        };

        var cap_buf: [64]u8 = undefined;
        const cap_len = readProcFile(cap_path.ptr, &cap_buf) orelse {
            self.has_battery = false;
            self.battery_device_len = 0;
            self.bat_seconds_remaining = null;
            return;
        };

        self.has_battery = true;
        const trimmed_cap = std.mem.trim(u8, cap_buf[0..cap_len], " \t\r\n");
        self.bat_capacity = std.fmt.parseInt(u32, trimmed_cap, 10) catch 100;

        var stat_path_buf: [128:0]u8 = undefined;
        var stat_buf: [64]u8 = undefined;
        var stat_len: ?usize = null;
        if (std.fmt.bufPrintZ(&stat_path_buf, "/sys/class/power_supply/{s}/status", .{dev})) |sp| {
            stat_len = readProcFile(sp.ptr, &stat_buf);
        } else |_| {}

        if (stat_len) |l| {
            const s = std.mem.trim(u8, stat_buf[0..l], " \t\r\n");
            if (std.mem.eql(u8, s, "Charging")) {
                self.bat_status = .charging;
            } else if (std.mem.eql(u8, s, "Full")) {
                self.bat_status = .full;
            } else if (std.mem.eql(u8, s, "Discharging")) {
                self.bat_status = .discharging;
            } else if (std.mem.eql(u8, s, "Not charging") or std.mem.eql(u8, s, "Unknown")) {
                // AC plugged in but not actively charging (e.g., battery full)
                if (self.ac_online) {
                    self.bat_status = .charging;
                } else {
                    self.bat_status = .discharging;
                }
            } else if (self.ac_online) {
                if (self.bat_capacity >= 98) {
                    self.bat_status = .full;
                } else {
                    self.bat_status = .charging;
                }
            } else {
                self.bat_status = .discharging;
            }
        } else if (self.ac_online) {
            self.bat_status = if (self.bat_capacity >= 98) .full else .charging;
        } else {
            self.bat_status = .discharging;
        }

        // Sysfs estimate from energy/charge and power/current
        var e_now_buf: [32]u8 = undefined;
        var e_full_buf: [32]u8 = undefined;
        var p_now_buf: [32]u8 = undefined;
        var e_path_buf: [128:0]u8 = undefined;
        var p_path_buf: [128:0]u8 = undefined;
        var ef_path_buf: [128:0]u8 = undefined;

        var energy_now: u64 = 0;
        var energy_full: u64 = 0;
        var power_now: u64 = 0;

        if (std.fmt.bufPrintZ(&e_path_buf, "/sys/class/power_supply/{s}/energy_now", .{dev})) |ep| {
            if (readProcFile(ep.ptr, &e_now_buf)) |l| {
                energy_now = std.fmt.parseInt(u64, std.mem.trim(u8, e_now_buf[0..l], " \t\r\n"), 10) catch 0;
            }
        } else |_| {}
        if (std.fmt.bufPrintZ(&ef_path_buf, "/sys/class/power_supply/{s}/energy_full", .{dev})) |efp| {
            if (readProcFile(efp.ptr, &e_full_buf)) |l| {
                energy_full = std.fmt.parseInt(u64, std.mem.trim(u8, e_full_buf[0..l], " \t\r\n"), 10) catch 0;
            }
        } else |_| {}
        if (std.fmt.bufPrintZ(&p_path_buf, "/sys/class/power_supply/{s}/power_now", .{dev})) |pp| {
            if (readProcFile(pp.ptr, &p_now_buf)) |l| {
                power_now = std.fmt.parseInt(u64, std.mem.trim(u8, p_now_buf[0..l], " \t\r\n"), 10) catch 0;
            }
        } else |_| {}

        if (energy_now == 0) {
            if (std.fmt.bufPrintZ(&e_path_buf, "/sys/class/power_supply/{s}/charge_now", .{dev})) |cp| {
                if (readProcFile(cp.ptr, &e_now_buf)) |l| {
                    energy_now = std.fmt.parseInt(u64, std.mem.trim(u8, e_now_buf[0..l], " \t\r\n"), 10) catch 0;
                }
            } else |_| {}
        }
        if (energy_full == 0) {
            if (std.fmt.bufPrintZ(&ef_path_buf, "/sys/class/power_supply/{s}/charge_full", .{dev})) |cfp| {
                if (readProcFile(cfp.ptr, &e_full_buf)) |l| {
                    energy_full = std.fmt.parseInt(u64, std.mem.trim(u8, e_full_buf[0..l], " \t\r\n"), 10) catch 0;
                }
            } else |_| {}
        }
        if (power_now == 0) {
            if (std.fmt.bufPrintZ(&p_path_buf, "/sys/class/power_supply/{s}/current_now", .{dev})) |cp| {
                if (readProcFile(cp.ptr, &p_now_buf)) |l| {
                    power_now = std.fmt.parseInt(u64, std.mem.trim(u8, p_now_buf[0..l], " \t\r\n"), 10) catch 0;
                }
            } else |_| {}
        }

        // Battery saver: if low battery (<30%) and on battery, enable saver
        if (self.has_battery and self.bat_capacity <= 30 and !self.ac_online and self.bat_status == .discharging and !self.profile_manually_set) {
            self.setPowerProfile(.power_saver);
            spawnCmd("(echo 1 > /tmp/mizu-eye-comfort 2>/dev/null || true)");
            spawnCmd("echo 60 > /tmp/mizu-display-refresh-rate 2>/dev/null || true");
        }

        if (power_now > 0) {
            if (self.bat_status == .discharging and energy_now > 0) {
                self.bat_seconds_remaining = @intCast((energy_now * 3600) / power_now);
            } else if (self.bat_status == .charging and energy_full > energy_now) {
                self.bat_seconds_remaining = @intCast(((energy_full - energy_now) * 3600) / power_now);
            } else {
                self.bat_seconds_remaining = null;
            }
        } else {
            self.bat_seconds_remaining = null;
        }
    }

    pub fn formatDuration(buf: []u8, seconds: i64) []const u8 {
        if (seconds <= 0) return "";
        const hours = @divTrunc(seconds, 3600);
        const minutes = @divTrunc(@rem(seconds, 3600), 60);
        if (hours > 0 and minutes > 0) {
            return std.fmt.bufPrint(buf, "{d}h {d}m", .{ hours, minutes }) catch "";
        } else if (hours > 0) {
            return std.fmt.bufPrint(buf, "{d}h", .{hours}) catch "";
        } else if (minutes > 0) {
            return std.fmt.bufPrint(buf, "{d}m", .{minutes}) catch "";
        } else {
            return "1m";
        }
    }

    pub fn formatBatteryStatus(self: *const SysStatus, buf: []u8) []const u8 {
        if (!self.has_battery) {
            return if (self.ac_online) "AC Power" else "No Battery";
        }

        switch (self.bat_status) {
            .full => {
                return "Fully charged";
            },
            .charging => {
                if (self.bat_seconds_remaining) |sec| {
                    if (sec > 0) {
                        var time_buf: [32]u8 = undefined;
                        const t_str = formatDuration(&time_buf, sec);
                        if (t_str.len > 0) {
                            return std.fmt.bufPrint(buf, "Charging · {s} until full", .{t_str}) catch "Charging";
                        }
                    }
                }
                return std.fmt.bufPrint(buf, "Charging · {d}%", .{self.bat_capacity}) catch "Charging";
            },
            .discharging => {
                if (self.bat_seconds_remaining) |sec| {
                    if (sec > 0) {
                        var time_buf: [32]u8 = undefined;
                        const t_str = formatDuration(&time_buf, sec);
                        if (t_str.len > 0) {
                            return std.fmt.bufPrint(buf, "{d}% · {s} remaining", .{ self.bat_capacity, t_str }) catch "Discharging";
                        }
                    }
                }
                return std.fmt.bufPrint(buf, "{d}%", .{self.bat_capacity}) catch "Discharging";
            },
            .none => {
                return std.fmt.bufPrint(buf, "{d}%", .{self.bat_capacity}) catch "";
            },
        }
    }

    pub fn formatUptime(self: *const SysStatus, buf: []u8) []const u8 {
        var pbuf: [64]u8 = undefined;
        const len = readProcFile("/proc/uptime", &pbuf) orelse {
            if (self.uptime_len > 0) return self.uptime_str[0..self.uptime_len];
            return "Uptime · 0m";
        };
        const slice = pbuf[0..len];
        var end_idx: usize = 0;
        while (end_idx < slice.len and slice[end_idx] != ' ' and slice[end_idx] != '.') {
            end_idx += 1;
        }
        if (end_idx == 0) return "Uptime · 0m";
        const total_sec = std.fmt.parseInt(u64, slice[0..end_idx], 10) catch return "Uptime · 0m";

        const days = total_sec / 86400;
        const hours = (total_sec % 86400) / 3600;
        const mins = (total_sec % 3600) / 60;

        if (days > 0) {
            return std.fmt.bufPrint(buf, "Uptime · {d}d {d}h", .{ days, hours }) catch "Uptime";
        } else if (hours > 0) {
            return std.fmt.bufPrint(buf, "Uptime · {d}h {d}m", .{ hours, mins }) catch "Uptime";
        } else {
            return std.fmt.bufPrint(buf, "Uptime · {d}m", .{mins}) catch "Uptime";
        }
    }

    fn findBacklightDevice(self: *SysStatus) ?[]const u8 {
        if (self.backlight_device_len > 0) {
            return self.backlight_device[0..self.backlight_device_len];
        }
        const dir = c.opendir("/sys/class/backlight");
        if (dir == null) return null;
        defer _ = c.closedir(dir);

        while (c.readdir(dir)) |entry| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            const copy_len = @min(name.len, self.backlight_device.len);
            @memcpy(self.backlight_device[0..copy_len], name[0..copy_len]);
            self.backlight_device_len = copy_len;
            return self.backlight_device[0..copy_len];
        }
        return null;
    }

    pub fn updateBacklight(self: *SysStatus) void {
        const dev = self.findBacklightDevice() orelse {
            self.has_backlight = false;
            return;
        };

        var cur_path_buf: [128]u8 = undefined;
        const cur_path = std.fmt.bufPrintZ(&cur_path_buf, "/sys/class/backlight/{s}/brightness", .{dev}) catch return;
        var buf: [64]u8 = undefined;
        const cur_len = readProcFile(cur_path.ptr, &buf) orelse {
            self.has_backlight = false;
            return;
        };
        const cur_val = std.fmt.parseInt(u32, std.mem.trim(u8, buf[0..cur_len], " \t\r\n"), 10) catch 0;

        var max_path_buf: [128]u8 = undefined;
        const max_path = std.fmt.bufPrintZ(&max_path_buf, "/sys/class/backlight/{s}/max_brightness", .{dev}) catch return;
        const max_len = readProcFile(max_path.ptr, &buf) orelse {
            self.has_backlight = false;
            return;
        };
        const max_val = std.fmt.parseInt(u32, std.mem.trim(u8, buf[0..max_len], " \t\r\n"), 10) catch 0;

        if (max_val > 0) {
            self.has_backlight = true;
            self.backlight_percent = @min(100, (cur_val * 100) / max_val);
        }
    }

    pub fn updateVolume(self: *SysStatus) void {
        self.pullAsyncData();
    }

    pub fn updateMpris(self: *SysStatus) void {
        self.pullAsyncData();
    }

    pub fn updateNetwork(self: *SysStatus) void {
        self.updateRfkill();
        self.pullAsyncData();
    }

    pub fn updateBluetooth(self: *SysStatus) void {
        self.updateRfkill();
        self.pullAsyncData();
    }

    // Interactive control actions
    pub fn stepVolume(self: *SysStatus, delta: i32) void {
        const cur: i32 = @intCast(self.volume_percent);
        const next: u32 = @intCast(@min(200, @max(0, cur + delta)));
        self.volume_percent = next;
        if (self.shared) |s| {
            s.lock.lock();
            s.data.volume_percent = next;
            s.lock.unlock();
        }
        var cmd_buf: [128]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "wpctl set-volume -l 2.0 @DEFAULT_AUDIO_SINK@ {d}% 2>/dev/null || pactl set-sink-volume @DEFAULT_SINK@ {d}% 2>/dev/null || true", .{ next, next }) catch return;
        spawnCmd(cmd);
    }

    pub fn setVolume(self: *SysStatus, percent: u32) void {
        const clamped = @min(200, percent);
        self.volume_percent = clamped;
        if (self.shared) |s| {
            s.lock.lock();
            s.data.volume_percent = clamped;
            s.lock.unlock();
        }
        var cmd_buf: [128]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "wpctl set-volume -l 2.0 @DEFAULT_AUDIO_SINK@ {d}% 2>/dev/null || pactl set-sink-volume @DEFAULT_SINK@ {d}% 2>/dev/null || true", .{ clamped, clamped }) catch return;
        spawnCmd(cmd);
    }

    pub fn toggleVolumeMute(self: *SysStatus) void {
        self.volume_muted = !self.volume_muted;
        if (self.shared) |s| {
            s.lock.lock();
            s.data.volume_muted = self.volume_muted;
            s.lock.unlock();
        }
        if (self.volume_muted) {
            spawnCmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ 1 2>/dev/null || pactl set-sink-mute @DEFAULT_SINK@ 1 2>/dev/null || pamixer -m 2>/dev/null || amixer set Master mute 2>/dev/null || true");
        } else {
            spawnCmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 2>/dev/null || pactl set-sink-mute @DEFAULT_SINK@ 0 2>/dev/null || pamixer -u 2>/dev/null || amixer set Master unmute 2>/dev/null || true");
        }
    }

    pub fn setBrightness(self: *SysStatus, percent: u32) void {
        if (!self.has_backlight) return;
        const clamped = @min(100, percent);
        self.backlight_percent = clamped;
        var cmd_buf: [64]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "brightnessctl set {d}%", .{clamped}) catch return;
        spawnCmd(cmd);
    }

    pub fn toggleWifi(self: *SysStatus) void {
        self.wifi_enabled = !self.wifi_enabled;
        if (!self.wifi_enabled) {
            self.wifi_ssid_len = 0;
        }
        if (self.shared) |s| {
            s.wifi_enabled.store(self.wifi_enabled, .release);
            s.lock.lock();
            s.data.wifi_ssid_len = if (self.wifi_enabled) s.data.wifi_ssid_len else 0;
            s.lock.unlock();
        }
        if (self.wifi_enabled) {
            spawnCmd("rfkill unblock wlan 2>/dev/null; nmcli radio wifi on 2>/dev/null || true");
        } else {
            spawnCmd("nmcli radio wifi off 2>/dev/null; rfkill block wlan 2>/dev/null || true");
        }
    }

    pub fn toggleBluetooth(self: *SysStatus) void {
        self.bluetooth_enabled = !self.bluetooth_enabled;
        if (!self.bluetooth_enabled) {
            self.bluetooth_connected = false;
            self.bluetooth_device_len = 0;
        }
        if (self.shared) |s| {
            s.bluetooth_enabled.store(self.bluetooth_enabled, .release);
            s.lock.lock();
            s.data.bluetooth_connected = self.bluetooth_connected;
            s.data.bluetooth_device_len = self.bluetooth_device_len;
            s.lock.unlock();
        }
        if (self.bluetooth_enabled) {
            spawnCmd("rfkill unblock bluetooth 2>/dev/null; bluetoothctl power on 2>/dev/null || true");
        } else {
            spawnCmd("bluetoothctl power off 2>/dev/null; rfkill block bluetooth 2>/dev/null || true");
        }
    }
};

pub fn monotonicMs() i64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.tv_sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.tv_nsec)), 1_000_000);
}

const ToolAvailability = struct {
    wpctl: bool,
    playerctl: bool,
    iw: bool,
    iwgetid: bool,
    nmcli: bool,
    bluetoothctl: bool,
};

fn commandAvailable(name: []const u8) bool {
    const path_env = c.getenv("PATH") orelse return false;
    var dirs = std.mem.splitScalar(u8, std.mem.span(path_env), ':');
    while (dirs.next()) |dir| {
        if (dir.len == 0) continue;
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ dir, name }) catch continue;
        if (c.access(path.ptr, c.X_OK) == 0) return true;
    }
    return false;
}

fn detectTools() ToolAvailability {
    return .{
        .wpctl = commandAvailable("wpctl"),
        .playerctl = commandAvailable("playerctl"),
        .iw = commandAvailable("iw"),
        .iwgetid = commandAvailable("iwgetid"),
        .nmcli = commandAvailable("nmcli"),
        .bluetoothctl = commandAvailable("bluetoothctl"),
    };
}

fn queryVolume(vol: *u32, muted: *bool) void {
    const pipe = c.popen("wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null", "r") orelse return;
    defer _ = c.pclose(pipe);

    var buf: [64]u8 = undefined;
    const n = c.fread(&buf, 1, buf.len - 1, pipe);
    if (n == 0) return;
    buf[n] = 0;
    const s = buf[0..n];

    if (std.mem.indexOf(u8, s, "[MUTED]") != null) {
        muted.* = true;
    } else {
        muted.* = false;
    }

    if (std.mem.indexOf(u8, s, "Volume:")) |idx| {
        const rem = std.mem.trim(u8, s[idx + 7 ..], " \t\r\n");
        var end_idx: usize = 0;
        while (end_idx < rem.len and (std.ascii.isDigit(rem[end_idx]) or rem[end_idx] == '.')) {
            end_idx += 1;
        }
        if (end_idx > 0) {
            const vol_float = std.fmt.parseFloat(f32, rem[0..end_idx]) catch 0.5;
            vol.* = @intFromFloat(@min(200.0, vol_float * 100.0));
        }
    }
}

fn queryMpris(state: *MprisState, track_buf: *[128]u8, track_len: *usize) void {
    const pipe = c.popen("playerctl metadata --format '{{status}}:::{{artist}} - {{title}}' 2>/dev/null", "r") orelse {
        state.* = .stopped;
        track_len.* = 0;
        return;
    };
    defer _ = c.pclose(pipe);

    var buf: [256]u8 = undefined;
    const n = c.fread(&buf, 1, buf.len - 1, pipe);
    if (n == 0) {
        state.* = .stopped;
        track_len.* = 0;
        return;
    }
    buf[n] = 0;
    const s = std.mem.trim(u8, buf[0..n], " \t\r\n");

    if (std.mem.indexOf(u8, s, ":::")) |sep| {
        const status_str = s[0..sep];
        const track_str = std.mem.trim(u8, s[sep + 3 ..], " \t-");

        if (std.mem.eql(u8, status_str, "Playing")) {
            state.* = .playing;
        } else if (std.mem.eql(u8, status_str, "Paused")) {
            state.* = .paused;
        } else {
            state.* = .stopped;
        }

        const copy_len = @min(track_str.len, track_buf.len);
        @memcpy(track_buf[0..copy_len], track_str[0..copy_len]);
        track_len.* = copy_len;
    } else {
        state.* = .stopped;
        track_len.* = 0;
    }
}

fn queryWifiSsid(tools: ToolAvailability, ssid_buf: *[64]u8, ssid_len: *usize) void {
    ssid_len.* = 0;

    if (tools.iw) {
        const pipe = c.popen("iw dev 2>/dev/null", "r") orelse return;
        defer _ = c.pclose(pipe);
        var buf: [2048]u8 = undefined;
        const n = c.fread(&buf, 1, buf.len - 1, pipe);
        if (n > 0) {
            buf[n] = 0;
            var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (!std.mem.startsWith(u8, trimmed, "ssid ")) continue;
                const ssid = std.mem.trim(u8, trimmed[5..], " \t\r");
                if (ssid.len == 0) continue;
                const copy_len = @min(ssid.len, ssid_buf.len);
                @memcpy(ssid_buf[0..copy_len], ssid[0..copy_len]);
                ssid_len.* = copy_len;
                return;
            }
        }
    }

    if (tools.iwgetid) {
        const pipe = c.popen("iwgetid -r 2>/dev/null", "r") orelse return;
        defer _ = c.pclose(pipe);
        var buf: [128]u8 = undefined;
        const n = c.fread(&buf, 1, buf.len - 1, pipe);
        if (n > 0) {
            buf[n] = 0;
            const ssid = std.mem.trim(u8, buf[0..n], " \t\r\n");
            if (ssid.len > 0) {
                const copy_len = @min(ssid.len, ssid_buf.len);
                @memcpy(ssid_buf[0..copy_len], ssid[0..copy_len]);
                ssid_len.* = copy_len;
                return;
            }
        }
    }

    if (!tools.nmcli) return;
    const pipe = c.popen("nmcli -t -f name,type connection show --active 2>/dev/null", "r") orelse return;
    defer _ = c.pclose(pipe);
    var buf: [512]u8 = undefined;
    const n = c.fread(&buf, 1, buf.len - 1, pipe);
    if (n == 0) return;
    buf[n] = 0;

    var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (!std.mem.endsWith(u8, trimmed, ":802-11-wireless")) continue;
        const sep = std.mem.lastIndexOfScalar(u8, trimmed, ':') orelse continue;
        const ssid = trimmed[0..sep];
        if (ssid.len == 0) continue;
        const copy_len = @min(ssid.len, ssid_buf.len);
        @memcpy(ssid_buf[0..copy_len], ssid[0..copy_len]);
        ssid_len.* = copy_len;
        return;
    }
}

fn queryBluetooth(tools: ToolAvailability, connected: *bool, dev_buf: *[64]u8, dev_len: *usize) void {
    connected.* = false;
    dev_len.* = 0;
    if (!tools.bluetoothctl) return;

    const pipe = c.popen("bluetoothctl devices Connected 2>/dev/null", "r");
    if (pipe != null) {
        defer _ = c.pclose(pipe);
        var buf: [128]u8 = undefined;
        const n = c.fread(&buf, 1, buf.len - 1, pipe);
        if (n > 0) {
            buf[n] = 0;
            const line = std.mem.trim(u8, buf[0..n], " \t\r\n");
            if (std.mem.startsWith(u8, line, "Device ")) {
                connected.* = true;
                if (line.len > 25) {
                    const dev_name = std.mem.trim(u8, line[25..], " \t\r\n");
                    const copy_len = @min(dev_name.len, dev_buf.len);
                    @memcpy(dev_buf[0..copy_len], dev_name[0..copy_len]);
                    dev_len.* = copy_len;
                }
            }
        }
    }
}

fn getDefaultSinkName(buf: *[128]u8) ?[]const u8 {
    const pipe = c.popen("pactl get-default-sink 2>/dev/null", "r") orelse {
        const wp_pipe = c.popen("wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null | grep 'node.name' | head -1 | cut -d'\"' -f2", "r") orelse return null;
        defer _ = c.pclose(wp_pipe);
        const n = c.fread(buf, 1, buf.len - 1, wp_pipe);
        if (n == 0) return null;
        buf[n] = 0;
        const s = std.mem.trim(u8, buf[0..n], " \t\r\n");
        return if (s.len > 0) s else null;
    };
    defer _ = c.pclose(pipe);
    const n = c.fread(buf, 1, buf.len - 1, pipe);
    if (n == 0) return null;
    buf[n] = 0;
    const s = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return if (s.len > 0) s else null;
}

fn workerLoop(shared: *SharedWorkerState) void {
    defer shared.release();
    const tools = detectTools();
    var last_volume: i64 = 0;
    var last_mpris: i64 = 0;
    var last_wifi: i64 = 0;
    var last_bluetooth: i64 = 0;
    var last_sink: [128]u8 = [_]u8{0} ** 128;
    var last_sink_len: usize = 0;
    var last_audio_check: i64 = 0;
    var initialized_sink = false;

    const volume_interval_ms: i64 = 1000;
    const mpris_interval_ms: i64 = 1000;
    const network_interval_ms: i64 = 5000;
    const safety_interval_ms: i64 = 500;

    while (shared.running.load(.acquire)) {
        const now = monotonicMs();
        var snap = blk: {
            shared.lock.lock();
            defer shared.lock.unlock();
            break :blk shared.data;
        };
        var changed = false;

        if (dbus_monitor.mizu_dbus_monitor_check_network_dirty()) {
            last_wifi = 0;
        }
        if (dbus_monitor.mizu_dbus_monitor_check_bluetooth_dirty()) {
            last_bluetooth = 0;
            last_audio_check = 0;
        }

        if (tools.wpctl and now - last_volume >= volume_interval_ms) {
            queryVolume(&snap.volume_percent, &snap.volume_muted);
            last_volume = now;
            changed = true;
        }

        // Earphone safety volume monitoring
        if (now - last_audio_check >= safety_interval_ms) {
            last_audio_check = now;
            var sink_buf: [128]u8 = undefined;
            if (getDefaultSinkName(&sink_buf)) |cur_sink| {
                if (!initialized_sink) {
                    initialized_sink = true;
                    const clen = @min(cur_sink.len, last_sink.len);
                    @memcpy(last_sink[0..clen], cur_sink[0..clen]);
                    last_sink_len = clen;
                } else {
                    const prev_sink = last_sink[0..last_sink_len];
                    if (!std.mem.eql(u8, cur_sink, prev_sink)) {
                        if (shared.earbud_safety_enabled.load(.acquire) and SysStatus.isHeadphoneOrEarbud(cur_sink)) {
                            var cur_vol: u32 = snap.volume_percent;
                            var cur_mute: bool = snap.volume_muted;
                            queryVolume(&cur_vol, &cur_mute);
                            if (cur_vol > 20) {
                                spawnCmd("wpctl set-volume -l 2.0 @DEFAULT_AUDIO_SINK@ 20% 2>/dev/null || pactl set-sink-volume @DEFAULT_SINK@ 20% 2>/dev/null || true");
                                snap.volume_percent = 20;
                                snap.volume_muted = false;
                                last_volume = now;
                                changed = true;
                            }
                        }
                        const clen = @min(cur_sink.len, last_sink.len);
                        @memcpy(last_sink[0..clen], cur_sink[0..clen]);
                        last_sink_len = clen;
                    }
                }
            }
        }

        if (tools.playerctl and now - last_mpris >= mpris_interval_ms) {
            var snap_mpris: dbus_monitor.MizuMprisSnapshot = undefined;
            if (!dbus_monitor.mizu_dbus_monitor_get_mpris(&snap_mpris) or snap_mpris.version == 0) {
                queryMpris(&snap.mpris_state, &snap.mpris_track, &snap.mpris_track_len);
                changed = true;
            }
            last_mpris = now;
        }

        if (now - last_wifi >= network_interval_ms) {
            if (shared.wifi_enabled.load(.acquire)) {
                queryWifiSsid(tools, &snap.wifi_ssid, &snap.wifi_ssid_len);
            } else {
                snap.wifi_ssid_len = 0;
            }
            last_wifi = now;
            changed = true;
        }

        if (now - last_bluetooth >= network_interval_ms) {
            if (shared.bluetooth_enabled.load(.acquire)) {
                queryBluetooth(tools, &snap.bluetooth_connected, &snap.bluetooth_device, &snap.bluetooth_device_len);
            } else {
                snap.bluetooth_connected = false;
                snap.bluetooth_device_len = 0;
            }
            last_bluetooth = now;
            changed = true;
        }

        if (changed) {
            shared.lock.lock();
            defer shared.lock.unlock();
            shared.data = snap;
        }

        if (!shared.running.load(.acquire)) break;
        _ = c.usleep(100_000);
    }
}

test "SysStatus stepVolume and toggleVolumeMute state synchronization" {
    var status = SysStatus.init(std.testing.allocator);
    defer status.deinit();

    status.volume_percent = 50;
    status.volume_muted = false;

    // Step volume up
    status.stepVolume(5);
    try std.testing.expectEqual(@as(u32, 55), status.volume_percent);

    // Step volume down
    status.stepVolume(-10);
    try std.testing.expectEqual(@as(u32, 45), status.volume_percent);

    // Mute toggle
    status.toggleVolumeMute();
    try std.testing.expect(status.volume_muted);
    if (status.shared) |s| {
        s.lock.lock();
        try std.testing.expect(s.data.volume_muted);
        s.lock.unlock();
    }

    // Toggle unmute
    status.toggleVolumeMute();
    try std.testing.expect(!status.volume_muted);
    if (status.shared) |s| {
        s.lock.lock();
        try std.testing.expect(!s.data.volume_muted);
        s.lock.unlock();
    }
}

test "SysStatus batteryIcon and updateBattery" {
    try std.testing.expectEqualStrings("󰂄", batteryIcon(100, true));
    try std.testing.expectEqualStrings("󰂊", batteryIcon(81, true));
    try std.testing.expectEqualStrings("󰂂", batteryIcon(81, false));
    try std.testing.expectEqualStrings("󰂎", batteryIcon(5, false));
    try std.testing.expectEqualStrings("󰢜", batteryIcon(15, true));

    var status = SysStatus.init(std.testing.allocator);
    defer status.deinit();

    status.updateBattery();
    if (status.has_battery) {
        try std.testing.expect(status.bat_capacity <= 100);
    }
}

test "isHeadphoneOrEarbud detection and earbud safety settings" {
    // Should NOT match speakers / internal audio
    try std.testing.expect(!SysStatus.isHeadphoneOrEarbud("alsa_output.pci-0000_06_00.6.HiFi__Speaker__sink"));
    try std.testing.expect(!SysStatus.isHeadphoneOrEarbud("alsa_output.pci-0000_01_00.1.hdmi-stereo"));
    try std.testing.expect(!SysStatus.isHeadphoneOrEarbud("bluez_output.11_22_33_44_55_66.speaker"));

    // Should match wired headphones / headsets / earbuds
    try std.testing.expect(SysStatus.isHeadphoneOrEarbud("alsa_output.pci-0000_06_00.6.HiFi__Headphones__sink"));
    try std.testing.expect(SysStatus.isHeadphoneOrEarbud("alsa_output.usb-Generic_USB_Headset-00.analog-stereo"));
    try std.testing.expect(SysStatus.isHeadphoneOrEarbud("analog-output-headphones"));

    // Should match bluetooth earphones / earbuds / headsets
    try std.testing.expect(SysStatus.isHeadphoneOrEarbud("bluez_output.B0_38_E2_FB_21_DC.1"));
    try std.testing.expect(SysStatus.isHeadphoneOrEarbud("AirPods Pro"));
    try std.testing.expect(SysStatus.isHeadphoneOrEarbud("Galaxy Buds2 Pro"));
    try std.testing.expect(SysStatus.isHeadphoneOrEarbud("Sony WH-1000XM4 Headset"));
    try std.testing.expect(SysStatus.isHeadphoneOrEarbud("Nothing Ear (2)"));

    var status = SysStatus.init(std.testing.allocator);
    defer status.deinit();

    status.setEarbudSafety(false);
    try std.testing.expect(!status.earbud_safety_enabled);
    if (status.shared) |s| {
        try std.testing.expect(!s.earbud_safety_enabled.load(.acquire));
    }

    status.setEarbudSafety(true);
    try std.testing.expect(status.earbud_safety_enabled);
    if (status.shared) |s| {
        try std.testing.expect(s.earbud_safety_enabled.load(.acquire));
    }
}
