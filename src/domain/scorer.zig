const std = @import("std");
const types = @import("types.zig");

pub const SearchResult = types.SearchResult;
pub const FraudResponse = types.FraudResponse;

// Simple k-NN majority vote: fraud_score = fraud_count / k
// threshold = 0.6 (fixed by challenge spec)
pub fn score(neighbors: []const SearchResult, threshold: f32) FraudResponse {
    if (neighbors.len == 0) {
        return .{ .approved = true, .fraud_score = 0.0 };
    }

    var fraud_count: u32 = 0;
    for (neighbors) |n| {
        if (n.is_fraud) fraud_count += 1;
    }

    const fraud_score: f32 = @as(f32, @floatFromInt(fraud_count)) / @as(f32, @floatFromInt(neighbors.len));
    return .{
        .approved = fraud_score < threshold,
        .fraud_score = fraud_score,
    };
}

test "scorer simple vote threshold 0.6" {
    // 0 of 5 are fraud → score=0.0 → approved
    const n0 = [_]SearchResult{
        .{ .distance = 0.1, .is_fraud = false },
        .{ .distance = 0.2, .is_fraud = false },
        .{ .distance = 0.3, .is_fraud = false },
        .{ .distance = 0.4, .is_fraud = false },
        .{ .distance = 0.5, .is_fraud = false },
    };
    const r0 = score(&n0, 0.6);
    try std.testing.expect(r0.approved == true);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), r0.fraud_score, 0.001);

    // 2 of 5 are fraud → score=0.4 → approved (0.4 < 0.6)
    const n2 = [_]SearchResult{
        .{ .distance = 0.1, .is_fraud = true },
        .{ .distance = 0.2, .is_fraud = true },
        .{ .distance = 0.3, .is_fraud = false },
        .{ .distance = 0.4, .is_fraud = false },
        .{ .distance = 0.5, .is_fraud = false },
    };
    const r2 = score(&n2, 0.6);
    try std.testing.expect(r2.approved == true);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), r2.fraud_score, 0.001);

    // 3 of 5 are fraud → score=0.6 → denied (0.6 NOT < 0.6)
    const n3 = [_]SearchResult{
        .{ .distance = 0.1, .is_fraud = true },
        .{ .distance = 0.2, .is_fraud = true },
        .{ .distance = 0.3, .is_fraud = true },
        .{ .distance = 0.4, .is_fraud = false },
        .{ .distance = 0.5, .is_fraud = false },
    };
    const r3 = score(&n3, 0.6);
    try std.testing.expect(r3.approved == false);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), r3.fraud_score, 0.001);

    // 5 of 5 are fraud → score=1.0 → denied
    const n5 = [_]SearchResult{
        .{ .distance = 0.1, .is_fraud = true },
        .{ .distance = 0.2, .is_fraud = true },
        .{ .distance = 0.3, .is_fraud = true },
        .{ .distance = 0.4, .is_fraud = true },
        .{ .distance = 0.5, .is_fraud = true },
    };
    const r5 = score(&n5, 0.6);
    try std.testing.expect(r5.approved == false);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), r5.fraud_score, 0.001);
}
