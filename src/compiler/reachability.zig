const std = @import("std");
const ast = @import("../ast/root.zig");
const state_mod = @import("state.zig");
const path = @import("expr/path.zig");
const types = @import("typecheck/from_ast.zig");

const CompilerState = state_mod.CompilerState;

pub const Result = struct {
    functions: std.StringHashMap(void),
    globals: std.StringHashMap(void),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Result) void {
        self.functions.deinit();
        self.globals.deinit();
    }

    pub fn isFunctionReachable(self: *const Result, name: []const u8) bool {
        return self.functions.contains(name);
    }

    pub fn shouldEmitTopLevel(self: *const Result, doc: *ast.Document, node: *ast.Node) bool {
        switch (node.*) {
            .declaration => |d| {
                if (d.value.* == .import) return false;
                if (std.mem.indexOf(u8, d.name, "::") == null) return true;
                return self.globals.contains(d.name);
            },
            else => {
                const loc = node.loc();
                return std.mem.eql(u8, loc.path, doc.path);
            },
        }
    }
};

pub fn compute(state: *CompilerState, doc: *ast.Document) !Result {
    var result: Result = .{
        .functions = std.StringHashMap(void).init(state.allocator),
        .globals = std.StringHashMap(void).init(state.allocator),
        .allocator = state.allocator,
    };

    var work: std.ArrayList([]const u8) = .empty;
    defer work.deinit(state.allocator);

    if (state.functions.contains("main")) {
        try enqueueFunction(&result, &work, "main");
    }

    for (doc.statements) |s| {
        if (s.* == .function_decl or s.* == .struct_decl or s.* == .enum_decl) continue;
        const loc = s.loc();
        if (!std.mem.eql(u8, loc.path, doc.path)) continue;
        try collectRefs(state, null, s, &result, &work);
    }

    while (work.items.len > 0) {
        const name = work.pop().?;
        if (result.functions.contains(name)) continue;
        if (!state.functions.contains(name)) continue;
        try result.functions.put(name, {});

        const def = state.functions.get(name).?;
        try collectRefsFromFunction(state, name, def.node, &result, &work);

        var cit = def.calls.keyIterator();
        while (cit.next()) |call_name| {
            var targets = try expandCallTargets(state, call_name.*);
            defer targets.deinit(state.allocator);
            for (targets.items) |target| try enqueueFunction(&result, &work, target);
        }
    }

    try closeGlobalDeps(state, doc, &result, &work);

    while (work.items.len > 0) {
        const name = work.pop().?;
        if (result.functions.contains(name)) continue;
        if (!state.functions.contains(name)) continue;
        try result.functions.put(name, {});

        const def = state.functions.get(name).?;
        try collectRefsFromFunction(state, name, def.node, &result, &work);

        var cit = def.calls.keyIterator();
        while (cit.next()) |call_name| {
            var targets = try expandCallTargets(state, call_name.*);
            defer targets.deinit(state.allocator);
            for (targets.items) |target| try enqueueFunction(&result, &work, target);
        }
    }

    return result;
}

fn closeGlobalDeps(
    state: *CompilerState,
    doc: *ast.Document,
    result: *Result,
    work: *std.ArrayList([]const u8),
) !void {
    var changed = true;
    while (changed) {
        changed = false;
        const prev_count = result.globals.count();

        var pending: std.ArrayList([]const u8) = .empty;
        defer pending.deinit(state.allocator);

        var git = result.globals.keyIterator();
        while (git.next()) |gname| try pending.append(state.allocator, gname.*);

        for (pending.items) |gname| {
            const decl = findDeclaration(doc, gname) orelse continue;
            try collectRefs(state, null, decl.declaration.value, result, work);
        }

        if (result.globals.count() > prev_count) changed = true;
    }
}

fn findDeclaration(doc: *ast.Document, name: []const u8) ?*ast.Node {
    for (doc.statements) |s| {
        if (s.* == .declaration and std.mem.eql(u8, s.declaration.name, name)) return s;
    }
    return null;
}

