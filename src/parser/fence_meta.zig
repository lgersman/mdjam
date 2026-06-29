const std = @import("std");

const Allocator = std.mem.Allocator;

pub const InputDef = struct {
    description: ?[]const u8,
    default: ?[]const u8,
    readonly: bool,
};

pub const FenceMeta = struct {
    id: ?[]const u8,
    description: ?[]const u8,
    auto: bool,
    interactive: bool,
    inputs: std.StringHashMap(InputDef),
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
        .inputs = std.StringHashMap(InputDef).init(allocator),
        .outputs = &.{},
        .depends = &.{},
    };

    // Check if body starts with a metadata block: lines starting with "# ---"
    const marker = "# ---";
    if (!std.mem.startsWith(u8, body, marker)) {
        // No metadata block — free the empty meta and return null
        meta.inputs.deinit();
        return .{ .meta = null, .body = body };
    }

    // Find the end of the first marker line
    const first_nl = std.mem.indexOfScalar(u8, body, '\n') orelse {
        meta.inputs.deinit();
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
            meta.inputs.deinit();
            return .{ .meta = null, .body = body };
        }

        rest = rest[advance..];
    }

    if (!found_end) {
        meta.inputs.deinit();
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
            meta.id = try allocator.dupe(u8, stripQuotes(value_raw));
        } else if (std.mem.eql(u8, key, "description")) {
            meta.description = try allocator.dupe(u8, stripQuotes(value_raw));
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
        } else if (std.mem.eql(u8, key, "inputs")) {
            // Parse nested input definitions
            try parseInputs(allocator, meta, lines, &i);
        }
    }

    meta.outputs = try outputs.toOwnedSlice(allocator);
    meta.depends = try depends.toOwnedSlice(allocator);
}

fn parseInputs(allocator: Allocator, meta: *FenceMeta, lines: []const []const u8, i: *usize) Allocator.Error!void {
    // After "inputs:" we expect lines indented by 2 spaces (input name)
    // then lines indented by 4 spaces (input fields)
    while (i.* + 1 < lines.len and std.mem.startsWith(u8, lines[i.* + 1], "  ")) {
        i.* += 1;
        const name_line = std.mem.trim(u8, lines[i.*], " \t");
        // Should end with ":"
        if (!std.mem.endsWith(u8, name_line, ":")) continue;
        const input_name = name_line[0 .. name_line.len - 1];

        var input_def: InputDef = .{
            .description = null,
            .default = null,
            .readonly = false,
        };

        // Parse the nested fields (4-space indent)
        while (i.* + 1 < lines.len and std.mem.startsWith(u8, lines[i.* + 1], "    ")) {
            i.* += 1;
            const field_line = std.mem.trim(u8, lines[i.*], " \t");
            const colon = std.mem.indexOfScalar(u8, field_line, ':') orelse continue;
            const fkey = std.mem.trim(u8, field_line[0..colon], " \t");
            const fval = std.mem.trim(u8, field_line[colon + 1 ..], " \t");

            if (std.mem.eql(u8, fkey, "description")) {
                input_def.description = try allocator.dupe(u8, stripQuotes(fval));
            } else if (std.mem.eql(u8, fkey, "default")) {
                input_def.default = try allocator.dupe(u8, stripQuotes(fval));
            } else if (std.mem.eql(u8, fkey, "readonly")) {
                input_def.readonly = std.mem.eql(u8, fval, "true");
            }
        }

        const owned_name = try allocator.dupe(u8, input_name);
        try meta.inputs.put(owned_name, input_def);
    }
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        return s[1 .. s.len - 1];
    }
    if (s.len >= 2 and s[0] == '\'' and s[s.len - 1] == '\'') {
        return s[1 .. s.len - 1];
    }
    return s;
}

pub fn deinit(allocator: Allocator, meta: *FenceMeta) void {
    if (meta.id) |v| allocator.free(v);
    if (meta.description) |v| allocator.free(v);
    for (meta.outputs) |v| allocator.free(v);
    allocator.free(meta.outputs);
    for (meta.depends) |v| allocator.free(v);
    allocator.free(meta.depends);

    var it = meta.inputs.iterator();
    while (it.next()) |kv| {
        allocator.free(kv.key_ptr.*);
        if (kv.value_ptr.description) |d| allocator.free(d);
        if (kv.value_ptr.default) |d| allocator.free(d);
    }
    meta.inputs.deinit();
}
