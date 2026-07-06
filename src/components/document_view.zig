const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const md = @import("../parser/markdown.zig");
const CodeFenceWidget = @import("code_fence.zig").CodeFenceWidget;
const block_runner = @import("../engine/block_runner.zig");
const toc_mod = @import("toc_component.zig");
const TocWidget = toc_mod.TocWidget;
const state_store = @import("../engine/state_store.zig");
const highlighter = @import("highlighter.zig");
const fm_mod = @import("../parser/frontmatter.zig");

const Allocator = std.mem.Allocator;

const PendingCursor = struct {
    vrow: u32,
    col: u16,
    shape: vaxis.Cell.CursorShape,
};

pub const DocumentView = struct {
    allocator: Allocator,
    document: ?*const md.Document,
    store: *state_store.StateStore,
    environ_map: *const std.process.Environ.Map,
    io: std.Io,

    verbose: bool,
    frontmatter: ?*const fm_mod.Frontmatter,
    setup_error: ?[]const u8,
    scroll_offset: u32,
    focused_block: ?usize, // index into code_fences; null = no block focused
    // Set when Tab/Shift-Tab is pressed at the last/first block; shown once in
    // the status bar in place of the usual key hints, then cleared on the next key.
    boundary_hint: ?[]const u8,
    // Terminal-cursor position for the actively-edited param, in document
    // (virtual, pre-scroll) coordinates. Set by renderBlock() while drawing
    // the focused code fence's surface, since that surface's cells are
    // blitted into ours rather than nested as a vxfw child (which would
    // otherwise propagate `Surface.cursor` automatically). Consumed by
    // draw() after scroll-clipping to place it on the returned surface.
    pending_cursor: ?PendingCursor,
    code_fences: std.ArrayList(CodeFenceWidget),
    toc_widgets: std.ArrayList(TocWidget),
    terminal_width: u16,
    terminal_height: u16,

    // Editable frontmatter `variables`: name of the key currently being edited
    // (borrowed from frontmatter.variables; must be cleared before that map is
    // freed on reload — see resetFrontmatterEditing), the text field backing
    // that edit, and heap-cached rendered strings (see CodeFenceWidget's
    // input_line_cache doc for why these can't be ctx.arena-backed).
    fm_editing_key: ?[]const u8,
    fm_input_field: vxfw.TextField,
    fm_line_cache: std.StringHashMap([]u8),
    fm_editing_label_cache: ?[]u8,
    fm_editing_field_cache: ?[]u8,

    // Optional suspend/resume callbacks for interactive blocks
    suspend_fn: ?block_runner.SuspendFn,
    resume_fn: ?block_runner.ResumeFn,
    suspend_ctx: ?*anyopaque,

    pub fn init(
        allocator: Allocator,
        store: *state_store.StateStore,
        environ_map: *const std.process.Environ.Map,
        io: std.Io,
        verbose: bool,
    ) DocumentView {
        return .{
            .allocator = allocator,
            .document = null,
            .store = store,
            .environ_map = environ_map,
            .io = io,
            .verbose = verbose,
            .frontmatter = null,
            .setup_error = null,
            .scroll_offset = 0,
            .focused_block = null,
            .boundary_hint = null,
            .pending_cursor = null,
            .code_fences = std.ArrayList(CodeFenceWidget).empty,
            .toc_widgets = std.ArrayList(TocWidget).empty,
            .terminal_width = 80,
            .terminal_height = 24,
            .suspend_fn = null,
            .resume_fn = null,
            .suspend_ctx = null,
            .fm_editing_key = null,
            .fm_input_field = vxfw.TextField.init(allocator),
            .fm_line_cache = std.StringHashMap([]u8).init(allocator),
            .fm_editing_label_cache = null,
            .fm_editing_field_cache = null,
        };
    }

    pub fn deinit(self: *DocumentView) void {
        for (self.code_fences.items) |*cf| cf.deinit();
        self.code_fences.deinit(self.allocator);
        for (self.toc_widgets.items) |*tw| tw.deinit();
        self.toc_widgets.deinit(self.allocator);
        var fm_cache_it = self.fm_line_cache.valueIterator();
        while (fm_cache_it.next()) |v| self.allocator.free(v.*);
        self.fm_line_cache.deinit();
        if (self.fm_editing_label_cache) |v| self.allocator.free(v);
        if (self.fm_editing_field_cache) |v| self.allocator.free(v);
        self.fm_input_field.deinit();
    }

    /// Clears any in-progress frontmatter-default edit and its caches. Must be
    /// called before the current `frontmatter` is freed (e.g. on reload) since
    /// `fm_editing_key` and cache keys are borrowed from its `defaults` map.
    pub fn resetFrontmatterEditing(self: *DocumentView) void {
        self.fm_editing_key = null;
        self.fm_input_field.clearAndFree();
        var it = self.fm_line_cache.valueIterator();
        while (it.next()) |v| self.allocator.free(v.*);
        self.fm_line_cache.clearRetainingCapacity();
        if (self.fm_editing_label_cache) |v| self.allocator.free(v);
        self.fm_editing_label_cache = null;
        if (self.fm_editing_field_cache) |v| self.allocator.free(v);
        self.fm_editing_field_cache = null;
    }

    pub fn setDocument(self: *DocumentView, doc: *const md.Document) Allocator.Error!void {
        // Deinit existing code fences
        for (self.code_fences.items) |*cf| cf.deinit();
        self.code_fences.clearRetainingCapacity();
        for (self.toc_widgets.items) |*tw| tw.deinit();
        self.toc_widgets.clearRetainingCapacity();

        self.document = doc;
        self.scroll_offset = 0;
        self.focused_block = null;

        // Create code fence widgets for executable blocks, and TOC widgets for toc blocks
        for (doc.blocks) |*block| {
            switch (block.*) {
                .code_fence => |*cf| {
                    if (std.mem.eql(u8, cf.lang, "toc")) {
                        // Create a TOC widget for this block
                        const tw = try TocWidget.init(self.allocator, doc, cf);
                        try self.toc_widgets.append(self.allocator, tw);
                    } else {
                        // Only create widgets for bash blocks or blocks with metadata
                        const is_executable = std.mem.eql(u8, cf.lang, "bash") or
                            std.mem.eql(u8, cf.lang, "sh") or
                            (cf.metadata != null);
                        if (is_executable) {
                            var cfw = try CodeFenceWidget.init(
                                self.allocator,
                                cf,
                                self.store,
                                self.environ_map,
                                self.io,
                                self.verbose,
                            );
                            // Propagate suspend/resume callbacks for interactive blocks
                            cfw.suspend_fn = self.suspend_fn;
                            cfw.resume_fn = self.resume_fn;
                            cfw.suspend_ctx = self.suspend_ctx;
                            try self.code_fences.append(self.allocator, cfw);
                        }
                    }
                },
                else => {},
            }
        }

        // Nothing is focused on load — the document renders from the top in
        // plain reading mode (scroll_offset/focused_block were just reset
        // above). The first Tab press focuses (and auto-edits, if it has
        // params) the first block; Shift-Tab starts from the last.
    }

    const FenceEntryDirection = enum { first, last };

    /// Focuses fence `idx` and auto-edits its first (or, arriving backwards,
    /// last) editable input, mirroring how a click or Tab lands on a block.
    fn focusFence(self: *DocumentView, idx: usize, dir: FenceEntryDirection) void {
        self.focused_block = idx;
        self.code_fences.items[idx].focused = true;
        const name = switch (dir) {
            .first => self.code_fences.items[idx].firstEditableInput(),
            .last => self.code_fences.items[idx].lastEditableInput(),
        };
        if (name) |n| self.code_fences.items[idx].beginEditingInput(n);
        self.scrollToFence(idx);
    }

    /// Enters editing on the first frontmatter default field and scrolls it
    /// into view (it's always the very top of the document).
    fn enterFrontmatterField(self: *DocumentView, name: []const u8) void {
        self.beginEditingFrontmatterKey(name);
        self.scroll_offset = 0;
    }

    /// Tab: advance to the next frontmatter default field, the next block, or
    /// (from within a document-defaults edit) hand off to the first block
    /// once defaults are exhausted.
    pub fn focusNextBlock(self: *DocumentView) void {
        if (self.fm_editing_key) |cur| {
            if (self.nextFrontmatterKey(cur)) |next| {
                self.commitFrontmatterField();
                self.beginEditingFrontmatterKey(next);
                return;
            }
            self.commitFrontmatterField();
            self.stopEditingFrontmatter();
            if (self.code_fences.items.len == 0) {
                self.boundary_hint = "Already at the last block";
                return;
            }
            self.focusFence(0, .first);
            return;
        }
        if (self.focused_block == null) {
            if (self.firstFrontmatterKey()) |name| {
                self.enterFrontmatterField(name);
                return;
            }
            if (self.code_fences.items.len == 0) return;
            self.focusFence(0, .first);
            return;
        }
        const fb = self.focused_block.?;
        if (fb + 1 >= self.code_fences.items.len) {
            self.boundary_hint = "Already at the last block";
            return;
        }
        self.code_fences.items[fb].focused = false;
        self.focusFence(fb + 1, .first);
    }

    /// Shift-Tab mirror of `focusNextBlock`. Arriving backwards from the
    /// first block lands on the last frontmatter default field, if any.
    pub fn focusPrevBlock(self: *DocumentView) void {
        if (self.fm_editing_key) |cur| {
            if (self.prevFrontmatterKey(cur)) |prev| {
                self.commitFrontmatterField();
                self.beginEditingFrontmatterKey(prev);
                return;
            }
            self.boundary_hint = "Already at the first field";
            return;
        }
        if (self.focused_block == null) {
            if (self.code_fences.items.len == 0) {
                if (self.lastFrontmatterKey()) |name| self.enterFrontmatterField(name);
                return;
            }
            self.focusFence(self.code_fences.items.len - 1, .last);
            return;
        }
        const fb = self.focused_block.?;
        if (fb == 0) {
            if (self.lastFrontmatterKey()) |name| {
                self.code_fences.items[fb].focused = false;
                self.focused_block = null;
                self.enterFrontmatterField(name);
                return;
            }
            self.boundary_hint = "Already at the first block";
            return;
        }
        self.code_fences.items[fb].focused = false;
        self.focusFence(fb - 1, .last);
    }

    /// Tab while editing a param: advance to the next editable param in this
    /// block, or hand off to the next block if there isn't one. Boundary
    /// (last param of the last block) is checked before anything is
    /// committed/cleared, so the field's contents and edit state are left
    /// untouched — same "stop with hint" behavior as plain block navigation.
    pub fn paramOrBlockNext(self: *DocumentView) void {
        const fb = self.focused_block orelse return;
        const cf = &self.code_fences.items[fb];
        const cur = cf.editing_input orelse return;
        if (cf.nextEditableInput(cur)) |next_name| {
            cf.commitCurrentField();
            cf.beginEditingInput(next_name);
            return;
        }
        if (fb + 1 >= self.code_fences.items.len) {
            self.boundary_hint = "Already at the last block";
            return;
        }
        cf.commitCurrentField();
        cf.stopEditing();
        self.focusNextBlock();
    }

    /// Shift-Tab mirror of `paramOrBlockNext`. From the first param of the
    /// first block, hands off to the last frontmatter default field if the
    /// document has any (checked before committing, same boundary-safety
    /// rule as above); otherwise it's a true boundary.
    pub fn paramOrBlockPrev(self: *DocumentView) void {
        const fb = self.focused_block orelse return;
        const cf = &self.code_fences.items[fb];
        const cur = cf.editing_input orelse return;
        if (cf.prevEditableInput(cur)) |prev_name| {
            cf.commitCurrentField();
            cf.beginEditingInput(prev_name);
            return;
        }
        if (fb == 0 and self.lastFrontmatterKey() == null) {
            self.boundary_hint = "Already at the first block";
            return;
        }
        cf.commitCurrentField();
        cf.stopEditing();
        self.focusPrevBlock();
    }

    /// Enter while editing a param: commit it, resolve any other unset
    /// inputs in the block to their defaults (via `executeWithDeps` ->
    /// `startExecution` -> `resolveInputsBeforeExecution`), and run — without
    /// moving focus. The param editor stays open on the same field (refreshed
    /// with the value just committed) so a repeated Enter reruns the block.
    pub fn commitAndRunEditingBlock(self: *DocumentView) !void {
        const fb = self.focused_block orelse return;
        const cf = &self.code_fences.items[fb];
        const name = cf.editing_input orelse return;
        cf.commitCurrentField();
        if (cf.status != .running) {
            try self.executeWithDeps(cf, false, false);
        }
        // Refresh the display after resolveInputsBeforeExecution has written
        // this run's values to the store — beginEditingInput reads the store
        // first, so refreshing before execution would show the *previous*
        // run's value for this field instead of what was just committed.
        cf.beginEditingInput(name);
    }

    /// Populates `buf` with frontmatter default names in sorted (display)
    /// order and returns the count. Mirrors CodeFenceWidget.sortedInputNames
    /// so both editable-field kinds traverse consistently.
    fn sortedFrontmatterKeys(self: *const DocumentView, buf: *[16][]const u8) usize {
        const fm = self.frontmatter orelse return 0;
        var n: usize = 0;
        var it = fm.variables.iterator();
        while (it.next()) |entry| {
            if (n >= buf.len) break;
            buf[n] = entry.key_ptr.*;
            n += 1;
        }
        std.mem.sort([]const u8, buf[0..n], {}, lessThanStr);
        return n;
    }

    pub fn hasFrontmatterDefaults(self: *const DocumentView) bool {
        const fm = self.frontmatter orelse return false;
        return fm.variables.count() > 0;
    }

    pub fn firstFrontmatterKey(self: *const DocumentView) ?[]const u8 {
        var buf: [16][]const u8 = undefined;
        const n = self.sortedFrontmatterKeys(&buf);
        return if (n > 0) buf[0] else null;
    }

    pub fn lastFrontmatterKey(self: *const DocumentView) ?[]const u8 {
        var buf: [16][]const u8 = undefined;
        const n = self.sortedFrontmatterKeys(&buf);
        return if (n > 0) buf[n - 1] else null;
    }

    fn nextFrontmatterKey(self: *const DocumentView, current: []const u8) ?[]const u8 {
        var buf: [16][]const u8 = undefined;
        const n = self.sortedFrontmatterKeys(&buf);
        var found = false;
        for (buf[0..n]) |name| {
            if (found) return name;
            if (std.mem.eql(u8, name, current)) found = true;
        }
        return null;
    }

    fn prevFrontmatterKey(self: *const DocumentView, current: []const u8) ?[]const u8 {
        var buf: [16][]const u8 = undefined;
        const n = self.sortedFrontmatterKeys(&buf);
        var prev: ?[]const u8 = null;
        for (buf[0..n]) |name| {
            if (std.mem.eql(u8, name, current)) return prev;
            prev = name;
        }
        return null;
    }

    pub fn isEditingFrontmatter(self: *const DocumentView) bool {
        return self.fm_editing_key != null;
    }

    /// Resolved value for a frontmatter default: state store (reflects a
    /// prior edit or a block's `::set-output`) wins over the declared
    /// frontmatter value. Always returns a `self.allocator`-owned copy (or
    /// null) so callers free uniformly regardless of source.
    fn resolvedFrontmatterValue(self: *const DocumentView, name: []const u8) ?[]const u8 {
        if (self.store.getCopy(name, self.allocator) catch null) |v| return v;
        const fm = self.frontmatter orelse return null;
        const def = fm.variables.get(name) orelse return null;
        return self.allocator.dupe(u8, def.default orelse "") catch null;
    }

    pub fn beginEditingFrontmatterKey(self: *DocumentView, name: []const u8) void {
        self.fm_editing_key = name;
        self.fm_input_field.clearAndFree();
        self.fm_input_field.style = .{ .reverse = true };
        if (self.resolvedFrontmatterValue(name)) |v| {
            defer self.allocator.free(v);
            self.fm_input_field.insertSliceAtCursor(v) catch {};
        }
    }

    /// Commits the in-progress field text directly into the shared state
    /// store — unlike a fence param (which stages into `input_values` until
    /// the block runs), a frontmatter default has no associated execution
    /// step, so the edit takes effect immediately for every block reading it.
    fn commitFrontmatterField(self: *DocumentView) void {
        const name = self.fm_editing_key orelse return;
        const value = self.fm_input_field.toOwnedSlice() catch return;
        defer self.allocator.free(value);
        self.store.set(name, value, null) catch {};
    }

    fn stopEditingFrontmatter(self: *DocumentView) void {
        self.fm_editing_key = null;
        self.fm_input_field.clearAndFree();
    }

    /// Enter while editing a frontmatter default: commit it and reopen the
    /// same field (refreshed with the committed value) — there's no
    /// execution step to trigger, just a value that's now visible to every
    /// block reading it.
    pub fn commitFrontmatterEdit(self: *DocumentView) void {
        const name = self.fm_editing_key orelse return;
        self.commitFrontmatterField();
        self.beginEditingFrontmatterKey(name);
    }

    fn scrollToFence(self: *DocumentView, fence_idx: usize) void {
        self.scroll_offset = self.virtualRowOfFence(fence_idx);
    }

    fn virtualRowOfFence(self: *DocumentView, target_idx: usize) u32 {
        const doc = self.document orelse return 0;
        var vrow: u32 = self.frontmatterHeaderHeight();
        var fi: usize = 0;
        for (doc.blocks) |*block| {
            switch (block.*) {
                .code_fence => |*cf| {
                    for (self.code_fences.items, 0..) |*cfw, i| {
                        if (cfw.block == cf) {
                            if (i == target_idx) return vrow;
                            break;
                        }
                    }
                },
                else => {},
            }
            const h: u32 = @intCast(self.measureBlock(block, self.terminal_width, &fi));
            vrow += h + 1;
        }
        return 0;
    }

    fn fenceAtVirtualRow(self: *DocumentView, target_vrow: u32) ?usize {
        const doc = self.document orelse return null;
        var vrow: u32 = self.frontmatterHeaderHeight();
        var fi: usize = 0;
        for (doc.blocks) |*block| {
            const h: u32 = @intCast(self.measureBlock(block, self.terminal_width, &fi));
            if (target_vrow >= vrow and target_vrow < vrow + h) {
                switch (block.*) {
                    .code_fence => |*cf| {
                        for (self.code_fences.items, 0..) |*cfw, i| {
                            if (cfw.block == cf) return i;
                        }
                    },
                    else => {},
                }
                return null;
            }
            vrow += h + 1;
        }
        return null;
    }

    pub fn deselect(self: *DocumentView) void {
        if (self.focused_block) |fb| {
            self.code_fences.items[fb].focused = false;
            self.focused_block = null;
        }
    }

    /// True when a frontmatter default field or the focused code fence has an
    /// input field actively being edited. Callers should forward key events
    /// directly to it rather than applying their own navigation/shortcut
    /// handling.
    pub fn isEditingInput(self: *const DocumentView) bool {
        if (self.fm_editing_key != null) return true;
        const fb = self.focused_block orelse return false;
        return self.code_fences.items[fb].isEditingInput();
    }

    pub fn runFocusedBlock(self: *DocumentView) anyerror!void {
        const fb = self.focused_block orelse return;
        const cf = &self.code_fences.items[fb];
        if (cf.status != .running) {
            try self.executeWithDeps(cf, false, false);
        }
    }

    fn findFenceById(self: *DocumentView, block_id: []const u8) ?*CodeFenceWidget {
        for (self.code_fences.items) |*cf| {
            const meta = cf.block.metadata orelse continue;
            const id = meta.id orelse continue;
            if (std.mem.eql(u8, id, block_id)) return cf;
        }
        return null;
    }

    /// `auto`: true when this run was triggered by auto-execution rather than
    /// a manual Enter press; suppresses the "done" status badge (see
    /// CodeFenceWidget.ran_automatically).
    ///
    /// `wait_for_target`: whether to block until the target itself (last in
    /// `order`) finishes, rather than just kicking it off. True only when
    /// it's safe to freeze the event loop for the script's duration — e.g.
    /// document-load auto-execution, which runs before the TUI's first draw
    /// and needs deterministic ordering between chained auto blocks. Manual
    /// runs and live auto-reruns (triggered by `checkAutoReruns` while the
    /// TUI is already interactive) always pass false so the UI keeps
    /// redrawing and showing the running/spinner status. Dependencies ahead
    /// of the target in `order` are always waited on, regardless of this
    /// flag, since later scripts may rely on state they write.
    pub fn executeWithDeps(self: *DocumentView, target: *CodeFenceWidget, auto: bool, wait_for_target: bool) !void {
        // Collect dependency chain in execution order
        var order = std.ArrayList(*CodeFenceWidget).empty;
        defer order.deinit(self.allocator);

        try self.collectDeps(target, &order, 0);

        for (order.items, 0..) |fence, i| {
            const is_target = i == order.items.len - 1;
            // A dependency that already succeeded is reused as-is, but the
            // target itself must always (re-)run: callers only reach this
            // point after deciding this block should execute now, and a
            // block that already completed must still be re-runnable (e.g.
            // via a repeated Enter press).
            if (!is_target and fence.status == .done) continue;
            if (fence.status == .running) continue;
            fence.startExecution(auto) catch {};

            if (is_target and !wait_for_target) return;

            // Wait synchronously for this dep to complete before proceeding
            var waited: usize = 0;
            while (fence.status == .running and waited < 30000) : (waited += 1) {
                // sleep 1ms using libc nanosleep
                const ts = std.c.timespec{ .sec = 0, .nsec = 1_000_000 };
                _ = std.c.nanosleep(&ts, null);
            }
            if (fence.status != .done) return; // dep failed or timed out, stop chain
        }
    }

    /// Compute a signature over everything an `auto` block's rerun decision
    /// depends on: the run count of each block it `depends` on (bumped every
    /// time that dependency finishes a run — see CodeFenceWidget.run_count)
    /// and the resolved value of each of its own `inputs` ("parameters").
    /// A changed signature means the block is due for another run.
    fn autoSignature(self: *DocumentView, fence: *CodeFenceWidget) u64 {
        var hasher = std.hash.Wyhash.init(0);
        const meta = fence.block.metadata orelse return 0;

        for (meta.depends) |dep_id| {
            const dep = self.findFenceById(dep_id) orelse continue;
            hasher.update(std.mem.asBytes(&dep.run_count));
        }

        var it = meta.variables.iterator();
        while (it.next()) |entry| {
            hasher.update(entry.key_ptr.*);
            fence.hashInputValue(&hasher, entry.key_ptr.*, entry.value_ptr.*);
        }

        return hasher.final();
    }

    /// Re-run every `auto` block whose `depends`/`inputs` signature has moved
    /// since its last run (see `autoSignature`) — this also covers each
    /// fence's very first run, since `last_auto_signature` starts out null.
    /// Cheap to call often: it's a handful of hashes per fence, and only
    /// fences that are actually due get executed.
    ///
    /// `wait_for_target`: forwarded to `executeWithDeps` — pass true only at
    /// document load (before the TUI's first draw); false everywhere else so
    /// live reruns don't freeze the UI.
    pub fn checkAutoReruns(self: *DocumentView, wait_for_target: bool) void {
        for (self.code_fences.items) |*cf| {
            const meta = cf.block.metadata orelse continue;
            if (!meta.auto or cf.status == .running) continue;

            const sig = self.autoSignature(cf);
            if (cf.last_auto_signature) |prev| {
                if (prev == sig) continue;
            }
            cf.last_auto_signature = sig;
            self.executeWithDeps(cf, true, wait_for_target) catch {};
        }
    }

    fn collectDeps(self: *DocumentView, fence: *CodeFenceWidget, order: *std.ArrayList(*CodeFenceWidget), depth: u8) !void {
        if (depth > 20) return; // cycle guard
        const meta = fence.block.metadata orelse {
            // No metadata means no deps; just add the fence itself
            for (order.items) |existing| {
                if (existing == fence) return;
            }
            try order.append(self.allocator, fence);
            return;
        };
        for (meta.depends) |dep_id| {
            const dep = self.findFenceById(dep_id) orelse continue;
            try self.collectDeps(dep, order, depth + 1);
        }
        // Avoid duplicates
        for (order.items) |existing| {
            if (existing == fence) return;
        }
        try order.append(self.allocator, fence);
    }

    pub fn widget(self: *DocumentView) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *DocumentView = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *DocumentView = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn handleEvent(self: *DocumentView, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .winsize => |ws| {
                self.terminal_width = ws.cols;
                self.terminal_height = ws.rows;
                ctx.redraw = true;
            },
            .key_press => |key| {
                self.boundary_hint = null;
                if (self.fm_editing_key != null) {
                    // Tab/Shift-Tab/Enter/Escape drive field navigation and
                    // commit; every other key is the field's own to handle.
                    if (key.matches(vaxis.Key.tab, .{ .shift = true })) {
                        self.focusPrevBlock();
                        ctx.consumeAndRedraw();
                    } else if (key.matches(vaxis.Key.tab, .{})) {
                        self.focusNextBlock();
                        ctx.consumeAndRedraw();
                    } else if (key.matches(vaxis.Key.enter, .{})) {
                        self.commitFrontmatterEdit();
                        ctx.consumeAndRedraw();
                    } else if (key.matches(vaxis.Key.escape, .{})) {
                        self.stopEditingFrontmatter();
                        ctx.consumeAndRedraw();
                    } else {
                        try self.fm_input_field.handleEvent(ctx, event);
                    }
                    return;
                }
                if (self.isEditingInput()) {
                    // Tab/Shift-Tab/Enter drive param/block navigation and
                    // execution; every other key (Escape, text input) is the
                    // field's own to handle.
                    if (key.matches(vaxis.Key.tab, .{ .shift = true })) {
                        self.paramOrBlockPrev();
                        ctx.consumeAndRedraw();
                    } else if (key.matches(vaxis.Key.tab, .{})) {
                        self.paramOrBlockNext();
                        ctx.consumeAndRedraw();
                    } else if (key.matches(vaxis.Key.enter, .{})) {
                        try self.commitAndRunEditingBlock();
                        ctx.consumeAndRedraw();
                    } else {
                        try self.code_fences.items[self.focused_block.?].handleEvent(ctx, event);
                    }
                    return;
                }
                if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
                    self.scrollDown(3);
                    ctx.consumeAndRedraw();
                } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
                    self.scrollUp(3);
                    ctx.consumeAndRedraw();
                } else if (key.matches(' ', .{}) or key.matches(vaxis.Key.page_down, .{})) {
                    self.scrollDown(@max(1, self.terminal_height -| 2));
                    ctx.consumeAndRedraw();
                } else if (key.matches('b', .{}) or key.matches(vaxis.Key.page_up, .{})) {
                    self.scrollUp(@max(1, self.terminal_height -| 2));
                    ctx.consumeAndRedraw();
                } else if (key.matches('g', .{}) or key.matches(vaxis.Key.home, .{}) or key.matches(vaxis.Key.kp_home, .{})) {
                    self.scroll_offset = 0;
                    ctx.consumeAndRedraw();
                } else if (key.matches('G', .{}) or key.matches(vaxis.Key.end, .{}) or key.matches(vaxis.Key.kp_end, .{})) {
                    self.scroll_offset = std.math.maxInt(u32);
                    ctx.consumeAndRedraw();
                } else if (key.matches(vaxis.Key.tab, .{ .shift = true })) {
                    self.focusPrevBlock();
                    ctx.consumeAndRedraw();
                } else if (key.matches(vaxis.Key.tab, .{})) {
                    self.focusNextBlock();
                    ctx.consumeAndRedraw();
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    if (self.focused_block) |fb| {
                        const cf = &self.code_fences.items[fb];
                        if (cf.status != .running) {
                            try self.executeWithDeps(cf, false, false);
                        }
                    }
                    ctx.consumeAndRedraw();
                } else if (key.matches(vaxis.Key.escape, .{})) {
                    if (self.focused_block) |fb| {
                        const cf = &self.code_fences.items[fb];
                        if (cf.status == .running) {
                            try cf.handleEvent(ctx, event); // cancel
                        } else {
                            self.deselect();
                            ctx.consumeAndRedraw();
                        }
                    }
                } else {
                    // Pass to focused code fence
                    if (self.focused_block) |fb| {
                        try self.code_fences.items[fb].handleEvent(ctx, event);
                    }
                }
            },
            .mouse => |mouse| {
                if (mouse.type == .press and mouse.button == .left and mouse.row >= 0) {
                    const vrow: u32 = self.scroll_offset +| @as(u32, @intCast(mouse.row));
                    if (self.hasFrontmatterDefaults() and vrow < self.frontmatterHeaderHeight()) {
                        if (self.focused_block) |fb| self.code_fences.items[fb].focused = false;
                        self.focused_block = null;
                        if (self.firstFrontmatterKey()) |name| self.beginEditingFrontmatterKey(name);
                        ctx.consumeAndRedraw();
                        return;
                    }
                    if (self.fenceAtVirtualRow(vrow)) |fi| {
                        if (self.focused_block != fi) {
                            if (self.focused_block) |fb| self.code_fences.items[fb].focused = false;
                            self.focused_block = fi;
                            self.code_fences.items[fi].focused = true;
                            if (self.code_fences.items[fi].firstEditableInput()) |name| {
                                self.code_fences.items[fi].beginEditingInput(name);
                            }
                            // The clicked block may only be partially visible
                            // (e.g. its top border/description scrolled just
                            // out of view) — bring it fully into the viewport,
                            // same as Tab/Shift-Tab do.
                            self.scrollToFence(fi);
                            ctx.consumeAndRedraw();
                        }
                    }
                }
            },
            .app => |ev| {
                // Forward to all code fences
                for (self.code_fences.items) |*cf| {
                    try cf.handleEvent(ctx, .{ .app = ev });
                }
            },
            else => {},
        }
    }

    fn scrollDown(self: *DocumentView, amount: u16) void {
        self.scroll_offset +|= amount;
    }

    fn scrollUp(self: *DocumentView, amount: u16) void {
        if (self.scroll_offset > amount) {
            self.scroll_offset -= amount;
        } else {
            self.scroll_offset = 0;
        }
    }

    pub fn draw(self: *DocumentView, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        self.pending_cursor = null;
        const width = ctx.max.width orelse 80;
        const height = ctx.max.height orelse 24;
        // Keep in sync with what's actually drawn, not just what the last
        // `.winsize` event reported — that event isn't reliably delivered
        // (doesn't fire for the initial size, and some terminals/multiplexers
        // never emit it at all), throwing off scrollToFence's row math.
        const width_changed = width != self.terminal_width;
        self.terminal_width = width;
        self.terminal_height = height;
        // scroll_offset is a raw row number; a width change reflows paragraph
        // text above the focused block, shifting its true row without
        // changing this stale value. Re-anchor so its top border/description
        // stay in view, same as Tab does — but only actually on a width
        // change, so free j/k scrolling away from a focused block isn't
        // fought on every frame.
        if (width_changed) {
            if (self.focused_block) |fb| self.scrollToFence(fb);
        }

        const doc = self.document orelse {
            // Empty state
            const surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
            writeStr(surface, 2, height / 2, "No document loaded", .{ .fg = .{ .index = 8 } });
            return surface;
        };

        // First pass: measure total content height
        const total_height = self.measureContent(doc, width);

        // Clamp scroll
        const max_scroll = if (total_height > height) total_height - height else 0;
        if (self.scroll_offset > max_scroll) self.scroll_offset = @intCast(max_scroll);

        // Create a large virtual surface, then clip it
        const virtual_height: u16 = @intCast(total_height);
        const virtual_surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = virtual_height });

        var fence_idx: usize = 0;
        var vrow: u16 = self.renderFrontmatterHeader(virtual_surface, 0, width);

        for (doc.blocks) |*block| {
            if (vrow >= virtual_height) break;
            vrow = try self.renderBlock(ctx.arena, virtual_surface, block, vrow, width, &fence_idx);
            // Add blank line between blocks
            vrow += 1;
        }

        // Clip to visible area
        const visible_start: u16 = @intCast(self.scroll_offset);
        const visible_end: u16 = @min(virtual_height, visible_start + height);
        const visible_height = visible_end - visible_start;

        var output_surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });

        // Copy rows from virtual surface to output
        for (0..visible_height) |r| {
            const src_row = visible_start + @as(u16, @intCast(r));
            for (0..width) |c| {
                if (src_row < virtual_surface.size.height) {
                    const cell = virtual_surface.readCell(c, src_row);
                    output_surface.writeCell(@intCast(c), @intCast(r), cell);
                }
            }
        }

        // Place the terminal cursor for the actively-edited param, if it's
        // within the currently visible (scrolled) window.
        if (self.pending_cursor) |pc| {
            const vstart: u32 = visible_start;
            const vend: u32 = visible_end;
            if (pc.vrow >= vstart and pc.vrow < vend) {
                output_surface.cursor = .{
                    .row = @intCast(pc.vrow - vstart),
                    .col = pc.col,
                    .shape = pc.shape,
                };
            }
        }

        return output_surface;
    }

    fn setupErrorHeight(self: *const DocumentView) u16 {
        const msg = self.setup_error orelse return 0;
        var lines: u16 = 2; // opening banner + closing rule
        var it = std.mem.splitScalar(u8, msg, '\n');
        while (it.next()) |_| lines += 1;
        return lines;
    }

    fn renderSetupError(self: *const DocumentView, surface: vxfw.Surface, start_row: u16, width: u16) u16 {
        const msg = self.setup_error orelse return start_row;
        var row = start_row;
        const err_style: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xE0, 0x6C, 0x75 } }, .bold = true };

        writeBanner(surface, row, width, " Setup script failed ", err_style);
        row += 1;
        var it = std.mem.splitScalar(u8, msg, '\n');
        while (it.next()) |line| {
            writeStr(surface, 0, row, line, err_style);
            row += 1;
        }
        writeFillRow(surface, row, width, "─", err_style);
        row += 1;
        return row;
    }

    fn frontmatterHeaderHeight(self: *const DocumentView) u16 {
        const banner_h = self.setupErrorHeight();
        const fm = self.frontmatter orelse return banner_h;
        const variables_n: u16 = @intCast(fm.variables.count());

        if (!self.verbose) {
            // Non-verbose: description (optional) + editable variable rows
            // (always shown, not just verbose, since they're interactive —
            // same policy as CodeFenceWidget's variables) + trailing separator.
            var h: u16 = 0;
            if (fm.description != null) h += 1;
            h += variables_n;
            if (h == 0) return banner_h;
            return banner_h + h + 1;
        }

        // Verbose: count YAML lines
        var h: u16 = 0;
        if (fm.title != null) h += 1;
        if (fm.description != null) h += 1;
        const has_tools = fm.prerequisites.tools.len > 0;
        const has_env = fm.prerequisites.env.len > 0;
        if (has_tools or has_env) {
            h += 1; // "prerequisites:"
            if (has_tools) h += 1 + @as(u16, @intCast(fm.prerequisites.tools.len)); // "  tools:" + items
            if (has_env) h += 1 + @as(u16, @intCast(fm.prerequisites.env.len)); // "  env:" + items
        }
        if (variables_n > 0) {
            h += 1 + variables_n; // "variables:" + items
        }
        if (h == 0) return banner_h;
        return banner_h + h + 2; // opening banner + closing rule
    }

    /// Renders one frontmatter default row at `indent`: an editable field if
    /// it's the one currently being edited, otherwise its resolved value
    /// (state store, reflecting any prior edit, over the declared default).
    fn renderFrontmatterDefaultRow(self: *DocumentView, surface: vxfw.Surface, row: u16, width: u16, indent: u16, name: []const u8, style: vaxis.Style) void {
        const description: ?[]const u8 = if (self.frontmatter) |fm|
            if (fm.variables.get(name)) |def| def.description else null
        else
            null;

        if (self.fm_editing_key != null and std.mem.eql(u8, self.fm_editing_key.?, name)) {
            if (self.fm_editing_label_cache) |v| self.allocator.free(v);
            self.fm_editing_label_cache = std.fmt.allocPrint(self.allocator, "{s}: ", .{name}) catch null;
            const label = self.fm_editing_label_cache orelse "";
            writeStr(surface, indent, row, label, style);
            const field_col: u16 = indent + @as(u16, @intCast(label.len));
            if (width <= field_col) return;
            const field_width = descriptionAwareFieldWidth(width - field_col, description);

            if (self.fm_editing_field_cache) |v| self.allocator.free(v);
            self.fm_editing_field_cache = std.fmt.allocPrint(self.allocator, "{s}{s}", .{
                self.fm_input_field.buf.firstHalf(),
                self.fm_input_field.buf.secondHalf(),
            }) catch null;
            const field_text = self.fm_editing_field_cache orelse "";
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
            if (description) |desc| {
                const desc_style: vaxis.Style = .{ .fg = .{ .index = 8 }, .italic = true };
                writeStrRightAligned(surface, row, width, field_col + field_width, desc, desc_style);
            }
            // See CodeFenceWidget.draw's identical cursor recovery comment —
            // here there's no nested surface to blit, so this row is already
            // in virtual (pre-scroll) document coordinates.
            self.pending_cursor = .{
                .vrow = @as(u32, row),
                .col = field_col + self.fm_input_field.graphemesBeforeCursor(),
                .shape = .block_blink,
            };
            return;
        }

        const resolved = self.resolvedFrontmatterValue(name);
        defer if (resolved) |r| self.allocator.free(r);
        const fresh = std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ name, resolved orelse "" }) catch return;
        if (self.fm_line_cache.fetchRemove(name)) |kv| self.allocator.free(kv.value);
        self.fm_line_cache.put(name, fresh) catch {};
        writeStr(surface, indent, row, fresh, style);

        if (description) |desc| {
            const desc_style: vaxis.Style = .{ .fg = .{ .index = 8 }, .italic = true };
            const min_col: u16 = indent + @as(u16, @intCast(fresh.len));
            writeStrRightAligned(surface, row, width, min_col, desc, desc_style);
        }
    }

    fn renderFrontmatterDefaultRows(self: *DocumentView, surface: vxfw.Surface, start_row: u16, width: u16, indent: u16, style: vaxis.Style) u16 {
        var row = start_row;
        var buf: [16][]const u8 = undefined;
        const n = self.sortedFrontmatterKeys(&buf);
        for (buf[0..n]) |name| {
            self.renderFrontmatterDefaultRow(surface, row, width, indent, name, style);
            row += 1;
        }
        return row;
    }

    fn renderFrontmatterHeader(self: *DocumentView, surface: vxfw.Surface, start_row: u16, width: u16) u16 {
        const err_row = self.renderSetupError(surface, start_row, width);
        const fm = self.frontmatter orelse return err_row;
        var row = err_row;

        const s: vaxis.Style = .{ .fg = .{ .index = 8 } };

        if (!self.verbose) {
            // Non-verbose: italic description, editable default rows (always
            // shown — they're interactive), then a thin separator.
            if (fm.description) |desc| {
                writeStr(surface, 0, row, desc, .{ .fg = .{ .index = 8 }, .italic = true });
                row += 1;
            }
            if (fm.variables.count() > 0) {
                row = self.renderFrontmatterDefaultRows(surface, row, width, 0, s);
            }
            if (fm.description != null or fm.variables.count() > 0) {
                writeFillRow(surface, row, width, "─", s);
                row += 1;
            }
            return row;
        }

        // Verbose: check there's something to show
        const has_content = fm.title != null or fm.description != null or
            fm.prerequisites.tools.len > 0 or fm.prerequisites.env.len > 0 or
            fm.variables.count() > 0;
        if (!has_content) return err_row;

        // Opening rule (no label)
        writeFillRow(surface, row, width, "─", s);
        row += 1;

        if (fm.title) |title| {
            writeStr(surface, 0, row, "title: ", s);
            writeStr(surface, 7, row, title, s);
            row += 1;
        }
        if (fm.description) |desc| {
            writeStr(surface, 0, row, "description: ", s);
            writeStr(surface, 13, row, desc, s);
            row += 1;
        }

        const has_tools = fm.prerequisites.tools.len > 0;
        const has_env = fm.prerequisites.env.len > 0;
        if (has_tools or has_env) {
            writeStr(surface, 0, row, "prerequisites:", s);
            row += 1;
            if (has_tools) {
                writeStr(surface, 2, row, "tools:", s);
                row += 1;
                for (fm.prerequisites.tools) |tool| {
                    writeStr(surface, 4, row, "- ", s);
                    writeStr(surface, 6, row, tool, s);
                    row += 1;
                }
            }
            if (has_env) {
                writeStr(surface, 2, row, "env:", s);
                row += 1;
                for (fm.prerequisites.env) |env| {
                    writeStr(surface, 4, row, "- ", s);
                    writeStr(surface, 6, row, env, s);
                    row += 1;
                }
            }
        }

        if (fm.variables.count() > 0) {
            writeStr(surface, 0, row, "variables:", s);
            row += 1;
            row = self.renderFrontmatterDefaultRows(surface, row, width, 2, s);
        }

        // Closing rule
        writeFillRow(surface, row, width, "─", s);
        row += 1;
        return row;
    }

    fn measureContent(self: *DocumentView, doc: *const md.Document, width: u16) usize {
        var total: usize = self.frontmatterHeaderHeight();
        var fence_idx: usize = 0;
        for (doc.blocks) |*block| {
            total += self.measureBlock(block, width, &fence_idx);
            total += 1; // blank line
        }
        return total;
    }

    fn measureBlock(self: *DocumentView, block: *const md.Block, width: u16, fence_idx: *usize) usize {
        return switch (block.*) {
            .heading => 1,
            .paragraph => |p| measureParagraphHeight(p.spans, width),
            .code_fence => |*cf| blk: {
                // Check if it's a TOC block
                if (std.mem.eql(u8, cf.lang, "toc")) {
                    for (self.toc_widgets.items) |*tw| {
                        if (tw.block == cf) break :blk tw.height();
                    }
                    break :blk 2; // fallback
                }
                // Find matching code fence widget
                for (self.code_fences.items, 0..) |*cfw_item, i| {
                    if (cfw_item.block == cf) {
                        fence_idx.* = i;
                        break :blk cfw_item.height(width);
                    }
                }
                break :blk countLines(cf.body) + 4;
            },
            .list => |l| measureListHeight(l.items),
            .table => |t| blk: {
                // header + header-sep + rows + (row-seps between rows)
                const n = t.rows.len;
                break :blk 2 + n + if (n > 0) n - 1 else 0;
            },
            .blockquote => |bq| blk: {
                var total: usize = 0;
                var sub_fence_idx: usize = 0;
                for (bq.blocks) |*sub| {
                    total += self.measureBlock(sub, if (width > 2) width - 2 else width, &sub_fence_idx);
                    total += 1; // blank line between sub-blocks
                }
                break :blk total;
            },
            .horizontal_rule => 1,
            .blank => 0,
        };
    }

    fn renderBlock(
        self: *DocumentView,
        arena: Allocator,
        surface: vxfw.Surface,
        block: *const md.Block,
        start_row: u16,
        width: u16,
        fence_idx: *usize,
    ) Allocator.Error!u16 {
        var row = start_row;
        const t = &theme.dark;

        switch (block.*) {
            .heading => |h| {
                const style = theme.headingStyle(t, h.level);
                const prefix: []const u8 = switch (h.level) {
                    1 => "# ",
                    2 => "## ",
                    3 => "### ",
                    4 => "#### ",
                    5 => "##### ",
                    else => "###### ",
                };
                writeStr(surface, 0, row, prefix, style);
                writeStr(surface, @intCast(prefix.len), row, h.text, style);
                row += 1;
            },
            .paragraph => |p| {
                row = try renderSpans(arena, surface, p.spans, row, 0, width);
            },
            .code_fence => |*cf| toc_or_fence: {
                // Check if it's a TOC block
                if (std.mem.eql(u8, cf.lang, "toc")) {
                    for (self.toc_widgets.items) |*tw| {
                        if (tw.block == cf) {
                            const child_ctx = vxfw.DrawContext{
                                .arena = arena,
                                .min = .{ .width = width, .height = 0 },
                                .max = .{ .width = width, .height = null },
                                .cell_size = .{ .width = 1, .height = 1 },
                            };
                            const child_surf = try tw.draw(child_ctx);
                            for (0..child_surf.size.height) |r| {
                                for (0..child_surf.size.width) |col| {
                                    if (row + @as(u16, @intCast(r)) >= surface.size.height) break;
                                    surface.writeCell(@intCast(col), @intCast(row + r), child_surf.readCell(col, r));
                                }
                            }
                            row += child_surf.size.height;
                            break :toc_or_fence;
                        }
                    }
                    break :toc_or_fence;
                }
                // Find matching widget
                for (self.code_fences.items, 0..) |*cfw, i| {
                    if (cfw.block == cf) {
                        fence_idx.* = i;
                        const child_ctx = vxfw.DrawContext{
                            .arena = arena,
                            .min = .{ .width = width, .height = 0 },
                            .max = .{ .width = width, .height = null },
                            .cell_size = .{ .width = 1, .height = 1 },
                        };
                        const child_surf = try cfw.draw(child_ctx);
                        // Blit child surface to parent
                        for (0..child_surf.size.height) |r| {
                            for (0..child_surf.size.width) |c| {
                                if (row + @as(u16, @intCast(r)) >= surface.size.height) break;
                                surface.writeCell(@intCast(c), @intCast(row + r), child_surf.readCell(c, r));
                            }
                        }
                        // Cell contents were just copied by hand above, which
                        // drops Surface.cursor — recover it here, translated
                        // into this call's (still-virtual, pre-scroll) row.
                        if (child_surf.cursor) |cur| {
                            self.pending_cursor = .{
                                .vrow = @as(u32, row) + cur.row,
                                .col = cur.col,
                                .shape = cur.shape,
                            };
                        }
                        row += child_surf.size.height;
                        break;
                    }
                } else {
                    // Non-executable code block
                    row = try renderPlainCodeFence(arena, surface, cf, row, width, t);
                }
            },
            .list => |l| {
                row = try renderList(arena, surface, l.items, l.ordered, row, 0, width, t);
            },
            .table => |tab| {
                row = renderTable(surface, &tab, row, width, t);
            },
            .blockquote => |bq| {
                const border_style: vaxis.Style = .{ .fg = t.blockquote_border };
                const inner_width: u16 = if (width > 2) width - 2 else width;
                for (bq.blocks) |*sub_block| {
                    const sub_h = self.measureBlock(sub_block, inner_width, fence_idx);
                    if (sub_h == 0) continue;
                    const clamped_h: u16 = @intCast(@min(sub_h, surface.size.height -| row));
                    if (clamped_h == 0) break;
                    const sub_surf = try vxfw.Surface.init(arena, self.widget(), .{ .width = inner_width, .height = clamped_h });
                    var tmp_fence_idx: usize = 0;
                    _ = try self.renderBlock(arena, sub_surf, sub_block, 0, inner_width, &tmp_fence_idx);
                    // Copy sub surface rows to parent, with border at col 0
                    for (0..sub_surf.size.height) |r| {
                        if (row >= surface.size.height) break;
                        writeStr(surface, 0, row, "│", border_style);
                        for (0..inner_width) |cc| {
                            const cell = sub_surf.readCell(cc, r);
                            surface.writeCell(@intCast(cc + 2), row, cell);
                        }
                        row += 1;
                    }
                }
            },
            .horizontal_rule => {
                const hr_style: vaxis.Style = .{ .fg = t.hr_fg };
                var c: u16 = 0;
                while (c < width) : (c += 1) {
                    surface.writeCell(c, row, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = hr_style });
                }
                row += 1;
            },
            .blank => {},
        }

        return row;
    }
};

