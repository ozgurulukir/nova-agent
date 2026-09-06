//! OpenAI Codex OAuth flow and static model catalog.
//!
//! Generic provider API key storage lives in `auth.zig` — all providers
//! (builtin, dynamic, config) use that module. This file only handles the
//! OpenAI-specific OAuth PKCE flow and the hardcoded Codex model list.

const std = @import("std");
const log = std.log.scoped(.auth);

const os = @import("../os.zig");
const http = @import("../http.zig");
const symbols = @import("../symbols.zig");
const auth = @import("store.zig");

// Re-export so existing `codex.Credentials` / `codex.ApiKeyMap` callers
// keep compiling during the migration window.
pub const Credentials = auth.Credentials;
pub const ApiKeyMap = auth.ApiKeyMap;
pub const freeApiKeyMap = auth.freeApiKeyMap;
pub const loadAllProviderApiKeys = auth.loadAllProviderApiKeys;
pub const loadProviderApiKey = auth.loadProviderApiKey;
pub const saveProviderApiKey = auth.saveProviderApiKey;
pub const removeProviderApiKey = auth.removeProviderApiKey;
pub const pruneOrphanKeys = auth.pruneOrphanKeys;

const auth_port: u16 = 1455;
const auth_host = "127.0.0.1";
const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
const authorize_url = "https://auth.openai.com/oauth/authorize";
const token_url = "https://auth.openai.com/oauth/token";
/// The redirect URI is registered with the OAuth app — its host is
/// deliberately `localhost` (not the `auth_host` the listener binds) and its
/// port must stay in lockstep with `auth_port`, hence the composition.
const redirect_uri = std.fmt.comptimePrint("http://localhost:{d}/auth/callback", .{auth_port});
const scope = "openid profile email offline_access";
const jwt_claim_path = "https://api.openai.com/auth";

// ---------------------------------------------------------------------------
// Static Model Catalog
// ---------------------------------------------------------------------------

pub const Model = struct {
    id: []u8,
    label: []u8,

    pub fn deinit(self: *Model, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        gpa.free(self.label);
        self.* = undefined;
    }
};

const StaticModel = struct { id: []const u8, label: []const u8 };

/// ChatGPT-account Codex models selectable today (verified 2026-08-25,
/// openai.com GPT-5.6 price-performance announcement + learn.chatgpt.com
/// /docs/models):
/// Plus/Pro/Business/Enterprise choose Sol, Terra, Luna. Everything older is
/// deprecated or retired for ChatGPT sign-in — gpt-5.2/gpt-5.3-codex reject
/// with HTTP 400 ("model is not supported when using Codex with a ChatGPT
/// account"), gpt-5.4/gpt-5.4-mini retire 2026-08-31, gpt-5.3-codex-spark
/// never left the Pro research preview. API-key workflows can still reach
/// other models via their own provider entries.
const static_models = [_]StaticModel{
    .{ .id = "gpt-5.6-sol", .label = "OpenAI Codex" ++ symbols.separator_dot_padded ++ "GPT-5.6 Sol" },
    .{ .id = "gpt-5.6-terra", .label = "OpenAI Codex" ++ symbols.separator_dot_padded ++ "GPT-5.6 Terra" },
    .{ .id = "gpt-5.6-luna", .label = "OpenAI Codex" ++ symbols.separator_dot_padded ++ "GPT-5.6 Luna" },
};

pub fn loadStaticModels(gpa: std.mem.Allocator) ![]Model {
    const out = try gpa.alloc(Model, static_models.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |*model| model.deinit(gpa);
        gpa.free(out);
    }
    for (static_models) |model| {
        const id = try gpa.dupe(u8, model.id);
        errdefer gpa.free(id);
        const label = try gpa.dupe(u8, model.label);
        out[initialized] = .{
            .id = id,
            .label = label,
        };
        initialized += 1;
    }
    return out;
}

// ---------------------------------------------------------------------------
// OAuth Flow
// ---------------------------------------------------------------------------

const AuthorizationFlow = struct {
    verifier: []u8,
    state: []u8,
    url: []u8,

    fn deinit(self: *AuthorizationFlow, gpa: std.mem.Allocator) void {
        gpa.free(self.verifier);
        gpa.free(self.state);
        gpa.free(self.url);
        self.* = undefined;
    }
};

