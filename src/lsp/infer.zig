const std = @import("std");
const llts = @import("llts");
const ast = llts.ast;

const ConstantValue = union(enum) {
    int: i64,
    boolean: bool,
    string: []const u8,
};

fn isTruthy(val: ConstantValue) bool {
    return switch (val) {
        .int => |i| i != 0,
        .boolean => |b| b,
        .string => |s| s.len > 0,
    };
}

fn evalConstant(node: *const ast.Node, doc: *const ast.Document) ?ConstantValue {
    switch (node.*) {
        .literal => |l| {
            switch (l.literal_type) {
                .number => if (std.fmt.parseInt(i64, l.value, 10)) |v| return .{ .int = v } else |_| return null,
                .boolean => return .{ .boolean = std.mem.eql(u8, l.value, "true") },
                .string => return .{ .string = l.value },
                else => return null,
            }
        },
        .unary => |u| {
            const arg = evalConstant(u.arg, doc) orelse return null;
            if (u.operator.len == 1) {
                switch (u.operator[0]) {
                    '-' => if (arg == .int) return .{ .int = -arg.int } else return null,
                    '!' => return .{ .boolean = !isTruthy(arg) },
                    '~' => if (arg == .int) return .{ .int = ~arg.int } else return null,
                    '+' => if (arg == .int) return .{ .int = arg.int } else return null,
                    else => return null,
                }
            }
            return null;
        },
        .binary => |b| {
            const left = evalConstant(b.left, doc) orelse return null;
            const right = evalConstant(b.right, doc) orelse return null;
            if (b.operator.len == 1) {
                if (left != .int or right != .int) return null;
                switch (b.operator[0]) {
                    '+' => return .{ .int = left.int + right.int },
                    '-' => return .{ .int = left.int - right.int },
                    '*' => return .{ .int = left.int * right.int },
                    '/' => {
                        if (right.int == 0) return null;
                        return .{ .int = @divTrunc(left.int, right.int) };
                    },
                    '%' => {
                        if (right.int == 0) return null;
                        return .{ .int = @rem(left.int, right.int) };
                    },
                    '&' => return .{ .int = left.int & right.int },
                    '|' => return .{ .int = left.int | right.int },
                    '^' => return .{ .int = left.int ^ right.int },
                    '<' => return .{ .boolean = left.int < right.int },
                    '>' => return .{ .boolean = left.int > right.int },
                    else => return null,
                }
            } else if (b.operator.len == 2) {
                if (std.mem.eql(u8, b.operator, "==")) {
                    if (left == .int and right == .int) return .{ .boolean = left.int == right.int };
                    if (left == .boolean and right == .boolean) return .{ .boolean = left.boolean == right.boolean };
                    if (left == .string and right == .string) return .{ .boolean = std.mem.eql(u8, left.string, right.string) };
                    return .{ .boolean = false };
                }
                if (std.mem.eql(u8, b.operator, "!=")) {
                    if (left == .int and right == .int) return .{ .boolean = left.int != right.int };
                    if (left == .boolean and right == .boolean) return .{ .boolean = left.boolean != right.boolean };
                    if (left == .string and right == .string) return .{ .boolean = !std.mem.eql(u8, left.string, right.string) };
                    return .{ .boolean = true };
                }
                if (left == .int and right == .int) {
                    if (std.mem.eql(u8, b.operator, "<<")) return .{ .int = left.int << @intCast(right.int) };
                    if (std.mem.eql(u8, b.operator, ">>")) return .{ .int = left.int >> @intCast(right.int) };
                    if (std.mem.eql(u8, b.operator, "<=")) return .{ .boolean = left.int <= right.int };
                    if (std.mem.eql(u8, b.operator, ">=")) return .{ .boolean = left.int >= right.int };
                }
                if (std.mem.eql(u8, b.operator, "&&")) return .{ .boolean = isTruthy(left) and isTruthy(right) };
                if (std.mem.eql(u8, b.operator, "||")) return .{ .boolean = isTruthy(left) or isTruthy(right) };
            }
            return null;
        },
        .primary => |p| {
            if (p.kind == .identifier) {
                if (findDeclarationInAst(doc, p.name)) |decl| {
                    if (decl.* == .declaration and decl.declaration.is_const) {
                        return evalConstant(decl.declaration.value, doc);
                    }
                }
            }
            return null;
        },
        .assignment => |a| {
            if (std.mem.eql(u8, a.operator, "=")) return evalConstant(a.right, doc);
            return null;
        },
        else => return null,
    }
}

