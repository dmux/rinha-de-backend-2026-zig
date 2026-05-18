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

    pub fn init(store: vector_store.VectorStore, mcc_risk: MccRisk, threshold: f32) FraudService {
        return .{ .store = store, .mcc_risk = mcc_risk, .threshold = threshold };
    }

    pub fn evaluate(self: *const FraudService, req: *const FraudRequest) !FraudResponse {
        const vec = vectorizer.vectorizeI16(req, &self.mcc_risk);

        var results_buf: [5]SearchResult = undefined;
        const n = try self.store.search(vec, &results_buf);

        return scorer.score(results_buf[0..n], self.threshold);
    }
};
