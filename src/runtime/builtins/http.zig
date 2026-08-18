//! LLTS native HTTP functions — mirrors `src/vm/builtins/http.zig`.
//!
//! `__fetch(url, method, body)` performs an HTTP request using libcurl and
//! returns a handle (i64 pointer) to a `ResponseRecord` that carries
//! `status` and `body` fields.  On failure it returns an error value via
//! `util.errNew`.

const std = @import("std");
const util = @import("util.zig");

const dupBytes = util.dupBytes;
const cstr = util.cstr;

const c = @cImport({
    @cInclude("curl/curl.h");
});

// ─────────────────────────── response record ──────────────────────────────

pub const ResponseRecord = extern struct {
    status: i64,
    body: [*:0]const u8,
};

// ─────────────────────────── curl write callback ──────────────────────────

const WriteCtx = struct {
    buf: *std.ArrayList(u8),
};

fn writeCallback(ptr: ?*anyopaque, size: c_uint, nmemb: c_uint, userp: ?*anyopaque) callconv(.c) c_uint {
    const real_size: usize = @as(usize, size) * @as(usize, nmemb);
    if (real_size == 0 or ptr == null or userp == null) return 0;
    const ctx: *WriteCtx = @ptrCast(@alignCast(userp.?));
    const data: [*]const u8 = @ptrCast(ptr.?);
    ctx.buf.appendSlice(std.heap.page_allocator, data[0..real_size]) catch return 0;
    return @intCast(real_size);
}

// ─────────────────────────── export fn ────────────────────────────────────

export fn __fetch(url_ptr: [*:0]const u8, method_ptr: [*:0]const u8, body_ptr: ?[*:0]const u8) i64 {
    const alloc = std.heap.page_allocator;
    var url_buf: std.ArrayList(u8) = .empty;
    defer url_buf.deinit(alloc);
    url_buf.appendSlice(alloc, cstr(url_ptr)) catch return util.errNew(dupBytes("HttpError"), 0);

    var method_buf: std.ArrayList(u8) = .empty;
    defer method_buf.deinit(alloc);
    method_buf.appendSlice(alloc, cstr(method_ptr)) catch {};

    var body_buf: std.ArrayList(u8) = .empty;
    defer body_buf.deinit(alloc);
    if (body_ptr) |bp| {
        body_buf.appendSlice(alloc, cstr(bp)) catch {};
    }

    // Init curl
    const curl = c.curl_easy_init() orelse {
        return util.errNew(dupBytes("HttpError"), 0);
    };
    defer c.curl_easy_cleanup(curl);

    // URL — need NUL-terminated
    const url_z: [*:0]const u8 = alloc.dupeZ(u8, url_buf.items) catch return util.errNew(dupBytes("HttpError"), 0);
    _ = c.curl_easy_setopt(curl, c.CURLOPT_URL, url_z);

    // Method
    const method_str = method_buf.items;
    if (std.mem.eql(u8, method_str, "POST")) {
        _ = c.curl_easy_setopt(curl, c.CURLOPT_POST, @as(c_long, 1));
    } else if (std.mem.eql(u8, method_str, "PUT")) {
        _ = c.curl_easy_setopt(curl, c.CURLOPT_CUSTOMREQUEST, "PUT");
    } else if (std.mem.eql(u8, method_str, "DELETE")) {
        _ = c.curl_easy_setopt(curl, c.CURLOPT_CUSTOMREQUEST, "DELETE");
    } else if (std.mem.eql(u8, method_str, "PATCH")) {
        _ = c.curl_easy_setopt(curl, c.CURLOPT_CUSTOMREQUEST, "PATCH");
    } else {
        _ = c.curl_easy_setopt(curl, c.CURLOPT_HTTPGET, @as(c_long, 1));
    }

    // Body
    if (body_buf.items.len > 0) {
        _ = c.curl_easy_setopt(curl, c.CURLOPT_POSTFIELDS, body_buf.items.ptr);
        _ = c.curl_easy_setopt(curl, c.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body_buf.items.len)));
    }

    // Response body
    var resp_buf: std.ArrayList(u8) = .empty;
    defer resp_buf.deinit(alloc);
    var ctx = WriteCtx{ .buf = &resp_buf };
    _ = c.curl_easy_setopt(curl, c.CURLOPT_WRITEFUNCTION, &writeCallback);
    _ = c.curl_easy_setopt(curl, c.CURLOPT_WRITEDATA, &ctx);

    // Follow redirects
    _ = c.curl_easy_setopt(curl, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));

    // Perform
    const res = c.curl_easy_perform(curl);
    if (res != c.CURLE_OK) {
        const err_name: [*:0]const u8 = c.curl_easy_strerror(res);
        return util.errNew(dupBytes("HttpError"), @intFromPtr(dupBytes(cstr(err_name))));
    }

    // Status code
    var status_code: c_long = 0;
    _ = c.curl_easy_getinfo(curl, c.CURLINFO_RESPONSE_CODE, &status_code);

    // Allocate response record
    const alloc2 = util.strAlloc();
    const rec: *ResponseRecord = alloc2.create(ResponseRecord) catch {
        return util.errNew(dupBytes("HttpError"), 0);
    };
    rec.* = .{
        .status = @intCast(status_code),
        .body = dupBytes(resp_buf.items),
    };
    return @intCast(@intFromPtr(rec));
}
