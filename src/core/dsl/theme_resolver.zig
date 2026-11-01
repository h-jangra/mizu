const std = @import("std");
const theme = @import("../theme.zig");

pub const ThemeResolver = struct {
    allocator: std.mem.Allocator,
    theme_name: []const u8,
    loaded: ?theme.Theme = null,

    pub fn init(alloc: std.mem.Allocator, theme_name: []const u8) ThemeResolver {
        return .{ .allocator = alloc, .theme_name = theme_name, .loaded = theme.loadTheme(theme_name) };
    }

    pub fn deinit(self: *ThemeResolver) void {
        _ = self;
        // Theme is loaded as a static value; no persistent allocations per lookup
    }

    pub fn resolve(self: *ThemeResolver, var_path: []const u8) ?theme.Color {
        const th = self.loaded orelse return null;
        const s = std.mem.trim(u8, var_path, " \t");
        if (std.mem.eql(u8, s, "theme.accent")) return th.accent;
        if (std.mem.eql(u8, s, "theme.base")) return th.base;
        if (std.mem.eql(u8, s, "theme.surface")) return th.surface;
        if (std.mem.eql(u8, s, "theme.text_main")) return th.text_main;
        if (std.mem.eql(u8, s, "theme.text_muted")) return th.text_muted;
        if (std.mem.eql(u8, s, "theme.border")) return th.border;
        return null;
    }
};