fn renderPlainCodeFence(
    arena: Allocator,
    surface: vxfw.Surface,
    cf: *const md.CodeFence,
    start_row: u16,
    width: u16,
    t: *const theme.Theme,
) Allocator.Error!u16 {
    var row = start_row;
    const border_style: vaxis.Style = .{ .fg = t.unfocused_border };
    const tokens = try highlighter.tokenize(arena, cf.body, cf.lang);

    // Top border: ┌─...─┐
    writePlainBoxTop(surface, row, width, border_style);
    row += 1;

    var lines = std.mem.splitScalar(u8, cf.body, '\n');
    while (lines.next()) |line| {
        if (row >= surface.size.height) break;
        surface.writeCell(0, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border_style });
        const line_start = @intFromPtr(line.ptr) - @intFromPtr(cf.body.ptr);
        writeHighlightedStr(surface, 2, row, line, line_start, tokens, .{ .fg = t.code_fg });
        if (width >= 2) surface.writeCell(width - 1, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border_style });
        row += 1;
    }

    // Bottom border: └─...─┘
    writePlainBoxBottom(surface, row, width, border_style);
    row += 1;

    return row;
}

fn writeFillRow(surface: vxfw.Surface, row: u16, width: u16, grapheme: []const u8, style: vaxis.Style) void {
    for (0..width) |c| {
        surface.writeCell(@intCast(c), row, .{ .char = .{ .grapheme = grapheme, .width = 1 }, .style = style });
    }
}

