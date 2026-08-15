const std = @import("std");
const scan = @import("../../bytecode/scan.zig");
const chunk_mod = @import("../../bytecode/chunk.zig");
const state_mod = @import("../state.zig");
const print_mod = @import("print.zig");
const print_ln_mod = @import("print_ln.zig");
const len_mod = @import("len.zig");
const mem_mod = @import("mem.zig");
const math_mod = @import("math.zig");
const string_mod = @import("string.zig");
const io_mod = @import("io.zig");
const time_mod = @import("time.zig");
const os_mod = @import("os.zig");
const syscall_mod = @import("syscall.zig");
const http_mod = @import("http.zig");
const json_mod = @import("json_builtin.zig");
const list_mod = @import("list.zig");
const map_mod = @import("map.zig");
const buffer_mod = @import("buffer.zig");
const log_mod = @import("log.zig");

const VMState = state_mod.VMState;
const Chunk = chunk_mod.Chunk;

const Module = enum {
    print,
    print_ln,
    log,
    len,
    mem,
    math,
    string,
    io,
    time,
    os,
    syscall,
    http,
    json,
    list,
    map,
    buffer,
};

fn wants(needed: *const std.StringHashMap(void), comptime prefixes: []const []const u8, comptime exact: []const []const u8) bool {
    var it = needed.keyIterator();
    while (it.next()) |name| {
        inline for (exact) |e| {
            if (std.mem.eql(u8, name.*, e)) return true;
        }
        inline for (prefixes) |p| {
            if (std.mem.startsWith(u8, name.*, p)) return true;
        }
    }
    return false;
}

fn isMathGlobal(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "__")) {
        return std.mem.eql(u8, name, "HUGE_VAL") or
            std.mem.eql(u8, name, "INFINITY") or
            std.mem.eql(u8, name, "NAN") or
            std.mem.startsWith(u8, name, "FP_") or
            std.mem.startsWith(u8, name, "MATH_") or
            std.mem.eql(u8, name, "math_errhandling");
    }
    if (std.mem.startsWith(u8, name, "__host")) return false;
    if (std.mem.startsWith(u8, name, "__print")) return false;
    if (std.mem.startsWith(u8, name, "__sys")) return false;
    if (std.mem.startsWith(u8, name, "__SYS_")) return false;
    if (std.mem.eql(u8, name, "__syscall")) return false;
    if (std.mem.startsWith(u8, name, "__buffer")) return false;
    if (std.mem.startsWith(u8, name, "__list")) return false;
    if (std.mem.startsWith(u8, name, "__map")) return false;
    if (std.mem.startsWith(u8, name, "__json")) return false;
    if (std.mem.startsWith(u8, name, "__fetch")) return false;
    if (std.mem.startsWith(u8, name, "__read")) return false;
    if (std.mem.startsWith(u8, name, "__write")) return false;
    if (std.mem.startsWith(u8, name, "__append")) return false;
    if (std.mem.startsWith(u8, name, "__delete")) return false;
    if (std.mem.startsWith(u8, name, "__exists")) return false;
    if (std.mem.startsWith(u8, name, "__mkdir")) return false;
    if (std.mem.startsWith(u8, name, "__stat")) return false;
    if (std.mem.startsWith(u8, name, "__rename")) return false;
    if (std.mem.startsWith(u8, name, "__copy")) return false;
    if (std.mem.startsWith(u8, name, "__symlink")) return false;
    if (std.mem.startsWith(u8, name, "__readlink")) return false;
    if (std.mem.startsWith(u8, name, "__realpath")) return false;
    if (std.mem.startsWith(u8, name, "__chmod")) return false;
    if (std.mem.startsWith(u8, name, "__now")) return false;
    if (std.mem.startsWith(u8, name, "__sleep")) return false;
    if (std.mem.startsWith(u8, name, "__exec")) return false;
    if (std.mem.startsWith(u8, name, "__getEnv")) return false;
    if (std.mem.startsWith(u8, name, "__setEnv")) return false;
    if (std.mem.startsWith(u8, name, "__exit")) return false;
    if (std.mem.startsWith(u8, name, "__cwd")) return false;
    if (std.mem.startsWith(u8, name, "__chdir")) return false;
    if (std.mem.startsWith(u8, name, "__pid")) return false;
    if (std.mem.startsWith(u8, name, "__args")) return false;
    if (std.mem.startsWith(u8, name, "__platform")) return false;
    if (std.mem.startsWith(u8, name, "__strlen")) return false;
    if (std.mem.startsWith(u8, name, "__substr")) return false;
    if (std.mem.startsWith(u8, name, "__indexOf")) return false;
    if (std.mem.startsWith(u8, name, "__split")) return false;
    if (std.mem.startsWith(u8, name, "__toUpper")) return false;
    if (std.mem.startsWith(u8, name, "__toLower")) return false;
    if (std.mem.startsWith(u8, name, "__trim")) return false;
    if (std.mem.startsWith(u8, name, "__replace")) return false;
    if (std.mem.startsWith(u8, name, "__concat")) return false;
    if (std.mem.startsWith(u8, name, "__repeat")) return false;
    if (std.mem.startsWith(u8, name, "__startsWith")) return false;
    if (std.mem.startsWith(u8, name, "__endsWith")) return false;
    if (std.mem.startsWith(u8, name, "__charCode")) return false;
    if (std.mem.startsWith(u8, name, "__parseInt")) return false;
    if (std.mem.startsWith(u8, name, "__parseFloat")) return false;
    if (std.mem.startsWith(u8, name, "__fromCharCode")) return false;
    if (std.mem.startsWith(u8, name, "__contains")) return false;
    if (std.mem.startsWith(u8, name, "__lastIndex")) return false;
    if (std.mem.startsWith(u8, name, "__slice")) return false;
    if (std.mem.startsWith(u8, name, "__compare")) return false;
    if (std.mem.startsWith(u8, name, "__eql")) return false;
    if (std.mem.startsWith(u8, name, "__join")) return false;
    if (std.mem.startsWith(u8, name, "__pad")) return false;
    if (std.mem.startsWith(u8, name, "__isEmpty")) return false;
    if (std.mem.startsWith(u8, name, "__isBlank")) return false;
    if (std.mem.startsWith(u8, name, "__alloc")) return false;
    if (std.mem.startsWith(u8, name, "__arena_")) return false;
    if (std.mem.startsWith(u8, name, "__O_")) return false;
    if (std.mem.startsWith(u8, name, "__SEEK_")) return false;
    if (std.mem.startsWith(u8, name, "__STD")) return false;
    if (std.mem.startsWith(u8, name, "__F_OK")) return false;
    if (std.mem.startsWith(u8, name, "__R_OK")) return false;
    if (std.mem.startsWith(u8, name, "__W_OK")) return false;
    if (std.mem.startsWith(u8, name, "__X_OK")) return false;
    if (std.mem.startsWith(u8, name, "__AT_")) return false;
    if (std.mem.startsWith(u8, name, "__S_I")) return false;
    if (std.mem.startsWith(u8, name, "__SIG")) return false;
    if (std.mem.startsWith(u8, name, "__F_GET")) return false;
    if (std.mem.startsWith(u8, name, "__F_SET")) return false;
    return true;
}

