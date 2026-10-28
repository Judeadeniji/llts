//! Zig code emitter — translates analyzed LLTS AST into runtime-driving Zig source.
//!
//! Emission strategy (see docs/native-backend.md):
//!   - Each LLTS @func → `fn lls_fn_*(ctx: *rt.Context, ...) anyerror!RetType`
//!   - Local variables and parameters → unboxed native Zig variables
//!   - Frame watermark RAII → `const mark = ctx.enterFunction(...); defer ctx.leaveFunction(mark);`
//!   - Top-level code → `lls_top_level(ctx)` initializing globals then running statements
//!   - Entry wrapper → `pub fn main()` wiring Context + the LLTS-owned trap sink
//!
//! Supported subset: functions, returns, locals, scalar arithmetic,
//! comparisons, string concatenation, `print`, structured `@if`, scalar
//! `@switch`, range `@for`, and condition `@for` (including value-producing
//! break arms and loop break/continue). Iterable loops, aggregates, slices,
//! methods, and error values are rejected with a compile-time diagnostic. The LLTS typechecker owns semantic validation; the emitter only
//! rejects shapes it cannot lower and never adds its own runtime assertions.
const std = @import("std");
const ast_mod = @import("../../../ast/root.zig");
const state_mod = @import("../../state.zig");
const reachability = @import("../../reachability.zig");
const from_ast = @import("../../typecheck/from_ast.zig");
const widths = @import("../../widths.zig");
const compile_errors = @import("../../../errors/compile.zig");
const root_mod = @import("../root.zig");
const unit_mod = @import("unit.zig");
const prescan_mod = @import("prescan.zig");
const stmt_mod = @import("stmt.zig");
const expr_mod = @import("expr.zig");

const CompilerState = state_mod.CompilerState;

pub const ValKind = enum {
    int,
    float,
    bool,
    string,
    void,
    other,
    struct_,
    array,
    slice,
    optional,
    pointer,
    null_value,
    error_value,
    error_payload,
};

pub const ValType = struct {
    display: []const u8,
    clean: []const u8,
    kind: ValKind,
    zig: []const u8,
    width: ?widths.Width = null,
    may_error: bool = false,
    elem: ?*ValType = null,
    array_len: ?usize = null,
    payload: ?*ValType = null,
    success: ?*ValType = null,

    pub fn isI64(self: ValType) bool {
        return self.kind == .int and self.width != null and
            (self.width.? == .i64 or self.width.? == .isize);
    }

    pub fn isU64(self: ValType) bool {
        return self.kind == .int and self.width != null and
            (self.width.? == .u64 or self.width.? == .usize);
    }
};

pub const StructField = struct {
    name: []const u8,
    zig_name: []const u8,
    display: []const u8,
    vt: ValType,
    offset: i32,
};

pub const StructType = struct {
    key: []const u8,
    zig_name: []const u8,
    fields: []StructField = &.{},
    field_index: std.StringHashMap(usize),
};

pub const MemberTarget = struct {
    info: *StructType,
    index: usize,
};

pub const DeferEntry = struct {
    body: *ast_mod.Node,
    is_errdefer: bool,
};

pub const Binding = struct {
    /// Original LLTS spelling (for diagnostics).
    name: []const u8,
    /// Emitted Zig identifier.
    zig_name: []const u8,
    display: []const u8,
    assigned: bool = false,
    reassigned: bool = false,
    read: bool = false,
    is_param: bool = false,
};

pub const Global = struct {
    name: []const u8,
    zig_name: []const u8,
    display: []const u8,
    node: *ast_mod.Node,
};

pub const ParamInfo = struct {
    name: []const u8,
    arg_name: []const u8,
    display: []const u8,
    zig: []const u8,
    kind: ValKind,
};

pub const BreakTarget = struct {
    /// LLTS label, if the value expression was labeled.
    label: ?[]const u8,
    /// Unique Zig label for the emitted block.
    zig_label: []const u8,
    value_type: ValType,
    scope_depth: usize = 0,
};