fn writeBanner(surface: vxfw.Surface, row: u16, width: u16, label: []const u8, style: vaxis.Style) void {
    var c: u16 = 0;
    var it = std.unicode.Utf8Iterator{ .bytes = label, .i = 0 };
    while (it.nextCodepointSlice()) |g| {
        if (c >= width) break;
        surface.writeCell(c, row, .{ .char = .{ .grapheme = g, .width = 1 }, .style = style });
        c += 1;
    }
    while (c < width) : (c += 1) {
        surface.writeCell(c, row, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = style });
    }
}

fn writePlainBoxTop(surface: vxfw.Surface, row: u16, width: u16, style: vaxis.Style) void {
    if (width == 0) return;
    surface.writeCell(0, row, .{ .char = .{ .grapheme = "┌", .width = 1 }, .style = style });
    if (width >= 2) {
        for (1..width - 1) |col| {
            surface.writeCell(@intCast(col), row, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = style });
        }
        surface.writeCell(width - 1, row, .{ .char = .{ .grapheme = "┐", .width = 1 }, .style = style });
    }
}

fn writePlainBoxBottom(surface: vxfw.Surface, row: u16, width: u16, style: vaxis.Style) void {
    if (width == 0) return;
    surface.writeCell(0, row, .{ .char = .{ .grapheme = "└", .width = 1 }, .style = style });
    if (width >= 2) {
        for (1..width - 1) |col| {
            surface.writeCell(@intCast(col), row, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = style });
        }
        surface.writeCell(width - 1, row, .{ .char = .{ .grapheme = "┘", .width = 1 }, .style = style });
    }
}

