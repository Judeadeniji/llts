//! Memory primitives — the native counterparts to the VM heap builtins.
//!
//! Allocation sites are chosen from `src/compiler/value_clone.zig`'s copy
//! classification: `[]byte` assignment deep-copies (like `__cloneBytes`),
//! strings share immutable views, arrays deep-copy via Zig value semantics or
//! emitter-driven recursion (like `__cloneArray` minus the VM's shallow
//! inner-handle share, which is a VM bug we do not carry over).

const std = @import("std");
const Context = @import("context.zig").Context;

/// Deep copy of a byte span into the frame buffer — `[]byte` value semantics
/// on assignment (`__cloneBytes` parity).
pub fn cloneBytes(ctx: *Context, src: []const u8) error{OutOfMemory}![]u8 {
    const dst = try ctx.allocFrame(src.len, 1);
    @memcpy(dst, src);
    return dst;
}

/// Copy a byte span into the immortal buffer — string literals materialised
/// at runtime (concat operands, `@as(string, …)` conversions).
pub fn cloneBytesImmortal(ctx: *Context, src: []const u8) error{OutOfMemory}![]u8 {
    const dst = try ctx.allocImmortal(src.len, 1);
    @memcpy(dst, src);
    return dst;
}

/// Shallow-copy an array's backing bytes into the frame buffer
/// (`__cloneArray` parity for scalar element types; the emitter recurses for
/// nested arrays/structs so the overall copy is deep).
pub fn cloneArrayBytes(ctx: *Context, src: []const u8) error{OutOfMemory}![]u8 {
    const dst = try ctx.allocFrame(src.len, 1);
    @memcpy(dst, src);
    return dst;
}

/// Allocate backing storage for a runtime-sized array of `count` elements of
/// `elem_size` bytes (aligned to `elem_align`). No header: the length lives in
/// the slice the emitter builds around this buffer.
pub fn allocArray(
    ctx: *Context,
    count: usize,
    elem_size: usize,
    elem_align: usize,
) error{OutOfMemory}![]u8 {
    const len = std.math.mul(usize, count, elem_size) catch return error.OutOfMemory;
    return ctx.allocFrame(len, elem_align);
}

/// Concatenate two string views into the immortal buffer — `stringAdd`
/// parity (VM marks concatenation as immortal growth, so results survive
/// frame exits).
pub fn concat(ctx: *Context, a: []const u8, b: []const u8) error{OutOfMemory}![]const u8 {
    const total = std.math.add(usize, a.len, b.len) catch return error.OutOfMemory;
    const dst = try ctx.allocImmortal(total, 1);
    @memcpy(dst[0..a.len], a);
    @memcpy(dst[a.len..], b);
    return dst;
}
