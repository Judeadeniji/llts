//! LLVM IR codegen for statements and function bodies.

const std = @import("std");
const llvm = @import("llvm");
const T = llvm.types;
const C = llvm.core;
const ast = @import("../../ast/root.zig");
const context = @import("context.zig");
const expr_mod = @import("expr.zig");
const types_mod = @import("types.zig");
const from_ast = @import("../typecheck/from_ast.zig");

fn buildBrIfNoTerm(builder: T.LLVMBuilderRef, dest: T.LLVMBasicBlockRef) void {
    const curr_bb = C.LLVMGetInsertBlock(builder);
    if (curr_bb != null and C.LLVMGetBasicBlockTerminator(curr_bb) == null) {
        _ = C.LLVMBuildBr(builder, dest);
    }
}

const LlvmContext = context.LlvmContext;
const ExprState = expr_mod.ExprState;

pub const StmtError = expr_mod.CodegenError || error{
    UnsupportedStatement,
};

pub const StmtState = struct {
    lc: *LlvmContext,
    locals: std.StringHashMap(T.LLVMValueRef),
    current_fn: T.LLVMValueRef,
    loop_cond_bbs: std.ArrayList(T.LLVMBasicBlockRef),
    loop_end_bbs: std.ArrayList(T.LLVMBasicBlockRef),
    /// defer / errdefer bodies to run on return (reverse order).
    defers: std.ArrayList(DeferEntry),

    const DeferEntry = struct {
        body: *ast.Node,
        is_errdefer: bool,
    };

    pub fn init(lc: *LlvmContext, fn_val: T.LLVMValueRef) StmtState {
        return .{
            .lc = lc,
            .locals = std.StringHashMap(T.LLVMValueRef).init(lc.allocator),
            .current_fn = fn_val,
            .loop_cond_bbs = .empty,
            .loop_end_bbs = .empty,
            .defers = .empty,
        };
    }

    pub fn deinit(self: *StmtState) void {
        self.locals.deinit();
        self.loop_cond_bbs.deinit(self.lc.allocator);
        self.loop_end_bbs.deinit(self.lc.allocator);
        self.defers.deinit(self.lc.allocator);
    }

    fn exprState(self: *StmtState) ExprState {
        return .{ .lc = self.lc, .locals = &self.locals };
    }
};

pub fn lowerStmt(s: *StmtState, node: *ast.Node) StmtError!void {
    switch (node.*) {
        .declaration => |decl| try lowerDecl(s, decl, node),
        .return_expr => |ret| try lowerReturn(s, ret),
        .block => |blk| try lowerBlock(s, blk),
        .if_expr => |iff| try lowerIf(s, iff),
        .switch_expr => |sw| try lowerSwitch(s, sw),
        .for_expr => |f| try lowerFor(s, f),
        .defer_stmt => |d| {
            try s.defers.append(s.lc.allocator, .{ .body = d.body, .is_errdefer = d.is_errdefer });
        },
        .break_expr => {
            if (s.loop_end_bbs.items.len > 0) {
                _ = C.LLVMBuildBr(s.lc.builder, s.loop_end_bbs.items[s.loop_end_bbs.items.len - 1]);
            } else return error.UnsupportedStatement;
        },
        .continue_expr => {
            if (s.loop_cond_bbs.items.len > 0) {
                _ = C.LLVMBuildBr(s.lc.builder, s.loop_cond_bbs.items[s.loop_cond_bbs.items.len - 1]);
            } else return error.UnsupportedStatement;
        },
        .call, .assignment, .binary, .unary, .literal, .primary,
        .member, .index, .array_literal, .struct_init, .try_expr, .error_expr => {
            var es = s.exprState();
            _ = try expr_mod.lowerExpr(&es, node);
        },
        else => return error.UnsupportedStatement,
    }
}