fn renderSpans(
    arena: Allocator,
    surface: vxfw.Surface,
    spans: []const md.Span,
    start_row: u16,
    start_col: u16,
    width: u16,
) Allocator.Error!u16 {
    _ = arena;
    var row = start_row;
    var col = start_col;

    for (spans) |span| {
        col = renderSpan(surface, span, row, col, width, &row);
    }

    if (col > start_col) row += 1;
    return row;
}

fn renderSpan(
    surface: vxfw.Surface,
    span: md.Span,
    row_in: u16,
    col_in: u16,
    width: u16,
    row_out: *u16,
) u16 {
    var col = col_in;
    var row = row_in;
    const t = &theme.dark;

    switch (span) {
        .text => |text| {
            var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
            while (it.nextCodepointSlice()) |grapheme| {
                if (col >= width) {
                    col = 0;
                    row += 1;
                }
                if (row >= surface.size.height) break;
                surface.writeCell(col, row, .{
                    .char = .{ .grapheme = grapheme, .width = 1 },
                    .style = .{},
                });
                col += 1;
            }
        },
        .bold => |children| {
            for (children) |child| {
                col = renderSpanStyled(surface, child, row, col, width, &row, t.bold_style);
            }
        },
        .italic => |children| {
            for (children) |child| {
                col = renderSpanStyled(surface, child, row, col, width, &row, t.italic_style);
            }
        },
        .strikethrough => |children| {
            for (children) |child| {
                col = renderSpanStyled(surface, child, row, col, width, &row, t.strikethrough_style);
            }
        },
        .code => |text| {
            const code_style: vaxis.Style = .{ .fg = t.code_inline_fg };
            var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
            while (it.nextCodepointSlice()) |grapheme| {
                if (col >= width) {
                    col = 0;
                    row += 1;
                }
                if (row >= surface.size.height) break;
                surface.writeCell(col, row, .{
                    .char = .{ .grapheme = grapheme, .width = 1 },
                    .style = code_style,
                });
                col += 1;
            }
        },
        .link => |link| {
            // Render text with link color
            const link_style: vaxis.Style = .{ .fg = t.link_fg };
            var it = std.unicode.Utf8Iterator{ .bytes = link.text, .i = 0 };
            while (it.nextCodepointSlice()) |grapheme| {
                if (col >= width) {
                    col = 0;
                    row += 1;
                }
                if (row >= surface.size.height) break;
                surface.writeCell(col, row, .{
                    .char = .{ .grapheme = grapheme, .width = 1 },
                    .style = link_style,
                });
                col += 1;
            }
        },
    }

    row_out.* = row;
    return col;
}

