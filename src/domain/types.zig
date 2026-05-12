const std = @import("std");

pub const Vector14 = @Vector(14, f32);
pub const Vector14u8 = @Vector(14, u8);

// FraudRequest maps 1:1 to the JSON payload
pub const FraudRequest = struct {
    id: []const u8,
    transaction: TransactionInfo,
    customer: CustomerInfo,
    merchant: MerchantInfo,
    terminal: TerminalInfo,
    last_transaction: ?LastTransactionInfo,

    pub const TransactionInfo = struct {
        amount: f64,
        installments: u8,
        requested_at: []const u8,
    };

    pub const CustomerInfo = struct {
        avg_amount: f64,
        tx_count_24h: u32,
        known_merchants: [][]const u8,
    };

    pub const MerchantInfo = struct {
        id: []const u8,
        mcc: []const u8,
        avg_amount: f64,
    };

    pub const TerminalInfo = struct {
        is_online: bool,
        card_present: bool,
        km_from_home: f64,
    };

    pub const LastTransactionInfo = struct {
        timestamp: []const u8,
        km_from_current: f64,
    };
};

pub const FraudResponse = struct {
    approved: bool,
    fraud_score: f32,
};

pub const SearchResult = struct {
    distance: f32,
    is_fraud: bool,
};

pub const IndexHeader = extern struct {
    magic: u32 = MAGIC,
    version: u32 = 1,
    n_vectors: u32,
    n_centroids: u32,
    n_dims: u32 = 14,
    nprobe: u32 = 10,
    reserved: u64 = 0,

    pub const MAGIC: u32 = 0x52494E48;
};
