const std = @import("std");
const c = @import("c");
const config = @import("../../core/config.zig");
const async = @import("../../core/async.zig");
const renderer = @import("../../core/renderer.zig");
const sys_status = @import("../../services/system_status.zig");
const text_input = @import("../../core/text_input.zig");
const theme = @import("../../core/theme.zig");
const ui_mod = @import("../../core/ui.zig");
const types = @import("types.zig");

const Action = types.Action;
const QsLayout = types.QsLayout;

pub const WifiItem = struct {
    ssid: [64]u8 = @splat(0),
    ssid_len: usize = 0,
    signal: u8 = 0,
    security: [32]u8 = @splat(0),
    security_len: usize = 0,
    is_active: bool = false,
    is_saved: bool = false,
};

pub const WifiConnectState = enum {
    idle,
    connecting,
    failed,
    success,
};

const QsInputDraw = struct {
    input: *text_input.TextInput,
    font: *renderer.Font,
    cfg: *const config.Config,
    size: u32,

    fn draw(target: renderer.Renderer, rect: renderer.Rect, data: *const anyopaque) void {
        const self: *const QsInputDraw = @ptrCast(@alignCast(data));
        self.input.render(
            target,
            self.font,
            rect.x,
            rect.y,
            rect.w,
            rect.h,
            rect.x,
            self.cfg.theme.text_bright,
            self.cfg.theme.text_muted,
            self.cfg.theme.accent,
            self.size,
        );
    }
};

