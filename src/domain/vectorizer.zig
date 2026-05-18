const std = @import("std");
const types = @import("types.zig");

pub const Vector14 = types.Vector14;
pub const FraudRequest = types.FraudRequest;

// MCC risk table (keys are string MCCs from mcc_risk.json)
pub const MccRisk = struct {
    table: [10]Entry,
    len: usize,

    pub const Entry = struct { mcc: []const u8, risk: f32 };

    pub fn get(self: *const MccRisk, mcc: []const u8) f32 {
        if (mcc.len < 4) return 0.5;
        const target = @as(u32, @bitCast(mcc[0..4].*));
        for (self.table[0..self.len]) |e| {
            if (e.mcc.len >= 4 and @as(u32, @bitCast(e.mcc[0..4].*)) == target) return e.risk;
        }
        return 0.5;
    }

    pub fn fromJson(json_str: []const u8, allocator: std.mem.Allocator) !MccRisk {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
        defer parsed.deinit();

        var result = MccRisk{ .table = undefined, .len = 0 };
        var it = parsed.value.object.iterator();
        while (it.next()) |entry| {
            if (result.len >= 10) break;
            result.table[result.len] = .{
                .mcc = try allocator.dupe(u8, entry.key_ptr.*),
                .risk = @floatCast(entry.value_ptr.float),
            };
            result.len += 1;
        }
        return result;
    }
};

pub fn vectorize(req: *const FraudRequest, mcc_risk: *const MccRisk) Vector14 {
    var v: [14]f32 = undefined;

    const amount: f32 = @floatCast(req.transaction.amount);
    const avg_amount: f32 = @floatCast(req.customer.avg_amount);

    v[0] = clamp(amount / 10000.0);
    v[1] = clamp(@as(f32, @floatFromInt(req.transaction.installments)) / 12.0);
    v[2] = clamp(if (avg_amount > 0) (amount / avg_amount) / 10.0 else 1.0);

    const hour, const dow = parseTimestamp(req.transaction.requested_at);
    v[3] = @as(f32, @floatFromInt(hour)) / 23.0;
    v[4] = @as(f32, @floatFromInt(dow)) / 6.0;

    if (req.last_transaction) |lt| {
        const minutes = minutesBetween(lt.timestamp, req.transaction.requested_at);
        v[5] = clamp(@as(f32, @floatCast(minutes)) / 1440.0);
        v[6] = clamp(@as(f32, @floatCast(lt.km_from_current)) / 1000.0);
    } else {
        v[5] = -1.0;
        v[6] = -1.0;
    }

    v[7] = clamp(@as(f32, @floatCast(req.terminal.km_from_home)) / 1000.0);
    v[8] = clamp(@as(f32, @floatFromInt(req.customer.tx_count_24h)) / 20.0);
    v[9] = if (req.terminal.is_online) 1.0 else 0.0;
    v[10] = if (req.terminal.card_present) 1.0 else 0.0;
    v[11] = if (isUnknownMerchant(req.merchant.id, req.customer.known_merchants)) 1.0 else 0.0;
    v[12] = mcc_risk.get(req.merchant.mcc);
    v[13] = clamp(@as(f32, @floatCast(req.merchant.avg_amount)) / 10000.0);

    return v;
}

// Quantize f32 vector → i16 with SCALE=10000; sentinel for -1.0 dimensions
pub fn vectorizeI16(req: *const FraudRequest, mcc_risk: *const MccRisk) types.Vector16i16 {
    const f: [14]f32 = vectorize(req, mcc_risk); // coerce vector → array for runtime indexing
    var out: types.Vector16i16 = [_]i16{0} ** 16;
    for (0..14) |i| {
        out[i] = if (f[i] < -0.5)
            types.SENTINEL
        else
            @intCast(@min(10000, @max(-9999, @as(i32, @intFromFloat(@round(f[i] * @as(f32, @floatFromInt(types.SCALE))))))));
    }
    return out;
}