fn renderSpanStyled(
    surface: vxfw.Surface,
    span: md.Span,
    row_in: u16,
    col_in: u16,
    width: u16,
    row_out: *u16,
    style: vaxis.Style,
) u16 {
    var col = col_in;
    var row = row_in;

    const text: []const u8 = switch (span) {
        .text => |t| t,
        .code => |t| t,
        .link => |l| l.text,
        else => "",
    };

    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (it.nextCodepointSlice()) |grapheme| {
        if (col >= width) {
            col = 0;
            row += 1;
        }
        if (row >= surface.size.height) break;
        surface.writeCell(col, row, .{
            .char = .{ .grapheme = grapheme, .width = 1 },
            .style = style,
        });
        col += 1;
    }

    row_out.* = row;
    return col;
}

fn renderList(
    arena: Allocator,
    surface: vxfw.Surface,
    items: []const md.ListItem,
    ordered: bool,
    start_row: u16,
    indent: u16,
    width: u16,
    t: *const theme.Theme,
) Allocator.Error!u16 {
    var row = start_row;
    for (items, 0..) |item, idx| {
        if (row >= surface.size.height) break;

        // Bullet or number — content starts 1 space after the marker
        const bullet_col = indent;
        var content_col: u16 = indent + 2; // default: 1-char bullet + 1 space

        if (ordered) {
            const n = std.fmt.allocPrint(arena, "{d}.", .{idx + 1}) catch "?";
            writeStr(surface, bullet_col, row, n, .{ .fg = t.list_bullet });
            content_col = indent + @as(u16, @intCast(n.len)) + 1;
        } else if (item.checked) |checked| {
            const checkbox = if (checked) "[✓]" else "[ ]";
            writeStr(surface, bullet_col, row, checkbox, .{ .fg = t.list_bullet });
            content_col = indent + 4; // 3-char checkbox + 1 space
        } else {
            writeStr(surface, bullet_col, row, "•", .{});
            content_col = indent + 2; // 1-char bullet + 1 space
        }

        // Content
        var row2 = row;
        var col: u16 = content_col;
        for (item.spans) |span| {
            col = renderSpan(surface, span, row, col, width, &row2);
        }
        row = @max(row, row2) + 1;

        // Children
        if (item.children.len > 0) {
            row = try renderList(arena, surface, item.children, item.children_ordered, row, indent + 2, width, t);
        }
    }
    return row;
}

