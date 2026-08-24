//! OS keychain access for a single named secret (service + account -> bytes).
//! Two native backends are implemented — Windows Credential Manager and macOS
//! Keychain Services; every other OS reports `error.Unsupported` so callers can
//! fall back to plaintext storage.
//!
//! The secret is an opaque byte blob (Nova hands it the serialized `auth.json`).
//! `load` returns gpa-owned bytes (or null when the entry is absent); `save`
//! upserts; `delete` removes and reports whether anything was there.

const std = @import("std");
const os = @import("../os.zig");

pub const Error = error{
    /// No keychain backend on this OS — caller should use the file fallback.
    Unsupported,
    /// The backend was reachable but rejected the operation (e.g. the Windows
    /// credential blob exceeded the size limit, or an unexpected OS error).
    Backend,
    InvalidUtf8,
    OutOfMemory,
};

const impl = switch (os.tag) {
    .windows => Windows,
    .macos => Macos,
    else => Unsupported,
};

fn loadImpl(comptime Backend: type, gpa: std.mem.Allocator, service: []const u8, account: []const u8) Error!?[]u8 {
    return Backend.load(gpa, service, account);
}

fn saveImpl(comptime Backend: type, gpa: std.mem.Allocator, service: []const u8, account: []const u8, secret: []const u8) Error!void {
    return Backend.save(gpa, service, account, secret);
}

fn deleteImpl(comptime Backend: type, gpa: std.mem.Allocator, service: []const u8, account: []const u8) Error!bool {
    return Backend.delete(gpa, service, account);
}

/// Read the secret for `service`/`account`. Returns gpa-owned bytes, or null
/// when no such entry exists.
pub fn load(gpa: std.mem.Allocator, service: []const u8, account: []const u8) Error!?[]u8 {
    return loadImpl(impl, gpa, service, account);
}

/// Create or replace the secret for `service`/`account`.
pub fn save(gpa: std.mem.Allocator, service: []const u8, account: []const u8, secret: []const u8) Error!void {
    return saveImpl(impl, gpa, service, account, secret);
}

/// Remove the secret. Returns true when an entry was actually deleted.
pub fn delete(gpa: std.mem.Allocator, service: []const u8, account: []const u8) Error!bool {
    return deleteImpl(impl, gpa, service, account);
}

const Unsupported = struct {
    fn load(_: std.mem.Allocator, _: []const u8, _: []const u8) Error!?[]u8 {
        return error.Unsupported;
    }
    fn save(_: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8) Error!void {
        return error.Unsupported;
    }
    fn delete(_: std.mem.Allocator, _: []const u8, _: []const u8) Error!bool {
        return error.Unsupported;
    }
};

// --- Windows: Credential Manager (advapi32 Cred* API) ------------------------