pub const LoopTarget = struct {
    /// LLTS loop label, if any.
    label: ?[]const u8,
    /// Unique Zig label, emitted only when a labeled break/continue uses it.
    zig_label: ?[]const u8,
    scope_depth: usize = 0,
};

pub const Emitter = struct {
    allocator: std.mem.Allocator,
    writer: std.io.AnyWriter,
    options: root_mod.EmitOptions,
    arena: std.heap.ArenaAllocator,
    doc: *ast_mod.Document,
    state: *CompilerState,

    reach: ?reachability.Result = null,
    runtime_path: []const u8 = "",
    globals: std.StringHashMap(*Global),
    struct_types: std.ArrayList(*StructType) = .empty,
    struct_by_key: std.StringHashMap(*StructType),
    scopes: std.ArrayList(std.StringHashMap(*Binding)) = .empty,
    defer_scopes: std.ArrayList(std.ArrayList(DeferEntry)) = .empty,
    infos: std.AutoHashMap(*ast_mod.Node, *Binding),
    params: std.ArrayList(ParamInfo) = .empty,
    break_targets: std.ArrayList(BreakTarget) = .empty,
    loop_targets: std.ArrayList(LoopTarget) = .empty,
    cur_ret: ValType = undefined,
    counter: usize = 0,
    indent: usize = 1,

    pub const Resolved = struct {
        zig_name: []const u8,
        display: []const u8,
    };

    /// Coerce a literal to a concrete type for contexts without one (tuple
    /// elements, explicit `@as`); ordinary assignments/arguments already
    /// provide a target type, so they use `emitValueCoerced` directly.
    pub fn classify(self: *Emitter, node: *ast_mod.Node, display_in: []const u8) anyerror!ValType {
        const a = self.arena.allocator();
        const display = std.mem.trim(u8, display_in, " \t");
        const expanded = try self.expandTypedefs(display, 0);
        var parts: std.ArrayList([]const u8) = .empty;
        var has_error = false;
        var it = std.mem.splitSequence(u8, expanded, "|");
        while (it.next()) |part| {
            const p = std.mem.trim(u8, part, " \t");
            if (p.len == 0) continue;
            if (self.isErrorDisplay(p)) {
                has_error = true;
                continue;
            }
            try parts.append(a, p);
        }

        const clean = if (parts.items.len == 1)
            parts.items[0]
        else if (parts.items.len == 0)
            "void"
        else
            try std.mem.join(a, " | ", parts.items);

        if (has_error and parts.items.len == 0) {
            return .{
                .display = display,
                .clean = "error",
                .kind = .error_value,
                .zig = "rt.err.Error",
                .may_error = true,
            };
        }
        if (has_error) {
            const success = try self.childType(node, clean);
            var t = success.*;
            t.display = display;
            t.clean = clean;
            t.may_error = true;
            t.success = success;
            t.zig = try std.fmt.allocPrint(a, "rt.err.Result({s})", .{success.zig});
            return t;
        }

        var t: ValType = .{ .display = display, .clean = clean, .kind = .other, .zig = "void" };
        if (std.mem.eql(u8, clean, "void")) {
            t.kind = .void;
            t.zig = "void";
            return t;
        }
        if (std.mem.eql(u8, clean, "null")) {
            t.kind = .null_value;
            t.zig = "@TypeOf(null)";
            return t;
        }
        if (isByteSequenceDisplay(clean)) {
            t.kind = .string;
            t.zig = "[]const u8";
            t.elem = try self.childType(node, "u8");
            return t;
        }
        if (optionalPayloadDisplay(clean)) |payload_display| {
            const payload = try self.childType(node, payload_display);
            t.kind = .optional;
            t.payload = payload;
            t.zig = try std.fmt.allocPrint(a, "?{s}", .{payload.zig});
            return t;
        }
        if (clean.len > 0 and clean[0] == '*') {
            const payload = try self.childType(node, std.mem.trim(u8, clean[1..], " \t"));
            t.kind = .pointer;
            t.payload = payload;
            t.zig = try std.fmt.allocPrint(a, "*{s}", .{payload.zig});
            return t;
        }
        if (try parseArrayShape(clean)) |shape| {
            const elem = try self.childType(node, shape.elem);
            t.elem = elem;
            t.array_len = shape.length;
            if (shape.length) |len| {
                t.kind = .array;
                t.zig = try std.fmt.allocPrint(a, "[{d}]{s}", .{ len, elem.zig });
            } else {
                t.kind = .slice;
                t.zig = try std.fmt.allocPrint(a, "[]{s}", .{elem.zig});
            }
            return t;
        }
        if (try self.enumKind(clean)) |is_string_enum| {
            if (is_string_enum) {
                t.kind = .string;
                t.zig = "[]const u8";
            } else {
                t.kind = .int;
                t.width = .i64;
                t.zig = "i64";
            }
            return t;
        }
        if (from_ast.lookupStruct(self.state, clean) != null) {
            const info = try self.ensureStructType(node, clean);
            t.kind = .struct_;
            t.zig = info.zig_name;
            return t;
        }
        if (std.mem.eql(u8, clean, "u1") or std.mem.eql(u8, clean, "bool") or std.mem.eql(u8, clean, "boolean")) {
            t.kind = .bool;
            t.zig = "bool";
            t.width = .u1;
            return t;
        }
        if (widths.fromName(clean)) |w| {
            t.width = w;
            if (w.isFloat()) {
                t.kind = .float;
                t.zig = switch (w.concrete()) {
                    .f32 => "f32",
                    else => "f64",
                };
            } else {
                t.kind = .int;
                t.zig = switch (w.concrete()) {
                    .i8 => "i8",
                    .i16 => "i16",
                    .i32 => "i32",
                    .i64, .isize => "i64",
                    .u8 => "u8",
                    .u16 => "u16",
                    .u32 => "u32",
                    .u64, .usize => "u64",
                    .u1 => "bool",
                    else => "i64",
                };
            }
            return t;
        }
        const peeled = from_ast.peelTypedefDisplay(self.state, clean);
        if (!std.mem.eql(u8, peeled, clean)) {
            return self.classify(node, peeled);
        }
        return t;
    }

    fn expandTypedefs(self: *Emitter, display: []const u8, depth: usize) anyerror![]const u8 {
        if (depth > 16) return display;
        const a = self.arena.allocator();
        var out: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitSequence(u8, display, "|");
        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t");
            if (trimmed.len == 0) continue;
            const key = from_ast.findTypedefKey(self.state, trimmed) orelse {
                try out.append(a, trimmed);
                continue;
            };
            const td = self.state.typedefs.get(key) orelse {
                try out.append(a, trimmed);
                continue;
            };
            if (std.mem.indexOfScalar(u8, td.underlying, '|') != null or
                from_ast.typeAllowsErrorState(self.state, trimmed) or
                from_ast.typeAllowsErrorState(self.state, td.underlying))
            {
                try out.append(a, try self.expandTypedefs(td.underlying, depth + 1));
            } else {
                try out.append(a, trimmed);
            }
        }
        return std.mem.join(a, " | ", out.items);
    }

    fn isErrorDisplay(self: *Emitter, part: []const u8) bool {
        if (std.mem.eql(u8, part, "error")) return true;
        if (self.state.error_sets.contains(part)) return true;
        if (std.mem.lastIndexOfScalar(u8, part, '.')) |dot| {
            if (self.state.error_sets.contains(part[0..dot])) return true;
        }
        return false;
    }

    fn childType(self: *Emitter, node: *ast_mod.Node, display: []const u8) anyerror!*ValType {
        const p = try self.arena.allocator().create(ValType);
        p.* = try self.classify(node, display);
        return p;
    }

    fn enumKind(self: *Emitter, clean: []const u8) !?bool {
        if (self.state.enums.get(clean)) |ed| return ed.isString();
        if (std.mem.lastIndexOfScalar(u8, clean, '.')) |dot| {
            if (self.state.enums.get(clean[0..dot])) |ed| return ed.isString();
        }
        return null;
    }

    pub fn ensureStructType(self: *Emitter, node: *ast_mod.Node, display: []const u8) anyerror!*StructType {
        const clean = std.mem.trim(u8, display, " \t");
        const def = from_ast.lookupStruct(self.state, clean) orelse {
            return self.failAt(node, "native backend cannot resolve struct type '{s}'", .{clean});
        };
        if (self.struct_by_key.get(def.name)) |info| return info;

        const a = self.arena.allocator();
        const info = try a.create(StructType);
        info.* = .{
            .key = def.name,
            .zig_name = try std.fmt.allocPrint(a, "lls_t_{s}", .{try self.mangle(def.name)}),
            .field_index = std.StringHashMap(usize).init(a),
        };
        try self.struct_by_key.put(def.name, info);
        try self.struct_types.append(a, info);

        const Seed = struct {
            name: []const u8,
            display: []const u8,
            offset: i32,
        };
        var seeds: std.ArrayList(Seed) = .empty;
        var it = def.types.iterator();
        while (it.next()) |entry| {
            const field_name = entry.key_ptr.*;
            const offset = def.offsets.get(field_name) orelse 0;
            try seeds.append(a, .{
                .name = field_name,
                .display = entry.value_ptr.*,
                .offset = offset,
            });
        }
        std.mem.sort(Seed, seeds.items, {}, struct {
            fn lessThan(_: void, lhs: Seed, rhs: Seed) bool {
                if (lhs.offset != rhs.offset) return lhs.offset < rhs.offset;
                return std.mem.lessThan(u8, lhs.name, rhs.name);
            }
        }.lessThan);

        const fields = try a.alloc(StructField, seeds.items.len);
        for (seeds.items, 0..) |seed, i| {
            const vt = try self.classify(node, seed.display);
            if (vt.kind == .other or vt.kind == .void) {
                return self.failAt(node, "native backend cannot store field '{s}.{s}' of type '{s}'", .{
                    clean, seed.name, seed.display,
                });
            }
            fields[i] = .{
                .name = seed.name,
                .zig_name = try std.fmt.allocPrint(a, "f{d}", .{i}),
                .display = seed.display,
                .vt = vt,
                .offset = seed.offset,
            };
            try info.field_index.put(seed.name, i);
        }
        info.fields = fields;
        return info;
    }

    pub fn structInfoForDisplay(self: *Emitter, node: *ast_mod.Node, display: []const u8) anyerror!?*StructType {
        var clean = std.mem.trim(u8, display, " \t");
        if (optionalPayloadDisplay(clean)) |payload| clean = payload;
        while (clean.len > 0 and clean[0] == '*') {
            clean = std.mem.trim(u8, clean[1..], " \t");
        }
        if (from_ast.lookupStruct(self.state, clean) == null) return null;
        return try self.ensureStructType(node, clean);
    }

    pub fn emitStructTypeDecls(self: *Emitter) !void {
        var i: usize = 0;
        while (i < self.struct_types.items.len) : (i += 1) {
            const info = self.struct_types.items[i];
            try self.writer.print("const {s} = struct {{\n", .{info.zig_name});
            for (info.fields) |field| {
                try self.writer.print("    {s}: {s},\n", .{ field.zig_name, field.vt.zig });
            }
            try self.writer.writeAll("};\n\n");
        }
    }

    pub fn deinit(self: *Emitter) void {
        if (self.reach) |*r| r.deinit();
        self.globals.deinit();
        self.struct_by_key.deinit();
        self.infos.deinit();
        self.arena.deinit();
    }

    pub fn displayForDeclValue(self: *Emitter, d: *const ast_mod.Declaration) ![]const u8 {
        if (d.type_annotation) |ann| {
            if (try from_ast.typeAstToDisplay(ann, self.state)) |disp| return disp;
        }
        if (self.state.type_of_results.get(d.value)) |disp| return disp;
        if (from_ast.resolveType(self.state, d.value)) |disp| return disp;
        return self.failAt(d.value, "native backend cannot infer the type of '{s}'; add an annotation", .{d.name});
    }

    pub fn displayForExpr(self: *Emitter, node: *ast_mod.Node) ![]const u8 {
        if (self.state.type_of_results.get(node)) |disp| return disp;
        switch (node.*) {
            .primary => |p| {
                if (p.kind == .identifier or p.kind == .register) {
                    const resolved = try self.lookupBinding(node, p.name);
                    return resolved.display;
                }
            },
            else => {},
        }
        if (from_ast.resolveType(self.state, node)) |disp| return disp;
        return self.failAt(node, "native backend cannot infer the type of this expression", .{});
    }

    pub fn emit(self: *Emitter) !void {
        self.reach = try reachability.compute(self.state, self.doc);
        self.runtime_path = std.fs.cwd().realpathAlloc(self.arena.allocator(), self.options.runtime_path) catch {
            return self.failNoLoc("runtime path '{s}' not found (pass --runtime-path)", .{self.options.runtime_path});
        };

        try unit_mod.collectGlobals(self);

        try self.writer.writeAll("// Generated by `llts emit-zig` — do not edit.\n");
        try self.writer.writeAll("const rt = @import(");
        try self.writer.writeAll(try self.zigString(self.runtime_path));
        try self.writer.writeAll(");\n\n");

        try unit_mod.emitGlobalDecls(self);
        try unit_mod.emitFunctions(self);
        try unit_mod.emitTopLevel(self);
        try unit_mod.emitEntry(self);
        try self.emitStructTypeDecls();
    }

    pub fn failAt(self: *Emitter, node: *ast_mod.Node, comptime fmt: []const u8, args: anytype) error{CompileError} {
        const loc = node.loc();
        if (loc.path.len > 0) self.state.diag_path = loc.path;
        if (loc.line > 0) self.state.diag_line = loc.line;
        if (loc.column > 0) self.state.diag_column = loc.column;
        return compile_errors.compileFailFmt(self.state, fmt, args);
    }

    pub fn failNoLoc(self: *Emitter, comptime fmt: []const u8, args: anytype) error{CompileError} {
        self.state.diag_path = self.doc.path;
        self.state.diag_line = 1;
        self.state.diag_column = 1;
        return compile_errors.compileFailFmt(self.state, fmt, args);
    }

    pub fn fnName(self: *Emitter, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "lls_fn_{s}", .{try self.mangle(name)});
    }

    pub fn globalName(self: *Emitter, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "lls_g_{s}", .{try self.mangle(name)});
    }

    pub fn init(
        allocator: std.mem.Allocator,
        doc: *ast_mod.Document,
        state: *CompilerState,
        writer: std.io.AnyWriter,
        options: root_mod.EmitOptions,
    ) !Emitter {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        return .{
            .allocator = allocator,
            .writer = writer,
            .options = options,
            .arena = arena,
            .doc = doc,
            .state = state,
            .globals = std.StringHashMap(*Global).init(allocator),
            .struct_by_key = std.StringHashMap(*StructType).init(allocator),
            .infos = std.AutoHashMap(*ast_mod.Node, *Binding).init(allocator),
        };
    }

    pub fn localName(self: *Emitter, name: []const u8) ![]const u8 {
        self.counter += 1;
        return std.fmt.allocPrint(self.arena.allocator(), "lls_l{d}_{s}", .{ self.counter, try self.mangle(name) });
    }

    pub fn lookupBinding(self: *Emitter, node: *ast_mod.Node, name: []const u8) !Resolved {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].get(name)) |b| {
                return .{ .zig_name = b.zig_name, .display = b.display };
            }
        }
        if (self.globals.get(name)) |g| {
            return .{ .zig_name = g.zig_name, .display = g.display };
        }
        return self.failAt(node, "native backend cannot resolve '{s}' (imports/aggregates are Phase 3)", .{name});
    }

    pub fn mangle(self: *Emitter, name: []const u8) ![]const u8 {
        const a = self.arena.allocator();
        var out: std.ArrayList(u8) = .empty;
        for (name) |ch| {
            if (std.ascii.isAlphanumeric(ch) or ch == '_') {
                try out.append(a, ch);
            } else {
                try out.append(a, '_');
                try out.writer(a).print("{X:0>2}", .{ch});
            }
        }
        return out.toOwnedSlice(a);
    }

    pub fn paramArgName(self: *Emitter, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "lls_arg_{s}", .{try self.mangle(name)});
    }

    pub fn popScope(self: *Emitter) void {
        _ = self.scopes.pop();
        _ = self.defer_scopes.pop();
    }

    pub fn pushScope(self: *Emitter) void {
        self.scopes.append(self.arena.allocator(), std.StringHashMap(*Binding).init(self.arena.allocator())) catch unreachable;
        self.defer_scopes.append(self.arena.allocator(), .empty) catch unreachable;
    }

    pub fn emitDeferBody(self: *Emitter, body: *ast_mod.Node) anyerror!void {
        try self.writeIndent();
        try self.writer.writeAll("{\n");
        self.indent += 1;
        self.pushScope();
        if (body.* == .block) {
            try stmt_mod.emitStatements(self, body.block.statements);
        } else {
            try stmt_mod.emitStmt(self, body);
        }
        self.popScope();
        self.indent -= 1;
        try self.writeIndent();
        try self.writer.writeAll("}\n");
    }

    fn emitDeferFrame(self: *Emitter, frame: std.ArrayList(DeferEntry), include_errdefer: bool) anyerror!void {
        var i = frame.items.len;
        while (i > 0) {
            i -= 1;
            const entry = frame.items[i];
            if (entry.is_errdefer and !include_errdefer) continue;
            try self.emitDeferBody(entry.body);
        }
    }

    pub fn emitDeferredScope(self: *Emitter) anyerror!void {
        if (self.defer_scopes.items.len == 0) return;
        const frame = self.defer_scopes.items[self.defer_scopes.items.len - 1];
        try self.emitDeferFrame(frame, false);
    }

    pub fn emitDeferredAtScopeEnd(self: *Emitter, statements: []*ast_mod.Node) anyerror!void {
        if (statements.len > 0 and prescan_mod.stmtTerminates(self, statements[statements.len - 1])) return;
        try self.emitDeferredScope();
    }

    pub fn emitDeferredFromDepthMode(self: *Emitter, depth: usize, include_errdefer: bool) anyerror!void {
        if (self.defer_scopes.items.len <= depth) return;
        var i = self.defer_scopes.items.len;
        while (i > depth) {
            i -= 1;
            const frame = self.defer_scopes.items[i];
            try self.emitDeferFrame(frame, include_errdefer);
        }
    }

    pub fn emitDeferredFromDepth(self: *Emitter, depth: usize) anyerror!void {
        try self.emitDeferredFromDepthMode(depth, false);
    }

    pub fn emitErrorCleanup(self: *Emitter) anyerror!void {
        try self.emitDeferredFromDepthMode(0, true);
    }

    pub fn requireValueType(self: *Emitter, node: *ast_mod.Node, t: ValType) !void {
        if (t.kind == .other) {
            return self.failAt(node, "native backend (Phase 2) does not support type '{s}'", .{t.display});
        }
        if (t.kind == .void and !t.may_error) {
            return self.failAt(node, "native backend cannot bind a void value", .{});
        }
    }

    pub fn storageValueType(self: *Emitter, node: *ast_mod.Node) anyerror!ValType {
        const narrowed = try self.valueType(node);
        if (narrowed.kind != .error_value) return narrowed;
        if (node.* == .primary and (node.primary.kind == .identifier or node.primary.kind == .register)) {
            const b = try self.lookupBinding(node, node.primary.name);
            const stored = try self.classify(node, b.display);
            if (stored.may_error and stored.kind != .error_value) return stored;
        }
        return narrowed;
    }

    pub fn valueType(self: *Emitter, node: *ast_mod.Node) anyerror!ValType {
        switch (node.*) {
            .unwrap_expr => |u| {
                const inner = try self.valueType(u.expression);
                if (inner.kind == .optional and inner.payload != null) return inner.payload.?.*;
                return inner;
            },
            .index => |ix| {
                if (!ix.is_slice) {
                    const object = try self.valueType(ix.object);
                    if (object.elem) |elem| return elem.*;
                }
            },
            .member => |m| {
                if (m.property.* == .primary) {
                    const prop = m.property.primary.name;
                    if (std.mem.eql(u8, prop, "message") or std.mem.eql(u8, prop, "code") or std.mem.eql(u8, prop, "payload")) {
                        const obj_t = try self.storageValueType(m.object);
                        if (obj_t.kind == .error_value or obj_t.may_error) {
                            if (std.mem.eql(u8, prop, "payload")) {
                                return .{ .display = "unknown", .clean = "unknown", .kind = .error_payload, .zig = "rt.err.Payload" };
                            }
                            return .{ .display = "string", .clean = "string", .kind = .string, .zig = "[]const u8" };
                        }
                    }
                }
                if (try expr_mod.resolveMemberField(self, node, &m)) |target| {
                    return target.info.fields[target.index].vt;
                }
                if (self.state.type_of_results.get(node)) |disp| {
                    if (self.isErrorDisplay(disp)) return self.classify(node, disp);
                }
            },
            else => {},
        }
        const display = try self.displayForExpr(node);
        return self.classify(node, display);
    }

    pub fn writeIndent(self: *Emitter) !void {
        var i: usize = 0;
        while (i < self.indent) : (i += 1) try self.writer.writeAll("    ");
    }

    pub fn zigString(self: *Emitter, s: []const u8) ![]const u8 {
        const a = self.arena.allocator();
        var out: std.ArrayList(u8) = .empty;
        try out.append(a, '"');
        for (s) |ch| {
            switch (ch) {
                '"' => try out.appendSlice(a, "\\\""),
                '\\' => try out.appendSlice(a, "\\\\"),
                '\n' => try out.appendSlice(a, "\\n"),
                '\r' => try out.appendSlice(a, "\\r"),
                '\t' => try out.appendSlice(a, "\\t"),
                else => {
                    if (ch >= 0x20 and ch <= 0x7e) {
                        try out.append(a, ch);
                    } else {
                        try out.writer(a).print("\\x{X:0>2}", .{ch});
                    }
                },
            }
        }
        try out.append(a, '"');
        return out.toOwnedSlice(a);
    }
};

