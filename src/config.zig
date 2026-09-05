const std = @import("std");

pub const Config = struct {
    ipset_name: []const u8,
    monitoring_interval_ms: u64,
    mem_report_interval_s: i64,
    email_store_path: []const u8,
    cold_start_doh_enabled: bool,
    doh_fallback_allowed: bool,
    force_debug_mode: bool,
    global_settings: GlobalSettings,
    rotation_profiles: []RotationProfile,
    tor_global: TorGlobalConfig,
    tor_instances: []TorInstance,
    proxy_groups: []ProxyGroup,
    dns_tunnels: []DnsTunnel,
    email_providers: []EmailProvider,

    pub const GlobalSettings = struct {
        max_concurrent_rotations: u32,
        rotation_check_interval_s: u32,
    };

    pub const RotationProfile = struct {
        name: []const u8,
        min_ttl: i64,
        max_ttl: i64,
    };

    pub const TorGlobalConfig = struct {
        socks_ip: []const u8,
        socks_port: u16,
        control_ip: []const u8,
        control_port: u16,
        cookie_path: []const u8,
        binary_path: []const u8,
        state_path: []const u8,
        consensus_path: []const u8,
    };

    pub const TorInstance = struct {
        id: u8,
        interface: []const u8,
        local_ip: []const u8,
        socks_port: u16,
        http_port: u16,
        fwmark: u32,
    };

    pub const ProxyGroup = struct {
        group_name: []const u8,
        instances: []ProxyInstance,
    };

    pub const ProxyInstance = struct {
        id: u8,
        interface: []const u8,
        local_ip: []const u8,
        socks_port: u16,
        http_port: u16,
        fwmark: u32,
    };

    pub const DnsTunnel = struct {
        name: []const u8,
        ip: []const u8,
        sni: []const u8,
        doh_path: []const u8,
        local_ip: []const u8,
        local_port: u16,
    };

    pub const EmailProvider = struct {
        name: []const u8,
        local_ip: []const u8,
        domains: [][]const u8,
        imap_host: []const u8,
        smtp_host: []const u8,
        imap_port: u16,
        smtp_port: u16,
        imap_start_port: u16,
        smtp_start_port: u16,
        default_route: []const u8,
    };

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(Config) {
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 4 * 1024 * 1024);
        defer allocator.free(content);

        return try std.json.parseFromSlice(Config, allocator, content, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }
};
