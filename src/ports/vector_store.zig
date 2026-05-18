const types = @import("../domain/types.zig");

pub const SearchResult = types.SearchResult;
pub const Vector16i16 = types.Vector16i16;

pub const VectorStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        search: *const fn (ptr: *anyopaque, query: Vector16i16, results: []SearchResult) anyerror!usize,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn search(self: VectorStore, query: Vector16i16, results: []SearchResult) !usize {
        return self.vtable.search(self.ptr, query, results);
    }

    pub fn deinit(self: VectorStore) void {
        self.vtable.deinit(self.ptr);
    }
};
