const std = @import("std");
const c = @import("../../c.zig").c;
const buffer = @import("../../core/buffer.zig");
const renderer = @import("../../core/renderer.zig");
const theme = @import("../../core/theme.zig");
const config = @import("../../core/config.zig");
const wayland_win = @import("../../core/wayland_window.zig");
const image_ops = @import("../../graphics/image_ops.zig");

const Color = theme.Color;
const Rect = renderer.Rect;
const Font = renderer.Font;
const ImageBuffer = image_ops.ImageBuffer;
const WindowApp = wayland_win.WindowApp;

pub fn isSupportedImageExtension(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    return std.ascii.eqlIgnoreCase(ext, ".png") or
        std.ascii.eqlIgnoreCase(ext, ".jpg") or
        std.ascii.eqlIgnoreCase(ext, ".jpeg") or
        std.ascii.eqlIgnoreCase(ext, ".svg") or
        std.ascii.eqlIgnoreCase(ext, ".webp") or
        std.ascii.eqlIgnoreCase(ext, ".bmp") or
        std.ascii.eqlIgnoreCase(ext, ".qoi") or
        std.ascii.eqlIgnoreCase(ext, ".gif");
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn formatFileSize(bytes: usize, buf: []u8) []const u8 {
    if (bytes >= 1024 * 1024) {
        const mb = @as(f32, @floatFromInt(bytes)) / (1024.0 * 1024.0);
        return std.fmt.bufPrint(buf, "{d:.1} MB", .{mb}) catch "";
    } else if (bytes >= 1024) {
        const kb = @as(f32, @floatFromInt(bytes)) / 1024.0;
        return std.fmt.bufPrint(buf, "{d:.1} KB", .{kb}) catch "";
    } else {
        return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "";
    }
}

pub const ImageViewerApp = struct {
    allocator: std.mem.Allocator,
    win: *WindowApp,
    font: *Font,
    cfg: config.Config,

    image: ?ImageBuffer = null,
    file_path: ?[]const u8 = null,
    file_size_bytes: usize = 0,

    dir_files: std.ArrayListUnmanaged([]const u8) = .empty,
    current_file_idx: usize = 0,

    // Smooth Pan & Zoom
    zoom: f32 = 1.0,
    pan_x: f32 = 0.0,
    pan_y: f32 = 0.0,
    is_panning: bool = false,
    pan_start_x: i32 = 0,
    pan_start_y: i32 = 0,

    // HUD & Feedback
    hud_visible: bool = true,
    status_msg: [128]u8 = @splat(0),
    status_len: usize = 0,
    status_ticks: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config, loaded_img: ?ImageBuffer, initial_path: ?[]const u8) !*ImageViewerApp {
        var win = try WindowApp.init(allocator, .{
            .title = "Mizu View",
            .app_id = "mizu-view",
            .width = 1100,
            .height = 700,
            .min_width = 360,
            .min_height = 260,
        });
        errdefer win.deinit();

        const font = try allocator.create(Font);
        font.* = try Font.init(allocator, cfg.theme.font_family, 12);
        errdefer {
            font.deinit();
            allocator.destroy(font);
        }

        const app = try allocator.create(ImageViewerApp);
        app.* = .{
            .allocator = allocator,
            .win = win,
            .font = font,
            .cfg = cfg,
            .image = loaded_img,
            .file_path = if (initial_path) |p| try allocator.dupe(u8, p) else null,
            .file_size_bytes = 0,
            .dir_files = .empty,
            .current_file_idx = 0,
        };

        if (initial_path) |p| {
            app.file_size_bytes = getFileSize(p);
            app.scanDirectory(p);
        }

        app.fitToWindow();
        app.updateTitle();
        return app;
    }

    pub fn deinit(self: *ImageViewerApp) void {
        const alloc = self.allocator;
        for (self.dir_files.items) |p| alloc.free(p);
        self.dir_files.deinit(alloc);

        if (self.file_path) |p| alloc.free(p);
        if (self.image) |*img| img.deinit();

        self.font.deinit();
        alloc.destroy(self.font);
        self.win.deinit();
        alloc.destroy(self);
    }

    fn getFileSize(path: []const u8) usize {
        const p_z = std.posix.toPosixPath(path) catch return 0;
        var st: c.struct_stat = undefined;
        if (c.stat(&p_z, &st) == 0) {
            return @intCast(@max(0, st.st_size));
        }
        return 0;
    }

    pub fn scanDirectory(self: *ImageViewerApp, current_path: []const u8) void {
        for (self.dir_files.items) |p| self.allocator.free(p);
        self.dir_files.clearRetainingCapacity();

        const dirname = std.fs.path.dirname(current_path) orelse ".";
        const c_dir_path = self.allocator.dupeSentinel(u8, dirname, 0) catch return;
        defer self.allocator.free(c_dir_path);

        const dir = c.opendir(c_dir_path.ptr) orelse return;
        defer _ = c.closedir(dir);

        while (true) {
            const entry = c.readdir(dir) orelse break;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
            if (isSupportedImageExtension(name)) {
                const full = std.fs.path.join(self.allocator, &.{ dirname, name }) catch continue;
                self.dir_files.append(self.allocator, full) catch {
                    self.allocator.free(full);
                    continue;
                };
            }
        }

        if (self.dir_files.items.len > 0) {
            std.mem.sort([]const u8, self.dir_files.items, {}, stringLessThan);
            self.current_file_idx = 0;
            const target_base = std.fs.path.basename(current_path);
            for (self.dir_files.items, 0..) |p, i| {
                if (std.mem.eql(u8, p, current_path) or std.mem.eql(u8, std.fs.path.basename(p), target_base)) {
                    self.current_file_idx = i;
                    break;
                }
            }
        }
    }

    pub fn loadImageFromIndex(self: *ImageViewerApp, idx: usize) void {
        if (idx >= self.dir_files.items.len) return;
        const target_path = self.dir_files.items[idx];

        const new_img = ImageBuffer.loadFromFile(self.allocator, target_path) catch {
            self.setStatus("Failed to load image");
            return;
        };

        if (self.image) |*img| img.deinit();
        self.image = new_img;

        if (self.file_path) |p| self.allocator.free(p);
        self.file_path = self.allocator.dupe(u8, target_path) catch null;
        self.file_size_bytes = getFileSize(target_path);
        self.current_file_idx = idx;

        self.fitToWindow();
        self.updateTitle();
        self.win.needs_redraw = true;
    }

    pub fn nextImage(self: *ImageViewerApp) void {
        if (self.dir_files.items.len <= 1) return;
        self.current_file_idx = (self.current_file_idx + 1) % self.dir_files.items.len;
        self.loadImageFromIndex(self.current_file_idx);
    }

    pub fn prevImage(self: *ImageViewerApp) void {
        if (self.dir_files.items.len <= 1) return;
        if (self.current_file_idx == 0) {
            self.current_file_idx = self.dir_files.items.len - 1;
        } else {
            self.current_file_idx -= 1;
        }
        self.loadImageFromIndex(self.current_file_idx);
    }

    pub fn fitToWindow(self: *ImageViewerApp) void {
        const img = self.image orelse return;
        const win_w = @as(f32, @floatFromInt(self.win.width));
        const win_h = @as(f32, @floatFromInt(self.win.height));
        if (win_w <= 0.0 or win_h <= 0.0 or img.width == 0 or img.height == 0) return;

        const scale_w = win_w / @as(f32, @floatFromInt(img.width));
        const scale_h = win_h / @as(f32, @floatFromInt(img.height));
        self.zoom = @min(scale_w, scale_h);

        const scaled_w = @as(f32, @floatFromInt(img.width)) * self.zoom;
        const scaled_h = @as(f32, @floatFromInt(img.height)) * self.zoom;

        self.pan_x = (win_w - scaled_w) * 0.5;
        self.pan_y = (win_h - scaled_h) * 0.5;
        self.win.needs_redraw = true;
    }

    pub fn setActualSize(self: *ImageViewerApp) void {
        const img = self.image orelse return;
        const win_w = @as(f32, @floatFromInt(self.win.width));
        const win_h = @as(f32, @floatFromInt(self.win.height));

        self.zoom = 1.0;
        self.pan_x = (win_w - @as(f32, @floatFromInt(img.width))) * 0.5;
        self.pan_y = (win_h - @as(f32, @floatFromInt(img.height))) * 0.5;
        self.win.needs_redraw = true;
    }

    pub fn zoomAt(self: *ImageViewerApp, cursor_x: f32, cursor_y: f32, factor: f32) void {
        if (self.image == null) return;
        const old_zoom = self.zoom;
        var new_zoom = old_zoom * factor;
        new_zoom = @max(0.02, @min(64.0, new_zoom));
        if (new_zoom == old_zoom) return;

        self.pan_x = cursor_x - ((cursor_x - self.pan_x) / old_zoom) * new_zoom;
        self.pan_y = cursor_y - ((cursor_y - self.pan_y) / old_zoom) * new_zoom;
        self.zoom = new_zoom;
        self.win.needs_redraw = true;
    }

    pub fn rotateClockwise(self: *ImageViewerApp) !void {
        const img = self.image orelse return;
        const rotated = try img.rotate90(self.allocator);
        self.image.?.deinit();
        self.image = rotated;
        self.fitToWindow();
        self.setStatus("Rotated 90° CW");
    }

    pub fn rotateCounterClockwise(self: *ImageViewerApp) !void {
        const img = self.image orelse return;
        const rotated = try img.rotate270(self.allocator);
        self.image.?.deinit();
        self.image = rotated;
        self.fitToWindow();
        self.setStatus("Rotated 90° CCW");
    }

    pub fn flipHorizontal(self: *ImageViewerApp) !void {
        const img = self.image orelse return;
        const flipped = try img.flipHorizontal(self.allocator);
        self.image.?.deinit();
        self.image = flipped;
        self.win.needs_redraw = true;
        self.setStatus("Flipped Horizontally");
    }

    pub fn flipVertical(self: *ImageViewerApp) !void {
        const img = self.image orelse return;
        const flipped = try img.flipVertical(self.allocator);
        self.image.?.deinit();
        self.image = flipped;
        self.win.needs_redraw = true;
        self.setStatus("Flipped Vertically");
    }

    pub fn copyImage(self: *ImageViewerApp) !void {
        const img = self.image orelse return;
        try img.copyToClipboard(self.allocator);
        self.setStatus("Copied to clipboard (wl-copy)");
    }

    pub fn openInAnnotate(self: *ImageViewerApp) void {
        const path_to_open: []const u8 = if (self.file_path) |p| p else blk: {
            const tmp = "/tmp/mizu_view_edit.png";
            if (self.image) |*img| {
                _ = img.savePng(tmp) catch {};
            }
            break :blk tmp;
        };

        const pid = c.fork();
        if (pid == 0) {
            const path_z = self.allocator.dupeSentinel(u8, path_to_open, 0) catch return;
            const args = [_][*c]const u8{ "mizu", "annotate", path_z.ptr, null };
            _ = c.execvp("mizu", @ptrCast(&args));
            c.exit(1);
        }
        self.setStatus("Opened in Mizu Annotate");
    }

    pub fn setStatus(self: *ImageViewerApp, msg: []const u8) void {
        const len = @min(msg.len, self.status_msg.len);
        @memcpy(self.status_msg[0..len], msg[0..len]);
        self.status_len = len;
        self.status_ticks = 40; // ~2 seconds at 50ms tick
        self.win.needs_redraw = true;
    }

    pub fn updateTitle(self: *ImageViewerApp) void {
        if (self.win.xdg_toplevel) |t| {
            var t_buf: [256]u8 = undefined;
            const name = if (self.file_path) |p| std.fs.path.basename(p) else "stdin";
            const title = if (self.dir_files.items.len > 1)
                std.fmt.bufPrintSentinel(&t_buf, "{s} ({d}/{d}) - Mizu View", .{ name, self.current_file_idx + 1, self.dir_files.items.len }, 0) catch return
            else
                std.fmt.bufPrintSentinel(&t_buf, "{s} - Mizu View", .{name}, 0) catch return;
            c.xdg_toplevel_set_title(t, title.ptr);
        }
    }

    pub fn handleKey(self: *ImageViewerApp, sym: u32, utf8: []const u8, is_ctrl: bool, is_shift: bool) void {
        _ = utf8;
        if (sym == c.XKB_KEY_Escape or sym == c.XKB_KEY_q or sym == c.XKB_KEY_Q) {
            self.win.running = false;
            return;
        }

        // Navigation
        if (sym == c.XKB_KEY_Right or sym == c.XKB_KEY_l or sym == c.XKB_KEY_n or sym == c.XKB_KEY_space) {
            self.nextImage();
            return;
        }
        if (sym == c.XKB_KEY_Left or sym == c.XKB_KEY_h or sym == c.XKB_KEY_p or sym == c.XKB_KEY_BackSpace) {
            self.prevImage();
            return;
        }

        // Zoom & Scale
        if (sym == c.XKB_KEY_f or sym == c.XKB_KEY_F) {
            self.fitToWindow();
            self.setStatus("Fit to window");
            return;
        }
        if (sym == c.XKB_KEY_1 or sym == c.XKB_KEY_0) {
            self.setActualSize();
            self.setStatus("100% Actual size");
            return;
        }
        if (sym == c.XKB_KEY_plus or sym == c.XKB_KEY_equal or sym == c.XKB_KEY_KP_Add) {
            const cx = @as(f32, @floatFromInt(self.win.width)) * 0.5;
            const cy = @as(f32, @floatFromInt(self.win.height)) * 0.5;
            self.zoomAt(cx, cy, 1.25);
            return;
        }
        if (sym == c.XKB_KEY_minus or sym == c.XKB_KEY_underscore or sym == c.XKB_KEY_KP_Subtract) {
            const cx = @as(f32, @floatFromInt(self.win.width)) * 0.5;
            const cy = @as(f32, @floatFromInt(self.win.height)) * 0.5;
            self.zoomAt(cx, cy, 0.8);
            return;
        }

        // Transformations
        if (sym == c.XKB_KEY_r or sym == c.XKB_KEY_R) {
            if (is_shift or sym == c.XKB_KEY_R) {
                self.rotateCounterClockwise() catch {};
            } else {
                self.rotateClockwise() catch {};
            }
            return;
        }
        if (sym == c.XKB_KEY_m or sym == c.XKB_KEY_M) {
            self.flipHorizontal() catch {};
            return;
        }
        if (sym == c.XKB_KEY_v or sym == c.XKB_KEY_V) {
            self.flipVertical() catch {};
            return;
        }

        // Clipboard & Annotate Handoff
        if ((is_ctrl and (sym == c.XKB_KEY_c or sym == c.XKB_KEY_C)) or sym == c.XKB_KEY_c or sym == c.XKB_KEY_C) {
            self.copyImage() catch {};
            return;
        }
        if (sym == c.XKB_KEY_e or sym == c.XKB_KEY_E or sym == c.XKB_KEY_a or sym == c.XKB_KEY_A) {
            self.openInAnnotate();
            return;
        }

        // HUD Toggle
        if (sym == c.XKB_KEY_i or sym == c.XKB_KEY_I) {
            self.hud_visible = !self.hud_visible;
            self.win.needs_redraw = true;
            return;
        }
    }

    pub fn render(self: *ImageViewerApp) !void {
        var r = try self.win.getRenderer();

        // Dark canvas background
        const bg = Color.hex(0x121418);
        r.clear(bg);

        if (self.image) |*img| {
            const dest_w = @as(f64, @floatFromInt(img.width)) * @as(f64, @floatCast(self.zoom));
            const dest_h = @as(f64, @floatFromInt(img.height)) * @as(f64, @floatCast(self.zoom));
            const dest_x = @as(f64, @floatCast(self.pan_x));
            const dest_y = @as(f64, @floatCast(self.pan_y));

            // Shadow if image is bounded inside canvas
            if (dest_w < @as(f64, @floatFromInt(self.win.width)) or dest_h < @as(f64, @floatFromInt(self.win.height))) {
                const ix: i32 = @intFromFloat(dest_x);
                const iy: i32 = @intFromFloat(dest_y);
                const iw: u32 = @intFromFloat(@max(1.0, dest_w));
                const ih: u32 = @intFromFloat(@max(1.0, dest_h));
                r.drawSoftShadow(ix, iy, iw, ih, 4, 16, 4, Color.init(110, 0, 0, 0));
            }

            const img_wrapper = renderer.Image{
                .width = img.width,
                .height = img.height,
                .pixels = img.pixels,
                .allocator = self.allocator,
            };
            r.drawImage(&img_wrapper, dest_x, dest_y, dest_w, dest_h);
        } else {
            // Minimal empty state
            const th = self.cfg.theme;
            const cx = @divTrunc(@as(i32, @intCast(self.win.width)), 2);
            const cy = @divTrunc(@as(i32, @intCast(self.win.height)), 2);
            const msg1 = "󰋼 No image opened";
            const msg2 = "Pipe image via stdin: grim - | mizu view";
            const msg3 = "Or open a file: mizu view <path>";
            const w1 = r.measureTextWithSize(self.font, msg1, 15);
            const w2 = r.measureTextWithSize(self.font, msg2, 12);
            const w3 = r.measureTextWithSize(self.font, msg3, 12);
            r.drawTextWithSize(self.font, msg1, cx - @divTrunc(@as(i32, @intCast(w1)), 2), cy - 24, 15, th.text_main);
            r.drawTextWithSize(self.font, msg2, cx - @divTrunc(@as(i32, @intCast(w2)), 2), cy + 8, 12, th.text_muted);
            r.drawTextWithSize(self.font, msg3, cx - @divTrunc(@as(i32, @intCast(w3)), 2), cy + 30, 12, th.text_muted);
        }

        // Floating HUD overlay
        if (self.hud_visible and self.image != null) {
            self.renderHud(r);
        }

        // Action Status Toast
        if (self.status_ticks > 0 and self.status_len > 0) {
            self.renderStatusToast(r);
        }
    }

    fn renderHud(self: *ImageViewerApp, r: renderer.Renderer) void {
        const img = self.image orelse return;
        const win_w = self.win.width;
        const win_h = self.win.height;

        var buf: [256]u8 = undefined;
        var size_buf: [32]u8 = undefined;
        const size_str = formatFileSize(self.file_size_bytes, &size_buf);
        const name_str = if (self.file_path) |p| std.fs.path.basename(p) else "stdin";
        const zoom_pct = @as(u32, @intFromFloat(self.zoom * 100.0));

        const hud_text = if (self.dir_files.items.len > 1)
            std.fmt.bufPrint(
                &buf,
                "{s}   •   {d}×{d}   •   {d}%   •   {s}   •   [{d}/{d}]",
                .{ name_str, img.width, img.height, zoom_pct, size_str, self.current_file_idx + 1, self.dir_files.items.len },
            ) catch ""
        else
            std.fmt.bufPrint(
                &buf,
                "{s}   •   {d}×{d}   •   {d}%   •   {s}",
                .{ name_str, img.width, img.height, zoom_pct, size_str },
            ) catch "";

        const text_w = r.measureTextWithSize(self.font, hud_text, 11);
        const pill_w: u32 = text_w + 32;
        const pill_h: u32 = 32;
        const pill_x: i32 = @divTrunc(@as(i32, @intCast(win_w)) - @as(i32, @intCast(pill_w)), 2);
        const pill_y: i32 = @as(i32, @intCast(win_h)) - 48;

        // Shadow & translucent dark pill
        r.drawSoftShadow(pill_x, pill_y, pill_w, pill_h, 8, 16, 4, Color.init(140, 0, 0, 0));
        r.fillRoundedRect(pill_x, pill_y, pill_w, pill_h, 16, Color.init(215, 18, 20, 24));
        r.drawRoundedBorder(pill_x, pill_y, pill_w, pill_h, 16, 1, Color.init(24, 255, 255, 255));

        r.drawTextWithSize(self.font, hud_text, pill_x + 16, pill_y + 20, 11, Color.hex(0xABB2BF));
    }

    fn renderStatusToast(self: *ImageViewerApp, r: renderer.Renderer) void {
        const win_w = self.win.width;
        const msg = self.status_msg[0..self.status_len];

        const text_w = r.measureTextWithSize(self.font, msg, 11);
        const pill_w: u32 = text_w + 28;
        const pill_h: u32 = 28;
        const pill_x: i32 = @divTrunc(@as(i32, @intCast(win_w)) - @as(i32, @intCast(pill_w)), 2);
        const pill_y: i32 = 20;

        r.drawSoftShadow(pill_x, pill_y, pill_w, pill_h, 6, 12, 3, Color.init(120, 0, 0, 0));
        r.fillRoundedRect(pill_x, pill_y, pill_w, pill_h, 14, Color.init(230, 24, 28, 36));
        r.drawRoundedBorder(pill_x, pill_y, pill_w, pill_h, 14, 1, Color.init(120, 97, 175, 239));

        r.drawTextWithSize(self.font, msg, pill_x + 14, pill_y + 18, 11, Color.hex(0x61AFEF));
    }
};