fn renderTable(
    surface: vxfw.Surface,
    table: *const md.Table,
    start_row: u16,
    width: u16,
    t: *const theme.Theme,
) u16 {
    _ = width;
    var row = start_row;
    const border_style: vaxis.Style = .{ .fg = t.table_border };
    const header_style: vaxis.Style = .{ .bold = true };

    // Column inner widths (content only, without the surrounding "│ … │")
    var col_widths: [16]u16 = [_]u16{0} ** 16;
    const num_cols = @min(table.headers.len, 16);

    for (table.headers[0..num_cols], 0..) |h, c| {
        col_widths[c] = @max(col_widths[c], @as(u16, @intCast(h.len)));
    }
    for (table.rows) |data_row| {
        for (data_row, 0..) |cell, c| {
            if (c >= num_cols) break;
            col_widths[c] = @max(col_widths[c], @as(u16, @intCast(cell.len)));
        }
    }

    // Draw a horizontal rule line: left + (─×width + junction) × N-1 + ─×width + right
    const drawHRule = struct {
        fn run(
            sf: vxfw.Surface,
            r: u16,
            widths: *const [16]u16,
            nc: usize,
            mid: []const u8,
            bsty: vaxis.Style,
        ) void {
            var x: u16 = 0;
            for (0..nc) |c| {
                // col_width content + 2 for the " " padding on each side
                var di: u16 = 0;
                while (di < widths[c] + 2) : (di += 1) {
                    sf.writeCell(x, r, .{
                        .char = .{ .grapheme = "─", .width = 1 },
                        .style = bsty,
                    });
                    x += 1;
                }
                if (c < nc - 1) {
                    writeStr(sf, x, r, mid, bsty);
                    x += 1;
                }
            }
        }
    }.run;

    // Draw a data row: │ padded-cell │ … │
    const drawRow = struct {
        fn run(
            sf: vxfw.Surface,
            r: u16,
            widths: *const [16]u16,
            nc: usize,
            cells: []const []const u8,
            aligns: []const md.Align,
            sty: vaxis.Style,
            bsty: vaxis.Style,
        ) void {
            var x: u16 = 0;
            for (0..nc) |c| {
                const cell: []const u8 = if (c < cells.len) cells[c] else "";
                const col_w = widths[c];
                const cell_len: u16 = @intCast(cell.len);
                const cell_align: md.Align = if (c < aligns.len) aligns[c] else .none;

                // Compute left padding for alignment
                const slack: u16 = if (col_w > cell_len) col_w - cell_len else 0;
                const left_pad: u16 = switch (cell_align) {
                    .right => slack + 1,
                    .center => slack / 2 + 1,
                    else => 1, // left / none
                };

                // Write " "×left_pad + content + " "×right_pad + " "
                var px: u16 = 0;
                while (px < left_pad) : (px += 1) {
                    sf.writeCell(x, r, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = sty });
                    x += 1;
                }
                var ci: usize = 0;
                var it = std.unicode.Utf8Iterator{ .bytes = cell, .i = 0 };
                while (it.nextCodepointSlice()) |g| {
                    if (ci >= col_w) break;
                    sf.writeCell(x, r, .{ .char = .{ .grapheme = g, .width = 1 }, .style = sty });
                    x += 1;
                    ci += 1;
                }
                // Pad remaining to fill column + trailing space
                const written: u16 = @intCast(ci);
                var rp: u16 = written + left_pad;
                while (rp <= col_w + 1) : (rp += 1) {
                    sf.writeCell(x, r, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = sty });
                    x += 1;
                }

                // separator between columns; nothing after last column
                if (c < nc - 1) {
                    writeStr(sf, x, r, "│", bsty);
                    x += 1;
                }
            }
        }
    }.run;

    // Header row   Head  │  Head  │  Head
    drawRow(surface, row, &col_widths, num_cols, table.headers[0..num_cols], &.{}, header_style, border_style);
    row += 1;

    // Header separator    ──────┼──────┼──────
    drawHRule(surface, row, &col_widths, num_cols, "┼", border_style);
    row += 1;

    // Data rows, each separated by ──────┼──────
    for (table.rows, 0..) |data_row, ri| {
        drawRow(surface, row, &col_widths, num_cols, data_row, table.alignments, .{}, border_style);
        row += 1;
        if (ri + 1 < table.rows.len) {
            drawHRule(surface, row, &col_widths, num_cols, "┼", border_style);
            row += 1;
        }
    }

    return row;
}

