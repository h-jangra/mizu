const std = @import("std");
const c = @import("c");
const async = @import("../../core/async.zig");
const renderer = @import("../../core/renderer.zig");
const sys_status = @import("../../services/system_status.zig");
const theme = @import("../../core/theme.zig");
const ui_mod = @import("../../core/ui.zig");
const types = @import("types.zig");

const Action = types.Action;
const QsLayout = types.QsLayout;

pub const BluetoothItem = struct {
    mac: [32]u8 = @splat(0),
    mac_len: usize = 0,
    name: [64]u8 = @splat(0),
    name_len: usize = 0,
    connected: bool = false,
    icon: []const u8 = "󰂯",
};

pub const State = struct {
    items: std.ArrayList(BluetoothItem),
    scan_worker: BtScanWorker = .{},
    connect_worker: BtConnectWorker = .{},
    failed_mac: [32]u8 = @splat(0),
    failed_mac_len: usize = 0,
    error_msg: [128]u8 = @splat(0),
    error_len: usize = 0,
    status: async.OpStatus = .idle,
    connect_mac: [32]u8 = @splat(0),
    connect_mac_len: usize = 0,
    scan_status: async.OpStatus = .idle,
    last_auto_scan: i64 = 0,

    pub fn init() State {
        return .{ .items = std.ArrayList(BluetoothItem).empty };
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }
};

