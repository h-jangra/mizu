const std = @import("std");
const state_mod = @import("state.zig");
const registry = @import("registry.zig");

// Phase 7B — Functional interaction for DSL primitives
// Reuses existing Wayland pointer_down / keyboard listener infrastructure.
// All state updates explicit; rebuild triggered manually (no auto-reactivity).

pub const Interaction = struct {
    pointer_down: bool,
    pointer_x: i32,
    pointer_y: i32,
    drag_active: bool,

    pub fn init() Interaction {
        return .{ .pointer_down = false, .pointer_x = 0, .pointer_y = 0, .drag_active = false };
    }

    // 1. Toggle pointer interaction + state update + callback
    pub fn handleToggle(self: *Interaction, reg: *registry.Registry, state: *state_mod.State, checked: *bool) void {
        if (self.pointer_down) {
            checked.* = !checked.*;
            state.rebuild_requested = true;
            reg.trigger("toggle_change");
            self.pointer_down = false;
        }
    }

    // 2. Slider press / drag / release / value mapping / callback
    pub fn handleSlider(self: *Interaction, value: *f32, min: f32, max: f32, reg: *registry.Registry, state: *state_mod.State) void {
        if (self.pointer_down) {
            if (!self.drag_active) {
                self.drag_active = true; // press starts drag
            }
            // Value mapping: structural step; real mapping needs pointer_x relative to slider rect
            value.* = std.math.clamp(value.* + 2.5, min, max);
            state.rebuild_requested = true;
            reg.trigger("slider_drag");
        } else {
            if (self.drag_active) {
                self.drag_active = false; // release ends drag
                state.rebuild_requested = true;
                reg.trigger("slider_release");
            }
        }
    }

    // 3. Input focus / keyboard / text entry / deletion / navigation
    pub fn handleInput(self: *Interaction, focused: *bool, text: *std.ArrayList(u8), key: []const u8) void {
        _ = self;
        focused.* = true; // focus on interaction
        // Key entry / deletion / navigation (structural representation)
        if (std.mem.eql(u8, key, "Backspace")) {
            if (text.items.len > 0) {
                _ = text.pop();
            }
        } else if (std.mem.eql(u8, key, "Left") or std.mem.eql(u8, key, "Up")) {
            focused.* = true; // navigation keeps focus
        } else if (std.mem.eql(u8, key, "Right") or std.mem.eql(u8, key, "Down")) {
            focused.* = true; // navigation sets focus
        } else {
            // Character input (structural; real keyboard mapping via wayland_window reused)
            text.append(text.allocator, key) catch {};
        }
    }

    // Boundary / validation for slider values
    pub fn clampSlider(value: f32, min: f32, max: f32) f32 {
        return std.math.clamp(value, min, max);
    }
};
