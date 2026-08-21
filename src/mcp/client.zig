//! Model Context Protocol (MCP) Client.
//! Implements protocol state machine, tool discovery, execution, and health monitoring.

const std = @import("std");
const log = std.log.scoped(.mcp);
const config_mod = @import("../config/config.zig");
const os = @import("../os.zig");
const http = @import("../http.zig");
const tools_common = @import("../tools/common.zig");
const transport = @import("transport.zig");
const schema_mod = @import("schema.zig");

const assert = std.debug.assert;

// Streamable HTTP transport buffer/bound sizes.
const http_body_buffer_bytes = 8 * 1024;
const http_redirect_buffer_bytes = 16 * 1024;
const http_transfer_buffer_bytes = 64 * 1024;
const http_response_bytes_max = 64 * 1024 * 1024;

// MCP protocol version strings (spec-mandated — the server echoes one back
// during `initialize` negotiation, so these values can never change).
const protocol_version_stdio = "2024-11-05";
const protocol_version_streamable_http = "2025-03-26";

/// The Streamable HTTP `Accept` value: either a single JSON body or an SSE
/// stream (MCP spec contract).
const accept_streamable_http = http.content_type_json ++ ", " ++ http.media_type_event_stream;

/// A zeroed `std.process.Child` placeholder. On Windows the `thread_handle`
/// field is a non-nullable HANDLE, so `std.mem.zeroes` cannot be used; a
/// non-null sentinel pointer is substituted instead. The placeholder is only
/// ever overwritten by a real `spawn` before use.
pub fn zeroedChild() std.process.Child {
    if (os.is_windows) {
        return .{
            .id = null,
            .thread_handle = @ptrFromInt(1),
            .stdin = null,
            .stdout = null,
            .stderr = null,
            .request_resource_usage_statistics = false,
        };
    }
    return std.mem.zeroes(std.process.Child);
}
pub const ServerStatus = enum {
    connecting,
    connected,
    failed,
    disabled,

    pub fn label(self: ServerStatus) []const u8 {
        return switch (self) {
            .connecting => "CONNECTING",
            .connected => "CONNECTED",
            .failed => "FAILED",
            .disabled => "DISABLED",
        };
    }
};

pub const McpTool = struct {
    server_name: []u8,
    name: []u8,
    full_name: []u8,
    description: []u8,
    schema: tools_common.Schema,

    pub fn deinit(self: *McpTool, gpa: std.mem.Allocator) void {
        gpa.free(self.server_name);
        gpa.free(self.name);
        gpa.free(self.full_name);
        gpa.free(self.description);
        for (self.schema.properties) |*prop| {
            gpa.free(prop.name);
            gpa.free(prop.description);
        }
        if (self.schema.properties.len > 0) gpa.free(self.schema.properties);
        self.* = undefined;
    }
};

/// Server identity reported in the `initialize` response. Owned; freed in
/// `McpClient.deinit`. Used for diagnostics and TUI display.
pub const ServerInfo = struct {
    name: []u8,
    version: []u8,

    pub fn deinit(self: *ServerInfo, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.version);
        self.* = undefined;
    }
};

