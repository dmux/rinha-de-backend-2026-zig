const std = @import("std");
const types = @import("../../domain/types.zig");
const vector_store = @import("../../ports/vector_store.zig");

const Vector14 = types.Vector14;
const SearchResult = types.SearchResult;
const IndexHeader = types.IndexHeader;

pub const IvfStore = struct {
    allocator: std.mem.Allocator,
    header: IndexHeader,
    centroids: []align(32) [14]f32,
    offsets: []u32,
    vectors: []align(32) [14]f16,
    labels: []u8,

    // Stream-parse IVF index directly from file (no intermediate buffer — avoids 2× peak memory)
    pub fn initFromFile(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !*IvfStore {
        const file = try dir.openFile(io, path, .{});
        defer file.close(io);

        var read_buf: [65536]u8 = undefined;
        var fr = file.reader(io, &read_buf);
        const r = &fr.interface;

        var header: IndexHeader = undefined;
        try r.readSliceAll(std.mem.asBytes(&header));

        if (header.magic != IndexHeader.MAGIC) return error.InvalidMagic;
        if (header.n_dims != 14) return error.InvalidDimensions;
        if (header.version != 2) return error.UnsupportedVersion;

        const centroids = try allocator.alignedAlloc([14]f32, .fromByteUnits(32), header.n_centroids);
        errdefer allocator.free(centroids);
        try r.readSliceAll(std.mem.sliceAsBytes(centroids));

        const offsets = try allocator.alloc(u32, header.n_centroids + 1);
        errdefer allocator.free(offsets);
        try r.readSliceAll(std.mem.sliceAsBytes(offsets));
        // Fix endianness: offsets were written as little-endian u32
        for (offsets) |*o| o.* = std.mem.littleToNative(u32, o.*);

        const vectors = try allocator.alignedAlloc([14]f16, .fromByteUnits(32), header.n_vectors);
        errdefer allocator.free(vectors);
        try r.readSliceAll(std.mem.sliceAsBytes(vectors));

        const labels = try allocator.alloc(u8, header.n_vectors);
        errdefer allocator.free(labels);
        try r.readSliceAll(labels);

        const self = try allocator.create(IvfStore);
        self.* = .{
            .allocator = allocator,
            .header = header,
            .centroids = centroids,
            .offsets = offsets,
            .vectors = vectors,
            .labels = labels,
        };
        return self;
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *IvfStore = @ptrCast(@alignCast(ptr));
        self.allocator.free(self.centroids);
        self.allocator.free(self.offsets);
        self.allocator.free(self.vectors);
        self.allocator.free(self.labels);
        self.allocator.destroy(self);
    }

    pub fn search(ptr: *anyopaque, query: Vector14, results: []SearchResult) !usize {
        const self: *IvfStore = @ptrCast(@alignCast(ptr));
        const k = results.len;
        const nprobe = self.header.nprobe;

        // Find top nprobe clusters; K=1000 is the hard upper bound
        var top: [1000]struct { dist: f32, cid: u32 } = undefined;
        var n_top: usize = 0;
        const query_vec: @Vector(14, f32) = query;

        for (self.centroids, 0..) |*centroid_arr, cid| {
            const centroid: @Vector(14, f32) = centroid_arr.*;
            const diff = query_vec - centroid;
            const dist = @reduce(.Add, diff * diff);

            if (n_top < nprobe) {
                top[n_top] = .{ .dist = dist, .cid = @intCast(cid) };
                n_top += 1;
                var j = n_top - 1;
                while (j > 0 and top[j].dist < top[j - 1].dist) : (j -= 1) {
                    const tmp = top[j];
                    top[j] = top[j - 1];
                    top[j - 1] = tmp;
                }
            } else if (dist < top[n_top - 1].dist) {
                top[n_top - 1] = .{ .dist = dist, .cid = @intCast(cid) };
                var j = n_top - 1;
                while (j > 0 and top[j].dist < top[j - 1].dist) : (j -= 1) {
                    const tmp = top[j];
                    top[j] = top[j - 1];
                    top[j - 1] = tmp;
                }
            }
        }

        // Build mask for missing query dimensions (-1.0)
        const v_neg: @Vector(14, f32) = @splat(0.0);
        const q_present = query_vec >= v_neg;

        // Scan clusters; maintain k nearest using max-slot tracking
        var count: usize = 0;
        var max_dist: f32 = std.math.floatMax(f32);
        var max_idx: usize = 0;

        for (top[0..n_top], 0..) |tc, ci| {
            const cid = tc.cid;
            const start = self.offsets[cid];
            const end = self.offsets[cid + 1];

            // Prefetch next cluster's vectors and labels
            if (ci + 1 < n_top) {
                const next_start = self.offsets[top[ci + 1].cid];
                if (next_start < self.vectors.len) {
                    @prefetch(&self.vectors[next_start], .{ .rw = .read, .locality = 2, .cache = .data });
                    @prefetch(&self.labels[next_start], .{ .rw = .read, .locality = 2, .cache = .data });
                }
            }

            for (self.vectors[start..end], self.labels[start..end]) |*vec_arr, label| {
                // Convert stored f16 to f32 for distance computation
                const vec_f16: @Vector(14, f16) = vec_arr.*;
                const vec_f32: @Vector(14, f32) = vec_f16;

                // Both query and stored vector must be present (≥ 0) for a dimension to count
                const v_present = vec_f32 >= v_neg;
                const present = q_present & v_present;

                const qv = @select(f32, present, query_vec, @as(@Vector(14, f32), @splat(0.0)));
                const vv = @select(f32, present, vec_f32, @as(@Vector(14, f32), @splat(0.0)));
                const diff = qv - vv;
                const df = @reduce(.Add, diff * diff);

                if (count < k) {
                    results[count] = .{ .distance = df, .is_fraud = label != 0 };
                    count += 1;
                    if (count == k) {
                        max_dist = results[0].distance;
                        max_idx = 0;
                        for (1..k) |i| {
                            if (results[i].distance > max_dist) {
                                max_dist = results[i].distance;
                                max_idx = i;
                            }
                        }
                    }
                } else if (df < max_dist) {
                    results[max_idx] = .{ .distance = df, .is_fraud = label != 0 };
                    max_dist = results[0].distance;
                    max_idx = 0;
                    for (1..k) |i| {
                        if (results[i].distance > max_dist) {
                            max_dist = results[i].distance;
                            max_idx = i;
                        }
                    }
                }
            }
        }

        return count;
    }

    pub fn vectorStore(self: *IvfStore) vector_store.VectorStore {
        return .{
            .ptr = self,
            .vtable = &.{
                .search = IvfStore.search,
                .deinit = IvfStore.deinit,
            },
        };
    }
};
