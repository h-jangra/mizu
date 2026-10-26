const std = @import("std");
const c = @import("../c.zig").c;

pub const Color = @import("theme.zig").Color;

const max_elements = 8192;
const max_text_words = 16384;

var arena_memory: ?[]align(64) u8 = null;
var initialized = false;
var last_error: [512]u8 = undefined;
var last_error_len: usize = 0;

pub const MeasureContext = struct {
    font: ?*anyopaque = null,
    /// Logical-to-physical scale is applied by callers, so sizes arriving from
    /// Clay are always physical pixels.
    scale: f32 = 1.0,
};

var measure_ctx = MeasureContext{};

fn errorHandler(data: c.Clay_ErrorData) callconv(.c) void {
    const text = if (data.errorText.chars != null and data.errorText.length > 0)
        data.errorText.chars[0..@intCast(data.errorText.length)]
    else
        "unknown Clay error";
    const n = @min(text.len, last_error.len);
    @memcpy(last_error[0..n], text[0..n]);
    last_error_len = n;
}

fn measureText(text: c.Clay_StringSlice, config: [*c]c.Clay_TextElementConfig, user_data: ?*anyopaque) callconv(.c) c.Clay_Dimensions {
    _ = user_data;
    const cfg = config[0];
    const font_ptr = measure_ctx.font orelse return .{ .width = 0, .height = @floatFromInt(cfg.fontSize) };
    const font: *@import("renderer.zig").Font = @ptrCast(@alignCast(font_ptr));
    const size: u32 = if (cfg.fontSize > 0) cfg.fontSize else font.size_px;
    const slice = if (text.chars != null and text.length > 0)
        text.chars[0..@intCast(text.length)]
    else
        "";
    const w = font.measureTextWithSize(slice, size);
    const h: f32 = if (cfg.lineHeight > 0)
        @floatFromInt(cfg.lineHeight)
    else
        @floatFromInt(size);
    return .{ .width = @floatFromInt(w), .height = h };
}

/// Initialize (once) and begin a layout frame. Coordinates are physical pixels.
pub fn begin(
    font: *@import("renderer.zig").Font,
    width: u32,
    height: u32,
    pointer_x: f32,
    pointer_y: f32,
    pointer_down: bool,
    scroll_x: f32,
    scroll_y: f32,
    delta_s: f32,
) !void {
    if (!initialized) {
        // Set limits before asking Clay how much memory it needs.
        c.Clay_SetMaxElementCount(max_elements);
        c.Clay_SetMaxMeasureTextCacheWordCount(max_text_words);

        const size = c.Clay_MinMemorySize();
        const mem = try std.heap.page_allocator.alignedAlloc(u8, std.mem.Alignment.@"64", @intCast(size));
        arena_memory = mem;

        const arena = c.Clay_CreateArenaWithCapacityAndMemory(size, mem.ptr);
        const handler = c.Clay_ErrorHandler{
            .errorHandlerFunction = errorHandler,
            .userData = null,
        };
        const ctx = c.Clay_Initialize(arena, .{ .width = @floatFromInt(width), .height = @floatFromInt(height) }, handler);
        if (ctx == null) return error.ClayInitFailed;
        c.Clay_SetMeasureTextFunction(measureText, &measure_ctx);
        initialized = true;
    }

    measure_ctx.font = font;
    c.Clay_SetLayoutDimensions(.{ .width = @floatFromInt(width), .height = @floatFromInt(height) });
    c.Clay_SetPointerState(.{ .x = pointer_x, .y = pointer_y }, pointer_down);
    c.Clay_UpdateScrollContainers(false, .{ .x = scroll_x, .y = scroll_y }, delta_s);
    c.Clay_BeginLayout();
}

pub fn end(delta_s: f32) c.Clay_RenderCommandArray {
    return c.Clay_EndLayout(delta_s);
}

pub fn lastError() []const u8 {
    return last_error[0..last_error_len];
}

pub fn string(s: []const u8) c.Clay_String {
    return .{
        .length = @intCast(s.len),
        .isStaticallyAllocated = false,
        .chars = if (s.len > 0) s.ptr else null,
    };
}

pub fn color(col: Color) c.Clay_Color {
    return .{
        .r = @floatFromInt(col.r),
        .g = @floatFromInt(col.g),
        .b = @floatFromInt(col.b),
        .a = @floatFromInt(col.a),
    };
}

pub fn elementId(name: []const u8, index: u32) c.Clay_ElementId {
    return c.Clay_GetElementIdWithIndex(string(name), index);
}

pub fn open(id: c.Clay_ElementId, decl: c.Clay_ElementDeclaration) void {
    c.Clay__OpenElementWithId(id);
    c.Clay__ConfigureOpenElement(decl);
}

pub fn close() void {
    c.Clay__CloseElement();
}

pub fn openText(text: []const u8, config: c.Clay_TextElementConfig) void {
    c.Clay__OpenTextElement(string(text), config);
}

pub fn rectOf(id: c.Clay_ElementId) ?@import("renderer.zig").Rect {
    const data = c.Clay_GetElementData(id);
    if (!data.found) return null;
    const x: i32 = @intFromFloat(std.math.floor(data.boundingBox.x));
    const y: i32 = @intFromFloat(std.math.floor(data.boundingBox.y));
    const w: u32 = @intFromFloat(std.math.ceil(@max(0.0, data.boundingBox.width)));
    const h: u32 = @intFromFloat(std.math.ceil(@max(0.0, data.boundingBox.height)));
    return .{ .x = x, .y = y, .w = w, .h = h };
}

pub fn pointerOver(id: c.Clay_ElementId) bool {
    return c.Clay_PointerOver(id);
}

pub fn declarations() []const u8 {
    return "";
}
