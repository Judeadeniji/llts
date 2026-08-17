//! LLVM context, module and builder lifetime management.
//! One `LlvmContext` is created per compilation unit and owns all LLVM
//! resources. Callers must call `deinit` when done.

const std = @import("std");
const llvm = @import("llvm");
const T = llvm.types;
const C = llvm.core;
const bw = llvm.bitwriter;
const analysis = llvm.analysis;
const state_mod = @import("../state.zig");

pub const LlvmContext = struct {
    ctx: T.LLVMContextRef,
    mod: T.LLVMModuleRef,
    builder: T.LLVMBuilderRef,
    /// Interned LLVM function values, keyed by mangled name.
    functions: std.StringHashMap(T.LLVMValueRef),
    /// Global variables.
    globals: std.StringHashMap(T.LLVMValueRef),
    /// Named LLVM types (structs), keyed by source name.
    types: std.StringHashMap(T.LLVMTypeRef),
    allocator: std.mem.Allocator,
    state: *state_mod.CompilerState,

    pub fn init(allocator: std.mem.Allocator, module_name: []const u8, state: *state_mod.CompilerState) LlvmContext {
        const ctx = C.LLVMContextCreate();
        const name_z = allocator.dupeZ(u8, module_name) catch @panic("OOM");
        defer allocator.free(name_z);
        const mod = C.LLVMModuleCreateWithNameInContext(name_z, ctx);
        const builder = C.LLVMCreateBuilderInContext(ctx);
        return .{
            .ctx = ctx,
            .mod = mod,
            .builder = builder,
            .functions = std.StringHashMap(T.LLVMValueRef).init(allocator),
            .globals = std.StringHashMap(T.LLVMValueRef).init(allocator),
            .types = std.StringHashMap(T.LLVMTypeRef).init(allocator),
            .allocator = allocator,
            .state = state,
        };
    }

    pub fn deinit(self: *LlvmContext) void {
        self.functions.deinit();
        self.globals.deinit();
        self.types.deinit();
        C.LLVMDisposeBuilder(self.builder);
        C.LLVMDisposeModule(self.mod);
        C.LLVMContextDispose(self.ctx);
    }

    /// Dump LLVM IR to stderr (debug helper).
    pub fn dump(self: *const LlvmContext) void {
        C.LLVMDumpModule(self.mod);
    }

    /// Write textual LLVM IR to `path`.
    pub fn writeIr(self: *const LlvmContext, path: [*:0]const u8) !void {
        var err_msg: [*c]u8 = null;
        if (C.LLVMPrintModuleToFile(self.mod, path, &err_msg) != 0) {
            if (err_msg) |m| {
                defer C.LLVMDisposeMessage(m);
            }
            return error.IrWriteFailed;
        }
    }

    /// Verify the module; return an owned error string on failure.
    pub fn verify(self: *const LlvmContext) !void {
        var err_msg: [*c]u8 = null;
        if (analysis.LLVMVerifyModule(self.mod, .LLVMReturnStatusAction, &err_msg) != 0) {
            defer if (err_msg) |m| C.LLVMDisposeMessage(m);
            if (err_msg) |m| {
                std.log.err("LLVM verify failed:\n{s}", .{m});
            } else {
                std.log.err("LLVM verify failed", .{});
            }
            return error.LlvmVerifyFailed;
        }
    }

    /// Write LLVM bitcode to `path`.
    pub fn writeBitcode(self: *const LlvmContext, path: [*:0]const u8) !void {
        if (bw.LLVMWriteBitcodeToFile(self.mod, path) != 0)
            return error.BitcodeWriteFailed;
    }

    pub fn i1Ty(self: *const LlvmContext) T.LLVMTypeRef {
        return C.LLVMInt1TypeInContext(self.ctx);
    }

    pub fn i8Ty(self: *const LlvmContext) T.LLVMTypeRef {
        return C.LLVMInt8TypeInContext(self.ctx);
    }

    pub fn i16Ty(self: *const LlvmContext) T.LLVMTypeRef {
        return C.LLVMInt16TypeInContext(self.ctx);
    }

    pub fn i32Ty(self: *const LlvmContext) T.LLVMTypeRef {
        return C.LLVMInt32TypeInContext(self.ctx);
    }

    pub fn i64Ty(self: *const LlvmContext) T.LLVMTypeRef {
        return C.LLVMInt64TypeInContext(self.ctx);
    }

    pub fn f32Ty(self: *const LlvmContext) T.LLVMTypeRef {
        return C.LLVMFloatTypeInContext(self.ctx);
    }

    pub fn f64Ty(self: *const LlvmContext) T.LLVMTypeRef {
        return C.LLVMDoubleTypeInContext(self.ctx);
    }

    pub fn voidTy(self: *const LlvmContext) T.LLVMTypeRef {
        return C.LLVMVoidTypeInContext(self.ctx);
    }

    pub fn ptrTy(self: *const LlvmContext) T.LLVMTypeRef {
        return C.LLVMPointerTypeInContext(self.ctx, 0);
    }

    /// Pointer-width integer (i64 on 64-bit, i32 on 32-bit). Used for isize/usize.
    pub fn sizeTy(self: *const LlvmContext) T.LLVMTypeRef {
        // We target x86_64 for now; pointer width is 64 bits.
        return self.i64Ty();
    }
};
