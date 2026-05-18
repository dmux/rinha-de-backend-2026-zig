const std = @import("std");
const domain = @import("domain");
const types = domain.types;

const Vector16i16 = types.Vector16i16;
const SpecialistHeader = types.SpecialistHeader;
const PartitionEntry = types.PartitionEntry;
const KDNode = types.KDNode;
const VecBlock = types.VecBlock;
const SENTINEL = types.SENTINEL;

const LEAF_SIZE: u32 = 32; // vectors per leaf (4 blocks of 8)

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();
    const arg0 = args_iter.next() orelse "preprocess";
    const input_path = args_iter.next() orelse {
        std.debug.print("Usage: {s} <input.json.gz> <output.bin>\n", .{arg0});
        return;
    };
    const output_path = args_iter.next() orelse {
        std.debug.print("Usage: {s} <input.json.gz> <output.bin>\n", .{arg0});
        return;
    };

    std.debug.print("Loading vectors from {s}...\n", .{input_path});
    var vectors: std.ArrayListUnmanaged(Vector16i16) = .empty;
    var labels: std.ArrayListUnmanaged(u8) = .empty;
    defer vectors.deinit(allocator);
    defer labels.deinit(allocator);

    try loadVectors(init, input_path, &vectors, &labels);
    std.debug.print("Loaded {d} vectors\n", .{vectors.items.len});

    const n = vectors.items.len;

    // Step 1: Compute partition keys and group vectors into 256 buckets
    std.debug.print("Partitioning into 256 buckets...\n", .{});
    var buckets: [256]std.ArrayListUnmanaged(u32) = undefined;
    for (&buckets) |*b| b.* = .empty;
    defer for (&buckets) |*b| b.deinit(allocator);

    for (0..n) |i| {
        const key = domain.vectorizer.partitionKey(vectors.items[i]);
        try buckets[key].append(allocator, @intCast(i));
    }

    // Print partition stats
    var non_empty: u32 = 0;
    var max_bucket: u32 = 0;
    for (&buckets) |*b| {
        if (b.items.len > 0) non_empty += 1;
        if (b.items.len > max_bucket) max_bucket = @intCast(b.items.len);
    }
    std.debug.print("Non-empty partitions: {d}/256, max bucket: {d}\n", .{ non_empty, max_bucket });

    // Step 2: Build KD-tree for each partition
    std.debug.print("Building KD-trees...\n", .{});

    var all_nodes: std.ArrayListUnmanaged(KDNode) = .empty;
    defer all_nodes.deinit(allocator);
    var all_blocks: std.ArrayListUnmanaged(VecBlock) = .empty;
    defer all_blocks.deinit(allocator);

    // Pre-allocate with generous capacities
    try all_nodes.ensureTotalCapacity(allocator, n / 8);
    try all_blocks.ensureTotalCapacity(allocator, n / 8 + 1024);

    var partitions: [256]PartitionEntry = std.mem.zeroes([256]PartitionEntry);

    for (0..256) |pi| {
        const bucket = &buckets[pi];
        const node_start: u32 = @intCast(all_nodes.items.len);
        const block_start: u32 = @intCast(all_blocks.items.len);

        partitions[pi].node_start = node_start;
        partitions[pi].block_start = block_start;

        if (bucket.items.len == 0) {
            partitions[pi].node_count = 0;
            partitions[pi].block_count = 0;
            partitions[pi].root = 0;
            continue;
        }

        // Build a temporary sorted index array for this partition
        const idx_slice = try allocator.alloc(u32, bucket.items.len);
        defer allocator.free(idx_slice);
        @memcpy(idx_slice, bucket.items);

        // Compute bounding box for the whole partition
        computeBoundingBox(vectors.items, idx_slice, &partitions[pi].min, &partitions[pi].max);

        // Build KD-tree recursively (iterative via explicit stack)
        const root = try buildKDTree(
            allocator,
            vectors.items,
            labels.items,
            idx_slice,
            &all_nodes,
            &all_blocks,
        );
        partitions[pi].root = root; // absolute index into all_nodes
        partitions[pi].node_count = @intCast(all_nodes.items.len - node_start);
        partitions[pi].block_count = @intCast(all_blocks.items.len - block_start);
    }

    std.debug.print("Built {d} nodes, {d} blocks\n", .{ all_nodes.items.len, all_blocks.items.len });

    // Step 3: Serialize to file
    std.debug.print("Writing index to {s}...\n", .{output_path});
    try writeIndex(init, output_path, &partitions, all_nodes.items, all_blocks.items, @intCast(n));
    std.debug.print("Done.\n", .{});
}

