//! LLTS Compiler Test Suite Runner
//! Comprehensive, in-process Zig tests across all stages of the compiler:
//! Scanner -> Parser -> Typechecker -> Compiler Analysis -> Pipeline / Native Backend

const std = @import("std");

pub const scanner_tests = @import("scanner_test.zig");
pub const parser_tests = @import("parser_test.zig");
pub const typecheck_tests = @import("typecheck_test.zig");
pub const compiler_tests = @import("compiler_test.zig");
pub const pipeline_tests = @import("pipeline_test.zig");

test {
    std.testing.refAllDecls(@This());
}
