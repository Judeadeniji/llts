//! Maps source-language type names to their LLVM `LLVMTypeRef` equivalents.

const std = @import("std");
const llvm = @import("llvm");
const T = llvm.types;
const C = llvm.core;
const context = @import("context.zig");
const layout = @import("../layout.zig");
const LlvmContext = context.LlvmContext;

const StructFieldInfo = struct { name: []const u8, offset: i32, type_name: []const u8 };
const StructOffsetInfo = struct { name: []const u8, offset: i32 };

/// Resolve a source type display string (as produced by the typechecker) to
/// an LLVM type. Returns `null` for unknown or unimplemented types.
pub fn resolve(lc: *LlvmContext, type_name_raw: []const u8) ?T.LLVMTypeRef {
    const type_name = layout.unwrapTypeName(type_name_raw);

    if (eql(type_name, "bool") or eql(type_name, "u1")) return lc.i1Ty();
    if (eql(type_name, "int") or eql(type_name, "i64")) return lc.i64Ty();
    if (eql(type_name, "isize") or eql(type_name, "usize")) return lc.sizeTy();
    if (eql(type_name, "i16")) return lc.i16Ty();
    if (eql(type_name, "i32")) return lc.i32Ty();
    if (eql(type_name, "i8") or eql(type_name, "u8") or eql(type_name, "byte")) return lc.i8Ty();
    if (eql(type_name, "u16")) return C.LLVMInt16TypeInContext(lc.ctx);
    if (eql(type_name, "u32")) return C.LLVMInt32TypeInContext(lc.ctx);
    if (eql(type_name, "u64")) return lc.i64Ty();
    if (eql(type_name, "i128") or eql(type_name, "u128")) return C.LLVMInt128TypeInContext(lc.ctx);
    if (eql(type_name, "f32") or eql(type_name, "float32")) return lc.f32Ty();
    if (eql(type_name, "float") or eql(type_name, "f64")) return lc.f64Ty();
    if (eql(type_name, "fsize")) return lc.f64Ty(); // platform float — f64 on x86_64
    if (eql(type_name, "void")) return lc.voidTy();
    if (eql(type_name, "null") or eql(type_name, "unknown")) return null;
    if (eql(type_name, "string") or eql(type_name, "[]byte") or eql(type_name, "[]u8")) return lc.ptrTy();
    if (std.mem.startsWith(u8, type_name, "*")) return lc.ptrTy();
    // Optional types `?T` are represented as a nullable pointer (opaque ptr in LLVM).
    if (std.mem.startsWith(u8, type_name, "?")) return lc.ptrTy();

    // Fixed array `[N]T` → LLVM array type (value).
    if (std.mem.startsWith(u8, type_name, "[")) {
        if (std.mem.indexOfScalar(u8, type_name, ']')) |rb| {
            if (rb > 1) {
                const len_str = type_name[1..rb];
                if (std.fmt.parseInt(u32, len_str, 10)) |len| {
                    const elem_name = type_name[rb + 1 ..];
                    const elem_ty = resolve(lc, elem_name) orelse lc.i64Ty();
                    return C.LLVMArrayType(elem_ty, len);
                } else |_| {}
            }
            // Open slice `[]T` → pointer
            return lc.ptrTy();
        }
    }

    if (lc.types.get(type_name)) |ty| return ty;

    if (lc.state.enums.contains(type_name)) return lc.i64Ty();
    if (lc.state.typedefs.get(type_name)) |td| return resolve(lc, td.underlying);

    if (lc.state.structs.get(type_name)) |sd| {
        const name_z = lc.allocator.dupeZ(u8, type_name) catch return null;
        defer lc.allocator.free(name_z);
        const struct_ty = C.LLVMStructCreateNamed(lc.ctx, name_z);
        lc.types.put(type_name, struct_ty) catch return null;

        var fields_array: std.ArrayList(StructFieldInfo) = .empty;
        defer fields_array.deinit(lc.allocator);

        var it = sd.offsets.iterator();
        while (it.next()) |entry| {
            const field_name = entry.key_ptr.*;
            const offset = entry.value_ptr.*;
            const field_type_name = sd.types.get(field_name) orelse "i64";
            fields_array.append(lc.allocator, .{ .name = field_name, .offset = offset, .type_name = field_type_name }) catch return null;
        }

        std.mem.sort(StructFieldInfo, fields_array.items, {}, struct {
            pub fn lessThan(ctx: void, a: StructFieldInfo, b: StructFieldInfo) bool {
                _ = ctx;
                return a.offset < b.offset;
            }
        }.lessThan);

        const llvm_fields = lc.allocator.alloc(T.LLVMTypeRef, fields_array.items.len) catch return null;
        defer lc.allocator.free(llvm_fields);

        for (fields_array.items, 0..) |f, i| {
            llvm_fields[i] = resolve(lc, f.type_name) orelse lc.i64Ty();
        }

        C.LLVMStructSetBody(struct_ty, llvm_fields.ptr, @intCast(llvm_fields.len), 0);
        return struct_ty;
    }

    return null;
}

