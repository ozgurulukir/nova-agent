//! Shared process-capture machinery for the shell tools (`bash_exec.zig`,
//! `pwsh_exec.zig`).
//!
//! The two exec modules carried byte-identical copies of the bounded-tail
//! `Sink`, the child drainer, and the capture result types; only the
//! spill-file prefix differed (pinned per shell by `temp_files.zig`). The
//! spawn shapes (`bash -c <merged>` vs `pwsh -File <temp .ps1>`, and the
//! stderr-merge strategy) stay per-module — they are the shells' real
//! differences, not duplication.
//!
//! The spill directory is injected through the `Sink` config namespace so
//! this module imports neither exec module (both import this one).

const std = @import("std");
const os = @import("../os.zig");

const assert = std.debug.assert;

pub const Result = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,
    display: ?[]u8 = null,

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
        if (self.display) |display| gpa.free(display);
        self.* = undefined;
    }
};

const stdout_bytes_limit: usize = 512 * 1024;
const stderr_bytes_limit: usize = 512 * 1024;

/// Inline-vs-spill thresholds for `capture`.
pub const CaptureLimits = struct {
    /// Spill to disk (and mark the tail truncated) once either is exceeded.
    bytes_max: usize,
    lines_max: u32,
    /// In-memory rolling-tail capacity. Must exceed `bytes_max`: the spill file
    /// is seeded from the still-untrimmed tail the instant the threshold trips,
    /// so the tail must hold the full output up to that point.
    tail_bytes_max: usize,
    /// Hard cap on the spill file size. The observation only ever shows the
    /// last `bytes_max` bytes, so a command emitting endless output must not be
    /// able to grow an unbounded file on disk; once the cap is hit the spill
    /// stops growing while the in-memory tail keeps serving the observation.
    spill_bytes_max: usize,
};

/// Combined stdout+stderr capture of one command, streamed rather than buffered.
///
/// A bounded rolling `tail` is kept in memory; only once output exceeds the
/// inline budget is the full stream spilled to `spill_path` on disk. Small
/// commands — the common case — never touch the filesystem.
pub const Capture = struct {
    /// Trailing slice of the merged output, UTF-8-clean, bounded by
    /// `limits.tail_bytes_max`. The complete output when `spill_path` is null.
    tail: []u8,
    total_bytes: u64,
    total_lines: u32,
    /// Full output on disk, set iff the inline budget was exceeded. Caller owns
    /// the path string; the file itself is left in place for later retrieval.
    spill_path: ?[]u8,
    /// The command was killed for exceeding its timeout.
    timed_out: bool,
    /// Process exit code (255 for signal/unknown, 124 when `timed_out`).
    code: u8,

    pub fn deinit(self: *Capture, gpa: std.mem.Allocator) void {
        gpa.free(self.tail);
        if (self.spill_path) |path| gpa.free(path);
        self.* = undefined;
    }
};

pub const capture_read_reserve: usize = 64 * 1024;

/// Best-effort stdin feed for a spawned child, run on its own thread: on EPIPE
/// (the child exited before reading all of it) or any other write error, drop
/// the data and close. The main thread is never blocked writing stdin, so it
/// always drains stdout and the child progresses.
pub fn writeStdinAndClose(io: std.Io, stdin_file: std.Io.File, data: []const u8) void {
    stdin_file.writeStreamingAll(io, data) catch {};
    stdin_file.close(io);
}

/// Drain both pipes of a spawned child to completion and collect the output.
///
/// The timeout is converted to an absolute deadline once, so the cap is TOTAL
/// runtime (TD-2): every fill below waits against the same timestamp, and a
/// chatty command cannot push the deadline out. `error.Timeout` propagates to
/// the caller exactly as the per-shell callers expect.
pub fn drainChild(gpa: std.mem.Allocator, io: std.Io, child: *std.process.Child, timeout: std.Io.Timeout) !Result {
    assert(child.stdout != null);
    assert(child.stderr != null);
    const deadline = timeout.toDeadline(io);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(gpa, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);

    while (multi_reader.fill(64, deadline)) |_| {
        if (stdout_reader.buffered().len > stdout_bytes_limit) return error.StreamTooLong;
        if (stderr_reader.buffered().len > stderr_bytes_limit) return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }

    try multi_reader.checkAnyError();
    const term = try child.wait(io);

    const stdout_slice = try multi_reader.toOwnedSlice(0);
    errdefer gpa.free(stdout_slice);
    const stderr_slice = try multi_reader.toOwnedSlice(1);
    errdefer gpa.free(stderr_slice);

    return .{
        .stdout = stdout_slice,
        .stderr = stderr_slice,
        .code = os.termCode(term),
    };
}