const Windows = struct {
    const windows = std.os.windows;
    const DWORD = windows.DWORD;
    const FILETIME = windows.FILETIME;

    const CRED_TYPE_GENERIC: DWORD = 1;
    const CRED_PERSIST_LOCAL_MACHINE: DWORD = 2;
    const ERROR_NOT_FOUND: u32 = 1168;
    // CRED_MAX_CREDENTIAL_BLOB_SIZE (Vista+): 5 * 512 bytes. Anything larger is
    // rejected by the OS, so we surface `Backend` and let the caller fall back.
    const max_blob_bytes: usize = 5 * 512;

    const CREDENTIALW = extern struct {
        Flags: DWORD,
        Type: DWORD,
        TargetName: ?[*:0]u16,
        Comment: ?[*:0]u16,
        LastWritten: FILETIME,
        CredentialBlobSize: DWORD,
        CredentialBlob: ?[*]u8,
        Persist: DWORD,
        AttributeCount: DWORD,
        Attributes: ?*anyopaque,
        TargetAlias: ?[*:0]u16,
        UserName: ?[*:0]u16,
    };

    extern "advapi32" fn CredWriteW(Credential: *const CREDENTIALW, Flags: DWORD) callconv(.winapi) i32;
    extern "advapi32" fn CredReadW(TargetName: [*:0]const u16, Type: DWORD, Flags: DWORD, Credential: *?*CREDENTIALW) callconv(.winapi) i32;
    extern "advapi32" fn CredDeleteW(TargetName: [*:0]const u16, Type: DWORD, Flags: DWORD) callconv(.winapi) i32;
    extern "advapi32" fn CredFree(Buffer: *anyopaque) callconv(.winapi) void;

    /// `<service>:<account>` as a NUL-terminated UTF-16 string (the unique key).
    fn targetName(gpa: std.mem.Allocator, service: []const u8, account: []const u8) Error![:0]u16 {
        const utf8 = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ service, account });
        defer gpa.free(utf8);
        return std.unicode.utf8ToUtf16LeAllocZ(gpa, utf8);
    }

    fn load(gpa: std.mem.Allocator, service: []const u8, account: []const u8) Error!?[]u8 {
        const target = try targetName(gpa, service, account);
        defer gpa.free(target);

        var cred: ?*CREDENTIALW = null;
        if (CredReadW(target.ptr, CRED_TYPE_GENERIC, 0, &cred) == 0) {
            if (@intFromEnum(windows.GetLastError()) == ERROR_NOT_FOUND) return null;
            return error.Backend;
        }
        const found = cred orelse return null;
        defer CredFree(found);

        const size = found.CredentialBlobSize;
        const blob = found.CredentialBlob orelse return try gpa.dupe(u8, "");
        return try gpa.dupe(u8, blob[0..size]);
    }

    fn save(gpa: std.mem.Allocator, service: []const u8, account: []const u8, secret: []const u8) Error!void {
        if (secret.len > max_blob_bytes) return error.Backend;

        const target = try targetName(gpa, service, account);
        defer gpa.free(target);
        const user = try std.unicode.utf8ToUtf16LeAllocZ(gpa, account);
        defer gpa.free(user);

        const cred = CREDENTIALW{
            .Flags = 0,
            .Type = CRED_TYPE_GENERIC,
            .TargetName = target.ptr,
            .Comment = null,
            .LastWritten = .{ .dwLowDateTime = 0, .dwHighDateTime = 0 },
            .CredentialBlobSize = @intCast(secret.len),
            .CredentialBlob = @constCast(secret.ptr),
            .Persist = CRED_PERSIST_LOCAL_MACHINE,
            .AttributeCount = 0,
            .Attributes = null,
            .TargetAlias = null,
            .UserName = user.ptr,
        };
        if (CredWriteW(&cred, 0) == 0) return error.Backend;
    }

    fn delete(gpa: std.mem.Allocator, service: []const u8, account: []const u8) Error!bool {
        const target = try targetName(gpa, service, account);
        defer gpa.free(target);
        if (CredDeleteW(target.ptr, CRED_TYPE_GENERIC, 0) == 0) {
            if (@intFromEnum(windows.GetLastError()) == ERROR_NOT_FOUND) return false;
            return error.Backend;
        }
        return true;
    }
};

// --- macOS: Keychain Services (legacy generic-password API) ------------------

const Macos = struct {
    const OSStatus = i32;
    const errSecSuccess: OSStatus = 0;
    const errSecDuplicateItem: OSStatus = -25299;
    const errSecItemNotFound: OSStatus = -25300;

    extern fn SecKeychainAddGenericPassword(
        keychain: ?*anyopaque,
        serviceNameLength: u32,
        serviceName: [*]const u8,
        accountNameLength: u32,
        accountName: [*]const u8,
        passwordLength: u32,
        passwordData: [*]const u8,
        itemRef: ?*?*anyopaque,
    ) callconv(.c) OSStatus;

    extern fn SecKeychainFindGenericPassword(
        keychainOrArray: ?*anyopaque,
        serviceNameLength: u32,
        serviceName: [*]const u8,
        accountNameLength: u32,
        accountName: [*]const u8,
        passwordLength: ?*u32,
        passwordData: ?*?[*]u8,
        itemRef: ?*?*anyopaque,
    ) callconv(.c) OSStatus;

    extern fn SecKeychainItemModifyContent(itemRef: *anyopaque, attrList: ?*anyopaque, length: u32, data: [*]const u8) callconv(.c) OSStatus;
    extern fn SecKeychainItemDelete(itemRef: *anyopaque) callconv(.c) OSStatus;
    extern fn SecKeychainItemFreeContent(attrList: ?*anyopaque, data: ?*anyopaque) callconv(.c) OSStatus;
    extern fn CFRelease(cf: *anyopaque) callconv(.c) void;

    fn load(gpa: std.mem.Allocator, service: []const u8, account: []const u8) Error!?[]u8 {
        var len: u32 = 0;
        var data: ?[*]u8 = null;
        const status = SecKeychainFindGenericPassword(
            null,
            @intCast(service.len),
            service.ptr,
            @intCast(account.len),
            account.ptr,
            &len,
            &data,
            null,
        );
        if (status == errSecItemNotFound) return null;
        if (status != errSecSuccess) return error.Backend;
        const ptr = data orelse return try gpa.dupe(u8, "");
        defer _ = SecKeychainItemFreeContent(null, @ptrCast(ptr));
        return try gpa.dupe(u8, ptr[0..len]);
    }

    fn save(gpa: std.mem.Allocator, service: []const u8, account: []const u8, secret: []const u8) Error!void {
        _ = gpa;
        const add = SecKeychainAddGenericPassword(
            null,
            @intCast(service.len),
            service.ptr,
            @intCast(account.len),
            account.ptr,
            @intCast(secret.len),
            secret.ptr,
            null,
        );
        if (add == errSecSuccess) return;
        if (add != errSecDuplicateItem) return error.Backend;

        // Already present: locate the item and overwrite its contents.
        var item: ?*anyopaque = null;
        const found = SecKeychainFindGenericPassword(
            null,
            @intCast(service.len),
            service.ptr,
            @intCast(account.len),
            account.ptr,
            null,
            null,
            &item,
        );
        if (found != errSecSuccess) return error.Backend;
        const item_ref = item orelse return error.Backend;
        defer CFRelease(item_ref);
        if (SecKeychainItemModifyContent(item_ref, null, @intCast(secret.len), secret.ptr) != errSecSuccess) {
            return error.Backend;
        }
    }

    fn delete(gpa: std.mem.Allocator, service: []const u8, account: []const u8) Error!bool {
        _ = gpa;
        var item: ?*anyopaque = null;
        const found = SecKeychainFindGenericPassword(
            null,
            @intCast(service.len),
            service.ptr,
            @intCast(account.len),
            account.ptr,
            null,
            null,
            &item,
        );
        if (found == errSecItemNotFound) return false;
        if (found != errSecSuccess) return error.Backend;
        const item_ref = item orelse return false;
        defer CFRelease(item_ref);
        if (SecKeychainItemDelete(item_ref) != errSecSuccess) return error.Backend;
        return true;
    }
};

