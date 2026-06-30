const std = @import("std");
const fence_meta = @import("fence_meta.zig");

const Allocator = std.mem.Allocator;

pub const FenceMeta = fence_meta.FenceMeta;

pub const Align = enum { left, center, right, none };

pub const Link = struct {
    text: []const u8,
    url: []const u8,
};

pub const Span = union(enum) {
    text: []const u8,
    bold: []Span,
    italic: []Span,
    code: []const u8,
    strikethrough: []Span,
    link: Link,
};

pub const Heading = struct {
    level: u8,
    text: []const u8,
};

pub const Paragraph = struct {
    spans: []Span,
};

pub const CodeFence = struct {
    lang: []const u8,
    body: []const u8,     // cleaned body (without the # ---...# --- block)
    raw_body: []const u8, // original full body
    metadata: ?FenceMeta,
};

pub const ListItem = struct {
    spans: []Span,
    children: []ListItem,
    children_ordered: bool,
    checked: ?bool, // null = not a task item; true/false = checked/unchecked
};

pub const List = struct {
    ordered: bool,
    items: []ListItem,
};

pub const Table = struct {
    headers: [][]const u8,
    alignments: []Align,
    rows: [][][]const u8,
};

pub const Blockquote = struct {
    blocks: []Block,
};

pub const Block = union(enum) {
    heading: Heading,
    paragraph: Paragraph,
    code_fence: CodeFence,
    list: List,
    table: Table,
    blockquote: Blockquote,
    horizontal_rule,
    blank,
};

pub const Document = struct {
    blocks: []Block,
    allocator: Allocator,

    pub fn deinit(self: *Document) void {
        for (self.blocks) |*block| {
            freeBlock(self.allocator, block);
        }
        self.allocator.free(self.blocks);
    }
};

fn freeBlock(allocator: Allocator, block: *Block) void {
    switch (block.*) {
        .heading => |*h| {
            allocator.free(h.text);
        },
        .paragraph => |*p| {
            freeSpans(allocator, p.spans);
            allocator.free(p.spans);
        },
        .code_fence => |*cf| {
            if (cf.metadata) |*m| fence_meta.deinit(allocator, m);
        },
        .list => |*l| {
            freeListItems(allocator, l.items);
            allocator.free(l.items);
        },
        .table => |*t| {
            for (t.headers) |h| allocator.free(h);
            allocator.free(t.headers);
            allocator.free(t.alignments);
            for (t.rows) |row| {
                for (row) |cell| allocator.free(cell);
                allocator.free(row);
            }
            allocator.free(t.rows);
        },
        .blockquote => |bq| {
            for (bq.blocks) |*sub| freeBlock(allocator, sub);
            allocator.free(bq.blocks);
        },
        .horizontal_rule, .blank => {},
    }
}

fn freeSpans(allocator: Allocator, spans: []Span) void {
    for (spans) |*span| {
        switch (span.*) {
            .bold => |children| {
                freeSpans(allocator, children);
                allocator.free(children);
            },
            .italic => |children| {
                freeSpans(allocator, children);
                allocator.free(children);
            },
            .strikethrough => |children| {
                freeSpans(allocator, children);
                allocator.free(children);
            },
            .text, .code, .link => {},
        }
    }
}

fn freeListItems(allocator: Allocator, items: []ListItem) void {
    for (items) |*item| {
        freeSpans(allocator, item.spans);
        allocator.free(item.spans);
        freeListItems(allocator, item.children);
        allocator.free(item.children);
    }
}

// ===== Parser =====

