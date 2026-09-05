const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const net = std.net;
const posix = std.posix;
const Config = @import("../config.zig").Config;

pub const TorSource = struct {
    allocator: mem.Allocator,
    debug: bool,
    config: Config.TorGlobalConfig,
    control_stream: ?net.Stream = null,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, debug: bool, config: Config.TorGlobalConfig) TorSource {
        return .{
            .allocator = allocator,
            .debug = debug,
            .config = config,
            .control_stream = null,
        };
    }

    pub fn deinit(self: *TorSource) void {
        if (self.control_stream) |s| s.close();
        self.control_stream = null;
    }

    fn getControlStream(self: *TorSource, should_log: bool) !net.Stream {
        if (self.control_stream) |s| return s;

        if (self.debug and should_log) std.debug.print("🔄 Establishing Persistent ControlPort Connection...\n", .{});
        const stream = net.tcpConnectToHost(self.allocator, self.config.control_ip, self.config.control_port) catch |err| {
            if (self.debug and should_log) std.debug.print("⚠️ ControlPort Connection failed: {any}\n", .{err});
            return err;
        };
        errdefer stream.close();

        const cookie_hex = try self.getTorCookieHex(self.allocator);
        defer self.allocator.free(cookie_hex);

        try self.posixWriteAll(stream.handle, "AUTHENTICATE ");
        try self.posixWriteAll(stream.handle, cookie_hex);
        try self.posixWriteAll(stream.handle, "\r\n");

        var buf: [128]u8 = undefined;
        const n = try posix.read(stream.handle, &buf);
        if (n == 0 or !mem.startsWith(u8, buf[0..n], "250 OK")) {
            return error.TorAuthFailed;
        }

        self.control_stream = stream;
        return stream;
    }

    pub fn runCommand(self: *TorSource, cmd: []const u8, buf: []u8) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const stream = try self.getControlStream(true);
        try self.posixWriteAll(stream.handle, cmd);

        const n = try posix.read(stream.handle, buf);
        if (n == 0) {
            if (self.control_stream) |s| s.close();
            self.control_stream = null;
            return error.ControlPortDisconnected;
        }
        return buf[0..n];
    }

    /// Logic 2 & 3: 指定されたSOCKSユーザーに紐付く回路を強制パージする (Logic 4: 同期確認強化版)
    pub fn requestCircuitPurge(self: *TorSource, socks_user: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const stream = try self.getControlStream(true);
        try self.posixWriteAll(stream.handle, "GETINFO circuit-status\r\n");

        var buf: [16384]u8 = undefined;
        var bytes_in_buf: usize = 0;
        var ids_to_close = [_]u32{0} ** 16;
        var found_count: usize = 0;

        // --- Phase 1: 抽出 (Streaming Parse) ---
        // GETINFO のマルチライン応答を最後まで確実に消費し、対象IDを特定する
        outer: while (true) {
            const n = try posix.read(stream.handle, buf[bytes_in_buf..]);
            if (n == 0) return error.ControlPortDisconnected;
            bytes_in_buf += n;

            var start_of_line: usize = 0;
            var i: usize = 0;
            while (i < bytes_in_buf) : (i += 1) {
                if (buf[i] == '\n') {
                    const line = buf[start_of_line..i];
                    const trimmed = mem.trim(u8, line, "\r ");

                    // 終了判定: ドット1つの行の後に 250 OK が来る
                    if (mem.startsWith(u8, trimmed, "250 OK")) break :outer;
                    if (mem.eql(u8, trimmed, ".")) {
                        // ドット行単体なら次の 250 OK を待つために継続
                    } else if (found_count < 16 and mem.indexOf(u8, line, socks_user) != null) {
                        var tokens = mem.tokenizeAny(u8, line, " ");
                        if (tokens.next()) |id_str| {
                            if (std.fmt.parseInt(u32, id_str, 10)) |id| {
                                ids_to_close[found_count] = id;
                                found_count += 1;
                            } else |_| {}
                        }
                    }
                    start_of_line = i + 1;
                }
            }
            if (start_of_line > 0) {
                mem.copyForwards(u8, buf[0 .. bytes_in_buf - start_of_line], buf[start_of_line..bytes_in_buf]);
                bytes_in_buf -= start_of_line;
            }
        }

        // --- Phase 2: 執行 (Logic 4: コマンドごとに 250 OK を待機) ---
        if (found_count > 0) {
            for (ids_to_close[0..found_count]) |id| {
                var cmd_buf: [64]u8 = undefined;
                const cmd = try std.fmt.bufPrint(&cmd_buf, "CLOSECIRCUIT {d}\r\n", .{id});
                try self.posixWriteAll(stream.handle, cmd);

                // 各パージコマンドが受理されるのを確実に待つ (同期のズレを防止)
                const rn = try posix.read(stream.handle, &buf);
                if (rn == 0) return error.ControlPortDisconnected;
                // 正常ならここで "250 OK\r\n" が読み込まれる
            }
        }
    }

    pub fn waitForControlPort(self: *TorSource) void {
        std.debug.print("⏳ Waiting for Tor ControlPort ({s}:{d})...\n", .{ self.config.control_ip, self.config.control_port });
        while (true) {
            _ = self.getControlStream(false) catch {
                std.Thread.sleep(1 * std.time.ns_per_s);
                continue;
            };
            break;
        }
        std.debug.print("✅ Tor ControlPort Session Established (Persistent).\n", .{});
    }

    pub fn collectLiveIps(self: *TorSource, aa: mem.Allocator, map: *std.StringHashMap(void), should_log: bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const stream = try self.getControlStream(should_log);

        self.fetchAllLiveNodes(aa, stream, map, should_log) catch |err| {
            if (self.debug and should_log) std.debug.print("⚠️ ControlPort communication error: {any}\n", .{err});
            stream.close();
            self.control_stream = null;
            return err;
        };
    }

    fn getTorCookieHex(self: *TorSource, allocator: mem.Allocator) ![]u8 {
        const file = fs.openFileAbsolute(self.config.cookie_path, .{}) catch |err| {
            if (self.debug) std.debug.print("⚠️ Cookie file ({s}) access error: {any}\n", .{ self.config.cookie_path, err });
            return err;
        };
        defer file.close();
        var cookie_bin: [32]u8 = undefined;
        _ = try file.readAll(&cookie_bin);
        const hex_arr = std.fmt.bytesToHex(cookie_bin, .lower);
        return try allocator.dupe(u8, &hex_arr);
    }

    pub fn extractDAFromBinary(self: *TorSource, allocator: mem.Allocator, map: *std.StringHashMap(void)) !void {
        const file = fs.openFileAbsolute(self.config.binary_path, .{}) catch return;
        defer file.close();
        var segment = std.ArrayListUnmanaged(u8){};
        defer segment.deinit(allocator);
        var file_buf: [8192]u8 = undefined;
        var found_count: usize = 0;

        while (true) {
            const bytes_read = try file.read(&file_buf);
            if (bytes_read == 0) break;
            var cursor: usize = 0;
            while (cursor < bytes_read) {
                if (std.ascii.isPrint(file_buf[cursor])) {
                    const start = cursor;
                    while (cursor < bytes_read and std.ascii.isPrint(file_buf[cursor])) : (cursor += 1) {}
                    try segment.appendSlice(allocator, file_buf[start..cursor]);
                } else {
                    if (segment.items.len >= 4) {
                        if (mem.indexOf(u8, segment.items, "orport=") != null) {
                            var tokens = mem.tokenizeAny(u8, segment.items, " ");
                            while (tokens.next()) |token| {
                                // ポート番号付きのIP (例: 1.2.3.4:9001 または [2001:db8::1]:9001)
                                if (mem.lastIndexOfScalar(u8, token, ':')) |last_colon| {
                                    var ip = token[0..last_colon];
                                    // IPv6が [] で囲まれている場合は除去
                                    if (ip.len > 0 and ip[0] == '[') {
                                        if (mem.indexOfScalar(u8, ip, ']')) |end_bracket| {
                                            ip = ip[1..end_bracket];
                                        }
                                    }
                                    if (self.isValidIp(ip)) {
                                        try map.put(try allocator.dupe(u8, ip), {});
                                        found_count += 1;
                                    }
                                }
                            }
                        }
                    }
                    segment.clearRetainingCapacity();
                    cursor += 1;
                }
            }
        }
        if (self.debug) std.debug.print("🔎 [Debug] Binary scan: Found {d} DA/Hardcoded nodes.\n", .{found_count});
    }

    pub fn extractGuardsFromPrivilegedFiles(self: *TorSource, allocator: mem.Allocator, map: *std.StringHashMap(void)) !void {
        var target_guards = std.ArrayListUnmanaged([28]u8){};
        defer target_guards.deinit(allocator);
        var found_count: usize = 0;

        const files = [_][]const u8{ self.config.state_path, self.config.consensus_path };
        for (files, 0..) |path, i| {
            const file = fs.openFileAbsolute(path, .{}) catch continue;
            defer file.close();
            var line_buf = std.ArrayListUnmanaged(u8){};
            defer line_buf.deinit(allocator);
            var file_buf: [8192]u8 = undefined;

            while (true) {
                const n = try file.read(&file_buf);
                if (n == 0) break;
                var cursor: usize = 0;
                while (cursor < n) {
                    if (mem.indexOfScalarPos(u8, file_buf[0..n], cursor, '\n')) |next_nl| {
                        try line_buf.appendSlice(allocator, file_buf[cursor..next_nl]);
                        const line = line_buf.items;
                        if (i == 0) {
                            if (mem.startsWith(u8, line, "Guard ")) {
                                if (mem.indexOf(u8, line, "rsa_id=")) |p| {
                                    var bin_id: [20]u8 = undefined;
                                    _ = std.fmt.hexToBytes(&bin_id, line[p + 7 .. p + 47]) catch continue;
                                    var b64: [28]u8 = undefined;
                                    _ = std.base64.standard_no_pad.Encoder.encode(&b64, &bin_id);
                                    try target_guards.append(allocator, b64);
                                }
                            }
                        } else {
                            if (mem.startsWith(u8, line, "r ")) {
                                var t = mem.tokenizeAny(u8, line, " ");
                                _ = t.next();
                                _ = t.next();
                                if (t.next()) |id| {
                                    for (target_guards.items) |tg| {
                                        if (mem.eql(u8, id, &tg)) {
                                            while (t.next()) |token| {
                                                if (self.isValidIp(token)) {
                                                    try map.put(try allocator.dupe(u8, token), {});
                                                    found_count += 1;
                                                }
                                            }
                                            break;
                                        }
                                    }
                                }
                            }
                        }
                        line_buf.clearRetainingCapacity();
                        cursor = next_nl + 1;
                    } else {
                        try line_buf.appendSlice(allocator, file_buf[cursor..n]);
                        break;
                    }
                }
            }
        }
        if (self.debug) std.debug.print("🔎 [Debug] File scan: Resolved {d} Guard nodes from consensus.\n", .{found_count});
    }

    fn fetchAllLiveNodes(self: *TorSource, aa: mem.Allocator, stream: net.Stream, map: *std.StringHashMap(void), should_log: bool) !void {
        var line_buf = std.ArrayListUnmanaged(u8){};
        defer line_buf.deinit(aa);
        var sock_buf: [8192]u8 = undefined;
        var buf_pos: usize = 0;
        var buf_len: usize = 0;

        const readLine = struct {
            fn read(s: posix.fd_t, b: []u8, pos: *usize, len: *usize, out: *std.ArrayListUnmanaged(u8), alloc: mem.Allocator) !?[]const u8 {
                out.clearRetainingCapacity();
                while (true) {
                    if (pos.* >= len.*) {
                        len.* = try posix.read(s, b);
                        if (len.* == 0) return if (out.items.len > 0) out.items else null;
                        pos.* = 0;
                    }
                    const start = pos.*;
                    if (mem.indexOfScalarPos(u8, b[0..len.*], start, '\n')) |found| {
                        try out.appendSlice(alloc, b[start..found]);
                        pos.* = found + 1;
                        return mem.trimRight(u8, out.items, "\r");
                    } else {
                        try out.appendSlice(alloc, b[start..len.*]);
                        pos.* = len.*;
                    }
                }
            }
        }.read;

        try self.posixWriteAll(stream.handle, "GETINFO entry-guards\r\n");
        var fps = std.ArrayListUnmanaged([]const u8){};
        defer fps.deinit(aa);

        while (try readLine(stream.handle, &sock_buf, &buf_pos, &buf_len, &line_buf, aa)) |line| {
            if (mem.startsWith(u8, line, "250 OK")) break;
            if (mem.indexOf(u8, line, " up") != null) {
                if (mem.indexOf(u8, line, "$")) |start| {
                    if (mem.indexOf(u8, line, "~")) |end| try fps.append(aa, try aa.dupe(u8, line[start + 1 .. end]));
                }
            }
        }

        if (fps.items.len == 0) return;

        try self.posixWriteAll(stream.handle, "GETINFO ns/all ");
        for (fps.items) |fp| {
            try self.posixWriteAll(stream.handle, "ns/id/");
            try self.posixWriteAll(stream.handle, fp);
            try self.posixWriteAll(stream.handle, " ");
        }
        try self.posixWriteAll(stream.handle, "\r\n");

        var mode: enum { NONE, DA, GUARD } = .NONE;
        var last_r_ip: ?[]const u8 = null;
        var live_count: usize = 0;

        while (try readLine(stream.handle, &sock_buf, &buf_pos, &buf_len, &line_buf, aa)) |line| {
            if (mem.startsWith(u8, line, "250 OK")) break;
            if (mem.startsWith(u8, line, "250+ns/all=")) {
                mode = .DA;
            } else if (mem.startsWith(u8, line, "250+ns/id/")) {
                mode = .GUARD;
            } else if (mem.startsWith(u8, line, "r ")) {
                last_r_ip = null;
                var t = mem.tokenizeAny(u8, line, " ");
                _ = t.next();
                _ = t.next();
                if (t.next()) |_| {
                    while (t.next()) |token| {
                        if (self.isValidIp(token)) {
                            last_r_ip = try aa.dupe(u8, token);
                            if (mode == .GUARD) {
                                try map.put(last_r_ip.?, {});
                                live_count += 1;
                            }
                            break;
                        }
                    }
                }
            } else if (mode == .DA and mem.startsWith(u8, line, "s ") and mem.indexOf(u8, line, " Authority ") != null) {
                if (last_r_ip) |ip| {
                    try map.put(ip, {});
                    live_count += 1;
                }
            }
        }
        if (should_log and self.debug and live_count > 0) {
            std.debug.print("📡 [Debug] ControlPort: Fetched {d} live nodes.\n", .{live_count});
        }
    }

    fn isValidIp(self: *TorSource, text: []const u8) bool {
        _ = self;
        // IPv4 としてパースできるか試す
        if (net.Address.parseIp4(text, 0)) |_| return true else |_| {}
        // IPv6 としてパースできるか試す (追加)
        if (net.Address.parseIp6(text, 0)) |_| return true else |_| {}
        return false;
    }

    fn posixWriteAll(self: *TorSource, fd: posix.fd_t, data: []const u8) !void {
        _ = self;
        var written: usize = 0;
        while (written < data.len) {
            const n = try posix.write(fd, data[written..]);
            if (n == 0) break;
            written += n;
        }
    }

    /// 外部通信なしで出口ノードのIP、名前、国名を取得する (Logic 4: 同期保護版)
    pub fn fetchTorIdentityMap(self: *TorSource, aa: mem.Allocator) !std.StringHashMap([]const u8) {
        self.mutex.lock();
        defer self.mutex.unlock();

        const stream = try self.getControlStream(false);
        var map = std.StringHashMap([]const u8).init(aa);

        try self.posixWriteAll(stream.handle, "GETINFO circuit-status\r\n");

        var buf: [16384]u8 = undefined;
        var bytes_in_buf: usize = 0;
        var user_to_fp = std.StringHashMap([]const u8).init(aa);

        // --- Phase 1: 回路情報の取得 ---
        outer: while (true) {
            const n = try posix.read(stream.handle, buf[bytes_in_buf..]);
            if (n == 0) return error.ControlPortDisconnected;
            bytes_in_buf += n;

            var start_of_line: usize = 0;
            var i: usize = 0;
            while (i < bytes_in_buf) : (i += 1) {
                if (buf[i] == '\n') {
                    const line = buf[start_of_line..i];
                    const trimmed = mem.trim(u8, line, "\r ");
                    if (mem.startsWith(u8, trimmed, "250 OK")) break :outer;

                    if (mem.indexOf(u8, line, " BUILT ")) |_| {
                        if (mem.indexOf(u8, line, "SOCKS_USERNAME=\"")) |u_idx| {
                            const u_part = line[u_idx + 16 ..];
                            if (mem.indexOfScalar(u8, u_part, '"')) |u_end| {
                                const user = u_part[0..u_end];
                                var tokens = mem.tokenizeAny(u8, line, " ");
                                _ = tokens.next(); // ID
                                _ = tokens.next(); // BUILT
                                if (tokens.next()) |path| {
                                    var path_it = mem.splitBackwardsScalar(u8, path, ',');
                                    if (path_it.next()) |last_node| {
                                        if (mem.indexOfScalar(u8, last_node, '$')) |fp_pos| {
                                            const fp_raw = last_node[fp_pos + 1 ..];
                                            const fp_end = mem.indexOfAny(u8, fp_raw, "~=") orelse fp_raw.len;
                                            try user_to_fp.put(try aa.dupe(u8, user), try aa.dupe(u8, fp_raw[0..fp_end]));
                                        }
                                    }
                                }
                            }
                        }
                    }
                    start_of_line = i + 1;
                }
            }
            if (start_of_line > 0) {
                mem.copyForwards(u8, buf[0 .. bytes_in_buf - start_of_line], buf[start_of_line..bytes_in_buf]);
                bytes_in_buf -= start_of_line;
            }
        }

        // --- Phase 2: 出口詳細情報の同期取得 ---
        var it = user_to_fp.iterator();
        while (it.next()) |entry| {
            const user = entry.key_ptr.*;
            const fp = entry.value_ptr.*;

            var cmd_buf: [128]u8 = undefined;
            const cmd_ns = try std.fmt.bufPrint(&cmd_buf, "GETINFO ns/id/{s}\r\n", .{fp});
            try self.posixWriteAll(stream.handle, cmd_ns);

            var node_ip: ?[]const u8 = null;
            var node_nick: []const u8 = "unknown";

            // 🚀 Logic 4: 各 GETINFO ごとに応答を完全に読み切る
            var info_bytes: usize = 0;
            while (true) {
                const n = try posix.read(stream.handle, buf[info_bytes..]);
                if (n == 0) break;
                info_bytes += n;
                if (mem.indexOf(u8, buf[0..info_bytes], "250 OK\r\n") != null) break;
            }

            var info_lines = mem.tokenizeAny(u8, buf[0..info_bytes], "\r\n");
            while (info_lines.next()) |i_line| {
                if (mem.startsWith(u8, i_line, "r ")) {
                    var r_parts = mem.tokenizeAny(u8, i_line, " ");
                    _ = r_parts.next();
                    node_nick = r_parts.next() orelse "unknown";
                    var count: usize = 0;
                    while (r_parts.next()) |part| : (count += 1) {
                        if (count == 4) {
                            node_ip = try aa.dupe(u8, part);
                            break;
                        }
                    }
                }
            }

            if (node_ip) |ip| {
                const cmd_cc = try std.fmt.bufPrint(&cmd_buf, "GETINFO ip-to-country/{s}\r\n", .{ip});
                try self.posixWriteAll(stream.handle, cmd_cc);
                const cn = try posix.read(stream.handle, &buf);
                var country: []const u8 = "??";
                if (mem.indexOfScalar(u8, buf[0..cn], '=')) |eq_pos| {
                    const tail = buf[eq_pos + 1 .. cn];
                    country = mem.trim(u8, tail, "\r\n 250 OK.");
                }
                const identity = try std.fmt.allocPrint(aa, "{s} ({s}) [{s}]", .{ ip, node_nick, country });
                try map.put(user, identity);
            }
        }
        return map;
    }
};
