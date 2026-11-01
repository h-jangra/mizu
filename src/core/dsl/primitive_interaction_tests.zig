// Phase 7B — Event dispatch, state updates, callbacks, boundary conditions
const std = @import("std");
const interaction = @import("interaction.zig");
const state_mod = @import("state.zig");
const registry = @import("registry.zig");

pub fn testToggleClick() bool {
    var checked = false;
    var state = state_mod.State{ .label_text = "Test", .rebuild_requested = false };
    var reg = registry.Registry.init(std.heap.page_allocator);
    reg.register("toggle_change");
    var inter = interaction.Interaction.init();
    inter.pointer_down = true;
    inter.handleToggle(&reg, &state, &checked);
    return checked == true and state.rebuild_requested == true;
}

pub fn testSliderPressDragRelease() bool {
    var value: f32 = 50.0;
    var state = state_mod.State{ .label_text = "S", .rebuild_requested = false };
    var reg = registry.Registry.init(std.heap.page_allocator);
    reg.register("slider_drag");
    var inter = interaction.Interaction.init();
    inter.pointer_down = true;
    inter.handleSlider(&value, 0.0, 100.0, &reg, &state);
    return value > 50.0 and inter.drag_active == true; // press/drag
}

pub fn testSliderBoundary() bool {
    return interaction.Interaction.clampSlider(150.0, 0.0, 100.0) == 100.0 and
           interaction.Interaction.clampSlider(-10.0, 0.0, 100.0) == 0.0;
}

pub fn testInputDeletionAndFocus() bool {
    const alloc = std.heap.page_allocator;
    var list = std.ArrayList(u8).empty;
    try list.appendSlice(alloc, "hello");
    var focused = false;
    var inter = interaction.Interaction.init();
    inter.handleInput(&focused, &list, "Backspace");
    return list.items.len == 4 and focused == true;
}

pub fn testStateRebuildExplicit() bool {
    var s = state_mod.State{ .label_text = "X", .rebuild_requested = false };
    s.requestRebuild();
    return s.rebuild_requested == true;
}
