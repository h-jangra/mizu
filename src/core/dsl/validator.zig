const std = @import("std");
const ast = @import("ast.zig");

pub const ValidationError = struct {
    file: []const u8,
    line: u32,
    col: u32,
    msg: []const u8,
};

pub fn validate(source_path: []const u8, root: ast.Element, errors: *std.ArrayList(ValidationError)) void {
    // Unknown tag check
    if (!isSupportedTag(root.tag)) {
        errors.append(.{
            .file = source_path,
            .line = 1, // line tracking not fully propagated; milestone baseline
            .col = 1,
            .msg = std.fmt.allocPrint(errors.allocator, "unsupported tag '{s}'", .{root.tag}) catch root.tag,
        }) catch {};
    }
    // Property validation (minimal)
    for (root.props) |prop| {
        if (prop.name.len == 0) {
            errors.append(.{
                .file = source_path,
                .line = 1,
                .col = 1,
                .msg = "empty property name",
            }) catch {};
        }
        if (std.mem.eql(u8, prop.name, "label") and prop.value.str.len == 0) {
            errors.append(.{
                .file = source_path,
                .line = 1,
                .col = 1,
                .msg = "required property 'label' missing value",
            }) catch {};
        }
    }
}

fn isSupportedTag(tag: []const u8) bool {
    return std.mem.eql(u8, tag, "row") or
           std.mem.eql(u8, tag, "column") or
           std.mem.eql(u8, tag, "container") or
           std.mem.eql(u8, tag, "box") or
           std.mem.eql(u8, tag, "panel") or
           std.mem.eql(u8, tag, "header") or
           std.mem.eql(u8, tag, "button") or
           std.mem.eql(u8, tag, "text") or
           std.mem.eql(u8, tag, "icon") or
           std.mem.eql(u8, tag, "toggle") or
           std.mem.eql(u8, tag, "slider") or
           std.mem.eql(u8, tag, "input") or
           std.mem.eql(u8, tag, "list") or
           std.mem.eql(u8, tag, "if");
}
