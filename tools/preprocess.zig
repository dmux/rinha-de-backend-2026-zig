const std = @import("std");
const domain = @import("domain");
const types = domain.types;

const Vector14 = types.Vector14;
const IndexHeader = types.IndexHeader;

const K = 1000;
const ITERATIONS = 100;

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
    var vectors: std.ArrayListUnmanaged(Vector14) = .empty;
    var labels: std.ArrayListUnmanaged(bool) = .empty;
    defer vectors.deinit(allocator);
    defer labels.deinit(allocator);

    try loadVectors(init, input_path, &vectors, &labels);
    std.debug.print("Loaded {d} vectors\n", .{vectors.items.len});

    std.debug.print("Running K-means++ (K={d}, iter={d})...\n", .{ K, ITERATIONS });
    const centroids = try runKMeans(allocator, vectors.items);
    defer allocator.free(centroids);

    std.debug.print("Assigning vectors to clusters...\n", .{});
    var clusters = try allocator.alloc(std.ArrayListUnmanaged(u32), K);
    for (clusters) |*c| c.* = .empty;
    defer {
        for (clusters) |*c| c.deinit(allocator);
        allocator.free(clusters);
    }

    for (vectors.items, 0..) |v, idx| {
        var min_dist: f32 = std.math.floatMax(f32);
        var best: usize = 0;
        for (centroids, 0..) |c, ki| {
            const d = l2dist(v, c);
            if (d < min_dist) {
                min_dist = d;
                best = ki;
            }
        }
        try clusters[best].append(allocator, @intCast(idx));
    }

    // Log cluster balance stats
    var max_size: usize = 0;
    var total: usize = 0;
    for (clusters) |c| {
        if (c.items.len > max_size) max_size = c.items.len;
        total += c.items.len;
    }
    const mean_size = total / K;
    const ratio: f64 = @as(f64, @floatFromInt(max_size)) / @as(f64, @floatFromInt(mean_size));
    std.debug.print("Cluster stats: mean={d}, max={d}, ratio={d:.2}\n", .{ mean_size, max_size, ratio });
    if (ratio > 5.0) {
        std.debug.print("ERROR: clusters badly unbalanced (ratio={d:.2} > 5.0). Build failed.\n", .{ratio});
        std.process.exit(1);
    }

    std.debug.print("Writing index to {s}...\n", .{output_path});
    try writeIndex(init, output_path, centroids, clusters, vectors.items, labels.items);
    std.debug.print("Done.\n", .{});
}