fn declTypeName(s: *StmtState, decl: ast.Declaration, node: *ast.Node) []const u8 {
    _ = node;
    if (decl.type_annotation) |ann| {
        if (from_ast.typeAstToDisplay(ann, s.lc.state)) |opt| {
            if (opt) |d| return d;
        } else |_| {}
    }
    if (s.lc.state.global_types.get(decl.name)) |gt| return gt;
    if (s.lc.state.type_of_results.get(decl.value)) |t| {
        if (!std.mem.eql(u8, t, "unknown")) return t;
    }
    return "i64";
}

fn lowerDecl(s: *StmtState, decl: ast.Declaration, node: *ast.Node) StmtError!void {
    const ty_name = declTypeName(s, decl, node);
    const ty = types_mod.resolveOrSlot(s.lc, ty_name);

    // Top-level / already-declared global: store into the global, don't re-alloca.
    if (s.lc.globals.get(decl.name)) |gslot| {
        if (decl.value.* == .literal and decl.value.literal.literal_type == .@"null") return;
        var es = s.exprState();
        const val = try expr_mod.lowerExpr(&es, decl.value);
        const gty = C.LLVMGlobalGetValueType(gslot);
        const val_ty_name = expr_mod.typeOf(&es, decl.value);
        _ = C.LLVMBuildStore(s.lc.builder, types_mod.castTo(s.lc, val, val_ty_name, gty), gslot);
        return;
    }

    const entry = C.LLVMGetEntryBasicBlock(s.current_fn);
    const entry_builder = C.LLVMCreateBuilderInContext(s.lc.ctx);
    defer C.LLVMDisposeBuilder(entry_builder);
    const first_instr = C.LLVMGetFirstInstruction(entry);
    if (first_instr != null)
        C.LLVMPositionBuilderBefore(entry_builder, first_instr)
    else
        C.LLVMPositionBuilderAtEnd(entry_builder, entry);

    const name_z = try s.lc.allocator.dupeZ(u8, decl.name);
    defer s.lc.allocator.free(name_z);
    const slot = C.LLVMBuildAlloca(entry_builder, ty, name_z);
    try s.locals.put(decl.name, slot);

    if (decl.value.* == .literal and decl.value.literal.literal_type == .@"null") return;

    var es = s.exprState();
    const val = try expr_mod.lowerExpr(&es, decl.value);
    const val_ty_name = expr_mod.typeOf(&es, decl.value);
    const casted = types_mod.castTo(s.lc, val, val_ty_name, ty);
    _ = C.LLVMBuildStore(s.lc.builder, casted, slot);
}

fn runDefers(s: *StmtState, is_error_path: bool) StmtError!void {
    var i = s.defers.items.len;
    while (i > 0) {
        i -= 1;
        const d = s.defers.items[i];
        if (d.is_errdefer and !is_error_path) continue;
        if (!d.is_errdefer or is_error_path) {
            try lowerStmt(s, d.body);
        }
    }
}

fn lowerReturn(s: *StmtState, ret: ast.Return) StmtError!void {
    try runDefers(s, false);
    if (ret.return_value) |rv| {
        var es = s.exprState();
        const val = try expr_mod.lowerExpr(&es, rv);
        const fn_ty = C.LLVMGlobalGetValueType(s.current_fn);
        const ret_ty = C.LLVMGetReturnType(fn_ty);
        if (C.LLVMGetTypeKind(ret_ty) == .LLVMVoidTypeKind) {
            _ = C.LLVMBuildRetVoid(s.lc.builder);
        } else {
            const val_ty_name = expr_mod.typeOf(&es, rv);
            _ = C.LLVMBuildRet(s.lc.builder, types_mod.castTo(s.lc, val, val_ty_name, ret_ty));
        }
    } else {
        const fn_ty = C.LLVMGlobalGetValueType(s.current_fn);
        const ret_ty = C.LLVMGetReturnType(fn_ty);
        if (C.LLVMGetTypeKind(ret_ty) == .LLVMVoidTypeKind) {
            _ = C.LLVMBuildRetVoid(s.lc.builder);
        } else {
            _ = C.LLVMBuildRet(s.lc.builder, C.LLVMConstNull(ret_ty));
        }
    }
}