pub const State = struct {
    items: std.ArrayList(WifiItem),
    input_idx: ?usize = null,
    input_ssid: [64]u8 = @splat(0),
    input_ssid_len: usize = 0,
    input: ?text_input.TextInput = null,
    password: [128]u8 = @splat(0),
    password_len: usize = 0,
    connect_state: WifiConnectState = .idle,
    connecting_ssid: [64]u8 = @splat(0),
    connecting_ssid_len: usize = 0,
    failed_ssid: [64]u8 = @splat(0),
    failed_ssid_len: usize = 0,
    error_msg: [128]u8 = @splat(0),
    error_len: usize = 0,
    worker: WifiWorker = .{},
    worker_running: bool = false,
    scan_worker: WifiScanWorker = .{},
    scan_status: async.OpStatus = .idle,
    last_auto_scan: i64 = 0,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{
            .items = std.ArrayList(WifiItem).empty,
            .input = text_input.TextInput.init(allocator, "Enter Wi-Fi password...", true),
        };
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.input) |*inp| inp.deinit();
        self.items.deinit(allocator);
    }
};

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
    error_msg: [128]u8 = @splat(0),
    error_len: usize = 0,
    ssid: [64]u8 = @splat(0),
    ssid_len: usize = 0,
    pwd: [128]u8 = @splat(0),
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
            cmd_list.appendSlice(std.heap.c_allocator, "nmcli connection up ") catch return;
            appendShellArg(std.heap.c_allocator, &cmd_list, self.ssid[0..slen]) catch return;
            cmd_list.appendSlice(std.heap.c_allocator, " 2>&1 || nmcli dev wifi connect ") catch return;
            appendShellArg(std.heap.c_allocator, &cmd_list, self.ssid[0..slen]) catch return;
            cmd_list.appendSlice(std.heap.c_allocator, " 2>&1") catch return;
        }

        const c_cmd = std.heap.c_allocator.dupeSentinel(u8, cmd_list.items, 0) catch return;
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
    items: [64]WifiItem = @splat(WifiItem{}),
    count: usize = 0,

    pub fn run(worker: *WifiScanWorker) void {
        worker.status.store(.scanning, .release);
        var local_items: [64]WifiItem = @splat(WifiItem{});
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
                        .ssid = @splat(0),
                        .ssid_len = @min(ssid.len, 64),
                        .signal = signal,
                        .security = @splat(0),
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

pub fn triggerScan(panel: anytype) void {
    if (panel.wifi.scan_worker.running.load(.acquire)) return;
    panel.wifi.scan_status = .scanning;
    panel.wifi.scan_worker.done.store(false, .release);
    panel.wifi.scan_worker.running.store(true, .release);
    panel.wifi.scan_worker.wake_fd = panel.wake_fd;
    if (panel.wake_fd >= 0) {
        _ = async.spawnTask(WifiScanWorker, &panel.wifi.scan_worker, panel.wake_fd) catch {
            panel.wifi.scan_worker.running.store(false, .release);
            panel.wifi.scan_status = .failed;
        };
    } else {
        panel.wifi.scan_worker.running.store(false, .release);
        panel.wifi.scan_status = .idle;
    }
    panel.is_scanning = true;
    panel.scan_ticks = 45;
}

pub fn tickInput(panel: anytype) bool {
    if (panel.wifi.input) |*inp| {
        inp.toggleCaret();
        return true;
    }
    return false;
}

pub fn autoScan(panel: anytype, now: i64, net_dirty: bool) void {
    if (panel.view_mode != .wifi_menu or panel.wifi.input_idx != null) return;
    if (panel.wifi.scan_worker.running.load(.acquire) or panel.wifi.worker_running) return;
    if (net_dirty or (now - panel.wifi.last_auto_scan >= 5000)) {
        panel.wifi.last_auto_scan = now;
        triggerScan(panel);
    }
}

pub fn anyWorkerActive(panel: anytype) bool {
    return panel.wifi.scan_worker.running.load(.acquire) or panel.wifi.worker_running;
}

pub fn drain(panel: anytype) bool {
    var changed = false;

    if (panel.wifi.scan_worker.done.load(.acquire)) {
        panel.wifi.scan_worker.lock.lock();
        defer panel.wifi.scan_worker.lock.unlock();
        panel.wifi.items.clearRetainingCapacity();
        for (panel.wifi.scan_worker.items[0..panel.wifi.scan_worker.count]) |it| {
            panel.wifi.items.append(panel.allocator, it) catch break;
        }
        panel.wifi.scan_worker.done.store(false, .release);
        panel.wifi.scan_status = panel.wifi.scan_worker.status.load(.acquire);
        changed = true;
    }

    return changed;
}

pub fn connectNetwork(panel: anytype, ssid: []const u8, pwd: []const u8) void {
    if (panel.wifi.worker_running) return;

    panel.wifi.connect_state = .connecting;
    panel.wifi.error_len = 0;
    panel.wifi.failed_ssid_len = 0;

    const clen = @min(ssid.len, panel.wifi.connecting_ssid.len);
    @memcpy(panel.wifi.connecting_ssid[0..clen], ssid[0..clen]);
    panel.wifi.connecting_ssid_len = clen;

    panel.wifi.input_idx = null;
    panel.wifi.input_ssid_len = 0;
    if (panel.wifi.input) |*inp| inp.clear();
    panel.wifi.password_len = 0;

    panel.wifi.worker = WifiWorker{};
    panel.wifi.worker.wake_fd = panel.wake_fd;
    const slen = @min(ssid.len, panel.wifi.worker.ssid.len);
    @memcpy(panel.wifi.worker.ssid[0..slen], ssid[0..slen]);
    panel.wifi.worker.ssid_len = slen;

    const plen = @min(pwd.len, panel.wifi.worker.pwd.len);
    @memcpy(panel.wifi.worker.pwd[0..plen], pwd[0..plen]);
    panel.wifi.worker.pwd_len = plen;

    panel.wifi.worker_running = true;
    panel.is_scanning = true;
    panel.scan_ticks = 45;

    _ = async.spawnTask(WifiWorker, &panel.wifi.worker, panel.wake_fd) catch {
        panel.wifi.connect_state = .failed;
        panel.wifi.connecting_ssid_len = 0;
        panel.wifi.worker_running = false;
        const fb = "Failed to spawn connect worker.";
        @memcpy(panel.wifi.error_msg[0..fb.len], fb);
        panel.wifi.error_len = fb.len;
    };
}

pub fn checkStatus(panel: anytype) bool {
    if (!panel.wifi.worker_running) return false;
    if (!panel.wifi.worker.done.load(.acquire)) return false;

    if (panel.wifi.worker.success.load(.acquire)) {
        panel.wifi.connect_state = .success;
        const conn_ssid = panel.wifi.worker.ssid[0..panel.wifi.worker.ssid_len];
        panel.wifi.connecting_ssid_len = 0;
        panel.wifi.input_idx = null;
        panel.wifi.input_ssid_len = 0;
        panel.wifi.password_len = 0;
        panel.wifi.error_len = 0;
        panel.wifi.failed_ssid_len = 0;

        for (panel.wifi.items.items) |*it| {
            if (it.ssid_len == conn_ssid.len and std.mem.eql(u8, it.ssid[0..it.ssid_len], conn_ssid)) {
                it.is_active = true;
                it.is_saved = true;
            } else {
                it.is_active = false;
            }
        }

        std.mem.sort(WifiItem, panel.wifi.items.items, {}, struct {
            fn lessThan(_: void, a: WifiItem, b: WifiItem) bool {
                if (a.is_active != b.is_active) return a.is_active;
                if (a.is_saved != b.is_saved) return a.is_saved;
                return a.signal > b.signal;
            }
        }.lessThan);

        const mlen = @min(conn_ssid.len, panel.sys.wifi_ssid.len);
        @memcpy(panel.sys.wifi_ssid[0..mlen], conn_ssid[0..mlen]);
        panel.sys.wifi_ssid_len = mlen;
        panel.sys.wifi_enabled = true;

        panel.triggerWifiScan();
    } else {
        panel.wifi.connect_state = .failed;
        const elen = panel.wifi.worker.error_len;
        @memcpy(panel.wifi.error_msg[0..elen], panel.wifi.worker.error_msg[0..elen]);
        panel.wifi.error_len = elen;

        const flen = @min(panel.wifi.worker.ssid_len, panel.wifi.failed_ssid.len);
        @memcpy(panel.wifi.failed_ssid[0..flen], panel.wifi.worker.ssid[0..flen]);
        panel.wifi.failed_ssid_len = flen;
        panel.wifi.connecting_ssid_len = 0;
    }

    panel.wifi.worker_running = false;
    return true;
}

pub fn submitPassword(panel: anytype) void {
    const idx = panel.wifi.input_idx orelse return;
    if (idx >= panel.wifi.items.items.len) {
        panel.wifi.input_idx = null;
        panel.wifi.input_ssid_len = 0;
        return;
    }
    if (panel.wifi.connect_state == .connecting) return;

    const item = panel.wifi.items.items[idx];
    const ssid = item.ssid[0..item.ssid_len];
    const pwd = panel.wifi.password[0..panel.wifi.password_len];

    panel.connectWifiNetwork(ssid, pwd);
}

pub fn handleKey(panel: anytype, sym: u32, utf8_bytes: []const u8, ctrl: bool, shift: bool) bool {
    if (panel.wifi.input_idx == null) return false;

    if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_KP_Enter) {
        panel.submitWifiPassword();
        return true;
    } else if (sym == c.XKB_KEY_Escape) {
        panel.wifi.input_idx = null;
        panel.wifi.input_ssid_len = 0;
        if (panel.wifi.input) |*inp| inp.clear();
        panel.wifi.password_len = 0;
        return true;
    }

    if (panel.wifi.input) |*inp| {
        const handled = inp.handleKey(sym, utf8_bytes, ctrl, shift);
        if (handled) {
            const txt = inp.getText();
            const copy_len = @min(txt.len, panel.wifi.password.len);
            @memcpy(panel.wifi.password[0..copy_len], txt[0..copy_len]);
            panel.wifi.password_len = copy_len;
            return true;
        }
    }

    if (sym == c.XKB_KEY_BackSpace) {
        if (panel.wifi.password_len > 0) {
            panel.wifi.password_len -= 1;
        }
        return true;
    } else if (utf8_bytes.len > 0 and utf8_bytes[0] >= 32 and utf8_bytes[0] != 127) {
        if (panel.wifi.password_len + utf8_bytes.len <= panel.wifi.password.len) {
            @memcpy(panel.wifi.password[panel.wifi.password_len .. panel.wifi.password_len + utf8_bytes.len], utf8_bytes);
            panel.wifi.password_len += utf8_bytes.len;
            return true;
        }
    } else if (sym >= 32 and sym <= 126) {
        if (panel.wifi.password_len < panel.wifi.password.len) {
            panel.wifi.password[panel.wifi.password_len] = @intCast(sym);
            panel.wifi.password_len += 1;
            return true;
        }
    }
    return false;
}

