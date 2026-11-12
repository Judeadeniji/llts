//! Zig code emitter — translates analyzed LLTS AST into runtime-driving Zig source.
//!
//! Emission strategy:
//!   - Each LLTS @func → `fn lls_fn_*(ctx: *rt.Context, ...) anyerror!RetType`
//!   - Local variables and parameters → unboxed native Zig variables
//!   - Frame watermark RAII → `const mark = ctx.enterFunction(...); defer ctx.leaveFunction(mark);`
//!   - Top-level code → `lls_top_level(ctx)` initializing globals then running statements
//!   - Entry wrapper → `pub fn main()` wiring Context + the LLTS-owned trap sink
//!
//! Supported subset: functions, returns, locals, scalar arithmetic,
//! comparisons, string concatenation, `print`, structured `@if`, scalar
//! `@switch`, loops, aggregates (structs/arrays/slices/optionals/pointers),
//! error values and unions, struct methods (pointer and by-value `self`),
//! and `@import` modules (qualified calls, structs, and globals). Calls are
//! resolved during typecheck and recorded in `state.call_targets`; using a function
//! as a runtime value is rejected. Remaining gaps (native `__*` std backends) are
//! rejected with a compile-time diagnostic. The LLTS typechecker owns semantic
//! validation; the emitter only rejects shapes it cannot lower and never adds
//! its own runtime assertions.
const std = @import("std");
const ast_mod = @import("../../../ast/root.zig");
const state_mod = @import("../../state.zig");
const reachability = @import("../../reachability.zig");
const from_ast = @import("../../typecheck/from_ast.zig");
const ir = @import("../../typecheck/ir.zig");
const path_mod = @import("../../expr/path.zig");
const widths = @import("../../widths.zig");
const compile_errors = @import("../../../errors/compile.zig");
const root_mod = @import("../root.zig");
const unit_mod = @import("unit.zig");
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
    union_,
    array,
    slice,
    optional,
    pointer,
    null_value,
    error_value,
    func,
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
    /// Read-only view (`const []T` / `const [N]T`): writes through it are rejected.
    is_const: bool = false,

    pub fn isI64(self: ValType) bool {
        return self.kind == .int and self.width != null and
            (self.width.? == .i64 or self.width.? == .isize);
    }

    pub fn isU64(self: ValType) bool {
        return self.kind == .int and self.width != null and
            (self.width.? == .u64 or self.width.? == .usize);
    }

    pub fn isByteSequence(self: ValType) bool {
        if (self.kind == .string) return true;
        if ((self.kind == .slice or self.kind == .array) and self.elem != null and std.mem.eql(u8, self.elem.?.zig, "u8")) return true;
        return false;
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
    name: []const u8 = "",
    zig_name: []const u8,
    size: usize,
    fields: []StructField = &.{},
    field_index: std.StringHashMap(usize),
    is_tuple: bool = false,
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
    /// Compiler-recorded type for this binding; null for devirtualized
    /// function/module values and synthesized captures.
    ir_type: ?ir.Type = null,
    assigned: bool = false,
    reassigned: bool = false,
    read: bool = false,
    is_param: bool = false,
    /// Statically known function value (devirtualized — no Zig variable).
    fn_key: ?[]const u8 = null,
    /// Module namespace value — no runtime representation.
    module_path: ?[]const u8 = null,
};

pub const Global = struct {
    name: []const u8,
    zig_name: []const u8,
    display: []const u8,
    /// Compiler-recorded type of the binding; null for function/module values.
    ir_type: ?ir.Type = null,
    node: *ast_mod.Node,
    /// Statically known function value (`$f = add;` / `$p = mod.fn;`).
    fn_key: ?[]const u8 = null,
    /// Module namespace value (`$m = std.fmt;`) — no runtime representation.
    module_path: ?[]const u8 = null,
};

pub const ParamInfo = struct {
    name: []const u8,
    arg_name: []const u8,
    display: []const u8,
    ir_type: ?ir.Type = null,
    zig: []const u8,
    kind: ValKind,
};

pub const UnionVariant = struct {
    name: []const u8,
    zig_name: []const u8,
    vt: ValType,
    arm_ir: ir.Type,
};