const Parser = struct {
    allocator: Allocator,
    lines: []const []const u8,
    pos: usize,

    fn init(allocator: Allocator, source: []const u8) Allocator.Error!Parser {
        var line_list = std.ArrayList([]const u8).empty;
        var it = std.mem.splitScalar(u8, source, '\n');
        while (it.next()) |line| {
            // Strip trailing \r
            const l = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
            try line_list.append(allocator, l);
        }
        return .{
            .allocator = allocator,
            .lines = try line_list.toOwnedSlice(allocator),
            .pos = 0,
        };
    }

    fn deinit(self: *Parser) void {
        self.allocator.free(self.lines);
    }

    fn peek(self: *Parser) ?[]const u8 {
        if (self.pos >= self.lines.len) return null;
        return self.lines[self.pos];
    }

    fn advance(self: *Parser) ?[]const u8 {
        if (self.pos >= self.lines.len) return null;
        const line = self.lines[self.pos];
        self.pos += 1;
        return line;
    }

    fn parse(self: *Parser) Allocator.Error![]Block {
        var blocks = std.ArrayList(Block).empty;
        errdefer blocks.deinit(self.allocator);

        while (self.peek()) |line| {
            if (line.len == 0) {
                _ = self.advance();
                // Don't add blank blocks — just skip
                continue;
            }

            // Heading
            if (parseHeadingLine(line)) |h| {
                _ = self.advance();
                try blocks.append(self.allocator, .{ .heading = .{
                    .level = h.level,
                    .text = try self.allocator.dupe(u8, h.text),
                } });
                continue;
            }

            // Horizontal rule
            if (isHorizontalRule(line)) {
                _ = self.advance();
                try blocks.append(self.allocator, .horizontal_rule);
                continue;
            }

            // Code fence
            if (isCodeFenceStart(line)) {
                const block = try self.parseCodeFence();
                try blocks.append(self.allocator, block);
                continue;
            }

            // Blockquote
            if (std.mem.startsWith(u8, line, ">")) {
                const block = try self.parseBlockquote();
                try blocks.append(self.allocator, block);
                continue;
            }

            // Table
            if (isTableLine(line)) {
                const block = try self.parseTable();
                try blocks.append(self.allocator, block);
                continue;
            }

            // List
            if (isListLine(line, 0)) {
                const block = try self.parseList(0);
                try blocks.append(self.allocator, block);
                continue;
            }

            // Paragraph
            const block = try self.parseParagraph();
            try blocks.append(self.allocator, block);
        }

        return try blocks.toOwnedSlice(self.allocator);
    }

    fn parseHeadingLine(line: []const u8) ?struct { level: u8, text: []const u8 } {
        if (line.len == 0 or line[0] != '#') return null;
        var level: u8 = 0;
        while (level < line.len and line[level] == '#') level += 1;
        if (level > 6) return null;
        if (level >= line.len) return .{ .level = level, .text = "" };
        if (line[level] != ' ') return null;
        const text = std.mem.trim(u8, line[level + 1 ..], " \t");
        return .{ .level = level, .text = text };
    }

    fn isHorizontalRule(line: []const u8) bool {
        const stripped = std.mem.trim(u8, line, " \t");
        if (stripped.len < 3) return false;
        const c = stripped[0];
        if (c != '-' and c != '*' and c != '_') return false;
        for (stripped) |ch| {
            if (ch != c and ch != ' ' and ch != '\t') return false;
        }
        var count: usize = 0;
        for (stripped) |ch| {
            if (ch == c) count += 1;
        }
        return count >= 3;
    }

    fn isCodeFenceStart(line: []const u8) bool {
        return std.mem.startsWith(u8, line, "```") or std.mem.startsWith(u8, line, "~~~");
    }

    fn isTableLine(line: []const u8) bool {
        const trimmed = std.mem.trim(u8, line, " \t");
        return std.mem.startsWith(u8, trimmed, "|");
    }

    fn isListLine(line: []const u8, min_indent: usize) bool {
        var indent: usize = 0;
        while (indent < line.len and line[indent] == ' ') indent += 1;
        if (indent < min_indent) return false;
        const rest = line[indent..];
        // Unordered: "- ", "* ", "+ "
        if (rest.len >= 2 and (rest[0] == '-' or rest[0] == '*' or rest[0] == '+') and rest[1] == ' ') {
            return true;
        }
        // Ordered: "1. ", "2. ", etc.
        var i: usize = 0;
        while (i < rest.len and rest[i] >= '0' and rest[i] <= '9') i += 1;
        if (i > 0 and i < rest.len and rest[i] == '.' and i + 1 < rest.len and rest[i + 1] == ' ') {
            return true;
        }
        return false;
    }

    fn parseCodeFence(self: *Parser) Allocator.Error!Block {
        const fence_line = self.advance().?;
        const fence_char = fence_line[0];

        // Count the exact number of opening backticks/tildes to use as closing delimiter
        var fence_len: usize = 0;
        while (fence_len < fence_line.len and fence_line[fence_len] == fence_char) fence_len += 1;
        // fence_len is now the backtick/tilde count (e.g. 3 for ```, 4 for ````)

        // Extract language (everything after the opening backticks)
        const lang = std.mem.trim(u8, fence_line[fence_len..], " \t");

        var body_lines = std.ArrayList([]const u8).empty;
        defer body_lines.deinit(self.allocator);

        while (self.peek()) |line| {
            // Closing delimiter: must start with at least fence_len of the same char
            var closing_len: usize = 0;
            while (closing_len < line.len and line[closing_len] == fence_char) closing_len += 1;
            if (closing_len >= fence_len and std.mem.trim(u8, line[closing_len..], " \t").len == 0) {
                _ = self.advance();
                break;
            }
            try body_lines.append(self.allocator, line);
            _ = self.advance();
        }

        // Join body lines
        var raw_body_buf = std.ArrayList(u8).empty;
        defer raw_body_buf.deinit(self.allocator);
        for (body_lines.items) |bl| {
            try raw_body_buf.appendSlice(self.allocator, bl);
            try raw_body_buf.append(self.allocator, '\n');
        }
        const raw_body = try self.allocator.dupe(u8, raw_body_buf.items);

        // Parse fence metadata (only if lang is bash/sh or body starts with # ---)
        const is_bash = std.mem.eql(u8, lang, "bash") or std.mem.eql(u8, lang, "sh");
        const meta_result = if (is_bash or std.mem.startsWith(u8, raw_body, "# ---"))
            try fence_meta.parse(self.allocator, raw_body)
        else
            fence_meta.ParseResult{ .meta = null, .body = raw_body };

        return .{ .code_fence = .{
            .lang = try self.allocator.dupe(u8, lang),
            .body = std.mem.trimEnd(u8, meta_result.body, "\n"),
            .raw_body = raw_body,
            .metadata = meta_result.meta,
        } };
    }

    fn parseBlockquote(self: *Parser) Allocator.Error!Block {
        var content_lines = std.ArrayList([]const u8).empty;
        defer content_lines.deinit(self.allocator);

        while (self.peek()) |line| {
            if (!std.mem.startsWith(u8, line, ">")) break;
            const stripped = if (line.len > 1 and line[1] == ' ') line[2..] else line[1..];
            try content_lines.append(self.allocator, stripped);
            _ = self.advance();
        }

        // Join stripped lines into a string, then re-parse as markdown
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        for (content_lines.items) |cl| {
            try buf.appendSlice(self.allocator, cl);
            try buf.append(self.allocator, '\n');
        }

        // Re-parse the stripped content as a fresh markdown document
        var sub_parser = try Parser.init(self.allocator, buf.items);
        defer sub_parser.deinit();
        const sub_blocks = try sub_parser.parse();
        // sub_blocks is already allocated; transfer ownership
        return .{ .blockquote = .{ .blocks = sub_blocks } };
    }

    fn parseTable(self: *Parser) Allocator.Error!Block {
        // Read header line
        const header_line = self.advance().?;
        const headers = try parseTableRow(self.allocator, header_line);

        // Read separator line
        var alignments: []Align = &.{};
        if (self.peek()) |sep_line| {
            if (isTableSeparator(sep_line)) {
                _ = self.advance();
                alignments = try parseTableAlignments(self.allocator, sep_line, headers.len);
            }
        }

        // Read data rows
        var rows = std.ArrayList([][]const u8).empty;

        while (self.peek()) |line| {
            if (!isTableLine(line)) break;
            const row = try parseTableRow(self.allocator, line);
            try rows.append(self.allocator, row);
            _ = self.advance();
        }

        return .{ .table = .{
            .headers = headers,
            .alignments = alignments,
            .rows = try rows.toOwnedSlice(self.allocator),
        } };
    }

    fn isTableSeparator(line: []const u8) bool {
        const trimmed = std.mem.trim(u8, line, " \t|");
        if (trimmed.len == 0) return false;
        for (trimmed) |c| {
            if (c != '-' and c != ':' and c != '|' and c != ' ') return false;
        }
        return true;
    }

    fn parseTableRow(allocator: Allocator, line: []const u8) Allocator.Error![][]const u8 {
        var cells = std.ArrayList([]const u8).empty;
        var parts = std.mem.splitScalar(u8, line, '|');
        _ = parts.next(); // skip leading empty part
        while (parts.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t");
            if (parts.peek() == null and trimmed.len == 0) break; // trailing |
            try cells.append(allocator, try allocator.dupe(u8, trimmed));
        }
        return try cells.toOwnedSlice(allocator);
    }

    fn parseTableAlignments(allocator: Allocator, line: []const u8, n: usize) Allocator.Error![]Align {
        var alignments = try allocator.alloc(Align, n);
        @memset(alignments, .none);

        var parts = std.mem.splitScalar(u8, line, '|');
        _ = parts.next();
        var i: usize = 0;
        while (parts.next()) |part| {
            if (i >= n) break;
            const trimmed = std.mem.trim(u8, part, " \t");
            if (trimmed.len == 0) continue;
            const left_colon = std.mem.startsWith(u8, trimmed, ":");
            const right_colon = std.mem.endsWith(u8, trimmed, ":");
            alignments[i] = if (left_colon and right_colon)
                .center
            else if (right_colon)
                .right
            else if (left_colon)
                .left
            else
                .none;
            i += 1;
        }
        return alignments;
    }

    fn parseList(self: *Parser, base_indent: usize) Allocator.Error!Block {
        const first_line = self.peek().?;
        const ordered = isOrderedListLine(first_line, base_indent);

        var items = std.ArrayList(ListItem).empty;
        errdefer {
            for (items.items) |*item| {
                freeSpans(self.allocator, item.spans);
                self.allocator.free(item.spans);
                freeListItems(self.allocator, item.children);
                self.allocator.free(item.children);
            }
            items.deinit(self.allocator);
        }

        while (self.peek()) |line| {
            var line_indent: usize = 0;
            while (line_indent < line.len and line[line_indent] == ' ') line_indent += 1;

            if (line_indent < base_indent) break;
            if (line_indent == base_indent) {
                if (!isListLine(line, base_indent)) break;

                const item = try self.parseListItem(base_indent, ordered);
                try items.append(self.allocator, item);
            } else {
                // Continuation or nested — should have been consumed by parseListItem
                break;
            }
        }

        return .{ .list = .{
            .ordered = ordered,
            .items = try items.toOwnedSlice(self.allocator),
        } };
    }

    fn isOrderedListLine(line: []const u8, base_indent: usize) bool {
        var indent: usize = 0;
        while (indent < line.len and line[indent] == ' ') indent += 1;
        if (indent < base_indent) return false;
        const rest = line[indent..];
        var i: usize = 0;
        while (i < rest.len and rest[i] >= '0' and rest[i] <= '9') i += 1;
        return i > 0;
    }

    fn parseListItem(self: *Parser, base_indent: usize, _: bool) Allocator.Error!ListItem {
        const line = self.advance().?;
        var indent: usize = 0;
        while (indent < line.len and line[indent] == ' ') indent += 1;
        const rest = line[indent..];

        // Find where the content starts
        var content_start: usize = 0;
        var checked: ?bool = null;

        if (rest.len >= 2 and (rest[0] == '-' or rest[0] == '*' or rest[0] == '+') and rest[1] == ' ') {
            content_start = 2;
        } else {
            // Ordered
            var i: usize = 0;
            while (i < rest.len and rest[i] >= '0' and rest[i] <= '9') i += 1;
            if (i < rest.len and rest[i] == '.') content_start = i + 2; // ". "
        }

        var content = rest[content_start..];

        // Check for task list item: "[ ] " or "[x] "
        if (content.len >= 4 and content[0] == '[') {
            if ((content[1] == ' ' or content[1] == 'x' or content[1] == 'X') and content[2] == ']' and content[3] == ' ') {
                checked = content[1] != ' ';
                content = content[4..];
            }
        }

        const spans = try parseInline(self.allocator, content);

        // Parse nested items (next lines with indent > base_indent + 2)
        var children_list = std.ArrayList(ListItem).empty;
        const child_indent = base_indent + 2;
        var children_ordered = false;

        while (self.peek()) |next_line| {
            var ni: usize = 0;
            while (ni < next_line.len and next_line[ni] == ' ') ni += 1;
            if (ni < child_indent) break;
            if (!isListLine(next_line, child_indent)) break;

            const child_is_ordered = isOrderedListLine(next_line, child_indent);
            if (children_list.items.len == 0) children_ordered = child_is_ordered;
            const child = try self.parseListItem(child_indent, child_is_ordered);
            try children_list.append(self.allocator, child);
        }

        return .{
            .spans = spans,
            .children = try children_list.toOwnedSlice(self.allocator),
            .children_ordered = children_ordered,
            .checked = checked,
        };
    }

    fn parseParagraph(self: *Parser) Allocator.Error!Block {
        var text_lines = std.ArrayList([]const u8).empty;
        defer text_lines.deinit(self.allocator);

        while (self.peek()) |line| {
            if (line.len == 0) break;
            if (parseHeadingLine(line) != null) break;
            if (isHorizontalRule(line)) break;
            if (isCodeFenceStart(line)) break;
            if (isTableLine(line)) break;
            if (isListLine(line, 0)) break;
            if (std.mem.startsWith(u8, line, ">")) break;

            try text_lines.append(self.allocator, line);
            _ = self.advance();
        }

        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        for (text_lines.items, 0..) |tl, idx| {
            try buf.appendSlice(self.allocator, tl);
            if (idx + 1 < text_lines.items.len) try buf.append(self.allocator, ' ');
        }

        const spans = try parseInline(self.allocator, buf.items);
        return .{ .paragraph = .{ .spans = spans } };
    }
};

