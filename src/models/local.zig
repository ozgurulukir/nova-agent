//! Lifecycle for Nova's vendored local model server (the ModernBERT bash
//! classifier).

const std = @import("std");

const os = @import("../os.zig");
const platform = @import("platform");

const assert = std.debug.assert;

const host = "127.0.0.1";
const port_first: u16 = 8765;
const port_count: u16 = 10;
// The server binds before its models load (they finish in a background
// thread), but a cold Python start still takes several seconds — poll for up
// to 30s, returning as soon as /health answers.
const startup_attempts: u32 = 300;
const startup_sleep_ms: i64 = 100;

pub const Server = struct {
    child: ?std.process.Child,
    url: []u8,

    pub fn deinit(self: *Server, gpa: std.mem.Allocator, io: std.Io) void {
        if (self.child) |*child| child.kill(io);
        gpa.free(self.url);
        self.* = undefined;
    }
};

pub fn ensure(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8) !?Server {
    assert(cwd.len > 0);

    const classifier_dir = try std.fs.path.join(gpa, &.{ cwd, "vendor", "local-models" });
    defer gpa.free(classifier_dir);
    if (!accessible(io, classifier_dir)) return null;

    const model_path = try std.fs.path.join(gpa, &.{ classifier_dir, "ModernBERT-bash-classifier", "model.onnx" });
    defer gpa.free(model_path);
    if (!accessible(io, model_path)) return null;

    const tokenizer_path = try std.fs.path.join(gpa, &.{ classifier_dir, "ModernBERT-bash-classifier", "tokenizer.json" });
    defer gpa.free(tokenizer_path);
    if (!accessible(io, tokenizer_path)) return null;

    const python_path = try pythonPath(gpa, classifier_dir);
    defer gpa.free(python_path);
    if (!accessible(io, python_path)) return null;

    var port_offset: u16 = 0;
    while (port_offset < port_count) : (port_offset += 1) {
        const port = port_first + port_offset;
        const url = try classifyUrl(gpa, port);
        errdefer gpa.free(url);
        const health_url = try healthUrl(gpa, port);
        defer gpa.free(health_url);

        if (healthy(gpa, io, health_url)) {
            return .{ .child = null, .url = url };
        }

        var child = spawn(gpa, io, classifier_dir, python_path, port) catch {
            gpa.free(url);
            continue;
        };
        errdefer child.kill(io);
        if (waitHealthy(gpa, io, health_url)) {
            return .{ .child = child, .url = url };
        }

        child.kill(io);
        gpa.free(url);
    }
    return null;
}

fn spawn(gpa: std.mem.Allocator, io: std.Io, classifier_dir: []const u8, python_path: []const u8, port: u16) !std.process.Child {
    var port_buffer: [16]u8 = undefined;
    const port_text = try std.fmt.bufPrint(&port_buffer, "{d}", .{port});

    // Inherit parent process environment, then force ONNX Runtime to sleep
    // threads when idle instead of spinning (default busy-wait wastes ~10%
    // CPU per core).
    var env_map = try platform.getEnvMap(gpa);
    defer env_map.deinit();
    try env_map.put("OMP_WAIT_POLICY", "PASSIVE");

    return std.process.spawn(io, .{
        .argv = &.{
            python_path,
            "-I",
            "server.py",
            "--model-dir",
            "ModernBERT-bash-classifier",
            "--port",
            port_text,
        },
        .cwd = .{ .path = classifier_dir },
        .environ_map = &env_map,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

fn waitHealthy(gpa: std.mem.Allocator, io: std.Io, url: []const u8) bool {
    var attempt: u32 = 0;
    while (attempt < startup_attempts) : (attempt += 1) {
        if (healthy(gpa, io, url)) return true;
        io.sleep(.fromMilliseconds(startup_sleep_ms), .awake) catch return false;
    }
    return false;
}

fn healthy(gpa: std.mem.Allocator, io: std.Io, url: []const u8) bool {
    var response_body: std.Io.Writer.Allocating = .init(gpa);
    defer response_body.deinit();
    var redirect_buffer: [1024]u8 = undefined;
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const result = client.fetch(.{
        .method = .GET,
        .location = .{ .url = url },
        .response_writer = &response_body.writer,
        .redirect_buffer = &redirect_buffer,
        .keep_alive = false,
    }) catch return false;
    return result.status == .ok;
}

fn accessible(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn pythonPath(gpa: std.mem.Allocator, classifier_dir: []const u8) ![]u8 {
    if (os.is_windows) {
        return std.fs.path.join(gpa, &.{ classifier_dir, ".venv", "Scripts", "python.exe" });
    }
    return std.fs.path.join(gpa, &.{ classifier_dir, ".venv", "bin", "python" });
}

fn classifyUrl(gpa: std.mem.Allocator, port: u16) ![]u8 {
    return std.fmt.allocPrint(gpa, "http://{s}:{d}/classify", .{ host, port });
}

fn healthUrl(gpa: std.mem.Allocator, port: u16) ![]u8 {
    return std.fmt.allocPrint(gpa, "http://{s}:{d}/health", .{ host, port });
}

test "classifier server builds endpoint URLs" {
    const gpa = std.testing.allocator;
    const classify = try classifyUrl(gpa, 8765);
    defer gpa.free(classify);
    const health = try healthUrl(gpa, 8765);
    defer gpa.free(health);
    try std.testing.expectEqualStrings("http://127.0.0.1:8765/classify", classify);
    try std.testing.expectEqualStrings("http://127.0.0.1:8765/health", health);
}