pub fn login(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) !Credentials {
    return loginWith(gpa, io, home_dir, .{});
}

const LoginOptions = struct {
    /// The test seam exists to keep `xdg-open` out of the suite: spawning a
    /// real browser from a unit test is a user-visible side effect, and its
    /// variable latency was what starved the mock callback client's connect
    /// retries (see `MockCallbackClient`).
    open_browser: bool = true,
    callback_timeout_ms: u64 = callback_wait_timeout_ms,
};

fn loginWith(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, opts: LoginOptions) !Credentials {
    var flow = try createAuthorizationFlow(gpa, io);
    defer flow.deinit(gpa);
    if (opts.open_browser) try openBrowser(gpa, io, flow.url);
    const code = try waitForAuthorizationCode(gpa, io, auth_port, opts.callback_timeout_ms, flow.state);
    defer gpa.free(code);
    var credentials = try exchangeAuthorizationCode(gpa, io, code, flow.verifier);
    errdefer credentials.deinit(gpa);
    try auth.saveCredentials(gpa, io, home_dir, credentials);
    return credentials;
}

pub fn load(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) !?Credentials {
    return auth.loadCredentials(gpa, io, home_dir);
}

pub fn refresh(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, refresh_token: []const u8) !Credentials {
    var credentials = try refreshAccessToken(gpa, io, refresh_token);
    errdefer credentials.deinit(gpa);
    try auth.saveCredentials(gpa, io, home_dir, credentials);
    return credentials;
}

pub fn signOut(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) !void {
    try auth.removeCredentials(gpa, io, home_dir);
}

// ---------------------------------------------------------------------------
// OAuth Internals
// ---------------------------------------------------------------------------

fn createAuthorizationFlow(gpa: std.mem.Allocator, io: std.Io) !AuthorizationFlow {
    var random: [32]u8 = undefined;
    io.random(&random);
    const verifier = try base64Url(gpa, &random);
    errdefer gpa.free(verifier);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    const challenge = try base64Url(gpa, &digest);
    defer gpa.free(challenge);

    var state_bytes: [16]u8 = undefined;
    io.random(&state_bytes);
    const state = try hexLower(gpa, &state_bytes);
    errdefer gpa.free(state);

    var url: std.Io.Writer.Allocating = .init(gpa);
    errdefer url.deinit();
    try url.writer.writeAll(authorize_url ++ "?response_type=code&client_id=");
    try writeUrlEncoded(&url.writer, client_id);
    try url.writer.writeAll("&redirect_uri=");
    try writeUrlEncoded(&url.writer, redirect_uri);
    try url.writer.writeAll("&scope=");
    try writeUrlEncoded(&url.writer, scope);
    try url.writer.writeAll("&code_challenge=");
    try writeUrlEncoded(&url.writer, challenge);
    try url.writer.writeAll("&code_challenge_method=S256&state=");
    try writeUrlEncoded(&url.writer, state);
    try url.writer.writeAll("&id_token_add_organizations=true&codex_cli_simplified_flow=true&originator=nova");

    return .{ .verifier = verifier, .state = state, .url = try url.toOwnedSlice() };
}

fn openBrowser(gpa: std.mem.Allocator, io: std.Io, url: []const u8) !void {
    const argv = switch (os.tag) {
        .macos => &[_][]const u8{ "open", url },
        .windows => &[_][]const u8{ "cmd", "/c", "start", "", url },
        else => &[_][]const u8{ "xdg-open", url },
    };
    const result = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(4 * 1024),
        .stderr_limit = .limited(4 * 1024),
    }) catch return;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
}

/// Upper bound on how long `waitForAuthorizationCode` blocks waiting for the
/// browser callback before it gives up. The login flow can simply be retried.
const callback_wait_timeout_ms: u64 = 120_000;