fn loadVectors(
    init: std.process.Init,
    path: []const u8,
    vectors: *std.ArrayListUnmanaged(Vector14),
    labels: *std.ArrayListUnmanaged(bool),
) !void {
    const allocator = init.gpa;

    const file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);

    const file_buf = try allocator.alloc(u8, 1 << 16);
    defer allocator.free(file_buf);
    var file_reader = file.reader(init.io, file_buf);

    const decomp_buf = try allocator.alloc(u8, 1 << 16);
    defer allocator.free(decomp_buf);
    var decomp = std.compress.flate.Decompress.init(&file_reader.interface, .gzip, decomp_buf);

    // Decompress entire file to memory, then parse
    var aw: std.Io.Writer.Allocating = .init(allocator);
    _ = try decomp.reader.streamRemaining(&aw.writer);
    const decompressed = try aw.toOwnedSlice();
    defer allocator.free(decompressed);

    // Parse JSON using scanner on complete input
    var scanner = std.json.Scanner.initCompleteInput(allocator, decompressed);
    defer scanner.deinit();

    try vectors.ensureTotalCapacity(allocator, 3_100_000);
    try labels.ensureTotalCapacity(allocator, 3_100_000);

    // State machine: [ {vector:[f,f,...], label:"fraud"|"legit"} , ... ]
    var tok = try scanner.next();
    if (tok != .array_begin) return error.BadJson;

    while (true) {
        tok = try scanner.next();
        if (tok == .array_end) break;
        if (tok != .object_begin) return error.BadJson;

        var vec: [14]f32 = undefined;
        var is_fraud: bool = false;
        var got_vector = false;
        var got_label = false;

        // Read key-value pairs
        while (true) {
            const key_tok = try scanner.next();
            if (key_tok == .object_end) break;

            const key = switch (key_tok) {
                .string => |s| s,
                .partial_string => return error.BadJson,
                else => return error.BadJson,
            };

            if (std.mem.eql(u8, key, "vector")) {
                const arr_tok = try scanner.next();
                if (arr_tok != .array_begin) return error.BadJson;
                for (&vec) |*f| {
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

        try vectors.append(allocator, vec);
        try labels.append(allocator, is_fraud);
    }
}

fn runKMeans(allocator: std.mem.Allocator, vecs: []const Vector14) ![]Vector14 {
    var centroids = try allocator.alloc(Vector14, K);

    var rng = std.Random.DefaultPrng.init(0xdeadbeefcafe1337);
    const random = rng.random();

    // K-means++ initialization
    centroids[0] = vecs[random.uintAtMost(usize, vecs.len - 1)];

    var min_dists = try allocator.alloc(f32, vecs.len);
    defer allocator.free(min_dists);
    @memset(min_dists, std.math.floatMax(f32));

    for (1..K) |k| {
        // Update min distances using the newly added centroid
        var total: f64 = 0;
        for (vecs, 0..) |v, vi| {
            const d = l2dist(v, centroids[k - 1]);
            if (d < min_dists[vi]) min_dists[vi] = d;
            total += min_dists[vi];
        }

        // Sample proportional to distance squared
        var target = random.float(f64) * total;
        var chosen: usize = vecs.len - 1;
        for (0..vecs.len) |vi| {
            target -= min_dists[vi];
            if (target <= 0) {
                chosen = vi;
                break;
            }
        }
        centroids[k] = vecs[chosen];
    }

    // K-means iterations
    var assignments = try allocator.alloc(u32, vecs.len);
    defer allocator.free(assignments);

    for (0..ITERATIONS) |iter| {
        std.debug.print("  iter {d}/{d}\r", .{ iter + 1, ITERATIONS });

        // Assignment step
        for (vecs, 0..) |v, vi| {
            var best_d: f32 = std.math.floatMax(f32);
            var best_k: u32 = 0;
            for (centroids, 0..) |c, ki| {
                const d = l2dist(v, c);
                if (d < best_d) {
                    best_d = d;
                    best_k = @intCast(ki);
                }
            }
            assignments[vi] = best_k;
        }

        // Update step (accumulate in f64 to avoid overflow)
        var accums = try allocator.alloc(@Vector(14, f64), K);
        defer allocator.free(accums);
        @memset(accums, @splat(0.0));

        var counts = try allocator.alloc(u64, K);
        defer allocator.free(counts);
        @memset(counts, 0);

        for (vecs, 0..) |v, vi| {
            const ki = assignments[vi];
            accums[ki] += @as(@Vector(14, f64), @floatCast(v));
            counts[ki] += 1;
        }

        for (0..K) |ki| {
            if (counts[ki] > 0) {
                const n: @Vector(14, f64) = @splat(@floatFromInt(counts[ki]));
                centroids[ki] = @floatCast(accums[ki] / n);
            }
        }
    }
    std.debug.print("\n", .{});

    return centroids;
}

fn writeIndex(
    init: std.process.Init,
    path: []const u8,
    centroids: []const Vector14,
    clusters: []const std.ArrayListUnmanaged(u32),
    vecs: []const Vector14,
    lbls: []const bool,
) !void {
    const allocator = init.gpa;

    const file = try std.Io.Dir.cwd().createFile(init.io, path, .{});
    defer file.close(init.io);

    const write_buf = try allocator.alloc(u8, 1 << 16);
    defer allocator.free(write_buf);
    var fw = file.writer(init.io, write_buf);
    const w = &fw.interface;

    const header = IndexHeader{
        .version = 2, // version 2 = f16 vector storage
        .n_vectors = @intCast(vecs.len),
        .n_centroids = K,
        .nprobe = 50,
    };
    try w.writeAll(std.mem.asBytes(&header));

    // Centroids (f32)
    for (centroids) |c| {
        const arr: [14]f32 = c;
        try w.writeAll(std.mem.asBytes(&arr));
    }

    // Cluster offsets
    var offset: u32 = 0;
    for (clusters) |c| {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, offset, .little);
        try w.writeAll(&buf);
        offset += @intCast(c.items.len);
    }
    // Final sentinel offset
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, offset, .little);
    try w.writeAll(&buf);

    // Vectors ordered by cluster, stored as f16
    for (clusters) |c| {
        for (c.items) |idx| {
            const arr: [14]f32 = vecs[idx];
            var q: [14]f16 = undefined;
            for (0..14) |di| q[di] = @floatCast(arr[di]);
            try w.writeAll(std.mem.asBytes(&q));
        }
    }

    // Labels ordered by cluster
    for (clusters) |c| {
        for (c.items) |idx| {
            try w.writeByte(if (lbls[idx]) 1 else 0);
        }
    }

    try w.flush();
}

fn l2dist(a: Vector14, b: Vector14) f32 {
    const diff = a - b;
    return @reduce(.Add, diff * diff);
}
