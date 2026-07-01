const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");

const Allocator = std.mem.Allocator;

const HELP_LINES = [_][]const u8{
    " mdjam — Markdown Jam Runner ",
    "",
    " Navigation:",
    "   j / ↓       Scroll down",
    "   k / ↑       Scroll up",
    "   Space / PgDn  Page down",
    "   b / PgUp    Page up",
    "   g            Go to top",
    "   G            Go to bottom",
    "   Tab          Focus next code block",
    "",
    " Code blocks:",
    "   Enter        Execute focused block",
    "   Esc          Cancel running block",
    "   j/k          Scroll output",
    "",
    " Panels:",
    "   ?            Toggle this help",
    "",
    " General:",
    "   r            Reload file",
    "   Ctrl+C / q   Quit",
    "",
    "   Press ? to close",
};

pub const HelpPanel = struct {
    visible: bool,

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

    pub fn draw(self: *HelpPanel, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        if (!self.visible) {
            return vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = 0, .height = 0 });
        }

        const panel_width: u16 = 50;
        const panel_height: u16 = @intCast(HELP_LINES.len + 2);
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

        // Lines
        var row: u16 = 1;
        for (HELP_LINES) |line| {
            if (row >= panel_height - 1) break;
            const fg = if (row == 1)
                title_fg
            else if (line.len > 0 and line[line.len - 1] == ':')
                title_fg
            else if (std.mem.startsWith(u8, line, "   "))
                text_fg
            else
                dim_fg;

            writeStr(surface, 2, row, line, .{ .fg = fg, .bg = bg });
            row += 1;
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
