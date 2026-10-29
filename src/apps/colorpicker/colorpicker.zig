const std = @import("std");
const c = @import("c");
const buffer = @import("../../core/buffer.zig");
const renderer = @import("../../core/renderer.zig");
const theme = @import("../../core/theme.zig");
const wayland_win = @import("../../core/wayland_window.zig");
const image_ops = @import("../../graphics/image_ops.zig");
const config = @import("../../core/config.zig");

const Color = theme.Color;
const ImageBuffer = image_ops.ImageBuffer;
const WindowApp = wayland_win.WindowApp;
const WindowConfig = wayland_win.WindowConfig;

// ============================================================================
// Native Wayland Screencopy (hyprpicker style via zwlr_screencopy_manager_v1)
// ============================================================================

const ScreencopyState = struct {
    display: ?*c.wl_display = null,
    registry: ?*c.wl_registry = null,
    shm: ?*c.wl_shm = null,
    output: ?*c.wl_output = null,
    screencopy_mgr: ?*c.zwlr_screencopy_manager_v1 = null,
    frame: ?*c.zwlr_screencopy_frame_v1 = null,

    format: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    has_buffer: bool = false,
    done: bool = false,
    failed: bool = false,
    y_invert: bool = false,

    shm_fd: c_int = -1,
    shm_data: ?[*]u8 = null,
    shm_size: usize = 0,
    buffer: ?*c.wl_buffer = null,
};

fn frameHandleBuffer(
    data: ?*anyopaque,
    frame: ?*c.zwlr_screencopy_frame_v1,
    format: u32,
    width: u32,
    height: u32,
    stride: u32,
) callconv(.c) void {
    _ = frame;
    const s: *ScreencopyState = @ptrCast(@alignCast(data.?));
    s.format = format;
    s.width = width;
    s.height = height;
    s.stride = stride;
    s.has_buffer = true;

    // For screencopy version < 3, buffer_done event is not sent, copy immediately
    if (s.screencopy_mgr != null and c.zwlr_screencopy_manager_v1_get_version(s.screencopy_mgr.?) < 3) {
        setupAndCopyShmBuffer(s);
    }
}

fn frameHandleFlags(
    data: ?*anyopaque,
    frame: ?*c.zwlr_screencopy_frame_v1,
    flags: u32,
) callconv(.c) void {
    _ = frame;
    const s: *ScreencopyState = @ptrCast(@alignCast(data.?));
    s.y_invert = (flags & c.ZWLR_SCREENCOPY_FRAME_V1_FLAGS_Y_INVERT) != 0;
}

fn frameHandleReady(
    data: ?*anyopaque,
    frame: ?*c.zwlr_screencopy_frame_v1,
    tv_sec_hi: u32,
    tv_sec_lo: u32,
    tv_nsec: u32,
) callconv(.c) void {
    _ = frame;
    _ = tv_sec_hi;
    _ = tv_sec_lo;
    _ = tv_nsec;
    const s: *ScreencopyState = @ptrCast(@alignCast(data.?));
    s.done = true;
}

fn frameHandleFailed(
    data: ?*anyopaque,
    frame: ?*c.zwlr_screencopy_frame_v1,
) callconv(.c) void {
    _ = frame;
    const s: *ScreencopyState = @ptrCast(@alignCast(data.?));
    s.failed = true;
}

fn frameHandleDamage(
    data: ?*anyopaque,
    frame: ?*c.zwlr_screencopy_frame_v1,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
) callconv(.c) void {
    _ = data;
    _ = frame;
    _ = x;
    _ = y;
    _ = width;
    _ = height;
}

fn frameHandleLinuxDmabuf(
    data: ?*anyopaque,
    frame: ?*c.zwlr_screencopy_frame_v1,
    format: u32,
    width: u32,
    height: u32,
) callconv(.c) void {
    _ = data;
    _ = frame;
    _ = format;
    _ = width;
    _ = height;
}

