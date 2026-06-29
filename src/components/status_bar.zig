const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");

const Allocator = std.mem.Allocator;

pub const StatusBar = struct {
    hints: []const u8,

    pub fn widget(self: *const StatusBar) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *const StatusBar = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn draw(self: *const StatusBar, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const width = ctx.max.width orelse 80;
        const height: u16 = 1;
        const size: vxfw.Size = .{ .width = width, .height = height };
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);

        const bg = theme.dark.status_bar_bg;
        const fg = theme.dark.status_bar_fg;

        // Fill background
        for (0..width) |col| {
            surface.writeCell(@intCast(col), 0, .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = .{ .fg = fg, .bg = bg },
            });
        }

        // Write hints text
        var col: u16 = 1;
        var it = std.unicode.Utf8Iterator{ .bytes = self.hints, .i = 0 };
        while (it.nextCodepointSlice()) |grapheme| {
            if (col >= width) break;
            surface.writeCell(col, 0, .{
                .char = .{ .grapheme = grapheme, .width = 1 },
                .style = .{ .fg = fg, .bg = bg },
            });
            col += 1;
        }

        return surface;
    }
};

pub const DEFAULT_HINTS = "j/k: scroll  g/G: top/bot  Tab: next  Enter: run  s: state  ?: help  r: reload  Ctrl+C: quit";
pub const RUNNING_HINTS = "Esc: cancel output  j/k: scroll output  Ctrl+C: quit";
