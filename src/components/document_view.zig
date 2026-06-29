const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const md = @import("../parser/markdown.zig");
const CodeFenceWidget = @import("code_fence.zig").CodeFenceWidget;
const state_store = @import("../engine/state_store.zig");

const Allocator = std.mem.Allocator;

pub const DocumentView = struct {
    allocator: Allocator,
    document: ?*const md.Document,
    store: *state_store.StateStore,
    environ_map: *const std.process.Environ.Map,
    io: std.Io,

    scroll_offset: u32,
    focused_block: usize, // index into code_fences
    code_fences: std.ArrayList(CodeFenceWidget),
    terminal_width: u16,
    terminal_height: u16,

    pub fn init(
        allocator: Allocator,
        store: *state_store.StateStore,
        environ_map: *const std.process.Environ.Map,
        io: std.Io,
    ) DocumentView {
        return .{
            .allocator = allocator,
            .document = null,
            .store = store,
            .environ_map = environ_map,
            .io = io,
            .scroll_offset = 0,
            .focused_block = 0,
            .code_fences = std.ArrayList(CodeFenceWidget).empty,
            .terminal_width = 80,
            .terminal_height = 24,
        };
    }

    pub fn deinit(self: *DocumentView) void {
        for (self.code_fences.items) |*cf| cf.deinit();
        self.code_fences.deinit(self.allocator);
    }

    pub fn setDocument(self: *DocumentView, doc: *const md.Document) Allocator.Error!void {
        // Deinit existing code fences
        for (self.code_fences.items) |*cf| cf.deinit();
        self.code_fences.clearRetainingCapacity();

        self.document = doc;
        self.scroll_offset = 0;
        self.focused_block = 0;

        // Create code fence widgets for executable blocks
        for (doc.blocks) |*block| {
            switch (block.*) {
                .code_fence => |*cf| {
                    // Only create widgets for bash blocks or blocks with metadata
                    const is_executable = std.mem.eql(u8, cf.lang, "bash") or
                        std.mem.eql(u8, cf.lang, "sh") or
                        (cf.metadata != null);
                    if (is_executable) {
                        const cfw = try CodeFenceWidget.init(
                            self.allocator,
                            cf,
                            self.store,
                            self.environ_map,
                            self.io,
                        );
                        try self.code_fences.append(self.allocator, cfw);
                    }
                },
                else => {},
            }
        }

        // Focus first code fence
        if (self.code_fences.items.len > 0) {
            self.code_fences.items[0].focused = true;
        }
    }

    pub fn focusNextBlock(self: *DocumentView) void {
        if (self.code_fences.items.len == 0) return;
        self.code_fences.items[self.focused_block].focused = false;
        self.focused_block = (self.focused_block + 1) % self.code_fences.items.len;
        self.code_fences.items[self.focused_block].focused = true;
    }

    pub fn runFocusedBlock(self: *DocumentView) anyerror!void {
        if (self.code_fences.items.len == 0) return;
        const cf = &self.code_fences.items[self.focused_block];
        if (cf.status != .running) {
            try cf.startExecution();
        }
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
                } else if (key.matches(vaxis.Key.tab, .{})) {
                    self.focusNextBlock();
                    ctx.consumeAndRedraw();
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    if (self.code_fences.items.len > 0) {
                        const cf = &self.code_fences.items[self.focused_block];
                        try cf.handleEvent(ctx, event);
                    }
                } else if (key.matches(vaxis.Key.escape, .{})) {
                    if (self.code_fences.items.len > 0) {
                        const cf = &self.code_fences.items[self.focused_block];
                        try cf.handleEvent(ctx, event);
                    }
                } else {
                    // Pass to focused code fence
                    if (self.code_fences.items.len > 0) {
                        const cf = &self.code_fences.items[self.focused_block];
                        try cf.handleEvent(ctx, event);
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
            .table => |t| t.rows.len + 3,
            .blockquote => |bq| countLines(bq.content) + 2,
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
            .code_fence => |*cf| {
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
                    row = renderPlainCodeFence(surface, cf, row, width, t);
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
                const content_style: vaxis.Style = .{ .fg = t.blockquote_fg };
                var lines = std.mem.splitScalar(u8, bq.content, '\n');
                while (lines.next()) |line| {
                    if (row >= surface.size.height) break;
                    writeStr(surface, 0, row, "│ ", border_style);
                    writeStr(surface, 2, row, line, content_style);
                    row += 1;
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
    surface: vxfw.Surface,
    cf: *const md.CodeFence,
    start_row: u16,
    width: u16,
    t: *const theme.Theme,
) u16 {
    var row = start_row;
    const bg = t.code_bg;
    const code_fg = t.code_fg;

    // Fill with background
    for (0..width) |c| {
        surface.writeCell(@intCast(c), row, .{
            .char = .{ .grapheme = "─", .width = 1 },
            .style = .{ .fg = t.unfocused_border, .bg = bg },
        });
    }
    if (cf.lang.len > 0) {
        writeStr(surface, 1, row, cf.lang, .{ .fg = .{ .rgb = .{ 0xE5, 0xC0, 0x7B } }, .bg = bg });
    }
    row += 1;

    var lines = std.mem.splitScalar(u8, cf.body, '\n');
    while (lines.next()) |line| {
        if (row >= surface.size.height) break;
        for (0..width) |c| {
            surface.writeCell(@intCast(c), row, .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = .{ .bg = bg },
            });
        }
        writeStr(surface, 2, row, line, .{ .fg = code_fg, .bg = bg });
        row += 1;
    }

    for (0..width) |c| {
        surface.writeCell(@intCast(c), row, .{
            .char = .{ .grapheme = "─", .width = 1 },
            .style = .{ .fg = t.unfocused_border, .bg = bg },
        });
    }
    row += 1;

    return row;
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

        // Bullet or number
        const bullet_col = indent;
        const content_col = indent + 3;

        if (ordered) {
            var buf: [8]u8 = undefined;
            const n = std.fmt.bufPrint(&buf, "{d}.", .{idx + 1}) catch "?";
            writeStr(surface, bullet_col, row, n, .{ .fg = t.list_bullet });
        } else if (item.checked) |checked| {
            const checkbox = if (checked) "[x]" else "[ ]";
            writeStr(surface, bullet_col, row, checkbox, .{ .fg = t.list_bullet });
        } else {
            writeStr(surface, bullet_col, row, "•", .{ .fg = t.list_bullet });
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
            row = try renderList(arena, surface, item.children, false, row, indent + 2, width, t);
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

    // Calculate column widths
    var col_widths: [16]u16 = [_]u16{0} ** 16;
    const num_cols = @min(table.headers.len, 16);

    for (table.headers[0..num_cols], 0..) |h, c| {
        col_widths[c] = @max(col_widths[c], @as(u16, @intCast(h.len)) + 2);
    }
    for (table.rows) |data_row| {
        for (data_row, 0..) |cell, c| {
            if (c >= num_cols) break;
            col_widths[c] = @max(col_widths[c], @as(u16, @intCast(cell.len)) + 2);
        }
    }

    // Header
    var cc: u16 = 0;
    for (table.headers[0..num_cols], 0..) |h, c| {
        writeStr(surface, cc, row, "│ ", border_style);
        writeStr(surface, cc + 2, row, h, header_style);
        cc += col_widths[c];
    }
    writeStr(surface, cc, row, "│", border_style);
    row += 1;

    // Separator
    cc = 0;
    for (0..num_cols) |c| {
        writeStr(surface, cc, row, "├", border_style);
        var i: u16 = 0;
        while (i < col_widths[c]) : (i += 1) {
            surface.writeCell(cc + 1 + i, row, .{
                .char = .{ .grapheme = "─", .width = 1 },
                .style = border_style,
            });
        }
        cc += col_widths[c] + 1;
    }
    writeStr(surface, cc, row, "┤", border_style);
    row += 1;

    // Data rows
    for (table.rows) |data_row| {
        cc = 0;
        for (data_row, 0..) |cell, c| {
            if (c >= num_cols) break;
            writeStr(surface, cc, row, "│ ", border_style);
            writeStr(surface, cc + 2, row, cell, .{});
            cc += col_widths[c];
        }
        writeStr(surface, cc, row, "│", border_style);
        row += 1;
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