// ===== Inline parser =====

fn parseInline(allocator: Allocator, text: []const u8) Allocator.Error![]Span {
    var spans = std.ArrayList(Span).empty;
    errdefer {
        freeSpans(allocator, spans.items);
        spans.deinit(allocator);
    }

    var i: usize = 0;
    var text_start: usize = 0;

    while (i < text.len) {
        const c = text[i];

        // Check for various inline markers
        if (c == '`') {
            // Flush plain text
            if (i > text_start) {
                try spans.append(allocator, .{ .text = try allocator.dupe(u8, text[text_start..i]) });
            }
            // Find closing backtick
            const end = std.mem.indexOfScalarPos(u8, text, i + 1, '`') orelse {
                text_start = i;
                i += 1;
                continue;
            };
            try spans.append(allocator, .{ .code = try allocator.dupe(u8, text[i + 1 .. end]) });
            i = end + 1;
            text_start = i;
            continue;
        }

        if (c == '*' or c == '_') {
            const delim = c;
            // Check for double
            if (i + 1 < text.len and text[i + 1] == delim) {
                // Bold
                if (findClosingDelim(text, i + 2, delim, 2)) |end| {
                    if (i > text_start) {
                        try spans.append(allocator, .{ .text = try allocator.dupe(u8, text[text_start..i]) });
                    }
                    const inner = try parseInline(allocator, text[i + 2 .. end]);
                    try spans.append(allocator, .{ .bold = inner });
                    i = end + 2;
                    text_start = i;
                    continue;
                }
            } else {
                // Italic
                if (findClosingDelim(text, i + 1, delim, 1)) |end| {
                    if (i > text_start) {
                        try spans.append(allocator, .{ .text = try allocator.dupe(u8, text[text_start..i]) });
                    }
                    const inner = try parseInline(allocator, text[i + 1 .. end]);
                    try spans.append(allocator, .{ .italic = inner });
                    i = end + 1;
                    text_start = i;
                    continue;
                }
            }
        }

        if (c == '~' and i + 1 < text.len and text[i + 1] == '~') {
            if (findClosingDelim(text, i + 2, '~', 2)) |end| {
                if (i > text_start) {
                    try spans.append(allocator, .{ .text = try allocator.dupe(u8, text[text_start..i]) });
                }
                const inner = try parseInline(allocator, text[i + 2 .. end]);
                try spans.append(allocator, .{ .strikethrough = inner });
                i = end + 2;
                text_start = i;
                continue;
            }
        }

        if (c == '[') {
            // Link [text](url)
            if (findLinkEnd(text, i)) |link_end| {
                if (i > text_start) {
                    try spans.append(allocator, .{ .text = try allocator.dupe(u8, text[text_start..i]) });
                }
                try spans.append(allocator, .{ .link = .{
                    .text = try allocator.dupe(u8, link_end.text),
                    .url = try allocator.dupe(u8, link_end.url),
                } });
                i = link_end.end;
                text_start = i;
                continue;
            }
        }

        i += 1;
    }

    // Flush remaining text
    if (text_start < text.len) {
        try spans.append(allocator, .{ .text = try allocator.dupe(u8, text[text_start..]) });
    }

    return try spans.toOwnedSlice(allocator);
}

