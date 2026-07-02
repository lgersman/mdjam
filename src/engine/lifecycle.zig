const std = @import("std");
const state_store = @import("state_store.zig");
const c = @cImport({
    @cInclude("sys/wait.h");
});

const Allocator = std.mem.Allocator;

pub const LifecycleError = Allocator.Error || std.process.SpawnError || error{RunFailed};

/// Result of running a lifecycle script. Always populated (regardless of exit
/// status) so the caller can decide what to do with stdout/stderr — e.g. show
/// it to the user (gated by verbosity) and/or propagate the exit code.
pub const RunResult = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *RunResult, allocator: Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Run the `setup` script. On success (exit code 0), `::set-output`/export
/// lines in stdout are written to the state store. Always returns the full
/// result (including on failure) so the caller can surface output/exit code.
pub fn runSetup(
    allocator: Allocator,
    io: std.Io,
    script: []const u8,
    store: *state_store.StateStore,
    environ_map: *const std.process.Environ.Map,
) LifecycleError!RunResult {
    const result = try runScript(allocator, io, script, environ_map, store);
    if (result.exit_code == 0) {
        // Parse exports from stdout. Format: "KEY=value" lines (from `export -p` or simple assignments)
        parseExports(allocator, store, result.stdout, null);
    }
    return result;
}

/// Run the `teardown` script. Always returns the full result so the caller
/// can surface output/exit code.
pub fn runTeardown(
    allocator: Allocator,
    io: std.Io,
    script: []const u8,
    store: *state_store.StateStore,
    environ_map: *const std.process.Environ.Map,
) LifecycleError!RunResult {
    return runScript(allocator, io, script, environ_map, store);
}

fn runScript(
    allocator: Allocator,
    io: std.Io,
    script: []const u8,
    environ_map: *const std.process.Environ.Map,
    store: *state_store.StateStore,
) LifecycleError!RunResult {
    // Build environment
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var parent_it = environ_map.iterator();
    while (parent_it.next()) |kv| {
        try env_map.put(kv.key_ptr.*, kv.value_ptr.*);
    }

    // Inject state store as MDJAM_* vars
    const all_state = store.getAll(allocator) catch &.{};
    defer {
        for (all_state) |kv| {
            allocator.free(kv.key);
            allocator.free(kv.value);
        }
        allocator.free(all_state);
    }

    for (all_state) |kv| {
        var key_buf = try allocator.alloc(u8, "MDJAM_".len + kv.key.len);
        defer allocator.free(key_buf);
        @memcpy(key_buf[0..6], "MDJAM_");
        for (kv.key, 0..) |ch, idx| {
            key_buf[6 + idx] = if (std.ascii.isAlphanumeric(ch)) std.ascii.toUpper(ch) else '_';
        }
        try env_map.put(key_buf, kv.value);
    }

    const argv: []const []const u8 = &.{ "/bin/bash", "-c", script };

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = &env_map,
        .stdout = .pipe,
        .stderr = .pipe,
        .stdin = .ignore,
    });

    var stdout_data = std.ArrayList(u8).empty;
    defer stdout_data.deinit(allocator);
    var stderr_data = std.ArrayList(u8).empty;
    defer stderr_data.deinit(allocator);

    // Use raw POSIX read() to avoid std.Io.Threaded event loop issues
    if (child.stdout) |f| {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = std.posix.read(f.handle, &buf) catch break;
            if (n == 0) break;
            try stdout_data.appendSlice(allocator, buf[0..n]);
        }
        child.stdout = null;
    }
    if (child.stderr) |f| {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = std.posix.read(f.handle, &buf) catch break;
            if (n == 0) break;
            try stderr_data.appendSlice(allocator, buf[0..n]);
        }
        child.stderr = null;
    }

    // Use C waitpid to avoid std.Io.Threaded issues
    const pid = child.id orelse return error.RunFailed;
    var wstatus: c_int = 0;
    _ = c.waitpid(@as(c.pid_t, @intCast(pid)), &wstatus, 0);
    child.id = null;
    child.stdin = null;

    const exited: bool = c.WIFEXITED(wstatus);
    const exit_code: u8 = if (exited) @intCast(c.WEXITSTATUS(wstatus)) else 1;

    return .{
        .exit_code = exit_code,
        .stdout = try stdout_data.toOwnedSlice(allocator),
        .stderr = try stderr_data.toOwnedSlice(allocator),
    };
}

fn parseExports(allocator: Allocator, store: *state_store.StateStore, data: []const u8, block_id: ?[]const u8) void {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // Handle ::set-output name=KEY::VALUE format
        if (std.mem.startsWith(u8, trimmed, "::set-output name=")) {
            const rest = trimmed["::set-output name=".len..];
            const sep = std.mem.indexOf(u8, rest, "::") orelse continue;
            const key = rest[0..sep];
            const value = rest[sep + 2 ..];
            store.set(key, value, block_id) catch {};
            continue;
        }

        // Strip "export " prefix if present
        const assignment = if (std.mem.startsWith(u8, trimmed, "export "))
            trimmed["export ".len..]
        else
            trimmed;

        // Find KEY=value
        const eq = std.mem.indexOfScalar(u8, assignment, '=') orelse continue;
        const key = assignment[0..eq];
        var value = assignment[eq + 1 ..];

        // Strip surrounding quotes if present
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        } else if (value.len >= 2 and value[0] == '\'' and value[value.len - 1] == '\'') {
            value = value[1 .. value.len - 1];
        }

        store.set(key, value, block_id) catch {};
        _ = allocator;
    }
}