pub const McpClient = struct {
    gpa: std.mem.Allocator,
    name: []u8,
    /// The static transport configuration. Variants make illegal
    /// combinations unrepresentable: a stdio client always has
    /// command+args, an sse client always has a url.
    transport: union(enum) {
        stdio: struct {
            command: []u8,
            args: [][]u8,
        },
        sse: struct {
            url: []u8,
            /// Extra HTTP headers sent with every request (already `{env:VAR}`-
            /// expanded by the manager). Owned; freed in `stop`.
            headers: []config_mod.McpHeader = &.{},
        },
    },
    /// Runtime lifecycle. Variants make illegal combinations
    /// unrepresentable: only stdio can have a `process`, only failed
    /// has a reason, only disabled/connecting/ready are valid for the
    /// inner status.
    lifecycle: union(enum) {
        disabled,
        stdio: struct {
            process: std.process.Child,
            status: enum { connecting, ready },
        },
        sse: struct {
            status: enum { connecting, ready },
        },
        failed: struct {
            reason: []u8,
        },
    },
    latency_ms: u32 = 0,
    tools: std.ArrayList(McpTool) = .empty,
    next_request_id: i64 = 1,
    /// Serializes JSON-RPC requests — stdin/stdout pipes can't handle
    /// concurrent requests. Defensive for future parallel tool execution.
    request_mutex: std.Io.Mutex = .init,
    /// Read timeout for sendRequest poll, in milliseconds.
    read_timeout_ms: u32 = 30_000,
    /// Server-assigned `Mcp-Session-Id` for the Streamable HTTP transport.
    /// null until the initialize response provides one. Owned; freed in deinit.
    session_id: ?[]u8 = null,
    /// Server identity from the `initialize` response. Owned; freed in deinit.
    /// null until the handshake completes (or if the server omitted serverInfo).
    server_info: ?ServerInfo = null,
    /// Protocol version the server echoed back in `initialize`. May differ
    /// from what we sent — the server may downgrade. Owned; freed in deinit.
    negotiated_protocol: ?[]u8 = null,
    /// True when the server advertised `capabilities.tools.listChanged`. When
    /// set, the server may send `notifications/tools/list_changed` and the
    /// App should re-discover tools. False otherwise (including when the
    /// server advertises tools but not the listChanged flag).
    server_supports_tools_list_changed: bool = false,
    /// Set by `handleNotification` when a `notifications/tools/list_changed`
    /// arrives mid-request. The App polls `pollToolsRefresh` on each tick and,
    /// if true, calls `refreshMcpTools` to re-discover the tool list. This
    /// avoids re-entering `listTools` synchronously from inside a JSON-RPC
    /// read loop (which would deadlock the request mutex).
    pending_tools_refresh: bool = false,

    pub fn init(gpa: std.mem.Allocator, name: []const u8, command: ?[]const u8, args: []const []const u8, url: ?[]const u8) !McpClient {
        // Legacy init: if url is set, build an sse client; otherwise stdio.
        // The caller picks the transport via the (command, url) pair.
        if (url) |u| {
            if (command != null) return error.AmbiguousTransport;
            return initSse(gpa, name, u);
        }
        const cmd = command orelse return error.NoTransport;
        return initStdio(gpa, name, cmd, args);
    }

    /// Internal: build a McpClient from explicit stdio parameters. The
    /// manager now constructs Transport unions directly via this path.
    pub fn initStdio(gpa: std.mem.Allocator, name: []const u8, command: []const u8, args: []const []const u8) !McpClient {
        var owned_args = try gpa.alloc([]u8, args.len);
        errdefer {
            for (owned_args) |a| gpa.free(a);
            gpa.free(owned_args);
        }
        for (args, 0..) |arg, i| {
            owned_args[i] = try gpa.dupe(u8, arg);
        }
        return .{
            .gpa = gpa,
            .name = try gpa.dupe(u8, name),
            .transport = .{
                .stdio = .{
                    .command = try gpa.dupe(u8, command),
                    .args = owned_args,
                },
            },
            .lifecycle = .disabled,
        };
    }

    pub fn initSse(gpa: std.mem.Allocator, name: []const u8, url: []const u8) !McpClient {
        return .{
            .gpa = gpa,
            .name = try gpa.dupe(u8, name),
            .transport = .{ .sse = .{ .url = try gpa.dupe(u8, url) } },
            .lifecycle = .disabled,
        };
    }

    /// Build a fresh client with the same transport configuration (name, stdio
    /// command/args, sse url/headers) in `.connecting` lifecycle, for an async
    /// connect worker. The worker spawns and handshakes on the clone; the
    /// manager moves the completed client into the live list slot on the main
    /// thread, so the live client is never mutated off-thread.
    pub fn cloneForConnect(self: *const McpClient, io: std.Io) !McpClient {
        var clone: McpClient = switch (self.transport) {
            .stdio => |t| try initStdio(self.gpa, self.name, t.command, t.args),
            .sse => |t| try initSse(self.gpa, self.name, t.url),
        };
        errdefer clone.deinit(io);
        if (self.transport == .sse) {
            clone.transport.sse.headers = try config_mod.cloneHeaders(self.gpa, self.transport.sse.headers);
        }
        clone.markConnecting();
        return clone;
    }

    /// Map the lifecycle union to the public `ServerStatus` enum. The
    /// union is the canonical state; this is the legacy API surface
    /// for callers (manager, TUI) that read the status field.
    pub fn status(self: *const McpClient) ServerStatus {
        return switch (self.lifecycle) {
            .disabled => .disabled,
            .stdio => |s| switch (s.status) {
                .connecting => .connecting,
                .ready => .connected,
            },
            .sse => |s| switch (s.status) {
                .connecting => .connecting,
                .ready => .connected,
            },
            .failed => .failed,
        };
    }

    /// Move the lifecycle to connecting (preserves any existing
    /// stdio process handle or sse url). Used by the manager after
    /// syncFromConfig to mark a previously-disabled client as
    /// about-to-connect.
    pub fn markConnecting(self: *McpClient) void {
        switch (self.lifecycle) {
            .stdio => |*s| s.status = .connecting,
            .sse => |*s| s.status = .connecting,
            .disabled => {
                self.lifecycle = switch (self.transport) {
                    .stdio => .{ .stdio = .{
                        .process = zeroedChild(),
                        .status = .connecting,
                    } },
                    .sse => .{ .sse = .{ .status = .connecting } },
                };
            },
            .failed => {
                self.gpa.free(self.lifecycle.failed.reason);
                self.lifecycle = switch (self.transport) {
                    .stdio => .{ .stdio = .{
                        .process = zeroedChild(),
                        .status = .connecting,
                    } },
                    .sse => .{ .sse = .{ .status = .connecting } },
                };
            },
        }
    }

    pub fn deinit(self: *McpClient, io: std.Io) void {
        self.stop(io);
        self.gpa.free(self.name);
        switch (self.transport) {
            .stdio => |t| {
                self.gpa.free(t.command);
                for (t.args) |arg| self.gpa.free(arg);
                if (t.args.len > 0) self.gpa.free(t.args);
            },
            .sse => |t| {
                self.gpa.free(t.url);
                config_mod.freeHeaders(self.gpa, t.headers);
            },
        }
        switch (self.lifecycle) {
            .failed => |f| self.gpa.free(f.reason),
            else => {},
        }
        for (self.tools.items) |*tool| tool.deinit(self.gpa);
        self.tools.deinit(self.gpa);
        if (self.session_id) |sid| self.gpa.free(sid);
        if (self.server_info) |*si| si.deinit(self.gpa);
        if (self.negotiated_protocol) |pv| self.gpa.free(pv);
        self.* = undefined;
    }

    /// Set the lifecycle to failed (or replace the existing reason).
    pub fn setError(self: *McpClient, comptime fmt: []const u8, args: anytype) void {
        if (self.lifecycle == .failed) self.gpa.free(self.lifecycle.failed.reason);
        const reason = std.fmt.allocPrint(self.gpa, fmt, args) catch return;
        self.lifecycle = .{ .failed = .{ .reason = reason } };
    }

    /// Route a server-initiated notification captured during a request read.
    /// Only `notifications/tools/list_changed` is consumed (sets
    /// `pending_tools_refresh`); other notifications (progress, logging,
    /// resources/list_changed, prompts/list_changed) are accepted but ignored
    /// — Nova doesn't expose those primitives yet. `payload` is unused for
    /// the list_changed path (the spec carries no params), but kept on the
    /// signature for future notifications that do carry params.
    fn handleNotification(self: *McpClient, method: []const u8, payload: []const u8) void {
        _ = payload;
        if (std.mem.eql(u8, method, "notifications/tools/list_changed")) {
            // Honor the capability flag — a server that didn't advertise
            // listChanged shouldn't be sending these, but we still set the
            // flag: re-discovery is idempotent and harmless.
            self.pending_tools_refresh = true;
            return;
        }
        // Silently accept other notifications — they're informational.
    }

    /// True when a `notifications/tools/list_changed` arrived since the last
    /// check. The App calls this on each tick and, when true, calls
    /// `refreshMcpTools` (which re-runs `tools/list` and reinjects schemas).
    /// The flag is cleared atomically with the read.
    pub fn pollToolsRefresh(self: *McpClient) bool {
        if (self.pending_tools_refresh) {
            self.pending_tools_refresh = false;
            return true;
        }
        return false;
    }

    /// Spawn the MCP server subprocess (stdio transport).
    /// Sets up stdin/stdout pipes for JSON-RPC communication.
    pub fn startStdio(self: *McpClient, io: std.Io) !void {
        const t = switch (self.transport) {
            .stdio => |t| t,
            .sse => return error.NoStdioTransport,
        };
        // Build argv: command + args
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        try argv.append(self.gpa, t.command);
        for (t.args) |arg| try argv.append(self.gpa, arg);

        var child = try std.process.spawn(io, .{
            .argv = argv.items,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        errdefer child.kill(io);

        self.lifecycle = .{
            .stdio = .{
                .process = child,
                .status = .connecting,
            },
        };
    }

    /// Stop the subprocess: SIGTERM first, then SIGKILL via kill().
    /// Closes stdin/stdout pipes and reaps the child. For the Streamable HTTP
    /// transport, terminates the remote session (best-effort) and drops the
    /// session id.
    pub fn stop(self: *McpClient, io: std.Io) void {
        if (self.lifecycle == .stdio) {
            var child = self.lifecycle.stdio.process;
            // Close stdin so the child sees EOF and can exit gracefully.
            if (child.stdin) |*stdin_file| {
                stdin_file.close(io);
                child.stdin = null;
            }
            if (child.stdout) |*stdout_file| {
                stdout_file.close(io);
                child.stdout = null;
            }
            // SIGTERM first — gives well-behaved servers a chance to clean up.
            // kill() below sends SIGKILL and reaps the zombie regardless.
            if (child.id) |pid| {
                if (!os.is_windows) {
                    std.posix.kill(@intCast(pid), std.posix.SIG.TERM) catch {};
                }
            }
            child.kill(io);
        }
        if (self.transport == .sse) self.terminateHttpSession(io);
        // A failed client may carry an owned reason (set via `setError`, e.g.
        // by the async connect worker before tearing the clone down). Free it
        // before the lifecycle is clobbered, or deinit's failed-arm can never
        // see it and the reason leaks.
        if (self.lifecycle == .failed) self.gpa.free(self.lifecycle.failed.reason);
        self.lifecycle = .disabled;
    }

    /// Terminate the remote session via HTTP DELETE (best-effort) and free the
    /// stored session id. Servers may refuse DELETE; failures are ignored since
    /// the connection is being torn down regardless. Idempotent.
    fn terminateHttpSession(self: *McpClient, io: std.Io) void {
        defer {
            if (self.session_id) |sid| {
                self.gpa.free(sid);
                self.session_id = null;
            }
        }
        if (self.session_id == null) return;
        const url = switch (self.transport) {
            .sse => |t| t.url,
            .stdio => return,
        };
        var client: std.http.Client = .{ .allocator = self.gpa, .io = io };
        defer client.deinit();
        const extra_headers = self.buildExtraHeaders(self.gpa) catch return;
        defer self.gpa.free(extra_headers);
        var req = client.request(.DELETE, std.Uri.parse(url) catch return, .{
            .extra_headers = extra_headers,
        }) catch return;
        defer req.deinit();
        // Best-effort: bound the send so teardown can't hang on a dead server,
        // then send the termination without waiting for the response.
        if (req.connection) |conn| self.applyHttpTimeout(conn);
        req.sendBodiless() catch return;
    }

    /// Send a JSON-RPC request and read the response. Dispatches on the
    /// transport: stdio reads a newline-delimited response line; Streamable
    /// HTTP POSTs and reads a JSON body or an SSE stream. Returns the raw
    /// JSON-RPC response (owned, caller must free). Serialized via
    /// request_mutex — concurrent calls queue, not interleave.
    pub fn sendRequest(self: *McpClient, io: std.Io, method: []const u8, params_json: ?[]const u8) ![]u8 {
        return switch (self.transport) {
            .stdio => self.sendRequestStdio(io, method, params_json),
            .sse => self.sendRequestHttp(io, method, params_json),
        };
    }

    /// stdio transport: write the request line to the child's stdin and read
    /// one newline-delimited response line from stdout. Blocks up to
    /// `read_timeout_ms`. The server may push notifications (method, no id)
    /// between the request and its response — those are routed to
    /// `handleNotification` and the read continues until the matching
    /// response (id present) arrives.
    fn sendRequestStdio(self: *McpClient, io: std.Io, method: []const u8, params_json: ?[]const u8) ![]u8 {
        const child = if (self.lifecycle == .stdio) &self.lifecycle.stdio.process else return error.NotConnected;
        const stdin_file = child.stdin orelse return error.NotConnected;
        const stdout_file = child.stdout orelse return error.NotConnected;

        // Serialize requests: stdin/stdout pipes can't handle concurrent I/O.
        try self.request_mutex.lock(io);
        defer self.request_mutex.unlock(io);

        const id = self.next_request_id;
        self.next_request_id += 1;

        const request = try transport.formatRequest(self.gpa, id, method, params_json);
        defer self.gpa.free(request);

        try stdin_file.writeStreamingAll(io, request);

        var buf: [64 * 1024]u8 = undefined;
        var reader = stdout_file.reader(io, &buf);

        // Read newline-delimited lines until the response with our `id`
        // arrives. Server-initiated notifications (method, no id) are
        // routed to handleNotification and we keep reading.
        while (true) {
            // Wait for data on stdout with a timeout to prevent infinite hangs.
            // HUP alone is not treated as a crash — a server that has written
            // its response and exited still has buffered data in the pipe we
            // need to drain. Only a read failure after poll is a true crash.
            if (!os.is_windows) {
                var poll_fds: [1]std.posix.pollfd = .{
                    .{ .fd = stdout_file.handle, .events = std.posix.POLL.IN, .revents = 0 },
                };
                const ready = std.posix.poll(&poll_fds, @intCast(self.read_timeout_ms)) catch return error.ReadFailed;
                if (ready == 0) return error.Timeout;
            }
            // Windows: skip poll, proceed to read (kernel defaults apply)

            // Read one line from stdout (newline-delimited JSON-RPC).
            var line_writer: std.Io.Writer.Allocating = .init(self.gpa);
            errdefer line_writer.deinit();
            _ = reader.interface.streamDelimiterEnding(&line_writer.writer, '\n') catch |err| switch (err) {
                error.ReadFailed => return error.McpServerCrashed,
                error.WriteFailed => return error.OutOfMemory,
            };
            _ = reader.interface.take(1) catch {};
            const line = try line_writer.toOwnedSlice();
            errdefer self.gpa.free(line);

            // Classify: notification (method, no id) → handle + continue;
            // anything else → return for the caller to parse.
            const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, line, .{}) catch return line;
            defer parsed.deinit();
            if (parsed.value != .object) return line;
            const obj = parsed.value.object;
            if (obj.get("method") != null and obj.get("id") == null) {
                // Server-initiated notification — route and keep reading.
                const method_str = if (obj.get("method").? == .string) obj.get("method").?.string else "";
                self.handleNotification(method_str, line);
                self.gpa.free(line);
                continue;
            }
            return line;
        }
    }

    /// Send a JSON-RPC notification (no response expected). Dispatches on the
    /// transport.
    pub fn sendNotification(self: *McpClient, io: std.Io, method: []const u8, params_json: ?[]const u8) !void {
        return switch (self.transport) {
            .stdio => self.sendNotificationStdio(io, method, params_json),
            .sse => self.sendNotificationHttp(io, method, params_json),
        };
    }

    fn sendNotificationStdio(self: *McpClient, io: std.Io, method: []const u8, params_json: ?[]const u8) !void {
        const child = if (self.lifecycle == .stdio) &self.lifecycle.stdio.process else return error.NotConnected;
        const stdin_file = child.stdin orelse return error.NotConnected;

        const request = try transport.formatNotification(self.gpa, method, params_json);
        defer self.gpa.free(request);

        try stdin_file.writeStreamingAll(io, request);
    }

    // ── Streamable HTTP transport ──

    /// Split a request timeout in milliseconds into the `(sec, usec)` components
    /// of a POSIX `timeval` as used by `applyHttpTimeout`. Kept as a pure helper
    /// so the rounding math is unit-testable cross-platform (`std.posix.timeval`
    /// is not available on Windows, where the socket-timeout path is skipped).
    fn httpTimeoutParts(read_timeout_ms: u32) struct { sec: i64, usec: i64 } {
        return .{
            .sec = @intCast(read_timeout_ms / 1000),
            .usec = @intCast((read_timeout_ms % 1000) * 1000),
        };
    }

    /// Apply a socket-level send/recv timeout so a server that accepts the
    /// connection but then stalls — no response head, or a mid-body stop —
    /// fails the handshake instead of blocking the worker forever.
    ///
    /// `std.http.Client` exposes no connect-phase timeout in Zig 0.16, so the
    /// connect itself is bounded only by kernel TCP/DNS timeouts. Connects now
    /// run on a worker thread (`McpManager.launchConnect`), so a connect hang
    /// can never freeze the UI; this bounds everything after connect.
    fn applyHttpTimeout(self: *McpClient, conn: *std.http.Client.Connection) void {
        if (!os.is_windows) {
            const parts = httpTimeoutParts(self.read_timeout_ms);
            const tv: std.posix.timeval = .{
                .sec = parts.sec,
                .usec = parts.usec,
            };
            std.posix.setsockopt(
                conn.stream_reader.stream.socket.handle,
                std.posix.SOL.SOCKET,
                std.posix.SO.RCVTIMEO,
                std.mem.asBytes(&tv),
            ) catch {};
            std.posix.setsockopt(
                conn.stream_reader.stream.socket.handle,
                std.posix.SOL.SOCKET,
                std.posix.SO.SNDTIMEO,
                std.mem.asBytes(&tv),
            ) catch {};
        }
    }

    /// POST a JSON-RPC request to the remote endpoint and return the matching
    /// JSON-RPC response (owned). The response is either a single
    /// `application/json` body or a `text/event-stream` searched for the
    /// request `id`. Captures the server-assigned `Mcp-Session-Id`.
    fn sendRequestHttp(self: *McpClient, io: std.Io, method: []const u8, params_json: ?[]const u8) ![]u8 {
        const url = switch (self.transport) {
            .sse => |t| t.url,
            .stdio => return error.NoHttpTransport,
        };

        try self.request_mutex.lock(io);
        defer self.request_mutex.unlock(io);

        const id = self.next_request_id;
        self.next_request_id += 1;

        const body = try transport.formatRequest(self.gpa, id, method, params_json);
        defer self.gpa.free(body);

        var client: std.http.Client = .{ .allocator = self.gpa, .io = io };
        defer client.deinit();

        const extra_headers = try self.buildExtraHeaders(self.gpa);
        defer self.gpa.free(extra_headers);
        var req = try client.request(.POST, try std.Uri.parse(url), .{
            .headers = .{ .content_type = .{ .override = http.content_type_json } },
            .extra_headers = extra_headers,
        });
        defer req.deinit();
        // Bound send + head + body reads so a stalled server fails fast.
        if (req.connection) |conn| self.applyHttpTimeout(conn);
        try writeBody(&req, body);

        var redirect_buffer: [http_redirect_buffer_bytes]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);
        const status_code: u16 = @intFromEnum(response.head.status);
        if (status_code == 404) return error.McpSessionExpired;
        if (status_code == 401 or status_code == 403) return error.McpUnauthorized;
        if (!http.isSuccess(status_code)) return error.McpHttpRequestFailed;

        // Capture session id + content type BEFORE the body reader invalidates
        // the head's borrowed pointers.
        try self.captureSessionId(response.head);
        const is_sse = isEventStream(response.head);

        if (is_sse) {
            var transfer_buffer: [http_transfer_buffer_bytes]u8 = undefined;
            const reader = response.reader(&transfer_buffer);
            var notifications: std.ArrayList(transport.Notification) = .empty;
            defer {
                for (notifications.items) |*n| n.deinit(self.gpa);
                notifications.deinit(self.gpa);
            }
            const response_body = try transport.readSseResponse(self.gpa, reader, id, &notifications);
            // Route accumulated server notifications — they may set
            // pending_tools_refresh, which the App polls on the next tick.
            for (notifications.items) |n| self.handleNotification(n.method, n.payload);
            return response_body;
        }
        return try readJsonBody(self.gpa, &response);
    }

    /// POST a JSON-RPC notification to the remote endpoint. Expects
    /// 202 Accepted (or 200); the response body is not consumed.
    fn sendNotificationHttp(self: *McpClient, io: std.Io, method: []const u8, params_json: ?[]const u8) !void {
        const url = switch (self.transport) {
            .sse => |t| t.url,
            .stdio => return error.NoHttpTransport,
        };

        try self.request_mutex.lock(io);
        defer self.request_mutex.unlock(io);

        const body = try transport.formatNotification(self.gpa, method, params_json);
        defer self.gpa.free(body);

        var client: std.http.Client = .{ .allocator = self.gpa, .io = io };
        defer client.deinit();

        const extra_headers = try self.buildExtraHeaders(self.gpa);
        defer self.gpa.free(extra_headers);
        var req = try client.request(.POST, try std.Uri.parse(url), .{
            .headers = .{ .content_type = .{ .override = http.content_type_json } },
            .extra_headers = extra_headers,
        });
        defer req.deinit();
        // Bound send + head reads so a stalled server fails fast.
        if (req.connection) |conn| self.applyHttpTimeout(conn);
        try writeBody(&req, body);

        var redirect_buffer: [http_redirect_buffer_bytes]u8 = undefined;
        const response = try req.receiveHead(&redirect_buffer);
        try self.captureSessionId(response.head);
        const status_code: u16 = @intFromEnum(response.head.status);
        if (status_code == 404) return error.McpSessionExpired;
        if (status_code >= 400) return error.McpHttpRequestFailed;
    }

    /// Build the extra request headers: the Streamable HTTP `Accept` header,
    /// `Mcp-Session-Id` once a session is established, and any custom headers
    /// configured for the server (e.g. API keys). Returned slice is owned; free
    /// with `gpa.free`.
    fn buildExtraHeaders(self: *const McpClient, gpa: std.mem.Allocator) ![]std.http.Header {
        const custom: []const config_mod.McpHeader = switch (self.transport) {
            .sse => |t| t.headers,
            .stdio => &.{},
        };
        const count = 1 + custom.len + (if (self.session_id != null) @as(usize, 1) else 0);
        const headers = try gpa.alloc(std.http.Header, count);
        var i: usize = 0;
        headers[i] = .{ .name = "Accept", .value = accept_streamable_http };
        i += 1;
        if (self.session_id) |sid| {
            headers[i] = .{ .name = "Mcp-Session-Id", .value = sid };
            i += 1;
        }
        for (custom) |h| {
            headers[i] = .{ .name = h.name, .value = h.value };
            i += 1;
        }
        return headers;
    }

    /// Update `session_id` from the response's `Mcp-Session-Id` header (if
    /// present). Header values borrow the response head, so the value is duped.
    fn captureSessionId(self: *McpClient, head: std.http.Client.Response.Head) !void {
        var it = head.iterateHeaders();
        while (it.next()) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, "mcp-session-id")) continue;
            if (self.session_id) |old| self.gpa.free(old);
            self.session_id = try self.gpa.dupe(u8, header.value);
            return;
        }
    }

    /// Perform the MCP initialize handshake.
    /// On success, sets status to .connected, records latency, and captures
    /// the server's reported protocol version, serverInfo, and the
    /// `tools.listChanged` capability flag (for `notifications/tools/list_changed`
    /// subscription). Nova is a client only — it advertises no client
    /// capabilities (no sampling, no roots, no elicitation server-side).
    pub fn initialize(self: *McpClient, io: std.Io) !void {
        const start = std.Io.Timestamp.now(io, .awake);

        // Streamable HTTP requires protocol 2025-03-26+; stdio keeps the
        // original version so existing local servers are unaffected.
        const protocol_version: []const u8 = switch (self.transport) {
            .stdio => protocol_version_stdio,
            .sse => protocol_version_streamable_http,
        };
        const params = try std.fmt.allocPrint(self.gpa,
            \\{{"protocolVersion":"{s}","capabilities":{{}},"clientInfo":{{"name":"nova","version":"1.0"}}}}
        , .{protocol_version});
        defer self.gpa.free(params);

        const response = try self.sendRequest(io, "initialize", params);
        defer self.gpa.free(response);

        const parsed = try schema_mod.parseResponse(self.gpa, response) orelse {
            self.setError("handshake returned no result", .{});
            return error.McpHandshakeFailed;
        };
        defer parsed.deinit();

        const result = parsed.value.object.get("result") orelse {
            self.setError("handshake result missing", .{});
            return error.McpHandshakeFailed;
        };
        if (result != .object) {
            self.setError("handshake result not an object", .{});
            return error.McpHandshakeFailed;
        }
        const result_obj = result.object;

        // Negotiate protocol version — the server may echo or downgrade.
        // We accept whatever the server returns; no version pinning yet.
        if (result_obj.get("protocolVersion")) |pv| {
            if (pv == .string) {
                if (self.negotiated_protocol) |old| self.gpa.free(old);
                self.negotiated_protocol = self.gpa.dupe(u8, pv.string) catch null;
            }
        }

        // Capture server identity for diagnostics and TUI display.
        if (result_obj.get("serverInfo")) |si| {
            if (si == .object) {
                const sname = if (si.object.get("name")) |n| (if (n == .string) n.string else "") else "";
                const sver = if (si.object.get("version")) |v| (if (v == .string) v.string else "") else "";
                if (self.server_info) |*old| old.deinit(self.gpa);
                self.server_info = .{
                    .name = self.gpa.dupe(u8, sname) catch "",
                    .version = self.gpa.dupe(u8, sver) catch "",
                };
            }
        }

        // Parse server capabilities — record `tools.listChanged` so the App
        // can subscribe to `notifications/tools/list_changed` and re-discover.
        self.server_supports_tools_list_changed = false;
        if (result_obj.get("capabilities")) |caps| {
            if (caps == .object) {
                if (caps.object.get("tools")) |tools_cap| {
                    if (tools_cap == .object) {
                        if (tools_cap.object.get("listChanged")) |lc| {
                            if (lc == .bool) self.server_supports_tools_list_changed = lc.bool;
                        }
                    }
                }
            }
        }

        // Send initialized notification
        try self.sendNotification(io, "notifications/initialized", null);

        const end = std.Io.Timestamp.now(io, .awake);
        const elapsed_ns = start.durationTo(end).nanoseconds;
        self.latency_ms = @intCast(@max(elapsed_ns, 0) / std.time.ns_per_ms);
        // Mark the active transport as ready.
        switch (self.lifecycle) {
            .stdio => |*s| s.status = .ready,
            .sse => |*s| s.status = .ready,
            else => {},
        }
    }

    /// Query tools/list and populate the client's tool list.
    pub fn listTools(self: *McpClient, io: std.Io) !void {
        const response = try self.sendRequest(io, "tools/list", null);
        defer self.gpa.free(response);

        const parsed = try schema_mod.parseResponse(self.gpa, response) orelse return;
        defer parsed.deinit();

        const result = parsed.value.object.get("result") orelse return;
        if (result != .object) return;

        const tools_val = result.object.get("tools") orelse return;
        if (tools_val != .array) return;

        for (tools_val.array.items) |tool_val| {
            if (tool_val != .object) continue;
            const obj = tool_val.object;

            const tool_name = if (obj.get("name")) |n| (if (n == .string) n.string else continue) else continue;
            const description = if (obj.get("description")) |d| (if (d == .string) d.string else "") else "";
            const schema = if (obj.get("inputSchema")) |s| (try schema_mod.schemaFromJsonSchema(self.gpa, s)) else tools_common.Schema{ .properties = &.{} };

            try self.addTool(tool_name, description, schema);
        }
    }

    /// Call a tool via `tools/call` JSON-RPC.
    /// Returns the text content from the tool response (owned, caller must free).
    /// JSON-RPC errors and `isError: true` both return the server's message
    /// as text (not a Zig error) so the model can read what went wrong.
    pub fn callTool(self: *McpClient, io: std.Io, tool_name: []const u8, arguments_json: []const u8) ![]u8 {
        // Build params JSON with proper escaping for tool_name
        var pw: std.Io.Writer.Allocating = .init(self.gpa);
        defer pw.deinit();
        try pw.writer.writeAll("{\"name\":");
        try std.json.Stringify.value(tool_name, .{}, &pw.writer);
        try pw.writer.writeAll(",\"arguments\":");
        try pw.writer.writeAll(arguments_json);
        try pw.writer.writeAll("}");
        const params = try pw.toOwnedSlice();
        defer self.gpa.free(params);

        const response = try self.sendRequest(io, "tools/call", params);
        defer self.gpa.free(response);

        // Parse response inline to handle JSON-RPC errors with full context
        const trimmed = std.mem.trim(u8, response, " \t\r\n");
        if (trimmed.len == 0) return error.McpToolCallFailed;

        const parsed = try std.json.parseFromSlice(std.json.Value, self.gpa, trimmed, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.McpToolCallFailed;
        const obj = parsed.value.object;

        // JSON-RPC error — return the server's error message as text
        if (obj.get("error")) |err_val| {
            if (err_val == .object) {
                const msg = if (err_val.object.get("message")) |m|
                    (if (m == .string) m.string else "unknown error")
                else
                    "unknown error";
                const code = if (err_val.object.get("code")) |c|
                    (if (c == .integer) c.integer else 0)
                else
                    0;
                log.warn("MCP tool '{s}' JSON-RPC error (code {d}): {s}", .{ tool_name, code, msg });
                return self.gpa.dupe(u8, msg);
            }
            return error.McpToolCallFailed;
        }

        const result = obj.get("result") orelse return error.McpToolCallFailed;
        if (result != .object) return error.McpToolCallFailed;

        // Log server-side errors but still return the text content so the
        // model can read the server's error description (per MCP spec).
        if (result.object.get("isError")) |is_err| {
            if (is_err == .bool and is_err.bool) {
                log.warn("MCP tool '{s}' returned isError: true", .{tool_name});
            }
        }

        return schema_mod.extractContentText(self.gpa, result);
    }

    /// Register a mock or discovered tool for testing / dynamic loading.
    pub fn addTool(
        self: *McpClient,
        tool_name: []const u8,
        description: []const u8,
        schema: tools_common.Schema,
    ) !void {
        const full_name = try std.fmt.allocPrint(self.gpa, "mcp__{s}__{s}", .{ self.name, tool_name });
        errdefer self.gpa.free(full_name);

        try self.tools.append(self.gpa, .{
            .server_name = try self.gpa.dupe(u8, self.name),
            .name = try self.gpa.dupe(u8, tool_name),
            .full_name = full_name,
            .description = try self.gpa.dupe(u8, description),
            .schema = schema,
        });
    }
};