fn findClosingDelim(text: []const u8, start: usize, delim: u8, count: usize) ?usize {
    var i = start;
    while (i + count <= text.len) {
        var matches: usize = 0;
        while (matches < count and i + matches < text.len and text[i + matches] == delim) matches += 1;
        if (matches == count) return i;
        i += 1;
    }
    return null;
}

const LinkEnd = struct {
    text: []const u8,
    url: []const u8,
    end: usize,
};

fn findLinkEnd(text: []const u8, start: usize) ?LinkEnd {
    std.debug.assert(text[start] == '[');
    // Find ]
    const close_bracket = std.mem.indexOfScalarPos(u8, text, start + 1, ']') orelse return null;
    if (close_bracket + 1 >= text.len or text[close_bracket + 1] != '(') return null;
    const open_paren = close_bracket + 1;
    const close_paren = std.mem.indexOfScalarPos(u8, text, open_paren + 1, ')') orelse return null;
    return .{
        .text = text[start + 1 .. close_bracket],
        .url = text[open_paren + 1 .. close_paren],
        .end = close_paren + 1,
    };
}

// ===== Public API =====

pub fn parse(allocator: Allocator, source: []const u8) Allocator.Error!Document {
    var parser = try Parser.init(allocator, source);
    defer parser.deinit();

    const blocks = try parser.parse();
    return .{ .blocks = blocks, .allocator = allocator };
}
