const std = @import("std");
const llts = @import("llts");
const ast = llts.ast;

/// Tries to format the type of an AST node.
pub fn formatType(allocator: std.mem.Allocator, node: *const ast.Node) ?[]const u8 {
    switch (node.*) {
        .literal => |l| {
            return switch (l.literal_type) {
                .number, .hex, .octal, .binary => std.mem.Allocator.dupe(allocator, u8, "int") catch null,
                .string => std.mem.Allocator.dupe(allocator, u8, "[]const u8") catch null,
                .boolean => std.mem.Allocator.dupe(allocator, u8, "bool") catch null,
                .@"null" => std.mem.Allocator.dupe(allocator, u8, "null") catch null,
            };
        },
        .struct_decl => |s| {
            return std.fmt.allocPrint(allocator, "struct {s}", .{s.name}) catch null;
        },
        .enum_decl => |e| {
            return std.fmt.allocPrint(allocator, "enum {s}", .{e.name}) catch null;
        },
        .function_decl => |f| {
            // Simplified function signature
            return std.fmt.allocPrint(allocator, "func {s}()", .{f.name}) catch null;
        },
        .type_decl => |t| {
            return std.fmt.allocPrint(allocator, "type {s}", .{t.name}) catch null;
        },
        .declaration => |d| {
            if (d.type_annotation) |ta| {
                // Formatting AST type nodes to string is tricky without a printer.
                // We will just say "custom type" or try to format basic types.
                return formatType(allocator, ta);
            }
            return formatType(allocator, d.value);
        },
        .primary => |p| {
            return switch (p.kind) {
                .identifier => std.fmt.allocPrint(allocator, "typeof({s})", .{p.name}) catch null,
                .register => std.fmt.allocPrint(allocator, "typeof(${s})", .{p.name}) catch null,
                else => null,
            };
        },
        // Very basic type node formatting
        .shape_type => {
            return std.mem.Allocator.dupe(allocator, u8, "shape") catch null;
        },
        else => return null,
    }
}

pub fn findDeclarationInAst(doc: *const ast.Document, name: []const u8) ?*ast.Node {
    // Top-level scan for now. 
    // A true LSP would keep track of scopes!
    for (doc.statements) |stmt| {
        switch (stmt.*) {
            .declaration => |d| {
                if (std.mem.eql(u8, d.name, name)) return stmt;
            },
            .function_decl => |f| {
                if (std.mem.eql(u8, f.name, name)) return stmt;
            },
            .struct_decl => |s| {
                if (std.mem.eql(u8, s.name, name)) return stmt;
            },
            .enum_decl => |e| {
                if (std.mem.eql(u8, e.name, name)) return stmt;
            },
            .type_decl => |t| {
                if (std.mem.eql(u8, t.name, name)) return stmt;
            },
            else => {},
        }
    }
    return null;
}
