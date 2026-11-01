const sys_status = @import("../../services/system_status.zig");
const recorder = @import("../../bar/recorder.zig");
const ui_mod = @import("../../core/ui.zig");
const types = @import("types.zig");

const Action = types.Action;

pub const State = struct {
    audio_mode: recorder.RecordAudioMode = .system,

    pub fn init() State {
        return .{ .audio_mode = recorder.getRecordAudioMode() };
    }
};

pub fn isRecordingActive() bool {
    return recorder.isRecordingActive();
}

pub fn refresh(panel: anytype) void {
    panel.recording.audio_mode = recorder.getRecordAudioMode();
}

pub fn handleAction(panel: anytype, action: Action) bool {
    switch (action) {
        .open_recording_menu => {
            panel.view_mode = .recording_menu;
            panel.scroll_offset = 0;
            return true;
        },
        .toggle_recording => {
            if (recorder.isRecordingActive()) {
                sys_status.spawnCmd(recorder.stop_cmd);
            } else {
                const cmd = recorder.getRegionCommand(panel.recording.audio_mode);
                sys_status.spawnCmd(cmd);
            }
            return true;
        },
        .set_recording_mode_system => {
            panel.recording.audio_mode = .system;
            recorder.setRecordAudioMode(.system);
            return true;
        },
        .set_recording_mode_mic => {
            panel.recording.audio_mode = .mic;
            recorder.setRecordAudioMode(.mic);
            return true;
        },
        .set_recording_mode_none => {
            panel.recording.audio_mode = .none;
            recorder.setRecordAudioMode(.none);
            return true;
        },
        .start_record_region => {
            const cmd = recorder.getRegionCommand(panel.recording.audio_mode);
            sys_status.spawnCmd(cmd);
            return true;
        },
        .start_record_fullscreen => {
            const cmd = recorder.getFullscreenCommand(panel.recording.audio_mode);
            sys_status.spawnCmd(cmd);
            return true;
        },
        else => return false,
    }
}

pub fn renderMainCard(panel: anytype, ui: *ui_mod.Ui, scale: u32, icon_sz: u32, ui_sz: u32, sec_sz: u32) !void {
    const is_recording = recorder.isRecordingActive();
    const rec_sub = if (is_recording) "Recording" else "Not recording";
    const rec_icon = if (is_recording) "record" else "record";
    try panel.renderExpandableCard(ui, 2, rec_icon, rec_icon, "Screen Recording", rec_sub, is_recording, icon_sz, ui_sz, sec_sz, scale);
}

