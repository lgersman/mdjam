const vaxis = @import("vaxis");

pub const Color = vaxis.Color;
pub const Style = vaxis.Style;

pub const Theme = struct {
    // Headings
    heading1: Style,
    heading2: Style,
    heading3: Style,
    heading4: Style,
    heading5: Style,
    heading6: Style,

    // Code
    code_bg: Color,
    code_fg: Color,
    code_inline_fg: Color,

    // Inline formatting
    bold_style: Style,
    italic_style: Style,
    strikethrough_style: Style,

    // Block elements
    blockquote_border: Color,
    blockquote_fg: Color,
    list_bullet: Color,
    table_border: Color,
    link_fg: Color,
    hr_fg: Color,

    // Status colors
    status_idle: Style,
    status_running: Style,
    status_done: Style,
    status_failed: Style,
    status_blocked: Style,

    // UI
    muted: Style,
    panel_bg: Color,
    panel_border: Color,
    status_bar_bg: Color,
    status_bar_fg: Color,
    focused_border: Color,
    unfocused_border: Color,

    // Input fields
    input_bg: Color,
    input_fg: Color,
    input_label_fg: Color,
};

pub const dark: Theme = .{
    .heading1 = .{ .fg = .{ .rgb = .{ 0x61, 0xAF, 0xEF } }, .bold = true },
    .heading2 = .{ .fg = .{ .rgb = .{ 0x98, 0xC3, 0x79 } }, .bold = true },
    .heading3 = .{ .fg = .{ .rgb = .{ 0xE5, 0xC0, 0x7B } }, .bold = true },
    .heading4 = .{ .fg = .{ .rgb = .{ 0xC6, 0x78, 0xDD } }, .bold = true },
    .heading5 = .{ .fg = .{ .rgb = .{ 0x56, 0xB6, 0xC2 } }, .bold = true },
    .heading6 = .{ .fg = .{ .rgb = .{ 0xAB, 0xB2, 0xBF } }, .bold = true },

    .code_bg = .{ .rgb = .{ 0x2C, 0x32, 0x3C } },
    .code_fg = .{ .rgb = .{ 0xAB, 0xB2, 0xBF } },
    .code_inline_fg = .{ .rgb = .{ 0xE0, 0x6C, 0x75 } },

    .bold_style = .{ .bold = true },
    .italic_style = .{ .italic = true },
    .strikethrough_style = .{ .strikethrough = true, .fg = .{ .index = 8 } },

    .blockquote_border = .{ .rgb = .{ 0x61, 0xAF, 0xEF } },
    .blockquote_fg = .{ .rgb = .{ 0xAB, 0xB2, 0xBF } },
    .list_bullet = .{ .rgb = .{ 0x61, 0xAF, 0xEF } },
    .table_border = .{ .rgb = .{ 0x52, 0x59, 0x67 } },
    .link_fg = .{ .rgb = .{ 0x61, 0xAF, 0xEF } },
    .hr_fg = .{ .rgb = .{ 0x52, 0x59, 0x67 } },

    .status_idle = .{ .fg = .{ .index = 8 } },
    .status_running = .{ .fg = .{ .rgb = .{ 0xE5, 0xC0, 0x7B } } },
    .status_done = .{ .fg = .{ .rgb = .{ 0x98, 0xC3, 0x79 } } },
    .status_failed = .{ .fg = .{ .rgb = .{ 0xE0, 0x6C, 0x75 } } },
    .status_blocked = .{ .fg = .{ .index = 8 }, .dim = true },

    .muted = .{ .fg = .{ .index = 8 } },
    .panel_bg = .{ .rgb = .{ 0x21, 0x25, 0x2B } },
    .panel_border = .{ .rgb = .{ 0x52, 0x59, 0x67 } },
    .status_bar_bg = .{ .rgb = .{ 0x21, 0x25, 0x2B } },
    .status_bar_fg = .{ .rgb = .{ 0xAB, 0xB2, 0xBF } },
    .focused_border = .{ .rgb = .{ 0x61, 0xAF, 0xEF } },
    .unfocused_border = .{ .rgb = .{ 0x52, 0x59, 0x67 } },

    .input_bg = .{ .rgb = .{ 0x2C, 0x32, 0x3C } },
    .input_fg = .{ .rgb = .{ 0xAB, 0xB2, 0xBF } },
    .input_label_fg = .{ .rgb = .{ 0x61, 0xAF, 0xEF } },
};

pub fn headingStyle(t: *const Theme, level: u8) Style {
    return switch (level) {
        1 => t.heading1,
        2 => t.heading2,
        3 => t.heading3,
        4 => t.heading4,
        5 => t.heading5,
        else => t.heading6,
    };
}
