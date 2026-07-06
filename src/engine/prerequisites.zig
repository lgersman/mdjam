const std = @import("std");
const c = @cImport({
    @cInclude("sys/wait.h");
});

const Allocator = std.mem.Allocator;

pub const FailedCheck = struct {
    kind: Kind,
    name: []const u8,

    pub const Kind = enum { tool, env };
};

/// Check that all prerequisite tools are available (via PATH lookup) and env vars are set.
/// Returns a list of failed checks. Caller owns the returned slice and each name string.
pub fn check(
    allocator: Allocator,
    io: std.Io,
    tools: []const []const u8,
    envs: []const []const u8,
    environ_map: *const std.process.Environ.Map,
) Allocator.Error![]FailedCheck {
    var failed = std.ArrayList(FailedCheck).empty;
    errdefer {
        for (failed.items) |f| allocator.free(f.name);
        failed.deinit(allocator);
    }

    for (tools) |tool| {
        if (!toolAvailable(io, tool)) {
            try failed.append(allocator, .{
                .kind = .tool,
                .name = try allocator.dupe(u8, tool),
            });
        }
    }

    for (envs) |env_key| {
        if (environ_map.get(env_key) == null) {
            try failed.append(allocator, .{
                .kind = .env,
                .name = try allocator.dupe(u8, env_key),
            });
        }
    }

    return try failed.toOwnedSlice(allocator);
}

fn toolAvailable(io: std.Io, tool: []const u8) bool {
    const argv: []const []const u8 = &.{ "/usr/bin/which", tool };
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdout = .ignore,
        .stderr = .ignore,
        .stdin = .ignore,
    }) catch return false;

    child.stdout = null;
    child.stderr = null;
    child.stdin = null;
    const pid = child.id orelse return false;
    var wstatus: c_int = 0;
    _ = c.waitpid(@as(c.pid_t, @intCast(pid)), &wstatus, 0);
    child.id = null;
    const exited: bool = c.WIFEXITED(wstatus);
    const code: u8 = if (exited) @intCast(c.WEXITSTATUS(wstatus)) else 1;
    return code == 0;
}

pub fn freeChecks(allocator: Allocator, checks: []const FailedCheck) void {
    for (checks) |ch| allocator.free(@constCast(ch.name));
    allocator.free(checks);
}

/// Format a human-readable, multi-line explanation of failed prerequisite
/// checks for a given file, suitable for printing to stderr. Caller owns the
/// returned slice.
pub fn formatFailures(
    allocator: Allocator,
    file_path: []const u8,
    failed: []const FailedCheck,
) Allocator.Error![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    const header = try std.fmt.allocPrint(
        allocator,
        "mdjam: prerequisites not met for '{s}':\n",
        .{file_path},
    );
    defer allocator.free(header);
    try buf.appendSlice(allocator, header);

    for (failed) |f| {
        const line = try std.fmt.allocPrint(allocator, "  - missing {s}: {s}\n", .{
            if (f.kind == .tool) "tool" else "env var",
            f.name,
        });
        defer allocator.free(line);
        try buf.appendSlice(allocator, line);
    }

    return buf.toOwnedSlice(allocator);
}
