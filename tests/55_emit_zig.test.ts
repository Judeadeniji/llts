/**
 * Native emitter: `llts emit-zig` must produce Zig that compiles and matches
 * the bytecode VM for the supported subset (functions, locals, scalar
 * arithmetic, strings, print, top-level code, @if, @switch, and @for).
 */
import { test, expect } from "bun:test";
import { spawnSync } from "bun";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { runCli, runFile } from "./helpers";

const ROOT = path.resolve(import.meta.dir, "..");
const ZIG_BIN = process.env.LLTS_ZIG_BIN || "zig";

interface Emitted {
	sourcePath: string;
	outputPath: string;
	cleanup: () => void;
}

function emitZig(source: string): Emitted {
	const id = `${Date.now()}_${Math.random().toString(36).slice(2)}`;
	const sourcePath = path.join(os.tmpdir(), `llts_emit_zig_${id}.lls`);
	const outputPath = path.join(ROOT, `.tmp_emit_zig_${id}.zig`);
	fs.writeFileSync(sourcePath, source, "utf-8");
	return {
		sourcePath,
		outputPath,
		cleanup: () => {
			if (fs.existsSync(sourcePath)) fs.unlinkSync(sourcePath);
			if (fs.existsSync(outputPath)) fs.unlinkSync(outputPath);
		},
	};
}

function runEmitted(outputPath: string) {
	const result = spawnSync([ZIG_BIN, "run", "-lc", outputPath], { cwd: ROOT });
	return {
		stdout: result.stdout.toString(),
		stderr: result.stderr.toString(),
		exitCode: result.exitCode ?? 1,
	};
}

function expectParity(source: string, checkGenerated?: (code: string) => void) {
	const emitted = emitZig(source);
	try {
		const emit = runCli(["emit-zig", emitted.sourcePath, "-o", emitted.outputPath]);
		expect(emit.stderr + emit.stdout).toBe("");
		expect(emit.exitCode).toBe(0);
		if (checkGenerated) {
			checkGenerated(fs.readFileSync(emitted.outputPath, "utf-8"));
		}

		const native = runEmitted(emitted.outputPath);
		const vm = runFile(emitted.sourcePath);
		expect(native.exitCode).toBe(vm.exitCode);
		expect(native.stdout).toBe(vm.stdout);
	} finally {
		emitted.cleanup();
	}
}

test("emits functions, locals, and scalar arithmetic", () => {
	expectParity(`
@func add(a: int, b: int): int {
    return a + b;
}

pub @func main() {
    $a = 20;
    $b = 22;
    print(add(a, b));
    print(a * b - 10);
    print(-a);
    print(1.25 * 2.0);
}
`, (generated) => {
	expect(generated).not.toContain("@as(i64, lls_");
	expect(generated).not.toContain("@bitCast(lls_");
});
}, 60_000);

test("emits strings, booleans, len, and @as", () => {
	expectParity(`
pub @func main() {
    $s: string = "foo" + "bar";
    print(s);
    print(len(s));
    print(s == "foobar");
    print("a" != "b");
    print(@as(u8, 42));
    print(@as(int, @as(u8, 42)));
}
`, (generated) => {
	expect(generated).not.toContain("@as([]const u8,");
});
}, 60_000);

test("emits top-level globals before main", () => {
	expectParity(`
@const $base = 10;
$counter = 0;
print("top");
counter = counter + 1;
print(counter);

@func get(): int {
    return base;
}

pub @func main() {
    print(get());
    print(counter);
}
`);
}, 60_000);

test("runtime traps keep the VM error message and exit code", () => {
	const emitted = emitZig(`
@func div(a: int, b: int): int {
    return a / b;
}

pub @func main() {
    print("before");
    print(div(1, 0));
}
`);
	try {
		const emit = runCli(["emit-zig", emitted.sourcePath, "-o", emitted.outputPath]);
		expect(emit.exitCode).toBe(0);

		const native = runEmitted(emitted.outputPath);
		const vm = runFile(emitted.sourcePath);
		expect(native.exitCode).toBe(1);
		expect(vm.exitCode).toBe(1);
		expect(native.stdout).toBe("before\n");
		expect(vm.stdout).toBe("before\n");
		expect(native.stderr).toContain("Error: Division by zero");
		expect(vm.stderr).toContain("Error: Division by zero");
	} finally {
		emitted.cleanup();
	}
}, 60_000);

test("emits @if, @else @if, and returns inside arms", () => {
	expectParity(`
@func sign(a: int): int {
    @if (a < 0) {
        return 0 - 1;
    } @else @if (a > 0) {
        return 1;
    }
    return 0;
}

pub @func main() {
    $n = 2;
    @if (n == 1) {
        print("one");
    } @else @if (n == 2) {
        print("two");
    } @else {
        print("other");
    }
    @if (false) {
        print("bad");
    }
    print(sign(0 - 5));
    print(sign(0));
    print(sign(5));
}
`);
}, 60_000);

test("emits value-producing @if with break payloads", () => {
	expectParity(`
$g = @if (true) {
    break 3;
} @else {
    break 4;
};
print(g);

pub @func main() {
    $n = 2;
    $x = @if (n == 1) {
        break 10;
    } @else @if (n == 2) {
        break 20;
    } @else {
        break 30;
    };
    print(x);

    $y = @if (n > 0) {
        @if (n == 2) {
            break 42;
        }
        break 0;
    } @else {
        break 0 - 1;
    };
    print(y);

    $word: string = @if (true) {
        break "yes";
    } @else {
        break "no";
    };
    print(word);

    $dead = @if (true) {
        $unused = 7;
        break 1;
        print(unused);
    } @else {
        break 2;
    };
    print(dead);
    print(g);
}
`);
}, 60_000);

