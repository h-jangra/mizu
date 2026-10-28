const std = @import("std");
const theme = @import("../core/theme.zig");
const types = @import("context.zig");
const c = @import("../c.zig").c;
const ui_mod = @import("../core/ui.zig");

pub const RecordAudioMode = enum {
    system,
    mic,
    none,

    pub fn toLabel(self: RecordAudioMode) []const u8 {
        return switch (self) {
            .system => "System sounds",
            .mic => "Microphone",
            .none => "No audio",
        };
    }

    pub fn toShortLabel(self: RecordAudioMode) []const u8 {
        return switch (self) {
            .system => "System",
            .mic => "Mic",
            .none => "Muted",
        };
    }

    pub fn toIcon(self: RecordAudioMode) []const u8 {
        return switch (self) {
            .system => "󰓃",
            .mic => "󰍬",
            .none => "󰖁",
        };
    }
};

const recorders = [_][]const u8{
    "gpu-screen-recorder",
    "gpu-screen-reco",
    "wl-screenrec",
};

pub const stop_cmd = "pkill -INT -f gpu-screen-recorder 2>/dev/null; pkill -INT -x gpu-screen-reco 2>/dev/null; pkill -INT -x wl-screenrec 2>/dev/null || true";

var active_cached: bool = false;
var active_checked_s: i64 = 0;

pub fn isRecordingActive() bool {
    const now = c.time(null);
    if (active_checked_s != 0 and now == active_checked_s) return active_cached;
    active_cached = scanRecordingActive();
    active_checked_s = now;
    return active_cached;
}

fn scanRecordingActive() bool {
    const dir = c.opendir("/proc") orelse return false;
    defer _ = c.closedir(dir);

    while (c.readdir(dir)) |entry| {
        const pid = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        if (pid.len == 0 or !std.ascii.isDigit(pid[0])) continue;

        var path: [64]u8 = undefined;
        const file_path = std.fmt.bufPrintSentinel(&path, "/proc/{s}/comm", .{pid}, 0) catch continue;
        const file = c.fopen(file_path.ptr, "r") orelse continue;
        defer _ = c.fclose(file);

        var buf: [32]u8 = undefined;
        const n = c.fread(&buf, 1, buf.len, file);
        const name = std.mem.trim(u8, buf[0..n], " \t\r\n");

        for (recorders) |recorder| {
            if (std.mem.eql(u8, name, recorder) or (name.len >= 15 and std.mem.startsWith(u8, recorder, name))) return true;
        }
    }

    return false;
}

pub fn getRecordAudioMode() RecordAudioMode {
    var path_buf: [512]u8 = undefined;
    const home = c.getenv("HOME") orelse return .system;
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/.cache/mizu/record_audio_mode", .{std.mem.span(home)}, 0) catch return .system;

    const file = c.fopen(path.ptr, "r") orelse return .system;
    defer _ = c.fclose(file);

    var buf: [32]u8 = undefined;
    const n = c.fread(&buf, 1, buf.len, file);
    const content = std.mem.trim(u8, buf[0..n], " \t\r\n");

    if (std.mem.eql(u8, content, "mic")) return .mic;
    if (std.mem.eql(u8, content, "none")) return .none;
    return .system;
}

pub fn setRecordAudioMode(mode: RecordAudioMode) void {
    var path_buf: [512]u8 = undefined;
    const home = c.getenv("HOME") orelse return;
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/.cache/mizu/record_audio_mode", .{std.mem.span(home)}, 0) catch return;

    var dir_buf: [512]u8 = undefined;
    if (std.fmt.bufPrintSentinel(&dir_buf, "{s}/.cache/mizu", .{std.mem.span(home)}, 0)) |dir| {
        _ = c.mkdir(dir.ptr, 0o755);
    } else |_| {}

    const file = c.fopen(path.ptr, "w") orelse return;
    defer _ = c.fclose(file);

    const str: []const u8 = switch (mode) {
        .system => "system",
        .mic => "mic",
        .none => "none",
    };
    _ = c.fwrite(str.ptr, 1, str.len, file);
}

