const std = @import("std");
const domain = @import("domain");
const types = domain.types;

const FraudRequest = types.FraudRequest;

pub fn parseManual(allocator: std.mem.Allocator, json: []const u8) !FraudRequest {
    var scanner = std.json.Scanner.initCompleteInput(allocator, json);
    defer scanner.deinit();

    var req: FraudRequest = undefined;
    req.last_transaction = null; // Default to null

    if (try scanner.next() != .object_begin) return error.BadJson;

    while (true) {
        const token = try scanner.next();
        if (token == .object_end) break;
        const key = switch (token) {
            .string => |s| s,
            else => return error.BadJson,
        };

        if (key.len > 0) {
            switch (key[0]) {
                'i' => {
                    if (std.mem.eql(u8, key, "id")) req.id = try parseString(allocator, &scanner) else try scanner.skipValue();
                },
                't' => {
                    if (std.mem.eql(u8, key, "transaction")) req.transaction = try parseTransaction(allocator, &scanner) else if (std.mem.eql(u8, key, "terminal")) req.terminal = try parseTerminal(&scanner) else try scanner.skipValue();
                },
                'c' => {
                    if (std.mem.eql(u8, key, "customer")) req.customer = try parseCustomer(allocator, &scanner) else try scanner.skipValue();
                },
                'm' => {
                    if (std.mem.eql(u8, key, "merchant")) req.merchant = try parseMerchant(allocator, &scanner) else try scanner.skipValue();
                },
                'l' => {
                    if (std.mem.eql(u8, key, "last_transaction")) {
                        const next_tok = try scanner.next();
                        if (next_tok == .null) {
                            // already consumed
                        } else if (next_tok == .object_begin) {
                            req.last_transaction = try parseLastTransactionBody(&scanner);
                        } else {
                            return error.BadJson;
                        }
                    } else {
                        try scanner.skipValue();
                    }
                },
                else => try scanner.skipValue(),
            }
        } else {
            try scanner.skipValue();
        }
    }

    return req;
}

fn parseString(allocator: std.mem.Allocator, scanner: *std.json.Scanner) ![]const u8 {
    const token = try scanner.nextAlloc(allocator, .alloc_if_needed);
    return switch (token) {
        .allocated_string => |s| s,
        .string => |s| s,
        else => error.ExpectedString,
    };
}

fn parseNumber(scanner: *std.json.Scanner) !f64 {
    const token = try scanner.next();
    return switch (token) {
        .number => |s| try std.fmt.parseFloat(f64, s),
        else => error.ExpectedNumber,
    };
}

fn parseTransaction(allocator: std.mem.Allocator, scanner: *std.json.Scanner) !FraudRequest.TransactionInfo {
    if (try scanner.next() != .object_begin) return error.BadJson;
    var info: FraudRequest.TransactionInfo = undefined;
    while (true) {
        const tok = try scanner.next();
        if (tok == .object_end) break;
        const key = switch (tok) {
            .string => |s| s,
            else => return error.BadJson,
        };
        if (std.mem.eql(u8, key, "amount")) info.amount = try parseNumber(scanner) else if (std.mem.eql(u8, key, "installments")) {
            const num = try scanner.next();
            info.installments = try std.fmt.parseInt(u8, num.number, 10);
        } else if (std.mem.eql(u8, key, "requested_at")) info.requested_at = try parseString(allocator, scanner) else try scanner.skipValue();
    }
    return info;
}

fn parseCustomer(allocator: std.mem.Allocator, scanner: *std.json.Scanner) !FraudRequest.CustomerInfo {
    if (try scanner.next() != .object_begin) return error.BadJson;
    var info: FraudRequest.CustomerInfo = undefined;
    while (true) {
        const tok = try scanner.next();
        if (tok == .object_end) break;
        const key = switch (tok) {
            .string => |s| s,
            else => return error.BadJson,
        };
        if (std.mem.eql(u8, key, "avg_amount")) info.avg_amount = try parseNumber(scanner) else if (std.mem.eql(u8, key, "tx_count_24h")) {
            const num = try scanner.next();
            info.tx_count_24h = try std.fmt.parseInt(u32, num.number, 10);
        } else if (std.mem.eql(u8, key, "known_merchants")) {
            if (try scanner.next() != .array_begin) return error.BadJson;
            var list: std.ArrayListUnmanaged([]const u8) = .empty;
            while (true) {
                const inner_tok = try scanner.nextAlloc(allocator, .alloc_if_needed);
                if (inner_tok == .array_end) break;
                const s = switch (inner_tok) {
                    .string => |val| val,
                    .allocated_string => |val| val,
                    else => return error.BadJson,
                };
                try list.append(allocator, s);
            }
            info.known_merchants = try list.toOwnedSlice(allocator);
        } else try scanner.skipValue();
    }
    return info;
}

fn parseMerchant(allocator: std.mem.Allocator, scanner: *std.json.Scanner) !FraudRequest.MerchantInfo {
    if (try scanner.next() != .object_begin) return error.BadJson;
    var info: FraudRequest.MerchantInfo = undefined;
    while (true) {
        const tok = try scanner.next();
        if (tok == .object_end) break;
        const key = switch (tok) {
            .string => |s| s,
            else => return error.BadJson,
        };
        if (std.mem.eql(u8, key, "id")) info.id = try parseString(allocator, scanner) else if (std.mem.eql(u8, key, "mcc")) info.mcc = try parseString(allocator, scanner) else if (std.mem.eql(u8, key, "avg_amount")) info.avg_amount = try parseNumber(scanner) else try scanner.skipValue();
    }
    return info;
}

fn parseTerminal(scanner: *std.json.Scanner) !FraudRequest.TerminalInfo {
    if (try scanner.next() != .object_begin) return error.BadJson;
    var info: FraudRequest.TerminalInfo = undefined;
    while (true) {
        const tok = try scanner.next();
        if (tok == .object_end) break;
        const key = switch (tok) {
            .string => |s| s,
            else => return error.BadJson,
        };
        if (std.mem.eql(u8, key, "is_online")) info.is_online = (try scanner.next()) == .true else if (std.mem.eql(u8, key, "card_present")) info.card_present = (try scanner.next()) == .true else if (std.mem.eql(u8, key, "km_from_home")) info.km_from_home = try parseNumber(scanner) else try scanner.skipValue();
    }
    return info;
}

fn parseLastTransactionBody(scanner: *std.json.Scanner) !FraudRequest.LastTransactionInfo {
    var info: FraudRequest.LastTransactionInfo = undefined;
    while (true) {
        const tok = try scanner.next();
        if (tok == .object_end) break;
        const key = switch (tok) {
            .string => |s| s,
            else => return error.BadJson,
        };
        if (std.mem.eql(u8, key, "timestamp")) {
            const s_tok = try scanner.next();
            info.timestamp = switch (s_tok) {
                .string => |s| s,
                else => return error.BadJson,
            };
        } else if (std.mem.eql(u8, key, "km_from_current")) info.km_from_current = try parseNumber(scanner) else try scanner.skipValue();
    }
    return info;
}
