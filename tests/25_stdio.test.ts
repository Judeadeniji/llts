/**
 * std/io stdin/stdout/stderr File handles + write/read helpers.
 */
import { test } from "bun:test";
import { expectOutput, runSource } from "./helpers";

test("io.stdout / stderr writeAll and println", () => {
	const res = runSource(`
@const $io = @import("std/io");
pub @func main() {
    io.stdout.writeAll("out-line\\n");
    io.stderr.writeAll("err-line\\n");
    io.println("via-println");
    io.eprintln("via-eprintln");
}
`);
	if (res.exitCode !== 0) {
		throw new Error(`exit ${res.exitCode}\nstderr: ${res.stderr}`);
	}
	if (!res.stdout.includes("out-line") || !res.stdout.includes("via-println")) {
		throw new Error(`bad stdout:\n${res.stdout}`);
	}
	if (!res.stderr.includes("err-line") || !res.stderr.includes("via-eprintln")) {
		throw new Error(`bad stderr:\n${res.stderr}`);
	}
});

test("io stdio fds match syscall constants", () => {
	expectOutput(
		runSource(`
@const $io = @import("std/io");
@const $syscall = @import("std/syscall");
print(io.stdin.fd == syscall.STDIN_FILENO);
print(io.stdout.fd == syscall.STDOUT_FILENO);
print(io.stderr.fd == syscall.STDERR_FILENO);
`),
		["true", "true", "true"],
	);
});

test("io.writeAll through a pipe", () => {
	expectOutput(
		runSource(`
@const $io = @import("std/io");
@const $syscall = @import("std/syscall");
@const $buffer = @import("std/buffer");
$fds = syscall.pipe();
print(io.writeAll(fds[1], "ping") == 4);
$b = buffer.alloc(8);
print(io.read(fds[0], b) == 4);
print(buffer.readString(b, 0, 4));
syscall.close(fds[0]);
syscall.close(fds[1]);
`),
		["true", "true", "ping"],
	);
});

test("io.fromFd method style on a pipe", () => {
	expectOutput(
		runSource(`
@const $io = @import("std/io");
@const $syscall = @import("std/syscall");
@const $buffer = @import("std/buffer");
@const $mem = @import("std/mem");
$a = mem.create(0);
defer a.deinit();
$fds = syscall.pipe();
$w = io.fromFd(a, fds[1]);
$r = io.fromFd(a, fds[0]);
print(w.writeAll("pong") == 4);
$b = buffer.alloc(8);
print(r.read(b) == 4);
print(buffer.readString(b, 0, 4));
syscall.close(fds[0]);
syscall.close(fds[1]);
`),
		["true", "true", "pong"],
	);
});

test("local io.File method style", () => {
	const res = runSource(`
@const $io = @import("std/io");
pub @func main() {
    $out = io.File{ fd: io.stdout.fd };
    out.writeAll("method-ok\\n");
}
`);
	if (res.exitCode !== 0) {
		throw new Error(`exit ${res.exitCode}\nstderr: ${res.stderr}`);
	}
	if (!res.stdout.includes("method-ok")) {
		throw new Error(`bad stdout:\n${res.stdout}`);
	}
});

test("syscall.writeAll writes full payload", () => {
	expectOutput(
		runSource(`
@const $syscall = @import("std/syscall");
@const $buffer = @import("std/buffer");
$fds = syscall.pipe();
print(syscall.writeAll(fds[1], "abcdef") == 6);
$b = buffer.alloc(8);
print(syscall.read(fds[0], b) == 6);
print(buffer.readString(b, 0, 6));
syscall.close(fds[0]);
syscall.close(fds[1]);
`),
		["true", "true", "abcdef"],
	);
});
