//! URI utilities for the LSP: conversion between `file://` URIs and local
//! filesystem paths, shared by every handler that touches a document.
//!
//! Handles what clients actually send:
//! - percent-encoded characters in paths and hosts (`%20`, `%3A`)
//! - lowercase/uppercase hex digits
//! - Windows drive letters (`file:///C:/...` → `C:\...`)
//! - `localhost` and empty hosts (ignored)
//!
//! Only `file` scheme URIs are accepted; other schemes are an error since
//! the server cannot read or write them.

const std = @import("std");
const builtin = @import("builtin");

pub const UriError = error{
    InvalidUri,
    UnsupportedScheme,
    OutOfMemory,
};

/// Convert a `file://` URI to a filesystem path.
/// `file:///a/b%20c.lls` → `/a/b c.lls`
/// `file:///C:/x/y.lls` → `C:\x\y.lls` (Windows)
pub fn uriToPath(allocator: std.mem.Allocator, uri: []const u8) UriError![]u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) {
        // Tolerate bare paths (some clients send them): treat as already decoded.
        if (uri.len > 0 and uri[0] == '/') {
            return decodePercent(allocator, uri);
        }
        return error.InvalidUri;
    }

    var rest = uri["file://".len..];

    // Skip the authority (host). Language servers conventionally ignore it:
    // an empty host (file:///...) and "localhost" are equivalent to the local
    // machine, and remote-style hosts are dropped rather than rejected so
    // clients that produce them still work on local files.
    const authority_end = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidUri;
    rest = rest[authority_end..];

    const decoded = try decodePercent(allocator, rest);
    errdefer allocator.free(decoded);

    if (is_windows) {
        return windowsPath(allocator, decoded) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidUri,
        };
    }
    return decoded;
}

/// Convert a filesystem path to a `file://` URI.
/// `/a/b c.lls` → `file:///a/b%20c.lls`
/// `C:\x\y.lls` → `file:///C:/x/y.lls` (Windows)
pub fn pathToUri(allocator: std.mem.Allocator, path: []const u8) UriError![]u8 {
    if (path.len == 0) return error.InvalidUri;

    if (is_windows and path.len >= 2 and path[1] == ':') {
        // Drive-letter path: C:\x\y.lls → file:///C:/x/y.lls
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, "file:///");
        try out.append(allocator, path[0]);
        try out.appendSlice(allocator, ":");
        for (path[2..]) |c| {
            try appendEncoded(allocator, &out, if (c == '\\') '/' else c);
        }
        return out.toOwnedSlice(allocator);
    }

    if (path[0] != '/') return error.InvalidUri;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "file://");
    for (path) |c| {
        try appendEncoded(allocator, &out, c);
    }
    return out.toOwnedSlice(allocator);
}

const is_windows = builtin.os.tag == .windows;

