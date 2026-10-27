const std = @import("std");
const c = @import("../c.zig").c;
const clay = @import("clay.zig");
const renderer = @import("renderer.zig");
const theme = @import("theme.zig");
const icons = @import("../graphics/icons.zig");

pub const Color = theme.Color;
pub const Rect = renderer.Rect;
pub const Font = renderer.Font;

pub const Direction = enum { row, column };
pub const AlignX = enum { left, center, right };
pub const AlignY = enum { top, center, bottom };

pub const Edges = struct {
    left: u16 = 0,
    right: u16 = 0,
    top: u16 = 0,
    bottom: u16 = 0,

    pub fn all(v: u16) Edges {
        return .{ .left = v, .right = v, .top = v, .bottom = v };
    }
    pub fn xy(x: u16, y: u16) Edges {
        return .{ .left = x, .right = x, .top = y, .bottom = y };
    }
};

pub const Size = union(enum) {
    fit,
    grow: struct { min: f32 = 0, max: f32 = std.math.floatMax(f32) },
    fixed: f32,
    percent: f32,

    pub fn px(v: f32) Size {
        return .{ .fixed = v };
    }
    pub fn growMin(min: f32) Size {
        return .{ .grow = .{ .min = min } };
    }
};

pub const BoxOptions = struct {
    id: ?[]const u8 = null,
    index: u32 = 0,
    width: Size = .fit,
    height: Size = .fit,
    direction: Direction = .row,
    align_x: AlignX = .left,
    align_y: AlignY = .top,
    padding: Edges = .{},
    gap: u16 = 0,
    bg: ?Color = null,
    radius: f32 = 0,
    border: u16 = 0,
    border_color: ?Color = null,
    clip_horizontal: bool = false,
    clip_vertical: bool = false,
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
};

pub const TextOptions = struct {
    id: ?[]const u8 = null,
    index: u32 = 0,
    size: u32 = 14,
    color: Color = Color.rgb(255, 255, 255),
    width: ?f32 = null,
    height: ?f32 = null,
    wrap: bool = false,
    text_align: AlignX = .left,
    line_height: ?u16 = null,
};

pub const Custom = union(enum) {
    icon: struct {
        name: []const u8,
        size: u32,
        scale: u32,
        color: Color,
        rotation: f32 = 0.0,
    },
    callback: struct {
        function: *const fn (target: renderer.Renderer, rect: Rect, data: *const anyopaque) void,
        data: *const anyopaque,
    },
};

