//! Zig reference tokenizer for self-hosted scanner parity.
//! Line format: type\tvalue\tline:column
//! Type column uses LLTS `@nameOf` spellings (PascalCase as declared in tokens.lls).
const std = @import("std");
const llts = @import("llts");

fn typeName(t: llts.scanner.TokenType) []const u8 {
    return switch (t) {
        .keyword => "Keyword",
        .identifier => "Identifier",
        .v_register => "VRegister",
        .compiler_keyword => "CompilerKeyword",
        .string => "String",
        .number => "Number",
        .hex => "Hex",
        .octal => "Octal",
        .binary => "Binary",
        .boolean => "Boolean",
        .delimiter => "Delimiter",
        .type_decl => "TypeDecl",
        .bin_op => "BinOp",
        .unary_op => "UnaryOp",
        .assign_op => "AssignOp",
        .eof => "Eof",
    };
}

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var args = try std.process.argsWithAllocator(gpa);
    defer args.deinit();
    _ = args.next(); // argv0
    const path = args.next() orelse {
        std.debug.print("Usage: llts-tokenize-zig <path>\n", .{});
        std.process.exit(1);
    };

    const source = try std.fs.cwd().readFileAlloc(gpa, path, 16 * 1024 * 1024);
    defer gpa.free(source);

    var result = try llts.scanner.scan(gpa, source, path);
    defer llts.scanner.deinitScanResult(&result);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buf);
    const out = &stdout_writer.interface;

    for (result.tokens.items) |t| {
        try out.print("{s}\t{s}\t{d}:{d}\n", .{ typeName(t.type), t.value, t.line, t.column });
    }
    try out.flush();
}
