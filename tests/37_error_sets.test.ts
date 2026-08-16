/**
 * Typed error sets: `@error Name { A, B }`, members, `|` / `&`, switch exhaustiveness, `?`.
 */
import { test } from "bun:test";
import { expectError, expectOutput, runSource } from "./helpers";

test("@error member construct, return, print", () => {
	expectOutput(
		runSource(`
@error IoError { NotFound, Denied }

@func open(fail: u1): i64 | IoError {
  @if (fail == 1) {
    return IoError.NotFound;
  }
  return 7;
}

$x = open(0)?;
print(x);
print(open(1));
`),
		["7", "Error: NotFound"],
	);
});

test("incomplete @switch on error set fails", () => {
	expectError(
		runSource(`
@error IoError { NotFound, Denied }

@func handle(e: IoError) {
  @switch (e) {
    IoError.NotFound => {},
  }
}

pub @func main() {
  handle(IoError.Denied);
}
`),
		"missing error member",
	);
});

test("full @switch on error set ok", () => {
	expectOutput(
		runSource(`
@error IoError { NotFound, Denied }

@func handle(e: IoError) {
  @switch (e) {
    IoError.NotFound => { print("nf"); },
    IoError.Denied => { print("den"); },
  }
}

pub @func main() {
  handle(IoError.NotFound);
  handle(IoError.Denied);
}
`),
		["nf", "den"],
	);
});

test("@switch with @else covers remaining", () => {
	expectOutput(
		runSource(`
@error IoError { NotFound, Denied }

@func handle(e: IoError) {
  @switch (e) {
    IoError.NotFound => { print("nf"); },
    @else => { print("other"); },
  }
}

pub @func main() {
  handle(IoError.Denied);
}
`),
		["other"],
	);
});

test("union of sets requires all members", () => {
	expectError(
		runSource(`
@error IoError { NotFound, Denied }
@error HttpError { Timeout, Forbidden }

@type AppError = IoError | HttpError;

@func handle(e: AppError) {
  @switch (e) {
    IoError.NotFound => {},
    IoError.Denied => {},
    HttpError.Timeout => {},
  }
}

pub @func main() {
  handle(HttpError.Forbidden);
}
`),
		"missing error member",
	);
});

test("union of sets full cover", () => {
	expectOutput(
		runSource(`
@error IoError { NotFound, Denied }
@error HttpError { Timeout, Forbidden }

@type AppError = IoError | HttpError;

@func handle(e: AppError) {
  @switch (e) {
    IoError.NotFound => { print("nf"); },
    IoError.Denied => { print("den"); },
    HttpError.Timeout => { print("to"); },
    HttpError.Forbidden => { print("forb"); },
  }
}

pub @func main() {
  handle(IoError.NotFound);
  handle(HttpError.Timeout);
}
`),
		["nf", "to"],
	);
});

test("merge & full cover", () => {
	expectOutput(
		runSource(`
@error IoError { NotFound, Denied }
@error HttpError { Timeout, Forbidden }

@type Merged = IoError & HttpError;

@func handle(e: Merged) {
  @switch (e) {
    IoError.NotFound => { print("nf"); },
    IoError.Denied => { print("den"); },
    HttpError.Timeout => { print("to"); },
    HttpError.Forbidden => { print("forb"); },
  }
}

pub @func main() {
  handle(HttpError.Forbidden);
}
`),
		["forb"],
	);
});

test("merge & conflicting member names", () => {
	expectError(
		runSource(`
@error IoError { Timeout }
@error HttpError { Timeout }

@type Bad = IoError & HttpError;

pub @func main() {}
`),
		"conflicting error member",
	);
});

test("@type member + mixed union with ?", () => {
	expectOutput(
		runSource(`
@error IoError { NotFound, Denied }

@type NotFoundErr = IoError.NotFound;
@type MaybeBytes = IoError.NotFound | []byte;

@func load(ok: u1): MaybeBytes {
  @if (ok == 0) {
    return IoError.NotFound;
  }
  return "hi";
}

pub @func main() {
  $b = load(1)?;
  print(b);
  print(load(0));
}
`),
		["hi", "Error: NotFound"],
	);
});