pub fn scan(panel: anytype) void {
    panel.wifi.items.clearRetainingCapacity();

    // 0. Query saved wifi connections
    var saved_connections = std.ArrayList([64]u8).empty;
    defer saved_connections.deinit(panel.allocator);
    var saved_lengths = std.ArrayList(usize).empty;
    defer saved_lengths.deinit(panel.allocator);

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
                        var entry: [64]u8 = @splat(0);
                        @memcpy(entry[0..name.len], name);
                        saved_connections.append(panel.allocator, entry) catch {};
                        saved_lengths.append(panel.allocator, name.len) catch {};
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
        for (panel.wifi.items.items) |*existing| {
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
                .ssid = @splat(0),
                .ssid_len = @min(ssid.len, 64),
                .signal = signal,
                .security = @splat(0),
                .security_len = @min(security_str.len, 32),
                .is_active = is_active,
                .is_saved = is_saved,
            };
            @memcpy(item.ssid[0..item.ssid_len], ssid[0..item.ssid_len]);
            @memcpy(item.security[0..item.security_len], security_str[0..item.security_len]);
            panel.wifi.items.append(panel.allocator, item) catch break;
        }
    }

    // Sort: active first, then saved, then highest signal descending
    std.mem.sort(WifiItem, panel.wifi.items.items, {}, struct {
        fn lessThan(_: void, a: WifiItem, b: WifiItem) bool {
            if (a.is_active != b.is_active) return a.is_active;
            if (a.is_saved != b.is_saved) return a.is_saved;
            return a.signal > b.signal;
        }
    }.lessThan);
}