// Build KD-tree for a set of vector indices; returns absolute node index of root
fn buildKDTree(
    allocator: std.mem.Allocator,
    vecs: []const Vector16i16,
    lbls: []const u8,
    indices: []u32,
    nodes: *std.ArrayListUnmanaged(KDNode),
    blocks: *std.ArrayListUnmanaged(VecBlock),
) !u32 {
    const BuildTask = struct {
        indices_start: u32,
        indices_end: u32,
        node_idx: u32,
    };

    // Flat work queue (avoids deep recursion for 3M vectors)
    var work: std.ArrayListUnmanaged(BuildTask) = .empty;
    defer work.deinit(allocator);

    // Reserve a slot for root node
    const root_idx: u32 = @intCast(nodes.items.len);
    try nodes.append(allocator, std.mem.zeroes(KDNode));
    try work.append(allocator, .{ .indices_start = 0, .indices_end = @intCast(indices.len), .node_idx = root_idx });

    while (work.pop()) |task| {
        const count = task.indices_end - task.indices_start;
        const idx_slice = indices[task.indices_start..task.indices_end];

        // Compute bounding box for this node
        var bb_min: [16]i16 = undefined;
        var bb_max: [16]i16 = undefined;
        computeBoundingBox(vecs, idx_slice, &bb_min, &bb_max);

        nodes.items[task.node_idx].min = bb_min;
        nodes.items[task.node_idx].max = bb_max;

        if (count <= LEAF_SIZE) {
            // Leaf node: pack vectors into VecBlocks
            const block_start: u32 = @intCast(blocks.items.len);
            try packBlocks(allocator, vecs, lbls, idx_slice, blocks);
            nodes.items[task.node_idx].left = 0xFFFFFFFF;
            nodes.items[task.node_idx].right = 0xFFFFFFFF;
            nodes.items[task.node_idx].start = block_start;
            nodes.items[task.node_idx].count = @intCast(blocks.items.len - block_start);
        } else {
            // Internal node: split on dimension with maximum variance
            const split_dim = findSplitDim(vecs, idx_slice, &bb_min, &bb_max);
            const mid = count / 2;

            // Partial sort (nth_element equivalent): median split
            partialSort(vecs, idx_slice, split_dim, mid);

            // Reserve child nodes
            const left_idx: u32 = @intCast(nodes.items.len);
            try nodes.append(allocator, std.mem.zeroes(KDNode));
            const right_idx: u32 = @intCast(nodes.items.len);
            try nodes.append(allocator, std.mem.zeroes(KDNode));

            nodes.items[task.node_idx].left = left_idx;
            nodes.items[task.node_idx].right = right_idx;
            nodes.items[task.node_idx].start = 0;
            nodes.items[task.node_idx].count = 0;

            try work.append(allocator, .{ .indices_start = task.indices_start, .indices_end = task.indices_start + mid, .node_idx = left_idx });
            try work.append(allocator, .{ .indices_start = task.indices_start + mid, .indices_end = task.indices_end, .node_idx = right_idx });
        }
    }

    return root_idx;
}

fn computeBoundingBox(vecs: []const Vector16i16, indices: []const u32, bb_min: *[16]i16, bb_max: *[16]i16) void {
    @memset(bb_min, std.math.maxInt(i16));
    @memset(bb_max, std.math.minInt(i16));

    for (indices) |idx| {
        const v = &vecs[idx];
        // Include SENTINEL (-10000) in the bounding box so lowerBound can
        // prune subtrees where query-has-last-tx but node-doesn't (or vice versa).
        for (0..14) |d| {
            if (v[d] < bb_min[d]) bb_min[d] = v[d];
            if (v[d] > bb_max[d]) bb_max[d] = v[d];
        }
    }
    // Padding dims 14,15 with 0
    bb_min[14] = 0;
    bb_max[14] = 0;
    bb_min[15] = 0;
    bb_max[15] = 0;
}

