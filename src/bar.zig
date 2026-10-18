const std = @import("std");

pub const bar_mod = @import("bar/bar.zig");
pub const types = @import("bar/types.zig");

pub const Bar = bar_mod.Bar;
pub const BarContext = types.BarContext;
pub const ClickAction = types.ClickAction;
pub const ClickableArea = types.ClickableArea;

pub const launcher = @import("bar/launcher_pill.zig");
pub const omarchy = launcher;
pub const workspaces = @import("bar/workspaces.zig");
pub const custom_buttons = @import("bar/custom_buttons.zig");
pub const mpris = @import("bar/mpris.zig");
pub const clock = @import("bar/clock.zig");
pub const battery = @import("bar/battery.zig");
pub const memory = @import("bar/memory.zig");
pub const network = @import("bar/network.zig");
pub const bluetooth = @import("bar/bluetooth.zig");
pub const volume = @import("bar/volume.zig");
// pub const backlight = @import("bar/backlight.zig");
pub const theme_switch = @import("bar/theme_switch.zig");
pub const separator = @import("bar/separator.zig");

test "Bar Roman numerals" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("I", workspaces.toRoman(1, &buf));
    try std.testing.expectEqualStrings("IV", workspaces.toRoman(4, &buf));
    try std.testing.expectEqualStrings("IX", workspaces.toRoman(9, &buf));
    try std.testing.expectEqualStrings("X", workspaces.toRoman(10, &buf));
}