fn frameHandleBufferDone(
    data: ?*anyopaque,
    frame: ?*c.zwlr_screencopy_frame_v1,
) callconv(.c) void {
    _ = frame;
    const s: *ScreencopyState = @ptrCast(@alignCast(data.?));
    setupAndCopyShmBuffer(s);
}

fn setupAndCopyShmBuffer(s: *ScreencopyState) void {
    if (s.buffer != null or !s.has_buffer or s.shm == null or s.frame == null) return;
    const size = @as(usize, s.stride) * @as(usize, s.height);
    s.shm_size = size;

    const fd = c.memfd_create("mizu-screencopy", 0x0001); // MFD_CLOEXEC
    if (fd < 0) {
        s.failed = true;
        return;
    }
    s.shm_fd = fd;
    if (c.ftruncate(fd, @intCast(size)) < 0) {
        s.failed = true;
        return;
    }
    const map = c.mmap(null, size, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
    if (map == c.MAP_FAILED or map == null) {
        s.failed = true;
        return;
    }
    s.shm_data = @ptrCast(map);

    const pool = c.wl_shm_create_pool(s.shm.?, fd, @intCast(size));
    if (pool == null) {
        s.failed = true;
        return;
    }
    defer c.wl_shm_pool_destroy(pool);

    const buf = c.wl_shm_pool_create_buffer(pool, 0, @intCast(s.width), @intCast(s.height), @intCast(s.stride), s.format);
    if (buf == null) {
        s.failed = true;
        return;
    }
    s.buffer = buf;
    c.zwlr_screencopy_frame_v1_copy(s.frame.?, buf);
}

const screencopy_frame_listener = c.struct_zwlr_screencopy_frame_v1_listener{
    .buffer = frameHandleBuffer,
    .flags = frameHandleFlags,
    .ready = frameHandleReady,
    .failed = frameHandleFailed,
    .damage = frameHandleDamage,
    .linux_dmabuf = frameHandleLinuxDmabuf,
    .buffer_done = frameHandleBufferDone,
};

fn screencopyRegistryGlobal(
    data: ?*anyopaque,
    registry: ?*c.wl_registry,
    name: u32,
    interface: [*c]const u8,
    version: u32,
) callconv(.c) void {
    const s: *ScreencopyState = @ptrCast(@alignCast(data.?));
    const iface = std.mem.span(interface);
    if (std.mem.eql(u8, iface, "wl_shm")) {
        s.shm = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_shm_interface, 1));
    } else if (std.mem.eql(u8, iface, "wl_output")) {
        if (s.output == null) {
            s.output = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_output_interface, 1));
        }
    } else if (std.mem.eql(u8, iface, "zwlr_screencopy_manager_v1")) {
        s.screencopy_mgr = @ptrCast(c.wl_registry_bind(registry, name, &c.zwlr_screencopy_manager_v1_interface, @min(version, 3)));
    }
}

fn screencopyRegistryGlobalRemove(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32) callconv(.c) void {
    _ = data;
    _ = registry;
    _ = name;
}

const screencopy_registry_listener = c.struct_wl_registry_listener{
    .global = screencopyRegistryGlobal,
    .global_remove = screencopyRegistryGlobalRemove,
};

