const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const md = @import("../parser/markdown.zig");

const Allocator = std.mem.Allocator;

pub const HeadingEntry = struct {
    depth: u8,
    text: []const u8,
    block_idx: usize, // index in doc.blocks[]
};

pub const TocWidget = struct {
    allocator: Allocator,
    headings: []HeadingEntry,
    selected: usize,
    scroll: usize,
    focused: bool,
    /// The code fence block that this TOC widget corresponds to
    block: *const md.CodeFence,
    // Callback: set this to scroll the document
    on_select: ?*const fn (ctx: ?*anyopaque, block_idx: usize) void,
    on_select_ctx: ?*anyopaque,

    pub fn init(allocator: Allocator, doc: *const md.Document, block: *const md.CodeFence) Allocator.Error!TocWidget {
        var entries = std.ArrayList(HeadingEntry).empty;
        for (doc.blocks, 0..) |*blk, i| {
            switch (blk.*) {
                .heading => |h| try entries.append(allocator, .{
                    .depth = h.level,
                    .text = h.text,
                    .block_idx = i,
                }),
                else => {},
            }
        }
        return .{
            .allocator = allocator,
            .headings = try entries.toOwnedSlice(allocator),
            .selected = 0,
            .scroll = 0,
            .focused = false,
            .block = block,
            .on_select = null,
            .on_select_ctx = null,
        };
    }

    pub fn deinit(self: *TocWidget) void {
        self.allocator.free(self.headings);
    }

    pub fn widget(self: *TocWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *TocWidget = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *TocWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn handleEvent(self: *TocWidget, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .focus_in => { self.focused = true; ctx.redraw = true; },
            .focus_out => { self.focused = false; ctx.redraw = true; },
            .key_press => |key| {
                if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
                    if (self.selected > 0) self.selected -= 1;
                    ctx.consumeAndRedraw();
                } else if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
                    if (self.selected + 1 < self.headings.len) self.selected += 1;
                    ctx.consumeAndRedraw();
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    if (self.headings.len > 0) {
                        if (self.on_select) |cb| {
                            cb(self.on_select_ctx, self.headings[self.selected].block_idx);
                        }
                    }
                    ctx.consumeAndRedraw();
                }
            },
            else => {},
        }
    }

    pub fn height(self: *const TocWidget) u16 {
        // 2 borders + entries (max 10 visible)
        return @intCast(2 + @min(self.headings.len, 10));
    }

    pub fn draw(self: *TocWidget, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const width = ctx.max.width orelse 80;
        const h = self.height();
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = h });

        const border_fg: vaxis.Color = if (self.focused) .{ .index = 6 } else .{ .index = 8 };

        // Top border with "toc" label
        for (0..width) |col| {
            surface.writeCell(@intCast(col), 0, .{
                .char = .{ .grapheme = "─", .width = 1 },
                .style = .{ .fg = border_fg },
            });
        }
        writeStr(surface, 1, 0, " toc ", .{ .fg = .{ .rgb = .{ 0xE5, 0xC0, 0x7B } } });

        // Heading entries
        const visible: usize = h - 2;
        // Adjust scroll so selected is in view
        if (self.selected < self.scroll) {
            self.scroll = self.selected;
        } else if (self.selected >= self.scroll + visible) {
            self.scroll = self.selected - visible + 1;
        }

        for (0..visible) |i| {
            const idx = self.scroll + i;
            if (idx >= self.headings.len) break;
            const entry = self.headings[idx];
            const row: u16 = @intCast(i + 1);
            const is_selected = idx == self.selected and self.focused;

            const fg: vaxis.Color = switch (entry.depth) {
                1 => .{ .rgb = .{ 0xE0, 0x6C, 0x75 } },
                2 => .{ .rgb = .{ 0xE5, 0xC0, 0x7B } },
                3 => .{ .rgb = .{ 0x98, 0xC3, 0x79 } },
                else => .{ .index = 7 },
            };
            const style: vaxis.Style = .{ .fg = fg, .bold = is_selected, .reverse = is_selected };

            // Indent by depth
            var col: u16 = 2 * (entry.depth - 1);
            if (is_selected) {
                writeStr(surface, col, row, "▶ ", .{ .fg = fg, .bold = true });
                col += 2;
            } else {
                writeStr(surface, col, row, "  ", .{});
                col += 2;
            }
            writeStr(surface, col, row, entry.text, style);
        }

        // Bottom border
        for (0..width) |col| {
            surface.writeCell(@intCast(col), h - 1, .{
                .char = .{ .grapheme = "─", .width = 1 },
                .style = .{ .fg = border_fg },
            });
        }

        return surface;
    }
};

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
