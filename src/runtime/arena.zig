//! Native arena runtime for the LLVM backend.
//!
//! Implements the `__arena_*` ABI that `std/mem.lls` calls — the same names the
//! bytecode VM wires to `src/vm/builtins/mem.zig` — but with native semantics:
//! an allocation returns a raw, zeroed pointer owned by the arena, and
//! `__arena_deinit` frees every chunk the arena ever handed out. This is what
//! lets `@new(allocator, value)` in LLVM-emitted programs reclaim memory via
//! `arena.deinit()` instead of leaking a raw `malloc`.
//!
//! Handle model: `__arena_create` returns an opaque i64 (the address of the
//! arena control block). The source-language `Arena { handle: int }` just
//! carries that value, so passing it back into `__arena_alloc*` round-trips.
//!
//! Chunk model mirrors the VM: a bump arena with a linked chunk list and
//! ~1.5× growth (Zig ArenaAllocator-style). `__arena_reset` rewinds every
//! chunk and resumes at the first (retain capacity).

const std = @import("std");

/// First-chunk byte capacity when the caller passes 0 (the VM's "small
/// default" sized in bytes for the native runtime; not a hard cap).
const DEFAULT_CHUNK: usize = 1024;
/// Alignment for arena payloads (covers i64 / double / pointers).
const ALIGN: usize = 16;

const Chunk = struct {
    next: ?*Chunk,
    used: usize,
    cap: usize,

    fn payload(self: *Chunk) [*]u8 {
        return @as([*]u8, @ptrCast(self)) + @sizeOf(Chunk);
    }
};

const Arena = struct {
    alive: bool,
    first: *Chunk,
    current: *Chunk,
    last_cap: usize,
};

// Use libc malloc/free directly so the runtime object links into the clang
// binary without pulling in Zig's libc startup.
extern "c" fn malloc(size: usize) ?*anyopaque;
extern "c" fn free(ptr: ?*anyopaque) void;

fn fromHandle(handle: i64) ?*Arena {
    if (handle == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(handle)));
}

fn makeChunk(cap: usize) ?*Chunk {
    const raw = malloc(@sizeOf(Chunk) + cap) orelse return null;
    const chunk: *Chunk = @ptrCast(@alignCast(raw));
    chunk.* = .{ .next = null, .used = 0, .cap = cap };
    return chunk;
}

fn arenaAlloc(a: *Arena, n: usize) ?[*]u8 {
    const cur = a.current;
    if (cur.used + n <= cur.cap) {
        const p = cur.payload() + cur.used;
        cur.used += n;
        return p;
    }
    // Grow: new chunk ≥ max(n, 1.5× last cap), like Zig ArenaAllocator.
    const grown = a.last_cap + a.last_cap / 2;
    const new_cap = @max(n, @max(grown, DEFAULT_CHUNK));
    const chunk = makeChunk(new_cap) orelse return null;
    cur.next = chunk;
    a.current = chunk;
    a.last_cap = new_cap;
    chunk.used = n;
    return chunk.payload();
}

fn allocAndZero(a: *Arena, n: usize) ?[*]u8 {
    const p = arenaAlloc(a, n) orelse return null;
    @memset(p[0..n], 0);
    return p;
}

/// Create an arena. `initial_hint` = first chunk capacity in bytes
/// (0 picks the default). Returns the opaque handle, or 0 on OOM.
export fn __arena_create(initial_hint: i64) i64 {
    const hint: usize = if (initial_hint <= 0) DEFAULT_CHUNK else @intCast(initial_hint);
    const raw = malloc(@sizeOf(Arena)) orelse return 0;
    const arena: *Arena = @ptrCast(@alignCast(raw));
    const chunk = makeChunk(hint) orelse {
        free(raw);
        return 0;
    };
    arena.* = .{ .alive = true, .first = chunk, .current = chunk, .last_cap = hint };
    return @intCast(@intFromPtr(arena));
}

/// Bump-allocate `n` bytes in the arena (raw pointer, zeroed).
/// Mirrors the VM's `__arena_alloc` (value-slot allocation) with native types.
export fn __arena_alloc(handle: i64, n: i64) ?[*]u8 {
    const a = fromHandle(handle) orelse return null;
    if (!a.alive) return null;
    const size: usize = if (n <= 0) 1 else @intCast(n);
    return allocAndZero(a, size);
}

/// Byte-payload allocation — what `@new(allocator, …)` lowers to.
/// Returns a raw pointer (not a VM byte-offset handle).
export fn __arena_alloc_bytes(handle: i64, n: i64) ?[*]u8 {
    return __arena_alloc(handle, n);
}

/// Rewind every chunk watermark and resume at the first chunk
/// (retain capacity — matches `Arena.reset()` semantics).
export fn __arena_reset(handle: i64) void {
    const a = fromHandle(handle) orelse return;
    if (!a.alive) return;
    var chunk: ?*Chunk = a.first;
    while (chunk) |c| {
        c.used = 0;
        chunk = c.next;
    }
    a.current = a.first;
}

/// Free every chunk and the control block; mark the arena dead so further
/// allocations fail (matches the VM's `__arena_deinit`).
export fn __arena_deinit(handle: i64) void {
    const a = fromHandle(handle) orelse return;
    if (!a.alive) return;
    a.alive = false;
    var chunk: ?*Chunk = a.first;
    while (chunk) |c| {
        const next = c.next;
        free(c);
        chunk = next;
    }
    free(a);
}