pub const UnionType = struct {
    key: []const u8,
    zig_name: []const u8,
    size: i32,
    discrim_field: ?[]const u8 = null,
    enum_name: ?[]const u8 = null,
    variants: []UnionVariant,
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

/// A labeled `@switch` lowered to a generated wrapper loop so that
/// `continue :label value` can re-run dispatch with a new scrutinee.
pub const SwitchContinueTarget = struct {
    /// LLTS label of the labeled `@switch`.
    label: []const u8,
    /// Generated Zig label on the wrapper loop.
    zig_label: []const u8,
    /// Generated Zig variable holding the current scrutinee.
    scrut_name: []const u8,
    scrut_type: ValType,
    scope_depth: usize = 0,
};

pub const TraceSite = struct {
    func_name: []const u8,
    file: []const u8,
    line: u32,
    column: u32,
};

pub const Emitter = struct {
    allocator: std.mem.Allocator,
    writer: std.io.AnyWriter,
    options: root_mod.EmitOptions,
    arena: std.heap.ArenaAllocator,
    doc: *ast_mod.Document,
    state: *CompilerState,

    reach: ?*const reachability.Result = null,
    runtime_path: []const u8 = "",
    globals: std.StringHashMap(*Global),
    struct_types: std.ArrayList(*StructType) = .empty,
    struct_by_key: std.StringHashMap(*StructType),
    union_types: std.ArrayList(*UnionType) = .empty,
    union_by_key: std.StringHashMap(*UnionType),
    scopes: std.ArrayList(std.StringHashMap(*Binding)) = .empty,
    defer_scopes: std.ArrayList(std.ArrayList(DeferEntry)) = .empty,
    infos: std.AutoHashMap(*ast_mod.Node, *Binding),
    params: std.ArrayList(ParamInfo) = .empty,
    break_targets: std.ArrayList(BreakTarget) = .empty,
    loop_targets: std.ArrayList(LoopTarget) = .empty,
    switch_targets: std.ArrayList(SwitchContinueTarget) = .empty,
    trace_sites: std.ArrayList(TraceSite) = .empty,
    current_trace_func: ?[]const u8 = null,
    current_trace_file: []const u8 = "",
    cur_ret: ValType = undefined,
    counter: usize = 0,
    indent: usize = 1,

    pub const Resolved = struct {
        zig_name: []const u8,
        display: []const u8,
        ir_type: ?ir.Type = null,
    };

    /// Lower a compiler-recorded type. Without a record (or when the recorded
    /// shape has no runtime projection) the result is the unsupported `other`
    /// kind carrying the recorded display; no display string is re-parsed.
    pub fn valTypeFor(
        self: *Emitter,
        node: *ast_mod.Node,
        t: ?ir.Type,
        display: []const u8,
    ) anyerror!ValType {
        if (t) |ty| {
            if (try self.valTypeFromIR(node, ty)) |vt| return vt;
        }
        return .{ .display = display, .clean = display, .kind = .other, .zig = "void" };
    }

    /// Lower a compiler-recorded type that the run must be able to represent.
    pub fn valTypeOfIR(self: *Emitter, node: *ast_mod.Node, t: ir.Type) anyerror!ValType {
        if (try self.valTypeFromIR(node, t)) |vt| return vt;
        const d = try ir.displayTypeQualifiedAlloc(self.arena.allocator(), t);
        return self.failAt(node, "native backend (Phase 2) does not support type '{s}'", .{d});
    }

    /// Compiler-recorded type of a declaration binding: its annotation when
    /// present (authoritative), else the recorded initializer type.
    pub fn declaredIRType(self: *Emitter, d: *const ast_mod.Declaration) ?ir.Type {
        if (d.type_annotation) |ann| {
            return from_ast.typeFromAst(ann, self.state, self.state.typeAlloc()) catch null;
        }
        return self.state.type_ir_of_results.get(d.value);
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
        const is_tuple = clean.len > 0 and clean[0] == '[' and std.mem.indexOfScalar(u8, clean, ',') != null;
        const base_name = if (std.mem.lastIndexOf(u8, def.name, "::")) |idx|
            def.name[idx + 2 ..]
        else if (std.mem.lastIndexOfScalar(u8, def.name, '.')) |idx|
            def.name[idx + 1 ..]
        else
            def.name;
        const struct_name = if (base_name.len > 0 and (base_name[0] == '{' or base_name[0] == '['))
            ""
        else
            base_name;
        info.* = .{
            .key = def.name,
            .name = struct_name,
            .zig_name = try std.fmt.allocPrint(a, "lls_t_{s}", .{try self.mangle(def.name)}),
            .size = @intCast(def.size),
            .field_index = std.StringHashMap(usize).init(a),
            .is_tuple = is_tuple,
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
            const vt = try self.valTypeFor(node, def.field_irs.get(seed.name), seed.display);
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

    /// Struct layout behind a lowered type (`T`, `*T`, `?T`, `T | error`): peels
    /// the handles the projection already produced instead of parsing them.
    pub fn structInfoForValType(self: *Emitter, node: *ast_mod.Node, t_in: ValType) anyerror!?*StructType {
        var vt = t_in;
        while (true) {
            switch (vt.kind) {
                .struct_ => break,
                .pointer, .optional => vt = (vt.payload orelse return null).*,
                else => return null,
            }
        }
        if (from_ast.lookupStruct(self.state, vt.display) == null) return null;
        return try self.ensureStructType(node, vt.display);
    }

    pub fn emitStructTypeDecls(self: *Emitter) !void {
        var i: usize = 0;
        while (i < self.struct_types.items.len) : (i += 1) {
            const info = self.struct_types.items[i];
            try self.writer.print("const {s} = struct {{\n", .{info.zig_name});
            for (info.fields) |field| {
                try self.writer.print("    {s}: {s},\n", .{ field.zig_name, field.vt.zig });
            }
            if (info.is_tuple) {
                try self.writer.writeAll("    pub const is_tuple = true;\n");
            }
            try self.writer.print("    pub const lls_struct_name = \"{s}\";\n", .{info.name});
            try self.writer.writeAll("    pub const lls_field_names = [_][]const u8{\n");
            for (info.fields) |field| {
                try self.writer.print("        \"{s}\",\n", .{field.name});
            }
            try self.writer.writeAll("    };\n");
            try self.writer.print("\n    pub fn to_bytes(self: @This()) [{d}]u8 {{\n", .{info.size});
            try self.writer.print("        return lls_bytes_{s}(self);\n", .{info.zig_name});
            try self.writer.writeAll("    }\n");
            try self.writer.writeAll("};\n\n");

            var has_scalar = false;
            for (info.fields) |field| {
                if (field.vt.width != null and
                    (field.vt.kind == .int or field.vt.kind == .bool or field.vt.kind == .float))
                {
                    has_scalar = true;
                }
                if (field.vt.kind == .struct_) {
                    has_scalar = true;
                }
                if (field.vt.kind == .array and field.vt.elem != null and
                    (field.vt.elem.?.kind == .int or field.vt.elem.?.kind == .bool or field.vt.elem.?.kind == .float or field.vt.elem.?.kind == .struct_))
                {
                    has_scalar = true;
                }
            }
            try self.writer.print("fn lls_bytes_{s}(v: {s}) [{d}]u8 {{\n", .{ info.zig_name, info.zig_name, info.size });
            if (!has_scalar) {
                try self.writer.writeAll("    _ = v;\n");
                try self.writer.print("    return [_]u8{{0}} ** {d};\n}}\n\n", .{info.size});
                continue;
            }
            try self.writer.print("    var out = [_]u8{{0}} ** {d};\n", .{info.size});
            for (info.fields) |field| {
                if (field.vt.width) |w| {
                    if (field.vt.kind == .int or field.vt.kind == .bool or field.vt.kind == .float) {
                        try self.writer.print("    @memcpy(out[{d}..][0..{d}], std.mem.asBytes(&v.{s}));\n", .{
                            field.offset, w.size(), field.zig_name,
                        });
                    }
                } else if (field.vt.kind == .struct_) {
                    const inner_info = self.struct_by_key.get(field.vt.clean) orelse self.struct_by_key.get(field.vt.display);
                    if (inner_info) |ii| {
                        try self.writer.print("    const lls_nested_{s} = lls_bytes_{s}(v.{s});\n", .{ field.zig_name, ii.zig_name, field.zig_name });
                        try self.writer.print("    @memcpy(out[{d}..][0..{d}], &lls_nested_{s});\n", .{ field.offset, ii.size, field.zig_name });
                    }
                } else if (field.vt.kind == .array and field.vt.elem != null) {
                    if (field.vt.elem.?.kind == .int or field.vt.elem.?.kind == .bool or field.vt.elem.?.kind == .float) {
                        try self.writer.print("    @memcpy(out[{d}..][0..@sizeOf(@TypeOf(v.{s}))], std.mem.asBytes(&v.{s}));\n", .{
                            field.offset, field.zig_name, field.zig_name,
                        });
                    } else if (field.vt.elem.?.kind == .struct_) {
                        const elem_info = self.struct_by_key.get(field.vt.elem.?.clean) orelse self.struct_by_key.get(field.vt.elem.?.display);
                        if (elem_info) |ei| {
                            try self.writer.print("    for (v.{s}, 0..) |elem, idx| {{\n", .{field.zig_name});
                            try self.writer.print("        const lls_elem_bytes = lls_bytes_{s}(elem);\n", .{ei.zig_name});
                            try self.writer.print("        @memcpy(out[{d} + idx * {d}..][0..{d}], &lls_elem_bytes);\n", .{ field.offset, ei.size, ei.size });
                            try self.writer.writeAll("    }\n");
                        }
                    }
                }
            }
            try self.writer.writeAll("    return out;\n}\n\n");
        }
    }

    pub fn ensureUnionType(self: *Emitter, node: *ast_mod.Node, display: []const u8) anyerror!*UnionType {
        const clean = std.mem.trim(u8, display, " \t");
        const udef = from_ast.lookupUnion(self.state, clean) orelse {
            return self.failAt(node, "native backend cannot resolve union type '{s}'", .{clean});
        };
        if (self.union_by_key.get(udef.name)) |info| return info;

        const a = self.arena.allocator();
        const info = try a.create(UnionType);
        info.* = .{
            .key = udef.name,
            .zig_name = try std.fmt.allocPrint(a, "lls_u_{s}", .{try self.mangle(udef.name)}),
            .size = udef.size,
            .discrim_field = udef.discrim_field,
            .enum_name = udef.enum_name,
            .variants = &.{},
        };
        try self.union_by_key.put(udef.name, info);
        try self.union_types.append(a, info);

        var variants = std.ArrayList(UnionVariant).empty;
        for (udef.arm_names, udef.arm_irs, 0..) |arm_name, arm_ir, i| {
            const vt = try self.valTypeFor(node, arm_ir, arm_name);
            const vname = cleanVariantName(a, arm_name, i);
            try variants.append(a, .{
                .name = arm_name,
                .zig_name = vname,
                .vt = vt,
                .arm_ir = arm_ir,
            });
        }
        info.variants = try variants.toOwnedSlice(a);
        return info;
    }

    fn cleanVariantName(a: std.mem.Allocator, name: []const u8, idx: usize) []const u8 {
        var valid = true;
        for (name) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') {
                valid = false;
                break;
            }
        }
        if (valid and name.len > 0 and !std.ascii.isDigit(name[0])) return name;
        return std.fmt.allocPrint(a, "v{d}", .{idx}) catch "v";
    }

    pub fn emitUnionTypeDecls(self: *Emitter) !void {
        var i: usize = 0;
        while (i < self.union_types.items.len) : (i += 1) {
            const info = self.union_types.items[i];
            try self.writer.print("const {s} = union(enum) {{\n", .{info.zig_name});
            for (info.variants) |v| {
                try self.writer.print("    {s}: {s},\n", .{ v.zig_name, v.vt.zig });
            }
            if (info.discrim_field) |df| {
                try self.writer.print("\n    pub fn get_{s}(self: @This()) i64 {{\n", .{df});
                try self.writer.writeAll("        return switch (self) {\n");
                for (info.variants) |v| {
                    try self.writer.print("            .{s} => |val| val.f0,\n", .{v.zig_name});
                }
                try self.writer.writeAll("        };\n    }\n");
            }
            try self.writer.writeAll("};\n\n");
        }
    }

    pub fn deinit(self: *Emitter) void {
        self.globals.deinit();
        self.struct_by_key.deinit();
        self.union_by_key.deinit();
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

    /// True when a node is a call to the compile-time `@typeOf` intrinsic.
    pub fn isTypeOfCall(node: *ast_mod.Node) bool {
        return node.* == .call and node.call.callee.* == .primary and
            std.mem.eql(u8, node.call.callee.primary.name, "@typeOf");
    }

    /// True when a node is a call to the compile-time `@sizeOf` intrinsic.
    pub fn isSizeOfCall(node: *ast_mod.Node) bool {
        return node.* == .call and node.call.callee.* == .primary and
            std.mem.eql(u8, node.call.callee.primary.name, "@sizeOf");
    }

    /// Typecheck's recorded identity for an expression node. `type_of_results`
    /// is a derived cache of this IR, so codegen lowers the IR rather than a
    /// re-derived display string.
    pub fn recordedType(self: *Emitter, node: *ast_mod.Node) ?ir.Type {
        const t = self.state.type_ir_of_results.get(node) orelse return null;
        if (t == .unknown) return null;
        return t;
    }

    /// Flatten a union's arms through aliases and nested unions so `int | AppError`
    /// (where `AppError = IoError | HttpError`) classifies as one success plus
    /// error arms instead of two opaque success arms.
    fn appendUnionArms(a: std.mem.Allocator, out: *std.ArrayList(ir.Type), arms: []const ir.Type) !void {
        for (arms) |arm| {
            switch (ir.peelDefined(arm)) {
                .union_ => |inner| try appendUnionArms(a, out, inner),
                .never => {},
                else => try out.append(a, arm),
            }
        }
    }

    /// Project a recorded compiler type onto the emitter's `ValType`.
    /// Returns null for shapes the run has no representation for (tuples,
    /// function values, singletons, plain non-error unions); callers report
    /// them as unsupported instead of re-parsing a display string.
    pub fn valTypeFromIR(self: *Emitter, node: *ast_mod.Node, t_in: ir.Type) anyerror!?ValType {
        const a = self.arena.allocator();
        const display = try ir.displayTypeQualifiedAlloc(a, t_in);
        const t = ir.peelDefined(t_in);
        var vt: ValType = .{ .display = display, .clean = display, .kind = .other, .zig = "void" };

        if (ir.widthOf(t)) |w| {
            vt.width = w;
            if (w.isFloat()) {
                vt.kind = .float;
                vt.zig = switch (w.concrete()) {
                    .f32 => "f32",
                    else => "f64",
                };
            } else {
                vt.kind = if (w == .u1) .bool else .int;
                vt.zig = switch (w.concrete()) {
                    .i8 => "i8",
                    .i16 => "i16",
                    .i32 => "i32",
                    .i64 => "i64",
                    .u1 => "bool",
                    .u8 => "u8",
                    .u16 => "u16",
                    .u32 => "u32",
                    .u64 => "u64",
                    else => "i64",
                };
            }
            return vt;
        }

        switch (t) {
            .null => {
                vt.kind = .null_value;
                vt.zig = "@TypeOf(null)";
            },
            .void => {
                vt.kind = .void;
                vt.zig = "void";
            },
            .func => |f| {
                vt.kind = .func;
                const ret_vt = (try self.valTypeFromIR(node, f.ret.*)) orelse return null;
                var param_zigs: std.ArrayList([]const u8) = .empty;
                try param_zigs.append(a, "*rt.Context");
                for (f.params) |p| {
                    const p_vt = (try self.valTypeFromIR(node, p)) orelse return null;
                    try param_zigs.append(a, p_vt.zig);
                }
                const params_joined = try std.mem.join(a, ", ", param_zigs.items);
                vt.zig = try std.fmt.allocPrint(a, "*const fn({s}) anyerror!{s}", .{
                    params_joined,
                    ret_vt.zig,
                });
                return vt;
            },
            .error_, .error_set, .error_lit => {
                vt.kind = .error_value;
                vt.clean = "error";
                vt.zig = "rt.err.Error";
                vt.may_error = true;
            },
            .array => |arr| {
                const elem = (try self.valTypeFromIR(node, arr.elem.*)) orelse return null;
                const elem_p = try a.create(ValType);
                elem_p.* = elem;
                vt.elem = elem_p;
                vt.array_len = arr.length;
                vt.is_const = arr.is_const;
                if (arr.is_const and arr.length == null and std.mem.eql(u8, elem.zig, "u8")) {
                    vt.kind = .string;
                    vt.zig = "[]const u8";
                    return vt;
                }
                if (arr.length) |len| {
                    vt.kind = .array;
                    vt.zig = try std.fmt.allocPrint(a, "[{d}]{s}", .{ len, elem.zig });
                } else {
                    vt.kind = .slice;
                    vt.zig = if (arr.is_const)
                        try std.fmt.allocPrint(a, "[]const {s}", .{elem.zig})
                    else
                        try std.fmt.allocPrint(a, "[]{s}", .{elem.zig});
                }
            },
            .ptr => |p| {
                const payload = (try self.valTypeFromIR(node, p.*)) orelse return null;
                const payload_p = try a.create(ValType);
                payload_p.* = payload;
                vt.kind = .pointer;
                vt.payload = payload_p;
                vt.zig = try std.fmt.allocPrint(a, "*{s}", .{payload.zig});
            },
            .shape, .tuple => {
                // Keep the declared identity (`@type Point = { … };` is emitted
                // as `Point`, not as a second layout for the shape spelling).
                const info = try self.ensureStructType(node, display);
                vt.kind = .struct_;
                vt.clean = display;
                vt.zig = info.zig_name;
            },
            .struct_ => |name| {
                if (std.mem.startsWith(u8, name, "module:")) return null;
                const info = try self.ensureStructType(node, name);
                vt.kind = .struct_;
                vt.zig = info.zig_name;
            },
            .enum_, .enum_lit => {
                const is_string = (try self.enumKind(display)) orelse return null;
                if (is_string) {
                    vt.kind = .string;
                    vt.zig = "[]const u8";
                } else {
                    vt.kind = .int;
                    vt.width = .i64;
                    vt.zig = "i64";
                }
            },
            .str_lit => {
                vt.kind = .string;
                vt.zig = "[]const u8";
                vt.is_const = true;
            },
            .int_lit => {
                vt.kind = .int;
                vt.width = .i64;
                vt.zig = "i64";
            },
            .bool_lit => {
                vt.kind = .bool;
                vt.width = .u1;
                vt.zig = "bool";
            },
            .union_ => |arms| {
                var has_error = false;
                var has_null = false;
                var success: ?ir.Type = null;
                var extra_success = false;
                var flat: std.ArrayList(ir.Type) = .empty;
                defer flat.deinit(a);
                try appendUnionArms(a, &flat, arms);
                for (flat.items) |arm| switch (ir.peelDefined(arm)) {
                    .error_, .error_set, .error_lit => has_error = true,
                    .null => has_null = true,
                    else => {
                        if (success == null) success = arm else extra_success = true;
                    },
                };
                if (!extra_success and success != null) {
                    // Gradual `unknown | error`: no success value is known yet, so
                    // at runtime the value is a bare error.
                    if (has_error and ir.isUnknown(success.?)) {
                        vt.kind = .error_value;
                        vt.clean = "error";
                        vt.zig = "rt.err.Error";
                        vt.may_error = true;
                        return vt;
                    }
                    const raw_inner = (try self.valTypeFromIR(node, success.?)) orelse return null;
                    const inner: ValType = if (has_null and has_error) blk: {
                        const raw_p = try a.create(ValType);
                        raw_p.* = raw_inner;
                        break :blk .{
                            .display = try std.fmt.allocPrint(a, "?{s}", .{raw_inner.display}),
                            .clean = raw_inner.clean,
                            .kind = .optional,
                            .payload = raw_p,
                            .zig = try std.fmt.allocPrint(a, "?{s}", .{raw_inner.zig}),
                        };
                    } else raw_inner;
                    const inner_p = try a.create(ValType);
                    inner_p.* = inner;
                    if (has_error) {
                        vt = inner;
                        vt.display = display;
                        vt.clean = try ir.displayTypeQualifiedAlloc(a, success.?);
                        vt.may_error = true;
                        vt.success = inner_p;
                        vt.zig = try std.fmt.allocPrint(a, "rt.err.Result({s})", .{inner.zig});
                    } else {
                        vt.kind = .optional;
                        vt.payload = inner_p;
                        vt.zig = try std.fmt.allocPrint(a, "?{s}", .{inner.zig});
                    }
                    return vt;
                }
                if (success == null and has_error and !has_null) {
                    vt.kind = .error_value;
                    vt.clean = "error";
                    vt.zig = "rt.err.Error";
                    vt.may_error = true;
                    return vt;
                }
                const uinfo = try self.ensureUnionType(node, display);
                vt.kind = .union_;
                vt.clean = display;
                vt.zig = uinfo.zig_name;
                if (has_error) vt.may_error = true;
            },
            else => return null,
        }
        return vt;
    }

    pub fn emit(self: *Emitter) !void {
        if (self.state.reachability == null) {
            self.state.reachability = try reachability.compute(self.state, self.doc);
        }
        self.reach = &self.state.reachability.?;
        self.runtime_path = std.fs.cwd().realpathAlloc(self.arena.allocator(), self.options.runtime_path) catch {
            return self.failNoLoc("runtime path '{s}' not found (pass --runtime-path)", .{self.options.runtime_path});
        };

        try unit_mod.collectGlobals(self);

        try self.writer.writeAll("// Generated by `llts emit-zig` — do not edit.\n");
        try self.writer.writeAll("const std = @import(\"std\");\n");
        try self.writer.writeAll("const rt = @import(");
        try self.writer.writeAll(try self.zigString(self.runtime_path));
        try self.writer.writeAll(");\n\n");

        try unit_mod.emitGlobalDecls(self);
        try unit_mod.emitFunctions(self);
        try unit_mod.emitTopLevel(self);
        try self.emitTraceSiteTable();
        try unit_mod.emitEntry(self);
        try self.emitStructTypeDecls();
        try self.emitUnionTypeDecls();
    }

    pub fn addTraceSite(self: *Emitter, func_name: []const u8, file: []const u8, line: u32, column: u32) !u32 {
        if (self.trace_sites.items.len > std.math.maxInt(u32)) {
            return self.failNoLoc("native trace site table exceeds {d} entries", .{std.math.maxInt(u32)});
        }
        const id: u32 = @intCast(self.trace_sites.items.len);
        try self.trace_sites.append(self.arena.allocator(), .{
            .func_name = func_name,
            .file = file,
            .line = line,
            .column = column,
        });
        return id;
    }

    pub fn emitTraceSiteTable(self: *Emitter) !void {
        try self.writer.writeAll("const lls_trace_sites = [_]rt.trace.Site{\n");
        for (self.trace_sites.items) |site| {
            try self.writer.print("    .{{ .func_name = {s}, .file = {s}, .line = {d}, .column = {d} }},\n", .{
                try self.zigString(site.func_name),
                try self.zigString(site.file),
                site.line,
                site.column,
            });
        }
        try self.writer.writeAll("};\n\n");
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

    pub const ReceiverMode = enum { none, pointer, value };

    pub const MethodTarget = struct {
        key: []const u8,
        mode: ReceiverMode,
        receiver_is_pointer: bool,
    };

    /// Resolve `object.method` to its `Type::method` definition when the object
    /// is a struct (or `*struct`) and `method` is not a field.
    pub fn methodTarget(self: *Emitter, member: *ast_mod.Node) anyerror!?MethodTarget {
        if (member.* != .member) return null;
        const target = self.state.call_targets.get(member) orelse return null;
        if (target.receiver_mode == .none) return null;
        const recv_t = try self.valueType(member.member.object);
        return .{
            .key = target.key,
            .mode = switch (target.receiver_mode) {
                .none => .none,
                .pointer => .pointer,
                .value => .value,
            },
            .receiver_is_pointer = recv_t.kind == .pointer,
        };
    }

    /// The call's arguments that exist at runtime. A generic call's leading
    /// arguments are compile-time type arguments, so they are not passed.
    pub fn runtimeArgs(self: *Emitter, node: *ast_mod.Node, c: *const ast_mod.Call) []*ast_mod.Node {
        if (self.state.generic_calls.get(node)) |gc| {
            const n = @min(gc.value_args, c.args.len);
            return c.args[c.args.len - n ..];
        }
        return c.args;
    }

    pub fn lookupBindingOptional(self: *Emitter, name: []const u8) ?*Binding {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].get(name)) |b| return b;
        }
        return null;
    }

    /// Module namespace value (`std.fmt`, `lib.sub`) or null.
    pub fn resolveModuleValue(self: *Emitter, node: *ast_mod.Node) ?[]const u8 {
        const a = self.arena.allocator();
        switch (node.*) {
            .primary => |p| {
                if (p.kind != .identifier and p.kind != .register) return null;
                const mod = path_mod.aliasModuleType(self.state, p.name) orelse return null;
                if (std.mem.startsWith(u8, mod, "module:")) return mod["module:".len..];
                return null;
            },
            .member => |m| {
                if (m.property.* != .primary) return null;
                const obj_path = (path_mod.tryResolveStaticPath(self.state, m.object) catch null) orelse return null;
                const key = std.fmt.allocPrint(a, "${s}::{s}", .{ obj_path, m.property.primary.name }) catch return null;
                const ty = self.state.global_types.get(key) orelse return null;
                if (std.mem.startsWith(u8, ty, "module:")) return ty["module:".len..];
                return null;
            },
            else => return null,
        }
    }

    pub fn isPlaceNode(node: *ast_mod.Node) bool {
        return switch (node.*) {
            .primary => |p| p.kind == .identifier or p.kind == .register,
            .member, .index => true,
            else => false,
        };
    }

    /// Struct canon name for a method function key (`Type::method`), or null
    /// for ordinary functions and module exports (`std/fmt.lls::sprintf`).
    /// The struct a function key belongs to: everything before the last `::`,
    /// whether the key is `Type::method`, `module::Type::method`, or a generic
    /// instance `Type(T)::method`. A free module function's prefix is not a
    /// struct, so it resolves to null.
    pub fn methodStructFor(self: *Emitter, name: []const u8) ?[]const u8 {
        const sep = std.mem.lastIndexOf(u8, name, "::") orelse return null;
        const prefix = name[0..sep];
        const sd = from_ast.lookupStruct(self.state, prefix) orelse return null;
        return sd.name;
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
            .union_by_key = std.StringHashMap(*UnionType).init(allocator),
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
                return .{ .zig_name = b.zig_name, .display = b.display, .ir_type = b.ir_type };
            }
        }
        if (self.globals.get(name)) |g| {
            return .{ .zig_name = g.zig_name, .display = g.display, .ir_type = g.ir_type };
        }
        if (self.state.functions.get(name)) |_| {
            const zname = try self.fnName(name);
            const rec_ir = self.recordedType(node);
            return .{ .zig_name = zname, .display = "@func", .ir_type = rec_ir };
        }
        if (self.state.fn_aliases.get(name)) |aliased| {
            const zname = try self.fnName(aliased);
            const rec_ir = self.recordedType(node);
            return .{ .zig_name = zname, .display = "@func", .ir_type = rec_ir };
        }
        return self.failAt(node, "native backend cannot resolve '{s}'", .{name});
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
        if (statements.len > 0 and (self.state.terminates.get(statements[statements.len - 1]) orelse false)) return;
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
            const stored = try self.valTypeFor(node, b.ir_type, b.display);
            if (stored.may_error and stored.kind != .error_value) return stored;
        }
        return narrowed;
    }

    pub fn valueType(self: *Emitter, node: *ast_mod.Node) anyerror!ValType {
        if (isTypeOfCall(node)) return try self.valTypeOfIR(node, ir.TString);
        if (isSizeOfCall(node)) return try self.valTypeOfIR(node, ir.TI64);
        if (self.recordedType(node)) |t| {
            if (try self.valTypeFromIR(node, t)) |vt| return vt;
        }
        // A call recorded while its callee was still unrefined (mutual
        // recursion, forward calls) keeps a stale `unknown`; re-resolve it
        // through the callee's final recorded return type.
        if (node.* == .call) {
            const target = self.state.call_targets.get(node) orelse self.state.call_targets.get(node.call.callee);
            if (target) |t| {
                if (self.state.functions.get(t.key)) |def| {
                    return try unit_mod.functionReturnType(self, t.key, def);
                }
            }
        }
        return self.failAt(node, "native backend cannot infer the type of this expression", .{});
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
