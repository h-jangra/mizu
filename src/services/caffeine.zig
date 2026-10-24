const std = @import("std");
const c = @import("../c.zig").c;

var signal_running = true;

fn handleSignal(sig: c_int) callconv(.c) void {
    _ = sig;
    signal_running = false;
}

const State = struct {
    compositor: ?*c.wl_compositor = null,
    shm: ?*c.wl_shm = null,
    layer_shell: ?*c.zwlr_layer_shell_v1 = null,
    idle_manager: ?*c.zwp_idle_inhibit_manager_v1 = null,
    surface: ?*c.wl_surface = null,
    layer_surface: ?*c.zwlr_layer_surface_v1 = null,
    buffer: ?*c.wl_buffer = null,
    inhibitor: ?*c.zwp_idle_inhibitor_v1 = null,
    configured: bool = false,
    running: bool = true,
};

fn registryGlobal(
    data: ?*anyopaque,
    registry: ?*c.wl_registry,
    name: u32,
    interface: [*c]const u8,
    version: u32,
) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data.?));
    const iface = std.mem.span(interface);

    if (std.mem.eql(u8, iface, "wl_compositor")) {
        state.compositor = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_compositor_interface, @min(version, 4)));
    } else if (std.mem.eql(u8, iface, "wl_shm")) {
        state.shm = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_shm_interface, 1));
    } else if (std.mem.eql(u8, iface, "zwlr_layer_shell_v1")) {
        state.layer_shell = @ptrCast(c.wl_registry_bind(registry, name, &c.zwlr_layer_shell_v1_interface, @min(version, 4)));
    } else if (std.mem.eql(u8, iface, "zwp_idle_inhibit_manager_v1")) {
        state.idle_manager = @ptrCast(c.wl_registry_bind(registry, name, &c.zwp_idle_inhibit_manager_v1_interface, 1));
    }
}

const registry_listener = c.wl_registry_listener{
    .global = registryGlobal,
    .global_remove = struct {
        fn remove(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32) callconv(.c) void {
            _ = data;
            _ = registry;
            _ = name;
        }
    }.remove,
};

fn layerConfigure(
    data: ?*anyopaque,
    surface: ?*c.zwlr_layer_surface_v1,
    serial: u32,
    width: u32,
    height: u32,
) callconv(.c) void {
    _ = width;
    _ = height;
    c.zwlr_layer_surface_v1_ack_configure(surface, serial);
    const state: *State = @ptrCast(@alignCast(data.?));
    state.configured = true;
}

fn layerClosed(data: ?*anyopaque, surface: ?*c.zwlr_layer_surface_v1) callconv(.c) void {
    _ = surface;
    const state: *State = @ptrCast(@alignCast(data.?));
    state.running = false;
}

const layer_listener = c.zwlr_layer_surface_v1_listener{
    .configure = layerConfigure,
    .closed = layerClosed,
};

/// Run a persistent idle inhibitor. The associated surface must be mapped and
/// visible for the compositor to honor the inhibitor, so a transparent 1x1
/// overlay layer surface is kept alive for the lifetime of this process.
pub fn run() u8 {
    _ = c.signal(c.SIGTERM, handleSignal);
    _ = c.signal(c.SIGINT, handleSignal);

    const display = c.wl_display_connect(null) orelse return 1;
    defer c.wl_display_disconnect(display);

    var state = State{};
    const registry = c.wl_display_get_registry(display) orelse return 1;
    defer c.wl_registry_destroy(registry);
    _ = c.wl_registry_add_listener(registry, &registry_listener, &state);
    _ = c.wl_display_roundtrip(display);

    if (state.compositor == null or state.shm == null or
        state.layer_shell == null or state.idle_manager == null)
    {
        return 2;
    }

    const surface = c.wl_compositor_create_surface(state.compositor.?) orelse return 3;
    state.surface = surface;
    defer c.wl_surface_destroy(surface);

    const layer_surface = c.zwlr_layer_shell_v1_get_layer_surface(
        state.layer_shell.?,
        surface,
        null,
        c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
        "mizu-caffeine",
    ) orelse return 4;
    state.layer_surface = layer_surface;
    defer c.zwlr_layer_surface_v1_destroy(layer_surface);

    _ = c.zwlr_layer_surface_v1_add_listener(layer_surface, &layer_listener, &state);
    c.zwlr_layer_surface_v1_set_anchor(layer_surface, c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP);
    c.zwlr_layer_surface_v1_set_size(layer_surface, 1, 1);
    c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surface, -1);
    c.zwlr_layer_surface_v1_set_keyboard_interactivity(
        layer_surface,
        c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE,
    );

    if (c.wl_compositor_create_region(state.compositor.?)) |region| {
        c.wl_surface_set_input_region(surface, region);
        c.wl_region_destroy(region);
    }

    c.wl_surface_commit(surface);
    while (!state.configured and state.running and signal_running) {
        if (c.wl_display_dispatch(display) < 0) return 5;
    }
    if (!state.running or !signal_running) return 0;

    const fd = c.memfd_create("mizu-caffeine", 0x0001);
    if (fd < 0) return 6;
    defer _ = c.close(fd);
    if (c.ftruncate(fd, 4) != 0) return 7;

    const map = c.mmap(null, 4, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
    if (map == c.MAP_FAILED) return 8;
    defer _ = c.munmap(map, 4);
    @memset(@as([*]u8, @ptrCast(map))[0..4], 0);

    const pool = c.wl_shm_create_pool(state.shm.?, fd, 4) orelse return 9;
    defer c.wl_shm_pool_destroy(pool);
    const buffer = c.wl_shm_pool_create_buffer(
        pool,
        0,
        1,
        1,
        4,
        c.WL_SHM_FORMAT_ARGB8888,
    ) orelse return 10;
    state.buffer = buffer;
    defer c.wl_buffer_destroy(buffer);

    c.wl_surface_attach(surface, buffer, 0, 0);
    c.wl_surface_damage_buffer(surface, 0, 0, 1, 1);
    c.wl_surface_commit(surface);

    state.inhibitor = c.zwp_idle_inhibit_manager_v1_create_inhibitor(state.idle_manager.?, surface);
    if (state.inhibitor == null) return 11;
    defer c.zwp_idle_inhibitor_v1_destroy(state.inhibitor.?);

    while (state.running and signal_running) {
        if (c.wl_display_dispatch(display) < 0) break;
    }
    return 0;
}
