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

const Allocator = std.mem.Allocator;

pub const DocumentView = struct {
    allocator: Allocator,
    document: ?*const md.Document,
    store: *state_store.StateStore,
    environ_map: *const std.process.Environ.Map,
    io: std.Io,

    verbose: bool,
    scroll_offset: u32,
    focused_block: ?usize, // index into code_fences; null = no block focused
    code_fences: std.ArrayList(CodeFenceWidget),
    toc_widgets: std.ArrayList(TocWidget),
    terminal_width: u16,
    terminal_height: u16,

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
            .scroll_offset = 0,
            .focused_block = null,
            .code_fences = std.ArrayList(CodeFenceWidget).empty,
            .toc_widgets = std.ArrayList(TocWidget).empty,
            .terminal_width = 80,
            .terminal_height = 24,
            .suspend_fn = null,
            .resume_fn = null,
            .suspend_ctx = null,
        };
    }

    pub fn deinit(self: *DocumentView) void {
        for (self.code_fences.items) |*cf| cf.deinit();
        self.code_fences.deinit(self.allocator);
        for (self.toc_widgets.items) |*tw| tw.deinit();
        self.toc_widgets.deinit(self.allocator);
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

        // Focus first code fence
        if (self.code_fences.items.len > 0) {
            self.focused_block = 0;
            self.code_fences.items[0].focused = true;
        }
    }

    pub fn focusNextBlock(self: *DocumentView) void {
        if (self.code_fences.items.len == 0) return;
        if (self.focused_block) |fb| {
            self.code_fences.items[fb].focused = false;
            self.focused_block = (fb + 1) % self.code_fences.items.len;
        } else {
            self.focused_block = 0;
        }
        self.code_fences.items[self.focused_block.?].focused = true;
    }

    pub fn focusPrevBlock(self: *DocumentView) void {
        if (self.code_fences.items.len == 0) return;
        if (self.focused_block) |fb| {
            self.code_fences.items[fb].focused = false;
            self.focused_block = if (fb == 0) self.code_fences.items.len - 1 else fb - 1;
        } else {
            self.focused_block = self.code_fences.items.len - 1;
        }
        self.code_fences.items[self.focused_block.?].focused = true;
    }

    pub fn deselect(self: *DocumentView) void {
        if (self.focused_block) |fb| {
            self.code_fences.items[fb].focused = false;
            self.focused_block = null;
        }
    }

    pub fn runFocusedBlock(self: *DocumentView) anyerror!void {
        const fb = self.focused_block orelse return;
        const cf = &self.code_fences.items[fb];
        if (cf.status != .running) {
            try self.executeWithDeps(cf);
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

    pub fn executeWithDeps(self: *DocumentView, target: *CodeFenceWidget) !void {
        // Collect dependency chain in execution order
        var order = std.ArrayList(*CodeFenceWidget).empty;
        defer order.deinit(self.allocator);

        try self.collectDeps(target, &order, 0);

        for (order.items) |fence| {
            if (fence.status == .done) continue; // already succeeded
            if (fence.status == .running) continue;
            fence.startExecution() catch {};
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
                } else if (key.matches('g', .{})) {
                    self.scroll_offset = 0;
                    ctx.consumeAndRedraw();
                } else if (key.matches('G', .{})) {
                    // Scroll to bottom - we'll just set a large value and clamp when drawing
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
                            try self.executeWithDeps(cf);
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
        const width = ctx.max.width orelse 80;
        const height = ctx.max.height orelse 24;

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
        var vrow: u16 = 0;

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

        const output_surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });

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

        return output_surface;
    }

    fn measureContent(self: *DocumentView, doc: *const md.Document, width: u16) usize {
        var total: usize = 0;
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
                if (col >= width) { col = 0; row += 1; }
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
                if (col >= width) { col = 0; row += 1; }
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
        if (col >= width) { col = 0; row += 1; }
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
                    else => 1,  // left / none
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
    if (width == 0) return 1;
    return (len + width - 1) / width + 1;
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
        .code => |t| t.len + 2,
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