fn lowerBlock(s: *StmtState, blk: ast.Block) StmtError!void {
    for (blk.statements) |st| try lowerStmt(s, st);
}

fn lowerIf(s: *StmtState, iff: ast.If) StmtError!void {
    var es = s.exprState();
    const cond_raw = try expr_mod.lowerExpr(&es, iff.condition);
    const fn_val = s.current_fn;

    // Coerce condition to i1: truncate wider ints, compare pointers to null.
    const cond = blk: {
        const ck = C.LLVMGetTypeKind(C.LLVMTypeOf(cond_raw));
        if (ck == .LLVMIntegerTypeKind and C.LLVMGetIntTypeWidth(C.LLVMTypeOf(cond_raw)) > 1) {
            break :blk C.LLVMBuildTrunc(s.lc.builder, cond_raw, s.lc.i1Ty(), "tobool");
        }
        if (ck == .LLVMPointerTypeKind) {
            const null_val = C.LLVMConstNull(C.LLVMTypeOf(cond_raw));
            break :blk C.LLVMBuildICmp(s.lc.builder, .LLVMIntNE, cond_raw, null_val, "tobool");
        }
        break :blk cond_raw;
    };

    const then_bb = C.LLVMAppendBasicBlockInContext(s.lc.ctx, fn_val, "then");
    const else_bb = C.LLVMAppendBasicBlockInContext(s.lc.ctx, fn_val, "else");
    const merge_bb = C.LLVMAppendBasicBlockInContext(s.lc.ctx, fn_val, "merge");

    _ = C.LLVMBuildCondBr(s.lc.builder, cond, then_bb, else_bb);

    C.LLVMPositionBuilderAtEnd(s.lc.builder, then_bb);

    // Bind the `@if (expr) |capture|` variable inside the then block.
    if (iff.pipe_value) |pv| {
        if (pv.* == .primary) {
            const cap_ty = C.LLVMTypeOf(cond_raw);
            const cap_name = try s.lc.allocator.dupeZ(u8, pv.primary.name);
            defer s.lc.allocator.free(cap_name);
            const slot = C.LLVMBuildAlloca(s.lc.builder, cap_ty, cap_name);
            _ = C.LLVMBuildStore(s.lc.builder, cond_raw, slot);
            try s.locals.put(pv.primary.name, slot);
        }
    }

    try lowerStmt(s, iff.body);
    buildBrIfNoTerm(s.lc.builder, merge_bb);

    C.LLVMPositionBuilderAtEnd(s.lc.builder, else_bb);
    if (iff.else_body) |eb| try lowerStmt(s, eb);
    buildBrIfNoTerm(s.lc.builder, merge_bb);

    C.LLVMPositionBuilderAtEnd(s.lc.builder, merge_bb);
}

fn lowerFor(s: *StmtState, f: ast.For) StmtError!void {
    if (f.captures.len > 0) {
        if (f.expr.* == .binary and std.mem.eql(u8, f.expr.binary.operator, "..")) {
            try lowerRangeFor(s, f);
        } else if (s.lc.state.for_is_cond.contains(&f)) {
            // @for (optional) |val| — poll-loop pattern
            try lowerOptionalFor(s, f);
        } else {
            try lowerIterFor(s, f);
        }
    } else {
        try lowerCondFor(s, f);
    }
}