/// Streaming accumulator behind `capture`: keeps a bounded rolling tail and,
/// once the inline budget is exceeded, spills the full output to a temp file.
///
/// Instantiated once per shell with a config namespace of two decls:
/// `spill_prefix` (`temp_files.zig` prunable prefix for the log name) and
/// `spillDir` (the temp dir both the shell and Nova agree on).
pub fn Sink(comptime config: type) type {
    return struct {
        const Spill = struct {
            file: std.Io.File,
            path: []u8,
        };
        const Self = @This();

        limits: CaptureLimits,
        tail: std.ArrayList(u8) = .empty,
        total_bytes: u64 = 0,
        newline_count: u32 = 0,
        ended_with_newline: bool = false,
        spill: ?Spill = null,
        /// Bytes written to the spill file so far; capped by `limits.spill_bytes_max`.
        spill_bytes: usize = 0,

        pub fn ingest(self: *Self, gpa: std.mem.Allocator, io: std.Io, chunk: []const u8) !void {
            assert(chunk.len > 0);
            const chunk_ends_newline = chunk[chunk.len - 1] == '\n';
            const new_total = self.total_bytes + chunk.len;
            const new_lines = self.newline_count + countNewlines(chunk);
            // Count an unterminated trailing line as a line, exactly like the
            // `total_lines` reported in `finish`, so the spill trigger and the
            // observation's truncation test agree: a spill file exists iff the tail
            // is shown truncated.
            const new_total_lines = new_lines + @intFromBool(!chunk_ends_newline);

            // Decide to spill before appending/trimming. The tail is still untrimmed
            // here (the byte threshold is below the trim threshold), so it holds the
            // complete output so far and can seed the file; the current chunk is then
            // written whole, so the file captures everything from this point on.
            if (self.spill == null and (new_total > self.limits.bytes_max or new_total_lines > self.limits.lines_max)) {
                self.spill = try openSpill(gpa, io);
                try self.spill.?.file.writeStreamingAll(io, self.tail.items);
                self.spill_bytes = self.tail.items.len;
            }
            // Cap the spill file at `spill_bytes_max` (TD-9): once reached, stop
            // appending while the in-memory rolling tail keeps serving the
            // observation. `spill_bytes_max >= tail_bytes_max` (asserted in
            // `capture`), so the seed write always fits.
            if (self.spill) |spill| {
                const room = self.limits.spill_bytes_max -| self.spill_bytes;
                if (room > 0) {
                    const n = @min(chunk.len, room);
                    try spill.file.writeStreamingAll(io, chunk[0..n]);
                    self.spill_bytes += n;
                }
            }

            try self.tail.appendSlice(gpa, chunk);
            self.total_bytes = new_total;
            self.newline_count = new_lines;
            self.ended_with_newline = chunk_ends_newline;
            self.trimTail();
        }

        /// Drop leading bytes once the tail grows past twice its budget, keeping the
        /// last `tail_bytes_max` bytes and not splitting a UTF-8 sequence.
        fn trimTail(self: *Self) void {
            if (self.tail.items.len <= self.limits.tail_bytes_max * 2) return;
            var start = self.tail.items.len - self.limits.tail_bytes_max;
            while (start < self.tail.items.len and (self.tail.items[start] & 0xC0) == 0x80) start += 1;
            std.mem.copyForwards(u8, self.tail.items[0 .. self.tail.items.len - start], self.tail.items[start..]);
            self.tail.shrinkRetainingCapacity(self.tail.items.len - start);
        }

        /// Consume the sink into a `Capture`: the tail buffer and the spill
        /// path move into the result, so this is terminal — pair `deinit`
        /// only with the error path (before `finish` has succeeded).
        pub fn finish(self: *Self, gpa: std.mem.Allocator, io: std.Io, code: u8, timed_out: bool) !Capture {
            const tail = try self.tail.toOwnedSlice(gpa);
            if (self.spill) |spill| spill.file.close(io);
            return .{
                .tail = tail,
                .total_bytes = self.total_bytes,
                .total_lines = if (self.total_bytes == 0) 0 else self.newline_count + @intFromBool(!self.ended_with_newline),
                .spill_path = if (self.spill) |spill| spill.path else null,
                .timed_out = timed_out,
                .code = code,
            };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator, io: std.Io) void {
            self.tail.deinit(gpa);
            if (self.spill) |spill| {
                spill.file.close(io);
                std.Io.Dir.deleteFile(.cwd(), io, spill.path) catch {};
                gpa.free(spill.path);
            }
            self.* = undefined;
        }

        fn openSpill(gpa: std.mem.Allocator, io: std.Io) !Spill {
            const path = try tempSpillPath(gpa, io);
            errdefer gpa.free(path);
            const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
            return .{ .file = file, .path = path };
        }

        fn tempSpillPath(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
            var random: [16]u8 = undefined;
            io.random(&random);
            const hex = std.fmt.bytesToHex(random, .lower);
            const name = try std.fmt.allocPrint(gpa, config.spill_prefix ++ "{s}.log", .{hex[0..]});
            defer gpa.free(name);
            const dir = try config.spillDir(gpa);
            defer gpa.free(dir);
            return std.fs.path.join(gpa, &.{ dir, name });
        }

        fn countNewlines(bytes: []const u8) u32 {
            var count: u32 = 0;
            for (bytes) |byte| {
                if (byte == '\n') count += 1;
            }
            return count;
        }
    };
}
