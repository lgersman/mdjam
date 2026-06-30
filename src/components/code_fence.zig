const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const md = @import("../parser/markdown.zig");
const block_runner = @import("../engine/block_runner.zig");
const state_store = @import("../engine/state_store.zig");

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
    output_lines: std.ArrayList(OutputLine),
    output_scroll: usize,
    runner: block_runner.Runner,
    runner_thread: ?std.Thread,

    // Redraw notification (set by callback, polled by app)
    needs_redraw: bool,

    // Optional suspend/resume callbacks for interactive blocks
    suspend_fn: ?block_runner.SuspendFn,
    resume_fn: ?block_runner.ResumeFn,
    suspend_ctx: ?*anyopaque,

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
    ) Allocator.Error!CodeFenceWidget {
        return .{
            .allocator = allocator,
            .block = block,
            .store = store,
            .environ_map = environ_map,
            .io = io,
            .focused = false,
            .status = .idle,
            .output_lines = std.ArrayList(OutputLine).empty,
            .output_scroll = 0,
            .runner = block_runner.Runner.init(),
            .runner_thread = null,
            .needs_redraw = false,
            .suspend_fn = null,
            .resume_fn = null,
            .suspend_ctx = null,
        };
    }

    pub fn deinit(self: *CodeFenceWidget) void {
        if (self.runner_thread) |t| t.detach();
        for (self.output_lines.items) |line| self.allocator.free(line.text);
        self.output_lines.deinit(self.allocator);
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
                if (key.matches(vaxis.Key.enter, .{})) {
                    if (self.status != .running) {
                        try self.startExecution();
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

    pub fn startExecution(self: *CodeFenceWidget) !void {
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
        self.needs_redraw = true;
        // ctx_ptr is destroyed here; allocator is still valid because App owns it
        exec_ctx.widget.allocator.destroy(exec_ctx);
    }

    pub fn height(self: *const CodeFenceWidget, width: u16) u16 {
        _ = width;
        var h: u16 = 0;

        // Description line
        if (self.block.metadata) |meta| {
            if (meta.description != null) h += 1;
        }

        // Code lines
        var code_lines: u16 = 0;
        var it = std.mem.splitScalar(u8, self.block.body, '\n');
        while (it.next()) |_| code_lines += 1;
        h += code_lines + 2; // +2 for top/bottom border

        // Status bar
        h += 1;

        // Output area (if any)
        if (self.output_lines.items.len > 0) {
            h += @intCast(@min(self.output_lines.items.len, 10) + 1);
        }

        return @max(h, 4);
    }

    pub fn draw(self: *CodeFenceWidget, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const width = ctx.max.width orelse 80;
        const h = self.height(width);
        const size: vxfw.Size = .{ .width = width, .height = h };
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);

        const bg = theme.dark.code_bg;
        const code_fg = theme.dark.code_fg;
        const border_fg = if (self.focused) theme.dark.focused_border else theme.dark.unfocused_border;

        // Fill background
        for (0..h) |row| {
            for (0..width) |col| {
                surface.writeCell(@intCast(col), @intCast(row), .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = .{ .bg = bg },
                });
            }
        }

        var row: u16 = 0;

        // Description
        if (self.block.metadata) |meta| {
            if (meta.description) |desc| {
                const desc_style: vaxis.Style = .{ .fg = .{ .index = 8 }, .italic = true, .bg = bg };
                writeStr(surface, 2, row, "# ", desc_style);
                writeStr(surface, 4, row, desc, desc_style);
                row += 1;
            }
        }

        // Top border with language label
        const lang_label = self.block.lang;
        writeBorder(surface, 0, row, width, border_fg, bg);
        if (lang_label.len > 0) {
            writeStr(surface, 2, row, " ", .{ .fg = border_fg, .bg = bg });
            writeStr(surface, 3, row, lang_label, .{ .fg = .{ .rgb = .{ 0xE5, 0xC0, 0x7B } }, .bg = bg });
            writeStr(surface, @intCast(3 + lang_label.len), row, " ", .{ .fg = border_fg, .bg = bg });
        }
        row += 1;

        // Code body
        var code_it = std.mem.splitScalar(u8, self.block.body, '\n');
        while (code_it.next()) |code_line| {
            if (row >= h - 1) break;
            writeStr(surface, 2, row, code_line, .{ .fg = code_fg, .bg = bg });
            row += 1;
        }

        // Bottom border
        if (row < h) {
            writeBorder(surface, 0, row, width, border_fg, bg);
            row += 1;
        }

        // Status bar
        if (row < h) {
            const status_text = statusText(self.status);
            const status_style = statusStyle(self.status);
            writeStr(surface, 0, row, " [", .{ .fg = .{ .index = 8 }, .bg = bg });
            writeStr(surface, 2, row, status_text, status_style);
            writeStr(surface, @intCast(2 + status_text.len), row, "]", .{ .fg = .{ .index = 8 }, .bg = bg });
            row += 1;
        }

        // Output area
        if (self.output_lines.items.len > 0 and row < h) {
            const out_style: vaxis.Style = .{ .fg = .{ .index = 8 }, .bg = bg };
            writeStr(surface, 0, row, " ─── output ────────────────────────────────────────────", out_style);
            row += 1;

            const max_display: usize = @min(self.output_lines.items.len -| self.output_scroll, h -| row);
            for (0..max_display) |i| {
                if (row >= h) break;
                const line = self.output_lines.items[self.output_scroll + i];
                const out_line_style: vaxis.Style = .{
                    .fg = if (line.is_stderr) .{ .rgb = .{ 0xE0, 0x6C, 0x75 } } else code_fg,
                    .bg = bg,
                };
                writeStr(surface, 2, row, line.text, out_line_style);
                row += 1;
            }
        }

        return surface;
    }
};

fn statusText(status: block_runner.RunStatus) []const u8 {
    return switch (status) {
        .idle => "idle",
        .running => "running...",
        .done => "done",
        .failed => "failed",
        .cancelled => "cancelled",
        .blocked => "blocked",
    };
}

fn statusStyle(status: block_runner.RunStatus) vaxis.Style {
    return switch (status) {
        .idle => theme.dark.status_idle,
        .running => theme.dark.status_running,
        .done => theme.dark.status_done,
        .failed => theme.dark.status_failed,
        .cancelled => theme.dark.status_failed,
        .blocked => theme.dark.status_blocked,
    };
}

fn writeBorder(surface: vxfw.Surface, x: u16, y: u16, width: u16, fg: vaxis.Color, bg: vaxis.Color) void {
    const style: vaxis.Style = .{ .fg = fg, .bg = bg };
    for (0..width) |col| {
        surface.writeCell(@intCast(x + col), y, .{
            .char = .{ .grapheme = "─", .width = 1 },
            .style = style,
        });
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

