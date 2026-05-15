const std = @import("std");
const httpz = @import("httpz");
const domain = @import("domain");
const handler = @import("adapters/http/handler.zig");

const FraudService = domain.fraud_service.FraudService;
const IvfStore = domain.ivf_store.IvfStore;
const MccRisk = domain.fraud_service.MccRisk;
const AppState = handler.AppState;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();
    _ = args_iter.next(); // skip argv[0]

    var index_path: []const u8 = init.environ_map.get("INDEX_PATH") orelse "/data/ivf_index.bin";
    var mcc_risk_path: []const u8 = init.environ_map.get("MCC_RISK_PATH") orelse "/resources/mcc_risk.json";
    var port: u16 = 8080;
    if (init.environ_map.get("PORT")) |v| port = std.fmt.parseInt(u16, v, 10) catch 8080;
    var threshold: f32 = 0.6;
    if (init.environ_map.get("THRESHOLD")) |v| threshold = std.fmt.parseFloat(f32, v) catch 0.6;
    var nprobe_env: ?u32 = null;
    if (init.environ_map.get("NPROBE")) |v| nprobe_env = std.fmt.parseInt(u32, v, 10) catch null;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--index")) {
            if (args_iter.next()) |v| index_path = v;
        } else if (std.mem.eql(u8, arg, "--port")) {
            if (args_iter.next()) |v| port = try std.fmt.parseInt(u16, v, 10);
        } else if (std.mem.eql(u8, arg, "--mcc-risk")) {
            if (args_iter.next()) |v| mcc_risk_path = v;
        } else if (std.mem.eql(u8, arg, "--threshold")) {
            if (args_iter.next()) |v| threshold = try std.fmt.parseFloat(f32, v);
        }
    }

    const io = init.io;
    const dir = std.Io.Dir.cwd();

    std.debug.print("Loading IVF index from {s}...\n", .{index_path});
    const store = try IvfStore.initFromFile(allocator, io, dir, index_path);
    if (nprobe_env) |np| store.header.nprobe = np;
    const vs = store.vectorStore();
    defer vs.deinit();

    std.debug.print("Index loaded: {d} vectors, {d} centroids, nprobe={d}\n", .{
        store.header.n_vectors,
        store.header.n_centroids,
        store.header.nprobe,
    });

    std.debug.print("Loading MCC risk from {s}...\n", .{mcc_risk_path});
    const mcc_json = try readFileAlloc(allocator, io, dir, mcc_risk_path);
    defer allocator.free(mcc_json);
    const mcc_risk = try MccRisk.fromJson(mcc_json, allocator);

    const service = FraudService.init(vs, mcc_risk, threshold);

    // Warm-up: 2000 varied queries to pre-populate caches and warm the engine
    std.debug.print("Warming up engine (2000 searches)...\n", .{});
    var wi: u32 = 0;
    while (wi < 2000) : (wi += 1) {
        const amount: f64 = @as(f64, @floatFromInt(wi * 33 + 1));
        const km: f64 = @as(f64, @floatFromInt(wi * 3));
        const avg: f64 = @as(f64, @floatFromInt(wi * 17 % 500 + 10));
        var dummy = std.mem.zeroInit(domain.types.FraudRequest, .{
            .id = "warmup",
            .transaction = .{ .amount = amount, .installments = @as(u8, @intCast(wi % 12 + 1)), .requested_at = "2026-01-01T00:00:00Z" },
            .customer = .{ .avg_amount = avg, .tx_count_24h = wi % 20, .known_merchants = @constCast(&[_][]const u8{}) },
            .merchant = .{ .id = "M", .mcc = "5411", .avg_amount = avg },
            .terminal = .{ .is_online = (wi % 2 == 0), .card_present = (wi % 3 != 0), .km_from_home = km },
        });
        _ = try service.evaluate(&dummy);
    }
    std.debug.print("Engine warmed up\n", .{});

    var state = AppState.init(&service);
    state.setReady();

    // Prefer Unix domain socket (set via API_SOCKET env var) to eliminate TCP overhead
    const api_socket: ?[]const u8 = init.environ_map.get("API_SOCKET");

    const address = if (api_socket) |s| blk: {
        std.debug.print("Using Unix socket: {s}\n", .{s});
        break :blk httpz.Config.Address{ .unix = s };
    } else blk: {
        std.debug.print("Using TCP port {d}\n", .{port});
        break :blk httpz.Config.Address.all(port);
    };

    var server = try httpz.Server(*AppState).init(io, allocator, .{
        .address = address,
        .thread_pool = .{ 
            .count = 1,
            .backlog = 2048,
        },
        .request = .{ 
            .max_body_size = 8192,
            .buffer_size = 4096,
        },
    }, &state);
    defer server.deinit();
    defer server.stop();

    var router = try server.router(.{});
    router.post("/fraud-score", handler.fraudScore, .{});
    router.get("/ready", handler.ready, .{});

    std.debug.print("Server ready\n", .{});
    try server.listen();
}

fn readFileAlloc(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) ![]u8 {
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);

    var file_buf: [64 * 1024]u8 = undefined;
    var fr = file.reader(io, &file_buf);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    _ = try fr.interface.streamRemaining(&aw.writer);
    return aw.toOwnedSlice();
}

test {
    const dom = @import("domain");
    _ = dom.vectorizer;
    _ = dom.scorer;
    _ = dom.ivf_store;
}
