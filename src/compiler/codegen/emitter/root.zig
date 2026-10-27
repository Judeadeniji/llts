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

pub const ValKind = enum { int, float, bool, string, void, other };

pub const ValType = struct {
    display: []const u8,
    clean: []const u8,
    kind: ValKind,
    zig: []const u8,
    width: ?widths.Width = null,
    may_error: bool = false,

    pub fn isI64(self: ValType) bool {
        return self.kind == .int and self.width != null and
            (self.width.? == .i64 or self.width.? == .isize);
    }

    pub fn isU64(self: ValType) bool {
        return self.kind == .int and self.width != null and
            (self.width.? == .u64 or self.width.? == .usize);
    }
};

pub const Binding = struct {
    /// Original LLTS spelling (for diagnostics).
    name: []const u8,
    /// Emitted Zig identifier.
    zig_name: []const u8,
    display: []const u8,
    assigned: bool = false,
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
};

pub const BreakTarget = struct {
    /// LLTS label, if the value expression was labeled.
    label: ?[]const u8,
    /// Unique Zig label for the emitted block.
    zig_label: []const u8,
    value_type: ValType,
};

pub const LoopTarget = struct {
    /// LLTS loop label, if any.
    label: ?[]const u8,
    /// Unique Zig label, emitted only when a labeled break/continue uses it.
    zig_label: ?[]const u8,
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
    scopes: std.ArrayList(std.StringHashMap(*Binding)) = .empty,
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
    pub fn classify(self: *Emitter, node: *ast_mod.Node, display_in: []const u8) !ValType {
        const a = self.arena.allocator();
        const display = std.mem.trim(u8, display_in, " \t");
        var parts: std.ArrayList([]const u8) = .empty;
        var may_error = false;
        var has_custom_error = false;
        var it = std.mem.splitSequence(u8, display, "|");
        while (it.next()) |part| {
            const p = std.mem.trim(u8, part, " \t");
            if (p.len == 0) continue;
            if (std.mem.eql(u8, p, "error")) {
                may_error = true;
                continue;
            }
            if (self.state.error_sets.contains(p)) {
                may_error = true;
                has_custom_error = true;
                continue;
            }
            try parts.append(a, p);
        }
        if (has_custom_error) {
            return self.failAt(node, "native backend does not support custom error sets yet ('{s}')", .{display});
        }

        const clean = if (parts.items.len == 1)
            parts.items[0]
        else if (parts.items.len == 0)
            "void"
        else
            try std.mem.join(a, " | ", parts.items);

        var t: ValType = .{ .display = display, .clean = clean, .kind = .other, .zig = "void", .may_error = may_error };
        if (std.mem.eql(u8, clean, "void")) {
            t.kind = .void;
            t.zig = "void";
            return t;
        }
        if (isByteSliceDisplay(clean)) {
            t.kind = .string;
            t.zig = "[]const u8";
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
        return t;
    }

    pub fn deinit(self: *Emitter) void {
        if (self.reach) |*r| r.deinit();
        self.globals.deinit();
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

        try self.collectGlobals();

        try self.writer.writeAll("// Generated by `llts emit-zig` — do not edit.\n");
        try self.writer.writeAll("const rt = @import(");
        try self.writer.writeAll(try self.zigString(self.runtime_path));
        try self.writer.writeAll(");\n\n");

        try self.emitGlobalDecls();
        try self.emitFunctions();
        try self.emitTopLevel();
        try self.emitEntry();
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
    }

    pub fn pushScope(self: *Emitter) void {
        self.scopes.append(self.arena.allocator(), std.StringHashMap(*Binding).init(self.arena.allocator())) catch unreachable;
    }

    pub fn requireValueType(self: *Emitter, node: *ast_mod.Node, t: ValType) !void {
        if (t.may_error) {
            return self.failAt(node, "native backend does not support error values yet (handle with '?')", .{});
        }
        if (t.kind == .other) {
            return self.failAt(node, "native backend (Phase 2) does not support type '{s}'", .{t.display});
        }
        if (t.kind == .void) {
            return self.failAt(node, "native backend cannot bind a void value", .{});
        }
    }

    pub fn valueType(self: *Emitter, node: *ast_mod.Node) !ValType {
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

    pub const collectGlobals = unit_mod.collectGlobals;
    pub const emitEntry = unit_mod.emitEntry;
    pub const emitFunction = unit_mod.emitFunction;
    pub const emitFunctions = unit_mod.emitFunctions;
    pub const emitGlobalDecls = unit_mod.emitGlobalDecls;
    pub const emitTopLevel = unit_mod.emitTopLevel;
    pub const functionReturnType = unit_mod.functionReturnType;
    pub const prepareFunction = unit_mod.prepareFunction;
    pub const zeroValue = unit_mod.zeroValue;
    pub const markAssigned = prescan_mod.markAssigned;
    pub const markRead = prescan_mod.markRead;
    pub const preScanAssignmentTarget = prescan_mod.preScanAssignmentTarget;
    pub const preScanExpr = prescan_mod.preScanExpr;
    pub const preScanStmt = prescan_mod.preScanStmt;
    pub const stmtTerminates = prescan_mod.stmtTerminates;
    pub const emitAssignment = stmt_mod.emitAssignment;
    pub const emitBoolCondition = stmt_mod.emitBoolCondition;
    pub const emitBreak = stmt_mod.emitBreak;
    pub const emitCondFor = stmt_mod.emitCondFor;
    pub const emitCondition = stmt_mod.emitCondition;
    pub const emitContinue = stmt_mod.emitContinue;
    pub const emitEqualityCode = stmt_mod.emitEqualityCode;
    pub const emitExprStatement = stmt_mod.emitExprStatement;
    pub const emitForStmt = stmt_mod.emitForStmt;
    pub const emitIfBody = stmt_mod.emitIfBody;
    pub const emitIfChain = stmt_mod.emitIfChain;
    pub const emitIfStmt = stmt_mod.emitIfStmt;
    pub const emitIfValue = stmt_mod.emitIfValue;
    pub const emitLineMarker = stmt_mod.emitLineMarker;
    pub const emitLocalDeclaration = stmt_mod.emitLocalDeclaration;
    pub const emitProngBody = stmt_mod.emitProngBody;
    pub const emitRangeFor = stmt_mod.emitRangeFor;
    pub const emitStatements = stmt_mod.emitStatements;
    pub const emitStmt = stmt_mod.emitStmt;
    pub const emitSwitchChain = stmt_mod.emitSwitchChain;
    pub const emitSwitchCondition = stmt_mod.emitSwitchCondition;
    pub const emitSwitchStmt = stmt_mod.emitSwitchStmt;
    pub const emitSwitchValue = stmt_mod.emitSwitchValue;
    pub const findBreakTarget = stmt_mod.findBreakTarget;
    pub const findLoopTarget = stmt_mod.findLoopTarget;
    pub const forBody = stmt_mod.forBody;
    pub const loopLabelUsed = stmt_mod.loopLabelUsed;
    pub const switchScrutineeType = stmt_mod.switchScrutineeType;
    pub const emitBinary = expr_mod.emitBinary;
    pub const emitCall = expr_mod.emitCall;
    pub const emitComparison = expr_mod.emitComparison;
    pub const emitExpr = expr_mod.emitExpr;
    pub const emitF32Operand = expr_mod.emitF32Operand;
    pub const emitF64Operand = expr_mod.emitF64Operand;
    pub const emitFloatBinary = expr_mod.emitFloatBinary;
    pub const emitI64Operand = expr_mod.emitI64Operand;
    pub const emitIntBinary = expr_mod.emitIntBinary;
    pub const emitLiteral = expr_mod.emitLiteral;
    pub const emitStrongCoercion = expr_mod.emitStrongCoercion;
    pub const emitUnary = expr_mod.emitUnary;
    pub const emitValueCoerced = expr_mod.emitValueCoerced;
    pub const emitValueCoercedForce = expr_mod.emitValueCoercedForce;
    pub const emitValueCoercedMode = expr_mod.emitValueCoercedMode;
    pub const f64Code = expr_mod.f64Code;
    pub const i64Code = expr_mod.i64Code;
    pub const isStringy = expr_mod.isStringy;
    pub const wrapWidth = expr_mod.wrapWidth;
};

pub fn isImportDecl(decl: *const ast_mod.Declaration) bool {
    if (decl.value.* != .call) return false;
    const c = decl.value.call;
    return c.callee.* == .primary and std.mem.eql(u8, c.callee.primary.name, "@import");
}

fn isByteSliceDisplay(clean: []const u8) bool {
    if (std.mem.eql(u8, clean, "string") or std.mem.eql(u8, clean, "[]byte") or
        std.mem.eql(u8, clean, "[]u8")) return true;
    const elem = (from_ast.arrayElemDisplay(std.heap.page_allocator, clean) catch return false) orelse return false;
    defer std.heap.page_allocator.free(elem);
    return std.mem.eql(u8, elem, "byte") or std.mem.eql(u8, elem, "u8");
}
