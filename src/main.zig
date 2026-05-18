const std = @import("std");
const httpz = @import("httpz");
const domain = @import("domain");
const handler = @import("adapters/http/handler.zig");

const FraudService = domain.fraud_service.FraudService;
const SpecialistStore = domain.specialist_store.SpecialistStore;
const MccRisk = domain.fraud_service.MccRisk;
const AppState = handler.AppState;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();
    _ = args_iter.next(); // skip argv[0]

    var index_path: []const u8 = init.environ_map.get("INDEX_PATH") orelse "/data/specialist_index.bin";
    var mcc_risk_path: []const u8 = init.environ_map.get("MCC_RISK_PATH") orelse "/resources/mcc_risk.json";
    var port: u16 = 8080;
    if (init.environ_map.get("PORT")) |v| port = std.fmt.parseInt(u16, v, 10) catch 8080;
    var threshold: f32 = 0.6;
    if (init.environ_map.get("THRESHOLD")) |v| threshold = std.fmt.parseFloat(f32, v) catch 0.6;

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

    std.debug.print("Loading specialist index from {s}...\n", .{index_path});
    const store = try SpecialistStore.initFromFile(allocator, io, dir, index_path);
    const vs = store.vectorStore();
    defer vs.deinit();

    std.debug.print("Index loaded: {d} vectors, {d} nodes, {d} blocks\n", .{
        store.header.n_vectors,
        store.header.n_nodes,
        store.header.n_blocks,
    });

    std.debug.print("Loading MCC risk from {s}...\n", .{mcc_risk_path});
    const mcc_json = try readFileAlloc(allocator, io, dir, mcc_risk_path);
    defer allocator.free(mcc_json);
    const mcc_risk = try MccRisk.fromJson(mcc_json, allocator);

    const service = FraudService.init(vs, mcc_risk, threshold);

    var state = AppState.init(&service);
    state.setReady();

    const api_socket: ?[]const u8 = init.environ_map.get("API_SOCKET");

    const address = if (api_socket) |s| blk: {
        std.debug.print("Using Unix socket: {s}\n", .{s});
        std.Io.Dir.cwd().deleteFile(init.io, s) catch {};
        break :blk httpz.Config.Address{ .unix = s };
    } else blk: {
        std.debug.print("Using TCP port {d}\n", .{port});
        break :blk httpz.Config.Address.all(port);
    };

    var server = try httpz.Server(*AppState).init(io, allocator, .{
        .address = address,
        .workers = .{ .count = 2 },
        .thread_pool = .{
            .count = 512,
            .backlog = 4096,
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
    _ = dom.specialist_store;
}
