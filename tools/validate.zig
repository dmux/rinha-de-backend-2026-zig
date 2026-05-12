const std = @import("std");
const domain = @import("domain");

const IvfStore = domain.ivf_store.IvfStore;
const BruteForceStore = domain.brute_force.BruteForceStore;
const FraudService = domain.fraud_service.FraudService;
const MccRisk = domain.fraud_service.MccRisk;
const FraudRequest = domain.types.FraudRequest;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();
    _ = args_iter.next(); // skip argv[0]

    var index_path: []const u8 = "ivf_index.bin";
    var mcc_risk_path: []const u8 = "resources/mcc_risk.json";
    var test_data_path: []const u8 = "test-data.json";
    var threshold: f32 = 0.4;
    var diagnose: bool = false;
    var nprobe_override: ?u32 = null;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--index")) {
            if (args_iter.next()) |v| index_path = v;
        } else if (std.mem.eql(u8, arg, "--mcc-risk")) {
            if (args_iter.next()) |v| mcc_risk_path = v;
        } else if (std.mem.eql(u8, arg, "--test-data")) {
            if (args_iter.next()) |v| test_data_path = v;
        } else if (std.mem.eql(u8, arg, "--threshold")) {
            if (args_iter.next()) |v| threshold = try std.fmt.parseFloat(f32, v);
        } else if (std.mem.eql(u8, arg, "--nprobe")) {
            if (args_iter.next()) |v| nprobe_override = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, arg, "--diagnose")) {
            diagnose = true;
        }
    }

    const io = init.io;
    const dir = std.Io.Dir.cwd();

    const store = try IvfStore.initFromFile(allocator, io, dir, index_path);
    if (nprobe_override) |np| store.header.nprobe = np;
    const vs = store.vectorStore();
    defer vs.deinit();

    const mcc_json = try readFileAlloc(allocator, io, dir, mcc_risk_path);
    defer allocator.free(mcc_json);
    const mcc_risk = try MccRisk.fromJson(mcc_json, allocator);

    const service = FraudService.init(vs, mcc_risk, threshold);

    const TestEntry = struct {
        request: FraudRequest,
        expected_approved: bool,
    };
    const TestData = struct {
        entries: []TestEntry,
    };

    std.debug.print("Loading test data from {s}...\n", .{test_data_path});
    const test_data_json = try readFileAlloc(allocator, io, dir, test_data_path);
    defer allocator.free(test_data_json);

    const parsed = try std.json.parseFromSlice(TestData, allocator, test_data_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const entries = parsed.value.entries;
    var fp: u32 = 0;
    var fn_count: u32 = 0;
    var tp: u32 = 0;
    var tn: u32 = 0;
    var total: u32 = 0;

    // Collect failing entry indices for diagnosis pass
    var fail_indices = try std.ArrayListUnmanaged(u32).initCapacity(allocator, 256);
    defer fail_indices.deinit(allocator);

    for (entries, 0..) |entry, i| {
        const expected_fraud = !entry.expected_approved;
        const result = try service.evaluate(&entry.request);
        total += 1;

        const is_fail = result.approved != entry.expected_approved;
        if (is_fail) try fail_indices.append(allocator, @intCast(i));

        if (result.approved) {
            if (expected_fraud) fn_count += 1 else tn += 1;
        } else {
            if (expected_fraud) tp += 1 else fp += 1;
        }

        if (total % 5000 == 0) std.debug.print("Processed {d}/{d}...\r", .{ total, entries.len });
    }

    const e_score = fp + (fn_count * 3);
    std.debug.print("\n", .{});

    // Print fail indices cleanly on one line (no interleaving with progress)
    if (diagnose) {
        std.debug.print("FAIL_INDICES:", .{});
        for (fail_indices.items) |idx| std.debug.print(" {d}", .{idx});
        std.debug.print("\n", .{});
    }

    std.debug.print("=== IVF Results (threshold={d:.2}, nprobe={d}) ===\n", .{ threshold, store.header.nprobe });
    std.debug.print("Total: {d} | TP: {d} TN: {d} FP: {d} FN: {d}\n", .{ total, tp, tn, fp, fn_count });
    std.debug.print("E = 1×FP + 3×FN = {d}\n", .{e_score});

    const failure_rate: f64 = @as(f64, @floatFromInt(e_score)) / @as(f64, @floatFromInt(total));
    const score_det: f64 = if (e_score == 0)
        3000.0
    else
        1000.0 * std.math.log10(1.0 / failure_rate) - 300.0 * std.math.log10(1.0 + @as(f64, @floatFromInt(e_score)));
    std.debug.print("score_det_est = {d:.1}\n", .{score_det});

    if (!diagnose or fail_indices.items.len == 0) return;

    // --- Two-pass diagnosis: run BruteForce on only the failing entries ---
    std.debug.print("\n=== Diagnosis: BruteForce on {d} IVF failures ===\n", .{fail_indices.items.len});
    std.debug.print("Loading BruteForce store (f16→f32 exact scan)...\n", .{});

    const bf_store = try BruteForceStore.initFromFile(allocator, io, dir, index_path);
    const bf_vs = bf_store.vectorStore();
    defer bf_vs.deinit();
    const bf_service = FraudService.init(bf_vs, mcc_risk, threshold);

    var bf_fp: u32 = 0;
    var bf_fn: u32 = 0;
    var fixed_by_bf: u32 = 0;

    for (fail_indices.items) |idx| {
        const entry = entries[idx];
        const expected_fraud = !entry.expected_approved;
        const result = try bf_service.evaluate(&entry.request);

        if (result.approved != entry.expected_approved) {
            if (result.approved) bf_fn += 1 else bf_fp += 1;
        } else {
            fixed_by_bf += 1;
        }
        _ = expected_fraud;
    }

    const bf_e = bf_fp + bf_fn * 3;
    std.debug.print("After BruteForce (exact scan, dequantized):\n", .{});
    std.debug.print("  Fixed by BF:       {d}  ← ANN miss (IVF missed true top-5 cluster)\n", .{fixed_by_bf});
    std.debug.print("  Still wrong in BF: {d}  ← Precision loss (f16 still changes neighbor rank)\n", .{bf_fp + bf_fn});
    std.debug.print("  BF FP: {d}, BF FN: {d}, BF E: {d}\n", .{ bf_fp, bf_fn, bf_e });

    if (fixed_by_bf > 0) {
        std.debug.print("\nConclusion: {d} errors fixable by better recall (increase nprobe or rebuild k-means)\n", .{fixed_by_bf});
    }
    if (bf_fp + bf_fn > 0) {
        std.debug.print("Conclusion: {d} errors from f16 precision loss — need float32 or better training\n", .{bf_fp + bf_fn});
    }
}

fn readFileAlloc(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) ![]u8 {
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    var buf: [4096]u8 = undefined;
    var r = file.reader(io, &buf);
    _ = try r.interface.streamRemaining(&aw.writer);
    return aw.toOwnedSlice();
}
