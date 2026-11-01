const std = @import("std");
const parser = @import("parser.zig");
const ast = @import("ast.zig");

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    const file = try std.fs.cwd().readFileAlloc(alloc, "dsl_demo.mizu", 1024);
    defer alloc.free(file);

    var p = parser.Parser.init(alloc, file);
    const root = p.parseElement();
    std.debug.print("DSL parsed tag={s} props={d}\n", .{ root.tag, root.props.items.len });
    for (root.props.items) |prop| {
        std.debug.print("  prop: {s} = {s}\n", .{ prop.name, prop.value.str });
    }
}