fn lowerCondFor(s: *StmtState, f: ast.For) StmtError!void {
    const fn_val = s.current_fn;
    const cond_bb = C.LLVMAppendBasicBlockInContext(s.lc.ctx, fn_val, "for.cond");
    const body_bb = C.LLVMAppendBasicBlockInContext(s.lc.ctx, fn_val, "for.body");
    const end_bb = C.LLVMAppendBasicBlockInContext(s.lc.ctx, fn_val, "for.end");

    _ = C.LLVMBuildBr(s.lc.builder, cond_bb);
    C.LLVMPositionBuilderAtEnd(s.lc.builder, cond_bb);

    var is_infinite = false;
    if (f.expr.* == .literal and std.mem.eql(u8, f.expr.literal.value, "true")) {
        is_infinite = true;
    }

    if (!is_infinite) {
        var es = s.exprState();
        const cond_val = try expr_mod.lowerExpr(&es, f.expr);
        _ = C.LLVMBuildCondBr(s.lc.builder, cond_val, body_bb, end_bb);
    } else {
        _ = C.LLVMBuildBr(s.lc.builder, body_bb);
    }

    C.LLVMPositionBuilderAtEnd(s.lc.builder, body_bb);

    try s.loop_cond_bbs.append(s.lc.allocator, cond_bb);
    try s.loop_end_bbs.append(s.lc.allocator, end_bb);

    if (f.body.* == .block) {
        for (f.body.block.statements) |st| try lowerStmt(s, st);
    } else return error.UnsupportedStatement;

    _ = s.loop_cond_bbs.pop();
    _ = s.loop_end_bbs.pop();

    buildBrIfNoTerm(s.lc.builder, cond_bb);

    C.LLVMPositionBuilderAtEnd(s.lc.builder, end_bb);
}

fn lowerRangeFor(s: *StmtState, f: ast.For) StmtError!void {
    const fn_val = s.current_fn;
    var es = s.exprState();
    const start_val = try expr_mod.lowerExpr(&es, f.expr.binary.left);
    const end_val = try expr_mod.lowerExpr(&es, f.expr.binary.right);
    const iv_ty = C.LLVMTypeOf(start_val);

    const i_name = s.lc.allocator.dupeZ(u8, f.captures[0].name) catch return error.OutOfMemory;
    defer s.lc.allocator.free(i_name);

    const i_slot = C.LLVMBuildAlloca(s.lc.builder, iv_ty, i_name);
    try s.locals.put(f.captures[0].name, i_slot);
    _ = C.LLVMBuildStore(s.lc.builder, start_val, i_slot);

    const cond_bb = C.LLVMAppendBasicBlockInContext(s.lc.ctx, fn_val, "for.cond");
    const body_bb = C.LLVMAppendBasicBlockInContext(s.lc.ctx, fn_val, "for.body");
    const end_bb = C.LLVMAppendBasicBlockInContext(s.lc.ctx, fn_val, "for.end");

    _ = C.LLVMBuildBr(s.lc.builder, cond_bb);
    C.LLVMPositionBuilderAtEnd(s.lc.builder, cond_bb);

    const curr_i = C.LLVMBuildLoad2(s.lc.builder, iv_ty, i_slot, i_name);
    const end_ty_name = expr_mod.typeOf(&es, f.expr.binary.right);
    const end_c = types_mod.castTo(s.lc, end_val, end_ty_name, iv_ty);
    const cmp = C.LLVMBuildICmp(s.lc.builder, llvm.types.LLVMIntPredicate.LLVMIntSLT, curr_i, end_c, "cmp");
    _ = C.LLVMBuildCondBr(s.lc.builder, cmp, body_bb, end_bb);

    C.LLVMPositionBuilderAtEnd(s.lc.builder, body_bb);

    try s.loop_cond_bbs.append(s.lc.allocator, cond_bb);
    try s.loop_end_bbs.append(s.lc.allocator, end_bb);

    if (f.body.* == .block) {
        for (f.body.block.statements) |st| try lowerStmt(s, st);
    } else return error.UnsupportedStatement;

    _ = s.loop_cond_bbs.pop();
    _ = s.loop_end_bbs.pop();

    const one = C.LLVMConstInt(iv_ty, 1, 0);
    const next_i = C.LLVMBuildAdd(s.lc.builder, curr_i, one, "next");
    _ = C.LLVMBuildStore(s.lc.builder, next_i, i_slot);

    buildBrIfNoTerm(s.lc.builder, cond_bb);

    C.LLVMPositionBuilderAtEnd(s.lc.builder, end_bb);
}

