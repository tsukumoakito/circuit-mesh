const std = @import("std");
const posix = std.posix;
const net = std.net;
const mem = std.mem;
const linux = std.os.linux;

const AF_INET = 2;
const AF_INET6 = 10;
const AF_NETLINK = 16;
const NETLINK_NETFILTER = 12;
const NFNL_SUBSYS_IPSET = 6;

const IPSET_CMD_CREATE = 2;
const IPSET_CMD_ADD = 9;
const IPSET_CMD_DEL = 10;

const IPSET_ATTR_PROTOCOL = 1;
const IPSET_ATTR_SETNAME = 2;
const IPSET_ATTR_TYPENAME = 3;
const IPSET_ATTR_REVISION = 4;
const IPSET_ATTR_FAMILY = 5;
const IPSET_ATTR_DATA = 7;
const IPSET_ATTR_IP = 1;
const IPSET_ATTR_IPADDR_IPV4 = 1;
const IPSET_ATTR_IPADDR_IPV6 = 2;

const nlmsghdr = extern struct {
    len: u32,
    type: u16,
    flags: u16,
    seq: u32,
    pid: u32,
};

const nfgenmsg = extern struct {
    nfgen_family: u8,
    version: u8,
    res_id: u16,
};

const nlattr = extern struct {
    nla_len: u16,
    nla_type: u16,
};

const sockaddr_nl = extern struct {
    family: u16,
    pad: u16 = 0,
    pid: u32 = 0,
    groups: u32 = 0,
};

