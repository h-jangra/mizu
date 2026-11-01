const std = @import("std");

pub const PropValue = union(enum) {
    str: []const u8,
    num: f32,
    ident: []const u8,
    theme_ref: []const u8,
};

pub const Prop = struct {
    name: []const u8,
    value: PropValue,
};

pub const Element = struct {
    tag: []const u8,
    props: []Prop,
    children: []Element,
};

pub const ComponentDef = struct {
    name: []const u8,
    props: []Prop,
    body: Element,
};

pub const Import = struct {
    path: []const u8,
};

pub const Event = struct {
    event_type: []const u8,
    handler_name: []const u8,
};

pub const If = struct {
    condition: []const u8,
    body: []Element,
    else_body: ?[]Element,
};

pub const List = struct {
    items: []const u8,
    selected: u32,
    on_select: []const u8,
};
