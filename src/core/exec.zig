const c = @import("../c.zig").c;

/// Run a shell command in a detached child with stdio redirected to /dev/null.
/// Used for fire-and-forget desktop actions and notifications.
pub fn spawnShell(cmd: []const u8) void {
    const pid = c.fork();
    if (pid != 0) return;

    _ = c.setsid();
    const devnull = c.open("/dev/null", c.O_WRONLY);
    if (devnull >= 0) {
        _ = c.dup2(devnull, 1);
        _ = c.dup2(devnull, 2);
        _ = c.close(devnull);
    }

    var stack_buf: [2048]u8 = undefined;
    if (cmd.len < stack_buf.len) {
        @memcpy(stack_buf[0..cmd.len], cmd);
        stack_buf[cmd.len] = 0;
        _ = c.execl("/bin/sh", "sh", "-c", stack_buf[0..cmd.len :0].ptr, @as(?*anyopaque, null));
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

/// Launch `mizu notify` directly (no shell) so notification text cannot be
/// interpreted as shell syntax and no extra shell process is spawned.
pub fn spawnNotify(summary: []const u8, body: []const u8) void {
    const pid = c.fork();
    if (pid != 0) return;

    _ = c.setsid();
    const devnull = c.open("/dev/null", c.O_RDWR);
    if (devnull >= 0) {
        _ = c.dup2(devnull, 0);
        _ = c.dup2(devnull, 1);
        _ = c.dup2(devnull, 2);
        _ = c.close(devnull);
    }

    var sum_buf: [1024]u8 = undefined;
    var body_buf: [4096]u8 = undefined;
    const sum_len = @min(summary.len, sum_buf.len - 1);
    const body_len = @min(body.len, body_buf.len - 1);
    @memcpy(sum_buf[0..sum_len], summary[0..sum_len]);
    @memcpy(body_buf[0..body_len], body[0..body_len]);
    sum_buf[sum_len] = 0;
    body_buf[body_len] = 0;

    _ = c.execl(
        "/proc/self/exe",
        "mizu",
        "notify",
        "--no-store",
        @as([*:0]const u8, @ptrCast(&sum_buf)),
        @as([*:0]const u8, @ptrCast(&body_buf)),
        @as(?*anyopaque, null),
    );
    c.exit(1);
}