pub const NetlinkEngine = struct {
    nl_sock: ?posix.socket_t = null,
    debug: bool,
    ipset_name: []const u8,
    initialized_v4: bool = false,
    initialized_v6: bool = false,

    pub fn init(debug: bool, ipset_name: []const u8) NetlinkEngine {
        return .{
            .debug = debug,
            .ipset_name = ipset_name,
        };
    }

    fn ensureSocket(self: *NetlinkEngine) !posix.socket_t {
        if (self.nl_sock) |fd| return fd;
        const fd = try posix.socket(AF_NETLINK, posix.SOCK.RAW, NETLINK_NETFILTER);
        errdefer posix.close(fd);

        var addr = mem.zeroInit(sockaddr_nl, .{ .family = AF_NETLINK });
        try posix.bind(fd, @ptrCast(&addr), @sizeOf(sockaddr_nl));

        self.nl_sock = fd;
        return fd;
    }

    fn createIpset(self: *NetlinkEngine, name: []const u8, family: u8) !void {
        const fd = try self.ensureSocket();

        var buf: [512]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();

        const header_pos = fbs.pos;
        try writer.writeStruct(nlmsghdr{
            .len = 0,
            .type = (@as(u16, NFNL_SUBSYS_IPSET) << 8) | @as(u16, IPSET_CMD_CREATE),
            .flags = linux.NLM_F_REQUEST | linux.NLM_F_ACK | 0x600,
            .seq = @as(u32, @intCast(std.time.timestamp() & 0xFFFFFFFF)),
            .pid = 0,
        });

        try writer.writeStruct(nfgenmsg{ .nfgen_family = AF_INET, .version = 0, .res_id = 0 });

        try self.writeAttr(writer, IPSET_ATTR_PROTOCOL, &[_]u8{7});

        var name_z: [64]u8 = undefined;
        const n = @min(name.len, 63);
        @memcpy(name_z[0..n], name[0..n]);
        name_z[n] = 0;
        try self.writeAttr(writer, IPSET_ATTR_SETNAME, name_z[0 .. n + 1]);

        try self.writeAttr(writer, IPSET_ATTR_TYPENAME, "hash:ip\x00");
        try self.writeAttr(writer, IPSET_ATTR_REVISION, &[_]u8{6});
        try self.writeAttr(writer, IPSET_ATTR_FAMILY, &[_]u8{family});
        try writer.writeStruct(nlattr{ .nla_len = 4, .nla_type = 0x8000 | IPSET_ATTR_DATA });

        const total_len = @as(u32, @intCast(fbs.pos));
        mem.writeInt(u32, @ptrCast(buf[header_pos..][0..4]), total_len, .little);

        _ = try posix.send(fd, fbs.getWritten(), 0);

        var rx_buf: [1024]u8 = undefined;
        const rx_len = try posix.recv(fd, &rx_buf, 0);
        if (rx_len >= @sizeOf(nlmsghdr)) {
            const err_val = mem.readInt(i32, rx_buf[@sizeOf(nlmsghdr)..][0..4], .little);
            if (self.debug and err_val != 0 and err_val != -17) {
                std.debug.print("⚠️ ipset create failed for {s}: {d}\n", .{ name, err_val });
            } else if (self.debug and err_val == 0) {
                std.debug.print("✅ ipset '{s}' created (family {d}).\n", .{ name, family });
            }
        }
    }

    pub fn updateBarrier(self: *NetlinkEngine, cmd: u8, ip_str: []const u8) !void {
        const is_ipv6 = mem.indexOfScalar(u8, ip_str, ':') != null;
        const family: u8 = if (is_ipv6) AF_INET6 else AF_INET;

        var name_buf: [64]u8 = undefined;
        var target_set_name: []const u8 = self.ipset_name;
        if (is_ipv6) {
            target_set_name = try std.fmt.bufPrint(&name_buf, "{s}6", .{self.ipset_name});
            if (!self.initialized_v6) {
                try self.createIpset(target_set_name, AF_INET6);
                self.initialized_v6 = true;
            }
        } else {
            if (!self.initialized_v4) {
                try self.createIpset(target_set_name, AF_INET);
                self.initialized_v4 = true;
            }
        }

        const fd = try self.ensureSocket();
        var buf: [512]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();

        const header_pos = fbs.pos;
        try writer.writeStruct(nlmsghdr{
            .len = 0,
            .type = (@as(u16, NFNL_SUBSYS_IPSET) << 8) | @as(u16, cmd),
            .flags = linux.NLM_F_REQUEST | linux.NLM_F_ACK,
            .seq = @as(u32, @intCast(std.time.timestamp() & 0xFFFFFFFF)),
            .pid = 0,
        });

        try writer.writeStruct(nfgenmsg{ .nfgen_family = family, .version = 0, .res_id = 0 });

        try self.writeAttr(writer, IPSET_ATTR_PROTOCOL, &[_]u8{7});

        var n_buf: [64]u8 = undefined;
        const n = @min(target_set_name.len, 63);
        @memcpy(n_buf[0..n], target_set_name[0..n]);
        n_buf[n] = 0;
        try self.writeAttr(writer, IPSET_ATTR_SETNAME, n_buf[0 .. n + 1]);

        const data_start = fbs.pos;
        try writer.writeStruct(nlattr{ .nla_len = 0, .nla_type = 0x8000 | IPSET_ATTR_DATA });
        {
            const ip_nest_start = fbs.pos;
            try writer.writeStruct(nlattr{ .nla_len = 0, .nla_type = 0x8000 | IPSET_ATTR_IP });
            {
                if (is_ipv6) {
                    const ip_addr = try net.Address.parseIp6(ip_str, 0);
                    try self.writeAttr(writer, 0x4000 | IPSET_ATTR_IPADDR_IPV6, &ip_addr.in6.sa.addr);
                } else {
                    const ip_addr = try net.Address.parseIp4(ip_str, 0);
                    try self.writeAttr(writer, 0x4000 | IPSET_ATTR_IPADDR_IPV4, mem.asBytes(&ip_addr.in.sa.addr));
                }
            }
            const ip_nest_len = @as(u16, @intCast(fbs.pos - ip_nest_start));
            mem.writeInt(u16, @ptrCast(buf[ip_nest_start..][0..2]), ip_nest_len, .little);
            try self.writeAttr(writer, 0x4000 | 9, &[_]u8{ 0, 0, 0, 0 });
        }
        const data_len = @as(u16, @intCast(fbs.pos - data_start));
        mem.writeInt(u16, @ptrCast(buf[data_start..][0..2]), data_len, .little);

        const total_len = @as(u32, @intCast(fbs.pos));
        mem.writeInt(u32, @ptrCast(buf[header_pos..][0..4]), total_len, .little);

        _ = try posix.send(fd, fbs.getWritten(), 0);

        var rx_buf: [256]u8 = undefined;
        _ = posix.recv(fd, &rx_buf, posix.MSG.DONTWAIT) catch {};
    }

    fn writeAttr(self: *NetlinkEngine, writer: anytype, attr_type: u16, data: []const u8) !void {
        _ = self;
        const len = @as(u16, @intCast(4 + data.len));
        try writer.writeStruct(nlattr{ .nla_len = len, .nla_type = attr_type });
        try writer.writeAll(data);
        const pad = (4 - (len % 4)) % 4;
        if (pad > 0) try writer.writeByteNTimes(0, pad);
    }
};
