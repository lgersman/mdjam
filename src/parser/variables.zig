const std = @import("std");

const Allocator = std.mem.Allocator;

/// A single named variable declared in a `variables:` block — shared shape
/// for both document-level frontmatter variables and per-code-block
/// variables, so both parse and render identically.
pub const VariableDef = struct {
    description: ?[]const u8,
    default: ?[]const u8,
    readonly: bool,
    /// When true, this variable's current value is included in the JSON
    /// object mdjam prints to stdout on exit.
    output: bool,
};

pub const VariableMap = std.StringHashMap(VariableDef);

pub fn deinitVariables(allocator: Allocator, vars: *VariableMap) void {
    var it = vars.iterator();
    while (it.next()) |kv| {
        allocator.free(kv.key_ptr.*);
        if (kv.value_ptr.description) |d| allocator.free(d);
        if (kv.value_ptr.default) |d| allocator.free(d);
    }
    vars.deinit();
}

pub fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2) {
        if ((s[0] == '"' and s[s.len - 1] == '"') or
            (s[0] == '\'' and s[s.len - 1] == '\''))
        {
            return s[1 .. s.len - 1];
        }
    }
    return s;
}

/// Parses the body of a `variables:` block starting at `line_idx.*` (the
/// line right after the `variables:` header) and advances `line_idx.*` past
/// it — consuming every line indented by at least 2 spaces. Each entry may
/// be either a flat scalar:
///
///   name: value
///
/// (a default with no description), or a nested form:
///
///   name:
///     description: ...
///     default: ...
///     readonly: true
///     output: true
///
/// Used identically by document-level frontmatter (`variables:` at the top
/// of the YAML frontmatter) and by bash code-block metadata (`variables:`
/// inside the `# --- ... # ---` comment block) — both hand this function
/// plain, comment-stripped lines and a cursor into them.
pub fn parseVariablesSection(allocator: Allocator, vars: *VariableMap, lines: []const []const u8, line_idx: *usize) Allocator.Error!void {
    while (line_idx.* < lines.len) {
        const line = lines[line_idx.*];
        if (line.len == 0) break;

        var indent: usize = 0;
        while (indent < line.len and line[indent] == ' ') indent += 1;
        if (indent < 2) break;

        const trimmed = line[indent..];
        if (trimmed.len == 0 or indent != 2) {
            line_idx.* += 1;
            continue;
        }

        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse {
            line_idx.* += 1;
            continue;
        };
        const name = std.mem.trim(u8, trimmed[0..colon], " \t");
        const value_raw = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
        line_idx.* += 1;

        if (value_raw.len != 0) {
            // Shorthand: `name: value` — a default with no description.
            const owned_name = try allocator.dupe(u8, name);
            errdefer allocator.free(owned_name);
            const owned_default = try allocator.dupe(u8, stripQuotes(value_raw));
            try vars.put(owned_name, .{ .description = null, .default = owned_default, .readonly = false, .output = false });
            continue;
        }

        // Nested form: `name:` followed by `description:`/`default:`/`readonly:`/`output:` lines.
        var desc: ?[]const u8 = null;
        var default_val: ?[]const u8 = null;
        var readonly = false;
        var output = false;
        while (line_idx.* < lines.len) {
            const fline = lines[line_idx.*];
            if (fline.len == 0) break;
            var find: usize = 0;
            while (find < fline.len and fline[find] == ' ') find += 1;
            if (find < 4) break;

            const ftrimmed = fline[find..];
            const fcolon = std.mem.indexOfScalar(u8, ftrimmed, ':') orelse {
                line_idx.* += 1;
                continue;
            };
            const fkey = std.mem.trim(u8, ftrimmed[0..fcolon], " \t");
            const fval = stripQuotes(std.mem.trim(u8, ftrimmed[fcolon + 1 ..], " \t"));
            if (std.mem.eql(u8, fkey, "description")) {
                if (desc) |old| allocator.free(old);
                desc = try allocator.dupe(u8, fval);
            } else if (std.mem.eql(u8, fkey, "default")) {
                if (default_val) |old| allocator.free(old);
                default_val = try allocator.dupe(u8, fval);
            } else if (std.mem.eql(u8, fkey, "readonly")) {
                readonly = std.mem.eql(u8, fval, "true");
            } else if (std.mem.eql(u8, fkey, "output")) {
                output = std.mem.eql(u8, fval, "true");
            }
            line_idx.* += 1;
        }

        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        try vars.put(owned_name, .{ .description = desc, .default = default_val, .readonly = readonly, .output = output });
    }
}