pub const Ui = struct {
    allocator: std.mem.Allocator,
    font: *Font,
    width: u32,
    height: u32,
    scale: u32,
    depth: i32 = 0,
    ended: bool = false,
    overlay: ?Color = null,
    overlay_stack: [16]?Color = [_]?Color{null} ** 16,
    overlay_depth: usize = 0,
    clip_stack: [32]Rect = undefined,
    clip_depth: usize = 0,
    next_custom_index: u32 = 0,

    pub fn begin(
        allocator: std.mem.Allocator,
        font: *Font,
        width: u32,
        height: u32,
        scale: u32,
        pointer_x: i32,
        pointer_y: i32,
        pointer_down: bool,
        delta_s: f32,
    ) !Ui {
        maybeResetArena(allocator);
        const pointer_px: f32 = if (pointer_x < -1000) -10000 else @floatFromInt(pointer_x * @as(i32, @intCast(scale)));
        const pointer_py: f32 = if (pointer_y < -1000) -10000 else @floatFromInt(pointer_y * @as(i32, @intCast(scale)));
        try clay.begin(
            font,
            width,
            height,
            pointer_px,
            pointer_py,
            pointer_down,
            0,
            0,
            delta_s,
        );
        return .{
            .allocator = global_arena.allocator(),
            .font = font,
            .width = width,
            .height = height,
            .scale = scale,
        };
    }

    pub fn deinit(self: *Ui) void {
        _ = self;
        frame_active = false;
    }

    pub fn px(self: *const Ui, logical: u32) f32 {
        return @floatFromInt(logical * self.scale);
    }

    pub fn s(self: *const Ui, logical: u32) f32 {
        return @floatFromInt(logical * self.scale);
    }

    pub fn su(self: *const Ui, logical: u32) u16 {
        return @intCast(logical * self.scale);
    }

    pub fn f(self: *const Ui, logical: anytype) f32 {
        return @as(f32, @floatFromInt(logical)) * @as(f32, @floatFromInt(self.scale));
    }

    /// Open the full-surface root container. Callers can leave it open;
    /// endLayout closes it.
    pub fn root(self: *Ui, opts: BoxOptions) void {
        var o = opts;
        o.width = .{ .fixed = @floatFromInt(self.width) };
        o.height = .{ .fixed = @floatFromInt(self.height) };
        _ = self.open(o);
    }

    pub fn open(self: *Ui, opts: BoxOptions) c.Clay_ElementId {
        var decl = std.mem.zeroes(c.Clay_ElementDeclaration);
        decl.layout.sizing.width = sizeAxis(opts.width);
        decl.layout.sizing.height = sizeAxis(opts.height);
        decl.layout.padding = .{
            .left = opts.padding.left,
            .right = opts.padding.right,
            .top = opts.padding.top,
            .bottom = opts.padding.bottom,
        };
        decl.layout.childGap = opts.gap;
        decl.layout.layoutDirection = if (opts.direction == .column)
            c.CLAY_TOP_TO_BOTTOM
        else
            c.CLAY_LEFT_TO_RIGHT;
        decl.layout.childAlignment = .{
            .x = switch (opts.align_x) {
                .left => c.CLAY_ALIGN_X_LEFT,
                .center => c.CLAY_ALIGN_X_CENTER,
                .right => c.CLAY_ALIGN_X_RIGHT,
            },
            .y = switch (opts.align_y) {
                .top => c.CLAY_ALIGN_Y_TOP,
                .center => c.CLAY_ALIGN_Y_CENTER,
                .bottom => c.CLAY_ALIGN_Y_BOTTOM,
            },
        };
        if (opts.bg) |bg| decl.backgroundColor = clay.color(bg);
        decl.cornerRadius = .{
            .topLeft = opts.radius,
            .topRight = opts.radius,
            .bottomLeft = opts.radius,
            .bottomRight = opts.radius,
        };
        if (opts.border > 0) {
            decl.border = .{
                .color = clay.color(opts.border_color orelse theme.Color.rgb(255, 255, 255)),
                .width = .{
                    .left = opts.border,
                    .right = opts.border,
                    .top = opts.border,
                    .bottom = opts.border,
                    .betweenChildren = 0,
                },
            };
        }
        if (opts.clip_horizontal or opts.clip_vertical) {
            decl.clip = .{
                .horizontal = opts.clip_horizontal,
                .vertical = opts.clip_vertical,
                .childOffset = .{ .x = -opts.scroll_x, .y = -opts.scroll_y },
            };
        }

        var id: c.Clay_ElementId = undefined;
        if (opts.id) |name| {
            id = clay.elementId(name, opts.index);
            clay.open(id, decl);
        } else {
            c.Clay__OpenElement();
            c.Clay__ConfigureOpenElementPtr(&decl);
            id = c.Clay_GetElementId(clay.string(""));
        }
        self.depth += 1;
        return id;
    }

    pub fn close(self: *Ui) void {
        if (self.depth <= 0) return;
        clay.close();
        self.depth -= 1;
    }

    pub fn hovered(self: *const Ui, name: []const u8, index: u32) bool {
        _ = self;
        return clay.pointerOver(clay.elementId(name, index));
    }

    pub fn text(self: *Ui, contents: []const u8, opts: TextOptions) void {
        const owned = self.allocator.dupe(u8, contents) catch return;
        var cfg = std.mem.zeroes(c.Clay_TextElementConfig);
        cfg.textColor = clay.color(opts.color);
        cfg.fontId = 0;
        cfg.fontSize = @intCast(opts.size);
        cfg.lineHeight = opts.line_height orelse @intCast(opts.size + 3);
        cfg.letterSpacing = 0;
        cfg.wrapMode = if (opts.wrap) c.CLAY_TEXT_WRAP_WORDS else c.CLAY_TEXT_WRAP_NONE;
        cfg.textAlignment = switch (opts.text_align) {
            .left => c.CLAY_TEXT_ALIGN_LEFT,
            .center => c.CLAY_TEXT_ALIGN_CENTER,
            .right => c.CLAY_TEXT_ALIGN_RIGHT,
        };
        if (opts.width != null or opts.height != null) {
            // Text configs cannot size themselves; wrap in a sized box only
            // when the caller needs an explicit alignment box.
            var decl = std.mem.zeroes(c.Clay_ElementDeclaration);
            if (opts.width) |w| decl.layout.sizing.width = sizeAxis(.{ .fixed = w });
            if (opts.height) |h| decl.layout.sizing.height = sizeAxis(.{ .fixed = h });
            decl.layout.childAlignment = .{
                .x = switch (opts.text_align) {
                    .left => c.CLAY_ALIGN_X_LEFT,
                    .center => c.CLAY_ALIGN_X_CENTER,
                    .right => c.CLAY_ALIGN_X_RIGHT,
                },
                .y = c.CLAY_ALIGN_Y_CENTER,
            };
            c.Clay__OpenElement();
            c.Clay__ConfigureOpenElementPtr(&decl);
            self.depth += 1;
            clay.openText(owned, cfg);
            self.close();
        } else {
            clay.openText(owned, cfg);
        }
    }

    pub fn icon(self: *Ui, name: []const u8, size: u32, color: Color, index: u32) void {
        self.iconRotated(name, size, color, 0.0, index);
    }

    pub fn iconRotated(self: *Ui, name: []const u8, size: u32, color: Color, rotation: f32, index: u32) void {
        const data = self.allocator.create(Custom) catch return;
        data.* = .{ .icon = .{
            .name = name,
            .size = size,
            .scale = self.scale,
            .color = color,
            .rotation = rotation,
        } };
        self.custom(.{ .fixed = @floatFromInt(size) }, .{ .fixed = @floatFromInt(size) }, data, index);
        self.close();
    }

    pub fn custom(self: *Ui, width: Size, height: Size, data: *const Custom, index: u32) void {
        _ = index;
        var decl = std.mem.zeroes(c.Clay_ElementDeclaration);
        decl.layout.sizing.width = sizeAxis(width);
        decl.layout.sizing.height = sizeAxis(height);
        decl.custom.customData = @ptrCast(@constCast(data));
        decl.userData = @ptrCast(@constCast(data));
        const custom_index = self.next_custom_index;
        self.next_custom_index += 1;
        c.Clay__OpenElementWithId(clay.elementId("custom", custom_index));
        c.Clay__ConfigureOpenElementPtr(&decl);
        self.depth += 1;
    }

    pub fn box(self: *Ui, opts: BoxOptions) c.Clay_ElementId {
        return self.open(opts);
    }

    pub fn spacer(self: *Ui, width: f32, height: f32) void {
        _ = self.open(.{ .width = .{ .fixed = width }, .height = .{ .fixed = height } });
        self.close();
    }

    pub fn spacerSized(self: *Ui, width: Size, height: Size) void {
        _ = self.open(.{ .width = width, .height = height });
        self.close();
    }

    pub fn growSpacer(self: *Ui, axis: Direction) void {
        switch (axis) {
            .row => self.spacerSized(.{ .grow = .{} }, .{ .fixed = 0 }),
            .column => self.spacerSized(.{ .fixed = 0 }, .{ .grow = .{} }),
        }
    }

    pub fn rect(self: *Ui, width: Size, height: Size, bg: Color, radius: f32, opts: BoxOptions) void {
        var o = opts;
        o.width = width;
        o.height = height;
        o.bg = bg;
        o.radius = radius;
        _ = self.open(o);
        self.close();
    }

    pub fn image(self: *Ui, img: *const renderer.Image, width: Size, height: Size, tint: ?Color, index: u32) void {
        _ = index;
        var decl = std.mem.zeroes(c.Clay_ElementDeclaration);
        decl.layout.sizing.width = sizeAxis(width);
        decl.layout.sizing.height = sizeAxis(height);
        decl.image.imageData = @ptrCast(@constCast(img));
        if (tint) |col| decl.backgroundColor = clay.color(col);
        const image_index = self.next_custom_index;
        self.next_custom_index += 1;
        c.Clay__OpenElementWithId(clay.elementId("image", image_index));
        c.Clay__ConfigureOpenElementPtr(&decl);
        self.depth += 1;
        self.close();
    }

    pub fn endLayout(self: *Ui) c.Clay_RenderCommandArray {
        if (!self.ended) {
            while (self.depth > 0) self.close();
            self.ended = true;
        }
        return clay.end(1.0 / 60.0);
    }

    pub fn rectOf(self: *const Ui, name: []const u8, index: u32) ?Rect {
        _ = self;
        return clay.rectOf(clay.elementId(name, index));
    }

    pub fn render(self: *Ui, target: renderer.Renderer, commands: c.Clay_RenderCommandArray) void {
        var surface = target;
        self.clip_stack[0] = target.active_clip;
        self.clip_depth = 1;
        self.overlay = null;
        self.overlay_depth = 0;
        const debug = c.getenv("MIZU_CLAY_DEBUG") != null;
        var i: i32 = 0;
        while (i < commands.length) : (i += 1) {
            const cmd = commands.internalArray[@intCast(i)];
            if (debug) {
                std.debug.print(
                    "clay cmd {d}: box=({d:.1},{d:.1},{d:.1},{d:.1})\n",
                    .{ cmd.commandType, cmd.boundingBox.x, cmd.boundingBox.y, cmd.boundingBox.width, cmd.boundingBox.height },
                );
            }
            self.renderCommand(&surface, cmd);
        }
    }

    fn renderCommand(self: *Ui, target: *renderer.Renderer, cmd: c.Clay_RenderCommand) void {
        const bx: i32 = @intFromFloat(std.math.floor(cmd.boundingBox.x));
        const by: i32 = @intFromFloat(std.math.floor(cmd.boundingBox.y));
        const bw: u32 = @intFromFloat(std.math.ceil(@max(0.0, cmd.boundingBox.width)));
        const bh: u32 = @intFromFloat(std.math.ceil(@max(0.0, cmd.boundingBox.height)));
        const bounds = Rect{ .x = bx, .y = by, .w = bw, .h = bh };

        switch (cmd.commandType) {
            c.CLAY_RENDER_COMMAND_TYPE_RECTANGLE => {
                const data = cmd.renderData.rectangle;
                const col = self.applyOverlay(rectFromClay(data.backgroundColor));
                if (col.a == 0 or bw == 0 or bh == 0) return;
                const radius: u32 = @intFromFloat(@max(
                    @max(data.cornerRadius.topLeft, data.cornerRadius.topRight),
                    @max(data.cornerRadius.bottomLeft, data.cornerRadius.bottomRight),
                ));
                target.fillRoundedRect(bx, by, bw, bh, radius, col);
            },
            c.CLAY_RENDER_COMMAND_TYPE_BORDER => {
                const data = cmd.renderData.border;
                const col = self.applyOverlay(rectFromClay(data.color));
                if (col.a == 0) return;
                const radius: u32 = @intFromFloat(@max(
                    @max(data.cornerRadius.topLeft, data.cornerRadius.topRight),
                    @max(data.cornerRadius.bottomLeft, data.cornerRadius.bottomRight),
                ));
                const w = data.width;
                if (w.left == w.right and w.top == w.bottom and w.left == w.top) {
                    target.drawRoundedBorder(bx, by, bw, bh, radius, w.left, col);
                } else {
                    drawBorderSides(target.*, bounds, radius, w, col);
                }
            },
            c.CLAY_RENDER_COMMAND_TYPE_TEXT => {
                const data = cmd.renderData.text;
                const col = self.applyOverlay(rectFromClay(data.textColor));
                const size: u32 = if (data.fontSize > 0) data.fontSize else self.font.size_px;
                const slice = if (data.stringContents.chars != null and data.stringContents.length > 0)
                    data.stringContents.chars[0..@intCast(data.stringContents.length)]
                else
                    "";
                if (slice.len == 0 or col.a == 0) return;
                const ascent = self.font.ascentForSize(size);
                const baseline = by + @divTrunc(@as(i32, @intCast(bh)) + ascent, 2) - 1;
                target.drawTextWithSpacing(self.font, slice, bx, baseline, size, col, data.letterSpacing);
            },
            c.CLAY_RENDER_COMMAND_TYPE_IMAGE => {
                const data = cmd.renderData.image;
                if (data.imageData == null) {
                    std.debug.print("mizu: Clay image command without imageData\n", .{});
                    return;
                }
                const img: *const renderer.Image = @ptrCast(@alignCast(data.imageData));
                const tint = rectFromClay(data.backgroundColor);
                if (tint.a > 0) {
                    target.drawImageTinted(img, @floatFromInt(bx), @floatFromInt(by), @floatFromInt(bw), @floatFromInt(bh), tint);
                } else {
                    target.drawImage(img, @floatFromInt(bx), @floatFromInt(by), @floatFromInt(bw), @floatFromInt(bh));
                }
            },
            c.CLAY_RENDER_COMMAND_TYPE_SCISSOR_START => {
                if (self.clip_depth >= self.clip_stack.len) {
                    std.debug.print("mizu: Clay scissor stack overflow\n", .{});
                    return;
                }
                const clipped = target.withClip(bounds);
                self.clip_stack[self.clip_depth] = clipped.active_clip;
                self.clip_depth += 1;
                target.active_clip = clipped.active_clip;
            },
            c.CLAY_RENDER_COMMAND_TYPE_SCISSOR_END => {
                if (self.clip_depth > 1) {
                    self.clip_depth -= 1;
                    target.active_clip = self.clip_stack[self.clip_depth - 1];
                }
            },
            c.CLAY_RENDER_COMMAND_TYPE_OVERLAY_COLOR_START => {
                if (self.overlay_depth >= self.overlay_stack.len) {
                    std.debug.print("mizu: Clay overlay stack overflow\n", .{});
                    return;
                }
                self.overlay_stack[self.overlay_depth] = self.overlay;
                self.overlay_depth += 1;
                self.overlay = rectFromClay(cmd.renderData.overlayColor.color);
            },
            c.CLAY_RENDER_COMMAND_TYPE_OVERLAY_COLOR_END => {
                if (self.overlay_depth > 0) {
                    self.overlay_depth -= 1;
                    self.overlay = self.overlay_stack[self.overlay_depth];
                } else {
                    self.overlay = null;
                }
            },
            c.CLAY_RENDER_COMMAND_TYPE_CUSTOM => {
                if (cmd.renderData.custom.customData == null) {
                    std.debug.print("mizu: Clay custom command without data\n", .{});
                    return;
                }
                const data: *const Custom = @ptrCast(@alignCast(cmd.renderData.custom.customData));
                switch (data.*) {
                    .icon => |ic| {
                        if (ic.size == 0) return;
                        const raster = icons.getIcon(std.heap.c_allocator, ic.name, ic.size, ic.scale) orelse {
                            std.debug.print("mizu: missing icon '{s}'\n", .{ic.name});
                            return;
                        };
                        const cx = bounds.x + @divTrunc(@as(i32, @intCast(bounds.w)), 2);
                        const cy = bounds.y + @divTrunc(@as(i32, @intCast(bounds.h)), 2);
                        if (ic.rotation != 0.0) {
                            icons.drawIconRasterRotated(target.*, raster, cx, cy, ic.rotation, self.applyOverlay(ic.color));
                        } else {
                            icons.drawIconRaster(target.*, raster, cx, cy, self.applyOverlay(ic.color));
                        }
                    },
                    .callback => |cb| cb.function(target.*, bounds, cb.data),
                }
            },
            c.CLAY_RENDER_COMMAND_TYPE_NONE => {},
            else => {
                std.debug.print("mizu: unsupported Clay render command {d}\n", .{cmd.commandType});
            },
        }

        // SCISSOR_START changes the clip for following commands. Because the
        // renderer is passed by value, the caller loop applies it here.
        if (cmd.commandType == c.CLAY_RENDER_COMMAND_TYPE_SCISSOR_START) {
            target.active_clip = self.clip_stack[self.clip_depth - 1];
        } else if (cmd.commandType == c.CLAY_RENDER_COMMAND_TYPE_SCISSOR_END) {
            target.active_clip = self.clip_stack[self.clip_depth - 1];
        }
    }

    fn applyOverlay(self: *const Ui, col_in: Color) Color {
        const ov = self.overlay orelse return col_in;
        if (ov.a == 0) return col_in;
        const t = @as(f32, @floatFromInt(ov.a)) / 255.0;
        return Color.init(
            col_in.a,
            @intFromFloat(@as(f32, @floatFromInt(col_in.r)) * (1.0 - t) + @as(f32, @floatFromInt(ov.r)) * t),
            @intFromFloat(@as(f32, @floatFromInt(col_in.g)) * (1.0 - t) + @as(f32, @floatFromInt(ov.g)) * t),
            @intFromFloat(@as(f32, @floatFromInt(col_in.b)) * (1.0 - t) + @as(f32, @floatFromInt(ov.b)) * t),
        );
    }
};