pub const BtScanWorker = struct {
    running: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    status: std.atomic.Value(async.OpStatus) = .init(.idle),
    lock: sys_status.SpinLock = .{},
    wake_fd: c_int = -1,
    items: [64]BluetoothItem = @splat(BluetoothItem{}),
    count: usize = 0,

    pub fn run(worker: *BtScanWorker) void {
        worker.status.store(.scanning, .release);
        var local_items: [64]BluetoothItem = @splat(BluetoothItem{});
        var local_count: usize = 0;

        var connected_macs: [16][18]u8 = undefined;
        var connected_count: usize = 0;

        if (c.popen("bluetoothctl devices Connected 2>/dev/null", "r")) |pipe| {
            defer _ = c.pclose(pipe);
            var buf: [4096]u8 = undefined;
            var total: usize = 0;
            while (total < buf.len - 1) {
                const n = c.fread(buf[total..].ptr, 1, buf.len - 1 - total, pipe);
                if (n == 0) break;
                total += n;
            }
            buf[total] = 0;
            var line_it = std.mem.splitScalar(u8, buf[0..total], '\n');
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
            var buf: [8192]u8 = undefined;
            var total: usize = 0;
            while (total < buf.len - 1) {
                const n = c.fread(buf[total..].ptr, 1, buf.len - 1 - total, pipe);
                if (n == 0) break;
                total += n;
            }
            buf[total] = 0;
            var line_it = std.mem.splitScalar(u8, buf[0..total], '\n');
            while (line_it.next()) |raw_line| {
                const line = std.mem.trim(u8, raw_line, " \t\r");
                if (std.mem.startsWith(u8, line, "Device ")) {
                    const after = line[7..];
                    if (after.len >= 17) {
                        const mac_str = after[0..17];
                        var name_str = if (after.len > 18) std.mem.trim(u8, after[18..], " \t") else "";
                        if (name_str.len == 0) {
                            name_str = mac_str;
                        }

                        // Avoid duplicate devices
                        var already_added = false;
                        for (local_items[0..local_count]) |exist| {
                            if (exist.mac_len == mac_str.len and std.mem.eql(u8, exist.mac[0..exist.mac_len], mac_str)) {
                                already_added = true;
                                break;
                            }
                        }
                        if (already_added) continue;

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
                            std.mem.indexOf(u8, lower_name, "airpods") != null or
                            std.mem.indexOf(u8, lower_name, "pixel buds") != null or
                            std.mem.indexOf(u8, lower_name, "audio") != null)
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
                                .mac = @splat(0),
                                .mac_len = @min(mac_str.len, 32),
                                .name = @splat(0),
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
    mac: [32]u8 = @splat(0),
    mac_len: usize = 0,
    connect: bool = true,
    error_msg: [128]u8 = @splat(0),
    error_len: usize = 0,

    pub fn run(worker: *BtConnectWorker) void {
        worker.status.store(if (worker.connect) .connecting else .disconnecting, .release);
        worker.running.store(true, .release);

        const mac = worker.mac[0..worker.mac_len];
        var mac_z: [33]u8 = @splat(0);
        @memcpy(mac_z[0..mac.len], mac);
        mac_z[mac.len] = 0;

        var err_buf: [128]u8 = @splat(0);
        var success = sys_status.dbus_monitor.mizu_dbus_monitor_bt_connect(&mac_z, worker.connect, &err_buf, err_buf.len);

        if (!success) {
            // If direct D-Bus returned an error, attempt clean bluetoothctl as fallback
            var cmd_buf: [256]u8 = undefined;
            const cmd_slice = if (worker.connect)
                std.fmt.bufPrintSentinel(&cmd_buf, "bluetoothctl --timeout 15 connect {s} 2>&1", .{mac}, 0) catch null
            else
                std.fmt.bufPrintSentinel(&cmd_buf, "bluetoothctl --timeout 8 disconnect {s} 2>&1", .{mac}, 0) catch null;

            if (cmd_slice) |cmd_z| {
                if (c.popen(cmd_z.ptr, "r")) |pipe| {
                    var out_buf: [2048]u8 = undefined;
                    var total_read: usize = 0;
                    while (total_read < out_buf.len - 1) {
                        const n = c.fread(out_buf[total_read..].ptr, 1, out_buf.len - 1 - total_read, pipe);
                        if (n == 0) break;
                        total_read += n;
                    }
                    out_buf[total_read] = 0;
                    _ = c.pclose(pipe);

                    if (worker.connect) {
                        if (std.mem.indexOf(u8, out_buf[0..total_read], "Connection successful") != null or
                            std.mem.indexOf(u8, out_buf[0..total_read], "Connected: yes") != null)
                        {
                            success = true;
                        }
                    } else {
                        if (std.mem.indexOf(u8, out_buf[0..total_read], "Successful disconnected") != null or
                            std.mem.indexOf(u8, out_buf[0..total_read], "Connected: no") != null)
                        {
                            success = true;
                        }
                    }
                }
            }
        }

        if (!success) {
            const err_len = std.mem.len(@as([*:0]const u8, @ptrCast(&err_buf)));
            if (err_len > 0) {
                const clen = @min(err_len, worker.error_msg.len);
                @memcpy(worker.error_msg[0..clen], err_buf[0..clen]);
                worker.error_len = clen;
            }
        }

        if (success) {
            worker.status.store(.success, .release);
        } else {
            worker.status.store(.failed, .release);
            if (worker.error_len == 0) {
                const fallback = if (worker.connect) "Failed to connect device." else "Failed to disconnect device.";
                const clen = @min(fallback.len, worker.error_msg.len);
                @memcpy(worker.error_msg[0..clen], fallback[0..clen]);
                worker.error_len = clen;
            }
        }

        worker.done.store(true, .release);
        worker.running.store(false, .release);
        if (worker.wake_fd >= 0) {
            const val: u64 = 1;
            _ = c.write(worker.wake_fd, &val, @sizeOf(u64));
        }
    }
};

pub fn triggerScan(panel: anytype) void {
    if (panel.bluetooth.scan_worker.running.load(.acquire)) return;
    panel.bluetooth.scan_status = .scanning;
    panel.bluetooth.scan_worker.done.store(false, .release);
    panel.bluetooth.scan_worker.running.store(true, .release);
    panel.bluetooth.scan_worker.wake_fd = panel.wake_fd;
    if (panel.wake_fd >= 0) {
        _ = async.spawnTask(BtScanWorker, &panel.bluetooth.scan_worker, panel.wake_fd) catch {
            panel.bluetooth.scan_worker.running.store(false, .release);
            panel.bluetooth.scan_status = .failed;
        };
    } else {
        panel.bluetooth.scan_worker.running.store(false, .release);
        panel.bluetooth.scan_status = .idle;
    }
    panel.is_scanning = true;
    panel.scan_ticks = 45;
}

pub fn autoScan(panel: anytype, now: i64, bt_dirty: bool) void {
    if (panel.view_mode != .bluetooth_menu) return;
    if (panel.bluetooth.scan_worker.running.load(.acquire) or panel.bluetooth.connect_worker.running.load(.acquire)) return;
    if (bt_dirty or (now - panel.bluetooth.last_auto_scan >= 2000)) {
        panel.bluetooth.last_auto_scan = now;
        triggerScan(panel);
    }
}

pub fn anyWorkerActive(panel: anytype) bool {
    return panel.bluetooth.scan_worker.running.load(.acquire) or panel.bluetooth.connect_worker.running.load(.acquire);
}

pub fn drain(panel: anytype) bool {
    var changed = false;

    if (panel.bluetooth.scan_worker.done.load(.acquire)) {
        panel.bluetooth.scan_worker.lock.lock();
        defer panel.bluetooth.scan_worker.lock.unlock();
        panel.bluetooth.items.clearRetainingCapacity();
        for (panel.bluetooth.scan_worker.items[0..panel.bluetooth.scan_worker.count]) |it| {
            panel.bluetooth.items.append(panel.allocator, it) catch break;
        }
        panel.bluetooth.scan_worker.done.store(false, .release);
        panel.bluetooth.scan_status = panel.bluetooth.scan_worker.status.load(.acquire);
        changed = true;
    }

    return changed;
}

pub fn checkStatus(panel: anytype) bool {
    if (!panel.bluetooth.connect_worker.done.load(.acquire)) return false;

    const st = panel.bluetooth.connect_worker.status.load(.acquire);
    panel.bluetooth.status = st;
    if (st == .success) {
        const mac = panel.bluetooth.connect_mac[0..panel.bluetooth.connect_mac_len];
        var connected_name: [64]u8 = @splat(0);
        var connected_name_len: usize = 0;
        for (panel.bluetooth.items.items) |*it| {
            if (it.mac_len == mac.len and std.mem.eql(u8, it.mac[0..it.mac_len], mac)) {
                it.connected = panel.bluetooth.connect_worker.connect;
                if (panel.bluetooth.connect_worker.connect) {
                    connected_name_len = it.name_len;
                    @memcpy(connected_name[0..it.name_len], it.name[0..it.name_len]);
                }
            }
        }
        if (panel.bluetooth.connect_worker.connect and connected_name_len > 0) {
            if (panel.sys.earbud_safety_enabled and sys_status.SysStatus.isHeadphoneOrEarbud(connected_name[0..connected_name_len])) {
                if (panel.sys.volume_percent > 20) {
                    sys_status.spawnCmd("wpctl set-volume -l 2.0 @DEFAULT_AUDIO_SINK@ 20% 2>/dev/null || pactl set-sink-volume @DEFAULT_SINK@ 20% 2>/dev/null || true");
                    panel.sys.volume_percent = 20;
                    panel.sys.volume_muted = false;
                    panel.sys.updateVolume();
                }
            }
        }
        panel.bluetooth.connect_mac_len = 0;
        panel.bluetooth.failed_mac_len = 0;
        panel.bluetooth.error_len = 0;
        panel.triggerBtScan();
        panel.triggerAudioScan();
    } else {
        const flen = @min(panel.bluetooth.connect_worker.mac_len, panel.bluetooth.failed_mac.len);
        @memcpy(panel.bluetooth.failed_mac[0..flen], panel.bluetooth.connect_worker.mac[0..flen]);
        panel.bluetooth.failed_mac_len = flen;
        const elen = @min(panel.bluetooth.connect_worker.error_len, panel.bluetooth.error_msg.len);
        @memcpy(panel.bluetooth.error_msg[0..elen], panel.bluetooth.connect_worker.error_msg[0..elen]);
        panel.bluetooth.error_len = elen;
        panel.bluetooth.connect_mac_len = 0;
    }
    panel.bluetooth.connect_worker.done.store(false, .release);
    panel.bluetooth.connect_worker.running.store(false, .release);
    return true;
}

pub fn scan(panel: anytype) void {
    panel.bluetooth.items.clearRetainingCapacity();

    // 1. Get connected device MACs
    var connected_macs = std.ArrayList([18]u8).empty;
    defer connected_macs.deinit(panel.allocator);

    if (c.popen("bluetoothctl devices Connected 2>/dev/null", "r")) |pipe| {
        defer _ = c.pclose(pipe);
        var buf: [4096]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len - 1) {
            const n = c.fread(buf[total..].ptr, 1, buf.len - 1 - total, pipe);
            if (n == 0) break;
            total += n;
        }
        buf[total] = 0;
        var line_it = std.mem.splitScalar(u8, buf[0..total], '\n');
        while (line_it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (std.mem.startsWith(u8, line, "Device ")) {
                const after = line[7..];
                if (after.len >= 17) {
                    var mac: [18]u8 = @splat(0);
                    @memcpy(mac[0..17], after[0..17]);
                    connected_macs.append(panel.allocator, mac) catch {};
                }
            }
        }
    }

    // 2. Get all paired/known devices
    if (c.popen("bluetoothctl devices 2>/dev/null", "r")) |pipe| {
        defer _ = c.pclose(pipe);
        var buf: [8192]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len - 1) {
            const n = c.fread(buf[total..].ptr, 1, buf.len - 1 - total, pipe);
            if (n == 0) break;
            total += n;
        }
        buf[total] = 0;
        var line_it = std.mem.splitScalar(u8, buf[0..total], '\n');
        while (line_it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (std.mem.startsWith(u8, line, "Device ")) {
                const after = line[7..];
                if (after.len >= 17) {
                    const mac_str = after[0..17];
                    var name_str = if (after.len > 18) std.mem.trim(u8, after[18..], " \t") else "";
                    if (name_str.len == 0) {
                        name_str = mac_str;
                    }

                    // Avoid duplicate devices
                    var already_added = false;
                    for (panel.bluetooth.items.items) |exist| {
                        if (exist.mac_len == mac_str.len and std.mem.eql(u8, exist.mac[0..exist.mac_len], mac_str)) {
                            already_added = true;
                            break;
                        }
                    }
                    if (already_added) continue;

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
                        std.mem.indexOf(u8, lower_name, "airpods") != null or
                        std.mem.indexOf(u8, lower_name, "pixel buds") != null or
                        std.mem.indexOf(u8, lower_name, "audio") != null)
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
                        .mac = @splat(0),
                        .mac_len = @min(mac_str.len, 32),
                        .name = @splat(0),
                        .name_len = @min(name_str.len, 64),
                        .connected = is_connected,
                        .icon = dev_icon,
                    };
                    @memcpy(item.mac[0..item.mac_len], mac_str[0..item.mac_len]);
                    @memcpy(item.name[0..item.name_len], name_str[0..item.name_len]);

                    panel.bluetooth.items.append(panel.allocator, item) catch break;
                }
            }
        }
    }

    // Sort: connected first, then by name
    std.mem.sort(BluetoothItem, panel.bluetooth.items.items, {}, struct {
        fn lessThan(_: void, a: BluetoothItem, b: BluetoothItem) bool {
            if (a.connected != b.connected) return a.connected;
            return std.mem.order(u8, a.name[0..a.name_len], b.name[0..b.name_len]) == .lt;
        }
    }.lessThan);
}