/// Write the request `body` with an explicit content-length and flush it, so
/// the server receives a complete request before we read the response head.
fn writeBody(req: *std.http.Client.Request, body: []const u8) !void {
    req.transfer_encoding = .{ .content_length = body.len };
    var body_buffer: [http_body_buffer_bytes]u8 = undefined;
    var body_writer = try req.sendBodyUnflushed(&body_buffer);
    try body_writer.writer.writeAll(body);
    try body_writer.end();
    try req.connection.?.flush();
}

/// True when the response `Content-Type` is `text/event-stream` (an SSE
/// stream) rather than a single `application/json` body.
fn isEventStream(head: std.http.Client.Response.Head) bool {
    const content_type = head.content_type orelse return false;
    return std.mem.indexOf(u8, content_type, http.media_type_event_stream) != null;
}

/// Read a single `application/json` response body, honouring content-encoding
/// (mirrors `modelsdev.fetchApiJson`: Cloudflare-style hosts may gzip it).
/// Returns the owned body; caller frees.
fn readJsonBody(gpa: std.mem.Allocator, response: *std.http.Client.Response) ![]u8 {
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

    var transfer_buffer: [http_transfer_buffer_bytes]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    return reader.allocRemaining(gpa, .limited(http_response_bytes_max)) catch |err| switch (err) {
        error.StreamTooLong => error.McpResponseTooLarge,
        else => |e| e,
    };
}

