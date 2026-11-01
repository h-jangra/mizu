const std = @import("std");
const ast = @import("ast.zig");

pub const Toggle = struct {
    checked: bool,
    on_change: *const fn(void) void,
}

pub const Slider = struct {
    min: f32,
    max: f32,
    value: f32,
    on_drag: *const fn(f32) void,
}

pub const Input = struct {
    value: []const u8,
    on_change: *const fn([]const u8) void,
    on_submit: *const fn(void) void,
}

pub const If = struct {
    condition: []const u8,
    body: ast.Element,
    else_body: ?ast.Element,
}

pub const List = struct {
    items: []const u8,
    selected: u32,
    on_select: *const fn(u32) void,
}