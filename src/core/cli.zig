const std = @import("std");

pub const CliResult = struct {
    debug_mode: bool,
    config_path: []const u8,
};

pub fn parse(allocator: std.mem.Allocator) !CliResult {
    var debug_mode = false;
    var config_path: []const u8 = "/etc/net-bastion/config.json";
    var config_explicit = false;

    const args = try std.process.argsAlloc(allocator);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--debug")) {
            debug_mode = true;
        } else if (std.mem.eql(u8, args[i], "--config")) {
            if (i + 1 < args.len) {
                config_path = args[i + 1];
                config_explicit = true;
                i += 1;
            }
        }
    }

    if (!config_explicit) {
        if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
            defer allocator.free(home);
            const user_cfg = try std.fs.path.join(allocator, &[_][]const u8{ home, ".config", "net-bastion", "config.json" });
            if (std.fs.accessAbsolute(user_cfg, .{})) |_| {
                config_path = try allocator.dupe(u8, user_cfg);
            } else |_| {
                allocator.free(user_cfg);
            }
        } else |_| {}
    }

    return CliResult{
        .debug_mode = debug_mode,
        .config_path = config_path,
    };
}
