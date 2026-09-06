const std = @import("std");
pub const build_options = @import("build_options");
pub const version = build_options.version;

pub const core = struct {
    pub const env = struct {
        pub const CLI = @import("core/cli.zig");
        pub const Config = @import("config.zig").Config;
        pub const Tracker = @import("tracker.zig").TrackingAllocator;
    };

    pub const barrier = struct {
        pub const Sync = @import("core/barrier.zig");
    };

    pub const system = struct {
        pub const Netlink = @import("netlink.zig").NetlinkEngine;
    };
};

pub const sources = struct {
    pub const Tor = @import("sources/tor.zig").TorSource;
};

pub const services = struct {
    pub const dns = struct {
        pub const Manager = @import("services/dns.zig").DnsTunnelManager;

        pub const internal = struct {
            pub const Connection = @import("services/dns/connection.zig");
            pub const Crypto = @import("services/dns/crypto.zig");
            pub const H2 = @import("services/dns/h2.zig");
            pub const IO = @import("services/dns/io.zig");
            pub const Reporting = @import("services/dns/reporting.zig");
            pub const Types = @import("services/dns/types.zig");
            pub const Workers = @import("services/dns/workers.zig");
        };
    };
};

test {
    std.testing.refAllDecls(@This());
}