const base_region_cmd =
    "geom=$( (get_window 2>/dev/null || true) | slurp -f \"%wx%h+%x+%y\" 2>/dev/null) || exit; " ++
    "[ -n \"$geom\" ] || exit; " ++
    "mkdir -p \"$HOME/Videos/Recordings\"; " ++
    "file=\"$HOME/Videos/Recordings/Recording_$(date +%Y-%m-%d_%H-%M-%S).mp4\"; ";

const base_fullscreen_cmd =
    "mkdir -p \"$HOME/Videos/Recordings\"; " ++
    "file=\"$HOME/Videos/Recordings/Recording_$(date +%Y-%m-%d_%H-%M-%S).mp4\"; ";

const post_cmd =
    "[ -f \"$file\" ] && (notify-send -i video-x-generic \"󱁩 Recording Saved\" \"$file\" 2>/dev/null || mizu notify \"󱁩 Recording Saved\" \"$file\")";

const gsr_base = "gpu-screen-recorder -f 60 -fm cfr -fallback-cpu-encoding yes -c mp4 -ac aac";

pub const region_cmd_system = base_region_cmd ++ gsr_base ++ " -w \"$geom\" -a default_output -o \"$file\"; " ++ post_cmd;
pub const fullscreen_cmd_system = base_fullscreen_cmd ++ gsr_base ++ " -w screen -a default_output -o \"$file\"; " ++ post_cmd;

pub const region_cmd_mic = base_region_cmd ++ gsr_base ++ " -w \"$geom\" -a default_input -o \"$file\"; " ++ post_cmd;
pub const fullscreen_cmd_mic = base_fullscreen_cmd ++ gsr_base ++ " -w screen -a default_input -o \"$file\"; " ++ post_cmd;

pub const region_cmd_none = base_region_cmd ++ gsr_base ++ " -w \"$geom\" -o \"$file\"; " ++ post_cmd;
pub const fullscreen_cmd_none = base_fullscreen_cmd ++ gsr_base ++ " -w screen -o \"$file\"; " ++ post_cmd;

pub fn getRegionCommand(mode: RecordAudioMode) []const u8 {
    return switch (mode) {
        .system => region_cmd_system,
        .mic => region_cmd_mic,
        .none => region_cmd_none,
    };
}

pub fn getFullscreenCommand(mode: RecordAudioMode) []const u8 {
    return switch (mode) {
        .system => fullscreen_cmd_system,
        .mic => fullscreen_cmd_mic,
        .none => fullscreen_cmd_none,
    };
}

pub fn render(ctx: *types.BarContext, ui: *ui_mod.Ui) !void {
    const active = isRecordingActive();
    if (!active and ctx.cfg.recorder_hide_when_idle) return;

    const icon_size = ctx.iconFontSize();
    const icon_name = if (active) "record" else "screen-recording";
    const icon_color = if (active) theme.Color.rgb(255, 255, 255) else ctx.cfg.theme.accent;
    const bg_color = if (active) theme.Color.rgb(204, 36, 29) else ctx.cfg.theme.pill_bg;
    const id = "bar-recorder";
    const hovered = ui.hovered(id, 0);

    _ = ui.open(.{
        .id = id,
        .width = .{ .fixed = @as(f32, @floatFromInt(icon_size)) + ui.s(16) },
        .height = .{ .grow = .{} },
        .bg = if (hovered) ctx.cfg.theme.pill_hover else bg_color,
        .radius = ui.f(ctx.cfg.pill_radius),
        .border = if (hovered) ui.su(1) else 0,
        .border_color = if (hovered) ctx.cfg.theme.accent else null,
        .align_x = .center,
        .align_y = .center,
    });
    ui.icon(icon_name, icon_size, icon_color, 0);
    ui.close();

    const mode = getRecordAudioMode();
    const region_cmd = getRegionCommand(mode);
    const fullscreen_cmd = getFullscreenCommand(mode);
    try ctx.linkClick(ui, id, 0, .{
        .dual_command = .{
            .left = if (active) stop_cmd else region_cmd,
            .right = if (active) stop_cmd else fullscreen_cmd,
        },
    }, null);
}