fn rectFromClay(col: c.Clay_Color) Color {
    return Color.init(
        @intFromFloat(std.math.clamp(col.a, 0, 255)),
        @intFromFloat(std.math.clamp(col.r, 0, 255)),
        @intFromFloat(std.math.clamp(col.g, 0, 255)),
        @intFromFloat(std.math.clamp(col.b, 0, 255)),
    );
}

fn sizeAxis(size: Size) c.Clay_SizingAxis {
    return switch (size) {
        .fit => .{ .size = .{ .minMax = .{ .min = 0, .max = 0 } }, .type = c.CLAY__SIZING_TYPE_FIT },
        .grow => |g| .{ .size = .{ .minMax = .{ .min = g.min, .max = g.max } }, .type = c.CLAY__SIZING_TYPE_GROW },
        .fixed => |v| .{ .size = .{ .minMax = .{ .min = v, .max = v } }, .type = c.CLAY__SIZING_TYPE_FIXED },
        .percent => |p| .{ .size = .{ .percent = p }, .type = c.CLAY__SIZING_TYPE_PERCENT },
    };
}

fn drawBorderSides(target: renderer.Renderer, rect: Rect, radius: u32, w: c.Clay_BorderWidth, col: Color) void {
    _ = radius;
    if (w.top > 0) target.fillRect(rect.x, rect.y, rect.w, w.top, col);
    if (w.bottom > 0) target.fillRect(rect.x, rect.y + @as(i32, @intCast(rect.h)) - w.bottom, rect.w, w.bottom, col);
    if (w.left > 0) target.fillRect(rect.x, rect.y, w.left, rect.h, col);
    if (w.right > 0) target.fillRect(rect.x + @as(i32, @intCast(rect.w)) - w.right, rect.y, w.right, rect.h, col);
}

// Global arena reused across frames with retain_capacity.
var global_arena: std.heap.ArenaAllocator = undefined;
var global_arena_ready = false;
var frame_active = false;

fn maybeResetArena(_: std.mem.Allocator) void {
    if (!global_arena_ready) {
        // Process-lifetime frame arena backed by page allocator.
        global_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        global_arena_ready = true;
    } else if (!frame_active) {
        _ = global_arena.reset(.retain_capacity);
    }
    frame_active = true;
}