fn measureParagraphHeight(spans: []const md.Span, width: u16) usize {
    var len: usize = 0;
    for (spans) |span| {
        len += spanTextLen(span);
    }
    if (len == 0) return 0;
    if (width == 0) return 1;
    return (len + width - 1) / width;
}

fn spanTextLen(span: md.Span) usize {
    return switch (span) {
        .text => |t| t.len,
        .bold => |children| blk: {
            var l: usize = 0;
            for (children) |c| l += spanTextLen(c);
            break :blk l;
        },
        .italic => |children| blk: {
            var l: usize = 0;
            for (children) |c| l += spanTextLen(c);
            break :blk l;
        },
        .strikethrough => |children| blk: {
            var l: usize = 0;
            for (children) |c| l += spanTextLen(c);
            break :blk l;
        },
        .code => |t| t.len,
        .link => |l| l.text.len,
    };
}

fn measureListHeight(items: []const md.ListItem) usize {
    var h: usize = 0;
    for (items) |item| {
        h += 1;
        h += measureListHeight(item.children);
    }
    return h;
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn countLines(text: []const u8) usize {
    var count: usize = 1;
    for (text) |c| {
        if (c == '\n') count += 1;
    }
    return count;
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
        if (c >= surface.size.width or row >= surface.size.height) break;
        surface.writeCell(c, row, .{
            .char = .{ .grapheme = grapheme, .width = 1 },
            .style = style,
        });
        c += 1;
    }
}

