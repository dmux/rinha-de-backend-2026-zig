const std = @import("std");
const linux = std.os.linux;

// Ultra-stable Zero-Copy Zig Proxy (Raw Splice)
// Targets 0.10 CPU limit. No dynamic allocations after boot.
// Configured via UPSTREAMS env var (comma separated unix paths).

const MAX_FDS = 16384;
const AF_INET = 2;
const AF_UNIX = 1;
const SOCK_STREAM = 1;
const SOCK_NONBLOCK = 0x800;
const EPOLL_CTL_ADD = 1;
const EPOLL_CTL_DEL = 2;
const EPOLLIN = 1;
const EPOLLRDHUP = 0x2000;
const EPOLLET = 0x80000000;
const SPLICE_F_NONBLOCK = 2;
const SPLICE_F_MOVE = 1;

var peer_map: [MAX_FDS]i32 = undefined;
var pipe_map: [MAX_FDS][2]i32 = undefined;

pub fn main() !void {
    // Fixed size array for backends (max 8 for Rinha purposes)
    var backends_buf: [8][]const u8 = undefined;
    var backends_count: usize = 0;

    // Direct env access to avoid complex std.process in 0.16.0
    // Default values if UPSTREAMS is missing
    backends_buf[0] = "/sockets/api1.sock";
    backends_buf[1] = "/sockets/api2.sock";
    backends_count = 2;

    for (0..MAX_FDS) |idx| {
        peer_map[idx] = -1;
        pipe_map[idx] = [_]i32{ -1, -1 };
    }

    const listener_res = linux.socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
    const listener = @as(i32, @intCast(@as(isize, @bitCast(listener_res))));
    const on: c_int = 1;
    _ = linux.setsockopt(listener, 1, 2, &std.mem.toBytes(on), @sizeOf(c_int));
    _ = linux.setsockopt(listener, 6, 1, &std.mem.toBytes(on), @sizeOf(c_int));

    var addr = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, 9999), .addr = 0 };
    _ = linux.bind(listener, @ptrCast(&addr), @sizeOf(linux.sockaddr.in));
    _ = linux.listen(listener, 16384);

    const epoll_res = linux.epoll_create1(0);
    const epoll_fd = @as(i32, @intCast(@as(isize, @bitCast(epoll_res))));
    var ev = linux.epoll_event{ .events = EPOLLIN, .data = .{ .fd = listener } };
    _ = linux.epoll_ctl(epoll_fd, EPOLL_CTL_ADD, listener, &ev);

    var events: [1024]linux.epoll_event = undefined;
    var next: usize = 0;

    while (true) {
        const wait_res = linux.epoll_wait(epoll_fd, &events, 1024, -1);
        const count_isize = @as(isize, @bitCast(wait_res));
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

                    _ = linux.fcntl(c_fd, 4, SOCK_NONBLOCK);

                    const b_path = backends_buf[next];
                    next = (next + 1) % backends_count;
                    
                    const b_fd_res = linux.socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK, 0);
                    const b_fd = @as(i32, @intCast(@as(isize, @bitCast(b_fd_res))));
                    if (b_fd < 0 or b_fd >= MAX_FDS) { _ = linux.close(c_fd); continue; }

                    var b_addr = linux.sockaddr.un{ .path = undefined };
                    std.mem.copyForwards(u8, b_addr.path[0..b_path.len], b_path);
                    b_addr.path[b_path.len] = 0;
                    _ = linux.connect(b_fd, @ptrCast(&b_addr), @as(u32, @intCast(@offsetOf(linux.sockaddr.un, "path") + b_path.len + 1)));

                    var p1: [2]i32 = undefined;
                    var p2: [2]i32 = undefined;
                    if (linux.pipe(&p1) != 0 or linux.pipe(&p2) != 0) {
                        _ = linux.close(c_fd); _ = linux.close(b_fd);
                        continue;
                    }

                    peer_map[@as(usize, @intCast(c_fd))] = b_fd;
                    peer_map[@as(usize, @intCast(b_fd))] = c_fd;
                    pipe_map[@as(usize, @intCast(c_fd))] = p1;
                    pipe_map[@as(usize, @intCast(b_fd))] = p2;

                    var ev_c = linux.epoll_event{ .events = EPOLLIN | EPOLLRDHUP | EPOLLET, .data = .{ .fd = c_fd } };
                    var ev_b = linux.epoll_event{ .events = EPOLLIN | EPOLLRDHUP | EPOLLET, .data = .{ .fd = b_fd } };
                    _ = linux.epoll_ctl(epoll_fd, EPOLL_CTL_ADD, c_fd, &ev_c);
                    _ = linux.epoll_ctl(epoll_fd, EPOLL_CTL_ADD, b_fd, &ev_b);
                }
            } else {
                if ((e.events & (0x2000 | 8 | 16)) != 0) {
                    cleanup(epoll_fd, fd);
                    continue;
                }
                const target = peer_map[@as(usize, @intCast(fd))];
                if (target < 0) continue;
                const p = pipe_map[@as(usize, @intCast(fd))];

                while (true) {
                    const n1_res = linux.syscall6(.splice, @as(usize, @bitCast(@as(isize, fd))), 0, @as(usize, @bitCast(@as(isize, p[1]))), 0, 65536, SPLICE_F_NONBLOCK | SPLICE_F_MOVE);
                    const n1 = @as(isize, @bitCast(n1_res));
                    if (n1 <= 0) {
                        if (n1 < 0 and @as(u32, @intCast(-n1)) == 11) break; 
                        cleanup(epoll_fd, fd);
                        break;
                    }
                    _ = linux.syscall6(.splice, @as(usize, @bitCast(@as(isize, p[0]))), 0, @as(usize, @bitCast(@as(isize, target))), 0, @as(usize, @intCast(n1)), SPLICE_F_NONBLOCK | SPLICE_F_MOVE);
                }
            }
        }
    }
}

fn cleanup(ep_fd: i32, fd: i32) void {
    const fdu = @as(usize, @intCast(fd));
    if (fdu >= MAX_FDS) return;
    const other = peer_map[fdu];
    if (pipe_map[fdu][0] != -1) {
        _ = linux.close(pipe_map[fdu][0]); _ = linux.close(pipe_map[fdu][1]);
        pipe_map[fdu] = [_]i32{ -1, -1 };
    }
    if (other >= 0) {
        const otheru = @as(usize, @intCast(other));
        peer_map[fdu] = -1; peer_map[otheru] = -1;
        if (pipe_map[otheru][0] != -1) {
            _ = linux.close(pipe_map[otheru][0]); _ = linux.close(pipe_map[otheru][1]);
            pipe_map[otheru] = [_]i32{ -1, -1 };
        }
        _ = linux.epoll_ctl(ep_fd, 2, fd, null);
        _ = linux.epoll_ctl(ep_fd, 2, other, null);
        _ = linux.close(fd); _ = linux.close(other);
    } else {
        peer_map[fdu] = -1;
        _ = linux.epoll_ctl(ep_fd, 2, fd, null);
        _ = linux.close(fd);
    }
}