test("@isError on error set members and unions", () => {
	expectOutput(
		runSource(`
@error IoError { NotFound, Denied }

@func open(fail: u1): i64 | IoError {
  @if (fail == 1) {
    return IoError.NotFound;
  }
  return 7;
}

pub @func main() {
  print(@isError(IoError.NotFound));
  print(@isError(7));
  print(@isError(open(1)));
  print(@isError(open(0)));
}
`),
		["true", "false", "true", "false"],
	);
});

test("set member assignable to open error (anyerror-style umbrella)", () => {
	expectOutput(
		runSource(`
@error IoError { NotFound }

@func f(): error {
  return IoError.NotFound;
}

pub @func main() {
  $e: error = f();
  print(e);
  print(@isError(e));
}
`),
		["Error: NotFound", "true"],
	);
});

test("open error not assignable to set", () => {
	expectError(
		runSource(`
@error IoError { NotFound }

@func f(): IoError {
  return error("Nope");
}

pub @func main() {}
`),
		"not assignable",
	);
});

// ---------------------------------------------------------------------------
// Error handling policy: typed; discarded fallible stmts warn (non-fatal)
// ---------------------------------------------------------------------------

test("discarding fallible call in pure function warns but runs", () => {
	const res = runSource(`
@error IoError { NotFound }

@func fail(): i64 | IoError {
  return IoError.NotFound;
}

@func pure(): i64 {
  fail();
  return 1;
}

pub @func main() {
  print(pure());
}
`);
	expectOutput(res, ["1"]);
	if (!res.stderr.includes("Warning") || !res.stderr.includes("discarded")) {
		throw new Error(`expected discard Warning on stderr, got:\n${res.stderr}`);
	}
});

test("discarding fallible call in main warns but runs", () => {
	const res = runSource(`
@error IoError { NotFound }

@func fail(): i64 | IoError {
  return IoError.NotFound;
}

pub @func main() {
  fail();
  print("ok");
}
`);
	expectOutput(res, ["ok"]);
	if (!res.stderr.includes("Warning") || !res.stderr.includes("discarded")) {
		throw new Error(`expected discard Warning on stderr, got:\n${res.stderr}`);
	}
});

test("discarding fallible call in fallible function also warns", () => {
	const res = runSource(`
@error IoError { NotFound }

@func fail(): i64 | IoError {
  return IoError.NotFound;
}

@func wrap(): i64 | IoError {
  fail();
  return 1;
}

pub @func main() {
  print(wrap());
}
`);
	expectOutput(res, ["1"]);
	if (!res.stderr.includes("Warning") || !res.stderr.includes("discarded")) {
		throw new Error(`expected discard Warning on stderr, got:\n${res.stderr}`);
	}
});

test("storing error union without unwrap is allowed (no discard warning)", () => {
	const res = runSource(`
@error IoError { NotFound }

@func fail(): i64 | IoError {
  return IoError.NotFound;
}

pub @func main() {
  $x = fail();
  print(@isError(x));
  print(x);
}
`);
	expectOutput(res, ["true", "Error: NotFound"]);
	if (res.stderr.includes("discarded")) {
		throw new Error(`unexpected discard Warning on bind:\n${res.stderr}`);
	}
});

test("cannot return set member from pure i64 function", () => {
	expectError(
		runSource(`
@error IoError { NotFound }

@func bad(): i64 {
  return IoError.NotFound;
}

pub @func main() {}
`),
		"not assignable",
	);
});

test("? inside pure function is rejected", () => {
	expectError(
		runSource(`
@error IoError { NotFound }

@func fail(): i64 | IoError {
  return IoError.NotFound;
}

@func pure(): i64 {
  return fail()?;
}

pub @func main() {}
`),
		"does not allow error",
	);
});

test("? on non-error value is rejected", () => {
	expectError(
		runSource(`
@func get(): i64 {
  return 7;
}

@func wrap(): i64 | error {
  return get()?;
}

pub @func main() {}
`),
		"non-error-union",
	);
});
