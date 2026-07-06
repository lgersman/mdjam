const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const md = @import("../parser/markdown.zig");
const fence_meta = @import("../parser/fence_meta.zig");
const block_runner = @import("../engine/block_runner.zig");
const state_store = @import("../engine/state_store.zig");
const highlighter = @import("highlighter.zig");

const Allocator = std.mem.Allocator;

const MAX_OUTPUT_LINES = 500;

pub const CodeFenceWidget = struct {
    allocator: Allocator,
    block: *const md.CodeFence,
    store: *state_store.StateStore,
    environ_map: *const std.process.Environ.Map,
    io: std.Io,

    // State
    focused: bool,
    status: block_runner.RunStatus,
    // True when the current/last run was triggered by document-load auto
    // execution rather than a manual Enter press; the status bar hides the
    // "done" badge in that case since the user never asked to see the result.
    ran_automatically: bool,
    // Bumped every time this block finishes a run (any outcome). Lets an
    // `auto` block that `depends` on this one detect "it ran again" without
    // needing to know which state-store keys it wrote.
    run_count: u32,
    // Signature (see DocumentView.autoSignature) this fence was last run
    // with, if it's an `auto` block; null before its first run.
    last_auto_signature: ?u64,
    output_lines: std.ArrayList(OutputLine),
    output_scroll: usize,
    runner: block_runner.Runner,
    runner_thread: ?std.Thread,

    verbose: bool,

    // Redraw notification (set by callback, polled by app)
    needs_redraw: bool,

    // Optional suspend/resume callbacks for interactive blocks
    suspend_fn: ?block_runner.SuspendFn,
    resume_fn: ?block_runner.ResumeFn,
    suspend_ctx: ?*anyopaque,

    // Editable inputs: name of the input currently being edited (points into
    // block.metadata's owned key strings), the text field backing that edit, and
    // locally-entered values not yet committed to the shared state store.
    editing_input: ?[]const u8,
    input_field: vxfw.TextField,
    input_values: std.StringHashMap([]u8),
    // Heap-owned (not ctx.arena!) rendered text per input row, keyed by input name.
    // vaxis's diff keeps a *reference* to the previous frame's cell content rather
    // than copying it; ctx.arena resets to the same base address every frame, so a
    // per-frame arena string here would alias its own prior frame's (now-stale)
    // memory and fool the diff into never re-emitting the row. Caching on the heap
    // and only replacing the pointer when the text actually changes avoids that.
    input_line_cache: std.StringHashMap([]u8),
    // Same reasoning, for the single input actively being edited (label + live text).
    editing_label_cache: ?[]u8,
    editing_field_cache: ?[]u8,

    pub const OutputLine = struct {
        text: []const u8,
        is_stderr: bool,
    };

    pub fn init(
        allocator: Allocator,
        block: *const md.CodeFence,
        store: *state_store.StateStore,
        environ_map: *const std.process.Environ.Map,
        io: std.Io,
        verbose: bool,
    ) Allocator.Error!CodeFenceWidget {
        return .{
            .allocator = allocator,
            .block = block,
            .store = store,
            .environ_map = environ_map,
            .io = io,
            .verbose = verbose,
            .focused = false,
            .status = .idle,
            .ran_automatically = false,
            .run_count = 0,
            .last_auto_signature = null,
            .output_lines = std.ArrayList(OutputLine).empty,
            .output_scroll = 0,
            .runner = block_runner.Runner.init(),
            .runner_thread = null,
            .needs_redraw = false,
            .suspend_fn = null,
            .resume_fn = null,
            .suspend_ctx = null,
            .editing_input = null,
            .input_field = vxfw.TextField.init(allocator),
            .input_values = std.StringHashMap([]u8).init(allocator),
            .input_line_cache = std.StringHashMap([]u8).init(allocator),
            .editing_label_cache = null,
            .editing_field_cache = null,
        };
    }

    pub fn deinit(self: *CodeFenceWidget) void {
        if (self.runner_thread) |t| t.detach();
        for (self.output_lines.items) |line| self.allocator.free(line.text);
        self.output_lines.deinit(self.allocator);
        var val_it = self.input_values.valueIterator();
        while (val_it.next()) |v| self.allocator.free(v.*);
        self.input_values.deinit();
        var cache_it = self.input_line_cache.valueIterator();
        while (cache_it.next()) |v| self.allocator.free(v.*);
        self.input_line_cache.deinit();
        if (self.editing_label_cache) |v| self.allocator.free(v);
        if (self.editing_field_cache) |v| self.allocator.free(v);
        self.input_field.deinit();
    }

    /// Render (and cache) a string for a code-fence cell that vaxis's frame-to-frame
    /// diffing will see. Must NOT be backed by ctx.arena (see input_line_cache doc).
    fn cachedLine(self: *CodeFenceWidget, key: []const u8, comptime fmt: []const u8, args: anytype) []const u8 {
        const fresh = std.fmt.allocPrint(self.allocator, fmt, args) catch return key;
        if (self.input_line_cache.fetchRemove(key)) |kv| self.allocator.free(kv.value);
        self.input_line_cache.put(key, fresh) catch {};
        return fresh;
    }

    pub fn widget(self: *CodeFenceWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *CodeFenceWidget = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *CodeFenceWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn handleEvent(self: *CodeFenceWidget, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .focus_in => {
                self.focused = true;
                ctx.redraw = true;
            },
            .focus_out => {
                self.focused = false;
                ctx.redraw = true;
            },
            .key_press => |key| {
                if (self.editing_input != null) {
                    try self.handleInputEditKey(ctx, key);
                    return;
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    if (self.status != .running) {
                        try self.startExecution(false);
                    }
                    ctx.consumeAndRedraw();
                } else if (key.matches(vaxis.Key.escape, .{})) {
                    self.runner.cancel();
                    ctx.consumeAndRedraw();
                } else if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
                    if (self.output_lines.items.len > 0) {
                        const max_scroll = self.output_lines.items.len -| 1;
                        if (self.output_scroll < max_scroll) self.output_scroll += 1;
                    }
                    ctx.consumeAndRedraw();
                } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
                    if (self.output_scroll > 0) self.output_scroll -= 1;
                    ctx.consumeAndRedraw();
                } else if (key.matches('g', .{})) {
                    self.output_scroll = 0;
                    ctx.consumeAndRedraw();
                } else if (key.matches('G', .{})) {
                    if (self.output_lines.items.len > 0) {
                        self.output_scroll = self.output_lines.items.len - 1;
                    }
                    ctx.consumeAndRedraw();
                } else if (key.matches('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                }
            },
            .app => |ev| {
                if (std.mem.eql(u8, ev.name, "fence_output")) {
                    // Redraw notification from runner thread
                    self.needs_redraw = false;
                    ctx.redraw = true;
                }
            },
            else => {},
        }
    }

    fn handleInputEditKey(self: *CodeFenceWidget, ctx: *vxfw.EventContext, key: vaxis.Key) anyerror!void {
        if (self.editing_input == null) return;
        if (key.matches(vaxis.Key.escape, .{})) {
            self.editing_input = null;
            self.input_field.clearAndFree();
            ctx.consumeAndRedraw();
            return;
        }
        // Tab/Shift-Tab/Enter are intercepted by DocumentView before reaching
        // here (they drive cross-block param navigation and execution); any
        // other key is raw text input for the field.
        try self.input_field.handleEvent(ctx, .{ .key_press = key });
    }

    /// Populates `buf` with this fence's input names in sorted (display) order
    /// and returns the count. Shared by draw() and the param-navigation helpers
    /// below so both agree on ordering.
    fn sortedInputNames(self: *const CodeFenceWidget, buf: *[16][]const u8) usize {
        const meta = self.block.metadata orelse return 0;
        var n: usize = 0;
        var it = meta.inputs.iterator();
        while (it.next()) |entry| {
            if (n >= buf.len) break;
            buf[n] = entry.key_ptr.*;
            n += 1;
        }
        std.mem.sort([]const u8, buf[0..n], {}, lessThanStr);
        return n;
    }

    /// Name of the first non-readonly input, in display order (regardless of
    /// whether it already has a value — navigation stops on every editable
    /// input, not just unset ones).
    pub fn firstEditableInput(self: *const CodeFenceWidget) ?[]const u8 {
        const meta = self.block.metadata orelse return null;
        var names_buf: [16][]const u8 = undefined;
        const n = self.sortedInputNames(&names_buf);
        for (names_buf[0..n]) |name| {
            const def = meta.inputs.get(name).?;
            if (def.readonly) continue;
            return name;
        }
        return null;
    }

    /// Name of the last non-readonly input, in display order — the entry
    /// point when arriving at this block backwards (Shift-Tab).
    pub fn lastEditableInput(self: *const CodeFenceWidget) ?[]const u8 {
        const meta = self.block.metadata orelse return null;
        var names_buf: [16][]const u8 = undefined;
        const n = self.sortedInputNames(&names_buf);
        var i = n;
        while (i > 0) {
            i -= 1;
            const name = names_buf[i];
            const def = meta.inputs.get(name).?;
            if (def.readonly) continue;
            return name;
        }
        return null;
    }

    /// Non-readonly input after `current` in display order, or null if
    /// `current` is the last one.
    pub fn nextEditableInput(self: *const CodeFenceWidget, current: []const u8) ?[]const u8 {
        const meta = self.block.metadata orelse return null;
        var names_buf: [16][]const u8 = undefined;
        const n = self.sortedInputNames(&names_buf);
        var found_current = false;
        for (names_buf[0..n]) |name| {
            if (found_current) {
                const def = meta.inputs.get(name).?;
                if (def.readonly) continue;
                return name;
            }
            if (std.mem.eql(u8, name, current)) found_current = true;
        }
        return null;
    }

    /// Non-readonly input before `current` in display order, or null if
    /// `current` is the first one.
    pub fn prevEditableInput(self: *const CodeFenceWidget, current: []const u8) ?[]const u8 {
        const meta = self.block.metadata orelse return null;
        var names_buf: [16][]const u8 = undefined;
        const n = self.sortedInputNames(&names_buf);
        var prev_editable: ?[]const u8 = null;
        for (names_buf[0..n]) |name| {
            if (std.mem.eql(u8, name, current)) return prev_editable;
            const def = meta.inputs.get(name).?;
            if (!def.readonly) prev_editable = name;
        }
        return null;
    }

    pub fn hasEditableInputs(self: *const CodeFenceWidget) bool {
        return self.firstEditableInput() != null;
    }

    pub fn isEditingInput(self: *const CodeFenceWidget) bool {
        return self.editing_input != null;
    }

    /// Commits the in-progress field text for the input currently being
    /// edited into `input_values`, without changing edit mode. Callers decide
    /// afterwards whether to move to another input (`beginEditingInput`) or
    /// leave edit mode (`stopEditing`).
    pub fn commitCurrentField(self: *CodeFenceWidget) void {
        const name = self.editing_input orelse return;
        const value = self.input_field.toOwnedSlice() catch return;
        defer self.allocator.free(value);
        self.setInputValue(name, value) catch {};
    }

    /// Leaves input-edit mode without committing (mirrors what Escape does).
    pub fn stopEditing(self: *CodeFenceWidget) void {
        self.editing_input = null;
        self.input_field.clearAndFree();
    }

    fn storeHasValue(self: *const CodeFenceWidget, name: []const u8) bool {
        const copy = self.store.getCopy(name, self.allocator) catch return false;
        if (copy) |c| {
            self.allocator.free(c);
            return true;
        }
        return false;
    }

    /// Resolved value for display: store (upstream/committed) > local edit > declared default.
    /// `arena` should be a per-frame arena so the store copy doesn't need manual freeing.
    fn resolvedInputValueForDisplay(
        self: *const CodeFenceWidget,
        arena: Allocator,
        name: []const u8,
        def: fence_meta.InputDef,
    ) ?[]const u8 {
        if (self.store.getCopy(name, arena) catch null) |v| return v;
        if (self.input_values.get(name)) |v| return v;
        return def.default;
    }

    /// Feed this input's currently-resolved value (store > local edit >
    /// declared default — same precedence as `resolvedInputValueForDisplay`)
    /// into `hasher`. Used by DocumentView.autoSignature to detect changed
    /// parameters without needing to know that precedence itself.
    pub fn hashInputValue(self: *const CodeFenceWidget, hasher: *std.hash.Wyhash, name: []const u8, def: fence_meta.InputDef) void {
        if (self.store.getCopy(name, self.allocator) catch null) |v| {
            defer self.allocator.free(v);
            hasher.update(v);
            return;
        }
        if (self.input_values.get(name)) |v| {
            hasher.update(v);
            return;
        }
        if (def.default) |v| hasher.update(v);
    }

    fn setInputValue(self: *CodeFenceWidget, name: []const u8, value: []const u8) !void {
        const owned = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned);
        if (self.input_values.fetchRemove(name)) |kv| self.allocator.free(kv.value);
        try self.input_values.put(name, owned);
    }

    pub fn beginEditingInput(self: *CodeFenceWidget, name: []const u8) void {
        self.editing_input = name;
        self.input_field.clearAndFree();
        self.input_field.style = .{ .reverse = true };
        const meta = self.block.metadata orelse return;
        const def = meta.inputs.get(name) orelse return;
        // Same precedence as resolvedInputValueForDisplay: store (upstream/
        // shared-default edit) > local edit > declared default. Without the
        // store check, re-entering edit mode on an input that another block
        // (or a frontmatter default) already set would silently discard that
        // value and prefill from the stale declared default instead.
        if (self.store.getCopy(name, self.allocator) catch null) |v| {
            defer self.allocator.free(v);
            self.input_field.insertSliceAtCursor(v) catch {};
            return;
        }
        const prefill = self.input_values.get(name) orelse def.default;
        if (prefill) |p| {
            self.input_field.insertSliceAtCursor(p) catch {};
        }
    }

    /// Commit each non-readonly input's current value to the shared state
    /// store so it's available as an MDJAM_* env var for this and later
    /// blocks. A local edit (`input_values`) always wins and is written on
    /// every run — even a rerun after the store already holds this key from
    /// an earlier run — so re-editing a param and pressing Enter again
    /// actually takes effect. Only when there's no local edit do we leave an
    /// existing store value alone, falling back to the declared default
    /// otherwise.
    fn resolveInputsBeforeExecution(self: *CodeFenceWidget) void {
        const meta = self.block.metadata orelse return;
        var it = meta.inputs.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const def = entry.value_ptr.*;
            if (def.readonly) continue;
            if (self.input_values.get(name)) |edited| {
                self.store.set(name, edited, if (meta.id) |id| id else null) catch {};
                continue;
            }
            if (self.storeHasValue(name)) continue;
            const value = def.default orelse "";
            self.store.set(name, value, if (meta.id) |id| id else null) catch {};
        }
    }

    pub fn startExecution(self: *CodeFenceWidget, is_auto: bool) !void {
        self.ran_automatically = is_auto;
        self.resolveInputsBeforeExecution();
        // Clear previous output
        for (self.output_lines.items) |line| self.allocator.free(line.text);
        self.output_lines.clearRetainingCapacity();
        self.output_scroll = 0;
        self.status = .running;

        const is_interactive = if (self.block.metadata) |meta| meta.interactive else false;

        if (is_interactive and self.suspend_fn != null) {
            // Run interactive block in a thread (it will block until done)
            const ctx_ptr = try self.allocator.create(ExecCtx);
            ctx_ptr.* = .{ .widget = self };

            const thread = try std.Thread.spawn(.{}, interactiveThreadFn, .{ctx_ptr});
            if (self.runner_thread) |old| old.detach();
            self.runner_thread = thread;
            return;
        }

        const ctx_ptr = try self.allocator.create(ExecCtx);
        ctx_ptr.* = .{ .widget = self };

        const thread = block_runner.runAsync(&self.runner, .{
            .script = self.block.body,
            .block_id = if (self.block.metadata) |m| m.id else null,
            .store = self.store,
            .environ_map = self.environ_map,
            .allocator = self.allocator,
            .io = self.io,
            .output_cb = outputCallback,
            .done_cb = doneCallback,
            .cb_ctx = ctx_ptr,
        }) catch |err| {
            self.allocator.destroy(ctx_ptr);
            self.status = .failed;
            return err;
        };

        if (self.runner_thread) |old| old.detach();
        self.runner_thread = thread;
    }

    fn interactiveThreadFn(ctx: *ExecCtx) void {
        const self = ctx.widget;
        block_runner.runInteractive(
            self.block.body,
            self.allocator,
            self.suspend_fn.?,
            self.resume_fn.?,
            self.suspend_ctx,
            outputCallback,
            doneCallback,
            ctx,
        );
    }

    const ExecCtx = struct {
        widget: *CodeFenceWidget,
    };

    fn outputCallback(ctx: ?*anyopaque, line: []const u8, is_stderr: bool) void {
        const exec_ctx: *ExecCtx = @ptrCast(@alignCast(ctx.?));
        const self = exec_ctx.widget;

        // Consume ::set-output lines silently (they go to state store, not display)
        if (!is_stderr and std.mem.startsWith(u8, line, "::set-output name=")) return;

        if (self.output_lines.items.len >= MAX_OUTPUT_LINES) return;

        const owned = self.allocator.dupe(u8, line) catch return;
        self.output_lines.append(self.allocator, .{ .text = owned, .is_stderr = is_stderr }) catch {
            self.allocator.free(owned);
        };
        self.needs_redraw = true;
    }

    fn doneCallback(ctx: ?*anyopaque, result: block_runner.ExecResult) void {
        const exec_ctx: *ExecCtx = @ptrCast(@alignCast(ctx.?));
        const self = exec_ctx.widget;
        self.status = result.status;
        self.run_count += 1;
        if (result.status == .failed) {
            const msg = std.fmt.allocPrint(self.allocator, "(exited with code {d})", .{result.exit_code}) catch null;
            if (msg) |m| {
                self.output_lines.append(self.allocator, .{ .text = m, .is_stderr = true }) catch {
                    self.allocator.free(m);
                };
            }
        }
        self.needs_redraw = true;
        // ctx_ptr is destroyed here; allocator is still valid because App owns it
        exec_ctx.widget.allocator.destroy(exec_ctx);
    }

    pub fn height(self: *const CodeFenceWidget, width: u16) u16 {
        _ = width;
        var h: u16 = 0;

        // Meta header inside box (description or full meta in verbose mode)
        const ml = metaLineCount(self);
        if (ml > 0) h += ml + 1; // meta lines + separator

        // Code lines
        var code_lines: u16 = 0;
        var it = std.mem.splitScalar(u8, self.block.body, '\n');
        while (it.next()) |_| code_lines += 1;
        h += code_lines;

        // Output inside box: separator + output lines
        if (self.output_lines.items.len > 0) {
            h += 1 + @as(u16, @intCast(@min(self.output_lines.items.len, 10)));
        }

        h += 2; // top + bottom border

        return @max(h, 4);
    }

    pub fn draw(self: *CodeFenceWidget, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const width = ctx.max.width orelse 80;
        const h = self.height(width);
        const size: vxfw.Size = .{ .width = width, .height = h };
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);

        const code_fg = theme.dark.code_fg;
        const border_fg = if (self.focused) theme.dark.focused_border else theme.dark.unfocused_border;
        const border_style: vaxis.Style = .{ .fg = border_fg };
        const tokens = try highlighter.tokenize(ctx.arena, self.block.body, self.block.lang);

        var row: u16 = 0;

        // Top border: ┌─...─┐
        writeBoxTop(surface, row, width, border_style);
        row += 1;

        // Meta header inside box, followed by a separator
        if (self.block.metadata) |meta| {
            const meta_style: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x5C, 0x63, 0x70 } }, .italic = true };
            if (meta.description) |desc| {
                surface.writeCell(0, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border_style });
                writeStr(surface, 2, row, "# ", meta_style);
                writeStr(surface, 4, row, desc, meta_style);
                if (width >= 2) surface.writeCell(width - 1, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border_style });
                row += 1;
            }
            if (self.verbose) {
                if (meta.id) |id| {
                    surface.writeCell(0, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border_style });
                    writeStr(surface, 2, row, "# id: ", meta_style);
                    writeStr(surface, 8, row, id, meta_style);
                    if (width >= 2) surface.writeCell(width - 1, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border_style });
                    row += 1;
                }
                if (meta.auto) {
                    surface.writeCell(0, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border_style });
                    writeStr(surface, 2, row, "# auto: true", meta_style);
                    if (width >= 2) surface.writeCell(width - 1, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border_style });
                    row += 1;
                }
                if (meta.interactive) {
                    surface.writeCell(0, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border_style });
                    writeStr(surface, 2, row, "# interactive: true", meta_style);
                    if (width >= 2) surface.writeCell(width - 1, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border_style });
                    row += 1;
                }
                if (meta.depends.len > 0) {
                    surface.writeCell(0, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border_style });
                    writeStr(surface, 2, row, "# depends: ", meta_style);
                    var col: u16 = 13;
                    for (meta.depends, 0..) |dep, i| {
                        if (i > 0) {
                            writeStr(surface, col, row, ", ", meta_style);
                            col += 2;
                        }
                        writeStr(surface, col, row, dep, meta_style);
                        col += @intCast(dep.len);
                    }
                    if (width >= 2) surface.writeCell(width - 1, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border_style });
                    row += 1;
                }
                if (meta.outputs.len > 0) {
                    surface.writeCell(0, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border_style });
                    writeStr(surface, 2, row, "# outputs: ", meta_style);
                    var col: u16 = 13;
                    for (meta.outputs, 0..) |out, i| {
                        if (i > 0) {
                            writeStr(surface, col, row, ", ", meta_style);
                            col += 2;
                        }
                        writeStr(surface, col, row, out, meta_style);
                        col += @intCast(out.len);
                    }
                    if (width >= 2) surface.writeCell(width - 1, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border_style });
                    row += 1;
                }
            }

            // Inputs: always shown (not just verbose) since they're interactive.
            if (meta.inputs.count() > 0) {
                var names_buf: [16][]const u8 = undefined;
                const n = self.sortedInputNames(&names_buf);

                for (names_buf[0..n]) |name| {
                    const def = meta.inputs.get(name).?;
                    surface.writeCell(0, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border_style });

                    if (self.editing_input != null and std.mem.eql(u8, self.editing_input.?, name)) {
                        if (self.editing_label_cache) |v| self.allocator.free(v);
                        self.editing_label_cache = std.fmt.allocPrint(self.allocator, "# {s}: ", .{name}) catch null;
                        const label = self.editing_label_cache orelse "# input: ";
                        writeStr(surface, 2, row, label, meta_style);
                        const field_col: u16 = 2 + @as(u16, @intCast(label.len));
                        if (width > field_col + 1) {
                            const field_width = width - field_col - 1;
                            // Render the field's current text ourselves (heap-cached) rather
                            // than blitting TextField.draw()'s surface, which is backed by
                            // ctx.arena and would hit the same stale-diff issue as above.
                            if (self.editing_field_cache) |v| self.allocator.free(v);
                            self.editing_field_cache = std.fmt.allocPrint(self.allocator, "{s}{s}", .{
                                self.input_field.buf.firstHalf(),
                                self.input_field.buf.secondHalf(),
                            }) catch null;
                            const field_text = self.editing_field_cache orelse "";
                            const field_style: vaxis.Style = .{ .reverse = true };
                            var col: u16 = 0;
                            var it = std.unicode.Utf8Iterator{ .bytes = field_text, .i = 0 };
                            while (it.nextCodepointSlice()) |g| {
                                if (col >= field_width) break;
                                surface.writeCell(field_col + col, row, .{ .char = .{ .grapheme = g, .width = 1 }, .style = field_style });
                                col += 1;
                            }
                            while (col < field_width) : (col += 1) {
                                surface.writeCell(field_col + col, row, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = field_style });
                            }
                            // Ask the terminal to show its own (native, blinking)
                            // cursor at the insertion point, in this surface's own
                            // local coordinates — DocumentView translates it into
                            // document space since it blits this surface's cells
                            // rather than nesting it as a vxfw child.
                            surface.cursor = .{
                                .row = row,
                                .col = field_col + self.input_field.graphemesBeforeCursor(),
                                .shape = .block_blink,
                            };
                        }
                    } else {
                        const value = self.resolvedInputValueForDisplay(ctx.arena, name, def);
                        const hint: []const u8 = if (def.readonly) " (readonly)" else "";
                        const line = self.cachedLine(name, "# {s}: {s}{s}", .{ name, value orelse "", hint });
                        writeStr(surface, 2, row, line, meta_style);
                    }

                    if (width >= 2) surface.writeCell(width - 1, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border_style });
                    row += 1;
                }
            }
            if (metaLineCount(self) > 0) {
                writeBoxSeparator(surface, row, width, border_style);
                row += 1;
            }
        }

        // Code body with side borders
        var code_it = std.mem.splitScalar(u8, self.block.body, '\n');
        while (code_it.next()) |code_line| {
            if (row >= h - 1) break;
            surface.writeCell(0, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border_style });
            const line_start = @intFromPtr(code_line.ptr) - @intFromPtr(self.block.body.ptr);
            writeHighlightedStr(surface, 2, row, code_line, line_start, tokens, .{ .fg = code_fg });
            if (width >= 2) surface.writeCell(width - 1, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border_style });
            row += 1;
        }

        // Output separator + output lines inside the box
        if (self.output_lines.items.len > 0 and row < h -| 1) {
            writeBoxSeparator(surface, row, width, border_style);
            row += 1;

            const max_display: usize = @min(self.output_lines.items.len -| self.output_scroll, h -| row -| 1);
            for (0..max_display) |i| {
                if (row >= h -| 1) break;
                const line = self.output_lines.items[self.output_scroll + i];
                const out_style: vaxis.Style = .{
                    .fg = if (line.is_stderr) .{ .rgb = .{ 0xE0, 0x6C, 0x75 } } else code_fg,
                };
                surface.writeCell(0, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border_style });
                writeStr(surface, 2, row, line.text, out_style);
                if (width >= 2) surface.writeCell(width - 1, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border_style });
                row += 1;
            }
        }

        // Bottom border: └─...─┘
        writeBoxBottom(surface, row, width, border_style);

        return surface;
    }
};

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn metaLineCount(self: *const CodeFenceWidget) u16 {
    const meta = self.block.metadata orelse return 0;
    var n: u16 = 0;
    if (meta.description != null) n += 1;
    if (self.verbose) {
        if (meta.id != null) n += 1;
        if (meta.auto) n += 1;
        if (meta.interactive) n += 1;
        if (meta.depends.len > 0) n += 1;
        if (meta.outputs.len > 0) n += 1;
    }
    // Inputs are always shown (not just in verbose mode) since they're interactive.
    n += @intCast(meta.inputs.count());
    return n;
}