test "keyring round-trips a secret on supported platforms" {
    const gpa = std.testing.allocator;
    const service = "Nova Test";
    const account = "cli|keyringtest0";

    // Clean any leftover from a previous aborted run.
    _ = delete(gpa, service, account) catch {};

    save(gpa, service, account, "hello-secret") catch |err| switch (err) {
        // No backend in CI/headless — nothing to verify here.
        error.Unsupported, error.Backend => return,
        else => return err,
    };

    const loaded = (try load(gpa, service, account)) orelse return error.TestUnexpectedResult;
    defer gpa.free(loaded);
    try std.testing.expectEqualStrings("hello-secret", loaded);

    // Upsert replaces, not appends.
    try save(gpa, service, account, "second");
    const again = (try load(gpa, service, account)) orelse return error.TestUnexpectedResult;
    defer gpa.free(again);
    try std.testing.expectEqualStrings("second", again);

    try std.testing.expect(try delete(gpa, service, account));
    try std.testing.expect((try load(gpa, service, account)) == null);
}

// --- Mock Backends for Testing -----------------------------------------------

const MockBackend = struct {
    var storage: std.StringArrayHashMapUnmanaged([]u8) = .empty;

    fn reset(gpa: std.mem.Allocator) void {
        var it = storage.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        storage.deinit(gpa);
        storage = .empty;
    }

    fn makeKey(gpa: std.mem.Allocator, service: []const u8, account: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}:{s}", .{ service, account });
    }

    fn load(gpa: std.mem.Allocator, service: []const u8, account: []const u8) Error!?[]u8 {
        const key = try makeKey(gpa, service, account);
        defer gpa.free(key);
        if (storage.get(key)) |val| {
            return try gpa.dupe(u8, val);
        }
        return null;
    }

    fn save(gpa: std.mem.Allocator, service: []const u8, account: []const u8, secret: []const u8) Error!void {
        const key = try makeKey(gpa, service, account);
        defer gpa.free(key);
        if (storage.fetchOrderedRemove(key)) |kv| {
            gpa.free(kv.key);
            gpa.free(kv.value);
        }
        const owned_key = try gpa.dupe(u8, key);
        errdefer gpa.free(owned_key);
        const owned_val = try gpa.dupe(u8, secret);
        errdefer gpa.free(owned_val);
        try storage.put(gpa, owned_key, owned_val);
    }

    fn delete(gpa: std.mem.Allocator, service: []const u8, account: []const u8) Error!bool {
        const key = try makeKey(gpa, service, account);
        defer gpa.free(key);
        if (storage.fetchOrderedRemove(key)) |kv| {
            gpa.free(kv.key);
            gpa.free(kv.value);
            return true;
        }
        return false;
    }
};

