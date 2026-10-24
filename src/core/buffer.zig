const std = @import("std");
const c = @import("../c.zig").c;

pub const ShmBuffer = struct {
    buffer: ?*c.wl_buffer = null,
    data: ?[*]u32 = null,
    size: usize = 0,
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    busy: bool = false,

    fn buffer_release(data: ?*anyopaque, buffer: ?*c.wl_buffer) callconv(.c) void {
        _ = buffer;
        if (data) |ptr| {
            const self: *ShmBuffer = @ptrCast(@alignCast(ptr));
            self.busy = false;
        }
    }

    const buffer_listener = c.wl_buffer_listener{
        .release = buffer_release,
    };

    pub fn deinit(self: *ShmBuffer) void {
        if (self.buffer) |buf| {
            c.wl_buffer_destroy(buf);
            self.buffer = null;
        }
        if (self.data) |d| {
            _ = c.munmap(d, self.size);
            self.data = null;
        }
        self.size = 0;
        self.width = 0;
        self.height = 0;
        self.stride = 0;
        self.busy = false;
    }
};

pub const BufferPool = struct {
    shm: ?*c.wl_shm = null,
    buffers: [4]ShmBuffer = .{ .{}, .{}, .{}, .{} },
    current_index: usize = 0,

    pub fn init(shm: *c.wl_shm) BufferPool {
        return .{
            .shm = shm,
        };
    }

    pub fn deinit(self: *BufferPool) void {
        for (&self.buffers) |*buf| {
            buf.deinit();
        }
    }

    fn createShmFd(size: usize) !c_int {
        // memfd_create with MFD_CLOEXEC
        const fd = c.memfd_create("mizu-shm", 0x0001); // MFD_CLOEXEC = 0x0001
        if (fd < 0) {
            return error.MemfdFailed;
        }
        if (c.ftruncate(fd, @intCast(size)) < 0) {
            _ = c.close(fd);
            return error.FtruncateFailed;
        }
        return fd;
    }

    pub fn getNextBuffer(self: *BufferPool, width: u32, height: u32) !*ShmBuffer {
        const stride = width * 4;
        const size: usize = @as(usize, stride) * @as(usize, height);

        // Try to find a buffer that isn't busy
        var chosen_buf: ?*ShmBuffer = null;
        for (&self.buffers) |*buf| {
            if (!buf.busy) {
                chosen_buf = buf;
                break;
            }
        }

        // If all are busy, cycle to next index
        if (chosen_buf == null) {
            self.current_index = (self.current_index + 1) % self.buffers.len;
            chosen_buf = &self.buffers[self.current_index];
        }

        const buf = chosen_buf.?;

        // Reallocate if dimensions changed or buffer not yet created
        if (buf.buffer == null or buf.width != width or buf.height != height) {
            buf.deinit();

            const fd = try createShmFd(size);
            defer _ = c.close(fd);

            const mmap_ptr = c.mmap(null, size, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
            if (mmap_ptr == c.MAP_FAILED) {
                return error.MmapFailed;
            }

            const pool = c.wl_shm_create_pool(self.shm, fd, @intCast(size));
            if (pool == null) {
                _ = c.munmap(mmap_ptr, size);
                return error.CreatePoolFailed;
            }
            defer c.wl_shm_pool_destroy(pool);

            const wl_buf = c.wl_shm_pool_create_buffer(
                pool,
                0,
                @intCast(width),
                @intCast(height),
                @intCast(stride),
                c.WL_SHM_FORMAT_ARGB8888,
            );
            if (wl_buf == null) {
                _ = c.munmap(mmap_ptr, size);
                return error.CreateBufferFailed;
            }

            buf.buffer = wl_buf;
            buf.data = @ptrCast(@alignCast(mmap_ptr));
            buf.size = size;
            buf.width = width;
            buf.height = height;
            buf.stride = stride;
            buf.busy = false;

            _ = c.wl_buffer_add_listener(wl_buf, &ShmBuffer.buffer_listener, buf);
        }

        return buf;
    }

    pub fn createSingleBuffer(shm: *c.wl_shm, width: u32, height: u32) !ShmBuffer {
        const stride = width * 4;
        const size: usize = @as(usize, stride) * @as(usize, height);
        const fd = try createShmFd(size);
        defer _ = c.close(fd);

        const mmap_ptr = c.mmap(null, size, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
        if (mmap_ptr == c.MAP_FAILED) {
            return error.MmapFailed;
        }

        const pool = c.wl_shm_create_pool(shm, fd, @intCast(size));
        if (pool == null) {
            _ = c.munmap(mmap_ptr, size);
            return error.CreatePoolFailed;
        }
        defer c.wl_shm_pool_destroy(pool);

        const wl_buf = c.wl_shm_pool_create_buffer(
            pool,
            0,
            @intCast(width),
            @intCast(height),
            @intCast(stride),
            c.WL_SHM_FORMAT_ARGB8888,
        );
        if (wl_buf == null) {
            _ = c.munmap(mmap_ptr, size);
            return error.CreateBufferFailed;
        }

        const data_ptr: [*]u32 = @ptrCast(@alignCast(mmap_ptr));
        @memset(data_ptr[0 .. size / 4], 0);

        return ShmBuffer{
            .buffer = wl_buf,
            .data = data_ptr,
            .size = size,
            .width = width,
            .height = height,
            .stride = stride,
            .busy = false,
        };
    }
};
