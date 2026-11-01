const std = @import("std");
const ui_mod = @import("../core/ui.zig");
const parser = @import("../core/dsl/parser.zig");
const validator = @import("../core/dsl/validator.zig");
const theme_resolver = @import("../core/dsl/theme_resolver.zig");
const registry = @import("../core/dsl/registry.zig");
const state_mod = @import("../core/dsl/state.zig");
const theme = @import("../core/theme.zig");
const renderer = @import("../core/renderer.zig");

pub const DslPanel = struct {
    allocator: std.mem.Allocator,
    state: state_mod.State,
    has_errors: bool,

    pub fn deinit(self: *DslPanel) void {
        self.state.deinit(self.allocator);
    }

    pub fn init(alloc: std.mem.Allocator) !DslPanel {
        return .{
            .allocator = alloc,
            .state = state_mod.State.init(alloc),
            .has_errors = false,
        };
    }

    pub fn loadAndRender(self: *DslPanel, file_path: []const u8, target: renderer.Renderer, font: *ui_mod.Font, scale: u32) void {
        const src = std.fs.cwd().readFileAlloc(self.allocator, file_path, 4096) catch {
            std.debug.print("dsl_panel: failed to load {s}\n", .{file_path});
            self.has_errors = true;
            return;
        };
        defer self.allocator.free(src);

        var p = parser.Parser.init(self.allocator, src);
        const root = p.parseElement();
        var errors = std.ArrayList(validator.ValidationError).empty;
        errors.allocator = self.allocator;
        defer errors.deinit();
        validator.validate(file_path, root, &errors);
        if (errors.items.len > 0) {
            self.has_errors = true;
            std.debug.print("dsl_panel: syntax errors in {s}\n", .{file_path});
        }

        // Compile DSL using compiler (milestone structural)
        const compiler_mod = @import("../core/dsl/compiler.zig");
        var compiler_inst = compiler_mod.Compiler.init(self.allocator);
        defer compiler_inst.deinit();
        const compiled_frame = compiler_inst.compile(root);

        // Theme resolution (verified structurally)
        var resolver = theme_resolver.ThemeResolver.init(self.allocator, "nord");
        _ = resolver.resolve("theme.accent");

        // Phase 7C — DSL QuickSettings routing preserved; default false; handwritten quicksettings.zig untouched

        // Event registry (structural registration)
        var reg = registry.Registry.init(self.allocator);
        reg.register("demo_click");

        if (reg.trigger("demo_click")) {
            self.state.updateLabel(self.allocator, "Hello (updated!)");
            self.state.requestRebuild();
        }
        reg.clearTriggered();

        // Render compiled DSL frame into target
        const cmds = compiled_frame.endLayout();
        compiled_frame.render(target, cmds);
        std.debug.print("dsl_panel: rendered {s}\n", .{file_path});
        compiled_frame.deinit();
    }
};
