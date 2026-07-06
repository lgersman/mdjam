const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Entry = struct {
    value: []const u8,
    set_by: ?[]const u8, // block ID that last set this key
};

/// Simple spinlock wrapper around std.atomic.Mutex
const SpinMutex = struct {
    inner: std.atomic.Mutex,

    const init_val: SpinMutex = .{ .inner = .unlocked };

    fn lock(self: *SpinMutex) void {
        while (!self.inner.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinMutex) void {
        self.inner.unlock();
    }
};

pub const StateStore = struct {
    mutex: SpinMutex,
    map: std.StringHashMap(Entry),
    allocator: Allocator,

    pub fn init(allocator: Allocator) StateStore {
        return .{
            .mutex = SpinMutex.init_val,
            .map = std.StringHashMap(Entry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StateStore) void {
        var it = self.map.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            self.allocator.free(kv.value_ptr.value);
            if (kv.value_ptr.set_by) |sb| self.allocator.free(sb);
        }
        self.map.deinit();
    }

    /// Set a key. Caller does not need to keep key/value/block_id alive after this call.
    pub fn set(self: *StateStore, key: []const u8, value: []const u8, block_id: ?[]const u8) Allocator.Error!void {
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);
        const owned_block_id: ?[]const u8 = if (block_id) |bid|
            try self.allocator.dupe(u8, bid)
        else
            null;
        errdefer if (owned_block_id) |sb| self.allocator.free(sb);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.map.getPtr(key)) |existing| {
            self.allocator.free(existing.value);
            if (existing.set_by) |sb| self.allocator.free(sb);
            existing.value = owned_value;
            existing.set_by = owned_block_id;
            self.allocator.free(owned_key);
        } else {
            try self.map.put(owned_key, .{ .value = owned_value, .set_by = owned_block_id });
        }
    }

    /// Get a copy of the value. Caller owns the returned slice.
    pub fn getCopy(self: *StateStore, key: []const u8, allocator: Allocator) Allocator.Error!?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.map.get(key) orelse return null;
        return try allocator.dupe(u8, entry.value);
    }

    /// Returns all entries. Caller owns the returned slice and its contents.
    pub fn getAll(self: *StateStore, allocator: Allocator) Allocator.Error![]KV {
        self.mutex.lock();
        defer self.mutex.unlock();

        var list = std.ArrayList(KV).empty;
        errdefer {
            for (list.items) |kv| {
                allocator.free(kv.key);
                allocator.free(kv.value);
            }
            list.deinit(allocator);
        }

        var it = self.map.iterator();
        while (it.next()) |kv| {
            try list.append(allocator, .{
                .key = try allocator.dupe(u8, kv.key_ptr.*),
                .value = try allocator.dupe(u8, kv.value_ptr.value),
            });
        }
        return try list.toOwnedSlice(allocator);
    }

    pub fn clear(self: *StateStore) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.map.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            self.allocator.free(kv.value_ptr.value);
            if (kv.value_ptr.set_by) |sb| self.allocator.free(sb);
        }
        self.map.clearRetainingCapacity();
    }
};

pub const KV = struct {
    key: []const u8,
    value: []const u8,
};
