const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const state_store = @import("../engine/state_store.zig");

const Allocator = std.mem.Allocator;

pub const StatePanel = struct {
    store: *state_store.StateStore,
    visible: bool,

    pub fn widget(self: *StatePanel) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *StatePanel = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn draw(self: *StatePanel, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        if (!self.visible) {
            return vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = 0, .height = 0 });
        }

        const panel_width: u16 = 40;
        const height = ctx.max.height orelse 24;
        const size: vxfw.Size = .{ .width = panel_width, .height = height };
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);

        const bg = theme.dark.panel_bg;
        const border_fg = theme.dark.panel_border;
        const key_fg: vaxis.Color = .{ .rgb = .{ 0x61, 0xAF, 0xEF } };
        const val_fg: vaxis.Color = .{ .rgb = .{ 0xAB, 0xB2, 0xBF } };

        // Fill background
        for (0..height) |row| {
            for (0..panel_width) |col| {
                surface.writeCell(@intCast(col), @intCast(row), .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = .{ .bg = bg },
                });
            }
        }

        // Draw left border
        for (0..height) |row| {
            surface.writeCell(0, @intCast(row), .{
                .char = .{ .grapheme = "│", .width = 1 },
                .style = .{ .fg = border_fg, .bg = bg },
            });
        }

        // Title
        writeStr(surface, 2, 0, " State Store ", .{ .fg = .{ .index = 7 }, .bg = bg, .bold = true });

        var row: u16 = 2;

        // Get all entries
        const entries = self.store.getAll(ctx.arena) catch &.{};
        // Note: entries are allocated from arena, so no need to free

        if (entries.len == 0) {
            writeStr(surface, 2, row, "(empty)", .{ .fg = .{ .index = 8 }, .bg = bg });
        } else {
            for (entries) |kv| {
                if (row >= height - 1) break;

                // Key
                const max_key_len: usize = @min(kv.key.len, panel_width / 2 - 2);
                writeStr(surface, 2, row, kv.key[0..max_key_len], .{ .fg = key_fg, .bg = bg });
                writeStr(surface, @intCast(2 + max_key_len), row, "=", .{ .fg = .{ .index = 8 }, .bg = bg });

                // Value
                const val_start = 2 + max_key_len + 1;
                const max_val_len: usize = @min(kv.value.len, panel_width -| val_start - 1);
                if (val_start < panel_width) {
                    writeStr(surface, @intCast(val_start), row, kv.value[0..max_val_len], .{ .fg = val_fg, .bg = bg });
                }

                row += 1;
            }
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
