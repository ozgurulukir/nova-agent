const std = @import("std");

pub const buffer = @import("buffer.zig");

pub const proto = @import("proto.zig");
pub const OpCode = proto.OpCode;
pub const Message = proto.Message;
pub const MessageType = Message.Type;
pub const MessageTextType = Message.TextType;

pub const Client = @import("client/client.zig").Client;

pub const Compression = struct {
    write_threshold: ?usize = null,
    retain_write_buffer: bool = true,
    // don't know how to support these with the Zig 0.15 changes. So, for now
    // we'll always require these to be true
    // client_no_context_takeover: bool = false,
    // server_no_context_takeover: bool = false,
};

pub fn bufferProvider(io: std.Io, allocator: std.mem.Allocator, config: buffer.Config) !buffer.Provider {
    return buffer.Provider.init(io, allocator, config);
}
