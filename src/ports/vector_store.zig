const types = @import("../domain/types.zig");

pub const SearchResult = types.SearchResult;
pub const Vector14 = types.Vector14;

pub const VectorStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // Fill caller-provided buffer with up to results.len nearest neighbors.
        // Returns the actual number of results written.
        search: *const fn (ptr: *anyopaque, query: Vector14, results: []SearchResult) anyerror!usize,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn search(self: VectorStore, query: Vector14, results: []SearchResult) !usize {
        return self.vtable.search(self.ptr, query, results);
    }

    pub fn deinit(self: VectorStore) void {
        self.vtable.deinit(self.ptr);
    }
};