/// Cancellation signal shared with the watchdog thread. `fired` is set when
/// the real callback arrives or on any exit path, so the watchdog never pokes
/// a listener that is already gone. On expiry it completes one throwaway
/// loopback connection so the main thread's blocking `accept` returns.
const AcceptWatchdog = struct {
    fired: std.atomic.Value(bool),
    port: u16,

    fn arm(port: u16) AcceptWatchdog {
        return .{ .fired = .init(false), .port = port };
    }

    /// Runs on the watchdog thread: sleep until the deadline, then force the
    /// main thread's `accept` to unblock with a loopback connection. Bounded:
    /// one poke, then done.
    fn watch(self: *AcceptWatchdog, io: std.Io, timeout_ms: u64) void {
        var waited_ms: u64 = 0;
        while (waited_ms < timeout_ms) : (waited_ms += 100) {
            if (self.fired.load(.acquire)) return;
            io.sleep(.fromMilliseconds(100), .awake) catch {};
        }
        if (self.fired.load(.acquire)) return;
        var address = std.Io.net.IpAddress.parseIp4(auth_host, self.port) catch return;
        if (address.connect(io, .{ .mode = .stream })) |stream| {
            var local_stream = stream;
            defer local_stream.close(io);
        } else |_| {}
    }
};

fn waitForAuthorizationCode(gpa: std.mem.Allocator, io: std.Io, port: u16, timeout_ms: u64, state: []const u8) ![]u8 {
    var address = try std.Io.net.IpAddress.parseIp4(auth_host, port);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    // A hung browser hand-off must not hang the whole process forever: a
    // watchdog thread bounds the wait and forces `accept` to return when the
    // deadline passes (the throwaway connection yields an empty request,
    // surfaced as error.Timeout below).
    var watchdog = AcceptWatchdog.arm(port);
    var watchdog_thread = try std.Thread.spawn(.{}, AcceptWatchdog.watch, .{ &watchdog, io, timeout_ms });
    defer {
        watchdog.fired.store(true, .release);
        watchdog_thread.join();
    }

    // The watchdog poke completes as an ordinary loopback connection whose
    // client immediately hangs up; the empty request below surfaces the
    // deadline as error.Timeout.
    const stream = try server.accept(io);
    defer stream.close(io);

    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [8192]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    var http_server = std.http.Server.init(&reader.interface, &writer.interface);
    var request = http_server.receiveHead() catch |err| switch (err) {
        // Watchdog poke: the loopback client hung up without sending anything.
        error.HttpConnectionClosing => return error.Timeout,
        else => return err,
    };
    const code = parseCallbackTarget(gpa, request.head.target, state) catch |err| {
        try request.respond("OpenAI authentication failed.", .{ .status = .bad_request });
        return err;
    };
    errdefer gpa.free(code);
    try request.respond("OpenAI authentication completed. You can close this window.", .{});
    return code;
}

fn parseCallbackTarget(gpa: std.mem.Allocator, target: []const u8, expected_state: []const u8) ![]u8 {
    const question = std.mem.findScalar(u8, target, '?') orelse return error.InvalidCallback;
    if (!std.mem.eql(u8, target[0..question], "/auth/callback")) return error.InvalidCallback;
    const query = target[question + 1 ..];
    const code = queryValue(query, "code") orelse return error.InvalidCallback;
    const state = queryValue(query, "state") orelse return error.InvalidCallback;
    if (!std.mem.eql(u8, state, expected_state)) return error.StateMismatch;
    return try percentDecode(gpa, code);
}

fn exchangeAuthorizationCode(gpa: std.mem.Allocator, io: std.Io, code: []const u8, verifier: []const u8) !Credentials {
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try body.writer.writeAll("grant_type=authorization_code&client_id=");
    try writeUrlEncoded(&body.writer, client_id);
    try body.writer.writeAll("&code=");
    try writeUrlEncoded(&body.writer, code);
    try body.writer.writeAll("&code_verifier=");
    try writeUrlEncoded(&body.writer, verifier);
    try body.writer.writeAll("&redirect_uri=");
    try writeUrlEncoded(&body.writer, redirect_uri);
    return try tokenRequest(gpa, io, body.written());
}

fn refreshAccessToken(gpa: std.mem.Allocator, io: std.Io, refresh_token: []const u8) !Credentials {
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try body.writer.writeAll("grant_type=refresh_token&refresh_token=");
    try writeUrlEncoded(&body.writer, refresh_token);
    try body.writer.writeAll("&client_id=");
    try writeUrlEncoded(&body.writer, client_id);
    return try tokenRequest(gpa, io, body.written());
}