/// Writes `s` right-aligned in `row`, ending just before `right_edge`
/// (exclusive) and never starting before `min_col`, leaving at least one
/// column of gap. Truncates from the end when there isn't room for all of
/// `s`; renders nothing when there isn't room for even one column plus gap.
fn writeStrRightAligned(surface: vxfw.Surface, row: u16, right_edge: u16, min_col: u16, s: []const u8, style: vaxis.Style) void {
    const avail = (right_edge -| min_col) -| 1;
    if (avail == 0) return;

    var len: u16 = 0;
    var it = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    while (it.nextCodepointSlice()) |_| len += 1;
    const shown: u16 = @min(len, avail);
    if (shown == 0) return;

    const start_col = right_edge - shown;
    var it2 = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    var written: u16 = 0;
    while (it2.nextCodepointSlice()) |g| {
        if (written >= shown) break;
        surface.writeCell(start_col + written, row, .{ .char = .{ .grapheme = g, .width = 1 }, .style = style });
        written += 1;
    }
}

/// Shrinks an editable field's width to leave room for `description`
/// (rendered right-aligned via `writeStrRightAligned`) so it stays visible
/// while the field is focused, unless that would leave less than
/// `min_field_width` columns to actually edit in — in which case the field
/// keeps the full width and the description is dropped for this frame.
fn descriptionAwareFieldWidth(full_width: u16, description: ?[]const u8) u16 {
    const desc = description orelse return full_width;
    var desc_len: u16 = 0;
    var it = std.unicode.Utf8Iterator{ .bytes = desc, .i = 0 };
    while (it.nextCodepointSlice()) |_| desc_len += 1;
    if (desc_len == 0) return full_width;

    const reserve = desc_len + 1; // +1 gap column before the description
    const min_field_width: u16 = 4;
    if (full_width > reserve + min_field_width) return full_width - reserve;
    return full_width;
}
