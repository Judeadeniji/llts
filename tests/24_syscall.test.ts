import { test } from "bun:test";
import { expectOutput, runSource } from "./helpers";

test("syscall: getpid, nr, call, SYS_* agree", () => {
	expectOutput(
		runSource(`
@const $syscall = @import("std/syscall");
print(syscall.getpid() > 0);
print(syscall.SYS_getpid == syscall.nr("getpid"));
print(syscall.call(syscall.SYS_getpid) == syscall.getpid());
print(syscall.isError(syscall.call(syscall.SYS_getpid)) == false);
print(syscall.errName(syscall.call(syscall.SYS_getpid)) == "");
`),
		["true", "true", "true", "true", "true"],
	);
});

test("syscall: open/write/read/lseek/unlink roundtrip", () => {
	expectOutput(
		runSource(`
@const $syscall = @import("std/syscall");
@const $buffer = @import("std/buffer");
$path = "test_syscall_roundtrip.txt";
$flags = syscall.O_CREAT | syscall.O_WRONLY | syscall.O_TRUNC;
$fd = syscall.open(path, flags, 420);
print(@isError(fd) == false);
print(syscall.write(fd, "abc") == 3);
syscall.close(fd);
$fd2 = syscall.open(path, syscall.O_RDONLY);
$b = buffer.alloc(8);
print(syscall.read(fd2, b) == 3);
print(buffer.readString(b, 0, 3));
print(syscall.lseek(fd2, 0, syscall.SEEK_SET) == 0);
syscall.close(fd2);
syscall.unlink(path);
$missing = syscall.access(path);
print(@isError(missing));
`),
		["true", "true", "true", "abc", "true", "true"],
	);
});

test("syscall: pipe duplex", () => {
	expectOutput(
		runSource(`
@const $syscall = @import("std/syscall");
@const $buffer = @import("std/buffer");
$fds = syscall.pipe();
print(len(fds) == 2);
syscall.write(fds[1], "z");
$b = buffer.alloc(4);
print(syscall.read(fds[0], b) == 1);
print(buffer.get(b, 0) == 122);
syscall.close(fds[0]);
syscall.close(fds[1]);
`),
		["true", "true", "true"],
	);
});

test("syscall: open missing path is SyscallError", () => {
	expectOutput(
		runSource(`
@const $syscall = @import("std/syscall");
$err = syscall.open("/no/such/llts/path/xyz", syscall.O_RDONLY);
print(@isError(err));
print(err.code);
`),
		["true", "SyscallError"],
	);
});

test("syscall: ids and cwd", () => {
	expectOutput(
		runSource(`
@const $syscall = @import("std/syscall");
@const $os = @import("std/os");
print(syscall.getuid() >= 0);
print(syscall.getgid() >= 0);
print(syscall.getcwd() == os.cwd());
print(syscall.STDOUT_FILENO == 1);
print(syscall.O_RDONLY == 0);
`),
		["true", "true", "true", "true", "true"],
	);
});
