const std = @import("std");
const c = @import("../c.zig").c;

pub const Tag = struct {
    index: u32,
    is_active: bool = false,
    is_urgent: bool = false,
    client_count: u32 = 0,
};

const TagJson = struct {
    index: u32,
    is_active: bool = false,
    is_urgent: bool = false,
    client_count: u32 = 0,
    layout: ?[]const u8 = null,
};

const MonitorTagsJson = struct {
    monitor: []const u8,
    tags: []TagJson,
};

const AllTagsMsg = struct {
    all_tags: []MonitorTagsJson,
};

pub const MangoIpc = struct {
    fd: c_int = -1,
    read_buf: [16384]u8 = undefined,
    read_len: usize = 0,
    tags: [9]Tag = .{
        .{ .index = 1 }, .{ .index = 2 }, .{ .index = 3 },
        .{ .index = 4 }, .{ .index = 5 }, .{ .index = 6 },
        .{ .index = 7 }, .{ .index = 8 }, .{ .index = 9 },
    },
    active_monitor: [64]u8 = [_]u8{0} ** 64,
    socket_path: ?[]const u8 = null,

    pub fn init() MangoIpc {
        var self = MangoIpc{};

        if (c.getenv("MANGO_INSTANCE_SIGNATURE")) |path_ptr| {
            self.socket_path = std.mem.span(path_ptr);
            self.connect() catch |err| {
                std.debug.print("Failed to connect to MangoWC IPC: {any}\n", .{err});
            };
        } else {
            std.debug.print("MANGO_INSTANCE_SIGNATURE not set; running without MangoWC IPC\n", .{});
        }

        return self;
    }

    pub fn deinit(self: *MangoIpc) void {
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
    }

    pub fn connect(self: *MangoIpc) !void {
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }

        const path = self.socket_path orelse return error.NoSocketPath;

        const sock = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (sock < 0) return error.SocketCreateFailed;
        errdefer _ = c.close(sock);

        var addr: c.struct_sockaddr_un = undefined;
        @memset(std.mem.asBytes(&addr), 0);
        addr.sun_family = c.AF_UNIX;

        if (path.len >= @sizeOf(@TypeOf(addr.sun_path))) {
            return error.SocketPathTooLong;
        }
        @memcpy(addr.sun_path[0..path.len], path);
        addr.sun_path[path.len] = 0;

        const addr_len = @sizeOf(c.sa_family_t) + path.len + 1;
        const res = c.connect(sock, .{ .__sockaddr__ = @ptrCast(&addr) }, @intCast(addr_len));
        if (res < 0) {
            return error.ConnectFailed;
        }

        // Set non-blocking
        const flags = c.fcntl(sock, c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(sock, c.F_SETFL, flags | c.O_NONBLOCK);

        // Send watch command
        const cmd = "watch all-tags\n";
        _ = c.send(sock, cmd.ptr, cmd.len, 0);

        self.fd = sock;
        self.read_len = 0;
    }

    pub fn readEvents(self: *MangoIpc) bool {
        if (self.fd < 0) return false;

        var changed = false;

        while (true) {
            if (self.read_len >= self.read_buf.len) {
                // Buffer full without newline, reset to avoid deadlock
                self.read_len = 0;
            }

            const n = c.recv(
                self.fd,
                self.read_buf[self.read_len..].ptr,
                self.read_buf.len - self.read_len,
                0,
            );

            if (n <= 0) {
                if (n == 0) {
                    // Socket closed by compositor
                    _ = c.close(self.fd);
                    self.fd = -1;
                }
                break;
            }

            self.read_len += @intCast(n);

            // Process all newline-delimited lines
            while (true) {
                const slice = self.read_buf[0..self.read_len];
                if (std.mem.indexOfScalar(u8, slice, '\n')) |newline_pos| {
                    const line = slice[0..newline_pos];
                    if (line.len > 0 and self.parseTagsLine(line)) {
                        changed = true;
                    }

                    // Shift remaining bytes
                    const remaining = self.read_len - (newline_pos + 1);
                    if (remaining > 0) {
                        std.mem.copyForwards(u8, self.read_buf[0..remaining], self.read_buf[newline_pos + 1 .. self.read_len]);
                    }
                    self.read_len = remaining;
                } else {
                    break;
                }
            }
        }

        return changed;
    }

    fn parseTagsLine(self: *MangoIpc, line: []const u8) bool {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        const parsed = std.json.parseFromSlice(AllTagsMsg, arena.allocator(), line, .{
            .ignore_unknown_fields = true,
        }) catch return false;
        defer parsed.deinit();

        if (parsed.value.all_tags.len == 0) return false;

        // Use the first active monitor or matching monitor
        const mon = parsed.value.all_tags[0];
        var changed = false;

        for (mon.tags) |tag_json| {
            if (tag_json.index >= 1 and tag_json.index <= 9) {
                const idx = tag_json.index - 1;
                const old = self.tags[idx];
                if (old.is_active != tag_json.is_active or
                    old.is_urgent != tag_json.is_urgent or
                    old.client_count != tag_json.client_count)
                {
                    self.tags[idx].is_active = tag_json.is_active;
                    self.tags[idx].is_urgent = tag_json.is_urgent;
                    self.tags[idx].client_count = tag_json.client_count;
                    changed = true;
                }
            }
        }

        return changed;
    }

    pub fn sendCommand(self: *MangoIpc, comptime fmt: []const u8, args: anytype) void {
        const path = self.socket_path orelse return;

        const sock = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (sock < 0) return;
        defer _ = c.close(sock);

        var addr: c.struct_sockaddr_un = undefined;
        @memset(std.mem.asBytes(&addr), 0);
        addr.sun_family = c.AF_UNIX;

        if (path.len >= @sizeOf(@TypeOf(addr.sun_path))) return;
        @memcpy(addr.sun_path[0..path.len], path);
        addr.sun_path[path.len] = 0;

        const addr_len = @sizeOf(c.sa_family_t) + path.len + 1;
        if (c.connect(sock, .{ .__sockaddr__ = @ptrCast(&addr) }, @intCast(addr_len)) < 0) return;

        var cmd_buf: [128]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, fmt, args) catch return;
        _ = c.send(sock, cmd.ptr, cmd.len, 0);
    }

    pub fn switchWorkspace(self: *MangoIpc, index: u32) void {
        self.sendCommand("dispatch view,{d},0\n", .{index});
        var cmd_buf: [64]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "mmsg dispatch view,{d},0 2>/dev/null || true", .{index}) catch return;
        @import("./system_status.zig").spawnCmd(cmd);
    }

    pub fn toggleWorkspace(self: *MangoIpc, index: u32) void {
        self.sendCommand("dispatch toggleview,{d},0\n", .{index});
        var cmd_buf: [64]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "mmsg dispatch toggleview,{d},0 2>/dev/null || true", .{index}) catch return;
        @import("./system_status.zig").spawnCmd(cmd);
    }
};