// Find the dimension with the largest spread (max-min) for splitting.
// SENTINEL (-10000) is included in the range, so dims where all vectors have
// SENTINEL have spread=0 and are skipped naturally.
fn findSplitDim(vecs: []const Vector16i16, indices: []const u32, bb_min: *const [16]i16, bb_max: *const [16]i16) u8 {
    _ = vecs;
    _ = indices;
    var best_dim: u8 = 0;
    var best_spread: i32 = -1;
    for (0..14) |d| {
        const spread: i32 = @as(i32, bb_max[d]) - @as(i32, bb_min[d]);
        if (spread <= 0) continue; // all-same value (including all-SENTINEL) → no useful split
        if (spread > best_spread) {
            best_spread = spread;
            best_dim = @intCast(d);
        }
    }
    return best_dim;
}

// Partial sort to put median at position mid; elements before mid <= median, after >= median
fn partialSort(vecs: []const Vector16i16, indices: []u32, dim: u8, mid: usize) void {
    // Introselect / quickselect variant
    var lo: usize = 0;
    var hi: usize = indices.len - 1;

    while (lo < hi) {
        // Median-of-three pivot
        const m = lo + (hi - lo) / 2;
        const pivot_val = getVal(vecs[indices[m]], dim);

        // Three-way partition
        var i = lo;
        var j = lo;
        var k = hi;

        while (j <= k) {
            const v = getVal(vecs[indices[j]], dim);
            if (v < pivot_val) {
                const tmp = indices[i];
                indices[i] = indices[j];
                indices[j] = tmp;
                i += 1;
                j += 1;
            } else if (v > pivot_val) {
                const tmp = indices[j];
                indices[j] = indices[k];
                indices[k] = tmp;
                if (k == 0) break;
                k -= 1;
            } else {
                j += 1;
            }
        }

        if (mid < i) {
            hi = if (i > 0) i - 1 else 0;
        } else if (mid >= j) {
            lo = j;
        } else {
            break; // mid is in the equal-to-pivot region
        }
    }
}

inline fn getVal(v: Vector16i16, dim: u8) i16 {
    return v[dim]; // SENTINEL (-10000) sorts to the low end, separating it from real values
}

// Pack a slice of vector indices into VecBlocks (AoSoA layout)
fn packBlocks(
    allocator: std.mem.Allocator,
    vecs: []const Vector16i16,
    lbls: []const u8,
    indices: []const u32,
    blocks: *std.ArrayListUnmanaged(VecBlock),
) !void {
    var i: usize = 0;
    while (i < indices.len) {
        var blk: VecBlock = std.mem.zeroes(VecBlock);
        const lane_count = @min(8, indices.len - i);

        for (0..lane_count) |lane| {
            const idx = indices[i + lane];
            const v = &vecs[idx];
            for (0..16) |d| {
                blk.dims[d][lane] = v[d];
            }
            blk.labels[lane] = lbls[idx];
        }

        // Pad unused lanes with SENTINEL so they never match
        for (lane_count..8) |lane| {
            for (0..16) |d| {
                blk.dims[d][lane] = SENTINEL;
            }
            blk.labels[lane] = 0;
        }

        blk._pad[0] = @intCast(lane_count); // valid lane count (1..8) stored in _pad[0]
        try blocks.append(allocator, blk);
        i += lane_count;
    }
}

