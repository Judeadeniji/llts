/**
 * Test: Explicit error handling
 *
 * Tests the `error` keyword for creating errors,
 * the `@isError()` builtin (or typeOf) for checking them manually,
 * and the `?` postfix operator for automatic propagation.
 */
import { test } from "bun:test";
import { runSource, expectOutput, expectError } from "./helpers";

// ---------------------------------------------------------------------------
// Basic creation / inspection
// ---------------------------------------------------------------------------

test("can create and print an error", () => {
  expectOutput(runSource(`
$err = error("File not found");
print(err);
`), ["Error: File not found"]);
});

test("can manually check if a value is an error", () => {
  expectOutput(runSource(`
$err = error("Boom");
$val = 42;
print(@isError(err));
print(@isError(val));
`), ["true", "false"]);
});

test("@isError returns false for other falsy-ish values", () => {
  expectOutput(runSource(`
print(@isError(0));
print(@isError(""));
print(@isError(false));
print(@isError(null));
`), ["false", "false", "false", "false"]);
});

test("error() with empty message", () => {
  expectOutput(runSource(`
$err = error("");
print(err);
`), ["Error: "]);
});

test("two errors with the same message are distinct instances", () => {
  expectOutput(runSource(`
$a = error("same");
$b = error("same");
print(a == b);
`), ["false"]);
});

// ---------------------------------------------------------------------------
// ? operator: basic propagation / unwrap (existing, kept for regression)
// ---------------------------------------------------------------------------

test("? operator propagates error automatically", () => {
  expectOutput(runSource(`
@func fail(): string | error {
    return error("Task failed successfully");
}

@func doWork(): string | error {
    $result = fail()?;
    print("This should not print");
    return "Success";
}

$res = doWork();
print(res);
`), ["Error: Task failed successfully"]);
});

test("? operator unwraps successful value", () => {
  expectOutput(runSource(`
@func succeed(): string | error {
    return "Task succeeded";
}

@func doWork(): string | error {
    $result = succeed()?;
    print(result);
    return "Done";
}

doWork();
`), ["Task succeeded"]);
});

// ---------------------------------------------------------------------------
// ? operator: propagation depth
// ---------------------------------------------------------------------------

test("? propagates through three levels of nested calls", () => {
  expectOutput(runSource(`
@func level3(): string | error {
    return error("deep failure");
}

@func level2(): string | error {
    $r = level3()?;
    return r;
}

@func level1(): string | error {
    $r = level2()?;
    return r;
}

print(level1());
`), ["Error: deep failure"]);
});

test("? stops propagation at the first level that manually checks", () => {
  expectOutput(runSource(`
@func fail(): string | error {
    return error("inner boom");
}

@func middle(): string | error {
    return fail()?;
}

@func outer(): string {
    $res = middle();
    @if (@isError(res)) {
        return "caught: " + res.message;
    }
    return "no error";
}

print(outer());
`), ["caught: inner boom"]);
});

test("multiple ? calls in the same function, first one fails", () => {
  expectOutput(runSource(`
@func a(): string | error { return error("a failed"); }
@func b(): string | error { return "b ok"; }

@func doWork(): string | error {
    $x = a()?;
    $y = b()?;
    print("unreachable");
    return x + y;
}

print(doWork());
`), ["Error: a failed"]);
});

test("multiple ? calls in the same function, second one fails", () => {
  expectOutput(runSource(`
@func a(): string | error { return "a ok"; }
@func b(): string | error { return error("b failed"); }

@func doWork(): string | error {
    $x = a()?;
    $y = b()?;
    print("unreachable");
    return x + y;
}

print(doWork());
`), ["Error: b failed"]);
});

test("? used directly in an expression without intermediate assignment", () => {
  expectOutput(runSource(`
@func getNum(): number | error {
    return 10;
}

@func doWork(): number | error {
    return getNum()? + 5;
}

print(doWork());
`), ["15"]);
});

test("? propagates immediately even mid-expression, short-circuiting the rest", () => {
  expectOutput(runSource(`
@func getNum(): number | error {
    return error("no number");
}

@func sideEffect(): number {
    print("side effect ran");
    return 1;
}

@func doWork(): number | error {
    return getNum()? + sideEffect();
}

print(doWork());
`), ["Error: no number"]);
});

// ---------------------------------------------------------------------------
// ? operator: interaction with control flow
// ---------------------------------------------------------------------------

test("? inside a for loop propagates out of the loop and function", () => {
  expectOutput(runSource(`
@func risky(i: number): number | error {
    @if (i == 2) {
        return error("failed at 2");
    }
    return i;
}

@func doWork(): number | error {
    $total = 0;
    @for (0..5) |i| {
        total = total + risky(i)?;
    }
    return total;
}

print(doWork());
`), ["Error: failed at 2"]);
});

test("? inside a loop that never fails accumulates normally", () => {
  expectOutput(runSource(`
@func risky(i: number): number | error {
    return i;
}

@func doWork(): number | error {
    $total = 0;
    @for (0..5) |i| {
        total = total + risky(i)?;
    }
    return total;
}

print(doWork());
`), ["10"]);
});

test("? inside an if-branch that is never taken does not fire", () => {
  expectOutput(runSource(`
@func fail(): string | error {
    return error("should not run");
}

@func doWork(cond: bool): string | error {
    @if (cond) {
        $r = fail()?;
        return r;
    }
    return "skipped";
}

print(doWork(false));
`), ["skipped"]);
});

// ---------------------------------------------------------------------------
// error objects: fields / interop
// ---------------------------------------------------------------------------

test("error value exposes a readable .message field", () => {
  expectOutput(runSource(`
$err = error("custom message");
print(err.message);
`), ["custom message"]);
});

test("@isError on the result of a function call, not just a variable", () => {
  expectOutput(runSource(`
@func fail(): string | error {
    return error("direct check");
}

print(@isError(fail()));
`), ["true"]);
});

test("errors can be stored in and retrieved from an array", () => {
  expectOutput(runSource(`
$errs = [error("first"), error("second")];
print(errs[0]);
print(errs[1]);
print(@isError(errs[0]));
`), ["Error: first", "Error: second", "true"]);
});

// ---------------------------------------------------------------------------
// ? operator: misuse / edge cases
// ---------------------------------------------------------------------------

test("? on a function with no error in its return type is a compile-time error", () => {
  expectError(runSource(`
@func getStr(): string {
    return "original text";
}

@func doWork(): string | error {
    return getStr()?;
}

print(doWork());
`), "CompileError: '?' operator used on non-error-union type '[]byte'");
});

test("propagated error keeps its original message through multiple hops unmodified", () => {
  expectOutput(runSource(`
@func origin(): string | error {
    return error("original text");
}

@func hop1(): string | error {
    return origin()?;
}

@func hop2(): string | error {
    return hop1()?;
}

$final = hop2();
print(@isError(final));
print(final.message);
`), ["true", "original text"]);
});