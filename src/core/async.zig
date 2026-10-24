const std = @import("std");
const c = @import("../c.zig").c;

/// Lifecycle of an asynchronous system operation.
///
/// Every potentially slow system operation (D-Bus, subprocess, sysfs polling)
/// progresses through these states so the UI can show a consistent loading /
/// success / failed experience instead of mutating shared state ad-hoc.
pub const OpStatus = enum(u8) {
    idle,
    /// Operation is in progress (generic loading).
    loading,
    /// A discovery/scan is in progress.
    scanning,
    /// A connection is being established.
    connecting,
    /// A connection is being torn down.
    disconnecting,
    success,
    failed,

    pub fn isActive(self: OpStatus) bool {
        return switch (self) {
            .loading, .scanning, .connecting, .disconnecting => true,
            .idle, .success, .failed => false,
        };
    }

    pub fn label(self: OpStatus) []const u8 {
        return switch (self) {
            .idle => "",
            .loading => "Loading...",
            .scanning => "Scanning...",
            .connecting => "Connecting...",
            .disconnecting => "Disconnecting...",
            .success => "",
            .failed => "",
        };
    }
};

/// Spawn `Worker.run(ctx)` on a detached background thread.
///
/// The thread is detached immediately so the caller never blocks on it.
/// Each worker is responsible for signaling its own `wake_fd` (an eventfd, if
/// >= 0) when it finishes, so the UI event loop can drain results without
/// polling. The caller sets the operation status to `.loading`/`.scanning`
/// before calling and to `.success`/`.failed` inside `Worker.run`.
pub fn spawnTask(comptime Worker: type, ctx: *Worker, wake_fd: c_int) !void {
    const thread = try std.Thread.spawn(.{}, Worker.run, .{ctx});
    thread.detach();
    _ = wake_fd;
}

/// Read and drain a wake eventfd after a background worker signals completion.
/// Returns true if a wake was consumed.
pub fn drainWake(fd: c_int) bool {
    if (fd < 0) return false;
    var val: u64 = 0;
    const n = c.read(fd, &val, @sizeOf(u64));
    return n > 0;
}