fn enqueueFunction(result: *Result, work: *std.ArrayList([]const u8), name: []const u8) !void {
    if (result.functions.contains(name)) return;
    for (work.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    try work.append(result.allocator, name);
}

fn expandCallTargets(state: *CompilerState, call_name: []const u8) !std.ArrayList([]const u8) {
    var targets: std.ArrayList([]const u8) = .empty;

    if (state.native_globals.contains(call_name)) return targets;

    {
        var kit = state.functions.keyIterator();
        while (kit.next()) |k| {
            if (std.mem.eql(u8, k.*, call_name)) {
                try targets.append(state.allocator, k.*);
                return targets;
            }
        }
    }

    if (std.mem.indexOf(u8, call_name, "::") != null) return targets;

    {
        var kit = state.functions.keyIterator();
        while (kit.next()) |k| {
            if (std.mem.endsWith(u8, k.*, call_name)) {
                const prefix_len = k.*.len - call_name.len;
                if (prefix_len >= 2 and std.mem.eql(u8, k.*[prefix_len - 2 .. prefix_len], "::")) {
                    try targets.append(state.allocator, k.*);
                }
            }
        }
    }
    return targets;
}

fn collectRefsFromFunction(
    state: *CompilerState,
    func_name: []const u8,
    node: *ast.Node,
    result: *Result,
    work: *std.ArrayList([]const u8),
) !void {
    switch (node.*) {
        .function_decl => |f| try collectRefsFromFunction(state, func_name, f.body, result, work),
        else => try collectRefs(state, func_name, node, result, work),
    }
}

fn collectRefs(
    state: *CompilerState,
    func_name: ?[]const u8,
    node: *ast.Node,
    result: *Result,
    work: *std.ArrayList([]const u8),
) !void {
    switch (node.*) {
        .function_decl => |f| try collectRefs(state, func_name, f.body, result, work),
        .block => |b| {
            for (b.statements) |s| try collectRefs(state, func_name, s, result, work);
        },
        .declaration => |d| {
            try collectRefs(state, func_name, d.value, result, work);
        },
        .return_expr => |r| {
            if (r.return_value) |v| try collectRefs(state, func_name, v, result, work);
        },
        .break_expr => |br| {
            if (br.value) |v| try collectRefs(state, func_name, v, result, work);
        },
        .defer_stmt => |d| try collectRefs(state, func_name, d.body, result, work),
        .if_expr => |i| {
            try collectRefs(state, func_name, i.condition, result, work);
            try collectRefs(state, func_name, i.body, result, work);
            if (i.else_body) |e| try collectRefs(state, func_name, e, result, work);
        },
        .switch_expr => |sw| {
            try collectRefs(state, func_name, sw.condition, result, work);
            for (sw.prongs) |prong| {
                for (prong.patterns) |pat| try collectRefs(state, func_name, pat, result, work);
                try collectRefs(state, func_name, prong.body, result, work);
            }
        },
        .for_expr => |f| {
            if (f.condition) |c| try collectRefs(state, func_name, c, result, work);
            if (f.range_start) |s| try collectRefs(state, func_name, s, result, work);
            if (f.range_end) |e| try collectRefs(state, func_name, e, result, work);
            if (f.iterable) |it| try collectRefs(state, func_name, it, result, work);
            try collectRefs(state, func_name, f.body, result, work);
        },
        .binary => |b| {
            try collectRefs(state, func_name, b.left, result, work);
            try collectRefs(state, func_name, b.right, result, work);
            if (std.mem.eql(u8, b.operator, "|>")) {
                if (b.right.* == .call) {
                    try noteCall(state, func_name, b.right.call.callee, result, work);
                } else {
                    try noteFunctionValue(state, b.right, result, work);
                }
            }
        },
        .unary => |u| try collectRefs(state, func_name, u.arg, result, work),
        .assignment => |a| {
            try collectRefs(state, func_name, a.left, result, work);
            try collectRefs(state, func_name, a.right, result, work);
        },
        .call => |c| {
            try noteCall(state, func_name, c.callee, result, work);
            try collectRefs(state, func_name, c.callee, result, work);
            for (c.args) |arg| try collectRefs(state, func_name, arg, result, work);
        },
        .member => |m| {
            try noteStaticPath(state, node, result, work);
            try collectRefs(state, func_name, m.object, result, work);
            try collectRefs(state, func_name, m.property, result, work);
        },
        .index => |ix| {
            try collectRefs(state, func_name, ix.object, result, work);
            try collectRefs(state, func_name, ix.index, result, work);
        },
        .array_literal => |a| {
            for (a.elements) |e| try collectRefs(state, func_name, e, result, work);
        },
        .struct_init => |init| {
            if (init.name.len > 0) try noteGlobalRead(state, init.name, result);
            for (init.fields) |field| try collectRefs(state, func_name, field.value, result, work);
        },
        .try_expr => |t| try collectRefs(state, func_name, t.expression, result, work),
        .error_expr => |e| try collectRefs(state, func_name, e.message, result, work),
        .primary => |p| {
            if (p.kind == .identifier) try noteGlobalRead(state, p.name, result);
        },
        else => {},
    }
}

fn noteStaticPath(
    state: *CompilerState,
    node: *ast.Node,
    result: *Result,
    work: *std.ArrayList([]const u8),
) !void {
    if (try path.tryResolveStaticPath(state, node)) |name| {
        if (state.functions.contains(name)) {
            try enqueueFunction(result, work, name);
        } else {
            try noteGlobalRead(state, name, result);
        }
    }
}

fn noteGlobalRead(state: *CompilerState, name: []const u8, result: *Result) !void {
    if (state.global_vars.contains(name)) {
        try result.globals.put(name, {});
        return;
    }
    var buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "${s}", .{name}) catch return;
    if (state.global_types.get(key)) |ty| {
        if (std.mem.startsWith(u8, ty, "module:")) {
            try result.globals.put(name, {});
        }
    }
}

