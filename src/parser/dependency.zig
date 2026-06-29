const std = @import("std");

const Allocator = std.mem.Allocator;

pub const DependencyError = error{CycleDetected} || Allocator.Error;

/// A node in the dependency graph.
pub const Node = struct {
    id: []const u8,
    depends: []const []const u8,
};

/// Perform topological sort using Kahn's algorithm.
/// Returns an ordered slice of block IDs (caller owns). Returns error.CycleDetected if a cycle
/// is found.
pub fn topoSort(allocator: Allocator, nodes: []const Node) DependencyError![][]const u8 {
    // Build a map from id → index
    var id_to_idx = std.StringHashMap(usize).init(allocator);
    defer id_to_idx.deinit();

    for (nodes, 0..) |node, i| {
        try id_to_idx.put(node.id, i);
    }

    // In-degree count
    const n = nodes.len;
    var in_degree = try allocator.alloc(usize, n);
    defer allocator.free(in_degree);
    @memset(in_degree, 0);

    // Adjacency list: for each node, which nodes depend on it
    var adj = try allocator.alloc(std.ArrayList(usize), n);
    defer {
        for (adj) |*list| list.deinit(allocator);
        allocator.free(adj);
    }
    for (adj) |*list| {
        list.* = std.ArrayList(usize).empty;
    }

    for (nodes, 0..) |node, i| {
        for (node.depends) |dep| {
            const dep_idx = id_to_idx.get(dep) orelse continue; // unknown dep, skip
            try adj[dep_idx].append(allocator, i);
            in_degree[i] += 1;
        }
    }

    // Initialize queue with nodes that have in_degree == 0
    var queue = std.ArrayList(usize).empty;
    defer queue.deinit(allocator);

    for (in_degree, 0..) |deg, i| {
        if (deg == 0) try queue.append(allocator, i);
    }

    var result = std.ArrayList([]const u8).empty;
    errdefer result.deinit(allocator);

    while (queue.items.len > 0) {
        const idx = queue.orderedRemove(0);
        try result.append(allocator, nodes[idx].id);

        for (adj[idx].items) |neighbor| {
            in_degree[neighbor] -= 1;
            if (in_degree[neighbor] == 0) {
                try queue.append(allocator, neighbor);
            }
        }
    }

    if (result.items.len != n) {
        result.deinit(allocator);
        return DependencyError.CycleDetected;
    }

    return try result.toOwnedSlice(allocator);
}