fn lowerIterFor(s: *StmtState, f: ast.For) StmtError!void {
    var es = s.exprState();
    const arr_val = try expr_mod.lowerExpr(&es, f.expr);
    const arr_ty_name = expr_mod.typeOf(&es, f.expr);
    const arr_ty = types_mod.resolveOrSlot(s.lc, arr_ty_name);
    const fn_val = s.current_fn;

    const is_array = C.LLVMGetTypeKind(arr_ty) == .LLVMArrayTypeKind;
    const is_ptr = C.LLVMGetTypeKind(arr_ty) == .LLVMPointerTypeKind or C.LLVMGetTypeKind(arr_ty) == .LLVMIntegerTypeKind;

    if (is_array) {
        // ── Fixed-length array: @for (arr) |elem| or @for (arr) |elem, idx| ──
        const len = C.LLVMGetArrayLength(arr_ty);
        const elem_ty = C.LLVMGetElementType(arr_ty);

        const i_slot = C.LLVMBuildAlloca(s.lc.builder, s.lc.i64Ty(), "iter.i");
        _ = C.LLVMBuildStore(s.lc.builder, C.LLVMConstInt(s.lc.i64Ty(), 0, 0), i_slot);

        const elem_name = s.lc.allocator.dupeZ(u8, f.captures[0].name) catch return error.OutOfMemory;
        defer s.lc.allocator.free(elem_name);
        const elem_slot = C.LLVMBuildAlloca(s.lc.builder, elem_ty, elem_name);
        try s.locals.put(f.captures[0].name, elem_slot);

        // Optional second capture: index variable.
        var idx_slot: ?T.LLVMValueRef = null;
        if (f.captures.len > 1) {
            const idx_name = s.lc.allocator.dupeZ(u8, f.captures[1].name) catch return error.OutOfMemory;
            defer s.lc.allocator.free(idx_name);
            const sl = C.LLVMBuildAlloca(s.lc.builder, s.lc.i64Ty(), idx_name);
            _ = C.LLVMBuildStore(s.lc.builder, C.LLVMConstInt(s.lc.i64Ty(), 0, 0), sl);
            try s.locals.put(f.captures[1].name, sl);
            idx_slot = sl;
        }

        const tmp = C.LLVMBuildAlloca(s.lc.builder, arr_ty, "iter.arr");
        _ = C.LLVMBuildStore(s.lc.builder, arr_val, tmp);

        const cond_bb = C.LLVMAppendBasicBlockInContext(s.lc.ctx, fn_val, "iter.cond");
        const body_bb = C.LLVMAppendBasicBlockInContext(s.lc.ctx, fn_val, "iter.body");
        const end_bb = C.LLVMAppendBasicBlockInContext(s.lc.ctx, fn_val, "iter.end");

        _ = C.LLVMBuildBr(s.lc.builder, cond_bb);
        C.LLVMPositionBuilderAtEnd(s.lc.builder, cond_bb);
        const cur = C.LLVMBuildLoad2(s.lc.builder, s.lc.i64Ty(), i_slot, "i");
        const cmp = C.LLVMBuildICmp(s.lc.builder, .LLVMIntULT, cur, C.LLVMConstInt(s.lc.i64Ty(), len, 0), "cmp");
        _ = C.LLVMBuildCondBr(s.lc.builder, cmp, body_bb, end_bb);

        C.LLVMPositionBuilderAtEnd(s.lc.builder, body_bb);
        var idxs = [_]T.LLVMValueRef{ C.LLVMConstInt(s.lc.i64Ty(), 0, 0), cur };
        const ep = C.LLVMBuildGEP2(s.lc.builder, arr_ty, tmp, &idxs, 2, "ep");
        const ev = C.LLVMBuildLoad2(s.lc.builder, elem_ty, ep, "ev");
        _ = C.LLVMBuildStore(s.lc.builder, ev, elem_slot);
        if (idx_slot) |isl| _ = C.LLVMBuildStore(s.lc.builder, cur, isl);

        try s.loop_cond_bbs.append(s.lc.allocator, cond_bb);
        try s.loop_end_bbs.append(s.lc.allocator, end_bb);
        if (f.body.* == .block) {
            for (f.body.block.statements) |st| try lowerStmt(s, st);
        } else return error.UnsupportedStatement;
        _ = s.loop_cond_bbs.pop();
        _ = s.loop_end_bbs.pop();

        const next = C.LLVMBuildAdd(s.lc.builder, cur, C.LLVMConstInt(s.lc.i64Ty(), 1, 0), "next");
        _ = C.LLVMBuildStore(s.lc.builder, next, i_slot);
        if (idx_slot) |isl| _ = C.LLVMBuildStore(s.lc.builder, next, isl);
        buildBrIfNoTerm(s.lc.builder, cond_bb);
        C.LLVMPositionBuilderAtEnd(s.lc.builder, end_bb);
    } else if (is_ptr) {
        // ── String / slice pointer: @for (str) |ch| — null-terminated byte walk ──
        const byte_ty = s.lc.i8Ty();

        const i_slot = C.LLVMBuildAlloca(s.lc.builder, s.lc.i64Ty(), "iter.i");
        _ = C.LLVMBuildStore(s.lc.builder, C.LLVMConstInt(s.lc.i64Ty(), 0, 0), i_slot);

        const elem_name = s.lc.allocator.dupeZ(u8, f.captures[0].name) catch return error.OutOfMemory;
        defer s.lc.allocator.free(elem_name);
        const elem_slot = C.LLVMBuildAlloca(s.lc.builder, byte_ty, elem_name);
        try s.locals.put(f.captures[0].name, elem_slot);

        // Optional second capture: index
        var idx_slot: ?T.LLVMValueRef = null;
        if (f.captures.len > 1) {
            const idx_name = s.lc.allocator.dupeZ(u8, f.captures[1].name) catch return error.OutOfMemory;
            defer s.lc.allocator.free(idx_name);
            const sl = C.LLVMBuildAlloca(s.lc.builder, s.lc.i64Ty(), idx_name);
            _ = C.LLVMBuildStore(s.lc.builder, C.LLVMConstInt(s.lc.i64Ty(), 0, 0), sl);
            try s.locals.put(f.captures[1].name, sl);
            idx_slot = sl;
        }

        // Store the base pointer so we can GEP from it each iteration.
        const ptr_slot = C.LLVMBuildAlloca(s.lc.builder, s.lc.ptrTy(), "iter.ptr");
        const ptr_val = if (C.LLVMGetTypeKind(C.LLVMTypeOf(arr_val)) == .LLVMIntegerTypeKind)
            C.LLVMBuildIntToPtr(s.lc.builder, arr_val, s.lc.ptrTy(), "arr_ptr")
        else
            arr_val;
        _ = C.LLVMBuildStore(s.lc.builder, ptr_val, ptr_slot);

        const cond_bb = C.LLVMAppendBasicBlockInContext(s.lc.ctx, fn_val, "iter.cond");
        const body_bb = C.LLVMAppendBasicBlockInContext(s.lc.ctx, fn_val, "iter.body");
        const end_bb = C.LLVMAppendBasicBlockInContext(s.lc.ctx, fn_val, "iter.end");

        _ = C.LLVMBuildBr(s.lc.builder, cond_bb);
        C.LLVMPositionBuilderAtEnd(s.lc.builder, cond_bb);

        // Load current index, GEP into base ptr, load byte, compare to \0.
        const cur_i = C.LLVMBuildLoad2(s.lc.builder, s.lc.i64Ty(), i_slot, "i");
        const base = C.LLVMBuildLoad2(s.lc.builder, s.lc.ptrTy(), ptr_slot, "base");
        var gep_idx = [_]T.LLVMValueRef{cur_i};
        const byte_ptr = C.LLVMBuildGEP2(s.lc.builder, byte_ty, base, &gep_idx, 1, "bp");
        const ch = C.LLVMBuildLoad2(s.lc.builder, byte_ty, byte_ptr, "ch");
        const zero_byte = C.LLVMConstInt(byte_ty, 0, 0);
        const not_null = C.LLVMBuildICmp(s.lc.builder, .LLVMIntNE, ch, zero_byte, "notnull");
        _ = C.LLVMBuildCondBr(s.lc.builder, not_null, body_bb, end_bb);

        C.LLVMPositionBuilderAtEnd(s.lc.builder, body_bb);
        _ = C.LLVMBuildStore(s.lc.builder, ch, elem_slot);
        if (idx_slot) |isl| _ = C.LLVMBuildStore(s.lc.builder, cur_i, isl);

        try s.loop_cond_bbs.append(s.lc.allocator, cond_bb);
        try s.loop_end_bbs.append(s.lc.allocator, end_bb);
        if (f.body.* == .block) {
            for (f.body.block.statements) |st| try lowerStmt(s, st);
        } else return error.UnsupportedStatement;
        _ = s.loop_cond_bbs.pop();
        _ = s.loop_end_bbs.pop();

        const next_i = C.LLVMBuildAdd(s.lc.builder, cur_i, C.LLVMConstInt(s.lc.i64Ty(), 1, 0), "nexti");
        _ = C.LLVMBuildStore(s.lc.builder, next_i, i_slot);
        buildBrIfNoTerm(s.lc.builder, cond_bb);
        C.LLVMPositionBuilderAtEnd(s.lc.builder, end_bb);
    } else {
        return error.UnsupportedStatement;
    }
}