const FailureMockBackend = struct {
    fn load(_: std.mem.Allocator, _: []const u8, _: []const u8) Error!?[]u8 {
        return error.Backend;
    }
    fn save(_: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8) Error!void {
        return error.Backend;
    }
    fn delete(_: std.mem.Allocator, _: []const u8, _: []const u8) Error!bool {
        return error.Backend;
    }
};

test "returnsErrorUnsupported_whenBackendIsUnsupported" {
    // Arrange
    const gpa = std.testing.allocator;

    // Act & Assert
    try std.testing.expectError(error.Unsupported, loadImpl(Unsupported, gpa, "Nova", "user1"));
    try std.testing.expectError(error.Unsupported, saveImpl(Unsupported, gpa, "Nova", "user1", "secret"));
    try std.testing.expectError(error.Unsupported, deleteImpl(Unsupported, gpa, "Nova", "user1"));
}

test "returnsNull_whenNoSecretExists" {
    // Arrange
    const gpa = std.testing.allocator;
    MockBackend.reset(gpa);
    defer MockBackend.reset(gpa);

    // Act
    const result = try loadImpl(MockBackend, gpa, "Nova", "nonexistent");

    // Assert
    try std.testing.expectEqual(@as(?[]u8, null), result);
}

test "returnsSecret_whenEntryExists" {
    // Arrange
    const gpa = std.testing.allocator;
    MockBackend.reset(gpa);
    defer MockBackend.reset(gpa);
    try saveImpl(MockBackend, gpa, "Nova", "user1", "secret123");

    // Act
    const loaded = try loadImpl(MockBackend, gpa, "Nova", "user1");

    // Assert
    try std.testing.expect(loaded != null);
    defer gpa.free(loaded.?);
    try std.testing.expectEqualStrings("secret123", loaded.?);
}

test "overwritesSecret_whenEntryAlreadyExists" {
    // Arrange
    const gpa = std.testing.allocator;
    MockBackend.reset(gpa);
    defer MockBackend.reset(gpa);
    try saveImpl(MockBackend, gpa, "Nova", "user1", "initial_secret");

    // Act
    try saveImpl(MockBackend, gpa, "Nova", "user1", "updated_secret");
    const loaded = try loadImpl(MockBackend, gpa, "Nova", "user1");

    // Assert
    try std.testing.expect(loaded != null);
    defer gpa.free(loaded.?);
    try std.testing.expectEqualStrings("updated_secret", loaded.?);
}

test "deletesEntry_andReturnsNullOnSubsequentLoad" {
    // Arrange
    const gpa = std.testing.allocator;
    MockBackend.reset(gpa);
    defer MockBackend.reset(gpa);
    try saveImpl(MockBackend, gpa, "Nova", "user1", "secret_to_delete");

    // Act
    const deleted = try deleteImpl(MockBackend, gpa, "Nova", "user1");
    const loaded = try loadImpl(MockBackend, gpa, "Nova", "user1");

    // Assert
    try std.testing.expect(deleted);
    try std.testing.expectEqual(@as(?[]u8, null), loaded);

    // Deleting again returns false
    const delete_again = try deleteImpl(MockBackend, gpa, "Nova", "user1");
    try std.testing.expect(!delete_again);
}

test "returnsError_whenBackendFails" {
    // Arrange
    const gpa = std.testing.allocator;

    // Act & Assert
    try std.testing.expectError(error.Backend, loadImpl(FailureMockBackend, gpa, "Nova", "user1"));
    try std.testing.expectError(error.Backend, saveImpl(FailureMockBackend, gpa, "Nova", "user1", "secret"));
    try std.testing.expectError(error.Backend, deleteImpl(FailureMockBackend, gpa, "Nova", "user1"));
}

test "formatsWindowsTargetName_asUtf16LeWithColon" {
    // Arrange
    const gpa = std.testing.allocator;

    // Act
    const target = try Windows.targetName(gpa, "Nova", "account1");
    defer gpa.free(target);

    // Assert: UTF-16 representation of "Nova:account1"
    const expected_utf8 = "Nova:account1";
    const expected_utf16 = try std.unicode.utf8ToUtf16LeAllocZ(gpa, expected_utf8);
    defer gpa.free(expected_utf16);

    try std.testing.expectEqualSlices(u16, expected_utf16, target);
}

test "rejectsOversizedSecret_onWindowsSave" {
    if (comptime !os.is_windows) return;
    // Arrange
    const gpa = std.testing.allocator;
    const oversized_secret = try gpa.alloc(u8, Windows.max_blob_bytes + 1);
    defer gpa.free(oversized_secret);
    @memset(oversized_secret, 'x');

    // Act & Assert
    try std.testing.expectError(error.Backend, saveImpl(Windows, gpa, "Nova", "account1", oversized_secret));
}