test "McpClient initializes and formats namespaced tool names" {
    const gpa = std.testing.allocator;
    var client = try McpClient.init(gpa, "memory", "npx", &.{}, null);
    defer client.deinit(std.testing.io);

    client.lifecycle = .{
        .stdio = .{
            .process = zeroedChild(),
            .status = .ready,
        },
    };
    try client.addTool("create_entities", "Create entities in graph", .{ .properties = &.{} });

    try std.testing.expectEqualStrings("memory", client.name);
    try std.testing.expectEqual(ServerStatus.connected, client.status());
    try std.testing.expectEqual(@as(usize, 1), client.tools.items.len);
    try std.testing.expectEqualStrings("mcp__memory__create_entities", client.tools.items[0].full_name);
}

test "McpClient startStdio + stop lifecycle" {
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Spawn a simple echo server that reads one line and echoes it back.
    var client = try McpClient.init(gpa, "echo-test", "bash", &.{
        "-c",
        "read line; echo \"$line\"",
    }, null);
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);

    try std.testing.expect(client.lifecycle == .stdio);
    try std.testing.expectEqual(ServerStatus.connecting, client.status());
}

test "McpClient sendRequest round-trip" {
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Bash one-liner: read one line from stdin, echo a fixed JSON-RPC response.
    var client = try McpClient.init(gpa, "echo-test", "bash", &.{
        "-c",
        "read line; echo '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2024-11-05\"}}'",
    }, null);
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);

    const response = try client.sendRequest(io, "initialize", "{\"protocolVersion\":\"2024-11-05\"}");
    defer gpa.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"protocolVersion\"") != null);
}