/// @for (optional_expr) |capture| — re-evaluates condition each iteration,
/// breaking when it becomes null/zero. Semantically a "while let" loop.
fn lowerOptionalFor(s: *StmtState, f: ast.For) StmtError!void {
    const fn_val = s.current_fn;
    const cond_bb = C.LLVMAppendBasicBlockInContext(s.lc.ctx, fn_val, "optfor.cond");
    const body_bb = C.LLVMAppendBasicBlockInContext(s.lc.ctx, fn_val, "optfor.body");
    const end_bb = C.LLVMAppendBasicBlockInContext(s.lc.ctx, fn_val, "optfor.end");

    // Allocate the capture slot (type determined from first evaluation).
    _ = C.LLVMBuildBr(s.lc.builder, cond_bb);
    C.LLVMPositionBuilderAtEnd(s.lc.builder, cond_bb);

    var es = s.exprState();
    const val = try expr_mod.lowerExpr(&es, f.expr);
    const val_ty = C.LLVMTypeOf(val);

    // Allocate capture slot once (we do it in the entry block via a helper alloca).
    // Since we're already past entry, just alloca here — it hoists in practice.
    const cap_name = s.lc.allocator.dupeZ(u8, f.captures[0].name) catch return error.OutOfMemory;
    defer s.lc.allocator.free(cap_name);
    const cap_slot = C.LLVMBuildAlloca(s.lc.builder, val_ty, cap_name);
    try s.locals.put(f.captures[0].name, cap_slot);

    // Compute truthiness.
    const cond: T.LLVMValueRef = blk: {
        const vk = C.LLVMGetTypeKind(val_ty);
        if (vk == .LLVMPointerTypeKind) {
            const null_val = C.LLVMConstNull(val_ty);
            break :blk C.LLVMBuildICmp(s.lc.builder, .LLVMIntNE, val, null_val, "tobool");
        }
        if (vk == .LLVMIntegerTypeKind and C.LLVMGetIntTypeWidth(val_ty) > 1) {
            break :blk C.LLVMBuildTrunc(s.lc.builder, val, s.lc.i1Ty(), "tobool");
        }
        break :blk val;
    };
    _ = C.LLVMBuildCondBr(s.lc.builder, cond, body_bb, end_bb);

    C.LLVMPositionBuilderAtEnd(s.lc.builder, body_bb);
    _ = C.LLVMBuildStore(s.lc.builder, val, cap_slot);

    try s.loop_cond_bbs.append(s.lc.allocator, cond_bb);
    try s.loop_end_bbs.append(s.lc.allocator, end_bb);
    if (f.body.* == .block) {
        for (f.body.block.statements) |st| try lowerStmt(s, st);
    } else return error.UnsupportedStatement;
    _ = s.loop_cond_bbs.pop();
    _ = s.loop_end_bbs.pop();

    buildBrIfNoTerm(s.lc.builder, cond_bb);
    C.LLVMPositionBuilderAtEnd(s.lc.builder, end_bb);
}


