const std = @import("std");
const ast = @import("../../ast/root.zig");

pub const BlockId = usize;

pub const SwitchArm = struct {
    patterns: []const *ast.Node,
    is_else: bool,
    body: *ast.Node,
    /// Destination block for this arm's body.
    bb: BlockId,
};

/// How a block ends. Exactly one successor shape is active.
pub const Terminator = union(enum) {
    /// Unconditional fallthrough to `target`.
    goto: BlockId,
    /// Conditional branch on `cond`.
    br: struct {
        cond: *ast.Node,
        true_bb: BlockId,
        false_bb: BlockId,
    },
    /// `@switch` dispatch on `cond`.
    switch_: struct {
        cond: *ast.Node,
        arms: []SwitchArm,
        /// Fallback when no pattern matches (an `@else` prong or a synthetic
        /// unreachable block when the switch is exhaustive).
        else_bb: BlockId,
    },
    /// Function return / end of body.
    ret: void,
    /// `break` to a loop/switch/labeled-block join.
    jump: BlockId,
    /// `continue` back to a loop header.
    loop: BlockId,
    /// No successors (dead code).
    unreachable_: void,
};

pub const Block = struct {
    id: BlockId,
    stmts: std.ArrayList(*ast.Node) = .empty,
    term: Terminator = .{ .unreachable_ = {} },
    preds: std.ArrayList(BlockId) = .empty,

    pub fn deinit(self: *Block, allocator: std.mem.Allocator) void {
        self.stmts.deinit(allocator);
        self.preds.deinit(allocator);
    }

    /// Successor ids implied by the terminator.
    pub fn successors(self: *const Block, allocator: std.mem.Allocator) ![]BlockId {
        var out: std.ArrayList(BlockId) = .empty;
        errdefer out.deinit(allocator);
        switch (self.term) {
            .goto => |t| try out.append(allocator, t),
            .br => |b| {
                try out.append(allocator, b.true_bb);
                try out.append(allocator, b.false_bb);
            },
            .switch_ => |sw| {
                for (sw.arms) |arm| try out.append(allocator, arm.bb);
                try out.append(allocator, sw.else_bb);
            },
            .ret => {},
            .jump => |t| try out.append(allocator, t),
            .loop => |t| try out.append(allocator, t),
            .unreachable_ => {},
        }
        return out.toOwnedSlice(allocator);
    }
};

const LoopFrame = struct {
    header: BlockId,
    exit: BlockId,
    label: ?[]const u8,
};

/// CFG for a single function/initializer body.
pub const CFG = struct {
    allocator: std.mem.Allocator,
    blocks: std.ArrayList(Block) = .empty,
    entry: BlockId = 0,
    exit: BlockId = 0,

    pub fn deinit(self: *CFG) void {
        for (self.blocks.items) |*b| b.deinit(self.allocator);
        self.blocks.deinit(self.allocator);
    }

    fn newBlock(self: *CFG) !BlockId {
        const id = self.blocks.items.len;
        try self.blocks.append(self.allocator, .{ .id = id });
        return id;
    }

    /// Fill predecessor lists from terminators.
    fn finish(self: *CFG) !void {
        for (self.blocks.items) |*b| b.preds.clearRetainingCapacity();
        for (self.blocks.items) |b| {
            const succs = try b.successors(self.allocator);
            defer self.allocator.free(succs);
            for (succs) |s| {
                try self.blocks.items[s].preds.append(self.allocator, b.id);
            }
        }
    }
};

/// Build a CFG for `body` (a `.block` node). Returns null when the body is
/// not a block so callers can fall back to syntactic-only narrowing.
pub fn build(allocator: std.mem.Allocator, body: *ast.Node) !?*CFG {
    if (body.* != .block) return null;

    var cfg = try allocator.create(CFG);
    cfg.* = .{ .allocator = allocator };
    errdefer cfg.deinit();

    const entry = try cfg.newBlock();
    cfg.entry = entry;
    const exit = try cfg.newBlock();
    cfg.exit = exit;

    var b = Builder{
        .cfg = cfg,
        .allocator = allocator,
        .cur = entry,
    };
    var loops: std.ArrayList(LoopFrame) = .empty;
    defer loops.deinit(allocator);
    var break_targets: std.ArrayList(BlockId) = .empty;
    defer break_targets.deinit(allocator);

    try b.stmts(body.block.statements, &loops, &break_targets);
    if (b.reachable) {
        b.cfg.blocks.items[b.cur].term = .{ .goto = exit };
    }
    try cfg.finish();
    return cfg;
}