fn tokenRequest(gpa: std.mem.Allocator, io: std.Io, body: []const u8) !Credentials {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    log.info("codex.token.request POST {s}", .{token_url});
    var req = try client.request(.POST, try std.Uri.parse(token_url), .{ .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } } });
    defer req.deinit();
    req.transfer_encoding = .{ .content_length = body.len };
    var buffer: [http.body_buffer_bytes]u8 = undefined;
    var body_writer = try req.sendBodyUnflushed(&buffer);
    try body_writer.writer.writeAll(body);
    try body_writer.end();
    try req.connection.?.flush();
    var redirect_buffer: [http.redirect_buffer_bytes]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    const status: u16 = @intFromEnum(response.head.status);
    const bytes = try readResponseBody(gpa, &response);
    defer gpa.free(bytes);
    log.info("codex.token.response status={d}", .{status});
    if (!http.isSuccess(status)) return error.TokenRequestFailed;
    return try parseTokenResponse(gpa, io, bytes);
}

/// Token responses are larger than the shared 4 KB transfer buffer used by
/// the AI clients, so this deliberately keeps its own 8 KB size instead of
/// aliasing `http.transfer_buffer_bytes`.
const token_transfer_buffer_bytes: usize = 8192;

fn readResponseBody(gpa: std.mem.Allocator, response: *std.http.Client.Response) ![]u8 {
    var empty_decompress_buffer: [0]u8 = .{};
    var decompress_buffer: []u8 = &empty_decompress_buffer;
    var decompress_buffer_owned = false;
    switch (response.head.content_encoding) {
        .identity => {},
        .zstd => {
            decompress_buffer = try gpa.alloc(u8, std.compress.zstd.default_window_len);
            decompress_buffer_owned = true;
        },
        .deflate, .gzip => {
            decompress_buffer = try gpa.alloc(u8, std.compress.flate.max_window_len);
            decompress_buffer_owned = true;
        },
        .compress => return error.UnsupportedCompressionMethod,
    }
    defer if (decompress_buffer_owned) gpa.free(decompress_buffer);
    var transfer_buffer: [token_transfer_buffer_bytes]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    _ = try reader.streamRemaining(&out.writer);
    return try out.toOwnedSlice();
}

const TokenResponse = struct {
    access_token: []const u8,
    refresh_token: []const u8,
    expires_in: i64,
};

fn parseTokenResponse(gpa: std.mem.Allocator, io: std.Io, bytes: []const u8) !Credentials {
    const parsed = std.json.parseFromSlice(TokenResponse, gpa, bytes, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCredentials,
    };
    defer parsed.deinit();
    if (parsed.value.access_token.len == 0 or parsed.value.refresh_token.len == 0 or parsed.value.expires_in < 0) {
        return error.InvalidCredentials;
    }

    const expires_ms = std.math.mul(i64, parsed.value.expires_in, 1000) catch return error.InvalidCredentials;
    const expires = std.math.add(i64, nowMs(io), expires_ms) catch return error.InvalidCredentials;
    const account_id = try accountIdFromAccessToken(gpa, parsed.value.access_token);
    errdefer gpa.free(account_id);
    const access = try gpa.dupe(u8, parsed.value.access_token);
    errdefer gpa.free(access);
    const refresh_token_copy = try gpa.dupe(u8, parsed.value.refresh_token);
    errdefer gpa.free(refresh_token_copy);
    return .{
        .access = access,
        .refresh = refresh_token_copy,
        .account_id = account_id,
        .expires = expires,
    };
}

const AccessTokenClaims = struct {
    @"https://api.openai.com/auth": AccountClaim,
};

const AccountClaim = struct {
    chatgpt_account_id: []const u8,
};

