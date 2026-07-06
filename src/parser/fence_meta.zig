const std = @import("std");
const variables = @import("variables.zig");

const Allocator = std.mem.Allocator;

pub const FenceMeta = struct {
    id: ?[]const u8,
    description: ?[]const u8,
    auto: bool,
    interactive: bool,
    variables: variables.VariableMap,
    outputs: [][]const u8,
    depends: [][]const u8,
};

pub const ParseResult = struct {
    meta: ?FenceMeta, // null when no # ---...# --- block is present
    body: []const u8, // cleaned body (without the # ---...# --- block)
};

/// Parse a code fence body. If it starts with `# ---\n` we extract the metadata block.
/// All strings in the returned FenceMeta point into the supplied `body` slice or are allocated
/// from `allocator`. The returned `body` slice also points into the original `body`.
pub fn parse(allocator: Allocator, body: []const u8) Allocator.Error!ParseResult {
    var meta: FenceMeta = .{
        .id = null,
        .description = null,
        .auto = false,
        .interactive = false,
        .variables = variables.VariableMap.init(allocator),
        .outputs = &.{},
        .depends = &.{},
    };

    // Check if body starts with a metadata block: lines starting with "# ---"
    const marker = "# ---";
    if (!std.mem.startsWith(u8, body, marker)) {
        // No metadata block — free the empty meta and return null
        meta.variables.deinit();
        return .{ .meta = null, .body = body };
    }

    // Find the end of the first marker line
    const first_nl = std.mem.indexOfScalar(u8, body, '\n') orelse {
        meta.variables.deinit();
        return .{ .meta = null, .body = body };
    };
    var rest = body[first_nl + 1 ..];

    // Collect all lines until the closing # ---
    var yaml_lines = std.ArrayList([]const u8).empty;
    defer yaml_lines.deinit(allocator);

    var found_end = false;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const line = if (nl) |n| rest[0..n] else rest;
        const advance = if (nl) |n| n + 1 else rest.len;

        if (std.mem.startsWith(u8, line, marker)) {
            rest = rest[advance..];
            found_end = true;
            break;
        }

        // Strip leading "# " or "#"
        if (std.mem.startsWith(u8, line, "# ")) {
            try yaml_lines.append(allocator, line[2..]);
        } else if (std.mem.startsWith(u8, line, "#")) {
            try yaml_lines.append(allocator, line[1..]);
        } else {
            // Not a comment line — metadata block is malformed, return raw body
            meta.variables.deinit();
            return .{ .meta = null, .body = body };
        }

        rest = rest[advance..];
    }

    if (!found_end) {
        meta.variables.deinit();
        return .{ .meta = null, .body = body };
    }

    // Parse the collected YAML lines
    try parseYamlLines(allocator, &meta, yaml_lines.items);

    return .{ .meta = meta, .body = rest };
}

fn parseYamlLines(allocator: Allocator, meta: *FenceMeta, lines: []const []const u8) Allocator.Error!void {
    var outputs = std.ArrayList([]const u8).empty;
    errdefer outputs.deinit(allocator);
    var depends = std.ArrayList([]const u8).empty;
    errdefer depends.deinit(allocator);

    var i: usize = 0;
    while (i < lines.len) : (i += 1) {
        const line = lines[i];
        if (line.len == 0) continue;

        // Check indentation level (2 spaces = nested)
        if (std.mem.startsWith(u8, line, "  ")) {
            // Nested line — handled inside the block parsing below
            continue;
        }

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value_raw = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (std.mem.eql(u8, key, "id")) {
            meta.id = try allocator.dupe(u8, variables.stripQuotes(value_raw));
        } else if (std.mem.eql(u8, key, "description")) {
            meta.description = try allocator.dupe(u8, variables.stripQuotes(value_raw));
        } else if (std.mem.eql(u8, key, "auto")) {
            meta.auto = std.mem.eql(u8, value_raw, "true");
        } else if (std.mem.eql(u8, key, "interactive")) {
            meta.interactive = std.mem.eql(u8, value_raw, "true");
        } else if (std.mem.eql(u8, key, "outputs")) {
            // Collect list items (lines starting with "  - ")
            while (i + 1 < lines.len and std.mem.startsWith(u8, lines[i + 1], "  ")) {
                i += 1;
                const item = std.mem.trim(u8, lines[i], " \t");
                if (std.mem.startsWith(u8, item, "- ")) {
                    try outputs.append(allocator, try allocator.dupe(u8, std.mem.trim(u8, item[2..], " \t")));
                }
            }
        } else if (std.mem.eql(u8, key, "depends")) {
            while (i + 1 < lines.len and std.mem.startsWith(u8, lines[i + 1], "  ")) {
                i += 1;
                const item = std.mem.trim(u8, lines[i], " \t");
                if (std.mem.startsWith(u8, item, "- ")) {
                    try depends.append(allocator, try allocator.dupe(u8, std.mem.trim(u8, item[2..], " \t")));
                }
            }
        } else if (std.mem.eql(u8, key, "variables")) {
            // The shared parser expects a cursor already pointing at the
            // first unconsumed line; this loop's own `: (i += 1)` will then
            // advance past whatever it left consumed, so back up by one.
            var vidx: usize = i + 1;
            try variables.parseVariablesSection(allocator, &meta.variables, lines, &vidx);
            i = vidx - 1;
        }
    }

    meta.outputs = try outputs.toOwnedSlice(allocator);
    meta.depends = try depends.toOwnedSlice(allocator);
}

pub fn deinit(allocator: Allocator, meta: *FenceMeta) void {
    if (meta.id) |v| allocator.free(v);
    if (meta.description) |v| allocator.free(v);
    for (meta.outputs) |v| allocator.free(v);
    allocator.free(meta.outputs);
    for (meta.depends) |v| allocator.free(v);
    allocator.free(meta.depends);

    variables.deinitVariables(allocator, &meta.variables);
}
