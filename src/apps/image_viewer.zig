const std = @import("std");
const c = @import("../c.zig").c;
const buffer = @import("../core/buffer.zig");
const renderer = @import("../core/renderer.zig");
const theme = @import("../core/theme.zig");
const config = @import("../core/config.zig");
const wayland_win = @import("../core/wayland_window.zig");
const image_ops = @import("../graphics/image_ops.zig");

const Color = theme.Color;
const Rect = renderer.Rect;
const Font = renderer.Font;
const ImageBuffer = image_ops.ImageBuffer;
const UndoStack = image_ops.UndoStack;
const WindowApp = wayland_win.WindowApp;

pub const Mode = enum {
    view,
    crop,
    adjust,
    info,
};

pub const Adjustments = struct {
    brightness: f32 = 0.0, // -1.0 to 1.0
    contrast: f32 = 1.0,   // 0.0 to 2.0
    saturation: f32 = 1.0, // 0.0 to 2.0
    blur: u32 = 0,         // 0 to 20
    grayscale: bool = false,

    pub fn isDefault(self: Adjustments) bool {
        return self.brightness == 0.0 and
            self.contrast == 1.0 and
            self.saturation == 1.0 and
            self.blur == 0 and
            !self.grayscale;
    }

    pub fn reset(self: *Adjustments) void {
        self.* = Adjustments{};
    }
};