pub fn handleAction(panel: anytype, action: Action) bool {
    switch (action) {
        .toggle_bluetooth => {
            panel.sys.toggleBluetooth();
            if (panel.sys.bluetooth_enabled) {
                if (panel.view_mode == .bluetooth_menu) {
                    sys_status.dbus_monitor.mizu_dbus_monitor_start_bt_discovery();
                }
                panel.is_scanning = true;
                panel.scan_ticks = 45;
                panel.triggerBtScan();
            } else {
                sys_status.dbus_monitor.mizu_dbus_monitor_stop_bt_discovery();
                panel.bluetooth.items.clearRetainingCapacity();
            }
            return true;
        },
        .open_bluetooth_menu => {
            panel.view_mode = .bluetooth_menu;
            panel.scroll_offset = 0;
            sys_status.dbus_monitor.mizu_dbus_monitor_start_bt_discovery();
            panel.is_scanning = true;
            panel.scan_ticks = 45;
            panel.triggerBtScan();
            return true;
        },
        .remove_bluetooth => |idx| {
            if (idx < panel.bluetooth.items.items.len) {
                const item = panel.bluetooth.items.items[idx];
                const mac = item.mac[0..item.mac_len];
                var mac_z: [33]u8 = @splat(0);
                @memcpy(mac_z[0..mac.len], mac);
                mac_z[mac.len] = 0;
                _ = sys_status.dbus_monitor.mizu_dbus_monitor_bt_remove(&mac_z);

                var cmd_buf: [128]u8 = undefined;
                if (std.fmt.bufPrintSentinel(&cmd_buf, "bluetoothctl remove {s} 2>/dev/null || true", .{mac}, 0)) |cmd| {
                    sys_status.spawnCmd(cmd);
                } else |_| {}

                // Instantly reflect device removal in UI state without closing panel
                _ = panel.bluetooth.items.orderedRemove(idx);
                return true;
            }
        },
        .disconnect_bluetooth => |idx| {
            if (idx < panel.bluetooth.items.items.len) {
                const item = panel.bluetooth.items.items[idx];
                if (!item.connected) return true;
                if (panel.bluetooth.connect_worker.running.load(.acquire)) return true;
                const mac = item.mac[0..item.mac_len];
                const clen = @min(mac.len, panel.bluetooth.connect_mac.len);
                @memcpy(panel.bluetooth.connect_mac[0..clen], mac[0..clen]);
                panel.bluetooth.connect_mac_len = clen;
                panel.bluetooth.failed_mac_len = 0;
                panel.bluetooth.status = .disconnecting;
                panel.bluetooth.connect_worker.done.store(false, .release);
                panel.bluetooth.connect_worker.running.store(true, .release);
                panel.bluetooth.connect_worker.wake_fd = panel.wake_fd;
                @memcpy(panel.bluetooth.connect_worker.mac[0..clen], mac[0..clen]);
                panel.bluetooth.connect_worker.mac_len = clen;
                panel.bluetooth.connect_worker.connect = false;
                panel.is_scanning = true;
                panel.scan_ticks = 60;
                _ = async.spawnTask(BtConnectWorker, &panel.bluetooth.connect_worker, panel.wake_fd) catch {
                    panel.bluetooth.status = .failed;
                    panel.bluetooth.connect_worker.running.store(false, .release);
                };
            }
            return true;
        },
        .select_bluetooth => |idx| {
            if (idx < panel.bluetooth.items.items.len) {
                const item = panel.bluetooth.items.items[idx];
                if (item.connected) return true;
                if (panel.bluetooth.connect_worker.running.load(.acquire)) return true;
                const mac = item.mac[0..item.mac_len];
                const clen = @min(mac.len, panel.bluetooth.connect_mac.len);
                @memcpy(panel.bluetooth.connect_mac[0..clen], mac[0..clen]);
                panel.bluetooth.connect_mac_len = clen;
                panel.bluetooth.failed_mac_len = 0;
                panel.bluetooth.status = .connecting;
                panel.bluetooth.connect_worker.done.store(false, .release);
                panel.bluetooth.connect_worker.running.store(true, .release);
                panel.bluetooth.connect_worker.wake_fd = panel.wake_fd;
                @memcpy(panel.bluetooth.connect_worker.mac[0..clen], mac[0..clen]);
                panel.bluetooth.connect_worker.mac_len = clen;
                panel.bluetooth.connect_worker.connect = true;
                panel.is_scanning = true;
                panel.scan_ticks = 60;
                _ = async.spawnTask(BtConnectWorker, &panel.bluetooth.connect_worker, panel.wake_fd) catch {
                    panel.bluetooth.status = .failed;
                    panel.bluetooth.connect_worker.running.store(false, .release);
                };
            }
            return true;
        },
        else => return false,
    }
    return false;
}

