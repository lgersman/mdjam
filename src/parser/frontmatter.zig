const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Prerequisites = struct {
    tools: [][]const u8,
    env: [][]const u8,
};

pub const Frontmatter = struct {
    title: ?[]const u8,
    description: ?[]const u8,
    prerequisites: Prerequisites,
    setup: ?[]const u8,
    teardown: ?[]const u8,
    defaults: std.StringHashMap([]const u8),

    pub fn deinit(self: *Frontmatter, allocator: Allocator) void {
        if (self.title) |v| allocator.free(v);
        if (self.description) |v| allocator.free(v);
        if (self.setup) |v| allocator.free(v);
        if (self.teardown) |v| allocator.free(v);
        for (self.prerequisites.tools) |t| allocator.free(t);
        allocator.free(self.prerequisites.tools);
        for (self.prerequisites.env) |e| allocator.free(e);
        allocator.free(self.prerequisites.env);

        var it = self.defaults.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            allocator.free(kv.value_ptr.*);
        }
        self.defaults.deinit();
    }
};

pub const ParseResult = struct {
    frontmatter: ?Frontmatter,
    /// Content of the file after the frontmatter block
    body: []const u8,
};

/// Parse YAML frontmatter from the beginning of a markdown file.
/// Returns null for frontmatter if there is no `---` block at the start.
/// All returned strings are allocated from `allocator`.
pub fn parse(allocator: Allocator, source: []const u8) Allocator.Error!ParseResult {
    const marker = "---";

    // Must start with "---\n" or "---\r\n"
    if (!std.mem.startsWith(u8, source, marker)) {
        return .{ .frontmatter = null, .body = source };
    }
    const after_open = skipNewline(source[marker.len..]) orelse {
        return .{ .frontmatter = null, .body = source };
    };

    // Find closing ---
    var rest = after_open;
    const close_idx = findClosingMarker(rest) orelse {
        return .{ .frontmatter = null, .body = source };
    };

    const yaml_block = rest[0..close_idx];
    const after_close = skipNewline(rest[close_idx + marker.len ..]) orelse rest[close_idx + marker.len ..];

    var fm = Frontmatter{
        .title = null,
        .description = null,
        .prerequisites = .{ .tools = &.{}, .env = &.{} },
        .setup = null,
        .teardown = null,
        .defaults = std.StringHashMap([]const u8).init(allocator),
    };
    errdefer fm.deinit(allocator);

    try parseYaml(allocator, &fm, yaml_block);

    return .{ .frontmatter = fm, .body = after_close };
}

fn skipNewline(s: []const u8) ?[]const u8 {
    if (s.len == 0) return s;
    if (s[0] == '\n') return s[1..];
    if (s.len >= 2 and s[0] == '\r' and s[1] == '\n') return s[2..];
    // allow "---" on same line as following content? No — must have newline
    return null;
}

fn findClosingMarker(s: []const u8) ?usize {
    var i: usize = 0;
    while (i < s.len) {
        // Check if this position starts a "---" at beginning of a line
        if (std.mem.startsWith(u8, s[i..], "---")) {
            // Make sure it's at a line start (i == 0 or previous char was newline)
            if (i == 0 or s[i - 1] == '\n') {
                return i;
            }
        }
        i += 1;
    }
    return null;
}