/// Decode %XX sequences in place; other bytes pass through unchanged.
/// Malformed escapes (e.g. `%G1` or a trailing `%`) are an error rather
/// than being copied literally, so callers never see ambiguous paths.
fn decodePercent(allocator: std.mem.Allocator, input: []const u8) UriError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c == '%') {
            if (i + 2 >= input.len) return error.InvalidUri;
            const hi = hexVal(input[i + 1]) orelse return error.InvalidUri;
            const lo = hexVal(input[i + 2]) orelse return error.InvalidUri;
            try out.append(allocator, @intCast(hi * 16 + lo));
            i += 3;
        } else {
            try out.append(allocator, c);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn hexVal(c: u8) ?u32 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Encode a path byte for use in a `file://` URI. `/` stays literal;
/// ASCII unreserved characters (RFC 3986) stay literal; everything else
/// (spaces, non-ASCII, `#`, `?`, ...) is percent-encoded.
fn appendEncoded(allocator: std.mem.Allocator, out: *std.ArrayList(u8), c: u8) !void {
    const unreserved = (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '.' or c == '_' or c == '~';
    if (c == '/' or unreserved) {
        try out.append(allocator, c);
    } else {
        var buf: [3]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "%{X:0>2}", .{c}) catch unreachable;
        try out.appendSlice(allocator, &buf);
    }
}

/// On Windows, `/C:/x/y` → `C:\x\y`. No-op elsewhere.
fn windowsPath(allocator: std.mem.Allocator, decoded: []const u8) ![]u8 {
    if (decoded.len >= 3 and decoded[0] == '/' and decoded[2] == ':') {
        const without_slash = decoded[1..];
        const replaced = try allocator.dupe(u8, without_slash);
        for (replaced) |*c| {
            if (c.* == '/') c.* = '\\';
        }
        return replaced;
    }
    return allocator.dupe(u8, decoded);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "roundtrip simple path" {
    const uri = try pathToUri(testing.allocator, "/a/b.lls");
    defer testing.allocator.free(uri);
    try testing.expectEqualStrings("file:///a/b.lls", uri);

    const path = try uriToPath(testing.allocator, uri);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/a/b.lls", path);
}

test "roundtrip path with spaces" {
    const path = "/home/user/my project/src/main.lls";
    const uri = try pathToUri(testing.allocator, path);
    defer testing.allocator.free(uri);
    try testing.expectEqualStrings("file:///home/user/my%20project/src/main.lls", uri);

    const back = try uriToPath(testing.allocator, uri);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings(path, back);
}

test "encode special characters" {
    // '#' and '?' are fragment/query delimiters in URIs and must be escaped.
    const uri = try pathToUri(testing.allocator, "/a b/c#d?e.lls");
    defer testing.allocator.free(uri);
    try testing.expectEqualStrings("file:///a%20b/c%23d%3Fe.lls", uri);
}

test "decode uppercase and lowercase hex" {
    const path = try uriToPath(testing.allocator, "file:///a%2Bb%2bc.lls");
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/a+b+c.lls", path);
}

test "decode pre-encoded uri with percent and tilde" {
    const path = try uriToPath(testing.allocator, "file:///home/u%20ser/~w/test.lls");
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/home/u ser/~w/test.lls", path);
}

test "localhost authority is dropped" {
    const path = try uriToPath(testing.allocator, "file://localhost/x/y.lls");
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/x/y.lls", path);
}

test "bare absolute path is tolerated" {
    const path = try uriToPath(testing.allocator, "/plain/path.lls");
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/plain/path.lls", path);
}

test "malformed escapes are errors" {
    try testing.expectError(error.InvalidUri, uriToPath(testing.allocator, "file:///a%2.lls"));
    try testing.expectError(error.InvalidUri, uriToPath(testing.allocator, "file:///a%GGb.lls"));
    try testing.expectError(error.InvalidUri, uriToPath(testing.allocator, "file:///a%2"));
}

test "truncated and non-file uris are errors" {
    try testing.expectError(error.InvalidUri, uriToPath(testing.allocator, "file://"));
    try testing.expectError(error.InvalidUri, uriToPath(testing.allocator, "file://only-host"));
    try testing.expectError(error.InvalidUri, uriToPath(testing.allocator, "http:///x.lls"));
    try testing.expectError(error.InvalidUri, uriToPath(testing.allocator, "relative/path.lls"));
    try testing.expectError(error.InvalidUri, uriToPath(testing.allocator, ""));
    try testing.expectError(error.InvalidUri, pathToUri(testing.allocator, ""));
    try testing.expectError(error.InvalidUri, pathToUri(testing.allocator, "relative/path.lls"));
}

test "root uri decodes to root path" {
    // `file:///` is the filesystem root, not an empty path.
    const path = try uriToPath(testing.allocator, "file:///");
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/", path);
}

test "unicode filename roundtrip" {
    const path = "/home/user/über-dïr/naïve.lls";
    const uri = try pathToUri(testing.allocator, path);
    defer testing.allocator.free(uri);
    const back = try uriToPath(testing.allocator, uri);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings(path, back);
}