pub const ImageViewerApp = struct {
    allocator: std.mem.Allocator,
    win: *WindowApp,
    font: *Font,
    cfg: config.Config,

    base_image: ImageBuffer,      // Image without temporary uncommitted adjustments
    display_image: ImageBuffer,   // Currently shown image (with live adjustments if adjusting)
    file_path: ?[]const u8 = null,
    file_size_bytes: usize = 0,
    undo_stack: UndoStack,

    mode: Mode = .view,
    adjustments: Adjustments = .{},

    // Zoom & Pan
    zoom: f32 = 1.0,
    pan_x: f32 = 0.0,
    pan_y: f32 = 0.0,
    is_panning: bool = false,
    pan_start_x: i32 = 0,
    pan_start_y: i32 = 0,

    // Interactive Crop State
    is_cropping: bool = false,
    crop_start_x: i32 = 0,
    crop_start_y: i32 = 0,
    crop_curr_x: i32 = 0,
    crop_curr_y: i32 = 0,

    // Active Slider dragging in Adjustments panel
    active_slider: ?enum { brightness, contrast, saturation, blur } = null,

    // UI feedback
    status_msg: [128]u8 = [_]u8{0} ** 128,
    status_len: usize = 0,
    status_ticks: u32 = 0,

    toolbar_height: u32 = 46,
    statusbar_height: u32 = 28,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config, image_to_load: ?ImageBuffer, file_path: ?[]const u8) !*ImageViewerApp {
        var win = try WindowApp.init(allocator, .{
            .title = "Mizu Image",
            .app_id = "mizu-image",
            .width = 1100,
            .height = 720,
            .min_width = 600,
            .min_height = 400,
        });
        errdefer win.deinit();

        const font = try allocator.create(Font);
        font.* = try Font.init(allocator, cfg.theme.font_family, 13);
        errdefer {
            font.deinit();
            allocator.destroy(font);
        }

        var base = if (image_to_load) |loaded|
            loaded
        else
            try ImageBuffer.init(allocator, 800, 600, Color.rgb(240, 242, 245));
        errdefer base.deinit();

        var display = try base.clone(allocator);
        errdefer display.deinit();

        const path_copy = if (file_path) |p| try allocator.dupe(u8, p) else null;

        var f_size: usize = 0;
        if (file_path) |p| {
            var st: c.struct_stat = undefined;
            const p_z = try allocator.dupeZ(u8, p);
            defer allocator.free(p_z);
            if (c.stat(p_z.ptr, &st) == 0) {
                f_size = @intCast(st.st_size);
            }
        }

        const app = try allocator.create(ImageViewerApp);
        app.* = .{
            .allocator = allocator,
            .win = win,
            .font = font,
            .cfg = cfg,
            .base_image = base,
            .display_image = display,
            .file_path = path_copy,
            .file_size_bytes = f_size,
            .undo_stack = UndoStack.init(allocator, 25),
        };

        app.fitToWindow();
        return app;
    }

    pub fn deinit(self: *ImageViewerApp) void {
        const alloc = self.allocator;
        if (self.file_path) |p| alloc.free(p);
        self.undo_stack.deinit();
        self.display_image.deinit();
        self.base_image.deinit();
        self.font.deinit();
        alloc.destroy(self.font);
        self.win.deinit();
        alloc.destroy(self);
    }

    pub fn setStatus(self: *ImageViewerApp, msg: []const u8) void {
        const copy_len = @min(msg.len, self.status_msg.len - 1);
        @memcpy(self.status_msg[0..copy_len], msg[0..copy_len]);
        self.status_msg[copy_len] = 0;
        self.status_len = copy_len;
        self.status_ticks = 150;
        self.win.needs_redraw = true;
    }

    pub fn canvasRect(self: *const ImageViewerApp) Rect {
        const w = self.win.width;
        const h = self.win.height;
        const ch = if (h > self.toolbar_height + self.statusbar_height)
            h - self.toolbar_height - self.statusbar_height
        else
            0;
        return Rect{
            .x = 0,
            .y = @intCast(self.toolbar_height),
            .w = w,
            .h = ch,
        };
    }

    pub fn fitToWindow(self: *ImageViewerApp) void {
        const c_rect = self.canvasRect();
        if (c_rect.w == 0 or c_rect.h == 0 or self.display_image.width == 0 or self.display_image.height == 0) return;

        const avail_w = @as(f32, @floatFromInt(c_rect.w - 40));
        const avail_h = @as(f32, @floatFromInt(c_rect.h - 40));
        const img_w = @as(f32, @floatFromInt(self.display_image.width));
        const img_h = @as(f32, @floatFromInt(self.display_image.height));

        const scale_w = avail_w / img_w;
        const scale_h = avail_h / img_h;
        self.zoom = std.math.clamp(@min(scale_w, scale_h), 0.05, 5.0);

        const displayed_w = img_w * self.zoom;
        const displayed_h = img_h * self.zoom;
        self.pan_x = @as(f32, @floatFromInt(c_rect.x)) + (@as(f32, @floatFromInt(c_rect.w)) - displayed_w) / 2.0;
        self.pan_y = @as(f32, @floatFromInt(c_rect.y)) + (@as(f32, @floatFromInt(c_rect.h)) - displayed_h) / 2.0;
        self.win.needs_redraw = true;
    }

    pub fn screenToImageX(self: *const ImageViewerApp, sx: i32) i32 {
        return @intFromFloat((@as(f32, @floatFromInt(sx)) - self.pan_x) / self.zoom);
    }

    pub fn screenToImageY(self: *const ImageViewerApp, sy: i32) i32 {
        return @intFromFloat((@as(f32, @floatFromInt(sy)) - self.pan_y) / self.zoom);
    }

    pub fn imageToScreenX(self: *const ImageViewerApp, ix: i32) i32 {
        return @intFromFloat(self.pan_x + @as(f32, @floatFromInt(ix)) * self.zoom);
    }

    pub fn imageToScreenY(self: *const ImageViewerApp, iy: i32) i32 {
        return @intFromFloat(self.pan_y + @as(f32, @floatFromInt(iy)) * self.zoom);
    }

    // ==========================================
    // Transformations: Rotate, Flip, Crop, Resize
    // ==========================================

    pub fn rotate(self: *ImageViewerApp, clockwise: bool) !void {
        try self.undo_stack.pushState(&self.base_image);
        const rotated = if (clockwise)
            try self.base_image.rotate90(self.allocator)
        else
            try self.base_image.rotate270(self.allocator);

        self.base_image.deinit();
        self.base_image = rotated;
        self.refreshDisplayImage();
        self.fitToWindow();
        self.setStatus(if (clockwise) "Rotated 90° CW" else "Rotated 90° CCW");
    }

    pub fn rotate180(self: *ImageViewerApp) !void {
        try self.undo_stack.pushState(&self.base_image);
        const rotated = try self.base_image.rotate180(self.allocator);
        self.base_image.deinit();
        self.base_image = rotated;
        self.refreshDisplayImage();
        self.setStatus("Rotated 180°");
    }

    pub fn flip(self: *ImageViewerApp, horizontal: bool) !void {
        try self.undo_stack.pushState(&self.base_image);
        const flipped = if (horizontal)
            try self.base_image.flipHorizontal(self.allocator)
        else
            try self.base_image.flipVertical(self.allocator);

        self.base_image.deinit();
        self.base_image = flipped;
        self.refreshDisplayImage();
        self.setStatus(if (horizontal) "Flipped horizontally" else "Flipped vertically");
    }

    pub fn commitCrop(self: *ImageViewerApp) !void {
        const x0 = @min(self.crop_start_x, self.crop_curr_x);
        const y0 = @min(self.crop_start_y, self.crop_curr_y);
        const cw: u32 = @intCast(@abs(self.crop_curr_x - self.crop_start_x));
        const ch: u32 = @intCast(@abs(self.crop_curr_y - self.crop_start_y));

        if (cw < 4 or ch < 4) {
            self.mode = .view;
            self.win.needs_redraw = true;
            return;
        }

        try self.undo_stack.pushState(&self.base_image);
        const cropped = try self.base_image.crop(self.allocator, Rect{ .x = x0, .y = y0, .w = cw, .h = ch });
        self.base_image.deinit();
        self.base_image = cropped;
        self.refreshDisplayImage();
        self.mode = .view;
        self.fitToWindow();
        self.setStatus("Cropped image");
    }

    pub fn resizeScale(self: *ImageViewerApp, factor: f32) !void {
        const nw: u32 = @intFromFloat(@as(f32, @floatFromInt(self.base_image.width)) * factor);
        const nh: u32 = @intFromFloat(@as(f32, @floatFromInt(self.base_image.height)) * factor);
        if (nw < 2 or nh < 2) return;

        try self.undo_stack.pushState(&self.base_image);
        const resized = try self.base_image.resize(self.allocator, nw, nh, .bilinear);
        self.base_image.deinit();
        self.base_image = resized;
        self.refreshDisplayImage();
        self.fitToWindow();

        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Resized to {d}×{d} px", .{ nw, nh }) catch "Resized";
        self.setStatus(msg);
    }

    // ==========================================
    // Adjustments: Live Preview & Commit
    // ==========================================

    pub fn refreshDisplayImage(self: *ImageViewerApp) void {
        self.display_image.deinit();
        self.display_image = self.base_image.clone(self.allocator) catch return;

        if (self.adjustments.brightness != 0.0) {
            self.display_image.applyBrightness(self.adjustments.brightness);
        }
        if (self.adjustments.contrast != 1.0) {
            self.display_image.applyContrast(self.adjustments.contrast);
        }
        if (self.adjustments.saturation != 1.0) {
            self.display_image.applySaturation(self.adjustments.saturation);
        }
        if (self.adjustments.grayscale) {
            self.display_image.applyGrayscale();
        }
        if (self.adjustments.blur > 0) {
            self.display_image.applyBlur(self.adjustments.blur);
        }
        self.win.needs_redraw = true;
    }

    pub fn commitAdjustments(self: *ImageViewerApp) !void {
        try self.undo_stack.pushState(&self.base_image);
        self.base_image.deinit();
        self.base_image = try self.display_image.clone(self.allocator);
        self.adjustments.reset();
        self.mode = .view;
        self.setStatus("Adjustments applied");
    }

    pub fn resetAdjustments(self: *ImageViewerApp) void {
        self.adjustments.reset();
        self.refreshDisplayImage();
        self.mode = .view;
        self.setStatus("Adjustments reset");
    }

    // ==========================================
    // Save, Export, Copy
    // ==========================================

    pub fn save(self: *ImageViewerApp) !void {
        var path_buf: [512]u8 = undefined;
        const save_path = if (self.file_path) |p|
            p
        else blk: {
            const ts = c.time(null);
            break :blk std.fmt.bufPrint(&path_buf, "/tmp/mizu_image_{d}.png", .{ts}) catch "/tmp/mizu_image.png";
        };

        if (std.mem.endsWith(u8, save_path, ".jpg") or std.mem.endsWith(u8, save_path, ".jpeg")) {
            try self.display_image.saveJpeg(save_path, 90);
        } else {
            try self.display_image.savePng(save_path);
        }

        var feedback_buf: [128]u8 = undefined;
        const feedback = std.fmt.bufPrint(&feedback_buf, "Saved to {s}", .{save_path}) catch "Saved successfully";
        self.setStatus(feedback);
    }

    pub fn exportImage(self: *ImageViewerApp, as_jpeg: bool) !void {
        const home = if (c.getenv("HOME")) |h| std.mem.span(h) else "/tmp";
        const ts = c.time(null);
        var path_buf: [512]u8 = undefined;

        const path = if (as_jpeg)
            try std.fmt.bufPrint(&path_buf, "{s}/Pictures/mizu_export_{d}.jpg", .{ home, ts })
        else
            try std.fmt.bufPrint(&path_buf, "{s}/Pictures/mizu_export_{d}.png", .{ home, ts });

        if (as_jpeg) {
            try self.display_image.saveJpeg(path, 92);
        } else {
            try self.display_image.savePng(path);
        }

        var feedback_buf: [128]u8 = undefined;
        const feedback = std.fmt.bufPrint(&feedback_buf, "Exported to {s}", .{path}) catch "Exported successfully";
        self.setStatus(feedback);
    }

    pub fn copyClipboard(self: *ImageViewerApp) !void {
        try self.display_image.copyToClipboard(self.allocator);
        self.setStatus("Copied to clipboard!");
    }

    // ==========================================
    // Event Handling
    // ==========================================

    pub fn handlePointerMotion(self: *ImageViewerApp, x: i32, y: i32) void {
        const c_rect = self.canvasRect();
        const inside_canvas = (x >= c_rect.x and y >= c_rect.y and x < c_rect.x + @as(i32, @intCast(c_rect.w)) and y < c_rect.y + @as(i32, @intCast(c_rect.h)));

        if (self.is_panning) {
            self.pan_x += @floatFromInt(x - self.pan_start_x);
            self.pan_y += @floatFromInt(y - self.pan_start_y);
            self.pan_start_x = x;
            self.pan_start_y = y;
            self.win.needs_redraw = true;
            return;
        }

        if (self.mode == .crop and self.is_cropping) {
            self.crop_curr_x = self.screenToImageX(x);
            self.crop_curr_y = self.screenToImageY(y);
            self.win.needs_redraw = true;
            return;
        }

        if (self.mode == .adjust and self.active_slider != null) {
            self.updateSliderFromMouse(x);
            return;
        }

        if (inside_canvas) {
            self.win.setCursorShape(if (self.mode == .crop) .crosshair else .default);
        } else {
            self.win.setCursorShape(.default);
        }
    }

    pub fn handlePointerButton(self: *ImageViewerApp, x: i32, y: i32, button: u32, pressed: bool) void {
        const c_rect = self.canvasRect();
        const inside_canvas = (x >= c_rect.x and y >= c_rect.y and x < c_rect.x + @as(i32, @intCast(c_rect.w)) and y < c_rect.y + @as(i32, @intCast(c_rect.h)));

        // Middle button (0x112): panning
        if (button == 0x112) {
            if (pressed) {
                self.is_panning = true;
                self.pan_start_x = x;
                self.pan_start_y = y;
                self.win.setCursorShape(.grab);
            } else {
                self.is_panning = false;
                self.win.setCursorShape(if (inside_canvas) .pointer else .default);
            }
            return;
        }

        if (button == 0x110) {
            if (pressed) {
                // Toolbar click
                if (y < @as(i32, @intCast(self.toolbar_height))) {
                    self.handleToolbarClick(x, y);
                    return;
                }

                // Statusbar click
                if (y >= @as(i32, @intCast(self.win.height - self.statusbar_height))) {
                    self.handleStatusbarClick(x, y);
                    return;
                }

                // Adjustments panel click
                if (self.mode == .adjust and x > @as(i32, @intCast(self.win.width - 240))) {
                    self.handleAdjustPanelClick(x, y);
                    return;
                }

                // Info panel dismiss
                if (self.mode == .info) {
                    self.mode = .view;
                    self.win.needs_redraw = true;
                    return;
                }

                if (inside_canvas) {
                    if (self.mode == .crop) {
                        self.is_cropping = true;
                        const img_x = self.screenToImageX(x);
                        const img_y = self.screenToImageY(y);
                        self.crop_start_x = img_x;
                        self.crop_start_y = img_y;
                        self.crop_curr_x = img_x;
                        self.crop_curr_y = img_y;
                        self.win.needs_redraw = true;
                    } else {
                        // Standard left-drag pan
                        self.is_panning = true;
                        self.pan_start_x = x;
                        self.pan_start_y = y;
                        self.win.setCursorShape(.grab);
                    }
                }
            } else {
                // Released
                if (self.is_panning) {
                    self.is_panning = false;
                    self.win.setCursorShape(if (inside_canvas) .pointer else .default);
                }
                if (self.is_cropping) {
                    self.is_cropping = false;
                    self.win.needs_redraw = true;
                }
                if (self.active_slider != null) {
                    self.active_slider = null;
                }
            }
        }
    }

    pub fn handlePointerAxis(self: *ImageViewerApp, x: i32, y: i32, scroll: i32) void {
        _ = x; _ = y;
        if (scroll != 0) {
            const factor: f32 = if (scroll < 0) 1.15 else 0.85;
            self.zoom = std.math.clamp(self.zoom * factor, 0.05, 10.0);
            self.win.needs_redraw = true;
        }
    }

    pub fn handleKey(self: *ImageViewerApp, sym: u32, is_ctrl: bool, is_shift: bool) void {
        _ = is_shift;
        if (is_ctrl) {
            if (sym == c.XKB_KEY_s or sym == c.XKB_KEY_S) {
                self.save() catch self.setStatus("Failed to save");
                return;
            } else if (sym == c.XKB_KEY_c or sym == c.XKB_KEY_C) {
                self.copyClipboard() catch self.setStatus("Failed to copy");
                return;
            } else if (sym == c.XKB_KEY_z or sym == c.XKB_KEY_Z) {
                if (self.undo_stack.undo(&self.base_image) catch false) {
                    self.refreshDisplayImage();
                    self.setStatus("Undo");
                }
                return;
            } else if (sym == c.XKB_KEY_y or sym == c.XKB_KEY_Y) {
                if (self.undo_stack.redo(&self.base_image) catch false) {
                    self.refreshDisplayImage();
                    self.setStatus("Redo");
                }
                return;
            }
        }

        switch (sym) {
            c.XKB_KEY_f, c.XKB_KEY_F => self.fitToWindow(),
            c.XKB_KEY_0 => {
                self.zoom = 1.0;
                self.win.needs_redraw = true;
            },
            c.XKB_KEY_plus, c.XKB_KEY_equal => {
                self.zoom = std.math.clamp(self.zoom * 1.2, 0.05, 10.0);
                self.win.needs_redraw = true;
            },
            c.XKB_KEY_minus, c.XKB_KEY_underscore => {
                self.zoom = std.math.clamp(self.zoom * 0.8, 0.05, 10.0);
                self.win.needs_redraw = true;
            },
            c.XKB_KEY_r, c.XKB_KEY_R => {
                self.rotate(true) catch {};
            },
            c.XKB_KEY_c, c.XKB_KEY_C => {
                self.mode = if (self.mode == .crop) .view else .crop;
                self.win.needs_redraw = true;
            },
            c.XKB_KEY_a, c.XKB_KEY_A => {
                self.mode = if (self.mode == .adjust) .view else .adjust;
                self.win.needs_redraw = true;
            },
            c.XKB_KEY_i, c.XKB_KEY_I => {
                self.mode = if (self.mode == .info) .view else .info;
                self.win.needs_redraw = true;
            },
            c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => {
                if (self.mode == .crop) {
                    self.commitCrop() catch {};
                }
            },
            c.XKB_KEY_Escape => {
                if (self.mode != .view) {
                    self.mode = .view;
                    self.win.needs_redraw = true;
                } else {
                    self.win.running = false;
                }
            },
            else => {},
        }
    }

    fn handleToolbarClick(self: *ImageViewerApp, x: i32, y: i32) void {
        _ = y;
        var bx: i32 = 140;
        const btn_h: i32 = 28;
        _ = btn_h;

        // Crop toggle [Crop]
        if (x >= bx and x < bx + 50) {
            self.mode = if (self.mode == .crop) .view else .crop;
            self.win.needs_redraw = true;
            return;
        }
        bx += 56;

        // Rotate 90° CW [↻ 90°]
        if (x >= bx and x < bx + 50) {
            self.rotate(true) catch {};
            return;
        }
        bx += 56;

        // Flip H [⇄ Flip H]
        if (x >= bx and x < bx + 56) {
            self.flip(true) catch {};
            return;
        }
        bx += 62;

        // Flip V [⇅ Flip V]
        if (x >= bx and x < bx + 56) {
            self.flip(false) catch {};
            return;
        }
        bx += 62;

        // Resize: 50%, 200%
        if (x >= bx and x < bx + 42) {
            self.resizeScale(0.5) catch {};
            return;
        }
        bx += 46;

        if (x >= bx and x < bx + 42) {
            self.resizeScale(2.0) catch {};
            return;
        }
        bx += 50;

        // Separator
        bx += 8;

        // Adjustments Toggle [Adjust]
        if (x >= bx and x < bx + 64) {
            self.mode = if (self.mode == .adjust) .view else .adjust;
            self.win.needs_redraw = true;
            return;
        }
        bx += 70;

        // Info Toggle [Info]
        if (x >= bx and x < bx + 50) {
            self.mode = if (self.mode == .info) .view else .info;
            self.win.needs_redraw = true;
            return;
        }
        bx += 60;

        // Separator
        bx += 8;

        // Undo & Redo
        if (x >= bx and x < bx + 30) {
            if (self.undo_stack.undo(&self.base_image) catch false) {
                self.refreshDisplayImage();
                self.setStatus("Undo");
            }
            return;
        }
        bx += 34;

        if (x >= bx and x < bx + 30) {
            if (self.undo_stack.redo(&self.base_image) catch false) {
                self.refreshDisplayImage();
                self.setStatus("Redo");
            }
            return;
        }
        bx += 40;

        // Save
        if (x >= bx and x < bx + 60) {
            self.save() catch self.setStatus("Failed to save");
            return;
        }
        bx += 66;

        // Export (PNG / JPEG)
        if (x >= bx and x < bx + 66) {
            self.exportImage(false) catch self.setStatus("Failed to export");
            return;
        }
        bx += 72;

        // Copy
        if (x >= bx and x < bx + 60) {
            self.copyClipboard() catch self.setStatus("Failed to copy");
            return;
        }
    }

    fn handleAdjustPanelClick(self: *ImageViewerApp, x: i32, y: i32) void {
        const panel_x: i32 = @as(i32, @intCast(self.win.width)) - 240;
        const panel_y: i32 = @intCast(self.toolbar_height + 16);

        // Sliders are laid out vertically
        // Brightness: y + 40
        if (y >= panel_y + 40 and y <= panel_y + 55) {
            self.active_slider = .brightness;
            self.updateSliderFromMouse(x);
        } else if (y >= panel_y + 80 and y <= panel_y + 95) {
            self.active_slider = .contrast;
            self.updateSliderFromMouse(x);
        } else if (y >= panel_y + 120 and y <= panel_y + 135) {
            self.active_slider = .saturation;
            self.updateSliderFromMouse(x);
        } else if (y >= panel_y + 160 and y <= panel_y + 175) {
            self.active_slider = .blur;
            self.updateSliderFromMouse(x);
        } else if (y >= panel_y + 190 and y <= panel_y + 215) {
            // Grayscale toggle button
            self.adjustments.grayscale = !self.adjustments.grayscale;
            self.refreshDisplayImage();
        } else if (y >= panel_y + 230 and y <= panel_y + 258) {
            // [Apply] button
            if (x >= panel_x + 16 and x <= panel_x + 110) {
                self.commitAdjustments() catch {};
            } else if (x >= panel_x + 120 and x <= panel_x + 224) {
                // [Reset] button
                self.resetAdjustments();
            }
        }
    }

    fn updateSliderFromMouse(self: *ImageViewerApp, x: i32) void {
        const panel_x: i32 = @as(i32, @intCast(self.win.width)) - 240;
        const sx = panel_x + 16;
        const sw: f32 = 208.0;
        const frac = std.math.clamp((@as(f32, @floatFromInt(x)) - @as(f32, @floatFromInt(sx))) / sw, 0.0, 1.0);

        if (self.active_slider) |s| {
            switch (s) {
                .brightness => {
                    self.adjustments.brightness = (frac - 0.5) * 2.0; // -1.0 to +1.0
                },
                .contrast => {
                    self.adjustments.contrast = frac * 2.0; // 0.0 to 2.0
                },
                .saturation => {
                    self.adjustments.saturation = frac * 2.0; // 0.0 to 2.0
                },
                .blur => {
                    self.adjustments.blur = @intFromFloat(frac * 16.0); // 0 to 16
                },
            }
            self.refreshDisplayImage();
        }
    }

    fn handleStatusbarClick(self: *ImageViewerApp, x: i32, y: i32) void {
        _ = y;
        const right_base: i32 = @as(i32, @intCast(self.win.width)) - 140;
        if (x >= right_base and x < right_base + 30) {
            self.zoom = std.math.clamp(self.zoom * 0.85, 0.05, 10.0);
            self.win.needs_redraw = true;
        } else if (x >= right_base + 32 and x < right_base + 72) {
            self.fitToWindow();
        } else if (x >= right_base + 74 and x < right_base + 104) {
            self.zoom = std.math.clamp(self.zoom * 1.15, 0.05, 10.0);
            self.win.needs_redraw = true;
        }
    }

    // ==========================================
    // Rendering
    // ==========================================

    pub fn render(self: *ImageViewerApp) !void {
        var r = try self.win.getRenderer();
        const th = self.cfg.theme;

        // Clear with background color
        r.clear(th.base);

        const c_rect = self.canvasRect();
        var canvas_renderer = r.withClip(c_rect);

        // Draw image with pan & zoom
        const dest_x = self.pan_x;
        const dest_y = self.pan_y;
        const dest_w = @as(f64, @floatFromInt(self.display_image.width)) * @as(f64, self.zoom);
        const dest_h = @as(f64, @floatFromInt(self.display_image.height)) * @as(f64, self.zoom);

        canvas_renderer.drawSoftShadow(
            @intFromFloat(dest_x),
            @intFromFloat(dest_y),
            @intFromFloat(dest_w),
            @intFromFloat(dest_h),
            8,
            16,
            4,
            th.shadow_dark,
        );

        const r_img = try self.display_image.toRendererImage(self.allocator);
        defer r_img.deinit();

        canvas_renderer.drawImage(r_img, dest_x, dest_y, dest_w, dest_h);

        canvas_renderer.drawRoundedBorder(
            @intFromFloat(dest_x),
            @intFromFloat(dest_y),
            @intFromFloat(dest_w),
            @intFromFloat(dest_h),
            2,
            1,
            th.border,
        );

        // Render interactive crop box overlay
        if (self.mode == .crop) {
            const sx0 = self.imageToScreenX(self.crop_start_x);
            const sy0 = self.imageToScreenY(self.crop_start_y);
            const sx1 = self.imageToScreenX(self.crop_curr_x);
            const sy1 = self.imageToScreenY(self.crop_curr_y);

            const rx = @min(sx0, sx1);
            const ry = @min(sy0, sy1);
            const rw: u32 = @intCast(@abs(sx1 - sx0));
            const rh: u32 = @intCast(@abs(sy1 - sy0));

            if (rw > 0 and rh > 0) {
                // Dimmed surrounding
                canvas_renderer.drawRoundedBorder(rx, ry, rw, rh, 0, 2, th.accent);
                // Crop dimension label
                var c_buf: [32]u8 = undefined;
                const c_txt = std.fmt.bufPrint(&c_buf, "{d}×{d} [Enter to Commit]", .{
                    @as(u32, @intCast(@abs(self.crop_curr_x - self.crop_start_x))),
                    @as(u32, @intCast(@abs(self.crop_curr_y - self.crop_start_y))),
                }) catch "";
                canvas_renderer.fillRoundedRect(rx, ry - 22, @intCast(canvas_renderer.measureTextWithSize(self.font, c_txt, 11) + 12), 20, 4, th.accent);
                canvas_renderer.drawTextWithSize(self.font, c_txt, rx + 6, ry - 8, 11, th.accent_fg);
            }
        }

        // Render Adjustments Sidebar
        if (self.mode == .adjust) {
            self.renderAdjustPanel(r);
        }

        // Render Image Information Overlay
        if (self.mode == .info) {
            self.renderInfoPanel(r);
        }

        self.renderToolbar(r);
        self.renderStatusbar(r);

        if (self.status_ticks > 0) self.status_ticks -= 1;
    }

    fn renderToolbar(self: *ImageViewerApp, r: renderer.Renderer) void {
        const th = self.cfg.theme;
        const w = self.win.width;
        const h = self.toolbar_height;
        const btn_y: i32 = 9;
        const btn_h: i32 = 28;

        r.fillRect(0, 0, w, h, th.surface);
        r.fillRect(0, @intCast(h - 1), w, 1, th.glass_border);

        r.drawTextWithSize(self.font, "󰋩 Mizu Image", 14, 28, 14, th.accent);

        var bx: i32 = 140;

        // [Crop]
        {
            const active = (self.mode == .crop);
            r.fillRoundedRect(bx, btn_y, 50, @intCast(btn_h), 6, if (active) th.accent else th.btn_raised_bg);
            r.drawRoundedBorder(bx, btn_y, 50, @intCast(btn_h), 6, 1, if (active) th.accent else th.glass_border);
            r.drawTextWithSize(self.font, "Crop", bx + 12, btn_y + 18, 11, if (active) th.accent_fg else th.text_main);
            bx += 56;
        }

        // [↻ 90°]
        {
            r.fillRoundedRect(bx, btn_y, 50, @intCast(btn_h), 6, th.btn_raised_bg);
            r.drawRoundedBorder(bx, btn_y, 50, @intCast(btn_h), 6, 1, th.glass_border);
            r.drawTextWithSize(self.font, "↻ 90°", bx + 10, btn_y + 18, 11, th.text_main);
            bx += 56;
        }

        // [⇄ Flip H]
        {
            r.fillRoundedRect(bx, btn_y, 56, @intCast(btn_h), 6, th.btn_raised_bg);
            r.drawRoundedBorder(bx, btn_y, 56, @intCast(btn_h), 6, 1, th.glass_border);
            r.drawTextWithSize(self.font, "⇄ Flip H", bx + 8, btn_y + 18, 11, th.text_main);
            bx += 62;
        }

        // [⇅ Flip V]
        {
            r.fillRoundedRect(bx, btn_y, 56, @intCast(btn_h), 6, th.btn_raised_bg);
            r.drawRoundedBorder(bx, btn_y, 56, @intCast(btn_h), 6, 1, th.glass_border);
            r.drawTextWithSize(self.font, "⇅ Flip V", bx + 8, btn_y + 18, 11, th.text_main);
            bx += 62;
        }

        // Resizes: 50%, 200%
        {
            r.fillRoundedRect(bx, btn_y, 42, @intCast(btn_h), 6, th.btn_raised_bg);
            r.drawRoundedBorder(bx, btn_y, 42, @intCast(btn_h), 6, 1, th.glass_border);
            r.drawTextWithSize(self.font, "50%", bx + 10, btn_y + 18, 11, th.text_main);
            bx += 46;

            r.fillRoundedRect(bx, btn_y, 42, @intCast(btn_h), 6, th.btn_raised_bg);
            r.drawRoundedBorder(bx, btn_y, 42, @intCast(btn_h), 6, 1, th.glass_border);
            r.drawTextWithSize(self.font, "200%", bx + 8, btn_y + 18, 11, th.text_main);
            bx += 50;
        }

        bx += 8;
        r.fillRect(bx, 12, 1, 22, th.glass_border);
        bx += 12;

        // [Adjust] Toggle
        {
            const active = (self.mode == .adjust);
            r.fillRoundedRect(bx, btn_y, 64, @intCast(btn_h), 6, if (active) th.accent else th.btn_raised_bg);
            r.drawRoundedBorder(bx, btn_y, 64, @intCast(btn_h), 6, 1, if (active) th.accent else th.glass_border);
            r.drawTextWithSize(self.font, "󰔎 Adjust", bx + 8, btn_y + 18, 11, if (active) th.accent_fg else th.text_main);
            bx += 70;
        }

        // [Info] Toggle
        {
            const active = (self.mode == .info);
            r.fillRoundedRect(bx, btn_y, 50, @intCast(btn_h), 6, if (active) th.accent else th.btn_raised_bg);
            r.drawRoundedBorder(bx, btn_y, 50, @intCast(btn_h), 6, 1, if (active) th.accent else th.glass_border);
            r.drawTextWithSize(self.font, "󰋼 Info", bx + 8, btn_y + 18, 11, if (active) th.accent_fg else th.text_main);
            bx += 60;
        }

        bx += 8;
        r.fillRect(bx, 12, 1, 22, th.glass_border);
        bx += 12;

        // Undo & Redo
        {
            r.fillRoundedRect(bx, btn_y, 30, @intCast(btn_h), 6, th.btn_raised_bg);
            r.drawRoundedBorder(bx, btn_y, 30, @intCast(btn_h), 6, 1, th.glass_border);
            r.drawTextWithSize(self.font, "↺", bx + 10, btn_y + 19, 13, if (self.undo_stack.canUndo()) th.text_main else th.text_muted);
            bx += 34;

            r.fillRoundedRect(bx, btn_y, 30, @intCast(btn_h), 6, th.btn_raised_bg);
            r.drawRoundedBorder(bx, btn_y, 30, @intCast(btn_h), 6, 1, th.glass_border);
            r.drawTextWithSize(self.font, "↻", bx + 10, btn_y + 19, 13, if (self.undo_stack.canRedo()) th.text_main else th.text_muted);
            bx += 40;
        }

        // Save, Export, Copy
        {
            r.fillRoundedRect(bx, btn_y, 60, @intCast(btn_h), 6, th.btn_raised_bg);
            r.drawRoundedBorder(bx, btn_y, 60, @intCast(btn_h), 6, 1, th.glass_border);
            r.drawTextWithSize(self.font, "󰆓 Save", bx + 10, btn_y + 18, 11, th.text_main);
            bx += 66;

            r.fillRoundedRect(bx, btn_y, 66, @intCast(btn_h), 6, th.btn_raised_bg);
            r.drawRoundedBorder(bx, btn_y, 66, @intCast(btn_h), 6, 1, th.glass_border);
            r.drawTextWithSize(self.font, "󰢔 Export", bx + 8, btn_y + 18, 11, th.text_main);
            bx += 72;

            r.fillRoundedRect(bx, btn_y, 60, @intCast(btn_h), 6, th.accent);
            r.drawRoundedBorder(bx, btn_y, 60, @intCast(btn_h), 6, 1, th.accent);
            r.drawTextWithSize(self.font, "󰆏 Copy", bx + 10, btn_y + 18, 11, th.accent_fg);
        }
    }

    fn renderAdjustPanel(self: *ImageViewerApp, r: renderer.Renderer) void {
        const th = self.cfg.theme;
        const panel_w: u32 = 240;
        const panel_h: u32 = 280;
        const panel_x: i32 = @as(i32, @intCast(self.win.width)) - @as(i32, @intCast(panel_w)) - 16;
        const panel_y: i32 = @intCast(self.toolbar_height + 16);

        // Glass background card
        r.drawSoftShadow(panel_x, panel_y, panel_w, panel_h, 12, 16, 4, th.shadow_dark);
        r.fillRoundedRect(panel_x, panel_y, panel_w, panel_h, 12, th.elevated);
        r.drawRoundedBorder(panel_x, panel_y, panel_w, panel_h, 12, 1, th.glass_border);

        r.drawTextWithSize(self.font, "Image Adjustments", panel_x + 16, panel_y + 24, 13, th.accent);

        // Sliders: Brightness, Contrast, Saturation, Blur
        const sliders = [_]struct { label: []const u8, val_txt: []const u8, frac: f32, y: i32 }{
            .{
                .label = "Brightness",
                .val_txt = "+0.0",
                .frac = (self.adjustments.brightness / 2.0) + 0.5,
                .y = panel_y + 40,
            },
            .{
                .label = "Contrast",
                .val_txt = "1.0",
                .frac = self.adjustments.contrast / 2.0,
                .y = panel_y + 80,
            },
            .{
                .label = "Saturation",
                .val_txt = "1.0",
                .frac = self.adjustments.saturation / 2.0,
                .y = panel_y + 120,
            },
            .{
                .label = "Blur",
                .val_txt = "0px",
                .frac = @as(f32, @floatFromInt(self.adjustments.blur)) / 16.0,
                .y = panel_y + 160,
            },
        };

        for (sliders) |s| {
            r.drawTextWithSize(self.font, s.label, panel_x + 16, s.y + 10, 11, th.text_muted);
            const track_x = panel_x + 16;
            const track_w: u32 = 208;
            r.fillRoundedRect(track_x, s.y + 16, track_w, 6, 3, th.slider_track);
            const thumb_x = track_x + @as(i32, @intFromFloat(s.frac * @as(f32, @floatFromInt(track_w))));
            r.fillCircle(@floatFromInt(thumb_x), @floatFromInt(s.y + 19), 6, th.accent);
        }

        // Grayscale toggle button
        {
            const gy = panel_y + 196;
            const active = self.adjustments.grayscale;
            r.fillRoundedRect(panel_x + 16, gy, 208, 26, 6, if (active) th.accent else th.btn_raised_bg);
            r.drawRoundedBorder(panel_x + 16, gy, 208, 26, 6, 1, th.glass_border);
            r.drawTextWithSize(self.font, if (active) "✓ Grayscale Enabled" else "Grayscale Filter", panel_x + 50, gy + 17, 11, if (active) th.accent_fg else th.text_main);
        }

        // Action Buttons: [Apply] [Reset]
        {
            const by = panel_y + 232;
            r.fillRoundedRect(panel_x + 16, by, 98, 28, 6, th.accent);
            r.drawTextWithSize(self.font, "Apply", panel_x + 48, by + 18, 11, th.accent_fg);

            r.fillRoundedRect(panel_x + 124, by, 100, 28, 6, th.btn_raised_bg);
            r.drawRoundedBorder(panel_x + 124, by, 100, 28, 6, 1, th.glass_border);
            r.drawTextWithSize(self.font, "Reset", panel_x + 158, by + 18, 11, th.text_main);
        }
    }

    fn renderInfoPanel(self: *ImageViewerApp, r: renderer.Renderer) void {
        const th = self.cfg.theme;
        const panel_w: u32 = 320;
        const panel_h: u32 = 220;
        const panel_x: i32 = @divTrunc(@as(i32, @intCast(self.win.width)) - @as(i32, @intCast(panel_w)), 2);
        const panel_y: i32 = @divTrunc(@as(i32, @intCast(self.win.height)) - @as(i32, @intCast(panel_h)), 2);

        r.drawSoftShadow(panel_x, panel_y, panel_w, panel_h, 12, 24, 6, th.shadow_dark);
        r.fillRoundedRect(panel_x, panel_y, panel_w, panel_h, 12, th.elevated);
        r.drawRoundedBorder(panel_x, panel_y, panel_w, panel_h, 12, 1, th.accent);

        r.drawTextWithSize(self.font, "󰋼 Image Information", panel_x + 20, panel_y + 30, 14, th.accent);

        var buf: [128]u8 = undefined;

        // Dimensions
        const dim_txt = std.fmt.bufPrint(&buf, "Dimensions:    {d} × {d} pixels", .{ self.display_image.width, self.display_image.height }) catch "";
        r.drawTextWithSize(self.font, dim_txt, panel_x + 20, panel_y + 65, 12, th.text_main);

        // Aspect Ratio
        const aspect = @as(f32, @floatFromInt(self.display_image.width)) / @as(f32, @floatFromInt(self.display_image.height));
        const asp_txt = std.fmt.bufPrint(&buf, "Aspect Ratio:  {d:.2}:1", .{aspect}) catch "";
        r.drawTextWithSize(self.font, asp_txt, panel_x + 20, panel_y + 95, 12, th.text_main);

        // Color Format
        r.drawTextWithSize(self.font, "Color Depth:   32-bit ARGB8888", panel_x + 20, panel_y + 125, 12, th.text_main);

        // Memory Usage
        const mem_mb = @as(f32, @floatFromInt(self.display_image.width * self.display_image.height * 4)) / (1024.0 * 1024.0);
        const mem_txt = std.fmt.bufPrint(&buf, "Buffer Memory: {d:.2} MB", .{mem_mb}) catch "";
        r.drawTextWithSize(self.font, mem_txt, panel_x + 20, panel_y + 155, 12, th.text_main);

        // File Path
        const p_txt = if (self.file_path) |p| p else "Unsaved image";
        r.drawTextWithSize(self.font, p_txt, panel_x + 20, panel_y + 185, 11, th.text_muted);
    }

    fn renderStatusbar(self: *ImageViewerApp, r: renderer.Renderer) void {
        const th = self.cfg.theme;
        const w = self.win.width;
        const h = self.statusbar_height;
        const y: i32 = @intCast(self.win.height - h);

        r.fillRect(0, y, w, h, th.surface);
        r.fillRect(0, y, w, 1, th.glass_border);

        var info_buf: [128]u8 = undefined;
        const info = std.fmt.bufPrint(
            &info_buf,
            "{d}×{d} px  |  Zoom: {d}%  |  {s}",
            .{
                self.display_image.width,
                self.display_image.height,
                @as(u32, @intFromFloat(self.zoom * 100.0)),
                if (self.mode == .crop) "Mode: Crop [Enter to apply]" else if (self.mode == .adjust) "Mode: Adjustments" else "Mode: View",
            },
        ) catch "";
        r.drawTextWithSize(self.font, info, 14, y + 18, 11, th.text_muted);

        if (self.status_ticks > 0 and self.status_len > 0) {
            const msg = self.status_msg[0..self.status_len];
            const mw = r.measureTextWithSize(self.font, msg, 11);
            const mx = @divTrunc(@as(i32, @intCast(w)) - @as(i32, @intCast(mw)), 2);
            r.drawTextWithSize(self.font, msg, mx, y + 18, 11, th.success_color);
        }

        const right_base: i32 = @as(i32, @intCast(w)) - 140;
        r.fillRoundedRect(right_base, y + 4, 26, 20, 4, th.btn_raised_bg);
        r.drawTextWithSize(self.font, "-", right_base + 9, y + 17, 12, th.text_main);

        r.fillRoundedRect(right_base + 30, y + 4, 38, 20, 4, th.btn_raised_bg);
        r.drawTextWithSize(self.font, "Fit", right_base + 42, y + 17, 10, th.text_main);

        r.fillRoundedRect(right_base + 72, y + 4, 26, 20, 4, th.btn_raised_bg);
        r.drawTextWithSize(self.font, "+", right_base + 8, y + 17, 12, th.text_main);
    }
};

// ==========================================
// Main Application Event Loop
// ==========================================

const annotate_app = @import("annotate.zig");

pub fn run(allocator: std.mem.Allocator, cfg: config.Config, file_to_open: ?[]const u8) !u8 {
    return annotate_app.run(allocator, cfg, file_to_open, false);
}

test "ImageViewer Adjustments struct" {
    var adj = Adjustments{};
    try std.testing.expect(adj.isDefault());
    adj.brightness = 0.5;
    adj.grayscale = true;
    try std.testing.expect(!adj.isDefault());
    adj.reset();
    try std.testing.expect(adj.isDefault());
    try std.testing.expectEqual(@as(f32, 0.0), adj.brightness);
    try std.testing.expectEqual(@as(f32, 1.0), adj.contrast);
    try std.testing.expectEqual(@as(f32, 1.0), adj.saturation);
    try std.testing.expectEqual(@as(u32, 0), adj.blur);
    try std.testing.expectEqual(false, adj.grayscale);
}