fn parseYaml(allocator: Allocator, fm: *Frontmatter, yaml: []const u8) Allocator.Error!void {
    var tools = std.ArrayList([]const u8).empty;
    errdefer {
        for (tools.items) |t| allocator.free(t);
        tools.deinit(allocator);
    }
    var envs = std.ArrayList([]const u8).empty;
    errdefer {
        for (envs.items) |e| allocator.free(e);
        envs.deinit(allocator);
    }

    // Build a list of raw lines so we can index into them for block scalars
    var raw_lines = std.ArrayList([]const u8).empty;
    defer raw_lines.deinit(allocator);
    var split = std.mem.splitScalar(u8, yaml, '\n');
    while (split.next()) |l| {
        try raw_lines.append(allocator, std.mem.trimEnd(u8, l, "\r"));
    }

    var line_idx: usize = 0;
    var current_section: ?[]const u8 = null;
    var current_subsection: ?[]const u8 = null;

    while (line_idx < raw_lines.items.len) {
        const line = raw_lines.items[line_idx];
        line_idx += 1;

        if (line.len == 0) {
            current_section = null;
            current_subsection = null;
            continue;
        }

        // Determine indentation
        var indent: usize = 0;
        while (indent < line.len and line[indent] == ' ') indent += 1;

        const trimmed = line[indent..];
        if (trimmed.len == 0) continue;

        if (indent == 0) {
            current_section = null;
            current_subsection = null;

            const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
            const key = std.mem.trim(u8, trimmed[0..colon], " \t");
            const value_raw = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");

            // Handle YAML block scalar (|) for multi-line strings
            if (std.mem.eql(u8, value_raw, "|") or std.mem.eql(u8, value_raw, "|-")) {
                const strip_trailing = std.mem.eql(u8, value_raw, "|-");
                var block = std.ArrayList(u8).empty;
                defer block.deinit(allocator);
                // Determine block indent from first non-empty line
                var block_indent: usize = 0;
                while (line_idx < raw_lines.items.len) {
                    const bl = raw_lines.items[line_idx];
                    if (bl.len == 0) { try block.appendSlice(allocator, "\n"); line_idx += 1; continue; }
                    var bi: usize = 0;
                    while (bi < bl.len and bl[bi] == ' ') bi += 1;
                    if (block_indent == 0 and bi > 0) block_indent = bi;
                    if (bi < block_indent) break; // back to parent level
                    const stripped = if (bl.len >= block_indent) bl[block_indent..] else bl;
                    try block.appendSlice(allocator, stripped);
                    try block.append(allocator, '\n');
                    line_idx += 1;
                }
                const result_mutable = try block.toOwnedSlice(allocator);
                const result: []u8 = if (strip_trailing)
                    @constCast(std.mem.trimEnd(u8, result_mutable, "\n"))
                else
                    result_mutable;
                if (std.mem.eql(u8, key, "setup")) {
                    if (fm.setup) |old| allocator.free(old);
                    fm.setup = result;
                } else if (std.mem.eql(u8, key, "teardown")) {
                    if (fm.teardown) |old| allocator.free(old);
                    fm.teardown = result;
                } else {
                    allocator.free(result);
                }
                continue;
            }

            if (value_raw.len == 0) {
                // This is a section header
                current_section = key;
            } else {
                // Scalar value
                const value = stripYamlQuotes(value_raw);
                if (std.mem.eql(u8, key, "title")) {
                    if (fm.title) |old| allocator.free(old);
                    fm.title = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "description")) {
                    if (fm.description) |old| allocator.free(old);
                    fm.description = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "setup")) {
                    if (fm.setup) |old| allocator.free(old);
                    fm.setup = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "teardown")) {
                    if (fm.teardown) |old| allocator.free(old);
                    fm.teardown = try allocator.dupe(u8, value);
                }
            }
        } else if (indent == 2) {
            // Inside a section
            if (current_section) |section| {
                if (std.mem.eql(u8, section, "prerequisites")) {
                    const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse {
                        // List item
                        if (std.mem.startsWith(u8, trimmed, "- ")) {
                            const item = std.mem.trim(u8, trimmed[2..], " \t");
                            if (current_subsection) |sub| {
                                if (std.mem.eql(u8, sub, "tools")) {
                                    try tools.append(allocator, try allocator.dupe(u8, item));
                                } else if (std.mem.eql(u8, sub, "env")) {
                                    try envs.append(allocator, try allocator.dupe(u8, item));
                                }
                            }
                        }
                        continue;
                    };
                    const key = std.mem.trim(u8, trimmed[0..colon], " \t");
                    const value_raw = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
                    if (value_raw.len == 0) {
                        current_subsection = key;
                    }
                } else if (std.mem.eql(u8, section, "defaults")) {
                    const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
                    const key = std.mem.trim(u8, trimmed[0..colon], " \t");
                    const value_raw = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
                    const value = stripYamlQuotes(value_raw);
                    const owned_key = try allocator.dupe(u8, key);
                    errdefer allocator.free(owned_key);
                    const owned_value = try allocator.dupe(u8, value);
                    try fm.defaults.put(owned_key, owned_value);
                }
            }
        } else if (indent == 4) {
            // List items inside subsections
            if (current_section) |section| {
                if (std.mem.eql(u8, section, "prerequisites")) {
                    if (std.mem.startsWith(u8, trimmed, "- ")) {
                        const item = std.mem.trim(u8, trimmed[2..], " \t");
                        if (current_subsection) |sub| {
                            if (std.mem.eql(u8, sub, "tools")) {
                                try tools.append(allocator, try allocator.dupe(u8, item));
                            } else if (std.mem.eql(u8, sub, "env")) {
                                try envs.append(allocator, try allocator.dupe(u8, item));
                            }
                        }
                    }
                }
            }
        }
    }

    fm.prerequisites.tools = try tools.toOwnedSlice(allocator);
    fm.prerequisites.env = try envs.toOwnedSlice(allocator);
}

fn stripYamlQuotes(s: []const u8) []const u8 {
    if (s.len >= 2) {
        if ((s[0] == '"' and s[s.len - 1] == '"') or
            (s[0] == '\'' and s[s.len - 1] == '\''))
        {
            return s[1 .. s.len - 1];
        }
    }
    return s;
}