fn noteCall(
    state: *CompilerState,
    func_name: ?[]const u8,
    callee: *ast.Node,
    result: *Result,
    work: *std.ArrayList([]const u8),
) !void {
    if (try resolveCallTarget(state, callee)) |name| {
        if (state.native_globals.contains(name)) return;
        var targets = try expandCallTargets(state, name);
        defer targets.deinit(state.allocator);
        for (targets.items) |target| try enqueueFunction(result, work, target);
        return;
    }

    if (callee.* == .member) {
        const mem = &callee.member;
        if (mem.property.* == .primary) {
            const prop = mem.property.primary.name;
            const object = mem.object;
            if (object.* == .primary and object.primary.kind == .identifier and std.mem.eql(u8, object.primary.name, "self")) {
                if (func_name) |fname| {
                    if (std.mem.indexOf(u8, fname, "::")) |idx| {
                        const type_name = fname[0..idx];
                        const method_name = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ type_name, prop });
                        defer state.allocator.free(method_name);
                        var targets = try expandCallTargets(state, method_name);
                        defer targets.deinit(state.allocator);
                        for (targets.items) |target| try enqueueFunction(result, work, target);
                        return;
                    }
                }
            }
            if (types.resolveType(state, mem.object)) |type_name| {
                if (state.structs.get(type_name)) |sd| {
                    if (sd.offsets.get(prop) == null) {
                        const method_name = try std.fmt.allocPrint(state.allocator, "{s}::{s}", .{ type_name, prop });
                        defer state.allocator.free(method_name);
                        var targets = try expandCallTargets(state, method_name);
                        defer targets.deinit(state.allocator);
                        for (targets.items) |target| try enqueueFunction(result, work, target);
                    }
                }
            }
        }
    }
}

fn noteFunctionValue(
    state: *CompilerState,
    node: *ast.Node,
    result: *Result,
    work: *std.ArrayList([]const u8),
) !void {
    try noteStaticPath(state, node, result, work);
    if (node.* == .primary and node.primary.kind == .identifier) {
        const name = node.primary.name;
        if (state.functions.contains(name)) try enqueueFunction(result, work, name);
    }
}

fn resolveCallTarget(state: *CompilerState, callee: *ast.Node) !?[]const u8 {
    if (try path.tryResolveStaticPath(state, callee)) |p| return p;
    if (callee.* == .primary and callee.primary.kind == .identifier) {
        return callee.primary.name;
    }
    return null;
}

test "reachability keeps only called std/debug function" {
    const allocator = std.testing.allocator;
    const source =
        \\@const $std = @import("std/index.lls");
        \\@const $err_msg = error("this is an error", "hello");
        \\std.debug.err(err_msg);
        \\
    ;

    const scanner = @import("../scanner/root.zig");
    const parser = @import("../parser/root.zig");
    const compiler = @import("root.zig");

    var scan_result = try scanner.scan(allocator, source, "test.lls");
    defer scanner.deinitScanResult(&scan_result);

    var doc = try parser.parse(allocator, scan_result.tokens.items, "test.lls", source);
    defer doc.deinit();

    var chunk = try compiler.compile(allocator, &doc, .{ .debug = false });
    defer chunk.deinit();

    try std.testing.expect(chunk.functions.count() < 20);
    try std.testing.expect(chunk.functions.count() >= 1);
}

test "native print does not pull in std/io print" {
    const allocator = std.testing.allocator;
    const source =
        \\@const $std = @import("std/index.lls");
        \\print(42);
        \\
    ;

    const scanner = @import("../scanner/root.zig");
    const parser = @import("../parser/root.zig");
    const compiler = @import("root.zig");

    var scan_result = try scanner.scan(allocator, source, "test.lls");
    defer scanner.deinitScanResult(&scan_result);

    var doc = try parser.parse(allocator, scan_result.tokens.items, "test.lls", source);
    defer doc.deinit();

    var chunk = try compiler.compile(allocator, &doc, .{ .debug = false });
    defer chunk.deinit();

    try std.testing.expect(chunk.functions.count() == 0);
}