// 8-bit partition key derived from binary feature thresholds
pub fn partitionKey(v: types.Vector16i16) u8 {
    var key: u8 = 0;
    if (v[5] != types.SENTINEL) key |= 1;   // has last_transaction
    if (v[9] > 5000)  key |= 2;             // is_online
    if (v[10] > 5000) key |= 4;             // card_present
    if (v[11] > 5000) key |= 8;             // unknown_merchant
    if (v[12] < 3300) key |= 16;            // mcc_risk low (<0.33)
    if (v[12] > 6600) key |= 32;            // mcc_risk high (>0.66)
    if (v[2] > 4000)  key |= 64;            // amount anomaly (>4x avg)
    if (v[8] > 2500)  key |= 128;           // high velocity (>5 tx/24h)
    return key;
}

fn isUnknownMerchant(merchant_id: []const u8, known: [][]const u8) bool {
    for (known) |k| {
        if (std.mem.eql(u8, k, merchant_id)) return false;
    }
    return true;
}

fn clamp(val: f32) f32 {
    return @max(0.0, @min(1.0, val));
}

// Returns {hour_utc (0-23), day_of_week (0=Mon, 6=Sun)}
fn parseTimestamp(iso: []const u8) struct { u8, u8 } {
    if (iso.len < 19) return .{ 0, 0 };

    const year = fastParseInt4(iso, 0);
    const month = fastParseInt2(iso, 5);
    const day = fastParseInt2(iso, 8);
    const hour = fastParseInt2(iso, 11);

    const dow = dayOfWeek(year, month, day);
    return .{ @intCast(hour), @intCast(dow) };
}

// Returns minutes between prev_ts and curr_ts (curr - prev), clamped to >= 0
fn minutesBetween(prev_ts: []const u8, curr_ts: []const u8) f64 {
    const t1 = epochSeconds(prev_ts);
    const t2 = epochSeconds(curr_ts);
    const diff = t2 - t1;
    return @as(f64, @floatFromInt(if (diff > 0) diff else 0)) / 60.0;
}

inline fn fastParseInt2(s: []const u8, start: usize) i64 {
    return @as(i64, s[start] - '0') * 10 + @as(i64, s[start + 1] - '0');
}

inline fn fastParseInt4(s: []const u8, start: usize) i64 {
    return @as(i64, s[start] - '0') * 1000 +
        @as(i64, s[start + 1] - '0') * 100 +
        @as(i64, s[start + 2] - '0') * 10 +
        @as(i64, s[start + 3] - '0');
}

// Tomohiko Sakamoto's algorithm: 0=Sun, 1=Mon, ..., 6=Sat -> convert to Mon=0, Sun=6
fn dayOfWeek(year_: i64, month_: i64, day: i64) u8 {
    const t = [_]i64{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    var y = year_;
    const m = month_;
    if (m < 3) y -= 1;
    const sakamoto = @mod(y + @divTrunc(y, 4) - @divTrunc(y, 100) + @divTrunc(y, 400) + t[@intCast(m - 1)] + day, 7);
    return @intCast(@mod(sakamoto + 6, 7));
}

// Howard Hinnant's civil_to_days + time => epoch seconds
fn epochSeconds(iso: []const u8) i64 {
    if (iso.len < 19) return 0;
    const y = fastParseInt4(iso, 0);
    const m = fastParseInt2(iso, 5);
    const d = fastParseInt2(iso, 8);
    const h = fastParseInt2(iso, 11);
    const min = fastParseInt2(iso, 14);
    const s = fastParseInt2(iso, 17);

    var year = y;
    const month = m;
    if (month <= 2) year -= 1;
    const era: i64 = @divTrunc(if (year >= 0) year else year - 399, 400);
    const yoe: i64 = year - era * 400;
    const month_adj: i64 = if (m > 2) month - 3 else month + 9;
    const doy: i64 = @divTrunc(153 * month_adj + 2, 5) + d - 1;
    const doe: i64 = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    const epoch_days: i64 = era * 146097 + doe - 719468;

    return epoch_days * 86400 + h * 3600 + min * 60 + s;
}