fn moduleNeeded(needed: *const std.StringHashMap(void), module: Module) bool {
    return switch (module) {
        .print => wants(needed, &.{}, &.{"print"}),
        .print_ln => wants(needed, &.{}, &.{ "__printLn" }),
        .log => wants(needed, &.{}, &.{ "__hostLog" }),
        .len => wants(needed, &.{}, &.{ "len" }),
        .mem => wants(needed, &.{ "__alloc", "__arena_" }, &.{ "__allocImmortal", "__allocBytes", "__allocImmortalBytes", "__allocArray", "__allocImmortalArray" }),
        .string => wants(needed, &.{
            "__str", "__sub", "__index", "__split", "__toU", "__toL", "__trim", "__replace",
            "__concat", "__repeat", "__starts", "__ends", "__char", "__parse", "__fromC",
            "__contains", "__lastIndex", "__slice", "__compare", "__eql", "__join", "__pad",
            "__isEmpty", "__isBlank",
        }, &.{}),
        .io => wants(needed, &.{ "__read", "__write", "__append", "__delete", "__exists", "__mkdir", "__stat", "__rename", "__copy", "__symlink", "__readlink", "__realpath", "__chmod" }, &.{}),
        .time => wants(needed, &.{}, &.{ "__now", "__sleep" }),
        .os => wants(needed, &.{}, &.{ "__exec", "__getEnv", "__setEnv", "__exit", "__cwd", "__chdir", "__pid", "__args", "__platform" }),
        .syscall => wants(needed, &.{ "__sys_", "__SYS_", "__O_", "__SEEK_", "__STD", "__F_OK", "__R_OK", "__W_OK", "__X_OK", "__AT_", "__S_I", "__SIG", "__F_GET", "__F_SET" }, &.{ "__syscall" }),
        .http => wants(needed, &.{}, &.{ "__fetch" }),
        .json => wants(needed, &.{ "__json" }, &.{}),
        .list => wants(needed, &.{ "__list" }, &.{}),
        .map => wants(needed, &.{ "__map" }, &.{}),
        .buffer => wants(needed, &.{ "__buffer" }, &.{}),
        .math => blk: {
            var it = needed.keyIterator();
            while (it.next()) |name| {
                if (isMathGlobal(name.*)) break :blk true;
            }
            break :blk false;
        },
    };
}

pub fn registerBuiltins(vm: *VMState, chunk: *const Chunk) !void {
    var needed = try scan.referencedGlobalNames(vm.allocator, chunk);
    defer needed.deinit();

    if (moduleNeeded(&needed, .print)) try print_mod.register(vm);
    if (moduleNeeded(&needed, .print_ln)) try print_ln_mod.register(vm);
    if (moduleNeeded(&needed, .log)) try log_mod.register(vm);
    if (moduleNeeded(&needed, .len)) try len_mod.register(vm);
    if (moduleNeeded(&needed, .mem)) try mem_mod.register(vm);
    if (moduleNeeded(&needed, .math)) try math_mod.register(vm);
    if (moduleNeeded(&needed, .string)) try string_mod.register(vm);
    if (moduleNeeded(&needed, .io)) try io_mod.register(vm);
    if (moduleNeeded(&needed, .time)) try time_mod.register(vm);
    if (moduleNeeded(&needed, .os)) try os_mod.register(vm);
    if (moduleNeeded(&needed, .syscall)) try syscall_mod.register(vm);
    if (moduleNeeded(&needed, .http)) try http_mod.register(vm);
    if (moduleNeeded(&needed, .json)) try json_mod.register(vm);
    if (moduleNeeded(&needed, .list)) try list_mod.register(vm);
    if (moduleNeeded(&needed, .map)) try map_mod.register(vm);
    if (moduleNeeded(&needed, .buffer)) try buffer_mod.register(vm);
}