test("emits statement and value-producing @switch", () => {
	expectParity(`
pub @func main() {
    $n = 2;
    @switch (n) {
        1 => { print("one"); },
        2, 3 => { print("two-three"); },
        @else => { print("other"); },
    }
    @switch (n) {
        1 => { print("only-one"); },
    }
    $x = @switch (n) {
        1 => { break 10; },
        2 => { break 20; },
        @else => { break 30; },
    };
    print(x);
    $s = @switch ("b") {
        "a" => { break 1; },
        "b" => { break 2; },
        @else => { break 3; },
    };
    print(s);
    $f = @switch (1.5) {
        1.0 => { break 4; },
        1.5 => { break 5; },
        @else => { break 6; },
    };
    print(f);
}
`, (generated) => {
	expect(generated).toContain("lls_sw_");
	expect(generated).toContain("rt.arith.eqStr");
});
}, 60_000);

test("emits range and condition @for loops with break/continue", () => {
	expectParity(`
pub @func main() {
    @for (0..3) |i| {
        print(i);
    }
    $n = 4;
    @for (0..n) |i| {
        @if (i == 1) {
            continue;
        }
        @if (i == 3) {
            break;
        }
        print(i);
    }
    roll: @for (0..5) |i| {
        @for (0..5) |j| {
            @if (j == 2) {
                continue :roll;
            }
            @if (i == 2) {
                break :roll;
            }
            print(i * 10 + j);
        }
    }
    unused: @for (0..2) |i| {
        print(i);
    }
    via_value: @for (0..2) |i| {
        $x = @if (i == 0) {
            @for (0..2) |j| {
                @if (j == 0) {
                    break :via_value;
                }
                break;
            }
            break 1;
        } @else {
            break 2;
        };
        print(x);
    }
    print("via-value done");
    $k = 0;
    @for (k < 3) {
        print(k);
        k = k + 1;
    }
    @for (false) {
        print("bad");
    }
}
`);
}, 60_000);

test("emits iterable @for over arrays, slices, and strings", () => {
	expectParity(`
pub @func main() {
    $arr: [3]int = [10, 20, 30];
    @for (arr) |value, index| {
        print(index);
        print(value);
    }
    $slice: []int = [9, 8];
    @for (slice) |n| {
        print(n);
    }
    $s: string = "abc";
    @for (s) |c| {
        print(c);
    }
    $count = 0;
    @for (arr) |value| {
        count = count + value;
    }
    print(count);
}
`);
}, 60_000);

test("emits structs, arrays, slices, and optionals", () => {
	expectParity(`
@struct Point {
    x: int;
    y: int;
}

@struct Box {
    point: Point;
    label: string;
}

@func maybe(flag: bool): ?Point {
    @if (flag) {
        return Point { x: 3, y: 4 };
    }
    return null;
}

pub @func main() {
    $p: Point = { x: 3, y: 4 };
    print(p.x + p.y);
    p.x = 10;
    print(p.x);

    $fixed: [3]int = [1, 2, 3];
    print(fixed[0] + fixed[2]);
    fixed[1] = 7;
    print(len(fixed));
    print(fixed[1]);

    $view: []int = fixed;
    view[0] = 50;
    print(fixed[0]);
    print(view[0]);

    $box: Box = { point: Point { x: 1, y: 2 }, label: "box" };
    box.point.x = 5;
    print(box.point.x);
    $points: [2]Point = [Point { x: 1, y: 2 }, Point { x: 3, y: 4 }];
    points[1].x = 8;
    print(points[1].x);

    $dynamic: []int = [4, 5, 6];
    dynamic[0] = 40;
    print(len(dynamic));
    print(dynamic[0]);

    $text: string = "hello";
    print(text[1..3]);
    print(len(text));

    $none: ?int = null;
    print(none);
    $some: ?int = 5;
    print(some);

    @if (maybe(true)) |point| {
        print(point.x);
        print(point.y);
    } @else {
        print("missing");
    }
    @if (maybe(false)) |point| {
        print(point.x);
    } @else {
        print("missing");
    }
}
`);
}, 60_000);

test("emits @defer on scope exit, break, continue, and return", () => {
	expectParity(`
@func valueBeforeDefer() {
    $x = 0;
    defer x = 5;
    return x;
}

@func order() {
    defer print("first");
    defer print("second");
    print("body");
}

pub @func main() {
    $x = 0;
    @for (0..3) |i| {
        defer x = x + i;
        continue;
    }
    print(x);

    @for (true) {
        defer x = x + 10;
        break;
    }
    print(x);

    $y = 0;
    @if (true) {
        defer y = y + 5;
        y = y + 1;
    }
    print(y);

    print(valueBeforeDefer());
    order();
}
`);
}, 60_000);

test("emits pointers and address-of places", () => {
	expectParity(`
@struct Point {
    x: int;
    y: int;
}

@func bump(p: *Point) {
    p.x = p.x + 1;
}

pub @func main() {
    $p: Point = { x: 1, y: 2 };
    $q: *Point = &p;
    q.x = 5;
    print(p.x);
    bump(&p);
    print(p.x);

    $pts: [2]Point = [Point { x: 1, y: 2 }, Point { x: 3, y: 4 }];
    $rp: *Point = &pts[1];
    rp.y = 9;
    print(pts[1].y);

    $nums: [2]int = [1, 2];
    $np: *[2]int = &nums;
    print(np[1]);
    print(len(np));
    np[1] = 7;
    print(nums[1]);
}
`);
}, 60_000);