test "McpClient full handshake + tools/list" {
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Mock MCP server that handles initialize + initialized + tools/list.
    // Protocol: read initialize → respond → read initialized (ignore) → read tools/list → respond.
    var client = try McpClient.init(gpa, "mock-server", "bash", &.{
        "-c",
        \\read line
        \\echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"mock","version":"1.0"},"capabilities":{"tools":{}}}}'
        \\read line
        \\read line
        \\echo '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"greet","description":"Say hello","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"Name to greet"}},"required":["name"]}}]}}'
    }, null);
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);

    // Handshake
    try client.initialize(io);
    try std.testing.expectEqual(ServerStatus.connected, client.status());

    // Capability negotiation — server reported serverInfo + protocolVersion
    // and `capabilities.tools` without the listChanged flag.
    try std.testing.expect(client.server_info != null);
    try std.testing.expectEqualStrings("mock", client.server_info.?.name);
    try std.testing.expectEqualStrings("1.0", client.server_info.?.version);
    try std.testing.expect(client.negotiated_protocol != null);
    try std.testing.expectEqualStrings("2024-11-05", client.negotiated_protocol.?);
    try std.testing.expectEqual(false, client.server_supports_tools_list_changed);

    // Tool discovery
    try client.listTools(io);
    try std.testing.expectEqual(@as(usize, 1), client.tools.items.len);
    try std.testing.expectEqualStrings("mcp__mock-server__greet", client.tools.items[0].full_name);
    try std.testing.expectEqualStrings("greet", client.tools.items[0].name);
    try std.testing.expectEqualStrings("Say hello", client.tools.items[0].description);
    try std.testing.expectEqual(@as(usize, 1), client.tools.items[0].schema.properties.len);
    try std.testing.expectEqualStrings("name", client.tools.items[0].schema.properties[0].name);
    try std.testing.expectEqual(tools_common.Schema.Kind.string, client.tools.items[0].schema.properties[0].kind);
    try std.testing.expect(client.tools.items[0].schema.properties[0].required);
}

