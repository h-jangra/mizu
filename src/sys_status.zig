const std = @import("std");
const c = @import("c.zig").c;

pub const BatteryStatus = enum {
    none,
    charging,
    discharging,
    full,
};

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

pub fn spawnCmd(cmd: []const u8) void {
    const pid = c.fork();
    if (pid == 0) {
        _ = c.setsid();
        const devnull = c.open("/dev/null", c.O_WRONLY);
        if (devnull >= 0) {
            _ = c.dup2(devnull, 1);
            _ = c.dup2(devnull, 2);
            _ = c.close(devnull);
        }
        var c_buf: [2048]u8 = undefined;
        if (cmd.len < c_buf.len) {
            @memcpy(c_buf[0..cmd.len], cmd);
            c_buf[cmd.len] = 0;
            _ = c.execl("/bin/sh", "sh", "-c", c_buf[0..cmd.len :0].ptr, @as(?*anyopaque, null));
        } else {
            const mem = c.malloc(cmd.len + 1);
            if (mem != null) {
                const ptr: [*]u8 = @ptrCast(mem);
                @memcpy(ptr[0..cmd.len], cmd);
                ptr[cmd.len] = 0;
                _ = c.execl("/bin/sh", "sh", "-c", ptr, @as(?*anyopaque, null));
            }
        }
        c.exit(1);
    }
}