// ==========================================
// Stdin & Main Application Event Loop
// ==========================================

pub fn readAllFromStdin(allocator: std.mem.Allocator) ![]u8 {
    var list = std.ArrayListUnmanaged(u8).empty;
    errdefer list.deinit(allocator);

    var buf: [65536]u8 = undefined;
    while (true) {
        const rc = c.read(0, &buf, buf.len);
        if (rc < 0) {
            const err = std.posix.errno(rc);
            if (err == .INTR) continue;
            return error.ReadFailed;
        }
        if (rc == 0) break; // EOF
        try list.appendSlice(allocator, buf[0..@intCast(rc)]);
    }
    return list.toOwnedSlice(allocator);
}

pub fn run(allocator: std.mem.Allocator, cfg: config.Config, file_to_open: ?[]const u8) !u8 {
    var initial_image: ?ImageBuffer = null;
    const is_stdin = if (file_to_open) |f| std.mem.eql(u8, f, "-") else (c.isatty(0) == 0);

    if (is_stdin) {
        // Read stdin until EOF BEFORE creating the Wayland window
        // (prevents obscuring interactive tools like grim -g "$(slurp)" -)
        const stdin_bytes = readAllFromStdin(allocator) catch null;
        if (stdin_bytes) |bytes| {
            defer allocator.free(bytes);
            if (bytes.len > 0) {
                initial_image = ImageBuffer.loadFromMemory(allocator, bytes) catch null;
            }
        }
    } else if (file_to_open) |path| {
        initial_image = ImageBuffer.loadFromFile(allocator, path) catch null;
    }

    var app = try ImageViewerApp.init(allocator, cfg, initial_image, if (is_stdin) null else file_to_open);
    defer app.deinit();

    const display_fd = c.wl_display_get_fd(app.win.display.?);

    var prev_px: i32 = -1;
    var prev_py: i32 = -1;
    var prev_pdown: bool = false;

    while (app.win.running) {
        while (c.wl_display_prepare_read(app.win.display.?) != 0) {
            _ = c.wl_display_dispatch_pending(app.win.display.?);
        }
        _ = c.wl_display_flush(app.win.display.?);

        var poll_fds = [_]c.struct_pollfd{
            .{ .fd = display_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (app.win.repeat_timer_fd >= 0) app.win.repeat_timer_fd else -1, .events = c.POLLIN, .revents = 0 },
        };

        const poll_res = c.poll(&poll_fds, 2, 50);
        if (poll_res < 0) {
            c.wl_display_cancel_read(app.win.display.?);
            break;
        }

        if (poll_fds[0].revents & (c.POLLHUP | c.POLLERR) != 0) {
            c.wl_display_cancel_read(app.win.display.?);
            break;
        }

        if (poll_res == 0) {
            c.wl_display_cancel_read(app.win.display.?);
        } else {
            if (poll_fds[0].revents & c.POLLIN != 0) {
                _ = c.wl_display_read_events(app.win.display.?);
            } else {
                c.wl_display_cancel_read(app.win.display.?);
            }
        }
        _ = c.wl_display_dispatch_pending(app.win.display.?);

        const cur_px = app.win.pointer_x;
        const cur_py = app.win.pointer_y;
        const cur_down = app.win.pointer_down;

        // Pointer panning
        if (cur_down and !prev_pdown) {
            app.is_panning = true;
            app.pan_start_x = cur_px;
            app.pan_start_y = cur_py;
            app.win.setCursorShape(.grab);
        } else if (!cur_down and prev_pdown) {
            app.is_panning = false;
            app.win.setCursorShape(.default);
        } else if (cur_down and (cur_px != prev_px or cur_py != prev_py)) {
            const dx = cur_px - app.pan_start_x;
            const dy = cur_py - app.pan_start_y;
            app.pan_x += @as(f32, @floatFromInt(dx));
            app.pan_y += @as(f32, @floatFromInt(dy));
            app.pan_start_x = cur_px;
            app.pan_start_y = cur_py;
            app.win.needs_redraw = true;
        }

        prev_px = cur_px;
        prev_py = cur_py;
        prev_pdown = cur_down;

        // Mouse wheel zooming centered at cursor
        if (app.win.scroll_delta_y != 0.0) {
            const scroll = app.win.scroll_delta_y;
            app.win.scroll_delta_y = 0.0;
            const cx = @as(f32, @floatFromInt(@max(0, cur_px)));
            const cy = @as(f32, @floatFromInt(@max(0, cur_py)));
            const factor: f32 = if (scroll < 0) 1.15 else (1.0 / 1.15);
            app.zoomAt(cx, cy, factor);
        }

        // Keyboard events
        if (app.win.repeat_sym != 0) {
            const sym = app.win.repeat_sym;
            const slice = app.win.repeat_utf8_buf[0..app.win.repeat_utf8_len];
            app.handleKey(sym, slice, app.win.is_ctrl, app.win.is_shift);
            app.win.repeat_sym = 0;
            app.win.repeat_utf8_len = 0;
        }

        // Status toast timer
        if (app.status_ticks > 0) {
            app.status_ticks -= 1;
            if (app.status_ticks == 0) {
                app.status_len = 0;
                app.win.needs_redraw = true;
            }
        }

        // Redraw
        if (app.win.needs_redraw and app.win.configured) {
            app.render() catch {};
            app.win.commitFrame();
        }
    }

    return 0;
}

test "ImageViewer supported image extensions" {
    try std.testing.expect(isSupportedImageExtension("photo.png"));
    try std.testing.expect(isSupportedImageExtension("photo.JPG"));
    try std.testing.expect(isSupportedImageExtension("image.jpeg"));
    try std.testing.expect(isSupportedImageExtension("vector.svg"));
    try std.testing.expect(isSupportedImageExtension("graphic.webp"));
    try std.testing.expect(!isSupportedImageExtension("notes.txt"));
    try std.testing.expect(!isSupportedImageExtension("binary.bin"));
}

test "ImageViewer formatFileSize" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("500 B", formatFileSize(500, &buf));
    try std.testing.expectEqualStrings("1.5 KB", formatFileSize(1536, &buf));
    try std.testing.expectEqualStrings("2.0 MB", formatFileSize(2 * 1024 * 1024, &buf));
}
