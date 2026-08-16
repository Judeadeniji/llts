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

test("set member assignable to open error", () => {
	expectOutput(
		runSource(`
@error IoError { NotFound }

@func f(): error {
  return IoError.NotFound;
}

pub @func main() {
  print(f());
}
`),
		["Error: NotFound"],
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