fn lowerSwitch(s: *StmtState, sw: ast.Switch) StmtError!void {
    const fn_val = s.current_fn;
    const end_bb = C.LLVMAppendBasicBlockInContext(s.lc.ctx, fn_val, "switch.end");

    var es = s.exprState();
    const cond_val = try expr_mod.lowerExpr(&es, sw.condition);

    // String switches (`@switch (name) { "FileNotFound", ... => })` compare
    // by content via `__eql` — pointer equality would never match runtime
    // heap strings against literal globals.
    const string_mode = C.LLVMGetTypeKind(C.LLVMTypeOf(cond_val)) == .LLVMPointerTypeKind or
        expr_mod.isStringTypeName(expr_mod.typeOf(&es, sw.condition));
    var cond_arg = cond_val;
    if (string_mode and C.LLVMGetTypeKind(C.LLVMTypeOf(cond_val)) == .LLVMIntegerTypeKind) {
        cond_arg = C.LLVMBuildIntToPtr(s.lc.builder, cond_val, s.lc.ptrTy(), "cond_str");
    }

    var next_cond_bb = C.LLVMAppendBasicBlockInContext(s.lc.ctx, fn_val, "switch.case");
    _ = C.LLVMBuildBr(s.lc.builder, next_cond_bb);
    C.LLVMPositionBuilderAtEnd(s.lc.builder, next_cond_bb);

    for (sw.prongs) |prong| {
        const body_bb = C.LLVMAppendBasicBlockInContext(s.lc.ctx, fn_val, "switch.body");
        next_cond_bb = C.LLVMAppendBasicBlockInContext(s.lc.ctx, fn_val, "switch.next");

        if (prong.is_else) {
            buildBrIfNoTerm(s.lc.builder, body_bb);
        } else {
            // OR-chain of patterns
            var matched: ?T.LLVMValueRef = null;
            for (prong.patterns) |pat| {
                const pat_val = try expr_mod.lowerExpr(&es, pat);
                if (string_mode) {
                    var pv = pat_val;
                    if (C.LLVMGetTypeKind(C.LLVMTypeOf(pat_val)) == .LLVMIntegerTypeKind) {
                        pv = C.LLVMBuildIntToPtr(s.lc.builder, pat_val, s.lc.ptrTy(), "pat_str");
                    }
                    const cmp = try expr_mod.strEql(&es, cond_arg, pv);
                    matched = if (matched) |m| C.LLVMBuildOr(s.lc.builder, m, cmp, "or") else cmp;
                } else {
                    const pat_ty_name = expr_mod.typeOf(&es, pat);
                    const pv = types_mod.castTo(s.lc, pat_val, pat_ty_name, C.LLVMTypeOf(cond_val));
                    const cmp = C.LLVMBuildICmp(s.lc.builder, .LLVMIntEQ, cond_val, pv, "eq");
                    matched = if (matched) |m| C.LLVMBuildOr(s.lc.builder, m, cmp, "or") else cmp;
                }
            }
            _ = C.LLVMBuildCondBr(s.lc.builder, matched.?, body_bb, next_cond_bb);
        }

        C.LLVMPositionBuilderAtEnd(s.lc.builder, body_bb);

        if (prong.body.* == .block) {
            for (prong.body.block.statements) |st| try lowerStmt(s, st);
        } else {
            try lowerStmt(s, prong.body);
        }

        buildBrIfNoTerm(s.lc.builder, end_bb);
        C.LLVMPositionBuilderAtEnd(s.lc.builder, next_cond_bb);
    }

    buildBrIfNoTerm(s.lc.builder, end_bb);
    C.LLVMPositionBuilderAtEnd(s.lc.builder, end_bb);
}
