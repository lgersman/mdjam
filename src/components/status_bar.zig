const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const CodeFenceWidget = @import("code_fence.zig").CodeFenceWidget;
const block_runner = @import("../engine/block_runner.zig");

const Allocator = std.mem.Allocator;

pub const Context = enum {
    markdown, // no block focused — show scroll/nav hints
    codeblock, // a code block is focused
    running, // a block is actively executing
    editing_input, // an input field is being edited
};

// Braille-dot spinner frames for the "running" badge, advanced once per tick
// (~80ms while a block is executing — see App's tick handler).
const SPINNER_FRAMES = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

pub const StatusBar = struct {
    focused_fence: ?*CodeFenceWidget,
    context: Context,
    // One-shot message shown in place of the key hints (e.g. "Already at the
    // last block"); set by DocumentView.boundary_hint, cleared on the next key.
    boundary_hint: ?[]const u8,
    spinner_frame: u8,

    pub fn init() StatusBar {
        return .{ .focused_fence = null, .context = .markdown, .boundary_hint = null, .spinner_frame = 0 };
    }

    pub fn setFocusedFence(self: *StatusBar, fence: ?*CodeFenceWidget) void {
        self.focused_fence = fence;
        self.context = contextFor(fence);
    }

    pub fn update(self: *StatusBar) void {
        if (self.focused_fence) |f| {
            self.context = contextFor(f);
        }
        self.spinner_frame +%= 1;
    }

    pub fn widget(self: *StatusBar) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *StatusBar = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn draw(self: *StatusBar, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const width = ctx.max.width orelse 80;
        const size: vxfw.Size = .{ .width = width, .height = 1 };
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

        // Left side: status badge when a block is focused and there's something
        // worth reporting (idle and auto-run "done" results are hidden).
        var left_len: u16 = 0;
        if (self.focused_fence) |fence| {
            if (shouldShowBadge(fence)) {
                const status_text = statusText(self, fence.status);
                const status_style = vaxis.Style{ .fg = statusFg(fence.status), .bg = bg, .bold = true };
                writeStr(surface, 1, 0, "[", .{ .fg = .{ .index = 8 }, .bg = bg });
                writeStr(surface, 2, 0, status_text, status_style);
                const after_status: u16 = @intCast(2 + displayWidth(status_text));
                writeStr(surface, after_status, 0, "]", .{ .fg = .{ .index = 8 }, .bg = bg });
                left_len = after_status + 2;
            }
        }

        // Right side: a one-shot boundary message takes priority over the usual
        // key hints; otherwise show only keys that have an effect in this context
        const has_inputs = if (self.focused_fence) |f| f.hasEditableInputs() else false;
        const hints: []const u8 = self.boundary_hint orelse switch (self.context) {
            .markdown => "j/k: scroll  g/G: top/bot  Tab: next block",
            .codeblock => if (has_inputs)
                "Enter: run  i: edit input  y: copy  Tab/S-Tab: next/prev  Esc: deselect"
            else
                "Enter: run  y: copy  Tab/S-Tab: next/prev  Esc: deselect",
            .running => "Esc: cancel",
            .editing_input => "Enter: save  Esc: cancel",
        };
        const hints_style: vaxis.Style = if (self.boundary_hint != null)
            .{ .fg = .{ .rgb = .{ 0xE5, 0xC0, 0x7B } }, .bg = bg, .italic = true }
        else
            .{ .fg = fg, .bg = bg };

        // Truncate right side to fit after left side
        const hints_len: u16 = @intCast(hints.len);
        const right_start_ideal = if (width > hints_len + 1) width - hints_len - 1 else 0;
        // Don't overlap left content
        const right_start: u16 = @max(right_start_ideal, left_len + 2);
        if (right_start < width) {
            const available = width - right_start;
            const truncated = hints[0..@min(hints.len, available)];
            writeStr(surface, right_start, 0, truncated, hints_style);
        }

        // Separator dot between left and right (only when both are visible)
        if (left_len > 0 and right_start > left_len + 3) {
            const mid: u16 = @intCast((left_len + right_start) / 2);
            surface.writeCell(mid, 0, .{
                .char = .{ .grapheme = "·", .width = 1 },
                .style = .{ .fg = .{ .index = 8 }, .bg = bg },
            });
        }

        return surface;
    }
};

fn contextFor(fence: ?*CodeFenceWidget) Context {
    const f = fence orelse return .markdown;
    if (f.isEditingInput()) return .editing_input;
    if (f.status == .running) return .running;
    return .codeblock;
}

/// Idle blocks have nothing to report; auto-run blocks that merely succeeded
/// don't need to announce "done" since the user never asked to run them.
fn shouldShowBadge(fence: *CodeFenceWidget) bool {
    if (fence.status == .idle) return false;
    if (fence.status == .done and fence.ran_automatically) return false;
    return true;
}

fn statusText(self: *const StatusBar, status: block_runner.RunStatus) []const u8 {
    return switch (status) {
        .idle => "idle",
        .running => SPINNER_FRAMES[self.spinner_frame % SPINNER_FRAMES.len],
        .done => "done",
        .failed => "failed",
        .cancelled => "cancelled",
        .blocked => "blocked",
    };
}

/// Column width of a string when rendered one grapheme per cell (matches
/// writeStr's cadence below) — byte length overcounts multi-byte glyphs
/// like the braille spinner frames.
fn displayWidth(s: []const u8) u16 {
    var n: u16 = 0;
    var it = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    while (it.nextCodepointSlice()) |_| n += 1;
    return n;
}

fn statusFg(status: block_runner.RunStatus) vaxis.Color {
    return switch (status) {
        .idle => .{ .index = 8 },
        .running => .{ .rgb = .{ 0xE5, 0xC0, 0x7B } },
        .done => .{ .rgb = .{ 0x98, 0xC3, 0x79 } },
        .failed => .{ .rgb = .{ 0xE0, 0x6C, 0x75 } },
        .cancelled => .{ .index = 8 },
        .blocked => .{ .rgb = .{ 0xE0, 0x6C, 0x75 } },
    };
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
