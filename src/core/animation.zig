const std = @import("std");
const c = @import("c");

/// Monotonic time in milliseconds.
pub fn monotonicMs() u64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.tv_sec)) * 1_000 + @as(u64, @intCast(ts.tv_nsec)) / 1_000_000;
}

/// Reusable easing functions. All take a normalized progress `t` in [0, 1]
/// and return an eased progress in [0, 1].
pub const Easing = struct {
    pub fn linear(t: f32) f32 {
        return t;
    }

    /// Fast start, slow end.
    pub fn easeOutCubic(t: f32) f32 {
        const clamped = std.math.clamp(t, 0.0, 1.0);
        const inv = 1.0 - clamped;
        return 1.0 - inv * inv * inv;
    }

    /// Slow start, fast middle, slow end.
    pub fn easeInOutCubic(t: f32) f32 {
        const clamped = std.math.clamp(t, 0.0, 1.0);
        return if (clamped < 0.5)
            4.0 * clamped * clamped * clamped
        else
            1.0 - (-2.0 * clamped + 2.0) ^ 3 / 2.0;
    }

    /// Very fast end (strong ease-out).
    pub fn easeOutQuint(t: f32) f32 {
        const clamped = std.math.clamp(t, 0.0, 1.0);
        const inv = 1.0 - clamped;
        return 1.0 - inv * inv * inv * inv * inv;
    }

    /// Slow start and end with a sinusoidal curve.
    pub fn easeInOutSine(t: f32) f32 {
        const clamped = std.math.clamp(t, 0.0, 1.0);
        return -(std.math.cos(clamped * std.math.pi) - 1.0) / 2.0;
    }
};

/// Time-based animation interpolating a value using easing curves.
pub const Animation = struct {
    from: f32 = 0.0,
    to: f32 = 0.0,
    value: f32 = 0.0,
    duration_ms: u32 = 0,
    elapsed_ms: u32 = 0,
    easing: *const fn (f32) f32 = &Easing.linear,
    active: bool = false,
    on_complete: ?*const fn () void = null,

    /// Initialize an animation in its idle (inactive) state.
    pub fn init() Animation {
        return .{};
    }

    /// Start (or restart) an animation from `from` to `to` over `duration_ms`.
    pub fn start(self: *Animation, from: f32, to: f32, duration_ms: u32, easing: *const fn (f32) f32) void {
        self.from = from;
        self.to = to;
        self.value = from;
        self.duration_ms = duration_ms;
        self.elapsed_ms = 0;
        self.easing = easing;
        self.active = true;
    }

    /// Cancel the animation, leaving `value` where it is.
    pub fn cancel(self: *Animation) void {
        self.active = false;
        self.elapsed_ms = 0;
    }

    /// Advance animation by dt_ms. Returns true if value changed.
    pub fn update(self: *Animation, dt_ms: u32) bool {
        if (!self.active or self.duration_ms == 0) return false;

        self.elapsed_ms += dt_ms;
        if (self.elapsed_ms >= self.duration_ms) {
            self.value = self.to;
            self.active = false;
            self.elapsed_ms = 0;
            if (self.on_complete) |cb| {
                cb();
            }
            return true;
        }

        const t = @as(f32, @floatFromInt(self.elapsed_ms)) / @as(f32, @floatFromInt(self.duration_ms));
        const eased = self.easing(t);
        self.value = self.from + (self.to - self.from) * eased;
        return true;
    }

    /// Current interpolated value.
    pub fn get(self: *const Animation) f32 {
        return self.value;
    }

    /// True while the animation is running.
    pub fn isActive(self: *const Animation) bool {
        return self.active;
    }
};

/// Pool of concurrent animations for a panel or component.
pub const AnimationGroup = struct {
    items: [8]Animation = [_]Animation{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} },
    count: usize = 0,

    pub fn init() AnimationGroup {
        return .{};
    }

    /// Add (or restart) an animation.
    pub fn add(self: *AnimationGroup, from: f32, to: f32, duration_ms: u32, easing: *const fn (f32) f32) void {
        if (self.count >= self.items.len) return;
        self.items[self.count].start(from, to, duration_ms, easing);
        self.count += 1;
    }

    /// Add an animation at a specific slot, replacing any existing one.
    pub fn set(self: *AnimationGroup, slot: usize, from: f32, to: f32, duration_ms: u32, easing: *const fn (f32) f32) void {
        if (slot >= self.items.len) return;
        self.items[slot].start(from, to, duration_ms, easing);
        if (slot >= self.count) self.count = slot + 1;
    }

    /// Cancel the animation at `slot`.
    pub fn cancel(self: *AnimationGroup, slot: usize) void {
        if (slot < self.items.len) {
            self.items[slot].cancel();
        }
    }

    /// Advance all active animations by `dt_ms`.
    /// Returns true if any value changed.
    pub fn updateAll(self: *AnimationGroup, dt_ms: u32) bool {
        var changed = false;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.items[i].update(dt_ms)) changed = true;
        }
        return changed;
    }

    /// True if any animation is currently active.
    pub fn anyActive(self: *const AnimationGroup) bool {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.items[i].isActive()) return true;
        }
        return false;
    }

    /// Value of the animation at `slot`, or 0 if inactive/out of range.
    pub fn get(self: *const AnimationGroup, slot: usize) f32 {
        if (slot < self.items.len) return self.items[slot].get();
        return 0.0;
    }
};

test "Animation interpolates and completes" {
    var a = Animation.init();
    a.start(0.0, 100.0, 100, &Easing.linear);
    try std.testing.expect(a.active);
    try std.testing.expectEqual(0.0, a.get());

    // Halfway
    const changed = a.update(50);
    try std.testing.expect(changed);
    try std.testing.expectEqual(50.0, a.get());

    // Complete
    const changed2 = a.update(50);
    try std.testing.expect(changed2);
    try std.testing.expectEqual(100.0, a.get());
    try std.testing.expect(!a.active);
}

test "Animation easing affects value" {
    var a = Animation.init();
    a.start(0.0, 100.0, 100, &Easing.easeOutCubic);
    _ = a.update(50);
    // easeOutCubic(0.5) = 1 - 0.5^3 = 0.875, so value = 87.5
    try std.testing.expect(@as(f32, a.get()) > 50.0);
    try std.testing.expect(@as(f32, a.get()) < 100.0);
}

test "AnimationGroup tracks multiple animations" {
    var g = AnimationGroup.init();
    g.add(0.0, 10.0, 100, &Easing.linear);
    g.add(0.0, 20.0, 100, &Easing.linear);
    try std.testing.expect(g.anyActive());
    _ = g.updateAll(100);
    try std.testing.expect(!g.anyActive());
    try std.testing.expectEqual(10.0, g.get(0));
    try std.testing.expectEqual(20.0, g.get(1));
}

test "Animation cancel" {
    var a = Animation.init();
    a.start(0.0, 100.0, 1000, &Easing.linear);
    _ = a.update(100);
    try std.testing.expect(a.active);
    a.cancel();
    try std.testing.expect(!a.active);
}