pub fn isImportDecl(decl: *const ast_mod.Declaration) bool {
    if (decl.value.* != .call) return false;
    const c = decl.value.call;
    return c.callee.* == .primary and std.mem.eql(u8, c.callee.primary.name, "@import");
}

fn isByteSequenceDisplay(clean: []const u8) bool {
    return std.mem.eql(u8, clean, "string") or std.mem.eql(u8, clean, "[]byte") or
        std.mem.eql(u8, clean, "[]u8") or std.mem.eql(u8, clean, "[]const u8");
}

fn optionalPayloadDisplay(clean: []const u8) ?[]const u8 {
    if (clean.len > 1 and clean[0] == '?') {
        const payload = std.mem.trim(u8, clean[1..], " \t");
        if (payload.len > 0) return payload;
    }
    if (std.mem.endsWith(u8, clean, " | null")) {
        const payload = std.mem.trim(u8, clean[0 .. clean.len - " | null".len], " \t");
        if (payload.len > 0) return payload;
    }
    if (std.mem.startsWith(u8, clean, "null | ")) {
        const payload = std.mem.trim(u8, clean["null | ".len..], " \t");
        if (payload.len > 0) return payload;
    }
    return null;
}

const ArrayShape = struct {
    length: ?usize,
    elem: []const u8,
};

fn parseArrayShape(clean: []const u8) !?ArrayShape {
    if (clean.len < 2 or clean[0] != '[') return null;
    if (clean[1] == ']') {
        const elem = std.mem.trim(u8, clean[2..], " \t");
        if (elem.len == 0) return null;
        return .{ .length = null, .elem = elem };
    }
    var i: usize = 1;
    while (i < clean.len and clean[i] >= '0' and clean[i] <= '9') : (i += 1) {}
    if (i == 1 or i >= clean.len or clean[i] != ']') return null;
    const length = std.fmt.parseInt(usize, clean[1..i], 10) catch return null;
    const elem = std.mem.trim(u8, clean[i + 1 ..], " \t");
    if (elem.len == 0) return null;
    return .{ .length = length, .elem = elem };
}