pub fn handleAction(panel: anytype, action: Action) bool {
    switch (action) {
        .toggle_wifi => {
            panel.sys.toggleWifi();
            if (panel.sys.wifi_enabled) {
                panel.is_scanning = true;
                panel.scan_ticks = 45;
                panel.triggerWifiScan();
            } else {
                panel.wifi.items.clearRetainingCapacity();
            }
            return true;
        },
        .open_wifi_menu => {
            panel.view_mode = .wifi_menu;
            panel.scroll_offset = 0;
            panel.is_scanning = true;
            panel.scan_ticks = 45;
            panel.triggerWifiScan();
            return true;
        },
        .forget_wifi => |idx| {
            if (idx < panel.wifi.items.items.len) {
                const item = panel.wifi.items.items[idx];
                const ssid = item.ssid[0..item.ssid_len];
                var cmd_buf: [256]u8 = undefined;
                const cmd = std.fmt.bufPrint(&cmd_buf, "nmcli connection delete id \"{s}\" 2>/dev/null || true", .{ssid}) catch "";
                sys_status.spawnCmd(cmd);

                // Instantly reflect deletion in UI state without closing panel
                panel.wifi.items.items[idx].is_saved = false;
                if (item.signal == 0 and !item.is_active) {
                    _ = panel.wifi.items.orderedRemove(idx);
                }
                return true;
            }
        },
        .disconnect_wifi => |idx| {
            if (idx < panel.wifi.items.items.len) {
                const item = panel.wifi.items.items[idx];
                const ssid = item.ssid[0..item.ssid_len];
                var cmd_buf: [256]u8 = undefined;
                const cmd = std.fmt.bufPrint(&cmd_buf, "nmcli connection down id \"{s}\" 2>/dev/null || true", .{ssid}) catch "";
                sys_status.spawnCmd(cmd);
                panel.wifi.items.items[idx].is_active = false;
                panel.sys.wifi_ssid_len = 0;
                panel.is_scanning = true;
                panel.scan_ticks = 10;
                panel.triggerWifiScan();
                return true;
            }
        },
        .select_wifi => |idx| {
            if (idx < panel.wifi.items.items.len) {
                const item = panel.wifi.items.items[idx];
                if (item.is_active) {
                    return true;
                }
                if (panel.wifi.worker_running) return true;
                panel.wifi.failed_ssid_len = 0;
                const sec_str = if (item.security_len > 0) item.security[0..item.security_len] else "";
                const is_open = (item.security_len == 0 or std.mem.eql(u8, sec_str, "--") or (std.mem.indexOf(u8, sec_str, "WPA") == null and std.mem.indexOf(u8, sec_str, "WEP") == null and std.mem.indexOf(u8, sec_str, "802.1X") == null));
                if (item.is_saved or is_open) {
                    panel.connectWifiNetwork(item.ssid[0..item.ssid_len], "");
                } else {
                    if (panel.wifi.input_ssid_len > 0 and std.mem.eql(u8, panel.wifi.input_ssid[0..panel.wifi.input_ssid_len], item.ssid[0..item.ssid_len])) {
                        panel.wifi.input_idx = null;
                        panel.wifi.input_ssid_len = 0;
                        if (panel.wifi.input) |*inp| inp.clear();
                        panel.wifi.password_len = 0;
                    } else {
                        panel.wifi.input_idx = idx;
                        const slen = @min(item.ssid_len, panel.wifi.input_ssid.len);
                        @memcpy(panel.wifi.input_ssid[0..slen], item.ssid[0..slen]);
                        panel.wifi.input_ssid_len = slen;
                        if (panel.wifi.input) |*inp| {
                            inp.clear();
                            inp.focused = true;
                            inp.resetCaret();
                        }
                        panel.wifi.password_len = 0;
                    }
                }
            }
            return true;
        },
        .wifi_cancel => {
            panel.wifi.input_idx = null;
            panel.wifi.input_ssid_len = 0;
            if (panel.wifi.input) |*inp| inp.clear();
            panel.wifi.password_len = 0;
            return true;
        },
        .wifi_connect_submit => {
            panel.submitWifiPassword();
            return true;
        },
        else => return false,
    }
    return false;
}

