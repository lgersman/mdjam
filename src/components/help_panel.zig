const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");

const Allocator = std.mem.Allocator;

const HELP_TITLE = " mdjam Help ";

// Scrollable body (everything below the title).
const HELP_BODY = [_][]const u8{
    "",
    " Navigation:",
    "   j / ↓       Scroll down",
    "   k / ↑       Scroll up",
    "   Space / PgDn  Page down",
    "   b / PgUp    Page up",
    "   g            Go to top",
    "   G            Go to bottom",
    "   Tab / S-Tab  Focus next/prev block or param",
    "",
    " Document variables (frontmatter):",
    "   Tab / S-Tab  Next/prev variable field",
    "   Enter        Save the value",
    "   Esc          Cancel edit",
    "",
    " Code blocks:",
    "   Enter        Execute focused block",
    "   Esc          Cancel running block",
    "   j/k          Scroll output",
    "",
    " Parameters (auto-focused on select):",
    "   Tab / S-Tab  Next/prev param, or next/prev block",
    "   Enter        Save and run the block",
    "   Esc          Cancel edit",
    "",
    " Mouse:",
    "   Click        Select a code block (auto-edits its first param)",
    "   Shift+drag   Select text (terminal-native)",
    "",
    " Panels:",
    "   ?            Toggle this help",
    "",
    " General:",
    "   r            Reload file",
    "   Ctrl+C       Quit",
};

// Rows always reserved outside the scrollable body: top border, title, footer, bottom border.
const CHROME_ROWS: u16 = 4;

pub const HelpPanel = struct {
    visible: bool,
    scroll: u16 = 0,

    pub fn widget(self: *HelpPanel) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *HelpPanel = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn scrollDown(self: *HelpPanel, amount: u16) void {
        self.scroll +|= amount;
    }

    pub fn scrollUp(self: *HelpPanel, amount: u16) void {
        self.scroll -|= amount;
    }

    pub fn scrollToTop(self: *HelpPanel) void {
        self.scroll = 0;
    }

    pub fn scrollToBottom(self: *HelpPanel) void {
        self.scroll = std.math.maxInt(u16);
    }

    pub fn draw(self: *HelpPanel, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        if (!self.visible) {
            return vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = 0, .height = 0 });
        }

        const panel_width: u16 = 50;
        const desired_height: u16 = @intCast(HELP_BODY.len + CHROME_ROWS);
        const avail_height: u16 = ctx.max.height orelse desired_height;
        const panel_height: u16 = @min(desired_height, @max(avail_height, CHROME_ROWS));
        const size: vxfw.Size = .{ .width = panel_width, .height = panel_height };
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);

        const bg = theme.dark.panel_bg;
        const border_fg = theme.dark.panel_border;
        const title_fg: vaxis.Color = .{ .rgb = .{ 0x61, 0xAF, 0xEF } };
        const text_fg: vaxis.Color = .{ .rgb = .{ 0xAB, 0xB2, 0xBF } };
        const dim_fg: vaxis.Color = .{ .index = 8 };

        // Fill
        for (0..panel_height) |row| {
            for (0..panel_width) |col| {
                surface.writeCell(@intCast(col), @intCast(row), .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = .{ .bg = bg },
                });
            }
        }

        // Box border
        drawBox(surface, 0, 0, panel_width, panel_height, border_fg, bg);

        // Title (fixed, row 1)
        writeStr(surface, 2, 1, HELP_TITLE, .{ .fg = title_fg, .bg = bg });

        // Scrollable body, rows [2, panel_height - 2)
        const visible_rows: u16 = panel_height -| CHROME_ROWS;
        const total_rows: u16 = @intCast(HELP_BODY.len);
        const max_scroll: u16 = total_rows -| visible_rows;
        if (self.scroll > max_scroll) self.scroll = max_scroll;

        for (0..visible_rows) |i| {
            const idx = self.scroll + @as(u16, @intCast(i));
            if (idx >= total_rows) break;
            const line = HELP_BODY[idx];
            const row: u16 = 2 + @as(u16, @intCast(i));
            const fg = if (line.len > 0 and line[line.len - 1] == ':')
                title_fg
            else if (std.mem.startsWith(u8, line, "   "))
                text_fg
            else
                dim_fg;

            writeStr(surface, 2, row, line, .{ .fg = fg, .bg = bg });
        }

        // Footer (fixed, second-to-last row)
        if (panel_height >= CHROME_ROWS) {
            const footer_row = panel_height - 2;
            const footer: []const u8 = if (max_scroll > 0)
                "j/k or ↑/↓ scroll   Esc close"
            else
                "Press Esc to close";
            writeStr(surface, 2, footer_row, footer, .{ .fg = dim_fg, .bg = bg });
        }

        return surface;
    }
};

fn drawBox(surface: vxfw.Surface, x: u16, y: u16, w: u16, h: u16, fg: vaxis.Color, bg: vaxis.Color) void {
    const style: vaxis.Style = .{ .fg = fg, .bg = bg };

    // Top/bottom borders
    for (1..w - 1) |col| {
        surface.writeCell(@intCast(x + col), y, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = style });
        surface.writeCell(@intCast(x + col), y + h - 1, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = style });
    }
    // Left/right borders
    for (1..h - 1) |row| {
        surface.writeCell(x, @intCast(y + row), .{ .char = .{ .grapheme = "│", .width = 1 }, .style = style });
        surface.writeCell(x + w - 1, @intCast(y + row), .{ .char = .{ .grapheme = "│", .width = 1 }, .style = style });
    }
    // Corners
    surface.writeCell(x, y, .{ .char = .{ .grapheme = "┌", .width = 1 }, .style = style });
    surface.writeCell(x + w - 1, y, .{ .char = .{ .grapheme = "┐", .width = 1 }, .style = style });
    surface.writeCell(x, y + h - 1, .{ .char = .{ .grapheme = "└", .width = 1 }, .style = style });
    surface.writeCell(x + w - 1, y + h - 1, .{ .char = .{ .grapheme = "┘", .width = 1 }, .style = style });
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
