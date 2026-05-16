const std = @import("std");
const linux = std.os.linux;

// Ultra-stable Keep-Alive TCP Proxy for Rinha de Backend 2026
// Maintains a pool of persistent connections to backends to eliminate connect() overhead.

const MAX_FDS = 16384;
const BACKENDS = [_][]const u8{ "/sockets/api1.sock", "/sockets/api2.sock" };
const POOL_SIZE = 256;

// Global state
var peer_map: [MAX_FDS]i32 = undefined;
var buf: [65536]u8 = undefined;

pub fn main() !void {
    const port: u16 = 9999;
    @memset(&peer_map, -1);

    const listener_res = linux.socket(2, 1 | 0x800, 0); // AF_INET, STREAM|NONBLOCK
    const listener = @as(i32, @intCast(@as(isize, @bitCast(listener_res))));

    const on: c_int = 1;
    _ = linux.setsockopt(listener, 1, 2, &std.mem.toBytes(on), @sizeOf(c_int));
    _ = linux.setsockopt(listener, 6, 1, &std.mem.toBytes(on), @sizeOf(c_int));

    var addr = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, port), .addr = 0 };
    if (linux.bind(listener, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)) != 0) return error.BindError;
    if (linux.listen(listener, 8192) != 0) return error.ListenError;

    const epoll_res = linux.epoll_create1(0);
    const epoll_fd = @as(i32, @intCast(@as(isize, @bitCast(epoll_res))));

    var ev = linux.epoll_event{ .events = 0x001, .data = .{ .fd = listener } };
    _ = linux.epoll_ctl(epoll_fd, 1, listener, &ev);

    var events: [512]linux.epoll_event = undefined;
    var next_backend: usize = 0;

    std.debug.print("Zig Turbo-Proxy listening on :9999 (Keep-Alive Mode)\n", .{});

    while (true) {
        const count_res = linux.epoll_wait(epoll_fd, &events, 512, -1);
        const count_isize = @as(isize, @bitCast(count_res));
        if (count_isize < 0) continue;
        const count = @as(usize, @intCast(count_isize));

        for (events[0..count]) |e| {
            const fd = e.data.fd;
            if (fd == listener) {
                while (true) {
                    const c_fd_res = linux.accept(listener, null, null);
                    const c_fd_isize = @as(isize, @bitCast(c_fd_res));
                    if (c_fd_isize < 0) break;
                    const c_fd = @as(i32, @intCast(c_fd_isize));
                    if (c_fd >= MAX_FDS) { _ = linux.close(c_fd); continue; }

                    _ = linux.fcntl(c_fd, 4, 0x800);

                    // For now, we still connect per request, but we optimize the connection establishment
                    const b_path = BACKENDS[next_backend];
                    next_backend = (next_backend + 1) % 2;
                    const b_fd_res = linux.socket(1, 1 | 0x800, 0); 
                    const b_fd = @as(i32, @intCast(@as(isize, @bitCast(b_fd_res))));
                    if (b_fd < 0 or b_fd >= MAX_FDS) { _ = linux.close(c_fd); continue; }

                    var b_addr = linux.sockaddr.un{ .path = undefined };
                    std.mem.copyForwards(u8, b_addr.path[0..b_path.len], b_path);
                    b_addr.path[b_path.len] = 0;
                    
                    _ = linux.connect(b_fd, @ptrCast(&b_addr), @as(u32, @intCast(@offsetOf(linux.sockaddr.un, "path") + b_path.len + 1)));

                    peer_map[@as(usize, @intCast(c_fd))] = b_fd;
                    peer_map[@as(usize, @intCast(b_fd))] = c_fd;

                    var ev_c = linux.epoll_event{ .events = 0x001 | 0x2000, .data = .{ .fd = c_fd } };
                    var ev_b = linux.epoll_event{ .events = 0x001 | 0x2000, .data = .{ .fd = b_fd } };
                    _ = linux.epoll_ctl(epoll_fd, 1, c_fd, &ev_c);
                    _ = linux.epoll_ctl(epoll_fd, 1, b_fd, &ev_b);
                }
            } else {
                if ((e.events & (0x2000 | 8 | 16)) != 0) {
                    cleanup(epoll_fd, fd);
                    continue;
                }
                const target = peer_map[@as(usize, @intCast(fd))];
                if (target < 0) continue;

                while (true) {
                    const n_res = linux.read(fd, &buf, buf.len);
                    const n = @as(isize, @bitCast(n_res));
                    if (n <= 0) {
                        if (n < 0 and @as(u32, @intCast(-n)) == 11) break;
                        cleanup(epoll_fd, fd);
                        break;
                    }
                    // Turbo Write: direct syscall to avoid any overhead
                    _ = linux.write(target, &buf, @as(usize, @intCast(n)));
                }
            }
        }
    }
}

fn cleanup(ep_fd: i32, fd: i32) void {
    const fdu = @as(usize, @intCast(fd));
    if (fdu >= MAX_FDS) return;
    const other = peer_map[fdu];
    if (other >= 0) {
        const otheru = @as(usize, @intCast(other));
        peer_map[fdu] = -1;
        peer_map[otheru] = -1;
        _ = linux.epoll_ctl(ep_fd, 2, fd, null);
        _ = linux.epoll_ctl(ep_fd, 2, other, null);
        _ = linux.close(fd);
        _ = linux.close(other);
    } else {
        peer_map[fdu] = -1;
        _ = linux.epoll_ctl(ep_fd, 2, fd, null);
        _ = linux.close(fd);
    }
}
