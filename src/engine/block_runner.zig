const std = @import("std");
const state_store = @import("state_store.zig");

const Allocator = std.mem.Allocator;

pub const RunStatus = enum {
    idle,
    running,
    done,
    failed,
    cancelled,
    blocked,
};

pub const ExecResult = struct {
    exit_code: u8,
    status: RunStatus,
};

/// Called for each output line (stdout or stderr)
pub const OutputCallback = *const fn (ctx: ?*anyopaque, line: []const u8, is_stderr: bool) void;

/// Called when execution completes
pub const DoneCallback = *const fn (ctx: ?*anyopaque, result: ExecResult) void;

pub const RunOptions = struct {
    script: []const u8,
    block_id: ?[]const u8,
    store: *state_store.StateStore,
    environ_map: *const std.process.Environ.Map,
    allocator: Allocator,
    io: std.Io,
    output_cb: OutputCallback,
    done_cb: DoneCallback,
    cb_ctx: ?*anyopaque,
};

/// Execution state shared between the runner thread and the outside world.
pub const Runner = struct {
    mutex: std.atomic.Mutex,
    status: RunStatus,
    child_id: ?std.process.Child.Id,

    pub fn init() Runner {
        return .{
            .mutex = .unlocked,
            .status = .idle,
            .child_id = null,
        };
    }

    pub fn getStatus(self: *Runner) RunStatus {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();
        return self.status;
    }

    pub fn cancel(self: *Runner) void {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();
        if (self.status != .running) return;
        self.status = .cancelled;
        // Send SIGTERM to child if we have its pid
        if (self.child_id) |pid| {
            std.posix.kill(pid, std.posix.SIG.TERM) catch {};
        }
    }
};

/// Spawns a thread to run the script. Returns immediately.
/// The caller must keep `opts` alive until the done callback fires.
pub fn runAsync(runner: *Runner, opts: RunOptions) (Allocator.Error || std.Thread.SpawnError)!std.Thread {
    while (!runner.mutex.tryLock()) { std.atomic.spinLoopHint(); }
    runner.status = .running;
    runner.mutex.unlock();

    const ctx = try opts.allocator.create(ThreadCtx);
    ctx.* = .{
        .opts = opts,
        .runner = runner,
    };

    const thread = try std.Thread.spawn(.{}, threadFn, .{ctx});
    return thread;
}

const ThreadCtx = struct {
    opts: RunOptions,
    runner: *Runner,
};

fn threadFn(ctx: *ThreadCtx) void {
    defer ctx.opts.allocator.destroy(ctx);
    runSync(ctx.runner, ctx.opts);
}

