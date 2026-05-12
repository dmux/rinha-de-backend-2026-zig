const std = @import("std");
const types = @import("../../domain/types.zig");
const vector_store = @import("../../ports/vector_store.zig");

const Vector14 = types.Vector14;
const SearchResult = types.SearchResult;
const IndexHeader = types.IndexHeader;

pub const BruteForceStore = struct {
    allocator: std.mem.Allocator,
    header: IndexHeader,
    vectors: []Vector14,
    labels: []bool,

    // Stream-parse and dequantize for exact recall testing
    pub fn initFromFile(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !*BruteForceStore {
        const file = try dir.openFile(io, path, .{});
        defer file.close(io);

        var read_buf: [65536]u8 = undefined;
        var fr = file.reader(io, &read_buf);
        const r = &fr.interface;

        var header: IndexHeader = undefined;
        try r.readSliceAll(std.mem.asBytes(&header));

        if (header.magic != IndexHeader.MAGIC) return error.InvalidMagic;
        if (header.version != 2) return error.UnsupportedVersion;

        // Skip centroids (n_centroids × 14 × 4 bytes)
        const centroid_skip = @as(usize, header.n_centroids) * 14 * @sizeOf(f32);
        var skipped: usize = 0;
        var skip_buf: [4096]u8 = undefined;
        while (skipped < centroid_skip) {
            const chunk = @min(skip_buf.len, centroid_skip - skipped);
            try r.readSliceAll(skip_buf[0..chunk]);
            skipped += chunk;
        }

        // Skip offsets ((n_centroids + 1) × 4 bytes)
        const offset_skip = @as(usize, header.n_centroids + 1) * @sizeOf(u32);
        skipped = 0;
        while (skipped < offset_skip) {
            const chunk = @min(skip_buf.len, offset_skip - skipped);
            try r.readSliceAll(skip_buf[0..chunk]);
            skipped += chunk;
        }

        // Load f16 vectors → convert to f32 for exact distance computation
        const vectors = try allocator.alloc(Vector14, header.n_vectors);
        errdefer allocator.free(vectors);

        var f16_batch: [512][14]f16 = undefined;
        var loaded: u32 = 0;
        while (loaded < header.n_vectors) {
            const batch = @min(f16_batch.len, header.n_vectors - loaded);
            try r.readSliceAll(std.mem.sliceAsBytes(f16_batch[0..batch]));
            for (0..batch) |bi| {
                var arr: [14]f32 = undefined;
                for (0..14) |di| arr[di] = @floatCast(f16_batch[bi][di]);
                vectors[loaded + bi] = arr;
            }
            loaded += @intCast(batch);
        }

        const labels = try allocator.alloc(bool, header.n_vectors);
        errdefer allocator.free(labels);
        const label_bytes = try allocator.alloc(u8, header.n_vectors);
        defer allocator.free(label_bytes);
        try r.readSliceAll(label_bytes);
        for (labels, label_bytes) |*l, b| l.* = b != 0;

        const self = try allocator.create(BruteForceStore);
        self.* = .{
            .allocator = allocator,
            .header = header,
            .vectors = vectors,
            .labels = labels,
        };
        return self;
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *BruteForceStore = @ptrCast(@alignCast(ptr));
        self.allocator.free(self.vectors);
        self.allocator.free(self.labels);
        self.allocator.destroy(self);
    }

    pub fn search(ptr: *anyopaque, query: Vector14, results: []SearchResult) !usize {
        const self: *BruteForceStore = @ptrCast(@alignCast(ptr));
        const k = results.len;
        const query_vec: @Vector(14, f32) = query;
        const v_neg: @Vector(14, f32) = @splat(0.0);
        const q_present = query_vec >= v_neg;

        var count: usize = 0;
        var max_dist: f32 = std.math.floatMax(f32);
        var max_idx: usize = 0;

        for (self.vectors, self.labels) |v, label| {
            const vec_f32: @Vector(14, f32) = v;
            const v_present = vec_f32 >= v_neg;
            const present = q_present & v_present;

            const qv = @select(f32, present, query_vec, @as(@Vector(14, f32), @splat(0.0)));
            const vv = @select(f32, present, vec_f32, @as(@Vector(14, f32), @splat(0.0)));
            const diff = qv - vv;
            const df = @reduce(.Add, diff * diff);

            if (count < k) {
                results[count] = .{ .distance = df, .is_fraud = label };
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
                results[max_idx] = .{ .distance = df, .is_fraud = label };
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
        return count;
    }

    pub fn vectorStore(self: *BruteForceStore) vector_store.VectorStore {
        return .{
            .ptr = self,
            .vtable = &.{
                .search = BruteForceStore.search,
                .deinit = BruteForceStore.deinit,
            },
        };
    }
};