/// Returns the LLVM struct element index for a given field name in a struct.
pub fn getStructFieldIndex(lc: *LlvmContext, type_name: []const u8, field_name: []const u8) ?u32 {
    const sd = lc.state.structs.get(type_name) orelse return null;

    var fields_array: std.ArrayList(StructOffsetInfo) = .empty;
    defer fields_array.deinit(lc.allocator);

    var it = sd.offsets.iterator();
    while (it.next()) |entry| {
        fields_array.append(lc.allocator, .{ .name = entry.key_ptr.*, .offset = entry.value_ptr.* }) catch return null;
    }

    std.mem.sort(StructOffsetInfo, fields_array.items, {}, struct {
        pub fn lessThan(ctx: void, a: StructOffsetInfo, b: StructOffsetInfo) bool {
            _ = ctx;
            return a.offset < b.offset;
        }
    }.lessThan);

    for (fields_array.items, 0..) |f, i| {
        if (eql(f.name, field_name)) return @intCast(i);
    }
    return null;
}

/// Prefer a real resolved type; fall back to i64 only for unknown/untyped.
pub fn resolveOrSlot(lc: *LlvmContext, type_name_raw: []const u8) T.LLVMTypeRef {
    if (eql(layout.unwrapTypeName(type_name_raw), "unknown")) return lc.i64Ty();
    return resolve(lc, type_name_raw) orelse lc.i64Ty();
}

pub fn isFloatName(type_name: []const u8) bool {
    const t = layout.unwrapTypeName(type_name);
    return eql(t, "float") or eql(t, "f64") or eql(t, "f32") or eql(t, "float32") or eql(t, "fsize");
}

pub fn isUnsignedName(type_name: []const u8) bool {
    const t = layout.unwrapTypeName(type_name);
    return eql(t, "u8") or eql(t, "u16") or eql(t, "u32") or eql(t, "u64") or eql(t, "u128") or eql(t, "usize") or eql(t, "byte");
}

/// Cast `val` to `dst_ty` when both are integer or float widths.
pub fn castTo(lc: *LlvmContext, val: T.LLVMValueRef, dst_ty: T.LLVMTypeRef) T.LLVMValueRef {
    const src_ty = C.LLVMTypeOf(val);
    if (src_ty == dst_ty) return val;
    const sk = C.LLVMGetTypeKind(src_ty);
    const dk = C.LLVMGetTypeKind(dst_ty);
    if (sk == .LLVMIntegerTypeKind and dk == .LLVMIntegerTypeKind) {
        const sw = C.LLVMGetIntTypeWidth(src_ty);
        const dw = C.LLVMGetIntTypeWidth(dst_ty);
        if (sw < dw) return C.LLVMBuildSExt(lc.builder, val, dst_ty, "sext");
        if (sw > dw) return C.LLVMBuildTrunc(lc.builder, val, dst_ty, "trunc");
        return val;
    }
    if (sk == .LLVMFloatTypeKind or sk == .LLVMDoubleTypeKind) {
        if (dk == .LLVMFloatTypeKind or dk == .LLVMDoubleTypeKind) {
            const sw = if (sk == .LLVMDoubleTypeKind) @as(u32, 64) else 32;
            const dw = if (dk == .LLVMDoubleTypeKind) @as(u32, 64) else 32;
            if (sw < dw) return C.LLVMBuildFPExt(lc.builder, val, dst_ty, "fpext");
            if (sw > dw) return C.LLVMBuildFPTrunc(lc.builder, val, dst_ty, "fptrunc");
        }
        if (dk == .LLVMIntegerTypeKind) return C.LLVMBuildFPToSI(lc.builder, val, dst_ty, "fptosi");
    }
    if (sk == .LLVMIntegerTypeKind and (dk == .LLVMFloatTypeKind or dk == .LLVMDoubleTypeKind)) {
        return C.LLVMBuildSIToFP(lc.builder, val, dst_ty, "sitofp");
    }
    if (sk == .LLVMPointerTypeKind and dk == .LLVMPointerTypeKind) return val;
    if (dk == .LLVMPointerTypeKind and sk == .LLVMIntegerTypeKind) {
        return C.LLVMBuildIntToPtr(lc.builder, val, dst_ty, "inttoptr");
    }
    if (sk == .LLVMPointerTypeKind and dk == .LLVMIntegerTypeKind) {
        return C.LLVMBuildPtrToInt(lc.builder, val, dst_ty, "ptrtoint");
    }
    return val;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
