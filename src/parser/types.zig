const std = @import("std");
const ctx = @import("ctx.zig");
const ast = @import("../ast/root.zig");

const Parser = ctx.Parser;
const ParseError = ctx.ParseError;
const Node = ast.Node;

/// Parse a type: `[]T`, `[N]T`, nested `[2][3]int`, `Name`, or `T | U`.
pub fn parseType(self: *Parser) ParseError!*Node {
    var left: *Node = undefined;
    if (self.checkDelim("[")) {
        const start = self.peek(0).?;
        _ = self.advance();
        var length: ?usize = null;
        if (self.check(.number) or self.check(.hex) or self.check(.octal) or self.check(.binary)) {
            const num_tok = self.advance().?;
            length = try parseArrayLength(self, num_tok);
        }
        _ = try self.consume(.delimiter, "Expected ']' in array type", "]");
        const elem = try parseType(self);
        left = try self.create(.{ .array_type = .{
            .elem = elem,
            .length = length,
            .loc = self.locOf(start),
        } });
    } else {
        left = try parseTypeAtom(self);
    }

    while (self.checkDelim("|")) {
        _ = self.advance();
        const right = try parseTypeAtom(self);
        const peek = self.peek(0) orelse self.previous().?;
        left = try self.create(.{ .union_type = .{
            .left = left,
            .right = right,
            .loc = self.locOf(peek),
        } });
    }
    return left;
}

fn parseArrayLength(self: *Parser, num_tok: ctx.Token) ParseError!usize {
    const raw = num_tok.value;
    const n: i64 = switch (num_tok.type) {
        .hex => std.fmt.parseInt(i64, raw[2..], 16) catch {
            return self.failTok(num_tok, "Invalid array length '{s}'", .{raw});
        },
        .binary => std.fmt.parseInt(i64, raw[2..], 2) catch {
            return self.failTok(num_tok, "Invalid array length '{s}'", .{raw});
        },
        .octal => std.fmt.parseInt(i64, raw[2..], 8) catch {
            return self.failTok(num_tok, "Invalid array length '{s}'", .{raw});
        },
        else => std.fmt.parseInt(i64, raw, 10) catch {
            return self.failTok(num_tok, "Invalid array length '{s}'", .{raw});
        },
    };
    if (n < 0) return self.failTok(num_tok, "Invalid array length '{s}'", .{raw});
    return @intCast(n);
}

fn parseTypeAtom(self: *Parser) ParseError!*Node {
    const peek = self.peek(0) orelse return self.failMsg("Expected type name");
    if (peek.type == .keyword and std.mem.eql(u8, peek.value, "error")) {
        _ = self.advance();
        return self.create(.{ .primary = .{
            .kind = .identifier,
            .name = try self.dupe("error"),
            .loc = self.locOf(peek),
        } });
    }
    const type_name = try self.consume(.identifier, "Expected type name", null);
    return self.create(.{ .primary = .{
        .kind = .identifier,
        .name = try self.dupe(type_name.value),
        .loc = self.locOf(type_name),
    } });
}
