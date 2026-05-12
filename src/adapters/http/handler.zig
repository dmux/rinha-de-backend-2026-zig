const std = @import("std");
const httpz = @import("httpz");
const domain = @import("domain");
const json_parser = @import("json.zig");

pub const FraudService = domain.fraud_service.FraudService;
pub const FraudRequest = domain.types.FraudRequest;

pub const AppState = struct {
    service: *const FraudService,
    ready: std.atomic.Value(bool),

    pub fn init(service: *const FraudService) AppState {
        return .{
            .service = service,
            .ready = std.atomic.Value(bool).init(false),
        };
    }

    pub fn setReady(self: *AppState) void {
        self.ready.store(true, .release);
    }
};

pub fn fraudScore(state: *AppState, req: *httpz.Request, res: *httpz.Response) !void {
    var buf: [16384]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    const body = req.body() orelse {
        res.status = 400;
        res.body = "{\"error\":\"empty body\"}";
        return;
    };
    if (body.len == 0) {
        res.status = 400;
        res.body = "{\"error\":\"empty body\"}";
        return;
    }

    const req_payload = json_parser.parseManual(allocator, body) catch {
        res.status = 400;
        res.body = "{\"error\":\"invalid json\"}";
        return;
    };

    const result = state.service.evaluate(&req_payload) catch |err| {
        std.debug.print("Evaluation error: {}\n", .{err});
        res.status = 500;
        res.body = "{\"error\":\"internal error\"}";
        return;
    };

    // k=5 → fraud_score ∈ {0.0, 0.2, 0.4, 0.6, 0.8, 1.0}: use pre-computed strings
    const precomputed = [6][]const u8{
        "{\"approved\":true,\"fraud_score\":0.0000}",
        "{\"approved\":true,\"fraud_score\":0.2000}",
        "{\"approved\":true,\"fraud_score\":0.4000}",
        "{\"approved\":false,\"fraud_score\":0.6000}",
        "{\"approved\":false,\"fraud_score\":0.8000}",
        "{\"approved\":false,\"fraud_score\":1.0000}",
    };
    const idx: usize = @intFromFloat(@round(result.fraud_score * 5.0));
    res.content_type = .JSON;
    res.body = if (idx < precomputed.len)
        precomputed[idx]
    else
        try std.fmt.allocPrint(res.arena, "{{\"approved\":{s},\"fraud_score\":{d:.4}}}", .{
            if (result.approved) "true" else "false", result.fraud_score,
        });
}

pub fn ready(state: *AppState, _: *httpz.Request, res: *httpz.Response) !void {
    if (state.ready.load(.acquire)) {
        res.status = 200;
        res.body = "OK";
    } else {
        res.status = 503;
        res.body = "loading";
    }
}