fn accountIdFromAccessToken(gpa: std.mem.Allocator, access: []const u8) ![]u8 {
    var parts = std.mem.splitScalar(u8, access, '.');
    _ = parts.next() orelse return error.InvalidCredentials;
    const payload = parts.next() orelse return error.InvalidCredentials;
    _ = parts.next() orelse return error.InvalidCredentials;
    if (parts.next() != null or payload.len == 0) return error.InvalidCredentials;

    const size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload) catch return error.InvalidCredentials;
    const decoded = try gpa.alloc(u8, size);
    defer gpa.free(decoded);
    std.base64.url_safe_no_pad.Decoder.decode(decoded, payload) catch return error.InvalidCredentials;
    const parsed = std.json.parseFromSlice(AccessTokenClaims, gpa, decoded, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCredentials,
    };
    defer parsed.deinit();
    const account_id = @field(parsed.value, jwt_claim_path).chatgpt_account_id;
    if (account_id.len == 0) return error.InvalidCredentials;
    return try gpa.dupe(u8, account_id);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.now(.real, io).toMilliseconds();
}

fn queryValue(query: []const u8, name: []const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, query, '&');
    while (parts.next()) |part| {
        const equals = std.mem.findScalar(u8, part, '=') orelse continue;
        if (std.mem.eql(u8, part[0..equals], name)) return part[equals + 1 ..];
    }
    return null;
}

fn base64Url(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(bytes.len));
    _ = std.base64.url_safe_no_pad.Encoder.encode(out, bytes);
    return out;
}

fn hexLower(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const digits = "0123456789abcdef";
    const out = try gpa.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        out[index * 2] = digits[byte >> 4];
        out[index * 2 + 1] = digits[byte & 15];
    }
    return out;
}

fn writeUrlEncoded(writer: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try writer.writeByte(byte);
        } else if (byte == ' ') {
            try writer.writeByte('+');
        } else {
            try writer.writeByte('%');
            try writer.writeByte(hex[byte >> 4]);
            try writer.writeByte(hex[byte & 15]);
        }
    }
}

fn percentDecode(gpa: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var index: usize = 0;
    while (index < value.len) {
        if (value[index] == '+') {
            try out.writer.writeByte(' ');
            index += 1;
        } else if (value[index] == '%') {
            if (index + 2 >= value.len) return error.InvalidPercentEncoding;
            const hi = try std.fmt.charToDigit(value[index + 1], 16);
            const lo = try std.fmt.charToDigit(value[index + 2], 16);
            try out.writer.writeByte((hi << 4) | lo);
            index += 3;
        } else {
            try out.writer.writeByte(value[index]);
            index += 1;
        }
    }
    return try out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "pkce helpers use base64url without padding" {
    const gpa = std.testing.allocator;
    const encoded = try base64Url(gpa, "abc");
    defer gpa.free(encoded);
    try std.testing.expectEqualStrings("YWJj", encoded);
}

test "callback parser validates state and decodes code" {
    const gpa = std.testing.allocator;
    const code = try parseCallbackTarget(gpa, "/auth/callback?code=a%2Fb%3D&state=ok", "ok");
    defer gpa.free(code);
    try std.testing.expectEqualStrings("a/b=", code);
    try std.testing.expectError(error.StateMismatch, parseCallbackTarget(gpa, "/auth/callback?code=a&state=bad", "ok"));
}

test "invalid token json maps to domain error" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidCredentials, parseTokenResponse(gpa, std.testing.io, "not json"));
}

test "parseTokenResponse rejects empty tokens or negative expires_in" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidCredentials, parseTokenResponse(gpa, std.testing.io, "{\"access_token\":\"\",\"refresh_token\":\"r\",\"expires_in\":3600}"));
    try std.testing.expectError(error.InvalidCredentials, parseTokenResponse(gpa, std.testing.io, "{\"access_token\":\"a\",\"refresh_token\":\"\",\"expires_in\":3600}"));
    try std.testing.expectError(error.InvalidCredentials, parseTokenResponse(gpa, std.testing.io, "{\"access_token\":\"a\",\"refresh_token\":\"r\",\"expires_in\":-1}"));
}

test "static models match openai codex catalog" {
    const gpa = std.testing.allocator;
    const loaded = try loadStaticModels(gpa);
    defer {
        for (loaded) |*model| model.deinit(gpa);
        gpa.free(loaded);
    }
    try std.testing.expectEqual(@as(usize, 3), loaded.len);
    try std.testing.expectEqualStrings("gpt-5.6-sol", loaded[0].id);
    try std.testing.expectEqualStrings("OpenAI Codex" ++ symbols.separator_dot_padded ++ "GPT-5.6 Sol", loaded[0].label);
    try std.testing.expectEqualStrings("gpt-5.6-terra", loaded[1].id);
    try std.testing.expectEqualStrings("OpenAI Codex" ++ symbols.separator_dot_padded ++ "GPT-5.6 Terra", loaded[1].label);
    try std.testing.expectEqualStrings("gpt-5.6-luna", loaded[2].id);
    try std.testing.expectEqualStrings("OpenAI Codex" ++ symbols.separator_dot_padded ++ "GPT-5.6 Luna", loaded[2].label);
}