pub fn refresh(panel: anytype) void {
    sys_status.dbus_monitor.mizu_dbus_monitor_start_bt_discovery();
    panel.is_scanning = true;
    panel.scan_ticks = 45;
    triggerScan(panel);
}

pub fn renderMainCard(panel: anytype, ui: *ui_mod.Ui, scale: u32, icon_sz: u32, ui_sz: u32, sec_sz: u32) !void {
    const is_bt_on = panel.sys.bluetooth_enabled;
    try panel.renderExpandableCard(ui, 1, "bluetooth", "bluetooth", "Bluetooth", if (is_bt_on) "On" else "Off", is_bt_on, icon_sz, ui_sz, sec_sz, scale);
}

pub fn renderMenu(
    panel: anytype,
    ui: *ui_mod.Ui,
    target: renderer.Renderer,
    scale: u32,
    sec_sz: u32,
    max_visible: usize,
) !void {
    const sub_sz = panel.cfg.typography.submenu_text * scale;
    const row_h_u = QsLayout.row_h * scale;
    const content_w: u32 = blk: {
        const pad_u = QsLayout.pad * scale;
        break :blk if (target.width > 2 * pad_u) target.width - 2 * pad_u else target.width;
    };
    if (panel.bluetooth.items.items.len == 0) {
        types.emptyState(ui, "bluetooth", "No Bluetooth devices found", "Click refresh to scan", scale);
    } else {
        const start_idx = panel.scroll_offset;
        const end_idx = @min(panel.bluetooth.items.items.len, start_idx + max_visible);
        for (panel.bluetooth.items.items[start_idx..end_idx], start_idx..) |item, actual_idx| {
            const is_connecting_this = (panel.bluetooth.status == .connecting and panel.bluetooth.connect_mac_len > 0 and
                std.mem.eql(u8, panel.bluetooth.connect_mac[0..panel.bluetooth.connect_mac_len], item.mac[0..item.mac_len]));
            const is_disconnecting_this = (panel.bluetooth.status == .disconnecting and panel.bluetooth.connect_mac_len > 0 and
                std.mem.eql(u8, panel.bluetooth.connect_mac[0..panel.bluetooth.connect_mac_len], item.mac[0..item.mac_len]));
            const is_failed_this = (panel.bluetooth.status == .failed and panel.bluetooth.failed_mac_len > 0 and
                std.mem.eql(u8, panel.bluetooth.failed_mac[0..panel.bluetooth.failed_mac_len], item.mac[0..item.mac_len]));

            const hov = ui.hovered("qs-bt-card", @intCast(actual_idx));
            var bg = if (item.connected or is_connecting_this) panel.cfg.theme.elevated else panel.cfg.theme.surface;
            if (hov) bg = panel.cfg.theme.btn_raised_hover;

            _ = ui.open(.{
                .id = "qs-bt-card",
                .index = @intCast(actual_idx),
                .width = .{ .grow = .{} },
                .height = .{ .fixed = @floatFromInt(row_h_u) },
                .direction = .row,
                .padding = .{ .left = ui.su(10), .right = ui.su(10) },
                .gap = ui.su(10),
                .bg = bg,
                .radius = ui.f(panel.cfg.theme.radius_button),
                .border = ui.su(1),
                .border_color = if (is_failed_this)
                    panel.cfg.theme.error_color
                else if (item.connected or is_connecting_this or is_disconnecting_this)
                    panel.cfg.theme.accent
                else
                    panel.cfg.theme.border,
                .align_y = .center,
            });

            _ = ui.open(.{
                .width = .{ .fixed = ui.s(24) },
                .height = .{ .fixed = ui.s(24) },
                .bg = if (item.connected) panel.cfg.theme.toggle_on else panel.cfg.theme.btn_raised_bg,
                .radius = ui.f(12),
                .align_x = .center,
                .align_y = .center,
            });
            ui.icon("bluetooth", 16 * scale, if (item.connected) panel.cfg.theme.accent_fg else panel.cfg.theme.text_bright, 0);
            ui.close();

            _ = ui.open(.{
                .width = .{ .grow = .{} },
                .height = .{ .grow = .{} },
                .direction = .column,
                .gap = ui.su(2),
                .align_y = .center,
                .clip_horizontal = true,
            });
            var name_buf: [64]u8 = undefined;
            const trunc_name = types.truncateText(target, &panel.font, item.name[0..item.name_len], content_w -| 150 * scale, sub_sz, &name_buf);
            ui.text(trunc_name, .{ .size = sub_sz, .color = panel.cfg.theme.text_bright });

            const sub_str = if (is_connecting_this)
                "Connecting..."
            else if (is_disconnecting_this)
                "Disconnecting..."
            else if (is_failed_this)
                (if (panel.bluetooth.error_len > 0) panel.bluetooth.error_msg[0..panel.bluetooth.error_len] else "Offline • Failed to connect")
            else if (item.connected)
                "Connected"
            else
                "Offline";

            const sub_color = if (is_connecting_this or is_disconnecting_this)
                panel.cfg.theme.warning_color
            else if (is_failed_this)
                panel.cfg.theme.error_color
            else if (item.connected)
                panel.cfg.theme.accent
            else
                panel.cfg.theme.text_muted;

            ui.text(sub_str, .{
                .size = sec_sz,
                .color = sub_color,
            });
            ui.close();

            const forget_hov = ui.hovered("qs-bt-forget", @intCast(actual_idx));
            _ = ui.open(.{
                .id = "qs-bt-forget",
                .index = @intCast(actual_idx),
                .width = .{ .fixed = ui.s(28) },
                .height = .{ .fixed = ui.s(28) },
                .bg = if (forget_hov) panel.cfg.theme.error_color else panel.cfg.theme.surface,
                .radius = ui.f(6),
                .border = ui.su(1),
                .border_color = if (forget_hov) panel.cfg.theme.error_color else panel.cfg.theme.border,
                .align_x = .center,
                .align_y = .center,
            });
            ui.icon("trash", 16 * scale, if (forget_hov) panel.cfg.theme.accent_fg else panel.cfg.theme.error_color, 0);
            ui.close();

            const action_hov = ui.hovered("qs-bt-action", @intCast(actual_idx));
            const is_active_conn = item.connected;

            const action_bg = if (is_connecting_this or is_disconnecting_this)
                panel.cfg.theme.surface
            else if (is_active_conn)
                (if (action_hov) panel.cfg.theme.error_color else theme.Color.init(45, panel.cfg.theme.error_color.r, panel.cfg.theme.error_color.g, panel.cfg.theme.error_color.b))
            else
                (if (action_hov) panel.cfg.theme.accent else panel.cfg.theme.btn_raised_bg);

            const action_fg = if (is_connecting_this or is_disconnecting_this)
                panel.cfg.theme.warning_color
            else if (is_active_conn)
                (if (action_hov) theme.Color.hex(0xFFFFFF) else panel.cfg.theme.error_color)
            else
                (if (action_hov) panel.cfg.theme.accent_fg else panel.cfg.theme.text_bright);

            _ = ui.open(.{
                .id = "qs-bt-action",
                .index = @intCast(actual_idx),
                .width = .{ .fixed = ui.s(28) },
                .height = .{ .fixed = ui.s(28) },
                .bg = action_bg,
                .radius = ui.f(6),
                .border = ui.su(1),
                .border_color = if (is_connecting_this or is_disconnecting_this)
                    panel.cfg.theme.warning_color
                else if (is_active_conn and action_hov)
                    panel.cfg.theme.error_color
                else if (is_active_conn)
                    panel.cfg.theme.accent
                else if (action_hov)
                    panel.cfg.theme.accent
                else
                    panel.cfg.theme.border,
                .align_x = .center,
                .align_y = .center,
            });
            if (is_connecting_this or is_disconnecting_this) {
                ui.iconRotated("spinner", 16 * scale, action_fg, panel.scan_angle, 0);
            } else {
                ui.icon(if (item.connected) "plug-disconnected" else "plug-connected", 16 * scale, action_fg, 0);
            }
            ui.close();

            ui.close(); // bt card
        }
    }
}

pub fn appendHitAreas(panel: anytype, ui: *ui_mod.Ui, scale: u32, max_visible: usize) !void {
    const start_idx = panel.scroll_offset;
    const end_idx = @min(panel.bluetooth.items.items.len, start_idx + max_visible);
    for (panel.bluetooth.items.items[start_idx..end_idx], start_idx..) |item, actual_idx| {
        if (ui.rectOf("qs-bt-forget", @intCast(actual_idx))) |rect| try types.appendHitArea(panel, rect, scale, .{ .remove_bluetooth = actual_idx });
        if (ui.rectOf("qs-bt-action", @intCast(actual_idx))) |rect| {
            try types.appendHitArea(panel, rect, scale, if (item.connected) .{ .disconnect_bluetooth = actual_idx } else .{ .select_bluetooth = actual_idx });
        }
        if (ui.rectOf("qs-bt-card", @intCast(actual_idx))) |rect| {
            try types.appendHitArea(panel, rect, scale, if (item.connected) .{ .disconnect_bluetooth = actual_idx } else .{ .select_bluetooth = actual_idx });
        }
    }
}