pub const SysStatus = struct {
    allocator: std.mem.Allocator,

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
    power_profile: PowerProfile = .balanced,
    profile_manually_set: bool = false,

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
        self.updateAll();
        return self;
    }

    pub fn tick(self: *SysStatus) void {
        self.tick_count +%= 1;

        // Fast metrics updated every tick (1s)
        self.updateCpu();
        self.updateMem();
        self.updateUptime();
        self.updateVolume();

        // Battery, backlight, network & bluetooth every 2 seconds
        if (self.tick_count % 2 == 0) {
            self.updateBattery();
            self.updatePowerProfile();
            self.updateBacklight();
            self.updateNetwork();
            self.updateBluetooth();
        }

        // MPRIS every 3 seconds
        if (self.tick_count % 3 == 0) {
            self.updateMpris();
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
        self.updateVolume();
        self.updateMpris();
        self.updateNetwork();
        self.updateBluetooth();
    }

    pub fn updatePowerProfile(self: *SysStatus) void {
        if (self.profile_manually_set) return;

        var buf: [64]u8 = undefined;
        // 1. ACPI platform_profile
        if (readProcFile("/sys/firmware/acpi/platform_profile", &buf)) |l| {
            const s = std.mem.trim(u8, buf[0..l], " \t\r\n");
            if (std.mem.indexOf(u8, s, "low-power") != null or std.mem.indexOf(u8, s, "quiet") != null or std.mem.indexOf(u8, s, "cool") != null or std.mem.indexOf(u8, s, "saver") != null) {
                self.power_profile = .power_saver;
                return;
            } else if (std.mem.indexOf(u8, s, "perf") != null) {
                self.power_profile = .performance;
                return;
            } else if (std.mem.indexOf(u8, s, "bal") != null or std.mem.indexOf(u8, s, "default") != null) {
                self.power_profile = .balanced;
                return;
            }
        }

        // 2. CPU EPP
        if (readProcFile("/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference", &buf)) |l| {
            const s = std.mem.trim(u8, buf[0..l], " \t\r\n");
            if (std.mem.indexOf(u8, s, "power") != null) {
                self.power_profile = .power_saver;
                return;
            } else if (std.mem.indexOf(u8, s, "perf") != null) {
                self.power_profile = .performance;
                return;
            } else {
                self.power_profile = .balanced;
                return;
            }
        }

        // 3. CPU scaling_governor
        if (readProcFile("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor", &buf)) |l| {
            const s = std.mem.trim(u8, buf[0..l], " \t\r\n");
            if (std.mem.eql(u8, s, "powersave") or std.mem.eql(u8, s, "conservative")) {
                self.power_profile = .power_saver;
                return;
            } else if (std.mem.eql(u8, s, "performance")) {
                self.power_profile = .performance;
                return;
            } else {
                self.power_profile = .balanced;
                return;
            }
        }
    }

    pub fn setPowerProfile(self: *SysStatus, profile: PowerProfile) void {
        self.power_profile = profile;
        self.profile_manually_set = true;
        savePowerProfileCache(profile);

        switch (profile) {
            .power_saver => {
                spawnCmd(
                    "export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin\"; " ++
                    "powerprofilesctl set power-saver 2>/dev/null || " ++
                    "dbus-send --system --dest=net.hadess.PowerProfiles --type=method_call /net/hadess/PowerProfiles org.freedesktop.DBus.Properties.Set string:net.hadess.PowerProfiles string:ActiveProfile variant:string:power-saver 2>/dev/null || " ++
                    "(for p in cool quiet low-power; do echo $p > /sys/firmware/acpi/platform_profile 2>/dev/null && break; done) || " ++
                    "(for p in cool quiet low-power; do echo $p | sudo -n tee /sys/firmware/acpi/platform_profile 2>/dev/null && break; done) || true; " ++
                    "(echo powersave > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo powersave | sudo -n tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || true); " ++
                    "(echo power > /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo power | sudo -n tee /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference 2>/dev/null || true)"
                );
            },
            .balanced => {
                spawnCmd(
                    "export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin\"; " ++
                    "powerprofilesctl set balanced 2>/dev/null || " ++
                    "dbus-send --system --dest=net.hadess.PowerProfiles --type=method_call /net/hadess/PowerProfiles org.freedesktop.DBus.Properties.Set string:net.hadess.PowerProfiles string:ActiveProfile variant:string:balanced 2>/dev/null || " ++
                    "(echo balanced > /sys/firmware/acpi/platform_profile 2>/dev/null) || " ++
                    "(echo balanced | sudo -n tee /sys/firmware/acpi/platform_profile 2>/dev/null) || true; " ++
                    "(echo schedutil > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo powersave > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true); " ++
                    "(echo balance_performance > /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || true)"
                );
            },
            .performance => {
                spawnCmd(
                    "export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin\"; " ++
                    "powerprofilesctl set performance 2>/dev/null || " ++
                    "dbus-send --system --dest=net.hadess.PowerProfiles --type=method_call /net/hadess/PowerProfiles org.freedesktop.DBus.Properties.Set string:net.hadess.PowerProfiles string:ActiveProfile variant:string:performance 2>/dev/null || " ++
                    "(echo performance > /sys/firmware/acpi/platform_profile 2>/dev/null) || " ++
                    "(echo performance | sudo -n tee /sys/firmware/acpi/platform_profile 2>/dev/null) || true; " ++
                    "(echo performance > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo performance | sudo -n tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || true); " ++
                    "(echo performance > /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo performance | sudo -n tee /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference 2>/dev/null || true)"
                );
            },
        }
    }

    fn savePowerProfileCache(profile: PowerProfile) void {
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

    fn loadPowerProfileCache() ?PowerProfile {
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

    fn readProcFile(path: [*:0]const u8, buf: []u8) ?usize {
        const f = c.fopen(path, "rb") orelse return null;
        defer _ = c.fclose(f);
        const bytes_read = c.fread(buf.ptr, 1, buf.len - 1, f);
        if (bytes_read == 0) return null;
        buf[bytes_read] = 0;
        return bytes_read;
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
                total_kb = parseKbValue(line[9..]);
            } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
                avail_kb = parseKbValue(line[13..]);
            }
            if (total_kb > 0 and avail_kb > 0) break;
        }

        if (total_kb > 0 and total_kb >= avail_kb) {
            const used_kb = total_kb - avail_kb;
            self.mem_used_gib = @as(f32, @floatFromInt(used_kb)) / (1024.0 * 1024.0);
            self.mem_total_gib = @as(f32, @floatFromInt(total_kb)) / (1024.0 * 1024.0);
        }
    }

    fn parseKbValue(str: []const u8) u64 {
        const trimmed = std.mem.trim(u8, str, " \t\r\n");
        var num_len: usize = 0;
        while (num_len < trimmed.len and std.ascii.isDigit(trimmed[num_len])) {
            num_len += 1;
        }
        if (num_len == 0) return 0;
        return std.fmt.parseInt(u64, trimmed[0..num_len], 10) catch 0;
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

        var cap_len = readProcFile("/sys/class/power_supply/BAT0/capacity", &buf);
        var stat_len: ?usize = null;
        if (cap_len != null) {
            stat_len = readProcFile("/sys/class/power_supply/BAT0/status", &buf);
        } else {
            cap_len = readProcFile("/sys/class/power_supply/BAT1/capacity", &buf);
            if (cap_len != null) {
                stat_len = readProcFile("/sys/class/power_supply/BAT1/status", &buf);
            }
        }

        if (cap_len) |l| {
            self.has_battery = true;
            const trimmed = std.mem.trim(u8, buf[0..l], " \t\r\n");
            self.bat_capacity = std.fmt.parseInt(u32, trimmed, 10) catch 100;
        } else {
            self.has_battery = false;
            return;
        }

        if (stat_len) |l| {
            const s = std.mem.trim(u8, buf[0..l], " \t\r\n");
            if (std.mem.eql(u8, s, "Charging")) {
                self.bat_status = .charging;
            } else if (std.mem.eql(u8, s, "Full")) {
                self.bat_status = .full;
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
        // Query wpctl get-volume @DEFAULT_AUDIO_SINK@
        const pipe = c.popen("wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null", "r") orelse return;
        defer _ = c.pclose(pipe);

        var buf: [64]u8 = undefined;
        const n = c.fread(&buf, 1, buf.len - 1, pipe);
        if (n == 0) return;
        buf[n] = 0;
        const s = buf[0..n];

        // Format: Volume: 0.50 [MUTED]
        if (std.mem.indexOf(u8, s, "[MUTED]") != null) {
            self.volume_muted = true;
        } else {
            self.volume_muted = false;
        }

        if (std.mem.indexOf(u8, s, "Volume:")) |idx| {
            const rem = std.mem.trim(u8, s[idx + 7 ..], " \t\r\n");
            var end_idx: usize = 0;
            while (end_idx < rem.len and (std.ascii.isDigit(rem[end_idx]) or rem[end_idx] == '.')) {
                end_idx += 1;
            }
            if (end_idx > 0) {
                const vol_float = std.fmt.parseFloat(f32, rem[0..end_idx]) catch 0.5;
                self.volume_percent = @intFromFloat(@min(100.0, vol_float * 100.0));
            }
        }
    }

    fn updateMpris(self: *SysStatus) void {
        const pipe = c.popen("playerctl metadata --format '{{status}}:::{{artist}} - {{title}}' 2>/dev/null", "r") orelse {
            self.mpris_state = .stopped;
            self.mpris_track_len = 0;
            return;
        };
        defer _ = c.pclose(pipe);

        var buf: [256]u8 = undefined;
        const n = c.fread(&buf, 1, buf.len - 1, pipe);
        if (n == 0) {
            self.mpris_state = .stopped;
            self.mpris_track_len = 0;
            return;
        }
        buf[n] = 0;
        const s = std.mem.trim(u8, buf[0..n], " \t\r\n");

        if (std.mem.indexOf(u8, s, ":::")) |sep| {
            const status_str = s[0..sep];
            const track_str = std.mem.trim(u8, s[sep + 3 ..], " \t-");

            if (std.mem.eql(u8, status_str, "Playing")) {
                self.mpris_state = .playing;
            } else if (std.mem.eql(u8, status_str, "Paused")) {
                self.mpris_state = .paused;
            } else {
                self.mpris_state = .stopped;
            }

            const copy_len = @min(track_str.len, self.mpris_track.len);
            @memcpy(self.mpris_track[0..copy_len], track_str[0..copy_len]);
            self.mpris_track_len = copy_len;
        } else {
            self.mpris_state = .stopped;
            self.mpris_track_len = 0;
        }
    }

    fn updateNetwork(self: *SysStatus) void {
        var wlan_on = true;
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
                        }
                    }
                }
            }
        }
        self.wifi_enabled = wlan_on;

        self.wifi_ssid_len = 0;
        if (self.wifi_enabled) {
            const pipe = c.popen("nmcli -t -f active,ssid dev wifi 2>/dev/null | grep '^yes:'", "r") orelse return;
            defer _ = c.pclose(pipe);

            var buf: [128]u8 = undefined;
            const n = c.fread(&buf, 1, buf.len - 1, pipe);
            if (n > 4) {
                buf[n] = 0;
                const line = std.mem.trim(u8, buf[0..n], " \t\r\n");
                if (std.mem.startsWith(u8, line, "yes:")) {
                    const ssid = std.mem.trim(u8, line[4..], " \t\r\n");
                    const copy_len = @min(ssid.len, self.wifi_ssid.len);
                    @memcpy(self.wifi_ssid[0..copy_len], ssid[0..copy_len]);
                    self.wifi_ssid_len = copy_len;
                }
            }
        }
    }

    fn updateBluetooth(self: *SysStatus) void {
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
                        if (std.mem.eql(u8, tstr, "bluetooth")) {
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
        if (bt_found) {
            self.bluetooth_enabled = !bt_blocked;
        }
        self.bluetooth_connected = false;
        self.bluetooth_device_len = 0;

        if (self.bluetooth_enabled) {
            const pipe = c.popen("bluetoothctl devices Connected 2>/dev/null", "r");
            if (pipe != null) {
                defer _ = c.pclose(pipe);
                var buf: [128]u8 = undefined;
                const n = c.fread(&buf, 1, buf.len - 1, pipe);
                if (n > 0) {
                    buf[n] = 0;
                    const line = std.mem.trim(u8, buf[0..n], " \t\r\n");
                    if (std.mem.startsWith(u8, line, "Device ")) {
                        self.bluetooth_connected = true;
                        if (line.len > 25) {
                            const dev_name = std.mem.trim(u8, line[25..], " \t\r\n");
                            const copy_len = @min(dev_name.len, self.bluetooth_device.len);
                            @memcpy(self.bluetooth_device[0..copy_len], dev_name[0..copy_len]);
                            self.bluetooth_device_len = copy_len;
                        }
                    }
                }
            }
        }
    }

    // Interactive control actions
    pub fn setVolume(self: *SysStatus, percent: u32) void {
        const clamped = @min(100, percent);
        self.volume_percent = clamped;
        self.volume_muted = false;
        var cmd_buf: [64]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "wpctl set-volume @DEFAULT_AUDIO_SINK@ {d}%", .{clamped}) catch return;
        spawnCmd(cmd);
    }

    pub fn toggleVolumeMute(self: *SysStatus) void {
        self.volume_muted = !self.volume_muted;
        spawnCmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle");
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
        if (self.wifi_enabled) {
            self.wifi_enabled = false;
            self.wifi_ssid_len = 0;
            spawnCmd("nmcli radio wifi off 2>/dev/null || rfkill block wlan 2>/dev/null || true");
        } else {
            self.wifi_enabled = true;
            spawnCmd("nmcli radio wifi on 2>/dev/null || rfkill unblock wlan 2>/dev/null || true");
        }
    }

    pub fn toggleBluetooth(self: *SysStatus) void {
        if (self.bluetooth_enabled) {
            self.bluetooth_enabled = false;
            self.bluetooth_connected = false;
            spawnCmd("rfkill block bluetooth 2>/dev/null; bluetoothctl power off 2>/dev/null || true");
        } else {
            self.bluetooth_enabled = true;
            spawnCmd("rfkill unblock bluetooth 2>/dev/null; bluetoothctl power on 2>/dev/null || true");
        }
    }
};