fn loadVectors(
    init: std.process.Init,
    path: []const u8,
    vectors: *std.ArrayListUnmanaged(Vector16i16),
    labels: *std.ArrayListUnmanaged(u8),
) !void {
    const allocator = init.gpa;

    const file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);

    const file_buf = try allocator.alloc(u8, 1 << 16);
    defer allocator.free(file_buf);
    var file_reader = file.reader(init.io, file_buf);

    const data = if (std.mem.endsWith(u8, path, ".gz")) blk: {
        const decomp_buf = try allocator.alloc(u8, 1 << 16);
        defer allocator.free(decomp_buf);
        var decomp = std.compress.flate.Decompress.init(&file_reader.interface, .gzip, decomp_buf);
        var aw: std.Io.Writer.Allocating = .init(allocator);
        _ = try decomp.reader.streamRemaining(&aw.writer);
        break :blk try aw.toOwnedSlice();
    } else blk: {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        _ = try file_reader.interface.streamRemaining(&aw.writer);
        break :blk try aw.toOwnedSlice();
    };
    defer allocator.free(data);

    var scanner = std.json.Scanner.initCompleteInput(allocator, data);
    defer scanner.deinit();

    try vectors.ensureTotalCapacity(allocator, 3_100_000);
    try labels.ensureTotalCapacity(allocator, 3_100_000);

    var tok = try scanner.next();
    if (tok != .array_begin) return error.BadJson;

    while (true) {
        tok = try scanner.next();
        if (tok == .array_end) break;
        if (tok != .object_begin) return error.BadJson;

        var vec_f32: [14]f32 = undefined;
        var is_fraud: bool = false;
        var got_vector = false;
        var got_label = false;

        while (true) {
            const key_tok = try scanner.next();
            if (key_tok == .object_end) break;

            const key = switch (key_tok) {
                .string => |s| s,
                else => return error.BadJson,
            };

            if (std.mem.eql(u8, key, "vector")) {
                const arr_tok = try scanner.next();
                if (arr_tok != .array_begin) return error.BadJson;
                for (&vec_f32) |*f| {
                    const num_tok = try scanner.nextAlloc(allocator, .alloc_if_needed);
                    switch (num_tok) {
                        .number => |s| f.* = try std.fmt.parseFloat(f32, s),
                        .allocated_number => |s| {
                            defer allocator.free(s);
                            f.* = try std.fmt.parseFloat(f32, s);
                        },
                        else => return error.BadJson,
                    }
                }
                const arr_end = try scanner.next();
                if (arr_end != .array_end) return error.BadJson;
                got_vector = true;
            } else if (std.mem.eql(u8, key, "label")) {
                const str_tok = try scanner.nextAlloc(allocator, .alloc_if_needed);
                switch (str_tok) {
                    .string => |s| is_fraud = std.mem.eql(u8, s, "fraud"),
                    .allocated_string => |s| {
                        defer allocator.free(s);
                        is_fraud = std.mem.eql(u8, s, "fraud");
                    },
                    else => return error.BadJson,
                }
                got_label = true;
            } else {
                try scanner.skipValue();
            }
        }

        if (!got_vector or !got_label) return error.MissingFields;

        // Quantize f32 → i16
        var v: Vector16i16 = [_]i16{0} ** 16;
        for (0..14) |i| {
            v[i] = if (vec_f32[i] < -0.5)
                SENTINEL
            else
                @intCast(@min(10000, @max(-9999, @as(i32, @intFromFloat(@round(vec_f32[i] * 10000.0))))));
        }

        try vectors.append(allocator, v);
        try labels.append(allocator, if (is_fraud) 1 else 0);
    }
}

fn writeIndex(
    init: std.process.Init,
    path: []const u8,
    partitions: *const [256]PartitionEntry,
    nodes: []const KDNode,
    blocks: []const VecBlock,
    n_vectors: u32,
) !void {
    const allocator = init.gpa;

    const file = try std.Io.Dir.cwd().createFile(init.io, path, .{});
    defer file.close(init.io);

    const write_buf = try allocator.alloc(u8, 1 << 20); // 1MB write buffer
    defer allocator.free(write_buf);
    var fw = file.writer(init.io, write_buf);
    const w = &fw.interface;

    const header = SpecialistHeader{
        .n_vectors = n_vectors,
        .n_nodes = @intCast(nodes.len),
        .n_blocks = @intCast(blocks.len),
    };
    try w.writeAll(std.mem.asBytes(&header));
    try w.writeAll(std.mem.sliceAsBytes(partitions));
    try w.writeAll(std.mem.sliceAsBytes(nodes));
    try w.writeAll(std.mem.sliceAsBytes(blocks));
    try w.flush();

    const index_size = @sizeOf(SpecialistHeader) + 256 * @sizeOf(PartitionEntry) +
        nodes.len * @sizeOf(KDNode) + blocks.len * @sizeOf(VecBlock);
    std.debug.print("Index size: {d:.1} MB\n", .{@as(f64, @floatFromInt(index_size)) / (1024.0 * 1024.0)});
}
