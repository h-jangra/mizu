const std = @import("std");
const c = @import("c");

/// Monotonic time in milliseconds.
pub fn monotonicMs() u64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.tv_sec)) * 1_000 + @as(u64, @intCast(ts.tv_nsec)) / 1_000_000;
}

pub const CubicBezierParams = struct { x1: f32, y1: f32, x2: f32, y2: f32 };

/// Cubic bezier helper for M3 easing curves.
fn cubicBezier(p: CubicBezierParams, t: f32) f32 {
    const uu = 1.0 - t;
    const uu_sq = uu * uu;
    const tt = t * t;
    const tt_cu = tt * t;
    const y = 3.0 * uu_sq * t * p.y1 + 3.0 * uu * tt * p.y2 + tt_cu * 1.0;
    return y;
}

fn bezierX(p: CubicBezierParams, t: f32) f32 {
    const uu = 1.0 - t;
    const uu_sq = uu * uu;
    const tt = t * t;
    const tt_cu = tt * t;
    return 3.0 * uu_sq * t * p.x1 + 3.0 * uu * tt * p.x2 + tt_cu * 1.0;
}

pub fn applyBezier(p: CubicBezierParams, x: f32) f32 {
    if (x <= 0.0) return 0.0;
    if (x >= 1.0) return 1.0;
    var lo: f32 = 0.0;
    var hi: f32 = 1.0;
    var t: f32 = 0.5;
    for (0..32) |_| {
        const mid = lo + (hi - lo) * 0.5;
        const x_mid = bezierX(p, mid);
        if (x_mid < x) lo = mid else hi = mid;
        t = lo + (hi - lo) * 0.5;
    }
    return cubicBezier(p, t);
}

/// Reusable easing functions. All take a normalized progress `t` in [0, 1]
/// and return an eased progress in [0, 1].
pub const Easing = struct {
    pub fn linear(t: f32) f32 {
        return std.math.clamp(t, 0.0, 1.0);
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
            1.0 - (-2.0 * clamped + 2.0) * (-2.0 * clamped + 2.0) * (-2.0 * clamped + 2.0) / 2.0;
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

    /// M3 Standard easing: cubic-bezier(0.25, 0.1, 0.25, 1.0)
    pub fn standard(t: f32) f32 {
        const clamped = std.math.clamp(t, 0.0, 1.0);
        const curve = CubicBezierParams{ .x1 = 0.25, .y1 = 0.1, .x2 = 0.25, .y2 = 1.0 };
        return applyBezier(curve, clamped);
    }

    /// M3 Standard Deceleration easing: cubic-bezier(0.05, 0, 0.1, 1.0)
    pub fn standardDeceleration(t: f32) f32 {
        const clamped = std.math.clamp(t, 0.0, 1.0);
        const curve = CubicBezierParams{ .x1 = 0.05, .y1 = 0.0, .x2 = 0.1, .y2 = 1.0 };
        return applyBezier(curve, clamped);
    }

    /// M3 Standard Acceleration easing: cubic-bezier(0.3, 0, 1, 1.0)
    pub fn standardAcceleration(t: f32) f32 {
        const clamped = std.math.clamp(t, 0.0, 1.0);
        const curve = CubicBezierParams{ .x1 = 0.3, .y1 = 0.0, .x2 = 1.0, .y2 = 1.0 };
        return applyBezier(curve, clamped);
    }

    /// M3 Emphasized Deceleration easing: cubic-bezier(0.05, 0, 0.7, 1.0)
    pub fn emphasizedDeceleration(t: f32) f32 {
        const clamped = std.math.clamp(t, 0.0, 1.0);
        const curve = CubicBezierParams{ .x1 = 0.05, .y1 = 0.0, .x2 = 0.7, .y2 = 1.0 };
        return applyBezier(curve, clamped);
    }

    /// M3 Emphasized Acceleration easing: cubic-bezier(0.3, 0, 1.2, 1.0)
    pub fn emphasizedAcceleration(t: f32) f32 {
        const clamped = std.math.clamp(t, 0.0, 1.0);
        const curve = CubicBezierParams{ .x1 = 0.3, .y1 = 0.0, .x2 = 1.2, .y2 = 1.0 };
        return applyBezier(curve, clamped);
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

/// Check whether reduced motion is preferred (respect accessibility settings).
pub fn reducedMotionPreferred() bool {
    const env = c.getenv("MIZU_REDUCED_MOTION");
    if (env) |v| {
        const slice = std.mem.sliceTo(v, 0);
        if (std.mem.eql(u8, slice, "1") or std.mem.eql(u8, slice, "true")) return true;
    }
    return false;
}

/// Quick single-animation helper for 120ms fade/slide with standard easing.
pub fn quickFadeIn(anim: *Animation) void {
    if (reducedMotionPreferred()) {
        anim.start(1.0, 1.0, 0, &Easing.linear);
    } else {
        anim.start(0.0, 1.0, 120, &Easing.standard);
    }
}

pub fn quickFadeOut(anim: *Animation) void {
    if (reducedMotionPreferred()) {
        anim.start(0.0, 0.0, 0, &Easing.linear);
    } else {
        anim.start(1.0, 0.0, 130, &Easing.standard);
    }
}

/// Quick slide-up animation (from positive y offset to 0).
pub fn quickSlideUp(anim: *Animation) void {
    if (reducedMotionPreferred()) {
        anim.start(0.0, 0.0, 0, &Easing.linear);
    } else {
        anim.start(16.0, 0.0, 150, &Easing.emphasizedDeceleration);
    }
}

/// Quick slide-down animation.
pub fn quickSlideDown(anim: *Animation) void {
    if (reducedMotionPreferred()) {
        anim.start(0.0, 0.0, 0, &Easing.linear);
    } else {
        anim.start(0.0, 16.0, 140, &Easing.emphasizedDeceleration);
    }
}

/// Subtle scale animation for hover/press effects.
pub fn quickScaleUp(anim: *Animation) void {
    anim.start(1.0, 1.035, 100, &Easing.easeOutCubic);
}

pub fn quickScaleDown(anim: *Animation) void {
    anim.start(1.035, 1.0, 100, &Easing.easeOutCubic);
}

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

// Test M3 easing curves

test "M3 standard easing" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), Easing.standard(0.0), 0.001);
    try std.testing.expect(Easing.standard(0.5) > 0.0 and Easing.standard(0.5) < 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), Easing.standard(1.0), 0.001);
}

test "M3 standardDeceleration easing" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), Easing.standardDeceleration(0.0), 0.001);
    try std.testing.expect(Easing.standardDeceleration(0.5) > 0.0 and Easing.standardDeceleration(0.5) < 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), Easing.standardDeceleration(1.0), 0.001);
}

test "M3 standardAcceleration easing" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), Easing.standardAcceleration(0.0), 0.001);
    try std.testing.expect(Easing.standardAcceleration(0.5) > 0.0 and Easing.standardAcceleration(0.5) < 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), Easing.standardAcceleration(1.0), 0.001);
}

test "M3 emphasizedDeceleration easing" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), Easing.emphasizedDeceleration(0.0), 0.001);
    try std.testing.expect(Easing.emphasizedDeceleration(0.5) > 0.0 and Easing.emphasizedDeceleration(0.5) < 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), Easing.emphasizedDeceleration(1.0), 0.001);
}

test "M3 emphasizedAcceleration easing" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), Easing.emphasizedAcceleration(0.0), 0.001);
    try std.testing.expect(Easing.emphasizedAcceleration(0.5) > 0.0 and Easing.emphasizedAcceleration(0.5) < 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), Easing.emphasizedAcceleration(1.0), 0.001);
}