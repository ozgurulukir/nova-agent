const std = @import("std");
const log = std.log.scoped(.ai);

const openai_endpoint = @import("openai_endpoint.zig");

const redirect_buffer_bytes: u32 = 8192;
const transfer_buffer_bytes: u32 = 4096;
const response_bytes_max: u32 = 1 * 1024 * 1024;
const model_count_max: u32 = 512;

pub const ModelEntry = struct {
    id: []u8,

    pub fn deinit(self: *ModelEntry, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        self.* = undefined;
    }
};

pub fn listModels(
    gpa: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8,
    api_key: []const u8,
) ![]ModelEntry {
    std.debug.assert(base_url.len > 0);

    const v1_root = try openai_endpoint.v1Root(gpa, base_url);
    defer gpa.free(v1_root);
    const url = try std.fmt.allocPrint(gpa, "{s}/models", .{v1_root});
    defer gpa.free(url);

    const authorization: ?[]u8 = if (api_key.len > 0)
        try std.fmt.allocPrint(gpa, "Bearer {s}", .{api_key})
    else
        null;
    defer if (authorization) |a| gpa.free(a);

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    var request = try http_client.request(.GET, try std.Uri.parse(url), .{
        .headers = .{ .authorization = if (authorization) |a| .{ .override = a } else .omit },
    });
    defer request.deinit();
    try request.sendBodiless();
    log.info("openai_compatible.models.request GET {s}", .{url});

    var redirect_buffer: [redirect_buffer_bytes]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    const status: u16 = @intFromEnum(response.head.status);
    log.info("openai_compatible.models.response.head status={d}", .{status});
    if (status < 200) return error.HttpUnexpectedStatus;
    if (status >= 300) {
        if (status >= 500) return error.HttpServerError;
        return error.HttpClientError;
    }

    const body = try readBody(gpa, &response);
    defer gpa.free(body);
    return try parseResponse(gpa, body);
}

fn readBody(gpa: std.mem.Allocator, response: *std.http.Client.Response) ![]u8 {
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

    var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    return reader.allocRemaining(gpa, .limited(response_bytes_max)) catch |err| switch (err) {
        error.StreamTooLong => error.ResponseTooLarge,
        else => |e| e,
    };
}

const ModelsResponse = struct {
    data: []const ModelJson,
};

const ModelJson = struct {
    id: ?[]const u8 = null,
};

fn parseResponse(gpa: std.mem.Allocator, bytes: []const u8) ![]ModelEntry {
    std.debug.assert(bytes.len > 0);
    const parsed = std.json.parseFromSlice(ModelsResponse, gpa, bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidModelsResponse;
    defer parsed.deinit();
    if (parsed.value.data.len > model_count_max) return error.TooManyModels;

    var out: std.ArrayList(ModelEntry) = .empty;
    errdefer {
        for (out.items) |*entry| entry.deinit(gpa);
        out.deinit(gpa);
    }
    for (parsed.value.data) |item| {
        const id = item.id orelse continue;
        if (id.len == 0) continue;
        try out.append(gpa, .{ .id = try gpa.dupe(u8, id) });
    }
    return out.toOwnedSlice(gpa);
}