test "loadStaticModels handles allocation failures gracefully" {
    const gpa = std.testing.allocator;
    var succeeded = false;
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = i });
        if (loadStaticModels(failing.allocator())) |models| {
            for (models) |*model| model.deinit(failing.allocator());
            failing.allocator().free(models);
            succeeded = true;
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
    try std.testing.expect(succeeded);
}

test "sign out removes missing auth file without error" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const home_dir = "/tmp/nova-missing-home-for-signout-test";

    const auth_file = try std.fs.path.join(gpa, &.{ home_dir, ".config", "nova", "auth.json" });
    defer gpa.free(auth_file);

    // Precondition: ensure the auth file is absent (idempotent cleanup of any
    // leftover from a previous run). This and the post-condition below use the
    // Io fs API, matching the rest of this module — `std.fs.cwd()` is gone in
    // Zig 0.16.
    if (std.Io.Dir.openFile(.cwd(), io, auth_file, .{})) |file| {
        file.close(io);
        std.Io.Dir.deleteFile(.cwd(), io, auth_file) catch {};
    } else |err| try std.testing.expectEqual(error.FileNotFound, err);

    // The actual exercise: signOut on a missing file must not error.
    try signOut(gpa, io, home_dir);

    // Post-condition: still absent. signOut went through the whole code path,
    // so reaching here without the file being created is the meaningful check.
    if (std.Io.Dir.openFile(.cwd(), io, auth_file, .{})) |file| {
        file.close(io);
        return error.TestUnexpectedFilePresent;
    } else |err| try std.testing.expectEqual(error.FileNotFound, err);
}

test "accountIdFromAccessToken extracts chatgpt_account_id from valid JWT token" {
    // Arrange
    const gpa = std.testing.allocator;
    const valid_jwt = "e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjLTEyMzQ1In19.sig";

    // Act
    const account_id = try accountIdFromAccessToken(gpa, valid_jwt);
    defer gpa.free(account_id);

    // Assert
    try std.testing.expectEqualStrings("acc-12345", account_id);
}

test "accountIdFromAccessToken returns InvalidCredentials on invalid JSON payload in JWT token" {
    // Arrange
    const gpa = std.testing.allocator;
    const invalid_json_jwt = "e30.bm90IGpzb24.sig";

    // Act & Assert
    try std.testing.expectError(error.InvalidCredentials, accountIdFromAccessToken(gpa, invalid_json_jwt));
}

test "accountIdFromAccessToken returns InvalidCredentials on missing claims or malformed JWT token" {
    // Arrange
    const gpa = std.testing.allocator;
    const missing_claims_jwt = "e30.eyJmb28iOiJiYXIifQ.sig";
    const malformed_jwt = "header.payload";

    // Act & Assert
    try std.testing.expectError(error.InvalidCredentials, accountIdFromAccessToken(gpa, missing_claims_jwt));
    try std.testing.expectError(error.InvalidCredentials, accountIdFromAccessToken(gpa, malformed_jwt));
}

test "accountIdFromAccessToken rejects JWTs with extra segments or empty payload" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidCredentials, accountIdFromAccessToken(gpa, "e30.eyJmb28iOiJiYXIifQ.sig.extra"));
    try std.testing.expectError(error.InvalidCredentials, accountIdFromAccessToken(gpa, "e30..sig"));
}

test "createAuthorizationFlow constructs valid PKCE authorization URL and state" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var flow = try createAuthorizationFlow(gpa, io);
    defer flow.deinit(gpa);

    try std.testing.expect(flow.verifier.len > 0);
    try std.testing.expectEqual(@as(usize, 32), flow.state.len);
    try std.testing.expect(std.mem.startsWith(u8, flow.url, authorize_url));
    try std.testing.expect(std.mem.indexOf(u8, flow.url, "client_id=") != null);
    try std.testing.expect(std.mem.indexOf(u8, flow.url, "code_challenge=") != null);
    try std.testing.expect(std.mem.indexOf(u8, flow.url, "state=") != null);
}