pub fn renderMenu(panel: anytype, ui: *ui_mod.Ui, scale: u32, sub_sz: u32, btn_sz: u32) void {
    const active_rec = recorder.isRecordingActive();
    const options = [_]struct {
        mode: recorder.RecordAudioMode,
        icon_name: []const u8,
        title: []const u8,
        description: []const u8,
        action: Action,
    }{
        .{ .mode = .system, .icon_name = "volume", .title = "System sounds (default)", .description = "Record desktop and application sounds", .action = .set_recording_mode_system },
        .{ .mode = .mic, .icon_name = "microphone", .title = "Microphone", .description = "Record voice from the default microphone", .action = .set_recording_mode_mic },
        .{ .mode = .none, .icon_name = "volume-muted", .title = "No audio", .description = "Record video without audio", .action = .set_recording_mode_none },
    };
    for (options, 0..) |opt, idx| {
        const selected = (panel.recording.audio_mode == opt.mode);
        const hov = ui.hovered("qs-rec-mode", @intCast(idx));
        _ = ui.open(.{
            .id = "qs-rec-mode",
            .index = @intCast(idx),
            .width = .{ .grow = .{} },
            .height = .{ .fixed = ui.s(48) },
            .direction = .row,
            .padding = .{ .left = ui.su(10), .right = ui.su(10) },
            .gap = ui.su(10),
            .bg = if (selected) panel.cfg.theme.elevated else if (hov) panel.cfg.theme.btn_raised_hover else panel.cfg.theme.surface,
            .radius = ui.f(panel.cfg.theme.radius_button),
            .border = ui.su(1),
            .border_color = if (selected) panel.cfg.theme.accent else panel.cfg.theme.border,
            .align_y = .center,
        });
        _ = ui.open(.{
            .width = .{ .fixed = ui.s(24) },
            .height = .{ .fixed = ui.s(24) },
            .bg = if (selected) panel.cfg.theme.toggle_on else panel.cfg.theme.btn_raised_bg,
            .radius = ui.f(12),
            .align_x = .center,
            .align_y = .center,
        });
        ui.icon(opt.icon_name, 16 * scale, if (selected) panel.cfg.theme.accent_fg else panel.cfg.theme.text_bright, 0);
        ui.close();
        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
            .padding = .{ .left = ui.su(8) },
            .align_y = .center,
            .clip_horizontal = true,
        });
        ui.text(opt.title, .{ .size = sub_sz, .color = panel.cfg.theme.text_bright });
        ui.close();
        if (selected) ui.icon("check", 16 * scale, panel.cfg.theme.accent, 0);
        ui.close();
    }

    ui.spacerSized(.{ .fixed = 0 }, .{ .fixed = ui.s(10) });

    if (active_rec) {
        const hov = ui.hovered("qs-rec-stop", 0);
        _ = ui.open(.{
            .id = "qs-rec-stop",
            .width = .{ .grow = .{} },
            .height = .{ .fixed = ui.s(40) },
            .bg = if (hov) panel.cfg.theme.error_color else panel.cfg.theme.btn_raised_bg,
            .radius = ui.f(10),
            .border = ui.su(1),
            .border_color = if (hov) panel.cfg.theme.error_color else panel.cfg.theme.border,
            .align_x = .center,
            .align_y = .center,
        });
        ui.text("Stop Recording", .{ .size = btn_sz, .color = if (hov) @import("../../core/theme.zig").Color.rgb(255, 255, 255) else panel.cfg.theme.error_color });
        ui.close();
    } else {
        _ = ui.open(.{
            .width = .{ .grow = .{} },
            .height = .{ .fixed = ui.s(40) },
            .direction = .row,
            .gap = ui.su(12),
        });
        const region_hov = ui.hovered("qs-rec-region", 0);
        _ = ui.open(.{
            .id = "qs-rec-region",
            .width = .{ .percent = 0.5 },
            .height = .{ .grow = .{} },
            .bg = if (region_hov) panel.cfg.theme.btn_raised_hover else panel.cfg.theme.surface,
            .radius = ui.f(10),
            .padding = .{ .left = ui.su(10), .right = ui.su(6) },
            .gap = ui.su(8),
            .align_y = .center,
        });
        ui.icon("screenshot-region", 16 * scale, panel.cfg.theme.text_main, 0);
        ui.text("Record Region", .{ .size = 13 * scale, .color = panel.cfg.theme.text_main });
        ui.close();

        const full_hov = ui.hovered("qs-rec-full", 0);
        _ = ui.open(.{
            .id = "qs-rec-full",
            .width = .{ .percent = 0.5 },
            .height = .{ .grow = .{} },
            .bg = if (full_hov) panel.cfg.theme.btn_raised_hover else panel.cfg.theme.surface,
            .radius = ui.f(10),
            .padding = .{ .left = ui.su(10), .right = ui.su(6) },
            .gap = ui.su(8),
            .align_y = .center,
        });
        ui.icon("monitor", 16 * scale, panel.cfg.theme.text_main, 0);
        ui.text("Record Screen", .{ .size = 13 * scale, .color = panel.cfg.theme.text_main });
        ui.close();
        ui.close();
    }
}

pub fn appendHitAreas(panel: anytype, ui: *ui_mod.Ui, scale: u32) !void {
    if (ui.rectOf("qs-rec-mode", 0)) |rect| try types.appendHitArea(panel, rect, scale, .set_recording_mode_system);
    if (ui.rectOf("qs-rec-mode", 1)) |rect| try types.appendHitArea(panel, rect, scale, .set_recording_mode_mic);
    if (ui.rectOf("qs-rec-mode", 2)) |rect| try types.appendHitArea(panel, rect, scale, .set_recording_mode_none);
    if (ui.rectOf("qs-rec-stop", 0)) |rect| try types.appendHitArea(panel, rect, scale, .toggle_recording);
    if (ui.rectOf("qs-rec-region", 0)) |rect| try types.appendHitArea(panel, rect, scale, .start_record_region);
    if (ui.rectOf("qs-rec-full", 0)) |rect| try types.appendHitArea(panel, rect, scale, .start_record_fullscreen);
}