test "McpClient initialize captures tools.listChanged capability" {
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Mock server that advertises tools.listChanged: true.
    var client = try McpClient.init(gpa, "changeful", "bash", &.{
        "-c",
        \\read line
        \\echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"changeful","version":"2.0"},"capabilities":{"tools":{"listChanged":true}}}}'
        \\read line
    }, null);
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);

    try client.initialize(io);
    try std.testing.expectEqual(ServerStatus.connected, client.status());
    try std.testing.expect(client.server_supports_tools_list_changed);
    try std.testing.expectEqualStrings("changeful", client.server_info.?.name);
    try std.testing.expectEqualStrings("2.0", client.server_info.?.version);
}

test "McpClient callTool round-trip" {
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Mock MCP server: initialize → tools/list → tools/call → respond with text content.
    var client = try McpClient.init(gpa, "mock-server", "bash", &.{
        "-c",
        \\read line
        \\echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"mock","version":"1.0"},"capabilities":{"tools":{}}}}'
        \\read line
        \\read line
        \\echo '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"greet","description":"Say hello","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"Name to greet"}},"required":["name"]}}]}}'
        \\read line
        \\echo '{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"Hello, World!"}]}}'
    }, null);
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);

    // Handshake + discovery
    try client.initialize(io);
    try client.listTools(io);
    try std.testing.expectEqual(@as(usize, 1), client.tools.items.len);

    // Call the tool
    const result = try client.callTool(io, "greet", "{\"name\":\"World\"}");
    defer gpa.free(result);

    try std.testing.expectEqualStrings("Hello, World!", result);
}