pub fn captureScreenNative(allocator: std.mem.Allocator) !ImageBuffer {
    var s = ScreencopyState{};
    s.display = c.wl_display_connect(null);
    if (s.display == null) return error.DisplayConnectFailed;
    defer {
        if (s.frame) |f| c.zwlr_screencopy_frame_v1_destroy(f);
        if (s.buffer) |b| c.wl_buffer_destroy(b);
        if (s.shm_data) |d| _ = c.munmap(d, s.shm_size);
        if (s.shm_fd >= 0) _ = c.close(s.shm_fd);
        if (s.output) |o| c.wl_output_destroy(o);
        if (s.screencopy_mgr) |m| c.zwlr_screencopy_manager_v1_destroy(m);
        if (s.shm) |shm| c.wl_shm_destroy(shm);
        if (s.registry) |r| c.wl_registry_destroy(r);
        if (s.display) |disp| c.wl_display_disconnect(disp);
    }

    s.registry = c.wl_display_get_registry(s.display.?);
    if (s.registry == null) return error.GetRegistryFailed;
    _ = c.wl_registry_add_listener(s.registry.?, &screencopy_registry_listener, &s);

    _ = c.wl_display_roundtrip(s.display.?);
    _ = c.wl_display_roundtrip(s.display.?);

    if (s.screencopy_mgr == null) return error.ScreencopyNotSupported;
    if (s.shm == null or s.output == null) return error.MissingShmOrOutput;

    // Capture output frame (overlay_cursor = 0 so existing cursor is not frozen into pixels)
    s.frame = c.zwlr_screencopy_manager_v1_capture_output(s.screencopy_mgr.?, 0, s.output.?);
    if (s.frame == null) return error.CaptureOutputFailed;
    _ = c.zwlr_screencopy_frame_v1_add_listener(s.frame.?, &screencopy_frame_listener, &s);

    while (!s.done and !s.failed) {
        if (c.wl_display_dispatch(s.display.?) < 0) {
            return error.WaylandDispatchError;
        }
    }

    if (s.failed or s.shm_data == null or s.width == 0 or s.height == 0) {
        return error.ScreencopyFailed;
    }

    var img = try ImageBuffer.init(allocator, s.width, s.height, Color.transparent);
    errdefer img.deinit();

    const is_xbgr = (s.format == 0x34324258 or s.format == 0x34324241); // DRM_FORMAT_XBGR8888 or ABGR8888
    const is_rgba = (s.format == 0x34324152); // DRM_FORMAT_RGBA8888
    const is_bgra = (s.format == 0x34324142); // DRM_FORMAT_BGRA8888

    for (0..s.height) |y| {
        const src_y = if (s.y_invert) (s.height - 1 - y) else y;
        const row_offset = src_y * s.stride;
        const src_row: [*]const u8 = s.shm_data.? + row_offset;
        const dst_row_offset = y * s.width;

        for (0..s.width) |x| {
            const b0 = src_row[x * 4 + 0];
            const b1 = src_row[x * 4 + 1];
            const b2 = src_row[x * 4 + 2];

            var r: u8 = 0;
            var g: u8 = 0;
            var b: u8 = 0;

            if (is_xbgr or is_rgba) {
                r = b0;
                g = b1;
                b = b2;
            } else if (is_bgra) {
                b = b0;
                g = b1;
                r = b2;
            } else {
                // XRGB8888 / ARGB8888
                b = b0;
                g = b1;
                r = b2;
            }

            const argb: u32 = (@as(u32, 255) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
            img.pixels[dst_row_offset + x] = argb;
        }
    }

    return img;
}

fn captureScreenGrim(allocator: std.mem.Allocator) ?ImageBuffer {
    const tmp_path = "/tmp/mizu_colorpicker_tmp.png";
    _ = c.unlink(tmp_path);
    defer _ = c.unlink(tmp_path);

    var cmd_buf: [512]u8 = undefined;
    const cmd_str = std.fmt.bufPrintSentinel(
        &cmd_buf,
        "export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; grim {s}",
        .{tmp_path},
        0,
    ) catch return null;

    const ret = c.system(cmd_str.ptr);
    if (ret != 0) return null;

    return ImageBuffer.loadFromFile(allocator, tmp_path) catch null;
}

// ============================================================================
// Main Color Picker Entrypoint
// ============================================================================

pub fn run(allocator: std.mem.Allocator, cfg: config.Config) !u8 {
    // Attempt native screencopy first (hyprpicker-style), fallback to grim only if unsupported
    var img_opt: ?ImageBuffer = captureScreenNative(allocator) catch null;
    if (img_opt == null) {
        img_opt = captureScreenGrim(allocator);
    }

    if (img_opt == null) {
        std.debug.print("mizu: colorpicker failed to capture screen (native zwlr_screencopy and grim unavailable).\n", .{});
        return 1;
    }
    var screenshot = img_opt.?;
    defer screenshot.deinit();

    const win_cfg = WindowConfig{
        .title = "Mizu Color Picker",
        .app_id = "mizu-colorpicker",
        .width = 400,
        .height = 240,
        .fullscreen_layer = true,
    };

    var win = try WindowApp.init(allocator, win_cfg);
    defer win.deinit();

    const display_fd = c.wl_display_get_fd(win.display.?);
    const timer_fd = c.timerfd_create(c.CLOCK_MONOTONIC, c.TFD_CLOEXEC | c.TFD_NONBLOCK);
    if (timer_fd >= 0) {
        var its: c.struct_itimerspec = undefined;
        its.it_interval.tv_sec = 0;
        its.it_interval.tv_nsec = 16_666_667; // ~60fps
        its.it_value.tv_sec = 0;
        its.it_value.tv_nsec = 16_666_667;
        _ = c.timerfd_settime(timer_fd, 0, &its, null);
        defer _ = c.close(timer_fd);
    }

    var font = try renderer.Font.init(allocator, cfg.theme.font_family, cfg.typography.ui);
    defer font.deinit();

    var selected: bool = false;
    var selected_hex_str: [8]u8 = undefined;

    var pointer_screen_x: i32 = -1;
    var pointer_screen_y: i32 = -1;

    while (win.running and !selected) {
        while (c.wl_display_prepare_read(win.display.?) != 0) {
            _ = c.wl_display_dispatch_pending(win.display.?);
        }
        _ = c.wl_display_flush(win.display.?);

        var poll_fds: [3]c.struct_pollfd = .{
            .{ .fd = display_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (timer_fd >= 0) timer_fd else -1, .events = c.POLLIN, .revents = 0 },
            .{ .fd = -1, .events = 0, .revents = 0 },
        };
        const poll_res = c.poll(&poll_fds, 3, 16);

        if (poll_fds[0].revents & (c.POLLHUP | c.POLLERR) != 0) {
            c.wl_display_cancel_read(win.display.?);
            break;
        }
        if (poll_fds[0].revents & c.POLLIN != 0) {
            _ = c.wl_display_read_events(win.display.?);
        } else {
            c.wl_display_cancel_read(win.display.?);
        }
        _ = c.wl_display_dispatch_pending(win.display.?);

        // Update pointer coordinates from WindowApp state
        pointer_screen_x = win.pointer_x;
        pointer_screen_y = win.pointer_y;

        win.setCursorShape(.crosshair);

        // Check for Escape or Q key to cancel
        if (win.repeat_sym == 0xff1b or win.repeat_sym == 'q' or win.repeat_sym == 'Q') {
            selected = false;
            break;
        }

        if (win.pointer_down and win.mouse_button == 0x110) {
            // Left click - sample color and confirm
            const scale_x: f32 = if (win.width > 0) @as(f32, @floatFromInt(screenshot.width)) / @as(f32, @floatFromInt(win.width)) else 1.0;
            const scale_y: f32 = if (win.height > 0) @as(f32, @floatFromInt(screenshot.height)) / @as(f32, @floatFromInt(win.height)) else 1.0;
            const sx_f = @as(f32, @floatFromInt(std.math.clamp(pointer_screen_x, 0, @as(i32, @intCast(win.width)) - 1))) * scale_x;
            const sy_f = @as(f32, @floatFromInt(std.math.clamp(pointer_screen_y, 0, @as(i32, @intCast(win.height)) - 1))) * scale_y;
            const sx = std.math.clamp(@as(i32, @intFromFloat(@round(sx_f))), 0, @as(i32, @intCast(screenshot.width)) - 1);
            const sy = std.math.clamp(@as(i32, @intFromFloat(@round(sy_f))), 0, @as(i32, @intCast(screenshot.height)) - 1);

            const pixel = screenshot.getPixel(sx, sy) orelse Color.rgb(0, 0, 0);
            _ = std.fmt.bufPrint(selected_hex_str[0..7], "#{X:0>2}{X:0>2}{X:0>2}", .{
                pixel.r, pixel.g, pixel.b,
            }) catch "#000000";
            selected_hex_str[7] = 0;
            selected = true;
            break;
        } else if (win.pointer_down and win.mouse_button == 0x111) {
            // Right click cancels
            selected = false;
            break;
        }

        if (poll_fds[1].revents & c.POLLIN != 0) {
            var expirations: u64 = 0;
            _ = c.read(timer_fd, &expirations, @sizeOf(u64));
        }

        if (poll_res > 0) {
            win.needs_redraw = true;
        }

        // Redraw overlay
        if (win.needs_redraw and win.configured) {
            try redrawOverlay(win, screenshot, pointer_screen_x, pointer_screen_y, &font);
            _ = c.wl_display_flush(win.display.?);
            win.needs_redraw = false;
        }
    }

    if (selected) {
        const hex_slice = std.mem.sliceTo(&selected_hex_str, 0);
        // Copy to clipboard using wl-copy
        var copy_cmd_buf: [256]u8 = undefined;
        const copy_cmd = std.fmt.bufPrintSentinel(
            &copy_cmd_buf,
            "export PATH=\"$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:$HOME/.local/bin\"; wl-copy '{s}'",
            .{hex_slice},
            0,
        ) catch "wl-copy '#000000'";
        _ = c.system(copy_cmd.ptr);
        std.debug.print("{s}\n", .{hex_slice});
        return 0;
    }
    return 1;
}

fn redrawOverlay(
    win: *WindowApp,
    screenshot: ImageBuffer,
    cursor_x: i32,
    cursor_y: i32,
    font: *renderer.Font,
) !void {
    if (!win.configured or win.width == 0 or win.height == 0) return;
    const surf = win.surface orelse return;
    const phys_w = @as(u32, @intCast(win.width));
    const phys_h = @as(u32, @intCast(win.height));
    var pool = win.buffer_pool orelse return;
    var shmbuf = try pool.getNextBuffer(phys_w, phys_h);
    defer shmbuf.deinit();
    var target = try renderer.Renderer.init(shmbuf.data.?, phys_w, phys_h, shmbuf.stride);
    defer target.deinit();

    // Clear transparent so desktop remains visible
    target.clear(Color.transparent);

    // If pointer hasn't entered surface yet, just commit blank transparent surface
    if (cursor_x < 0 or cursor_y < 0) {
        c.wl_surface_attach(surf, shmbuf.buffer.?, 0, 0);
        c.wl_surface_damage_buffer(surf, 0, 0, @intCast(phys_w), @intCast(phys_h));
        c.wl_surface_commit(surf);
        return;
    }

    const scale_x: f32 = if (win.width > 0) @as(f32, @floatFromInt(screenshot.width)) / @as(f32, @floatFromInt(win.width)) else 1.0;
    const scale_y: f32 = if (win.height > 0) @as(f32, @floatFromInt(screenshot.height)) / @as(f32, @floatFromInt(win.height)) else 1.0;

    const sx_center = std.math.clamp(@as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(cursor_x)) * scale_x))), 0, @as(i32, @intCast(screenshot.width)) - 1);
    const sy_center = std.math.clamp(@as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(cursor_y)) * scale_y))), 0, @as(i32, @intCast(screenshot.height)) - 1);
    const center_pixel = screenshot.getPixel(sx_center, sy_center) orelse Color.rgb(0, 0, 0);

    // Floating loupe card
    const card_w: u32 = 144;
    const card_h: u32 = 148;
    const cell_size: u32 = 8;
    const grid_cells: u32 = 9;
    const grid_size: u32 = grid_cells * cell_size; // 72px
    const grid_radius: i32 = 4;

    // Card placement relative to cursor: offset by +18px, flip if near edges
    var card_x: i32 = cursor_x + 18;
    var card_y: i32 = cursor_y + 18;

    if (card_x + @as(i32, @intCast(card_w)) > @as(i32, @intCast(win.width)) - 8) {
        card_x = cursor_x - @as(i32, @intCast(card_w)) - 18;
    }
    if (card_y + @as(i32, @intCast(card_h)) > @as(i32, @intCast(win.height)) - 8) {
        card_y = cursor_y - @as(i32, @intCast(card_h)) - 18;
    }
    card_x = std.math.clamp(card_x, 8, @as(i32, @intCast(win.width)) - @as(i32, @intCast(card_w)) - 8);
    card_y = std.math.clamp(card_y, 8, @as(i32, @intCast(win.height)) - @as(i32, @intCast(card_h)) - 8);

    // Card shadow and background
    target.drawDropShadow(card_x, card_y, card_w, card_h, 12, 14, Color.init(100, 0, 0, 0));
    target.fillRoundedRect(card_x, card_y, card_w, card_h, 12, Color.init(240, 20, 20, 24));
    target.drawRoundedBorder(card_x, card_y, card_w, card_h, 12, 1, Color.init(60, 255, 255, 255));

    // Magnified pixel grid (Loupe)
    const loupe_x = card_x + @as(i32, @intCast((card_w - grid_size) / 2));
    const loupe_y = card_y + 10;

    for (0..grid_cells) |gy| {
        const dy: i32 = @as(i32, @intCast(gy)) - grid_radius;
        const py = std.math.clamp(sy_center + dy, 0, @as(i32, @intCast(screenshot.height)) - 1);
        for (0..grid_cells) |gx| {
            const dx: i32 = @as(i32, @intCast(gx)) - grid_radius;
            const px = std.math.clamp(sx_center + dx, 0, @as(i32, @intCast(screenshot.width)) - 1);
            const col = screenshot.getPixel(px, py) orelse Color.rgb(0, 0, 0);
            const cx = loupe_x + @as(i32, @intCast(gx * cell_size));
            const cy = loupe_y + @as(i32, @intCast(gy * cell_size));
            target.fillRect(cx, cy, cell_size, cell_size, col);
        }
    }

    // Grid border
    target.drawRoundedBorder(loupe_x - 1, loupe_y - 1, grid_size + 2, grid_size + 2, 2, 1, Color.init(100, 255, 255, 255));

    // Center pixel crosshair / highlight
    const center_cell_x = loupe_x + @as(i32, @intCast(grid_radius)) * @as(i32, @intCast(cell_size));
    const center_cell_y = loupe_y + @as(i32, @intCast(grid_radius)) * @as(i32, @intCast(cell_size));
    target.drawRoundedBorder(center_cell_x - 1, center_cell_y - 1, cell_size + 2, cell_size + 2, 0, 1, Color.init(255, 255, 255, 255));

    // Swatch and text info
    const swatch_y = loupe_y + @as(i32, @intCast(grid_size)) + 10;
    const swatch_x = card_x + 14;
    const swatch_size: u32 = 18;

    target.fillRoundedRect(swatch_x, swatch_y, swatch_size, swatch_size, 4, center_pixel);
    target.drawRoundedBorder(swatch_x, swatch_y, swatch_size, swatch_size, 4, 1, Color.init(120, 255, 255, 255));

    var hex_buf: [32]u8 = undefined;
    const hex_text = std.fmt.bufPrint(&hex_buf, "#{X:0>2}{X:0>2}{X:0>2}", .{
        center_pixel.r, center_pixel.g, center_pixel.b,
    }) catch "#000000";
    target.drawTextWithSize(font, hex_text, swatch_x + @as(i32, @intCast(swatch_size)) + 8, swatch_y + 14, 14, Color.init(255, 255, 255, 255));

    var rgb_buf: [32]u8 = undefined;
    const rgb_text = std.fmt.bufPrint(&rgb_buf, "rgb({d}, {d}, {d})", .{
        center_pixel.r, center_pixel.g, center_pixel.b,
    }) catch "rgb(0,0,0)";
    target.drawTextWithSize(font, rgb_text, card_x + 14, swatch_y + 34, 11, Color.init(200, 180, 180, 180));

    c.wl_surface_attach(surf, shmbuf.buffer.?, 0, 0);
    c.wl_surface_damage_buffer(surf, 0, 0, @intCast(phys_w), @intCast(phys_h));
    c.wl_surface_commit(surf);
}