pub fn handleInputClick(panel: anytype, action: Action, x: i32, y: i32, area: types.HitArea) bool {
    if (action != .wifi_input_click) return false;
    if (panel.wifi.input) |*inp| {
        inp.focused = true;
        inp.resetCaret();
        _ = inp.handlePointerDown(x, y, area.x, area.y, area.w, area.h, area.x + 8, &panel.font);
    }
    return true;
}

pub fn refresh(panel: anytype) void {
    panel.is_scanning = true;
    panel.scan_ticks = 45;
    triggerScan(panel);
}

pub fn renderMainCard(panel: anytype, ui: *ui_mod.Ui, scale: u32, icon_sz: u32, ui_sz: u32, sec_sz: u32) !void {
    const is_wifi_on = panel.sys.wifi_enabled;
    const wifi_sub = if (is_wifi_on)
        (if (panel.sys.wifi_ssid_len > 0) panel.sys.wifi_ssid[0..panel.sys.wifi_ssid_len] else "Connected")
    else
        "Off";
    try panel.renderExpandableCard(ui, 0, if (is_wifi_on) "wifi-high" else "wifi-off", if (is_wifi_on) "wifi-high" else "wifi-off", "Wi-Fi", wifi_sub, is_wifi_on, icon_sz, ui_sz, sec_sz, scale);
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
    const btn_sz = panel.cfg.typography.button_text * scale;
    const row_h_u = QsLayout.row_h * scale;
    const content_w: u32 = blk: {
        const pad_u = QsLayout.pad * scale;
        break :blk if (target.width > 2 * pad_u) target.width - 2 * pad_u else target.width;
    };
    if (panel.is_scanning and panel.wifi.items.items.len == 0) {
        types.emptyState(ui, "wifi-none", "Scanning networks...", "Please wait", scale);
    } else if (panel.wifi.items.items.len == 0) {
        types.emptyState(ui, "wifi-none", "No Wi-Fi networks found", "Click refresh to scan", scale);
    } else {
        const start_idx = panel.scroll_offset;
        const end_idx = @min(panel.wifi.items.items.len, start_idx + max_visible);
        for (panel.wifi.items.items[start_idx..end_idx], start_idx..) |item, actual_idx| {
            const is_connecting_this = (panel.wifi.connect_state == .connecting and panel.wifi.connecting_ssid_len > 0 and
                std.mem.eql(u8, panel.wifi.connecting_ssid[0..panel.wifi.connecting_ssid_len], item.ssid[0..item.ssid_len]));
            const is_failed_this = (panel.wifi.connect_state == .failed and panel.wifi.failed_ssid_len > 0 and
                std.mem.eql(u8, panel.wifi.failed_ssid[0..panel.wifi.failed_ssid_len], item.ssid[0..item.ssid_len]));
            const is_input_active = (panel.wifi.input_ssid_len > 0 and
                std.mem.eql(u8, panel.wifi.input_ssid[0..panel.wifi.input_ssid_len], item.ssid[0..item.ssid_len]));
            const has_error = (is_input_active and panel.wifi.error_len > 0);
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
                    .bg = panel.cfg.theme.elevated,
                    .radius = ui.f(panel.cfg.theme.radius_button),
                    .border = ui.su(1),
                    .border_color = if (has_error) panel.cfg.theme.error_color else panel.cfg.theme.accent,
                });

                _ = ui.open(.{
                    .width = .{ .grow = .{} },
                    .height = .{ .fixed = ui.s(28) },
                    .direction = .row,
                    .gap = ui.su(8),
                    .align_y = .center,
                });
                ui.text(item.ssid[0..item.ssid_len], .{ .size = sub_sz, .color = panel.cfg.theme.text_bright });
                ui.spacerSized(.{ .grow = .{} }, .{ .fixed = 0 });
                const cancel_hov = ui.hovered("qs-wifi-input-cancel", 0);
                _ = ui.open(.{
                    .id = "qs-wifi-input-cancel",
                    .width = .{ .fixed = ui.s(26) },
                    .height = .{ .fixed = ui.s(26) },
                    .bg = if (cancel_hov) panel.cfg.theme.card_hover_bg else null,
                    .radius = ui.f(6),
                    .align_x = .center,
                    .align_y = .center,
                });
                ui.icon("close", 14 * scale, if (cancel_hov) panel.cfg.theme.error_color else panel.cfg.theme.text_muted, 0);
                ui.close();
                ui.close();

                _ = ui.open(.{
                    .id = "qs-wifi-input",
                    .width = .{ .grow = .{} },
                    .height = .{ .fixed = ui.s(28) },
                    .padding = .{ .left = ui.su(8), .right = ui.su(8) },
                    .bg = panel.cfg.theme.base,
                    .radius = ui.f(6),
                    .align_y = .center,
                });
                if (panel.wifi.input != null) {
                    const data = try ui.allocator.create(QsInputDraw);
                    data.* = .{ .input = &panel.wifi.input.?, .font = &panel.font, .cfg = &panel.cfg, .size = sub_sz };
                    const custom = try ui.allocator.create(ui_mod.Custom);
                    custom.* = .{ .callback = .{ .function = QsInputDraw.draw, .data = data } };
                    ui.custom(.{ .grow = .{} }, .{ .grow = .{} }, custom, 0);
                    ui.close();
                } else {
                    if (panel.wifi.password_len == 0) {
                        ui.text("Enter Wi-Fi password...", .{ .size = sub_sz, .color = panel.cfg.theme.text_muted });
                    } else {
                        var mask_buf: [130]u8 = undefined;
                        const mask_len = @min(panel.wifi.password_len, 32);
                        @memset(mask_buf[0..mask_len], '*');
                        mask_buf[mask_len] = '|';
                        ui.text(mask_buf[0 .. mask_len + 1], .{ .size = sub_sz, .color = panel.cfg.theme.text_bright });
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
                    .bg = if (cancel_btn_hov) panel.cfg.theme.elevated else panel.cfg.theme.surface,
                    .radius = ui.f(6),
                    .align_x = .center,
                    .align_y = .center,
                });
                ui.text("Cancel", .{ .size = btn_sz, .color = panel.cfg.theme.text_bright });
                ui.close();

                const is_connecting = (panel.wifi.connect_state == .connecting);
                const conn_hov = ui.hovered("qs-wifi-connect", 0);
                _ = ui.open(.{
                    .id = "qs-wifi-connect",
                    .width = .{ .fixed = if (is_connecting) ui.s(100) else ui.s(82) },
                    .height = .{ .grow = .{} },
                    .bg = if (is_connecting) panel.cfg.theme.elevated else if (conn_hov) panel.cfg.theme.accent else panel.cfg.theme.surface,
                    .radius = ui.f(6),
                    .align_x = .center,
                    .align_y = .center,
                });
                ui.text(if (is_connecting) "Connecting..." else "Connect", .{
                    .size = btn_sz,
                    .color = if (conn_hov and !is_connecting) panel.cfg.theme.accent_fg else panel.cfg.theme.text_bright,
                });
                ui.close();
                ui.close();

                if (has_error) {
                    ui.text(panel.wifi.error_msg[0..panel.wifi.error_len], .{
                        .size = sec_sz,
                        .color = panel.cfg.theme.error_color,
                    });
                }
                ui.close(); // input card
            } else {
                var bg = if (item.is_active or is_connecting_this) panel.cfg.theme.elevated else panel.cfg.theme.surface;
                if (hov) bg = panel.cfg.theme.btn_raised_hover;
                _ = ui.open(.{
                    .id = "qs-wifi-card",
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
                    else if (item.is_active or is_connecting_this)
                        panel.cfg.theme.accent
                    else
                        panel.cfg.theme.border,
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
                    .bg = if (item.is_active) panel.cfg.theme.toggle_on else panel.cfg.theme.btn_raised_bg,
                    .radius = ui.f(12),
                    .align_x = .center,
                    .align_y = .center,
                });
                ui.icon(sig_icon_name, 16 * scale, if (item.is_active) panel.cfg.theme.accent_fg else panel.cfg.theme.text_bright, 0);
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
                const trunc_name = types.truncateText(target, &panel.font, item.ssid[0..item.ssid_len], content_w -| 150 * scale, sub_sz, &name_buf);
                ui.text(trunc_name, .{ .size = sub_sz, .color = panel.cfg.theme.text_bright });
                var sub_buf: [64]u8 = undefined;
                const sec_str = if (item.security_len > 0) item.security[0..item.security_len] else "Open";
                const sub_str = if (is_connecting_this)
                    "Connecting..."
                else if (is_failed_this)
                    (if (panel.wifi.error_len > 0) panel.wifi.error_msg[0..panel.wifi.error_len] else "Connection failed")
                else if (item.is_active)
                    std.fmt.bufPrint(&sub_buf, "Connected • {d}%", .{item.signal}) catch "Connected"
                else
                    std.fmt.bufPrint(&sub_buf, "{d}% • {s}", .{ item.signal, sec_str }) catch sec_str;
                ui.text(sub_str, .{
                    .size = sec_sz,
                    .color = if (is_connecting_this)
                        panel.cfg.theme.warning_color
                    else if (is_failed_this)
                        panel.cfg.theme.error_color
                    else if (item.is_active)
                        panel.cfg.theme.accent
                    else
                        panel.cfg.theme.text_muted,
                });
                ui.close();

                if (item.is_saved) {
                    const forget_hov = ui.hovered("qs-wifi-forget", @intCast(actual_idx));
                    _ = ui.open(.{
                        .id = "qs-wifi-forget",
                        .index = @intCast(actual_idx),
                        .width = .{ .fixed = ui.s(28) },
                        .height = .{ .fixed = ui.s(28) },
                        .bg = if (forget_hov) panel.cfg.theme.error_color else panel.cfg.theme.surface,
                        .radius = ui.f(6),
                        .align_x = .center,
                        .align_y = .center,
                    });
                    ui.icon("trash", 16 * scale, if (forget_hov) panel.cfg.theme.accent_fg else panel.cfg.theme.error_color, 0);
                    ui.close();
                }

                if (item.is_active or item.is_saved or is_connecting_this) {
                    const action_hov = ui.hovered("qs-wifi-action", @intCast(actual_idx));
                    const action_icon = if (item.is_active) "plug-disconnected" else "plug-connected";
                    const is_active_conn = item.is_active;

                    const action_bg = if (is_connecting_this)
                        panel.cfg.theme.surface
                    else if (is_active_conn)
                        (if (action_hov) panel.cfg.theme.error_color else theme.Color.init(45, panel.cfg.theme.error_color.r, panel.cfg.theme.error_color.g, panel.cfg.theme.error_color.b))
                    else
                        (if (action_hov) panel.cfg.theme.accent else panel.cfg.theme.btn_raised_bg);

                    const action_fg = if (is_connecting_this)
                        panel.cfg.theme.warning_color
                    else if (is_active_conn)
                        (if (action_hov) theme.Color.hex(0xFFFFFF) else panel.cfg.theme.error_color)
                    else
                        (if (action_hov) panel.cfg.theme.accent_fg else panel.cfg.theme.text_bright);

                    _ = ui.open(.{
                        .id = "qs-wifi-action",
                        .index = @intCast(actual_idx),
                        .width = .{ .fixed = ui.s(28) },
                        .height = .{ .fixed = ui.s(28) },
                        .bg = action_bg,
                        .radius = ui.f(6),
                        .align_x = .center,
                        .align_y = .center,
                    });
                    if (is_connecting_this) {
                        ui.iconRotated("spinner", 16 * scale, action_fg, panel.scan_angle, 0);
                    } else {
                        ui.icon(action_icon, 16 * scale, action_fg, 0);
                    }
                    ui.close();
                }

                ui.close(); // wifi card
            }
        }
    }
}