fn formatConstant(allocator: std.mem.Allocator, val: ConstantValue) ?[]const u8 {
    return switch (val) {
        .int => |i| std.fmt.allocPrint(allocator, "{d}", .{i}) catch null,
        .boolean => |b| std.fmt.allocPrint(allocator, "{s}", .{if (b) "true" else "false"}) catch null,
        .string => |s| std.fmt.allocPrint(allocator, "\"{s}\"", .{s}) catch null,
    };
}

/// Tries to format the type of an AST node.
pub fn formatType(allocator: std.mem.Allocator, node: *const ast.Node, is_const: bool, doc: *const ast.Document) ?[]const u8 {
    if (is_const) {
        if (evalConstant(node, doc)) |val| {
            if (formatConstant(allocator, val)) |val_str| {
                if (formatType(allocator, node, false, doc)) |base_type| {
                    return std.fmt.allocPrint(allocator, "{s} ({s})", .{ val_str, base_type }) catch null;
                }
                return val_str;
            }
        }
    }
    switch (node.*) {
        .literal => |l| {
            return switch (l.literal_type) {
                .number, .hex, .octal, .binary => if (is_const) std.fmt.allocPrint(allocator, "{s} (int)", .{l.value}) catch null else std.mem.Allocator.dupe(allocator, u8, "int") catch null,
                .string => if (is_const) std.fmt.allocPrint(allocator, "\"{s}\" ([]byte)", .{l.value}) catch null else std.mem.Allocator.dupe(allocator, u8, "[]byte") catch null,
                .boolean => if (is_const) std.fmt.allocPrint(allocator, "{s} (bool)", .{l.value}) catch null else std.mem.Allocator.dupe(allocator, u8, "bool") catch null,
                .@"null" => std.mem.Allocator.dupe(allocator, u8, "null") catch null,
            };
        },
        .struct_decl => |s| {
            var fields_str = std.ArrayList(u8).empty;
            defer fields_str.deinit(allocator);
            
            for (s.fields, 0..) |f, i| {
                if (i > 0) fields_str.appendSlice(allocator, ", ") catch {};
                fields_str.appendSlice(allocator, f.name) catch {};
                if (f.type_annotation) |ta| {
                    fields_str.appendSlice(allocator, ": ") catch {};
                    if (formatType(allocator, ta, false, doc)) |t_str| {
                        fields_str.appendSlice(allocator, t_str) catch {};
                    } else {
                        fields_str.appendSlice(allocator, "unknown") catch {};
                    }
                }
            }
            if (fields_str.items.len > 0) {
                return std.fmt.allocPrint(allocator, "@struct {s} {{ {s} }}", .{s.name, fields_str.items}) catch null;
            }
            return std.fmt.allocPrint(allocator, "@struct {s} {{}}", .{s.name}) catch null;
        },
        .enum_decl => |e| {
            return std.fmt.allocPrint(allocator, "@enum {s}", .{e.name}) catch null;
        },
        .error_decl => |e| {
            if (e.variants.len == 0) {
                return std.fmt.allocPrint(allocator, "@error {s} {{}}", .{e.name}) catch null;
            }
            var members_str = std.ArrayList(u8).empty;
            for (e.variants, 0..) |v, i| {
                if (i > 0) members_str.appendSlice(allocator, ", ") catch {};
                members_str.appendSlice(allocator, v) catch {};
            }
            return std.fmt.allocPrint(allocator, "@error {s} {{ {s} }}", .{ e.name, members_str.items }) catch null;
        },
        .function_decl => |f| {
            var params_str = std.ArrayList(u8).empty;
            defer params_str.deinit(allocator);
            if (f.params.* == .params) {
                const p_node = f.params.params;
                for (p_node.params, 0..) |p, i| {
                    if (i > 0) params_str.appendSlice(allocator, ", ") catch {};
                    if (p.is_rest) params_str.appendSlice(allocator, "...") catch {};
                    params_str.appendSlice(allocator, p.name) catch {};
                    if (p.type_annotation) |ta| {
                        params_str.appendSlice(allocator, ": ") catch {};
                        if (formatType(allocator, ta, false, doc)) |t_str| {
                            params_str.appendSlice(allocator, t_str) catch {};
                        } else {
                            params_str.appendSlice(allocator, "unknown") catch {};
                        }
                    }
                }
            }
            var ret_str: []const u8 = "";
            if (f.return_type) |rt| {
                if (formatType(allocator, rt, false, doc)) |r_str| {
                    ret_str = std.fmt.allocPrint(allocator, ": {s}", .{r_str}) catch "";
                }
            }
            return std.fmt.allocPrint(allocator, "@func {s}({s}){s}", .{f.name, params_str.items, ret_str}) catch null;
        },
        .type_decl => |t| {
            if (formatType(allocator, t.type_expr, false, doc)) |te_str| {
                return std.fmt.allocPrint(allocator, "@type {s} = {s}", .{t.name, te_str}) catch null;
            }
            return std.fmt.allocPrint(allocator, "@type {s}", .{t.name}) catch null;
        },
        .declaration => |d| {
            if (d.is_const) {
                if (evalConstant(d.value, doc)) |val| {
                    if (formatConstant(allocator, val)) |val_str| {
                        if (d.type_annotation) |ta| {
                            if (formatType(allocator, ta, false, doc)) |ta_type| {
                                return std.fmt.allocPrint(allocator, "{s} ({s})", .{ val_str, ta_type }) catch null;
                            }
                        }
                        // Default base types for constants
                        const base = switch (val) {
                            .int => "int",
                            .boolean => "bool",
                            .string => "[]byte",
                        };
                        return std.fmt.allocPrint(allocator, "{s} ({s})", .{ val_str, base }) catch null;
                    }
                }
                if (d.value.* == .literal and d.type_annotation != null) {
                    const l = d.value.literal;
                    if (formatType(allocator, d.type_annotation.?, false, doc)) |ta_type| {
                        if (l.literal_type == .string) return std.fmt.allocPrint(allocator, "\"{s}\" ({s})", .{ l.value, ta_type }) catch null;
                        return std.fmt.allocPrint(allocator, "{s} ({s})", .{ l.value, ta_type }) catch null;
                    }
                }
            }
            if (d.type_annotation) |ta| {
                return formatType(allocator, ta, false, doc);
            }
            return formatType(allocator, d.value, d.is_const, doc);
        },
        .primary => |p| {
            return switch (p.kind) {
                .identifier => std.fmt.allocPrint(allocator, "{s}", .{p.name}) catch null,
                .register => std.fmt.allocPrint(allocator, "${s}", .{p.name}) catch null,
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
    for (doc.statements) |stmt| {
        if (!isSameDoc(stmt, doc.path)) continue;
        if (findDeclarationInNode(stmt, name)) |found| return found;
    }
    return null;
}

/// True when `stmt` originates from the document itself rather than from an
/// inlined imported module: `resolveImports` splices module statements into
/// `doc.statements`, and their locations carry the *module's* path/lines,
/// which would collide with the user's coordinates during position lookups.
fn isSameDoc(stmt: *ast.Node, doc_path: []const u8) bool {
    const p = stmt.loc().path;
    return p.len == 0 or std.mem.eql(u8, p, doc_path);
}

fn findDeclarationInNode(stmt: *ast.Node, name: []const u8) ?*ast.Node {
    switch (stmt.*) {
        .declaration => |d| {
            if (std.mem.eql(u8, d.name, name)) return stmt;
        },
        .function_decl => |f| {
            if (std.mem.eql(u8, f.name, name)) return stmt;
            if (findDeclarationInNode(f.body, name)) |found| return found;
        },
        .struct_decl => |s| {
            if (std.mem.eql(u8, s.name, name)) return stmt;
            for (s.methods) |m| {
                if (findDeclarationInNode(m, name)) |found| return found;
            }
        },
        .enum_decl => |e| {
            if (std.mem.eql(u8, e.name, name)) return stmt;
        },
        .error_decl => |e| {
            if (std.mem.eql(u8, e.name, name)) return stmt;
        },
        .type_decl => |t| {
            if (std.mem.eql(u8, t.name, name)) return stmt;
        },
        .block => |b| {
            for (b.statements) |s| {
                if (findDeclarationInNode(s, name)) |found| return found;
            }
        },
        .if_expr => |i| {
            if (findDeclarationInNode(i.body, name)) |found| return found;
            if (i.else_body) |eb| {
                if (findDeclarationInNode(eb, name)) |found| return found;
            }
        },
        .for_expr => |f| {
            if (findDeclarationInNode(f.body, name)) |found| return found;
        },
        .switch_expr => |sw| {
            for (sw.prongs) |p| {
                if (findDeclarationInNode(p.body, name)) |found| return found;
            }
        },
        else => {},
    }
    return null;
}

pub fn locOf(node: *ast.Node) ast.Location {
    switch (node.*) {
        inline else => |n| return n.loc,
    }
}

pub fn findPrimaryAtLoc(node: *ast.Node, line: u32, col: u32) ?*ast.Node {
    const loc = locOf(node);
    if (loc.line == line and loc.column == col) {
        switch (node.*) {
            .primary, .literal, .if_expr, .for_expr, .switch_expr, .struct_init, .try_expr, .error_expr,
            .array_type, .tuple_type, .union_type, .intersection_type, .pointer_type, .func_type, .type_decl => return node,
            else => {},
        }
    }
    switch (node.*) {
        .declaration => |d| return findPrimaryAtLoc(d.value, line, col),
        .binary => |b| {
            if (findPrimaryAtLoc(b.left, line, col)) |found| return found;
            return findPrimaryAtLoc(b.right, line, col);
        },
        .unary => |u| return findPrimaryAtLoc(u.arg, line, col),
        .assignment => |a| {
            if (findPrimaryAtLoc(a.left, line, col)) |found| return found;
            return findPrimaryAtLoc(a.right, line, col);
        },
        .call => |c| {
            if (findPrimaryAtLoc(c.callee, line, col)) |found| return found;
            for (c.args) |arg| {
                if (findPrimaryAtLoc(arg, line, col)) |found| return found;
            }
            return null;
        },
        .member => |m| {
            if (findPrimaryAtLoc(m.object, line, col)) |found| return found;
            const prop_loc = locOf(m.property);
            if (prop_loc.line == line and prop_loc.column == col) return node; // return member node itself!
            if (findPrimaryAtLoc(m.property, line, col)) |found| return found;
            return null;
        },
        .index => |i| {
            if (findPrimaryAtLoc(i.object, line, col)) |found| return found;
            if (i.index) |idx| {
                if (findPrimaryAtLoc(idx, line, col)) |found| return found;
            }
            if (i.end) |end| return findPrimaryAtLoc(end, line, col);
            return null;
        },
        .array_literal => |al| {
            for (al.elements) |el| {
                if (findPrimaryAtLoc(el, line, col)) |found| return found;
            }
            return null;
        },
        .function_decl => |f| return findPrimaryAtLoc(f.body, line, col),
        .struct_decl => |s| {
            for (s.methods) |m| {
                if (findPrimaryAtLoc(m, line, col)) |found| return found;
            }
            return null;
        },
        .block => |b| {
            for (b.statements) |s| {
                if (findPrimaryAtLoc(s, line, col)) |found| return found;
            }
            return null;
        },
        .if_expr => |i| {
            if (findPrimaryAtLoc(i.condition, line, col)) |found| return found;
            if (findPrimaryAtLoc(i.body, line, col)) |found| return found;
            if (i.else_body) |eb| return findPrimaryAtLoc(eb, line, col);
            return null;
        },
        .for_expr => |f| {
            if (findPrimaryAtLoc(f.expr, line, col)) |found| return found;
            return findPrimaryAtLoc(f.body, line, col);
        },
        .switch_expr => |s| {
            if (findPrimaryAtLoc(s.condition, line, col)) |found| return found;
            for (s.prongs) |p| {
                if (findPrimaryAtLoc(p.body, line, col)) |found| return found;
                for (p.patterns) |pat| {
                    if (findPrimaryAtLoc(pat, line, col)) |found| return found;
                }
            }
            return null;
        },
        .return_expr => |r| if (r.return_value) |v| return findPrimaryAtLoc(v, line, col) else return null,
        .defer_stmt => |d| return findPrimaryAtLoc(d.body, line, col),
        .struct_init => |si| {
            if (findPrimaryAtLoc(si.type_expr, line, col)) |found| return found;
            for (si.fields) |f| {
                if (findPrimaryAtLoc(f.value, line, col)) |found| return found;
            }
            return null;
        },
        .try_expr => |te| return findPrimaryAtLoc(te.expression, line, col),
        .error_expr => |ee| {
            for (ee.args) |arg| {
                if (findPrimaryAtLoc(arg, line, col)) |found| return found;
            }
            return null;
        },
        .pointer_type => |pt| return findPrimaryAtLoc(pt.elem, line, col),
        .array_type => |at| {
            return findPrimaryAtLoc(at.elem, line, col);
        },
        else => return null,
    }
}

/// The kind of set a variant belongs to, plus the resolved names.
pub const VariantSite = struct {
    decl_kind: enum { enum_decl, error_decl },
    type_name: []const u8,
    variant: []const u8,
};

/// Finds the enum/error-set declaration whose variant list contains `name`
/// and whose body spans `line`. Used for decl-site variant hovers — variants
/// are not declaration nodes, so `findDeclarationInAst` misses them.
pub fn findVariantSiteInDoc(doc: *const ast.Document, name: []const u8, line: u32) ?VariantSite {
    for (doc.statements) |stmt| {
        if (!isSameDoc(stmt, doc.path)) continue;
        switch (stmt.*) {
            .enum_decl => |e| {
                // Loose span guard: the @enum header plus one line per variant
                // (covers both single-line and one-per-line bodies).
                if (e.loc.line == 0 or e.loc.line > line or line > e.loc.line + e.variants.len + 2) continue;
                for (e.variants) |v| {
                    if (std.mem.eql(u8, v.name, name)) return .{ .decl_kind = .enum_decl, .type_name = e.name, .variant = v.name };
                }
            },
            .error_decl => |e| {
                if (e.loc.line == 0 or e.loc.line > line or line > e.loc.line + e.variants.len + 2) continue;
                for (e.variants) |v| {
                    if (std.mem.eql(u8, v, name)) return .{ .decl_kind = .error_decl, .type_name = e.name, .variant = v };
                }
            },
            else => {},
        }
    }
    return null;
}

pub fn findPrimaryInDoc(doc: *const ast.Document, line: u32, col: u32) ?*ast.Node {
    for (doc.statements) |stmt| {
        if (!isSameDoc(stmt, doc.path)) continue;
        if (findPrimaryAtLoc(stmt, line, col)) |found| return found;
    }
    return null;
}