fn writeBoxTop(surface: vxfw.Surface, row: u16, width: u16, style: vaxis.Style) void {
    if (width == 0) return;
    surface.writeCell(0, row, .{ .char = .{ .grapheme = "┌", .width = 1 }, .style = style });
    if (width >= 2) {
        for (1..width - 1) |col| {
            surface.writeCell(@intCast(col), row, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = style });
        }
        surface.writeCell(width - 1, row, .{ .char = .{ .grapheme = "┐", .width = 1 }, .style = style });
    }
}

fn writeBoxSeparator(surface: vxfw.Surface, row: u16, width: u16, style: vaxis.Style) void {
    if (width == 0) return;
    surface.writeCell(0, row, .{ .char = .{ .grapheme = "├", .width = 1 }, .style = style });
    if (width >= 2) {
        for (1..width - 1) |col| {
            surface.writeCell(@intCast(col), row, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = style });
        }
        surface.writeCell(width - 1, row, .{ .char = .{ .grapheme = "┤", .width = 1 }, .style = style });
    }
}

fn writeBoxBottom(surface: vxfw.Surface, row: u16, width: u16, style: vaxis.Style) void {
    if (width == 0) return;
    surface.writeCell(0, row, .{ .char = .{ .grapheme = "└", .width = 1 }, .style = style });
    if (width >= 2) {
        for (1..width - 1) |col| {
            surface.writeCell(@intCast(col), row, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = style });
        }
        surface.writeCell(width - 1, row, .{ .char = .{ .grapheme = "┘", .width = 1 }, .style = style });
    }
}

fn writeHighlightedStr(
    surface: vxfw.Surface,
    col: u16,
    row: u16,
    s: []const u8,
    byte_offset: usize,
    tokens: []const highlighter.Token,
    default_style: vaxis.Style,
) void {
    var c = col;
    var off: usize = 0;
    var it = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    while (it.nextCodepointSlice()) |grapheme| {
        if (c >= surface.size.width) break;
        const style = highlighter.styleAtByte(tokens, byte_offset + off, default_style);
        surface.writeCell(c, row, .{
            .char = .{ .grapheme = grapheme, .width = 1 },
            .style = style,
        });
        c += 1;
        off += grapheme.len;
    }
}

fn writeStr(surface: vxfw.Surface, col: u16, row: u16, s: []const u8, style: vaxis.Style) void {
    var c = col;
    var it = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    while (it.nextCodepointSlice()) |grapheme| {
        if (c >= surface.size.width) break;
        surface.writeCell(c, row, .{
            .char = .{ .grapheme = grapheme, .width = 1 },
            .style = style,
        });
        c += 1;
    }
}