const Builder = struct {
    cfg: *CFG,
    allocator: std.mem.Allocator,
    cur: BlockId,
    reachable: bool = true,

    fn stmts(
        self: *Builder,
        list: []const *ast.Node,
        loops: *std.ArrayList(LoopFrame),
        break_targets: *std.ArrayList(BlockId),
    ) std.mem.Allocator.Error!void {
        for (list) |s| {
            if (!self.reachable) break;
            try self.stmt(s, loops, break_targets);
        }
    }

    fn stmt(
        self: *Builder,
        node: *ast.Node,
        loops: *std.ArrayList(LoopFrame),
        break_targets: *std.ArrayList(BlockId),
    ) std.mem.Allocator.Error!void {
        switch (node.*) {
            .if_expr => try self.ifNode(node, loops, break_targets),
            .switch_expr => try self.switchNode(node, loops, break_targets),
            .for_expr => try self.forNode(node, loops, break_targets),
            .block => try self.stmts(node.block.statements, loops, break_targets),
            .return_expr => {
                try self.cfg.blocks.items[self.cur].stmts.append(self.allocator, node);
                self.cfg.blocks.items[self.cur].term = .{ .ret = {} };
                self.reachable = false;
            },
            .break_expr => |br| {
                try self.cfg.blocks.items[self.cur].stmts.append(self.allocator, node);
                if (resolveBreakTarget(br.label, loops, break_targets)) |t| {
                    self.cfg.blocks.items[self.cur].term = .{ .jump = t };
                    self.reachable = false;
                }
            },
            .continue_expr => |c| {
                try self.cfg.blocks.items[self.cur].stmts.append(self.allocator, node);
                if (resolveContinueTarget(c.label, loops)) |t| {
                    self.cfg.blocks.items[self.cur].term = .{ .loop = t };
                    self.reachable = false;
                }
            },
            else => {
                try self.cfg.blocks.items[self.cur].stmts.append(self.allocator, node);
            },
        }
    }

    fn ifNode(
        self: *Builder,
        node: *ast.Node,
        loops: *std.ArrayList(LoopFrame),
        break_targets: *std.ArrayList(BlockId),
    ) std.mem.Allocator.Error!void {
        const ife = &node.if_expr;
        // Record the `if` statement itself so its condition is typechecked
        // against the flow env *after* the preceding statements.
        try self.cfg.blocks.items[self.cur].stmts.append(self.allocator, node);
        const then_bb = try self.cfg.newBlock();
        const else_bb = try self.cfg.newBlock();
        const join_bb = try self.cfg.newBlock();

        // End the current block with the branch.
        self.cfg.blocks.items[self.cur].term = .{ .br = .{
            .cond = ife.condition,
            .true_bb = then_bb,
            .false_bb = else_bb,
        } };
        self.reachable = false;

        const saved_cur = self.cur;

        // Then arm.
        self.cur = then_bb;
        self.reachable = true;
        try self.bodyStmts(ife.body, loops, break_targets);
        if (self.reachable) {
            self.cfg.blocks.items[self.cur].term = .{ .goto = join_bb };
        }

        // Else arm (or the implicit empty else that falls through).
        self.cur = else_bb;
        self.reachable = true;
        if (ife.else_body) |eb| {
            try self.bodyStmts(eb, loops, break_targets);
        }
        if (self.reachable) {
            self.cfg.blocks.items[self.cur].term = .{ .goto = join_bb };
        }

        self.cur = join_bb;
        self.reachable = true;
        _ = saved_cur;
    }

    fn switchNode(
        self: *Builder,
        node: *ast.Node,
        loops: *std.ArrayList(LoopFrame),
        break_targets: *std.ArrayList(BlockId),
    ) std.mem.Allocator.Error!void {
        const sw = &node.switch_expr;
        // See `ifNode`: the switch statement itself is a "statement" whose
        // snapshot must precede the branch terminator.
        try self.cfg.blocks.items[self.cur].stmts.append(self.allocator, node);
        const n = sw.prongs.len;
        const arm_bbs = try self.allocator.alloc(BlockId, n);
        defer self.allocator.free(arm_bbs);
        for (arm_bbs) |*bb| bb.* = try self.cfg.newBlock();
        const join_bb = try self.cfg.newBlock();
        // Synthetic else for non-`@else` exhaustive switches: jumps straight to join.
        const else_bb = try self.cfg.newBlock();
        self.cfg.blocks.items[else_bb].term = .{ .goto = join_bb };

        var arms = try self.allocator.alloc(SwitchArm, n);
        for (sw.prongs, 0..) |prong, i| {
            arms[i] = .{
                .patterns = prong.patterns,
                .is_else = prong.is_else,
                .body = prong.body,
                .bb = arm_bbs[i],
            };
        }

        self.cfg.blocks.items[self.cur].term = .{ .switch_ = .{
            .cond = sw.condition,
            .arms = arms,
            .else_bb = else_bb,
        } };
        self.reachable = false;

        const saved_cur = self.cur;
        break_targets.append(self.allocator, join_bb) catch {};

        for (sw.prongs, 0..) |prong, i| {
            self.cur = arm_bbs[i];
            self.reachable = true;
            try self.bodyStmts(prong.body, loops, break_targets);
            if (self.reachable) {
                self.cfg.blocks.items[self.cur].term = .{ .goto = join_bb };
            }
        }
        _ = break_targets.pop();

        self.cur = join_bb;
        self.reachable = true;
        _ = saved_cur;
    }

    fn forNode(
        self: *Builder,
        node: *ast.Node,
        loops: *std.ArrayList(LoopFrame),
        break_targets: *std.ArrayList(BlockId),
    ) std.mem.Allocator.Error!void {
        const fe = &node.for_expr;
        // See `ifNode`: snapshot the loop statement before entering the header.
        try self.cfg.blocks.items[self.cur].stmts.append(self.allocator, node);
        const header = try self.cfg.newBlock();
        const body_bb = try self.cfg.newBlock();
        const exit_bb = try self.cfg.newBlock();

        self.cfg.blocks.items[self.cur].term = .{ .goto = header };
        self.reachable = false;

        // Header evaluates the iterable / condition and branches.
        self.cfg.blocks.items[header].stmts.append(self.allocator, fe.expr) catch {};
        self.cfg.blocks.items[header].term = .{ .br = .{
            .cond = fe.expr,
            .true_bb = body_bb,
            .false_bb = exit_bb,
        } };

        loops.append(self.allocator, .{
            .header = header,
            .exit = exit_bb,
            .label = fe.label,
        }) catch {};
        break_targets.append(self.allocator, exit_bb) catch {};

        self.cur = body_bb;
        self.reachable = true;
        try self.bodyStmts(fe.body, loops, break_targets);
        if (self.reachable) {
            self.cfg.blocks.items[self.cur].term = .{ .loop = header };
        }

        _ = break_targets.pop();
        _ = loops.pop();

        self.cur = exit_bb;
        self.reachable = true;
    }

    fn bodyStmts(
        self: *Builder,
        body: *ast.Node,
        loops: *std.ArrayList(LoopFrame),
        break_targets: *std.ArrayList(BlockId),
    ) std.mem.Allocator.Error!void {
        switch (body.*) {
            .block => try self.stmts(body.block.statements, loops, break_targets),
            else => try self.stmt(body, loops, break_targets),
        }
    }
};

fn resolveBreakTarget(
    label: ?[]const u8,
    loops: *const std.ArrayList(LoopFrame),
    break_targets: *const std.ArrayList(BlockId),
) ?BlockId {
    if (label) |lbl| {
        var i = loops.items.len;
        while (i > 0) {
            i -= 1;
            if (loops.items[i].label) |l| {
                if (std.mem.eql(u8, l, lbl)) return loops.items[i].exit;
            }
        }
        return null;
    }
    if (break_targets.items.len > 0) return break_targets.items[break_targets.items.len - 1];
    return null;
}

fn resolveContinueTarget(label: ?[]const u8, loops: *const std.ArrayList(LoopFrame)) ?BlockId {
    if (label) |lbl| {
        var i = loops.items.len;
        while (i > 0) {
            i -= 1;
            if (loops.items[i].label) |l| {
                if (std.mem.eql(u8, l, lbl)) return loops.items[i].header;
            }
        }
        return null;
    }
    if (loops.items.len > 0) return loops.items[loops.items.len - 1].header;
    return null;
}
