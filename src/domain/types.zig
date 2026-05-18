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

// Specialist KD-Tree index types (i16 quantized, exact k-NN)
pub const SCALE: i32 = 10000;
pub const SENTINEL: i16 = -10000; // -1.0 sentinel for dims 5,6 (no last_transaction)

// 16-element i16 vector (dims 0..13 + 2 padding for AVX2 alignment)
pub const Vector16i16 = [16]i16;

// KD-tree node: 80 bytes
pub const KDNode = extern struct {
    left: u32,   // child index; 0xFFFFFFFF = leaf
    right: u32,
    start: u32,  // first block index (leaf only)
    count: u32,  // number of blocks (leaf only)
    min: [16]i16,
    max: [16]i16,
};

// AoSoA block: 8 vectors × 16 dims, layout dims[dim_idx][lane_idx]
pub const VecBlock = extern struct {
    dims: [16][8]i16,  // 256 bytes
    labels: [8]u8,
    _pad: [8]u8,       // total: 272 bytes
};

// Partition entry (256 total, indexed by 8-bit partition key)
pub const PartitionEntry = extern struct {
    root: u32,
    node_start: u32,
    node_count: u32,
    block_start: u32,
    block_count: u32,
    min: [16]i16,
    max: [16]i16,
};

// Specialist index file header
pub const SpecialistHeader = extern struct {
    magic: u32 = MAGIC,
    version: u32 = 1,
    n_vectors: u32 = 0,
    n_nodes: u32 = 0,
    n_blocks: u32 = 0,
    scale: i32 = 10000,
    _reserved: [8]u8 = [_]u8{0} ** 8,

    pub const MAGIC: u32 = 0x5350454B; // "SPEK"
};
