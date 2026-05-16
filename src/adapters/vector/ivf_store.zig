const std = @import("std");
const types = @import("../../domain/types.zig");
const vector_store = @import("../../ports/vector_store.zig");
const linux = std.os.linux;
const posix = std.posix;

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
    mmap_ptr: ?[*]align(4096) u8 = null,
    mmap_len: usize = 0,

    pub fn initFromFile(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !*IvfStore {
        const file = try dir.openFile(io, path, .{});
        defer file.close(io);

        const stat = try file.stat(io);
        const size = stat.size;

        // Use direct linux mmap syscall to avoid std library issues
        // PROT_READ=1, MAP_PRIVATE=2
        const mmap_res = linux.syscall6(.mmap, 0, size, 1, 2, @as(usize, @bitCast(@as(isize, file.handle))), 0);
        const mmap_ptr: [*]align(4096) u8 = @ptrFromInt(mmap_res);
        const mmap_data = mmap_ptr[0..size];

        var pos: usize = 0;
        
        const header_ptr: *IndexHeader = @ptrCast(@alignCast(&mmap_data[pos]));
        const header = header_ptr.*;
        pos += @sizeOf(IndexHeader);

        if (header.magic != IndexHeader.MAGIC) return error.InvalidMagic;
        if (header.n_dims != 14) return error.InvalidDimensions;
        if (header.version != 2) return error.UnsupportedVersion;

        const centroids_bytes = header.n_centroids * @sizeOf([14]f32);
        const centroids: []align(32) [14]f32 = @alignCast(std.mem.bytesAsSlice([14]f32, mmap_data[pos .. pos + centroids_bytes]));
        pos += centroids_bytes;

        // Offsets need endianness correction, so we copy them
        const offsets = try allocator.alloc(u32, header.n_centroids + 1);
        errdefer allocator.free(offsets);
        const offsets_bytes = (header.n_centroids + 1) * @sizeOf(u32);
        @memcpy(std.mem.sliceAsBytes(offsets), mmap_data[pos .. pos + offsets_bytes]);
        for (offsets) |*o| o.* = std.mem.littleToNative(u32, o.*);
        pos += offsets_bytes;

        const vectors_bytes = header.n_vectors * @sizeOf([14]f16);
        const vectors: []align(32) [14]f16 = @alignCast(std.mem.bytesAsSlice([14]f16, mmap_data[pos .. pos + vectors_bytes]));
        pos += vectors_bytes;

        const labels = mmap_data[pos .. pos + header.n_vectors];

        const self = try allocator.create(IvfStore);
        self.* = .{
            .allocator = allocator,
            .header = header,
            .centroids = centroids,
            .offsets = offsets,
            .vectors = vectors,
            .labels = labels,
            .mmap_ptr = mmap_ptr,
            .mmap_len = size,
        };
        return self;
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *IvfStore = @ptrCast(@alignCast(ptr));
        if (self.mmap_ptr) |m| {
            _ = linux.syscall2(.munmap, @intFromPtr(m), self.mmap_len);
        }
        self.allocator.free(self.offsets);
        self.allocator.destroy(self);
    }

    pub fn search(ptr: *anyopaque, query: Vector14, results: []SearchResult, nprobe_opt: ?u32) !usize {
        const self: *IvfStore = @ptrCast(@alignCast(ptr));
        const k = results.len;
        const nprobe = nprobe_opt orelse self.header.nprobe;

        // Find top nprobe clusters
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

        const v_neg: @Vector(14, f32) = @splat(0.0);
        const q_present = query_vec >= v_neg;

        var count: usize = 0;
        var max_dist: f32 = std.math.floatMax(f32);
        var max_idx: usize = 0;

        for (top[0..n_top], 0..) |tc, ci| {
            const cid = tc.cid;
            const start = self.offsets[cid];
            const end = self.offsets[cid + 1];

            if (ci + 1 < n_top) {
                const next_start = self.offsets[top[ci + 1].cid];
                if (next_start < self.vectors.len) {
                    @prefetch(&self.vectors[next_start], .{ .rw = .read, .locality = 2, .cache = .data });
                }
            }

            for (self.vectors[start..end], self.labels[start..end]) |*vec_arr, label| {
                const vec_f16: @Vector(14, f16) = vec_arr.*;
                const vec_f32: @Vector(14, f32) = vec_f16;
                const v_present = vec_f32 >= v_neg;
                const present = q_present & v_present;
                const diff = query_vec - vec_f32;
                const final_diff = @select(f32, present, diff, @as(@Vector(14, f32), @splat(0.0)));
                const df = @reduce(.Add, final_diff * final_diff);

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
