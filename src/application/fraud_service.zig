const std = @import("std");
const types = @import("../domain/types.zig");
const vectorizer = @import("../domain/vectorizer.zig");
const scorer = @import("../domain/scorer.zig");
const vector_store = @import("../ports/vector_store.zig");

pub const FraudRequest = types.FraudRequest;
pub const FraudResponse = types.FraudResponse;
pub const MccRisk = vectorizer.MccRisk;
pub const SearchResult = types.SearchResult;

pub const FraudService = struct {
    store: vector_store.VectorStore,
    mcc_risk: MccRisk,
    threshold: f32,
    active_requests: *std.atomic.Value(u32),
    adaptive_min: u32,
    adaptive_max: u32,

    pub fn init(store: vector_store.VectorStore, mcc_risk: MccRisk, threshold: f32, active_requests: *std.atomic.Value(u32), adaptive_min: u32, adaptive_max: u32) FraudService {
        return .{
            .store = store,
            .mcc_risk = mcc_risk,
            .threshold = threshold,
            .active_requests = active_requests,
            .adaptive_min = adaptive_min,
            .adaptive_max = adaptive_max,
        };
    }

    // Evaluate a fraud request, using caller's stack buffer for k-NN results (no heap alloc)
    pub fn evaluate(self: *const FraudService, req: *const FraudRequest) !FraudResponse {
        const active = self.active_requests.fetchAdd(1, .monotonic);
        defer _ = self.active_requests.fetchSub(1, .monotonic);

        // Simple adaptive logic: if more than 2 requests are active, use min nprobe (faster)
        const nprobe = if (active > 2) self.adaptive_min else self.adaptive_max;

        const vec = vectorizer.vectorize(req, &self.mcc_risk);

        var results_buf: [5]SearchResult = undefined;
        const n = try self.store.search(vec, &results_buf, nprobe);

        return scorer.score(results_buf[0..n], self.threshold);
    }
};
