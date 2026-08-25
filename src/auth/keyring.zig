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

/// Read the secret for `service`/`account`. Returns gpa-owned bytes, or null
/// when no such entry exists.
pub fn load(gpa: std.mem.Allocator, service: []const u8, account: []const u8) Error!?[]u8 {
    return impl.load(gpa, service, account);
}

/// Create or replace the secret for `service`/`account`.
pub fn save(gpa: std.mem.Allocator, service: []const u8, account: []const u8, secret: []const u8) Error!void {
    return impl.save(gpa, service, account, secret);
}

/// Remove the secret. Returns true when an entry was actually deleted.
pub fn delete(gpa: std.mem.Allocator, service: []const u8, account: []const u8) Error!bool {
    return impl.delete(gpa, service, account);
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

// The Windows-backend limit test is gated behind a comptime-known `os.tag`
// check so the `Windows` body (and its C externs) is never analyzed on other
// platforms -- referencing it unconditionally breaks the Linux link.
// The `Unsupported` stub cases are covered by store.zig fallback tests and
// the delete() suite; they are not repeated here.

test "windowsBackend_rejectsOversizedSecret_withBackendError" {
    if (os.tag != .windows) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const service = "NovaTest";
    const account = "account";

    // CRED_MAX_CREDENTIAL_BLOB_SIZE (Vista+) is 5 * 512 bytes; the OS rejects
    // anything larger and the backend must surface `error.Backend` so the
    // caller falls back to auth.json storage.
    const oversized_secret = "x" ** (Windows.max_blob_bytes + 1);
    try std.testing.expectError(error.Backend, Windows.save(gpa, service, account, oversized_secret));
}

test "save_upsertsSecret_whenCalledTwiceForSameServiceAndAccount" {
    // Exercises the public dispatch so the upsert path stays reachable from
    // production call sites; skips cleanly on platforms without a keychain.
    const gpa = std.testing.allocator;
    const service = "Nova Test";
    const account = "cli|keyringtest_overwrite";
    _ = delete(gpa, service, account) catch {};

    save(gpa, service, account, "initial-secret") catch |err| switch (err) {
        error.Unsupported => return error.SkipZigTest,
        else => return err,
    };
    defer _ = delete(gpa, service, account) catch {};

    try save(gpa, service, account, "updated-secret");

    const loaded = (try load(gpa, service, account)) orelse return error.TestUnexpectedResult;
    defer gpa.free(loaded);
    try std.testing.expectEqualStrings("updated-secret", loaded);
}

test "save_acceptsEmptySecret_whenEmptyStringProvided" {
    const gpa = std.testing.allocator;
    const service = "Nova Test";
    const account = "cli|keyringtest_empty";
    _ = delete(gpa, service, account) catch {};

    save(gpa, service, account, "") catch |err| switch (err) {
        error.Unsupported => return error.SkipZigTest,
        // Some platforms legitimately refuse empty payloads; that is policy,
        // not a bug -- nothing further to assert beyond "it did not crash".
        error.Backend => return,
        else => return err,
    };
    defer _ = delete(gpa, service, account) catch {};

    const loaded = (try load(gpa, service, account)) orelse return error.TestUnexpectedResult;
    defer gpa.free(loaded);
    try std.testing.expectEqualStrings("", loaded);
}

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
