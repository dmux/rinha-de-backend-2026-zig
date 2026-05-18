const std = @import("std");
const types = @import("../../domain/types.zig");
const vector_store = @import("../../ports/vector_store.zig");
const linux = std.os.linux;

const Vector16i16 = types.Vector16i16;
const SearchResult = types.SearchResult;
const SpecialistHeader = types.SpecialistHeader;
const PartitionEntry = types.PartitionEntry;
const KDNode = types.KDNode;
const VecBlock = types.VecBlock;
const SENTINEL = types.SENTINEL;
const SCALE = types.SCALE;

const SCALE_F32: f32 = @floatFromInt(SCALE);
const INV_SCALE: f32 = 1.0 / SCALE_F32;

// Search at most this many non-empty partitions per query.
// LB pruning cuts off far partitions; this caps worst-case when pruning is loose.
const MAX_PARTITIONS: usize = 32;

pub const SpecialistStore = struct {
    header: SpecialistHeader,
    partitions: *[256]PartitionEntry,
    nodes: []KDNode,
    blocks: []VecBlock,
    mmap_ptr: ?[*]align(4096) u8,
    mmap_len: usize,
    allocator: std.mem.Allocator,

    pub fn initFromFile(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !*SpecialistStore {
        const file = try dir.openFile(io, path, .{});
        defer file.close(io);

        const stat = try file.stat(io);
        const size = stat.size;

        // MAP_POPULATE preloads pages; MADV_WILLNEED keeps them warm
        const mmap_res = linux.syscall6(.mmap, 0, size, 1, 2 | 0x8000, @as(usize, @bitCast(@as(isize, file.handle))), 0);
        const mmap_ptr: [*]align(4096) u8 = @ptrFromInt(mmap_res);
        _ = linux.syscall3(.madvise, mmap_res, size, 3);
        const data = mmap_ptr[0..size];

        var pos: usize = 0;

        const hdr: *SpecialistHeader = @ptrCast(@alignCast(&data[pos]));
        if (hdr.magic != SpecialistHeader.MAGIC) return error.InvalidMagic;
        if (hdr.version != 1) return error.UnsupportedVersion;
        pos += @sizeOf(SpecialistHeader);

        const partitions: *[256]PartitionEntry = @ptrCast(@alignCast(&data[pos]));
        pos += 256 * @sizeOf(PartitionEntry);

        const nodes_bytes = @as(usize, hdr.n_nodes) * @sizeOf(KDNode);
        const nodes: []KDNode = @alignCast(std.mem.bytesAsSlice(KDNode, data[pos .. pos + nodes_bytes]));
        pos += nodes_bytes;

        const blocks_bytes = @as(usize, hdr.n_blocks) * @sizeOf(VecBlock);
        const blocks: []VecBlock = @alignCast(std.mem.bytesAsSlice(VecBlock, data[pos .. pos + blocks_bytes]));

        const self = try allocator.create(SpecialistStore);
        self.* = .{
            .header = hdr.*,
            .partitions = partitions,
            .nodes = nodes,
            .blocks = blocks,
            .mmap_ptr = mmap_ptr,
            .mmap_len = size,
            .allocator = allocator,
        };
        return self;
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *SpecialistStore = @ptrCast(@alignCast(ptr));
        if (self.mmap_ptr) |m| {
            _ = linux.syscall2(.munmap, @intFromPtr(m), self.mmap_len);
        }
        self.allocator.destroy(self);
    }

    pub fn search(ptr: *anyopaque, query: Vector16i16, results: []SearchResult) !usize {
        const self: *SpecialistStore = @ptrCast(@alignCast(ptr));
        const k = results.len;

        // Dequantize query to f32: SENTINEL (-10000) → -1.0, normal → [0, 1].
        // Using the same metric as the original IVF (full L2 including "missing" dims).
        var query_f32: [14]f32 = undefined;
        for (0..14) |i| {
            query_f32[i] = @as(f32, @floatFromInt(query[i])) * INV_SCALE;
        }

        var best_dists: [5]f32 = [_]f32{std.math.inf(f32)} ** 5;
        var best_labels: [5]u8 = [_]u8{0} ** 5;
        var count: usize = 0;

        const query_key = partitionKey(query);

        var part_order: [256]u8 = undefined;
        for (0..256) |i| part_order[i] = @intCast(i);

        // Compute lower bounds for all 256 partitions
        var part_lbs: [256]f32 = undefined;
        for (0..256) |i| {
            part_lbs[i] = lowerBound(query_f32, self.partitions[i].min, self.partitions[i].max);
        }

        // Sort: exact-match partition first (prio = -inf), then ascending LB
        for (1..256) |i| {
            const key_i = part_order[i];
            const prio_i: f32 = if (key_i == query_key) -std.math.inf(f32) else part_lbs[key_i];
            var j = i;
            while (j > 0) {
                const key_j1 = part_order[j - 1];
                const prio_j1: f32 = if (key_j1 == query_key) -std.math.inf(f32) else part_lbs[key_j1];
                if (prio_j1 <= prio_i) break;
                part_order[j] = part_order[j - 1];
                j -= 1;
            }
            part_order[j] = key_i;
        }

        var partitions_searched: usize = 0;

        for (part_order) |pi| {
            const part = &self.partitions[pi];

            // Global LB pruning: remaining partitions are at least this far
            if (count >= k) {
                const worst = best_dists[0];
                if (part_lbs[pi] >= worst) break;
            }

            if (part.node_count == 0) continue;

            searchTree(
                self.nodes,
                self.blocks,
                query_f32,
                &best_dists,
                &best_labels,
                &count,
                k,
                part.root,
            );

            partitions_searched += 1;
            if (partitions_searched >= MAX_PARTITIONS) break;
        }

        for (0..count) |i| {
            results[i] = .{
                .distance = best_dists[i],
                .is_fraud = best_labels[i] != 0,
            };
        }
        return count;
    }

    pub fn vectorStore(self: *SpecialistStore) vector_store.VectorStore {
        return .{ .ptr = self, .vtable = &.{ .search = SpecialistStore.search, .deinit = SpecialistStore.deinit } };
    }
};

// Squared L2 lower bound from query (f32) to bounding box [min, max] (i16).
// Bounding boxes include SENTINEL (-10000 = -1.0), so this gives tight bounds
// that prune subtrees where last_tx presence mismatches (SENTINEL vs real value).
fn lowerBound(query_f32: [14]f32, min: [16]i16, max: [16]i16) f32 {
    var lb: f32 = 0.0;
    for (0..14) |d| {
        const q = query_f32[d];
        const min_f: f32 = @as(f32, @floatFromInt(min[d])) * INV_SCALE;
        const max_f: f32 = @as(f32, @floatFromInt(max[d])) * INV_SCALE;
        const lo: f32 = if (q < min_f) min_f - q else 0.0;
        const hi: f32 = if (q > max_f) q - max_f else 0.0;
        const diff = lo + hi;
        lb += diff * diff;
    }
    return lb;
}

// Iterative stack-based KD-tree traversal using f32 distances
fn searchTree(
    nodes: []KDNode,
    blocks: []VecBlock,
    query_f32: [14]f32,
    best_dists: *[5]f32,
    best_labels: *[5]u8,
    count: *usize,
    k: usize,
    root: u32,
) void {
    var stack: [128]u32 = undefined;
    var stack_top: usize = 0;
    stack[stack_top] = root;
    stack_top += 1;

    while (stack_top > 0) {
        stack_top -= 1;
        const node_idx = stack[stack_top];
        const node = &nodes[node_idx];

        if (count.* >= k) {
            const worst = best_dists[0];
            const lb = lowerBound(query_f32, node.min, node.max);
            if (lb >= worst) continue;
        }

        if (node.left == 0xFFFFFFFF) {
            const start = node.start;
            const end = node.start + node.count;
            scanBlocks(blocks[start..end], query_f32, best_dists, best_labels, count, k);
        } else {
            const lb_left = lowerBound(query_f32, nodes[node.left].min, nodes[node.left].max);
            const lb_right = lowerBound(query_f32, nodes[node.right].min, nodes[node.right].max);
            const worst: f32 = if (count.* >= k) best_dists[0] else std.math.inf(f32);

            // Push farther child first (LIFO → closer child popped first), skip if prunable
            if (lb_left <= lb_right) {
                if (lb_right < worst and stack_top < 127) {
                    stack[stack_top] = node.right;
                    stack_top += 1;
                }
                if (lb_left < worst and stack_top < 128) {
                    stack[stack_top] = node.left;
                    stack_top += 1;
                }
            } else {
                if (lb_left < worst and stack_top < 127) {
                    stack[stack_top] = node.left;
                    stack_top += 1;
                }
                if (lb_right < worst and stack_top < 128) {
                    stack[stack_top] = node.right;
                    stack_top += 1;
                }
            }
        }
    }
}

// Compute f32 squared L2 distances for 8 lanes simultaneously using SIMD.
// Dequantizes i16 → f32 so distances match the original IVF metric exactly
// (SENTINEL = -10000 → -1.0, included in distance computation).
fn scanBlocks(
    block_slice: []VecBlock,
    query_f32: [14]f32,
    best_dists: *[5]f32,
    best_labels: *[5]u8,
    count: *usize,
    k: usize,
) void {
    const inv_scale_vec: @Vector(8, f32) = @splat(INV_SCALE);

    for (block_slice) |*blk| {
        var dists: @Vector(8, f32) = @splat(0.0);

        for (0..14) |d| {
            const q_vec: @Vector(8, f32) = @splat(query_f32[d]);
            const v_i16: @Vector(8, i16) = blk.dims[d];
            const v_i32: @Vector(8, i32) = v_i16;
            const v_f32: @Vector(8, f32) = @floatFromInt(v_i32);
            const v_scaled = v_f32 * inv_scale_vec;
            const diff = q_vec - v_scaled;
            dists = @mulAdd(@Vector(8, f32), diff, diff, dists);
        }

        // Only process valid lanes; _pad[0] stores count (1..8)
        const valid: usize = if (blk._pad[0] > 0 and blk._pad[0] <= 8) blk._pad[0] else 8;
        const dists_arr: [8]f32 = dists;
        for (0..valid) |lane| {
            updateBest(best_dists, best_labels, count, k, dists_arr[lane], blk.labels[lane]);
        }
    }
}

// Update the top-k max-heap with a new candidate (f32 distances, descending sort)
inline fn updateBest(
    best_dists: *[5]f32,
    best_labels: *[5]u8,
    count: *usize,
    k: usize,
    d: f32,
    label: u8,
) void {
    if (count.* < k) {
        best_dists[count.*] = d;
        best_labels[count.*] = label;
        count.* += 1;
        if (count.* == k) {
            sortDescending5(best_dists, best_labels, count.*);
        }
    } else if (d < best_dists[0]) {
        best_dists[0] = d;
        best_labels[0] = label;
        sortDescending5(best_dists, best_labels, count.*);
    }
}

// Sort first n elements (n ≤ 5) descending by dist; best_dists[0] = max (worst)
fn sortDescending5(dists: *[5]f32, labels: *[5]u8, n: usize) void {
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const d = dists[i];
        const l = labels[i];
        var j = i;
        while (j > 0 and dists[j - 1] < d) : (j -= 1) {
            dists[j] = dists[j - 1];
            labels[j] = labels[j - 1];
        }
        dists[j] = d;
        labels[j] = l;
    }
}

// Partition key: 8 binary features of the transaction vector
pub fn partitionKey(v: Vector16i16) u8 {
    var key: u8 = 0;
    if (v[5] != SENTINEL) key |= 1;
    if (v[9] > 5000)  key |= 2;
    if (v[10] > 5000) key |= 4;
    if (v[11] > 5000) key |= 8;
    if (v[12] < 3300) key |= 16;
    if (v[12] > 6600) key |= 32;
    if (v[2] > 4000)  key |= 64;
    if (v[8] > 2500)  key |= 128;
    return key;
}