pub fn appendHitAreas(panel: anytype, ui: *ui_mod.Ui, scale: u32, max_visible: usize) !void {
    const start_idx = panel.scroll_offset;
    const end_idx = @min(panel.wifi.items.items.len, start_idx + max_visible);
    for (panel.wifi.items.items[start_idx..end_idx], start_idx..) |item, actual_idx| {
        const is_input_active = (panel.wifi.input_ssid_len > 0 and
            std.mem.eql(u8, panel.wifi.input_ssid[0..panel.wifi.input_ssid_len], item.ssid[0..item.ssid_len]));
        if (is_input_active) {
            if (ui.rectOf("qs-wifi-input", 0)) |rect| try types.appendHitArea(panel, rect, scale, .wifi_input_click);
            if (ui.rectOf("qs-wifi-input-cancel", 0)) |rect| try types.appendHitArea(panel, rect, scale, .wifi_cancel);
            if (ui.rectOf("qs-wifi-cancel", 0)) |rect| try types.appendHitArea(panel, rect, scale, .wifi_cancel);
            if (ui.rectOf("qs-wifi-connect", 0)) |rect| try types.appendHitArea(panel, rect, scale, .wifi_connect_submit);
        } else {
            if (item.is_saved) {
                if (ui.rectOf("qs-wifi-forget", @intCast(actual_idx))) |rect| try types.appendHitArea(panel, rect, scale, .{ .forget_wifi = actual_idx });
            }
            if (item.is_active) {
                if (ui.rectOf("qs-wifi-action", @intCast(actual_idx))) |rect| try types.appendHitArea(panel, rect, scale, .{ .disconnect_wifi = actual_idx });
            } else if (item.is_saved) {
                if (ui.rectOf("qs-wifi-action", @intCast(actual_idx))) |rect| try types.appendHitArea(panel, rect, scale, .{ .select_wifi = actual_idx });
            }
            if (ui.rectOf("qs-wifi-card", @intCast(actual_idx))) |rect| try types.appendHitArea(panel, rect, scale, .{ .select_wifi = actual_idx });
        }
    }
}