const MockCallbackClient = struct {
    io: std.Io,
    path: []const u8,

    fn run(self: MockCallbackClient) void {
        var address = std.Io.net.IpAddress.parseIp4(auth_host, auth_port) catch return;
        // 2000 × 5ms ≈ 10s of connect retries. This budget must comfortably
        // exceed any pre-bind work on the tested side: when it was 100 tries
        // (~500ms), pre-bind latency — historically an xdg-open spawn inside
        // login, plus scheduling jitter after the ~500 tests that run before
        // this one — could outlive it, the client gave up before the listener
        // existed, and the 120s watchdog then surfaced the deadline as
        // error.Timeout instead of the error under test. A generous budget
        // only costs time on the failure path — the success path connects on
        // the first try.
        var retry: usize = 0;
        while (retry < 2000) : (retry += 1) {
            if (address.connect(self.io, .{ .mode = .stream })) |stream| {
                var local_stream = stream;
                defer local_stream.close(self.io);
                var write_buf: [1024]u8 = undefined;
                var writer = local_stream.writer(self.io, &write_buf);
                writer.interface.print("GET {s} HTTP/1.1\r\nHost: localhost:{d}\r\nConnection: close\r\n\r\n", .{ self.path, auth_port }) catch {};
                writer.interface.flush() catch {};
                return;
            } else |_| {
                self.io.sleep(.fromMilliseconds(5), .awake) catch {};
            }
        }
    }
};

test "watchdog_forcesAcceptToReturn_withTimeout_whenNoClientConnects" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // A port nothing will ever connect to during this test.
    try std.testing.expectError(
        error.Timeout,
        waitForAuthorizationCode(gpa, io, 14550, 200, "no_client_will_come"),
    );
}

test "waitForAuthorizationCode accepts valid callback and returns authorization code" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const expected_state = "valid_state_1234567890abcdef";
    const callback_path = "/auth/callback?code=test_code_xyz&state=valid_state_1234567890abcdef";

    const client = MockCallbackClient{ .io = io, .path = callback_path };
    const thread = try std.Thread.spawn(.{}, MockCallbackClient.run, .{client});
    defer thread.join();

    const code = try waitForAuthorizationCode(gpa, io, auth_port, 10_000, expected_state);
    defer gpa.free(code);
    try std.testing.expectEqualStrings("test_code_xyz", code);
}

test "waitForAuthorizationCode rejects state mismatch and invalid path" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // State Mismatch case
    {
        const client = MockCallbackClient{ .io = io, .path = "/auth/callback?code=test_code&state=wrong_state" };
        const thread = try std.Thread.spawn(.{}, MockCallbackClient.run, .{client});
        defer thread.join();

        try std.testing.expectError(error.StateMismatch, waitForAuthorizationCode(gpa, io, auth_port, 10_000, "expected_state"));
    }

    // Invalid Path case
    {
        const client = MockCallbackClient{ .io = io, .path = "/wrong/path?code=test_code&state=expected_state" };
        const thread = try std.Thread.spawn(.{}, MockCallbackClient.run, .{client});
        defer thread.join();

        try std.testing.expectError(error.InvalidCallback, waitForAuthorizationCode(gpa, io, auth_port, 10_000, "expected_state"));
    }
}

test "login handles callback state mismatch and cleans up resources" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const home_dir = "/tmp/nova-login-test-home";

    const client = MockCallbackClient{ .io = io, .path = "/auth/callback?code=some_code&state=unmatched_state" };
    const thread = try std.Thread.spawn(.{}, MockCallbackClient.run, .{client});
    defer thread.join();

    // open_browser=false keeps a real xdg-open out of the suite (and out of
    // the race with the mock client); the shortened deadline bounds a
    // hypothetical regression to seconds instead of the production 120 s
    // watchdog wait.
    try std.testing.expectError(error.StateMismatch, loginWith(gpa, io, home_dir, .{
        .open_browser = false,
        .callback_timeout_ms = 10_000,
    }));
}