// ---------------------------------------------------------------------------
// Streamable HTTP transport tests
// ---------------------------------------------------------------------------

test "buildExtraHeaders sends Accept, session id, and custom headers" {
    const gpa = std.testing.allocator;
    var client = try McpClient.initSse(gpa, "x", "http://x/mcp");
    defer client.deinit(std.testing.io);

    // No session, no custom headers → only Accept.
    {
        const headers = try client.buildExtraHeaders(gpa);
        defer gpa.free(headers);
        try std.testing.expectEqual(@as(usize, 1), headers.len);
        try std.testing.expectEqualStrings("Accept", headers[0].name);
        try std.testing.expectEqualStrings("application/json, text/event-stream", headers[0].value);
    }

    // With a session → Accept + Mcp-Session-Id.
    client.session_id = try gpa.dupe(u8, "sess-1");
    {
        const headers = try client.buildExtraHeaders(gpa);
        defer gpa.free(headers);
        try std.testing.expectEqual(@as(usize, 2), headers.len);
        try std.testing.expectEqualStrings("Mcp-Session-Id", headers[1].name);
        try std.testing.expectEqualStrings("sess-1", headers[1].value);
    }

    // With a custom header → Accept + Mcp-Session-Id + custom (e.g. an API key).
    client.transport.sse.headers = try config_mod.cloneHeaders(gpa, &[_]config_mod.McpHeader{
        .{ .name = @constCast("CONTEXT7_API_KEY"), .value = @constCast("secret") },
    });
    {
        const headers = try client.buildExtraHeaders(gpa);
        defer gpa.free(headers);
        try std.testing.expectEqual(@as(usize, 3), headers.len);
        try std.testing.expectEqualStrings("CONTEXT7_API_KEY", headers[2].name);
        try std.testing.expectEqualStrings("secret", headers[2].value);
    }
}

