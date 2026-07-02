const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("theme.zig");
const md = @import("parser/markdown.zig");
const frontmatter = @import("parser/frontmatter.zig");
const state_store = @import("engine/state_store.zig");
const prerequisites = @import("engine/prerequisites.zig");
const lifecycle = @import("engine/lifecycle.zig");
const DocumentView = @import("components/document_view.zig").DocumentView;
const StatusBar = @import("components/status_bar.zig").StatusBar;
const HelpPanel = @import("components/help_panel.zig").HelpPanel;
const status_bar = @import("components/status_bar.zig");

const Allocator = std.mem.Allocator;

/// App must be heap-allocated to maintain stable pointer invariants.
/// Use App.create() / App.destroy().
pub const App = struct {
    allocator: Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    file_path: []const u8,
    vxfw_app: ?*vxfw.App,
    verbose: bool,

    // Owned document state (reset on reload)
    doc_arena: std.heap.ArenaAllocator,
    document: ?md.Document,
    fm: ?frontmatter.Frontmatter,
    setup_error: ?[]const u8,
    initial_load_done: bool,

    // Process exit code, set when setup/teardown exits non-zero. Propagated
    // as mdjam's own exit code once the process quits normally.
    exit_code: u8,
    // Setup/teardown stdout+stderr, buffered here because they run while the
    // TUI owns the terminal (setup) or must be flushed to the real terminal
    // after it's torn down (teardown) — printed once in destroy().
    post_run_stdout: std.ArrayList(u8),
    post_run_stderr: std.ArrayList(u8),

    // State store (long-lived, survives reloads)
    store: state_store.StateStore,

    // Components (reference self.store, so App must not be moved)
    doc_view: DocumentView,
    status_bar_widget: StatusBar,
    help_panel: HelpPanel,

    // UI state
    show_help: bool,
    terminal_width: u16,
    terminal_height: u16,

    pub const Options = struct {
        stdin_mode: bool = false,
        no_auto: bool = false,
        no_watch: bool = false,
        verbose: bool = false,
    };

    /// Allocate and initialize App on the heap. Caller calls destroy() when done.
    pub fn create(
        allocator: Allocator,
        io: std.Io,
        environ_map: *const std.process.Environ.Map,
        file_path: []const u8,
        opts: Options,
    ) Allocator.Error!*App {
        const self = try allocator.create(App);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.io = io;
        self.environ_map = environ_map;
        self.file_path = file_path;
        self.vxfw_app = null;
        self.verbose = opts.verbose;
        self.doc_arena = std.heap.ArenaAllocator.init(allocator);
        self.document = null;
        self.fm = null;
        self.setup_error = null;
        self.initial_load_done = false;
        self.exit_code = 0;
        self.post_run_stdout = std.ArrayList(u8).empty;
        self.post_run_stderr = std.ArrayList(u8).empty;
        self.store = state_store.StateStore.init(allocator);
        self.doc_view = DocumentView.init(allocator, &self.store, environ_map, io, opts.verbose);
        self.status_bar_widget = StatusBar.init();
        self.help_panel = .{ .visible = false };
        self.show_help = false;
        self.terminal_width = 80;
        self.terminal_height = 24;

        return self;
    }

    /// Set the vxfw.App reference for suspend/resume support.
    /// Must be called before loadFile() for interactive blocks to work.
    pub fn setVxfwApp(self: *App, vxfw_app_ptr: *vxfw.App) void {
        self.vxfw_app = vxfw_app_ptr;
        // Wire up suspend/resume callbacks on doc_view
        self.doc_view.suspend_fn = suspendTuiCallback;
        self.doc_view.resume_fn = resumeTuiCallback;
        self.doc_view.suspend_ctx = self;
    }

    fn suspendTuiCallback(ctx: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        if (self.vxfw_app) |vxfw_a| {
            vxfw_a.vx.exitAltScreen(vxfw_a.tty.writer()) catch {};
            vxfw_a.tty.writer().flush() catch {};
        }
    }

    fn resumeTuiCallback(ctx: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        if (self.vxfw_app) |vxfw_a| {
            vxfw_a.vx.enterAltScreen(vxfw_a.tty.writer()) catch {};
            vxfw_a.tty.writer().flush() catch {};
        }
    }

    /// Tear down the app. Runs the teardown script (if declared), flushes any
    /// buffered setup/teardown output to the real terminal (the caller must
    /// ensure the TUI has already released the terminal by this point), and
    /// returns the process exit code that should be propagated (0 if setup
    /// and teardown both succeeded or weren't declared).
    pub fn destroy(self: *App) u8 {
        self.runTeardown();
        self.flushPostRunOutput();
        const code = self.exit_code;

        self.doc_view.deinit();
        if (self.document) |*doc| doc.deinit();
        if (self.fm) |*fm| fm.deinit(self.allocator);
        if (self.setup_error) |msg| self.allocator.free(msg);
        self.post_run_stdout.deinit(self.allocator);
        self.post_run_stderr.deinit(self.allocator);
        self.doc_arena.deinit();
        self.store.deinit();
        self.allocator.destroy(self);
        return code;
    }

    /// Run the document's teardown script (if declared), on normal quit.
    fn runTeardown(self: *App) void {
        const fm = self.fm orelse return;
        const script = fm.teardown orelse return;
        // Nothing was ever set up (e.g. we aborted on a failed prerequisite
        // before the document ever loaded) — there's nothing to tear down.
        if (self.document == null) return;
        var result = lifecycle.runTeardown(self.allocator, self.io, script, &self.store, self.environ_map) catch |err| {
            std.log.warn("Teardown script failed to run: {}", .{err});
            self.exit_code = 1;
            return;
        };
        defer result.deinit(self.allocator);
        self.recordScriptOutput("teardown", result);
        if (result.exit_code != 0) self.exit_code = result.exit_code;
    }

    /// Buffer a lifecycle script's output for later display: stdout only when
    /// verbose (it's not error output, just informational), stderr always.
    fn recordScriptOutput(self: *App, label: []const u8, result: lifecycle.RunResult) void {
        if (self.verbose and result.stdout.len > 0) {
            appendLabeled(self.allocator, &self.post_run_stdout, label, "stdout", result.stdout);
        }
        if (result.stderr.len > 0) {
            appendLabeled(self.allocator, &self.post_run_stderr, label, "stderr", result.stderr);
        }
    }

    /// Print buffered setup/teardown output to the real terminal. Must only
    /// be called after the TUI has released the terminal (alt-screen exited).
    fn flushPostRunOutput(self: *App) void {
        if (self.post_run_stdout.items.len > 0) {
            std.Io.File.writeStreamingAll(std.Io.File.stdout(), self.io, self.post_run_stdout.items) catch {};
        }
        if (self.post_run_stderr.items.len > 0) {
            std.Io.File.writeStreamingAll(std.Io.File.stderr(), self.io, self.post_run_stderr.items) catch {};
        }
    }

    /// Outcome of an initial (fail-fast) load, used by main() to decide
    /// whether it's safe to start the TUI.
    pub const LoadOutcome = union(enum) {
        ok,
        /// Owned by the caller; must be freed with `allocator.free`.
        prereq_failed: []const u8,
    };

    /// Load (or reload) the markdown file. Resets document state.
    ///
    /// `fail_fast_prereqs`: when true (the initial load, before the TUI has
    /// started), a failed prerequisite check aborts the load entirely and
    /// returns `.prereq_failed` instead of blocking fences, so the caller can
    /// print the reason and exit without ever starting the TUI. When false
    /// (reload via `r`), prerequisite failures keep the existing softer
    /// behavior of blocking fences so the rest of the document stays usable.
    pub fn loadFile(self: *App, fail_fast_prereqs: bool) !LoadOutcome {
        // Reset document state
        if (self.document) |*doc| {
            doc.deinit();
            self.document = null;
        }
        _ = self.doc_arena.reset(.free_all);
        if (self.fm) |*fm| {
            fm.deinit(self.allocator);
            self.fm = null;
        }
        if (self.setup_error) |msg| {
            self.allocator.free(msg);
            self.setup_error = null;
        }
        self.doc_view.frontmatter = null;
        self.doc_view.setup_error = null;

        // Read file using std.Io.Dir.cwd()
        const source = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            self.file_path,
            self.allocator,
            std.Io.Limit.limited(10 * 1024 * 1024),
        ) catch |err| {
            std.log.err("Failed to read '{s}': {}", .{ self.file_path, err });
            return .ok;
        };
        defer self.allocator.free(source);

        // Parse frontmatter
        const fm_result = try frontmatter.parse(self.allocator, source);
        self.fm = fm_result.frontmatter;
        const body = fm_result.body;

        // Apply frontmatter defaults to state store
        if (self.fm) |fm| {
            var it = fm.defaults.iterator();
            while (it.next()) |kv| {
                self.store.set(kv.key_ptr.*, kv.value_ptr.*, null) catch {};
            }
        }

        // Check prerequisites
        var prereq_failed = false;
        if (self.fm) |fm| {
            const failed = prerequisites.check(
                self.allocator,
                self.io,
                fm.prerequisites.tools,
                fm.prerequisites.env,
                self.environ_map,
            ) catch &.{};
            if (failed.len > 0) {
                if (fail_fast_prereqs) {
                    const msg = prerequisites.formatFailures(self.allocator, self.file_path, failed) catch
                        try self.allocator.dupe(u8, "mdjam: prerequisites not met\n");
                    prerequisites.freeChecks(self.allocator, failed);
                    return .{ .prereq_failed = msg };
                }
                prereq_failed = true;
                // Block all fences when prerequisites fail
                for (self.doc_view.code_fences.items) |*cf| {
                    cf.status = .blocked;
                }
            }
            prerequisites.freeChecks(self.allocator, failed);
        }

        // Run setup script if present
        if (!prereq_failed) {
            if (self.fm) |fm| {
                if (fm.setup) |setup_script| {
                    var result = lifecycle.runSetup(
                        self.allocator,
                        self.io,
                        setup_script,
                        &self.store,
                        self.environ_map,
                    ) catch |err| blk: {
                        std.log.warn("Setup script failed to run: {}", .{err});
                        self.exit_code = 1;
                        break :blk null;
                    };
                    if (result) |*r| {
                        defer r.deinit(self.allocator);
                        self.recordScriptOutput("setup", r.*);
                        if (r.exit_code != 0) {
                            self.exit_code = r.exit_code;
                            const stderr_trimmed = std.mem.trim(u8, r.stderr, " \t\r\n");
                            self.setup_error = std.fmt.allocPrint(
                                self.allocator,
                                "Setup script failed (exit code {d}){s}{s}",
                                .{
                                    r.exit_code,
                                    if (stderr_trimmed.len > 0) ":\n" else "",
                                    stderr_trimmed,
                                },
                            ) catch null;
                            self.doc_view.setup_error = self.setup_error;
                        }
                    }
                }
            }
        }

        // Parse markdown into arena allocator
        const arena = self.doc_arena.allocator();
        self.document = try md.parse(arena, body);

        // Set document on view (creates code fence widgets)
        if (self.document) |*doc| {
            try self.doc_view.setDocument(doc);
        }
        self.doc_view.frontmatter = if (self.fm) |*fm| fm else null;

        // Auto-execute blocks with auto:true. Waits for the whole chain since
        // this runs before the TUI's first draw (see executeWithDeps docs).
        self.doc_view.checkAutoReruns(true);

        return .ok;
    }

    pub fn widget(self: *App) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *App = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *App = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn syncStatusBar(self: *App) void {
        const focused = if (self.doc_view.focused_block) |fb|
            &self.doc_view.code_fences.items[fb]
        else
            null;
        self.status_bar_widget.setFocusedFence(focused);
        self.status_bar_widget.boundary_hint = self.doc_view.boundary_hint;
    }

    fn anyFenceRunning(self: *App) bool {
        for (self.doc_view.code_fences.items) |*cf| {
            if (cf.status == .running) return true;
        }
        return false;
    }

    fn anyFenceNeedsRedraw(self: *App) bool {
        for (self.doc_view.code_fences.items) |*cf| {
            if (cf.needs_redraw) {
                cf.needs_redraw = false;
                return true;
            }
        }
        return false;
    }

    pub fn handleEvent(self: *App, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .tick => {
                self.status_bar_widget.update();
                // Reruns any `auto` block whose depends/inputs changed since
                // its last run — never blocks (wait_for_target: false), so
                // this is safe to poll from the live event loop.
                self.doc_view.checkAutoReruns(false);
                if (self.anyFenceNeedsRedraw()) ctx.redraw = true;
                if (self.anyFenceRunning()) {
                    try ctx.tick(80, self.widget());
                    ctx.redraw = true;
                }
            },
            .init => {
                // Normally the initial (fail-fast) load already happened in
                // main() before the TUI started; this is a fallback for
                // standalone use of App without that preflight check.
                if (!self.initial_load_done) {
                    _ = try self.loadFile(false);
                    self.initial_load_done = true;
                }
                self.syncStatusBar();
                if (self.anyFenceRunning()) {
                    try ctx.tick(80, self.widget());
                }
                ctx.redraw = true;
            },
            .winsize => |ws| {
                self.terminal_width = ws.cols;
                self.terminal_height = ws.rows;
                // Forward to document view for layout recalculation
                try self.doc_view.handleEvent(ctx, event);
                ctx.redraw = true;
            },
            .key_press => |key| {
                // While the help overlay is visible, navigation keys scroll it,
                // Esc closes it, and all other keys are ignored.
                if (self.show_help) {
                    if (key.matches(vaxis.Key.escape, .{})) {
                        self.show_help = false;
                        self.help_panel.visible = false;
                    } else if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
                        self.help_panel.scrollDown(1);
                    } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
                        self.help_panel.scrollUp(1);
                    } else if (key.matches(' ', .{}) or key.matches(vaxis.Key.page_down, .{})) {
                        self.help_panel.scrollDown(10);
                    } else if (key.matches('b', .{}) or key.matches(vaxis.Key.page_up, .{})) {
                        self.help_panel.scrollUp(10);
                    } else if (key.matches('g', .{}) or key.matches(vaxis.Key.home, .{})) {
                        self.help_panel.scrollToTop();
                    } else if (key.matches('G', .{}) or key.matches(vaxis.Key.end, .{})) {
                        self.help_panel.scrollToBottom();
                    }
                    ctx.redraw = true;
                    return;
                }

                // While editing an input field, it owns the keyboard entirely —
                // bypass global keys (reload, help, copy, quit) and navigation.
                if (self.doc_view.isEditingInput()) {
                    try self.doc_view.handleEvent(ctx, event);
                    self.syncStatusBar();
                    // Committing an input can change an `auto` block's
                    // parameter signature; catch up right away.
                    self.doc_view.checkAutoReruns(false);
                    if (self.anyFenceRunning()) {
                        try ctx.tick(80, self.widget());
                    }
                    return;
                }

                // Global keys
                if (key.matches('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                    return;
                }
                if (key.matches('r', .{})) {
                    _ = try self.loadFile(false);
                    self.syncStatusBar();
                    ctx.redraw = true;
                    return;
                }
                if (key.matches('?', .{})) {
                    self.show_help = !self.show_help;
                    self.help_panel.visible = self.show_help;
                    if (self.show_help) self.help_panel.scrollToTop();
                    ctx.redraw = true;
                    return;
                }
                if (key.matches('y', .{})) {
                    if (self.doc_view.focused_block) |fb| {
                        const fence = &self.doc_view.code_fences.items[fb];
                        if (self.vxfw_app) |vxfw_a| {
                            try vxfw_a.vx.copyToSystemClipboard(vxfw_a.tty.writer(), fence.block.body, self.allocator);
                        }
                    }
                    return;
                }

                // Forward navigation and execution keys to document view
                try self.doc_view.handleEvent(ctx, event);
                self.syncStatusBar();
                // A block may have just finished (e.g. a dependency an `auto`
                // block watches) or started; catch up before deciding whether
                // to keep polling.
                self.doc_view.checkAutoReruns(false);
                // If a block started running, start the polling tick
                if (self.anyFenceRunning()) {
                    try ctx.tick(80, self.widget());
                }
            },
            .app => |ev| {
                try self.doc_view.handleEvent(ctx, .{ .app = ev });
                _ = self.anyFenceNeedsRedraw();
                ctx.redraw = true;
                self.doc_view.checkAutoReruns(false);
                // Keep polling if blocks are still running
                if (self.anyFenceRunning()) {
                    try ctx.tick(80, self.widget());
                }
            },
            else => {
                try self.doc_view.handleEvent(ctx, event);
                self.syncStatusBar();
            },
        }
    }

    pub fn draw(self: *App, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const width = ctx.max.width orelse self.terminal_width;
        const height = ctx.max.height orelse self.terminal_height;
        const size: vxfw.Size = .{ .width = width, .height = height };

        var children = std.ArrayList(vxfw.SubSurface).empty;

        // Reserve 1 row for status bar
        const doc_height: u16 = if (height > 1) height - 1 else height;
        const doc_width: u16 = width;

        // Document view (main content)
        {
            const doc_ctx = ctx.withConstraints(
                .{ .width = doc_width, .height = doc_height },
                .{ .width = doc_width, .height = doc_height },
            );
            const doc_surf = try self.doc_view.draw(doc_ctx);
            try children.append(ctx.arena, .{
                .origin = .{ .row = 0, .col = 0 },
                .surface = doc_surf,
                .z_index = 0,
            });
        }

        // Status bar (bottom row)
        {
            const sb_ctx = ctx.withConstraints(
                .{ .width = width, .height = 1 },
                .{ .width = width, .height = 1 },
            );
            const sb_surf = try self.status_bar_widget.draw(sb_ctx);
            try children.append(ctx.arena, .{
                .origin = .{ .row = @intCast(doc_height), .col = 0 },
                .surface = sb_surf,
                .z_index = 0,
            });
        }

        // Help overlay (centered, on top)
        if (self.show_help) {
            const help_w: u16 = @min(50, width);
            const help_h: u16 = @min(30, height);
            const help_ctx = ctx.withConstraints(
                .{ .width = help_w, .height = 0 },
                .{ .width = help_w, .height = help_h },
            );
            const help_surf = try self.help_panel.draw(help_ctx);
            const help_col: i17 = @intCast((width -| help_surf.size.width) / 2);
            const help_row: i17 = @intCast((height -| help_surf.size.height) / 2);
            try children.append(ctx.arena, .{
                .origin = .{ .row = help_row, .col = help_col },
                .surface = help_surf,
                .z_index = 10,
            });
        }

        // Root surface buffer (default background)
        const root_buffer = try vxfw.Surface.createBuffer(ctx.arena, size);
        @memset(root_buffer, .{ .default = true });

        return .{
            .size = size,
            .widget = self.widget(),
            .buffer = root_buffer,
            .children = children.items,
        };
    }
};

/// Append a labeled block of script output (e.g. "== setup stdout ==") to a
/// buffer. Errors are swallowed — this is best-effort diagnostic output.
fn appendLabeled(allocator: Allocator, buf: *std.ArrayList(u8), script: []const u8, stream: []const u8, data: []const u8) void {
    const header = std.fmt.allocPrint(allocator, "== {s} {s} ==\n", .{ script, stream }) catch return;
    defer allocator.free(header);
    buf.appendSlice(allocator, header) catch return;
    buf.appendSlice(allocator, data) catch return;
    if (data.len == 0 or data[data.len - 1] != '\n') {
        buf.append(allocator, '\n') catch {};
    }
}