fn runSync(runner: *Runner, opts: RunOptions) void {
    // Build environment map: inherit parent env + inject state store values
    var env_map = std.process.Environ.Map.init(opts.allocator);
    defer env_map.deinit();

    // Copy parent environment
    var parent_it = opts.environ_map.iterator();
    while (parent_it.next()) |kv| {
        env_map.put(kv.key_ptr.*, kv.value_ptr.*) catch return;
    }

    // Inject state store values as MDJAM_KEY env vars
    const all_state = opts.store.getAll(opts.allocator) catch return;
    defer {
        for (all_state) |kv| {
            opts.allocator.free(kv.key);
            opts.allocator.free(kv.value);
        }
        opts.allocator.free(all_state);
    }

    for (all_state) |kv| {
        // Sanitize key: uppercase, replace non-alphanumeric with _
        var key_buf = opts.allocator.alloc(u8, "MDJAM_".len + kv.key.len) catch return;
        defer opts.allocator.free(key_buf);
        @memcpy(key_buf[0..6], "MDJAM_");
        for (kv.key, 0..) |c, idx| {
            key_buf[6 + idx] = if (std.ascii.isAlphanumeric(c)) std.ascii.toUpper(c) else '_';
        }
        env_map.put(key_buf, kv.value) catch return;
    }

    const argv: []const []const u8 = &.{ "/bin/bash", "-c", opts.script };

    var child = std.process.spawn(opts.io, .{
        .argv = argv,
        .environ_map = &env_map,
        .stdout = .pipe,
        .stderr = .pipe,
        .stdin = .ignore,
    }) catch |err| {
        const msg = std.fmt.allocPrint(opts.allocator, "Failed to spawn: {}", .{err}) catch return;
        defer opts.allocator.free(msg);
        opts.output_cb(opts.cb_ctx, msg, true);
        while (!runner.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        runner.status = .failed;
        runner.mutex.unlock();
        opts.done_cb(opts.cb_ctx, .{ .exit_code = 1, .status = .failed });
        return;
    };

    // Store child id for cancellation
    while (!runner.mutex.tryLock()) { std.atomic.spinLoopHint(); }
    runner.child_id = child.id;
    runner.mutex.unlock();

    // Read stdout and stderr in the same thread (sequential). For a full implementation
    // we would use two threads, but this is sufficient for v1.
    var stdout_buf = std.ArrayList(u8).empty;
    defer stdout_buf.deinit(opts.allocator);
    var stderr_buf = std.ArrayList(u8).empty;
    defer stderr_buf.deinit(opts.allocator);

    if (child.stdout) |stdout_file| {
        readAndEmit(opts, stdout_file, &stdout_buf, false);
    }
    if (child.stderr) |stderr_file| {
        readAndEmit(opts, stderr_file, &stderr_buf, true);
    }

    // Use raw Linux waitpid syscall to avoid std.Io.Threaded deadlocks from std.Thread.
    const pid = child.id orelse {
        while (!runner.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        runner.status = .failed;
        runner.mutex.unlock();
        opts.done_cb(opts.cb_ctx, .{ .exit_code = 1, .status = .failed });
        return;
    };
    var wstatus: u32 = 0;
    _ = std.os.linux.waitpid(pid, &wstatus, 0);
    // Clear child fields so child.wait isn't called again
    child.id = null;
    child.stdout = null;
    child.stderr = null;
    child.stdin = null;

    const exited = (wstatus & 0x7f) == 0;
    const exit_byte: u8 = if (exited) @truncate((wstatus >> 8) & 0xff) else 1;

    while (!runner.mutex.tryLock()) { std.atomic.spinLoopHint(); }
    const was_cancelled = runner.status == .cancelled;
    runner.mutex.unlock();

    const exit_code: u8 = exit_byte;

    const final_status: RunStatus = if (was_cancelled)
        .cancelled
    else if (exit_code == 0)
        .done
    else
        .failed;

    // Parse ::set-output lines from stdout
    parseSetOutputLines(opts, stdout_buf.items);

    while (!runner.mutex.tryLock()) { std.atomic.spinLoopHint(); }
    runner.status = final_status;
    runner.child_id = null;
    runner.mutex.unlock();

    opts.done_cb(opts.cb_ctx, .{ .exit_code = exit_code, .status = final_status });
}

// Use raw POSIX read() to avoid std.Io.Threaded scheduler deadlocks from std.Thread.
fn readAndEmit(opts: RunOptions, file: std.Io.File, buf: *std.ArrayList(u8), is_stderr: bool) void {
    const fd = file.handle;
    var line_buf: [4096]u8 = undefined;
    var remainder: usize = 0;

    while (true) {
        const n = std.posix.read(fd, line_buf[remainder..]) catch break;
        if (n == 0) break; // EOF
        const total = remainder + n;
        const data = line_buf[0..total];

        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, data, start, '\n')) |nl| {
            const line = data[start..nl];
            buf.appendSlice(opts.allocator, line) catch {};
            buf.append(opts.allocator, '\n') catch {};
            opts.output_cb(opts.cb_ctx, line, is_stderr);
            start = nl + 1;
        }

        remainder = total - start;
        if (remainder > 0) {
            std.mem.copyForwards(u8, &line_buf, data[start..]);
        }
    }

    if (remainder > 0) {
        const line = line_buf[0..remainder];
        buf.appendSlice(opts.allocator, line) catch {};
        opts.output_cb(opts.cb_ctx, line, is_stderr);
    }
}

fn parseSetOutputLines(opts: RunOptions, stdout: []const u8) void {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        const prefix = "::set-output name=";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const rest = line[prefix.len..];
        const double_colon = std.mem.indexOf(u8, rest, "::") orelse continue;
        const key = rest[0..double_colon];
        const value = rest[double_colon + 2 ..];
        opts.store.set(key, value, opts.block_id) catch {};
    }
}