test "captureSessionId + isEventStream read the response head" {
    const gpa = std.testing.allocator;
    var client = try McpClient.initSse(gpa, "x", "http://x/mcp");
    defer client.deinit(std.testing.io);

    const json_head = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nMcp-Session-Id: sess-42\r\n\r\n",
    );
    try client.captureSessionId(json_head);
    try std.testing.expectEqualStrings("sess-42", client.session_id.?);
    try std.testing.expect(!isEventStream(json_head));

    const sse_head = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n",
    );
    try std.testing.expect(isEventStream(sse_head));
}

// ---------------------------------------------------------------------------
// Notification handling tests
// ---------------------------------------------------------------------------

test "handleNotification sets pending_tools_refresh for tools/list_changed" {
    const gpa = std.testing.allocator;
    var client = try McpClient.init(gpa, "x", "echo", &.{}, null);
    defer client.deinit(std.testing.io);

    // Initially no pending refresh.
    try std.testing.expectEqual(false, client.pollToolsRefresh());

    // Simulate a server-initiated tools/list_changed notification.
    client.handleNotification("notifications/tools/list_changed", "");
    try std.testing.expect(client.pollToolsRefresh());

    // The flag clears on read — a second poll returns false.
    try std.testing.expectEqual(false, client.pollToolsRefresh());

    // Other notifications do NOT set the flag.
    client.handleNotification("notifications/progress", "{}");
    client.handleNotification("notifications/resources/list_changed", "");
    try std.testing.expectEqual(false, client.pollToolsRefresh());
}

test "sendRequestStdio routes interleaved notifications to handleNotification" {
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Mock MCP server that advertises tools.listChanged. For the tools/list
    // request it emits a notification BEFORE the response — exercises the
    // stdio read loop's notification routing.
    var client = try McpClient.init(gpa, "notif-server", "bash", &.{
        "-c",
        \\read line
        \\echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"mock","version":"1.0"},"capabilities":{"tools":{"listChanged":true}}}}'
        \\read line
        \\read line
        \\echo '{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}'
        \\echo '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"greet","description":"Say hello","inputSchema":{"type":"object","properties":{}}}]}}'
    }, null);
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);

    // Handshake records the listChanged capability.
    try client.initialize(io);
    try std.testing.expect(client.server_supports_tools_list_changed);

    // tools/list arrives after a notification — the loop routes the
    // notification and keeps reading until the response.
    try client.listTools(io);
    try std.testing.expectEqual(@as(usize, 1), client.tools.items.len);
    try std.testing.expectEqualStrings("mcp__notif-server__greet", client.tools.items[0].full_name);

    // The interleaved notification was buffered — poll drains it.
    try std.testing.expect(client.pollToolsRefresh());
    try std.testing.expectEqual(false, client.pollToolsRefresh());
}

test "httpTimeoutParts derives timeval sec/usec from read_timeout_ms" {
    // The per-server `requestTimeoutMs` knob flows into `read_timeout_ms` and
    // feeds `applyHttpTimeout`'s socket timeval. Exact multiples land on zero
    // usec; non-multiples carry the sub-second remainder.
    const whole = McpClient.httpTimeoutParts(5000);
    try std.testing.expectEqual(@as(i64, 5), whole.sec);
    try std.testing.expectEqual(@as(i64, 0), whole.usec);

    const partial = McpClient.httpTimeoutParts(1500);
    try std.testing.expectEqual(@as(i64, 1), partial.sec);
    try std.testing.expectEqual(@as(i64, 500_000), partial.usec);

    // Sub-second values produce zero sec and the sub-second remainder in usec.
    const sub_second = McpClient.httpTimeoutParts(250);
    try std.testing.expectEqual(@as(i64, 0), sub_second.sec);
    try std.testing.expectEqual(@as(i64, 250_000), sub_second.usec);
}
